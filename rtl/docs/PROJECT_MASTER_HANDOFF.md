# PROJECT MASTER HANDOFF

> Zynq FPGA SoC 기반 ResNet-20 추론 가속기
> Snapshot date: 2026-08-10 (Asia/Seoul)
> Git branch: `main`
> Git HEAD/origin-main: `9099840b4628ef895e152804e646f03eec8c5d49` / same (`0 ahead, 0 behind`)
> Working tree: **DIRTY** — 협업 중인 미커밋 RTL, cocotb, agent-environment 변경이 존재한다.

이 문서는 새 개발자나 새 AI 세션이 프로젝트를 재개할 때 먼저 읽는 단일 source-of-context다.
코드와 로그를 확인한 2026-08-10 시점의 상태를 우선하며, 과거 개인 저장소 문서는 역사적 배경으로만 취급한다.

## 1. Executive Summary

| 항목 | 현재 기준 |
|---|---|
| 프로젝트 | Zynq FPGA SoC 기반 ResNet 추론 가속기 |
| 최종 목표 | Zybo Z7-20에서 CIFAR-10 ResNet-20 계열 inference를 ARM PS와 FPGA PL로 실행하고 Python fixed-point golden과 bit-accurate 검증 |
| 기능 우선순위 | 기능 정확성 및 재현성 → end-to-end 동작 → 성능/PE 최적화 |
| RTL/HW 담당 | 황정민 — SystemVerilog, controller/compute/stream, testbench, Vivado, HW handoff |
| FW/Python 담당 | 소은수 — bare-metal FW, AXI DMA, scheduler, cache/DDR, Vitis, model/quantization/export/golden |
| 공동 결정 | HW/SW interface, opcode/register, residual scale, checkpoint, projection, board/E2E 검증 |
| 보드/FPGA | Digilent Zybo Z7-20, XC7Z020 계열 (`xc7z020clg400-1`) |
| PL | 100 MHz, 단일 clock domain, active-low reset |
| 제어/데이터 | AXI4-Lite / 32-bit AXI4-Stream + AXI DMA |
| tensor | N=1, NHWC, signed INT8 activation/weight, INT32 bias/accumulator |
| 완료 기준선 | Development Stage 1 single `OP_CONV` |
| 현재 단계 | Development Stage 2, `OP_RESIDUAL_ADD` Stage 2-A 구현 중 |
| 가장 가까운 목표 | Residual 전용 verification closure → common-scale golden/FW scheduler → 첫 identity BasicBlock |

현재 working tree에는 Residual Add 핵심 RTL이 존재하지만 전용 testbench/vector와 최종 regression summary는 없다. 따라서 현재 판정은 **Stage 2-A core implementation present; verification closure pending**이다.

## 2. Status Vocabulary

- `CURRENT`: 현재 Organization 저장소의 코드/상태에서 확인.
- `VERIFIED`: 저장된 simulation 또는 명시적 실행 증거로 확인.
- `IN PROGRESS`: working tree에 구현 중이며 아직 closure 전.
- `PLANNED`: 설계 방향은 있으나 구현 전.
- `DEFERRED`: 현재 milestone 이후로 의도적으로 연기.
- `HISTORICAL`: 과거 저장소, obsolete 환경 또는 해결된 문제.
- `DECISION REQUIRED`: 공동 합의가 필요한 계약/경계.
- `UNVERIFIED`: 주장 또는 계획은 있으나 현재 저장소에서 직접 증거를 찾지 못함.

## 3. Development Stage와 Model Stage

용어를 섞지 않는다.

- **Development Stage 1**: single OP_CONV RTL, Vivado 및 보드 bring-up.
- **Development Stage 2**: residual connection과 첫 Basic Residual Block.
- **ResNet model stage1**: 32×32, 16 channels.
- **ResNet model stage2**: 16×16, 32 channels.
- **ResNet model stage3**: 8×8, 64 channels.

이 문서에서 별도 수식어 없는 “현재 Stage 2”는 Development Stage 2다.

## 4. Official Repository and Ownership

```text
GitHub: https://github.com/2026-zynq-fpga-accelerator/zynq-fpga-accelerator.git
Linux clone: /home/jmhwang/zynq-fpga-accelerator

zynq-fpga-accelerator/
├── rtl/                     # 황정민 수정 영역
└── firmware-verification/   # 소은수 영역; 황정민에게는 읽기 전용
```

`/home/jmhwang/resnet-fpga-accelerator`와 `/home/jmhwang/Zynq_FPGA_ResNet`은 `HISTORICAL`이다. 새 코드, commit, 명령의 기준으로 사용하지 않는다.

현재 root `AGENTS.md`는 황정민이 `rtl/**`만 수정하고 `firmware-verification/**` 변경 전 사용자 확인을 받도록 규정한다. `firmware-verification/verification/cocotb/Makefile`과 `bfm.py`의 미커밋 변경은 소은수/다른 협업자가 아니라 이번 황정민 RTL 세션에서 직접 만든 것이다: `Makefile`의 `RTL_DIR`이 존재하지 않는 경로(`../../rtl`)를 가리키던 사전 결함(HEAD 커밋 `8c321a7`부터 존재, 이 세션이 만든 결함 아님)을 `../../../rtl/rtl`로 고쳐 cocotb 회귀가 실제로 컴파일되게 했고, `bfm.py`에는 residual 테스트가 참조하는 `OP_RESIDUAL_ADD`/`FSM_LOAD_SKIP` 상수를 추가했다. 사용자 확인(유지 결정)을 받았으며, `STAGE2_RTL_REQUEST.md` §2(ISSUE-003)·§3(검증 요구사항)과 대조해 타당성을 확인했다.

## 5. Architecture

### Control path

```text
ARM Cortex-A9 bare-metal
  → PS M_AXI_GP0
  → interconnect/SmartConnect
  → accelerator AXI4-Lite registers
```

DMA control도 PS가 담당한다. accelerator base는 문서 기준 `0x43C00000`, AXI DMA base는 `0x40400000`이다.

### Data path

```text
DDR → AXI DMA MM2S → Accelerator S_AXIS
Accelerator M_AXIS → AXI DMA S2MM → DDR
```

AXI DMA는 현재 milestone에서 Simple mode, SG off, DRE off, polling, MM2S/S2MM 32-bit다. DDR buffers와 packet byte count는 4-byte aligned/multiple이어야 한다. S2MM을 START보다 먼저 arm한다.

### Clock/reset

- PS `FCLK_CLK0 = 100 MHz`.
- `FCLK_RESET0_N`은 active-low.
- Processor System Reset을 거쳐 accelerator `aresetn`으로 연결.
- accelerator는 단일 PL clock domain.

## 6. HW/SW Interface Source of Truth

1. Repository baseline: `firmware-verification/HW_SW_Interface_v1.1_FINAL.md`.
2. Residual extension: 외부 파일 `HW_SW_Interface_v1.2_DRAFT.md` (2026-08-04). **현재 repository에는 포함되어 있지 않다.**
3. v1.2는 v1.1을 대체하지 않고 `OP_RESIDUAL_ADD`만 확장한다.

### v1.1 invariant

- one START = one operation.
- START는 W1P/auto-clear, DONE/ERROR는 sticky W1C.
- BUSY, ERROR_CODE, CYCLE_COUNT, DEBUG_STATE 제공.
- AXIS packet 마지막 beat만 TLAST=1, full word는 TKEEP=1111.
- OP_CONV packet은 Weight → Bias → Input → Output.
- register/interface 변경은 코드보다 interface 문서와 공동 합의가 먼저다.

### v1.2 residual contract

| 항목 | 계약 |
|---|---|
| opcode | `OP_RESIDUAL_ADD = 2` |
| packet | MAIN → SKIP → OUTPUT |
| bytes | INPUT_BYTES=MAIN, SKIP_BYTES=SKIP, OUTPUT_BYTES=result |
| unused | WEIGHT_BYTES=0, BIAS_BYTES=0, OUTPUT_SCALE=0 |
| config | kernel/stride/padding=0, bit 24=Final ReLU |
| arithmetic | sign-extend INT8 → add → optional ReLU → signed INT8 clamp |
| quantization | MAIN/SKIP은 add 직전 동일 INT8 scale; RTL 내부 requantization 없음 |
| extension policy | 신규 register 및 ERROR_CODE 없음 |
| debug | MAIN error=LOAD_INPUT(4), compute=5, SKIP error=LOAD_SKIP(8) |
| debug clear | ERROR W1C 또는 다음 정상 START accept |

## 7. Development Stage 1 — Single OP_CONV

`VERIFIED` baseline 기능:

- 3×3 convolution, bias, M/N requantization, optional ReLU, INT8 clamp.
- stride 1/2, padding 0/1, signed inputs/weights/bias.
- saturating accumulation, sign-symmetric ties-away-from-zero rounding.
- TLAST/length errors, ABORT/recovery, busy-write protection, consecutive operations.
- 대표 vector: 32×32×3 → 32×32×16; Weight 432, Bias 64, Input 3,072, Output 16,384 bytes.

현재 저장 로그:

- `rtl/build/regression/smoke.log`: 64-byte smoke PASS.
- `rtl/build/regression/unit.log`: 3 unit tests PASS.
- `rtl/build/regression/directed.log`: 51 integration/error checks PASS.
- `rtl/build/regression/full_conv.log`: 16,384 output bytes, mismatch 0, 1,435,424 cycles.
- 이번 세션에서 `scripts/sim/run_regression.sh` 전체를 재실행해 `TOTAL: 10 PASS, 0 FAIL`을 직접 확인했다(vector_gen/smoke/unit/directed/full_conv 5개 stage 전부 PASS 포함).
- `rtl/TODO.md`의 committed baseline은 1,435,391 cycles로 기록되어 있어 위 1,435,424와 33 cycle 차이가 있다. 이 차이는 이번 세션 변경과 무관하다: `tb_full_conv.sv`는 이번 세션에서 전혀 수정하지 않았고(git diff 없음, `9099840` 커밋 그대로), 그 파일 자체가 이미 `OLD_EXPECTED_CYCLES=1435390`/`EXPECTED_CYCLES=1435424`를 하드코딩하고 있으며 로그의 `CYCLE COUNT SEMANTICS: old=1435390 new=1435424 delta=34 (admission active clocks)` 줄도 테스트벤치가 원래 출력하는 문구다. 즉 1,435,424는 ISSUE-003 수정이나 이번 세션의 다른 RTL 변경과 무관하게 이미 커밋되어 있던 기대값이며, `rtl/TODO.md`(1,435,391)만 그 이후 갱신되지 않은 stale 문서로 보인다. Stage-1 회귀는 이 차이와 무관하게 PASS했다.

Stage 1 board execution은 repository history의 `c71d2bb Validate stage1 OP_CONV on Zybo Z7-20`과 전달된 프로젝트 상태에서 PASS로 보고되었다. 그러나 현재 repository에서 “10회 이상”을 입증하는 원본 UART log 경로는 찾지 못했다. 따라서 16,384-byte/0-mismatch board PASS는 프로젝트의 현재 resolved baseline으로 사용하되 정확한 반복 횟수는 `UNVERIFIED`로 유지한다.

## 8. DMA Length Width — HISTORICAL / RESOLVED

과거 stale BSP는 SgLengthWidth=14, MaxTransferLen=16,383이어서 Stage 1 output 16,384-byte S2MM 요청을 driver가 제출 전에 거부했다. 현재 HW handoff는 Simple DMA, SgLengthWidth=23, MaxTransferLen=8,388,607을 기록한다. 현재 ResNet-20의 큰 3×3 64→64 weight packet은 약 36,864 bytes로 23-bit 범위 안이다.

현재 판단:

- DMA 14-bit 문제는 blocker가 아니다.
- 현재 milestone은 Simple mode를 유지한다.
- SG multi-BD는 대형 모델/성능 연구용 `DEFERRED` 항목이다.
- 석사 연구원 피드백의 핵심은 초과 데이터를 특정하고, BD 수/interrupt/SW overhead/resource trade-off를 검토하라는 것이었다. 현재 초과 데이터는 Stage 1 output 16,384 bytes로 특정되고 width 23으로 해결되었다.

## 9. 담당 석사 연구원 요구사항과 결정

### ReLU

별도 opcode 대신 datapath에 fuse한다. Conv는 MAC → bias → requantization → optional ReLU → clamp, Residual은 Add → Final ReLU → clamp다. 비교/mux 수준이며 현재 timing 최적화의 주 대상이 아니다.

### Batch Normalization

Python에서 inference 전에 Conv weight/bias에 folding한 뒤 quantize한다. 현재 ResNet-20에 dedicated BN RTL을 추가하지 않는다 (`DEFERRED`).

### Layer Normalization

현재 ResNet-20 graph에 없다. ViT/Swin 등 향후 모델에서 PS fallback, dedicated PL, LUT/PWL reciprocal sqrt 또는 Newton-Raphson을 검토한다 (`DEFERRED`).

### Processing Engine

현재 Conv는 single-MAC sequential baseline이다. 병목 후보는 synchronous BRAM read, address FSM, BRAM→MAC path, 낮은 input/weight reuse다. E2E 이후 첫 후보는 NHWC input patch를 broadcast하는 output-channel parallel PE이며 `PE_COUNT=1→2→4→8` 순서로 비교한다. Development Stage 2에서는 시작하지 않는다.

## 10. Actual ResNet-20 Graph

`firmware-verification/python/models/resnet_fp.py`의 현재 graph:

```text
Input 32×32×3
→ stem 3×3 Conv 3→16, stride1, BN, ReLU
→ model stage1: 3 × BasicBlock 16→16 identity, 32×32
→ model stage2: first block 16→32 stride2 + 1×1 projection,
                then 2 identity blocks, 16×16
→ model stage3: first block 32→64 stride2 + 1×1 projection,
                then 2 identity blocks, 8×8
→ adaptive GAP → 64
→ FC 64→10 logits
```

Softmax는 graph에 없으며 분류는 logits argmax로 가능하다.

## 11. Basic Residual Block and Stage 2 Target

```text
X ───────────────────────────────→ SKIP
└→ Conv1 + folded BN + ReLU
   → Conv2 + folded BN (ReLU OFF) → MAIN
MAIN + SKIP → Residual Add → Final ReLU → block output
```

Firmware scheduler가 OP_CONV → OP_CONV → OP_RESIDUAL_ADD 세 독립 operation을 순서화한다. 전체 block을 하나의 거대한 PL FSM으로 만들지 않는다.

첫 대상은 model stage1 identity BasicBlock:

- shape 32×32×16, activation당 16,384 bytes.
- Conv1: 3×3 16→16, stride1, padding1, ReLU ON.
- Conv2: 3×3 16→16, stride1, padding1, ReLU OFF.
- SKIP: original X를 MAIN과 같은 scale로 준비.
- Residual: Final ReLU ON, output 32×32×16.
- 제외: projection, stride2 shortcut, GAP, FC, PE optimization.

권장 DDR buffers는 A=X/SKIP, B=Conv1 output, C=Conv2/MAIN, D=final output으로 각 16,384 bytes, 총 65,536 bytes다.

## 12. Current OP_RESIDUAL_ADD Implementation

| Feature | State | Evidence | Verification |
|---|---|---|---|
| opcode/packet constants | VERIFIED | `accel_pkg.sv` diff + `rtl/tb/tb_op_residual_add_directed.sv` | 10/10 directed checks PASS (Vivado xsim, this session) |
| MAIN→SKIP controller sequence | VERIFIED | `controller_fsm.sv` + `tb_op_residual_add_directed.sv` | normal-flow + 4개 error-injection 케이스 PASS |
| residual validation/snapshot | IN PROGRESS | `controller_fsm.sv` | accept 경로는 directed test로 검증됨; reject/boundary 경로(CONV_CONFIG 비트 위반, byte 불일치, in≠out channels 등)는 아직 미검증 |
| skip packet routing | VERIFIED | `axis_packet_loader.sv` + `tb_op_residual_add_directed.sv` | SKIP TLAST/length error 케이스 PASS, DEBUG_STATE=8 확인 |
| independent skip buffer | VERIFIED | `tensor_buffers.sv` + `tb_op_residual_add_directed.sv` | SKIP 데이터가 독립적으로 저장/합산되는 것을 directed test로 확인 |
| four INT8 lanes/word add | VERIFIED | new `residual_add_engine.sv` + `tb_op_residual_add_directed.sv` | 8-lane 양수/음수 add directed test PASS |
| saturation/ReLU | VERIFIED | `add_lane()` + `tb_op_residual_add_directed.sv` | overflow/underflow clamp + Final ReLU on/off directed test PASS; §13에 명시된 정확한 경계값 벡터 전부는 아직 미실행 |
| full-word output write | VERIFIED | buffers/top diff + `tb_op_residual_add_directed.sv` | 캡처한 M_AXIS 출력이 기대값과 word 단위로 일치 |
| packet-error DEBUG latch | IN PROGRESS | controller diff + `tb_op_residual_add_directed.sv` | MAIN=4/SKIP=8 latch는 확인됨; W1C 단독 clear와 W1C 없는 다음 accepted START clear는 각각 독립적으로 미검증 |
| abort wiring | IN PROGRESS | controller/top/engine | residual 전용 ABORT/recovery 테스트 여전히 부재 |
| external AXI ports | CURRENT unchanged | `resnet_accel_top.sv` port list | elaborated with OP_CONV tests |
| existing Conv engine | CURRENT unchanged | no `conv_engine.sv` diff | `run_regression.sh` 재실행 결과 TOTAL: 10 PASS/0 FAIL (this session) |

`firmware-verification/verification/cocotb/Makefile`와 `bfm.py`에도 미커밋 Residual compile/constants 연결이 있으나 test body는 아직 OP_CONV 중심(`test_accel_conv.py`)이다. 이 변경은 FW 담당 영역의 기존 협업 변경이 아니라 이번 황정민 RTL 세션에서 직접 만든 것이다(§4 참조).

## 13. Residual Verification Closure

Stage 2-A 완료 전 아래를 실제 marker와 결과로 닫는다.

- [ ] Arithmetic: 127+1, 127+127, -128+-1, -128+-128, 100+-100. — `tb_op_residual_add_directed.sv`가 다른 경계값(100+100, -100+-100, 127+0, -128+0 등)으로 동일 saturation 경로를 검증했으나, 여기 명시된 정확한 벡터 자체는 아직 미실행.
- [x] ReLU OFF signed result, ReLU ON negative→0, mixed four-lane word. — `tb_op_residual_add_directed.sv`의 `add_and_saturate_relu_off`/`final_relu_on` PASS (this session).
- [ ] MAIN normal/early/late/missing TLAST/length mismatch, error DEBUG=4. — normal/early-TLAST/length(bad TKEEP) 케이스만 PASS; late/missing TLAST 변형은 아직 없음.
- [ ] SKIP normal/early/late/missing TLAST/length mismatch, error DEBUG=8. — normal/missing-TLAST/length(bad TKEEP) 케이스만 PASS; early/late TLAST 변형은 아직 없음.
- [ ] DEBUG latch: ERROR W1C 및 다음 accepted START clear. — 에러 후 `clear_status()`(W1C) + 재실행 성공은 확인했으나, W1C만 단독으로 latch를 지우는지와 W1C 없이 다음 accepted START만으로 지워지는지는 각각 독립적으로 검증하지 않음.
- [ ] AXIS backpressure, valid data/last stability, final TLAST, TKEEP=1111. — 아직 없음(`tb_op_residual_add_directed.sv`는 M_AXIS_TREADY를 항상 1로 유지).
- [ ] ABORT during MAIN/SKIP/COMPUTE/output and recovery. — 아직 없음.
- [ ] Consecutive Residual operations and OP_CONV↔OP_RESIDUAL_ADD. — 연속된 residual-only 연산(정상 2건 + 에러 후 recovery 4건)은 한 시뮬레이션 내에서 PASS; OP_CONV↔OP_RESIDUAL_ADD 교차 실행은 아직 없음.
- [x] 기존 OP_CONV 10 PASS/0 FAIL을 식별 가능한 결과로 보존. — `scripts/sim/run_regression.sh` 재실행, `TOTAL: 10 PASS, 0 FAIL` 확인 (this session).
- [x] 전체 regression wrapper의 최종 PASS summary 확보. — 위와 동일 실행에서 확보.

## 14. Stage 2-B — Golden and Firmware

`generate_stage2_vectors.py`는 identity/projection BasicBlock용 conv checkpoint와 residual expected output을 생성하며 Conv2/shortcut을 공통 scale로 맞춘다. identity shortcut은 현재 Python에서 INT8 rescale한다. 즉 common-scale 정책과 golden generator는 코드에 존재한다. 다만 생성 artifact/manifest를 RTL Residual과 대조한 repository 내 PASS 증거는 아직 없다.

필수 checkpoints: A block input/shortcut, B Conv1 output, C Conv2 MAIN, A/rescaled A SKIP, D final output. 각 artifact에 shape, NHWC, dtype, scale, zero-point, M/N, ReLU, byte count, SHA-256을 기록한다.

FW의 `accel_driver.c`는 현재 `layer->op != OP_CONV`를 거부한다. enum과 register 예약값만 존재하므로 Residual scheduler는 **PLANNED**, 구현 완료가 아니다. Scheduler는 S2MM arm → START → MAIN MM2S → SKIP MM2S → DONE/S2MM 확인 → packet error 시 W1C 전에 DEBUG_STATE 기록 → cache invalidate/golden compare 순서를 구현해야 한다.

## 15. Roadmap

| Roadmap | State | Completion criterion |
|---|---|---|
| R0 baseline/interface | DONE | v1.1 baseline과 Organization 통합 |
| R1 single OP_CONV/board bring-up | DONE, repeat count UNVERIFIED | full vector와 board 0 mismatch |
| R2 OP_RESIDUAL_ADD RTL | IN PROGRESS (core arithmetic/MAIN→SKIP/DEBUG-latch directed tests PASS this session; abort/backpressure/reject-path/exact-vector 항목 남음) | Section 13 전 항목 PASS |
| R3 FW Residual scheduler | PLANNED | 실제 opcode 2 실행 및 recovery |
| R4 first identity BasicBlock | PLANNED | A/B/C/D checkpoints mismatch 0, board repeat |
| R5 1×1 projection/downsample | PLANNED | kernel1 stride2 padding0 지원/검증 |
| R6 all BasicBlocks/model stages | PLANNED | stage scheduler checkpoint PASS |
| R7 GAP | DECISION REQUIRED | 초기 권장 PS fallback |
| R8 FC/argmax | DECISION REQUIRED | 초기 권장 PS fallback |
| R9 ResNet-20 E2E | PLANNED | golden/FPGA checkpoints와 board repeat |
| R10 PE optimization | DEFERRED | E2E 후 timing/resource/speedup/accuracy 비교 |

Projection 구현 시 validator kernel=1, weight bytes, output dimension, tap/address loop, stride2/padding0, Python golden과 FW descriptor를 함께 변경한다. 가능하면 기존 KERNEL_SIZE register를 재사용하고 register map은 유지한다.

## 16. Quantization and Conv Engine

- BN folding 후 weight INT8, activation INT8, bias INT32.
- bias scale은 input scale × weight scale.
- M/N requantization과 RTL 동일 rounding/saturation 순서를 사용.
- Residual MAIN/SKIP은 동일 scale이며 add engine 내부 requantization은 없다.
- current Conv engine은 single MAC, 3×3×IC sequential taps, synchronous buffers, INT32 accumulation, bias/requant/ReLU/clamp, output buffer 구조다.
- 과거 100 MHz timing 보고는 committed OP_CONV artifact에 대한 값이다. Residual dirty tree의 synthesis/timing은 `UNVERIFIED`다.

## 17. Verification Rules

1. simulation PASS와 FPGA PASS를 별도 상태로 기록한다.
2. enum, script 또는 문서 존재만으로 기능 완료를 선언하지 않는다.
3. Python golden과 RTL/FW를 checkpoint별로 비교한다.
4. 새 operation은 기존 OP_CONV regression을 보존한다.
5. register/interface 변경은 최소화하고 공동 합의한다.
6. 실제 로그 없이 PASS 또는 반복 횟수를 추정하지 않는다.
7. 기능 correctness를 성능보다 먼저 닫는다.
8. accelerator error와 DMA error를 별도 진단한다.

## 18. Open Decisions and Blockers

| Item | Owner | Needed before | Status | Next action |
|---|---|---|---|---|
| Residual dedicated verification | 황정민 | Stage 2-A 종료 | IN PROGRESS — partial closure (`tb_op_residual_add_directed.sv` 10/10 PASS, this session) | Section 13 잔여 항목(abort/backpressure/validation reject-path/정확한 경계값 벡터/early-late-missing 전체 매트릭스) 추가 |
| v1.2 source control | Joint | 협업 안정화 | DECISION REQUIRED | 외부 DRAFT를 repo에 검토/승격 |
| common-scale artifact PASS | 소은수 + 황정민 | Stage 2-B | READY, UNVERIFIED | generator output과 RTL 비교 |
| FW Residual scheduler | 소은수 | first block | PLANNED | driver operation 분기 구현 |
| identity BasicBlock vector/manifest | 소은수 | R4 | READY/UNVERIFIED | 생성·hash·handoff 확인 |
| 1×1 projection | Joint | model stage2/3 | PLANNED | R4 후 kernel1 설계 |
| GAP/FC boundary | Joint | E2E | DECISION REQUIRED | 초기 PS fallback 확정 |
| Residual synthesis/timing | 황정민 | board build | UNVERIFIED | functional closure 후 수행 |
| PE timing/architecture | 황정민 | optimization | DEFERRED | R9 이후 비교 |

DMA 14-bit 문제는 blocker 목록에 넣지 않는다.

## 19. Do Not Reopen without New Evidence

- single OP_CONV 기본 architecture와 canonical full-conv vector.
- 현재 milestone의 AXI DMA Simple mode 선택.
- SgLengthWidth=23 / MaxTransferLen=8,388,607 handoff.
- Stage 1 16,384-byte S2MM 문제의 해결 판정.
- BN은 Python folding, dedicated BN RTL은 현재 불필요.
- LayerNorm은 현재 ResNet-20 범위 밖.
- PE optimization은 E2E 이후.
- 첫 BasicBlock은 identity 32×32×16.

## 20. Quick Start in a New Environment

```bash
git clone https://github.com/2026-zynq-fpga-accelerator/zynq-fpga-accelerator.git
cd zynq-fpga-accelerator

git remote -v
git branch --show-current
git rev-parse HEAD
git status --short
git fetch origin
git rev-list --left-right --count HEAD...origin/main
```

기존 clone이 dirty면 pull/rebase보다 먼저 diff와 ownership을 확인한다. 깨끗한 clone에서 동기화할 때만 `git pull --ff-only origin main`을 사용한다.

RTL baseline:

```bash
cd rtl
source /home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh  # 기존 환경 예; 새 환경 경로는 다를 수 있음
scripts/sim/run_regression.sh
```

완료 전 repository root에서 `git status --short`, `git diff --stat`, `git diff --check`, `git diff --name-only`을 실행한다. 황정민은 합의된 RTL 변경만 `git add rtl/`로 stage하고 push 직전 origin/main 변화를 다시 확인한다.

## 21. Toolchain

| Tool | 용도 | 분류 |
|---|---|---|
| Linux, Git | 전체 개발/협업 | Required |
| Vivado/XSim 2022.2 | RTL simulation, synthesis, implementation | RTL Required |
| Python 3 | vector/golden/scripts | Required |
| Icarus Verilog/Verilator | 빠른 compile/cocotb 보조 | RTL/verification Optional-to-Required by test |
| Vitis 2022.2 | bare-metal platform/FW | FW Required |
| Zybo Z7-20, SD, UART | physical validation | Board milestone Required |

## 22. Immediate Next Actions

1. 공식 clone과 branch/HEAD/status를 확인하고 현재 dirty ownership을 합의한다.
2. 기존 Residual RTL diff와 cocotb 변경을 review한다; 임의 reset/stash하지 않는다.
3. 현재 OP_CONV regression을 끝까지 실행해 최종 summary를 보존한다.
4. Section 13의 Residual 전용 arithmetic/protocol/error/recovery tests와 vector를 추가한다.
5. Stage 2-A를 모든 marker PASS 후에만 완료로 판정한다.
6. v1.2 DRAFT를 repository source-of-truth로 둘지 공동 검토한다.
7. Python common-scale identity vector/manifest를 생성하고 RTL output과 비교한다.
8. FW Residual scheduler를 소은수 영역에서 구현·검증한다.
9. Conv1→Conv2→Residual 첫 identity BasicBlock simulation을 A/B/C/D mismatch 0으로 닫는다.
10. 새 bitstream/FW로 Zybo 반복 test하고 UART log와 artifact provenance를 저장한다.

## 23. Current Project Status Dashboard

| Area | State | Evidence | Next |
|---|---|---|---|
| OP_CONV RTL | DONE | committed RTL + regression logs | preserve |
| Stage 1 board | DONE; count UNVERIFIED | commit history/project report | archive raw UART log |
| DMA length issue | HISTORICAL/RESOLVED | HW handoff width 23 | do not reopen |
| Residual engine | IN PROGRESS | dirty RTL/new engine + `tb_op_residual_add_directed.sv` 10/10 PASS (this session) | validation reject-path, abort, backpressure tests; Conv1→Conv2→Residual 통합 sim |
| Residual verification | IN PROGRESS — partial closure | dedicated TB 존재·PASS (§12/§13 참조); reject-path/abort/backpressure/exact-vector는 미검증 | Section 13 잔여 항목 |
| common-scale Python | READY/UNVERIFIED | stage2 generator | artifact comparison |
| FW Residual scheduler | PLANNED | driver rejects non-Conv | implement in FW scope |
| identity BasicBlock | PLANNED | graph/generator exist | R4 integration |
| 1×1 projection | PLANNED | Python graph uses it | R5 |
| GAP/FC | DECISION REQUIRED | graph exists, HW boundary open | prefer initial PS |
| PE | DEFERRED | research direction only | after E2E |

## 24. Source and Evidence Appendix

### Git snapshot

- HEAD and origin/main: `9099840b4628ef895e152804e646f03eec8c5d49`, 0 ahead/0 behind.
- Pre-existing tracked RTL changes: package, buffers, controller, loader, top and four sim filelists.
- Pre-existing untracked RTL: `rtl/rtl/compute/residual_add_engine.sv`.
- RTL 세션(황정민)이 이번 세션에서 만든 FW 하네스 변경(사용자 확인 후 유지, §4 참조): cocotb `Makefile`(사전 결함 RTL_DIR 경로 수정), `bfm.py`(residual 상수 추가).
- Pre-existing root additions: `.agents/`, `.claude/`, `AGENTS.md`, `docs/`, `skills-lock.json`.

### Key RTL

- `rtl/rtl/common/accel_pkg.sv`
- `rtl/rtl/control/{controller_fsm,axi_lite_regs,error_ctrl}.sv`
- `rtl/rtl/stream/{axis_packet_loader,axis_output_streamer}.sv`
- `rtl/rtl/compute/{tensor_buffers,conv_engine,residual_add_engine}.sv`
- `rtl/rtl/top/resnet_accel_top.sv`
- `rtl/tb/`, `rtl/scripts/sim/`, `rtl/vectors/`

### Key FW/Python

- `firmware-verification/firmware/src/{accel_driver,resnet_scheduler,dma_transfer}.c`
- `firmware-verification/firmware/inc/{accel_regs,resnet_layer}.h`
- `firmware-verification/python/models/{resnet_fp,bn_fold,golden_fixed_point,quantize}.py`
- `firmware-verification/scripts/generate_stage2_vectors.py`
- `firmware-verification/scripts/generate_stage2_{vector_manifest,c_header}.py`

### Documents/logs

- `firmware-verification/HW_SW_Interface_v1.1_FINAL.md`
- external `HW_SW_Interface_v1.2_DRAFT.md`
- `rtl/README.md`, `rtl/TODO.md`
- `rtl/docs/FIRMWARE_INTEGRATION_AUDIT.md`
- `rtl/docs/ZYBO_Z7_OP_CONV_{INTEGRATION_PLAN,HW_HANDOFF}.md`
- `rtl/docs/verification/{RTL_COMPLETION_EDGE_FIX_REPORT,PHASE_3B2_ARTIFACT_REBUILD_REPORT,COMPLETION_FIX_BUILD_SUMMARY}.md`
- `rtl/build/regression/{smoke,unit,directed,full_conv}.log`
- raw Stage 1 repeat UART log: `UNVERIFIED / path not found`.

# Context Capsule for a New AI Coding Session

```text
Official repo: https://github.com/2026-zynq-fpga-accelerator/zynq-fpga-accelerator.git
Expected clone: /home/jmhwang/zynq-fpga-accelerator
RTL owner/scope: 황정민, rtl/**
FW/Python owner/scope: 소은수, firmware-verification/** (read-only unless agreed)
Goal: Zybo Z7-20 CIFAR-10 ResNet-20 end-to-end, Python golden bit-accurate.
Board: Zybo Z7-20 / XC7Z020, PL 100 MHz.
Control/data: AXI4-Lite and 32-bit AXI4-Stream via Simple AXI DMA.
Tensor: N=1 NHWC, signed INT8; bias/accumulator INT32.
Interface baseline: firmware-verification/HW_SW_Interface_v1.1_FINAL.md.
Residual extension: HW_SW_Interface_v1.2_DRAFT.md is currently external.
Completed: Development Stage 1 single OP_CONV baseline and reported board PASS.
Current: Development Stage 2, Stage 2-A OP_RESIDUAL_ADD.
Snapshot branch/HEAD: main / 9099840b4628ef895e152804e646f03eec8c5d49.
At handoff creation HEAD equals origin/main, but working tree is dirty.
Residual core RTL exists uncommitted: opcode 2, MAIN→SKIP, skip buffer,
4-lane signed INT8 add, saturation, optional ReLU, controller/debug/abort wiring.
Residual dedicated verification is not closed; do not call Stage 2-A DONE.
Existing logs show smoke/unit/directed/full-conv OP_CONV PASS markers.
FW accel_driver still rejects operations other than OP_CONV.
Python stage2 vector generator already expresses common MAIN/SKIP scale.
Immediate goal: dedicated Residual tests → final regression summary → common-scale
golden → FW scheduler → first 32×32×16 identity BasicBlock.
Do not reopen without new evidence: OP_CONV baseline, Simple DMA choice,
DMA width 23 resolution, BN folding, LayerNorm exclusion, PE deferral.
Do not modify register map, ERROR_CODE, or interface without joint agreement.
Do not touch firmware-verification/** from RTL work without approval.
Begin with git status/diff/remote/HEAD; preserve all existing dirty changes.
Baseline: cd rtl && scripts/sim/run_regression.sh
Stop and report on ownership conflict, interface conflict, or regression failure.
Do not commit/push automatically; report diff and validation first.
Read rtl/docs/PROJECT_MASTER_HANDOFF.md for full evidence and roadmap.
```
