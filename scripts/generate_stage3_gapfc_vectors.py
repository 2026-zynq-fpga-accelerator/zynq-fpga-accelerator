#!/usr/bin/env python3
# Generate GAP + FC test vectors (HW_SW_Interface_v1.4_DRAFT.md §2, §3). The accelerator runs
# these as two independent OP_GLOBAL_AVG_POOL / OP_CONV(kernel=1) operations (v1.4 §3.1: FC is
# not a distinct hardware op), mirroring how generate_stage2_vectors.py decomposes a BasicBlock
# into its individual accelerator operations. There is no real 9-block backbone yet
# (STAGE3_MASTER_ROADMAP.md §2.2), so the GAP input here is a synthetic INT8 activation standing
# in for "some stage-3 BasicBlock's output" -- it is not chained from an actual trained model.
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from python.export.exporter import export_conv_test_vector, export_gap_test_vector
from python.models.golden_fixed_point import conv2d_fixed_point, global_avg_pool_fixed_point
from python.models.quantize import QuantResult, compute_output_scale, quantize_symmetric_int8
from python.models.resnet_fp import ResNet20CIFAR

NUM_CLASSES = 10
FC_OUT_CHANNELS_PADDED = 12  # v1.4 §3.3: pad 10 -> 12 real classes for 4-byte output alignment
GAP_IN_H = GAP_IN_W = 8
GAP_CHANNELS = 64
GAP_MULTIPLIER_M = 1
GAP_SHIFT_N = 6  # v1.4 §2.6: exact mean for H*W = 8*8 = 64 = 2^6, this model's only GAP call site


def generate_gap_directed(output_root: Path) -> None:
    """all-zero / max / min directed cases, per §15.5-style checklist coverage."""
    out_dir = output_root / "stage3_gap_fc" / "gap_directed"
    cases = {
        "all_zero": np.zeros((GAP_IN_H, GAP_IN_W, GAP_CHANNELS), dtype=np.int8),
        "all_max": np.full((GAP_IN_H, GAP_IN_W, GAP_CHANNELS), 127, dtype=np.int8),
        "all_min": np.full((GAP_IN_H, GAP_IN_W, GAP_CHANNELS), -128, dtype=np.int8),
    }
    for name, inp in cases.items():
        res = global_avg_pool_fixed_point(inp, multiplier_m=GAP_MULTIPLIER_M, shift_n=GAP_SHIFT_N)
        export_gap_test_vector(
            out_dir / name,
            input_hwc=inp, expected_output_c=res.output,
            multiplier_m=GAP_MULTIPLIER_M, shift_n=GAP_SHIFT_N,
        )
    print(f"GAP directed vectors written to {out_dir}")


def generate_fc_kernel1_directed(output_root: Path, seed: int) -> None:
    """Minimal IC=4/OC=4 kernel=1,H=W=1 case -- flagged in HW_SW_Interface_v1.4 §6 checklist as
    never tested in isolation before, separate from the full 64->12 FC vector below so there's a
    small standalone case to debug against."""
    rng = np.random.default_rng(seed)
    ic, oc = 4, 4
    inp = rng.integers(-128, 128, size=(1, 1, ic), dtype=np.int8)
    w = rng.integers(-128, 128, size=(1, 1, ic, oc), dtype=np.int8)
    bias = rng.integers(-1000, 1000, size=(oc,), dtype=np.int32)
    result = conv2d_fixed_point(
        inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False,
    )
    out_dir = output_root / "stage3_gap_fc" / "fc_kernel1_directed"
    export_conv_test_vector(
        out_dir, input_hwc=inp, weight_hwio=w, bias_oc=bias,
        expected_output_hwc=result.output,
        stride=1, padding=0, relu_enable=False, multiplier_m=1, shift_n=0,
    )
    print(f"FC kernel=1/H=W=1 directed vector written to {out_dir}")


def generate_gap_fc_chain(output_root: Path, seed: int) -> None:
    """End-to-end GAP -> FC chain, mirroring HW_SW_Interface_v1.4 §4 execution order:
    stage3_block_output(8x8x64) -> GAP -> gap_output(64) -> FC -> fc_output(12, first 10 valid).
    """
    out_dir = output_root / "stage3_gap_fc" / "chain"

    rng = np.random.default_rng(seed)
    block_output_q = rng.integers(-128, 128, size=(GAP_IN_H, GAP_IN_W, GAP_CHANNELS), dtype=np.int8)
    # No real backbone exists yet to derive this from (ROADMAP §2.2) -- nominal full-range scale,
    # only used below to size the FC bias's fixed-point quantization.
    block_output_scale = 1.0 / 127.0

    gap_result = global_avg_pool_fixed_point(
        block_output_q, multiplier_m=GAP_MULTIPLIER_M, shift_n=GAP_SHIFT_N,
    )
    export_gap_test_vector(
        out_dir / "gap",
        input_hwc=block_output_q, expected_output_c=gap_result.output,
        multiplier_m=GAP_MULTIPLIER_M, shift_n=GAP_SHIFT_N,
    )
    # GAP's M=1/N=6 is an exact mean (v1.4 §2.6), so it preserves the input's scale exactly.
    gap_output_scale = block_output_scale

    torch.manual_seed(seed)
    model = ResNet20CIFAR(num_classes=NUM_CLASSES)
    fc = model.fc  # nn.Linear(64, 10); random init, no training in this pipeline (matches stage2's approach)

    weight_float = fc.weight.detach().numpy()  # [10, 64], oc-major (v1.4 §3.2 gotcha)
    bias_float = fc.bias.detach().numpy()      # [10]

    weight_q = quantize_symmetric_int8(weight_float)
    fc_input_q = QuantResult(q=gap_result.output, scale=gap_output_scale)

    bias_scale = fc_input_q.scale * weight_q.scale
    bias_q_values = np.round(bias_float / bias_scale).astype(np.int32)

    # v1.4 §3.2: transpose [10,64] (oc-major) -> [64,10] (ic-major) to match HWIO's
    # index = ic*OC+oc convention for KH=KW=1, then reshape to [1,1,64,10].
    weight_hwio = weight_q.q.T.reshape(1, 1, 64, NUM_CLASSES)

    # v1.4 §3.3: zero-pad OUT_CHANNELS 10 -> 12 for 4-byte output alignment; the 2 padding
    # channels get zero weight + zero bias so their computed value is always exactly 0.
    weight_hwio_padded = np.zeros((1, 1, 64, FC_OUT_CHANNELS_PADDED), dtype=np.int8)
    weight_hwio_padded[:, :, :, :NUM_CLASSES] = weight_hwio
    bias_padded = np.zeros((FC_OUT_CHANNELS_PADDED,), dtype=np.int32)
    bias_padded[:NUM_CLASSES] = bias_q_values

    with torch.no_grad():
        dequant_input = torch.from_numpy(gap_result.output.astype(np.float64) * gap_output_scale).float()
        float_logits = fc(dequant_input).numpy()
    max_abs_logit = float(np.max(np.abs(float_logits))) or 1.0
    fc_output_scale = max_abs_logit / 127.0
    multiplier_m, shift_n = compute_output_scale(fc_input_q.scale, weight_q.scale, fc_output_scale)

    fc_input_hwc = gap_result.output.reshape(1, 1, 64)
    fc_result = conv2d_fixed_point(
        fc_input_hwc, weight_hwio_padded, bias_padded,
        stride=1, padding=0, multiplier_m=multiplier_m, shift_n=shift_n, relu_enable=False,
    )
    export_conv_test_vector(
        out_dir / "fc",
        input_hwc=fc_input_hwc, weight_hwio=weight_hwio_padded, bias_oc=bias_padded,
        expected_output_hwc=fc_result.output,
        stride=1, padding=0, relu_enable=False, multiplier_m=multiplier_m, shift_n=shift_n,
    )

    predicted_class = int(np.argmax(fc_result.output.reshape(-1)[:NUM_CLASSES]))

    (out_dir / "chain_config.json").write_text(json.dumps({
        "note": (
            "gap_output_scale is exact (GAP M=1/N=6, v1.4 §2.6); fc uses padded OUT_CHANNELS=12 "
            "(v1.4 §3.3), only bytes[0:10] are valid class scores, bytes[10:12] are always 0."
        ),
        "predicted_class": predicted_class,
        "num_valid_classes": NUM_CLASSES,
        "fc_output_channels_padded": FC_OUT_CHANNELS_PADDED,
    }, indent=2) + "\n")

    print(f"GAP->FC chain vectors written to {out_dir}, predicted_class={predicted_class}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "data" / "test_vectors")
    args = parser.parse_args()

    generate_gap_directed(args.output_dir)
    generate_fc_kernel1_directed(args.output_dir, args.seed)
    generate_gap_fc_chain(args.output_dir, args.seed)


if __name__ == "__main__":
    main()
