"""Export the committed model as the binary file loaded by msrvctl.

Layout: the 122-word APB model image followed by the anomaly threshold, all
little-endian 32-bit words (492 bytes). msrvctl verifies the format word and
the hardware recomputes the image CRC-32 before committing.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from model.edgematrix import DEFAULT_MODEL_PATH, image_crc, load_model, model_image  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL_PATH)
    parser.add_argument("--output", type=Path, default=Path("build/motorsentinel_ae_v1.bin"))
    args = parser.parse_args()

    model = load_model(args.model)
    words = model_image(model) + [model.threshold]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(struct.pack(f"<{len(words)}I", *words))
    print(f"{args.output}: {len(words) * 4} bytes, image CRC-32 "
          f"0x{image_crc(model_image(model)):08x}, threshold {model.threshold}")


if __name__ == "__main__":
    main()
