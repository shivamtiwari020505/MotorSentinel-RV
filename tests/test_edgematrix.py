from __future__ import annotations

import unittest
import zlib
import struct

from model.edgematrix import (
    DEFAULT_MODEL_PATH,
    FORMAT_WORD,
    HIDDEN,
    IMAGE_WORDS,
    INPUTS,
    QuantizedModel,
    image_crc,
    infer,
    load_model,
    model_image,
    normalize,
    rshift_round,
    sat8,
)
from model.features import extract_overlapping
from model.motor_sim import Fault, XorShift32, healthy_profile, simulate


def identity_like_model(**changes) -> QuantizedModel:
    base = dict(
        offset=(0,) * INPUTS,
        scale=(1,) * INPUTS,
        norm_shift=(0,) * INPUTS,
        w1=tuple(
            tuple(1 if i == j else 0 for i in range(INPUTS)) for j in range(HIDDEN)
        ),
        b1=(0,) * HIDDEN,
        w2=tuple(
            tuple(1 if i == j else 0 for j in range(HIDDEN)) for i in range(INPUTS)
        ),
        b2=(0,) * INPUTS,
        s1=0,
        s2=0,
    )
    base.update(changes)
    return QuantizedModel(**base)


class ArithmeticTests(unittest.TestCase):
    def test_round_half_up_including_negatives(self) -> None:
        self.assertEqual(rshift_round(5, 1), 3)
        self.assertEqual(rshift_round(-5, 1), -2)
        self.assertEqual(rshift_round(-6, 2), -1)
        self.assertEqual(rshift_round(7, 0), 7)

    def test_saturation(self) -> None:
        self.assertEqual(sat8(1000), 127)
        self.assertEqual(sat8(-1000), -128)
        self.assertEqual(sat8(-3), -3)

    def test_normalizer_extremes_saturate_without_overflow(self) -> None:
        model = identity_like_model(
            offset=(-(1 << 31),) * INPUTS, scale=(-32768,) * INPUTS
        )
        self.assertEqual(normalize(model, [(1 << 31) - 1] * INPUTS), (-128,) * INPUTS)


class InferenceTests(unittest.TestCase):
    def test_identity_network_reconstructs_positive_hidden_inputs(self) -> None:
        model = identity_like_model()
        features = [5, 6, 7, 8, 9, 10, 11, 12] + [0] * 8
        result = infer(model, features)
        self.assertEqual(result.h, tuple(features[:8]))
        self.assertEqual(result.y[:8], tuple(features[:8]))
        self.assertEqual(result.score, 0)

    def test_relu_and_l1_score(self) -> None:
        model = identity_like_model()
        features = [-4] + [0] * 7 + [3] * 8
        result = infer(model, features)
        self.assertEqual(result.h[0], 0)
        self.assertEqual(result.score, 4 + 3 * 8)


class ImageTests(unittest.TestCase):
    def test_image_layout_and_crc(self) -> None:
        model = identity_like_model(s1=3, s2=24, scale=(-2,) + (1,) * 15)
        image = model_image(model)
        self.assertEqual(len(image), IMAGE_WORDS)
        self.assertEqual(image[0], FORMAT_WORD)
        self.assertEqual(image[17], 0x0000FFFE)
        self.assertEqual(image[121], (24 << 8) | 3)
        self.assertEqual(
            image_crc(image), zlib.crc32(struct.pack("<122I", *image))
        )

    def test_out_of_range_parameters_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            model_image(identity_like_model(b1=(1 << 24,) + (0,) * 7))
        with self.assertRaises(ValueError):
            model_image(identity_like_model(norm_shift=(48,) + (0,) * 15))
        with self.assertRaises(ValueError):
            model_image(identity_like_model(s2=25))


class CommittedModelTests(unittest.TestCase):
    def test_committed_model_loads_and_separates_faults(self) -> None:
        model = load_model(DEFAULT_MODEL_PATH)
        profile = healthy_profile(XorShift32(424242))
        healthy = extract_overlapping(simulate(1024, 424242, profile))
        self.assertTrue(all(infer(model, w).score <= model.threshold for w in healthy))
        for kind, magnitude in (("imbalance", 3.0), ("bearing", 60.0), ("noise", 40.0)):
            faulty = simulate(1024, 424242, profile, Fault(kind, 0, magnitude))
            scores = [infer(model, w).score for w in extract_overlapping(faulty)]
            self.assertTrue(
                all(score > model.threshold for score in scores), (kind, scores)
            )


if __name__ == "__main__":
    unittest.main()
