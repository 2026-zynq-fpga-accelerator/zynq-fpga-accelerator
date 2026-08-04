# Directed tests for python/models/golden_fixed_point.py, covering the §15.5 checklist cases.
import unittest

import numpy as np

from python.models.golden_fixed_point import conv2d_fixed_point


class TestAllZeroInput(unittest.TestCase):
    def test_zero_input_nonzero_bias(self):
        inp = np.zeros((3, 3, 1), dtype=np.int8)
        w = np.zeros((3, 3, 1, 1), dtype=np.int8)
        bias = np.array([40], dtype=np.int32)  # requant(40*1>>0) = 40
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=1, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertTrue(np.all(res.output == 40))
        self.assertFalse(res.overflow)

    def test_zero_everything(self):
        inp = np.zeros((3, 3, 2), dtype=np.int8)
        w = np.zeros((3, 3, 2, 4), dtype=np.int8)
        bias = np.zeros((4,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=1, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertTrue(np.all(res.output == 0))


class TestIdentityWeight(unittest.TestCase):
    def test_identity_reproduces_input(self):
        # 1x1 IC=OC, 3x3 kernel with only the center tap = 1 acts as identity under padding=1, stride=1.
        inp = np.array(
            [[-5, 10, 3], [0, -128, 127], [1, 2, -1]], dtype=np.int8
        ).reshape(3, 3, 1)
        w = np.zeros((3, 3, 1, 1), dtype=np.int8)
        w[1, 1, 0, 0] = 1
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=1, multiplier_m=1, shift_n=0, relu_enable=False)
        np.testing.assert_array_equal(res.output.reshape(3, 3), inp.reshape(3, 3))


class TestExtremeValues(unittest.TestCase):
    def test_max_positive_times_max_positive(self):
        inp = np.array([[127]], dtype=np.int8).reshape(1, 1, 1)
        w = np.array([[127]], dtype=np.int8).reshape(1, 1, 1, 1)
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertEqual(int(res.accumulator[0, 0, 0]), 127 * 127)
        self.assertEqual(int(res.output[0, 0, 0]), 127)  # saturates to INT8_MAX

    def test_min_negative_times_max_positive(self):
        inp = np.array([[-128]], dtype=np.int8).reshape(1, 1, 1)
        w = np.array([[127]], dtype=np.int8).reshape(1, 1, 1, 1)
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertEqual(int(res.accumulator[0, 0, 0]), -128 * 127)
        self.assertEqual(int(res.output[0, 0, 0]), -128)  # saturates to INT8_MIN

    def test_mixed_sign_cross_terms(self):
        # 1x1 kernel over IC=3 exercises the same signed-cross-term accumulation without a non-square kernel.
        inp = np.array([-10, 20, -30], dtype=np.int8).reshape(1, 1, 3)
        w = np.array([1, -1, 1], dtype=np.int8).reshape(1, 1, 3, 1)
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        expected = -10 * 1 + 20 * -1 + -30 * 1
        self.assertEqual(int(res.accumulator[0, 0, 0]), expected)


class TestAccumulatorOverflow(unittest.TestCase):
    def test_overflow_flag_set_and_saturates(self):
        inp = np.array([127, 127, 127, 127], dtype=np.int8).reshape(1, 1, 4)
        w = np.array([127, 127, 127, 127], dtype=np.int8).reshape(1, 1, 4, 1)
        # 4 * 127*127 = 64516, nowhere near overflow by itself, so force it via bias near INT32_MAX.
        bias = np.array([2147483647 - 64516], dtype=np.int32)  # exact fit, no overflow
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertFalse(res.overflow)
        self.assertEqual(int(res.accumulator[0, 0, 0]), 2147483647)

        bias_overflow = np.array([2147483647 - 64515], dtype=np.int32)  # one more than fits -> saturates
        res2 = conv2d_fixed_point(inp, w, bias_overflow, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertTrue(res2.overflow)
        self.assertEqual(int(res2.accumulator[0, 0, 0]), 2147483647)


class TestStrideAndPadding(unittest.TestCase):
    def test_stride_2_output_shape(self):
        inp = np.zeros((5, 5, 1), dtype=np.int8)
        w = np.zeros((3, 3, 1, 1), dtype=np.int8)
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=2, padding=1, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertEqual(res.output.shape, (3, 3, 1))

    def test_stride_1_no_padding_shape(self):
        inp = np.zeros((5, 5, 1), dtype=np.int8)
        w = np.zeros((3, 3, 1, 1), dtype=np.int8)
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertEqual(res.output.shape, (3, 3, 1))

    def test_padding_zero_excludes_edge_taps(self):
        # With padding=0, a 3x3 input with a 3x3 kernel produces exactly one valid (no zero-pad) output pixel.
        inp = np.arange(1, 10, dtype=np.int8).reshape(3, 3, 1)
        w = np.ones((3, 3, 1, 1), dtype=np.int8)
        bias = np.zeros((1,), dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=False)
        self.assertEqual(res.output.shape, (1, 1, 1))
        self.assertEqual(int(res.accumulator[0, 0, 0]), 45)  # sum(1..9), no zero padding contributes


class TestReluEnable(unittest.TestCase):
    def test_relu_zeroes_negative_output(self):
        inp = np.array([[0]], dtype=np.int8).reshape(1, 1, 1)
        w = np.array([[0]], dtype=np.int8).reshape(1, 1, 1, 1)
        bias = np.array([-5], dtype=np.int32)
        res = conv2d_fixed_point(inp, w, bias, stride=1, padding=0, multiplier_m=1, shift_n=0, relu_enable=True)
        self.assertEqual(int(res.output[0, 0, 0]), 0)


class TestInvalidConfig(unittest.TestCase):
    def test_channel_mismatch_raises(self):
        inp = np.zeros((3, 3, 2), dtype=np.int8)
        w = np.zeros((3, 3, 3, 1), dtype=np.int8)  # IC mismatch: 3 vs 2
        bias = np.zeros((1,), dtype=np.int32)
        with self.assertRaises(ValueError):
            conv2d_fixed_point(inp, w, bias, stride=1, padding=1, multiplier_m=1, shift_n=0, relu_enable=False)

    def test_invalid_stride_raises(self):
        inp = np.zeros((3, 3, 1), dtype=np.int8)
        w = np.zeros((3, 3, 1, 1), dtype=np.int8)
        bias = np.zeros((1,), dtype=np.int32)
        with self.assertRaises(ValueError):
            conv2d_fixed_point(inp, w, bias, stride=3, padding=1, multiplier_m=1, shift_n=0, relu_enable=False)


if __name__ == "__main__":
    unittest.main()
