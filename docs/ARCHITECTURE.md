# BunnyBar architecture

## Compatibility research

Research was done on 7 November 2026, three days after WoW Forever launched on 4 November 2026. No official Blizzard developer documentation for Forever's addon API was found. The facts below come from community sources that agree with each other, but **they have not been confirmed in game by this project**.

| Topic | Finding | Confidence |
|---|---|---|
| Client / interface | Client 1.60.1, TOC `## Interface: 16001` | Consistent across several sources (Warcraft Wiki TOC table as cited by guides, CurseForge game-version filter, launch addon lists) |
| API family | Modern Mainline API (Midnight-era, reported as 12.1.5), **not** Classic Era | Several guides, quoting Blizzard ("the vast majority of APIs available in 12.1.5") |
| Restrictions | Midnight addon restrictions apply. In combat, many unit values are *secret values*: they can be displayed but not compared or used in arithmetic. `COMBAT_LOG_EVENT_UNFILTERED` is unavailable. Blocked protected calls can fail silently. | Several guides |
| Lua | Modified Lua 5.1: no `goto`, `//`, bitwise operators or `_ENV`. No `require`, `io` or `os`. The TOC is the module loader. | Standard for all WoW clients |
| AddOns folder | `World of Warcraft/_forever_/Interface/AddOns` (beta: `_classic_beta_`) | Add-on managers and guides. Not stated in any Blizzard post that was found. |
| TOC suffixes | `_Forever.toc` / `_Camelot.toc` reportedly supported for multi-client addons | Single source. Not used by BunnyBar. |
| Action bar frame names | Unknown for Forever. Modern clients use `MainActionBar` (older: `MainMenuBar`) plus `MultiBarBottomLeft/Right`. | **Unverified.** Treated as optional. |
| SavedVariables | Standard. Ready at `ADDON_LOADED`. An early-beta restore bug was reportedly fixed in build 70009. | Guides |

Sources:
[ForeverMeta addon guide](https://forevermeta.me/en/guides/wow-forever-addons-interface),
[WoW Forever Guides developer page](https://wowforeverguides.com/addons/developers),
[MMOnster install guide](https://mmonster.co/wow-forever/guides/addons/install),
[Timesaver launch addon list](https://timesaver.gg/blog/wow-forever-addons-save-beta-ui-before-launch),
[WoW Forever Addons folder article](https://wowforeveraddons.com/articles/wow-forever-addons-folder).

### Design consequences

1. **Depend only on stable, unrestricted APIs:** `CreateFrame`, textures, font strings, `SetPoint`, `C_Timer`, `GetTime`, frame drag, and SavedVariables. BunnyBar reads no unit, spell, aura or combat data, so secret values and combat-log restrictions don't affect its core.
2. **No protected frames are touched.** The bunny is an independent `Frame` parented to `UIParent`. It is never anchored *to* an action bar and never hooks or modifies one, so combat lockdown can't block it, and it can't taint Blizzard's secure action buttons.
3. **The action bar is only read, and the read is guarded.** Placement reads `IsVisible`/`GetTop`/`GetCenter` from the candidate bars inside `pcall`, rejects secret values via `issecretvalue` (when that function exists), and falls back to a fixed screen offset. Reading happens at login, after Edit Mode layout changes, after UI scale changes and on `/bunny reset`. It never polls.
4. **Optional APIs are feature-detected:** `C_AddOnProfiler`, the memory functions, and the layout events (registered with `pcall`, since registering an unknown event raises an error).

## Files

```text
addon/BunnyBar/
├── BunnyBar.toc     metadata + load order
├── Util.lua         pure functions (no WoW API): math, parsing, validation
├── Config.lua       defaults, limits, SavedVariables sanitising, slash commands
├── Animation.lua    the frame, sprite poses, state machine, placement, stats
├── Core.lua         event wiring (ADDON_LOADED, PLAYER_LOGIN, layout events)
└── Textures/        generated 32x32-frame sprite strips (TGA, 32-bit BGRA)
scripts/
├── generate_sprites.py   pixel art -> TGA + PNG preview (stdlib only)
├── validate.py           static checks + runs the Lua test-suite
└── package.py            reproducible ZIP build + verification
tests/
├── lua/wow_mock.lua      minimal WoW API mock with a controllable clock
├── lua/run_tests.lua     offline behaviour tests (Lua 5.1 / LuaJIT)
└── test_static.py        tooling tests incl. negative cases (unittest)
```

Every Lua file starts with `local addonName, ns = ...` and shares state only through the private `ns` table. The only globals are `BunnyBarDB` (SavedVariables), `SLASH_BUNNYBAR1/2`, `SlashCmdList.BUNNYBAR` and the frame name `BunnyBarFrame` (named so `/fstack` can identify it). The test-suite fails if any other global is written.

## Frame layout

```text
UIParent
└── BunnyBarFrame  (strata LOW, width = track width, height = size + hop height)
    ├── backdrop   (blue, only while unlocked)
    ├── label      (hint text, only while unlocked)
    └── sprite     (size x size texture, BOTTOMLEFT offset = (x, y))
```

- The frame is click-through (`EnableMouse(false)`) while locked, so it can never block clicks on anything beneath it.
- Strata `LOW` keeps it under action buttons (`MEDIUM`) in case of overlap.
- `x` runs from `0` to `trackWidth - size`. `y` is the hop height above the frame's bottom edge.
- Facing left is done by swapping the left and right texture coordinates, so no mirrored art is needed.
- Textures use `SetTexture(file, "CLAMP", "CLAMP", "NEAREST")` for crisp pixels.

## State machine

```text
          ┌──────── interval × U(0.5, 1.5) ────────┐
          ▼                                         │
 ┌──── idle ───(sleepChance, never twice)──► sleep ─┘ (10–25 s, breathing frames)
 │  (blink / twitch / breathe fidgets on a separate timer)
 │
 └─► journey to random destination (≥ one sprite width away, inside bounds)
        prep (0.14 s) ─► air (hopDuration, OnUpdate) ─► land (0.12 s)
          ▲                                                 │
          └──── between (0.08 s) ◄── not there yet ─────────┤
                                                            └─► idle
```

All durations except naps and fidgets are divided by `speed`. Each hop covers at most `max(8, 1.5 × size)` units horizontally (48 at the default size), so a long journey is several small hops rather than one huge leap.

**The arc:** horizontal position is linear in time and height is `4·h·t·(1−t)`, which is a true ballistic parabola peaking at `hopHeight` when `t = 0.5`. Large frame-time spikes are clamped at `t = 1`, so the bunny lands exactly on its target.

**Timers:** at most two `C_Timer` handles exist at any time: `actionTimer` (state transitions) and `poseTimer` (idle fidgets). Every callback is a file-level function, so nothing allocates per frame.

**Pausing:** `OnHide` calls `Stop()`, which cancels both timers, removes the `OnUpdate` script, finishes any hop in progress and puts the bunny on the ground. `OnShow` calls `Start()`. This covers `/bunny hide`, Alt+Z, cinematics, and anything else that hides `UIParent`.

## SavedVariables

`BunnyBarDB` (account-wide). On `ADDON_LOADED`, `Config.Sanitize` rebuilds it:

- Unknown keys are dropped and missing keys are filled from `DEFAULTS`.
- Numbers are clamped to `LIMITS` and integer settings are rounded. NaN, ±inf and wrong types are replaced with defaults.
- Position is all-or-nothing. An invalid anchor name or a non-finite offset resets it to automatic placement.

A dragged position is stored as `BOTTOM` → `UIParent BOTTOM` with an x offset from the screen centre, which tolerates resolution and UI-scale changes. `SetUserPlaced(false)` is called after a drag so the client's own layout cache doesn't compete with ours.

## Testing strategy

| Layer | Tool | What it proves |
|---|---|---|
| Static | `scripts/validate.py` | TOC metadata and references (exact-case), no unlisted Lua, Lua 5.1 syntax (via LuaJIT/lua5.1), no 5.2+ syntax, no forbidden APIs (`print`, `io`, `os`, `hooksecurefunc`, combat log, secure templates), TGA format/size/frames/transparency, sprites match the generator |
| Offline behaviour | `tests/lua/run_tests.lua` + `wow_mock.lua` | Loads the real addon files in TOC order. Covers defaults, sanitising, slash parsing and validation, 10 simulated minutes of movement (bounds, ≤ 2.5 units per frame, facing, naps, idle waits ≥ 4 s, `OnUpdate` only while airborne, < 15 % of frames), hide/show/Alt+Z pausing, drag and save, reset, placement heuristics (secret values, erroring APIs, bars at the top), unknown events, global leaks |
| Tooling | `tests/test_static.py` | Validators catch broken inputs (negative tests). Packaging is reproducible and verification catches a wrong root, missing files and junk files. Every command is documented. |
| **In game** | manual, see below | **Not yet done.** This is the only layer that proves real compatibility. |

The mock implements only the methods BunnyBar calls, and raises an error for anything else. It can't prove that a method exists in the real client, only that the addon is internally consistent.

## Manual in-game test checklist

Run these in WoW Forever and note the client build (shown on the login screen):

1. The addon appears in the AddOns list and isn't marked out of date.
2. Log in with no Lua errors (`/console scriptErrors 1` to show them).
3. The bunny appears just above the main action bar, centred. Check `/fstack` over the bar and record the bar's frame name.
4. The sprite is crisp, not blurry, at UI scale 1 and at another scale.
5. Within about 15 s it hops. The arc is smooth, it faces its direction of travel, and it lands cleanly.
6. Watch for a nap (or force one by waiting) and check the `z` frames.
7. Run every command in [COMMANDS.md](COMMANDS.md), including the invalid inputs.
8. Unlock, drag, lock, `/reload`: the position persists. `/bunny reset` brings it back above the bar.
9. Hide and show the UI with Alt+Z. Enter and leave combat. Use Edit Mode and move the action bar: there should be no errors and no "Interface action failed because of an AddOn" messages.
10. Clicking action buttons right under the bunny still works.
11. `/bunny stats` prints memory and CPU figures (or says they're not available).
12. Optional: compare FPS on an M1 MacBook Air with `/bunny hide` and `/bunny show`.
