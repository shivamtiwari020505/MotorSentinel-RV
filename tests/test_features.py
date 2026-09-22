from __future__ import annotations

import unittest

from model.features import (
    FEATURE_COUNT,
    WINDOW_SIZE,
    extract_features,
    extract_overlapping,
)


class FeatureModelTests(unittest.TestCase):
    def test_zero_window(self) -> None:
        features = extract_features([(0, 0, 0)] * WINDOW_SIZE)
        self.assertEqual(features, (0,) * FEATURE_COUNT)

    def test_constant_window(self) -> None:
        sample = (100, -200, 32767)
        features = extract_features([sample] * WINDOW_SIZE)
        self.assertEqual(features[0:3], sample)
        self.assertEqual(
            features[3:6], tuple(value * value for value in sample)
        )
        self.assertEqual(features[6:], (0,) * 10)

    def test_constant_signed_extremes_anchor(self) -> None:
        features = extract_features([(-32768, 32767, -1)] * WINDOW_SIZE)
        self.assertEqual(
            features,
            (
                -32768,
                32767,
                -1,
                0x40000000,
                0x3FFF0001,
                1,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            ),
        )

    def test_alternating_extremes(self) -> None:
        samples = [
            ((-32768 if index % 2 == 0 else 32767), 0, 0)
            for index in range(WINDOW_SIZE)
        ]
        features = extract_features(samples)
        pair_energy = 65535 * 65535
        self.assertEqual(features[0], -1)
        self.assertEqual(
            features[3], (32768 * 32768 + 32767 * 32767) // 2
        )
        self.assertEqual(features[6], 65535)
        self.assertEqual(features[9], 255)
        self.assertEqual(features[12:15], (0, 0, 0))
        self.assertEqual(features[15], (128 * pair_energy) >> 10)

    def test_full_scale_haar_band_anchors(self) -> None:
        # A full-scale dyadic square wave has energy in exactly one Haar
        # lane. Driving all three axes reaches the independently calculated
        # signed-32 maximum for this normalization: 3 * 65535**2 // 8.
        band_index = {8: 12, 4: 13, 2: 14, 1: 15}
        crossing_count = {8: 31, 4: 63, 2: 127, 1: 255}
        for half_length in (8, 4, 2, 1):
            with self.subTest(half_length=half_length):
                axis = (
                    [32767] * half_length + [-32768] * half_length
                ) * (WINDOW_SIZE // (2 * half_length))
                samples = [(value, value, value) for value in axis]
                expected = (
                    [-1] * 3
                    + [0x3FFF8000] * 3
                    + [0xFFFF] * 3
                    + [crossing_count[half_length]] * 3
                    + [0] * 4
                )
                expected[band_index[half_length]] = 0x5FFF4000
                self.assertEqual(extract_features(samples), tuple(expected))

    def test_zero_crossings_use_exact_window_mean(self) -> None:
        samples = [(102 if index % 2 else 100, 0, 0) for index in range(WINDOW_SIZE)]
        self.assertEqual(extract_features(samples)[9], 255)

    def test_zero_center_values_are_ignored(self) -> None:
        samples = [((-1, 0, 1, 0)[index % 4], 0, 0) for index in range(WINDOW_SIZE)]
        self.assertEqual(extract_features(samples)[9], 127)

    def test_overlapping_window_counts(self) -> None:
        # These literal thresholds independently anchor N=256 and H=128.
        # Do not derive the expected values from the model constants: doing so
        # would let an accidental contract change pass this regression.
        expected_counts = (
            (0, 0),
            (255, 0),
            (256, 1),
            (383, 1),
            (384, 2),
            (511, 2),
            (512, 3),
            (640, 4),
            (1024, 7),
        )
        for sample_count, expected_count in expected_counts:
            with self.subTest(sample_count=sample_count):
                samples = [(0, 0, 0)] * sample_count
                self.assertEqual(
                    len(extract_overlapping(samples)), expected_count
                )

    def test_overlapping_window_boundaries(self) -> None:
        # Impulses immediately around every overlap boundary give independent
        # per-window sums. For windows [0:256], [128:384], [256:512], and
        # [384:640], the expected X sums are 1792, 7680, 30720, and 24575.
        samples = [(0, 0, 0)] * 640
        impulses = {
            127: 256,
            128: 512,
            255: 1024,
            256: 2048,
            383: 4096,
            384: 8192,
            511: 16384,
            512: 32767,
            639: -32768,
        }
        for index, value in impulses.items():
            samples[index] = (value, 0, 0)

        windows = extract_overlapping(samples)
        self.assertEqual(len(windows), 4)
        self.assertEqual(tuple(window[0] for window in windows), (7, 30, 120, 95))
        self.assertEqual(
            tuple(window[6] for window in windows),
            (1024, 4096, 16384, 65535),
        )
        self.assertTrue(
            all(window[1] == 0 and window[2] == 0 for window in windows)
        )

    def test_rejects_invalid_shape_and_range(self) -> None:
        with self.assertRaises(ValueError):
            extract_features([(0, 0, 0)] * (WINDOW_SIZE - 1))
        with self.assertRaises(ValueError):
            extract_features([(40000, 0, 0)] * WINDOW_SIZE)
        with self.assertRaises(ValueError):
            extract_features([(0, 0)] * WINDOW_SIZE)
        with self.assertRaises(TypeError):
            extract_features([(1.5, 0, 0)] * WINDOW_SIZE)
        with self.assertRaises(TypeError):
            extract_features([("1", 0, 0)] * WINDOW_SIZE)


if __name__ == "__main__":
    unittest.main()
