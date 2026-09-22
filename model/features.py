"""Bit-exact fixed-point feature contract used by RTL and model tooling.

All operations are integer-only. Python's ``//`` division intentionally rounds
negative means toward negative infinity, matching an arithmetic right shift in
the SystemVerilog implementation.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
import operator

WINDOW_SIZE = 256
HOP_SIZE = 128
AXES = 3
FEATURE_COUNT = 16
HAAR_HALF_LENGTHS = (1, 2, 4, 8)

FEATURE_NAMES = (
    "mean_x",
    "mean_y",
    "mean_z",
    "mean_square_x",
    "mean_square_y",
    "mean_square_z",
    "peak_to_peak_x",
    "peak_to_peak_y",
    "peak_to_peak_z",
    "zero_crossings_x",
    "zero_crossings_y",
    "zero_crossings_z",
    "haar_energy_25_50_hz",
    "haar_energy_50_100_hz",
    "haar_energy_100_200_hz",
    "haar_energy_200_400_hz",
)

Sample = tuple[int, int, int]


def _validate_int16(value: object) -> int:
    try:
        integer = operator.index(value)
    except TypeError as exc:
        raise TypeError(f"sample {value!r} is not an integer") from exc

    if not -32768 <= integer <= 32767:
        raise ValueError(f"sample {integer} is outside signed INT16 range")
    return integer


def _normalize_samples(samples: Iterable[Sequence[int]]) -> list[Sample]:
    normalized: list[Sample] = []
    for sample in samples:
        if len(sample) != AXES:
            raise ValueError(f"expected {AXES} axes, got {len(sample)}")
        item = (
            _validate_int16(sample[0]),
            _validate_int16(sample[1]),
            _validate_int16(sample[2]),
        )
        normalized.append(item)
    return normalized


def extract_features(
    samples: Iterable[Sequence[int]],
) -> tuple[int, ...]:
    """Return the 16 raw integer features for exactly one 256-sample window."""

    window = _normalize_samples(samples)
    if len(window) != WINDOW_SIZE:
        raise ValueError(
            f"expected exactly {WINDOW_SIZE} samples, got {len(window)}"
        )
    sums = [0] * AXES
    energies = [0] * AXES
    minima = [32767] * AXES
    maxima = [-32768] * AXES

    for sample in window:
        for axis in range(AXES):
            value = sample[axis]
            sums[axis] += value
            energies[axis] += value * value
            minima[axis] = min(minima[axis], value)
            maxima[axis] = max(maxima[axis], value)

    means = [value // WINDOW_SIZE for value in sums]
    mean_squares = [value // WINDOW_SIZE for value in energies]
    peak_to_peak = [
        maxima[axis] - minima[axis] for axis in range(AXES)
    ]

    crossings = [0] * AXES
    for axis in range(AXES):
        previous_sign: bool | None = None
        for sample in window:
            centered = WINDOW_SIZE * sample[axis] - sums[axis]
            if centered == 0:
                continue
            sign = centered < 0
            if previous_sign is not None and sign != previous_sign:
                crossings[axis] += 1
            previous_sign = sign

    raw_haar_energies: list[int] = []
    for half_length in HAAR_HALF_LENGTHS:
        block_length = 2 * half_length
        band_energy = 0
        for block_start in range(0, WINDOW_SIZE, block_length):
            second_start = block_start + half_length
            block_end = block_start + block_length
            for axis in range(AXES):
                first_sum = sum(
                    window[index][axis]
                    for index in range(block_start, second_start)
                )
                second_sum = sum(
                    window[index][axis]
                    for index in range(second_start, block_end)
                )
                difference = first_sum - second_sum
                band_energy += difference * difference
        raw_haar_energies.append(band_energy)

    # Low-to-high band order. For half-length L, block size is 2L and
    # normalization divides by 2 * WINDOW_SIZE * block_size.
    haar_energies = [
        raw_haar_energies[3] >> 13,
        raw_haar_energies[2] >> 12,
        raw_haar_energies[1] >> 11,
        raw_haar_energies[0] >> 10,
    ]

    features = tuple(
        means + mean_squares + peak_to_peak + crossings + haar_energies
    )
    if len(features) != FEATURE_COUNT:
        raise AssertionError("feature contract produced an invalid length")
    return features


def extract_overlapping(
    samples: Iterable[Sequence[int]],
) -> list[tuple[int, ...]]:
    """Extract every complete 256-sample window at a 128-sample hop."""

    stream = _normalize_samples(samples)
    return [
        extract_features(stream[start : start + WINDOW_SIZE])
        for start in range(0, len(stream) - WINDOW_SIZE + 1, HOP_SIZE)
    ]
