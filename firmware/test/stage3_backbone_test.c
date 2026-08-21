/* Full ResNet-20 CIFAR backbone bring-up test (STAGE3_MASTER_ROADMAP.md §2.2): stem -> 9x
 * BasicBlock (stage1 3x identity/16ch, stage2 1x projection+2x identity/32ch, stage3 1x
 * projection+2x identity/64ch) -> OP_GLOBAL_AVG_POOL -> FC(=OP_CONV kernel=1) -> predicted class,
 * run as one long chain of independent resnet_layer_t entries through resnet_run(), compared
 * against the Python golden model checkpoint-by-checkpoint.
 *
 * Every individual operation here (OP_CONV incl. kernel=1, OP_RESIDUAL_ADD, OP_GLOBAL_AVG_POOL)
 * is already board-verified on its own. What's untested is running this many of them back to
 * back -- STAGE3_MASTER_ROADMAP.md §2.2 flags multi-block resource-reuse/timing/state-carryover
 * as the thing still needing real hardware confirmation.
 *
 * Test vector data comes from generated/stage3_backbone_test_vector.h; regenerate it with
 *   python3 scripts/generate_stage3_backbone_vectors.py
 *   python3 scripts/generate_stage3_backbone_c_header.py
 * after any change to data/test_vectors/stage3_backbone/.
 */
#include <stdint.h>

#include "accel_driver.h"
#include "accel_regs.h"
#include "dma_transfer.h"
#include "resnet_layer.h"
#include "resnet_scheduler.h"
#include "xil_printf.h"
#include "platform.h"

#include "generated/stage3_backbone_test_vector.h"

#define NUM_LAYERS 32

static uint8_t g_stem_output[STAGE3_BACKBONE_STEM_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block01_conv1[STAGE3_BACKBONE_BLOCK01_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block01_conv2[STAGE3_BACKBONE_BLOCK01_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block01_output[STAGE3_BACKBONE_BLOCK01_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block02_conv1[STAGE3_BACKBONE_BLOCK02_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block02_conv2[STAGE3_BACKBONE_BLOCK02_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block02_output[STAGE3_BACKBONE_BLOCK02_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block03_conv1[STAGE3_BACKBONE_BLOCK03_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block03_conv2[STAGE3_BACKBONE_BLOCK03_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block03_output[STAGE3_BACKBONE_BLOCK03_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block04_conv1[STAGE3_BACKBONE_BLOCK04_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block04_conv2[STAGE3_BACKBONE_BLOCK04_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block04_shortcut[STAGE3_BACKBONE_BLOCK04_SHORTCUT_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block04_output[STAGE3_BACKBONE_BLOCK04_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block05_conv1[STAGE3_BACKBONE_BLOCK05_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block05_conv2[STAGE3_BACKBONE_BLOCK05_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block05_output[STAGE3_BACKBONE_BLOCK05_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block06_conv1[STAGE3_BACKBONE_BLOCK06_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block06_conv2[STAGE3_BACKBONE_BLOCK06_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block06_output[STAGE3_BACKBONE_BLOCK06_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block07_conv1[STAGE3_BACKBONE_BLOCK07_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block07_conv2[STAGE3_BACKBONE_BLOCK07_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block07_shortcut[STAGE3_BACKBONE_BLOCK07_SHORTCUT_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block07_output[STAGE3_BACKBONE_BLOCK07_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block08_conv1[STAGE3_BACKBONE_BLOCK08_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block08_conv2[STAGE3_BACKBONE_BLOCK08_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block08_output[STAGE3_BACKBONE_BLOCK08_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_block09_conv1[STAGE3_BACKBONE_BLOCK09_CONV1_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block09_conv2[STAGE3_BACKBONE_BLOCK09_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_block09_output[STAGE3_BACKBONE_BLOCK09_CONV2_OUTPUT_BYTES] __attribute__((aligned(32)));

static uint8_t g_gap_output[STAGE3_BACKBONE_GAP_OUTPUT_BYTES] __attribute__((aligned(32)));
static uint8_t g_fc_output[STAGE3_BACKBONE_FC_OUTPUT_BYTES] __attribute__((aligned(32)));

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
        "stage3_backbone_test: %s %s - %lu/%lu bytes mismatched (first at %lu)\r\n",
        name, (mismatch_count == 0) ? "PASS" : "FAIL",
        (unsigned long)mismatch_count, (unsigned long)count, (unsigned long)first_mismatch_index);
    return mismatch_count;
}

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
        xil_printf("stage3_backbone_test: dma_init failed rc=%d\r\n", rc);
        goto out;
    }

    {
        dma_static_diag_t dma_diag;
        dma_get_static_diag(&dma_diag);
        xil_printf(
            "stage3_backbone_test: dma_static cfginit_status=%d reg_base=0x%lx has_sg=%d "
            "has_mm2s=%d has_mm2s_dre=%d has_s2mm=%d has_s2mm_dre=%d "
            "mm2s_data_width=%lu s2mm_data_width=%lu\r\n",
            dma_diag.cfginit_status, (unsigned long)dma_diag.reg_base,
            dma_diag.has_sg, dma_diag.has_mm2s, dma_diag.has_mm2s_dre,
            dma_diag.has_s2mm, dma_diag.has_s2mm_dre,
            (unsigned long)dma_diag.mm2s_data_width, (unsigned long)dma_diag.s2mm_data_width);
    }

    rc = accel_init();
    if (rc != ACCEL_OK) {
        xil_printf("stage3_backbone_test: accel_init failed rc=%d (VERSION mismatch?)\r\n", rc);
        goto out;
    }

    {
        resnet_layer_t layers[NUM_LAYERS] = {
            /* [0] stem: input_x -> g_stem_output, ReLU ON */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)stage3_backbone_input_x,
                .weight_addr = (uintptr_t)stage3_backbone_stem_weight,
                .bias_addr = (uintptr_t)stage3_backbone_stem_bias,
                .output_addr = (uintptr_t)g_stem_output,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_STEM_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_STEM_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_STEM_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_STEM_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_STEM_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_STEM_STRIDE,
                .padding = STAGE3_BACKBONE_STEM_PADDING,
                .relu_enable = STAGE3_BACKBONE_STEM_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_STEM_MULTIPLIER_M, STAGE3_BACKBONE_STEM_SHIFT_N),
            },

            /* --- block01 (identity, 16ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_stem_output,
                .weight_addr = (uintptr_t)stage3_backbone_block01_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block01_conv1_bias,
                .output_addr = (uintptr_t)g_block01_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK01_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK01_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK01_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK01_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK01_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK01_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK01_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK01_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK01_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK01_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block01_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block01_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block01_conv2_bias,
                .output_addr = (uintptr_t)g_block01_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK01_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK01_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK01_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK01_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK01_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK01_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK01_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK01_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK01_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK01_CONV2_SHIFT_N),
            },
            /* residual_add: MAIN=conv2, SKIP=block input (identity, already same scale by
             * construction -- HW_SW_Interface_v1.2_DRAFT.md §2.2, no rescale needed) */
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block01_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block01_output,
                .skip_addr = (uintptr_t)g_stem_output,
                .in_channels = STAGE3_BACKBONE_BLOCK01_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK01_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK01_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK01_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK01_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block02 (identity, 16ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block01_output,
                .weight_addr = (uintptr_t)stage3_backbone_block02_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block02_conv1_bias,
                .output_addr = (uintptr_t)g_block02_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK02_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK02_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK02_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK02_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK02_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK02_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK02_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK02_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK02_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK02_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block02_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block02_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block02_conv2_bias,
                .output_addr = (uintptr_t)g_block02_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK02_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK02_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK02_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK02_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK02_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK02_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK02_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK02_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK02_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK02_CONV2_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block02_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block02_output,
                .skip_addr = (uintptr_t)g_block01_output,
                .in_channels = STAGE3_BACKBONE_BLOCK02_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK02_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK02_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK02_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK02_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block03 (identity, 16ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block02_output,
                .weight_addr = (uintptr_t)stage3_backbone_block03_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block03_conv1_bias,
                .output_addr = (uintptr_t)g_block03_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK03_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK03_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK03_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK03_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK03_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK03_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK03_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK03_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK03_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK03_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block03_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block03_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block03_conv2_bias,
                .output_addr = (uintptr_t)g_block03_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK03_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK03_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK03_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK03_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK03_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK03_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK03_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK03_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK03_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK03_CONV2_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block03_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block03_output,
                .skip_addr = (uintptr_t)g_block02_output,
                .in_channels = STAGE3_BACKBONE_BLOCK03_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK03_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK03_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK03_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK03_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block04 (projection, 16->32ch, stride2) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block03_output,
                .weight_addr = (uintptr_t)stage3_backbone_block04_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block04_conv1_bias,
                .output_addr = (uintptr_t)g_block04_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK04_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK04_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK04_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK04_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK04_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK04_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK04_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK04_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK04_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK04_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block04_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block04_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block04_conv2_bias,
                .output_addr = (uintptr_t)g_block04_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK04_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK04_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK04_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK04_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK04_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK04_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK04_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK04_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK04_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK04_CONV2_SHIFT_N),
            },
            /* projection shortcut: block input -> g_block04_shortcut, 1x1 stride2, forced onto
             * conv2's output scale at export time (v1.2 §2.2 mechanism, unchanged) */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block03_output,
                .weight_addr = (uintptr_t)stage3_backbone_block04_shortcut_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block04_shortcut_bias,
                .output_addr = (uintptr_t)g_block04_shortcut,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK04_SHORTCUT_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK04_SHORTCUT_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK04_SHORTCUT_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK04_SHORTCUT_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK04_SHORTCUT_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK04_SHORTCUT_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK04_SHORTCUT_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK04_SHORTCUT_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK04_SHORTCUT_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK04_SHORTCUT_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block04_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block04_output,
                .skip_addr = (uintptr_t)g_block04_shortcut,
                .in_channels = STAGE3_BACKBONE_BLOCK04_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK04_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK04_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK04_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK04_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block05 (identity, 32ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block04_output,
                .weight_addr = (uintptr_t)stage3_backbone_block05_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block05_conv1_bias,
                .output_addr = (uintptr_t)g_block05_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK05_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK05_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK05_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK05_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK05_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK05_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK05_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK05_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK05_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK05_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block05_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block05_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block05_conv2_bias,
                .output_addr = (uintptr_t)g_block05_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK05_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK05_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK05_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK05_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK05_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK05_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK05_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK05_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK05_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK05_CONV2_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block05_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block05_output,
                .skip_addr = (uintptr_t)g_block04_output,
                .in_channels = STAGE3_BACKBONE_BLOCK05_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK05_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK05_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK05_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK05_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block06 (identity, 32ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block05_output,
                .weight_addr = (uintptr_t)stage3_backbone_block06_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block06_conv1_bias,
                .output_addr = (uintptr_t)g_block06_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK06_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK06_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK06_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK06_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK06_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK06_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK06_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK06_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK06_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK06_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block06_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block06_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block06_conv2_bias,
                .output_addr = (uintptr_t)g_block06_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK06_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK06_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK06_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK06_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK06_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK06_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK06_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK06_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK06_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK06_CONV2_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block06_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block06_output,
                .skip_addr = (uintptr_t)g_block05_output,
                .in_channels = STAGE3_BACKBONE_BLOCK06_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK06_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK06_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK06_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK06_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block07 (projection, 32->64ch, stride2) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block06_output,
                .weight_addr = (uintptr_t)stage3_backbone_block07_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block07_conv1_bias,
                .output_addr = (uintptr_t)g_block07_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK07_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK07_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK07_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK07_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK07_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK07_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK07_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK07_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK07_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK07_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block07_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block07_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block07_conv2_bias,
                .output_addr = (uintptr_t)g_block07_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK07_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK07_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK07_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK07_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK07_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK07_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK07_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK07_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK07_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK07_CONV2_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block06_output,
                .weight_addr = (uintptr_t)stage3_backbone_block07_shortcut_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block07_shortcut_bias,
                .output_addr = (uintptr_t)g_block07_shortcut,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK07_SHORTCUT_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK07_SHORTCUT_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK07_SHORTCUT_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK07_SHORTCUT_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK07_SHORTCUT_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK07_SHORTCUT_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK07_SHORTCUT_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK07_SHORTCUT_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK07_SHORTCUT_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK07_SHORTCUT_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block07_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block07_output,
                .skip_addr = (uintptr_t)g_block07_shortcut,
                .in_channels = STAGE3_BACKBONE_BLOCK07_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK07_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK07_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK07_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK07_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block08 (identity, 64ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block07_output,
                .weight_addr = (uintptr_t)stage3_backbone_block08_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block08_conv1_bias,
                .output_addr = (uintptr_t)g_block08_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK08_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK08_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK08_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK08_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK08_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK08_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK08_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK08_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK08_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK08_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block08_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block08_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block08_conv2_bias,
                .output_addr = (uintptr_t)g_block08_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK08_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK08_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK08_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK08_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK08_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK08_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK08_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK08_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK08_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK08_CONV2_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block08_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block08_output,
                .skip_addr = (uintptr_t)g_block07_output,
                .in_channels = STAGE3_BACKBONE_BLOCK08_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK08_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK08_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK08_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK08_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* --- block09 (identity, 64ch) --- */
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block08_output,
                .weight_addr = (uintptr_t)stage3_backbone_block09_conv1_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block09_conv1_bias,
                .output_addr = (uintptr_t)g_block09_conv1,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK09_CONV1_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK09_CONV1_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK09_CONV1_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK09_CONV1_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK09_CONV1_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK09_CONV1_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK09_CONV1_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK09_CONV1_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK09_CONV1_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK09_CONV1_SHIFT_N),
            },
            {
                .op = OP_CONV,
                .input_addr = (uintptr_t)g_block09_conv1,
                .weight_addr = (uintptr_t)stage3_backbone_block09_conv2_weight,
                .bias_addr = (uintptr_t)stage3_backbone_block09_conv2_bias,
                .output_addr = (uintptr_t)g_block09_conv2,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_BLOCK09_CONV2_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK09_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK09_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK09_CONV2_INPUT_WIDTH,
                .kernel = STAGE3_BACKBONE_BLOCK09_CONV2_KERNEL_SIZE,
                .stride = STAGE3_BACKBONE_BLOCK09_CONV2_STRIDE,
                .padding = STAGE3_BACKBONE_BLOCK09_CONV2_PADDING,
                .relu_enable = STAGE3_BACKBONE_BLOCK09_CONV2_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_BLOCK09_CONV2_MULTIPLIER_M, STAGE3_BACKBONE_BLOCK09_CONV2_SHIFT_N),
            },
            {
                .op = OP_RESIDUAL_ADD,
                .input_addr = (uintptr_t)g_block09_conv2,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_block09_output,
                .skip_addr = (uintptr_t)g_block08_output,
                .in_channels = STAGE3_BACKBONE_BLOCK09_CONV2_OUT_CHANNELS,
                .out_channels = STAGE3_BACKBONE_BLOCK09_CONV2_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_BLOCK09_CONV2_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_BLOCK09_CONV2_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_BLOCK09_RESIDUAL_RELU_ENABLE,
                .output_scale = 0,
            },

            /* [30] GAP: block09 output -> g_gap_output */
            {
                .op = OP_GLOBAL_AVG_POOL,
                .input_addr = (uintptr_t)g_block09_output,
                .weight_addr = 0,
                .bias_addr = 0,
                .output_addr = (uintptr_t)g_gap_output,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_GAP_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_GAP_OUT_CHANNELS,
                .height = STAGE3_BACKBONE_GAP_INPUT_HEIGHT,
                .width = STAGE3_BACKBONE_GAP_INPUT_WIDTH,
                .kernel = 0, .stride = 0, .padding = 0, .relu_enable = 0,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_GAP_MULTIPLIER_M, STAGE3_BACKBONE_GAP_SHIFT_N),
            },

            /* [31] FC: g_gap_output -> g_fc_output, realized as OP_CONV(kernel=1,H=W=1) per
             * HW_SW_Interface_v1.4_FINAL.md §3.1 -- accel_configure() fills height/width/kernel/
             * stride/padding automatically for OP_FC. */
            {
                .op = OP_FC,
                .input_addr = (uintptr_t)g_gap_output,
                .weight_addr = (uintptr_t)stage3_backbone_fc_weight,
                .bias_addr = (uintptr_t)stage3_backbone_fc_bias,
                .output_addr = (uintptr_t)g_fc_output,
                .skip_addr = 0,
                .in_channels = STAGE3_BACKBONE_FC_IN_CHANNELS,
                .out_channels = STAGE3_BACKBONE_FC_OUT_CHANNELS,
                .height = 0, .width = 0, .kernel = 0, .stride = 0, .padding = 0,
                .relu_enable = STAGE3_BACKBONE_FC_RELU_ENABLE,
                .output_scale = (int32_t)accel_pack_output_scale(
                    STAGE3_BACKBONE_FC_MULTIPLIER_M, STAGE3_BACKBONE_FC_SHIFT_N),
            },
        };

        rc = resnet_run(layers, NUM_LAYERS);
    }
    if (rc != ACCEL_OK) {
        xil_printf(
            "stage3_backbone_test: resnet_run rc=%d status=0x%lx error_code=%lu debug_state=%lu\r\n",
            rc, (unsigned long)accel_get_status(), (unsigned long)accel_get_error_code(),
            (unsigned long)accel_get_debug_state());
        /* Fall through to comparisons anyway: whatever checkpoints did complete are still worth
         * comparing for partial diagnostics -- pinpoints exactly which block/op failed. */
    }

    {
        uint32_t mismatches = 0;

        mismatches += compare_checkpoint("stem", g_stem_output, stage3_backbone_stem_expected_output, STAGE3_BACKBONE_STEM_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block01_conv1", g_block01_conv1, stage3_backbone_block01_conv1_expected_output, STAGE3_BACKBONE_BLOCK01_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block01_conv2", g_block01_conv2, stage3_backbone_block01_conv2_expected_output, STAGE3_BACKBONE_BLOCK01_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block01_output", g_block01_output, stage3_backbone_block01_expected_output, STAGE3_BACKBONE_BLOCK01_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block02_conv1", g_block02_conv1, stage3_backbone_block02_conv1_expected_output, STAGE3_BACKBONE_BLOCK02_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block02_conv2", g_block02_conv2, stage3_backbone_block02_conv2_expected_output, STAGE3_BACKBONE_BLOCK02_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block02_output", g_block02_output, stage3_backbone_block02_expected_output, STAGE3_BACKBONE_BLOCK02_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block03_conv1", g_block03_conv1, stage3_backbone_block03_conv1_expected_output, STAGE3_BACKBONE_BLOCK03_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block03_conv2", g_block03_conv2, stage3_backbone_block03_conv2_expected_output, STAGE3_BACKBONE_BLOCK03_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block03_output", g_block03_output, stage3_backbone_block03_expected_output, STAGE3_BACKBONE_BLOCK03_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block04_conv1", g_block04_conv1, stage3_backbone_block04_conv1_expected_output, STAGE3_BACKBONE_BLOCK04_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block04_conv2", g_block04_conv2, stage3_backbone_block04_conv2_expected_output, STAGE3_BACKBONE_BLOCK04_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block04_shortcut", g_block04_shortcut, stage3_backbone_block04_shortcut_expected_output, STAGE3_BACKBONE_BLOCK04_SHORTCUT_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block04_output", g_block04_output, stage3_backbone_block04_expected_output, STAGE3_BACKBONE_BLOCK04_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block05_conv1", g_block05_conv1, stage3_backbone_block05_conv1_expected_output, STAGE3_BACKBONE_BLOCK05_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block05_conv2", g_block05_conv2, stage3_backbone_block05_conv2_expected_output, STAGE3_BACKBONE_BLOCK05_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block05_output", g_block05_output, stage3_backbone_block05_expected_output, STAGE3_BACKBONE_BLOCK05_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block06_conv1", g_block06_conv1, stage3_backbone_block06_conv1_expected_output, STAGE3_BACKBONE_BLOCK06_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block06_conv2", g_block06_conv2, stage3_backbone_block06_conv2_expected_output, STAGE3_BACKBONE_BLOCK06_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block06_output", g_block06_output, stage3_backbone_block06_expected_output, STAGE3_BACKBONE_BLOCK06_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block07_conv1", g_block07_conv1, stage3_backbone_block07_conv1_expected_output, STAGE3_BACKBONE_BLOCK07_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block07_conv2", g_block07_conv2, stage3_backbone_block07_conv2_expected_output, STAGE3_BACKBONE_BLOCK07_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block07_shortcut", g_block07_shortcut, stage3_backbone_block07_shortcut_expected_output, STAGE3_BACKBONE_BLOCK07_SHORTCUT_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block07_output", g_block07_output, stage3_backbone_block07_expected_output, STAGE3_BACKBONE_BLOCK07_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block08_conv1", g_block08_conv1, stage3_backbone_block08_conv1_expected_output, STAGE3_BACKBONE_BLOCK08_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block08_conv2", g_block08_conv2, stage3_backbone_block08_conv2_expected_output, STAGE3_BACKBONE_BLOCK08_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block08_output", g_block08_output, stage3_backbone_block08_expected_output, STAGE3_BACKBONE_BLOCK08_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("block09_conv1", g_block09_conv1, stage3_backbone_block09_conv1_expected_output, STAGE3_BACKBONE_BLOCK09_CONV1_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block09_conv2", g_block09_conv2, stage3_backbone_block09_conv2_expected_output, STAGE3_BACKBONE_BLOCK09_CONV2_OUTPUT_BYTES);
        mismatches += compare_checkpoint("block09_output", g_block09_output, stage3_backbone_block09_expected_output, STAGE3_BACKBONE_BLOCK09_CONV2_OUTPUT_BYTES);

        mismatches += compare_checkpoint("gap", g_gap_output, stage3_backbone_gap_expected_output, STAGE3_BACKBONE_GAP_OUTPUT_BYTES);
        mismatches += compare_checkpoint("fc", g_fc_output, stage3_backbone_fc_expected_output, STAGE3_BACKBONE_FC_OUTPUT_BYTES);

        uint32_t predicted_class = argmax_class(g_fc_output, STAGE3_BACKBONE_NUM_VALID_CLASSES);
        xil_printf(
            "stage3_backbone_test: predicted_class=%lu expected_predicted_class=%lu\r\n",
            (unsigned long)predicted_class, (unsigned long)STAGE3_BACKBONE_EXPECTED_PREDICTED_CLASS);

        int class_match = (predicted_class == STAGE3_BACKBONE_EXPECTED_PREDICTED_CLASS);

        xil_printf(
            "stage3_backbone_test: %s - %lu total mismatched bytes across %d checkpoints, "
            "class_match=%d\r\n",
            (mismatches == 0 && rc == ACCEL_OK && class_match) ? "PASS" : "FAIL",
            (unsigned long)mismatches, 30, class_match);

        exit_code = (mismatches == 0 && rc == ACCEL_OK && class_match) ? 0 : -1;
    }

out:
    cleanup_platform();
    return exit_code;
}
