# Zybo Z7-20 Single OP_CONV Integration TODO

Status vocabulary used below:

- `[x] Already verified`: supported by the current repository or recorded agreement.
- `[ ] Ready to execute`: inputs are available, but the action has not been run.
- `[ ] Blocked by hardware information`: exact board/part or exported hardware is required.
- `[ ] Deferred until single OP_CONV hardware PASS`: excluded from the first-board milestone.

## Phase 0. Baseline freeze

- [x] [RTL/Vivado] Already verified — Single OP_CONV integrated RTL passes Vivado XSim.
- [x] [RTL/Vivado] Already verified — automated regression reports 10 PASS, 0 FAIL.
- [x] [RTL/Vivado] Already verified — 32x32x3 -> 32x32x16 compares 16,384 bytes with mismatch 0.
- [x] [RTL/Vivado] Already verified — Weight/Bias/Input/Expected binary sizes are 432/64/3,072/16,384 bytes.
- [x] [RTL/Vivado] Already verified — source/vector files are staged; build and XSim products are ignored.
- [ ] [Joint] Ready to execute — re-run `scripts/sim/run_regression.sh` immediately before Vivado mutation.
- [ ] [Joint] Ready to execute — create an immutable baseline commit after the user confirms Git identity; no commit or remote exists now.

## Phase 1. Zybo board/part preflight

- [ ] [Joint] Blocked by hardware information — read and record the physical Zybo Z7-20 board revision.
- [ ] [RTL/Vivado] Ready to execute — inspect installed Vivado 2022.2 board files.
- [ ] [RTL/Vivado] Blocked by hardware information — reconcile physical revision, board part, and exact FPGA part without guessing.
- [ ] [RTL/Vivado] Ready to execute — verify `resnet_accel_top` port/interface packaging compatibility.
- [ ] [RTL/Vivado] Ready to execute — verify `s_axis_*`, `m_axis_*`, AXI4-Lite clock/reset association.
- [ ] [Joint] Ready to execute — confirm 100 MHz FCLK and Processor System Reset polarity/topology.

## Phase 2. OOC synthesis

- [x] [RTL/Vivado] Already verified — parameterized `scripts/vivado/synth_ooc.tcl` exists and rejects missing part/clock.
- [ ] [RTL/Vivado] Blocked by hardware information — run OOC synthesis with the confirmed FPGA part and 10 ns period.
- [ ] [RTL/Vivado] Blocked by hardware information — review timing, LUT/FF/BRAM/DSP utilization, and RAM/DSP inference.
- [ ] [Joint] Blocked by hardware information — approve results or stop on major timing/inference problems.

## Phase 3. RTL IP packaging

- [ ] [RTL/Vivado] Ready to execute — package `resnet_accel_top` only after Phase 2 passes.
- [ ] [RTL/Vivado] Ready to execute — map the 32-bit AXI4-Lite and two 32-bit AXI4-Stream interfaces.
- [ ] [RTL/Vivado] Ready to execute — associate all bus interfaces with `aclk` and active-low `aresetn`.
- [ ] [RTL/Vivado] Ready to execute — define the register address space without changing v1.1 offsets.
- [ ] [Joint] Ready to execute — inspect packaged interface metadata; stop if inference/mapping is incorrect.

## Phase 4. Zynq PS + AXI DMA Block Design

- [ ] [RTL/Vivado] Blocked by hardware information — create the project with the confirmed board/FPGA part.
- [ ] [RTL/Vivado] Ready to execute — configure PS7 FCLK_CLK0=100 MHz, M_AXI_GP0, S_AXI_HP0, and FCLK_RESET0_N.
- [ ] [RTL/Vivado] Ready to execute — configure Processor System Reset and verify active-low reset release.
- [ ] [RTL/Vivado] Ready to execute — configure AXI DMA Simple mode, SG/DRE disabled, MM2S/S2MM 32-bit.
- [ ] [RTL/Vivado] Ready to execute — connect GP0 control and HP0 DDR paths through interconnect/SmartConnect.
- [ ] [RTL/Vivado] Ready to execute — connect DMA MM2S -> accelerator S_AXIS and accelerator M_AXIS -> DMA S2MM.
- [ ] [RTL/Vivado] Ready to execute — assign and record accelerator/DMA address ranges.
- [ ] [Joint] Ready to execute — review DMA width, TLAST, clocks, resets, and address map.
- [ ] [RTL/Vivado] Ready to execute — validate the Block Design; stop on any validation error.

## Phase 5. Full synthesis and implementation

- [ ] [RTL/Vivado] Ready to execute — generate and inspect the HDL wrapper.
- [ ] [RTL/Vivado] Ready to execute — run synthesis and review critical warnings/utilization.
- [ ] [RTL/Vivado] Ready to execute — run implementation and review timing summary.
- [ ] [RTL/Vivado] Ready to execute — confirm no unintended clock-domain crossing or reset issue.
- [ ] [Joint] Ready to execute — approve implementation reports before bitstream generation.

## Phase 6. Bitstream/XSA handoff

- [ ] [RTL/Vivado] Ready to execute — generate bitstream only after Phase 5 approval.
- [ ] [RTL/Vivado] Ready to execute — export XSA with the implemented hardware.
- [ ] [RTL/Vivado] Ready to execute — deliver bitstream/XSA, address map, accelerator base address, and DMA hardware data.
- [ ] [Firmware] Blocked by hardware information — replace `ACCEL_BASE_ADDR` and DMA ID placeholders from the handoff.

## Phase 7. Vitis firmware integration

- [x] [Firmware] Already verified (firmware-owner report; not independently verified here) — accelerator register driver complete.
- [x] [Firmware] Already verified (firmware-owner report; not independently verified here) — AXI DMA Simple-mode polling code complete.
- [x] [Firmware] Already verified (firmware-owner report; not independently verified here) — OP_CONV scheduler complete.
- [ ] [Firmware] Ready to execute — finish aligned DDR buffer management.
- [ ] [Firmware] Ready to execute — implement/verify cache flush and invalidate ranges.
- [ ] [Firmware] Ready to execute — implement finite DMA/accelerator timeouts and DMA reset recovery.
- [ ] [Firmware] Blocked by hardware information — create Vitis platform/application from XSA.
- [ ] [Joint] Blocked by hardware information — review BSP parameters and final hardware identifiers.

## Phase 8. Zybo single OP_CONV hardware test

- [ ] [Joint] Blocked by hardware information — program the confirmed Zybo Z7-20.
- [ ] [Firmware] Blocked by hardware information — start 16,384-byte S2MM before START/MM2S.
- [ ] [Firmware] Blocked by hardware information — send separate Weight/Bias/Input MM2S transfers in order.
- [ ] [Firmware] Blocked by hardware information — poll DMA and accelerator with finite timeouts.
- [ ] [Firmware] Blocked by hardware information — invalidate output cache and compare all 16,384 bytes.
- [ ] [Joint] Blocked by hardware information — record UART status, cycle count, mismatch total, and first mismatch.
- [ ] [Joint] Blocked by hardware information — declare single OP_CONV FPGA PASS only when mismatch=0 and ERROR_CODE=ERR_NONE.

## Phase 9. Post-OP_CONV ResNet-20 scope decision

- [ ] [Joint] Deferred until single OP_CONV hardware PASS — decide residual-add RTL and skip-packet interface.
- [ ] [Joint] Deferred until single OP_CONV hardware PASS — decide projection shortcut implementation.
- [ ] [Joint] Deferred until single OP_CONV hardware PASS — define GAP and FC fixed-point behavior.
- [ ] [Joint] Deferred until single OP_CONV hardware PASS — decide CPU fallback boundary.
- [ ] [Joint] Deferred until single OP_CONV hardware PASS — define full quantization/exporter and scheduler.
- [ ] [Joint] Deferred until single OP_CONV hardware PASS — run end-to-end CIFAR-10 inference.

## Mandatory stop conditions

Stop and request a joint decision if:

- The exact FPGA part cannot be confirmed.
- Board revision, board file, board part, or FPGA part conflict.
- Vivado IP packaging cannot correctly recognize/map an AXI interface.
- OOC synthesis shows a major timing or memory-inference problem.
- Block Design validation reports an error.
- The agreed DMA width, TLAST behavior, DRE setting, or reset structure must change.
- The existing regression fails.
- A proposed fix would change the v1.1 external interface.
