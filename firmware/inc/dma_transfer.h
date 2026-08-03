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

/* One-time facts about the AXI DMA instance, captured at dma_init() and unchanging afterwards.
 * Added for bring-up diagnostics (정민님 요청, 2026-08-03) after S2MM_PREPARE started failing
 * before the accelerator was ever started (START_written=0, BUSY_ever=0) — this rules out (or
 * confirms) a bad XAxiDma_CfgInitialize()/Config mismatch as the cause, independent of any
 * specific transfer. Log once right after a successful dma_init(), not per layer run. */
typedef struct {
    int cfginit_status;   /* raw XAxiDma_CfgInitialize() return value */
    uintptr_t reg_base;   /* AXI DMA instance's register base address */
    int has_sg;
    int has_mm2s;
    int has_mm2s_dre;    /* captured from XAxiDma_Config at dma_init(); not an XAxiDma instance field */
    int has_s2mm;
    int has_s2mm_dre;    /* captured from XAxiDma_Config at dma_init(); not an XAxiDma instance field */
    uint32_t mm2s_data_width;   /* TxBdRing.DataWidth, populated by XAxiDma_CfgInitialize() */
    uint32_t s2mm_data_width;   /* RxBdRing[0].DataWidth, populated by XAxiDma_CfgInitialize();
                                 * XAxiDma_SimpleTransfer() requires buffers aligned to this value
                                 * minus one when DRE is absent - if this reads 32 instead of 4,
                                 * a 4-byte-aligned buffer is not enough. */
} dma_static_diag_t;

/* Per-call diagnostics for dma_s2mm_prepare(), filled in regardless of outcome (정민님 요청,
 * 2026-08-03) so a S2MM_PREPARE failure (e.g. ACCEL_REG_OUTPUT_BYTES reading back as 0, or the
 * S2MM channel not accepting XAxiDma_SimpleTransfer()) can be root-caused from one UART log
 * instead of needing another board round-trip. */
typedef struct {
    uintptr_t dst_addr;
    uint32_t byte_count;
    int buffer_is_valid;          /* dma_buffer_is_valid(dst_addr, byte_count) result */
    int busy_before;              /* XAxiDma_Busy(..., DEVICE_TO_DMA), sampled before submit */
    uint32_t dmacr_before;
    uint32_t dmasr_before;
    uint32_t dmacr_after;
    uint32_t dmasr_after;
    int simple_transfer_status;   /* raw XAxiDma_SimpleTransfer() return value */
} dma_s2mm_prepare_diag_t;

int dma_init(void);
/* Fills *out with facts captured during dma_init(); only meaningful after dma_init() succeeds. */
void dma_get_static_diag(dma_static_diag_t *out);

/* Starts an MM2S (DDR -> accelerator) transfer of byte_count bytes from src_addr; non-blocking. */
int dma_mm2s_transfer(uintptr_t src_addr, uint32_t byte_count);
/* Blocks until the most recent dma_mm2s_transfer() completes, or byte_count timeout_ms elapses.
 * If last_dmasr is non-NULL, it is set to the last raw DMASR value read for this channel
 * (whatever the outcome — OK, HW error, or timeout), for bring-up diagnostics. */
int dma_mm2s_wait_complete(uint32_t timeout_ms, uint32_t *last_dmasr);

/* Arms the S2MM (accelerator -> DDR) receive buffer; must be called before CONTROL.START (§11.1 step 6).
 * diag, if non-NULL, is always filled in (even on failure) with the bring-up diagnostics above. */
int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count, dma_s2mm_prepare_diag_t *diag);
/* Blocks until the S2MM transfer armed by dma_s2mm_prepare() completes, or timeout_ms elapses.
 * If last_dmasr is non-NULL, it is set to the last raw DMASR value read for this channel
 * (whatever the outcome — OK, HW error, or timeout), for bring-up diagnostics. */
int dma_s2mm_wait_complete(uint32_t timeout_ms, uint32_t *last_dmasr);

/* Halts and resets both DMA channels; used during ABORT recovery (§11.5). */
int dma_halt_reset(void);

#endif /* DMA_TRANSFER_H */
