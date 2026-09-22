"""Generate deterministic RTL stimulus and bit-exact expected features."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from model.features import extract_overlapping

SAMPLE_COUNT = 1024


def signed16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def generate_samples() -> list[tuple[int, int, int]]:
    """Create deterministic directed windows followed by irregular data.

    Window zero is a signed-extreme constant. The window beginning at sample
    256 contains three independent full-scale Haar patterns (L1, L2, and L8),
    and the window at 512 contains an all-axis L4 pattern. The final window
    exercises DC-biased and centered-zero crossing semantics alongside an
    irregular signed LFSR channel. Intervening windows stress overlap edges.
    """

    samples: list[tuple[int, int, int]] = []
    lfsr = 0x5A3D
    for index in range(SAMPLE_COUNT):
        if index < 256:
            x_axis, y_axis, z_axis = -32768, 32767, -1
        elif index < 512:
            phase = index - 256
            x_axis = -32768 if (phase % 2) == 0 else 32767
            y_axis = -32768 if (phase % 4) < 2 else 32767
            z_axis = -32768 if (phase % 16) < 8 else 32767
        elif index < 768:
            phase = index - 512
            value = -32768 if (phase % 8) < 4 else 32767
            x_axis, y_axis, z_axis = value, value, value
        else:
            phase = index - 768
            x_axis = 100 if (phase % 2) == 0 else 102
            y_axis = (-1, 0, 1, 0)[phase % 4]

            feedback = (
                (lfsr >> 0) ^ (lfsr >> 2) ^ (lfsr >> 3) ^ (lfsr >> 5)
            ) & 1
            lfsr = ((lfsr >> 1) | (feedback << 15)) & 0xFFFF
            z_axis = signed16(lfsr)

        samples.append((x_axis, y_axis, z_axis))
    return samples


def write_vectors(output_dir: Path) -> None:
    samples = generate_samples()
    windows = extract_overlapping(samples)
    output_dir.mkdir(parents=True, exist_ok=True)

    sample_lines = [
        f"{x_axis & 0xffff:04x}{y_axis & 0xffff:04x}{z_axis & 0xffff:04x}"
        for x_axis, y_axis, z_axis in samples
    ]
    feature_lines = [
        f"{feature & 0xffffffff:08x}"
        for window in windows
        for feature in window
    ]

    for window in windows:
        if not all(-(1 << 31) <= feature < (1 << 31) for feature in window[:3]):
            raise AssertionError("signed mean output exceeds 32-bit contract")
        if not all(0 <= feature <= 0x7FFFFFFF for feature in window[3:]):
            raise AssertionError("nonnegative feature exceeds 31-bit contract")

    (output_dir / "feature_samples.hex").write_text(
        "\n".join(sample_lines) + "\n", encoding="ascii"
    )
    (output_dir / "feature_expected.hex").write_text(
        "\n".join(feature_lines) + "\n", encoding="ascii"
    )
    (output_dir / "feature_vector_summary.txt").write_text(
        f"samples={len(samples)}\nwindows={len(windows)}\n"
        f"features_per_window={len(windows[0])}\n",
        encoding="ascii",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir", type=Path, default=Path("build"), help="vector directory"
    )
    args = parser.parse_args()
    write_vectors(args.output_dir)


if __name__ == "__main__":
    main()
