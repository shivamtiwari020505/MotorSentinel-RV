"""Render the MotorSentinel-RV system block diagram (vector PDF + PNG).

The contest portal links to docs/MotorSentinel-RV_System_Block_Diagram.pdf on
the main branch, so the output path and filename must never change; only the
content is regenerated. The proposal-stage original is preserved in
docs/archive/.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
matplotlib.rcParams["pdf.fonttype"] = 42  # embed TrueType text, not Type 3
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch  # noqa: E402

NAVY = "#17324d"
TEAL = "#1f8a7a"
TEAL_FILL = "#e8f5f2"
BLUE = "#1d6a8a"
BLUE_FILL = "#e9f1f7"
RED = "#c0392b"
RED_FILL = "#fbeaea"
ORANGE = "#e8913a"
ORANGE_FILL = "#fdf0e3"
GREY = "#5f6b76"
WHITE = "#ffffff"
GOLD = "#b7791f"
GOLD_FILL = "#fff7e6"

OUTPUT_DIR = Path(__file__).resolve().parents[1] / "docs"
STEM = "MotorSentinel-RV_System_Block_Diagram"  # path linked from the portal


def box(ax, x, y, w, h, title, lines=(), edge=TEAL, fill=WHITE, planned=False,
        title_size=11.5, line_size=8.6, radius=0.012, lw=1.8):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle=f"round,pad=0,rounding_size={radius}",
        linewidth=lw, edgecolor=edge, facecolor=fill,
        linestyle=(0, (4, 3)) if planned else "solid", zorder=2))
    count = len(lines)
    title_y = y + h - 0.030 if count else y + h / 2
    ax.text(x + w / 2, title_y, title, ha="center", va="center",
            fontsize=title_size, fontweight="bold", color=NAVY, zorder=3)
    for index, line in enumerate(lines):
        ax.text(x + w / 2, title_y - 0.034 - index * 0.026, line, ha="center",
                va="center", fontsize=line_size, color=GREY, zorder=3)


def arrow(ax, start, end, color=TEAL, lw=2.0, style="-|>", ls="solid",
          connection="arc3,rad=0"):
    ax.add_patch(FancyArrowPatch(
        start, end, arrowstyle=style, mutation_scale=14, linewidth=lw,
        color=color, linestyle=ls, connectionstyle=connection, zorder=4,
        shrinkA=0, shrinkB=0))


def label(ax, x, y, text, color=GREY, size=8.6, ha="center", weight="normal"):
    ax.text(x, y, text, ha=ha, va="center", fontsize=size, color=color,
            fontweight=weight, zorder=5,
            bbox=dict(facecolor=WHITE, edgecolor="none", pad=1.2, alpha=0.92))


def render(output_dir: Path) -> None:
    fig = plt.figure(figsize=(16, 9.4), dpi=150)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1.6)
    ax.set_ylim(0, 0.94)
    ax.axis("off")
    fig.patch.set_facecolor(WHITE)

    ax.text(0.04, 0.905, "MotorSentinel-RV System Architecture",
            fontsize=21, fontweight="bold", color=NAVY, va="center")
    ax.text(0.04, 0.868,
            "Track 2 — PolarFire SoC Icicle Kit  |  sensor-bus guard + sensor-integrity "
            "monitor + INT8 EdgeMatrix-RV autoencoder + hardware safety policy",
            fontsize=10.5, color=GREY, va="center")

    # External sensors and attacker.
    box(ax, 0.03, 0.62, 0.17, 0.11, "ADXL345", ("3-axis accelerometer", "800 S/s, 256 LSB/g"),
        edge=BLUE, fill=BLUE_FILL)
    box(ax, 0.03, 0.44, 0.17, 0.11, "RP2040 PIO", ("attack emulator", "replay, freeze, NACK, bias"),
        edge=ORANGE, fill=ORANGE_FILL, planned=True)

    # PolarFire SoC outline and fabric region.
    ax.add_patch(FancyBboxPatch((0.24, 0.035), 1.13, 0.80,
                                boxstyle="round,pad=0,rounding_size=0.02",
                                linewidth=2.6, edgecolor=NAVY, facecolor="#f7fafc", zorder=1))
    ax.text(0.265, 0.81, "PolarFire SoC MPFS250T", fontsize=13, fontweight="bold",
            color=NAVY, va="center")
    ax.add_patch(FancyBboxPatch((0.26, 0.27), 1.09, 0.515,
                                boxstyle="round,pad=0,rounding_size=0.015",
                                linewidth=2.0, edgecolor=TEAL, facecolor=TEAL_FILL, zorder=1))
    ax.text(0.28, 0.762, "FPGA FABRIC — deterministic data plane (motorsentinel_core_apb)",
            fontsize=12.5, fontweight="bold", color=TEAL, va="center")

    # Acquisition stage.
    box(ax, 0.275, 0.555, 0.165, 0.13, "I2C Acquisition", ("ADXL345 sequencer", "(next milestone)"),
        edge=TEAL, planned=True)
    box(ax, 0.275, 0.33, 0.165, 0.17, "Protocol Guard", ("2-FF line sync", "stuck SCL/SDA, stretch",
        "NACK storm, rogue START", "missing-sample watchdog"))

    # Integrity monitor.
    box(ax, 0.48, 0.555, 0.21, 0.17, "Sensor-Integrity Monitor",
        ("range + slew limits", "frozen-value run detector",
         "replay: 16-tap rolling hash", "1024-entry tag RAM"), edge=GOLD, fill=GOLD_FILL,
        title_size=10.2)

    # Feature + inference chain.
    box(ax, 0.48, 0.33, 0.20, 0.17, "Feature Extractor",
        ("256-sample / 128-hop windows", "mean, MS, p-p, exact ZCR",
         "4 Haar band energies", "16 x 32-bit, bit-exact"))
    box(ax, 0.73, 0.33, 0.14, 0.17, "INT8 Normalizer",
        ("per-feature offset,", "scale, shift, sat8", "streams with the", "16-word transfer"),
        title_size=10.2)
    box(ax, 0.91, 0.33, 0.20, 0.17, "EdgeMatrix-RV",
        ("8x8 INT8 systolic array", "16 -> 8 -> 16 autoencoder", "4 weight tiles, ReLU",
         "L1 score in 74 cycles"))
    box(ax, 0.91, 0.555, 0.20, 0.125, "Model Store",
        ("122-word image, CRC-32", "format + range checks", "fail-safe atomic commit"))

    # Safety policy.
    box(ax, 1.16, 0.33, 0.17, 0.39, "Safety Policy", ("verified kernel, unchanged", "",
        "protocol faults", "integrity faults", "learned anomaly", "(2-window confirm)",
        "latched provenance", "healthy-window recovery", "explicit re-arm"),
        edge=RED, fill=RED_FILL)

    # Motor.
    box(ax, 1.42, 0.44, 0.16, 0.17, "Motor Driver", ("+ DC motor", "active-high enable,", "pull-down fail-safe"),
        edge=RED, fill=RED_FILL)

    # MSS region.
    ax.add_patch(FancyBboxPatch((0.26, 0.055), 1.09, 0.17,
                                boxstyle="round,pad=0,rounding_size=0.015",
                                linewidth=2.0, edgecolor=BLUE, facecolor=BLUE_FILL, zorder=1))
    ax.text(0.28, 0.203, "RISC-V MSS — Linux control plane (not in the safety path)",
            fontsize=12.5, fontweight="bold", color=BLUE, va="center")
    box(ax, 0.30, 0.075, 0.22, 0.095, "UIO driver + model loader", ("CRC-checked image, thresholds",),
        edge=BLUE, planned=True, title_size=9.8)
    box(ax, 0.56, 0.075, 0.22, 0.095, "Event service + dashboard", ("fault provenance, scores, features",),
        edge=BLUE, planned=True, title_size=9.8)
    box(ax, 0.82, 0.075, 0.22, 0.095, "CPU baseline + replay", ("same data via APB injection",),
        edge=BLUE, planned=True, title_size=9.8)
    box(ax, 1.08, 0.075, 0.24, 0.095, "PAC1934 power monitor", ("CPU vs FPGA energy per window",),
        edge=BLUE, planned=True, title_size=9.8)

    # Data arrows.
    arrow(ax, (0.20, 0.675), (0.275, 0.640), color=BLUE)
    label(ax, 0.238, 0.705, "I2C 400 kHz", BLUE, size=8.2)
    arrow(ax, (0.20, 0.495), (0.275, 0.600), color=ORANGE, ls=(0, (4, 3)))
    arrow(ax, (0.3575, 0.555), (0.3575, 0.500), color=TEAL)
    label(ax, 0.395, 0.528, "SCL/SDA", TEAL, size=8)
    arrow(ax, (0.44, 0.640), (0.48, 0.640), color=TEAL)
    ax.plot([0.46, 0.46], [0.640, 0.415], color=TEAL, lw=2.0, zorder=4)
    arrow(ax, (0.46, 0.415), (0.48, 0.415), color=TEAL)
    label(ax, 0.46, 0.668, "X/Y/Z", TEAL, size=8)
    arrow(ax, (0.68, 0.415), (0.73, 0.415), color=TEAL)
    arrow(ax, (0.87, 0.415), (0.91, 0.415), color=TEAL)
    label(ax, 0.89, 0.448, "q[16]", TEAL, size=8)
    arrow(ax, (1.01, 0.555), (1.01, 0.500), color=TEAL)
    label(ax, 1.048, 0.528, "weights", TEAL, size=8)
    arrow(ax, (1.11, 0.415), (1.16, 0.415), color=TEAL)
    label(ax, 1.135, 0.448, "score", TEAL, size=8)
    ax.plot([0.69, 0.71, 0.71], [0.640, 0.640, 0.705], color=GOLD, lw=2.0, zorder=4)
    ax.plot([0.71, 1.14], [0.705, 0.705], color=GOLD, lw=2.0, zorder=4)
    ax.plot([1.14, 1.14], [0.705, 0.660], color=GOLD, lw=2.0, zorder=4)
    arrow(ax, (1.14, 0.660), (1.16, 0.660), color=GOLD)
    label(ax, 0.80, 0.705, "range / slew / frozen / replay", GOLD, size=8.4, weight="bold")
    ax.plot([0.3575, 0.3575], [0.330, 0.300], color=RED, lw=2.0, zorder=4)
    ax.plot([0.3575, 1.245], [0.300, 0.300], color=RED, lw=2.0, zorder=4)
    arrow(ax, (1.245, 0.300), (1.245, 0.330), color=RED)
    label(ax, 0.62, 0.300, "protocol faults (6 causes)", RED, size=8.4)
    arrow(ax, (1.33, 0.525), (1.42, 0.525), color=RED, lw=3.2)
    label(ax, 1.375, 0.565, "safe disable", RED, size=9, weight="bold")

    # Control-plane link.
    arrow(ax, (0.41, 0.225), (0.41, 0.270), color=BLUE, style="<|-|>")
    label(ax, 0.43, 0.245,
          "APB3 via FIC3, one 256-byte slot: 0x00-0x3F safety kernel, 0x40-0xFF data plane  |  level IRQ to MSS",
          BLUE, size=8.6, ha="left")

    # Verified results panel.
    ax.add_patch(FancyBboxPatch((1.385, 0.64), 0.21, 0.195,
                                boxstyle="round,pad=0,rounding_size=0.012",
                                linewidth=1.6, edgecolor=NAVY, facecolor=WHITE, zorder=2))
    ax.text(1.49, 0.812, "Verified in RTL simulation", ha="center", fontsize=9.2,
            fontweight="bold", color=NAVY, va="center")
    results = (
        "9/9 attack scenarios pass",
        "every score bit-exact vs Python",
        "decision 348 cycles (6.96 us)",
        "frozen sensor trip: 38.75 ms",
        "spike trip: 1 sample (1.25 ms)",
        "mechanical faults: 320 ms",
    )
    for index, line in enumerate(results):
        ax.text(1.393, 0.778 - index * 0.024, "• " + line, fontsize=7.8,
                color=GREY, va="center")

    # Legend.
    ax.plot([0.04, 0.08], [0.012, 0.012], color=TEAL, lw=2)
    ax.text(0.085, 0.012, "implemented and verified", fontsize=8.6, color=GREY, va="center")
    ax.plot([0.30, 0.34], [0.012, 0.012], color=TEAL, lw=2, ls=(0, (4, 3)))
    ax.text(0.345, 0.012, "planned / board integration", fontsize=8.6, color=GREY, va="center")
    ax.plot([0.58, 0.62], [0.012, 0.012], color=RED, lw=2)
    ax.text(0.625, 0.012, "independent hardware safety response", fontsize=8.6, color=GREY, va="center")
    ax.plot([0.92, 0.96], [0.012, 0.012], color=GOLD, lw=2)
    ax.text(0.965, 0.012, "sensor-integrity evidence", fontsize=8.6, color=GREY, va="center")

    output_dir.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_dir / f"{STEM}.png", dpi=150, facecolor=WHITE)
    fig.savefig(output_dir / f"{STEM}.pdf", facecolor=WHITE)
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    args = parser.parse_args()
    render(args.output_dir)


if __name__ == "__main__":
    main()
