"""Deterministic ADXL345-style motor-vibration and sensor-attack simulator.

The simulator produces signed INT16 X/Y/Z samples at 800 samples/s in the
ADXL345 full-resolution scale (256 LSB/g). It is intentionally standard-library
only and seeded so every training set, test vector and RTL scenario can be
regenerated bit-for-bit on any machine.

It is a test-stimulus generator, not a claim about a specific motor: the
physical constants are plausible values for a small fan-cooled DC motor and are
replaced by recorded Icicle Kit data once the hardware is assembled.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import math

SAMPLE_RATE_HZ = 800
LSB_PER_G = 256
INT16_MIN = -32768
INT16_MAX = 32767

Sample = tuple[int, int, int]


class XorShift32:
    """Small portable PRNG; independent of Python's ``random`` internals."""

    def __init__(self, seed: int) -> None:
        self.state = (seed & 0xFFFFFFFF) or 0x6D2B79F5

    def next_u32(self) -> int:
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.state = x
        return x

    def uniform(self) -> float:
        return (self.next_u32() + 0.5) / 4294967296.0

    def gauss(self) -> float:
        # Box-Muller using only the cosine branch keeps the stream simple.
        u1 = self.uniform()
        u2 = self.uniform()
        return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)


@dataclass(frozen=True)
class MotorProfile:
    """Operating point of the healthy demonstration motor."""

    rotation_hz: float = 24.5
    imbalance_lsb: float = 18.0
    harmonic_lsb: float = 5.0
    noise_lsb: float = 4.0
    tilt_x_lsb: float = 0.0
    tilt_y_lsb: float = 0.0
    gravity_lsb: float = float(LSB_PER_G)
    load_wobble: float = 0.05


@dataclass(frozen=True)
class Fault:
    """A mechanical fault or sensor attack applied from ``onset`` onward."""

    kind: str = "none"
    onset: int = 0
    magnitude: float = 0.0


MECHANICAL_FAULTS = ("imbalance", "bearing")
SENSOR_ATTACKS = ("bias", "noise", "frozen", "replay", "spike")


def _saturate16(value: float) -> int:
    integer = int(math.floor(value + 0.5))
    return max(INT16_MIN, min(INT16_MAX, integer))


def healthy_profile(rng: XorShift32) -> MotorProfile:
    """Draw a healthy operating point from the training distribution."""

    def spread(nominal: float, fraction: float) -> float:
        return nominal * (1.0 + fraction * (2.0 * rng.uniform() - 1.0))

    tilt = math.radians(3.0) * (2.0 * rng.uniform() - 1.0)
    roll = math.radians(3.0) * (2.0 * rng.uniform() - 1.0)
    return MotorProfile(
        rotation_hz=spread(24.5, 0.12),
        imbalance_lsb=spread(18.0, 0.25),
        harmonic_lsb=spread(5.0, 0.30),
        noise_lsb=spread(4.0, 0.20),
        tilt_x_lsb=LSB_PER_G * math.sin(tilt),
        tilt_y_lsb=LSB_PER_G * math.sin(roll),
        gravity_lsb=LSB_PER_G * math.cos(tilt) * math.cos(roll),
    )


def simulate(
    count: int,
    seed: int,
    profile: MotorProfile | None = None,
    fault: Fault | None = None,
) -> list[Sample]:
    """Generate ``count`` samples, optionally applying one fault or attack."""

    rng = XorShift32(seed)
    profile = profile or healthy_profile(rng)
    fault = fault or Fault()
    if fault.kind not in ("none",) + MECHANICAL_FAULTS + SENSOR_ATTACKS:
        raise ValueError(f"unknown fault kind {fault.kind!r}")

    phase = 2.0 * math.pi * rng.uniform()
    harmonic_phase = 2.0 * math.pi * rng.uniform()
    wobble_phase = 2.0 * math.pi * rng.uniform()
    bpfo_hz = 3.58 * profile.rotation_hz
    resonance_hz = 280.0
    impulse_phase = 0.0
    ring_amplitude = 0.0
    ring_time = 0.0

    samples: list[Sample] = []
    for index in range(count):
        t = index / SAMPLE_RATE_HZ
        active = fault.kind != "none" and index >= fault.onset
        load = 1.0 + profile.load_wobble * math.sin(
            2.0 * math.pi * 0.7 * t + wobble_phase
        )
        theta = 2.0 * math.pi * profile.rotation_hz * t + phase
        one_x = profile.imbalance_lsb * load
        if active and fault.kind == "imbalance":
            one_x *= fault.magnitude
        two_x = profile.harmonic_lsb

        x = one_x * math.cos(theta) + two_x * math.cos(2 * theta + harmonic_phase)
        y = 0.8 * one_x * math.sin(theta) + two_x * math.sin(2 * theta)
        z = 0.15 * one_x * math.cos(theta + 0.4)

        if active and fault.kind == "bearing":
            impulse_phase += bpfo_hz / SAMPLE_RATE_HZ
            if impulse_phase >= 1.0:
                impulse_phase -= 1.0
                ring_amplitude = fault.magnitude * (0.8 + 0.4 * rng.uniform())
                ring_time = 0.0
            ring = ring_amplitude * math.exp(-ring_time / 0.003) * math.sin(
                2.0 * math.pi * resonance_hz * ring_time
            )
            ring_time += 1.0 / SAMPLE_RATE_HZ
            x += ring
            y += 0.6 * ring
            z += 0.9 * ring

        noise = profile.noise_lsb
        x += profile.tilt_x_lsb + noise * rng.gauss()
        y += profile.tilt_y_lsb + noise * rng.gauss()
        z += profile.gravity_lsb + noise * rng.gauss()

        if active and fault.kind == "bias":
            x += fault.magnitude
        if active and fault.kind == "noise":
            x += fault.magnitude * rng.gauss()
            y += fault.magnitude * rng.gauss()
            z += fault.magnitude * rng.gauss()

        samples.append((_saturate16(x), _saturate16(y), _saturate16(z)))

    if fault.kind in ("frozen", "replay", "spike"):
        samples = _apply_stream_attack(samples, fault, rng)
    return samples


def _apply_stream_attack(
    samples: list[Sample], fault: Fault, rng: XorShift32
) -> list[Sample]:
    onset = fault.onset
    attacked = list(samples)
    if fault.kind == "frozen":
        held = samples[onset - 1]
        for index in range(onset, len(samples)):
            attacked[index] = held
    elif fault.kind == "replay":
        # Loop a recording of the healthy stream. The loop length is
        # deliberately not a multiple of the 128-sample hop, so detection must
        # not depend on window alignment.
        loop = int(fault.magnitude)
        recording = samples[onset - loop : onset]
        for index in range(onset, len(samples)):
            attacked[index] = recording[(index - onset) % loop]
    elif fault.kind == "spike":
        period = 53
        for index in range(onset, len(samples), period):
            sign = 1 if rng.next_u32() & 1 else -1
            x, y, z = attacked[index]
            attacked[index] = (_saturate16(x + sign * fault.magnitude), y, z)
    return attacked


def with_profile(profile: MotorProfile, **changes: float) -> MotorProfile:
    return replace(profile, **changes)
