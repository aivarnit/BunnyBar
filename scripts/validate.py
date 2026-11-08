#!/usr/bin/env python3
"""Static validation for the BunnyBar addon.

Checks (no game client required):
  * TOC metadata, interface number, and that every listed file exists with
    exactly matching case
  * no stray Lua files that the TOC doesn't load
  * Lua syntax (LuaJIT or Lua 5.1 preferred, since WoW embeds Lua 5.1)
  * Lua 5.1 compatibility (no goto, //, bitwise operators, <const>, ...)
  * no forbidden APIs or debug prints in addon code
  * every texture referenced from Lua exists; TGA format, dimensions and size
  * committed sprites match scripts/generate_sprites.py output
  * the offline Lua test-suite (tests/lua/run_tests.lua)

Usage:
  python3 scripts/validate.py            # run everything
  python3 scripts/validate.py --no-lua   # skip checks that need a Lua binary

Exit status is non-zero if any check fails.
"""
from __future__ import annotations

import argparse
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON_NAME = "BunnyBar"
ADDON_DIR = ROOT / "addon" / ADDON_NAME
EXPECTED_INTERFACE = "16001"  # WoW Forever (client 1.60.x)
FRAME = 32
MAX_TEXTURE_BYTES = 80 * 1024


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    passed: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    def check(self, ok: bool, name: str, detail: str = "") -> bool:
        if ok:
            self.passed.append(name)
        else:
            self.errors.append(f"{name}: {detail}" if detail else name)
        return ok


# ---------------------------------------------------------------------------
# TOC
# ---------------------------------------------------------------------------

def parse_toc(path: Path):
    meta, files = {}, []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("##"):
            key, _, value = line[2:].partition(":")
            meta[key.strip()] = value.strip()
        elif line.startswith("#"):
            continue
        else:
            files.append(line)
    return meta, files


def exists_exact_case(base: Path, rel: str) -> bool:
    """True if `rel` exists under `base` with exactly this spelling. macOS and
    Windows are case-insensitive, but mismatches still break on other setups
    and in packaging, so be strict."""
    current = base
    for part in re.split(r"[\\/]", rel):
        if not current.is_dir() or part not in {p.name for p in current.iterdir()}:
            return False
        current = current / part
    return current.exists()


def check_toc(r: Report, addon_dir: Path = ADDON_DIR):
    toc = addon_dir / f"{addon_dir.name}.toc"
    if not r.check(toc.exists(), "toc: file exists", str(toc)):
        return {}, []
    meta, files = parse_toc(toc)
    interface = meta.get("Interface", "")
    r.check(bool(re.fullmatch(r"\d+(\s*,\s*\d+)*", interface)), "toc: Interface is numeric", interface)
    r.check(EXPECTED_INTERFACE in [v.strip() for v in interface.split(",")],
            f"toc: Interface includes {EXPECTED_INTERFACE}", interface)
    r.check(bool(meta.get("Title")), "toc: Title present")
    r.check(bool(re.fullmatch(r"\d+\.\d+\.\d+", meta.get("Version", ""))),
            "toc: Version is semver", meta.get("Version", ""))
    r.check(meta.get("SavedVariables") == "BunnyBarDB", "toc: SavedVariables is BunnyBarDB",
            meta.get("SavedVariables", ""))
    r.check(len(files) > 0, "toc: lists files")
    for f in files:
        r.check(exists_exact_case(addon_dir, f), f"toc: listed file exists ({f})",
                "missing or wrong case")
    lua_on_disk = sorted(p.name for p in addon_dir.glob("*.lua"))
    unlisted = [f for f in lua_on_disk if f not in files]
    r.check(not unlisted, "toc: no unlisted Lua files", ", ".join(unlisted))
    icon = meta.get("IconTexture")
    if icon:
        prefix = f"Interface\\AddOns\\{addon_dir.name}\\"
        ok = icon.startswith(prefix) and exists_exact_case(addon_dir, icon[len(prefix):])
        r.check(ok, "toc: IconTexture exists", icon)
    return meta, files


# ---------------------------------------------------------------------------
# Lua source checks
# ---------------------------------------------------------------------------

_LONG_BRACKET = re.compile(r"\[(=*)\[")


def strip_lua(src: str) -> str:
    """Replace comments and string literals with spaces (keeping newlines), so
    token checks don't trip over text such as '|cff' colour codes."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = _LONG_BRACKET.match(src, i + 2)
            if m:
                end = src.find("]" + m.group(1) + "]", m.end())
                end = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end
            out.append(re.sub(r"[^\n]", " ", src[i:end]))
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(" " * (j + 1 - i))
            i = j + 1
        elif c == "[" and _LONG_BRACKET.match(src, i):
            m = _LONG_BRACKET.match(src, i)
            end = src.find("]" + m.group(1) + "]", m.end())
            end = n if end < 0 else end + len(m.group(1)) + 2
            out.append(re.sub(r"[^\n]", " ", src[i:end]))
            i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)


LUA51_FORBIDDEN = [
    (re.compile(r"\bgoto\b"), "goto (Lua 5.2+)"),
    (re.compile(r"::\w+::"), "labels (Lua 5.2+)"),
    (re.compile(r"//"), "integer division // (Lua 5.3+)"),
    (re.compile(r"<<|>>"), "bit shift (Lua 5.3+)"),
    (re.compile(r"(?<![~<>=])&(?!&)"), "bitwise & (Lua 5.3+)"),
    (re.compile(r"(?<!\|)\|(?!\|)"), "bitwise | (Lua 5.3+)"),
    (re.compile(r"~(?!=)"), "bitwise ~ (Lua 5.3+)"),
    (re.compile(r"<\s*(const|close)\s*>"), "attribs <const>/<close> (Lua 5.4+)"),
    (re.compile(r"\b_ENV\b"), "_ENV (Lua 5.2+)"),
]

FORBIDDEN_API = [
    (re.compile(r"(?<![\w.:])print\s*\("), "print() - use ns.Print"),
    (re.compile(r"\b(io|os|debug)\s*\."), "io/os/debug library (not available in WoW)"),
    (re.compile(r"\b(require|dofile|loadfile|loadstring)\s*\("), "module loading (not available in WoW)"),
    (re.compile(r"\bhooksecurefunc\b"), "hooksecurefunc (not needed for a decorative frame)"),
    (re.compile(r"\bCOMBAT_LOG_EVENT"), "combat log events (restricted on Forever)"),
    (re.compile(r"\b(SecureHandler|SecureActionButton)"), "secure templates (not needed)"),
    (re.compile(r"\bRegisterAllEvents\b"), "RegisterAllEvents (polls unrelated game state)"),
]


def check_lua_sources(r: Report, files, addon_dir: Path = ADDON_DIR):
    for name in files:
        path = addon_dir / name
        if not name.endswith(".lua") or not path.exists():
            continue
        src = path.read_text(encoding="utf-8")
        code = strip_lua(src)
        lines = code.splitlines()
        for rx, what in LUA51_FORBIDDEN + FORBIDDEN_API:
            hits = [i + 1 for i, line in enumerate(lines) if rx.search(line)]
            r.check(not hits, f"lua: {name} has no {what}",
                    f"lines {hits[:5]}")
        r.check(src.lstrip().startswith("--") or "= ..." in src.splitlines()[0],
                f"lua: {name} has a header")
        r.check(re.search(r"^local\s+[\w_, ]+=\s*\.\.\.", src, re.M) is not None,
                f"lua: {name} receives (addonName, ns) varargs")
        r.check("\t" not in src, f"lua: {name} uses spaces for indentation")


def find_lua_51():
    for exe in ("luajit", "lua5.1", "lua51"):
        path = shutil.which(exe)
        if path:
            return path
    return None


def check_lua_syntax(r: Report, files, addon_dir: Path = ADDON_DIR):
    exe = find_lua_51()
    if not exe:
        r.skipped.append("lua: syntax check (no luajit/lua5.1 found)")
        return
    for name in files:
        path = addon_dir / name
        if not name.endswith(".lua") or not path.exists():
            continue
        proc = subprocess.run(
            [exe, "-e", f"assert(loadfile({str(path)!r}))"],
            capture_output=True, text=True)
        r.check(proc.returncode == 0, f"lua: {name} parses as Lua 5.1",
                (proc.stderr or proc.stdout).strip())


def run_lua_tests(r: Report):
    exe = find_lua_51()
    if not exe:
        r.skipped.append("lua: offline test-suite (no luajit/lua5.1 found)")
        return
    proc = subprocess.run([exe, str(ROOT / "tests" / "lua" / "run_tests.lua")],
                          capture_output=True, text=True, cwd=ROOT)
    summary = (proc.stdout.strip().splitlines() or ["(no output)"])
    tail = next((l for l in reversed(summary) if "passed" in l), summary[-1])
    if proc.returncode != 0:
        print(proc.stdout)
        print(proc.stderr, file=sys.stderr)
    r.check(proc.returncode == 0, f"lua: offline test-suite ({tail.strip()})",
            "see output above")


# ---------------------------------------------------------------------------
# Textures
# ---------------------------------------------------------------------------

def read_tga(path: Path):
    """Return (width, height, bpp, alpha_bits, top_left, pixels) for an
    uncompressed true-colour TGA. pixels is a list of rows of (r,g,b,a)."""
    data = path.read_bytes()
    if len(data) < 18:
        raise ValueError("file too small")
    (id_len, cmap_type, img_type, _, _, _, _, _, w, h, bpp, desc) = struct.unpack(
        "<BBBHHBHHHHBB", data[:18])
    if img_type != 2 or cmap_type != 0:
        raise ValueError(f"unsupported TGA type {img_type}")
    if bpp != 32:
        raise ValueError(f"expected 32 bpp, got {bpp}")
    off = 18 + id_len
    expected = off + w * h * 4
    if len(data) < expected:
        raise ValueError("truncated pixel data")
    rows = []
    for y in range(h):
        row = []
        base = off + y * w * 4
        for x in range(w):
            b, g, rr, a = data[base + x * 4: base + x * 4 + 4]
            row.append((rr, g, b, a))
        rows.append(row)
    top_left = bool(desc & 0x20)
    if not top_left:
        rows.reverse()
    return w, h, bpp, desc & 0x0F, top_left, rows


def is_pow2(n: int) -> bool:
    return n > 0 and n & (n - 1) == 0


def texture_references(addon_dir: Path = ADDON_DIR):
    """Map texture file name -> (frame count, slot count, frame height) from
    every Lua file, using declarations like
        { file = "bunny-idle.tga", count = 4, slots = 4 }
        { file = "bunny-ears.tga", count = 1, slots = 1, height = 16 }
    `slots` is the strip width in frames (unused slots are padding); every
    texture holds two stacked layers (fur, detail), so it is 2*height tall."""
    refs = {}
    pattern = re.compile(r'"([\w-]+\.tga)"\s*,\s*count\s*=\s*(\d+)'
                         r'(?:\s*,\s*slots\s*=\s*(\d+))?(?:\s*,\s*height\s*=\s*(\d+))?')
    for lua in sorted(addon_dir.glob("*.lua")):
        for m in pattern.finditer(lua.read_text(encoding="utf-8")):
            count = int(m.group(2))
            refs[m.group(1)] = (count, int(m.group(3) or count), int(m.group(4) or FRAME))
    return refs


# Default fur tint (the original fur tone): fur layer x tint = original art.
DEFAULT_FUR = (0xF6, 0xF3, 0xFA)


def composite(fur, detail):
    """What the client draws with the default colour: detail over tinted fur."""
    if detail[3]:
        return detail
    if fur[3]:
        return tuple(round(fur[i] * DEFAULT_FUR[i] / 255) for i in range(3)) + (fur[3],)
    return (0, 0, 0, 0)


def check_textures(r: Report, addon_dir: Path = ADDON_DIR):
    refs = texture_references(addon_dir)
    r.check(len(refs) >= 4, "textures: Lua declares sprite sheets", str(refs))
    tex_dir = addon_dir / "Textures"
    for name, (count, slots, fh) in sorted(refs.items()):
        path = tex_dir / name
        if not r.check(exists_exact_case(tex_dir, name) if tex_dir.exists() else False,
                       f"textures: {name} exists"):
            continue
        try:
            w, h, bpp, alpha, top_left, rows = read_tga(path)
        except ValueError as exc:
            r.check(False, f"textures: {name} is a valid TGA", str(exc))
            continue
        r.check(alpha == 8, f"textures: {name} has 8-bit alpha", str(alpha))
        r.check(is_pow2(w) and is_pow2(h), f"textures: {name} has power-of-two size", f"{w}x{h}")
        r.check(slots >= count, f"textures: {name} declares slots >= count", f"{count}/{slots}")
        r.check(h == 2 * fh and w == FRAME * slots,
                f"textures: {name} is {slots} slot(s) of {FRAME}x{fh}, two layers", f"{w}x{h}")
        if w != FRAME * slots or h != 2 * fh:
            continue
        r.check(path.stat().st_size <= MAX_TEXTURE_BYTES, f"textures: {name} is small",
                f"{path.stat().st_size} bytes")
        fur_rows, detail_rows = rows[:fh], rows[fh:]
        overlap = sum(1 for y in range(fh) for x in range(w)
                      if fur_rows[y][x][3] and detail_rows[y][x][3])
        r.check(overlap == 0, f"textures: {name} fur and detail layers don't overlap",
                f"{overlap} px in both")
        fur_px = [p for row in fur_rows for p in row if p[3]]
        r.check(fur_px and all(min(p[:3]) >= 150 and p[3] == 255 for p in fur_px),
                f"textures: {name} fur layer is light, opaque and tintable")
        comp = [[composite(fur_rows[y][x], detail_rows[y][x]) for x in range(w)] for y in range(fh)]
        area = FRAME * fh
        for i in range(count):
            px = [comp[y][x] for y in range(fh) for x in range(i * FRAME, (i + 1) * FRAME)]
            opaque = sum(1 for p in px if p[3] > 0)
            corners = [comp[0][i * FRAME], comp[0][(i + 1) * FRAME - 1]]
            r.check(80 < opaque < area * 0.7,
                    f"textures: {name} frame {i + 1} has a sprite", f"{opaque} opaque px")
            r.check(all(c[3] == 0 for c in corners),
                    f"textures: {name} frame {i + 1} has a transparent background")
        for i in range(count, slots):
            pad = [rows[y][x] for y in range(h) for x in range(i * FRAME, (i + 1) * FRAME)]
            r.check(all(p[3] == 0 for p in pad), f"textures: {name} padding slot {i + 1} is empty")
        whites = sum(1 for row in comp for p in row if p[3] and min(p[:3]) > 230)
        pinks = sum(1 for row in detail_rows for p in row
                    if p[3] and p[0] > 220 and p[1] < 200 and p[2] > 140)
        r.check(whites > 0 and pinks > 0, f"textures: {name} has white fur and pink details")
    # The TOC icon is a single-layer 32x32 image (the AddOns list shows the
    # whole file, so it must not be a stacked two-layer sheet).
    icon_name = None
    toc = addon_dir / f"{addon_dir.name}.toc"
    if toc.exists():
        icon = parse_toc(toc)[0].get("IconTexture", "")
        icon_name = re.split(r"[\\/]", icon)[-1] if icon else None
    if icon_name and (tex_dir / icon_name).exists():
        try:
            w, h, *_ = read_tga(tex_dir / icon_name)
            r.check((w, h) == (FRAME, FRAME), f"textures: {icon_name} icon is {FRAME}x{FRAME}", f"{w}x{h}")
        except ValueError as exc:
            r.check(False, f"textures: {icon_name} icon is a valid TGA", str(exc))
    # No unreferenced textures shipped (keeps the package lean).
    if tex_dir.exists():
        extra = sorted(p.name for p in tex_dir.iterdir()
                       if p.name not in refs and p.name != icon_name and not p.name.startswith("."))
        r.check(not extra, "textures: no unreferenced files", ", ".join(extra))


def check_sprites_up_to_date(r: Report):
    proc = subprocess.run([sys.executable, str(ROOT / "scripts" / "generate_sprites.py"), "--check"],
                          capture_output=True, text=True)
    r.check(proc.returncode == 0, "textures: committed sprites match generator",
            proc.stdout.strip())


# ---------------------------------------------------------------------------

def run(no_lua: bool = False) -> Report:
    r = Report()
    meta, files = check_toc(r)
    check_lua_sources(r, files)
    check_textures(r)
    check_sprites_up_to_date(r)
    if no_lua:
        r.skipped.append("lua: syntax + offline tests (--no-lua)")
    else:
        check_lua_syntax(r, files)
        run_lua_tests(r)
    return r


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Static validation for BunnyBar")
    ap.add_argument("--no-lua", action="store_true", help="skip checks that need a Lua interpreter")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every passed check")
    args = ap.parse_args(argv)

    r = run(no_lua=args.no_lua)
    if args.verbose:
        for p in r.passed:
            print(f"  PASS {p}")
    for s in r.skipped:
        print(f"  SKIP {s}")
    for e in r.errors:
        print(f"  FAIL {e}")
    print(f"\n{len(r.passed)} passed, {len(r.errors)} failed, {len(r.skipped)} skipped")
    print("Note: these are static/offline checks. In-game behaviour must be verified in WoW Forever.")
    return 1 if r.errors else 0


if __name__ == "__main__":
    sys.exit(main())
