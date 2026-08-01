/* ResNet layer descriptor scheduler (project doc §7). */
#include "resnet_scheduler.h"

#include "accel_driver.h"
#include "dma_transfer.h"
#include "platform_time.h"
#include "xil_printf.h" /* UART status/result output */

int resnet_run(const resnet_layer_t *layers, size_t num_layers)
{
    for (size_t i = 0; i < num_layers; ++i) {
        int rc = accel_run_layer(&layers[i]);

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
