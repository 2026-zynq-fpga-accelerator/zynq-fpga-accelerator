#!/usr/bin/env python3
# Converts data/test_vectors/stage2_basicblock_{identity,projection}/{conv1,conv2,shortcut,
# residual}/* into a C header of static byte arrays, mirroring generate_stage1_c_header.py (bare-
# metal firmware has no filesystem to load the .bin files from).
# Regenerate whenever scripts/generate_stage2_vectors.py produces new test vectors.
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

VARIANTS = ("identity", "projection")


def format_byte_array(name: str, data: bytes, values_per_line: int = 20) -> str:
    lines = [f"static const uint8_t {name}[{len(data)}] __attribute__((aligned(32))) = {{"]
    for i in range(0, len(data), values_per_line):
        chunk = data[i : i + values_per_line]
        lines.append("    " + ", ".join(f"0x{b:02X}" for b in chunk) + ",")
    lines.append("};")
    return "\n".join(lines)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_manifest(manifest_path: Path, payloads: dict[str, bytes]) -> None:
    """Rejects generation if any binary differs from the jointly approved hashes recorded for the
    selected vector candidate (same joint-decision-gate pattern as generate_stage1_c_header.py)."""
    manifest = json.loads(manifest_path.read_text())
    approved = manifest["sha256"]
    for name, data in payloads.items():
        expected = approved.get(name)
        if expected is None:
            raise ValueError(f"approved manifest has no sha256 entry for {name!r}")
        actual = sha256_hex(data)
        if actual != expected:
            raise ValueError(f"SHA-256 mismatch for {name}: expected {expected}, got {actual}")


def _load_conv(conv_dir: Path) -> dict:
    config = json.loads((conv_dir / "config.json").read_text())
    weight = (conv_dir / "weight.bin").read_bytes()
    bias = (conv_dir / "bias.bin").read_bytes()
    expected_output = (conv_dir / "expected_output.bin").read_bytes()
    assert len(weight) == config["weight_bytes"]
    assert len(bias) == config["bias_bytes"]
    assert len(expected_output) == config["output_bytes"]
    return {"config": config, "weight": weight, "bias": bias, "expected_output": expected_output}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=VARIANTS, default="identity")
    parser.add_argument("--vector-root", type=Path, default=REPO_ROOT / "data" / "test_vectors")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument(
        "--approved-manifest", type=Path, default=None,
        help=(
            "path to a jointly-approved {\"sha256\": {file: hash, ...}} manifest for this "
            "variant's vector dir; if omitted, no provenance check is performed (development-only "
            "default, not for hardware bring-up -- see generate_stage1_c_header.py for precedent)"
        ),
    )
    args = parser.parse_args()

    variant = args.variant
    vector_dir = args.vector_root / f"stage2_basicblock_{variant}"
    output = args.output or (
        REPO_ROOT / "firmware" / "test" / "generated" / f"stage2_{variant}_test_vector.h"
    )

    conv1 = _load_conv(vector_dir / "conv1")
    conv2 = _load_conv(vector_dir / "conv2")
    input_x = (vector_dir / "conv1" / "input.bin").read_bytes()
    assert len(input_x) == conv1["config"]["input_bytes"]

    # conv2's own input.bin is byte-identical to conv1's expected_output (chained golden output);
    # not embedded separately since real firmware feeds conv2 from conv1's actual HW output buffer.
    conv2_input_check = (vector_dir / "conv2" / "input.bin").read_bytes()
    if conv2_input_check != conv1["expected_output"]:
        raise ValueError(
            "conv2/input.bin does not match conv1/expected_output.bin -- vectors are stale, "
            "regenerate with scripts/generate_stage2_vectors.py"
        )

    residual_config = json.loads((vector_dir / "residual" / "residual_config.json").read_text())
    final_expected_output = (vector_dir / "residual" / "final_expected_output.bin").read_bytes()

    payloads = {
        "conv1/weight.bin": conv1["weight"], "conv1/bias.bin": conv1["bias"],
        "conv1/input.bin": input_x, "conv1/expected_output.bin": conv1["expected_output"],
        "conv2/weight.bin": conv2["weight"], "conv2/bias.bin": conv2["bias"],
        "conv2/expected_output.bin": conv2["expected_output"],
        "residual/final_expected_output.bin": final_expected_output,
    }

    if variant == "projection":
        shortcut = _load_conv(vector_dir / "shortcut")
        payloads["shortcut/weight.bin"] = shortcut["weight"]
        payloads["shortcut/bias.bin"] = shortcut["bias"]
        payloads["shortcut/expected_output.bin"] = shortcut["expected_output"]
        shortcut_rescaled = None
    else:
        shortcut = None
        shortcut_rescaled = (vector_dir / "residual" / "shortcut_rescaled.bin").read_bytes()
        payloads["residual/shortcut_rescaled.bin"] = shortcut_rescaled

    if args.approved_manifest is not None:
        verify_manifest(args.approved_manifest, payloads)
    else:
        print(
            "warning: no --approved-manifest given, skipping provenance verification "
            "(fine for local iteration, required before the first hardware bring-up run)",
            file=sys.stderr,
        )

    output.parent.mkdir(parents=True, exist_ok=True)
    prefix = f"STAGE2_{variant.upper()}"
    c1, c2 = conv1["config"], conv2["config"]

    sections = [f"""/* Generated by scripts/generate_stage2_c_header.py from
 * {vector_dir.relative_to(REPO_ROOT)} -- do not edit by hand.
 *
 * Stage-2 Basic Residual Block ({variant} shortcut) test vector, embedded as byte arrays because
 * bare-metal firmware has no filesystem to load the .bin files from. Mirrors
 * STAGE2_BASIC_RESIDUAL_BLOCK_PLAN.md's recommended structure: conv1 (ReLU ON) -> conv2 (ReLU
 * OFF) -> {"projection shortcut conv" if variant == "projection" else "identity shortcut (rescaled onto conv2's output scale)"} -> residual add -> final ReLU.
 * conv2's real runtime input is conv1's own accelerator output (not embedded here -- see
 * conv1_expected_output, used only for the Checkpoint-1 golden compare).
 */
#ifndef STAGE2_{variant.upper()}_TEST_VECTOR_H
#define STAGE2_{variant.upper()}_TEST_VECTOR_H

#include <stdint.h>

#define {prefix}_INPUT_HEIGHT   {c1["input_height"]}
#define {prefix}_INPUT_WIDTH    {c1["input_width"]}
#define {prefix}_IN_CHANNELS    {c1["in_channels"]}

#define {prefix}_CONV1_OUT_CHANNELS  {c1["out_channels"]}
#define {prefix}_CONV1_KERNEL_SIZE   {c1["kernel_size"]}
#define {prefix}_CONV1_STRIDE        {c1["stride"]}
#define {prefix}_CONV1_PADDING       {c1["padding"]}
#define {prefix}_CONV1_RELU_ENABLE   {1 if c1["relu_enable"] else 0}
#define {prefix}_CONV1_MULTIPLIER_M  {c1["multiplier_m"]}
#define {prefix}_CONV1_SHIFT_N       {c1["shift_n"]}
#define {prefix}_CONV1_WEIGHT_BYTES  {c1["weight_bytes"]}
#define {prefix}_CONV1_BIAS_BYTES    {c1["bias_bytes"]}
#define {prefix}_CONV1_OUTPUT_BYTES  {c1["output_bytes"]}

#define {prefix}_CONV2_OUT_CHANNELS  {c2["out_channels"]}
#define {prefix}_CONV2_KERNEL_SIZE   {c2["kernel_size"]}
#define {prefix}_CONV2_STRIDE        {c2["stride"]}
#define {prefix}_CONV2_PADDING       {c2["padding"]}
#define {prefix}_CONV2_RELU_ENABLE   {1 if c2["relu_enable"] else 0}
#define {prefix}_CONV2_MULTIPLIER_M  {c2["multiplier_m"]}
#define {prefix}_CONV2_SHIFT_N       {c2["shift_n"]}
#define {prefix}_CONV2_WEIGHT_BYTES  {c2["weight_bytes"]}
#define {prefix}_CONV2_BIAS_BYTES    {c2["bias_bytes"]}
#define {prefix}_CONV2_OUTPUT_BYTES  {c2["output_bytes"]}

#define {prefix}_RESIDUAL_SCALE {residual_config["residual_scale"]!r} /* Conv2 output scale == shared MAIN/SKIP scale (§4.4 권장안 A) */

{format_byte_array(f"{prefix.lower()}_input_x", input_x)}

{format_byte_array(f"{prefix.lower()}_conv1_weight", conv1["weight"])}

{format_byte_array(f"{prefix.lower()}_conv1_bias", conv1["bias"])}

{format_byte_array(f"{prefix.lower()}_conv1_expected_output", conv1["expected_output"])}

{format_byte_array(f"{prefix.lower()}_conv2_weight", conv2["weight"])}

{format_byte_array(f"{prefix.lower()}_conv2_bias", conv2["bias"])}

{format_byte_array(f"{prefix.lower()}_conv2_expected_output", conv2["expected_output"])}
"""]

    if variant == "projection":
        sc = shortcut["config"]
        sections.append(f"""
#define {prefix}_SHORTCUT_OUT_CHANNELS  {sc["out_channels"]}
#define {prefix}_SHORTCUT_KERNEL_SIZE   {sc["kernel_size"]}
#define {prefix}_SHORTCUT_STRIDE        {sc["stride"]}
#define {prefix}_SHORTCUT_PADDING       {sc["padding"]}
#define {prefix}_SHORTCUT_MULTIPLIER_M  {sc["multiplier_m"]}
#define {prefix}_SHORTCUT_SHIFT_N       {sc["shift_n"]}
#define {prefix}_SHORTCUT_WEIGHT_BYTES  {sc["weight_bytes"]}
#define {prefix}_SHORTCUT_BIAS_BYTES    {sc["bias_bytes"]}
#define {prefix}_SHORTCUT_OUTPUT_BYTES  {sc["output_bytes"]}

{format_byte_array(f"{prefix.lower()}_shortcut_weight", shortcut["weight"])}

{format_byte_array(f"{prefix.lower()}_shortcut_bias", shortcut["bias"])}

{format_byte_array(f"{prefix.lower()}_shortcut_expected_output", shortcut["expected_output"])}
""")
    else:
        sections.append(f"""
/* Identity shortcut: no conv, just the block input rescaled onto CONV2's output scale (§4.4/4.5).
 * How that rescale is actually produced at runtime (firmware software passthrough vs. RTL) is not
 * yet decided -- this is the golden checkpoint value only. */
{format_byte_array(f"{prefix.lower()}_shortcut_rescaled", shortcut_rescaled)}
""")

    sections.append(f"""
{format_byte_array(f"{prefix.lower()}_final_expected_output", final_expected_output)}

#endif /* STAGE2_{variant.upper()}_TEST_VECTOR_H */
""")

    body = "\n".join(sections)
    output.write_text(body)
    print(f"wrote {output} ({len(body)} bytes)")


if __name__ == "__main__":
    main()
