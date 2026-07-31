# Zybo Z7-20 Single OP_CONV Integration Plan

Status: RTL/OOC and Phase 3B-1 wrapper/IP packaging complete. Phase 3C Block
Design has not started.

## 1. Confirmed baseline

- Board: Zybo Z7-20
- Board part: `digilentinc.com:zybo-z7-20:part0:1.2`
- FPGA: `xc7z020clg400-1`
- Vivado/Vitis: 2022.2
- Clock: one 100 MHz PL domain
- Core: `resnet_accel_top`
- Packaged IP: `jmhwang.local:npu:resnet_accel:1.0`

The verified baseline is a single 3x3 `OP_CONV`, not complete ResNet-20
inference. Residual add, GAP, FC, CPU fallback, and full-network scheduling are
outside the current milestone.

## 2. Verification evidence

- Official regression: 10 PASS, 0 FAIL
- Full vector: 32x32x3 to 32x32x16, 16,384 bytes, mismatch 0
- Validator latency: 34 cycles for the full vector
- Operation cycle count: 1,435,391
- OOC timing at 100 MHz: WNS +0.691 ns, TNS 0 ns, 0 failing endpoints
- Wrapper smoke: 64 bytes, mismatch 0
- Wrapper full vector: 16,384 bytes, mismatch 0, 1,435,391 cycles
- Packaged-IP integrity and explicit interface checks: PASS

OOC timing is not full-design implemented timing, and simulation is not FPGA
execution.

## 3. Stable interface and packet contract

The wrapper adds standard AXI names and `AWPROT`/`ARPROT`; protection inputs are
ignored by the unchanged core. It adds no register, latency, CDC, or reset logic.

- `S_AXI_CTRL`: AXI4-Lite slave, address/data widths 7/32
- `S_AXIS_INPUT`: AXIS slave, 32-bit TDATA, TKEEP/TLAST/TVALID/TREADY
- `M_AXIS_OUTPUT`: AXIS master, 32-bit TDATA, TKEEP/TLAST/TVALID/TREADY
- `aclk`: 100 MHz and associated with all three buses
- `aresetn`: active-low and associated with `aclk`

Input is three separate DMA MM2S transfers in this order:

1. Weight: 432 bytes
2. Bias: 64 bytes
3. Input: 3,072 bytes

Output is one 16,384-byte S2MM transfer prepared before START. Do not combine
the three input packets. DRE is disabled, so addresses and lengths are at least
4-byte aligned. Firmware must flush MM2S source ranges and invalidate the S2MM
output range.

## 4. Planned Block Design (Phase 3C)

```text
PS7 M_AXI_GP0
  -> AXI interconnect/SmartConnect
     -> Accelerator S_AXI_CTRL
     -> AXI DMA S_AXI_LITE

AXI DMA M_AXI_MM2S + M_AXI_S2MM
  -> AXI interconnect/SmartConnect
     -> PS7 S_AXI_HP0

AXI DMA M_AXIS_MM2S -> Accelerator S_AXIS_INPUT
Accelerator M_AXIS_OUTPUT -> AXI DMA S_AXIS_S2MM
```

Configure AXI DMA in Simple mode with Scatter-Gather, DRE, and interrupts
disabled. MM2S and S2MM stream widths are 32 bits. Use PS7 FCLK_CLK0 at 100 MHz
for accelerator, DMA, interconnect, and Processor System Reset.

Reset intent:

```text
PS7 FCLK_CLK0 -> proc_sys_reset/slowest_sync_clk
PS7 FCLK_RESET0_N -> proc_sys_reset/ext_reset_in (ACTIVE_LOW)
proc_sys_reset/peripheral_aresetn -> accelerator/DMA/interconnect
```

Do not insert a reset inverter when `ext_reset_in` is configured active-low.

## 5. Remaining phases

### Phase 3C - Block Design

Create the PS7/DMA/interconnect/reset design by Tcl, assign addresses, and run
Validate Design. Stop on any validation error.

### Phase 3D - Hardware build

Generate output products and HDL wrapper, synthesize, implement, review timing,
then generate bitstream and an XSA that includes it. Do not infer implementation
success from the existing OOC result.

### Phase 3E - Firmware and boot image

Create the Vitis platform/BSP, replace accelerator and DMA placeholders from
`xparameters.h`, build the application and FSBL, and generate BOOT.BIN.
BOOT.BIN generation does not prove physical-board execution.

### Physical-board acceptance

Boot from SD, capture UART, initialize DMA, read accelerator VERSION, execute the
three MM2S transfers and one S2MM transfer, poll BUSY/ERROR correctly, and compare
all 16,384 output bytes. The target success line is:

```text
STAGE1 OP_CONV FPGA PASS: 16384 bytes, mismatch=0
```

## 6. Stop conditions

Stop and report before changing the verified core if any phase requires a
register-map, packet, reset-polarity, datapath-cycle, stream-width, clock-domain,
CDC, controller, or AXI DMA contract change. Also stop on regression failure,
IP integrity failure, Block Design validation errors, or board/part conflicts.

See `docs/ZYBO_INTEGRATION.md` for Phase 3B-1 commands and package metadata.
