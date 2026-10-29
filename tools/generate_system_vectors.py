"""Generate EdgeMatrix-RV and end-to-end attack-scenario RTL vectors.

Outputs (all deterministic):
  model_image.hex            122-word APB model image
  inference_features.hex     random and extreme feature vectors
  inference_expected.hex     score, q, h and y for each vector
  system_config.hex          CRC, threshold, integrity limits, scenario count
  system_manifest.hex        per-scenario metadata and expected outcome
  system_samples.hex         concatenated X/Y/Z scenario streams
  system_scores.hex          concatenated expected per-window anomaly scores
  scenario_summary.txt       human-readable expectation table
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from model.edgematrix import (  # noqa: E402
    DEFAULT_MODEL_PATH,
    INPUTS,
    QuantizedModel,
    image_crc,
    infer,
    load_model,
    model_image,
)
from model.features import HOP_SIZE, WINDOW_SIZE, extract_overlapping  # noqa: E402
from model.integrity import (  # noqa: E402
    IntegrityConfig,
    latched_events,
    monitor,
)
from model.motor_sim import (  # noqa: E402
    SAMPLE_RATE_HZ,
    Fault,
    XorShift32,
    healthy_profile,
    simulate,
)

SCENARIO_SAMPLES = 2816
ONSET = 1536
ANOMALY_CONFIRM = 2
NONE = 0xFFFFFFFF
INTEGRITY = IntegrityConfig(
    range_limit=4000, slew_limit=1024, frozen_limit=32, replay_threshold=16
)

FAULT_NACK_LIMIT = 1 << 3
FAULT_PHYSICAL = 1 << 6
FAULT_ANOMALY = 1 << 9


@dataclass(frozen=True)
class Scenario:
    name: str
    fault: Fault
    seed: int
    nack_at: int = NONE  # accepted-sample count at which a NACK storm starts


SCENARIOS = (
    Scenario("normal", Fault(), 9001),
    Scenario("imbalnce", Fault("imbalance", ONSET, 3.0), 9002),
    Scenario("bearing", Fault("bearing", ONSET, 60.0), 9003),
    Scenario("bias", Fault("bias", ONSET, 120.0), 9004),
    Scenario("noise", Fault("noise", ONSET, 40.0), 9005),
    Scenario("frozen", Fault("frozen", ONSET), 9006),
    Scenario("replay", Fault("replay", ONSET, 600.0), 9007),
    Scenario("spike", Fault("spike", ONSET, 1500.0), 9008),
    Scenario("nackstrm", Fault(), 9009, nack_at=ONSET),
)


def scenario_samples(scenario: Scenario):
    profile = healthy_profile(XorShift32(scenario.seed ^ 0x9E3779B9))
    return simulate(SCENARIO_SAMPLES, scenario.seed, profile, scenario.fault)


def expected_outcome(scenario: Scenario, model: QuantizedModel, samples):
    """Model the safety policy decision in accepted-sample time."""

    scores = [infer(model, window).score for window in extract_overlapping(samples)]
    integrity = monitor(samples, INTEGRITY)
    trip_candidates = []
    fault_vector = 0

    for index, result in enumerate(integrity):
        if result.events:
            trip_candidates.append(index + 1)
            fault_vector |= FAULT_PHYSICAL

    consecutive = 0
    for window, score in enumerate(scores):
        if score > model.threshold:
            consecutive += 1
            if consecutive >= ANOMALY_CONFIRM:
                trip_candidates.append(WINDOW_SIZE + HOP_SIZE * window)
                fault_vector |= FAULT_ANOMALY
        else:
            consecutive = 0

    if scenario.nack_at != NONE:
        trip_candidates.append(scenario.nack_at)
        fault_vector |= FAULT_NACK_LIMIT

    trip = min(trip_candidates) if trip_candidates else NONE
    events = latched_events(integrity)
    return scores, trip, fault_vector, events


def name_words(name: str) -> tuple[int, int]:
    encoded = name.encode("ascii")[:8].ljust(8, b" ")
    return int.from_bytes(encoded[:4], "big"), int.from_bytes(encoded[4:], "big")


def inference_vectors(model: QuantizedModel, count: int):
    rng = XorShift32(0xC0FFEE)
    vectors = []
    extremes = (-(1 << 31), (1 << 31) - 1, 0, -1, 1)
    for index in range(count):
        features = []
        for feature in range(INPUTS):
            choice = rng.next_u32() % 8
            if index < 4:
                value = extremes[(index + feature) % len(extremes)]
            elif choice == 0:
                value = extremes[rng.next_u32() % len(extremes)]
            elif choice == 1:
                value = int(rng.next_u32()) - (1 << 31)
            else:
                # Near the healthy operating point, spanning several sigma.
                spread = max(64, abs(model.offset[feature]) // 2)
                value = model.offset[feature] + (
                    int(rng.next_u32() % (2 * spread + 1)) - spread
                )
                value = max(-(1 << 31), min((1 << 31) - 1, value))
            features.append(value)
        vectors.append((features, infer(model, features)))
    return vectors


def pack_int8(values) -> list[int]:
    words = []
    for base in range(0, len(values), 4):
        word = 0
        for lane in range(4):
            word |= (values[base + lane] & 0xFF) << (8 * lane)
        words.append(word)
    return words


def write_hex(path: Path, words) -> None:
    path.write_text("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words), encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=Path("build"))
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL_PATH)
    parser.add_argument("--inference-vectors", type=int, default=96)
    args = parser.parse_args()
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)

    model = load_model(args.model)
    image = model_image(model)
    write_hex(out / "model_image.hex", image)

    features_words, expected_words = [], []
    for features, result in inference_vectors(model, args.inference_vectors):
        features_words += features
        expected_words += [result.score] + pack_int8(result.q) + pack_int8(result.h) + pack_int8(result.y)
    write_hex(out / "inference_features.hex", features_words)
    write_hex(out / "inference_expected.hex", expected_words)

    manifest, sample_lines, score_words, summary = [], [], [], []
    summary.append(
        f"threshold={model.threshold} crc=0x{image_crc(image):08x} "
        f"samples/scenario={SCENARIO_SAMPLES} onset={ONSET}"
    )
    for scenario in SCENARIOS:
        samples = scenario_samples(scenario)
        scores, trip, fault_vector, events = expected_outcome(scenario, model, samples)
        name_hi, name_lo = name_words(scenario.name)
        manifest += [
            name_hi, name_lo, len(samples), ONSET if scenario.fault.kind != "none" or scenario.nack_at != NONE else NONE,
            scenario.nack_at, len(scores), trip, fault_vector, events,
            0 if trip != NONE else 1,
        ]
        sample_lines += [
            f"{x & 0xffff:04x}{y & 0xffff:04x}{z & 0xffff:04x}" for x, y, z in samples
        ]
        score_words += scores
        detect = "-" if trip == NONE else f"{(trip - ONSET) * 1000 / SAMPLE_RATE_HZ:.1f} ms"
        summary.append(
            f"{scenario.name:9s} trip_sample={'none' if trip == NONE else trip:>5} "
            f"detect={detect:>9s} faults=0x{fault_vector:03x} integrity=0x{events:x} "
            f"max_score={max(scores)}"
        )

    write_hex(out / "system_manifest.hex", manifest)
    (out / "system_samples.hex").write_text("\n".join(sample_lines) + "\n", encoding="ascii")
    write_hex(out / "system_scores.hex", score_words)
    write_hex(
        out / "system_config.hex",
        [
            image_crc(image),
            model.threshold,
            (INTEGRITY.slew_limit << 16) | INTEGRITY.range_limit,
            (INTEGRITY.replay_threshold << 8) | INTEGRITY.frozen_limit,
            len(SCENARIOS),
            ANOMALY_CONFIRM,
        ],
    )
    (out / "scenario_summary.txt").write_text("\n".join(summary) + "\n", encoding="ascii")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
