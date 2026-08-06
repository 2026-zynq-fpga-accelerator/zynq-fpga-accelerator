/* AXI4-Lite register map, bitfields, and error codes (HW_SW_Interface_v1.1 §8, §10). */
#ifndef ACCEL_REGS_H
#define ACCEL_REGS_H

#include <stdint.h>

/* ---- Register offsets (§8.2) ---- */
#define ACCEL_REG_CONTROL        0x00U
#define ACCEL_REG_STATUS         0x04U
#define ACCEL_REG_OPERATION      0x08U
#define ACCEL_REG_INPUT_HEIGHT   0x0CU
#define ACCEL_REG_INPUT_WIDTH    0x10U
#define ACCEL_REG_IN_CHANNELS    0x14U
#define ACCEL_REG_OUT_CHANNELS   0x18U
#define ACCEL_REG_CONV_CONFIG    0x1CU
#define ACCEL_REG_OUTPUT_SCALE   0x20U
#define ACCEL_REG_INPUT_BYTES    0x24U
#define ACCEL_REG_WEIGHT_BYTES   0x28U
#define ACCEL_REG_BIAS_BYTES     0x2CU
#define ACCEL_REG_SKIP_BYTES     0x30U
#define ACCEL_REG_OUTPUT_BYTES   0x34U
#define ACCEL_REG_CYCLE_COUNT    0x38U
#define ACCEL_REG_ERROR_CODE     0x3CU
#define ACCEL_REG_VERSION        0x40U
#define ACCEL_REG_DEBUG_STATE    0x44U

/* ---- CONTROL (0x00) — W1P (§8.3) ---- */
#define CONTROL_START_MASK       (1U << 0)
#define CONTROL_ABORT_MASK       (1U << 1)

/* ---- STATUS (0x04) — RO / W1C (§8.4) ---- */
#define STATUS_IDLE_MASK         (1U << 0)
#define STATUS_BUSY_MASK         (1U << 1)
#define STATUS_DONE_MASK         (1U << 2)
#define STATUS_ERROR_MASK        (1U << 3)

/* ---- OPERATION (0x08) — §8.5 ---- */
typedef enum {
    ACCEL_OPERATION_CONV             = 0,
    ACCEL_OPERATION_POOL             = 1, /* reserved */
    ACCEL_OPERATION_RESIDUAL_ADD     = 2, /* required, v1.2 -- Basic Residual Block final add + ReLU */
    ACCEL_OPERATION_GLOBAL_AVG_POOL  = 3, /* reserved */
    ACCEL_OPERATION_FC               = 4, /* reserved */
} accel_operation_t;

/* ---- CONV_CONFIG (0x1C) — §8.6 ---- */
#define CONV_CONFIG_KERNEL_SIZE_SHIFT   0
#define CONV_CONFIG_KERNEL_SIZE_MASK    (0xFFU << CONV_CONFIG_KERNEL_SIZE_SHIFT)
#define CONV_CONFIG_STRIDE_SHIFT        8
#define CONV_CONFIG_STRIDE_MASK         (0xFFU << CONV_CONFIG_STRIDE_SHIFT)
#define CONV_CONFIG_PADDING_SHIFT       16
#define CONV_CONFIG_PADDING_MASK        (0xFFU << CONV_CONFIG_PADDING_SHIFT)
#define CONV_CONFIG_RELU_ENABLE_SHIFT   24
#define CONV_CONFIG_RELU_ENABLE_MASK    (0x1U << CONV_CONFIG_RELU_ENABLE_SHIFT)

static inline uint32_t accel_pack_conv_config(uint8_t kernel, uint8_t stride, uint8_t padding, uint8_t relu_enable)
{
    return ((uint32_t)kernel << CONV_CONFIG_KERNEL_SIZE_SHIFT)
         | ((uint32_t)stride << CONV_CONFIG_STRIDE_SHIFT)
         | ((uint32_t)padding << CONV_CONFIG_PADDING_SHIFT)
         | (((uint32_t)relu_enable & 0x1U) << CONV_CONFIG_RELU_ENABLE_SHIFT);
}

/* ---- OUTPUT_SCALE (0x20) — §5.3 ---- */
#define OUTPUT_SCALE_MULTIPLIER_M_SHIFT 0
#define OUTPUT_SCALE_MULTIPLIER_M_MASK  (0xFFFFU << OUTPUT_SCALE_MULTIPLIER_M_SHIFT)
#define OUTPUT_SCALE_SHIFT_N_SHIFT      16
#define OUTPUT_SCALE_SHIFT_N_MASK       (0xFFFFU << OUTPUT_SCALE_SHIFT_N_SHIFT)

static inline uint32_t accel_pack_output_scale(uint16_t multiplier_m, uint16_t shift_n)
{
    return ((uint32_t)shift_n << OUTPUT_SCALE_SHIFT_N_SHIFT)
         | ((uint32_t)multiplier_m << OUTPUT_SCALE_MULTIPLIER_M_SHIFT);
}

/* ---- VERSION (0x40) — §8.7 ---- */
#define ACCEL_INTERFACE_VERSION_EXPECTED 0x00010001U /* v1.1 */

/* ---- DEBUG_STATE (0x44) — §8.8, §12; debug-only, never affects protocol behavior ---- */
#define DEBUG_STATE_FSM_STATE_MASK 0xFU

typedef enum {
    ACCEL_FSM_RESET       = 0,
    ACCEL_FSM_IDLE        = 1,
    ACCEL_FSM_LOAD_WEIGHT = 2,
    ACCEL_FSM_LOAD_BIAS   = 3,
    ACCEL_FSM_LOAD_INPUT  = 4,
    ACCEL_FSM_COMPUTE     = 5,
    ACCEL_FSM_SEND_OUTPUT = 6,
    ACCEL_FSM_COMPLETE    = 7,
    ACCEL_FSM_LOAD_SKIP   = 8, /* required, v1.2 -- SKIP tensor receive, OP_RESIDUAL_ADD only */
} accel_fsm_state_t;

/* ---- ERROR_CODE (0x3C) — §10.1 ---- */
typedef enum {
    ACCEL_ERR_NONE                 = 0,  /* -                */
    ACCEL_ERR_START_WHILE_BUSY     = 1,  /* non-fatal        */
    ACCEL_ERR_INVALID_OPERATION    = 2,  /* fatal            */
    ACCEL_ERR_INVALID_CONFIG       = 3,  /* fatal            */
    ACCEL_ERR_PACKET_LENGTH        = 4,  /* fatal            */
    ACCEL_ERR_TLAST_POSITION       = 5,  /* fatal            */
    ACCEL_ERR_ACC_OVERFLOW         = 6,  /* non-fatal        */
    ACCEL_ERR_ABORTED              = 7,  /* fatal            */
    ACCEL_ERR_CONFIG_WRITE_BUSY    = 8,  /* non-fatal        */
    ACCEL_ERR_INTERNAL             = 9,  /* fatal            */
    ACCEL_ERR_INVALID_ADDRESS      = 10, /* non-fatal        */
} accel_error_code_t;

#endif /* ACCEL_REGS_H */
