# BunnyBar slash commands

All commands start with `/bunny`, or the alias `/bunnybar`. Command words aren't case-sensitive. Settings are saved automatically in the `BunnyBarDB` SavedVariable, which is account-wide.

## General

| Command | Effect |
|---|---|
| `/bunny` or `/bunny help` | Print the command list. |
| `/bunny show` | Show the bunny and resume animation. |
| `/bunny hide` | Hide the bunny. All timers and updates stop while it's hidden. |
| `/bunny lock` | Lock the position. The frame becomes click-through again. |
| `/bunny unlock` | Show a translucent blue track that you can drag with the left mouse button. |
| `/bunny reset` | Restore **all** settings to their defaults, return to automatic placement above the action bar, and re-centre the bunny. |
| `/bunny test` | Hop now. Wakes the bunny if it's asleep. Does nothing if it's already hopping. |
| `/bunny stats` (alias `status`) | Print state, hop/nap counters, the share of time per-frame updates were active, memory use, and per-addon CPU time (if the client exposes it). |

## Numeric settings

Run one without a value to print the current setting and its allowed range, for example `/bunny size`.

| Command | Range | Default | Meaning |
|---|---|---|---|
| `/bunny size 32` | 16–128, whole numbers | 32 | Sprite size in UI units. The art is 32×32 pixels, so 32, 64 and 96 give the sharpest results at UI scale 1. |
| `/bunny speed 1.0` | 0.25–4 | 1.0 | Animation speed multiplier. At 2.0 a hop takes 0.2 s instead of 0.4 s. It doesn't change how often the bunny hops. |
| `/bunny interval 8` | 2–120 | 8 | *Average* seconds between hop journeys. Each wait is random, between 50 % and 150 % of this value (default 4–12 s). |
| `/bunny width 480` | 64–2000, whole numbers | 480 | Width of the horizontal track the bunny roams. |
| `/bunny height 16` | 0–64, whole numbers | 16 | Peak height of each hop. Use 0 for a bunny that only shuffles along. |

### Input validation

Values must be plain decimal numbers. Hex (`0x20`), exponents (`1e2`), `nan` and `inf` are rejected. Out-of-range values aren't clamped either: the command is refused, nothing changes, and a message explains why.

```text
/bunny size 12      → BunnyBar: Size must be between 16 and 128.
/bunny size 33.5    → BunnyBar: Size must be a whole number (16 to 128).
/bunny speed fast   → BunnyBar: 'fast' is not a number. Use 0.25 to 4.
/bunny dance        → BunnyBar: unknown command 'dance'. Type /bunny for help.
```

## Positioning tips

- **Automatic placement**, the default, puts the track's bottom edge 2 units above the highest visible bottom action bar and centres it on the main bar. It updates when you save an Edit Mode layout or change the UI scale.
- Once you drag the track, its position is stored relative to the bottom centre of the screen, so it stays sensible across resolution and UI-scale changes. Automatic placement is off from then on, until you run `/bunny reset`.
- The frame is clamped to the screen, so you can't lose it off the edge.
