# Zybo Z7-20 Integration Status

Last updated: 2026-07-31

## Current source of truth

- Board: Zybo Z7-20
- Board part: `digilentinc.com:zybo-z7-20:part0:1.2`
- FPGA part: `xc7z020clg400-1`
- Vivado/Vitis: 2022.2
- PL clock: one 100 MHz domain
- Core: `rtl/top/resnet_accel_top.sv`
- Packaged IP: `jmhwang.local:npu:resnet_accel:1.0`
- Block Design: `zybo_resnet_system`

The repository is a bit-exact single `OP_CONV` baseline for a Zynq ResNet
accelerator. It is not a complete ResNet-20 accelerator.

## Verified milestones

- Core regression: 10 PASS, 0 FAIL
- Full convolution: 16,384 bytes, mismatch 0, 1,435,391 cycles
- OOC timing at 100 MHz: WNS +0.691 ns, TNS 0, 0 failing endpoints
- Phase 3B-1 wrapper smoke/full-vector and IP integrity: PASS
- Phase 3C BD validation, output products, and HDL wrapper: PASS

Full-design synthesis/implementation, bitstream, XSA, Vitis, FSBL, BOOT.BIN,
and physical-board execution have not been performed.

## Wrapper contract

`resnet_accel_ip_wrapper` is a zero-latency single-clock wiring wrapper.

- `S_AXI_CTRL`: AXI4-Lite slave, 7-bit address and 32-bit data
- `S_AXIS_INPUT`: 32-bit AXI4-Stream slave
- `M_AXIS_OUTPUT`: 32-bit AXI4-Stream master
- `aclk`: 100 MHz, associated with all three buses and `aresetn`
- `aresetn`: active-low
- `AWPROT` and `ARPROT` are present and intentionally ignored by the core
- No register, protocol, packet, latency, CDC, or reset-polarity change

## Reproduction

```bash
source /home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh

# Phase 3B-1 package, when needed
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/package_resnet_accel_ip.tcl

# Recreate Phase 3C from a new generated project directory
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/create_zybo_system.tcl

# Reopen and independently validate the existing generated project
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/validate_zybo_system.tcl
```

The create script regenerates the accelerator package automatically when
`build/ip_repo/resnet_accel_1_0/component.xml` is absent. It then updates the IP
catalog, recreates the project, validates the BD, generates all BD output
products, creates the HDL wrapper, and updates compile order. It does not start
synthesis.

Generated paths:

```text
Project: build/vivado_zybo/resnet_accel_zybo/resnet_accel_zybo.xpr
BD:      zybo_resnet_system
Wrapper: build/vivado_zybo/resnet_accel_zybo/resnet_accel_zybo.gen/
         sources_1/bd/zybo_resnet_system/hdl/zybo_resnet_system_wrapper.v
```

## Phase 3C instances and topology

| Instance | VLNV / configuration |
|---|---|
| `processing_system7_0` | `xilinx.com:ip:processing_system7:5.5`, Zybo board preset |
| `axi_dma_0` | `xilinx.com:ip:axi_dma:7.1`, Simple mode |
| `proc_sys_reset_0` | `xilinx.com:ip:proc_sys_reset:5.0` |
| `control_smartconnect` | `xilinx.com:ip:smartconnect:1.0`, 1 SI / 2 MI |
| `memory_smartconnect` | `xilinx.com:ip:smartconnect:1.0`, 2 SI / 1 MI |
| `resnet_accel_0` | `jmhwang.local:npu:resnet_accel:1.0` |

The board preset creates external DDR and FIXED_IO and preserves UART1 and SD0.
M_AXI_GP0, S_AXI_HP0, FCLK_CLK0, and FCLK_RESET0_N are enabled.

Control path:

```text
processing_system7_0/M_AXI_GP0
  -> control_smartconnect/S00_AXI
     -> M00_AXI -> resnet_accel_0/S_AXI_CTRL
     -> M01_AXI -> axi_dma_0/S_AXI_LITE
```

DDR path:

```text
axi_dma_0/M_AXI_MM2S -> memory_smartconnect/S00_AXI
axi_dma_0/M_AXI_S2MM -> memory_smartconnect/S01_AXI
memory_smartconnect/M00_AXI -> processing_system7_0/S_AXI_HP0
```

Streams are direct, with no FIFO, width converter, register slice, or CDC:

```text
axi_dma_0/M_AXIS_MM2S -> resnet_accel_0/S_AXIS_INPUT
resnet_accel_0/M_AXIS_OUTPUT -> axi_dma_0/S_AXIS_S2MM
```

## Clock and reset

`processing_system7_0/FCLK_CLK0` is 100 MHz and drives GP0/HP0 ACLK, both
SmartConnect clocks, DMA `s_axi_lite_aclk`, `m_axi_mm2s_aclk`, and
`m_axi_s2mm_aclk`, accelerator `aclk`, and reset `slowest_sync_clk`.

`FCLK_RESET0_N` connects directly to active-low `ext_reset_in`; no inverter is
used. `proc_sys_reset_0/peripheral_aresetn` drives both SmartConnect `aresetn`
pins, DMA `axi_resetn`, and accelerator `aresetn`. `interconnect_aresetn` is not
used.

## DMA and packet contract

- Scatter-Gather: off
- MM2S/S2MM: enabled
- DRE: off on both channels
- Stream widths: 32 bits
- Memory-map master widths: 32 bits, adapted by SmartConnect to PS7 HP0
- Asynchronous clocks: off
- Interrupt outputs: generated but intentionally unconnected for polling

Input remains three separate MM2S transfers: Weight 432 bytes, Bias 64 bytes,
and Input 3,072 bytes. Output is one 16,384-byte S2MM transfer prepared before
START. Every packet ends with TLAST.

## Address map

| Mapping | Base | High |
|---|---:|---:|
| Accelerator control | `0x43C00000` | `0x43C0FFFF` |
| DMA control | `0x40400000` | `0x4040FFFF` |
| DMA MM2S DDR/Low-OCM | `0x00000000` | `0x3FFFFFFF` |
| DMA S2MM DDR/Low-OCM | `0x00000000` | `0x3FFFFFFF` |

Generated reports:

```text
build/vivado_zybo/reports/board_design_summary.txt
build/vivado_zybo/reports/address_map.txt
build/vivado_zybo/reports/ip_configuration.txt
build/vivado_zybo/reports/interface_connections.txt
```

## Validation result and warnings

`validate_bd_design`, `generate_target all`, `make_wrapper`, and
`update_compile_order` pass. No synthesis run was started.

Observed warnings:

- The requested local board repo has an installed counterpart (`Board 49-151`).
- The Digilent board preset contains four negative DDR DQS-to-clock delay values
  (`PSU-1` through `PSU-4`). The board-preset values were not hand-edited.
- Control SmartConnect low-area mode warns that WRAP bursts are unsupported.
  Firmware control accesses are AXI4-Lite single-beat transactions.
- Generated SmartConnect internals report AXI metadata payload-width adaptation
  (`BD 41-2384`). This is not an external AXIS TDATA width mismatch; direct
  32-bit MM2S/S2MM stream validation passes.

## Phase boundary

The next separately approved task is Phase 3D full-design synthesis and
implementation. Phase 3C success does not imply synthesis, implemented timing,
bitstream, XSA, BOOT.BIN, or physical-board execution success.
