#!/usr/bin/env python3
"""Convert the firmware team's already-generated Stage-2 identity BasicBlock golden vectors
(firmware-verification/scripts/generate_stage2_vectors.py output, produced from the actual
BN-folded/quantized PyTorch model) into $readmemh-compatible .hex files for
tb_stage2_identity_block.sv, mirroring generate_full_conv_vector.py's vectors/<name>/*.hex
convention. This does not recompute any golden data -- it only reformats bytes that already
exist under firmware-verification/data/test_vectors/, keeping that directory read-only.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = REPO_ROOT.parent / "firmware-verification" / "data" / "test_vectors" / "stage2_basicblock_identity"
OUT_DIR = REPO_ROOT / "vectors" / "stage2_identity_block"


def write_hex(path: Path, data: bytes, width: int) -> None:
    assert len(data) % width == 0, f"{path}: {len(data)} bytes not a multiple of width {width}"
    lines = []
    for i in range(0, len(data), width):
        # little-endian words, matching axis_send's int.from_bytes(beat, "little") convention
        # used throughout the cocotb harness and axi_lite_regs' word-addressed BRAMs.
        value = int.from_bytes(data[i:i + width], "little", signed=False)
        lines.append(f"{value:0{width * 2}x}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> None:
    if not SRC_DIR.exists():
        print(f"ERROR: {SRC_DIR} not found; run "
              f"firmware-verification/scripts/generate_stage2_vectors.py first", file=sys.stderr)
        sys.exit(1)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    conv1_cfg = json.loads((SRC_DIR / "conv1" / "config.json").read_text())
    conv2_cfg = json.loads((SRC_DIR / "conv2" / "config.json").read_text())
    residual_cfg = json.loads((SRC_DIR / "residual" / "residual_config.json").read_text())

    write_hex(OUT_DIR / "conv1_input.hex", (SRC_DIR / "conv1" / "input.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "conv1_weight.hex", (SRC_DIR / "conv1" / "weight.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "conv1_bias.hex", (SRC_DIR / "conv1" / "bias.bin").read_bytes(), 4)
    write_hex(OUT_DIR / "conv1_expected.hex", (SRC_DIR / "conv1" / "expected_output.bin").read_bytes(), 1)

    write_hex(OUT_DIR / "conv2_weight.hex", (SRC_DIR / "conv2" / "weight.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "conv2_bias.hex", (SRC_DIR / "conv2" / "bias.bin").read_bytes(), 4)
    write_hex(OUT_DIR / "conv2_expected.hex", (SRC_DIR / "conv2" / "expected_output.bin").read_bytes(), 1)

    write_hex(OUT_DIR / "shortcut.hex", (SRC_DIR / "residual" / "shortcut_rescaled.bin").read_bytes(), 1)
    write_hex(OUT_DIR / "final_expected.hex", (SRC_DIR / "residual" / "final_expected_output.bin").read_bytes(), 1)

    manifest = {
        "source": str(SRC_DIR),
        "conv1": conv1_cfg,
        "conv2": conv2_cfg,
        "residual": residual_cfg,
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"stage-2 identity block .hex vectors written to {OUT_DIR}")


if __name__ == "__main__":
    main()
