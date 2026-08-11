# Bit-accurate NHWC/HWIO fixed-point convolution golden model, mirrors RTL exactly (HW_SW_Interface_v1.1 §4, §5).
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from python.utils.fixed_point import (
    conv_output_dim,
    mac_product,
    relu_and_saturate_int8,
    requantize,
    sat_add_int32,
    validate_conv_config,
)


@dataclass
class ConvFixedPointResult:
    output: np.ndarray          # [OUT_H, OUT_W, OUT_CHANNELS] int8, final result
    accumulator: np.ndarray     # [OUT_H, OUT_W, OUT_CHANNELS] int32, post-bias pre-requant (§5.1)
    requantized: np.ndarray     # [OUT_H, OUT_W, OUT_CHANNELS] int64, post-requant pre-ReLU/clamp (§5.4)
    overflow: bool              # True if any accumulator step saturated (-> ERR_ACC_OVERFLOW, §5.2)


@dataclass
class GapFixedPointResult:
    output: np.ndarray          # [OUT_CHANNELS] int8, final result (= [1][1][C] flattened)
    accumulator: np.ndarray     # [OUT_CHANNELS] int32, post-sum pre-requant (HW_SW_Interface_v1.4 §2.5)
    overflow: bool              # True if any per-channel sum saturated


def _pad_input(input_hwc: np.ndarray, padding: int) -> list:
    """Zero-pad [H][W][C] input on H/W; padding is never stored in DDR, only generated logically (§3 rule 9)."""
    if padding == 0:
        return input_hwc.tolist()
    h, w, c = input_hwc.shape
    padded = np.zeros((h + 2 * padding, w + 2 * padding, c), dtype=np.int64)
    padded[padding:padding + h, padding:padding + w, :] = input_hwc
    return padded.tolist()


def conv2d_fixed_point(
    input_hwc: np.ndarray,
    weight_hwio: np.ndarray,
    bias_oc: np.ndarray,
    stride: int,
    padding: int,
    multiplier_m: int,
    shift_n: int,
    relu_enable: bool,
) -> ConvFixedPointResult:
    """Sequential per-step-saturating conv + bias + requant + optional ReLU (§5.1-§5.5).

    Accumulation is done element-by-element in RTL loop order (kh, kw, ic) so that
    directed overflow/saturation test vectors reproduce the exact RTL trajectory,
    not just the final mathematical sum.
    """
    in_h, in_w, in_channels = input_hwc.shape
    kh, kw, kic, out_channels = weight_hwio.shape
    if kic != in_channels:
        raise ValueError(f"weight IN_CHANNELS {kic} != input IN_CHANNELS {in_channels}")
    if kh != kw:
        raise ValueError("only square kernels are supported (KERNEL_SIZE)")
    if bias_oc.shape != (out_channels,):
        raise ValueError(f"bias shape {bias_oc.shape} != ({out_channels},)")

    validate_conv_config(in_h, in_w, in_channels, out_channels, kh, stride, padding)

    out_h = conv_output_dim(in_h, padding, kh, stride)
    out_w = conv_output_dim(in_w, padding, kw, stride)

    padded = _pad_input(input_hwc, padding)
    weight_list = weight_hwio.tolist()
    bias_list = [int(b) for b in bias_oc.tolist()]

    output = np.zeros((out_h, out_w, out_channels), dtype=np.int8)
    accumulator = np.zeros((out_h, out_w, out_channels), dtype=np.int32)
    requantized = np.zeros((out_h, out_w, out_channels), dtype=np.int64)
    overflow_seen = False

    for oh in range(out_h):
        base_h = oh * stride
        for ow in range(out_w):
            base_w = ow * stride
            flat_patch = [
                padded[base_h + r][base_w + s][ic]
                for r in range(kh)
                for s in range(kw)
                for ic in range(in_channels)
            ]

            for oc in range(out_channels):
                acc = 0
                idx = 0
                for r in range(kh):
                    for s in range(kw):
                        for ic in range(in_channels):
                            product = mac_product(flat_patch[idx], weight_list[r][s][ic][oc])
                            idx += 1
                            acc, ov = sat_add_int32(acc, product)
                            overflow_seen = overflow_seen or ov
                acc, ov = sat_add_int32(acc, bias_list[oc])
                overflow_seen = overflow_seen or ov

                accumulator[oh, ow, oc] = acc
                q = requantize(acc, multiplier_m, shift_n)
                requantized[oh, ow, oc] = q
                output[oh, ow, oc] = relu_and_saturate_int8(q, relu_enable)

    return ConvFixedPointResult(
        output=output,
        accumulator=accumulator,
        requantized=requantized,
        overflow=overflow_seen,
    )


def global_avg_pool_fixed_point(
    input_hwc: np.ndarray,
    multiplier_m: int,
    shift_n: int,
) -> GapFixedPointResult:
    """Per-channel spatial average, HW_SW_Interface_v1.4 §2.5.

    Same per-step INT32 saturation and M/N requantization as conv2d_fixed_point (§5.1-§5.4),
    but summing instead of multiply-accumulating, and never applying ReLU (§2.2 CONV_CONFIG
    is unused/RELU_ENABLE=0 for OP_GLOBAL_AVG_POOL).
    """
    in_h, in_w, in_channels = input_hwc.shape

    output = np.zeros((in_channels,), dtype=np.int8)
    accumulator = np.zeros((in_channels,), dtype=np.int32)
    overflow_seen = False

    for c in range(in_channels):
        acc = 0
        for h in range(in_h):
            for w in range(in_w):
                acc, ov = sat_add_int32(acc, int(input_hwc[h, w, c]))
                overflow_seen = overflow_seen or ov

        accumulator[c] = acc
        q = requantize(acc, multiplier_m, shift_n)
        output[c] = relu_and_saturate_int8(q, False)

    return GapFixedPointResult(
        output=output,
        accumulator=accumulator,
        overflow=overflow_seen,
    )
