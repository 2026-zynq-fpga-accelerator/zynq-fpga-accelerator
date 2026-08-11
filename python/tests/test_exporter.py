# Tests for python/export/exporter.py: byte-count formulas (§7.3) and binary round-trip (§14.3).
import shutil
import tempfile
import unittest
from pathlib import Path

import numpy as np

from python.export.exporter import (
    export_conv_test_vector,
    export_gap_test_vector,
    load_gap_test_vector,
    load_test_vector,
)


class TestExporterRoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = Path(tempfile.mkdtemp(prefix="exporter_test_"))

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_roundtrip_and_byte_counts(self):
        rng = np.random.default_rng(42)
        in_h, in_w, ic, oc, k = 5, 5, 3, 4, 3
        inp = rng.integers(-128, 128, size=(in_h, in_w, ic), dtype=np.int8)
        w = rng.integers(-128, 128, size=(k, k, ic, oc), dtype=np.int8)
        bias = rng.integers(-1000, 1000, size=(oc,), dtype=np.int32)
        expected_output = rng.integers(-128, 128, size=(in_h, in_w, oc), dtype=np.int8)

        out_dir = export_conv_test_vector(
            self.tmp_dir / "tv",
            input_hwc=inp,
            weight_hwio=w,
            bias_oc=bias,
            expected_output_hwc=expected_output,
            stride=1,
            padding=1,
            relu_enable=True,
            multiplier_m=100,
            shift_n=4,
        )

        loaded = load_test_vector(out_dir)
        np.testing.assert_array_equal(loaded["input"], inp)
        np.testing.assert_array_equal(loaded["weight"], w)
        np.testing.assert_array_equal(loaded["bias"], bias)
        np.testing.assert_array_equal(loaded["expected_output"], expected_output)

        config = loaded["config"]
        self.assertEqual(config["weight_bytes"], k * k * ic * oc)
        self.assertEqual(config["bias_bytes"], oc * 4)
        self.assertEqual(config["input_bytes"], in_h * in_w * ic)
        self.assertEqual(config["output_bytes"], in_h * in_w * oc)
        self.assertEqual(config["skip_bytes"], 0)
        self.assertEqual(config["interface_version"], "1.1")

    def test_wrong_dtype_raises(self):
        inp = np.zeros((3, 3, 1), dtype=np.int32)  # wrong dtype, must be int8
        w = np.zeros((3, 3, 1, 1), dtype=np.int8)
        bias = np.zeros((1,), dtype=np.int32)
        out = np.zeros((3, 3, 1), dtype=np.int8)
        with self.assertRaises(TypeError):
            export_conv_test_vector(
                self.tmp_dir / "bad",
                input_hwc=inp, weight_hwio=w, bias_oc=bias, expected_output_hwc=out,
                stride=1, padding=1, relu_enable=False, multiplier_m=1, shift_n=0,
            )

    def test_channel_mismatch_raises(self):
        inp = np.zeros((3, 3, 2), dtype=np.int8)
        w = np.zeros((3, 3, 3, 1), dtype=np.int8)  # IC mismatch
        bias = np.zeros((1,), dtype=np.int32)
        out = np.zeros((3, 3, 1), dtype=np.int8)
        with self.assertRaises(ValueError):
            export_conv_test_vector(
                self.tmp_dir / "mismatch",
                input_hwc=inp, weight_hwio=w, bias_oc=bias, expected_output_hwc=out,
                stride=1, padding=1, relu_enable=False, multiplier_m=1, shift_n=0,
            )


class TestGapExporterRoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = Path(tempfile.mkdtemp(prefix="gap_exporter_test_"))

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_roundtrip_and_byte_counts(self):
        rng = np.random.default_rng(7)
        in_h, in_w, c = 8, 8, 64
        inp = rng.integers(-128, 128, size=(in_h, in_w, c), dtype=np.int8)
        expected_output = rng.integers(-128, 128, size=(c,), dtype=np.int8)

        out_dir = export_gap_test_vector(
            self.tmp_dir / "tv",
            input_hwc=inp,
            expected_output_c=expected_output,
            multiplier_m=1,
            shift_n=6,
        )

        loaded = load_gap_test_vector(out_dir)
        np.testing.assert_array_equal(loaded["input"], inp)
        np.testing.assert_array_equal(loaded["expected_output"], expected_output)

        config = loaded["config"]
        self.assertEqual(config["operation"], "OP_GLOBAL_AVG_POOL")
        self.assertEqual(config["input_bytes"], in_h * in_w * c)
        self.assertEqual(config["output_bytes"], c)
        self.assertEqual(config["weight_bytes"], 0)
        self.assertEqual(config["bias_bytes"], 0)
        self.assertEqual(config["skip_bytes"], 0)
        self.assertEqual(config["out_channels"], config["in_channels"])

    def test_wrong_dtype_raises(self):
        inp = np.zeros((8, 8, 4), dtype=np.int32)  # wrong dtype, must be int8
        out = np.zeros((4,), dtype=np.int8)
        with self.assertRaises(TypeError):
            export_gap_test_vector(
                self.tmp_dir / "bad",
                input_hwc=inp, expected_output_c=out, multiplier_m=1, shift_n=6,
            )

    def test_channel_mismatch_raises(self):
        inp = np.zeros((8, 8, 4), dtype=np.int8)
        out = np.zeros((3,), dtype=np.int8)  # mismatch: 3 vs 4
        with self.assertRaises(ValueError):
            export_gap_test_vector(
                self.tmp_dir / "mismatch",
                input_hwc=inp, expected_output_c=out, multiplier_m=1, shift_n=6,
            )


if __name__ == "__main__":
    unittest.main()
