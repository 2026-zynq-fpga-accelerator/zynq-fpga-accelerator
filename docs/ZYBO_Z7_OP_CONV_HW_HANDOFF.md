# Zybo Z7-20 단일 OP_CONV 하드웨어 handoff

## 검증 상태

Hardware repository commit은 `798388201f3d0663390c4f7e0db0123e246301db`이며 Vivado 2022.2를 사용했다. RTL simulation, OOC synthesis, IP packaging, block-design validation, implementation, 100 MHz timing closure, DRC, bitstream 및 bitstream 포함 XSA 생성은 PASS했다. 실제 Zybo Z7-20 보드 실행과 firmware/Vitis build는 이 단계에서 수행하지 않았다.

## Hardware platform

- Board: Zybo Z7-20
- Board part: `digilentinc.com:zybo-z7-20:part0:1.2`
- FPGA part: `xc7z020clg400-1`
- PL clock: PS7 `FCLK_CLK0`, 100 MHz (10 ns)
- Reset source: PS7 `FCLK_RESET0_N` -> `proc_sys_reset_0/ext_reset_in`
- Peripheral reset: `proc_sys_reset_0/peripheral_aresetn` (active low)
- Control: PS7 `M_AXI_GP0` -> control SmartConnect -> DMA S_AXI_LITE 및 accelerator AXI4-Lite
- DDR: DMA MM2S/S2MM memory-map masters -> memory SmartConnect -> PS7 `S_AXI_HP0`
- Stream: DMA MM2S -> accelerator S_AXIS; accelerator M_AXIS -> DMA S2MM
- DMA interrupt ports are intentionally unconnected because firmware uses polling.

The reset IP uses `C_EXT_RESET_HIGH=0`, matching the active-low PS7 reset source. Accelerator, DMA, and SmartConnect resets are driven from the synchronized active-low peripheral reset output.

## Address map

| Resource | Base | Range |
|---|---:|---:|
| Accelerator AXI4-Lite | `0x43C00000` | `0x00010000` |
| AXI DMA S_AXI_LITE | `0x40400000` | `0x00010000` |
| DMA MM2S/S2MM DDR window | `0x00000000` | `0x40000000` |

The machine-readable copy is in `vivado/reports/address_map.csv`.

## AXI DMA contract

- Mode: Simple; Scatter-Gather disabled
- MM2S and S2MM enabled
- MM2S/S2MM AXI4-Stream width: 32 bits
- MM2S/S2MM DRE disabled
- Buffer Length Register (`CONFIG.c_sg_length_width`): 23
- Maximum transfer length: 8,388,607 bytes
- Stage-1 output transfer: one 16,384-byte S2MM packet; do not split it as a workaround
- All DDR buffers must be at least 4-byte aligned and all transfer lengths multiples of four

The generated XSA must be used to regenerate the Vitis platform/BSP. Reusing an older BSP can retain `XPAR_AXI_DMA_0_SG_LENGTH_WIDTH=14`; the regenerated `xparameters.h` must report 23 before firmware is built.

## Canonical Stage-1 vector

Use `vectors/full_conv_32x32x3x16/` without regeneration: seed 20260730, input NHWC 32x32x3, weight HWIO 3x3x3x16, output NHWC 32x32x16, stride 1, padding 1, ReLU enabled, M=3, N=2. Packet order is Weight (432 bytes), Bias (64 bytes), then Input (3,072 bytes). Expected output is 16,384 bytes. Exact SHA-256 values are recorded in `vivado/reports/stage1_vector_manifest.txt`.

Each MM2S transfer is a separate AXI4-Stream packet with TLAST on its final beat. Every beat has `TKEEP=4'b1111`. The accelerator output is one packet with TLAST only on the final output beat.

## First board-run sequence

1. Initialize and reset AXI DMA; confirm both channels are halted/idle and no DMA error is pending.
2. Initialize/reset the accelerator and clear prior DONE/ERROR state according to the register contract.
3. Place canonical Weight, Bias, Input, and Expected Output data in 4-byte-aligned DDR buffers.
4. Flush cache lines covering Weight, Bias, and Input.
5. Initialize the 16,384-byte output DDR buffer to a known value and flush it if required by the cache policy.
6. Start the single 16,384-byte S2MM receive before allowing accelerator output.
7. Program accelerator dimensions, stride, padding, ReLU, M=3, and N=2.
8. Issue START and confirm admission through BUSY or ERROR polling.
9. Submit a 432-byte Weight MM2S transfer and wait for MM2S completion/error.
10. Submit a 64-byte Bias MM2S transfer and wait for MM2S completion/error.
11. Submit a 3,072-byte Input MM2S transfer and wait for MM2S completion/error.
12. Poll both DMA channels with a bounded timeout and inspect DMA status/error bits on failure.
13. Poll accelerator BUSY/DONE/ERROR with a bounded timeout; record final STATUS, ERROR_CODE, cycle counter, and debug state.
14. After S2MM completion, invalidate cache lines covering the entire output buffer.
15. Compare all 16,384 output bytes against `expected_output.bin`; print total mismatch count and the first mismatch offset/value.
16. Clear DONE using its W1C operation after results have been captured.
17. On accelerator or DMA error, record both status domains and perform a coordinated DMA/accelerator reset before retrying.

## Deliverables

- Bitstream: `vivado/output/zybo_z7_op_conv.bit`
- Bitstream-included XSA: `vivado/output/zybo_z7_op_conv.xsa`
- Reproducible BD export: `vivado/zybo_z7_op_conv/system_bd_export.tcl`
- Generated wrapper snapshot: `vivado/zybo_z7_op_conv/system_wrapper.v`
- Reports: `vivado/reports/`

The `.bit` and `.xsa` files are delivery artifacts, not evidence that physical-board execution has passed.
