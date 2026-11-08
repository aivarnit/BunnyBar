// BunnyBar (zombie): two green and one purple wisp flicker into being and circle the bunny's head on a tilted orbit,
// passing behind and in front of it with short fading trails, then come apart into tiny motes. The orbit with a far
// half behind the character follows pixelfx's necro-skulls; the wisps are BunnyBar's own.
import { Rng, fit, ease, smooth, clamp, TAU, WHITE } from "../../core/index.js";
import { life, winks, OUTLINE } from "./_bunny.js";

export const meta = {
  name: "Haunted wisps",
  desc: "Three little wisps, two green and one purple, flicker in over the head, circle it behind and in front with fading trails, then come apart into tiny drifting motes.",
  tags: ["bunnybar", "ghost", "wisp", "spirit", "orbit", "zombie", "one-shot"],
  size: [48, 48],
  origin: [24, 46],
  duration: 2.5,
  loop: false,
  fps: 30,
  bg: "ground",
  options: {
    green: ["#16402e", "#2f8a5e", "#62d39a", "#c8ffe0"],
    purple: ["#2c1a4a", "#6a46b0", "#a982ec", "#eadcff"],
    head: [5, -21.8],
    seed: 13,
  },
};

const RX = 11, RY = 3.2, TILT = -0.08, TURN = 1.5; // orbit radii (px), tilt, seconds per turn
export const APPEAR = 0, DISSOLVE = 1.7;

function wispAt(i, t, o) {
  const [hx, hy] = o.head, a = (TAU * t) / TURN + (i * TAU) / 3 + 0.4;
  const ex = Math.cos(a) * RX, ey = Math.sin(a) * RY, bob = Math.sin(t * 6 + i * 2) * 0.8;
  return { x: hx + ex * Math.cos(TILT) - ey * Math.sin(TILT), y: hy + ex * Math.sin(TILT) + ey * Math.cos(TILT) + bob, z: Math.sin(a) };
}

function ramps(o) {
  const G = fit(o.green, 4), V = fit(o.purple, 4);
  return [G, V, G];
}

// One wisp: a little ghost flame, a round 2 px head with a bright flickering eye of light, its tail streaming back
// along the orbit and fading through the ramp (solid steps, no checkerboard). Far ones are a step dimmer.
const HEAD = [[0, 0], [1, 0], [0, -1], [1, -1]];
function wisp(p, W, i, t, o, size) {
  const s = wispAt(i, t, o), far = s.z < 0, d = far ? 1 : 0;
  const x = Math.round(s.x), y = Math.round(s.y), flick = Math.sin(t * 31 + i * 4) > -0.3;
  // the tail: where it was a moment ago, darker the further back, and lifting a little like a flame
  const n = size > 0.6 ? 4 : 1;
  for (let k = n; k >= 1; k--) {
    const q = wispAt(i, t - k * 0.05, o), c = W[Math.max(0, 3 - d - k)];
    if (c === W[0] && far) continue;
    p.px(Math.round(q.x) + (q.x < s.x ? 0 : 1), Math.round(q.y) - (k > 2 ? 1 : 0), c);
  }
  if (size > 0.4) for (const [dx, dy] of HEAD) p.px(x + dx, y + dy, W[2 - d]);
  if (size > 0.7) p.px(x, y - 2, W[1 - d + 1]);
  p.px(x + (flick ? 0 : 1), y - 1, far ? W[2] : flick ? W[3] : WHITE);
  p.glow(x + 0.5, y - 0.5, 3.5, W[2], (far ? 0.1 : 0.22) * size);
}

function drawWisps(p, t, o, back) {
  const W = ramps(o);
  for (let i = 0; i < 3; i++) {
    const born = APPEAR + i * 0.12, grow = clamp((t - born) / 0.25), end = DISSOLVE + i * 0.1;
    if (t < born || t >= end) continue;
    const s = wispAt(i, t, o);
    if ((s.z < 0) !== back) continue;
    wisp(p, W[i], i, t, o, ease.outCubic(grow));
  }
}

// Coming apart: each wisp bursts into a few tiny motes that drift up and out and wink away.
function dissolve(p, t, o) {
  const W = ramps(o), R = new Rng(o.seed);
  for (let i = 0; i < 3; i++) {
    const t0 = DISSOLVE + i * 0.1, s = wispAt(i, t0, o);
    for (let m = 0; m < 6; m++) {
      const a = R.range(0, TAU), sp = R.range(5, 10), L = R.range(0.35, 0.6), u = life(t, t0, L);
      if (u < 0 || winks(u, 0.55, a)) continue;
      const d = sp * ease.outCubic(u) * 0.6;
      p.px(s.x + Math.cos(a) * d, s.y + Math.sin(a) * d * 0.6 - 3 * u, u < 0.4 ? W[i][3] : W[i][2]);
    }
    const f = life(t, t0, 0.1);
    if (f >= 0) p.px(s.x, s.y, WHITE);
  }
}

export function drawBack(p, t, o) {
  drawWisps(p, t, o, true);
}

export function draw(p, t, o) {
  // as they appear: a cold flicker of motes gathering over the head
  const [hx, hy] = o.head, R = new Rng(o.seed + 1), W = ramps(o);
  for (let m = 0; m < 6; m++) {
    const a = R.range(0, TAU), d = R.range(6, 10), u = life(t, R.range(0, 0.2), 0.3);
    if (u < 0 || winks(u, 0.6, a)) continue;
    const k = 1 - ease.outCubic(u);
    p.px(hx + Math.cos(a) * d * k, hy + Math.sin(a) * d * 0.4 * k, W[m % 2][2]);
  }
  drawWisps(p, t, o, false);
  dissolve(p, t, o);
  p.glow(hx, hy, 12, W[0][1], 0.12 * smooth(0, 0.3, t) * (1 - smooth(DISSOLVE, DISSOLVE + 0.5, t)));
}

export { OUTLINE };
