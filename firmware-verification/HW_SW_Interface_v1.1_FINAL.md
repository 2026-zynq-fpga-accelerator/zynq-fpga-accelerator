# Zynq FPGA SoC 기반 ResNet 추론 가속기
## HW/SW Interface Specification v1.1

- 문서 상태: **1단계 구현 기준선 확정본 (Baseline), v1.0 리뷰 반영**
- 적용 범위: **단일 3×3 Convolution + Bias + Requantization + 선택적 ReLU**
- 확장 대상: Basic Residual Block → CIFAR-10 ResNet-20
- 작성 목적: Python golden model, ARM bare-metal firmware, AXI DMA, SystemVerilog RTL 사이의 데이터·제어 규칙을 하나로 통일한다.
- 변경 원칙: 본 문서와 다른 구현이 필요하면 코드보다 먼저 인터페이스 문서 버전을 갱신한다.

---

# 0. v1.1 수정 사항 (v1.0 리뷰 반영)

v1.0에 대한 실현 가능성·디버깅 용이성 검토 결과, 다음 네 가지를 이번 개정에서 수정했다. 나머지 항목은 v1.0 그대로 유지한다.

| # | 항목 | 문제 | 수정 내용 | 위치 |
|---|---|---|---|---|
| 1 | ABORT 완료 확인 누락 | `accel_wait_done` timeout 시 `accel_abort()`만 호출하고 `BUSY==0`을 재확인하지 않아, 다음 operation 설정과 경쟁(race)할 수 있었다 | ABORT 이후 `BUSY==0`을 별도 timeout으로 재확인하는 confirm loop를 추가하고, 확인 실패 시 `ACCEL_ABORT_TIMEOUT`을 반환한다 | §11.4, §11.5 |
| 2 | ERROR_CODE 우선순위 모호성 | 비치명적 오류가 연속으로 발생하는 경우의 동작이 암묵적으로만 규정되어 있었다 | "두 오류가 모두 비치명적이면 최초 code를 유지하고 이후 code는 반영하지 않는다"를 명시적으로 규정 | §10.4 |
| 3 | 내부 FSM 상태 미노출 | STATUS는 IDLE/BUSY/DONE/ERROR 4비트뿐이라 timeout 발생 시 어느 단계(LOAD_WEIGHT/LOAD_BIAS/…)에서 멈췄는지 알 수 없었다 | RO register `DEBUG_STATE (0x44)` 추가, 현재 Controller FSM 상태를 노출 | §8.2, §8.8, §12 |
| 4 | START+ABORT 동시 write 미정의 | CONTROL에 START와 ABORT를 한 write로 동시에 1을 쓰는 경우, 그리고 IDLE 상태에서 ABORT만 오는 경우의 동작이 없었다 | ABORT 우선 처리 규칙과 IDLE 중 ABORT no-op 규칙을 명시 | §8.3 |

---

# 1. 시스템 경계

```text
Python / PyTorch
  ├─ BatchNorm folding
  ├─ Fixed-point quantization
  ├─ 입력·가중치·bias 생성
  └─ Bit-accurate expected output 생성
                         ↓
                       PS DDR
                         ↓
ARM bare-metal firmware (Zynq PS)
  ├─ AXI4-Lite: 가속기 설정·시작·상태 확인
  └─ AXI DMA: tensor 전송 및 결과 수신
                         ↓
SystemVerilog accelerator (Zynq PL)
  ├─ AXI4-Stream packet loader
  ├─ Convolution / MAC
  ├─ Bias / Requantization / ReLU
  ├─ Output streamer
  └─ Controller FSM
```

## 1.1 인터페이스 구분

| 목적 | 인터페이스 | 담당 내용 |
|---|---|---|
| 제어 및 상태 | AXI4-Lite | 연산 종류, tensor shape, 설정값, START, BUSY, DONE, ERROR |
| 대용량 입력 | AXI DMA MM2S → AXI4-Stream | Weight, Bias, Input activation, 추후 Skip tensor |
| 대용량 출력 | AXI4-Stream → AXI DMA S2MM | Output activation |
| DDR 주소 | AXI DMA 및 펌웨어 | 가속기 register map에는 DDR 주소를 두지 않음 |

---

# 2. v1.0 확정 사항 요약

| 항목 | 확정안 |
|---|---|
| 실행 단위 | 한 번의 START = 한 개 layer operation |
| Batch | `N=1` |
| Activation layout | `NHWC` |
| Weight layout | `HWIO` |
| Input / Weight | signed INT8 |
| Bias / Accumulator | signed INT32 |
| Output | signed INT8 |
| AXI4-Lite data width | 32-bit |
| Accelerator AXI4-Stream width | 32-bit |
| AXI DMA stream width | MM2S 32-bit, S2MM 32-bit |
| 입력 packet 순서 | Weight → Bias → Input |
| START | W1P, 1-cycle pulse, auto-clear |
| BUSY | Read Only |
| DONE / ERROR | Sticky + W1C |
| 완료 확인 | Accelerator DONE과 S2MM DMA 완료를 모두 확인 |
| Requantization | 16-bit multiplier + 16-bit shift, 부호 대칭 반올림 |
| Accumulator overflow | INT32 saturating arithmetic, operation 계속 진행 |
| BUSY 중 config write | Write 무시, BRESP=OKAY, ERROR 기록 |

---

# 3. 공통 설계 원칙

1. 한 번의 START는 한 개의 layer operation만 실행한다.
2. v1.0은 polling 방식으로 완료를 확인한다.
3. 설정 register는 원칙적으로 `BUSY=0`일 때만 변경한다.
4. Tensor 데이터는 AXI4-Stream packet으로 전달한다.
5. 각 packet의 마지막 beat에서 `TLAST=1`이다.
6. Python exporter, 펌웨어, RTL은 같은 layout, packing, rounding, saturation 규칙을 사용한다.
7. BatchNorm은 Python에서 Convolution에 folding한다.
8. FPGA에는 folded weight와 folded bias만 전달한다.
9. Padding 값은 DDR에 저장하지 않고 RTL에서 논리적 0으로 생성한다.
10. v1.0은 단일 batch 추론만 지원한다.
11. Interface 위반과 연산 수치 경고는 sticky ERROR로 기록한다.
12. 치명적 오류와 비치명적 오류의 동작을 구분한다.

---

# 4. Tensor Layout 및 데이터 형식

## 4.1 데이터 형식

| 데이터 | 형식 | 비고 |
|---|---:|---|
| Input activation | signed INT8 | 2's complement |
| Weight | signed INT8 | BatchNorm-folded weight |
| Bias | signed INT32 | 출력 채널당 1개 |
| MAC product | signed INT16 | RTL 내부 |
| Accumulator | signed INT32 | 매 누산 단계에서 saturation 적용 |
| Requantization intermediate | signed 49-bit 이상 | Accumulator × unsigned 16-bit M |
| Output activation | signed INT8 | Requantization, 선택적 ReLU, saturation 후 |
| Skip tensor | signed INT8 | v1.2 이후 residual operation에서 사용 |

## 4.2 Activation layout

```text
NHWC = [Batch][Height][Width][Channel]
```

v1.0에서는 `N=1`이므로 실제 순서는 다음과 같다.

```text
activation[h][w][c]
```

### 1차원 인덱스

```text
index = ((h × WIDTH) + w) × CHANNELS + c
```

### 전송 순서

```text
for h = 0 .. H-1
  for w = 0 .. W-1
    for c = 0 .. C-1
      send activation[h][w][c]
```

- Output activation도 NHWC를 사용한다.
- Identity shortcut의 Skip tensor도 NHWC를 사용한다.

## 4.3 Weight layout

```text
HWIO = [Kernel Height][Kernel Width][Input Channel][Output Channel]
```

### 1차원 인덱스

```text
index = (((kh × KERNEL_W) + kw) × IN_CHANNELS + ic)
        × OUT_CHANNELS + oc
```

### 전송 순서

```text
for kh = 0 .. KH-1
  for kw = 0 .. KW-1
    for ic = 0 .. IC-1
      for oc = 0 .. OC-1
        send weight[kh][kw][ic][oc]
```

### 선택 이유

- NHWC activation의 채널 순서와 결합하기 쉽다.
- 향후 여러 output channel을 MAC lane으로 병렬 처리할 때 연속 weight를 읽기 쉽다.

> MAC array 구조가 바뀌어 weight 재배열이 필요하면 v1.x 문서에서 명시적으로 변경한다.

## 4.4 Bias layout

```text
bias[oc]
```

- 출력 채널당 signed INT32 하나
- 순서: `oc = 0 .. OUT_CHANNELS-1`

## 4.5 Output shape

```text
OUT_H = floor((IN_H + 2 × PADDING - KERNEL_H) / STRIDE) + 1
OUT_W = floor((IN_W + 2 × PADDING - KERNEL_W) / STRIDE) + 1
```

다음 조건이 성립하지 않으면 `ERR_INVALID_CONFIG`이다.

```text
IN_H > 0
IN_W > 0
IN_CHANNELS > 0
OUT_CHANNELS > 0
KERNEL_SIZE > 0
STRIDE ∈ {1, 2}
IN_H + 2×PADDING >= KERNEL_SIZE
IN_W + 2×PADDING >= KERNEL_SIZE
```

---

# 5. Fixed-point MAC, Overflow, Requantization

## 5.1 MAC 연산

각 output element의 기본 연산은 다음과 같다.

```text
acc = 0
for kh, kw, ic:
    acc = SAT_INT32(acc + input × weight)
acc = SAT_INT32(acc + bias[oc])
```

- `input × weight`는 signed INT8 × signed INT8이다.
- 곱셈 결과는 signed INT16으로 표현한다.
- 누산과 bias addition은 signed INT32 saturating arithmetic을 사용한다.

## 5.2 INT32 Saturation

```text
INT32_MAX =  2,147,483,647
INT32_MIN = -2,147,483,648
```

매 덧셈 단계에서 수학적 결과를 33-bit 이상으로 먼저 계산한다.

```text
if wide_sum > INT32_MAX:
    acc = INT32_MAX
    acc_overflow_seen = 1
else if wide_sum < INT32_MIN:
    acc = INT32_MIN
    acc_overflow_seen = 1
else:
    acc = wide_sum
```

- Overflow가 발생해도 operation은 중단하지 않는다.
- 이후 누산은 saturation된 INT32 값을 기준으로 계속 수행한다.
- 한 번이라도 overflow가 발생하면 `STATUS.ERROR=1`과 `ERROR_CODE=ERR_ACC_OVERFLOW`를 기록한다.
- 정상 output 전송까지 끝나면 `DONE=1`도 함께 설정될 수 있다.
- Python golden model도 동일한 per-step saturation을 구현해야 한다.

## 5.3 OUTPUT_SCALE register

`OUTPUT_SCALE (0x20)`은 다음과 같이 사용한다.

| Bit | 이름 | 형식 | 범위 |
|---:|---|---|---|
| `[15:0]` | `MULTIPLIER_M` | unsigned 16-bit | 0 .. 65535 |
| `[31:16]` | `SHIFT_N` | unsigned 16-bit | v1.0에서 0 .. 31 |

다음은 invalid configuration이다.

```text
SHIFT_N > 31
```

## 5.4 Requantization 수식

먼저 signed Accumulator와 unsigned M을 충분히 넓은 signed intermediate로 곱한다.

```text
P = Accumulator × M
```

RTL은 signed/unsigned 자동 변환에 의존하지 않고 다음 원칙을 지킨다.

- Accumulator는 signed로 명시한다.
- M은 0을 붙여 양수 signed 값으로 확장한다.
- P는 signed 49-bit 이상으로 계산한다.

### N = 0

```text
Q = P
```

### N > 0

음수와 양수에 동일한 절댓값 반올림 규칙을 적용한다.

```text
if P >= 0:
    Q = (P + 2^(N-1)) >>> N
else:
    Q = -(((-P) + 2^(N-1)) >>> N)
```

- `>>>`는 arithmetic right shift이다.
- 반올림 방식은 **round to nearest, ties away from zero**이다.
- 이 부호 대칭 규칙은 음수 결과가 필요한 ReLU 비활성 레이어에서도 편향을 줄인다.
- Python model은 위 정수 수식을 그대로 구현한다.

## 5.5 ReLU 및 INT8 saturation

```text
if RELU_ENABLE == 1:
    Q = max(Q, 0)

Output = clamp(Q, -128, 127)
```

ReLU가 활성화된 경우 실제 출력 범위는 `0 .. 127`이다.

---

# 6. AXI4-Stream Data Packing

## 6.1 Data width

```text
ACCELERATOR_AXIS_DATA_WIDTH = 32 bits
AXI_DMA_MM2S_STREAM_WIDTH   = 32 bits
AXI_DMA_S2MM_STREAM_WIDTH   = 32 bits
```

- 가속기와 DMA의 stream 폭을 동일하게 설정한다.
- v1.0에서는 가속기 앞뒤에 AXI4-Stream Data Width Converter를 두지 않는다.
- AXI DMA의 DDR memory-mapped 쪽 data width는 Vivado 시스템 구성에 따라 다를 수 있으며 본 인터페이스 규격의 직접 대상이 아니다.

## 6.2 DMA 정렬 규칙

v1.0 권장 설정은 DRE 비활성화이다.

- MM2S source buffer address: 4-byte aligned
- S2MM destination buffer address: 4-byte aligned
- v1.0의 모든 packet byte 수: 4의 배수

DRE를 활성화하거나 비정렬 전송을 지원할 경우 interface version을 갱신하고 별도로 검증한다.

## 6.3 INT8 packing

한 beat에 INT8 element 네 개를 packing한다.

| TDATA 비트 | 데이터 |
|---|---|
| `[7:0]` | element 0 |
| `[15:8]` | element 1 |
| `[23:16]` | element 2 |
| `[31:24]` | element 3 |

- 각 element는 signed INT8 2's complement이다.
- 낮은 주소의 byte를 낮은 TDATA bit에 배치한다.
- v1.0 packet은 모두 4-byte 배수이므로 모든 beat에서 `TKEEP=4'b1111`이다.
- 추후 4-byte 배수가 아닌 packet을 허용하면 마지막 beat의 유효 byte만 `TKEEP=1`로 설정한다.

## 6.4 INT32 bias packing

```text
TDATA[31:0] = bias[oc]
TKEEP       = 4'b1111
```

Bias 하나당 한 beat를 사용한다.

## 6.5 Handshake 및 packet 규칙

전송은 다음 순간에만 성립한다.

```text
transfer = TVALID && TREADY
```

- `TVALID=1 && TREADY=0`인 동안 송신자는 `TDATA`, `TKEEP`, `TLAST`를 유지한다.
- 각 tensor는 별도 AXI DMA transfer 및 별도 AXI4-Stream packet이다.
- packet의 마지막 실제 transfer beat에서 `TLAST=1`이다.
- packet 중간 beat에서는 `TLAST=0`이다.
- DMA transfer length와 가속기의 기대 byte 수가 같아야 한다.

---

# 7. Input / Output Packet 순서

## 7.1 OP_CONV

START가 정상 접수된 뒤 가속기는 다음 packet을 기대한다.

```text
1. WEIGHT packet
2. BIAS packet
3. INPUT ACTIVATION packet
4. OUTPUT ACTIVATION packet 송신
```

각 입력 packet은 ARM firmware가 AXI DMA MM2S transfer를 별도로 시작한다.

## 7.2 Residual 확장 예정

BasicBlock 또는 residual operation의 packet 규칙은 v1.2에서 최종 확정한다.

잠정 순서는 다음과 같다.

```text
WEIGHT → BIAS → INPUT → SKIP → OUTPUT
```

## 7.3 Packet byte 수

```text
weight_bytes = KH × KW × IC × OC
bias_bytes   = OC × 4
input_bytes  = IN_H × IN_W × IC
skip_bytes   = OUT_H × OUT_W × OC
output_bytes = OUT_H × OUT_W × OC
```

- Firmware는 계산값과 register에 기록할 byte 수를 일치시킨다.
- RTL은 실제 handshake된 byte 수와 register 값을 비교한다.

---

# 8. AXI4-Lite Register Map

## 8.1 공통 규칙

- AXI4-Lite data width: 32-bit
- 모든 register offset은 4-byte aligned
- `RO`: Read Only
- `RW`: Read/Write
- `W1P`: Write 1 Pulse
- `W1C`: Write 1 to Clear
- Reserved bit에는 0을 쓴다.
- AXI read는 BUSY 여부와 관계없이 허용한다.

## 8.2 Register 주소표

| Offset | Register | 접근 | 설명 |
|---:|---|---|---|
| `0x00` | CONTROL | RW/W1P | START, ABORT |
| `0x04` | STATUS | RO/W1C | IDLE, BUSY, DONE, ERROR |
| `0x08` | OPERATION | RW | 실행 연산 종류 |
| `0x0C` | INPUT_HEIGHT | RW | 입력 높이 |
| `0x10` | INPUT_WIDTH | RW | 입력 너비 |
| `0x14` | IN_CHANNELS | RW | 입력 채널 수 |
| `0x18` | OUT_CHANNELS | RW | 출력 채널 수 |
| `0x1C` | CONV_CONFIG | RW | Kernel, stride, padding, ReLU |
| `0x20` | OUTPUT_SCALE | RW | `[31:16]=N`, `[15:0]=M` |
| `0x24` | INPUT_BYTES | RW | 예상 input packet byte 수 |
| `0x28` | WEIGHT_BYTES | RW | 예상 weight packet byte 수 |
| `0x2C` | BIAS_BYTES | RW | 예상 bias packet byte 수 |
| `0x30` | SKIP_BYTES | RW | 예상 skip packet byte 수, 미사용 시 0 |
| `0x34` | OUTPUT_BYTES | RW | 예상 output packet byte 수 |
| `0x38` | CYCLE_COUNT | RO | 최근 operation cycle 수 |
| `0x3C` | ERROR_CODE | RO | 현재 또는 최근 오류 코드 |
| `0x40` | VERSION | RO | Interface version |
| `0x44` | DEBUG_STATE | RO | 디버깅용 현재 Controller FSM 상태 |

## 8.3 CONTROL — `0x00`

| Bit | 이름 | 접근 | 동작 |
|---:|---|---|---|
| 0 | START | W1P | 1 write 시 실행 요청 pulse 발생 |
| 1 | ABORT | W1P | 1 write 시 현재 operation 중단 요청 |
| 31:2 | RESERVED | - | 0 |

### START

- `BUSY=0`이고 config가 유효할 때만 새 operation을 시작한다.
- accepted START는 내부적으로 1-cycle pulse이다.
- `BUSY=1` 중 START write는 무시하며 현재 operation은 계속한다.
- 이 경우 `ERR_START_WHILE_BUSY`를 기록한다.

### ABORT

- `BUSY=1` 중에도 허용한다.
- AXI DMA transfer는 펌웨어가 별도로 정지 또는 reset한다.
- `BUSY=0`(IDLE)일 때 ABORT write는 아무 동작도 하지 않는다 (no-op).

### START와 ABORT 동시 write

- 한 번의 AXI4-Lite write에서 START와 ABORT 비트가 모두 1이면 ABORT를 우선 처리한다.
- 이 경우 START는 무시되며 `ERR_ABORTED`를 기록한다.

## 8.4 STATUS — `0x04`

| Bit | 이름 | 접근 | 동작 |
|---:|---|---|---|
| 0 | IDLE | RO | 새 START를 받을 수 있으면 1 |
| 1 | BUSY | RO | packet 수신, 연산 또는 output 송신 중이면 1 |
| 2 | DONE | RO/W1C | output stream 전달 완료 시 1 |
| 3 | ERROR | RO/W1C | 오류 또는 수치 경고가 발생하면 1 |
| 31:4 | RESERVED | - | 0 |

- DONE과 ERROR는 sticky flag이다.
- 해당 bit 위치에 1을 write하면 clear한다.
- 0을 write한 bit에는 영향이 없다.
- BUSY는 펌웨어가 변경할 수 없다.
- 비치명적 오류가 발생한 operation은 `DONE=1`과 `ERROR=1`이 동시에 될 수 있다.

## 8.5 OPERATION — `0x08`

| 값 | Operation | v1.0 지원 |
|---:|---|---|
| 0 | `OP_CONV` | 필수 |
| 1 | `OP_POOL` | 예약 |
| 2 | `OP_RESIDUAL_ADD` | 예약 |
| 3 | `OP_GLOBAL_AVG_POOL` | 예약 |
| 4 | `OP_FC` | 예약 |
| 기타 | Illegal | 오류 |

## 8.6 CONV_CONFIG — `0x1C`

| Bit | 이름 | 설명 |
|---:|---|---|
| 7:0 | KERNEL_SIZE | v1.0 기본 3 |
| 15:8 | STRIDE | 1 또는 2 |
| 23:16 | PADDING | 일반적으로 0 또는 1 |
| 24 | RELU_ENABLE | 1이면 requantization 후 ReLU |
| 31:25 | RESERVED | 0 |

## 8.7 VERSION — `0x40`

```text
[31:16] Major
[15:0]  Minor
```

v1.1 값:

```text
VERSION = 0x0001_0001
```

## 8.8 DEBUG_STATE — `0x44`

| Bit | 이름 | 형식 | 설명 |
|---:|---|---|---|
| `[3:0]` | `FSM_STATE` | RO | 현재 Controller FSM 상태 (§12 참조) |
| `[31:4]` | RESERVED | - | 0 |

`FSM_STATE` 값:

| 값 | 상태 |
|---:|---|
| 0 | RESET |
| 1 | IDLE |
| 2 | LOAD_WEIGHT |
| 3 | LOAD_BIAS |
| 4 | LOAD_INPUT |
| 5 | COMPUTE |
| 6 | SEND_OUTPUT |
| 7 | COMPLETE |
| 8 | LOAD_SKIP (v1.2 이후 Residual 확장 예약) |
| 기타 | RESERVED |

- 이 register는 연산 결과나 protocol 동작에 영향을 주지 않는다.
- 목적은 오직 디버깅이다: polling timeout이나 hang 발생 시 firmware가 어느 단계에서 멈췄는지 즉시 식별할 수 있게 한다.
- BUSY 여부와 무관하게 항상 read 가능하다.

---

# 9. AXI4-Lite Write 응답 및 BUSY 중 Write 정책

## 9.1 BRESP 정책

가속기 IP aperture 내부의 AXI4-Lite write는 다음 정책을 사용한다.

```text
BRESP = OKAY
```

- BUSY 중 금지된 config write도 AXI transaction 자체는 정상 종료한다.
- 오류는 AXI exception 대신 STATUS.ERROR와 ERROR_CODE로 보고한다.
- IP aperture 밖 주소의 decode 동작은 AXI interconnect 설정에 따른다.

## 9.2 BUSY 중 허용되는 write

| 대상 | 처리 |
|---|---|
| CONTROL.ABORT | 허용 |
| STATUS.DONE W1C | 허용 |
| STATUS.ERROR W1C | 허용 |
| CONTROL.START | 무시, `ERR_START_WHILE_BUSY` 기록 |
| OPERATION / shape / CONV_CONFIG | 무시, `ERR_CONFIG_WRITE_BUSY` 기록 |
| OUTPUT_SCALE / byte count | 무시, `ERR_CONFIG_WRITE_BUSY` 기록 |
| RO register write | 무시 |
| 정의되지 않은 IP 내부 offset | 무시, `ERR_INVALID_ADDRESS` 기록 |

- 금지된 write로 현재 operation을 중단하지 않는다.
- 정상 operation 완료 시 DONE이 설정될 수 있다.

## 9.3 BUSY=0에서 정의되지 않은 offset

- Write는 무시하고 `ERR_INVALID_ADDRESS`를 기록한다.
- Read는 `0x0000_0000`을 반환한다.
- AXI 응답은 OKAY이다.

---

# 10. Error Model

## 10.1 Error code

| 값 | 이름 | 분류 | 발생 조건 |
|---:|---|---|---|
| 0 | `ERR_NONE` | - | 오류 없음 |
| 1 | `ERR_START_WHILE_BUSY` | 비치명적 | BUSY 중 START write |
| 2 | `ERR_INVALID_OPERATION` | 치명적 | 지원하지 않는 OPERATION으로 START |
| 3 | `ERR_INVALID_CONFIG` | 치명적 | shape, kernel, stride, shift 등의 설정 오류 |
| 4 | `ERR_PACKET_LENGTH` | 치명적 | 실제 packet byte 수 불일치 |
| 5 | `ERR_TLAST_POSITION` | 치명적 | TLAST 위치 불일치 |
| 6 | `ERR_ACC_OVERFLOW` | 비치명적 | INT32 accumulator saturation 발생 |
| 7 | `ERR_ABORTED` | 치명적 | ABORT 요청 |
| 8 | `ERR_CONFIG_WRITE_BUSY` | 비치명적 | BUSY 중 config write |
| 9 | `ERR_INTERNAL` | 치명적 | Illegal FSM state 등 내부 오류 |
| 10 | `ERR_INVALID_ADDRESS` | 비치명적 | IP 내부 미정의 register offset 접근 |

## 10.2 비치명적 오류

다음 오류는 현재 operation을 계속한다.

```text
ERR_START_WHILE_BUSY
ERR_ACC_OVERFLOW
ERR_CONFIG_WRITE_BUSY
ERR_INVALID_ADDRESS
```

- ERROR를 sticky 1로 설정한다.
- 정상 output을 끝까지 전송하면 DONE도 1로 설정한다.

## 10.3 치명적 오류

치명적 오류는 현재 operation을 실패 처리한다.

```text
ERR_INVALID_OPERATION
ERR_INVALID_CONFIG
ERR_PACKET_LENGTH
ERR_TLAST_POSITION
ERR_ABORTED
ERR_INTERNAL
```

- 새로운 input 수신과 output 생성 작업을 중단한다.
- 내부 FSM과 counter를 정리한다.
- BUSY를 0으로 내린다.
- DONE은 설정하지 않는다.
- DMA가 진행 중이면 펌웨어가 DMA를 reset한다.

## 10.4 ERROR_CODE 우선순위

- 기본적으로 operation 또는 IDLE 구간에서 처음 발생한 오류를 보존한다.
- 기존 code와 새 오류가 모두 비치명적이면 최초 code를 유지하고, 이후 발생하는 비치명적 오류는 code에 반영하지 않는다 (단, `STATUS.ERROR` sticky bit는 계속 1이다).
- 기존 code가 비치명적이고 이후 치명적 오류가 발생하면 치명적 오류 code로 덮어쓴다.
- 기존 code가 치명적이면 이후 오류로 덮어쓰지 않는다.
- 펌웨어가 ERROR를 W1C로 clear하면 ERROR_CODE도 `ERR_NONE`으로 clear한다.

---

# 11. Execution Protocol

## 11.1 정상 실행 순서

```text
[1]  ARM: STATUS.BUSY == 0 확인
[2]  ARM: STATUS.DONE 및 STATUS.ERROR를 W1C로 clear
[3]  ARM: OPERATION, shape, CONV_CONFIG, OUTPUT_SCALE 설정
[4]  ARM: INPUT/WEIGHT/BIAS/SKIP/OUTPUT_BYTES 설정
[5]  ARM: AXI DMA S2MM destination 및 OUTPUT_BYTES 설정
[6]  ARM: AXI DMA S2MM 시작 — output 수신을 먼저 준비
[7]  ARM: CONTROL.START에 1 write
[8]  RTL: config 검증 후 START accept, BUSY=1
[9]  ARM: MM2S로 WEIGHT packet 전송
[10] ARM: MM2S 완료 확인
[11] ARM: MM2S로 BIAS packet 전송
[12] ARM: MM2S 완료 확인
[13] ARM: MM2S로 INPUT packet 전송
[14] ARM: MM2S 완료 확인
[15] RTL: Convolution + Bias + Requantization + 선택적 ReLU
[16] RTL: OUTPUT packet 송신
[17] RTL: 마지막 output beat handshake 후 BUSY=0, DONE=1
[18] ARM: Accelerator DONE 확인
[19] ARM: AXI DMA S2MM 완료 확인
[20] ARM: 두 완료 조건을 모두 확인한 뒤 DDR output 읽기
[21] ARM: STATUS.ERROR 및 ERROR_CODE 확인·로그
[22] ARM: Python fixed-point reference와 비교
[23] ARM: DONE과 ERROR를 W1C로 clear
```

## 11.2 START accept 조건

START는 다음 조건을 모두 만족할 때만 accept한다.

```text
BUSY == 0
OPERATION is supported
shape/config is valid
registered packet byte counts match calculated values
SHIFT_N <= 31
```

조건이 맞지 않으면 BUSY를 올리지 않고 적절한 치명적 ERROR를 기록한다.

## 11.3 DONE 발생 기준

DONE은 다음 조건이 모두 만족된 후 정확히 한 번 설정한다.

1. 모든 필수 input packet을 정상 수신했다.
2. 연산이 완료됐다.
3. 마지막 output beat가 `TVALID && TREADY && TLAST`로 전달됐다.

> Accelerator DONE은 AXI4-Stream beat가 DMA에 수락됐다는 뜻이다. ARM이 DDR 결과를 읽기 전에는 S2MM DMA 완료도 반드시 확인한다.

## 11.4 Polling 권장 코드

ABORT는 즉시 완료되지 않을 수 있다. Timeout 발생 시 `accel_abort()`만 호출하고 바로 반환하면, 아직 내부 정리 중인 가속기와 다음 operation 설정이 경쟁(race)할 수 있다. 따라서 ABORT 이후 `BUSY==0`이 되는 것을 별도 timeout으로 재확인한다.

```c
#define ACCEL_ABORT_CONFIRM_TIMEOUT 1000U

int accel_wait_done(uint32_t timeout)
{
    while (timeout-- > 0U) {
        uint32_t status = accel_read(STATUS_OFFSET);

        if ((status & STATUS_BUSY_MASK) == 0U) {
            uint32_t error_code = accel_read(ERROR_CODE_OFFSET);

            if ((status & STATUS_DONE_MASK) != 0U) {
                // 정상 완료 또는 비치명적 경고를 동반한 완료
                return (error_code == ERR_NONE) ? 0 : ACCEL_DONE_WITH_WARNING;
            }

            // DONE 없이 BUSY가 내려갔으면 치명적 실패
            return ACCEL_FATAL_ERROR;
        }
    }

    accel_abort();

    // ABORT가 실제로 BUSY를 내릴 때까지 별도로 확인한다.
    uint32_t confirm = ACCEL_ABORT_CONFIRM_TIMEOUT;
    while (confirm-- > 0U) {
        uint32_t status = accel_read(STATUS_OFFSET);
        if ((status & STATUS_BUSY_MASK) == 0U) {
            return ACCEL_TIMEOUT;
        }
    }

    // ABORT 이후에도 BUSY가 내려가지 않으면 가속기 상태를 신뢰할 수 없다.
    return ACCEL_ABORT_TIMEOUT;
}
```

펌웨어는 이 함수 이후 S2MM DMA 완료를 별도로 확인한다.

`ACCEL_ABORT_TIMEOUT`은 하드웨어 `ERROR_CODE`가 아니라 firmware 반환 코드이며, ABORT 이후에도 가속기가 응답하지 않는 비정상 상태(FSM lockup 등)를 상위 소프트웨어에 알리기 위한 것이다.

## 11.5 ABORT

- BUSY 중 ABORT write를 받으면 내부 작업을 정리한다.
- `BUSY=0`, `DONE=0`, `ERROR=1`, `ERROR_CODE=ERR_ABORTED`로 만든다.
- ABORT 접수부터 `BUSY=0`까지는 내부 정리에 필요한 유한한 cycle이 걸릴 수 있다. 펌웨어는 ABORT write 직후 `BUSY=0`을 즉시 가정하지 않고 §11.4의 confirm loop로 재확인한다.
- 펌웨어는 MM2S와 S2MM DMA를 별도로 halt/reset한다.
- DMA와 가속기 모두 정리된 뒤 sticky flag를 clear하고 재시작한다.

---

# 12. Controller FSM 권장 상태

```text
RESET
  ↓
IDLE
  ↓ accepted START
LOAD_WEIGHT
  ↓ expected TLAST
LOAD_BIAS
  ↓ expected TLAST
LOAD_INPUT
  ↓ expected TLAST
COMPUTE
  ↓
SEND_OUTPUT
  ↓ final output handshake
COMPLETE
  ↓
IDLE
```

Residual 확장 시 다음 상태를 추가한다.

```text
LOAD_INPUT → LOAD_SKIP → COMPUTE / RESIDUAL_ADD
```

> 각 상태의 인코딩 값은 §8.8 `DEBUG_STATE`에서 정의한다. 이 register는 디버깅 전용이며 동작에는 영향을 주지 않는다.

## 12.1 상태별 공통 검사

- Reset
- ABORT
- Packet byte count
- TLAST 위치
- Illegal FSM state
- Accumulator overflow
- Output backpressure

## 12.2 Cycle counter

- Accepted START에서 0으로 초기화한다.
- BUSY 기간 동안 매 cycle 증가한다.
- BUSY가 0이 되는 순간 값을 고정한다.
- 비치명적 warning을 동반한 완료에서도 값을 유지한다.

---

# 13. 1단계 단일 Convolution 기준 예시

## 13.1 설정

```text
N              = 1
IN_H           = 32
IN_W           = 32
IN_CHANNELS    = 3
OUT_CHANNELS   = 16
KERNEL_SIZE    = 3
STRIDE         = 1
PADDING        = 1
RELU_ENABLE    = 1
```

## 13.2 Tensor shape

```text
Input  : [1][32][32][3]   NHWC
Weight : [3][3][3][16]    HWIO
Bias   : [16]              INT32
Output : [1][32][32][16]  NHWC
```

## 13.3 Packet 크기

| Packet | 계산 | 크기 |
|---|---:|---:|
| Weight | `3×3×3×16×1 byte` | 432 bytes |
| Bias | `16×4 bytes` | 64 bytes |
| Input | `32×32×3×1 byte` | 3,072 bytes |
| Output | `32×32×16×1 byte` | 16,384 bytes |

## 13.4 32-bit Stream beat 수

| Packet | Beat 수 |
|---|---:|
| Weight | 108 |
| Bias | 16 |
| Input | 768 |
| Output | 4,096 |

모든 packet 크기가 4-byte 배수이므로 v1.0에서는 마지막 beat까지 `TKEEP=4'b1111`이다.

---

# 14. Python Exporter 및 Golden Model

Python exporter는 최소 다음 파일을 생성한다.

```text
config.json
weight.bin
bias.bin
input.bin
expected_output.bin
```

## 14.1 config.json 예시

```json
{
  "interface_version": "1.1",
  "operation": "OP_CONV",
  "activation_layout": "NHWC",
  "weight_layout": "HWIO",
  "input_dtype": "int8",
  "weight_dtype": "int8",
  "bias_dtype": "int32",
  "output_dtype": "int8",
  "input_height": 32,
  "input_width": 32,
  "in_channels": 3,
  "out_channels": 16,
  "kernel_size": 3,
  "stride": 1,
  "padding": 1,
  "relu_enable": true,
  "multiplier_m": 1,
  "shift_n": 0,
  "input_bytes": 3072,
  "weight_bytes": 432,
  "bias_bytes": 64,
  "skip_bytes": 0,
  "output_bytes": 16384
}
```

## 14.2 Binary 규칙

- `input.bin`: NHWC signed INT8
- `weight.bin`: HWIO signed INT8
- `bias.bin`: OC 순서 signed INT32 little-endian
- `expected_output.bin`: NHWC signed INT8

## 14.3 Golden model 필수 동작

Python model은 다음을 RTL과 동일하게 구현한다.

1. signed INT8 곱셈
2. 매 MAC 덧셈의 signed INT32 saturation
3. signed INT32 bias saturation
4. M/N requantization
5. 부호 대칭 round-to-nearest, ties-away-from-zero
6. 선택적 ReLU
7. INT8 saturation
8. NHWC/HWIO 순서

Binary 저장 후 다시 읽어 tensor가 동일한지 self-check한다.

---

# 15. 검증 체크리스트

## 15.1 Tensor 및 연산

- [ ] Activation layout이 Python/RTL 모두 NHWC이다.
- [ ] Weight layout이 Python/RTL 모두 HWIO이다.
- [ ] signed INT8 해석이 동일하다.
- [ ] Bias signed INT32 little-endian 해석이 동일하다.
- [ ] Padding 좌표와 값이 동일하다.
- [ ] Per-step INT32 saturation이 동일하다.
- [ ] M/N requantization이 동일하다.
- [ ] 음수 반올림 결과가 동일하다.
- [ ] ReLU 및 INT8 saturation 순서가 동일하다.

## 15.2 AXI4-Lite

- [ ] Register write/read
- [ ] Reset value
- [ ] START 1-cycle pulse
- [ ] BUSY 중 START 무시 및 ERROR 기록
- [ ] DONE W1C
- [ ] ERROR W1C 및 ERROR_CODE clear
- [ ] BUSY 중 config write 무시
- [ ] BUSY 중 config write의 BRESP=OKAY
- [ ] 정의되지 않은 IP 내부 offset 접근
- [ ] AXI address/data channel 독립 handshake
- [ ] Read/write backpressure
- [ ] START+ABORT 동시 write 시 ABORT 우선 처리
- [ ] DEBUG_STATE가 실제 FSM 상태와 일치

## 15.3 AXI4-Stream

- [ ] Continuous transfer
- [ ] Random TREADY
- [ ] Random source stall
- [ ] Output backpressure
- [ ] TLAST 위치
- [ ] Packet byte 수
- [ ] TKEEP=1111 확인
- [ ] Reset 중간 삽입
- [ ] Weight → Bias → Input 순서
- [ ] TVALID stall 중 TDATA/TKEEP/TLAST 유지

## 15.4 Error 및 Controller

- [ ] Reset 이후 IDLE
- [ ] Accepted operation당 DONE 최대 1회
- [ ] Accumulator overflow 후 연산 계속
- [ ] Overflow 완료 시 DONE=1, ERROR=1 가능
- [ ] Fatal error 시 DONE=0
- [ ] Fatal error가 non-fatal ERROR_CODE를 덮어씀
- [ ] ABORT 후 IDLE 복귀
- [ ] 마지막 output handshake 이후 DONE
- [ ] Accelerator DONE 후 S2MM 완료 전 DDR를 읽지 않음
- [ ] 연속된 비치명적 오류 발생 시 최초 code 유지
- [ ] ABORT 이후 BUSY=0 confirm loop가 실제로 동작

## 15.5 Directed test

- [ ] 모든 입력 0
- [ ] Identity 형태 weight
- [ ] 최대 양수 / 최소 음수
- [ ] 양수·음수 혼합
- [ ] INT32 overflow 유도
- [ ] N=0
- [ ] N=1 및 tie rounding 양수/음수
- [ ] M=0
- [ ] M=65535
- [ ] Stride 1 / 2
- [ ] Padding 0 / 1
- [ ] 잘못된 packet length
- [ ] 잘못된 TLAST
- [ ] BUSY 중 config write

---

# 16. 역할별 구현 항목

## 16.1 황정민 — RTL

- Signed fixed-point MAC PE
- INT32 saturating accumulator
- M/N requantization 및 INT8 saturation
- ReLU
- Convolution datapath
- Tensor buffer 및 address generator
- AXI4-Stream input/output
- Packet byte counter 및 TLAST 검사
- AXI4-Lite register interface
- START/BUSY/DONE/ERROR/ERROR_CODE
- DEBUG_STATE (FSM 상태 노출용 디버그 register)
- Controller FSM
- Cycle counter
- Assertion
- Vivado synthesis 및 implementation

## 16.2 소은수 — Firmware / Verification

- PyTorch 및 fixed-point golden model
- BatchNorm folding
- NHWC/HWIO binary exporter
- Per-step saturation 및 M/N requantization 모델
- AXI DMA MM2S/S2MM 32-bit stream 설정
- 4-byte aligned DDR buffer 관리
- AXI4-Lite accelerator driver
- W1P/W1C 처리
- ABORT 이후 BUSY=0 confirm 처리
- Weight/Bias/Input DMA scheduler
- S2MM 선행 준비 및 이중 완료 확인
- cocotb 또는 SystemVerilog testbench
- RTL/FPGA 결과와 Python 결과 비교

## 16.3 공동 확인

- 최초 test vector의 모든 register 값
- Tensor element 순서
- Rounding 및 saturation 결과
- 최초 mismatch index와 중간 accumulator
- Vivado Block Design의 실제 DMA stream width
- Interface version 변경

---

# 17. 구현 시작 순서

```text
1. Python scalar requantization 함수와 RTL 수식 일치 확인
2. ReLU 및 saturation 모듈
3. Signed MAC PE + per-step overflow test
4. 한 output element용 3×3×IC convolution
5. 작은 tensor convolution engine
6. 전체 32×32×3 → 32×32×16 RTL simulation
7. AXI4-Stream packet loader/output
8. AXI4-Lite register block
9. Controller FSM 통합
10. Vivado AXI DMA + Zynq PS 통합
11. Vitis firmware 실행
12. Python reference와 FPGA 결과 비교
```

---

# 18. v1.2 이후 예정 항목

- Basic Residual Block
- Skip packet 최종 규칙
- Residual add 전후 scale 정렬
- Stride 2와 projection shortcut
- Pooling / GAP / FC packet 정의
- Weight buffer 재사용
- Interrupt register 및 protocol
- Multiple MAC lane
- 64-bit 이상 AXI4-Stream
- DMA double buffering
- DMA 전송과 연산 overlap
- Layer fusion

---

# 19. 변경 이력

## v1.1

- ABORT 이후 `BUSY=0` 확인을 위한 confirm loop를 firmware 권장 코드(§11.4)에 추가
- ERROR_CODE 우선순위 규칙(§10.4)에 비치명적-비치명적 케이스 명시
- 디버깅용 `DEBUG_STATE (0x44)` register 추가 (§8.2, §8.8)
- CONTROL의 START+ABORT 동시 write 및 IDLE 중 ABORT 규칙 명시 (§8.3)

## v1.0

- NHWC activation, HWIO weight 확정
- AXI4-Stream 및 DMA stream 32-bit 확정
- M/N OUTPUT_SCALE 형식 확정
- 음수까지 대칭적인 requantization 반올림 규칙 확정
- INT32 accumulator saturation 및 non-fatal overflow 동작 확정
- BUSY 중 config write 무시 + BRESP OKAY 정책 확정
- Fatal / non-fatal error semantics 구분
- Accelerator DONE과 S2MM DMA 완료를 모두 확인하도록 protocol 보완
- Defined IP aperture invalid address 처리 추가

---

# 20. 최종 승인 체크

- [x] Activation: NHWC
- [x] Weight: HWIO
- [x] Input/Weight INT8, Bias/Accumulator INT32, Output INT8
- [x] One START per layer operation
- [x] AXI4-Lite 32-bit
- [x] AXI4-Stream 32-bit
- [x] DMA MM2S/S2MM stream 32-bit
- [x] Weight → Bias → Input packet order
- [x] START W1P auto-clear
- [x] BUSY RO
- [x] DONE/ERROR sticky W1C
- [x] OUTPUT_SCALE: M[15:0], N[31:16]
- [x] Sign-symmetric requantization rounding
- [x] INT32 saturating accumulator
- [x] Accumulator overflow is non-fatal
- [x] BUSY config write ignored with BRESP OKAY
- [x] Accelerator DONE + S2MM DMA completion required
- [x] ABORT 후 BUSY=0 confirm loop (v1.1)
- [x] ERROR_CODE 비치명적-비치명적 우선순위 규칙 (v1.1)
- [x] DEBUG_STATE debug register (v1.1)
- [x] START+ABORT 동시 write 규칙 (v1.1)

