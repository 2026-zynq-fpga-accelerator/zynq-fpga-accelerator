#!/usr/bin/env python3
# Generate the full 9-block ResNet-20 CIFAR backbone test vectors (STAGE3_MASTER_ROADMAP.md §2.2):
# stem -> stage1 (3x BasicBlock, 16ch) -> stage2 (1x projection + 2x identity, 32ch) -> stage3
# (1x projection + 2x identity, 64ch) -> OP_GLOBAL_AVG_POOL -> FC(=OP_CONV kernel=1) -> predicted
# class. Decomposed into the accelerator's actual per-operation granularity (OP_CONV for
# stem/conv1/conv2/shortcut, software residual-add combine per block), same pattern as
# generate_stage2_vectors.py but driven from the real ResNet20CIFAR module's 9 real BasicBlocks
# chained end-to-end instead of one standalone synthetic block at a time.
#
# Identity-shortcut scale handling: OP_RESIDUAL_ADD does a plain INT8 add with no requantization
# (HW_SW_Interface_v1.2_DRAFT.md §2.2), so MAIN (conv2's output) and SKIP (the raw block input, for
# identity blocks) must already share one scale. Earlier single-block tests faked this offline
# (rescaling a fixed constant) since there was no real upstream block; here conv2 is instead
# quantized with target_output_scale=input_q.scale for every identity block (the same
# target_output_scale mechanism already used to force projection shortcuts onto conv2's scale,
# just applied in the other direction) so MAIN and SKIP match by construction -- the raw
# (previous block's or stem's) INT8 output is reused directly as SKIP, no rescale step at all.
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from python.export.exporter import export_conv_test_vector, export_gap_test_vector
from python.models.bn_fold import fold_conv_bn
from python.models.golden_fixed_point import conv2d_fixed_point, global_avg_pool_fixed_point
from python.models.quantize import QuantResult, compute_output_scale, quantize_symmetric_int8
from python.models.resnet_fp import BasicBlock, ResNet20CIFAR

NUM_CLASSES = 10
FC_OUT_CHANNELS_PADDED = 12  # HW_SW_Interface_v1.4_FINAL.md §3.3
GAP_MULTIPLIER_M = 1  # HW_SW_Interface_v1.4_FINAL.md §2.6


@dataclass
class ConvVectorResult:
    output_q: np.ndarray
    output_scale: float
    float_output: np.ndarray


def _fold_with_random_bn_stats(conv: nn.Conv2d, bn: nn.BatchNorm2d, seed: int) -> nn.Conv2d:
    """Default BN stats (mean=0/var=1) make folding a no-op; inject stats like generate_stage1/2_vectors.py do."""
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
        max_abs_output = float(np.max(np.abs(float_output))) or 1.0
        output_scale = max_abs_output / 127.0
    else:
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


def _combine_residual(conv2_output_q: np.ndarray, shortcut_output_q: np.ndarray) -> np.ndarray:
    """out + identity, then ReLU (BasicBlock.forward's final two lines), both already on the same scale."""
    raw_sum = conv2_output_q.astype(np.int32) + shortcut_output_q.astype(np.int32)
    return np.clip(np.maximum(raw_sum, 0), -128, 127).astype(np.int8)


def process_block(
    block: BasicBlock,
    block_index: int,
    input_float_hwc: np.ndarray,
    input_q: QuantResult,
    out_root: Path,
    seed: int,
) -> tuple[QuantResult, np.ndarray, str]:
    """Quantize+export one real BasicBlock's conv1/conv2/[shortcut]/residual, chained from the
    previous block's (or stem's) actual output. Returns (output_q, float_output, shortcut_kind)."""
    block_dir = out_root / f"block{block_index:02d}"
    is_identity = isinstance(block.shortcut, nn.Identity)

    conv1_stride = block.conv1[0].stride[0]
    conv1_padding = block.conv1[0].padding[0]
    conv1 = _fold_with_random_bn_stats(block.conv1[0], block.conv1[1], seed)
    conv1_result = _quantize_and_export_conv(
        block_dir / "conv1", conv1, input_float_hwc, input_q,
        stride=conv1_stride, padding=conv1_padding, relu_enable=True, target_output_scale=None,
    )
    conv1_output_q = QuantResult(q=conv1_result.output_q, scale=conv1_result.output_scale)

    conv2_padding = block.conv2[0].padding[0]
    conv2 = _fold_with_random_bn_stats(block.conv2[0], block.conv2[1], seed + 1)
    conv2_target_scale = input_q.scale if is_identity else None
    conv2_result = _quantize_and_export_conv(
        block_dir / "conv2", conv2, conv1_result.float_output, conv1_output_q,
        stride=1, padding=conv2_padding, relu_enable=False, target_output_scale=conv2_target_scale,
    )

    if is_identity:
        # target_output_scale above forces conv2_result.output_scale == input_q.scale exactly, so
        # the raw upstream INT8 output IS already the correctly-scaled SKIP tensor -- no rescale.
        shortcut_output_q = input_q.q
        shortcut_kind = "identity"
        shortcut_module = None
    else:
        shortcut_stride = block.shortcut[0].stride[0]
        shortcut_module = _fold_with_random_bn_stats(block.shortcut[0], block.shortcut[1], seed + 2)
        shortcut_result = _quantize_and_export_conv(
            block_dir / "shortcut", shortcut_module, input_float_hwc, input_q,
            stride=shortcut_stride, padding=0, relu_enable=False,
            target_output_scale=conv2_result.output_scale,
        )
        shortcut_output_q = shortcut_result.output_q
        shortcut_kind = "projection"

    final_output_q = _combine_residual(conv2_result.output_q, shortcut_output_q)

    residual_dir = block_dir / "residual"
    residual_dir.mkdir(parents=True, exist_ok=True)
    (residual_dir / "final_expected_output.bin").write_bytes(final_output_q.tobytes(order="C"))
    (residual_dir / "residual_config.json").write_text(json.dumps({
        "block_index": block_index,
        "shortcut_kind": shortcut_kind,
        "block_scale": conv2_result.output_scale,
    }, indent=2) + "\n")

    # True float block output (BasicBlock.forward's algebra, using the same folded conv modules),
    # used only as the next block's calibration input -- doesn't affect the exported INT8 vectors.
    with torch.no_grad():
        x = torch.from_numpy(input_float_hwc).permute(2, 0, 1).unsqueeze(0).float()
        identity_float = x if is_identity else shortcut_module(x)
        conv1_float = torch.relu(conv1(x))
        conv2_float = conv2(conv1_float)
        float_block_output = torch.relu(conv2_float + identity_float).squeeze(0).permute(1, 2, 0).numpy()

    output_q = QuantResult(q=final_output_q, scale=conv2_result.output_scale)
    return output_q, float_block_output, shortcut_kind


def generate_backbone(seed: int, output_root: Path) -> None:
    out_dir = output_root / "stage3_backbone"

    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    model = ResNet20CIFAR(num_classes=NUM_CLASSES)

    input_float = rng.normal(loc=0.0, scale=1.0, size=(32, 32, 3))
    input_q = quantize_symmetric_int8(input_float)

    stem_conv = _fold_with_random_bn_stats(model.stem[0], model.stem[1], seed)
    stem_result = _quantize_and_export_conv(
        out_dir / "stem", stem_conv, input_float, input_q,
        stride=1, padding=1, relu_enable=True, target_output_scale=None,
    )
    current_q = QuantResult(q=stem_result.output_q, scale=stem_result.output_scale)
    current_float = stem_result.float_output

    per_block_summary = []
    block_index = 0
    for stage in (model.stage1, model.stage2, model.stage3):
        for block in stage:
            block_index += 1
            output_q, float_output, shortcut_kind = process_block(
                block, block_index, current_float, current_q, out_dir, seed + block_index * 10,
            )
            per_block_summary.append({
                "block_index": block_index, "shortcut_kind": shortcut_kind, "scale": output_q.scale,
                "shape": list(output_q.q.shape),
            })
            print(f"  block{block_index:02d} ({shortcut_kind}): shape={output_q.q.shape} scale={output_q.scale:.6f}")
            current_q, current_float = output_q, float_output

    # current_q is now block09's output = stage3_output (8x8x64), feeds GAP -> FC (v1.4 FINAL).
    gap_in_h, gap_in_w, gap_channels = current_q.q.shape
    gap_shift_n = int(np.log2(gap_in_h * gap_in_w))
    assert (1 << gap_shift_n) == gap_in_h * gap_in_w, "GAP §2.6 assumes H*W is a power of two"

    gap_result = global_avg_pool_fixed_point(current_q.q, multiplier_m=GAP_MULTIPLIER_M, shift_n=gap_shift_n)
    export_gap_test_vector(
        out_dir / "gap",
        input_hwc=current_q.q, expected_output_c=gap_result.output,
        multiplier_m=GAP_MULTIPLIER_M, shift_n=gap_shift_n,
    )
    gap_output_scale = current_q.scale  # exact mean, preserves scale (§2.6)

    fc = model.fc
    weight_float = fc.weight.detach().numpy()  # [NUM_CLASSES, gap_channels], oc-major
    bias_float = fc.bias.detach().numpy()

    weight_q = quantize_symmetric_int8(weight_float)
    fc_input_q = QuantResult(q=gap_result.output, scale=gap_output_scale)

    bias_scale = fc_input_q.scale * weight_q.scale
    bias_q_values = np.round(bias_float / bias_scale).astype(np.int32)

    weight_hwio = weight_q.q.T.reshape(1, 1, gap_channels, NUM_CLASSES)
    weight_hwio_padded = np.zeros((1, 1, gap_channels, FC_OUT_CHANNELS_PADDED), dtype=np.int8)
    weight_hwio_padded[:, :, :, :NUM_CLASSES] = weight_hwio
    bias_padded = np.zeros((FC_OUT_CHANNELS_PADDED,), dtype=np.int32)
    bias_padded[:NUM_CLASSES] = bias_q_values

    with torch.no_grad():
        dequant_input = torch.from_numpy(gap_result.output.astype(np.float64) * gap_output_scale).float()
        float_logits = fc(dequant_input).numpy()
    max_abs_logit = float(np.max(np.abs(float_logits))) or 1.0
    fc_output_scale = max_abs_logit / 127.0
    multiplier_m, shift_n = compute_output_scale(fc_input_q.scale, weight_q.scale, fc_output_scale)

    fc_input_hwc = gap_result.output.reshape(1, 1, gap_channels)
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
            "Full stem->9 BasicBlock->GAP->FC chain (STAGE3_MASTER_ROADMAP.md §2.2). Identity "
            "blocks force conv2 onto the block input's scale (no runtime rescale); projection "
            "blocks force their shortcut conv onto conv2's scale (existing v1.2 mechanism). FC "
            "uses padded OUT_CHANNELS=12 (v1.4 §3.3), only bytes[0:10] are valid class scores."
        ),
        "num_blocks": block_index,
        "per_block": per_block_summary,
        "predicted_class": predicted_class,
        "num_valid_classes": NUM_CLASSES,
        "fc_output_channels_padded": FC_OUT_CHANNELS_PADDED,
    }, indent=2) + "\n")

    print(f"stage-3 backbone vectors written to {out_dir}")
    print(f"  stem: shape={stem_result.output_q.shape} scale={stem_result.output_scale:.6f}")
    print(f"  gap: shape={gap_result.output.shape} scale={gap_output_scale:.6f}")
    print(f"  fc: predicted_class={predicted_class}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "data" / "test_vectors")
    args = parser.parse_args()

    generate_backbone(args.seed, args.output_dir)


if __name__ == "__main__":
    main()
