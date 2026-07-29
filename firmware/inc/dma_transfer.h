/* AXI DMA MM2S/S2MM wrappers for weight/bias/input/output packets (HW_SW_Interface_v1.1 §6, §7). */
#ifndef DMA_TRANSFER_H
#define DMA_TRANSFER_H

#include <stdint.h>

int dma_init(void);

/* Starts an MM2S (DDR -> accelerator) transfer of byte_count bytes from src_addr; non-blocking. */
int dma_mm2s_transfer(uintptr_t src_addr, uint32_t byte_count);
/* Blocks until the most recent dma_mm2s_transfer() completes. */
int dma_mm2s_wait_complete(void);

/* Arms the S2MM (accelerator -> DDR) receive buffer; must be called before CONTROL.START (§11.1 step 6). */
int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count);
/* Blocks until the S2MM transfer armed by dma_s2mm_prepare() completes. */
int dma_s2mm_wait_complete(void);

/* Halts and resets both DMA channels; used during ABORT recovery (§11.5). */
int dma_halt_reset(void);

#endif /* DMA_TRANSFER_H */
