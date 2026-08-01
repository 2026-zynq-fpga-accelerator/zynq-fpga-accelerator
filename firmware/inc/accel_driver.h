/* Accelerator register driver API (project doc §7, HW_SW_Interface_v1.1 §11). */
#ifndef ACCEL_DRIVER_H
#define ACCEL_DRIVER_H

#include <stdint.h>

#include "resnet_layer.h"

/* accel_wait_done() / accel_run_layer() return codes.
 * Negative values are firmware-level return codes, NOT hardware ERROR_CODE values
 * (accel_regs.h's accel_error_code_t) — always read STATUS.ERROR / ERROR_CODE
 * separately when you need the hardware's own diagnosis.
 */
#define ACCEL_OK                    0
#define ACCEL_DONE_WITH_WARNING     1  /* DONE=1, ERROR=1, non-fatal (§8.4, §10.2) */
#define ACCEL_FATAL_ERROR         (-1) /* BUSY dropped without DONE (§10.3) */
#define ACCEL_TIMEOUT             (-2) /* accel_wait_done() polling timed out, ABORT issued */
#define ACCEL_ABORT_TIMEOUT       (-3) /* ABORT accepted but BUSY never confirmed 0 (§11.4) */
#define ACCEL_INVALID_ARG         (-4)
#define ACCEL_VERSION_MISMATCH    (-5)
#define ACCEL_START_REJECTED      (-6) /* STATUS.ERROR set before BUSY rose: config rejected (§11.2) */

int accel_init(void);
int accel_configure(const resnet_layer_t *layer);
int accel_start(void);
int accel_wait_start_admitted(uint32_t timeout_ms);
int accel_wait_done(uint32_t timeout_ms);
int accel_run_layer(const resnet_layer_t *layer);
int accel_abort(void);
/* Issues ABORT if BUSY, then confirms BUSY==0 within timeout_ms; safe to call after any layer failure (§11.5). */
int accel_abort_and_wait_idle(uint32_t timeout_ms);
uint32_t accel_get_cycle_count(void);

/* Diagnostics, not part of the minimal API in project doc §7 but needed to act on §10/§11. */
uint32_t accel_get_status(void);
uint32_t accel_get_error_code(void);
uint32_t accel_get_debug_state(void);
void accel_clear_done_and_error(void);

#endif /* ACCEL_DRIVER_H */
