/* First hardware bring-up test: run the §13.1 canonical stage-1 OP_CONV
 * (32x32x3 -> 32x32x16, kernel 3, stride 1, padding 1, ReLU) on the real board and
 * compare the DMA'd-back output against the Python golden model byte-for-byte.
 *
 * Test vector data comes from generated/stage1_test_vector.h; regenerate it with
 *   python3 scripts/generate_stage1_c_header.py
 * after any change to data/test_vectors/stage1_conv/ (scripts/generate_stage1_vectors.py).
 */
#include <stdint.h>

#include "accel_driver.h"
#include "accel_regs.h"
#include "dma_transfer.h"
#include "resnet_layer.h"
#include "resnet_scheduler.h"
#include "xil_printf.h"
#include "platform.h"

#include "generated/stage1_test_vector.h"

static uint8_t g_output_buffer[STAGE1_OUTPUT_BYTES] __attribute__((aligned(4)));

int main(void)
{
    int exit_code = -1;
    init_platform();

    int rc = dma_init();
    if (rc != 0) {
        xil_printf("stage1_conv_test: dma_init failed rc=%d\r\n", rc);
        goto out;
    }

    {
        /* One-time DMA instance facts (정민님 요청, 2026-08-03), logged once here rather than per
         * layer run since they don't change between runs. */
        dma_static_diag_t dma_diag;
        dma_get_static_diag(&dma_diag);
        xil_printf(
            "stage1_conv_test: dma_static cfginit_status=%d reg_base=0x%lx has_sg=%d "
            "has_mm2s=%d has_mm2s_dre=%d has_s2mm=%d has_s2mm_dre=%d\r\n",
            dma_diag.cfginit_status, (unsigned long)dma_diag.reg_base,
            dma_diag.has_sg, dma_diag.has_mm2s, dma_diag.has_mm2s_dre,
            dma_diag.has_s2mm, dma_diag.has_s2mm_dre);
    }

    rc = accel_init();
    if (rc != ACCEL_OK) {
        xil_printf("stage1_conv_test: accel_init failed rc=%d (VERSION mismatch?)\r\n", rc);
        goto out;
    }

    resnet_layer_t layer = {
        .op = OP_CONV,
        .input_addr = (uintptr_t)stage1_input,
        .weight_addr = (uintptr_t)stage1_weight,
        .bias_addr = (uintptr_t)stage1_bias,
        .output_addr = (uintptr_t)g_output_buffer,
        .skip_addr = 0,
        .in_channels = STAGE1_IN_CHANNELS,
        .out_channels = STAGE1_OUT_CHANNELS,
        .height = STAGE1_INPUT_HEIGHT,
        .width = STAGE1_INPUT_WIDTH,
        .kernel = STAGE1_KERNEL_SIZE,
        .stride = STAGE1_STRIDE,
        .padding = STAGE1_PADDING,
        .relu_enable = STAGE1_RELU_ENABLE,
        .output_scale = (int32_t)accel_pack_output_scale(STAGE1_MULTIPLIER_M, STAGE1_SHIFT_N),
    };

    rc = resnet_run(&layer, 1);
    if (rc != ACCEL_OK) {
        xil_printf(
            "stage1_conv_test: FAIL - resnet_run rc=%d status=0x%lx error_code=%lu debug_state=%lu\r\n",
            rc, (unsigned long)accel_get_status(), (unsigned long)accel_get_error_code(),
            (unsigned long)accel_get_debug_state());
        goto out;
    }

    uint32_t mismatch_count = 0;
    uint32_t first_mismatch_index = 0;
    for (uint32_t i = 0; i < STAGE1_OUTPUT_BYTES; ++i) {
        if (g_output_buffer[i] != stage1_expected_output[i]) {
            if (mismatch_count == 0) {
                first_mismatch_index = i;
            }
            if (mismatch_count < 8) {
                xil_printf(
                    "  mismatch[%lu]: got 0x%02x expected 0x%02x\r\n",
                    (unsigned long)i, g_output_buffer[i], stage1_expected_output[i]);
            }
            ++mismatch_count;
        }
    }

    xil_printf(
        "stage1_conv_test: %s - %lu/%lu bytes mismatched (first at %lu), cycle_count=%lu\r\n",
        (mismatch_count == 0) ? "PASS" : "FAIL",
        (unsigned long)mismatch_count, (unsigned long)STAGE1_OUTPUT_BYTES,
        (unsigned long)first_mismatch_index, (unsigned long)accel_get_cycle_count());

    exit_code = (mismatch_count == 0) ? 0 : -1;

out:
    cleanup_platform();
    return exit_code;
}
