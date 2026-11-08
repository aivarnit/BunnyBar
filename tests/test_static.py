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
        self.assertEqual(files, ["Util.lua", "Config.lua", "Appearance.lua", "SpriteData.lua",
                                 "Placement.lua", "Animation.lua", "Personality.lua", "Hearts.lua", "Ears.lua",
                                 "Options.lua", "Core.lua"])

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
        # Two stacked layers (fur, detail): height = 2 x frame height. Every
        # style has its own copy of the bunny sheets; effects are shared.
        styled = {"bunny-idle.tga": (128, 64), "bunny-hop.tga": (256, 64),
                  "bunny-sleepy.tga": (256, 64), "bunny-sleep.tga": (256, 64),
                  "bunny-wake.tga": (128, 64), "bunny-carrot.tga": (512, 64),
                  "bunny-groom.tga": (512, 64), "bunny-moves.tga": (256, 64),
                  "bunny-burrow.tga": (512, 64)}
        expected = dict(styled)
        for sid in ("devil", "angel", "dragon", "zombie"):
            expected.update({f"{sid}/{n}": v for n, v in styled.items()})
        expected.update({"bunny-ears.tga": (32, 32), "bunny-burrow-fx.tga": (256, 64),
                         "bunny-heart.tga": (16, 16)})
        self.assertEqual(set(validate.texture_references()), set(expected))
        for name, (width, height) in expected.items():
            w, h, bpp, alpha, top_left, _ = validate.read_tga(validate.ADDON_DIR / "Textures" / name)
            self.assertEqual((w, h, bpp, alpha, top_left), (width, height, 32, 8, True), name)

    def test_missing_texture_is_caught(self):
        with TempAddon() as d:
            (d / "Textures" / "bunny-hop.tga").unlink()
            self.assertTrue(any("bunny-hop.tga" in e for e in errors_for(validate.check_textures, d)))

    def test_corrupt_texture_is_caught(self):
        with TempAddon() as d:
            (d / "Textures" / "bunny-wake.tga").write_bytes(b"not a tga")
            self.assertTrue(any("bunny-wake.tga" in e for e in errors_for(validate.check_textures, d)))

    def test_unreferenced_texture_is_caught(self):
        with TempAddon() as d:
            shutil.copy(d / "Textures" / "bunny-wake.tga", d / "Textures" / "bunny-extra.tga")
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


import re  # noqa: E402

ANIMATION_LUA = (validate.ADDON_DIR / "Animation.lua").read_text()


def lua_block(name):
    m = re.search(r"Bunny\." + name + r"\s*=\s*\{(.*?)\n\}", ANIMATION_LUA, re.S)
    assert m, name
    return m.group(1)


def lua_sequences():
    """Parse Bunny.SEQUENCES (multi-line) -> {name: [(pose, secs)]}."""
    out = {}
    for m in re.finditer(r"(\w+)\s*=\s*\{((?:\s*\{\s*\"\w+\"\s*,\s*[\d.]+\s*\}\s*,?)+)\s*\}",
                         lua_block("SEQUENCES")):
        steps = re.findall(r'\{\s*"(\w+)"\s*,\s*([\d.]+)\s*\}', m.group(2))
        out[m.group(1)] = [(p, float(t)) for p, t in steps]
    return out


def lua_poses():
    return {name: ("bunny-" + sheet, int(i))
            for name, sheet, i in re.findall(r'(\w+)\s*=\s*\{\s*"(\w+)"\s*,\s*(\d+)\s*\}', lua_block("POSES"))}


def lua_line(name):
    """Right-hand side of a single-line `Bunny.NAME = { ... }` table."""
    m = re.search(r"Bunny\." + name + r"\s*=\s*(\{.*\})\s*$", ANIMATION_LUA, re.M)
    assert m, name
    return m.group(1)


def lua_number_table(name):
    return {k: float(v) for k, v in re.findall(r"(\w+)\s*=\s*([\d.]+)", lua_line(name))}


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
                if name == "bunny-hop" and i in (2, 3, 4):
                    continue  # mid-air frames: rising, apex, falling
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
        self.assertEqual(set(lua), set(generate_sprites.SEQUENCES))
        for name, steps in generate_sprites.SEQUENCES.items():
            self.assertEqual(lua[name], [(p, float(t)) for p, t in steps], name)
        self.assertEqual(lua_poses(), generate_sprites.POSES)
        self.assertEqual(lua_number_table("HOP_TIMING"), generate_sprites.HOP_TIMING)
        air = re.findall(r'\{\s*([\d.]+)\s*,\s*"(\w+)"\s*\}', lua_line("AIR_POSES"))
        self.assertEqual([(float(a), b) for a, b in air], generate_sprites.AIR_POSES)
        for const in ("BURROW_UNDERGROUND", "BURROW_HOLE_OPEN"):
            m = re.search(r"Bunny\." + const + r"\s*=\s*([\d.]+)", ANIMATION_LUA)
            self.assertEqual(float(m.group(1)), getattr(generate_sprites, const), const)
        fx = {}
        for seq_name, body in re.findall(r"(\w+)\s*=\s*\{((?:\s*\[\d+\]\s*=\s*\{[^}]*\}\s*,?)+)\s*\}", lua_block("BURROW_FX")):
            fx[seq_name] = {int(i): (w, None if f == "false" else int(f))
                            for i, w, f in re.findall(r'\[(\d+)\]\s*=\s*\{\s*"(\w+)"\s*,\s*(\w+)\s*\}', body)}
        self.assertEqual(fx, generate_sprites.BURROW_FX)
        hearts = (validate.ADDON_DIR / "Hearts.lua").read_text()
        m = re.search(r"Hearts\.PARTICLE\s*=\s*\{([^}]*)\}", hearts)
        self.assertEqual({k: float(v) for k, v in re.findall(r"(\w+)\s*=\s*([\d.]+)", m.group(1))},
                         generate_sprites.HEART_PARTICLE)
        windows = {"drowsy": (0.5, 0.8), "liedown": (0.5, 0.8),
                   "breathe": (2.0, 3.0), "wake": (0.6, 1.0), "carrot": (3.0, 5.0)}
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

    def test_v03_previews_decode(self):
        out = _build()
        for name in ("hop-preview.gif", "carrot-preview.gif", "burrow-preview.gif", "hearts-preview.gif"):
            data = out[generate_sprites.IMAGES / name]
            self.assertLess(len(data), 200_000, name)
            w, h, frames, delays = gif_frames(data)
            self.assertGreater(len(set(frames)), 5, name)
            for f in frames:
                self.assertEqual(len(f), w * h)
        # The carrot preview plays the addon's carrot sequence at its timings.
        _, _, _, delays = gif_frames(out[generate_sprites.IMAGES / "carrot-preview.gif"])
        self.assertEqual(delays[1:-1], [round(t * 100) for t in generate_sprites.TIMINGS["carrot"]])
        for sid in ("classic", "devil", "angel", "dragon", "zombie"):
            self.assertIn(generate_sprites.IMAGES / f"sprites-{sid}.png", out)
        self.assertIn(generate_sprites.IMAGES / "styles.png", out)


class RecolourTests(unittest.TestCase):
    """Fur / detail layer split used for recolouring."""

    @classmethod
    def setUpClass(cls):
        cls.frames = [c for fr in generate_sprites.frames().values() for c in fr]
        cls.ears = generate_sprites.portrait_ears()

    def test_layers_are_disjoint_and_cover_the_sprite(self):
        for c in self.frames + [self.ears]:
            fur, detail = generate_sprites.split_layers(c)
            for y in range(c.h):
                for x in range(c.w):
                    self.assertFalse(fur.px[y][x][3] and detail.px[y][x][3])
                    self.assertEqual(bool(c.px[y][x][3]), bool(fur.px[y][x][3] or detail.px[y][x][3]))

    def test_default_colour_reproduces_the_original_art(self):
        tail = generate_sprites.TAIL[:3]
        for c in self.frames:
            t = generate_sprites.tint_composite(c, generate_sprites.DEFAULT_FUR_HEX)
            for y in range(32):
                for x in range(32):
                    a, b = c.px[y][x], t.px[y][x]
                    self.assertEqual(a[3], b[3])
                    if a[3]:
                        # The tail now uses the main fur tone (5/255 darker).
                        limit = 5 if a[:3] == tail else 1
                        self.assertLessEqual(max(abs(a[i] - b[i]) for i in range(3)), limit, (x, y))

    def test_fur_tones_are_consistent_across_every_frame(self):
        tones = set()
        for c in self.frames + [self.ears]:
            fur, _ = generate_sprites.split_layers(c)
            tones |= {p[:3] for row in fur.px for p in row if p[3]}
        # Only the normalised fur palette (main fur = white, shade, mouth,
        # eyelid): every frame recolours identically.
        allowed = {tuple(min(255, round(c[i] * 255 / generate_sprites.FUR_BASE[i])) for i in range(3))
                   for c in generate_sprites.FUR_RGB}
        self.assertTrue(tones <= allowed, tones - allowed)
        self.assertIn((255, 255, 255), tones)

    def test_recolour_changes_fur_only(self):
        for hx in ("FFB6C1", "87CEEB", "000000"):
            rgb = tuple(int(hx[i:i + 2], 16) for i in (0, 2, 4))
            for c in self.frames[:6] + [self.ears]:
                t = generate_sprites.tint_composite(c, hx)
                for y in range(c.h):
                    for x in range(c.w):
                        p = c.px[y][x]
                        if not p[3]:
                            self.assertEqual(t.px[y][x][3], 0)
                        elif generate_sprites.is_fur(p):
                            if p[:3] == generate_sprites.FUR[:3]:
                                self.assertEqual(t.px[y][x][:3], rgb, "main fur takes the exact colour")
                        else:
                            self.assertEqual(t.px[y][x], p, "eyes/nose/ears/outline unchanged")

    def test_portrait_ears_sprite(self):
        e = self.ears
        self.assertEqual((e.w, e.h), (32, 16))
        bottom = [x for x in range(32) if e.px[15][x][3]]
        self.assertTrue(bottom, "ears are rooted on the bottom edge")
        left = [x for x in bottom if x < 16]
        right = [x for x in bottom if x >= 16]
        self.assertTrue(left and right, "two ears")
        pink = generate_sprites.PINK[:3]
        self.assertTrue(any(p[:3] == pink for row in e.px for p in row), "pink inner ears")
        # Mirror-symmetric silhouette (within 1 px).
        sil = {(x, y) for y in range(16) for x in range(32) if e.px[y][x][3]}
        mirrored = {(31 - x, y) for x, y in sil}
        self.assertLessEqual(len(sil ^ mirrored), 8)


class StyleArtTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.all = {st.id: generate_sprites.frames(st.id) for st in generate_sprites.STYLES}

    def test_every_style_has_every_frame(self):
        base = {k: len(v) for k, v in self.all["classic"].items()}
        for sid, sheets in self.all.items():
            self.assertEqual({k: len(v) for k, v in sheets.items()}, base, sid)
            for frames in sheets.values():
                for c in frames:
                    self.assertEqual((c.w, c.h), (32, 32))

    def test_style_features_are_present_and_distinct(self):
        g = generate_sprites
        features = {"devil": [g.DEVIL_HORN, g.DEVIL_TAIL], "angel": [g.HALO, g.WING],
                    "dragon": [g.DRAGON_HORN, g.DRAGON_WING], "zombie": [g.STITCH, g.PATCH]}
        for sid, colours in features.items():
            idle = self.all[sid]["bunny-idle"][0]
            used = {p[:3] for row in idle.px for p in row if p[3]}
            for col in colours:
                self.assertIn(col[:3], used, f"{sid} idle frame lacks {col}")
            classic = {p[:3] for row in self.all["classic"]["bunny-idle"][0].px for p in row if p[3]}
            self.assertFalse(set(c[:3] for c in colours) & classic, f"{sid} features leak into classic")

    def test_style_details_stay_untinted_and_fur_tinted(self):
        g = generate_sprites
        for sid, sheets in self.all.items():
            for c in sheets["bunny-idle"] + sheets["bunny-hop"]:
                t = g.tint_composite(c, "3060C0")
                for y in range(32):
                    for x in range(32):
                        p = c.px[y][x]
                        if p[3] and not g.is_fur(p):
                            self.assertEqual(t.px[y][x], p, f"{sid}: detail pixel changed by tint")

    def test_zombie_has_a_drooping_ear(self):
        z = silhouette(self.all["zombie"]["bunny-idle"][0])
        c = silhouette(self.all["classic"]["bunny-idle"][0])
        # The far ear flops back: the zombie's ear tips no longer reach the top.
        self.assertGreater(min(y for _, y in z), min(y for _, y in c) - 1)
        self.assertNotEqual(z, c)

    def test_classic_style_is_unchanged_by_style_hooks(self):
        g = generate_sprites
        a = g.frames("classic")["bunny-sleep"][0]
        b = g.draw_bunny(**g.LIE, eyes="closed")
        g.add_z(b, g.Z_FRAMES[0])
        self.assertEqual(a.px, b.px)

    def test_burrow_frames_sink_and_emerge_progressively(self):
        for sid, sheets in self.all.items():
            bur = sheets["bunny-burrow"]
            sink = [sum(1 for row in c.px for p in row if p[3]) for c in bur[4:8]]
            self.assertEqual(sink, sorted(sink, reverse=True), f"{sid} sink shrinks: {sink}")
            self.assertGreater(sink[-1], 0, f"{sid}: ear tips still visible")
            emerge = [sum(1 for row in c.px for p in row if p[3]) for c in bur[8:11]]
            self.assertEqual(emerge, sorted(emerge), f"{sid} emerge grows: {emerge}")
            for c in bur[4:10]:
                self.assertTrue(all(c.px[y][x][3] == 0 for y in range(30, 32) for x in range(32)),
                                "nothing below the ground line while in the hole")

    def test_sprite_data_matches_frames(self):
        src = generate_sprites.SPRITE_DATA_PATH.read_text()
        for sid, sheets in self.all.items():
            for name, frames in sheets.items():
                boxes = [generate_sprites.bbox(c) for c in frames]
                line = f'["{name}.tga"] = {{ ' + ", ".join("{ %d, %d, %d, %d }" % b for b in boxes) + " },"
                self.assertIn(line, src, f"{sid} {name}")
                for b in boxes:
                    self.assertTrue(b[2] > b[0] and b[3] > b[1], f"{sid} {name}: empty box")


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
    def test_release_notes_exist_for_the_current_version(self):
        version = package.toc_meta()[0]["Version"]
        notes = ROOT / "docs" / "releases" / f"v{version}.md"
        self.assertTrue(notes.exists(), f"add {notes.relative_to(ROOT)} before tagging")
        text = notes.read_text()
        self.assertIn(f"v{version}", text)
        self.assertIn(f"BunnyBar-{version}.zip", text)
        self.assertIn("WoW Forever", text.replace("World of Warcraft: Forever", "WoW Forever"))
        self.assertIn("_forever_/Interface/AddOns", text)
        self.assertIn("16001", text)
        readme = (ROOT / "README.md").read_text()
        self.assertIn(f"Current version: {version}", readme)

    def test_every_slash_command_is_documented(self):
        config = (validate.ADDON_DIR / "Config.lua").read_text()
        commands = (ROOT / "docs" / "COMMANDS.md").read_text()
        readme = (ROOT / "README.md").read_text()
        for cmd in ["show", "hide", "lock", "unlock", "reset", "size", "speed",
                    "interval", "width", "height", "test", "stats", "bars", "options",
                    "color", "ears", "style", "hearts", "burrow", "idle", "carrot",
                    "personality", "mood"]:
            self.assertIn(cmd, config)
            self.assertIn(f"/bunny {cmd}", commands, cmd)
            self.assertIn(f"/bunny {cmd}", readme, cmd)


if __name__ == "__main__":
    unittest.main()
