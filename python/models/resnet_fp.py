# Floating-point PyTorch ResNet reference models, staged per project doc §5:
# 단계 1 (single conv) -> 단계 2 (BasicBlock) -> 단계 3 (CIFAR-10 ResNet-20).
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


def conv_bn(in_ch: int, out_ch: int, kernel_size: int, stride: int, padding: int, relu: bool) -> nn.Sequential:
    """Conv2d(bias=False) + BatchNorm2d [+ ReLU], kept as one nn.Sequential so bn_fold can find the pair."""
    layers = [
        nn.Conv2d(in_ch, out_ch, kernel_size, stride=stride, padding=padding, bias=False),
        nn.BatchNorm2d(out_ch),
    ]
    if relu:
        layers.append(nn.ReLU(inplace=True))
    return nn.Sequential(*layers)


class SingleConvReLU(nn.Module):
    """단계 1: Input 3x32x32 -> 3x3 conv -> 16 channels -> ReLU."""

    def __init__(self, in_channels: int = 3, out_channels: int = 16, stride: int = 1, padding: int = 1):
        super().__init__()
        self.conv_bn_relu = conv_bn(in_channels, out_channels, kernel_size=3, stride=stride, padding=padding, relu=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.conv_bn_relu(x)


class BasicBlock(nn.Module):
    """단계 2: Conv3x3 -> ReLU -> Conv3x3 -> (+ identity/projection shortcut) -> ReLU."""

    expansion = 1

    def __init__(self, in_channels: int, out_channels: int, stride: int = 1):
        super().__init__()
        self.conv1 = conv_bn(in_channels, out_channels, kernel_size=3, stride=stride, padding=1, relu=True)
        self.conv2 = conv_bn(out_channels, out_channels, kernel_size=3, stride=1, padding=1, relu=False)

        if stride != 1 or in_channels != out_channels:
            self.shortcut = conv_bn(in_channels, out_channels, kernel_size=1, stride=stride, padding=0, relu=False)
        else:
            self.shortcut = nn.Identity()

        self.relu = nn.ReLU(inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        identity = self.shortcut(x)
        out = self.conv1(x)
        out = self.conv2(out)
        out = out + identity
        return self.relu(out)


class ResNet20CIFAR(nn.Module):
    """단계 3: CIFAR-10 ResNet-20 (He et al. 2015) — stem + 3 stages x 3 BasicBlocks (16/32/64ch) + GAP + FC."""

    def __init__(self, num_classes: int = 10):
        super().__init__()
        self.stem = conv_bn(3, 16, kernel_size=3, stride=1, padding=1, relu=True)

        self.stage1 = self._make_stage(16, 16, num_blocks=3, stride=1)
        self.stage2 = self._make_stage(16, 32, num_blocks=3, stride=2)
        self.stage3 = self._make_stage(32, 64, num_blocks=3, stride=2)

        self.fc = nn.Linear(64, num_classes)

    @staticmethod
    def _make_stage(in_channels: int, out_channels: int, num_blocks: int, stride: int) -> nn.Sequential:
        strides = [stride] + [1] * (num_blocks - 1)
        blocks = []
        channels = in_channels
        for s in strides:
            blocks.append(BasicBlock(channels, out_channels, stride=s))
            channels = out_channels
        return nn.Sequential(*blocks)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stem(x)
        x = self.stage1(x)
        x = self.stage2(x)
        x = self.stage3(x)
        x = F.adaptive_avg_pool2d(x, 1)
        x = torch.flatten(x, 1)
        return self.fc(x)
