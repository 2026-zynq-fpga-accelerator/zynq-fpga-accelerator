#!/usr/bin/env python3
# Computes a {"sha256": {file: hash, ...}} provenance manifest for a stage-2 vector directory, in
# the same format generate_stage2_c_header.py's --approved-manifest expects (mirrors
# firmware/test/stage1_vector_manifest.json's role for stage-1).
#
# Unlike stage1_vector_manifest.json -- which recorded an RTL-canonical vector RTL had already
# confirmed byte-identical to his own regression run -- this script only hashes whatever is
# currently on disk from scripts/generate_stage2_vectors.py (a local Python golden-model run).
# It does NOT claim RTL-canonical status
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VARIANTS = ("identity", "projection")

# Relative to the variant's vector dir; shortcut/* only applies to "projection",
# residual/shortcut_rescaled.bin only applies to "identity".
COMMON_FILES = [
    "conv1/config.json", "conv1/weight.bin", "conv1/bias.bin", "conv1/input.bin",
    "conv1/expected_output.bin",
    "conv2/config.json", "conv2/weight.bin", "conv2/bias.bin", "conv2/expected_output.bin",
    "residual/residual_config.json", "residual/final_expected_output.bin",
]
PROJECTION_ONLY_FILES = [
    "shortcut/config.json", "shortcut/weight.bin", "shortcut/bias.bin",
    "shortcut/expected_output.bin",
]
IDENTITY_ONLY_FILES = ["residual/shortcut_rescaled.bin"]


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=VARIANTS, default="identity")
    parser.add_argument("--vector-root", type=Path, default=REPO_ROOT / "data" / "test_vectors")
    parser.add_argument("--seed", type=int, default=0, help="seed generate_stage2_vectors.py was run with")
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    variant = args.variant
    vector_dir = args.vector_root / f"stage2_basicblock_{variant}"
    output = args.output or (vector_dir / "manifest.json")

    files = list(COMMON_FILES)
    files += PROJECTION_ONLY_FILES if variant == "projection" else IDENTITY_ONLY_FILES

    sha256_map = {}
    for rel_path in files:
        data = (vector_dir / rel_path).read_bytes()
        sha256_map[rel_path] = sha256_hex(data)

    manifest = {
        "candidate": "Python golden model (local, generate_stage2_vectors.py)",
        "provenance_status": (
            "DRAFT -- not yet confirmed against an RTL-canonical vector"
            "Send this file to him for confirmation once OP_RESIDUAL_ADD RTL/simulation exists to "
            "compare against, then re-save as the --approved-manifest input to "
            "generate_stage2_c_header.py."
        ),
        "variant": variant,
        "seed": args.seed,
        "sha256": sha256_map,
    }

    output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
