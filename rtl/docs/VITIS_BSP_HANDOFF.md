# Phase 3E-2A Vitis Platform/BSP Handoff

Date: 2026-08-01  
Result: PASS

## Scope

Phase 3E-2A created and built only a Vitis 2022.2 fixed platform and standalone
BSP from the timing-PASS XSA. Firmware source, Stage-1 vectors, application,
ELF, FSBL, and BOOT.BIN were outside scope and were not generated or modified.

## Reproduction command

From the hardware repository:

```bash
/home/jmhwang/tools/Xilinxe/Vitis/2022.2/bin/xsct -nodisp \
  /home/jmhwang/resnet-fpga-accelerator/scripts/vitis/create_platform_bsp.tcl
```

`-nodisp` is required in this WSL environment. Without it, the Vitis launcher
requires the unavailable `xlsclients`/X display support even for XSCT batch
work.

The script refuses to overwrite an existing
`build/vitis/workspace/zybo_resnet_platform` directory. Reproduction therefore
requires a new/empty generated workspace chosen by the operator; the script
does not delete prior output.

## Exact generated platform

| Item | Value |
|---|---|
| Vitis/XSCT | 2022.2.0, SW Build 0 |
| Workspace | `/home/jmhwang/resnet-fpga-accelerator/build/vitis/workspace` |
| Platform | `zybo_resnet_platform` |
| Processor | `ps7_cortexa9_0` |
| Domain | `standalone_ps7_cortexa9_0` |
| OS | `standalone` |
| Architecture | 32-bit ARM Cortex-A9, hard-float |
| Boot BSP | disabled (`-no-boot-bsp`) |

Platform export:

```text
/home/jmhwang/resnet-fpga-accelerator/build/vitis/workspace/zybo_resnet_platform/export/zybo_resnet_platform/zybo_resnet_platform.xpfm
```

Original generated BSP root:

```text
/home/jmhwang/resnet-fpga-accelerator/build/vitis/workspace/zybo_resnet_platform/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp
```

Original generated include directory:

```text
/home/jmhwang/resnet-fpga-accelerator/build/vitis/workspace/zybo_resnet_platform/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/ps7_cortexa9_0/include
```

Generated BSP library:

```text
/home/jmhwang/resnet-fpga-accelerator/build/vitis/workspace/zybo_resnet_platform/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/ps7_cortexa9_0/lib/libxil.a
```

## XSA identity

Input XSA:

```text
/home/jmhwang/resnet-fpga-accelerator/build/vivado_zybo/artifacts/zybo_resnet_system.xsa
```

SHA-256:

```text
01f7f2121b6940064491ae7a25de46f6a4233f1a93ae3547a8ff67ea1b60477b
```

This matches `build/vivado_zybo/reports/bitstream_xsa_manifest.txt`. The input,
platform-internal, and exported XSA copies are byte-identical by SHA-256.

## BSP values relevant to firmware

### Accelerator

```c
#define XPAR_RESNET_ACCEL_0_BASEADDR 0x43C00000
#define XPAR_RESNET_ACCEL_0_HIGHADDR 0x43C0FFFF
```

The proposal's expected
`XPAR_RESNET_ACCEL_0_S_AXI_CTRL_BASEADDR` does not exist. The Phase 3E-2
firmware alias must use `XPAR_RESNET_ACCEL_0_BASEADDR`.

### AXI DMA

```c
#define XPAR_AXIDMA_0_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#define XPAR_AXI_DMA_0_DEVICE_ID 0
#define XPAR_AXIDMA_0_BASEADDR 0x40400000
#define XPAR_AXI_DMA_0_HIGHADDR 0x4040FFFF
#define XPAR_AXIDMA_0_INCLUDE_SG 0
#define XPAR_AXIDMA_0_INCLUDE_MM2S 1
#define XPAR_AXIDMA_0_INCLUDE_S2MM 1
#define XPAR_AXIDMA_0_INCLUDE_MM2S_DRE 0
#define XPAR_AXIDMA_0_INCLUDE_S2MM_DRE 0
#define XPAR_AXIDMA_0_M_AXI_MM2S_DATA_WIDTH 32
#define XPAR_AXIDMA_0_M_AXI_S2MM_DATA_WIDTH 32
```

The DMA is one-instance, Simple Mode, SG off, DRE off, one MM2S channel, and one
S2MM channel. The BSP does not emit a canonical DMA high-address macro, nor
does it emit AXI-Stream TDATA-width macros. The two listed width macros describe
the memory-mapped interfaces; the XSA/HWH remains the evidence for the 32-bit
stream contract.

### CPU and XTime

```c
#define XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ 666666687
#define COUNTS_PER_SECOND (XPAR_CPU_CORTEXA9_CORE_CLOCK_FREQ_HZ /2)

typedef u64 XTime;
void XTime_GetTime(XTime *Xtime_Global);
```

For this BSP, `SLEEP_TIMER_BASEADDR` is absent. `COUNTS_PER_SECOND` therefore
uses the Cortex-A9 global timer and evaluates by integer division to
`333333343` ticks/second. The requested code is usable without modification:

```c
#include "xtime_l.h"

XTime now;
XTime_GetTime(&now);
uint64_t ticks = COUNTS_PER_SECOND;
```

This is not the PL FCLK 100 MHz timebase.

### AXI DMA driver API

Generated driver: `axidma_v9_15`.

```c
#define XAXIDMA_TX_OFFSET        0x00000000
#define XAXIDMA_RX_OFFSET        0x00000030
#define XAXIDMA_CR_OFFSET        0x00000000
#define XAXIDMA_SR_OFFSET        0x00000004
#define XAXIDMA_CR_RESET_MASK    0x00000004
#define XAXIDMA_HALTED_MASK      0x00000001
#define XAXIDMA_IDLE_MASK        0x00000002
#define XAXIDMA_ERR_ALL_MASK     0x00000770
#define XAXIDMA_IRQ_ALL_MASK     0x00007000
```

The `XAxiDma` struct contains public `UINTPTR RegBase`, and the generated
headers provide `XAxiDma_ReadReg`, `XAxiDma_Busy`, `XAxiDma_Reset`, and
`XAxiDma_ResetIsDone`.

The proposed status read is compatible as written:

```c
XAxiDma_ReadReg(
    dma_instance.RegBase,
    channel_offset + XAXIDMA_SR_OFFSET
);

status & XAXIDMA_ERR_ALL_MASK
```

Overall patch proposal compatibility is PASS after replacing the accelerator
base macro name and using the peripheral-specific DMA high-address macro where
needed.

## Handoff files

Generated/reference-only copies under `build/vitis/handoff/`:

- `xparameters.h`
- `xtime_l.h`
- `xaxidma.h`
- `xaxidma_hw.h`
- `BSP_FIRMWARE_VALUES.md`

Header SHA-256 values and the complete macro/API analysis are recorded in
`build/vitis/handoff/BSP_FIRMWARE_VALUES.md`. The copied headers are not firmware
source and were not edited.

## Warnings and observations

- Launching XSCT without `-nodisp` failed because `xlsclients` is unavailable;
  the official batch option resolved it.
- The BSP compiler emitted an informational pragma saying sleep routines use
  the global timer.
- Platform export wrote a boot `.bif` metadata file. Because the platform was
  created with `-no-boot-bsp`, no boot BSP, FSBL project, FSBL ELF, or BOOT.BIN
  was generated.
- No Vitis build error was observed.

## Acceptance

| Check | Result |
|---|---|
| XSA hash matches existing manifest | PASS |
| Platform creation | PASS |
| `ps7_cortexa9_0` processor resolved | PASS |
| `standalone_ps7_cortexa9_0` domain creation | PASS |
| BSP generation/build and `libxil.a` | PASS |
| `xparameters.h` present | PASS |
| Accelerator address `0x43C00000-0x43C0FFFF` | PASS |
| DMA address `0x40400000-0x4040FFFF`, device ID 0 | PASS |
| Simple mode, SG off, DRE off, MM2S/S2MM on | PASS |
| `XTime_GetTime()` and `COUNTS_PER_SECOND` | PASS |
| AXI DMA offsets/error/reset APIs | PASS |
| Handoff header copies and hashes | PASS |
| Firmware repository unchanged | PASS |
| Hardware RTL/BD/XSA unchanged | PASS |
| Application ELF/FSBL/BOOT.BIN absent | PASS |

No stop condition was triggered during platform/BSP creation or header
analysis. Phase 3E-2A stops here as required.
