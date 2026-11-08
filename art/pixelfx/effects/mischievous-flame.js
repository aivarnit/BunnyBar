// BunnyBar (devil): a spark on the raised paw catches, a little flame dances and grows, then is snuffed in a puff.
// The flame's heat layering (white low in the heart, cooling outward and upward) follows pixelfx's candle and
// necro-skulls flames (the candle's tongue after Sprite Fusion's open-source fire, MIT, Copyright (c) 2026 Hugo
// Duprez); the shape, outline and choreography are BunnyBar's own.
import { Rng, fit, ease, smooth, clamp, TAU, WHITE, noise } from "../../core/index.js";
import { life, twinkle, outlined, winks, OUTLINE } from "./_bunny.js";

export const meta = {
  name: "Mischievous flame",
  desc: "A spark over the raised paw catches into a small outlined flame that sways and grows, shedding embers; snuffed, it squeezes out into a puff of smoke.",
  tags: ["bunnybar", "fire", "flame", "devil", "summon", "one-shot"],
  size: [48, 48],
  origin: [24, 46],
  duration: 2.2,
  loop: false,
  fps: 30,
  bg: "ground",
  options: {
    palette: ["#5a1424", "#b8232e", "#e8462c", "#ff8a2a", "#ffc94a", "#fff2b0"],
    smoke: ["#4a3f58", "#6e6280", "#978aa8", "#c2b8cf"],
    paw: [10.4, -12.8],
    seed: 5,
  },
};

export const IGNITE = 0, GROWN = 0.5, SNUFF = 1.4;

// Flame height (px) at t: catches, grows, dances, then squeezes out fast on the snuff.
function height(t) {
  if (t < IGNITE + 0.08) return 0;
  const grow = 2.5 + 4.5 * ease.outCubic(clamp((t - 0.08) / (GROWN - 0.08))) + 1.2 * smooth(0.6, 1.1, t);
  const dance = Math.sin(t * 13) * 0.6 + Math.sin(t * 7.3 + 1) * 0.4;
  const squeeze = 1 - ease.inQuad(clamp((t - SNUFF) / 0.12));
  return Math.max(0, (grow + dance) * squeeze);
}

function flame(p, C, bx, by, h, t) {
  if (h < 1) return;
  const w = 2.4 + h * 0.36, sway = Math.sin(t * 9) * 0.9 + Math.sin(t * 15 + 2) * 0.4;
  outlined(p, bx - w, by - h - 2, bx + w + 2, by + 2, (x, y) => {
    const v = (by - y) / h; // 0 at the base, 1 at the tip
    if (v < -0.28 || v > 1) return 0;
    const cxv = bx + sway * Math.max(0, v) * Math.max(0, v);
    const hw = v < 0.3 ? (w / 2) * Math.sqrt(Math.max(0, 1 - ((0.3 - v) / 0.58) ** 2)) : (w / 2) * Math.pow(1 - (v - 0.3) / 0.7, 0.9);
    const lick = noise(x * 0.7, (y + t * 30) * 0.5) * 0.5 * v;
    const d = Math.abs(x - cxv) / Math.max(0.5, hw + lick);
    if (d > 1) return 0;
    const heat = (1 - d) * Math.pow(Math.max(0, 1 - v), 0.6) + 0.1;
    return heat > 0.72 ? C[5] : heat > 0.5 ? C[4] : heat > 0.3 ? C[3] : C[2];
  }, C[0]);
}

export function draw(p, t, o) {
  const C = fit(o.palette, 6), S = fit(o.smoke, 4), [px, py] = o.paw, bx = px, by = py - 1;

  // ignite: a white pin of heat and a few sparks off the paw
  let u = life(t, IGNITE, 0.2);
  if (u >= 0) {
    twinkle(p, bx, by - 1, u < 0.4 ? 1 : 0, WHITE, C[4]);
    for (let i = 0; i < 4; i++) {
      const a = -Math.PI / 2 + (i - 1.5) * 0.7, d = 1.5 + 4 * ease.outCubic(u);
      if (!winks(u, 0.5, i)) p.px(bx + Math.cos(a) * d, by - 1 + Math.sin(a) * d, i % 2 ? C[4] : C[3]);
    }
  }

  // the flame and its warm light
  const h = height(t);
  if (h >= 1) {
    p.glow(bx, by - h * 0.45, 4 + h, C[3], 0.28);
    flame(p, C, bx, by, h, t);
  }

  // embers: shed off the tip while it burns, rising, wandering, cooling, winking out
  const R = new Rng(o.seed);
  for (let i = 0; i < 11; i++) {
    const e0 = 0.25 + i * 0.1 + R.range(0, 0.06), L = R.range(0.45, 0.8), dx = R.range(-1.5, 1.5), up = R.range(9, 15), ph = R.range(0, TAU);
    const eu = life(t, e0, L);
    if (eu < 0 || e0 > SNUFF) continue;
    const x = bx + dx + Math.sin(eu * 7 + ph) * 1.4, y = by - height(e0) - eu * up;
    if (winks(eu, 0.65, ph)) continue;
    p.px(x, y, eu < 0.3 ? C[5] : eu < 0.6 ? C[4] : C[2]);
    if (eu < 0.4) p.glow(x, y, 2, C[3], 0.2);
  }

  // snuffed: a puff of soft smoke that swells, rises and thins, two last sparks
  u = life(t, SNUFF + 0.08, 0.7);
  if (u >= 0) {
    const lobes = [[0, -3, 1.8], [-1.6, -2, 1.4], [1.6, -2.2, 1.4], [0.4, -4.4, 1.3]];
    lobes.forEach(([lx, ly, r], i) => {
      const k = clamp(u * 1.25 - i * 0.06), rr = r + 1.6 * ease.outCubic(k), a = (1 - ease.inQuad(k)) * 0.85;
      if (a <= 0.05) return;
      const x = bx + lx * (1 + k), y = by + ly - 5 * ease.outQuad(k);
      p.disc(x, y, rr, (d, ang) => (Math.sin(ang) < -0.3 && d < 0.75 ? S[3] : d > 0.7 ? S[1] : S[2]), a);
    });
    if (u < 0.3)
      for (const s of [-1, 1]) if (!winks(u, 0.15, s)) p.px(bx + s * (2 + 6 * u), by - 3 - 6 * u, C[4]);
  }
}

export { OUTLINE };
