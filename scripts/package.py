#!/usr/bin/env python3
"""Build and verify the distributable BunnyBar ZIP.

The archive has `BunnyBar/` as its only top-level folder, so users can extract
it straight into their `Interface/AddOns` directory.

Usage:
  python3 scripts/package.py                    # build dist/BunnyBar-<version>.zip
  python3 scripts/package.py --tag v0.1.0       # also require tag == TOC version
  python3 scripts/package.py --verify FILE.zip  # verify an existing archive

The build is reproducible: entries are sorted and carry a fixed timestamp.
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import ADDON_DIR, ADDON_NAME, ROOT, parse_toc, texture_references  # noqa: E402

DIST = ROOT / "dist"
FIXED_DATE = (2020, 1, 1, 0, 0, 0)


def toc_meta():
    return parse_toc(ADDON_DIR / f"{ADDON_NAME}.toc")


def expected_entries():
    """Archive paths that must be present (and nothing else)."""
    meta, files = toc_meta()
    entries = {f"{ADDON_NAME}/{ADDON_NAME}.toc"}
    entries |= {f"{ADDON_NAME}/{f.replace(chr(92), '/')}" for f in files}
    entries |= {f"{ADDON_NAME}/Textures/{name}" for name in texture_references()}
    icon = meta.get("IconTexture", "")
    if icon:
        entries.add(f"{ADDON_NAME}/Textures/{icon.replace(chr(92), '/').split('/')[-1]}")
    entries.add(f"{ADDON_NAME}/LICENSE.txt")
    return entries


def source_for(entry: str) -> Path:
    rel = entry[len(ADDON_NAME) + 1:]
    if rel == "LICENSE.txt":
        return ROOT / "LICENSE"
    return ADDON_DIR / rel


def build(out_dir: Path = DIST) -> Path:
    meta, _ = toc_meta()
    version = meta["Version"]
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{ADDON_NAME}-{version}.zip"
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for entry in sorted(expected_entries()):
            src = source_for(entry)
            if not src.exists():
                raise FileNotFoundError(f"{src} (for {entry})")
            info = zipfile.ZipInfo(entry, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, src.read_bytes())
    return out


def verify(path: Path) -> list[str]:
    """Return a list of problems with the archive (empty means OK)."""
    problems = []
    with zipfile.ZipFile(path) as zf:
        bad = zf.testzip()
        if bad:
            problems.append(f"corrupt entry: {bad}")
        names = [n for n in zf.namelist() if not n.endswith("/")]
        roots = {n.split("/", 1)[0] for n in zf.namelist()}
        if roots != {ADDON_NAME}:
            problems.append(f"archive root must be only '{ADDON_NAME}/', found {sorted(roots)}")
        expected = expected_entries()
        missing = sorted(expected - set(names))
        extra = sorted(set(names) - expected)
        if missing:
            problems.append(f"missing: {missing}")
        if extra:
            problems.append(f"unexpected: {extra}")
        for n in names:
            if re.search(r"(^|/)(\.|__MACOSX|Thumbs\.db)", n):
                problems.append(f"junk file: {n}")
        for entry in sorted(expected & set(names)):
            if zf.read(entry) != source_for(entry).read_bytes():
                problems.append(f"content differs from source: {entry}")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Build/verify the BunnyBar ZIP")
    ap.add_argument("--verify", type=Path, help="verify an existing archive instead of building")
    ap.add_argument("--tag", help="git tag (e.g. v0.1.0) that must match the TOC version")
    ap.add_argument("--out", type=Path, default=DIST, help="output directory (default: dist/)")
    args = ap.parse_args(argv)

    meta, _ = toc_meta()
    if args.tag is not None:
        if args.tag.lstrip("v") != meta["Version"]:
            print(f"FAIL: tag {args.tag} does not match TOC version {meta['Version']}")
            return 1
        print(f"OK: tag {args.tag} matches TOC version")

    path = args.verify or build(args.out)
    problems = verify(path)
    for p in problems:
        print(f"FAIL: {p}")
    if problems:
        return 1
    with zipfile.ZipFile(path) as zf:
        for n in zf.namelist():
            print(f"  {n}")
    print(f"OK: {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
