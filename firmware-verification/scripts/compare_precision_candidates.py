#!/usr/bin/env python3
"""
SW-only comparison of FP32 / FP16 / INT8 / INT4 as candidate weight+activation formats
for this project's ResNet-20 (CIFAR-10) accelerator, to narrow down which format(s) are
worth actually verifying on hardware.

"""
from __future__ import annotations

import copy
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from python.models.resnet_fp import ResNet20CIFAR  # noqa: E402
from python.models.bn_fold import fold_batchnorm_in_module  # noqa: E402

torch.manual_seed(0)

BIAS_BYTES_PER_ELEMENT = 4.0  # bias always INT32 in the real RTL, independent of format


@dataclass
class Format:
    name: str
    bytes_per_element: float          # storage/traffic cost per weight or activation element
    transform: "callable"             # fp32 tensor -> fake-quantized/rounded fp32 tensor


def fake_quantize_symmetric(x: torch.Tensor, bits: int) -> torch.Tensor:
    qmax = 2 ** (bits - 1) - 1
    max_abs = x.abs().max()
    if max_abs == 0:
        return x
    scale = max_abs / qmax
    q = torch.clamp(torch.round(x / scale), -qmax, qmax)
    return q * scale


def fp16_round_trip(x: torch.Tensor) -> torch.Tensor:
    return x.to(torch.float16).to(torch.float32)


FORMATS = [
    Format("FP32", 4.0, lambda x: x),
    Format("FP16", 2.0, fp16_round_trip),
    Format("INT8", 1.0, lambda x: fake_quantize_symmetric(x, 8)),
    Format("INT4", 0.5, lambda x: fake_quantize_symmetric(x, 4)),
]


def sqnr_db(ref: torch.Tensor, approx: torch.Tensor) -> float:
    signal_power = (ref ** 2).sum()
    noise_power = ((ref - approx) ** 2).sum()
    if noise_power == 0:
        return float("inf")
    return 10 * math.log10((signal_power / noise_power).item())


def rel_l2_error(ref: torch.Tensor, approx: torch.Tensor) -> float:
    denom = ref.norm()
    if denom == 0:
        return 0.0
    return ((ref - approx).norm() / denom).item()


def build_folded_model() -> nn.Module:
    model = ResNet20CIFAR()
    model.eval()
    fold_batchnorm_in_module(model)
    return model


class ActivationFakeQuantHook:
    def __init__(self, transform):
        self.transform = transform

    def __call__(self, module: nn.Module, inputs):
        (x,) = inputs
        return (self.transform(x),)


def apply_format(model: nn.Module, fmt: Format) -> list:
    """Quantizes every Conv2d/Linear weight (and INT32 bias) in place, and attaches
    activation fake-quant hooks. Returns hook handles to remove afterward."""
    handles = []
    for m in model.modules():
        if isinstance(m, (nn.Conv2d, nn.Linear)):
            with torch.no_grad():
                m.weight.data.copy_(fmt.transform(m.weight.data))
            if m.bias is not None:
                with torch.no_grad():
                    m.bias.data.copy_(fake_quantize_symmetric(m.bias.data, 32))
            handles.append(m.register_forward_pre_hook(ActivationFakeQuantHook(fmt.transform)))
    return handles


@dataclass
class LayerShape:
    name: str
    kind: str            # "conv" or "linear"
    weight_numel: int
    bias_numel: int
    in_numel: int         # activation elements read (single sample)
    out_numel: int        # activation elements written (single sample)


def probe_layer_shapes(model: nn.Module, sample: torch.Tensor) -> list[LayerShape]:
    shapes: list[LayerShape] = []
    handles = []

    def make_hook(name, module):
        def hook(mod, inputs, output):
            (x,) = inputs
            shapes.append(LayerShape(
                name=name,
                kind="conv" if isinstance(mod, nn.Conv2d) else "linear",
                weight_numel=mod.weight.numel(),
                bias_numel=mod.bias.numel() if mod.bias is not None else 0,
                in_numel=x.numel(),
                out_numel=output.numel(),
            ))
        return hook

    for n, m in model.named_modules():
        if isinstance(m, (nn.Conv2d, nn.Linear)):
            handles.append(m.register_forward_hook(make_hook(n, m)))

    with torch.no_grad():
        model(sample)

    for h in handles:
        h.remove()
    return shapes


def estimate_traffic_bytes(shapes: list[LayerShape], fmt: Format) -> tuple[float, float, float]:
    """Returns (weight_bytes, activation_bytes, bias_bytes) totals across all layers."""
    weight_bytes = sum(s.weight_numel * fmt.bytes_per_element for s in shapes)
    activation_bytes = sum((s.in_numel + s.out_numel) * fmt.bytes_per_element for s in shapes)
    bias_bytes = sum(s.bias_numel * BIAS_BYTES_PER_ELEMENT for s in shapes)
    return weight_bytes, activation_bytes, bias_bytes


def main() -> None:
    fp32_model = build_folded_model()
    single_image = torch.randn(1, 3, 32, 32)
    batch = torch.randn(64, 3, 32, 32)

    shapes = probe_layer_shapes(fp32_model, single_image)
    n_conv = sum(1 for s in shapes if s.kind == "conv")
    n_linear = sum(1 for s in shapes if s.kind == "linear")

    with torch.no_grad():
        fp32_logits = fp32_model(batch)
    fp32_argmax = fp32_logits.argmax(dim=1)

    fp32_weight_bytes, _, _ = estimate_traffic_bytes(shapes, FORMATS[0])

    print(f"architecture: {n_conv} conv layers + {n_linear} linear layer, "
          f"{sum(s.weight_numel for s in shapes):,} total weight params")
    print()
    header = (f"{'format':>6} | {'logits_rel_L2':>13} | {'SQNR_dB':>9} | {'decision_agree%':>15} | "
              f"{'weight_KB':>10} | {'vs FP32':>8} | {'activation_KB':>13} | "
              f"{'traffic_KB/img':>15} | {'vs FP32':>8}")
    print(header)
    print("-" * len(header))

    for fmt in FORMATS:
        model = copy.deepcopy(fp32_model)
        handles = apply_format(model, fmt)
        with torch.no_grad():
            q_logits = model(batch)
        for h in handles:
            h.remove()

        logits_rel_l2 = rel_l2_error(fp32_logits, q_logits)
        logits_sqnr = sqnr_db(fp32_logits, q_logits)
        agree_pct = (q_logits.argmax(dim=1) == fp32_argmax).float().mean().item() * 100

        weight_bytes, activation_bytes, bias_bytes = estimate_traffic_bytes(shapes, fmt)
        total_traffic = weight_bytes + activation_bytes + bias_bytes

        fp32_weight_kb = fp32_weight_bytes / 1024
        fp32_traffic_kb = None  # filled after FP32 row computed first (FP32 is FORMATS[0])
        if fmt.name == "FP32":
            fp32_traffic_kb_ref = total_traffic / 1024

        weight_kb = weight_bytes / 1024
        activation_kb = activation_bytes / 1024
        traffic_kb = total_traffic / 1024

        sqnr_str = "inf" if math.isinf(logits_sqnr) else f"{logits_sqnr:.2f}"
        print(f"{fmt.name:>6} | {logits_rel_l2*100:>12.3f}% | {sqnr_str:>9} | {agree_pct:>14.2f}% | "
              f"{weight_kb:>10.1f} | {fp32_weight_kb/weight_kb:>7.2f}x | {activation_kb:>13.1f} | "
              f"{traffic_kb:>15.1f} | {fp32_traffic_kb_ref/traffic_kb:>7.2f}x")

    print()
    print("caveat: 'decision_agree%' is agreement with the FP32 model's own argmax on random")
    print("        untrained weights -- a numeric-stability proxy, NOT real CIFAR-10 accuracy")
    print("        (weights are random-initialized per FINAL_SUBMISSION_REPORT.md SS11 item 6).")
    print(f"traffic model: sum over {n_conv + n_linear} layers of (weight_read + bias_read(INT32) +")
    print("        input_read + output_write), matching this project's per-layer DMA round-trip")
    print("        architecture (no on-chip cross-layer cache) -- see resnet_scheduler.c / controller_fsm.sv.")


if __name__ == "__main__":
    main()
