# Zybo Z7-20 Single OP_CONV Integration Plan

Status: RTL/OOC, Phase 3B-1 wrapper/IP packaging, and Phase 3C Block Design
validation/output products are complete. Phase 3D synthesis has not started.

## 1. Confirmed baseline

- Board: Zybo Z7-20
- Board part: `digilentinc.com:zybo-z7-20:part0:1.2`
- FPGA: `xc7z020clg400-1`
- Vivado/Vitis: 2022.2
- Clock: one 100 MHz PL domain
- Core: `resnet_accel_top`
- Packaged IP: `jmhwang.local:npu:resnet_accel:1.0`
- BD: `zybo_resnet_system`

This is a single 3x3 `OP_CONV`, not complete ResNet-20 inference. Residual add,
GAP, FC, CPU fallback, and full-network scheduling remain outside the current
milestone.

## 2. Verification evidence

- Official core regression: 10 PASS, 0 FAIL
- Full vector: 16,384 bytes, mismatch 0, 1,435,391 cycles
- OOC timing at 100 MHz: WNS +0.691 ns, TNS 0, 0 failing endpoints
- Wrapper smoke/full vector and packaged-IP integrity: PASS
- Phase 3C full Tcl recreation: PASS
- `validate_bd_design`: PASS
- `generate_target all`: PASS
- HDL wrapper and compile-order update: PASS
- Synthesis run started: no

OOC timing is not full-design implemented timing, and BD validation is not FPGA
execution.

## 3. Stable interface and packet contract

- `S_AXI_CTRL`: AXI4-Lite slave, address/data widths 7/32
- `S_AXIS_INPUT`: AXIS slave, 32-bit TDATA with TKEEP/TLAST/TVALID/TREADY
- `M_AXIS_OUTPUT`: AXIS master, 32-bit TDATA with TKEEP/TLAST/TVALID/TREADY
- `aclk`: 100 MHz and associated with all three buses
- `aresetn`: active-low

The wrapper and core register/packet protocols are unchanged.

Input is three separate DMA MM2S transfers:

1. Weight: 432 bytes
2. Bias: 64 bytes
3. Input: 3,072 bytes

Output is one 16,384-byte S2MM transfer prepared before START. DRE is disabled,
so addresses and lengths must be at least 4-byte aligned. Firmware must flush
MM2S sources and invalidate the S2MM destination.

## 4. Validated Block Design (Phase 3C)

Project:

```text
build/vivado_zybo/resnet_accel_zybo/resnet_accel_zybo.xpr
```

Control topology:

```text
PS7 M_AXI_GP0
  -> control_smartconnect (1 SI / 2 MI)
     -> resnet_accel_0/S_AXI_CTRL
     -> axi_dma_0/S_AXI_LITE
```

DDR topology:

```text
axi_dma_0/M_AXI_MM2S -> memory_smartconnect/S00_AXI
axi_dma_0/M_AXI_S2MM -> memory_smartconnect/S01_AXI
memory_smartconnect/M00_AXI -> PS7 S_AXI_HP0
```

Direct streams:

```text
axi_dma_0/M_AXIS_MM2S -> resnet_accel_0/S_AXIS_INPUT
resnet_accel_0/M_AXIS_OUTPUT -> axi_dma_0/S_AXIS_S2MM
```

No FIFO, width converter, register slice, clock converter, or CDC was added.

AXI DMA is Simple mode with SG and DRE disabled, MM2S/S2MM enabled, and 32-bit
stream and memory masters. SmartConnect adapts the 32-bit memory masters to HP0.
The generated DMA interrupt outputs remain unconnected for polling.

## 5. Clock, reset, and board preset

The Zybo Z7-20 board preset creates DDR/FIXED_IO and retains UART1 and SD0.
M_AXI_GP0, S_AXI_HP0, FCLK_CLK0, and FCLK_RESET0_N are enabled.

FCLK_CLK0 at 100 MHz is the only PL clock and drives every control, memory,
stream-related DMA clock, accelerator clock, SmartConnect clock, GP0/HP0 ACLK,
and reset synchronizer clock.

```text
FCLK_RESET0_N -> proc_sys_reset_0/ext_reset_in (active-low)
proc_sys_reset_0/peripheral_aresetn
  -> accelerator aresetn
  -> DMA axi_resetn
  -> both SmartConnect aresetn pins
```

No inverter is present. `interconnect_aresetn` is unused.

## 6. Address map

```text
AXI DMA control:      0x40400000 - 0x4040FFFF
Accelerator control:  0x43C00000 - 0x43C0FFFF
DMA MM2S DDR/Low-OCM: 0x00000000 - 0x3FFFFFFF
DMA S2MM DDR/Low-OCM: 0x00000000 - 0x3FFFFFFF
```

No address overlap was reported.

## 7. Reproduction and reports

```bash
source /home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/create_zybo_system.tcl
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/validate_zybo_system.tcl
```

Reports are regenerated under `build/vivado_zybo/reports/`:

- `board_design_summary.txt`
- `address_map.txt`
- `ip_configuration.txt`
- `interface_connections.txt`

Known warnings are the local/installed board counterpart, four board-preset DDR
DQS delay warnings, control SmartConnect low-area WRAP guidance, and generated
SmartConnect internal AXI metadata payload adaptation. External 32-bit AXIS
validation passes and no BD validation error occurred.

## 8. Remaining phases

### Phase 3D - Full hardware build

Generate/review full synthesis and implementation reports, verify setup/hold and
reset/CDC behavior, then generate bitstream and bitstream-included XSA only after
review. None of these actions has started.

### Phase 3E - Firmware and boot image

Create the Vitis platform/BSP, replace hardware identifiers from
`xparameters.h`, build the firmware ELF and FSBL, and generate BOOT.BIN.
BOOT.BIN generation will not prove physical-board execution.

### Physical-board acceptance

Boot from SD, capture UART, initialize DMA, read accelerator VERSION, execute the
three MM2S transfers and one S2MM transfer, poll BUSY/ERROR correctly, and compare
all 16,384 output bytes.

## 9. Stop conditions

Stop before changing core/package interfaces or DMA/reset topology. Also stop on
regression failure, IP integrity failure, BD validation error, address conflict,
external stream-width mismatch, CDC requirement, required interrupt connection,
or any need for an unplanned IP.

The next separately approved step is Phase 3D synthesis/implementation.
