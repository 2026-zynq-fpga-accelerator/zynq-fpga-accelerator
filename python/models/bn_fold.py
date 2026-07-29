# Conv2d + BatchNorm2d folding into a single Conv2d (project doc §6):
#   z = Wx + b ; y = gamma*(z-mu)/sqrt(var+eps) + beta
#   W' = (gamma/sqrt(var+eps)) * W ; b' = (gamma/sqrt(var+eps))*(b-mu) + beta
from __future__ import annotations

import torch
import torch.nn as nn


def fold_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> nn.Conv2d:
    """Return a new bias-enabled Conv2d with the BatchNorm folded into its weight/bias."""
    if conv.out_channels != bn.num_features:
        raise ValueError("conv.out_channels must match bn.num_features")

    with torch.no_grad():
        gamma = bn.weight if bn.weight is not None else torch.ones(bn.num_features)
        beta = bn.bias if bn.bias is not None else torch.zeros(bn.num_features)
        mean = bn.running_mean
        var = bn.running_var

        scale = gamma / torch.sqrt(var + bn.eps)  # [OC]
        folded_weight = conv.weight * scale.reshape(-1, 1, 1, 1)

        original_bias = conv.bias if conv.bias is not None else torch.zeros(conv.out_channels)
        folded_bias = scale * (original_bias - mean) + beta

    folded_conv = nn.Conv2d(
        in_channels=conv.in_channels,
        out_channels=conv.out_channels,
        kernel_size=conv.kernel_size,
        stride=conv.stride,
        padding=conv.padding,
        dilation=conv.dilation,
        groups=conv.groups,
        bias=True,
    )
    with torch.no_grad():
        folded_conv.weight.copy_(folded_weight)
        folded_conv.bias.copy_(folded_bias)

    return folded_conv


def fold_batchnorm_in_module(module: nn.Module) -> nn.Module:
    """Recursively fold every adjacent (Conv2d, BatchNorm2d) pair found inside nn.Sequential blocks.

    Mutates `module` in place and also returns it. Only Conv2d immediately followed
    by BatchNorm2d within the same nn.Sequential is folded; everything else (ReLU,
    Identity shortcuts, non-Sequential structure) is left untouched.
    """
    for name, child in module.named_children():
        if isinstance(child, nn.Sequential):
            children = list(child.named_children())
            new_layers = []
            i = 0
            while i < len(children):
                cur_name, cur_mod = children[i]
                if (
                    isinstance(cur_mod, nn.Conv2d)
                    and i + 1 < len(children)
                    and isinstance(children[i + 1][1], nn.BatchNorm2d)
                ):
                    folded = fold_conv_bn(cur_mod, children[i + 1][1])
                    new_layers.append((cur_name, folded))
                    i += 2
                else:
                    fold_batchnorm_in_module(cur_mod)  # recurse: cur_mod may itself contain foldable Sequentials
                    new_layers.append((cur_name, cur_mod))
                    i += 1

            new_seq = nn.Sequential()
            for n, m in new_layers:
                new_seq.add_module(n, m)
            setattr(module, name, new_seq)
        else:
            fold_batchnorm_in_module(child)

    return module


@torch.no_grad()
def verify_folding(
    original_model: nn.Module,
    folded_model: nn.Module,
    sample_input: torch.Tensor,
    atol: float = 1e-4,
) -> float:
    """Return max abs difference between original and folded model outputs; raises if it exceeds atol."""
    original_model.eval()
    folded_model.eval()
    out_original = original_model(sample_input)
    out_folded = folded_model(sample_input)
    max_diff = (out_original - out_folded).abs().max().item()
    if max_diff > atol:
        raise AssertionError(f"BatchNorm folding mismatch: max abs diff {max_diff} > atol {atol}")
    return max_diff
