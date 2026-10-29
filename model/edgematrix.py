"""Bit-exact EdgeMatrix-RV INT8 normalizer and autoencoder contract.

The RTL implements exactly these integer operations. Floating point appears
only in the offline training tool; the deployed model is a packed integer image
protected by a CRC-32.

Pipeline for one 16-feature window:

1. ``q[i] = sat8(rshift_round((f[i] - offset[i]) * scale[i], shift[i]))``
2. ``h[j] = sat8(max(0, rshift_round(b1[j] + sum_i W1[j][i] * q[i], s1)))``
3. ``y[i] = sat8(rshift_round(b2[i] + sum_j W2[i][j] * h[j], s2))``
4. ``score = sum_i |y[i] - q[i]|`` (L1 reconstruction error, 12 bits)

``rshift_round(v, s)`` adds ``2**(s-1)`` when ``s > 0`` and then performs an
arithmetic right shift, i.e. round half toward positive infinity.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import json
from pathlib import Path
import struct
import zlib

INPUTS = 16
HIDDEN = 8
FORMAT_WORD = 0x4D41_0001  # "MA", model-image format 1
IMAGE_WORDS = 122
MAX_NORM_SHIFT = 47
MAX_LAYER_SHIFT = 24
BIAS_LIMIT = 1 << 24
SCORE_MAX = INPUTS * 255

# Word offsets inside the model image.
OFFSET_BASE = 1
NORM_BASE = 17
W1_BASE = 33
W2_BASE = 65
B1_BASE = 97
B2_BASE = 105
SHIFT_WORD = 121


def sat8(value: int) -> int:
    return max(-128, min(127, value))


def rshift_round(value: int, shift: int) -> int:
    if shift < 0:
        raise ValueError("shift must be nonnegative")
    if shift == 0:
        return value
    return (value + (1 << (shift - 1))) >> shift


@dataclass(frozen=True)
class QuantizedModel:
    offset: tuple[int, ...]
    scale: tuple[int, ...]
    norm_shift: tuple[int, ...]
    w1: tuple[tuple[int, ...], ...]  # HIDDEN x INPUTS
    b1: tuple[int, ...]
    w2: tuple[tuple[int, ...], ...]  # INPUTS x HIDDEN
    b2: tuple[int, ...]
    s1: int
    s2: int
    threshold: int = 0

    def validate(self) -> None:
        def check(condition: bool, message: str) -> None:
            if not condition:
                raise ValueError(message)

        check(len(self.offset) == INPUTS, "offset length")
        check(len(self.scale) == INPUTS, "scale length")
        check(len(self.norm_shift) == INPUTS, "shift length")
        check(all(-(1 << 31) <= v < (1 << 31) for v in self.offset), "offset range")
        check(all(-(1 << 15) <= v < (1 << 15) for v in self.scale), "scale range")
        check(all(0 <= v <= MAX_NORM_SHIFT for v in self.norm_shift), "norm shift")
        check(len(self.w1) == HIDDEN and all(len(r) == INPUTS for r in self.w1), "W1 shape")
        check(len(self.w2) == INPUTS and all(len(r) == HIDDEN for r in self.w2), "W2 shape")
        for row in self.w1 + self.w2:
            check(all(-128 <= v <= 127 for v in row), "weight range")
        check(len(self.b1) == HIDDEN and len(self.b2) == INPUTS, "bias length")
        for value in self.b1 + self.b2:
            check(-BIAS_LIMIT <= value < BIAS_LIMIT, "bias range")
        check(0 <= self.s1 <= MAX_LAYER_SHIFT, "s1 range")
        check(0 <= self.s2 <= MAX_LAYER_SHIFT, "s2 range")
        check(0 <= self.threshold <= SCORE_MAX, "threshold range")


@dataclass(frozen=True)
class Inference:
    q: tuple[int, ...]
    h: tuple[int, ...]
    y: tuple[int, ...]
    score: int


def normalize(model: QuantizedModel, features: Sequence[int]) -> tuple[int, ...]:
    if len(features) != INPUTS:
        raise ValueError(f"expected {INPUTS} features")
    return tuple(
        sat8(
            rshift_round(
                (features[i] - model.offset[i]) * model.scale[i],
                model.norm_shift[i],
            )
        )
        for i in range(INPUTS)
    )


def infer(model: QuantizedModel, features: Sequence[int]) -> Inference:
    q = normalize(model, features)
    h = tuple(
        sat8(
            max(
                0,
                rshift_round(
                    model.b1[j]
                    + sum(model.w1[j][i] * q[i] for i in range(INPUTS)),
                    model.s1,
                ),
            )
        )
        for j in range(HIDDEN)
    )
    y = tuple(
        sat8(
            rshift_round(
                model.b2[i] + sum(model.w2[i][j] * h[j] for j in range(HIDDEN)),
                model.s2,
            )
        )
        for i in range(INPUTS)
    )
    score = sum(abs(y[i] - q[i]) for i in range(INPUTS))
    return Inference(q=q, h=h, y=y, score=score)


def _pack_bytes(values: Sequence[int]) -> list[int]:
    words = []
    for base in range(0, len(values), 4):
        word = 0
        for lane in range(4):
            word |= (values[base + lane] & 0xFF) << (8 * lane)
        words.append(word)
    return words


def model_image(model: QuantizedModel) -> list[int]:
    """Return the 122-word APB load image in transfer order."""

    model.validate()
    words = [FORMAT_WORD]
    words += [v & 0xFFFFFFFF for v in model.offset]
    words += [
        ((model.norm_shift[i] & 0x3F) << 16) | (model.scale[i] & 0xFFFF)
        for i in range(INPUTS)
    ]
    words += _pack_bytes([v for row in model.w1 for v in row])
    words += _pack_bytes([v for row in model.w2 for v in row])
    words += [v & 0xFFFFFFFF for v in model.b1]
    words += [v & 0xFFFFFFFF for v in model.b2]
    words.append(((model.s2 & 0x3F) << 8) | (model.s1 & 0x3F))
    if len(words) != IMAGE_WORDS:
        raise AssertionError("model image layout changed")
    return words


def image_crc(words: Sequence[int]) -> int:
    """IEEE CRC-32 over the image as little-endian bytes."""

    return zlib.crc32(struct.pack(f"<{len(words)}I", *words)) & 0xFFFFFFFF


def save_model(model: QuantizedModel, path: Path, metadata: dict | None = None) -> None:
    model.validate()
    document = {
        "format": "motorsentinel-edgematrix-v1",
        "offset": list(model.offset),
        "scale": list(model.scale),
        "norm_shift": list(model.norm_shift),
        "w1": [list(r) for r in model.w1],
        "b1": list(model.b1),
        "w2": [list(r) for r in model.w2],
        "b2": list(model.b2),
        "s1": model.s1,
        "s2": model.s2,
        "threshold": model.threshold,
        "image_crc32": f"0x{image_crc(model_image(model)):08x}",
        "metadata": metadata or {},
    }
    path.write_text(json.dumps(document, indent=1) + "\n", encoding="ascii")


def load_model(path: Path) -> QuantizedModel:
    document = json.loads(path.read_text(encoding="ascii"))
    if document.get("format") != "motorsentinel-edgematrix-v1":
        raise ValueError("unsupported model format")
    model = QuantizedModel(
        offset=tuple(document["offset"]),
        scale=tuple(document["scale"]),
        norm_shift=tuple(document["norm_shift"]),
        w1=tuple(tuple(r) for r in document["w1"]),
        b1=tuple(document["b1"]),
        w2=tuple(tuple(r) for r in document["w2"]),
        b2=tuple(document["b2"]),
        s1=document["s1"],
        s2=document["s2"],
        threshold=document["threshold"],
    )
    model.validate()
    recorded = int(document["image_crc32"], 16)
    if recorded != image_crc(model_image(model)):
        raise ValueError("model JSON does not match its recorded CRC")
    return model


DEFAULT_MODEL_PATH = Path(__file__).resolve().parent / "weights" / "motorsentinel_ae_v1.json"
