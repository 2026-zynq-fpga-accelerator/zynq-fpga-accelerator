/* Board/Vivado-integration constants.
 *
 * ACCEL_BASE_ADDR and the AXI DMA device ID depend on the Zynq PS-PL Vivado
 * block design (황정민 학생 담당) and are not knowable until that block design
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

#endif /* PLATFORM_CONFIG_H */
