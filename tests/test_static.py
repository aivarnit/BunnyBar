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

import generate_sprites  # noqa: E402
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
        self.assertEqual(files, ["Util.lua", "Config.lua", "Animation.lua", "Core.lua"])

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
        expected = {"bunny-idle.tga": 128, "bunny-hop.tga": 64,
                    "bunny-land.tga": 32, "bunny-sleep.tga": 64}
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
        a, b = generate_sprites.build(), generate_sprites.build()
        self.assertEqual(a, b)
        for path, data in a.items():
            self.assertTrue(path.exists(), path)
            self.assertEqual(path.read_bytes(), data, f"{path} is stale; run generate_sprites.py")

    def test_frames_are_32x32(self):
        for name, frames in generate_sprites.frames().items():
            for c in frames:
                self.assertEqual((c.w, c.h), (32, 32), name)


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
                    "interval", "width", "height", "test", "stats"]:
            self.assertIn(cmd, config)
            self.assertIn(f"/bunny {cmd}", commands, cmd)
            self.assertIn(f"/bunny {cmd}", readme, cmd)


if __name__ == "__main__":
    unittest.main()
