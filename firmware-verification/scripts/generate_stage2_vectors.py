#!/usr/bin/env python3
# Generate stage-2 BasicBlock test vectors (project doc §5 단계 2), decomposed into the
# individual OP_CONV operations the v1.1 accelerator can actually run (accel_driver.c:
# "only OP_CONV is implemented"; SKIP_BYTES / residual add is a v1.2 extension). Each
# conv1/conv2/shortcut piece is a standalone stage-1-style vector; conv2's output_scale
# and the shortcut path are forced onto the same INT8 scale so a future residual-add step
# (firmware software path today, possibly RTL v1.2 later) can add them directly. The
# combined block's own expected output (post add + ReLU) is exported for that future step
# to be checked against, not for the accelerator itself.
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from python.export.exporter import export_conv_test_vector
from python.models.bn_fold import fold_conv_bn
from python.models.golden_fixed_point import conv2d_fixed_point
from python.models.quantize import QuantResult, compute_output_scale, quantize_symmetric_int8
from python.models.resnet_fp import BasicBlock
from python.utils.fixed_point import requantize

# Matches the two structurally distinct BasicBlocks in ResNet20CIFAR (resnet_fp.py):
# an interior block (identity shortcut) and a stage-transition block (projection shortcut).
BLOCK_CONFIGS = {
    "identity": dict(in_h=32, in_w=32, in_channels=16, out_channels=16, stride=1),
    "projection": dict(in_h=32, in_w=32, in_channels=16, out_channels=32, stride=2),
}


@dataclass
class ConvVectorResult:
    output_q: np.ndarray   # [OUT_H, OUT_W, OUT_CHANNELS] int8
    output_scale: float
    float_output: np.ndarray  # [OUT_H, OUT_W, OUT_CHANNELS] float, feeds the next conv's calibration


def _fold_with_random_bn_stats(conv: nn.Conv2d, bn: nn.BatchNorm2d, seed: int) -> nn.Conv2d:
    """Default BN stats (mean=0/var=1) make folding a no-op; inject stats like generate_stage1_vectors.py does."""
    torch.manual_seed(seed)
    with torch.no_grad():
        bn.running_mean.copy_(0.1 * torch.randn(bn.num_features))
        bn.running_var.copy_(0.5 + torch.rand(bn.num_features))
    bn.eval()
    return fold_conv_bn(conv, bn)


def _quantize_and_export_conv(
    output_dir: Path,
    folded_conv: nn.Conv2d,
    input_float_hwc: np.ndarray,
    input_q: QuantResult,
    stride: int,
    padding: int,
    relu_enable: bool,
    target_output_scale: float | None,
) -> ConvVectorResult:
    weight_float = folded_conv.weight.detach().numpy()  # [OC, IC, KH, KW]
    bias_float = folded_conv.bias.detach().numpy()
    weight_hwio_float = np.transpose(weight_float, (2, 3, 1, 0))  # -> HWIO (§4.3)
    weight_q = quantize_symmetric_int8(weight_hwio_float)

    bias_scale = input_q.scale * weight_q.scale
    bias_q_values = np.round(bias_float / bias_scale).astype(np.int32)

    with torch.no_grad():
        x = torch.from_numpy(input_float_hwc).permute(2, 0, 1).unsqueeze(0).float()
        float_output = folded_conv(x).squeeze(0).permute(1, 2, 0).numpy()

    if target_output_scale is None:
        # Self-calibrated, exactly like generate_stage1_vectors.py.
        max_abs_output = float(np.max(np.abs(float_output))) or 1.0
        output_scale = max_abs_output / 127.0
    else:
        # Forced onto the shared residual-add scale instead of this conv's own float range.
        output_scale = target_output_scale

    multiplier_m, shift_n = compute_output_scale(input_q.scale, weight_q.scale, output_scale)

    result = conv2d_fixed_point(
        input_q.q, weight_q.q, bias_q_values,
        stride=stride, padding=padding,
        multiplier_m=multiplier_m, shift_n=shift_n, relu_enable=relu_enable,
    )

    export_conv_test_vector(
        output_dir,
        input_hwc=input_q.q, weight_hwio=weight_q.q, bias_oc=bias_q_values,
        expected_output_hwc=result.output,
        stride=stride, padding=padding, relu_enable=relu_enable,
        multiplier_m=multiplier_m, shift_n=shift_n,
    )

    return ConvVectorResult(output_q=result.output, output_scale=output_scale, float_output=float_output)


def _rescale_int8(values_int8: np.ndarray, from_scale: float, to_scale: float) -> np.ndarray:
    """INT8->INT8 requantization onto a different scale, via the same (M,N) mechanism as a conv's
    OUTPUT_SCALE register (weight=1, i.e. a pure passthrough) — used for the identity shortcut path,
    which has no conv of its own but still needs conv2's output scale to be addable."""
    multiplier_m, shift_n = compute_output_scale(from_scale, 1.0, to_scale)
    rescaled = np.vectorize(lambda v: requantize(int(v), multiplier_m, shift_n))(values_int8.astype(np.int64))
    return np.clip(rescaled, -128, 127).astype(np.int8)


def _combine_residual(conv2_output_q: np.ndarray, shortcut_output_q: np.ndarray) -> np.ndarray:
    """out + identity, then ReLU (BasicBlock.forward's final two lines), both already on the same scale."""
    raw_sum = conv2_output_q.astype(np.int32) + shortcut_output_q.astype(np.int32)
    return np.clip(np.maximum(raw_sum, 0), -128, 127).astype(np.int8)


def generate_block(variant: str, seed: int, output_root: Path) -> None:
    cfg = BLOCK_CONFIGS[variant]
    out_dir = output_root / f"stage2_basicblock_{variant}"

    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    block = BasicBlock(cfg["in_channels"], cfg["out_channels"], stride=cfg["stride"])

    input_float = rng.normal(loc=0.0, scale=1.0, size=(cfg["in_h"], cfg["in_w"], cfg["in_channels"]))
    input_q = quantize_symmetric_int8(input_float)

    # conv1: block input -> ReLU'd intermediate (relu=True, per BasicBlock.conv1).
    conv1 = _fold_with_random_bn_stats(block.conv1[0], block.conv1[1], seed)
    conv1_result = _quantize_and_export_conv(
        out_dir / "conv1", conv1, input_float, input_q,
        stride=cfg["stride"], padding=1, relu_enable=True, target_output_scale=None,
    )
    conv1_output_q = QuantResult(q=conv1_result.output_q, scale=conv1_result.output_scale)

    # conv2: chained from conv1's INT8 output, exactly how firmware DMAs it — no ReLU yet
    # (BasicBlock applies ReLU only after the residual add).
    conv2 = _fold_with_random_bn_stats(block.conv2[0], block.conv2[1], seed + 1)
    conv2_result = _quantize_and_export_conv(
        out_dir / "conv2", conv2, conv1_result.float_output, conv1_output_q,
        stride=1, padding=1, relu_enable=False, target_output_scale=None,
    )

    # Shortcut branches off the *block* input, not conv1's output, and is forced onto
    # conv2's output scale so the add below is a plain INT8 add.
    if isinstance(block.shortcut, nn.Identity):
        shortcut_output_q = _rescale_int8(input_q.q, input_q.scale, conv2_result.output_scale)
    else:
        shortcut = _fold_with_random_bn_stats(block.shortcut[0], block.shortcut[1], seed + 2)
        shortcut_result = _quantize_and_export_conv(
            out_dir / "shortcut", shortcut, input_float, input_q,
            stride=cfg["stride"], padding=0, relu_enable=False,
            target_output_scale=conv2_result.output_scale,
        )
        shortcut_output_q = shortcut_result.output_q

    final_output_q = _combine_residual(conv2_result.output_q, shortcut_output_q)

    residual_dir = out_dir / "residual"
    residual_dir.mkdir(parents=True, exist_ok=True)
    (residual_dir / "final_expected_output.bin").write_bytes(final_output_q.tobytes(order="C"))
    if isinstance(block.shortcut, nn.Identity):
        (residual_dir / "shortcut_rescaled.bin").write_bytes(shortcut_output_q.tobytes(order="C"))

    import json
    (residual_dir / "residual_config.json").write_text(json.dumps({
        "variant": variant,
        "note": (
            "final_expected_output is NOT produced by the v1.1 accelerator (OP_CONV only; "
            "residual add is a v1.2 extension per accel_driver.c ACCEL_REG_SKIP_BYTES comment). "
            "It is the target for whatever adds conv2's output_bin to the shortcut path "
            "(software today, possibly RTL later) — relu(sat_add_int8(conv2_output, shortcut))."
        ),
        "in_channels": cfg["in_channels"], "out_channels": cfg["out_channels"], "stride": cfg["stride"],
        "shortcut_kind": "identity" if isinstance(block.shortcut, nn.Identity) else "projection",
        "residual_scale": conv2_result.output_scale,
    }, indent=2) + "\n")

    print(f"stage-2 '{variant}' vectors written to {out_dir}")
    print(f"  conv1: -> {conv1_result.output_q.shape} scale={conv1_result.output_scale:.6f}")
    print(f"  conv2/shortcut shared residual_scale={conv2_result.output_scale:.6f}")
    print(f"  final block output: {final_output_q.shape}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument(
        "--output-dir", type=Path,
        default=REPO_ROOT / "data" / "test_vectors",
    )
    args = parser.parse_args()

    for variant in BLOCK_CONFIGS:
        generate_block(variant, args.seed, args.output_dir)


if __name__ == "__main__":
    main()
