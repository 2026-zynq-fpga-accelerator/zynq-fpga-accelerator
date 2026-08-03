/* AXI DMA MM2S/S2MM wrappers, simple (non-SG) transfer mode, 32-bit stream (HW_SW_Interface_v1.1 §6). */
#include "dma_transfer.h"

#include <stddef.h>

#include "platform_config.h"
#include "platform_time.h"

#include "xaxidma.h"
#include "xaxidma_hw.h"
#include "xil_cache.h"

static XAxiDma dma_instance;

/* Active S2MM destination, retained only after a successful submit so completion can re-invalidate
 * the exact range once DMA has finished writing DDR (§11.1 steps 18-20). */
static uintptr_t s2mm_dst_addr;
static uint32_t s2mm_byte_count;
static int s2mm_active;

/* Captured once in dma_init(); see dma_static_diag_t. */
static int g_cfginit_status = -1;
/* DRE capability flags exist on XAxiDma_Config (pre-init) but are not surfaced as top-level
 * XAxiDma instance members post-init (they end up in the internal Tx/Rx BD ring instead), so
 * they must be captured from config while it's still in scope. */
static int g_has_mm2s_dre;
static int g_has_s2mm_dre;

static int dma_buffer_is_valid(uintptr_t addr, uint32_t byte_count)
{
    return byte_count != 0U &&
           (addr & 0x3U) == 0U &&
           (byte_count & 0x3U) == 0U;
}

/* Polls the given channel's DMASR directly: any latched error bit is fatal, otherwise wait for
 * Busy to clear within timeout_ms (§3, §10.3, §11.1). last_dmasr (if non-NULL) is updated on every
 * poll, so it always holds the most recent raw DMASR read regardless of outcome (bring-up diag,
 * 정민님 요청 — the DMA_HW_ERROR/DMA_TIMEOUT enum alone doesn't show which error bits latched). */
static int dma_wait_channel(int direction, uint32_t timeout_ms, uint32_t *last_dmasr)
{
    const u32 channel_offset = (direction == XAXIDMA_DMA_TO_DEVICE)
        ? XAXIDMA_TX_OFFSET : XAXIDMA_RX_OFFSET;
    XTime start = fw_time_now();

    do {
        u32 status = XAxiDma_ReadReg(
            dma_instance.RegBase, channel_offset + XAXIDMA_SR_OFFSET);
        if (last_dmasr != NULL) {
            *last_dmasr = status;
        }
        if ((status & XAXIDMA_ERR_ALL_MASK) != 0U) {
            return DMA_HW_ERROR;
        }
        if (!XAxiDma_Busy(&dma_instance, direction)) {
            return DMA_OK;
        }
    } while (!fw_time_expired(start, timeout_ms));

    return DMA_TIMEOUT;
}

int dma_init(void)
{
    XAxiDma_Config *config = XAxiDma_LookupConfig(ACCEL_DMA_DEVICE_ID);
    if (config == NULL) {
        return -1;
    }

    g_has_mm2s_dre = config->HasMm2SDRE;
    g_has_s2mm_dre = config->HasS2MmDRE;

    g_cfginit_status = XAxiDma_CfgInitialize(&dma_instance, config);
    if (g_cfginit_status != XST_SUCCESS) {
        return -1;
    }

    if (XAxiDma_HasSg(&dma_instance)) {
        return -1; /* this driver targets simple-DMA mode; §6.2 assumes DRE disabled, no SG needed */
    }

    XAxiDma_IntrDisable(&dma_instance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_instance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    return 0;
}

void dma_get_static_diag(dma_static_diag_t *out)
{
    out->cfginit_status = g_cfginit_status;
    out->reg_base = dma_instance.RegBase;
    out->has_sg = XAxiDma_HasSg(&dma_instance);
    out->has_mm2s = dma_instance.HasMm2S;
    out->has_mm2s_dre = g_has_mm2s_dre;
    out->has_s2mm = dma_instance.HasS2Mm;
    out->has_s2mm_dre = g_has_s2mm_dre;
}

int dma_mm2s_transfer(uintptr_t src_addr, uint32_t byte_count)
{
    if (!dma_buffer_is_valid(src_addr, byte_count)) {
        return DMA_INVALID_ARG;
    }

    /* §6.2: source buffer must be 4-byte aligned, byte_count a multiple of 4. */
    Xil_DCacheFlushRange((UINTPTR)src_addr, byte_count);

    int status = XAxiDma_SimpleTransfer(&dma_instance, (UINTPTR)src_addr, byte_count, XAXIDMA_DMA_TO_DEVICE);
    return (status == XST_SUCCESS) ? DMA_OK : DMA_SUBMIT_ERROR;
}

int dma_mm2s_wait_complete(uint32_t timeout_ms, uint32_t *last_dmasr)
{
    return dma_wait_channel(XAXIDMA_DMA_TO_DEVICE, timeout_ms, last_dmasr);
}

int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count, dma_s2mm_prepare_diag_t *diag)
{
    if (diag != NULL) {
        dma_s2mm_prepare_diag_t zero_diag = {0};
        *diag = zero_diag;
        diag->dst_addr = dst_addr;
        diag->byte_count = byte_count;
    }

    int valid = dma_buffer_is_valid(dst_addr, byte_count);
    if (diag != NULL) {
        diag->buffer_is_valid = valid;
    }
    if (!valid) {
        return DMA_INVALID_ARG;
    }

    /* Must be armed before CONTROL.START so the accelerator's first output beat isn't dropped (§11.1 step 6). */
    Xil_DCacheInvalidateRange((UINTPTR)dst_addr, byte_count);

    if (diag != NULL) {
        diag->busy_before = XAxiDma_Busy(&dma_instance, XAXIDMA_DEVICE_TO_DMA);
        diag->dmacr_before = XAxiDma_ReadReg(dma_instance.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_CR_OFFSET);
        diag->dmasr_before = XAxiDma_ReadReg(dma_instance.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);
    }

    int status = XAxiDma_SimpleTransfer(&dma_instance, (UINTPTR)dst_addr, byte_count, XAXIDMA_DEVICE_TO_DMA);

    if (diag != NULL) {
        diag->simple_transfer_status = status;
        diag->dmacr_after = XAxiDma_ReadReg(dma_instance.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_CR_OFFSET);
        diag->dmasr_after = XAxiDma_ReadReg(dma_instance.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);
    }

    if (status != XST_SUCCESS) {
        return DMA_SUBMIT_ERROR;
    }

    s2mm_dst_addr = dst_addr;
    s2mm_byte_count = byte_count;
    s2mm_active = 1;
    return DMA_OK;
}

int dma_s2mm_wait_complete(uint32_t timeout_ms, uint32_t *last_dmasr)
{
    int rc = dma_wait_channel(XAXIDMA_DEVICE_TO_DMA, timeout_ms, last_dmasr);
    if (rc == DMA_OK && s2mm_active) {
        /* CPU may have speculatively refilled a cache line while DMA wrote DDR; invalidate again
         * so the caller's comparison reads the DMA'd data, not a stale line (§11.1 steps 18-20). */
        Xil_DCacheInvalidateRange((UINTPTR)s2mm_dst_addr, s2mm_byte_count);
        s2mm_active = 0;
    }
    return rc;
}

int dma_halt_reset(void)
{
    s2mm_active = 0;
    XAxiDma_Reset(&dma_instance);

    XTime start = fw_time_now();
    while (!XAxiDma_ResetIsDone(&dma_instance)) {
        if (fw_time_expired(start, FW_WAIT_TIMEOUT_MS)) {
            return DMA_RESET_ERROR;
        }
    }
    return DMA_OK;
}
