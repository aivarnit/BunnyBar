#!/usr/bin/env node
// Export BunnyBar's style-specific special effects with PixelFX (development time only).
//
//   node scripts/pixelfx_export.mjs [path/to/pixelfx]     (default: ../pixelfx next to this repository,
//                                                            or the PIXELFX_DIR environment variable)
//
// 1. Copies art/pixelfx/effects/*.js into <pixelfx>/src/fx/bunnybar/ so PixelFX's own tools can render and check
//    them:  node tools/render.mjs bunnybar/haunted-wisps --all   and   node tools/check.mjs bunnybar/haunted-wisps
// 2. Renders every style's effect at the sample times in art/pixelfx/timeline.json (written by
//    scripts/generate_sprites.py), with the back layer (behind the bunny) and front layer (in front of it) kept
//    apart, on a transparent background.
// 3. Writes art/pixelfx/<style>.png (row 1: back layer frames, row 2: front layer frames, 48 x 48 each) and
//    art/pixelfx/<style>.json (frame rects and times). scripts/generate_sprites.py turns those into the addon's
//    Textures/<style>/bunny-special-fx.tga. Nothing from PixelFX ships in the addon.
//
// Needs Node 18+ and a PixelFX checkout (https://github.com/patch-gg/pixelfx, MIT). No npm packages.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, copyFileSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ART = join(ROOT, "art", "pixelfx");
const PIXELFX = resolve(process.argv[2] ?? process.env.PIXELFX_DIR ?? join(ROOT, "..", "pixelfx"));
// Glow strength baked into the sheets. Glow over transparency becomes colour with alpha; BunnyBar keeps it low so
// the effects stay crisp pixel art over any background (the converter also drops near-invisible pixels).
const LIGHT = 0.55;

if (!existsSync(join(PIXELFX, "src", "core", "index.js"))) {
  console.error(`No PixelFX checkout at ${PIXELFX}.\nClone it: git clone https://github.com/patch-gg/pixelfx ${PIXELFX}`);
  process.exit(1);
}

// 1. sync the effect sources into the checkout
const target = join(PIXELFX, "src", "fx", "bunnybar");
mkdirSync(target, { recursive: true });
for (const f of readdirSync(join(ART, "effects")).filter((f) => f.endsWith(".js"))) copyFileSync(join(ART, "effects", f), join(target, f));

const core = await import(pathToFileURL(join(PIXELFX, "src", "core", "index.js")).href);
const { encodePNG } = await import(pathToFileURL(join(PIXELFX, "tools", "lib", "png.mjs")).href);
const timeline = JSON.parse(readFileSync(join(ART, "timeline.json"), "utf8"));
const [W, H] = timeline.canvas, [OX, OY] = timeline.origin;

for (const [style, spec] of Object.entries(timeline.styles)) {
  const mod = await import(pathToFileURL(join(target, spec.effect + ".js")).href + `?t=${Date.now()}`);
  const opts = { x: OX, y: OY, light: LIGHT, ...spec.anchors };
  if (style === "angel") opts.lift = spec.samples.map((s) => [s.t, s.lift]);
  const fx = core.createFx(mod, opts);
  const n = spec.samples.length, back = core.createFrame(W, H), front = core.createFrame(W, H);
  const sheet = new Uint8ClampedArray(W * n * H * 2 * 4), frames = [];
  let now = 0;
  spec.samples.forEach((s, i) => {
    if (s.t > now) fx.update(s.t - now), (now = s.t);
    core.clearFrame(back);
    core.clearFrame(front);
    fx.draw(back, "back");
    fx.draw(front, "front");
    [back, front].forEach((f, row) => {
      const rgba = core.composite(f, new Uint8ClampedArray(W * H * 4), null, 1);
      for (let y = 0; y < H; y++) sheet.set(rgba.subarray(y * W * 4, (y + 1) * W * 4), ((row * H + y) * W * n + i * W) * 4);
    });
    frames.push({ index: i + 1, t: s.t, back: { x: i * W, y: 0, w: W, h: H }, front: { x: i * W, y: H, w: W, h: H } });
  });
  writeFileSync(join(ART, `${style}.png`), encodePNG(W * n, H * 2, sheet));
  const meta = {
    effect: `bunnybar/${spec.effect}`, label: spec.label, frames, frameSize: [W, H], pivot: [OX, OY],
    step: timeline.step, light: LIGHT, app: "https://github.com/patch-gg/pixelfx",
  };
  writeFileSync(join(ART, `${style}.json`), JSON.stringify(meta, null, 1) + "\n");
  console.log(`${style.padEnd(8)} bunnybar/${spec.effect}  ${n} frames  ->  art/pixelfx/${style}.png`);
}
