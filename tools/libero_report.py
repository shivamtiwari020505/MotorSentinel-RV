"""Summarize a MotorSentinel-RV Libero build into build/libero/summary.md.

Libero's report names differ between releases, so this tool searches the
project tree instead of assuming fixed paths. It copies the relevant lines
verbatim: device resource usage from the place-and-route log, worst slack
from the timing reports and any failure reported by the build script. It does
not compute or estimate anything itself.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re

RESOURCE_PATTERN = re.compile(
    r"\b(4LUT|DFF|uSRAM|LSRAM|Math|User I/O|Single-ended I/O|Global|"
    r"Fabric 4LUT|Fabric DFF|Interface 4LUT|Interface DFF)\b"
)
SLACK_PATTERN = re.compile(r"slack", re.IGNORECASE)


def _read(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def resource_lines(project: Path) -> tuple[Path | None, list[str]]:
    logs = sorted(project.glob("designer/*/*layout_log*.log"))
    for log in logs:
        lines = [line.rstrip() for line in _read(log) if RESOURCE_PATTERN.search(line)]
        if lines:
            return log, lines
    return (logs[0] if logs else None), []


def timing_lines(project: Path, limit: int = 12) -> list[tuple[Path, list[str]]]:
    found = []
    for report in sorted(project.glob("designer/*/*timing*")):
        if report.is_file():
            lines = [line.rstrip() for line in _read(report) if SLACK_PATTERN.search(line)]
            if lines:
                found.append((report, lines[:limit]))
    return found


def build_failures(log: Path) -> list[str]:
    return [line for line in _read(log) if "MSRV: FAILED" in line or "ERROR" in line][:20]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path("build/libero"))
    args = parser.parse_args()
    project = args.build_dir / "motorsentinel"

    out = ["# MotorSentinel-RV Libero build summary", ""]
    failures = build_failures(args.build_dir / "libero.log")
    if failures:
        out += ["## Build errors", "", "```text", *failures, "```", ""]

    log, resources = resource_lines(project)
    out += ["## Resource usage", ""]
    if resources:
        out += [f"From `{log}`:", "", "```text", *resources, "```", ""]
    else:
        out += ["No place-and-route resource table found.", ""]

    out += ["## Timing", ""]
    timing = timing_lines(project)
    if timing:
        for report, lines in timing:
            out += [f"From `{report}`:", "", "```text", *lines, "```", ""]
    else:
        out += ["No timing report found.", ""]

    summary = args.build_dir / "summary.md"
    summary.parent.mkdir(parents=True, exist_ok=True)
    summary.write_text("\n".join(out) + "\n", encoding="utf-8")
    print("\n".join(out))
    print(f"wrote {summary}")


if __name__ == "__main__":
    main()
