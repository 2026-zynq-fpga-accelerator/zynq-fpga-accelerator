# Zynq FPGA SoC ResNet OP_CONV Accelerator

Current completion level: **bit-exact single OP_CONV RTL, 100 MHz OOC timing,
and Phase 3B-1 wrapper/IP packaging verified**.

This repository implements the HW/SW Interface Specification v1.1 single-layer
`OP_CONV` baseline. It is not a complete ResNet-20 accelerator. Block Design,
full-design implementation, bitstream/XSA, BOOT.BIN, and physical FPGA execution
are not complete.

## Implemented

- Batch `N=1`, NHWC activations, and HWIO weights
- Signed INT8 input/weight, signed INT32 bias/accumulator, signed INT8 output
- Single-MAC sequential 3x3 convolution with stride 1/2 and padding 0/1
- Per-MAC and bias-add INT32 saturation
- M/N sign-symmetric round-to-nearest, ties-away-from-zero requantization
- Optional ReLU and signed INT8 clamp
- 32-bit AXI4-Stream Weight -> Bias -> Input loader and output streamer
- 32-bit AXI4-Lite v1.1 register interface
- Configuration validation/snapshot, FSM, sticky status/error, ABORT, debug
  state, cycle counter, and capacity validation
- Thin packaged-IP wrapper with standard AXI names and AWPROT/ARPROT

## Verified baseline

Environment:

```bash
source /home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh
```

Run the complete core regression:

```bash
scripts/sim/run_regression.sh
```

Current results:

- Official regression: 10 PASS, 0 FAIL
- Directed integration: 49 PASS
- Full 32x32x3 -> 32x32x16 vector: 16,384 bytes, mismatch 0
- Full-vector validator latency: 34 cycles
- Full-vector operation cycle count: 1,435,391
- 100 MHz OOC timing: WNS +0.691 ns, TNS 0 ns, 0 failing endpoints
- OOC resources: 2,174 LUT, 1,993 FF, 3 DSP48E1, 24 RAMB36E1,
  1 RAMB18E1

The deterministic seed-20260730 vector under
`vectors/full_conv_32x32x3x16/` follows v1.1 NHWC/HWIO indexing and arithmetic.

## Phase 3B-1 wrapper/IP verification

Run wrapper smoke and full-vector simulation:

```bash
vivado -mode batch -nolog -nojournal \
  -source scripts/sim/run_wrapper_xsim.tcl
```

Create and validate the user IP:

```bash
vivado -mode batch -nolog -nojournal \
  -source scripts/vivado/package_resnet_accel_ip.tcl
```

Verified package facts:

- VLNV: `jmhwang.local:npu:resnet_accel:1.0`
- `S_AXI_CTRL`: AXI4-Lite slave, 7-bit address, 32-bit data
- `S_AXIS_INPUT`: AXIS slave, `TDATA_NUM_BYTES=4`
- `M_AXIS_OUTPUT`: AXIS master, `TDATA_NUM_BYTES=4`
- `aclk`: 100 MHz metadata, associated with all three buses and `aresetn`
- `aresetn`: active-low
- `ipx::check_integrity`: PASS

Generated package/project products default to ignored paths under `build/`.
See `docs/ZYBO_INTEGRATION.md` for the full wrapper contract and reproduction
record.

## Confirmed target

- Board: Zybo Z7-20
- Board part: `digilentinc.com:zybo-z7-20:part0:1.2`
- FPGA: `xc7z020clg400-1`
- Vivado/Vitis: 2022.2
- PL clock: 100 MHz

## Not yet implemented or verified

- Zybo PS7 + AXI DMA Block Design
- Full-design synthesis, implementation, and implemented timing
- Bitstream and bitstream-included XSA
- Vitis platform/BSP, firmware ELF, FSBL, and BOOT.BIN
- AXI DMA/cache coherency and software timeouts on hardware
- Physical-board UART/DMA/output comparison
- Residual add, projection, GAP, FC, full ResNet-20 scheduler, and end-to-end
  inference

OOC timing must not be reported as final implemented timing, and future BOOT.BIN
generation must not be reported as a successful physical-board run.

## Build policy

Handwritten RTL, testbenches, scripts, documentation, firmware headers, and the
small deterministic verification vector are source artifacts. Vivado/XSim
projects, snapshots, logs, wave databases, packaged-IP output, bitstreams, XSA,
and other reproducible build products are ignored.
