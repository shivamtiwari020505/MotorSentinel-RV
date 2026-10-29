"""Bit-exact sensor-integrity monitor contract.

These checks run on every accepted sample, before feature extraction, and catch
attacks that a learned model can miss because the manipulated data still looks
statistically normal:

* range: any axis magnitude above a physical limit (clipping, injected rails);
* slew: any axis step larger than the sensor and mechanics can produce;
* frozen: a run of bit-identical X/Y/Z samples (stuck or held sensor value);
* replay: previously observed 16-sample sequences reappearing in the stream.

Replay detection uses an alignment-free rolling hash. Each accepted sample is
mixed into a 32-bit word ``s[n]``; the cyclic-polynomial (buzhash) value

    H[n] = XOR_{k=0..15} rotl(s[n-k], k)

is updated in O(1) with only rotates and XORs. A 1024-entry direct-mapped table
remembers recent hashes. Natural sensor noise makes an exact 16-sample,
three-axis repeat vanishingly unlikely, while a replayed recording produces a
burst of hits regardless of where its loop boundary falls.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass

HASH_TAPS = 16
TABLE_BITS = 10
TABLE_SIZE = 1 << TABLE_BITS
TAG_BITS = 32 - TABLE_BITS
BLOCK_SAMPLES = 128
MASK32 = 0xFFFFFFFF

EVENT_RANGE = 1 << 0
EVENT_SLEW = 1 << 1
EVENT_FROZEN = 1 << 2
EVENT_REPLAY = 1 << 3


@dataclass(frozen=True)
class IntegrityConfig:
    range_limit: int = 4000
    slew_limit: int = 1024
    frozen_limit: int = 32
    replay_threshold: int = 16

    def validate(self) -> None:
        if not 0 <= self.range_limit <= 0xFFFF:
            raise ValueError("range_limit must be 16-bit")
        if not 0 <= self.slew_limit <= 0xFFFF:
            raise ValueError("slew_limit must be 16-bit")
        if not 0 <= self.frozen_limit <= 0xFF:
            raise ValueError("frozen_limit must be 8-bit")
        if not 0 <= self.replay_threshold <= 0xFF:
            raise ValueError("replay_threshold must be 8-bit")


def rotl32(value: int, amount: int) -> int:
    amount %= 32
    value &= MASK32
    return ((value << amount) | (value >> (32 - amount))) & MASK32


def mix_sample(sample: Sequence[int]) -> int:
    """Fold a 48-bit X/Y/Z sample into the 32-bit hash input word."""

    x, y, z = (axis & 0xFFFF for axis in sample)
    return ((x << 16) | y) ^ rotl32((z << 16) | (z ^ 0xA5C3), 7)


@dataclass(frozen=True)
class SampleResult:
    events: int
    replay_hits: int  # hits in the block that ended on this sample, else 0


def monitor(
    samples: Iterable[Sequence[int]], config: IntegrityConfig = IntegrityConfig()
) -> list[SampleResult]:
    """Return per-sample integrity events for a stream starting after enable."""

    config.validate()
    table: list[int | None] = [None] * TABLE_SIZE
    history = [0] * HASH_TAPS
    rolling = 0
    previous: tuple[int, int, int] | None = None
    run_length = 0
    block_hits = 0
    results: list[SampleResult] = []

    for index, raw in enumerate(samples):
        sample = (int(raw[0]), int(raw[1]), int(raw[2]))
        events = 0

        if config.range_limit and any(
            abs(axis) > config.range_limit for axis in sample
        ):
            events |= EVENT_RANGE

        if previous is not None and config.slew_limit and any(
            abs(sample[a] - previous[a]) > config.slew_limit for a in range(3)
        ):
            events |= EVENT_SLEW

        run_length = min(255, run_length + 1) if sample == previous else 1
        if config.frozen_limit and run_length >= config.frozen_limit:
            events |= EVENT_FROZEN
        previous = sample

        word = mix_sample(sample)
        outgoing = history[index % HASH_TAPS]
        history[index % HASH_TAPS] = word
        rolling = rotl32(rolling, 1) ^ word ^ rotl32(outgoing, HASH_TAPS)

        if index >= HASH_TAPS - 1:
            slot = rolling & (TABLE_SIZE - 1)
            tag = rolling >> TABLE_BITS
            if table[slot] == tag:
                block_hits += 1
            table[slot] = tag

        hits_reported = 0
        if index % BLOCK_SAMPLES == BLOCK_SAMPLES - 1:
            hits_reported = block_hits
            if config.replay_threshold and block_hits >= config.replay_threshold:
                events |= EVENT_REPLAY
            block_hits = 0

        results.append(SampleResult(events=events, replay_hits=hits_reported))
    return results


def latched_events(results: Iterable[SampleResult]) -> int:
    value = 0
    for result in results:
        value |= result.events
    return value
