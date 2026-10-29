from __future__ import annotations

import unittest

from model.integrity import (
    BLOCK_SAMPLES,
    EVENT_FROZEN,
    EVENT_RANGE,
    EVENT_REPLAY,
    EVENT_SLEW,
    HASH_TAPS,
    IntegrityConfig,
    latched_events,
    mix_sample,
    monitor,
    rotl32,
)
from model.motor_sim import Fault, XorShift32, healthy_profile, simulate


def noisy_stream(count: int, seed: int = 77):
    rng = XorShift32(seed)
    return [
        (int(rng.next_u32() % 41) - 20, int(rng.next_u32() % 41) - 20,
         256 + int(rng.next_u32() % 41) - 20)
        for _ in range(count)
    ]


class IntegrityTests(unittest.TestCase):
    def test_rolling_hash_matches_direct_definition(self) -> None:
        stream = noisy_stream(64)
        rolling = 0
        history = [0] * HASH_TAPS
        for index, sample in enumerate(stream):
            word = mix_sample(sample)
            rolling = rotl32(rolling, 1) ^ word ^ rotl32(history[index % HASH_TAPS], HASH_TAPS)
            history[index % HASH_TAPS] = word
            if index >= HASH_TAPS - 1:
                direct = 0
                for k in range(HASH_TAPS):
                    direct ^= rotl32(mix_sample(stream[index - k]), k)
                self.assertEqual(rolling, direct)

    def test_noise_raises_no_events(self) -> None:
        self.assertEqual(latched_events(monitor(noisy_stream(4096))), 0)

    def test_range_and_slew(self) -> None:
        stream = noisy_stream(40)
        stream[20] = (4001, stream[20][1], stream[20][2])
        events = monitor(stream)
        self.assertTrue(events[20].events & EVENT_RANGE)
        self.assertTrue(events[20].events & EVENT_SLEW)
        self.assertTrue(events[21].events & EVENT_SLEW)
        self.assertEqual(events[19].events, 0)

    def test_frozen_requires_configured_run(self) -> None:
        stream = noisy_stream(10) + [(1, 2, 3)] * 40
        events = monitor(stream, IntegrityConfig(frozen_limit=32))
        first = next(i for i, e in enumerate(events) if e.events & EVENT_FROZEN)
        self.assertEqual(first, 10 + 31)

    def test_unaligned_replay_is_detected(self) -> None:
        recording = noisy_stream(600)
        stream = recording + recording[:700 - 600] + recording * 2
        events = monitor(stream)
        self.assertEqual(latched_events(events[:600]), 0)
        self.assertTrue(latched_events(events) & EVENT_REPLAY)

    def test_replay_threshold_zero_disables(self) -> None:
        recording = noisy_stream(300)
        events = monitor(recording * 4, IntegrityConfig(replay_threshold=0))
        self.assertFalse(latched_events(events) & EVENT_REPLAY)

    def test_simulated_attacks(self) -> None:
        profile = healthy_profile(XorShift32(31337))
        healthy = simulate(2048, 31337, profile)
        self.assertEqual(latched_events(monitor(healthy)), 0)
        replay = simulate(2048, 31337, profile, Fault("replay", 1024, 600))
        self.assertTrue(latched_events(monitor(replay)) & EVENT_REPLAY)
        frozen = simulate(2048, 31337, profile, Fault("frozen", 1024))
        self.assertTrue(latched_events(monitor(frozen)) & EVENT_FROZEN)

    def test_block_hit_count_is_reported(self) -> None:
        stream = [(5, 5, 5)] * (2 * BLOCK_SAMPLES)
        events = monitor(stream, IntegrityConfig(frozen_limit=0))
        self.assertEqual(events[BLOCK_SAMPLES - 1].replay_hits, BLOCK_SAMPLES - HASH_TAPS)
        self.assertEqual(events[2 * BLOCK_SAMPLES - 1].replay_hits, BLOCK_SAMPLES)


if __name__ == "__main__":
    unittest.main()
