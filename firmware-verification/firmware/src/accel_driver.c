/* Accelerator register driver (project doc §7, HW_SW_Interface_v1.1 §11). */
#include "accel_driver.h"

#include "accel_regs.h"
#include "dma_transfer.h"
#include "platform_config.h"
#include "platform_time.h"

#include "xil_io.h" /* Xil_In32 / Xil_Out32, Xilinx standalone BSP */

static inline uint32_t accel_reg_read(uint32_t offset)
{
    return Xil_In32(ACCEL_BASE_ADDR + offset);
}

static inline void accel_reg_write(uint32_t offset, uint32_t value)
{
    Xil_Out32(ACCEL_BASE_ADDR + offset, value);
}

int accel_init(void)
{
    uint32_t version = accel_reg_read(ACCEL_REG_VERSION);
    if (version != ACCEL_INTERFACE_VERSION_EXPECTED) {
        return ACCEL_VERSION_MISMATCH;
    }

    accel_clear_done_and_error();
    return ACCEL_OK;
}

int accel_configure(const resnet_layer_t *layer)
{
    if (layer == NULL) {
        return ACCEL_INVALID_ARG;
    }
    if (layer->op != OP_CONV) {
        return ACCEL_INVALID_ARG; /* only OP_CONV is implemented; others are RTL-reserved in v1.1 */
    }

    uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
    if ((status & STATUS_BUSY_MASK) != 0U) {
        /* Hardware would silently ignore config writes while BUSY anyway (§9.2); fail fast instead. */
        return ACCEL_INVALID_ARG;
    }

    int32_t out_h = ((int32_t)layer->height + 2 * (int32_t)layer->padding - (int32_t)layer->kernel)
                    / (int32_t)layer->stride + 1;
    int32_t out_w = ((int32_t)layer->width + 2 * (int32_t)layer->padding - (int32_t)layer->kernel)
                    / (int32_t)layer->stride + 1;
    if (out_h <= 0 || out_w <= 0) {
        return ACCEL_INVALID_ARG;
    }

    uint32_t weight_bytes = (uint32_t)layer->kernel * layer->kernel * layer->in_channels * layer->out_channels;
    uint32_t bias_bytes   = (uint32_t)layer->out_channels * 4U;
    uint32_t input_bytes  = (uint32_t)layer->height * layer->width * layer->in_channels;
    uint32_t output_bytes = (uint32_t)out_h * (uint32_t)out_w * layer->out_channels;

    accel_reg_write(ACCEL_REG_OPERATION, (uint32_t)ACCEL_OPERATION_CONV);
    accel_reg_write(ACCEL_REG_INPUT_HEIGHT, layer->height);
    accel_reg_write(ACCEL_REG_INPUT_WIDTH, layer->width);
    accel_reg_write(ACCEL_REG_IN_CHANNELS, layer->in_channels);
    accel_reg_write(ACCEL_REG_OUT_CHANNELS, layer->out_channels);
    accel_reg_write(
        ACCEL_REG_CONV_CONFIG,
        accel_pack_conv_config(layer->kernel, layer->stride, layer->padding, layer->relu_enable));
    accel_reg_write(ACCEL_REG_OUTPUT_SCALE, (uint32_t)layer->output_scale);
    accel_reg_write(ACCEL_REG_INPUT_BYTES, input_bytes);
    accel_reg_write(ACCEL_REG_WEIGHT_BYTES, weight_bytes);
    accel_reg_write(ACCEL_REG_BIAS_BYTES, bias_bytes);
    accel_reg_write(ACCEL_REG_SKIP_BYTES, 0U); /* unused until v1.2 residual extension */
    accel_reg_write(ACCEL_REG_OUTPUT_BYTES, output_bytes);

    return ACCEL_OK;
}

int accel_start(void)
{
    accel_reg_write(ACCEL_REG_CONTROL, CONTROL_START_MASK);
    return ACCEL_OK;
}

int accel_abort(void)
{
    accel_reg_write(ACCEL_REG_CONTROL, CONTROL_ABORT_MASK);
    return ACCEL_OK;
}

uint32_t accel_get_cycle_count(void)
{
    return accel_reg_read(ACCEL_REG_CYCLE_COUNT);
}

uint32_t accel_get_status(void)
{
    return accel_reg_read(ACCEL_REG_STATUS);
}

uint32_t accel_get_error_code(void)
{
    return accel_reg_read(ACCEL_REG_ERROR_CODE);
}

uint32_t accel_get_debug_state(void)
{
    return accel_reg_read(ACCEL_REG_DEBUG_STATE) & DEBUG_STATE_FSM_STATE_MASK;
}

void accel_clear_done_and_error(void)
{
    accel_reg_write(ACCEL_REG_STATUS, STATUS_DONE_MASK | STATUS_ERROR_MASK); /* W1C */
}

/* Polls until START is admitted (BUSY=1) or rejected (ERROR=1 while BUSY=0) (§11.1 steps 7-9, §11.2). */
int accel_wait_start_admitted(uint32_t timeout_ms, int *busy_ever)
{
    XTime start = fw_time_now();
    do {
        uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
        if ((status & STATUS_BUSY_MASK) != 0U) {
            if (busy_ever != NULL) {
                *busy_ever = 1;
            }
            return ACCEL_OK;
        }
        if ((status & STATUS_ERROR_MASK) != 0U) {
            return ACCEL_START_REJECTED;
        }
    } while (!fw_time_expired(start, timeout_ms));
    return ACCEL_TIMEOUT;
}

/* Polling wait with ABORT + BUSY==0 confirm loop, verbatim per HW_SW_Interface_v1.1 §11.4. */
int accel_wait_done(uint32_t timeout_ms, int *busy_ever)
{
    XTime start = fw_time_now();
    do {
        uint32_t status = accel_reg_read(ACCEL_REG_STATUS);

        if ((status & STATUS_BUSY_MASK) == 0U) {
            uint32_t error_code = accel_reg_read(ACCEL_REG_ERROR_CODE);

            if ((status & STATUS_DONE_MASK) != 0U) {
                return (error_code == ACCEL_ERR_NONE) ? ACCEL_OK : ACCEL_DONE_WITH_WARNING;
            }

            /* DONE never asserted before BUSY dropped -> fatal error (§10.3). */
            return ACCEL_FATAL_ERROR;
        }

        if (busy_ever != NULL) {
            *busy_ever = 1;
        }
    } while (!fw_time_expired(start, timeout_ms));

    accel_abort();

    /* ABORT is accepted asynchronously; re-poll BUSY==0 with its own timeout before trusting hw state. */
    start = fw_time_now();
    do {
        uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
        if ((status & STATUS_BUSY_MASK) == 0U) {
            return ACCEL_TIMEOUT;
        }
    } while (!fw_time_expired(start, FW_WAIT_TIMEOUT_MS));

    /* ABORT accepted but BUSY still 1: FSM lockup or similar, hardware state can no longer be trusted. */
    return ACCEL_ABORT_TIMEOUT;
}

/* Bounded abort-and-idle-confirm helper used on every layer failure (§8.3, §11.5); harmless no-op abort
 * if BUSY is already 0 (e.g. accel_wait_done() already aborted). */
int accel_abort_and_wait_idle(uint32_t timeout_ms)
{
    if ((accel_reg_read(ACCEL_REG_STATUS) & STATUS_BUSY_MASK) != 0U) {
        accel_abort();
    }

    XTime start = fw_time_now();
    do {
        if ((accel_reg_read(ACCEL_REG_STATUS) & STATUS_BUSY_MASK) == 0U) {
            return ACCEL_OK;
        }
    } while (!fw_time_expired(start, timeout_ms));

    return ACCEL_ABORT_TIMEOUT;
}

int accel_run_layer(const resnet_layer_t *layer, accel_run_diag_t *diag)
{
    if (diag != NULL) {
        accel_run_diag_t zero_diag = {0};
        *diag = zero_diag;
    }

    if (layer == NULL) {
        return ACCEL_INVALID_ARG;
    }

    uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
    if ((status & STATUS_BUSY_MASK) != 0U) {
        return ACCEL_INVALID_ARG; /* caller must serialize layer execution */
    }

    accel_clear_done_and_error();

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_CONFIGURE;
    }
    int rc = accel_configure(layer);
    if (rc != ACCEL_OK) {
        return rc;
    }

    uint32_t output_bytes = accel_reg_read(ACCEL_REG_OUTPUT_BYTES);
    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_S2MM_PREPARE;
    }
    {
        dma_s2mm_prepare_diag_t *prep_diag = (diag != NULL) ? &diag->s2mm_prepare : NULL;
        if (dma_s2mm_prepare(layer->output_addr, output_bytes, prep_diag) != DMA_OK) {
            return ACCEL_FATAL_ERROR;
        }
    }

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_START;
    }
    rc = accel_start();
    if (rc != ACCEL_OK) {
        return rc;
    }
    if (diag != NULL) {
        diag->start_written = 1;
    }

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_START_ADMIT;
    }
    {
        int busy_ever = 0;
        rc = accel_wait_start_admitted(FW_WAIT_TIMEOUT_MS, &busy_ever);
        if (diag != NULL && busy_ever) {
            diag->busy_ever = 1;
        }
    }
    if (rc != ACCEL_OK) {
        return rc;
    }

    uint32_t weight_bytes = accel_reg_read(ACCEL_REG_WEIGHT_BYTES);
    uint32_t bias_bytes = accel_reg_read(ACCEL_REG_BIAS_BYTES);
    uint32_t input_bytes = accel_reg_read(ACCEL_REG_INPUT_BYTES);

    /* Packet order fixed by §7.1: WEIGHT -> BIAS -> INPUT. */
    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_WEIGHT_DMA;
    }
    int dma_rc = dma_mm2s_transfer(layer->weight_addr, weight_bytes);
    if (dma_rc == DMA_OK) {
        uint32_t dmasr = 0;
        dma_rc = dma_mm2s_wait_complete(FW_WAIT_TIMEOUT_MS, &dmasr);
        if (diag != NULL) {
            diag->mm2s_dmasr = dmasr;
        }
    }
    if (dma_rc != DMA_OK) {
        return ACCEL_FATAL_ERROR;
    }

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_BIAS_DMA;
    }
    dma_rc = dma_mm2s_transfer(layer->bias_addr, bias_bytes);
    if (dma_rc == DMA_OK) {
        uint32_t dmasr = 0;
        dma_rc = dma_mm2s_wait_complete(FW_WAIT_TIMEOUT_MS, &dmasr);
        if (diag != NULL) {
            diag->mm2s_dmasr = dmasr;
        }
    }
    if (dma_rc != DMA_OK) {
        return ACCEL_FATAL_ERROR;
    }

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_INPUT_DMA;
    }
    dma_rc = dma_mm2s_transfer(layer->input_addr, input_bytes);
    if (dma_rc == DMA_OK) {
        uint32_t dmasr = 0;
        dma_rc = dma_mm2s_wait_complete(FW_WAIT_TIMEOUT_MS, &dmasr);
        if (diag != NULL) {
            diag->mm2s_dmasr = dmasr;
        }
    }
    if (dma_rc != DMA_OK) {
        return ACCEL_FATAL_ERROR;
    }

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_WAIT_DONE;
    }
    {
        int busy_ever = 0;
        rc = accel_wait_done(FW_WAIT_TIMEOUT_MS, &busy_ever);
        if (diag != NULL && busy_ever) {
            diag->busy_ever = 1;
        }
    }
    if (rc != ACCEL_OK && rc != ACCEL_DONE_WITH_WARNING) {
        return rc;
    }

    /* Accelerator DONE only means the last beat was handed to the DMA (§11.3 note); S2MM must
     * also confirm completion before the caller reads DDR output (§11.1 step 19-20). */
    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_OUTPUT_S2MM;
    }
    {
        uint32_t dmasr = 0;
        int s2mm_rc = dma_s2mm_wait_complete(FW_WAIT_TIMEOUT_MS, &dmasr);
        if (diag != NULL) {
            diag->s2mm_dmasr = dmasr;
        }
        if (s2mm_rc != DMA_OK) {
            return ACCEL_FATAL_ERROR;
        }
    }

    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_NONE;
    }
    return rc;
}

const char *accel_failure_stage_name(accel_failure_stage_t stage)
{
    switch (stage) {
    case ACCEL_STAGE_NONE:          return "NONE";
    case ACCEL_STAGE_CONFIGURE:     return "CONFIGURE";
    case ACCEL_STAGE_S2MM_PREPARE:  return "S2MM_PREPARE";
    case ACCEL_STAGE_START:         return "START";
    case ACCEL_STAGE_START_ADMIT:   return "START_ADMIT";
    case ACCEL_STAGE_WEIGHT_DMA:    return "WEIGHT_DMA";
    case ACCEL_STAGE_BIAS_DMA:      return "BIAS_DMA";
    case ACCEL_STAGE_INPUT_DMA:     return "INPUT_DMA";
    case ACCEL_STAGE_WAIT_DONE:     return "WAIT_DONE";
    case ACCEL_STAGE_OUTPUT_S2MM:   return "OUTPUT_S2MM";
    default:                        return "UNKNOWN";
    }
}
