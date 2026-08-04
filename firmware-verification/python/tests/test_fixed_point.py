# Directed tests for python/utils/fixed_point.py, covering the §15.5 checklist cases.
import unittest

from python.utils.fixed_point import (
    INT32_MAX,
    INT32_MIN,
    clamp,
    conv_output_dim,
    mac_product,
    pack_output_scale,
    relu_and_saturate_int8,
    requantize,
    sat_add_int32,
    unpack_output_scale,
    validate_conv_config,
)


class TestSaturatingAdd(unittest.TestCase):
    def test_no_overflow(self):
        result, overflow = sat_add_int32(100, -50)
        self.assertEqual(result, 50)
        self.assertFalse(overflow)

    def test_positive_overflow_saturates(self):
        result, overflow = sat_add_int32(INT32_MAX, 1)
        self.assertEqual(result, INT32_MAX)
        self.assertTrue(overflow)

    def test_negative_overflow_saturates(self):
        result, overflow = sat_add_int32(INT32_MIN, -1)
        self.assertEqual(result, INT32_MIN)
        self.assertTrue(overflow)

    def test_exact_boundary_does_not_overflow(self):
        result, overflow = sat_add_int32(INT32_MAX - 1, 1)
        self.assertEqual(result, INT32_MAX)
        self.assertFalse(overflow)


class TestMacProduct(unittest.TestCase):
    def test_max_positive(self):
        self.assertEqual(mac_product(127, 127), 16129)

    def test_min_negative_times_min_negative(self):
        self.assertEqual(mac_product(-128, -128), 16384)

    def test_mixed_sign(self):
        self.assertEqual(mac_product(-128, 127), -16256)

    def test_zero(self):
        self.assertEqual(mac_product(0, 0), 0)

    def test_out_of_range_raises(self):
        with self.assertRaises(ValueError):
            mac_product(128, 0)
        with self.assertRaises(ValueError):
            mac_product(0, -129)


class TestRequantize(unittest.TestCase):
    def test_shift_zero_is_passthrough(self):
        self.assertEqual(requantize(12345, multiplier_m=1, shift_n=0), 12345)

    def test_multiplier_zero(self):
        self.assertEqual(requantize(999999, multiplier_m=0, shift_n=5), 0)

    def test_multiplier_max(self):
        # P = 100 * 65535 = 6,553,500 ; N=0 passthrough
        self.assertEqual(requantize(100, multiplier_m=65535, shift_n=0), 6_553_500)

    def test_tie_rounding_positive_ties_away_from_zero(self):
        # P=1, N=1 -> half=1 -> (1+1)>>1 = 1 (rounds up, away from zero)
        self.assertEqual(requantize(1, multiplier_m=1, shift_n=1), 1)

    def test_tie_rounding_negative_ties_away_from_zero(self):
        # acc=-1, M=1 -> P=-1, N=1 -> -(((1)+1)>>1) = -1 (rounds away from zero, i.e. more negative)
        self.assertEqual(requantize(-1, multiplier_m=1, shift_n=1), -1)

    def test_non_tie_rounds_to_nearest(self):
        # P=3, N=2 -> half=2 -> (3+2)>>2 = 1
        self.assertEqual(requantize(3, multiplier_m=1, shift_n=2), 1)
        # P=-3, N=2 -> -(((3)+2)>>2) = -1
        self.assertEqual(requantize(-3, multiplier_m=1, shift_n=2), -1)

    def test_out_of_range_raises(self):
        with self.assertRaises(ValueError):
            requantize(0, multiplier_m=65536, shift_n=0)
        with self.assertRaises(ValueError):
            requantize(0, multiplier_m=0, shift_n=32)


class TestReluAndSaturate(unittest.TestCase):
    def test_relu_clamps_negative_to_zero(self):
        self.assertEqual(relu_and_saturate_int8(-5, relu_enable=True), 0)

    def test_relu_disabled_keeps_negative(self):
        self.assertEqual(relu_and_saturate_int8(-5, relu_enable=False), -5)

    def test_saturates_high(self):
        self.assertEqual(relu_and_saturate_int8(200, relu_enable=False), 127)

    def test_saturates_low(self):
        self.assertEqual(relu_and_saturate_int8(-200, relu_enable=False), -128)

    def test_relu_range_is_0_to_127(self):
        self.assertEqual(relu_and_saturate_int8(300, relu_enable=True), 127)
        self.assertEqual(relu_and_saturate_int8(0, relu_enable=True), 0)


class TestOutputScalePacking(unittest.TestCase):
    def test_roundtrip(self):
        reg = pack_output_scale(multiplier_m=12345, shift_n=17)
        m, n = unpack_output_scale(reg)
        self.assertEqual((m, n), (12345, 17))

    def test_layout_matches_spec(self):
        # [31:16]=N, [15:0]=M
        reg = pack_output_scale(multiplier_m=1, shift_n=1)
        self.assertEqual(reg, (1 << 16) | 1)

    def test_invalid_shift_raises(self):
        with self.assertRaises(ValueError):
            pack_output_scale(multiplier_m=1, shift_n=32)


class TestConvOutputDimAndConfig(unittest.TestCase):
    def test_output_dim_stride1_pad1_k3(self):
        self.assertEqual(conv_output_dim(32, padding=1, kernel=3, stride=1), 32)

    def test_output_dim_stride2(self):
        self.assertEqual(conv_output_dim(32, padding=1, kernel=3, stride=2), 16)

    def test_valid_config_ok(self):
        validate_conv_config(32, 32, 3, 16, kernel=3, stride=1, padding=1)  # must not raise

    def test_invalid_stride_raises(self):
        with self.assertRaises(ValueError):
            validate_conv_config(32, 32, 3, 16, kernel=3, stride=3, padding=1)

    def test_input_too_small_for_kernel_raises(self):
        with self.assertRaises(ValueError):
            validate_conv_config(2, 2, 3, 16, kernel=3, stride=1, padding=0)


class TestClamp(unittest.TestCase):
    def test_within_range(self):
        self.assertEqual(clamp(5, -10, 10), 5)

    def test_below_range(self):
        self.assertEqual(clamp(-50, -10, 10), -10)

    def test_above_range(self):
        self.assertEqual(clamp(50, -10, 10), 10)


if __name__ == "__main__":
    unittest.main()
