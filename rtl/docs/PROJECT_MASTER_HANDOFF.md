# PROJECT MASTER HANDOFF

> Zynq FPGA SoC 기반 ResNet-20 추론 가속기
> Snapshot date: 2026-08-10 (Asia/Seoul), updated after board verification
> Git branch: `rtl/stage2-verification-closure`
> Git HEAD: `71488ae` (parent `4c1d795`, based on `main`@`9099840`)
> Working tree: clean as of this update; Stage 2-A RTL/verification work is committed.

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
| 현재 단계 | **Development Stage 2 완전 종료** (§3 정의 기준 R2/R3/R4 전부 DONE); Development Stage 3 = R5 1×1 projection/downsample 시작 |
| 가장 가까운 목표 | R5 1×1 projection RTL(kernel=1 지원) |

Stage 2-A(OP_RESIDUAL_ADD RTL), FW residual scheduler 팀 저장소 병합(R3), 첫 identity BasicBlock
보드 검증(R4)까지 전부 완료됐다: `tb_op_residual_add_directed.sv` 31/31 PASS,
`tb_stage2_identity_block.sv`(Conv1→Conv2→Residual 통합 시뮬레이션) 0/16384 mismatch, FW dispatch
`origin/main` 병합 완료(커밋 `4e98cdf`/`40df6d0`, §18), 실제 보드에서 `stage2_residual_test` 16회
연속 실행 전부 PASS(§7A). §3의 Stage 2 정의(residual connection + 첫 Basic Residual Block)를
구성하는 R2/R3/R4가 모두 닫혔으므로 **Stage 2는 완전히 종료됐다고 판정한다**. Development Stage 3는
R5(1×1 projection)부터 시작한다.

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

## 7A. Stage 2 Board Verification — First Identity BasicBlock (`VERIFIED`)

RTL 세션에서 만든 릴리즈(`rtl/build/releases/4c1d795/zybo_stage2_4c1d795_release.zip`, commit
`4c1d795`)의 `BOOT.BIN`을 소은수가 실제 Zybo Z7-20 보드에서 실행하고, 카카오톡으로 UART 로그
(`log2.txt`, PuTTY 캡처, 2026-08-10 17:33 KST)를 전달했다. 황정민이 로그 파일을 직접 열어 아래
수치를 라인 단위로 확인했다(요약이 아니라 원본 대조).

- 애플리케이션: `stage2_residual_test` (conv1 → conv2 → residual+ReLU, 소은수 개인 저장소
  `88377ab`의 `firmware/test/stage2_residual_test.c`).
- **로그로 확인된 연속 실행: 16/16 PASS.** 각 실행마다 `checkpoint1_conv1`,
  `checkpoint2_conv2`, `checkpoint3_final` 3개 checkpoint 전부 "0/16384 bytes mismatched".
- `cycle_count` 범위: 29,942 ~ 29,959 (16개 값 전부 이 구간 안, 표준편차 작음 — DMA/폴링에 의한
  정상적인 미세 지터로 보이며 기능 이상의 징후 아님).
- 추가로 소은수가 구두로(로그 없이) 더 많은 반복 실행에서도 PASS를 보고했으나, 이 문서의
  `VERIFIED`는 로그로 직접 대조한 16회에만 적용한다. 로그 없는 구두 보고는 `UNVERIFIED`로 유지한다
  (§17 검증 원칙 6번: "실제 로그 없이 PASS나 반복 횟수를 추정하지 않는다").
- **알려진 타이밍 마진 이슈(§12, WNS=-0.250ns)는 이 16회 실행에서 기능적 실패로 나타나지 않았다.**
  다만 검증된 것은 이번 릴리즈에 포함된 **단일 데이터 패턴**(identity BasicBlock 시드 0 벡터)뿐이다
  — setup 위반은 데이터 의존적(비트 스위칭 패턴)일 수 있으므로, 다른 데이터 패턴으로도 추가 보드
  테스트를 요청하는 것을 권장한다(§18 참조).
- `log2.txt` 원본은 `rtl/docs/verification/log2.txt`에 커밋되어 영구 보존됐다 — Stage 1의
  "10회 이상을 입증하는 원본 UART log 경로를 찾지 못했다"(§7) 문제를 반복하지 않는다.

이로써 **R4(첫 identity BasicBlock, 32×32×16)는 board repeat 기준을 충족해 `DONE`으로 판정한다**
(§15 로드맵 갱신 참조). 이 보드 테스트 당시(2026-08-10 17:33 KST)에는 소은수의 **개인 저장소**
펌웨어로 실행된 것이었으나, 그 직후(17:46~17:58 KST) 동일 커밋(`88377ab`)이 `origin/main`에
병합되어(커밋 `4e98cdf`/`40df6d0`) **R3(FW residual scheduler 팀 저장소 병합)도 완료**됐다 —
자세한 내용은 §18 참조.

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
| residual validation/snapshot | VERIFIED | `controller_fsm.sv` + `tb_op_residual_add_directed.sv` | accept 경로 + reject/boundary 4종(CONV_CONFIG 비트 위반, OUTPUT_SCALE 비영, byte 불일치, channel 불일치) directed test PASS |
| skip packet routing | VERIFIED | `axis_packet_loader.sv` + `tb_op_residual_add_directed.sv` | SKIP TLAST/length error 케이스 PASS, DEBUG_STATE=8 확인 |
| independent skip buffer | VERIFIED | `tensor_buffers.sv` + `tb_op_residual_add_directed.sv` | SKIP 데이터가 독립적으로 저장/합산되는 것을 directed test로 확인 |
| four INT8 lanes/word add | VERIFIED | new `residual_add_engine.sv` + `tb_op_residual_add_directed.sv` | 8-lane 양수/음수 add directed test PASS |
| saturation/ReLU | VERIFIED | `add_lane()` + `tb_op_residual_add_directed.sv` | overflow/underflow clamp + Final ReLU on/off directed test PASS; §13에 명시된 정확한 경계값 벡터 전부는 아직 미실행 |
| full-word output write | VERIFIED | buffers/top diff + `tb_op_residual_add_directed.sv` | 캡처한 M_AXIS 출력이 기대값과 word 단위로 일치 |
| packet-error DEBUG latch | VERIFIED | controller diff + `tb_op_residual_add_directed.sv` | MAIN=4/SKIP=8 latch 확인; W1C 단독 clear(`debug_latch_w1c_alone`)와 W1C 없는 다음 accepted START clear(`debug_latch_next_start_alone`) 각각 독립 검증 PASS |
| abort wiring | VERIFIED | controller/top/engine + `tb_op_residual_add_directed.sv` | MAIN/SKIP/COMPUTE/OUTPUT 4단계 ABORT + 각 recovery directed test PASS |
| external AXI ports | CURRENT unchanged | `resnet_accel_top.sv` port list | elaborated with OP_CONV tests |
| existing Conv engine | CURRENT unchanged | no `conv_engine.sv` diff | `run_regression.sh` 재실행 결과 TOTAL: 10 PASS/0 FAIL (this session) |

`firmware-verification/verification/cocotb/Makefile`와 `bfm.py`에도 미커밋 Residual compile/constants 연결이 있으나 test body는 아직 OP_CONV 중심(`test_accel_conv.py`)이다. 이 변경은 FW 담당 영역의 기존 협업 변경이 아니라 이번 황정민 RTL 세션에서 직접 만든 것이다(§4 참조).

## 13. Residual Verification Closure

Stage 2-A 완료 전 아래를 실제 marker와 결과로 닫는다.

- [x] Arithmetic: 127+1, 127+127, -128+-1, -128+-128, 100+-100. — `tb_op_residual_add_directed.sv`의 `exact_boundary_vectors` 테스트가 이 5개 벡터를 정확히 그대로 사용해 PASS.
- [x] ReLU OFF signed result, ReLU ON negative→0, mixed four-lane word. — `add_and_saturate_relu_off`/`final_relu_on` PASS.
- [x] MAIN normal/early/late/missing TLAST/length mismatch, error DEBUG=4. — normal/early(`main_tlast_error`)/missing(`main_missing_tlast_error`)/length(`main_packet_length_error`) PASS. "late TLAST"는 이 프로토콜에서 RTL 동작이 "missing"과 동일함을 확인(count_valid가 매 beat 4-byte 단위로만 증가하므로 초과 beat는 항상 정확한 위치의 missing/mismatch로 먼저 걸림) — 기존 `tb_op_conv_directed.sv`도 동일 이유로 early+missing만 다룸, 별도 케이스 불필요로 판단.
- [x] SKIP normal/early/late/missing TLAST/length mismatch, error DEBUG=8. — normal/early(`skip_early_tlast_error`)/missing(`skip_tlast_error`)/length(`skip_packet_length_error`) PASS. "late" 판단은 MAIN과 동일.
- [x] DEBUG latch: ERROR W1C 및 다음 accepted START clear. — `debug_latch_w1c_alone`(새 START 없이 W1C만으로 클리어됨), `debug_latch_next_start_alone`(W1C 없이 다음 accepted START만으로 클리어됨) 각각 독립 검증 PASS.
- [x] AXIS backpressure, valid data/last stability, final TLAST, TKEEP=1111. — `axis_backpressure` 테스트, non-blocking pre-edge capture로 TVALID/TDATA/TKEEP 안정성과 TLAST 위치 확인 PASS.
- [x] ABORT during MAIN/SKIP/COMPUTE/output and recovery. — `abort_during_{load_input,load_skip,compute,output}` 4종 + 각 recovery PASS.
- [x] Consecutive Residual operations and OP_CONV↔OP_RESIDUAL_ADD. — 시뮬레이션에서는 residual-only 연속 실행(정상 2건 + 에러 후 recovery 4건) PASS; OP_CONV↔OP_RESIDUAL_ADD 교차는 실제 보드에서 `stage2_residual_test`가 OP_CONV(conv1)→OP_CONV(conv2)→OP_RESIDUAL_ADD를 16회 연속 반복해 전부 PASS함으로써 board-level 증거로 충족(§7A).
- [x] 기존 OP_CONV 10 PASS/0 FAIL을 식별 가능한 결과로 보존. — `scripts/sim/run_regression.sh` 재실행, `TOTAL: 10 PASS, 0 FAIL` 확인.
- [x] 전체 regression wrapper의 최종 PASS summary 확보. — 위와 동일 실행에서 확보.

Stage 2-A verification closure는 위 전 항목 PASS로 **완료 판정**한다. 남은 것은 성능/합성 최적화(WNS=-0.250ns, §12)뿐이며 이는 §17 원칙 7번("기능 correctness를 성능보다 먼저 닫는다")에 따라 별도 트랙으로 관리한다.

## 14. Stage 2-B — Golden and Firmware

`generate_stage2_vectors.py`는 identity/projection BasicBlock용 conv checkpoint와 residual expected output을 생성하며 Conv2/shortcut을 공통 scale로 맞춘다. identity shortcut은 현재 Python에서 INT8 rescale한다. 즉 common-scale 정책과 golden generator는 코드에 존재한다. 다만 생성 artifact/manifest를 RTL Residual과 대조한 repository 내 PASS 증거는 아직 없다.

필수 checkpoints: A block input/shortcut, B Conv1 output, C Conv2 MAIN, A/rescaled A SKIP, D final output. 각 artifact에 shape, NHWC, dtype, scale, zero-point, M/N, ReLU, byte count, SHA-256을 기록한다.

FW의 `accel_driver.c`는 현재 `layer->op != OP_CONV`를 거부한다. enum과 register 예약값만 존재하므로 Residual scheduler는 **PLANNED**, 구현 완료가 아니다. Scheduler는 S2MM arm → START → MAIN MM2S → SKIP MM2S → DONE/S2MM 확인 → packet error 시 W1C 전에 DEBUG_STATE 기록 → cache invalidate/golden compare 순서를 구현해야 한다.

## 15. Roadmap

| Roadmap | State | Completion criterion |
|---|---|---|
| R0 baseline/interface | DONE | v1.1 baseline과 Organization 통합 |
| R1 single OP_CONV/board bring-up | DONE, repeat count UNVERIFIED | full vector와 board 0 mismatch |
| R2 OP_RESIDUAL_ADD RTL | DONE | Section 13 전 항목 PASS (commit `4c1d795`, `71488ae`) |
| R3 FW Residual scheduler | **DONE** | 실제 opcode 2 실행: `origin/main` 커밋 `4e98cdf`/`40df6d0`(작성자 EunsooSoh, 2026-08-10)로 팀 저장소 병합 완료, 개인 저장소 `88377ab`와 byte-for-byte 동일 확인. recovery(에러 경로)는 board에서 별도 검증 안 됨 |
| R4 first identity BasicBlock | **DONE** | board repeat 16/16 PASS, cycle_count 29,942–29,959, log `log2.txt`(§7A) — checkpoint mismatch 0 |
| R5 1×1 projection/downsample | PLANNED — **Stage 3 시작점으로 결정됨** | kernel1 stride2 padding0 지원/검증. 확인된 RTL 제약: `controller_fsm.sv`가 `kernel==3`만 허용(하드코딩), `conv_engine.sv`의 tap-loop(`kernel_h_q`/`kernel_w_q`)가 3×3 전용 구조라 kernel=1 지원은 validator뿐 아니라 conv_engine 내부 재설계 필요 |
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
- Residual 포함 전체 설계의 synthesis/timing은 `VERIFIED — 알려진 미해결 위반 있음`으로 갱신됐다: 3가지 구현 전략(Performance_ExplorePostRoutePhysOpt/_Explore/_NetDelay_high) 재시도 후 최선 결과 WNS=-0.250ns, 6개 setup endpoint 실패, hold/pulse-width는 모두 클린. 위반 경로는 `conv_engine.sv`의 기존 MAC 경로(weight_mem read → multiply → mac_product_q)이며 residual 추가로 인한 전체 설계 혼잡이 원인 — residual 자체의 정확성 문제 아님. 근본 수정(conv 전체 tap-loop 재파이프라인)은 conv 런타임을 거의 2배로 늘리므로 R10(PE 최적화, E2E 이후)로 defer. `generate_bitstream_xsa.tcl`에 이 위반을 명시적으로 추적·수용(WNS 하한 -0.30ns, 실패 endpoint ≤10)하도록 반영했다. 실제 보드에서는 이 위반이 기능 실패로 나타나지 않음을 16회 실행으로 확인했다(§7A) — 단, 단일 데이터 패턴 기준.
- `tensor_buffers.sv`의 `output_mem`이 (conv의 byte-select 쓰기 + residual의 word 쓰기) 2-write-port 충돌로 BRAM 대신 distributed RAM(~5,600 LUTRAM/SRL)에 떨어지는 실제 synthesis 버그를 발견·수정했다(byte-write-enable 단일 포트로 통합). 수정 후 LUTRAM/SRL=0으로 복귀, RAMB36E1은 24→32(정당한 증가: skip_mem 신규 + input_mem 2-read-port 복제).

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
| Residual dedicated verification | 황정민 | Stage 2-A 종료 | **DONE** | Section 13 전 항목 PASS (commit `4c1d795`) |
| v1.2 source control | Joint | 협업 안정화 | DECISION REQUIRED | 외부 DRAFT를 repo에 검토/승격 |
| common-scale artifact PASS | 소은수 + 황정민 | Stage 2-B | READY, UNVERIFIED | generator output과 RTL 비교 |
| identity BasicBlock vector/manifest | 소은수 | R4 | **VERIFIED (board)** | `log2.txt` 16/16 PASS 확인, `rtl/docs/verification/log2.txt`로 repo 보존 완료 |
| 추가 데이터 패턴 board 재검증 | 소은수 | 타이밍 위반 리스크 관리 | **DECISION REQUIRED — 요청 필요** | WNS=-0.250ns가 데이터 의존적일 수 있어, identity 시드 0 외 다른 패턴으로도 board 테스트 요청 |
| 1×1 projection | 황정민 (Stage 3) | model stage2/3 | PLANNED — Stage 3 시작 항목으로 확정 | kernel1 지원을 위한 controller_fsm/conv_engine 재설계 |
| GAP/FC boundary | Joint | E2E | DECISION REQUIRED | 초기 PS fallback 확정 |
| Residual synthesis/timing | 황정민 | board build | **VERIFIED — 알려진 미해결 위반**(WNS=-0.250ns) | R10에서 근본 수정 검토 |
| PE timing/architecture | 황정민 | optimization | DEFERRED | R9 이후 비교 |

DMA 14-bit 문제는 blocker 목록에 넣지 않는다.

**해소된 항목 (표에서 제거)**: FW Residual scheduler 팀 저장소 병합(R3) — `origin/main` 커밋
`4e98cdf`(작성자 EunsooSoh, 2026-08-10 17:46 KST, "stage-2 firmware/verification")와 merge
커밋 `40df6d0`으로 병합 완료. 변경 파일 4개(`accel_driver.{c,h}`, `accel_regs.h`,
`test/stage2_residual_test.c`) 전부 소은수 개인 저장소 커밋 `88377ab`와 byte-for-byte 동일함을
diff로 확인했고, merge가 `rtl/` 트리에 영향을 주지 않았음도 확인했다(`git diff b861679 origin/main -- rtl/`
비어있음). 이 merge에는 `log2.txt`나 다른 board 로그가 포함되어 있지 않다 — 그건 별도로
`rtl/docs/verification/log2.txt`에 커밋됐다(§7A).

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

Stage 2-A(1~5, 9)와 R4 board 검증(10)은 완료됐다(commit `4c1d795`, `71488ae`; `log2.txt` 16/16 PASS).
남은 항목:

1. ~~공식 clone과 branch/HEAD/status를 확인~~ — 완료.
2. ~~기존 Residual RTL diff와 cocotb 변경을 review~~ — 완료.
3. ~~현재 OP_CONV regression을 끝까지 실행해 최종 summary를 보존~~ — 완료, `TOTAL: 10 PASS, 0 FAIL`.
4. ~~Section 13의 Residual 전용 tests와 vector를 추가~~ — 완료, 전 항목 PASS.
5. ~~Stage 2-A를 모든 marker PASS 후 완료로 판정~~ — 완료.
6. v1.2 DRAFT를 repository source-of-truth로 둘지 공동 검토한다. (미결)
7. Python common-scale identity vector/manifest를 생성하고 RTL output과 비교한다. (미결 — Stage 2-B 항목, `generate_stage2_vectors.py` output과 RTL 직접 대조 아직 없음)
8. ~~FW Residual scheduler를 소은수 영역에서 구현·검증하고 팀 저장소로 병합한다~~ — 완료, `origin/main` 커밋 `4e98cdf`/`40df6d0` (2026-08-10).
9. ~~Conv1→Conv2→Residual 첫 identity BasicBlock simulation을 mismatch 0으로 닫는다~~ — 완료, `tb_stage2_identity_block.sv`.
10. ~~새 bitstream/FW로 Zybo 반복 test하고 UART log와 artifact provenance를 저장~~ — 완료(§7A), 로그는 `rtl/docs/verification/log2.txt`로 보존. **후속**: 다른 데이터 패턴으로 추가 board 테스트 요청.
11. **(신규)** R5(1×1 projection) RTL 착수: `controller_fsm.sv` validator의 kernel=3 하드코딩 제거, `conv_engine.sv` tap-loop을 kernel-size 파라미터화.

## 23. Current Project Status Dashboard

| Area | State | Evidence | Next |
|---|---|---|---|
| OP_CONV RTL | DONE | committed RTL + regression logs | preserve |
| Stage 1 board | DONE; count UNVERIFIED | commit history/project report | archive raw UART log |
| DMA length issue | HISTORICAL/RESOLVED | HW handoff width 23 | do not reopen |
| Residual engine | DONE | `tb_op_residual_add_directed.sv` 31/31 PASS + board 16/16 PASS | preserve; R10에서 timing 재검토 |
| Residual verification | DONE | Section 13 전 항목 PASS (commit `4c1d795`) | preserve |
| common-scale Python | READY/UNVERIFIED | stage2 generator | artifact comparison |
| FW Residual scheduler (팀 저장소 병합) | **DONE** | `origin/main` 커밋 `4e98cdf`/`40df6d0`, `88377ab`와 byte-identical | preserve |
| identity BasicBlock | **DONE** | board 16/16 PASS, `rtl/docs/verification/log2.txt`(§7A) | 추가 데이터 패턴 board 테스트 요청 |
| 1×1 projection | PLANNED — Stage 3 시작점 | kernel=3 하드코딩 확인됨(controller_fsm/conv_engine) | R5 설계 착수 |
| GAP/FC | DECISION REQUIRED | graph exists, HW boundary open | prefer initial PS |
| PE | DEFERRED | research direction only | after E2E |

## 24. Source and Evidence Appendix

### Git snapshot

- Branch `rtl/stage2-verification-closure`, HEAD `71488ae` (parent `4c1d795`), based on `main`@`9099840`. `main`은 아직 이 브랜치를 병합하지 않음(push/merge 여부는 별도 확인 필요).
- `4c1d795`: §13 verification closure (reject/boundary, TLAST 매트릭스, DEBUG latch 독립 검증, backpressure, abort×4, 정확한 경계값 벡터), `tb_stage2_identity_block.sv`(Conv1→Conv2→Residual 통합 sim), `tensor_buffers.sv`의 output_mem BRAM-inference 수정, Vivado/Vitis 빌드 스크립트(DMA width, IP 패키징, 리소스 기준값, 타이밍 게이트).
- `71488ae`: `rtl/scripts/release/package_stage2_release.py` (release zip 패키징).
- RTL 세션(황정민)이 만든 FW 하네스 변경(사용자 확인 후 유지, §4 참조): cocotb `Makefile`(사전 결함 RTL_DIR 경로 수정), `bfm.py`(residual 상수 추가).
- Root additions (여전히 untracked): `.agents/`, `AGENTS.md`, `docs/`(`.claude/`, `.agents/skills/`, `skills-lock.json`은 `.gitignore`로 제외됨).
- 산출물(gitignored, 커밋 대상 아님): `rtl/build/vivado_zybo/artifacts/zybo_resnet_system.{bit,xsa}`, `rtl/build/vitis_stage2/boot/BOOT.BIN`, `rtl/build/releases/4c1d795/zybo_stage2_4c1d795_release.zip`.

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
- Stage 2 board UART log: `rtl/docs/verification/log2.txt` (PuTTY, 2026-08-10 17:33 KST,
  카카오톡으로 전달받아 커밋 보존): 16/16 PASS, §7A 참조.

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
Completed: Development Stage 1 (OP_CONV) and Development Stage 2 in full (R2 OP_RESIDUAL_ADD
RTL + Section 13 verification closure; R3 FW scheduler merged into origin/main; R4 first
identity BasicBlock board-verified). Stage 2 is closed per this doc's own §3 definition.
Current: starting Development Stage 3 = R5 1×1 projection/downsample RTL.
Branch: rtl/stage2-verification-closure, commits 4c1d795 (verification closure + tensor_buffers
output_mem BRAM-inference fix + hardware build scripts) and 71488ae (release packaging script).
Residual RTL is committed and closed: opcode 2, MAIN→SKIP, skip buffer, 4-lane signed INT8 add,
saturation, optional ReLU, controller/debug/abort wiring -- tb_op_residual_add_directed.sv
31/31 PASS, tb_stage2_identity_block.sv (Conv1->Conv2->Residual sim) 0/16384 mismatch.
Board-verified: log2.txt (KakaoTalk, 2026-08-10) shows stage2_residual_test 16/16 consecutive
PASS on real Zybo Z7-20 hardware, cycle_count 29942-29959, 0/16384 mismatch on all 3
checkpoints, using EunsooSoh's *personal* firmware repo (commit 88377ab) -- not yet merged
into firmware-verification/** in this team repo.
Known open item: WNS=-0.250ns setup timing violation (pre-existing conv_engine MAC path,
congestion from the larger accelerator) is explicitly tracked/accepted in
generate_bitstream_xsa.tcl; did not manifest as a functional failure in the 16 board runs,
but only one data pattern has been tried -- request board tests with other data patterns too.
FW accel_driver in this team repo (firmware-verification/**) now dispatches OP_RESIDUAL_ADD
(merged into origin/main via commits 4e98cdf/40df6d0, verified byte-identical to Eunsoo Soh's
personal-repo commit 88377ab). R3 is DONE.
Immediate goal: R5 1x1 projection RTL (controller_fsm.sv currently hardcodes kernel==3;
conv_engine.sv's tap-loop is a fixed 3x3 structure -- both need to change to accept kernel=1).
Recommend: pull origin/main's firmware-verification/** changes into any fresh clone before
starting R5 (this session's rtl/stage2-verification-closure branch has not yet been rebased
onto the post-merge origin/main, though the merge touched no rtl/** files so no conflict is
expected).
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
