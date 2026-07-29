/* ResNet layer descriptor scheduler (project doc §7). */
#include "resnet_scheduler.h"

#include "accel_driver.h"
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
            xil_printf(
                "resnet_run: layer %u failed rc=%d status=0x%lx error_code=%lu debug_state=%lu\r\n",
                (unsigned)i, rc,
                (unsigned long)accel_get_status(),
                (unsigned long)accel_get_error_code(),
                (unsigned long)accel_get_debug_state());
            accel_abort();
            return rc;
        }
    }

    return ACCEL_OK;
}
