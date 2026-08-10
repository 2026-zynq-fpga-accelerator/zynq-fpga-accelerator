/* Stage-2 Basic Residual Block (identity shortcut) bring-up test: conv1 -> conv2 -> residual_add
 * (+ final ReLU), run as three independent resnet_layer_t entries through resnet_run(), compared
 * against the Python golden model checkpoint-by-checkpoint (STAGE2_BASIC_RESIDUAL_BLOCK_PLAN.md
 * §6, HW_SW_Interface_v1.2_DRAFT.md §6).
 *
 * NOTE: this test cannot pass on real hardware yet. OP_RESIDUAL_ADD RTL is not implemented --
 * see HW_SW_Interface_v1.2_DRAFT.md §8 checklist ("RTL 구현" still unchecked). Until that lands
 * and the bitstream is regenerated, this file is a compile-time-verified scaffold only
 * (gcc -fsyntax-only per VERIFICATION_GUIDE.md §9); resnet_run()'s third layer will fail against
 * real hardware today.
 *
 * Test vector data comes from generated/stage2_identity_test_vector.h; regenerate it with
 *   python3 scripts/generate_stage2_c_header.py
 * after any change to data/test_vectors/stage2_basicblock_identity/.
 */
#include <stdint.h>

#include "accel_driver.h"
#include "accel_regs.h"
#include "dma_transfer.h"
#include "resnet_layer.h"
#include "resnet_scheduler.h"
#include "xil_printf.h"
#include "platform.h"

#include "generated/stage2_identity_test_vector.h"

static uint8_t g_conv1_output[STAGE2_IDENTITY_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_conv2_output[STAGE2_IDENTITY_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_final_output[STAGE2_IDENTITY_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint32_t compare_checkpoint(
    const char *name, const uint8_t *got, const uint8_t *expected, uint32_t count)
{
    uint32_t mismatch_count = 0;
    uint32_t first_mismatch_index = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (got[i] != expected[i]) {
            if (mismatch_count == 0) {
                first_mismatch_index = i;
            }
            if (mismatch_count < 8) {
                xil_printf(
                    "  %s mismatch[%lu]: got 0x%02x expected 0x%02x\r\n",
                    name, (unsigned long)i, got[i], expected[i]);
            }
            ++mismatch_count;
        }
    }
    xil_printf(
        "stage2_residual_test: %s %s - %lu/%lu bytes mismatched (first at %lu)\r\n",
        name, (mismatch_count == 0) ? "PASS" : "FAIL",
        (unsigned long)mismatch_count, (unsigned long)count, (unsigned long)first_mismatch_index);
    return mismatch_count;
}

int main(void)
{
    int exit_code = -1;
    init_platform();

    int rc = dma_init();
    if (rc != 0) {
        xil_printf("stage2_residual_test: dma_init failed rc=%d\r\n", rc);
        goto out;
    }

    {
        dma_static_diag_t dma_diag;
        dma_get_static_diag(&dma_diag);
        xil_printf(
            "stage2_residual_test: dma_static cfginit_status=%d reg_base=0x%lx has_sg=%d "
            "has_mm2s=%d has_mm2s_dre=%d has_s2mm=%d has_s2mm_dre=%d "
            "mm2s_data_width=%lu s2mm_data_width=%lu\r\n",
            dma_diag.cfginit_status, (unsigned long)dma_diag.reg_base,
            dma_diag.has_sg, dma_diag.has_mm2s, dma_diag.has_mm2s_dre,
            dma_diag.has_s2mm, dma_diag.has_s2mm_dre,
            (unsigned long)dma_diag.mm2s_data_width, (unsigned long)dma_diag.s2mm_data_width);
    }

    rc = accel_init();
    if (rc != ACCEL_OK) {
        xil_printf("stage2_residual_test: accel_init failed rc=%d (VERSION mismatch?)\r\n", rc);
        goto out;
    }

    {
        resnet_layer_t layers[3] = {
            /* [0] conv1: input_x -> g_conv1_output, ReLU ON */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)stage2_identity_input_x,
                .weight_addr = (uintptr_t)stage2_identity_conv1_weight,
                .bias_addr = (uintptr_t)stage2_identity_conv1_bias,
                .output_addr = (uintptr_t)g_conv1_output,
                .skip_addr = 0,
                .in_channels = STAGE2_IDENTITY_IN_CHANNELS,
                .out_channels = STAGE2_IDENTITY_CONV1_OUT_CHANNELS,
                .height = STAGE2_IDENTITY_INPUT_HEIGHT,
                .width = STAGE2_IDENTITY_INPUT_WIDTH,
                .kernel = STAGE2_IDENTITY_CONV1_KERNEL_SIZE,
                .stride = STAGE2_IDENTITY_CONV1_STRIDE,
                .padding = STAGE2_IDENTITY_CONV1_PADDING,
                .relu_enable = STAGE2_IDENTITY_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE2_IDENTITY_CONV1_MULTIPLIER_M, STAGE2_IDENTITY_CONV1_SHIFT_N),
            },
            /* [1] conv2: g_conv1_output -> g_conv2_output, ReLU OFF (final ReLU happens in residual_add) */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_conv1_output,
                .weight_addr = (uintptr_t)stage2_identity_conv2_weight,
                .bias_addr = (uintptr_t)stage2_identity_conv2_bias,
                .output_addr = (uintptr_t)g_conv2_output,
                .skip_addr = 0,
                .in_channels = STAGE2_IDENTITY_IN_CHANNELS,
                .out_channels = STAGE2_IDENTITY_CONV2_OUT_CHANNELS,
                .height = STAGE2_IDENTITY_INPUT_HEIGHT,
                .width = STAGE2_IDENTITY_INPUT_WIDTH,
                .kernel = STAGE2_IDENTITY_CONV2_KERNEL_SIZE,
                .stride = STAGE2_IDENTITY_CONV2_STRIDE,
                .padding = STAGE2_IDENTITY_CONV2_PADDING,
                .relu_enable = STAGE2_IDENTITY_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE2_IDENTITY_CONV2_MULTIPLIER_M, STAGE2_IDENTITY_CONV2_SHIFT_N),
            },
            /* [2] residual_add: MAIN=g_conv2_output, SKIP=identity shortcut (pre-rescaled offline) -> g_final_output */
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_conv2_output,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_final_output,
                .skip_addr = (uintptr_t)stage2_identity_shortcut_rescaled,
                .in_channels = STAGE2_IDENTITY_CONV2_OUT_CHANNELS,
                .out_channels = STAGE2_IDENTITY_CONV2_OUT_CHANNELS,
                .height = STAGE2_IDENTITY_INPUT_HEIGHT,
                .width = STAGE2_IDENTITY_INPUT_WIDTH,
                .kernel = 0,
                .stride = 0,
                .padding = 0,
                .relu_enable = 1, /* Final ReLU, §2.2 */
                .output_scale = 0, /* unused for OP_RESIDUAL_ADD, §2.2 */
            },
        };

        rc = resnet_run(layers, 3);
    }
    if (rc != ACCEL_OK) {
        xil_printf(
            "stage2_residual_test: resnet_run rc=%d status=0x%lx error_code=%lu debug_state=%lu "
            "(expected on real hw today -- OP_RESIDUAL_ADD RTL not implemented yet, see "
            "HW_SW_Interface_v1.2_DRAFT.md checklist)\r\n",
            rc, (unsigned long)accel_get_status(), (unsigned long)accel_get_error_code(),
            (unsigned long)accel_get_debug_state());
        /* Fall through to comparisons anyway: whatever checkpoints did complete (e.g. conv1/conv2
         * before a residual_add failure) are still worth comparing for partial diagnostics. */
    }

    {
        uint32_t mismatches = 0;
        mismatches += compare_checkpoint(
            "checkpoint1_conv1", g_conv1_output, stage2_identity_conv1_expected_output,
            STAGE2_IDENTITY_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint(
            "checkpoint2_conv2", g_conv2_output, stage2_identity_conv2_expected_output,
            STAGE2_IDENTITY_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint(
            "checkpoint3_final", g_final_output, stage2_identity_final_expected_output,
            STAGE2_IDENTITY_CONV2_OUTPUT_BYTES);

        xil_printf(
            "stage2_residual_test: %s - %lu total mismatched bytes across 3 checkpoints, cycle_count=%lu\r\n",
            (mismatches == 0 && rc == ACCEL_OK) ? "PASS" : "FAIL",
            (unsigned long)mismatches, (unsigned long)accel_get_cycle_count());

        exit_code = (mismatches == 0 && rc == ACCEL_OK) ? 0 : -1;
    }

out:
    cleanup_platform();
    return exit_code;
}
