# Phase 3E-1 Firmware Integration Audit

Date: 2026-08-01

## 1. 분석 대상 repository/branch/commit

### Hardware

- Repository: `/home/jmhwang/resnet-fpga-accelerator`
- Branch: `integration/zybo-bootbin`
- HEAD: `cecb4b66bc3cfb45a6cf2e0933f65b818374afbf`
- Initial working tree: clean
- XSA: `build/vivado_zybo/artifacts/zybo_resnet_system.xsa`
- Bitstream: `build/vivado_zybo/artifacts/zybo_resnet_system.bit`

### Firmware

- Repository: `/home/jmhwang/Zynq_FPGA_ResNet`
- Remote: `https://github.com/EunsooSoh/Zynq_FPGA_ResNet.git`
- Default/current branch: `main`
- HEAD and `origin/main`: `26421df63a0254cf00a0c94ce5a699dc3a2428dc`
- Ahead/behind: `0/0`
- Initial working tree and index: clean
- Test-vector branch: `origin/test-vectors/stage1-conv`
- Test-vector commit: `7a326549bdaabdb9dc54fb9654b03d9cc154cd69`
- Branch relationship: the vector commit is one child commit of current `main` and adds only five files under `data/test_vectors/stage1_conv/`.

The test-vector directory was inspected without switching the firmware branch or
touching its index. `git archive` extracted it to
`build/vitis/temp/test_vectors_7a326549/`; firmware status before and after the
extraction was identical.

## 2. Firmware 구조

There is no README, Vitis project, BSP, linker script, or application build
configuration in the repository. `HW_SW_Interface_v1.1_FINAL.md` is the only
tracked integration/build specification.

| Path | Role |
|---|---|
| `firmware/test/stage1_conv_test.c` | Stage-1 application entry point, one-layer descriptor, golden byte comparison, UART result |
| `firmware/src/accel_driver.c` | AXI-Lite register access, configuration, START/ABORT, operation sequencing |
| `firmware/inc/accel_regs.h` | Register offsets, bit masks, error codes, VERSION `0x00010001` |
| `firmware/src/dma_transfer.c` | AXI DMA simple-mode initialization, MM2S/S2MM transfers and cache calls |
| `firmware/src/resnet_scheduler.c` | Calls `accel_run_layer()` for each layer and emits UART diagnostics |
| `firmware/inc/platform_config.h` | Placeholder accelerator base, DMA device ID, 100 MHz PL clock |
| `firmware/inc/resnet_layer.h` | Layer descriptor and buffer addresses |
| `scripts/generate_stage1_vectors.py` | PyTorch/NumPy vector generator; default seed is `0` |
| `python/export/exporter.py` | Writes NHWC/HWIO binary files and config metadata |
| `scripts/generate_stage1_c_header.py` | Converts five vector files to aligned C arrays |
| `firmware/host_stubs/` | Header declarations only; no host test/build harness |
| `verification/` | cocotb and SystemVerilog reference verification, not the Vitis application |

The generated header expected by the test application,
`firmware/test/generated/stage1_test_vector.h`, is absent from both `main` and
the test-vector branch and is intentionally ignored by Git.

### Actual call graph

```text
main
  -> dma_init
  -> accel_init
       -> VERSION read
       -> DONE/ERROR W1C
  -> resnet_run
       -> accel_run_layer
            -> DONE/ERROR W1C
            -> accel_configure
            -> dma_s2mm_prepare
            -> accel_start
            -> dma_mm2s_transfer(weight) -> wait
            -> dma_mm2s_transfer(bias)   -> wait
            -> dma_mm2s_transfer(input)  -> wait
            -> accel_wait_done
            -> dma_s2mm_wait_complete
  -> bytewise golden comparison
  -> xil_printf result
```

## 3. Stage 1 실행 흐름

The source implements DMA initialization first and accelerator VERSION checking
second. It does not call `init_platform()` or `cleanup_platform()` and includes
no `platform.h`, so explicit BSP/UART platform initialization is missing.

`accel_run_layer()` performs the following sequence:

1. Require `STATUS.BUSY == 0`.
2. Clear DONE and ERROR using STATUS W1C.
3. Configure OP_CONV, shape, M/N, and all byte counts.
4. Invalidate the output range and arm S2MM.
5. Write CONTROL.START.
6. Submit three separate MM2S transfers in Weight, Bias, Input order, waiting for each.
7. Poll for operation completion.
8. Poll for S2MM completion.
9. Return to the application, which compares 16,384 bytes and prints the result.

This matches the interface specification's START-before-input-packets protocol,
but it does not handle the current hardware's multi-cycle START admission
correctly. Full-convolution simulation reports 34 cycles between START and BUSY.
The firmware starts MM2S immediately without first polling until BUSY or ERROR.
If validation rejects START, the accelerator never accepts the stream and
`dma_mm2s_wait_complete()` can wait forever because it has neither a timeout nor
DMA error inspection.

`accel_wait_done()` is called only after all three MM2S transfers. It polls until
BUSY drops and distinguishes DONE from a fatal termination, but it is not a
START-admission poll. Its `1,000,000` iteration budget is not based on a timer and
therefore cannot be claimed to be the requested 100 ms timeout.

The timeout path writes ABORT and confirms BUSY becomes zero. However,
`resnet_scheduler.c` does not call the existing `dma_halt_reset()` recovery
function, and the DMA wait loops have no timeout/status/error recovery.

## 4. XSA 검사 결과

| Check | Result |
|---|---|
| Archive integrity | PASS (`unzip -t`, no errors) |
| XSA SHA-256 | PASS: `01f7f2121b6940064491ae7a25de46f6a4233f1a93ae3547a8ff67ea1b60477b` |
| Bitstream SHA-256 | PASS: `a0313efc078dbe644126534e5fbad106bd0e689eef28073e01eb62ad1dd56e4c` |
| Embedded bitstream | PASS: `zybo_resnet_system.bit` |
| Hardware metadata | PASS: system HWH, two SmartConnect HWH files, BDA, XSA/sysdef metadata |
| PS metadata | PASS: `processing_system7_0`, PS7 init sources |
| Accelerator | PASS: `resnet_accel_0`, `jmhwang.local:npu:resnet_accel:1.0` |
| AXI DMA | PASS: `axi_dma_0`, simple MM2S/S2MM connectivity |
| FCLK | PASS: `FCLK_CLK0`, `100000000` Hz |
| Accelerator address | PASS: `0x43C00000-0x43C0FFFF` |
| DMA address | PASS: `0x40400000-0x4040FFFF` |
| DDR mapping | PASS: `0x00000000-0x3FFFFFFF` |

The hardware register offsets and VERSION in `firmware/inc/accel_regs.h` match
`rtl/common/accel_pkg.sv`: offsets `0x00` through `0x44`, STATUS/CONTROL bits,
and interface version `0x00010001` are consistent.

## 5. Test-vector branch 검사 결과

| File | Bytes | SHA-256 |
|---|---:|---|
| `weight.bin` | 432 | `07a3e365236b069c30d77373ab8597ab86304e17fe330379161e92720478e54a` |
| `bias.bin` | 64 | `82bc77d59ebe68e9ff115bf58d36f6fd6ce2497bd41649ad417a1b289c23188f` |
| `input.bin` | 3,072 | `bc2015c578b2460442f73ff34d8fc5500d4ab397055fb1cec9185588f46303ab` |
| `expected_output.bin` | 16,384 | `5cd8327e855a200f4852a62c74a6f90202c0e4b47b3ab8dc4ccfa56786333acc` |
| `config.json` | 575 | `1c3c3badc14d084e801737c53eb6ca59ad9185455d91589114ffadde4f126cd1` |

Shape, byte counts, NHWC/HWIO layouts, signed INT32 bias, stride 1, padding 1,
and ReLU match the hardware contract. The exporter explicitly serializes bias
as little-endian INT32.

The branch snapshot is not the vector used for the completed hardware
regression:

- Firmware branch config: `multiplier_m=44077`, `shift_n=24`, no seed field.
- Firmware generator default: seed `0`; the exporter does not record seed or
  file hashes in config.
- Hardware canonical config: seed `20260730`, M `3`, N `2`.
- All four firmware binary SHA-256 values differ from the hardware canonical
  `vectors/full_conv_32x32x3x16/` files.
- The hardware canonical vector is independently generated by
  `scripts/vector_gen/generate_full_conv_vector.py` using only the Python
  standard library and produced the verified 16,384-byte, zero-mismatch result.

This is a Phase 3E-2 application-build blocker. The remote vector can be valid
for another quantization scenario, but it cannot be presented as the exact
already-verified hardware bring-up vector. A single authoritative vector and
metadata schema must be selected before generating the embedded C header.

The firmware header generator also expects `multiplier_m`/`shift_n`, whereas the
hardware canonical config uses `multiplier`/`shift`. It cannot consume the
hardware canonical config unchanged. No C header was generated during this
audit.

Static Python syntax compilation passed for all tracked Python files with pycache redirected to
`/tmp`. NumPy and PyTorch are not installed in the current default Python 3.12.3
environment, so the firmware vector generator is NOT RUN and cannot currently
be regenerated. This does not prevent use of an approved binary snapshot or
the standard-library-only hardware generator.

## 6. Hardware/Firmware 계약 비교표

| 항목 | 요구사항 | Firmware 현재 구현 | 판정 | 근거 파일/함수 | Phase 3E-2 조치 |
|---|---|---|---|---|---|
| Application entry point | Platform/UART init and test main | `main()` exists; no `init_platform()` | PARTIAL | `stage1_conv_test.c:22` | Add BSP platform init/cleanup |
| Accelerator base | XSA `0x43C00000` | Correct numeric placeholder, no BSP macro | PARTIAL | `platform_config.h:21-23` | Alias exact generated XPAR macro |
| DMA device/base | `axi_dma_0` at `0x40400000` | Device ID placeholder `0`; base not used directly | PARTIAL | `platform_config.h:25-27`, `dma_init()` | Bind generated DMA device ID and verify base |
| Register map | Offsets/bits/VERSION match RTL | Matches current hardware | PASS | `accel_regs.h`, `accel_pkg.sv` | No change unless BSP naming requires wrapper |
| S2MM-before-START | Arm output first | Implemented | PASS | `accel_run_layer():170-175` | Retain |
| Three MM2S packets | Weight, Bias, Input separately | Three `SimpleTransfer` calls | PASS | `accel_run_layer():184-193` | Retain |
| Transfer lengths | 432/64/3,072/16,384 | Computed correctly for Stage 1 | PASS | `accel_configure():59-77` | Assert generated header lengths |
| TLAST assumptions | Last beat of every packet | One DMA BTT per packet supplies TLAST | PASS | `dma_mm2s_transfer()` | Confirm DMA simple-mode BSP config |
| Cache flush | Before every MM2S | Implemented | PASS | `dma_transfer.c:34-40` | Retain |
| Cache invalidate | After completed S2MM | Only before S2MM | FAIL | `dma_transfer.c:51-65` | Invalidate again after completion |
| Alignment | Address and length 4-byte aligned | Stage arrays/output are aligned; driver performs no runtime checks | PARTIAL | generated-header script, `g_output_buffer`; DMA wrapper | Add address/length validation |
| START admission polling | Poll BUSY=1 or ERROR=1 after START | Missing; immediately starts DMA | FAIL / BLOCKER | `accel_run_layer():175-185` | Add 100 ms admission poll before MM2S |
| ERROR polling | Detect rejected START and error code | Only completion-time diagnostics | PARTIAL | `accel_wait_done()`, scheduler | Poll STATUS.ERROR during admission/completion |
| Operation timeout | Approximately 100 ms, timer-based | Loop count only; duration uncalibrated | FAIL | `ACCEL_DEFAULT_TIMEOUT` | Use BSP timer (`XTime`) or proven elapsed-time source |
| DONE W1C | Correct STATUS write-one-to-clear | Correct, before init/operation | PASS | `accel_clear_done_and_error()` | Retain and preserve diagnostics order |
| ERROR W1C | Correct STATUS write-one-to-clear | Correct, combined with DONE | PASS | `accel_clear_done_and_error()` | Retain |
| DMA busy/error handling | Timeout, status/error, recovery | Infinite busy loops, no error status | FAIL | `dma_mm2s_wait_complete()`, `dma_s2mm_wait_complete()` | Add timeout/error checks and reset |
| Error recovery | Abort accelerator and reset DMA | DMA reset function exists but is not called | FAIL | `dma_halt_reset()`, `resnet_run()` | Invoke coordinated accelerator/DMA recovery |
| Output comparison | Compare 16,384 golden bytes | Logic exists; header absent and vector differs | PARTIAL / BLOCKER | `stage1_conv_test.c:63-85` | Resolve vector, generate/import header |
| UART success log | Print mismatch/cycles | `xil_printf` exists; platform init missing | PARTIAL | test and scheduler | Add platform initialization |
| Test-vector generation | Reproducible seed 20260730, M=3, N=2 | Remote snapshot uses different M/N and omits seed | FAIL / BLOCKER | both generator pipelines/configs | Select canonical source and normalize metadata |
| BSP/xparameters | Use generated hardware identifiers | No `xparameters.h`; placeholders only | PARTIAL | `platform_config.h` | Inspect BSP output, then bind exact names |
| Linker/DDR placement | Buffers in mapped DDR and aligned | No linker script/build config | NOT FOUND | repository inventory | Verify generated linker memory region and map file |

## 7. xparameters.h 예상 연결

The current firmware directly requires only three integration constants:
`ACCEL_BASE_ADDR`, `ACCEL_DMA_DEVICE_ID`, and `PL_CLOCK_HZ`. It includes
`xil_io.h`, `xaxidma.h`, `xil_cache.h`, and `xil_printf.h`; it does not currently
include `xparameters.h`, `platform.h`, or a timer header.

Expected, not yet confirmed, BSP connections are:

| Firmware symbol | Expected generated source | Status |
|---|---|---|
| `ACCEL_DMA_DEVICE_ID` | likely `XPAR_AXIDMA_0_DEVICE_ID` | Confirm after BSP generation |
| DMA base sanity check | likely AXI DMA base macro at `0x40400000` | Exact spelling unknown until BSP |
| `ACCEL_BASE_ADDR` | likely `XPAR_RESNET_ACCEL_0_S_AXI_CTRL_BASEADDR` | Exact spelling unknown until BSP |
| `PL_CLOCK_HZ` | hardware contract `100000000` | May remain explicit after XSA check |
| Platform/UART init | Vitis-generated `platform.h` | Missing now |
| 100 ms timeouts | likely `xtime_l.h`/`XTime_GetTime` | Select after BSP inspection |

The expected processor is `ps7_cortexa9_0`, but the exact Vitis processor
identifier must be enumerated from the generated platform before creating the
domain. No `xparameters.h` was generated in Phase 3E-1.

## 8. 발견한 gap/blocker

### Blockers before application ELF build

1. Remote Stage-1 vector does not match the canonical hardware regression
   vector (content, M/N, and seed metadata).
2. START admission polling is missing. A rejected START can lead to an infinite
   MM2S busy loop.
3. `stage1_test_vector.h` is absent, and the current header generator cannot
   consume the canonical hardware config schema unchanged.

### Required minimal fixes

- Bind accelerator/DMA identifiers to actual BSP-generated macros.
- Add platform initialization and a real elapsed-time source.
- Add START BUSY-or-ERROR admission polling with a 100 ms limit.
- Add bounded DMA polling, DMA error inspection/reset, and coordinated abort.
- Invalidate output cache after S2MM completion.
- Add runtime alignment/length guards.
- Verify the Vitis-generated linker script and map place all buffers in DDR.

## 9. Phase 3E-2에서 수정 가능한 파일

No file was changed in the firmware repository during this audit. Subject to a
separate Phase 3E-2 approval, the minimal expected source set is:

- `firmware/inc/platform_config.h`: include/alias confirmed xparameters macros.
- `firmware/src/accel_driver.c`: START admission and time-based completion polling.
- `firmware/src/dma_transfer.c` and possibly its header: alignment, bounded wait,
  DMA error/reset, post-S2MM cache invalidate.
- `firmware/src/resnet_scheduler.c`: coordinated accelerator/DMA recovery.
- `firmware/test/stage1_conv_test.c`: platform init/cleanup and explicit diagnostics.
- `scripts/generate_stage1_c_header.py` or an integration-side adapter: accept
  the selected canonical metadata schema.
- Generated, untracked `firmware/test/generated/stage1_test_vector.h` or the
  equivalent Vitis application source.

RTL, BD, clocks, reset, address map, XSA, bitstream, and linker memory geometry
must not be changed to hide a firmware issue.

## 10. Phase 3E-2 정확한 build 계획

Proposed names and locations:

- Workspace: `/home/jmhwang/resnet-fpga-accelerator/build/vitis/workspace`
- Platform: `zybo_resnet_platform`
- Domain: `standalone_ps7_cortexa9_0`
- Application: `stage1_conv_test`
- Processor: expected `ps7_cortexa9_0`, confirm by platform enumeration
- OS: `standalone`
- Architecture: 32-bit ARM Cortex-A9
- Toolchain: Vitis 2022.2 GNU ARM (`arm-none-eabi-gcc`)

Planned sequence:

1. Recheck firmware/test-vector commits, clean states, and XSA SHA-256.
2. Resolve and record the authoritative Stage-1 vector. Do not proceed while
   the current vector mismatch is unresolved.
3. Create the Vitis platform from the existing XSA, enumerate processors, then
   create the standalone domain and BSP.
4. Inspect generated `xparameters.h`; require the XSA addresses and expected DMA
   mode before editing integration aliases.
5. Stage source from firmware commit `26421df...` into the application without
   modifying unrelated upstream files. Apply only the approved minimal fixes.
6. Import the approved vector into an ignored staging path and generate an
   aligned C header. Verify byte sizes and SHA-256 before compiling.
7. Build the application ELF with warnings visible; inspect the linker script,
   map, sections, and DDR addresses.
8. Create/build the FSBL for the same platform and processor.
9. Stop after verified application and FSBL ELFs. BOOT.BIN and board execution
   remain later, separately approved tasks.

Expected outputs are the platform metadata, BSP and `xparameters.h`, application
ELF/map, and FSBL ELF under `build/vitis/`. None was generated in Phase 3E-1.

## 11. Phase 3E-2 stop conditions

Stop if any of the following occurs:

- The vector source/M/N/seed decision remains unresolved.
- Generated header sizes or hashes differ from the approved vector.
- Generated BSP addresses differ from accelerator `0x43C00000`, DMA
  `0x40400000`, or DDR `0x00000000-0x3FFFFFFF`.
- DMA is not simple mode, DRE-off, polling-capable MM2S/S2MM.
- The expected Cortex-A9 processor or standalone domain cannot be created.
- A linker/map file places DMA buffers outside mapped DDR or violates alignment.
- START admission, timeout, DMA error, or cache correctness needs an RTL/BD fix.
- Application or FSBL build has errors, unresolved symbols, or missing generated
  hardware identifiers.
- XSA/bitstream hash changes or a Vitis step requires regenerating hardware.

## 12. 현재 Vitis build 가능 판정

**NO-GO for the Stage-1 application as currently checked out.** The XSA is valid
and technically ready for platform/BSP creation, but application/FSBL build
acceptance must not be claimed until the vector mismatch, missing START
admission polling, and generated-header incompatibility are resolved.

Phase 3E-1 performed analysis only. Vitis, BSP, xparameters, ELF, FSBL, and
BOOT.BIN generation were NOT RUN.
