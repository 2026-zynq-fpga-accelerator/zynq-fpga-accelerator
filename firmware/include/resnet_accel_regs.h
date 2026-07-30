#ifndef RESNET_ACCEL_REGS_H
#define RESNET_ACCEL_REGS_H

#include <stdint.h>

#define ACCEL_INTERFACE_VERSION       UINT32_C(0x00010001)

#define ACCEL_REG_CONTROL             UINT32_C(0x00)
#define ACCEL_REG_STATUS              UINT32_C(0x04)
#define ACCEL_REG_OPERATION           UINT32_C(0x08)
#define ACCEL_REG_INPUT_HEIGHT        UINT32_C(0x0C)
#define ACCEL_REG_INPUT_WIDTH         UINT32_C(0x10)
#define ACCEL_REG_IN_CHANNELS         UINT32_C(0x14)
#define ACCEL_REG_OUT_CHANNELS        UINT32_C(0x18)
#define ACCEL_REG_CONV_CONFIG         UINT32_C(0x1C)
#define ACCEL_REG_OUTPUT_SCALE        UINT32_C(0x20)
#define ACCEL_REG_INPUT_BYTES         UINT32_C(0x24)
#define ACCEL_REG_WEIGHT_BYTES        UINT32_C(0x28)
#define ACCEL_REG_BIAS_BYTES          UINT32_C(0x2C)
#define ACCEL_REG_SKIP_BYTES          UINT32_C(0x30)
#define ACCEL_REG_OUTPUT_BYTES        UINT32_C(0x34)
#define ACCEL_REG_CYCLE_COUNT         UINT32_C(0x38)
#define ACCEL_REG_ERROR_CODE          UINT32_C(0x3C)
#define ACCEL_REG_VERSION             UINT32_C(0x40)
#define ACCEL_REG_DEBUG_STATE         UINT32_C(0x44)

#define ACCEL_CONTROL_START           (UINT32_C(1) << 0)
#define ACCEL_CONTROL_ABORT           (UINT32_C(1) << 1)

#define ACCEL_STATUS_IDLE             (UINT32_C(1) << 0)
#define ACCEL_STATUS_BUSY             (UINT32_C(1) << 1)
#define ACCEL_STATUS_DONE             (UINT32_C(1) << 2)
#define ACCEL_STATUS_ERROR            (UINT32_C(1) << 3)

#define ACCEL_OP_CONV                 UINT32_C(0)

#define ACCEL_ERR_NONE                UINT32_C(0)
#define ACCEL_ERR_START_WHILE_BUSY    UINT32_C(1)
#define ACCEL_ERR_INVALID_OPERATION   UINT32_C(2)
#define ACCEL_ERR_INVALID_CONFIG      UINT32_C(3)
#define ACCEL_ERR_PACKET_LENGTH       UINT32_C(4)
#define ACCEL_ERR_TLAST_POSITION      UINT32_C(5)
#define ACCEL_ERR_ACC_OVERFLOW        UINT32_C(6)
#define ACCEL_ERR_ABORTED             UINT32_C(7)
#define ACCEL_ERR_CONFIG_WRITE_BUSY   UINT32_C(8)
#define ACCEL_ERR_INTERNAL            UINT32_C(9)
#define ACCEL_ERR_INVALID_ADDRESS     UINT32_C(10)

#define ACCEL_CONV_CONFIG(kernel, stride, padding, relu) \
  ((((uint32_t)(kernel))  & UINT32_C(0xFF))       | \
   (((uint32_t)(stride))  & UINT32_C(0xFF)) << 8  | \
   (((uint32_t)(padding)) & UINT32_C(0xFF)) << 16 | \
   (((uint32_t)(relu))    & UINT32_C(0x01)) << 24)

#define ACCEL_OUTPUT_SCALE(multiplier, shift) \
  ((((uint32_t)(multiplier)) & UINT32_C(0xFFFF)) | \
   (((uint32_t)(shift))      & UINT32_C(0xFFFF)) << 16)

#endif

