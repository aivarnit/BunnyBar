# BunnyBar slash commands

All commands start with `/bunny`, or the alias `/bunnybar`. Command words aren't case-sensitive. Settings are saved automatically in the `BunnyBarDB` SavedVariable, which is account-wide.

## General

| Command | Effect |
|---|---|
| `/bunny` or `/bunny help` | Print the command list. |
| `/bunny options` (aliases `config`, `settings`) | Open **Esc → Options → AddOns → BunnyBar**. In combat it opens as soon as combat ends. |
| `/bunny color #RRGGBB` (alias `colour`) | Set the fur colour, for example `#FFB6C1` (pink), `#87CEEB` (sky blue) or `#000000`. The `#` is optional and case doesn't matter. Invalid values are rejected and the colour stays as it was. `/bunny color reset` restores the original (`#F6F3FA`); `/bunny color` on its own prints the current value. |
| `/bunny ears player on\|off`, `/bunny ears party on\|off` | Show or hide bunny ears on your portrait or on party portraits. `/bunny ears` on its own prints the current state. |
| `/bunny show` | Show the bunny and resume animation. |
| `/bunny hide` | Hide the bunny. All timers and updates stop while it's hidden. |
| `/bunny lock` | Lock the position. The frame becomes click-through again. |
| `/bunny unlock` | Show a translucent blue track that you can drag with the left mouse button. |
| `/bunny reset` | Restore **all** settings to their defaults, return to automatic placement above the action bar, and re-centre the bunny. |
| `/bunny test` | Hop now. A napping bunny gets up first: from deep sleep it plays the wake-up (about 0.9 s), and if it's still lying down it rises back up. Does nothing if it's already hopping. |
| `/bunny bars` | Print where automatic placement put the bunny, and the status of every bar it checks: `visible` (with its top edge), `hidden`, `empty` (an XP/rep container with no bar showing), `off track`, `not at bottom`, `no geometry` and so on. Also lists frame names that don't exist on your client, how many frames are watched for live updates, and what last triggered a re-placement. |
| `/bunny stats` (alias `status`) | Print state, hop/nap counters, the share of time per-frame updates were active, memory use, and per-addon CPU time (if the client exposes it). |

## Numeric settings

Run one without a value to print the current setting and its allowed range, for example `/bunny size`.

| Command | Range | Default | Meaning |
|---|---|---|---|
| `/bunny size 64` | 16–128, whole numbers | 64 (32 for installs from v0.1) | Sprite size in UI units. The options panel offers the presets Tiny 16, Small 32, Regular 64, Large 96 and Huge 128. Any other whole size works here and shows as **Custom** in the panel. The art is 32×32 pixels, so 32, 64, 96 and 128 (whole multiples) are the sharpest at UI scale 1. |
| `/bunny speed 1.0` | 0.25–4 | 1.0 | Animation speed multiplier. At 2.0 a hop takes 0.2 s instead of 0.4 s. It doesn't change how often the bunny hops. |
| `/bunny interval 8` | 2–120 | 8 | *Average* seconds between hop journeys. Each wait is random, between 50 % and 150 % of this value (default 4–12 s). |
| `/bunny width 480` | 64–2000, whole numbers | 480 | Width of the horizontal track the bunny roams. |
| `/bunny height 16` | 0–64, whole numbers | 16 | Peak height of each hop. Use 0 for a bunny that only shuffles along. |

### Input validation

Values must be plain decimal numbers. Hex (`0x20`), exponents (`1e2`), `nan` and `inf` are rejected. Out-of-range values aren't clamped either: the command is refused, nothing changes, and a message explains why.

```text
/bunny size 12      → BunnyBar: Size must be between 16 and 128.
/bunny color pink   → BunnyBar: 'pink' is not a colour. Use six hex digits, e.g. #FFB6C1.
/bunny size 33.5    → BunnyBar: Size must be a whole number (16 to 128).
/bunny speed fast   → BunnyBar: 'fast' is not a number. Use 0.25 to 4.
/bunny dance        → BunnyBar: unknown command 'dance'. Type /bunny for help.
```

## Positioning tips

- **Automatic placement**, the default, puts the track's bottom edge 2 units above the highest visible bar under the track: Action Bars 2/3 (or 6–8 if you put them at the bottom), the XP or reputation bar, or the main action bar. The track is centred on the main action bar.
- It updates automatically, within about a quarter of a second, when a bar is shown or hidden (for example when you toggle Action Bar 2, or the XP bar disappears at the level cap), when an Edit Mode layout changes, when the UI scale or window size changes, and on login or reload.
- Once you drag the track, its position is stored relative to the bottom centre of the screen, so it stays sensible across resolution and UI-scale changes. Automatic placement is off from then on, until you run `/bunny reset`.
- The frame is clamped to the screen, so you can't lose it off the edge.
