# Zybo Z7-20 Integration Status

Last updated: 2026-07-31

## Current source of truth

- Board: Zybo Z7-20
- Board part: `digilentinc.com:zybo-z7-20:part0:1.2`
- FPGA part: `xc7z020clg400-1`
- Vivado/Vitis: 2022.2
- PL clock target: 100 MHz
- Core top: `rtl/top/resnet_accel_top.sv`
- Packaged top: `rtl/integration/resnet_accel_ip_wrapper.sv`
- VLNV: `jmhwang.local:npu:resnet_accel:1.0`

The project is a bit-exact single `OP_CONV` RTL baseline for a Zynq ResNet
accelerator. It is not a complete ResNet-20 accelerator.

## Verified milestones

Core RTL verification and OOC synthesis are complete:

- Official regression: 10 PASS, 0 FAIL
- Full convolution: 16,384 output bytes, mismatch 0
- Full-convolution validator latency: 34 cycles
- Full-convolution operation count: 1,435,391 cycles
- 100 MHz OOC timing: WNS +0.691 ns, TNS 0 ns, failing endpoints 0
- OOC resources: 2,174 LUT, 1,993 FF, 3 DSP48E1, 24 RAMB36E1,
  1 RAMB18E1

Phase 3B-1 is verified:

- Thin wrapper compile and elaboration PASS
- Wrapper smoke simulation: 64 bytes, mismatch 0
- Wrapper full-vector simulation: 16,384 bytes, mismatch 0,
  1,435,391 cycles
- Tcl-based IP packaging PASS
- `ipx::check_integrity` PASS
- One AXI4-Lite slave, one AXIS slave, one AXIS master, one clock, and one
  active-low reset are explicitly mapped

Block Design, full-design synthesis/implementation, bitstream, XSA, Vitis,
FSBL, BOOT.BIN, and physical-board execution have not been performed.

## Wrapper contract

`resnet_accel_ip_wrapper` is a zero-latency, single-clock wiring wrapper around
`resnet_accel_top`.

- `S_AXI_CTRL`: AXI4-Lite slave, 7-bit address and 32-bit data
- `S_AXIS_INPUT`: 32-bit AXI4-Stream slave
- `M_AXIS_OUTPUT`: 32-bit AXI4-Stream master
- `aclk`: 100 MHz, associated with all three buses and `aresetn`
- `aresetn`: active-low
- `AWPROT` and `ARPROT` exist at the wrapper boundary and are intentionally
  ignored by the unchanged v1.1 core
- No register, latency, CDC, reset polarity, stream width, or packet change

The AXI4-Lite address block is 128 bytes (`0x00` through `0x7f`). Existing
register offsets through `0x44` are unchanged.

## Reproduction

Load the tool environment:

```bash
source /home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh
```

Run the unchanged core regression:

```bash
scripts/sim/run_regression.sh
```

Run wrapper smoke and full-vector simulations:

```bash
vivado -mode batch -nolog -nojournal \
  -source scripts/sim/run_wrapper_xsim.tcl
```

Create and validate the packaged IP:

```bash
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/package_resnet_accel_ip.tcl
```

The package defaults to:

```text
build/ip_repo/resnet_accel_1_0/component.xml
```

An alternate generated IP root below `build/` may be passed as one Tcl argument. All default
project and packaged-IP products remain under ignored `build/` paths.

## DMA packet contract for Phase 3C

AXI DMA remains Simple mode with SG, DRE, and interrupts disabled. Streams are
32 bits. The input packets must be three separate MM2S transfers:

| Order | Payload | Bytes |
|---:|---|---:|
| 1 | Weight (HWIO INT8) | 432 |
| 2 | Bias (signed INT32 little-endian) | 64 |
| 3 | Input (NHWC INT8) | 3,072 |

Prepare one 16,384-byte S2MM transfer before START. Each MM2S packet and the
output packet terminate with TLAST. Full-word beats use `TKEEP=4'b1111`.

## Phase boundary

The next separately approved task is Phase 3C Block Design. Do not describe OOC
timing as implemented-design timing, IP packaging as a completed Block Design,
or a future BOOT.BIN as physical-board execution.
