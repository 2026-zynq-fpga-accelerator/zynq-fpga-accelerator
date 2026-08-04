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
- Phase 3D-1 synthesis, route, and controlled timing closure: PASS at 100 MHz
- Phase 3D-2 official run bitstream and bitstream-included XSA: PASS

The hardware build through the official implementation-run bitstream and
bitstream-included XSA is complete. Vitis, firmware ELF, FSBL, BOOT.BIN, and
physical-board execution have not been performed.

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

# Phase 3D-1 synthesis, implementation through route_design, and reports
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/build_zybo_implementation.tcl

# Phase 3D-2 official PASS-run bitstream and bitstream-included XSA
vivado -mode batch -notrace \
  -log build/vivado_zybo/reports/generate_bitstream_xsa.log \
  -journal build/vivado_zybo/reports/generate_bitstream_xsa.jou \
  -source scripts/vivado/generate_bitstream_xsa.tcl
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

## Phase 3D-1 synthesis and implementation result

A clean rebuild ran the package, BD creation, and implementation scripts in
that order. Full-design synthesis completed with no errors or critical
warnings. Implementation completed through `route_design`; `phys_opt_design`
was enabled and executed. The design is fully routed with zero routing errors,
zero black boxes, and zero DRC errors.

The baseline `Vivado Implementation Defaults` run failed the strict 100 MHz
acceptance gate:

| Check | Result |
|---|---:|
| Setup WNS / TNS | `-0.258 ns` / `-0.715 ns` |
| Setup failing endpoints | 5 |
| Hold WHS / THS | `+0.050 ns` / `0.000 ns` |
| Hold failing endpoints | 0 |
| Pulse-width failing endpoints | 0 |
| No-clock registers | 0 |
| Unconstrained internal endpoints | 0 |
| DRC errors / unrouted nets | 0 / 0 |

The worst setup path is entirely inside the accelerator, from
`u_buffers/weight_mem_reg_15/CLKBWRCLK` to
`u_conv_engine/mac_product_q_reg[12]/D`. Its data-path delay is `9.947 ns`
(`5.009 ns` logic, `4.938 ns` routing) over eight logic levels. This is not a
SmartConnect, DMA, PS, or CDC path. The worst hold path is inside AXI DMA and
meets timing with `+0.050 ns`.

There is exactly one implemented clock, `clk_fpga_0`, at `10.000 ns`. The CDC
report says all paths are safely timed. `FCLK_RESET0_N` and
`peripheral_aresetn` connectivity remains the validated Phase 3C topology; no
clock/reset RTL or BD change was made. The highest-fanout reset-related net is
the accelerator's internal `aresetn_0` (fanout 1,366); its worst slack is
`+2.180 ns`. No reset-related DRC, methodology, CDC, or timing failure appears.

Post-route utilization:

| Resource | Used | Device utilization |
|---|---:|---:|
| Slice LUTs | 6,087 | 11.44% |
| LUT as Logic | 5,521 | 10.38% |
| LUT as Memory | 566 | 3.25% |
| Slice Registers | 7,620 | 7.16% |
| RAMB36/FIFO | 26 | 18.57% |
| RAMB18 | 1 | 0.36% |
| DSP48E1 | 3 | 1.36% |
| BUFGCTRL | 1 | 3.13% |
| MMCM / PLL | 0 / 0 | 0% / 0% |

The accelerator hierarchy retains 24 RAMB36E1, one RAMB18E1, three DSP48E1,
and zero LUTRAM/SRL cells. The two additional RAMB36E1 blocks belong to AXI
DMA. Implementation DRC reports nine non-error findings: six DSP pipelining
warnings in the accelerator, one no-routable-load warning in generated
SmartConnect logic, and two AXI DMA BRAM write-first advisories. Methodology
reports zero violations.

Generated evidence is under `build/vivado_zybo/reports/`, including
`implementation_summary.txt`, post-synthesis/post-route timing and utilization,
hierarchical utilization, DRC, methodology, route status, clock utilization,
clock interaction, CDC, high-fanout, and worst setup/hold path reports.

### Controlled timing closure

The same `synth_1` checkpoint was compared with no RTL, BD, constraint, clock,
address, or floorplan change. `Performance_Explore` improved WNS to
`-0.115 ns`; `Performance_ExplorePostRoutePhysOpt` then ran post-route
`phys_opt_design -directive Explore` and closed timing:

| Check | Final result |
|---|---:|
| Setup WNS / TNS / failing endpoints | `+0.018 ns` / `0.000 ns` / 0 |
| Hold WHS / THS / failing endpoints | `+0.051 ns` / `0.000 ns` / 0 |
| Pulse-width failing endpoints | 0 |
| DRC errors / unrouted nets | 0 / 0 |
| No-clock / unconstrained internal endpoints | 0 / 0 |

The final run retains 24 accelerator RAMB36E1, one RAMB18E1, three DSP48E1,
and zero LUTRAM/SRL cells. Physical optimization automatically replicated the
PS7 clock BUFG, increasing BUFGCTRL use from one to two and producing one
non-error `PLBUFGOPT-1` warning; source clock configuration remains unchanged.
Full comparison evidence is in
`build/vivado_zybo/reports/timing_strategy_comparison.txt`.

## Phase 3D-2 bitstream and hardware handoff

The official `write_bitstream` step completed on
`impl_performance_postroute_physopt`. All implementation DCPs and the
place/route/post-route-phys-opt completion markers retained identical sizes,
timestamps, and SHA-256 values, confirming that no implementation stage was
rerun. Timing remained WNS `+0.018 ns`, TNS `0`, WHS `+0.051 ns`, with zero
failing endpoints, DRC errors, unrouted nets, no-clock registers, or
unconstrained internal endpoints.

Generated hardware artifacts:

```text
build/vivado_zybo/artifacts/zybo_resnet_system.bit
build/vivado_zybo/artifacts/zybo_resnet_system.xsa
```

The XSA is a valid archive containing the official bitstream, PS7
initialization files, system hardware handoff metadata, both SmartConnect HWH
files, and the validated accelerator and AXI DMA instances. Artifact sizes,
SHA-256 values, run-state transitions, and archive validation evidence are in
`build/vivado_zybo/reports/bitstream_xsa_manifest.txt`.

This completes the hardware build and permits Phase 3E Vitis work to begin.
It does not indicate that a firmware ELF, FSBL, BOOT.BIN, or physical-board
test has completed.

## Phase boundary

Phase 3D-2 hardware build and handoff are complete. The next separately
approved phase is Phase 3E Vitis platform and firmware work. No Vitis workspace,
firmware ELF, FSBL, BOOT.BIN, or physical-board result has been generated.
