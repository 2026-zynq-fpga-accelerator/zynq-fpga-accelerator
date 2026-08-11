## HW/SW Interface Specification v1.4 (DRAFT) — OP_GLOBAL_AVG_POOL 추가 + Fully Connected

이 문서는 `HW_SW_Interface_v1.1_FINAL.md`(§1~§20)와 `HW_SW_Interface_v1.2_DRAFT.md`(`OP_RESIDUAL_ADD`)를
대체하지 않고 **확장**한다. 마스터 문서 진짜 "단계 3"(`STAGE3_MASTER_ROADMAP.md` §2.1)의 첫 항목 —
Global Average Pooling과 Fully Connected layer — 를 다룬다.

**DRAFT인 이유**: RTL 구현 및 통합 시뮬레이션에서 `mismatch=0`이 확인되면 `_FINAL`로 승격한다.

**핵심 결정 미리 요약**: 이번 확장은 GAP만 진짜 신규 연산이고, **FC는 신규 연산이 아니다.** FC는
`OP_CONV`에 `KERNEL_SIZE=1, HEIGHT=WIDTH=1`을 대입한 것과 수학적으로 완전히 동일하며, kernel=1
지원은 지난 라운드(빌드 `86ff3c7`)에서 이미 실기 검증까지 끝났다(§3 참조). 즉 **RTL 쪽 신규 작업은
GAP 하나뿐**이다.

---

## 1. 원칙

- `OP_GLOBAL_AVG_POOL`과 FC(=`OP_CONV` 재사용)는 v1.1 §3 원칙 1("한 START = 한 operation")을
  그대로 따르는 **독립 operation**이다.
- 새 ERROR_CODE는 추가하지 않는다 — v1.1 §10.1 기존 코드를 그대로 재사용한다.
- 새 opcode는 **`OP_GLOBAL_AVG_POOL`(3) 하나만** 필요하다. v1.1 §8.5에 이미 예약돼 있던 값을
  그대로 쓴다. `OP_FC`(opcode 4)는 **영구히 미사용(예약 상태 유지)** — §3에서 이유를 설명한다.
- GAP → FC 사이에는 별도 reshape/flatten 연산이 없다. GAP 출력이 이미 `[1][1][C]`이므로 FC 입력에
  그대로 넣는다(§4 실행 순서).

---

## 2. Global Average Pooling (`OP_GLOBAL_AVG_POOL`)

### 2.1 Opcode

| 값 | Operation | v1.4 지원 |
|---:|---|---|
| 3 | `OP_GLOBAL_AVG_POOL` | **필수** (기존 "예약"에서 격상) |

`accel_regs.h`에는 이미 `ACCEL_OPERATION_GLOBAL_AVG_POOL = 3`으로 반영돼 있다. RTL은
`OPERATION == 3`을 `OP_GLOBAL_AVG_POOL`로 decode하도록 구현한다.

### 2.2 Register 재사용 매핑

새 register 없이 v1.1 §8.2 register map을 재해석한다.

| Offset | Register | `OP_CONV`에서의 의미 | `OP_GLOBAL_AVG_POOL`에서의 의미 |
|---:|---|---|---|
| `0x08` | OPERATION | 0 | **3** |
| `0x0C`/`0x10` | INPUT_HEIGHT/WIDTH | 입력 spatial 크기 | 동일 의미 (pooling window = 전체 spatial) |
| `0x14` | IN_CHANNELS | 입력 채널 수 | 동일 의미 |
| `0x18` | OUT_CHANNELS | 출력 채널 수 | **IN_CHANNELS와 항상 같은 값** (GAP은 채널 수를 바꾸지 않음) — 다르면 `ERR_INVALID_CONFIG` |
| `0x1C` | CONV_CONFIG | Kernel/Stride/Padding/ReLU | **전부 미사용, `0`으로 write.** `RELU_ENABLE`도 항상 0 — Python golden model(`resnet_fp.py` `forward()`)에서 GAP 뒤에 ReLU가 없음(바로 `flatten`→`fc`) |
| `0x20` | OUTPUT_SCALE | M/N 재양자화 계수 | **평균(÷ H×W)을 위한 M/N** — §2.5, 새 의미이지만 register/수식(v1.1 §5.4)은 그대로 재사용 |
| `0x24` | INPUT_BYTES | INPUT packet byte 수 | 동일 의미, `H×W×C` |
| `0x28` | WEIGHT_BYTES | WEIGHT packet byte 수 | **0** (weight 없음) |
| `0x2C` | BIAS_BYTES | BIAS packet byte 수 | **0** (bias 없음) |
| `0x30` | SKIP_BYTES | 미사용 | **0** (skip 없음) |
| `0x34` | OUTPUT_BYTES | OUTPUT packet byte 수 | `C` (=`1×1×OUT_CHANNELS`) |

### 2.3 DEBUG_STATE 재사용

새 상태 없음 — v1.1 §8.8 기존 값만 사용한다. WEIGHT/BIAS/SKIP packet이 전혀 없으므로 `LOAD_WEIGHT`,
`LOAD_BIAS`, `LOAD_SKIP`은 GAP 경로에서 등장하지 않는다.

| 값 | `OP_GLOBAL_AVG_POOL`에서의 의미 |
|---:|---|
| 4 (`LOAD_INPUT`) | 입력 activation 수신 |
| 5 (`COMPUTE`) | 채널별 합산 + M/N 평균 requantization |
| 6 (`SEND_OUTPUT`) / 7 (`COMPLETE`) | v1.1과 동일 |

> 정민님 쪽 RTL 작업: Controller FSM이 `OPERATION==3`일 때 `LOAD_WEIGHT`/`LOAD_BIAS`를 건너뛰고
> `IDLE → LOAD_INPUT → COMPUTE → SEND_OUTPUT`으로 바로 가도록 분기 추가. 이게 GAP에서 유일하게
> 새로 필요한 FSM 변경이다.

### 2.4 Packet 규칙

가장 단순한 packet 흐름 — WEIGHT/BIAS/SKIP이 모두 없다.

```text
1. INPUT ACTIVATION packet
2. OUTPUT ACTIVATION packet 송신
```

- v1.1 §4.2/§6.3과 동일하게 NHWC, signed INT8, AXI4-Stream 32-bit.
- Byte 수 공식:

```text
input_bytes  = IN_H × IN_W × IN_CHANNELS     (register: INPUT_BYTES)
output_bytes = OUT_CHANNELS                   (register: OUTPUT_BYTES, = IN_CHANNELS와 동일)
```

이 아키텍처(ResNet-20 CIFAR)에서 GAP 입력 채널은 항상 16/32/64이므로 `output_bytes`는 항상 4의
배수 — §3.5의 FC 패딩 문제가 GAP에는 발생하지 않는다.

### 2.5 연산 정의

v1.1 §5.1(누산)과 §5.4(M/N requantization) 수식을 그대로 재사용한다 — 곱셈이 없는 순수 합산이라는
점만 다르다.

```text
for c = 0 .. IN_CHANNELS-1:
    sum_i32 = 0
    for h = 0 .. IN_H-1:
        for w = 0 .. IN_W-1:
            sum_i32 = SAT_INT32(sum_i32 + sign_extend(input[h][w][c]))   // v1.1 §5.2와 동일 saturation

    mean_scaled = requantize(sum_i32, MULTIPLIER_M, SHIFT_N)             // v1.1 §5.4 수식 그대로
    output[c]   = clamp(mean_scaled, -128, 127)                          // ReLU 없음, INT8 saturation만
```

- `ERR_ACC_OVERFLOW`는 이론상 거의 발생하지 않는다 — 최대 `|sum| = 127 × (IN_H×IN_W)`이며 이
  모델의 최대 spatial(32×32=1024)에서도 `127×1024=130,048`로 INT32 범위에 한참 못 미친다. 그래도
  동작 정의는 v1.1 §10.1 그대로 유지한다(우연히 다른 설정으로 재사용될 경우를 대비).

### 2.6 권장 M/N 값

`SHIFT_N ≤ 31`(v1.1 §11.2 상속) 조건 안에서, **`IN_H × IN_W`가 2의 거듭제곱이면 정확한 평균이
가능**하다 — 이 모델은 stem/stage 해상도가 항상 32/16/8이라 항상 2의 거듭제곱이다.

```text
M = 1
N = log2(IN_H × IN_W)
```

| 적용 위치 | IN_H×IN_W | 권장 M | 권장 N |
|---|---:|---:|---:|
| stage3 최종 출력 → GAP (이 모델의 유일한 GAP 호출 지점) | 8×8=64 | 1 | 6 |

`M=1`이므로 곱셈이 필요 없고, `N=6`으로 나눗셈이 정확히 나누어져 **반올림 오차가 전혀 없는 평균**이
나온다(§v1.1 §5.4의 반올림 규칙은 이 경우 항상 나머지 0이라 실질적으로 미적용).

### 2.7 권장 설정 예시

```text
IN_H = IN_W = 8, IN_CHANNELS = OUT_CHANNELS = 64
Input  : [1][8][8][64]  NHWC INT8   (stage3 마지막 BasicBlock 출력)
Output : [64]            INT8       (= [1][1][64], flatten과 동일)
```

| Packet | 계산 | 크기 |
|---|---:|---:|
| Input | `8×8×64×1 byte` | 4,096 bytes (1,024 beat) |
| Output | `64×1 byte` | 64 bytes (16 beat) |

---

## 3. Fully Connected — 신규 연산 아님, `OP_CONV(KERNEL_SIZE=1)` 재사용

### 3.1 왜 신규 연산이 필요 없는가

`nn.Linear(64, 10)`(`resnet_fp.py` `ResNet20CIFAR.fc`)은 다음과 같다.

```text
y = W @ x + b     (W: [10][64], x: [64], b: [10], y: [10])
```

1×1 공간 입력에 대한 `Conv2d(64, 10, kernel_size=1)`은 output channel마다:

```text
y[oc] = Σ_ic  weight[0][0][ic][oc] × input[0][0][ic]  + bias[oc]
```

즉 **spatial 크기가 1×1일 때 1×1 conv와 FC는 완전히 동일한 연산**이다. kernel=1 RTL 파라미터화가
지난 라운드(`STAGE3_RTL_REQUEST.md`, 빌드 `86ff3c7`)에서 이미 board-verified 상태이므로, FC는
**새 opcode, 새 register 의미, 새 FSM 분기가 전혀 필요 없다.**

```text
OPERATION    = 0 (OP_CONV, 그대로)
INPUT_HEIGHT = 1
INPUT_WIDTH  = 1
KERNEL_SIZE  = 1
STRIDE       = 1
PADDING      = 0
RELU_ENABLE  = 0   (최종 분류 logit에는 ReLU를 적용하지 않음 — forward()에 fc 뒤 ReLU 없음)
```

`accel_regs.h`의 `ACCEL_OPERATION_FC = 4`는 **영구히 미사용 예약값으로 남긴다** — RTL이 `OPERATION
== 4`를 decode할 필요가 전혀 없다. v1.1 §8.5의 opcode 1(`OP_POOL`)과 마찬가지로 "예약, 구현 안 함"
상태로 확정한다.

### 3.2 Weight/Bias layout — 반드시 확인할 gotcha

v1.1 §4.3 HWIO 인덱스 공식(`index = (((kh×KW)+kw)×IC+ic)×OC+oc`)에 `KH=KW=1`을 대입하면:

```text
index = ic × OC + oc     (ic-major, oc-minor)
```

**`nn.Linear.weight`의 PyTorch 기본 shape는 `[out_features][in_features]`(oc-major)로, 이 순서와
반대다.** Python exporter가 `weight.bin`을 쓰기 전에 반드시 **transpose**해야 한다.

```python
# resnet_fp.py 의 self.fc.weight: shape [10, 64] (oc-major)
weight_hwio = fc.weight.T   # -> [64, 10] (ic-major), 그대로 flatten하면 HWIO 순서와 일치
```

- Bias는 `nn.Linear.bias`가 이미 `[out_features]`라 별도 reorder 불필요.
- 이 gotcha는 §v1.1 §3 원칙 6("Python exporter, 펌웨어, RTL은 같은 layout 규칙을 사용")에 해당하는
  이번 확장의 핵심 위험 지점 — projection shortcut(kernel=1) 때는 원래 conv weight가 이미 HWIO라
  이런 transpose 문제가 없었다.

### 3.3 Output byte 수 4-byte 정렬 문제와 해결

CIFAR-10 `num_classes=10`이라 순수 출력은 `10 bytes`, v1.1 §6.2("v1.0의 모든 packet byte 수는
4의 배수")를 위반한다. **이 프로젝트 전체에서 output byte 수가 4의 배수가 아닌 유일한 지점이다**
(GAP/conv 출력은 채널 수가 항상 16/32/64라 문제없음, §2.4).

**해결 — RTL/DRE를 건드리지 않는 쪽을 선택**: v1.1 §6.3이 예비해둔 "마지막 beat만 partial
TKEEP"(DRE 필요) 대신, **OUT_CHANNELS 자체를 12로 패딩**한다. 실제 class가 아닌 채널 2개를
weight=0, bias=0으로 만들면 그 두 채널의 출력은 항상 정확히 0이 되고(다른 채널 계산에는 전혀
영향 없음, MAC은 output channel마다 독립), 4-byte 정렬이 저절로 맞아 **RTL/streamer/DMA 쪼기 전혀
필요 없다.**

```text
OUT_CHANNELS(register) = 12          (10 실제 class + 2 zero-padding channel)
weight.bin: [64][12], 마지막 2 column(oc=10,11)은 전부 0
bias.bin:   [12],     마지막 2개(oc=10,11)는 0
```

| Packet | 계산 (OC=12 기준) | 크기 |
|---|---:|---:|
| Weight | `1×1×64×12×1 byte` | 768 bytes (192 beat) |
| Bias | `12×4 bytes` | 48 bytes (12 beat) |
| Input | `1×1×64×1 byte` | 64 bytes (16 beat) |
| Output | `1×1×12×1 byte` | 12 bytes (3 beat) |

모든 packet이 4의 배수 — DRE, partial TKEEP, RTL 예외 처리 **전혀 불필요**. 펌웨어는 출력 버퍼를
12 bytes로 할당하고 **`output[0..9]`만 실제 class score로 해석**(`output[10]`, `output[11]`은
항상 0, argmax 로직에서 무시).

> 이 패딩은 순수 Python exporter/펌웨어 쪽 데이터 준비 결정이며, RTL/register 의미론에는 아무
> 영향이 없다 — `OP_CONV(kernel=1)`이 원래 지원하던 그대로 `OUT_CHANNELS=12`인 보통의 conv를
> 실행할 뿐이다.

### 3.4 펌웨어 구현 노트 (참고, 정민님 확인 불필요)

- `accel_run_layer()`/`resnet_scheduler.c`는 **변경 없음** — 이미 byte count 기반으로 WEIGHT/
  BIAS/INPUT/SKIP packet을 조건부 전송하는 범용 구조라(§`accel_driver.c:290-357`), `OP_CONV`
  경로를 그대로 타면 끝난다.
- `resnet_layer.h`의 `OP_FC` enum 값은 유지하되, `accel_driver.c`의 `accel_configure()`에 얇은
  분기만 추가해 `OP_FC` → 레지스터에는 `ACCEL_OPERATION_CONV`(0)를 쓰고 `kernel=1, stride=1,
  padding=0, height=1, width=1`을 자동으로 채워 넣는 방식을 권장(호출부에서 매번 이 값들을 손으로
  안 채워도 되게). 이건 순수 편의 함수이며 레지스터/RTL 계약과는 무관.

---

## 4. 실행 순서 (Firmware Scheduler) — stage3 출력부터 classification까지

```text
[GAP]   stage3_block_output(8×8×64) → gap_output(64)
  (§2 그대로, OPERATION=3, OUTPUT_SCALE: M=1/N=6 권장, WEIGHT/BIAS/SKIP_BYTES=0)

[FC]    gap_output(64) → fc_output(12, 앞 10개만 유효)
  (§3 그대로, OPERATION=0, HEIGHT=WIDTH=1, KERNEL=1, STRIDE=1, PADDING=0,
   IN_CHANNELS=64, OUT_CHANNELS=12, RELU_ENABLE=0)

[ARM]   fc_output[0..9] 중 최댓값 index = argmax = 예측 class
```

DDR 버퍼는 기존 관례(`STAGE2_BASIC_RESIDUAL_BLOCK_PLAN.md`/`STAGE3_RTL_REQUEST.md` 방식)를 따라
`gap_output`(64B), `fc_output`(12B, 4-byte aligned) 2개를 새로 추가하면 된다.

---

## 5. v1.1/v1.2 대비 변경 요약

| 항목 | 상태 |
|---|---|
| 신규 opcode | `OP_GLOBAL_AVG_POOL`(3) **하나만** — v1.1에 이미 예약된 값을 "예약"→"필수"로 격상 |
| `OP_FC`(4) | **영구 미사용 예약으로 확정** — FC는 `OP_CONV(kernel=1, H=W=1)`로 실행 |
| 신규 register | 없음 — 기존 필드 재해석만 |
| 신규 ERROR_CODE | 없음 |
| 신규 DEBUG_STATE | 없음 |
| 신규 FSM 분기 | GAP 하나뿐 (`LOAD_WEIGHT`/`LOAD_BIAS` 스킵, §2.3) — **FC는 FSM 변경도 없음** |
| Weight layout gotcha | `nn.Linear.weight`는 exporter에서 transpose 필요 (§3.2) |
| Byte 정렬 | FC output을 `OUT_CHANNELS=12`(zero-padded)로 맞춰 4-byte 배수 유지, DRE/partial TKEEP 불필요 (§3.3) |

---

## 6. 확인 체크리스트

- [x] Opcode: `OP_GLOBAL_AVG_POOL=3` 활성화, `OP_FC=4`는 영구 예약으로 유지 (2026-08-11, 정민 —
      `accel_pkg.sv`에 현재 `OP_CONV=0`/`OP_RESIDUAL_ADD=2`만 정의돼 있어 3/4 모두 충돌 없음,
      `accel_regs.h`의 기존 예약값과도 일치)
- [x] GAP register 재사용 매핑 (§2.2) (2026-08-11, 정민 — `controller_fsm.sv`의 기존
      `OP_RESIDUAL_ADD` 전용 검증 분기(`VAL_FIELDS`→`VAL_INPUT_AREA`→`VAL_INPUT_CHANNELS`→전용
      COMPARE state, DIMS/WEIGHT_CHANNELS/OUTPUT_AREA 우회)와 동일한 패턴으로 GAP 전용 분기를
      추가하면 표에 나온 필드 전부 기존 레지스터/검증 인프라로 수용 가능. 신규 레지스터 불필요
      확인)
- [x] GAP FSM 분기 (`LOAD_WEIGHT`/`LOAD_BIAS` 스킵, §2.3) (2026-08-11, 정민 — `OP_RESIDUAL_ADD`가
      이미 동일하게 `DBG_LOAD_WEIGHT`/`DBG_LOAD_BIAS`를 건너뛰고 `DBG_LOAD_INPUT`으로 직행하는
      분기가 있음(`controller_fsm.sv` line 590, 658). GAP도 같은 자리에 세 번째 분기 추가로 구현
      가능, 새 FSM state 불필요)
- [x] FC를 `OP_CONV(kernel=1)`로 실행한다는 결정 자체 (§3.1) (2026-08-11, 정민 — RTL 영향 없음에
      동의. `H=W=1, KERNEL=1, STRIDE=1, PADDING=0` 대입 시 기존 일반화된 출력 크기 공식
      (`padded - kernel_size + 1` = `1-1+1=1`)과 최소 patch 크기 검사가 정상 통과함을 코드로
      확인. 다만 이 정확한 조합(H=W=1)은 지난 kernel=1 테스트(H=W=4 기준)에서 직접 검증된 적은
      없음 — 요청하신 별도 directed test로 커버 예정, §4 참조)
- [x] FC weight transpose gotcha 확인 (2026-08-10, 소은수 — exporter 구현 시 반영)
- [x] FC output 4-byte 정렬을 위한 `OUT_CHANNELS=12` zero-padding 결정 (2026-08-10, 소은수)
- [ ] GAP RTL 구현
- [ ] GAP unit/directed test (모든 입력 0, 최대/최소, overflow 불가능 확인용 큰 채널 수, M=1/N=6
      정확도 확인)
- [ ] GAP → FC(OP_CONV kernel=1) 통합 시뮬레이션, stage3 출력부터 logit까지 mismatch 0
- [ ] 실기 Zybo Z7-20 최소 10회 PASS
- [ ] 위 항목 전부 통과 후 `_DRAFT` → `_FINAL`로 승격

---

# 변경 이력

## v1.4 (DRAFT, 2026-08-10)

- `OP_GLOBAL_AVG_POOL` 추가 — opcode, register 재사용, FSM 분기, 평균 연산 정의, 권장 M/N 확정
  (§2)
- FC는 신규 연산으로 추가하지 않고 `OP_CONV(kernel=1, H=W=1)` 재사용으로 확정, `OP_FC` opcode는
  영구 예약 상태 유지 (§3)
- FC weight layout transpose gotcha 및 output byte 4-byte 정렬(`OUT_CHANNELS=12` zero-padding)
  결정 (§3.2, §3.3)
