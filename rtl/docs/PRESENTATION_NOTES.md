# 발표 자료 — RTL / HW-SW 인터페이스 설계 (정민 파트, 15분)

- 대상 청중: 컴퓨터구조·운영체제·임베디드 수강 학부생, Vivado 기본 사용법만 숙지
- 톤: 이론 설명 최소화, 실제 프로젝트에서 "무엇을 왜 이렇게 했는지" 위주
- 은수님 파트(펌웨어/소프트웨어/골든모델)와 시간 분담, 이 문서는 RTL/인터페이스만

---

## 1. 프로젝트 개요 (1~2분)

- **목표**: CIFAR-10 ResNet-20 추론을 Zynq SoC 위에서 하드웨어 가속으로 실행
- **보드**: Zybo Z7-20 (Zynq-7020, `xc7z020clg400-1`)
  - PS(ARM Cortex-A9, bare-metal) + PL(FPGA fabric) 한 칩에 통합된 구조
- **왜 FPGA 가속기인가**: ResNet의 핵심 연산(conv, GAP)은 반복적인 MAC 연산이 대부분 — ARM 코어로 순수 소프트웨어 실행하면 느림. PL에 전용 파이프라인을 만들어 그 부분만 떼어서 가속
- 진행 방식: 단계적 확장 — 1단계 단일 conv → 2단계 residual block → 3단계 GAP/FC + 9-block 전체 backbone

---

## 2. ResNet-20의 연산 종류 (2분, 개념만)

CIFAR-10용 ResNet-20이 실제로 필요로 하는 연산은 이 6가지뿐:

| 연산 | 한 줄 설명 |
|---|---|
| **Convolution** | 3×3 conv(대부분), 1×1 conv(shortcut 채널/해상도 정합용) |
| **BatchNorm** | 학습 후 **conv weight/bias에 미리 접어 넣음(folding)** → 온칩 별도 연산 아님 |
| **ReLU** | 음수 클리핑, 매 conv 뒤 |
| **Residual Add** | shortcut 경로 + main 경로 값을 더한 뒤 최종 ReLU |
| **Global Average Pooling (GAP)** | 마지막 feature map을 공간 전체 평균 내서 1×1로 축소 |
| **Fully Connected (FC)** | GAP 출력 → 10개 class score |

BatchNorm이 목록에서 빠진 이유가 중요함 — **연산이 없어서가 아니라, 추론 시점에는 이미 conv weight/bias에 수학적으로 합쳐져 있어서** RTL이 신경 쓸 필요가 없음. RTL은 "conv → bias add → requantize → (선택)ReLU"라는 파이프라인 하나만 구현하면 실제로는 BatchNorm까지 포함된 것.

---

## 3. PS(CPU) – PL(가속기) 역할 분담 (2분)

**PL(하드웨어)이 맡는 것**: 반복량이 크고 병렬화 이득이 큰 것만
- MAC 연산(conv), 채널별 accumulate(GAP), saturating add(residual)
- 고정 기능 파이프라인 — 범용 명령어 실행이 아니라 "이 연산 하나만 빠르게"

**PS(소프트웨어)가 맡는 것**: 그 외 전부
- 어떤 레이어를 어떤 순서로 돌릴지 스케줄링(레이어 리스트 순회)
- 양자화 계수(M/N), BatchNorm folding 등 **오프라인에서 미리 계산 가능한 것**은 전부 Python에서 끝내고 레지스터 값으로만 전달
- AXI DMA 제어, register 설정/폴링
- 최종 argmax(class 결정)

**왜 이렇게 나눴나**: "자주 반복되고 병렬화 가능한 계산"만 하드웨어로 만들고, "가끔 바뀌고 유연성이 필요한 제어/정책"은 소프트웨어에 남김. 이 원칙이 §4의 설계 전략과 그대로 이어짐 — 새 레이어 종류가 필요할 때 하드웨어를 다시 설계하는 대신, 최대한 기존 하드웨어 조합 + 펌웨어 코드로 해결하려 함.

---

## 4. 각 연산의 RTL 구현 (5~6분, 메인 파트)

### 4.1 설계 철학: "새로 안 만들고, 이미 있는 걸 재해석"

가장 처음 인터페이스 문서(v1.1)를 쓸 때부터 **opcode(연산 종류) 슬롯을 5개 미리 예약**해뒀음:

| OPERATION 값 | 이름 | v1.1 시점 상태 |
|---:|---|---|
| 0 | `OP_CONV` | 필수 구현 |
| 1 | `OP_POOL` | 예약 (끝까지 미사용) |
| 2 | `OP_RESIDUAL_ADD` | 예약 |
| 3 | `OP_GLOBAL_AVG_POOL` | 예약 |
| 4 | `OP_FC` | 예약 |

프로젝트가 진행되면서 이 예약 슬롯을 하나씩 "활성화"했는데, 그때마다 **새 레지스터를 추가하지 않고 기존 필드를 재해석**하는 쪽을 택함:

- **OP_RESIDUAL_ADD 추가할 때**: WEIGHT_BYTES/BIAS_BYTES 레지스터는 0으로 강제(안 씀), `CONV_CONFIG` 레지스터의 bit 24 하나만 "최종 ReLU 여부"로 재사용. DEBUG_STATE에 `LOAD_SKIP` 상태 1개만 추가.
- **OP_GLOBAL_AVG_POOL 추가할 때**: WEIGHT/BIAS/SKIP 전부 0 강제, `CONV_CONFIG` 전체를 0으로 강제. `OUTPUT_SCALE`(원래 conv의 M/N 재양자화 계수)을 그대로 "평균 계수"로 재사용 — 수식은 완전히 동일(`M=1, N=log2(H×W)`면 반올림 오차 없는 정확한 평균).
- **FC(완전연결층) 추가할 때**: opcode조차 새로 안 씀. `OP_CONV`에 `KERNEL_SIZE=1, H=W=1`만 넣으면 1×1 conv와 FC가 수학적으로 완전히 동일 연산 — **이 부분은 RTL 코드 한 줄도 안 바꿨음.**

### 4.2 이걸 가능하게 한 열쇠: KERNEL_SIZE 일반화

원래 `KERNEL_SIZE`는 3(3×3 conv)으로 하드코딩돼 있었음. 이걸 임의값을 받는 파라미터로 바꾸면서:
- `controller_fsm.sv`: 출력 크기 계산 공식(`출력 = (입력+padding−kernel)/stride + 1`), 최소 patch 크기 검사
- `conv_engine.sv`: MAC 누적 루프의 종료 조건(커널 순회 카운터)

이 **한 번의 일반화**가 서로 다른 두 가지 요구를 동시에 풀어줌:
1. Projection shortcut(1×1 conv, 채널 수/해상도 정합용)
2. FC(1×1 conv, H=W=1인 극단적인 경우)

### 4.3 실제 연산 엔진 3개

| 모듈 | 담당 연산 | 핵심 구조 |
|---|---|---|
| `conv_engine.sv` | Conv(3×3, 1×1), FC | MAC 파이프라인: 곱셈→누적→bias 더하기→requantize→ReLU/clamp |
| `residual_add_engine.sv` | Residual Add | 상태 없음 — 한 워드 읽고, 더하고, 바로 씀 (곱셈 없음) |
| `gap_engine.sv` | GAP | 채널마다 accumulator 1개로 공간 전체 순회하며 누적 → 누적 끝나면 requantize |

세 엔진이 공통으로 재사용하는 조각 모듈:
- `sat_add_int32.sv` (오버플로우 나면 saturate하는 덧셈)
- `requantizer.sv` (M/N 재양자화 — INT32 → INT8 변환 수식)
- `relu_clamp.sv` (ReLU + INT8 clamp)

→ 매 연산마다 새로 계산 로직을 짜는 게 아니라, **이미 검증된 조각을 다른 조합으로 이어붙이는 식**으로 확장.

### 4.4 지휘자: Controller FSM

`controller_fsm.sv`가 하는 일:
- `OPERATION` 레지스터 값을 보고 어떤 연산인지 판별, 설정값 검증(자체 곱셈기로 크기 계산 후 레지스터 값과 대조)
- 연산별로 필요 없는 패킷 단계는 건너뜀 (예: GAP/Residual Add는 WEIGHT/BIAS 단계 자체를 스킵)
- 검증 끝나면 해당 엔진(`conv_engine`/`residual_add_engine`/`gap_engine`)에 시작 신호를 보냄

GAP을 추가할 때도 **완전히 새로 설계하지 않고, 이미 있던 Residual Add의 라우팅 패턴을 그대로 확장**해서 구현 — "새 연산 추가 = 새 FSM 설계"가 아니라 "새 연산 추가 = 기존 패턴에 한 가지 분기 추가"가 되도록 만든 것이 이 프로젝트 RTL 설계의 일관된 방향.

---

## 5. CPU → PL 데이터 흐름 (3분, 그림 1장)

```text
[PS: ARM 펌웨어]
   1. AXI4-Lite write: OPERATION, INPUT_HEIGHT/WIDTH, IN/OUT_CHANNELS,
      CONV_CONFIG, OUTPUT_SCALE, *_BYTES 레지스터 설정
   2. AXI4-Lite write: CONTROL.START = 1
                    │
                    ▼
[PL: RTL 내부 검증]
   설정값이 유효한지 자체 검사(크기 계산 후 대조) → 불합격이면 ERROR_CODE만 세팅하고 대기 상태로

                    │  (합격)
                    ▼
[PS ↔ PL: AXI4-Stream 패킷, 연산에 필요한 것만 순서대로]
   WEIGHT → BIAS → INPUT → (SKIP, Residual Add만) → PL이 받음
   각 tensor는 AXI DMA MM2S 개별 transfer로 전송
   PL은 DEBUG_STATE(LOAD_WEIGHT→LOAD_BIAS→LOAD_INPUT→...)로 지금 뭘 기다리는지 노출

                    │
                    ▼
[PL: COMPUTE 상태]
   conv_engine / residual_add_engine / gap_engine 중 하나가 실제 연산 수행

                    │
                    ▼
[PL → PS: AXI4-Stream OUTPUT 패킷]
   PL이 결과를 AXI4-Stream으로 송신 → AXI DMA S2MM으로 PS DDR에 저장

                    │
                    ▼
[PS: 완료 확인]
   STATUS.DONE/ERROR 폴링 + S2MM DMA 완료 둘 다 확인 → 다음 레이어로
```

핵심 포인트: **가속기 register map에는 DDR 주소가 아예 없음.** 큰 데이터(가중치/입출력)는 전부 AXI4-Stream + DMA로 흐르고, AXI4-Lite는 오직 "설정값 몇 개 + 제어 비트"만 담당 — 두 인터페이스의 역할이 명확히 분리됨.

---

## 6. 검증 방법론 (1분, 짧게)

- **1단계 — RTL 시뮬레이션**: Vivado xsim 기반, 연산별 directed testbench + 여러 연산을 실제로 체이닝한 통합 시뮬레이션. 여기서 golden model(Python) 대비 mismatch 0을 먼저 확인.
- **2단계 — 실기 검증**: 시뮬레이션을 통과한 것만 비트스트림으로 합성해서 Zybo Z7-20 보드에 올려 재확인.
- 즉 **"보드에 올려보고 디버깅"이 아니라 "시뮬레이션에서 먼저 걸러내고, 보드에서는 확인만"** 하는 순서를 지킴.

---

# 참고문헌

- 내부 조사자료: *"ReLU, BatchNorm, LayerNorm and PE Design Research"* (`RELU_BN_LN_PE_DESIGN_RESEARCH.md`, 별도 저장소 `resnet-fpga-accelerator/docs/`) — ReLU를 별도 opcode 대신 conv/residual 파이프라인에 fuse하는 결정, BatchNorm을 RTL 없이 오프라인 folding으로 처리하는 근거, LayerNorm을 현재 범위에서 제외한 근거를 다룸
- Xilinx/AMD, *Zynq-7000 SoC Technical Reference Manual* (UG585)
- Arm, *AMBA AXI4 and AXI4-Stream Protocol Specification*
- 프로젝트 내부 문서: `HW_SW_Interface_v1.1_FINAL.md` ~ `v1.4_DRAFT.md`
- 프로젝트 내부 문서: `PROJECT_MASTER_HANDOFF.md`, `STAGE3_MASTER_ROADMAP.md`
- He, K., Zhang, X., Ren, S., Sun, J., *"Deep Residual Learning for Image Recognition"*, CVPR 2016
