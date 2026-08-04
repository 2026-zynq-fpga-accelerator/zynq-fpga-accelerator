#!/usr/bin/env python3
# Generate the §13.1 canonical stage-1 single-convolution test vector
# (32x32x3 -> 32x32x16, kernel 3, stride 1, padding 1, ReLU enabled).
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from python.export.exporter import export_conv_test_vector
from python.models.bn_fold import fold_conv_bn
from python.models.golden_fixed_point import conv2d_fixed_point
from python.models.quantize import compute_output_scale, quantize_symmetric_int8
from python.models.resnet_fp import SingleConvReLU

STAGE1_CONFIG = dict(
    in_h=32, in_w=32, in_channels=3, out_channels=16,
    kernel=3, stride=1, padding=1, relu_enable=True,
)


def build_folded_conv(seed: int) -> torch.nn.Conv2d:
    """SingleConvReLU with non-trivial BN stats (defaults of mean=0/var=1 would make folding a no-op), folded per §6."""
    torch.manual_seed(seed)
    model = SingleConvReLU(
        in_channels=STAGE1_CONFIG["in_channels"],
        out_channels=STAGE1_CONFIG["out_channels"],
        stride=STAGE1_CONFIG["stride"],
        padding=STAGE1_CONFIG["padding"],
    )
    conv, bn = model.conv_bn_relu[0], model.conv_bn_relu[1]
    with torch.no_grad():
        bn.running_mean.copy_(0.1 * torch.randn(bn.num_features))
        bn.running_var.copy_(0.5 + torch.rand(bn.num_features))
    bn.eval()
    return fold_conv_bn(conv, bn)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument(
        "--output-dir", type=Path,
        default=REPO_ROOT / "data" / "test_vectors" / "stage1_conv",
    )
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)

    folded_conv = build_folded_conv(args.seed)
    weight_float = folded_conv.weight.detach().numpy()  # [OC, IC, KH, KW] (PyTorch layout)
    bias_float = folded_conv.bias.detach().numpy()       # [OC]
    weight_hwio_float = np.transpose(weight_float, (2, 3, 1, 0))  # -> HWIO (§4.3)

    weight_q = quantize_symmetric_int8(weight_hwio_float)

    input_float = rng.normal(
        loc=0.0, scale=1.0,
        size=(STAGE1_CONFIG["in_h"], STAGE1_CONFIG["in_w"], STAGE1_CONFIG["in_channels"]),
    )
    input_q = quantize_symmetric_int8(input_float)

    bias_scale = input_q.scale * weight_q.scale
    bias_q_values = np.round(bias_float / bias_scale).astype(np.int32)

    # Calibrate OUTPUT_SCALE from the folded float model's pre-quantization output range,
    # so the INT8 output dynamic range is used well instead of guessed.
    with torch.no_grad():
        x = torch.from_numpy(input_float).permute(2, 0, 1).unsqueeze(0).float()
        float_output = folded_conv(x).squeeze(0).permute(1, 2, 0).numpy()
    max_abs_output = float(np.max(np.abs(float_output))) or 1.0
    output_scale = max_abs_output / 127.0

    multiplier_m, shift_n = compute_output_scale(input_q.scale, weight_q.scale, output_scale)

    result = conv2d_fixed_point(
        input_q.q, weight_q.q, bias_q_values,
        stride=STAGE1_CONFIG["stride"], padding=STAGE1_CONFIG["padding"],
        multiplier_m=multiplier_m, shift_n=shift_n, relu_enable=STAGE1_CONFIG["relu_enable"],
    )

    out_dir = export_conv_test_vector(
        args.output_dir,
        input_hwc=input_q.q, weight_hwio=weight_q.q, bias_oc=bias_q_values,
        expected_output_hwc=result.output,
        stride=STAGE1_CONFIG["stride"], padding=STAGE1_CONFIG["padding"],
        relu_enable=STAGE1_CONFIG["relu_enable"],
        multiplier_m=multiplier_m, shift_n=shift_n,
    )

    print(f"stage-1 test vector written to {out_dir}")
    print(f"  input_scale={input_q.scale:.6f} weight_scale={weight_q.scale:.6f} output_scale={output_scale:.6f}")
    print(f"  multiplier_m={multiplier_m} shift_n={shift_n} accumulator_overflow={result.overflow}")


if __name__ == "__main__":
    main()
