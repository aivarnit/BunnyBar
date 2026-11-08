// BunnyBar (angel): the halo brightens, the bunny floats up, gold sparkles and small feathers drift down round it,
// and it lands softly. Feathers rocking as they sink follow pixelfx's feather-burst; the halo's light follows
// pixelfx's halo. The design is BunnyBar's own.
import { Rng, fit, ease, smooth, clamp, TAU, WHITE } from "../../core/index.js";
import { life, liftAt, twinkle, winks, OUTLINE } from "./_bunny.js";

export const meta = {
  name: "Heavenly blessing",
  desc: "The halo warms and glints, gold dust puffs out as the bunny lifts off, sparkles fall and twinkle, and small white feathers rock down in front and behind before a soft landing.",
  tags: ["bunnybar", "holy", "halo", "feather", "float", "blessing", "one-shot"],
  size: [48, 48],
  origin: [24, 46],
  duration: 2.5,
  loop: false,
  fps: 30,
  bg: "ground",
  options: {
    palette: ["#7a3a2c", "#c4652e", "#f0a040", "#ffd25e", "#fff0a0", "#fffbe0"],
    feather: ["#7c74a0", "#d4d8f0", "#ffffff"],
    halo: [4.5, -23.0],
    haloPray: [4.5, -21.6],
    lift: [[0, 0], [0.3, 1], [0.4, 2], [0.5, 3], [0.6, 4], [0.7, 5], [1.5, 4], [1.8, 5], [2.0, 3], [2.1, 2], [2.2, 1], [2.3, 0]],
    seed: 11,
  },
};

export const RISE = 0.3, LAND = 2.3, END = 2.4; // everything is gone by END (the last frame is empty)

// The halo exactly as the angel sprite draws it (an ellipse band, rx 4.6, ry 1.5), so the glow sits on its pixels.
function haloPixels(p, hx, hy, top, low) {
  for (let x = Math.floor(hx - 5); x < Math.floor(hx + 6); x++)
    for (let y = Math.floor(hy - 2); y < Math.floor(hy + 3); y++) {
      const dx = (x + 0.5 - hx) / 4.6, dy = (y + 0.5 - hy) / 1.5, d = dx * dx + dy * dy;
      if (d >= 0.45 && d <= 1.05) p.px(x, y, y + 0.5 < hy ? top : low);
    }
}

function feathers(o) {
  const R = new Rng(o.seed);
  return Array.from({ length: 6 }, (_, i) => ({
    x: [-13, 15, -7, 11, -16, 4][i] + R.range(-1.5, 1.5), y: -38 + R.range(-3, 3), t0: 0.45 + i * 0.22 + R.range(0, 0.08),
    L: 0, Lw: R.range(1.2, 1.5), sink: R.range(12, 17), amp: R.range(1.6, 2.6), w: R.range(4.5, 6), ph: R.range(0, TAU), back: i % 2 === 1,
  })).map((f) => ({ ...f, L: Math.min(f.Lw, END - f.t0) }));
}

// A small feather: a 5 px white vane with a lavender shade along its lower edge and a dark quill end, rocking with
// the angle a. Snapped to whole pixels, so it stays a clean shape at 1x.
function feather(p, F, x, y, a) {
  const dx = Math.cos(a), dy = Math.sin(a);
  x = Math.round(x);
  y = Math.round(y);
  for (let k = -2; k <= 2; k++) p.px(x + Math.round(dx * k), y + Math.round(dy * k), k === -2 ? F[0] : F[2]);
  for (let k = -1; k <= 1; k++) p.px(x + Math.round(dx * k - dy), y + Math.round(dy * k + dx), F[1]);
}

function sparkles(o) {
  const R = new Rng(o.seed + 3);
  return Array.from({ length: 10 }, (_, i) => ({
    x: R.range(-15, 18), y: -40 + R.range(0, 8), t0: 0.4 + i * 0.13 + R.range(0, 0.05), Lw: R.range(0.9, 1.3),
    fall: R.range(10, 16), sway: R.range(0.8, 1.6), ph: R.range(0, TAU), white: i % 3 === 0,
  })).map((s) => ({ ...s, L: Math.min(s.Lw, END - s.t0) }));
}

function common(p, t, o, back) {
  const F = fit(o.feather, 3);
  for (const f of feathers(o)) {
    if (f.back !== back) continue;
    const u = life(t, f.t0, f.L);
    if (u < 0 || winks(u, 0.8, f.ph)) continue;
    const s = t - f.t0, a = Math.sin(s * f.w + f.ph) * 0.7;
    feather(p, back ? [F[0], F[0], F[1]] : F, f.x + Math.sin(s * f.w + f.ph) * f.amp, f.y + f.sink * s, a * 0.8);
  }
}

export function drawBack(p, t, o) {
  common(p, t, o, true);
}

export function draw(p, t, o) {
  const C = fit(o.palette, 6), lift = liftAt(o.lift, t);
  const [hx, hy] = t < RISE ? o.haloPray : o.halo, y = hy - (t < RISE ? 0 : lift);

  // the halo warms up (its own pixels, a step brighter), holds, and settles back as the bunny lands
  const k = smooth(0.02, 0.4, t) * (1 - smooth(LAND - 0.25, LAND + 0.1, t));
  if (k > 0.05) {
    p.glow(hx, y, 6 + 4 * k, C[4], 0.3 * k);
    if (k > 0.35) haloPixels(p, hx, y, k > 0.7 ? C[4] : C[3], C[3]);
    for (const [g0, gx] of [[0.5, 4], [0.95, -4], [1.4, 3], [1.85, -3]]) {
      const gu = life(t, g0, 0.2);
      if (gu >= 0) twinkle(p, hx + gx, y - 1, gu < 0.5 ? 1 : 0, WHITE, C[4]);
    }
  }

  // lifting off: a puff of gold dust blown out along the floor both ways, under the feet
  const ru = life(t, RISE, 0.5);
  if (ru >= 0)
    for (const s of [-1, 1])
      for (let j = 0; j < 3; j++) {
        const d = 6 + j * 2.5 + 7 * ease.outCubic(ru), yy = -1 - (j === 1 ? 1 : 0) - 1.5 * ru;
        if (!winks(ru, 0.55, s * 3 + j)) p.px(-1 + s * d, yy, ru < 0.4 ? C[5] : C[4]);
      }

  // gold sparkles falling and twinkling round it
  for (const s of sparkles(o)) {
    const u = life(t, s.t0, s.L);
    if (u < 0 || winks(u, 0.7, s.ph)) continue;
    const a = t - s.t0, x = s.x + Math.sin(a * 5 + s.ph) * s.sway, yy = s.y + s.fall * a;
    const big = Math.sin(a * 9 + s.ph) > 0.4 && u < 0.6;
    twinkle(p, x, yy, big ? 1 : 0, s.white ? WHITE : C[4], C[3]);
    if (u < 0.6) p.glow(x, yy, 2, C[4], 0.18);
  }

  common(p, t, o, false);

  // landing: a pinch of gold dust at the feet
  const lu = life(t, LAND - 0.1, 0.25);
  if (lu >= 0)
    for (const s of [-1, 1]) for (const j of [0, 1]) if (!winks(lu, 0.5, s + j)) p.px(-1 + s * (8 + 4 * lu + j * 2), -1 - j - 2 * lu, j ? C[5] : C[4]);
}

export { OUTLINE };
