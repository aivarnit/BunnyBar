# Style special effects (PixelFX)

The five style specials' **effects** (sparkles, flame, feathers, fire, wisps) are drawn with
[PixelFX](https://github.com/patch-gg/pixelfx), a code-driven pixel-art effects toolkit (MIT, by Patch, after
Hugo Duprez's Sprite Fusion VFX). It's used **at development time only**:
- Nothing in this folder ships in the addon ZIP.
- The addon has no JavaScript, no runtime renderer and no network access.
- In game, BunnyBar only flips pre-rendered TGA frames on its existing `C_Timer`.

The **bunny's own acting** in each special (raising the carrot, conjuring, floating, sneezing, watching the wisps)
is not PixelFX. It's drawn by `scripts/generate_sprites.py` from the same pose data as every other animation, so
your fur colour applies.

## Files

| File | What it is |
|---|---|
| `effects/*.js` | The five effects, BunnyBar's own code (MIT), written against PixelFX's effect contract. `_bunny.js` holds shared helpers. |
| `timeline.json` | **Generated** by `generate_sprites.py`: canvas, origin, sample times, the angel's lift and anchor points (paw, mouth, halo…), all computed from the poses. |
| `<style>.png` | **PixelFX export**: back-layer frames in the top row, front-layer frames in the bottom row, 48 × 48 each, transparent. |
| `<style>.json` | **PixelFX export**: frame rectangles and sample times. |
| `LICENSE-pixelfx.txt` | PixelFX's MIT licence and notices. |

| Style | Effect | Frames |
|---|---|---|
| classic | `carrot-celebration` | 21 |
| devil | `mischievous-flame` | 21 |
| angel | `heavenly-blessing` | 25 |
| dragon | `fire-sneeze` | 18 |
| zombie | `haunted-wisps` | 23 |

## Canvas

48 × 48 px at the bunny's own scale, so every detail is 1 px and readable at the Small (32) preset.

- **Local origin:** (0, 0) is the floor under the centre of the bunny's 32 × 32 frame, at canvas (24, 46). The bunny's frame covers x −16…16 and y −30…2.
- **Reach:** effects may go 16 px above the frame and 8 px to either side, but never below the feet. The validator checks that each frame's bottom row is empty, so effects can't cover action buttons.
- **Glow:** baked in at strength 0.55. The converter drops pixels with alpha below 32 so the result stays crisp over any background.

## Rebuilding

Node.js 18+ and a PixelFX checkout are needed. By default the checkout is `../pixelfx`; you can also pass a path
or set `PIXELFX_DIR`. No npm packages are needed.

```sh
git clone https://github.com/patch-gg/pixelfx ../pixelfx
python3 scripts/generate_sprites.py      # 1. timeline.json from the poses
node scripts/pixelfx_export.mjs          # 2. syncs effects/ into ../pixelfx/src/fx/bunnybar/, renders <style>.png/.json
python3 scripts/generate_sprites.py      # 3. Textures/<style>/bunny-special-fx.tga + docs/images/special-<style>.gif
```

The export also copies the effects into the PixelFX checkout, so PixelFX's own tools work on them:

```sh
cd ../pixelfx
node tools/check.mjs "bunnybar/*"                       # validation: canvas bounds, ends empty, determinism, speed
node tools/render.mjs bunnybar/fire-sneeze --all        # contact sheet: records/bunnybar/fire-sneeze/contact.png
```

CI doesn't need Node. `generate_sprites.py --check` and the tests verify the committed export against the timeline
and the shipped textures against the export.

## How they were made

PixelFX's method: find references, draft, render, look, refine, check.

- **References**, rendered and studied:
  - `pickups/collect-burst`: twinkles that brake and wink out.
  - `fire/candle` and `shadow/necro-skulls`: flame heat layering; an orbit with a far half behind the character.
  - `holy/feather-burst` and `holy/halo`: feathers rocking as they sink; halo light.
  - `fire/fire-breath`: a cone of flame cooling to smoke.
  - `shadow/curse` and `fire/spirit-flame`: ghostly wisps.

  Nothing was copied wholesale. Each effect is original and sized for a 32 px bunny.
- **Simulation:** the dragon's burst uses PixelFX's simulated particles (`FIRE`, `SPARK`, `EMBER`, from Sprite Fusion's MIT code). The other four are pure functions of time.
- **Inspection:** three passes, each judged on contact sheets that put the bunny's real poses and the effect together at the real timing.
  - The devil's flame was moved off the face.
  - The angel's floor ring became lift-off dust, and its feathers were redrawn.
  - The zombie's wisps got a ghost-flame shape with trails, so they no longer read as sparkles.
  - The dragon's burst was shrunk to stay on the canvas, and its smoke thinned so it dissolves instead of popping.
- **Validation:** all five pass PixelFX's `tools/check.mjs` with no warnings.

Tested with PixelFX 0.3.0 (commit `a841596`, 2026-10-31).
