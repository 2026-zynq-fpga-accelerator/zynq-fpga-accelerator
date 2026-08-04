/* ResNet layer descriptor (project doc §7). */
#ifndef RESNET_LAYER_H
#define RESNET_LAYER_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    OP_CONV,
    OP_POOL,
    OP_RESIDUAL_ADD,
    OP_GLOBAL_AVG_POOL,
    OP_FC,
} accel_op_t;

typedef struct {
    accel_op_t op;

    uintptr_t input_addr;
    uintptr_t weight_addr;
    uintptr_t bias_addr;
    uintptr_t output_addr;
    uintptr_t skip_addr;

    uint16_t in_channels;
    uint16_t out_channels;
    uint16_t height;
    uint16_t width;

    uint8_t kernel;
    uint8_t stride;
    uint8_t padding;
    uint8_t relu_enable;

    int32_t output_scale; /* packed (multiplier_m, shift_n), see accel_pack_output_scale() */
} resnet_layer_t;

#endif /* RESNET_LAYER_H */
