# RTL completion-edge normative fix verification

## Scope and baseline

- Branch: `integration/zybo-bootbin`
- Fix commit: `4c8ac3ae37a52907613e7af7c6c6988aa455ad21`
- Subject: `fix(rtl): align DONE assertion with BUSY deassert`
- Canonical vector: `vectors/full_conv_32x32x3x16/`, seed 20260730,
  multiplier M=3, shift N=2
- Authoritative contract: `Zynq_FPGA_ResNet/HW_SW_Interface_v1.1_FINAL.md`

이 문서는 `build/reports/RTL_COMPLETION_EDGE_FIX_REPORT.md`의 GitHub용 정리본이다.
Firmware, register map, vector 및 artifact는 이 RTL-only fix에서 변경하지 않았다.

## Previous behavior and contract violation

E0를 final output beat의 `TVALID && TREADY && TLAST` handshake edge라고 하면
수정 전 구조에는 두 개의 registered completion boundary가 있었다.

| Edge | 동작 | Edge 후 status |
|---|---|---|
| E0 | Streamer가 `output_stream_done`을 등록, controller는 SEND_OUTPUT | BUSY=1, DONE=0 |
| E1 | Controller가 pulse를 샘플하고 COMPLETE 진입 | BUSY=0, DONE=0 |
| E2 | `error_ctrl`이 registered `operation_done`을 샘플 | BUSY=0, DONE=1 |

E1의 `BUSY=0, DONE=0, ERROR=0`은 정상 종료 경로에서 허용되지 않는 gap이었다.
Normative timing A는 final handshake와 BUSY deassert, sticky DONE assertion이
동일 observable cycle에 발생하도록 요구한다.

## Minimal RTL change

### `rtl/stream/axis_output_streamer.sv`

`done_o`를 다음 exact final-beat acceptance event로 조합 생성하도록 변경했다.

```systemverilog
m_axis_tvalid_o && m_axis_tready_i && m_axis_tlast_o
```

기존 one-cycle-late sequential `done_o` register assignments는 제거했다. Final
beat에 backpressure가 있으면 TREADY가 올라올 때까지 data/TKEEP/TLAST가 유지되고,
실제 handshake 전에는 completion이 발생하지 않는다.

### `rtl/control/controller_fsm.sv`

SEND_OUTPUT에서 같은 `output_done_i` event로 `operation_done_o`를 조합 생성한다.
ABORT와 fatal packet/TLAST error가 동시에 있으면 normal DONE은 억제된다.
기존 COMPLETE state와 state encoding은 변경하지 않았다.

### Unchanged sticky-status path

- `rtl/control/error_ctrl.sv`가 sticky DONE의 owner이다.
- `rtl/control/axi_lite_regs.sv`의 STATUS `[3:0]`은
  `{ERROR,DONE,BUSY,IDLE}`이다.
- DONE W1C는 STATUS address, `WSTRB[0]`, `WDATA[2]`가 모두 맞을 때만 발생한다.
- `rtl/control/cycle_counter.sv`는 accepted START에서 clear되고 BUSY cycle마다
  증가한다.

## Changed files

Commit `4c8ac3a`는 다음 6개 파일만 변경했다.

- `rtl/control/controller_fsm.sv`
- `rtl/stream/axis_output_streamer.sv`
- `tb/tb_full_conv.sv`
- `tb/tb_op_conv_directed.sv`
- `tb/tb_resnet_accel_ip_wrapper.sv`
- `tb/tb_resnet_accel_top.sv`

Commit stat: 201 insertions, 12 deletions.

## Corrected timing

| Edge | Streamer | Controller | Observable status |
|---|---|---|---|
| E0 전 | Final beat valid, TREADY 대기 | SEND_OUTPUT | BUSY=1, DONE=0 |
| E0 | Exact handshake, streamer OUT_IDLE 진입 | COMPLETE 진입 | IDLE=1, BUSY=0, DONE=1 |
| E0+1 | OUT_IDLE | COMPLETE→IDLE | IDLE=1, BUSY=0, DONE=1 |
| 이후 | Idle | IDLE | W1C/reset 전까지 DONE=1 |

정상 operation에는 더 이상 `BUSY=0, DONE=0, ERROR=0` gap이 없다.

## Simultaneous-event priority

| 동시 event | 결과 |
|---|---|
| reset + completion | reset 우선, DONE/ERROR/code clear |
| ABORT + completion | ABORT 우선, normal DONE 억제, fatal ERROR |
| fatal packet/TLAST error + completion | fatal error 우선, operation cancel |
| nonfatal warning + completion | 계약에 따라 DONE=1과 ERROR=1 동시 가능 |
| W1C + completion | completion set 우선 |
| new START + prior DONE | prior DONE 유지; firmware가 W1C 담당 |
| unrelated write | DONE clear 안 됨 |

## Strengthened test coverage

- `tb/tb_full_conv.sv`: handshake/BUSY fall/DONE rise/COMPLETE/IDLE cycle 기록,
  no-gap invariant, 100-clock sticky hold, read side effect 없음, unrelated write,
  WSTRB-masked W1C 및 explicit W1C 검사
- `tb/tb_resnet_accel_top.sv`: final beat 4-clock backpressure와
  data/TKEEP/TLAST 안정성, immediate completion status 검사
- `tb/tb_op_conv_directed.sv`: new START가 prior DONE을 자동 clear하지 않음을
  두 operation으로 검사; fatal ERROR, ABORT, recovery, consecutive operation 포함
- `tb/tb_resnet_accel_ip_wrapper.sv`: wrapper core DONE을 동일 smoke/full-conv
  assertion 경로에 노출

## Regression results

| Flow | Result |
|---|---|
| Vivado 2022.2 smoke XSim | PASS, 64 bytes matched |
| Vivado 2022.2 unit regression | PASS, 3 tests |
| Vivado 2022.2 directed XSim | PASS, 51 checks |
| Canonical Full Conv XSim | PASS, 16,384 bytes, mismatch=0 |
| Packaged-wrapper regression | PASS, smoke and Full Conv |
| Icarus smoke | PASS, 64 bytes matched |
| Verilator lint | Exit 0, no lint errors |
| `git diff --check` | PASS |

전체 failure는 0이다. Icarus의 기존 constant-select sensitivity limitation
message와 Verilator의 기존 width/unused/testbench blocking-assignment warning은
error가 아니며 completion-edge 변경의 실패를 나타내지 않는다.

## Canonical cycle result

근거 log: `build/reports/rtl_completion_edge_fix_xsim.log`

| Observation | Cycle / value |
|---|---:|
| Final handshake | 1,435,476 |
| BUSY deassert | 1,435,476 |
| DONE assertion | 1,435,476 |
| COMPLETE | 1,435,476 |
| IDLE | 1,435,477 |
| DONE sticky hold | 100 clocks through 1,435,576 |
| Explicit W1C | cycle 1,435,605, STATUS=`0x1`, ERROR_CODE=0 |
| Output | 16,384 bytes |
| Mismatch | 0 |
| Cycle count after fix | 1,435,390 |
| ERROR / ERROR_CODE | 0 / NONE |

수정 전 cycle count는 1,435,391이었다. 한 count 감소는 기존 forbidden gap
cycle이 제거된 결과이며 counter 정의 자체는 변경되지 않았다.

## Verification boundary

RTL simulation과 regression은 PASS지만 실제 Zybo Z7-20 board runtime은 PASS가
아니다. Completion-fix가 반영된 신규 BOOT.BIN에서도 `status=0x1` failure가
보고되어 추가 분석 중이다. 이 결과만으로 RTL을 다시 수정하지 않으며 먼저
START admission, DMA, polling 및 실제 hardware status 관측 경로를 분리해야 한다.
