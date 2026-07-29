# Tests for python/models/bn_fold.py against the folding formula in project doc §6.
import copy
import unittest

import torch
import torch.nn as nn

from python.models.bn_fold import fold_conv_bn, fold_batchnorm_in_module, verify_folding
from python.models.resnet_fp import BasicBlock, ResNet20CIFAR, SingleConvReLU


class TestFoldConvBn(unittest.TestCase):
    def test_folded_matches_formula(self):
        torch.manual_seed(0)
        conv = nn.Conv2d(2, 3, kernel_size=3, padding=1, bias=False)
        bn = nn.BatchNorm2d(3)
        # Simulate "trained" BN stats so folding isn't a no-op (default running stats are mean=0, var=1).
        with torch.no_grad():
            bn.running_mean.copy_(torch.tensor([0.5, -0.2, 1.0]))
            bn.running_var.copy_(torch.tensor([2.0, 0.5, 3.0]))
            bn.weight.copy_(torch.tensor([1.5, 0.8, 2.0]))
            bn.bias.copy_(torch.tensor([0.1, -0.1, 0.3]))
        bn.eval()

        folded = fold_conv_bn(conv, bn)

        scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
        expected_weight = conv.weight * scale.reshape(-1, 1, 1, 1)
        expected_bias = scale * (0 - bn.running_mean) + bn.bias

        torch.testing.assert_close(folded.weight, expected_weight)
        torch.testing.assert_close(folded.bias, expected_bias)

    def test_output_matches_original(self):
        torch.manual_seed(1)
        conv = nn.Conv2d(3, 4, kernel_size=3, padding=1, bias=False)
        bn = nn.BatchNorm2d(4)
        bn.eval()
        with torch.no_grad():
            bn.running_mean.copy_(torch.randn(4))
            bn.running_var.copy_(torch.rand(4) + 0.5)

        folded = fold_conv_bn(conv, bn)
        x = torch.randn(2, 3, 8, 8)

        with torch.no_grad():
            original_out = bn(conv(x))
            folded_out = folded(x)

        torch.testing.assert_close(original_out, folded_out, atol=1e-5, rtol=1e-5)


class TestFoldModule(unittest.TestCase):
    def test_stage1_single_conv(self):
        torch.manual_seed(2)
        model = SingleConvReLU()
        model.eval()
        folded = fold_batchnorm_in_module(copy.deepcopy(model))
        self.assertIsInstance(folded.conv_bn_relu[0], nn.Conv2d)
        self.assertNotIsInstance(folded.conv_bn_relu[1], nn.BatchNorm2d)
        verify_folding(model, folded, torch.randn(1, 3, 8, 8))

    def test_basic_block_with_projection_shortcut(self):
        torch.manual_seed(3)
        model = BasicBlock(16, 32, stride=2)
        model.eval()
        folded = fold_batchnorm_in_module(copy.deepcopy(model))
        # shortcut is a projection conv+bn pair, must fold down to a single Conv2d
        self.assertEqual(len(list(folded.shortcut.children())), 1)
        self.assertIsInstance(folded.shortcut[0], nn.Conv2d)
        for m in folded.shortcut.modules():
            self.assertNotIsInstance(m, nn.BatchNorm2d)
        verify_folding(model, folded, torch.randn(1, 16, 16, 16))

    def test_resnet20_full_model(self):
        torch.manual_seed(4)
        model = ResNet20CIFAR()
        model.eval()
        folded = fold_batchnorm_in_module(copy.deepcopy(model))
        for m in folded.modules():
            self.assertNotIsInstance(m, nn.BatchNorm2d)
        verify_folding(model, folded, torch.randn(2, 3, 32, 32))


if __name__ == "__main__":
    unittest.main()
