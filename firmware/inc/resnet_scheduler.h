/* ResNet layer descriptor scheduler (project doc §7). */
#ifndef RESNET_SCHEDULER_H
#define RESNET_SCHEDULER_H

#include <stddef.h>

#include "resnet_layer.h"

/* Runs `layers[0..num_layers)` in order. Stops and returns the first fatal error's
 * accel_run_layer() return code, aborting the accelerator first. Non-fatal warnings
 * (ACCEL_DONE_WITH_WARNING, e.g. ERR_ACC_OVERFLOW) are logged but do not stop the run,
 * per the fatal/non-fatal distinction in HW_SW_Interface_v1.1 §10.2-§10.3.
 */
int resnet_run(const resnet_layer_t *layers, size_t num_layers);

#endif /* RESNET_SCHEDULER_H */
