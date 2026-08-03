/* AXI DMA MM2S/S2MM wrappers for weight/bias/input/output packets (HW_SW_Interface_v1.1 §6, §7). */
#ifndef DMA_TRANSFER_H
#define DMA_TRANSFER_H

#include <stdint.h>

#define DMA_OK             0
#define DMA_INVALID_ARG  (-1) /* zero length, or address/length not 4-byte aligned (§6.2) */
#define DMA_SUBMIT_ERROR (-2) /* XAxiDma_SimpleTransfer() rejected the descriptor */
#define DMA_HW_ERROR     (-3) /* DMASR decode/slave/internal/SG error bit latched (§10.3) */
#define DMA_TIMEOUT      (-4) /* channel still Busy with no error after timeout_ms */
#define DMA_RESET_ERROR  (-5) /* XAxiDma_Reset() did not complete within timeout_ms */

int dma_init(void);

/* Starts an MM2S (DDR -> accelerator) transfer of byte_count bytes from src_addr; non-blocking. */
int dma_mm2s_transfer(uintptr_t src_addr, uint32_t byte_count);
/* Blocks until the most recent dma_mm2s_transfer() completes, or byte_count timeout_ms elapses.
 * If last_dmasr is non-NULL, it is set to the last raw DMASR value read for this channel
 * (whatever the outcome — OK, HW error, or timeout), for bring-up diagnostics. */
int dma_mm2s_wait_complete(uint32_t timeout_ms, uint32_t *last_dmasr);

/* Arms the S2MM (accelerator -> DDR) receive buffer; must be called before CONTROL.START (§11.1 step 6). */
int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count);
/* Blocks until the S2MM transfer armed by dma_s2mm_prepare() completes, or timeout_ms elapses.
 * If last_dmasr is non-NULL, it is set to the last raw DMASR value read for this channel
 * (whatever the outcome — OK, HW error, or timeout), for bring-up diagnostics. */
int dma_s2mm_wait_complete(uint32_t timeout_ms, uint32_t *last_dmasr);

/* Halts and resets both DMA channels; used during ABORT recovery (§11.5). */
int dma_halt_reset(void);

#endif /* DMA_TRANSFER_H */
