# Zynq FPGA SoC ResNet Inference Accelerator

Current completion level: **Single OP_CONV integrated RTL with Vivado XSim verification**.

This repository implements the HW/SW Interface Specification v1.1 single-layer
`OP_CONV` baseline. It has not completed synthesis, implementation, bitstream
generation, FPGA execution, or ResNet-20 end-to-end inference.

## Implemented

- Batch `N=1`, NHWC activation, and HWIO weights
- Signed INT8 input/weight, signed INT32 bias/accumulator, signed INT8 output
- Single-MAC sequential 3x3 convolution
- Stride 1/2 and padding 0/1
- Per-MAC and bias-add INT32 saturation
- M/N sign-symmetric round-to-nearest, ties-away-from-zero requantization
- Optional ReLU and signed INT8 clamp
- 32-bit AXI4-Stream Weight -> Bias -> Input loader and buffered output streamer
- 32-bit AXI4-Lite v1.1 register interface
- Configuration snapshot, controller FSM, sticky status/error, ABORT, debug state,
  cycle counter, and parameterized capacity validation

## Simulation verified

The Vivado environment is:

```bash
source /home/jmhwang/tools/Xilinxe/Vivado/2022.2/settings64.sh
```

Run the complete regression with:

```bash
scripts/sim/run_regression.sh
```

Verified with Icarus, Verilator lint, and Vivado 2022.2 xvlog/xelab/XSim:

- Original 4x4x4 -> 4x4x4 smoke: 64 bytes, mismatch 0
- Scalar saturation, requantization rounding/ties, ReLU, and clamp boundaries
- Signed input/weight, non-zero bias, ReLU disabled, and `N>0`
- Stride 2 and padding 0
- Two consecutive operations
- Non-fatal START/config-write while BUSY behavior
- Capacity and register-byte-count invalid configuration
- Early/missing TLAST and invalid TKEEP fatal behavior with recovery
- ABORT followed by a successful new operation
- Seed 20260730 full 32x32x3 -> 32x32x16 convolution:
  16,384 output bytes, mismatch 0, XSim cycle count 927,486

The deterministic full-size vector is generated independently by
`scripts/vector_gen/generate_full_conv_vector.py` from the v1.1 NHWC/HWIO
indexing and arithmetic rules.

## Not yet verified

- Accumulator saturation inside a complete convolution with deliberately
  overflowing tensors
- Invalid AXI-Lite address and partial-WSTRB corner cases
- Output backpressure across every newly added directed case
- Synthesis, timing, and inferred BRAM/DSP resources
- AXI DMA/cache coherency and software timeouts on hardware

## Not yet implemented

- Vivado Block Design, packaged IP, board constraints, bitstream, and XSA
- Zynq firmware integration and physical FPGA execution
- PL residual add, projection shortcut, pooling, GAP, and FC
- ResNet-20 scheduler and end-to-end inference
- Interrupts, multiple MAC lanes, and DMA double buffering

## Reference documents

Approved source documents belong under `docs/reference/`. The current checkout
contains only the placeholder in that directory; do not change the external
interface without adding and approving the v1.1 source document.

## Synthesis preparation

After the board part is confirmed, out-of-context synthesis can be invoked as:

```bash
vivado -mode batch \
  -source scripts/vivado/synth_ooc.tcl \
  -tclargs <FPGA_PART> <CLK_PERIOD_NS>
```

The script rejects missing arguments. No FPGA part is hardcoded, and synthesis
has not been run in the current project state.

## Build policy

Handwritten RTL, testbenches, scripts, documentation, firmware headers, and the
small deterministic verification vector are source artifacts. Vivado/XSim
projects, snapshots, logs, wave databases, and other reproducible build products
are ignored.
