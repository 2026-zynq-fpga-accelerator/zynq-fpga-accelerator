/* Board/Vivado-integration constants.
 *
 * Target board: Digilent Zybo Z7-20, part XC7Z020-1CLG400C.
 *
 * PL clock/reset (agreed with 황정민 학생, RTL/testbench already built to match):
 *   - PL fabric clock: PS7 FCLK_CLK0 = 100 MHz
 *   - Reset: PS7 FCLK_RESET0_N (active-low) -> Processor System Reset IP
 *     -> peripheral_aresetn -> accelerator ARESETN (active-low throughout,
 *     no polarity conversion needed)
 *
 * ACCEL_BASE_ADDR and the AXI DMA device ID depend on the Zynq PS-PL Vivado
 * block design and are not knowable until that block design
 * exports xparameters.h. Until then this placeholder lets the driver code
 * compile and be unit-testable; update the values below (or replace them
 * with the generated XPAR_* macros) once the block design is integrated
 * (project doc §9 step 8).
 */
#ifndef PLATFORM_CONFIG_H
#define PLATFORM_CONFIG_H

#ifndef ACCEL_BASE_ADDR
#define ACCEL_BASE_ADDR 0x43C00000U /* placeholder AXI4-Lite base address */
#endif

#ifndef ACCEL_DMA_DEVICE_ID
#define ACCEL_DMA_DEVICE_ID 0U /* placeholder XPAR_AXIDMA_*_DEVICE_ID */
#endif

/* PL fabric clock (PS7 FCLK_CLK0), for converting ACCEL_REG_CYCLE_COUNT to
 * wall-clock latency in layer/inference timing reports (project doc §8.7). */
#ifndef PL_CLOCK_HZ
#define PL_CLOCK_HZ 100000000U
#endif

#endif /* PLATFORM_CONFIG_H */
