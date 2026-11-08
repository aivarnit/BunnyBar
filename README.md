# BunnyBar 🐇

A tiny pixel-art bunny that lives above your action bar in **World of Warcraft: Forever**.

It hops back and forth on its own little track, blinks, twitches its ears and sometimes takes a nap. You can give it any fur colour, pick its size, and put matching bunny ears on your portrait. That's all it does. It doesn't automate anything, read combat data or touch your action buttons.

**Current version: 0.2.0** · [Download](https://github.com/aivarnit/BunnyBar/releases/latest) · [Release notes](docs/releases/v0.2.0.md)

> **Coming in v0.3 (on `main`, not released yet):** a smoother 8-pose hop, idle behaviours (carrot eating, face washing, ear scratching, stretching, looking around), rare burrowing across the track, five bunny styles (Classic, Devil, Angel, Dragon, Zombie) and hover hearts. See [docs/ANIMATIONS.md](docs/ANIMATIONS.md). These features still need in-game testing on WoW Forever before release.

![The five bunny styles](docs/images/styles.png)

![Animated preview of a full nap: the bunny gets sleepy, yawns, lies down, breathes with drifting z's, twitches an ear, then wakes, stretches and sits up](docs/images/sleep-preview.gif)

![BunnyBar sprite sheet, one animation per row: idle and hopping; getting sleepy and lying down; sleeping breath cycle with ear and nose twitches; waking up](docs/images/sprite-preview.png)

> **Screenshot placeholder:** an in-game capture is still to come. The images above use the actual sprites, the animated one with the addon's real frame timings. The bottom row of the sprite sheet shows fur colours and the portrait ears.

## Features

### The bunny

- **Animated pixel art**: an original 32×32 white bunny with pink inner ears, drawn from code (`scripts/generate_sprites.py`) and rendered with nearest-neighbour filtering so pixels stay crisp.
- **Hops, blinks and ear twitches**: it waits 4–12 seconds, picks a random spot on its track and gets there in a series of small parabolic hops, each in 8 poses (anticipation, push-off, rising, apex, falling, contact, squash, recovery). It faces the way it's going and never teleports. In between, it blinks, twitches its ears and breathes.
- **Naps**: now and then it gets drowsy, yawns, curls up and sleeps, breathing slowly with a rising "z" and the odd ear or nose twitch. Then it wakes, stretches and sits up, with every step drawn as its own frame.
- **Idle behaviours** *(v0.3)*: finds and eats a carrot in three little bites, washes its face, scratches behind an ear, stretches and looks around.
- **Burrowing** *(v0.3)*: once in a while it digs a hole, disappears into it and pops out of a second hole on the other side of its track.
- **Automatic placement**: it sits just above the highest visible bar at the bottom of the screen, whether that's Action Bar 2/3, the XP or reputation bar, or the main action bar.
- **Live repositioning**: it moves by itself, within a fraction of a second, when you toggle action bars, gain or lose the XP bar, change UI scale or edit your layout. No `/reload` needed.
- **Manual positioning**: `/bunny unlock`, drag it anywhere, `/bunny lock`. A dragged position always wins over automatic placement until `/bunny reset`.
- **Unobtrusive**: a click-through decorative frame drawn *below* the action-button layer. It never modifies or anchors to Blizzard's bars and never touches action buttons.

### Customization

- **Native settings panel**: **Esc → Options → AddOns → BunnyBar**, or `/bunny options`. Everything applies instantly, no reload.
- **Five styles** *(v0.3)*: Classic, Devil (horns and a pointed tail), Angel (halo and little wings), Dragon (horns, wings, a spiky tail) and Zombie (patchwork, stitches, a floppy ear). Every style does every animation and takes your fur colour.
- **Behaviour switches** *(v0.3)*: idle animations, carrot eating, burrowing and how often (Rare, Normal or Often).
- **Any fur colour**: a saturation/brightness square, a hue slider, a brightness slider and a hex-code box (for example `#FFB6C1`), plus a live preview and a Reset Color button. Only the fur changes: eyes, nose, pink inner ears, outlines and shading stay the same in every animation frame.
- **Size presets**: Tiny 16, Small 32, Regular 64 (the default for new installs), Large 96 or Huge 128.
- **Custom sizes**: `/bunny size` accepts any whole size from 16 to 128. The panel shows it as "Custom".
- **More knobs**: hop speed, hop interval, track width and hop height, through slash commands.

### Interactions *(v0.3)*

- **Hover hearts**: point at the bunny and little pink hearts float up, even while it sleeps (it won't wake up). Subtle, Normal or Extra; clicks still go through to your action bars.

### Portrait accessories

- **Bunny ears on your portrait** and **on party members' portraits**, as original pixel art.
- **Independent on/off switches** for player and party ears, in the panel or with `/bunny ears`.
- **Fur colour sync**: the ears always match the bunny's fur colour.
- **Edit Mode compatible**: the ears follow portraits you move or resize in Edit Mode and stay in front of the portrait ring. They're purely local and cosmetic, click-through, and never change Blizzard's unit frames.

### Lightweight

No per-frame work while the bunny sits still; updates run only during the ~0.4 s of each hop. Hover hearts check the cursor 4 times a second (20 near the bunny) and animate with WoW's own animation system. No libraries, no network. Each style's textures are about 700 KB uncompressed, but the game only loads the style you use, and the ZIP stays small because transparent pixels compress well. Your settings are saved per account and carried over when you upgrade.

## Installation

1. Download `BunnyBar-<version>.zip` from the [latest release](https://github.com/aivarnit/BunnyBar/releases/latest).
2. Extract it into your WoW Forever AddOns folder so that you end up with `…/AddOns/BunnyBar/BunnyBar.toc`.

| OS | AddOns folder (default install) |
|---|---|
| **Windows** | `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\` |
| **macOS** | `/Applications/World of Warcraft/_forever_/Interface/AddOns/` |

3. Restart the game client completely. `/reload` doesn't always pick up a newly added addon.
4. On the character select screen, open **AddOns** and make sure **BunnyBar** is enabled.

Step-by-step instructions, including how to create a missing `AddOns` folder and how to find the folder via the Battle.net launcher, are in [docs/INSTALLATION.md](docs/INSTALLATION.md).

## Slash commands

| Command | What it does |
|---|---|
| `/bunny` | Show help |
| `/bunny options` | Open the BunnyBar settings panel |
| `/bunny color #FFB6C1` | Fur colour as a hex code; `/bunny color reset` restores the style's default |
| `/bunny style devil` | Style: `classic`, `devil`, `angel`, `dragon`, `zombie` *(v0.3)* |
| `/bunny hearts normal` | Hover hearts: `on`, `off`, `subtle`, `normal`, `extra` *(v0.3)* |
| `/bunny burrow rare` | Burrowing: `on`, `off`, `rare`, `normal`, `often` *(v0.3)* |
| `/bunny idle off`, `/bunny carrot off` | Idle behaviours / carrot eating on or off *(v0.3)* |
| `/bunny show` | Show the bunny |
| `/bunny hide` | Hide the bunny (all animation stops) |
| `/bunny lock` | Lock the position (click-through) |
| `/bunny unlock` | Highlight the track and allow dragging |
| `/bunny reset` | Restore all default settings and position |
| `/bunny size 64` | Sprite size, 16–128. Presets: 16, 32, 64 (default), 96, 128 |
| `/bunny ears player off` | Turn portrait ears `on`/`off` for `player` or `party` |
| `/bunny speed 1.0` | Hop speed multiplier, 0.25–4 (default 1.0) |
| `/bunny interval 8` | Average seconds between hops, 2–120 (default 8) |
| `/bunny width 480` | Track width, 64–2000 (default 480) |
| `/bunny height 16` | Hop height, 0–64 (default 16) |
| `/bunny test` | Hop right now (a napping bunny wakes up first) |
| `/bunny test carrot` | Try a behaviour now: `carrot`, `wash`, `scratch`, `stretch`, `look`, `burrow`, `nap`, `hearts` *(v0.3)* |
| `/bunny stats` | Status, hop counters and performance info |
| `/bunny bars` | Show which bottom bars were detected and which one the bunny sits on |

`/bunnybar` works as an alias. A numeric command with no value, such as `/bunny size`, prints the current value. Full reference: [docs/COMMANDS.md](docs/COMMANDS.md).

## Compatibility

| | |
|---|---|
| Game | World of Warcraft: Forever (client 1.60.x) |
| TOC `## Interface` | `16001` |
| Platforms | Windows, macOS (Apple Silicon and Intel) |
| Dependencies | none |

WoW Forever runs on the modern (Midnight-era, 12.1.x) client and API, *not* the Classic Era API. BunnyBar uses long-standing frame, texture and timer APIs (`CreateFrame`, `SetTexture`, `SetTexCoord`, `SetVertexColor`, `C_Timer`), plus the modern `Settings` API for its options panel. Every optional API is guarded, with a fallback.

**Verification status:** v0.2.0 has been tested in WoW Forever by the maintainer. That covers the bunny, naps, automatic and live placement, the options panel, colours, size presets and the portrait ears, including after Edit Mode moves. Every build also passes the offline checks in CI. BunnyBar is **designed and tested for WoW Forever only**. Retail, Classic and other clients have not been tested. The interface number and folder paths come from community sources published around the 4 November 2026 launch. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#compatibility-research) for sources and assumptions. If the client shows BunnyBar as *out of date*, a patch has probably raised the interface number. Tick **Load out of date AddOns** or open an issue.

## Performance

BunnyBar is designed to cost effectively nothing on a 2020 M1 MacBook Air:

- **Idle, napping and between hops:** no `OnUpdate` script at all. State changes and animation frames are scheduled with `C_Timer`: a few per minute while idle, and roughly 2 per second while asleep.
- **During a hop:** a single `OnUpdate` runs for ~0.4 s and is removed on landing. At default settings that's roughly 3–6 % of wall time.
- **Allocations:** no tables or closures are created per frame.
- **Hidden:** `/bunny hide`, or hiding the UI with Alt+Z, cancels every timer and update.
- **No** network, event polling, combat-log access or debug logging.

**Checking it yourself:** type `/bunny stats`. It reports how often per-frame updates were active, the addon's memory use, and the client's per-addon CPU average where the client exposes it (`C_AddOnProfiler`). For an A/B test, compare your frame rate with `/bunny hide` and `/bunny show`, or disable BunnyBar in the AddOns list.

## Development

Requirements: Python 3.9+ (standard library only) and LuaJIT or Lua 5.1 for the Lua checks (`brew install luajit` on macOS).

```sh
python3 scripts/generate_sprites.py            # regenerate textures + docs/images/sprite-preview.png
python3 scripts/validate.py -v                 # all static checks + offline Lua test-suite
python3 -m unittest discover -s tests -v       # tooling tests (incl. negative tests)
luajit tests/lua/run_tests.lua                 # offline Lua tests against a WoW API mock
python3 scripts/package.py                     # build + verify dist/BunnyBar-<version>.zip
```

To try your working copy in game, symlink the addon folder into your AddOns directory:

```sh
# macOS
ln -s "$PWD/addon/BunnyBar" "/Applications/World of Warcraft/_forever_/Interface/AddOns/BunnyBar"
```

```bat
:: Windows (cmd, as administrator)
mklink /D "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\BunnyBar" "%CD%\addon\BunnyBar"
```

The code layout and state machine are described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Releasing

1. Bump `## Version:` in `addon/BunnyBar/BunnyBar.toc`.
2. Add release notes as `docs/releases/v<version>.md`. The tests require this file for the current TOC version.
3. Commit, then create an annotated tag and push it: `git tag -a v0.2.1 -m "BunnyBar v0.2.1" && git push origin v0.2.1`.
4. The [release workflow](.github/workflows/release.yml) validates, builds and verifies the ZIP, writes a SHA-256 checksum, and publishes a GitHub Release with those notes. It only publishes if every step passes and the tag matches the TOC version. Afterwards it downloads the published ZIP and checks it again.

## Known limitations

- **WoW Forever only.** Other clients (Retail, Classic Era, …) are untested. If a Forever patch raises the interface number, the AddOns list may show BunnyBar as *out of date* until an update: tick **Load out of date AddOns**.
- **Portrait ears** need Blizzard's default unit frames. Raid-style party frames have no portraits, so no ears appear there. Replacement unit frame addons aren't supported yet.
- **Very small sizes:** at 16 the 32-pixel art is scaled down 2×, so single-pixel details (eye shine, mouth) can drop out. Sizes 32, 64, 96 and 128 are whole multiples of the art (1×, 2×, 3×, 4×), so they're pixel-exact at UI scale 1.
- **Automatic placement and portrait ears look for Blizzard's default frames.** Replacement action bar or unit frame addons aren't supported. If BunnyBar finds no bottom bar, it falls back to 100 units above the bottom of the screen. `/bunny bars` and `/bunny ears debug` show what was detected, and you can always drag the bunny with `/bunny unlock`.
- **In Edit Mode**, the ears catch up with a dragged portrait when you release the mouse, not continuously while dragging.
- Placement reacts within about 0.2 s to bars being shown or hidden, to Edit Mode or the Settings panel closing, and to layout events, then re-checks briefly while Blizzard's layout settles. A bar that changes *size* with none of these happening (rare) is picked up on the next one, or on `/reload`.
- Bars that are off to the side, outside the bunny's track, are deliberately ignored.
- The bunny sits on the frame layer *below* action buttons, so if you overlap it with a bar, the buttons win.
- Settings are account-wide. There are no per-character profiles.

## Contributing

Issues and pull requests are welcome.

- Keep it dependency-free and cheap: no per-frame work while idle and no new polling.
- Run `python3 scripts/validate.py` and `python3 -m unittest discover -s tests` before opening a PR. CI runs the same checks.
- New art should come from `scripts/generate_sprites.py` (commit the regenerated `.tga` files too). Please don't submit sprites from other games.
- If you've tested in game, say so in the PR, along with your client build and OS.

## License

[MIT](LICENSE) © 2026 Anthony Varnit. The sprites are original work generated by this repository and are covered by the same license.

*World of Warcraft is a trademark of Blizzard Entertainment, Inc. BunnyBar is an unofficial fan project, not affiliated with or endorsed by Blizzard.*
