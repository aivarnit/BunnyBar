# BunnyBar 🐇

A tiny pixel-art bunny that lives above your action bar in **World of Warcraft: Forever**.

It hops back and forth on its own little track, blinks, twitches its ears and sometimes takes a nap. That's all it does. It doesn't automate anything, read combat data or touch your action buttons.

![BunnyBar sprite sheet: idle, blink, ear twitch, breathe, hop preparation, jump, landing, and two sleeping frames](docs/images/sprite-preview.png)

> **Screenshot / GIF placeholder:** an in-game capture is still to come. The image above shows the actual sprites at 8× zoom.

## Features

- **Original pixel art**: a 32×32 white bunny with pink inner ears, drawn from code (`scripts/generate_sprites.py`) and rendered with nearest-neighbour filtering so pixels stay crisp.
- **Natural movement**: it waits 4–12 seconds, picks a random spot on its track and gets there in a series of small parabolic hops (crouch, jump, land). It faces the way it's going and never teleports.
- **Idle life**: blinking, ear twitches and breathing, plus an occasional nap with drifting "z"s.
- **Unobtrusive**: an independent, click-through decorative frame drawn *below* the action-button layer. It never modifies, hooks or overlaps protected frames.
- **Configurable**: size, speed, hop interval, track width and hop height. You can drag it anywhere, and settings are saved per account.
- **Lightweight**: no per-frame work while sitting still. Updates run only during the ~0.4 s of each hop. No libraries, no network, under 40 KB of textures.

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
| `/bunny show` | Show the bunny |
| `/bunny hide` | Hide the bunny (all animation stops) |
| `/bunny lock` | Lock the position (click-through) |
| `/bunny unlock` | Highlight the track and allow dragging |
| `/bunny reset` | Restore all default settings and position |
| `/bunny size 32` | Sprite size, 16–128 (default 32) |
| `/bunny speed 1.0` | Hop speed multiplier, 0.25–4 (default 1.0) |
| `/bunny interval 8` | Average seconds between hops, 2–120 (default 8) |
| `/bunny width 480` | Track width, 64–2000 (default 480) |
| `/bunny height 16` | Hop height, 0–64 (default 16) |
| `/bunny test` | Hop right now (also wakes a sleeping bunny) |
| `/bunny stats` | Status, hop counters and performance info |

`/bunnybar` works as an alias. A numeric command with no value, such as `/bunny size`, prints the current value. Full reference: [docs/COMMANDS.md](docs/COMMANDS.md).

## Compatibility

| | |
|---|---|
| Game | World of Warcraft: Forever (client 1.60.x) |
| TOC `## Interface` | `16001` |
| Platforms | Windows, macOS (Apple Silicon and Intel) |
| Dependencies | none |

WoW Forever runs on the modern (Midnight-era, 12.1.x) client and API, *not* the Classic Era API. BunnyBar uses only long-standing frame, texture and timer APIs (`CreateFrame`, `SetTexture`, `SetTexCoord`, `C_Timer`), and guards every optional API.

**Verification status:** BunnyBar has passed static and offline checks only. It has **not yet been run inside WoW Forever**. The interface number and folder paths come from community sources published around the 4 November 2026 launch. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#compatibility-research) for sources and assumptions. If the client shows BunnyBar as *out of date*, a patch has probably raised the interface number. Tick **Load out of date AddOns** or open an issue.

## Performance

BunnyBar is designed to cost effectively nothing on a 2020 M1 MacBook Air:

- **Idle, sleeping and between hops:** no `OnUpdate` script at all. State changes are scheduled with `C_Timer`, a few per minute.
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
2. Commit, then tag and push: `git tag v0.1.1 && git push origin v0.1.1`.
3. The [release workflow](.github/workflows/release.yml) validates, builds and verifies the ZIP. It publishes a GitHub Release only if every step passes and the tag matches the TOC version.

## Known limitations

- **Not yet tested in game.** Everything is checked offline against a mock of the WoW API. See the manual checklist in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#manual-in-game-test-checklist).
- **Automatic placement is a heuristic.** BunnyBar looks for `MainActionBar`, `MainMenuBar` and the bottom multi-bars and sits on top of the highest visible one. If the frames have other names on Forever, or your bars are somewhere unusual, it falls back to 100 units above the bottom of the screen. Use `/bunny unlock` to drag it into place.
- It re-checks placement after Edit Mode layout changes, but not continuously. Toggling a bar's visibility outside Edit Mode won't move the bunny until `/bunny reset` or a reload.
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
