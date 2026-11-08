"""Python unit tests for BunnyBar's build and validation tooling.

Run:  python3 -m unittest discover -s tests -v

Includes negative tests: each validator must actually *catch* the problem it
is meant to catch, not just pass on the good tree.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import functools  # noqa: E402

import generate_sprites  # noqa: E402

# Building every asset (incl. the GIF) takes a few seconds; do it once.
_build = functools.lru_cache(maxsize=None)(generate_sprites.build)
import package  # noqa: E402
import validate  # noqa: E402


class TempAddon:
    """Copy of addon/BunnyBar in a temp dir that tests can break."""

    def __enter__(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.dir = self.tmp / "BunnyBar"
        shutil.copytree(validate.ADDON_DIR, self.dir)
        return self.dir

    def __exit__(self, *exc):
        shutil.rmtree(self.tmp)


def errors_for(fn, addon_dir):
    r = validate.Report()
    if fn is validate.check_lua_sources:
        _, files = validate.parse_toc(addon_dir / "BunnyBar.toc")
        fn(r, files, addon_dir)
    else:
        fn(r, addon_dir)
    return r.errors


class TocTests(unittest.TestCase):
    def test_real_toc_is_valid(self):
        r = validate.Report()
        meta, files = validate.check_toc(r)
        self.assertEqual(r.errors, [])
        self.assertEqual(meta["Interface"], "16001")
        self.assertEqual(files, ["Util.lua", "Config.lua", "Placement.lua", "Animation.lua", "Core.lua"])

    def test_missing_listed_file_is_caught(self):
        with TempAddon() as d:
            (d / "Core.lua").unlink()
            self.assertTrue(any("Core.lua" in e for e in errors_for(validate.check_toc, d)))

    def test_wrong_case_is_caught(self):
        with TempAddon() as d:
            toc = d / "BunnyBar.toc"
            toc.write_text(toc.read_text().replace("Core.lua", "core.lua"))
            self.assertTrue(any("core.lua" in e for e in errors_for(validate.check_toc, d)))

    def test_unlisted_lua_is_caught(self):
        with TempAddon() as d:
            (d / "Extra.lua").write_text("local _, ns = ...\n")
            self.assertTrue(any("unlisted" in e for e in errors_for(validate.check_toc, d)))

    def test_wrong_interface_is_caught(self):
        with TempAddon() as d:
            toc = d / "BunnyBar.toc"
            toc.write_text(toc.read_text().replace("16001", "11507"))
            self.assertTrue(any("16001" in e for e in errors_for(validate.check_toc, d)))


class LuaSourceTests(unittest.TestCase):
    def test_strip_lua_removes_strings_and_comments(self):
        src = 'local a = "x // y | z" -- goto here\nlocal b = [[ & ]] --[[ ~ ]] local c = 1'
        stripped = validate.strip_lua(src)
        self.assertNotIn("//", stripped)
        self.assertNotIn("goto", stripped)
        self.assertNotIn("&", stripped)
        self.assertIn("local c = 1", stripped)
        self.assertEqual(stripped.count("\n"), src.count("\n"))

    def test_lua51_forbidden_syntax_detected(self):
        bad = ["local x = a // b", "goto done", "local y = a & b", "local z = a | b",
               "local w = ~a", "local k <const> = 1", "local s = 1 << 2"]
        for line in bad:
            code = validate.strip_lua(line)
            self.assertTrue(any(rx.search(code) for rx, _ in validate.LUA51_FORBIDDEN), line)

    def test_lua51_ok_syntax_not_flagged(self):
        ok = ['if a ~= b then end', 'local s = "|cffffd200x|r"', "local t = a <= b and a >= c",
              "local n = #list", "local s = a .. b"]
        for line in ok:
            code = validate.strip_lua(line)
            self.assertFalse(any(rx.search(code) for rx, _ in validate.LUA51_FORBIDDEN), line)

    def test_debug_print_is_caught(self):
        with TempAddon() as d:
            core = d / "Core.lua"
            core.write_text(core.read_text() + '\nprint("debug")\n')
            self.assertTrue(any("print" in e for e in errors_for(validate.check_lua_sources, d)))

    def test_real_sources_clean(self):
        self.assertEqual(errors_for(validate.check_lua_sources, validate.ADDON_DIR), [])


class TextureTests(unittest.TestCase):
    def test_real_textures_valid(self):
        self.assertEqual(errors_for(validate.check_textures, validate.ADDON_DIR), [])

    def test_sheet_dimensions(self):
        expected = {"bunny-idle.tga": 128, "bunny-hop.tga": 64, "bunny-land.tga": 32,
                    "bunny-sleepy.tga": 256, "bunny-sleep.tga": 256, "bunny-wake.tga": 128}
        self.assertEqual(set(validate.texture_references()), set(expected))
        for name, width in expected.items():
            w, h, bpp, alpha, top_left, _ = validate.read_tga(validate.ADDON_DIR / "Textures" / name)
            self.assertEqual((w, h, bpp, alpha, top_left), (width, 32, 32, 8, True), name)

    def test_missing_texture_is_caught(self):
        with TempAddon() as d:
            (d / "Textures" / "bunny-hop.tga").unlink()
            self.assertTrue(any("bunny-hop.tga" in e for e in errors_for(validate.check_textures, d)))

    def test_corrupt_texture_is_caught(self):
        with TempAddon() as d:
            (d / "Textures" / "bunny-land.tga").write_bytes(b"not a tga")
            self.assertTrue(any("bunny-land.tga" in e for e in errors_for(validate.check_textures, d)))

    def test_unreferenced_texture_is_caught(self):
        with TempAddon() as d:
            shutil.copy(d / "Textures" / "bunny-land.tga", d / "Textures" / "bunny-extra.tga")
            self.assertTrue(any("unreferenced" in e for e in errors_for(validate.check_textures, d)))

    def test_generator_is_deterministic_and_committed(self):
        a, b = _build(), generate_sprites.build()
        self.assertEqual(a, b)
        for path, data in a.items():
            self.assertTrue(path.exists(), path)
            self.assertEqual(path.read_bytes(), data, f"{path} is stale; run generate_sprites.py")

    def test_frames_are_32x32(self):
        for name, frames in generate_sprites.frames().items():
            for c in frames:
                self.assertEqual((c.w, c.h), (32, 32), name)


Z_RGB = generate_sprites.ZZZ[:3]


def silhouette(c):
    """Opaque bunny pixels (ignoring the floating 'z' glyphs)."""
    return {(x, y) for y in range(32) for x in range(32)
            if c.px[y][x][3] and c.px[y][x][:3] != Z_RGB}


def ground_row(c):
    return max(y for x, y in silhouette(c))


def iou(a, b):
    sa, sb = silhouette(a), silhouette(b)
    return len(sa & sb) / len(sa | sb)


def lua_sequences():
    """Parse Bunny.SEQUENCES from Animation.lua -> {name: [(pose, secs)]}."""
    import re
    src = (validate.ADDON_DIR / "Animation.lua").read_text()
    out = {}
    for m in re.finditer(r"^\s+(\w+)\s*=\s*\{((?:\s*\{\s*\"\w+\",\s*[\d.]+\s*\},?)+)\s*\},?$",
                         src, re.M):
        steps = re.findall(r'\{\s*"(\w+)",\s*([\d.]+)\s*\}', m.group(2))
        out[m.group(1)] = [(p, float(t)) for p, t in steps]
    return out


def gif_frames(data: bytes):
    """Tiny GIF decoder (enough for our own encoder's output)."""
    import struct
    assert data[:6] == b"GIF89a"
    w, h, flags = struct.unpack("<HHB", data[6:11])
    pos = 13 + 3 * (2 << (flags & 7))
    frames, delays = [], []
    while True:
        b = data[pos]
        if b == 0x3B:
            break
        if b == 0x21:
            label = data[pos + 1]
            if label == 0xF9:
                delays.append(struct.unpack("<H", data[pos + 4:pos + 6])[0])
            pos += 2
            while data[pos]:
                pos += data[pos] + 1
            pos += 1
            continue
        assert b == 0x2C, hex(b)
        pos += 10
        min_size = data[pos]
        pos += 1
        stream = bytearray()
        while data[pos]:
            stream += data[pos + 1:pos + 1 + data[pos]]
            pos += data[pos] + 1
        pos += 1
        frames.append(lzw_decode(bytes(stream), min_size))
    return w, h, frames, delays


def lzw_decode(stream: bytes, min_size: int):
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    size = min_size + 1
    table = [bytes([i]) for i in range(clear)] + [b"", b""]
    out, prev = bytearray(), None
    acc = nbits = 0
    it = iter(stream)
    while True:
        while nbits < size:
            acc |= next(it) << nbits
            nbits += 8
        code = acc & ((1 << size) - 1)
        acc >>= size
        nbits -= size
        if code == clear:
            table = table[:clear + 2]
            size, prev = min_size + 1, None
            continue
        if code == eoi:
            return bytes(out)
        if code < len(table):
            entry = table[code]
            if prev is not None:
                table.append(prev + entry[:1])
        else:
            entry = prev + prev[:1]
            table.append(entry)
        out += entry
        prev = entry
        if len(table) == (1 << size) and size < 12:
            size += 1


class SleepArtTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sheets = generate_sprites.frames()
        cls.idle = cls.sheets["bunny-idle"][0]
        sleepy = cls.sheets["bunny-sleepy"]
        cls.drowsy, cls.liedown = sleepy[:3], sleepy[3:]
        cls.sleep = cls.sheets["bunny-sleep"]
        cls.wake = cls.sheets["bunny-wake"]

    def test_frame_counts(self):
        self.assertEqual((len(self.drowsy), len(self.liedown), len(self.sleep), len(self.wake)),
                         (3, 4, 6, 4))

    def test_every_grounded_frame_shares_one_ground_row(self):
        rows = {}
        for name, frames in self.sheets.items():
            for i, c in enumerate(frames):
                if (name, i) == ("bunny-hop", 1):
                    continue  # mid-air jump frame
                rows[f"{name}[{i + 1}]"] = ground_row(c)
        self.assertEqual(set(rows.values()), {29}, rows)

    def test_breathing_moves_torso_exactly_one_pixel(self):
        rest, inhale = self.sleep[0], self.sleep[1]
        self.assertEqual(ground_row(rest), ground_row(inhale))
        a, b = silhouette(rest), silhouette(inhale)
        moved = 0
        for x in range(32):
            ta = min((y for xx, y in a if xx == x), default=None)
            tb = min((y for xx, y in b if xx == x), default=None)
            if ta is None or tb is None:
                self.assertEqual(ta, tb, f"column {x}")
                continue
            self.assertIn(ta - tb, (0, 1), f"column {x} top moved {ta - tb}px")
            moved += ta - tb == 1
        self.assertGreater(moved, 3, "inhale should visibly lift the back")
        # The head (front part of the frame) stays perfectly still.
        head = lambda s: {(x, y) for x, y in s if x >= 21}
        self.assertEqual(head(a), head(b))
        # Hold/exhale frames repeat the same two torso shapes.
        self.assertEqual(silhouette(self.sleep[2]), b)
        self.assertEqual(silhouette(self.sleep[3]), a)

    def test_twitch_frames_are_subtle_variants_of_rest(self):
        # Twitches sit between an exhale (sleep4) and the next rest (sleep1),
        # both of which share the resting torso shape.
        rest = self.sleep[0]
        ear, nose = self.sleep[4], self.sleep[5]
        self.assertLess(len(silhouette(ear) ^ silhouette(rest)), 30, "ear flick is small")
        self.assertGreater(len(silhouette(ear) ^ silhouette(rest)), 0)
        # Nose twitch: same silhouette, only a few face pixels change colour.
        self.assertEqual(silhouette(nose), silhouette(rest))
        face = sum(1 for y in range(32) for x in range(32)
                   if nose.px[y][x] != rest.px[y][x]
                   and Z_RGB not in (nose.px[y][x][:3], rest.px[y][x][:3]))
        self.assertTrue(0 < face <= 4, face)
        for c in (ear, nose):
            self.assertEqual(ground_row(c), ground_row(rest))

    def test_consecutive_frames_overlap_without_jumps(self):
        order = ([self.idle] + self.drowsy + self.liedown + self.sleep[:4] + [self.sleep[0]]
                 + self.wake + [self.idle])
        for i, (a, b) in enumerate(zip(order, order[1:])):
            self.assertGreaterEqual(iou(a, b), 0.7, f"transition {i} -> {i + 1}")
        # The lying-down sequence ends exactly in the sleeping rest pose.
        self.assertEqual(silhouette(self.liedown[-1]), silhouette(self.sleep[0]))

    def test_z_glyphs_stay_clear_of_the_bunny(self):
        for i, c in enumerate(self.sleep):
            zs = [(x, y) for y in range(32) for x in range(32) if c.px[y][x][:3] == Z_RGB]
            self.assertTrue(zs, f"sleep frame {i + 1} has a z")
            body = silhouette(c)
            for x, y in zs:
                for dx, dy in ((0, 1), (1, 0), (-1, 0), (0, -1)):
                    self.assertNotIn((x + dx, y + dy), body, f"z touches bunny in frame {i + 1}")

    def test_timings_match_lua(self):
        lua = lua_sequences()
        for name, secs in generate_sprites.TIMINGS.items():
            self.assertIn(name, lua)
            self.assertEqual([t for _, t in lua[name]], secs, name)
        windows = {"drowsy": (0.5, 0.8), "liedown": (0.5, 0.8),
                   "breathe": (2.0, 3.0), "wake": (0.6, 1.0)}
        for name, (lo, hi) in windows.items():
            self.assertTrue(lo <= sum(generate_sprites.TIMINGS[name]) <= hi, name)

    def test_animated_preview_decodes(self):
        data = _build()[generate_sprites.GIF_PATH]
        self.assertLess(len(data), 100_000)
        w, h, frames, delays = gif_frames(data)
        timeline = generate_sprites.nap_timeline(self.sheets)
        self.assertEqual(len(frames), len(timeline))
        self.assertEqual(len(delays), len(timeline))
        for f in frames:
            self.assertEqual(len(f), w * h)
        self.assertEqual(delays[3:6], [round(t * 100) for t in generate_sprites.TIMINGS["drowsy"]])
        # Frames differ (the animation actually animates).
        self.assertGreater(len(set(frames)), 15)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_build_and_verify(self):
        out = package.build(self.tmp)
        self.assertEqual(package.verify(out), [])
        with zipfile.ZipFile(out) as zf:
            names = zf.namelist()
        self.assertIn("BunnyBar/BunnyBar.toc", names)
        self.assertIn("BunnyBar/Textures/bunny-idle.tga", names)
        self.assertTrue(all(n.startswith("BunnyBar/") for n in names))

    def test_build_is_reproducible(self):
        a = package.build(self.tmp / "a").read_bytes()
        b = package.build(self.tmp / "b").read_bytes()
        self.assertEqual(a, b)

    def test_wrong_root_is_caught(self):
        bad = self.tmp / "bad.zip"
        with zipfile.ZipFile(package.build(self.tmp)) as src, zipfile.ZipFile(bad, "w") as dst:
            for n in src.namelist():
                dst.writestr("addon/" + n, src.read(n))
        self.assertTrue(any("root" in p for p in package.verify(bad)))

    def test_missing_and_junk_files_are_caught(self):
        bad = self.tmp / "bad.zip"
        with zipfile.ZipFile(package.build(self.tmp)) as src, zipfile.ZipFile(bad, "w") as dst:
            for n in src.namelist():
                if not n.endswith("Core.lua"):
                    dst.writestr(n, src.read(n))
            dst.writestr("BunnyBar/.DS_Store", b"x")
        problems = package.verify(bad)
        self.assertTrue(any("missing" in p and "Core.lua" in p for p in problems), problems)
        self.assertTrue(any(".DS_Store" in p for p in problems), problems)

    def test_tag_must_match_version(self):
        version = package.toc_meta()[0]["Version"]
        self.assertEqual(package.main(["--tag", "v9.9.9", "--out", str(self.tmp)]), 1)
        self.assertEqual(package.main(["--tag", f"v{version}", "--out", str(self.tmp)]), 0)


class DocsTests(unittest.TestCase):
    def test_every_slash_command_is_documented(self):
        config = (validate.ADDON_DIR / "Config.lua").read_text()
        commands = (ROOT / "docs" / "COMMANDS.md").read_text()
        readme = (ROOT / "README.md").read_text()
        for cmd in ["show", "hide", "lock", "unlock", "reset", "size", "speed",
                    "interval", "width", "height", "test", "stats", "bars"]:
            self.assertIn(cmd, config)
            self.assertIn(f"/bunny {cmd}", commands, cmd)
            self.assertIn(f"/bunny {cmd}", readme, cmd)


if __name__ == "__main__":
    unittest.main()
