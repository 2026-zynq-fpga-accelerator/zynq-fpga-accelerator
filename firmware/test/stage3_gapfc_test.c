/* GAP -> FC bring-up test: block_output -> OP_GLOBAL_AVG_POOL -> gap_output -> OP_CONV(kernel=1,
 * H=W=1) [=FC, HW_SW_Interface_v1.4_DRAFT.md §3.1] -> fc_output, run as two independent
 * resnet_layer_t entries through resnet_run(), compared against the Python golden model
 * checkpoint-by-checkpoint, then argmax'd against the expected predicted class
 * (v1.4 §2-§4, STAGE3_MASTER_ROADMAP.md §2.1).
 *
 * NOTE: as of this writing the GAP RTL (gap_engine.sv) has passed simulation (directed tests +
 * GAP->FC integration, mismatch 0 against its own reference) but has not yet been synthesized
 * into a delivered bitstream/BOOT.BIN. Until a new BOOT.BIN arrives, this file is a
 * compile-time-verified scaffold only (gcc -fsyntax-only per VERIFICATION_GUIDE.md §9.1), ready
 * to run the moment it does.
 *
 * Test vector data comes from generated/stage3_gapfc_test_vector.h; regenerate it with
 *   python3 scripts/generate_stage3_gapfc_vectors.py
 *   python3 scripts/generate_stage3_gapfc_c_header.py
 * after any change to data/test_vectors/stage3_gap_fc/.
 */
#include <stdint.h>

#include "accel_driver.h"
#include "accel_regs.h"
#include "dma_transfer.h"
#include "resnet_layer.h"
#include "resnet_scheduler.h"
#include "xil_printf.h"
#include "platform.h"

#include "generated/stage3_gapfc_test_vector.h"

static uint8_t g_gap_output[STAGE3_GAPFC_GAP_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_fc_output[STAGE3_GAPFC_FC_OUTPUT_BYTES] __attribute__((aligned(32)));

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
        "stage3_gapfc_test: %s %s - %lu/%lu bytes mismatched (first at %lu)\r\n",
        name, (mismatch_count == 0) ? "PASS" : "FAIL",
        (unsigned long)mismatch_count, (unsigned long)count, (unsigned long)first_mismatch_index);
    return mismatch_count;
}

/* argmax over the first STAGE3_GAPFC_NUM_VALID_CLASSES bytes, interpreted as signed INT8
 * (v1.4 §3.3: bytes[NUM_VALID_CLASSES..OUTPUT_BYTES) are always 0 zero-padding, never the max). */
static uint32_t argmax_class(const uint8_t *fc_output, uint32_t num_valid_classes)
{
    uint32_t best_index = 0;
    int8_t best_value = (int8_t)fc_output[0];
    for (uint32_t i = 1; i < num_valid_classes; ++i) {
        int8_t value = (int8_t)fc_output[i];
        if (value > best_value) {
            best_value = value;
            best_index = i;
        }
    }
    return best_index;
}

int main(void)
{
    int exit_code = -1;
    init_platform();

    int rc = dma_init();
    if (rc != 0) {
        xil_printf("stage3_gapfc_test: dma_init failed rc=%d\r\n", rc);
        goto out;
    }

    {
        dma_static_diag_t dma_diag;
        dma_get_static_diag(&dma_diag);
        xil_printf(
            "stage3_gapfc_test: dma_static cfginit_status=%d reg_base=0x%lx has_sg=%d "
            "has_mm2s=%d has_mm2s_dre=%d has_s2mm=%d has_s2mm_dre=%d "
            "mm2s_data_width=%lu s2mm_data_width=%lu\r\n",
            dma_diag.cfginit_status, (unsigned long)dma_diag.reg_base,
            dma_diag.has_sg, dma_diag.has_mm2s, dma_diag.has_mm2s_dre,
            dma_diag.has_s2mm, dma_diag.has_s2mm_dre,
            (unsigned long)dma_diag.mm2s_data_width, (unsigned long)dma_diag.s2mm_data_width);
    }

    rc = accel_init();
    if (rc != ACCEL_OK) {
        xil_printf("stage3_gapfc_test: accel_init failed rc=%d (VERSION mismatch?)\r\n", rc);
        goto out;
    }

    {
        /* [0] GAP: block_output -> g_gap_output, per v1.4 §2.2 no weight/bias/skip. */
        resnet_layer_t layers[2] = {
            {
                .op = OP_GLOBAL_AVG_POOL,
                .input_addr = (uintptr_t)stage3_gapfc_block_output,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_gap_output,
                .skip_addr = 0,
                .in_channels = STAGE3_GAPFC_GAP_IN_CHANNELS,
                .out_channels = STAGE3_GAPFC_GAP_OUT_CHANNELS,
                .height = STAGE3_GAPFC_GAP_INPUT_HEIGHT,
                .width = STAGE3_GAPFC_GAP_INPUT_WIDTH,
                .kernel = 0,
                .stride = 0,
                .padding = 0,
                .relu_enable = 0,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_GAPFC_GAP_MULTIPLIER_M, STAGE3_GAPFC_GAP_SHIFT_N),
            },
            /* [1] FC: g_gap_output -> g_fc_output, realized as OP_CONV(kernel=1,H=W=1) per
             * v1.4 §3.1 -- accel_configure() fills height/width/kernel/stride/padding
             * automatically for OP_FC, so they're left at 0 here deliberately. */
            {
                .op = OP_FC,
                .input_addr = (uintptr_t)g_gap_output,
                .weight_addr = (uintptr_t)stage3_gapfc_fc_weight,
                .bias_addr = (uintptr_t)stage3_gapfc_fc_bias,
                .output_addr = (uintptr_t)g_fc_output,
                .skip_addr = 0,
                .in_channels = STAGE3_GAPFC_FC_IN_CHANNELS,
                .out_channels = STAGE3_GAPFC_FC_OUT_CHANNELS,
                .height = 0,
                .width = 0,
                .kernel = 0,
                .stride = 0,
                .padding = 0,
                .relu_enable = STAGE3_GAPFC_FC_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_GAPFC_FC_MULTIPLIER_M, STAGE3_GAPFC_FC_SHIFT_N),
            },
        };

        rc = resnet_run(layers, 2);
    }
    if (rc != ACCEL_OK) {
        xil_printf(
            "stage3_gapfc_test: resnet_run rc=%d status=0x%lx error_code=%lu debug_state=%lu "
            "(expected until GAP RTL bitstream lands -- gap_engine.sv passed simulation but no "
            "BOOT.BIN delivered yet)\r\n",
            rc, (unsigned long)accel_get_status(), (unsigned long)accel_get_error_code(),
            (unsigned long)accel_get_debug_state());
    }

    {
        uint32_t mismatches = 0;
        mismatches += compare_checkpoint(
            "checkpoint1_gap", g_gap_output, stage3_gapfc_gap_expected_output,
            STAGE3_GAPFC_GAP_OUTPUT_BYTES);
        mismatches += compare_checkpoint(
            "checkpoint2_fc", g_fc_output, stage3_gapfc_fc_expected_output,
            STAGE3_GAPFC_FC_OUTPUT_BYTES);

        uint32_t predicted_class = argmax_class(g_fc_output, STAGE3_GAPFC_NUM_VALID_CLASSES);
        xil_printf(
            "stage3_gapfc_test: predicted_class=%lu expected_predicted_class=%lu\r\n",
            (unsigned long)predicted_class, (unsigned long)STAGE3_GAPFC_EXPECTED_PREDICTED_CLASS);

        int class_match = (predicted_class == STAGE3_GAPFC_EXPECTED_PREDICTED_CLASS);

        xil_printf(
            "stage3_gapfc_test: %s - %lu total mismatched bytes across 2 checkpoints, "
            "class_match=%d, cycle_count=%lu\r\n",
            (mismatches == 0 && rc == ACCEL_OK && class_match) ? "PASS" : "FAIL",
            (unsigned long)mismatches, class_match, (unsigned long)accel_get_cycle_count());

        exit_code = (mismatches == 0 && rc == ACCEL_OK && class_match) ? 0 : -1;
    }

out:
    cleanup_platform();
    return exit_code;
}
