"""Render the MotorSentinel-RV system block diagram (PNG + Pillow-encoded PDF).

The contest portal links to docs/MotorSentinel-RV_System_Block_Diagram.pdf on
the main branch, so the output path and filename must never change; only the
content is regenerated. The proposal-stage original is preserved in
docs/archive/.

The figure is sized for GitHub's in-browser preview: large type, at most two
short lines per block, and details left to docs/milestone-3.md.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from PIL import Image  # noqa: E402
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
GREY = "#4f5b66"
WHITE = "#ffffff"
GOLD = "#b7791f"
GOLD_FILL = "#fff7e6"

OUTPUT_DIR = Path(__file__).resolve().parents[1] / "docs"
STEM = "MotorSentinel-RV_System_Block_Diagram"  # path linked from the portal
PDF_DPI = 200

TITLE_SIZE = 13.5
LINE_SIZE = 10.5
LINE_STEP = 0.030


def _pick_font() -> None:
    available = {font.name for font in font_manager.fontManager.ttflist}
    for name in ("Segoe UI", "Calibri", "Arial"):
        if name in available:
            # DejaVu Sans supplies glyphs the UI font lacks (for example ✓).
            matplotlib.rcParams["font.family"] = [name, "DejaVu Sans"]
            return


def box(ax, x, y, w, h, title, lines=(), edge=TEAL, fill=WHITE, planned=False,
        title_size=TITLE_SIZE, line_size=LINE_SIZE, lw=2.0):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0,rounding_size=0.012",
        linewidth=lw, edgecolor=edge, facecolor=fill,
        linestyle=(0, (4, 3)) if planned else "solid", zorder=2))
    block = 0.036 + LINE_STEP * len(lines) if lines else 0.0
    title_y = y + h / 2 + block / 2 - 0.012 if lines else y + h / 2
    ax.text(x + w / 2, title_y, title, ha="center", va="center",
            fontsize=title_size, fontweight="bold", color=NAVY, zorder=3)
    for index, line in enumerate(lines):
        ax.text(x + w / 2, title_y - 0.040 - index * LINE_STEP, line,
                ha="center", va="center", fontsize=line_size, color=GREY, zorder=3)


def arrow(ax, start, end, color=TEAL, lw=2.4, style="-|>", ls="solid"):
    ax.add_patch(FancyArrowPatch(
        start, end, arrowstyle=style, mutation_scale=16, linewidth=lw,
        color=color, linestyle=ls, zorder=4, shrinkA=0, shrinkB=0))


def line(ax, xs, ys, color, lw=2.4):
    ax.plot(xs, ys, color=color, lw=lw, zorder=4, solid_capstyle="round")


def label(ax, x, y, text, color=GREY, size=10, ha="center", weight="normal"):
    ax.text(x, y, text, ha=ha, va="center", fontsize=size, color=color,
            fontweight=weight, zorder=5,
            bbox=dict(facecolor=WHITE, edgecolor="none", pad=1.5, alpha=0.95))


def region(ax, x, y, w, h, edge, fill, lw, title=None, title_color=None, size=14):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                                boxstyle="round,pad=0,rounding_size=0.016",
                                linewidth=lw, edgecolor=edge, facecolor=fill, zorder=1))
    if title:
        ax.text(x + 0.018, y + h - 0.024, title, fontsize=size, fontweight="bold",
                color=title_color or edge, va="center", zorder=3)


def render(output_dir: Path) -> None:
    _pick_font()
    fig = plt.figure(figsize=(13, 7.64), dpi=150)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1.6)
    ax.set_ylim(0, 0.94)
    ax.axis("off")
    fig.patch.set_facecolor(WHITE)

    ax.text(0.02, 0.905, "MotorSentinel-RV System Architecture",
            fontsize=23, fontweight="bold", color=NAVY, va="center")
    ax.text(0.02, 0.862,
            "Track 2 — PolarFire SoC Icicle Kit  |  attack-resilient sensing, "
            "INT8 inference and hardware safe response",
            fontsize=12, color=GREY, va="center")

    # External devices.
    box(ax, 0.015, 0.57, 0.17, 0.12, "ADXL345", ("vibration sensor", "800 S/s over I2C"),
        edge=BLUE, fill=BLUE_FILL)
    box(ax, 0.015, 0.38, 0.17, 0.12, "RP2040 PIO", ("attack emulator", "for live demos"),
        edge=ORANGE, fill=ORANGE_FILL, planned=True)

    # PolarFire SoC, fabric and MSS regions.
    region(ax, 0.21, 0.035, 1.155, 0.795, NAVY, "#f7fafc", 2.8,
           "PolarFire SoC MPFS250T", NAVY, size=15)
    region(ax, 0.225, 0.29, 1.125, 0.48, TEAL, TEAL_FILL, 2.2,
           "FPGA FABRIC — deterministic data plane", TEAL, size=14)
    region(ax, 0.225, 0.055, 1.125, 0.17, BLUE, BLUE_FILL, 2.2,
           "RISC-V MSS — Linux control plane (outside the safety path)", BLUE, size=14)

    # Fabric blocks: acquisition | integrity + features | model + inference | policy.
    box(ax, 0.27, 0.56, 0.18, 0.12, "I2C Acquisition", ("ADXL345 sequencer", "next milestone"),
        planned=True)
    box(ax, 0.27, 0.35, 0.18, 0.12, "Protocol Guard", ("stuck bus, stalls", "NACK storm"))
    box(ax, 0.50, 0.56, 0.22, 0.12, "Integrity Monitor", ("range · slew · frozen", "replay (rolling hash)"),
        edge=GOLD, fill=GOLD_FILL)
    box(ax, 0.50, 0.35, 0.22, 0.12, "Feature Extractor", ("16 features / window", "256 samples, 50% overlap"))
    box(ax, 0.77, 0.56, 0.22, 0.12, "Model Store", ("CRC-32 verified", "fail-safe commit"))
    box(ax, 0.77, 0.35, 0.22, 0.12, "EdgeMatrix-RV", ("8×8 INT8 systolic array", "16→8→16 autoencoder"))
    box(ax, 1.06, 0.35, 0.24, 0.33, "Safety Policy", ("protocol faults", "attack evidence",
        "learned anomaly", "latched, explicit re-arm"), edge=RED, fill=RED_FILL)

    # Motor and results.
    box(ax, 1.40, 0.43, 0.185, 0.15, "Motor Driver", ("+ DC motor", "fail-safe off"),
        edge=RED, fill=RED_FILL)
    ax.add_patch(FancyBboxPatch((1.385, 0.625), 0.21, 0.205,
                                boxstyle="round,pad=0,rounding_size=0.012",
                                linewidth=2.0, edgecolor=NAVY, facecolor=WHITE, zorder=2))
    ax.text(1.49, 0.800, "Verified in simulation", ha="center", fontsize=11.5,
            fontweight="bold", color=NAVY, va="center")
    for index, text in enumerate((
        "9/9 attacks detected",
        "0 false trips",
        "decision in 6.96 µs",
        "bit-exact vs Python",
    )):
        ax.text(1.400, 0.758 - index * 0.032, "✓  " + text, fontsize=10.5,
                color=GREY, va="center")

    # MSS blocks.
    for x, title, sub in (
        (0.255, "Linux UIO driver", "loads verified model"),
        (0.535, "Event dashboard", "faults, scores, features"),
        (0.815, "CPU baseline", "same data via APB"),
        (1.095, "PAC1934 monitor", "energy per window"),
    ):
        box(ax, x, 0.072, 0.235, 0.095, title, (sub,), edge=BLUE, planned=True,
            title_size=12, line_size=10)

    # Data flow.
    arrow(ax, (0.185, 0.63), (0.27, 0.62), color=BLUE)
    arrow(ax, (0.185, 0.44), (0.27, 0.585), color=ORANGE, ls=(0, (4, 3)))
    arrow(ax, (0.36, 0.56), (0.36, 0.47))
    label(ax, 0.40, 0.515, "SCL/SDA", TEAL, size=9.5)
    arrow(ax, (0.45, 0.62), (0.50, 0.62))
    line(ax, [0.475, 0.475], [0.62, 0.41], TEAL)
    arrow(ax, (0.475, 0.41), (0.50, 0.41))
    label(ax, 0.475, 0.52, "X/Y/Z", TEAL, size=9.5)
    arrow(ax, (0.72, 0.41), (0.77, 0.41))
    arrow(ax, (0.88, 0.56), (0.88, 0.47))
    label(ax, 0.925, 0.515, "weights", TEAL, size=9.5)
    arrow(ax, (0.99, 0.41), (1.06, 0.41))
    label(ax, 1.025, 0.445, "score", TEAL, size=9.5)

    # Attack evidence (gold) and protocol faults (red) into the policy.
    line(ax, [0.72, 0.745, 0.745], [0.62, 0.62, 0.715], GOLD)
    line(ax, [0.745, 1.03], [0.715, 0.715], GOLD)
    line(ax, [1.03, 1.03], [0.715, 0.64], GOLD)
    arrow(ax, (1.03, 0.64), (1.06, 0.64), color=GOLD)
    label(ax, 0.87, 0.715, "attack evidence", GOLD, size=10, weight="bold")
    line(ax, [0.36, 0.36], [0.35, 0.315], RED)
    line(ax, [0.36, 1.18], [0.315, 0.315], RED)
    arrow(ax, (1.18, 0.315), (1.18, 0.35), color=RED)
    label(ax, 0.64, 0.315, "protocol faults", RED, size=10)

    # Safety response and control plane.
    arrow(ax, (1.30, 0.505), (1.40, 0.505), color=RED, lw=3.6)
    label(ax, 1.35, 0.555, "safe\ndisable", RED, size=10.5, weight="bold")
    arrow(ax, (0.36, 0.225), (0.36, 0.29), color=BLUE, style="<|-|>")
    label(ax, 0.385, 0.258, "APB control + IRQ (no Linux in the trip path)", BLUE,
          size=10, ha="left")

    # Legend.
    legend = (
        (0.02, TEAL, "solid", "implemented and verified"),
        (0.33, TEAL, (0, (4, 3)), "planned"),
        (0.50, RED, "solid", "hardware safety response"),
        (0.83, GOLD, "solid", "sensor-attack evidence"),
    )
    for x, color, style, text in legend:
        ax.plot([x, x + 0.04], [0.014, 0.014], color=color, lw=2.4, ls=style)
        ax.text(x + 0.048, 0.014, text, fontsize=10, color=GREY, va="center")

    output_dir.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_dir / f"{STEM}.png", dpi=PDF_DPI, facecolor=WHITE)
    # GitHub's PDF viewer fails on matplotlib's vector PDF, so the linked PDF
    # uses the same Pillow raster encoding as the original proposal diagram.
    plt.close(fig)
    with Image.open(output_dir / f"{STEM}.png") as image:
        image.convert("RGB").save(output_dir / f"{STEM}.pdf", "PDF",
                                  resolution=float(PDF_DPI), quality=90)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    args = parser.parse_args()
    render(args.output_dir)


if __name__ == "__main__":
    main()
