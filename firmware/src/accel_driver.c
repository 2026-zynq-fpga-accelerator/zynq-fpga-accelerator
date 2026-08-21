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
    if (layer->op != OP_CONV && layer->op != OP_RESIDUAL_ADD
        && layer->op != OP_GLOBAL_AVG_POOL && layer->op != OP_FC) {
        return ACCEL_INVALID_ARG; /* OP_POOL remains RTL-reserved, HW_SW_Interface_v1.4 §1/§3.1 */
    }

    uint32_t status = accel_reg_read(ACCEL_REG_STATUS);
    if ((status & STATUS_BUSY_MASK) != 0U) {
        /* Hardware would silently ignore config writes while BUSY anyway (§9.2); fail fast instead. */
        return ACCEL_INVALID_ARG;
    }

    if (layer->op == OP_RESIDUAL_ADD) {
        /* HW_SW_Interface_v1.2_DRAFT.md §2.2: MAIN/SKIP/OUTPUT all share one shape, so a single
         * byte count covers INPUT_BYTES (MAIN), SKIP_BYTES, and OUTPUT_BYTES alike. */
        if (layer->height == 0U || layer->width == 0U || layer->out_channels == 0U) {
            return ACCEL_INVALID_ARG;
        }

        uint32_t bytes = (uint32_t)layer->height * (uint32_t)layer->width * layer->out_channels;

        accel_reg_write(ACCEL_REG_OPERATION, (uint32_t)ACCEL_OPERATION_RESIDUAL_ADD);
        accel_reg_write(ACCEL_REG_INPUT_HEIGHT, layer->height);
        accel_reg_write(ACCEL_REG_INPUT_WIDTH, layer->width);
        accel_reg_write(ACCEL_REG_IN_CHANNELS, layer->out_channels); /* MAIN/SKIP/OUTPUT share one channel count */
        accel_reg_write(ACCEL_REG_OUT_CHANNELS, layer->out_channels);
        accel_reg_write(
            ACCEL_REG_CONV_CONFIG,
            accel_pack_conv_config(0, 0, 0, layer->relu_enable)); /* only bit24 (Final ReLU) used, §2.2 */
        accel_reg_write(ACCEL_REG_OUTPUT_SCALE, 0U); /* unused: MAIN/SKIP already share scale, §2.2 */
        accel_reg_write(ACCEL_REG_INPUT_BYTES, bytes);   /* MAIN tensor byte count */
        accel_reg_write(ACCEL_REG_WEIGHT_BYTES, 0U);     /* no weight packet */
        accel_reg_write(ACCEL_REG_BIAS_BYTES, 0U);       /* no bias packet */
        accel_reg_write(ACCEL_REG_SKIP_BYTES, bytes);    /* SKIP tensor byte count */
        accel_reg_write(ACCEL_REG_OUTPUT_BYTES, bytes);

        return ACCEL_OK;
    }

    if (layer->op == OP_GLOBAL_AVG_POOL) {
        /* HW_SW_Interface_v1.4_DRAFT.md §2.2: OUT_CHANNELS always equals IN_CHANNELS (GAP never
         * changes channel count), no weight/bias/skip packet, CONV_CONFIG entirely unused. */
        if (layer->height == 0U || layer->width == 0U || layer->in_channels == 0U) {
            return ACCEL_INVALID_ARG;
        }

        uint32_t input_bytes = (uint32_t)layer->height * (uint32_t)layer->width * layer->in_channels;

        accel_reg_write(ACCEL_REG_OPERATION, (uint32_t)ACCEL_OPERATION_GLOBAL_AVG_POOL);
        accel_reg_write(ACCEL_REG_INPUT_HEIGHT, layer->height);
        accel_reg_write(ACCEL_REG_INPUT_WIDTH, layer->width);
        accel_reg_write(ACCEL_REG_IN_CHANNELS, layer->in_channels);
        accel_reg_write(ACCEL_REG_OUT_CHANNELS, layer->in_channels);
        accel_reg_write(ACCEL_REG_CONV_CONFIG, 0U); /* unused, §2.2 */
        accel_reg_write(ACCEL_REG_OUTPUT_SCALE, (uint32_t)layer->output_scale); /* mean M/N, §2.5/§2.6 */
        accel_reg_write(ACCEL_REG_INPUT_BYTES, input_bytes);
        accel_reg_write(ACCEL_REG_WEIGHT_BYTES, 0U); /* no weight packet */
        accel_reg_write(ACCEL_REG_BIAS_BYTES, 0U);   /* no bias packet */
        accel_reg_write(ACCEL_REG_SKIP_BYTES, 0U);   /* no skip packet */
        accel_reg_write(ACCEL_REG_OUTPUT_BYTES, layer->in_channels);

        return ACCEL_OK;
    }

    /* OP_CONV and OP_FC share this path -- FC is realized as OP_CONV(kernel=1, H=W=1), not a
     * distinct hardware operation (HW_SW_Interface_v1.4_DRAFT.md §3.1/§3.4). Callers building an
     * OP_FC resnet_layer_t don't need to fill in height/width/kernel/stride/padding; they're
     * forced to the FC-equivalent values here so RTL only ever sees an ordinary OP_CONV. */
    resnet_layer_t conv_layer = *layer;
    if (layer->op == OP_FC) {
        conv_layer.height = 1U;
        conv_layer.width = 1U;
        conv_layer.kernel = 1U;
        conv_layer.stride = 1U;
        conv_layer.padding = 0U;
    }

    int32_t out_h = ((int32_t)conv_layer.height + 2 * (int32_t)conv_layer.padding - (int32_t)conv_layer.kernel)
                    / (int32_t)conv_layer.stride + 1;
    int32_t out_w = ((int32_t)conv_layer.width + 2 * (int32_t)conv_layer.padding - (int32_t)conv_layer.kernel)
                    / (int32_t)conv_layer.stride + 1;
    if (out_h <= 0 || out_w <= 0) {
        return ACCEL_INVALID_ARG;
    }

    uint32_t weight_bytes = (uint32_t)conv_layer.kernel * conv_layer.kernel * conv_layer.in_channels * conv_layer.out_channels;
    uint32_t bias_bytes   = (uint32_t)conv_layer.out_channels * 4U;
    uint32_t input_bytes  = (uint32_t)conv_layer.height * conv_layer.width * conv_layer.in_channels;
    uint32_t output_bytes = (uint32_t)out_h * (uint32_t)out_w * conv_layer.out_channels;

    accel_reg_write(ACCEL_REG_OPERATION, (uint32_t)ACCEL_OPERATION_CONV);
    accel_reg_write(ACCEL_REG_INPUT_HEIGHT, conv_layer.height);
    accel_reg_write(ACCEL_REG_INPUT_WIDTH, conv_layer.width);
    accel_reg_write(ACCEL_REG_IN_CHANNELS, conv_layer.in_channels);
    accel_reg_write(ACCEL_REG_OUT_CHANNELS, conv_layer.out_channels);
    accel_reg_write(
        ACCEL_REG_CONV_CONFIG,
        accel_pack_conv_config(conv_layer.kernel, conv_layer.stride, conv_layer.padding, conv_layer.relu_enable));
    accel_reg_write(ACCEL_REG_OUTPUT_SCALE, (uint32_t)conv_layer.output_scale);
    accel_reg_write(ACCEL_REG_INPUT_BYTES, input_bytes);
    accel_reg_write(ACCEL_REG_WEIGHT_BYTES, weight_bytes);
    accel_reg_write(ACCEL_REG_BIAS_BYTES, bias_bytes);
    accel_reg_write(ACCEL_REG_SKIP_BYTES, 0U); /* unused for OP_CONV/OP_FC */
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
    uint32_t skip_bytes = accel_reg_read(ACCEL_REG_SKIP_BYTES);

    /* Packet order fixed by v1.1 §7.1 (OP_CONV: WEIGHT->BIAS->INPUT) and v1.2 §3 (OP_RESIDUAL_ADD:
     * MAIN->SKIP, no WEIGHT/BIAS). WEIGHT/BIAS are always nonzero for OP_CONV and always 0 for
     * OP_RESIDUAL_ADD (accel_configure() above); SKIP is the reverse. Each stage below only runs
     * if its byte count is nonzero: dma_mm2s_transfer()->dma_buffer_is_valid() rejects
     * byte_count==0 as DMA_INVALID_ARG, which would otherwise be misreported as ACCEL_FATAL_ERROR
     * for an operation that legitimately has no WEIGHT/BIAS/SKIP packet. */
    if (weight_bytes != 0U) {
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
    }

    if (bias_bytes != 0U) {
        if (diag != NULL) {
            diag->failure_stage = ACCEL_STAGE_BIAS_DMA;
        }
        int dma_rc = dma_mm2s_transfer(layer->bias_addr, bias_bytes);
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
    }

    /* INPUT (OP_CONV) / MAIN (OP_RESIDUAL_ADD) always has a packet. */
    if (diag != NULL) {
        diag->failure_stage = ACCEL_STAGE_INPUT_DMA;
    }
    {
        int dma_rc = dma_mm2s_transfer(layer->input_addr, input_bytes);
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
    }

    if (skip_bytes != 0U) {
        if (diag != NULL) {
            diag->failure_stage = ACCEL_STAGE_SKIP_DMA;
        }
        int dma_rc = dma_mm2s_transfer(layer->skip_addr, skip_bytes);
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
    case ACCEL_STAGE_SKIP_DMA:      return "SKIP_DMA";
    case ACCEL_STAGE_WAIT_DONE:     return "WAIT_DONE";
    case ACCEL_STAGE_OUTPUT_S2MM:   return "OUTPUT_S2MM";
    default:                        return "UNKNOWN";
    }
}
