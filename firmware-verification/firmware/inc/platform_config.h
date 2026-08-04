/* Board/Vivado-integration constants.
 *
 * Target board: Digilent Zybo Z7-20, part XC7Z020-1CLG400C.
 *
 * PL clock/reset (RTL/testbench already built to match):
 *   - PL fabric clock: PS7 FCLK_CLK0 = 100 MHz
 *   - Reset: PS7 FCLK_RESET0_N (active-low) -> Processor System Reset IP
 *     -> peripheral_aresetn -> accelerator ARESETN (active-low throughout,
 *     no polarity conversion needed)
 *
 * ACCEL_BASE_ADDR / ACCEL_DMA_DEVICE_ID come from the Vivado block design's
 * generated xparameters.h (2026-08-01). Note the
 * accelerator's IP-level base-address macro is XPAR_RESNET_ACCEL_0_BASEADDR,
 * not XPAR_RESNET_ACCEL_0_S_AXI_CTRL_BASEADDR (that S_AXI_CTRL-suffixed name
 * was never generated for this block design).
 */
#ifndef PLATFORM_CONFIG_H
#define PLATFORM_CONFIG_H

#include "xparameters.h"

#ifndef XPAR_RESNET_ACCEL_0_BASEADDR
#error "BSP does not expose resnet_accel_0 AXI-Lite base (expected XPAR_RESNET_ACCEL_0_BASEADDR)"
#endif
#ifndef ACCEL_BASE_ADDR
#define ACCEL_BASE_ADDR XPAR_RESNET_ACCEL_0_BASEADDR
#endif

#ifndef XPAR_AXIDMA_0_DEVICE_ID
#error "BSP does not expose axi_dma_0 device ID (expected XPAR_AXIDMA_0_DEVICE_ID)"
#endif
#ifndef ACCEL_DMA_DEVICE_ID
#define ACCEL_DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
#endif

#ifndef XPAR_AXIDMA_0_BASEADDR
#error "BSP does not expose axi_dma_0 base address (expected XPAR_AXIDMA_0_BASEADDR)"
#endif

/* Sanity-check against the addresses accel_driver.c/dma_transfer.c's register offsets were
 * audited against (project doc §8). A mismatch here means the block design changed and those
 * offsets must be re-reviewed before trusting this build. */
#if ACCEL_BASE_ADDR != 0x43C00000U
#error "ACCEL_BASE_ADDR no longer matches the audited accelerator base address -- re-verify accel_driver.c register offsets"
#endif

#if XPAR_AXIDMA_0_BASEADDR != 0x40400000U
#error "AXI DMA base address no longer matches the audited value -- re-verify dma_transfer.c"
#endif

/* PL fabric clock (PS7 FCLK_CLK0), for converting ACCEL_REG_CYCLE_COUNT to
 * wall-clock latency in layer/inference timing reports (project doc §8.7). */
#ifndef PL_CLOCK_HZ
#define PL_CLOCK_HZ 100000000U
#endif

#endif /* PLATFORM_CONFIG_H */
