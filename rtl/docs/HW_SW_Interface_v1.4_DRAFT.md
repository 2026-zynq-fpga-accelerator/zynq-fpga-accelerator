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
| `0x1C` | CONV_CONFIG | Kernel/Stride/Padding/ReLU | **전부 미사용, `0`으로 write.** `RELU_ENABLE`도 항상 0 |
| `0x20` | OUTPUT_SCALE | M/N 재양자화 계수 | **평균(÷ H×W)을 위한 M/N** — §2.5, 새 의미이지만 register/수식(v1.1 §5.4)은 그대로 재사용 |
| `0x24` | INPUT_BYTES | INPUT packet byte 수 | 동일 의미, `H×W×C` |
| `0x28` | WEIGHT_BYTES | WEIGHT packet byte 수 | **0** (weight 없음) |
| `0x2C` | BIAS_BYTES | BIAS packet byte 수 | **0** (bias 없음) |
| `0x30` | SKIP_BYTES | 미사용 | **0** (skip 없음) |
| `0x34` | OUTPUT_BYTES | OUTPUT packet byte 수 | `C` (=`1×1×OUT_CHANNELS`) |

### 2.3 DEBUG_STATE 재사용

새 상태 없음 — v1.1 §8.8 기존 값만 사용한다.

| 값 | `OP_GLOBAL_AVG_POOL`에서의 의미 |
|---:|---|
| 4 (`LOAD_INPUT`) | 입력 activation 수신 |
| 5 (`COMPUTE`) | 채널별 합산 + M/N 평균 requantization |
| 6 (`SEND_OUTPUT`) / 7 (`COMPLETE`) | v1.1과 동일 |

### 2.4 Packet 규칙

```text
1. INPUT ACTIVATION packet
2. OUTPUT ACTIVATION packet 송신
```

```text
input_bytes  = IN_H × IN_W × IN_CHANNELS     (register: INPUT_BYTES)
output_bytes = OUT_CHANNELS                   (register: OUTPUT_BYTES, = IN_CHANNELS와 동일)
```

### 2.5 연산 정의

```text
for c = 0 .. IN_CHANNELS-1:
    sum_i32 = 0
    for h = 0 .. IN_H-1:
        for w = 0 .. IN_W-1:
            sum_i32 = SAT_INT32(sum_i32 + sign_extend(input[h][w][c]))

    mean_scaled = requantize(sum_i32, MULTIPLIER_M, SHIFT_N)
    output[c]   = clamp(mean_scaled, -128, 127)
```

### 2.6 권장 M/N 값

```text
M = 1
N = log2(IN_H × IN_W)
```

| 적용 위치 | IN_H×IN_W | 권장 M | 권장 N |
|---|---:|---:|---:|
| stage3 최종 출력 → GAP (이 모델의 유일한 GAP 호출 지점) | 8×8=64 | 1 | 6 |

---

## 3. Fully Connected — 신규 연산 아님, `OP_CONV(KERNEL_SIZE=1)` 재사용

(§3.1~§3.4는 v1.4 초안과 동일 — weight transpose gotcha, `OUT_CHANNELS=12` zero-padding으로
4-byte 정렬 확보. 변경 없음.)

---

## 4. 실행 순서 (Firmware Scheduler)

```text
[GAP]   stage3_block_output(8×8×64) → gap_output(64)
[FC]    gap_output(64) → fc_output(12, 앞 10개만 유효)
[ARM]   fc_output[0..9] 중 최댓값 index = argmax = 예측 class
```

---

## 5. v1.1/v1.2 대비 변경 요약

(변경 없음 — 초안과 동일)

---

## 6. 확인 체크리스트

- [x] Opcode: `OP_GLOBAL_AVG_POOL=3` 활성화, `OP_FC=4`는 영구 예약으로 유지 (2026-08-11, 정민 — RTL 코드 대비 검토 완료, 기존 구조와 충돌 없음)
- [x] GAP register 재사용 매핑 (§2.2) (2026-08-11, 정민 — 확인 완료)
- [x] GAP FSM 분기 (`LOAD_WEIGHT`/`LOAD_BIAS` 스킵, §2.3) (2026-08-11, 정민 — `OP_RESIDUAL_ADD`가 이미 쓰는 것과 동일 패턴, 설계 리스크 낮음)
- [x] FC를 `OP_CONV(kernel=1)`로 실행한다는 결정 자체 (§3.1) (2026-08-11, 정민 — 기존 출력 크기 공식이 이미 일반화돼 있어 RTL 영향 없음 확인. 단, H=W=1 조합은 실제 테스트 이력이 없어 §7 directed test에 필수 포함)
- [x] FC weight transpose gotcha 확인 (2026-08-10, 소은수)
- [x] FC output 4-byte 정렬을 위한 `OUT_CHANNELS=12` zero-padding 결정 (2026-08-10, 소은수)
- [ ] GAP RTL 구현 — 진행 중 (§7 참조)
- [ ] GAP unit/directed test
- [ ] GAP → FC(OP_CONV kernel=1, H=W=1) 통합 시뮬레이션, mismatch 0
- [ ] 실기 Zybo Z7-20 최소 10회 PASS
- [ ] 위 항목 전부 통과 후 `_DRAFT` → `_FINAL`로 승격

---

## 7. GAP RTL 구현 계획 (참고, 2026-08-11 추가)

RTL 쪽 구현 설계를 공유한다 — 펌웨어/register 계약에는 영향 없는 순수 구현 세부사항이라
확인 불필요, 참고용.

- **신규 모듈 `gap_engine.sv`**: `conv_engine`(곱셈+커널루프)도 `residual_add_engine`(상태 없는
  1워드 처리)도 GAP에 맞지 않아 별도 엔진으로 구현한다. 채널별로 accumulator 1개를 두고 전체
  공간 위치를 순회하며 누적, 이후 기존 `requantizer.sv`(새 수식 없음, 그대로 재사용)로 M/N
  평균 처리 후 INT8 clamp.
- **출력 포트**: GAP과 conv는 동시에 실행되지 않으므로, top-level에서 `conv_engine`이 이미 쓰는
  byte-write 출력 포트를 2:1 mux로 공유한다 — `tensor_buffers.sv` 변경 없음.
- **controller_fsm.sv**: `OP_RESIDUAL_ADD`가 이미 쓰고 있는 것과 같은 패턴(전용 검증 분기 +
  `LOAD_WEIGHT`/`LOAD_BIAS` 스킵)을 그대로 확장 — 신규 FSM 구조 아님.
- **설계 결정 확정**:
  - Saturating add(`sat_add_int32.sv` 기존 모듈 재사용)로 구현 — overflow는 이론상 불가능하지만
    (최대 127×1024=130,048 ≪ INT32 범위) 코드 재사용 및 안전성 위해 유지.
  - `OUTPUT_SCALE=0`(M=0) 처리: 기존 `OP_CONV`가 M=0을 막지 않는 것과 동일하게, GAP도 별도
    검증 로직을 추가하지 않는다 — 연산별로 검증 기준이 달라지는 것을 피하기 위함. (M=0이 실제
    문제라면 이는 GAP만의 이슈가 아니라 `OP_CONV`를 포함한 기존 이슈이므로 이번 확장 범위 밖의
    별도 항목으로 남겨둔다.)
  - 모듈/포트 네이밍(`gap_engine.sv`, `gap_start_i`, `gap_done_o`)은 특별한 충돌 사유가 없는 한
    이대로 진행한다.

---

# 변경 이력

## v1.4 (DRAFT, 2026-08-10, 갱신 2026-08-11)

- `OP_GLOBAL_AVG_POOL` 추가 — opcode, register 재사용, FSM 분기, 평균 연산 정의, 권장 M/N 확정 (§2)
- FC는 신규 연산으로 추가하지 않고 `OP_CONV(kernel=1, H=W=1)` 재사용으로 확정 (§3)
- §6 체크리스트 중 "정민님 확인 필요" 4항목 전부 RTL 코드 대비 검토 완료 (2026-08-11)
- §7 GAP RTL 구현 계획 및 설계 결정(saturating add, M=0 미차단, 네이밍) 추가
