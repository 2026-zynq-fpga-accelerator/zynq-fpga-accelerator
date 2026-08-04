/* ResNet layer descriptor scheduler (project doc §7). */
#include "resnet_scheduler.h"

#include "accel_driver.h"
#include "dma_transfer.h"
#include "platform_time.h"
#include "xil_printf.h" /* UART status/result output */

int resnet_run(const resnet_layer_t *layers, size_t num_layers)
{
    for (size_t i = 0; i < num_layers; ++i) {
        accel_run_diag_t diag;
        int rc = accel_run_layer(&layers[i], &diag);

        if (rc == ACCEL_DONE_WITH_WARNING) {
            xil_printf(
                "resnet_run: layer %u completed with warning, error_code=%lu\r\n",
                (unsigned)i, (unsigned long)accel_get_error_code());
            continue;
        }

        if (rc != ACCEL_OK) {
            /* Snapshot diagnostics before recovery touches hardware state (§11.5). */
            uint32_t status = accel_get_status();
            uint32_t error_code = accel_get_error_code();
            uint32_t debug_state = accel_get_debug_state();
            uint32_t cycle_count = accel_get_cycle_count();
            xil_printf(
                "resnet_run: layer %u failed rc=%d status=0x%lx error_code=%lu debug_state=%lu cycle_count=%lu\r\n",
                (unsigned)i, rc, (unsigned long)status,
                (unsigned long)error_code, (unsigned long)debug_state, (unsigned long)cycle_count);
            /* Added 2026-08-03: the fields above don't say which of accel_run_layer()'s
             * stages failed, whether CONTROL.START was ever actually written, whether STATUS.BUSY
             * was ever observed 1 (distinguishes "never admitted" from "admitted then died"), or
             * what the raw DMASR bits were on either DMA channel. */
            xil_printf(
                "resnet_run: layer %u diag failure_stage=%s START_written=%d BUSY_ever=%d mm2s_dmasr=0x%lx s2mm_dmasr=0x%lx\r\n",
                (unsigned)i, accel_failure_stage_name(diag.failure_stage),
                diag.start_written, diag.busy_ever,
                (unsigned long)diag.mm2s_dmasr, (unsigned long)diag.s2mm_dmasr);
            /* Added 2026-08-03, after ISSUE-001 was pinned down to S2MM_PREPARE
             * (before accel_start() was ever called): dma_s2mm_prepare()'s own view of the buffer
             * it was handed and the DMA channel's DMACR/DMASR/Busy state right before and after
             * submitting, to tell an ACCEL_REG_OUTPUT_BYTES readback-as-0 bug apart from a DMA
             * channel that refuses the descriptor for its own reasons. */
            xil_printf(
                "resnet_run: layer %u s2mm_prepare dst=0x%lx bytes=%lu valid=%d busy_before=%d "
                "dmacr_before=0x%lx dmasr_before=0x%lx dmacr_after=0x%lx dmasr_after=0x%lx xfer_status=%d\r\n",
                (unsigned)i,
                (unsigned long)diag.s2mm_prepare.dst_addr, (unsigned long)diag.s2mm_prepare.byte_count,
                diag.s2mm_prepare.buffer_is_valid, diag.s2mm_prepare.busy_before,
                (unsigned long)diag.s2mm_prepare.dmacr_before, (unsigned long)diag.s2mm_prepare.dmasr_before,
                (unsigned long)diag.s2mm_prepare.dmacr_after, (unsigned long)diag.s2mm_prepare.dmasr_after,
                diag.s2mm_prepare.simple_transfer_status);

            /* ABORT does not reset DMA (§8.3); confirm accelerator idle, then reset both DMA
             * channels before reporting failure, so the next layer never inherits stale state (§10.3, §11.5). */
            int accel_recovery = accel_abort_and_wait_idle(FW_WAIT_TIMEOUT_MS);
            int dma_recovery = dma_halt_reset();
            if (accel_recovery != ACCEL_OK || dma_recovery != DMA_OK) {
                xil_printf(
                    "resnet_run: recovery failed accel_recovery=%d dma_recovery=%d\r\n",
                    accel_recovery, dma_recovery);
            }
            return rc;
        }
    }

    return ACCEL_OK;
}
