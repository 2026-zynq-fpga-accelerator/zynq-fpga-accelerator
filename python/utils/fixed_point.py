# Bit-accurate fixed-point primitives, mirrors HW_SW_Interface_v1.1 §5 exactly.
from __future__ import annotations

INT8_MIN, INT8_MAX = -128, 127
INT16_MIN, INT16_MAX = -32768, 32767
INT32_MIN, INT32_MAX = -2_147_483_648, 2_147_483_647

MULTIPLIER_M_MIN, MULTIPLIER_M_MAX = 0, 65535
SHIFT_N_MIN, SHIFT_N_MAX = 0, 31


def sat_int32(value: int) -> tuple[int, bool]:
    """Saturate an arbitrary-precision int to signed INT32. Returns (result, overflow)."""
    if value > INT32_MAX:
        return INT32_MAX, True
    if value < INT32_MIN:
        return INT32_MIN, True
    return value, False


def sat_add_int32(acc: int, term: int) -> tuple[int, bool]:
    """acc = SAT_INT32(acc + term), the per-step saturation rule used for both MAC accumulation and bias add (§5.1, §5.2)."""
    return sat_int32(acc + term)


def mac_product(input_val: int, weight_val: int) -> int:
    """signed INT8 x signed INT8 -> signed INT16 product (§5.1, §4.1)."""
    if not (INT8_MIN <= input_val <= INT8_MAX):
        raise ValueError(f"input_val out of INT8 range: {input_val}")
    if not (INT8_MIN <= weight_val <= INT8_MAX):
        raise ValueError(f"weight_val out of INT8 range: {weight_val}")
    product = input_val * weight_val
    assert INT16_MIN <= product <= INT16_MAX, "INT8 x INT8 must fit in INT16"
    return product


def requantize(acc: int, multiplier_m: int, shift_n: int) -> int:
    """Q from Accumulator x M, sign-symmetric round-to-nearest-ties-away-from-zero right shift by N (§5.3, §5.4)."""
    if not (INT32_MIN <= acc <= INT32_MAX):
        raise ValueError(f"acc out of INT32 range: {acc}")
    if not (MULTIPLIER_M_MIN <= multiplier_m <= MULTIPLIER_M_MAX):
        raise ValueError(f"multiplier_m out of range: {multiplier_m}")
    if not (SHIFT_N_MIN <= shift_n <= SHIFT_N_MAX):
        raise ValueError(f"shift_n out of range: {shift_n}")

    p = acc * multiplier_m  # signed x unsigned(zero-extended) -> signed, fits well within 49+ bits

    if shift_n == 0:
        return p

    half = 1 << (shift_n - 1)
    if p >= 0:
        return (p + half) >> shift_n
    return -(((-p) + half) >> shift_n)


def clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def relu_and_saturate_int8(value: int, relu_enable: bool) -> int:
    """Optional ReLU then INT8 saturation, applied in that order (§5.5)."""
    if relu_enable:
        value = max(value, 0)
    return clamp(value, INT8_MIN, INT8_MAX)


def pack_output_scale(multiplier_m: int, shift_n: int) -> int:
    """Pack (M, N) into the 32-bit OUTPUT_SCALE register value: [31:16]=N, [15:0]=M (§5.3)."""
    if not (MULTIPLIER_M_MIN <= multiplier_m <= MULTIPLIER_M_MAX):
        raise ValueError(f"multiplier_m out of range: {multiplier_m}")
    if not (SHIFT_N_MIN <= shift_n <= SHIFT_N_MAX):
        raise ValueError(f"shift_n out of range: {shift_n}")
    return ((shift_n & 0xFFFF) << 16) | (multiplier_m & 0xFFFF)


def unpack_output_scale(reg_value: int) -> tuple[int, int]:
    """Inverse of pack_output_scale. Returns (multiplier_m, shift_n)."""
    multiplier_m = reg_value & 0xFFFF
    shift_n = (reg_value >> 16) & 0xFFFF
    return multiplier_m, shift_n


def conv_output_dim(in_dim: int, padding: int, kernel: int, stride: int) -> int:
    """OUT = floor((IN + 2*PADDING - KERNEL) / STRIDE) + 1 (§4.5)."""
    return (in_dim + 2 * padding - kernel) // stride + 1


def validate_conv_config(
    in_h: int, in_w: int, in_channels: int, out_channels: int,
    kernel: int, stride: int, padding: int,
) -> None:
    """Raises ValueError with the same conditions RTL rejects as ERR_INVALID_CONFIG (§4.5)."""
    if in_h <= 0:
        raise ValueError("IN_H must be > 0")
    if in_w <= 0:
        raise ValueError("IN_W must be > 0")
    if in_channels <= 0:
        raise ValueError("IN_CHANNELS must be > 0")
    if out_channels <= 0:
        raise ValueError("OUT_CHANNELS must be > 0")
    if kernel <= 0:
        raise ValueError("KERNEL_SIZE must be > 0")
    if stride not in (1, 2):
        raise ValueError("STRIDE must be 1 or 2")
    if in_h + 2 * padding < kernel:
        raise ValueError("IN_H + 2*PADDING must be >= KERNEL_SIZE")
    if in_w + 2 * padding < kernel:
        raise ValueError("IN_W + 2*PADDING must be >= KERNEL_SIZE")
