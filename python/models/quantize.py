# Symmetric per-tensor INT8 quantization and OUTPUT_SCALE (M, N) derivation (HW_SW_Interface_v1.1 §5.3, §4.1).
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from python.utils.fixed_point import (
    INT8_MAX,
    MULTIPLIER_M_MAX,
    SHIFT_N_MAX,
)


@dataclass
class QuantResult:
    q: np.ndarray        # quantized integer tensor (same shape as input)
    scale: float          # dequant scale s.t. float_value ~= q * scale


def quantize_symmetric_int8(x: np.ndarray, scale: float | None = None) -> QuantResult:
    """Per-tensor symmetric quantization to signed INT8: q = clamp(round(x / scale), -127, 127).

    -128 is intentionally left unused so the range stays symmetric around zero,
    matching the signed-symmetric rounding rule used elsewhere in the interface (§5.4).
    """
    x = np.asarray(x, dtype=np.float64)
    if scale is None:
        max_abs = float(np.max(np.abs(x))) if x.size else 0.0
        scale = (max_abs / 127.0) if max_abs > 0 else 1.0
    q = np.round(x / scale)
    q = np.clip(q, -127, 127).astype(np.int8)
    return QuantResult(q=q, scale=scale)


def dequantize(q: np.ndarray, scale: float) -> np.ndarray:
    return q.astype(np.float64) * scale


def compute_output_scale(
    input_scale: float,
    weight_scale: float,
    output_scale: float,
) -> tuple[int, int]:
    """Derive (multiplier_m, shift_n) for the OUTPUT_SCALE register from float scales (§5.3, §5.4).

    Accumulator (int32) represents a value of true_value = acc * input_scale * weight_scale.
    We need Q ~= true_value / output_scale = acc * combined_scale, computed in RTL as
    Q = round_symmetric((acc * M) >> N). Choose the largest N <= 31 such that
    M = round(combined_scale * 2^N) still fits in an unsigned 16-bit value.
    """
    combined_scale = (input_scale * weight_scale) / output_scale
    if combined_scale <= 0:
        raise ValueError("combined_scale must be positive")

    best_n = 0
    best_m = 1
    for n in range(SHIFT_N_MAX, -1, -1):
        m = round(combined_scale * (1 << n))
        if 0 <= m <= MULTIPLIER_M_MAX:
            best_n = n
            best_m = m
            break
    else:
        raise ValueError(
            f"combined_scale={combined_scale} cannot be represented with SHIFT_N<=31, "
            f"MULTIPLIER_M<=65535"
        )

    return best_m, best_n


def requant_error(
    input_scale: float,
    weight_scale: float,
    output_scale: float,
    multiplier_m: int,
    shift_n: int,
) -> float:
    """Relative error between the exact combined_scale and the (M, N) approximation actually used in RTL."""
    combined_scale = (input_scale * weight_scale) / output_scale
    approx = multiplier_m / (1 << shift_n) if shift_n > 0 else float(multiplier_m)
    if combined_scale == 0:
        return 0.0
    return abs(approx - combined_scale) / combined_scale
