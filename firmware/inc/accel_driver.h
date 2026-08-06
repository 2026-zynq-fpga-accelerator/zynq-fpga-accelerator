/* Accelerator register driver API (project doc §7, HW_SW_Interface_v1.1 §11). */
#ifndef ACCEL_DRIVER_H
#define ACCEL_DRIVER_H

#include <stdint.h>

#include "dma_transfer.h"
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

/* Stage accel_run_layer() was attempting when it returned. ACCEL_STAGE_NONE means it returned
 * ACCEL_OK/ACCEL_DONE_WITH_WARNING (or never got past the layer==NULL/BUSY-already-set guard,
 * which fail before any stage is entered). Added for bring-up diagnostics (
 * 2026-08-03) — accel_run_layer() previously collapsed 6+ distinct failure points down to a
 * single ACCEL_FATAL_ERROR, which made it impossible to tell from the UART log alone whether
 * e.g. weight DMA never completed vs. the accelerator FSM never asserted DONE. */
typedef enum {
    ACCEL_STAGE_NONE = 0,
    ACCEL_STAGE_CONFIGURE,
    ACCEL_STAGE_S2MM_PREPARE,
    ACCEL_STAGE_START,
    ACCEL_STAGE_START_ADMIT,
    ACCEL_STAGE_WEIGHT_DMA,
    ACCEL_STAGE_BIAS_DMA,
    ACCEL_STAGE_INPUT_DMA,
    ACCEL_STAGE_SKIP_DMA,
    ACCEL_STAGE_WAIT_DONE,
    ACCEL_STAGE_OUTPUT_S2MM,
} accel_failure_stage_t;

/* Bring-up diagnostics filled in by accel_run_layer() as it runs (2026-08-03), meant
 * to disambiguate "operation was never admitted at all" (ISSUE-002/004 territory: start_written=1,
 * busy_ever=0) from "admitted and ran, then failed elsewhere" (busy_ever=1). Always fully
 * overwritten by accel_run_layer(); caller does not need to zero it first. */
typedef struct {
    accel_failure_stage_t failure_stage; /* stage in flight when accel_run_layer() returned */
    int start_written;                   /* CONTROL.START register write was issued this run */
    int busy_ever;                       /* STATUS.BUSY observed 1 at least once this run */
    uint32_t mm2s_dmasr;                 /* raw MM2S DMASR at the last weight/bias/input DMA check */
    uint32_t s2mm_dmasr;                 /* raw S2MM DMASR at the last output DMA check */
    dma_s2mm_prepare_diag_t s2mm_prepare; /* dma_s2mm_prepare() bring-up diagnostics (always filled) */
} accel_run_diag_t;

int accel_init(void);
int accel_configure(const resnet_layer_t *layer);
int accel_start(void);
/* busy_ever (if non-NULL) is set to 1 if STATUS.BUSY was observed 1; never reset to 0, so callers
 * that want a running OR across multiple calls should pre-zero it themselves. */
int accel_wait_start_admitted(uint32_t timeout_ms, int *busy_ever);
int accel_wait_done(uint32_t timeout_ms, int *busy_ever);
int accel_run_layer(const resnet_layer_t *layer, accel_run_diag_t *diag);
/* Human-readable name for a accel_failure_stage_t value, for UART logging. */
const char *accel_failure_stage_name(accel_failure_stage_t stage);
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
