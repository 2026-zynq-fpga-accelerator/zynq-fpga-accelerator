# Zybo Z7-20 Single OP_CONV Integration Plan

Status: planning and preflight only. No Vivado project, synthesis, IP packaging,
Block Design, implementation, bitstream, XSA, or FPGA execution has been
performed.

## 1. Goal

Integrate the simulation-verified `resnet_accel_top` with the Zynq-7000 PS and
AXI DMA on a Zybo Z7-20, then execute the existing deterministic
32x32x3-to-32x32x16 `OP_CONV` vector on physical hardware.

The current baseline is **Single OP_CONV integrated RTL with Vivado XSim
verification**. The repository regression reports 10 PASS and 0 FAIL, and the
full convolution compares all 16,384 output bytes with zero mismatches. This is
not FPGA verification.

Residual add, projection, GAP, FC, CPU fallback, full ResNet-20 scheduling, and
end-to-end CIFAR-10 inference are outside the acceptance path for this plan.

## 2. Confirmed Hardware Configuration

The following items are agreed integration requirements:

- Board: Zybo Z7-20.
- Vivado: 2022.2.
- PL clock domain: one 100 MHz domain.
- RTL clock period target: 10 ns.
- Accelerator top: `resnet_accel_top`.
- Accelerator interfaces: 32-bit AXI4-Lite, 32-bit AXI4-Stream input, and
  32-bit AXI4-Stream output.
- AXI DMA: Simple mode, Scatter-Gather disabled, MM2S and S2MM enabled.
- DMA DRE: disabled.
- DMA completion: polling; interrupts disabled.
- DDR buffer addresses: 4-byte aligned.
- DMA transfer lengths: multiples of four bytes.

The exact Vivado board part, FPGA part, and board revision are deliberately not
recorded as confirmed. They must be read from the physical board and the
installed Vivado board definition before any project or synthesis command is
issued. No part string may be inferred from the product name alone.

## 3. Confirmed DMA and Packet Protocol

### MM2S input transfers

| Transfer | Payload | Bytes | Stream termination |
|---|---:|---:|---|
| 1 | Weight, HWIO INT8 | 432 | TLAST on final beat |
| 2 | Bias, INT32 little-endian | 64 | TLAST on final beat |
| 3 | Input, NHWC INT8 | 3,072 | TLAST on final beat |

Rules:

- Transfer order is Weight, Bias, Input.
- Every beat uses `TKEEP=4'b1111`.
- A packet is one separate MM2S Simple-mode transfer.
- No bytes from adjacent packets may be combined into one DMA transfer.

### S2MM output transfer

- Start one 16,384-byte S2MM transfer before accelerator START.
- The accelerator emits one output packet.
- TLAST must be asserted only on the final output beat.
- All output beats use `TKEEP=4'b1111`.

AXI DMA must be reviewed to ensure Simple-mode MM2S generates TLAST at the
programmed transfer boundary and that the 32-bit, no-DRE configuration preserves
the required full-word TKEEP behavior.

## 4. Clock and Reset

Confirmed clock/reset intent:

- PS7 `FCLK_CLK0` is 100 MHz.
- DMA, accelerator, AXI interconnect/SmartConnect, and related PL IP use the same
  clock domain.
- RTL reset is active-low `aresetn`.
- A Processor System Reset IP provides `peripheral_aresetn` to accelerator
  AXI4-Lite/AXI4-Stream reset and compatible peripheral resets.
- `FCLK_RESET0_N` is the PS reset source.

Preflight requirement: verify the Processor System Reset IP external-reset
polarity configuration. `FCLK_RESET0_N` is active-low; it must not be connected
to a reset input configured as active-high without the appropriate polarity
setting or inversion. The released `peripheral_aresetn` must be synchronous to
the 100 MHz PL clock.

## 5. Vivado Block Design Topology

The agreed logical topology is:

```text
PS7 M_AXI_GP0
  -> AXI interconnect/SmartConnect
     -> AXI DMA S_AXI_LITE
     -> Accelerator S_AXI_LITE

AXI DMA M_AXI_MM2S
  -> AXI interconnect/SmartConnect
     -> PS7 S_AXI_HP0

AXI DMA M_AXI_S2MM
  -> AXI interconnect/SmartConnect
     -> PS7 S_AXI_HP0

AXI DMA M_AXIS_MM2S
  -> Accelerator S_AXIS

Accelerator M_AXIS
  -> AXI DMA S_AXIS_S2MM
```

All paths use the 100 MHz PL clock domain. The GP0 fanout and the two DMA DDR
masters require a suitable AXI interconnect/SmartConnect structure; the diagram
must not be interpreted as electrically connecting one AXI master directly to
multiple slaves or multiple masters directly to HP0.

Proposed implementation sequence after preflight:

1. Create the PS7 and apply only the verified board/part configuration.
2. Enable FCLK_CLK0 at 100 MHz, FCLK_RESET0_N, M_AXI_GP0, and S_AXI_HP0.
3. Add Processor System Reset with verified input polarity.
4. Add AXI DMA in Simple mode with SG/DRE/interrupt use disabled and both stream
   channels set to 32 bits.
5. Add the packaged accelerator.
6. Add interconnect/SmartConnect and connect clocks/resets.
7. Connect MM2S and S2MM streams.
8. Assign and record address ranges.
9. Run Block Design validation and stop on any error.

## 6. Firmware Execution Sequence

The agreed first-test sequence is:

1. Initialize AXI DMA and accelerator driver.
2. Prepare Weight, Bias, Input, Expected Output, and Output buffers in DDR.
3. Confirm every buffer address is 4-byte aligned.
4. Flush Weight, Bias, and Input cache ranges.
5. Initialize the output buffer and start the 16,384-byte S2MM transfer.
6. Program accelerator configuration registers.
7. Clear stale DONE/ERROR status and issue accelerator START.
8. Start the 432-byte Weight MM2S transfer and poll MM2S completion.
9. Start the 64-byte Bias MM2S transfer and poll MM2S completion.
10. Start the 3,072-byte Input MM2S transfer and poll MM2S completion.
11. Poll S2MM and accelerator completion with finite timeouts.
12. Invalidate the 16,384-byte output cache range.
13. Compare all output bytes with `expected_output.bin`.
14. Report DMA status, accelerator STATUS/ERROR_CODE/DEBUG_STATE/CYCLE_COUNT,
    mismatch count, and first mismatch coordinates over UART.

DMA timeout recovery must reset the affected DMA channel and leave enough
diagnostic state to distinguish a missing TLAST, reset problem, stalled stream,
or accelerator error.

## 7. Test Vector

The first physical test uses the existing seed-20260730 vector under
`vectors/full_conv_32x32x3x16/`.

| Field | Value |
|---|---|
| Input | 32x32x3 NHWC signed INT8 |
| Weight | 3x3x3x16 HWIO signed INT8 |
| Bias | 16 signed INT32, little-endian |
| Output | 32x32x16 NHWC signed INT8 |
| Stride / padding | 1 / 1 |
| Requantization | M=3, N=2 |
| ReLU | enabled |
| Input / Weight / Bias / Output bytes | 3,072 / 432 / 64 / 16,384 |

Repository inspection confirmed the four binary file sizes. The XSim regression
reports all 16,384 output bytes matched and cycle count 927,486.

The vector must not be regenerated before the first board comparison. Firmware
and hardware must consume the same staged binary files used by the verified
baseline.

## 8. Role Assignment

### RTL/Vivado

- Preserve RTL unless a demonstrated integration defect requires a minimal fix.
- Confirm the physical board revision, installed board part, and exact FPGA part.
- Run OOC synthesis, review timing/utilization and RAM/DSP inference.
- Package the RTL with correctly associated AXI clocks and resets.
- Build and validate the PS7, DMA, interconnect, reset, and accelerator design.
- Run synthesis/implementation and generate bitstream/XSA.
- Deliver the accelerator base address, DMA hardware configuration, address map,
  clock/reset facts, reports, bitstream, and XSA.

### Firmware

- Manage aligned DDR buffers and cache maintenance.
- Initialize and poll AXI DMA Simple-mode transfers.
- Use the existing accelerator register driver.
- Implement finite timeouts and DMA reset recovery.
- Replace `ACCEL_BASE_ADDR` and DMA ID placeholders from the exported hardware.
- Create the Vitis platform/application from the delivered XSA.
- Compare all FPGA output bytes with the golden vector.

Reported firmware state, not independently verified in this repository:

- Accelerator register driver complete.
- AXI DMA Simple-mode transfer code complete.
- OP_CONV scheduler complete.
- DDR buffer management in progress.
- Base address and DMA ID remain placeholders.
- No Vitis platform exists yet.
- Host GCC syntax checks currently use Xilinx BSP header stubs.

### Joint

- Review DMA parameters, widths, packet boundaries, and address map.
- Program the physical Zybo Z7-20 and review UART diagnostics.
- Diagnose mismatches, timeouts, reset issues, and cache coherency jointly.

## 9. Deliverables

### Preflight and synthesis

- Recorded board revision, Vivado board part, and exact FPGA part with source.
- Frozen baseline regression log.
- OOC synthesis checkpoint.
- Hierarchical utilization, timing summary, methodology, and RAM/DSP inference
  reports.

### Vivado integration

- Reproducible project/Block Design Tcl.
- Packaged accelerator IP metadata.
- Validated Block Design and exported address map.
- Synthesis and implementation reports.
- Bitstream and XSA.

### Firmware/hardware test

- Final accelerator base address and DMA hardware parameters.
- Vitis platform/application.
- UART log containing transfer status, accelerator status, cycle count, and
  mismatch count.
- A recorded 16,384-byte comparison result.

## 10. Open Items

### Mandatory preflight checklist

- [ ] Read the physical Zybo Z7-20 board revision.
- [ ] Confirm the Zybo board file is installed and compatible with Vivado 2022.2.
- [ ] Record the board part exposed by Vivado.
- [ ] Independently confirm the exact FPGA part; resolve any board-file conflict.
- [ ] Confirm top module `resnet_accel_top`.
- [ ] Confirm the AXI4-Lite port set and 7-bit address input are packageable.
- [ ] Confirm `s_axis_*` and `m_axis_*` are recognized or can be manually mapped
      as 32-bit AXI4-Stream interfaces.
- [ ] Confirm AXI clock/reset association metadata in IP packaging.
- [ ] Confirm FCLK_CLK0=100 MHz and the 10 ns OOC constraint.
- [ ] Confirm Processor System Reset input polarity and `peripheral_aresetn`.
- [ ] Confirm DMA Simple mode, SG disabled, DRE disabled, interrupts unused.
- [ ] Confirm MM2S/S2MM stream widths are 32 bits.
- [ ] Confirm GP0 control paths and HP0 DDR paths through interconnect.
- [ ] Confirm MM2S TLAST generation for each Simple-mode transfer.
- [ ] Confirm RTL source compile order in `scripts/vivado/synth_ooc.tcl`.
- [x] Confirm full vector files exist.
- [x] Confirm binary sizes are Weight 432, Bias 64, Input 3,072, Output 16,384.
- [x] Confirm regression command is `scripts/sim/run_regression.sh`.
- [ ] Re-run regression immediately before the first Vivado mutation.
- [ ] Create a committed or otherwise immutable clean baseline; the repository
      currently has staged files but no commit.

### Open but not blocking planning

- Exact accelerator AXI-Lite base address.
- AXI DMA device ID/base address.
- Final Vitis version.
- UART baud rate and diagnostic formatting.
- Whether installed board automation can be used or manual PS7 settings are needed.

These become execution inputs during Block Design/XSA/firmware work but do not
prevent preparing this plan.

### Deferred until single OP_CONV hardware PASS

- Residual add and skip-packet interface.
- Projection shortcut.
- GAP/FC fixed-point formats.
- CPU fallback.
- Full ResNet-20 exporter, quantization, scheduler, and CIFAR-10 inference.

## 11. Stop Conditions

Stop without guessing or broadening the design if any of the following occurs:

- The exact FPGA part cannot be independently confirmed.
- The physical board, board file, board part, and FPGA part conflict.
- Vivado IP packaging does not recognize or correctly map an AXI interface.
- Clock/reset association or reset polarity cannot be proven.
- OOC synthesis shows a major timing failure or unacceptable RAM/DSP inference.
- Existing regression fails before or after an integration change.
- Block Design validation reports an error.
- The agreed DMA width, DRE setting, TLAST behavior, or reset topology would need
  to change.
- A required change would alter the v1.1 external interface.

At a stop condition, preserve logs/reports, identify the first failing stage,
and request a joint decision before modifying RTL or protocol.

## 12. Completion Criteria

The single OP_CONV hardware milestone is complete only when all items below are
true:

- Exact board revision, board part, and FPGA part are recorded without conflict.
- Baseline regression still reports 10 PASS, 0 FAIL.
- OOC and full synthesis complete with reviewed utilization, inference, and
  timing reports.
- Block Design validates and implementation completes without unresolved
  critical warnings.
- Bitstream and XSA are generated from the reviewed design.
- Firmware uses the exported accelerator address and DMA hardware information.
- The physical Zybo is programmed and DMA/accelerator polling completes without
  timeout.
- All 16,384 output bytes match `expected_output.bin`.
- Accelerator reports DONE, ERROR_CODE=ERR_NONE, and IDLE after completion.
- UART log and build artifacts are retained for handoff.

Only after these criteria pass may the project be described as “single OP_CONV
FPGA verified.” ResNet-20 FPGA execution remains a separate milestone.
