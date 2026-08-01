/* Minimal stand-in for the real Vitis BSP-generated xparameters.h, used only for host-side
 * -fsyntax-only checks (see VERIFICATION_GUIDE.md). Values confirmed against the real generated
 * header by 황정민 학생, 2026-08-01 -- not for real Vitis builds. */
#ifndef XPARAMETERS_H
#define XPARAMETERS_H

#define XPAR_RESNET_ACCEL_0_BASEADDR 0x43C00000U
#define XPAR_RESNET_ACCEL_0_HIGHADDR 0x43C0FFFFU

#define XPAR_AXIDMA_0_DEVICE_ID 0U
#define XPAR_AXIDMA_0_BASEADDR 0x40400000U
#define XPAR_AXI_DMA_0_HIGHADDR 0x4040FFFFU

#endif /* XPARAMETERS_H */
