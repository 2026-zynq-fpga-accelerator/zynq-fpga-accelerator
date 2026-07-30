#!/usr/bin/env python3
"""Generate an independent deterministic v1.1 OP_CONV verification vector."""

from __future__ import annotations

import json
import random
import struct
from pathlib import Path

SEED = 20260730
INPUT_H = 32
INPUT_W = 32
IN_CHANNELS = 3
OUT_CHANNELS = 16
KERNEL = 3
STRIDE = 1
PADDING = 1
MULTIPLIER = 3
SHIFT = 2
RELU = True
INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


def sat_int32(value: int) -> int:
    return min(INT32_MAX, max(INT32_MIN, value))


def requantize(accumulator: int, multiplier: int, shift: int) -> int:
    product = accumulator * multiplier
    magnitude = abs(product)
    if shift:
        magnitude = (magnitude + (1 << (shift - 1))) >> shift
    return -magnitude if product < 0 else magnitude


def int8_clamp(value: int, relu: bool) -> int:
    if relu and value < 0:
        value = 0
    return min(127, max(-128, value))


def signed_byte(value: int) -> int:
    return value & 0xFF


def write_hex(path: Path, values: list[int], width: int) -> None:
    mask = (1 << (width * 4)) - 1
    path.write_text("".join(f"{value & mask:0{width}x}\n" for value in values), encoding="ascii")


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    output_dir = repo_root / "vectors" / "full_conv_32x32x3x16"
    output_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(SEED)
    input_values = [rng.randint(-4, 4) for _ in range(INPUT_H * INPUT_W * IN_CHANNELS)]
    weight_values = [
        rng.randint(-3, 3)
        for _ in range(KERNEL * KERNEL * IN_CHANNELS * OUT_CHANNELS)
    ]
    bias_values = []
    while len(bias_values) < OUT_CHANNELS:
        value = rng.randint(-31, 31)
        if value != 0:
            bias_values.append(value)

    output_h = ((INPUT_H + 2 * PADDING - KERNEL) // STRIDE) + 1
    output_w = ((INPUT_W + 2 * PADDING - KERNEL) // STRIDE) + 1
    expected: list[int] = []
    mac_accumulators: list[int] = []
    biased_accumulators: list[int] = []
    requantized_values: list[int] = []

    # Independent loop nest derived from NHWC activation and HWIO weight indexing.
    for oh in range(output_h):
        for ow in range(output_w):
            for oc in range(OUT_CHANNELS):
                accumulator = 0
                for kh in range(KERNEL):
                    for kw in range(KERNEL):
                        iy = oh * STRIDE + kh - PADDING
                        ix = ow * STRIDE + kw - PADDING
                        for ic in range(IN_CHANNELS):
                            if 0 <= iy < INPUT_H and 0 <= ix < INPUT_W:
                                input_index = ((iy * INPUT_W) + ix) * IN_CHANNELS + ic
                                input_value = input_values[input_index]
                            else:
                                input_value = 0
                            weight_index = (
                                (((kh * KERNEL) + kw) * IN_CHANNELS + ic)
                                * OUT_CHANNELS
                                + oc
                            )
                            accumulator = sat_int32(
                                accumulator + input_value * weight_values[weight_index]
                            )
                mac_accumulators.append(accumulator)
                biased = sat_int32(accumulator + bias_values[oc])
                biased_accumulators.append(biased)
                requantized = requantize(biased, MULTIPLIER, SHIFT)
                requantized_values.append(requantized)
                expected.append(int8_clamp(requantized, RELU))

    config = {
        "format": "HW_SW_Interface_v1.1 OP_CONV",
        "seed": SEED,
        "batch": 1,
        "input_layout": "NHWC",
        "weight_layout": "HWIO",
        "input_height": INPUT_H,
        "input_width": INPUT_W,
        "in_channels": IN_CHANNELS,
        "out_channels": OUT_CHANNELS,
        "kernel_size": KERNEL,
        "stride": STRIDE,
        "padding": PADDING,
        "relu_enable": RELU,
        "multiplier": MULTIPLIER,
        "shift": SHIFT,
        "input_bytes": len(input_values),
        "weight_bytes": len(weight_values),
        "bias_bytes": len(bias_values) * 4,
        "output_height": output_h,
        "output_width": output_w,
        "output_bytes": len(expected),
        "bias_binary_endianness": "little",
        "packet_order": ["weight", "bias", "input"],
    }
    (output_dir / "config.json").write_text(
        json.dumps(config, indent=2) + "\n", encoding="utf-8"
    )
    (output_dir / "input.bin").write_bytes(bytes(map(signed_byte, input_values)))
    (output_dir / "weight.bin").write_bytes(bytes(map(signed_byte, weight_values)))
    (output_dir / "bias.bin").write_bytes(
        b"".join(struct.pack("<i", value) for value in bias_values)
    )
    (output_dir / "expected_output.bin").write_bytes(bytes(map(signed_byte, expected)))

    write_hex(output_dir / "input.hex", input_values, 2)
    write_hex(output_dir / "weight.hex", weight_values, 2)
    write_hex(output_dir / "bias.hex", bias_values, 8)
    write_hex(output_dir / "expected_output.hex", expected, 2)
    write_hex(output_dir / "mac_accumulator.hex", mac_accumulators, 8)
    write_hex(output_dir / "biased_accumulator.hex", biased_accumulators, 8)
    write_hex(output_dir / "requantized.hex", requantized_values, 16)

    print(
        "VECTOR PASS: "
        f"seed={SEED} weight={len(weight_values)} bias={len(bias_values) * 4} "
        f"input={len(input_values)} output={len(expected)}"
    )


if __name__ == "__main__":
    main()
