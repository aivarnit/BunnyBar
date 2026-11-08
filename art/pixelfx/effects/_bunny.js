// BunnyBar effect helpers (a PixelFX "_" helper file, not an effect).
//
// BunnyBar's effects are drawn at the bunny's own scale: a 48 x 48 canvas whose local origin (0, 0) is the floor
// under the bunny's 32 x 32 frame centre (canvas 24, 46). The bunny's frame covers x -16..16, y -30..2. Every
// detail is 1 px: these effects are shown at 1x on the Small (32) preset, nearest-neighbour scaled above it.

import { WHITE, hex, clamp } from "../../core/index.js";

/** BunnyBar's plum outline, used to outline solid shapes (flames, feathers) like the bunny itself. */
export const OUTLINE = hex("#3a2c42");

/** Age of something that lives from t0 for L seconds, 0..1, or -1 when it isn't alive. */
export const life = (t, t0, L) => (t < t0 || t >= t0 + L ? -1 : (t - t0) / L);

/** The bunny's lift (px) at effect time t, from [[t, px], ...] samples (the angel floats). */
export function liftAt(samples, t) {
  let l = 0;
  for (const [ts, v] of samples ?? []) if (t + 1e-6 >= ts) l = v;
  return l;
}

/**
 * A tiny twinkle: a plus with arms of `arm` px (0 = one pixel) in c, tips in `tip`, a white heart once it has arms.
 * Snapped to whole pixels so it never smears at 1x.
 */
export function twinkle(p, x, y, arm, c, tip = c) {
  x = Math.round(x);
  y = Math.round(y);
  if (arm <= 0) {
    p.px(x, y, c);
    return;
  }
  for (let k = 1; k <= arm; k++) {
    const cc = k === arm ? tip : c;
    p.px(x + k, y, cc);
    p.px(x - k, y, cc);
    p.px(x, y + k, cc);
    p.px(x, y - k, cc);
  }
  p.px(x, y, WHITE);
}

/**
 * Fill a shape given by inside(x, y) -> color or 0 (sampled at pixel centres) inside a box, with a 1 px outline in
 * `edge` round it (4-connected), the way BunnyBar's sprites are outlined.
 */
export function outlined(p, x0, y0, x1, y1, inside, edge = OUTLINE) {
  x0 = Math.floor(x0) - 1;
  y0 = Math.floor(y0) - 1;
  x1 = Math.ceil(x1) + 1;
  y1 = Math.ceil(y1) + 1;
  const w = x1 - x0 + 1, h = y1 - y0 + 1, cells = new Array(w * h).fill(0);
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) cells[j * w + i] = inside(x0 + i + 0.5, y0 + j + 0.5) || 0;
  const at = (i, j) => (i < 0 || j < 0 || i >= w || j >= h ? 0 : cells[j * w + i]);
  for (let j = 0; j < h; j++)
    for (let i = 0; i < w; i++) {
      const c = cells[j * w + i];
      if (c) p.px(x0 + i, y0 + j, c);
      else if (edge && (at(i - 1, j) || at(i + 1, j) || at(i, j - 1) || at(i, j + 1))) p.px(x0 + i, y0 + j, edge);
    }
}

/** Blink out: true on the frames something near the end of its life should skip (a wink, not a fade). */
export const winks = (u, from, ph) => u > from && Math.sin(u * 40 + ph) < 0;

export { clamp };
