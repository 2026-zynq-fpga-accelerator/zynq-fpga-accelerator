#!/usr/bin/env python3
"""Assemble a Stage-3 9-block backbone (stem + 9x BasicBlock + GAP + FC, 32-operation chain)
release directory (rtl/build/releases/<git-hash>_backbone/) from the artifacts and Vivado
reports already produced by generate_bitstream_xsa.tcl,
report_shipped_bitstream_utilization.tcl, and build_stage3_backbone_boot_image.tcl, then zip it
-- same build/releases/<...>/ + SHA256SUMS.txt + zip pattern as the other package_stageN
scripts.

No RTL changed for this round (same bitstream/XSA as the GAP/FC release), so the git hash is
identical to that release's; the release directory is suffixed "_backbone" to avoid colliding
with rtl/build/releases/<hash>/ from package_stage3_gapfc_release.py.

Timing/resource reports are pulled from the pre_bitstream_* files (generate_bitstream_xsa.tcl /
report_shipped_bitstream_utilization.tcl), which reflect the actual run used to produce the
shipped bitstream (impl_performance_postroute_physopt) -- NOT build_zybo_implementation.tcl's
post_route_*.rpt, which reports the default impl_1 run and shows materially different numbers.

Run with: python3 scripts/release/package_stage3_backbone_release.py
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_DIR = REPO_ROOT / "build" / "vivado_zybo" / "artifacts"
REPORT_DIR = REPO_ROOT / "build" / "vivado_zybo" / "reports"
BOOT_DIR = REPO_ROOT / "build" / "vitis_stage3_backbone" / "boot"


def git_short_hash() -> str:
    return subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "--short=7", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> None:
    git_hash = git_short_hash()
    release_dir = REPO_ROOT / "build" / "releases" / f"{git_hash}_backbone"
    if release_dir.exists():
        raise SystemExit(f"refusing to overwrite existing release directory: {release_dir}")
    release_dir.mkdir(parents=True)

    # (source path, destination filename) -- BOOT.BIN keeps its fixed bootloader-recognized
    # name; everything else is suffixed with the git hash, matching the Stage-1/2/3 convention.
    copy_plan = [
        (BOOT_DIR / "BOOT.BIN", "BOOT.BIN"),
        (BOOT_DIR / "stage3_backbone.bif", f"boot_image_{git_hash}.bif"),
        (ARTIFACT_DIR / "zybo_resnet_system.bit", f"zybo_resnet_system_{git_hash}.bit"),
        (ARTIFACT_DIR / "zybo_resnet_system.xsa", f"zybo_resnet_system_{git_hash}.xsa"),
        (REPORT_DIR / "pre_bitstream_timing_summary.rpt", f"TIMING_SUMMARY_{git_hash}.rpt"),
        (REPORT_DIR / "pre_bitstream_utilization.rpt", f"RESOURCE_UTILIZATION_{git_hash}.rpt"),
        (REPORT_DIR / "pre_bitstream_utilization_hierarchical.rpt",
         f"RESOURCE_UTILIZATION_HIERARCHICAL_{git_hash}.rpt"),
        (REPORT_DIR / "pre_bitstream_drc.rpt", f"DRC_{git_hash}.rpt"),
        (REPORT_DIR / "bitstream_xsa_manifest.txt", f"BUILD_MANIFEST_{git_hash}.txt"),
    ]

    members: list[str] = []
    for source, dest_name in copy_plan:
        if not source.is_file() or source.stat().st_size == 0:
            raise SystemExit(f"missing or empty release input: {source}")
        shutil.copy2(source, release_dir / dest_name)
        members.append(dest_name)

    sha_path = release_dir / "SHA256SUMS.txt"
    with sha_path.open("w") as sha_file:
        for member in sorted(members):
            sha_file.write(f"{sha256_file(release_dir / member)}  {member}\n")
    members.append("SHA256SUMS.txt")
    members.sort()

    archive = release_dir / f"zybo_stage3_backbone_{git_hash}_release.zip"
    if archive.exists():
        raise SystemExit(f"refusing to overwrite existing archive: {archive}")
    with ZipFile(archive, "x", compression=ZIP_DEFLATED, compresslevel=9) as output:
        for member in members:
            output.write(release_dir / member, arcname=member)

    with ZipFile(archive, "r") as check:
        if sorted(check.namelist()) != members:
            raise SystemExit("archive member list mismatch")
        bad = check.testzip()
        if bad is not None:
            raise SystemExit(f"archive CRC failure: {bad}")

    print(f"RELEASE_DIR={release_dir}")
    print(f"RELEASE_ZIP_PASS path={archive} members={len(members)}")


if __name__ == "__main__":
    sys.exit(main())
