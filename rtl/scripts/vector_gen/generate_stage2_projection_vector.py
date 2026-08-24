#!/usr/bin/env python3
"""Convert the firmware team's already-generated Stage-3 projection BasicBlock golden vectors
(firmware-verification/data/test_vectors/stage2_basicblock_projection/, produced from the actual
BN-folded/quantized PyTorch model) into $readmemh-compatible .hex files for
tb_stage2_projection_block.sv. This does not recompute any golden data -- it only reformats bytes
that already exist under firmware-verification/data/test_vectors/, keeping that directory
read-only. Mirrors generate_stage2_identity_vector.py's conventions.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = REPO_ROOT.parent / "firmware-verification" / "data" / "test_vectors" / "stage2_basicblock_projection"
OUT_DIR = REPO_ROOT / "vectors" / "stage2_projection_block"


def write_hex(path: Path, data: bytes, width: int) -> None:
    assert len(data) % width == 0, f"{path}: {len(data)} bytes not a multiple of width {width}"
    lines = []
    for i in range(0, len(data), width):
        value = int.from_bytes(data[i:i + width], "little", signed=False)
        lines.append(f"{value:0{width * 2}x}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> None:
    if not SRC_DIR.exists():
        print(f"ERROR: {SRC_DIR} not found", file=sys.stderr)
        sys.exit(1)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    conv1_cfg = json.loads((SRC_DIR / "conv1" / "config.json").read_text())
    conv2_cfg = json.loads((SRC_DIR / "conv2" / "config.json").read_text())
    shortcut_cfg = json.loads((SRC_DIR / "shortcut" / "config.json").read_text())
    residual_cfg = json.loads((SRC_DIR / "residual" / "residual_config.json").read_text())

    write_hex(OUT_DIR / "conv1_input.hex", (SRC_DIR / "conv1" / "input.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "conv1_weight.hex", (SRC_DIR / "conv1" / "weight.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "conv1_bias.hex", (SRC_DIR / "conv1" / "bias.bin").read_bytes(), 4)
    write_hex(OUT_DIR / "conv1_expected.hex", (SRC_DIR / "conv1" / "expected_output.bin").read_bytes(), 1)

    write_hex(OUT_DIR / "conv2_weight.hex", (SRC_DIR / "conv2" / "weight.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "conv2_bias.hex", (SRC_DIR / "conv2" / "bias.bin").read_bytes(), 4)
    write_hex(OUT_DIR / "conv2_expected.hex", (SRC_DIR / "conv2" / "expected_output.bin").read_bytes(), 1)

    # Shortcut conv reads the block's original input (same tensor as conv1's input).
    write_hex(OUT_DIR / "shortcut_weight.hex", (SRC_DIR / "shortcut" / "weight.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "shortcut_bias.hex", (SRC_DIR / "shortcut" / "bias.bin").read_bytes(), 4)
    write_hex(OUT_DIR / "shortcut_expected.hex", (SRC_DIR / "shortcut" / "expected_output.bin").read_bytes(), 1)

    # residual_scale forces the shortcut conv's output_scale to already match conv2's, so
    # residual add takes conv2_output and shortcut_output directly, no separate rescale step.
    write_hex(OUT_DIR / "final_expected.hex", (SRC_DIR / "residual" / "final_expected_output.bin").read_bytes(), 1)

    manifest = {
        "source": str(SRC_DIR),
        "conv1": conv1_cfg,
        "conv2": conv2_cfg,
        "shortcut": shortcut_cfg,
        "residual": residual_cfg,
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"stage-3 projection block .hex vectors written to {OUT_DIR}")


if __name__ == "__main__":
    main()
