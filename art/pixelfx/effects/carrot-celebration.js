// BunnyBar (classic): the bunny finds a golden carrot and raises it like a trophy.
// The thrown twinkles that brake and wink out follow the choreography of pixelfx's collect-burst
// (itself after Sprite Fusion's open-source pickup, MIT, Copyright (c) 2026 Hugo Duprez); the design is BunnyBar's own.
import { Rng, fit, ease, TAU, WHITE, hex } from "../../core/index.js";
import { life, twinkle, winks } from "./_bunny.js";

export const meta = {
  name: "Carrot celebration",
  desc: "A golden carrot pops out with a glint; raised high it flashes and throws orange and green twinkles that brake, drift up and wink out, then sparkles away.",
  tags: ["bunnybar", "pickup", "sparkle", "carrot", "celebration", "one-shot"],
  size: [48, 48],
  origin: [24, 46],
  duration: 2.1,
  loop: false,
  fps: 30,
  bg: "ground",
  options: {
    palette: ["#7a2e14", "#c4521e", "#f08a2a", "#ffc04a", "#ffe9a0", "#fffbe6"],
    leaf: ["#1d4a2a", "#2f7a3a", "#5cb04a", "#a0e070", "#dcffb4"],
    carrot: [11, -23.6],
    carrotTop: [12.4, -27.4],
    carrotTip: [11.0, -20.5],
    chest: [8, -7.6],
    seed: 3,
  },
};

// Beats (effect time, s): the carrot pops out, is raised (burst), held (glints), then sparkles away.
export const POP = 0, RAISE = 0.2, HOLD_END = 1.4, VANISH = 1.8;

function burst(o) {
  const R = new Rng(o.seed);
  return Array.from({ length: 12 }, (_, i) => {
    // a wide fan, mostly upward: none fall onto the action bar
    const a = -Math.PI / 2 + (i / 11 - 0.5) * 3.4 + R.range(-0.12, 0.12);
    return {
      a, sp: R.range(26, 40) * (i % 3 === 0 ? 1.15 : 0.9), drag: R.range(4.5, 6.5), rise: R.range(5, 9),
      delay: R.range(0, 0.08), L: R.range(0.8, 1.25), green: i % 3 === 1, big: i % 4 === 0, ph: R.range(0, TAU),
    };
  });
}

export function draw(p, t, o) {
  const C = fit(o.palette, 6), G = fit(o.leaf, 5), [cx, cy] = o.carrot, [hx, hy] = o.chest;

  // 1. pop: a glint where the carrot comes out
  let u = life(t, POP, 0.2);
  if (u >= 0) {
    twinkle(p, hx + 2, hy - 2, u < 0.5 ? 2 : 1, C[4], C[3]);
    p.glow(hx + 2, hy - 2, 5, C[3], 0.3 * (1 - u));
  }

  // 2. raise: a one-frame flash on the carrot, then twinkles thrown out
  u = life(t, RAISE, 0.1);
  if (u >= 0) {
    p.circle(cx, cy, 2, C[5]);
    twinkle(p, cx, cy, 3, WHITE, C[4]);
    p.glow(cx, cy, 10, C[4], 0.45);
  }
  for (const s of burst(o)) {
    const age = t - RAISE - s.delay;
    if (age < 0 || age > s.L) continue;
    const k = age / s.L, d = (s.sp / s.drag) * (1 - Math.exp(-s.drag * age));
    const x = cx + Math.cos(s.a) * d, y = cy + Math.sin(s.a) * d - s.rise * age * age;
    if (winks(k, 0.6, s.ph)) continue;
    const c = s.green ? (k < 0.5 ? G[4] : G[3]) : k < 0.4 ? C[5] : k < 0.75 ? C[4] : C[3];
    const tip = s.green ? G[2] : C[2];
    twinkle(p, x, y, s.big && k < 0.45 ? 1 : 0, c, tip);
    if (k < 0.5) p.glow(x, y, 2.5, s.green ? G[3] : C[4], 0.25 * (1 - k));
  }

  // 3. held high: the carrot glints now and then along its length, a warm glow round it, motes drift up
  if (t > RAISE && t < HOLD_END + 0.4) {
    const fade = 1 - ease.inQuad(Math.min(1, Math.max(0, (t - HOLD_END) / 0.4)));
    p.glow(cx, cy, 7, C[4], 0.2 * fade);
    const [ax, ay] = o.carrotTop, [bx, by] = o.carrotTip;
    for (let g = 0; g < 4; g++) {
      const g0 = RAISE + 0.3 + g * 0.3, gu = life(t, g0, 0.2);
      if (gu < 0 || t > HOLD_END) continue;
      const f = [0.7, 0.35, 0.55, 0.2][g];
      twinkle(p, ax + (bx - ax) * f + 1, ay + (by - ay) * f, gu < 0.5 ? 1 : 0, WHITE, C[4]);
    }
    const R = new Rng(o.seed + 7);
    for (let m = 0; m < 7; m++) {
      const m0 = RAISE + 0.25 + m * 0.15 + R.range(0, 0.08), mu = life(t, m0, R.range(0.6, 0.9)), mx = cx + R.range(-6, 6);
      if (mu < 0) {
        R.range(0, 1);
        continue;
      }
      const x = mx + Math.sin(mu * 6 + m) * 1, y = cy - 1 - mu * R.range(8, 12);
      if (!winks(mu, 0.7, m)) p.px(x, y, mu < 0.5 ? C[4] : m % 2 ? G[3] : C[3]);
    }
  }

  // 4. put down: the carrot sparkles away at the chest
  u = life(t, VANISH, 0.3);
  if (u >= 0) {
    if (u < 0.34) twinkle(p, hx + 1, hy - 1, 2, WHITE, C[4]);
    for (let i = 0; i < 6; i++) {
      const a = (i / 6) * TAU + 0.4, d = 2 + 5 * ease.outCubic(u), x = hx + 1 + Math.cos(a) * d, y = hy - 1 + Math.sin(a) * d * 0.7 - 3 * u;
      if (!winks(u, 0.5, i)) p.px(x, y, i % 2 ? G[3] : C[4]);
    }
    p.glow(hx + 1, hy - 1, 6, C[4], 0.35 * (1 - u));
  }
}
