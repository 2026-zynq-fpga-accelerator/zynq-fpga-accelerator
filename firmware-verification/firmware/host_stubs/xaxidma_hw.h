/* Minimal stand-in for the real Xilinx BSP header, used only for host-side -fsyntax-only checks (see VERIFICATION_GUIDE.md). Not for real Vitis builds. */
#ifndef XAXIDMA_HW_H
#define XAXIDMA_HW_H
#include <stdint.h>
#include "xil_io.h"

typedef uint32_t u32;

/* Per-channel register block offsets from the AXI DMA base (matches real xaxidma_hw.h). */
#define XAXIDMA_TX_OFFSET 0x00000000U
#define XAXIDMA_RX_OFFSET 0x00000030U
/* DMACR (channel control register) offset within a channel's block. */
#define XAXIDMA_CR_OFFSET 0x00000000U
/* DMASR (channel status register) offset within a channel's block. */
#define XAXIDMA_SR_OFFSET 0x00000004U
/* DMAIntErr | DMASlvErr | DMADecErr | SGIntErr | SGSlvErr | SGDecErr. */
#define XAXIDMA_ERR_ALL_MASK 0x00000770U

u32 XAxiDma_ReadReg(UINTPTR BaseAddress, u32 RegOffset);

#endif
