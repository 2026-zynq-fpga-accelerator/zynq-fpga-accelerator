# Test-vector exporter: config.json + weight.bin/bias.bin/input.bin/expected_output.bin (HW_SW_Interface_v1.1 §14).
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

INTERFACE_VERSION = "1.1"


def _require_dtype(name: str, arr: np.ndarray, dtype: np.dtype) -> None:
    if arr.dtype != dtype:
        raise TypeError(f"{name} must have dtype {dtype}, got {arr.dtype}")


def export_conv_test_vector(
    output_dir: str | Path,
    *,
    input_hwc: np.ndarray,       # [IN_H, IN_W, IN_CHANNELS] int8
    weight_hwio: np.ndarray,     # [KH, KW, IN_CHANNELS, OUT_CHANNELS] int8
    bias_oc: np.ndarray,         # [OUT_CHANNELS] int32
    expected_output_hwc: np.ndarray,  # [OUT_H, OUT_W, OUT_CHANNELS] int8
    stride: int,
    padding: int,
    relu_enable: bool,
    multiplier_m: int,
    shift_n: int,
) -> Path:
    """Write a self-contained OP_CONV test vector directory per §14. Returns the directory path."""
    _require_dtype("input_hwc", input_hwc, np.int8)
    _require_dtype("weight_hwio", weight_hwio, np.int8)
    _require_dtype("bias_oc", bias_oc, np.int32)
    _require_dtype("expected_output_hwc", expected_output_hwc, np.int8)

    in_h, in_w, in_channels = input_hwc.shape
    kh, kw, kic, out_channels = weight_hwio.shape
    out_h, out_w, out_oc = expected_output_hwc.shape

    if kh != kw:
        raise ValueError("only square kernels are supported")
    if kic != in_channels:
        raise ValueError(f"weight IN_CHANNELS {kic} != input IN_CHANNELS {in_channels}")
    if bias_oc.shape != (out_channels,):
        raise ValueError(f"bias shape {bias_oc.shape} != ({out_channels},)")
    if out_oc != out_channels:
        raise ValueError(f"expected_output OUT_CHANNELS {out_oc} != weight OUT_CHANNELS {out_channels}")

    weight_bytes = kh * kw * in_channels * out_channels
    bias_bytes = out_channels * 4
    input_bytes = in_h * in_w * in_channels
    output_bytes = out_h * out_w * out_channels

    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # NHWC / HWIO iteration order (§4.2, §4.3) is exactly C-contiguous row-major order
    # for arrays shaped [H,W,C] / [KH,KW,IC,OC], so a plain .tobytes() matches the spec.
    (out_dir / "input.bin").write_bytes(input_hwc.tobytes(order="C"))
    (out_dir / "weight.bin").write_bytes(weight_hwio.tobytes(order="C"))
    (out_dir / "bias.bin").write_bytes(bias_oc.astype("<i4").tobytes(order="C"))
    (out_dir / "expected_output.bin").write_bytes(expected_output_hwc.tobytes(order="C"))

    config = {
        "interface_version": INTERFACE_VERSION,
        "operation": "OP_CONV",
        "activation_layout": "NHWC",
        "weight_layout": "HWIO",
        "input_dtype": "int8",
        "weight_dtype": "int8",
        "bias_dtype": "int32",
        "output_dtype": "int8",
        "input_height": in_h,
        "input_width": in_w,
        "in_channels": in_channels,
        "out_channels": out_channels,
        "kernel_size": kh,
        "stride": stride,
        "padding": padding,
        "relu_enable": bool(relu_enable),
        "multiplier_m": multiplier_m,
        "shift_n": shift_n,
        "output_height": out_h,
        "output_width": out_w,
        "input_bytes": input_bytes,
        "weight_bytes": weight_bytes,
        "bias_bytes": bias_bytes,
        "skip_bytes": 0,
        "output_bytes": output_bytes,
    }
    (out_dir / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    _self_check(out_dir, config, input_hwc, weight_hwio, bias_oc, expected_output_hwc)

    return out_dir


def _self_check(
    out_dir: Path,
    config: dict,
    input_hwc: np.ndarray,
    weight_hwio: np.ndarray,
    bias_oc: np.ndarray,
    expected_output_hwc: np.ndarray,
) -> None:
    """Reload every binary and confirm it round-trips exactly (§14.3)."""
    loaded = load_test_vector(out_dir)
    if not np.array_equal(loaded["input"], input_hwc):
        raise AssertionError("input.bin round-trip mismatch")
    if not np.array_equal(loaded["weight"], weight_hwio):
        raise AssertionError("weight.bin round-trip mismatch")
    if not np.array_equal(loaded["bias"], bias_oc):
        raise AssertionError("bias.bin round-trip mismatch")
    if not np.array_equal(loaded["expected_output"], expected_output_hwc):
        raise AssertionError("expected_output.bin round-trip mismatch")


def load_test_vector(directory: str | Path) -> dict:
    """Load a test-vector directory back into {config, input, weight, bias, expected_output} numpy arrays."""
    directory = Path(directory)
    config = json.loads((directory / "config.json").read_text())

    in_h = config["input_height"]
    in_w = config["input_width"]
    in_channels = config["in_channels"]
    out_channels = config["out_channels"]
    kernel = config["kernel_size"]
    out_h = config["output_height"]
    out_w = config["output_width"]

    input_hwc = np.fromfile(directory / "input.bin", dtype=np.int8).reshape(in_h, in_w, in_channels)
    weight_hwio = np.fromfile(directory / "weight.bin", dtype=np.int8).reshape(kernel, kernel, in_channels, out_channels)
    bias_oc = np.fromfile(directory / "bias.bin", dtype="<i4").astype(np.int32)
    expected_output_hwc = np.fromfile(directory / "expected_output.bin", dtype=np.int8).reshape(out_h, out_w, out_channels)

    return {
        "config": config,
        "input": input_hwc,
        "weight": weight_hwio,
        "bias": bias_oc,
        "expected_output": expected_output_hwc,
    }
