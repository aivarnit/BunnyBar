// BunnyBar (dragon): "ah... ahh... CHOO!" - puffs of smoke from the nose as the sneeze builds, then a small, snappy
// fire burst from the mouth that brakes, cools into smoke and leaves a few embers. The flame balls and sparks are
// pixelfx's simulated particles (FIRE, SPARK, EMBER from Sprite Fusion's open-source VFX code, MIT, Copyright (c)
// 2026 Hugo Duprez); the burst, its size and the smoke are BunnyBar's own, kept within a few px of the bunny.
import { Particles, Lights, P, Rng, fit, ease, clamp, TAU, WHITE } from "../../core/index.js";
import { life, twinkle, winks, OUTLINE } from "./_bunny.js";

export const meta = {
  name: "Fire sneeze",
  desc: "Smoke puffs from the nose as the sneeze builds; on the CHOO a white-hot puff snaps out into a short cone of flame that brakes, cools into soft smoke and leaves embers.",
  tags: ["bunnybar", "fire", "breath", "sneeze", "dragon", "one-shot"],
  size: [48, 48],
  origin: [24, 46],
  duration: 2.4,
  loop: false,
  fps: 30,
  bg: "ground",
  options: {
    palette: ["#4a1712", "#c9281f", "#f2561d", "#ff8a2a", "#ffc23d", "#fff3a6"],
    smoke: ["#4a4252", "#6e6478", "#968ca0", "#bdb4c6"],
    mouth: [11, -11],
    nose: [8, -14],
    seed: 8,
  },
};

export const SNEEZE = 0.7; // effect time of the CHOO (the head snaps forward)
const NOSE_PUFFS = [0.05, 0.3, 0.5];
const RIGHT = 22; // the canvas edge the burst must stay inside (local x)

// Soft smoke lobes: translucent, lit on top, swelling and thinning as they rise.
function smoke(p, S, x, y, r, a) {
  if (a <= 0.04 || r < 0.6) return;
  p.disc(x, y, r, (d, ang) => (Math.sin(ang) < -0.3 && d < 0.75 ? S[2] : d > 0.7 ? S[0] : S[1]), a);
}

export function create(o) {
  const C = fit(o.palette, 6), S = fit(o.smoke, 4), R = new Rng(o.seed), [mx, my] = o.mouth, [nx, ny] = o.nose;
  const ps = new Particles({ rng: R, ground: () => 0, sparks: [WHITE, C[5], C[4], C[3]] });
  const lights = new Lights();
  // where the burst's smoke comes from: spots along the cone, each a lobe that rises and drifts
  const lobes = Array.from({ length: 5 }, (_, i) => ({
    x: mx + 3 + i * 1.8 + R.range(-0.5, 0.5), y: my + R.range(-1.5, 1), r0: R.range(1.2, 1.8), r1: R.range(2.4, 3.2),
    t0: SNEEZE + 0.25 + i * 0.05, L: R.range(0.8, 1.1), rise: R.range(7, 11), drift: R.range(1, 3),
  }));
  let t = 0, sneezed = false;

  return {
    update(dt) {
      t += dt;
      if (!sneezed && t >= SNEEZE) {
        sneezed = true;
        // the burst: flame balls in a short cone that brake hard (FIRE drag), fastest in the middle
        for (let i = 0; i < 8; i++) {
          const a = R.range(-0.3, 0.22), sp = R.range(32, 48) * (1 - Math.abs(a) * 0.8);
          ps.spawn(P.FIRE, mx + 1, my, Math.cos(a) * sp, Math.sin(a) * sp, R.range(0.38, 0.5), 0, R.range(1.2, 1.9), R.range(0, 0.06));
        }
        for (let i = 0; i < 4; i++) {
          const a = R.range(-0.8, 0.1), sp = R.range(40, 55);
          ps.spawn(P.SPARK, mx + 2, my, Math.cos(a) * sp, Math.sin(a) * sp - 15, R.range(0.1, 0.16));
        }
        for (let i = 0; i < 4; i++)
          ps.spawn(P.EMBER, mx + R.range(2, 6), my + R.range(-1.5, 1), R.range(-3, 2), -R.range(10, 16), R.range(0.6, 0.9), 0, 1, R.range(0.2, 0.45));
        lights.add(mx + 3, my, 7, C[4], 0.7, 0.22);
        lights.add(mx + 1, my, 4, WHITE, 0.9, 0.08);
      }
      ps.update(dt);
      lights.update(dt);
    },
    draw(p) {
      // the build-up: a little grey puff from the nostril on each "ah", rising and thinning
      NOSE_PUFFS.forEach((t0, i) => {
        const u = life(t, t0, 0.35);
        if (u < 0) return;
        const x = nx + 1 + 2 * u, y = ny - 1 - 4 * ease.outQuad(u);
        p.px(x, y, u < 0.5 ? S[3] : S[2]);
        if (u < 0.6) p.px(x + 1, y + 1, S[2]);
        if (i === 2 && u > 0.3) p.px(x - 1, y - 1, S[1]);
      });
      // a hot tickle in the nose just before
      const g = life(t, SNEEZE - 0.2, 0.15);
      if (g >= 0 && !winks(g, 0.5, 1)) twinkle(p, nx + 1, ny - 1, 0, C[4]);
      // the burst's smoke, behind the flame
      for (const l of lobes) {
        const u = life(t, l.t0, l.L);
        if (u < 0) continue;
        const r = l.r0 + (l.r1 - l.r0) * ease.outCubic(u), x = Math.min(RIGHT - r, l.x + l.drift * u), y = l.y - l.rise * ease.outQuad(u);
        // thin from the start and gone smoothly: a puff, not a ball
        smoke(p, S, x, y, r, 0.6 * (1 - u) * (1 - u));
      }
      // the CHOO: one white-hot frame at the lips
      const u = life(t, SNEEZE, 0.1);
      if (u >= 0) {
        p.circle(mx + 2, my, 2, WHITE);
        p.circle(mx + 4, my, 1.4, C[5]);
      }
      ps.draw(p);
      lights.draw(p);
    },
  };
}

export { OUTLINE, clamp, TAU };
