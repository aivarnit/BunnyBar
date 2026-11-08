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
| Bottom bar frame names | Unknown for Forever. See [Frame names to verify](#frame-names-to-verify-in-game). | **Unverified.** Every name is optional. |
| SavedVariables | Standard. Ready at `ADDON_LOADED`. An early-beta restore bug was reportedly fixed in build 70009. | Guides |

Sources:
[ForeverMeta addon guide](https://forevermeta.me/en/guides/wow-forever-addons-interface),
[WoW Forever Guides developer page](https://wowforeverguides.com/addons/developers),
[MMOnster install guide](https://mmonster.co/wow-forever/guides/addons/install),
[Timesaver launch addon list](https://timesaver.gg/blog/wow-forever-addons-save-beta-ui-before-launch),
[WoW Forever Addons folder article](https://wowforeveraddons.com/articles/wow-forever-addons-folder).

### Design consequences

1. **Depend only on stable, unrestricted APIs:** `CreateFrame`, textures, font strings, `SetPoint`, `C_Timer`, `GetTime`, frame drag, and SavedVariables. BunnyBar reads no unit, spell, aura or combat data, so secret values and combat-log restrictions don't affect its core.
2. **No protected frames are modified.** The bunny is an independent `Frame` parented to `UIParent`. It is never anchored *to* a Blizzard bar, and it never calls a method that changes one, so combat lockdown can't block it. Action buttons are never touched.
3. **Bars are only read, and every read is guarded.** Placement reads `IsVisible`, `GetLeft`, `GetRight`, `GetBottom`, `GetTop` and `GetEffectiveScale` (core `Region` methods) inside `pcall`, rejects secret and non-finite values, and falls back to a fixed screen offset.
4. **Visibility changes are observed, not polled.** `HookScript("OnShow"/"OnHide")` adds a post-hook to each candidate bar, and to the bars inside the XP/rep containers. This doesn't replace Blizzard's handler. The hook only requests a deferred refresh, and `HookScript` is called through `pcall`.
5. **Optional APIs are feature-detected:** `C_AddOnProfiler`, the memory functions, and the layout events (registered with `pcall`, since registering an unknown event raises an error).

## Files

```text
addon/BunnyBar/
├── BunnyBar.toc     metadata + load order
├── Util.lua         pure functions (no WoW API): math, parsing, validation
├── Config.lua       defaults, limits, SavedVariables sanitising, slash commands
├── Placement.lua    automatic placement above the highest visible bottom bar
├── Animation.lua    the frame, sprite poses, state machine, ApplyPosition, stats
├── Core.lua         event wiring (ADDON_LOADED, PLAYER_LOGIN, layout events)
└── Textures/        generated 32x32-frame sprite strips (TGA, 32-bit BGRA,
                     padded to power-of-two widths)
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
 ┌──── idle ───(sleepChance, never twice)──► nap ───┘ (drowsy → lie down → sleep 10–25 s → wake; see Naps)
 │  (blink / twitch / breathe fidgets on a separate timer)
 │
 └─► journey to random destination (≥ one sprite width away, inside bounds)
        prep (0.14 s) ─► air (hopDuration, OnUpdate) ─► land (0.12 s)
          ▲                                                 │
          └──── between (0.08 s) ◄── not there yet ─────────┤
                                                            └─► idle
```

Hop-related durations are divided by `speed`; nap and fidget timings are not. Each hop covers at most `max(8, 1.5 × size)` units horizontally (48 at the default size), so a long journey is several small hops rather than one huge leap.

**The arc:** horizontal position is linear in time and height is `4·h·t·(1−t)`, which is a true ballistic parabola peaking at `hopHeight` when `t = 0.5`. Large frame-time spikes are clamped at `t = 1`, so the bunny lands exactly on its target.

### Naps

A nap is a chain of multi-frame sequences, defined as `{ pose, seconds }` lists in `Bunny.SEQUENCES` and played by a small timer-driven sequence player:

| Phase | State | Frames | Duration |
|---|---|---|---|
| Getting sleepy | `drowsy` | heavy eyelids → yawn → nodding off | 0.74 s |
| Lying down | `liedown` | 4 frames interpolated from the nodding pose to the curled-up pose | 0.64 s |
| Sleeping | `sleep` | rest → inhale → hold → exhale, looped | 2.4 s per breath |
| Waking up | `waking` | eyes open → rise → stretch with yawn → sit up | 0.88 s |

- **Breathing:** the torso (and the ears resting on it) rises exactly 1 px on the inhale, and the head and ground line don't move. A "z" drifts up one step per frame.
- **Twitches:** between breaths, 30 % of the time, an ear-flick or nose-twitch frame plays for 0.3 s. It only ever sits between two resting-torso frames, so it never causes a jump.
- **Ending a nap:** the nap length (10–25 s, drawn when the nap starts) is checked only between breaths. Waking therefore always starts from the exhaled resting pose.
- **Ground line:** every frame except the mid-air jump has its lowest pixel on row 29, so lying down and getting up never make the bunny sink or float. The landing frame used to sit on row 30, a 1 px dip on every landing; that is now fixed.
- **Sprite sheets:** `bunny-sleepy.tga` (drowsy + lying down, 7 of 8 slots), `bunny-sleep.tga` (4 breaths + 2 twitches, 6 of 8 slots) and `bunny-wake.tga` (4 slots). Texture coordinates are computed per slot.

**Interruptions:**

| While… | `/bunny test` | Hidden (`/bunny hide`, Alt+Z, settings change) |
|---|---|---|
| getting sleepy | cuts straight to the hop (the drowsy frames are still upright) | paused; resumes **asleep** with the remaining nap time |
| lying down | plays the lie-down frames backwards from the current frame (`rise`), then hops | same |
| asleep | plays the wake-up, then hops | same |
| waking / rising | finishes getting up, then hops instead of idling | paused; resumes awake |

On `Stop()` the bunny is always left in a valid resting state: on the ground, no timers, no `OnUpdate`, and showing either the idle or the sleeping frame.

**Timers:** at most two `C_Timer` handles exist at any time: `actionTimer` (state transitions) and `poseTimer` (idle fidgets). Every callback is a file-level function, so nothing allocates per frame.

**Pausing:** `OnHide` calls `Stop()`, which cancels both timers, removes the `OnUpdate` script, finishes any hop in progress and puts the bunny on the ground. `OnShow` calls `Start()`. This covers `/bunny hide`, Alt+Z, cinematics, and anything else that hides `UIParent`.

## Automatic placement

Implemented in `Placement.lua`. The saved (dragged) position always wins; everything below applies only while `BunnyBarDB.point` is `nil`.

**Detection** (`Placement.Detect`), for each name in `Placement.CANDIDATES`:

1. The frame must exist, `IsVisible()` must return `true` (not a secret), and an XP/rep container must have at least one visible bar in `.bars` when it exposes that table.
2. `GetLeft/GetRight/GetBottom/GetTop/GetEffectiveScale` must succeed and return finite, non-secret numbers. The rectangle is converted to UIParent units with `barScale / UIParent:GetEffectiveScale()`.
3. It must have a non-zero size, be at most 200 units tall, and have its top edge in the lower 45 % of the screen.
4. It must horizontally overlap the bunny's track, which is centred on the main action bar (or the screen centre if there is none), so bars parked at the sides don't lift the bunny.

The bunny's bottom edge goes `GAP` (2) units above the **highest** remaining top edge. If no candidate qualifies, it uses `FALLBACK_Y` (100).

**Refreshing** is event-driven and coalesced. Every trigger calls `RequestRefresh()`, which schedules one `Refresh()` 0.25 s later and ignores further requests until then. Nothing is scheduled for a manual position or while the UI is hidden, and an unchanged result doesn't re-anchor the frame.

| Trigger | Covers |
|---|---|
| `OnShow`/`OnHide` hooks on candidate bars and XP/rep sub-bars | toggling Action Bar 2/3, XP bar appearing or disappearing, reputation tracking changes, vehicle UI |
| `EDIT_MODE_LAYOUTS_UPDATED` | bars moved or resized in Edit Mode |
| `UI_SCALE_CHANGED`, `DISPLAY_SIZE_CHANGED` | scale and resolution |
| `PLAYER_LEVEL_UP`, `ENABLE_XP_GAIN`, `DISABLE_XP_GAIN`, `UPDATE_EXPANSION_LEVEL` | XP bar visibility around the level cap |
| `PLAYER_ENTERING_WORLD`, login (+1 s), bunny `OnShow` | reloads, zoning, returning from Alt+Z or `/bunny show` |
| `/bunny reset`, `/bunny width` | immediately, not deferred |

### Frame names to verify in game

None of these names are confirmed on WoW Forever. With the bunny on automatic placement, `/bunny bars` lists every name and what it found, so most of this can be checked without `/fstack`. Use `/fstack` (hover over the bar) when a bar you can see is reported as `missing`, and please report the real name in an issue.

| Bar | Names tried (in order) |
|---|---|
| Action Bar 1 (centres the bunny) | `MainActionBar`, `MainMenuBar` |
| Action Bar 2 / 3 | `MultiBarBottomLeft`, `MultiBarBottomRight` |
| Action Bars 6–8 (if placed at the bottom) | `MultiBar5`, `MultiBar6`, `MultiBar7` |
| Vehicle bar | `OverrideActionBar` |
| XP / reputation (modern) | `MainStatusTrackingBarContainer`, `SecondaryStatusTrackingBarContainer` (each with a `.bars` table) |
| XP / reputation (older layouts) | `StatusTrackingBarManager`, `MainMenuExpBar`, `ReputationWatchBar` |

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
| Offline behaviour | `tests/lua/run_tests.lua` + `wow_mock.lua` | Loads the real addon files in TOC order. Covers defaults, sanitising, slash parsing and validation, 10 simulated minutes of movement (bounds, ≤ 2.5 units per frame, facing, naps, idle waits ≥ 4 s, `OnUpdate` only while airborne, < 15 % of frames), hide/show/Alt+Z pausing, drag and save, reset, unknown events, global leaks. **Placement:** Action Bar 2 on/off × XP bar on/off, reputation bar only, empty XP container, legacy XP/rep frames, all bars hidden or missing (fallback), invalid geometry (secret, erroring, nil, NaN, zero-size, too tall), custom Edit Mode positions (moved main bar, side bars off the track, bars at the top), centring without a main bar, UI scale conversion, live toggling with coalesced deferred refresh, level-cap XP bar hiding, every refresh event, no re-anchoring when nothing changed, manual override and `/bunny reset`, saved position on reload, Alt+Z, the `/bunny bars` report, hooks installed once without replacing scripts. **Naps:** sequence frame counts and timing windows, full-nap frame order and per-frame durations, no movement or `OnUpdate` during a nap, twitches only between breaths, waking only from the resting frame, `/bunny test` in every nap phase, hiding in every phase (no timers left, valid pose, nap resumes with its remaining time), settings changes mid-nap, no back-to-back naps |
| Art | `tests/test_static.py` | One shared ground row, breathing moves the torso exactly 1 px and leaves the head still, twitches are subtle, consecutive frames overlap (silhouette IoU ≥ 0.7), z glyphs never touch the bunny, generator timings match the Lua sequences, the animated GIF decodes |
| Tooling | `tests/test_static.py` | Validators catch broken inputs (negative tests). Packaging is reproducible and verification catches a wrong root, missing files and junk files. Every command is documented. |
| **In game** | manual, see below | **Not yet done.** This is the only layer that proves real compatibility. |

The mock implements only the methods BunnyBar calls, and raises an error for anything else. It can't prove that a method exists in the real client, only that the addon is internally consistent.

## Manual in-game test checklist

Run these in WoW Forever and note the client build (shown on the login screen):

1. The addon appears in the AddOns list and isn't marked out of date.
2. Log in with no Lua errors (`/console scriptErrors 1` to show them).
3. The bunny appears just above the highest bottom bar, centred on the main action bar. Run `/bunny bars` and note which names are `missing` on Forever (see [Frame names to verify](#frame-names-to-verify-in-game)). For any bar you can see that's reported missing, hover it with `/fstack` and record its name.
4. Placement: toggle **Action Bar 2** (Edit Mode or Settings → Action Bars) and check that within about a second the bunny moves down onto the XP bar and back up. Repeat with the XP bar present and absent, for example on a max-level character or with reputation tracking on or off. Change the UI scale, move bars in Edit Mode, and check after `/reload`.
5. The sprite is crisp, not blurry, at UI scale 1 and at another scale.
6. Within about 15 s it hops. The arc is smooth, it faces its direction of travel, and it lands cleanly.
7. Watch a full nap. Waiting works, or type `/run BunnyBarDB.sleepChance = 1` and wait one idle period (set it back with `/bunny reset` afterwards). Check that:
   - getting sleepy, lying down and waking look smooth at your normal UI scale, and again at `/bunny size 64`;
   - breathing is visible but subtle;
   - the bunny never sinks or jumps vertically between frames;
   - the "z" stays clear of the head.
8. During each nap phase, try `/bunny test`, `/bunny hide` + `/bunny show`, and Alt+Z twice. The bunny should rise or wake before hopping, and resume its nap after being hidden.
9. Run every command in [COMMANDS.md](COMMANDS.md), including the invalid inputs.
10. Unlock, drag, lock, `/reload`: the position persists. `/bunny reset` brings it back above the bar.
11. Hide and show the UI with Alt+Z. Enter and leave combat. Use Edit Mode and move the action bar: there should be no errors and no "Interface action failed because of an AddOn" messages.
12. Clicking action buttons right under the bunny still works.
13. `/bunny stats` prints memory and CPU figures (or says they're not available).
14. Optional: compare FPS on an M1 MacBook Air with `/bunny hide` and `/bunny show`.
