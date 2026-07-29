/* AXI DMA MM2S/S2MM wrappers, simple (non-SG) transfer mode, 32-bit stream (HW_SW_Interface_v1.1 §6). */
#include "dma_transfer.h"

#include <stddef.h>

#include "platform_config.h"

#include "xaxidma.h"
#include "xil_cache.h"

static XAxiDma dma_instance;

int dma_init(void)
{
    XAxiDma_Config *config = XAxiDma_LookupConfig(ACCEL_DMA_DEVICE_ID);
    if (config == NULL) {
        return -1;
    }

    if (XAxiDma_CfgInitialize(&dma_instance, config) != XST_SUCCESS) {
        return -1;
    }

    if (XAxiDma_HasSg(&dma_instance)) {
        return -1; /* this driver targets simple-DMA mode; §6.2 assumes DRE disabled, no SG needed */
    }

    XAxiDma_IntrDisable(&dma_instance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma_instance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    return 0;
}

int dma_mm2s_transfer(uintptr_t src_addr, uint32_t byte_count)
{
    /* §6.2: source buffer must be 4-byte aligned, byte_count a multiple of 4. */
    Xil_DCacheFlushRange((UINTPTR)src_addr, byte_count);

    int status = XAxiDma_SimpleTransfer(&dma_instance, (UINTPTR)src_addr, byte_count, XAXIDMA_DMA_TO_DEVICE);
    return (status == XST_SUCCESS) ? 0 : -1;
}

int dma_mm2s_wait_complete(void)
{
    while (XAxiDma_Busy(&dma_instance, XAXIDMA_DMA_TO_DEVICE)) {
        /* poll; v1.0 is polling-only (§3 rule 2) */
    }
    return 0;
}

int dma_s2mm_prepare(uintptr_t dst_addr, uint32_t byte_count)
{
    /* Must be armed before CONTROL.START so the accelerator's first output beat isn't dropped (§11.1 step 6). */
    Xil_DCacheInvalidateRange((UINTPTR)dst_addr, byte_count);

    int status = XAxiDma_SimpleTransfer(&dma_instance, (UINTPTR)dst_addr, byte_count, XAXIDMA_DEVICE_TO_DMA);
    return (status == XST_SUCCESS) ? 0 : -1;
}

int dma_s2mm_wait_complete(void)
{
    while (XAxiDma_Busy(&dma_instance, XAXIDMA_DEVICE_TO_DMA)) {
        /* poll */
    }
    return 0;
}

int dma_halt_reset(void)
{
    XAxiDma_Reset(&dma_instance);

    int timeout = 10000;
    while (!XAxiDma_ResetIsDone(&dma_instance) && timeout-- > 0) {
        /* poll */
    }
    return (timeout > 0) ? 0 : -1;
}
