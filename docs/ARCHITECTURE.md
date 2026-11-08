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
| Settings API | Modern `Settings.RegisterCanvasLayoutCategory` / `RegisterAddOnCategory` / `OpenToCategory` expected (Mainline API). | **Unverified for v0.2.** Feature-detected with fallbacks. |
| Unit frame / portrait names | Modern `PlayerFrame.PlayerFrameContainer.PlayerPortrait`, `PartyFrame.MemberFrameN.Portrait` expected. | **Unverified.** Legacy names also tried. |
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
├── Util.lua         pure helpers: math, parsing, hex/HSV colour, safe frame reads
├── Config.lua       defaults, limits, schema migration, Config.Set/Notify, slash commands
├── Appearance.lua   cosmetic registries (variations, hats) + layered, tinted sprites
├── Placement.lua    automatic placement above the highest visible bottom bar
├── Animation.lua    the bunny frame, poses, state machine, ApplyPosition, stats
├── Ears.lua         bunny ears over the player / party portraits
├── Options.lua      Settings panel (colour picker, size presets, accessories)
├── Core.lua         event wiring
└── Textures/        generated sprite strips (TGA, 32-bit BGRA, power-of-two),
                     each with a fur layer on top and a detail layer below
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

## Appearance and recolouring

Every sprite texture stacks **two layers of the same frames**: the fur layer (top half) and the detail layer (bottom half). The generator splits each frame by palette. Main fur, shade and tail pixels go to the fur layer, normalised so the main fur tone is pure white. Everything else goes to the detail layer: outline, eyes and catch-light, nose, mouth, blush, inner ears, eyelid and the "z". The layers never overlap.

In game, each layer is its own texture showing the same frame, with `SetTexCoord(…, 0, 0.5)` and `(…, 0.5, 1)`. Only the fur layer gets `SetVertexColor(fur colour)`. As a result:

- the main fur takes **exactly** the chosen colour, and shading keeps its original ratio to it;
- eyes, nose, inner ears, outlines, transparency and nearest-neighbour filtering are untouched;
- every animation frame recolours identically, because all frames share the same two normalised fur tones (the tests check this);
- nothing is generated at runtime, and a colour change is a single `SetVertexColor` per fur texture;
- the default colour, `#F6F3FA` (the original fur tone), reproduces the v0.1 art within 1/255. The one exception is the cotton tail, which now uses the main fur tone (5/255 darker) so it can be recoloured.

`Appearance.lua` also holds small **registries** for future cosmetics: `variation` (sprite set / fur pattern; currently only `classic`) and `hat` (currently only `none`). Animation code only asks Appearance to "show sheet X, frame N, mirrored or not", so new layers such as hats, accessories or separately tinted accessory colours can be added without touching movement or timing. The options panel shows the current style as text and doesn't offer selectors until there is more than one choice.

## Options panel

`Options.lua` registers a canvas-layout category through `Settings.RegisterCanvasLayoutCategory` + `Settings.RegisterAddOnCategory`. If those are missing it falls back to `InterfaceOptions_AddCategory`, and failing that, to slash commands only. Controls are built the first time the panel is shown. `/bunny options` calls `Settings.OpenToCategory(category:GetID())`, deferred until after combat.

- **Colour:**
  - a 150×150 saturation (x) / brightness (y) square over the current hue, built from a hue colour texture plus white and black gradient overlays (`SetGradient` with `CreateColor`, falling back to `SetGradientAlpha`, then a flat colour);
  - a hue `Slider` over six gradient segments, and a separate brightness `Slider`;
  - a hex `EditBox`, a swatch, a live preview of the real tinted sprite, and **Reset Color**.

  Blizzard's `ColorPickerFrame` is a modal popup, so it doesn't fit the inline layout that was asked for. The square only runs `OnUpdate` while the mouse button is held on it.
- **Size:** five radio buttons (Tiny 16, Small 32, Regular 64, Large 96, Huge 128), taken from `Config.SIZE_PRESETS`. The positions of the sections below are computed from the number of presets, so adding presets can't overlap them. A non-preset size set with `/bunny size` shows as "Custom: N" with no radio selected; the panel never changes it.
- **Portrait Accessories:** "Bunny ears on my portrait", "Bunny ears on party portraits".
- **Styles:** informational text only.

All controls, slash commands and `/bunny reset` go through `Config.Set()`. That calls `Config.Notify()`, which updates the bunny, the appearance, the ears and `Options.Refresh()`. The panel keeps its own HSV state, so greys keep the hue you chose. Widget templates (`UIRadioButtonTemplate`, `UICheckButtonTemplate`, `InputBoxTemplate`, `UIPanelButtonTemplate`) are created through `pcall`, falling back to plain widgets.

## Portrait ears

`Ears.lua` draws a 32×16 pair of ears (tinted like the fur) above:

- the **player portrait**: `PlayerFrame.PlayerFrameContainer.PlayerPortrait`, or legacy `PlayerPortrait`;
- each **party portrait**: `PartyFrame.MemberFrameN.Portrait`, or legacy `PartyMemberFrameNPortrait`.

Combat and taint safety:

- Each pair of ears is BunnyBar's own frame, **parented and anchored to `UIParent`** and positioned from the portrait's rectangle read through `pcall`. It is never anchored to a unit frame: a frame anchored to a protected frame becomes implicitly protected and couldn't be moved, shown or hidden in combat.
- Nothing on Blizzard's unit frames is created, changed or re-anchored: no attributes, scripts, textures or children. Visibility is observed with `HookScript("OnShow"/"OnHide")` post-hooks on the unit frames and `PartyFrame`. These are installed only **out of combat**; if the addon loads in combat, installation waits for `PLAYER_REGEN_ENABLED`.
- Overlays are click-through (`EnableMouse(false)`).

**Layering.** WoW draws frames by strata, then by frame level. Texture draw layers (`BACKGROUND`…`OVERLAY`) only order regions *within one frame*, so the ears' own draw layer can't lift them over another frame.

v0.2.0 copied the unit frame's strata and used its level + 10. That fails because:

- the portrait texture is drawn by a nested frame (`PlayerFrame.PlayerFrameContainer`), and the ring and icons by other descendants. These carry their own level offsets and sometimes their own strata;
- Edit Mode raises a frame when you drag it, which re-levels its whole subtree, so "unit frame + 10" could end up below the portrait's frame and part of the ears was hidden.

`Ears.ComputeLayer` takes the highest strata, and then the highest level within it, among:

- the portrait's owner frame and its ancestors up to the unit frame, which always count;
- every **shown** frame in the unit frame's subtree whose rectangle **overlaps the ears**. Edit Mode `Selection` overlays are excluded, and the scan is bounded to 200 frames and depth 5.

The ears go 10 levels above that. Level is capped at 9900 and strata at `HIGH`, so dialogs, menus and tooltips stay on top. Our overlays are parented to `UIParent`, so they're never part of the scan and repeated refreshes can't ratchet levels upward. If no strata or level can be read (errors, secret values), the fallback is the `HIGH` strata.

**Second pass (after the in-game report: "ears hidden after an Edit Mode move, fixed by `/reload`").** Comparing the reload path with the runtime path turned up three weaknesses:

1. **Stale cache.** Layers were only re-applied when the *computed* value differed from the value we last *requested*, never from what the overlay actually had. A reload starts with an empty cache, so everything is applied fresh. At runtime, drift went unnoticed, for example when `SetFrameStrata` resets the level or a strata-only change keeps an old level. Now `applyLayer` compares against the overlay's **actual** `GetFrameStrata()`/`GetFrameLevel()`, always sets strata before level, and counts corrections as "drift".
2. **Timing.** An Edit Mode trigger got one pass plus a single re-check 0.5 s later. If Blizzard re-levels or re-parents frames after that, for example while applying the saved layout on exit, the position doesn't change and nothing re-checked. Now every trigger is debounced (0.1 s) and followed by bounded re-checks at +0.25, +0.75, +1.5 and +3.0 s. Edit Mode triggers always run the whole series; other triggers stop at the first pass that changes nothing. Each pass compares visibility, position, size, strata and level. A new trigger restarts the series.
3. **Scan scope.** Edit Mode's `Selection` overlay could lift the ears to `DIALOG` while editing, and descendants that don't overlap the ears counted too. Both are now excluded.

The code can't prove which of these Forever actually hits, so all three are fixed. `/bunny ears debug` exists to confirm it in game.

**Edit Mode.** Drops are caught with `OnDragStop`/`OnMouseUp` post-hooks on each unit frame's `Selection` child and the `EventRegistry` callbacks `EditMode.Enter` / `EditMode.Exit`, plus the existing `EditModeManagerFrame` `OnHide` and `EDIT_MODE_LAYOUTS_UPDATED`. While dragging, the ears catch up when the mouse is released, not continuously. In Edit Mode the shown `Selection` overlay can lift the ears to its strata, which keeps them visible while editing.
- Defensive guard: if an overlay ever reported `IsProtected()` in combat, changes would wait for combat to end.

Ear size is 0.8 × the portrait width, with height half of that. They overlap the portrait's top by 25 % and follow UI scale, using effective-scale conversion.

Refresh triggers are debounced (0.1 s, with one settle re-check 0.5 s later):

- unit frame / `PartyFrame` show or hide;
- `EditModeManagerFrame` closing;
- `GROUP_ROSTER_UPDATE`, `EDIT_MODE_LAYOUTS_UPDATED`, `UI_SCALE_CHANGED`, `DISPLAY_SIZE_CHANGED`, `PLAYER_ENTERING_WORLD`;
- combat end.

No `OnUpdate` is used.

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

**Refreshing** is event-driven, debounced and self-settling, and it never uses `OnUpdate`:

- **Trailing debounce.** Every trigger calls `RequestRefresh(reason)`. This (re)starts a single `C_Timer` 0.15 s (`DEBOUNCE`) after the *latest* change, capped at 0.6 s (`MAX_WAIT`) after the first. A burst of show/hide changes, which a single bar toggle usually causes, collapses into one pass that runs after Blizzard has re-laid out the bars. Continuous changes still get refreshed at least every 0.6 s.
- **Settle passes.** Blizzard lays bottom bars out over the following frames, so a bar can be shown before its final position is known. If a pass moved the bunny, or a shown bar had no usable geometry yet, it re-checks after 0.35 s and then 1.0 s (`SETTLE`). It stops as soon as a re-check finds nothing new.
- **No recursion.** Requests that arrive while BunnyBar is positioning itself are ignored. Nothing is scheduled for a manual position or while the UI is hidden. An unchanged result doesn't re-anchor the frame.
- **Diagnostics.** `/bunny bars` reports how many frames were hooked, the number of refreshes, moves and requests, and the last trigger (for example `MultiBarBottomLeft hidden`, `SettingsPanel hidden` or `EDIT_MODE_LAYOUTS_UPDATED`) with how long ago it happened.

| Trigger | Covers |
|---|---|
| `OnShow`/`OnHide` hooks on candidate bars and XP/rep sub-bars | toggling Action Bar 2/3, XP bar appearing or disappearing, reputation tracking changes, vehicle UI |
| `EDIT_MODE_LAYOUTS_UPDATED`; `OnHide` of `EditModeManagerFrame` | bars moved, resized or toggled in Edit Mode |
| `OnHide` of `SettingsPanel` (legacy `InterfaceOptionsFrame`) | bars toggled under Settings → Action Bars, in case the bar itself didn't fire a show/hide |
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

### Portrait frame names to verify in game

| Portrait | Names tried | How to check |
|---|---|---|
| Player | `PlayerFrame.PlayerFrameContainer.PlayerPortrait`, then `PlayerPortrait` | `/fstack` over your portrait; or `/run print(PlayerFrame.PlayerFrameContainer.PlayerPortrait)` |
| Party 1–4 | `PartyFrame.MemberFrame1..4.Portrait`, then `PartyMemberFrame1..4Portrait` | `/fstack` over a party portrait (default, non-raid-style party frames) |
| Edit Mode drag handle | `<unit frame>.Selection`, `PartyFrame.Selection` | `/fstack` while Edit Mode is open |
| Edit Mode callbacks | `EventRegistry` with `EditMode.Enter` / `EditMode.Exit` | `/run print(EventRegistry)` |

`/fstack` also shows each frame's strata and level. If ears are still hidden behind a portrait, record those for the portrait and the frame in front of it.

## SavedVariables

`BunnyBarDB` (account-wide), schema **2**. On `ADDON_LOADED`, `Config.Sanitize` rebuilds it:

- **Migration from v0.1 (schema 1)**: every existing setting is kept, including position, lock, track width, speed, interval, sleep chance, visibility and size. New keys get defaults: `furColor = "F6F3FA"`, `variation = "classic"`, `hat = "none"`, `earsPlayer = true`, `earsParty = true`. Only *new* installs default to size 64. A v0.1 save with a missing or broken size falls back to v0.1's default, 32.
- String settings are validated: the colour must be six hex digits (canonicalised to upper case), and the variation and hat must be registered.

- Unknown keys are dropped and missing keys are filled from `DEFAULTS`.
- Numbers are clamped to `LIMITS` and integer settings are rounded. NaN, ±inf and wrong types are replaced with defaults.
- Position is all-or-nothing. An invalid anchor name or a non-finite offset resets it to automatic placement.

A dragged position is stored as `BOTTOM` → `UIParent BOTTOM` with an x offset from the screen centre, which tolerates resolution and UI-scale changes. `SetUserPlaced(false)` is called after a drag so the client's own layout cache doesn't compete with ours.

## Testing strategy

| Layer | Tool | What it proves |
|---|---|---|
| Static | `scripts/validate.py` | TOC metadata and references (exact-case), no unlisted Lua, Lua 5.1 syntax (via LuaJIT/lua5.1), no 5.2+ syntax, no forbidden APIs (`print`, `io`, `os`, `hooksecurefunc`, combat log, secure templates), TGA format/size/frames/transparency, sprites match the generator |
| Offline behaviour | `tests/lua/run_tests.lua` + `wow_mock.lua` | Loads the real addon files in TOC order. Covers defaults, sanitising, slash parsing and validation, 10 simulated minutes of movement (bounds, ≤ 2.5 units per frame, facing, naps, idle waits ≥ 4 s, `OnUpdate` only while airborne, < 15 % of frames), hide/show/Alt+Z pausing, drag and save, reset, unknown events, global leaks. **v0.2:** hex parsing (valid and invalid), RGB↔HSV round-trips, schema-1 migration and fallbacks, appearance registry, fur-only tinting and the colour persisting through every sheet and pose, `/bunny color`, Settings registration plus the legacy, missing and failing API paths, lazy panel build, `/bunny options` deferred in combat, missing widget templates, hex box / hue / brightness / square / swatch / bunny staying in sync (including greys keeping their hue and `OnUpdate` only while dragging), invalid hex in the panel, size radios versus custom sizes, ear checkboxes versus `/bunny ears`, `/bunny reset` updating an open panel, ears geometry and click-through and `UIParent`-only anchoring, portrait visibility, party join / leave / re-sort, legacy portrait names, missing portraits, invalid geometry, UI scale and Edit Mode moves, combat-deferred hooks and protected-overlay deferral, ears following the fur colour, and no idle `OnUpdate`. **v0.2 fixes:** five size presets in order, saved sizes mapping onto the presets after reload, custom sizes, five radios fitting above the next section. Ear layering:
- above nested containers and rings, not just the unit frame;
- a higher-strata container winning over any level;
- hidden Edit Mode selection ignored until shown;
- Edit Mode drag (raised subtree, new position) caught on drop;
- the `EditMode.Exit` callback;
- idempotent refreshes with no level ratchet;
- the level cap;
- secret, erroring and broken strata/levels falling back to `HIGH`;
- no writes to Blizzard frames, including in combat;
- UI scale and party re-sorts;
- legacy party portraits;
- identical results after a reload. **Placement:** Action Bar 2 on/off × XP bar on/off, reputation bar only, empty XP container, legacy XP/rep frames, all bars hidden or missing (fallback), invalid geometry (secret, erroring, nil, NaN, zero-size, too tall), custom Edit Mode positions (moved main bar, side bars off the track, bars at the top), centring without a main bar, UI scale conversion, live toggling with coalesced deferred refresh, level-cap XP bar hiding, every refresh event, no re-anchoring when nothing changed, manual override and `/bunny reset`, saved position on reload, Alt+Z, the `/bunny bars` report, hooks installed once without replacing scripts. **Live repositioning:** Action Bar 2 on/off/on with bounded settling, XP container hidden/shown, reputation replacing XP (same and separate containers), Edit Mode closing and Settings closing as triggers, a 50-change burst collapsing into one pass, continuous changes refreshing at least every `MAX_WAIT`, geometry that becomes valid or shifts after a delay (picked up by settle passes), bounded settling with permanently invalid geometry, no recursion from our own `SetPoint`, manual positions ignoring every trigger, missing frames / missing `HookScript` / failing `HookScript`, and the diagnostics in `/bunny bars`. **Naps:** sequence frame counts and timing windows, full-nap frame order and per-frame durations, no movement or `OnUpdate` during a nap, twitches only between breaths, waking only from the resting frame, `/bunny test` in every nap phase, hiding in every phase (no timers left, valid pose, nap resumes with its remaining time), settings changes mid-nap, no back-to-back naps |
| Recolouring | `tests/test_static.py` | Layers are disjoint and complete. The default colour reproduces the original art. Only two normalised fur tones are used across every frame. Pink, sky blue and black change the fur only, and the main fur takes the exact colour. The portrait ears sprite is rooted, symmetric and has pink inner ears. |
| Art | `tests/test_static.py` | One shared ground row, breathing moves the torso exactly 1 px and leaves the head still, twitches are subtle, consecutive frames overlap (silhouette IoU ≥ 0.7), z glyphs never touch the bunny, generator timings match the Lua sequences, the animated GIF decodes |
| Tooling | `tests/test_static.py` | Validators catch broken inputs (negative tests). Packaging is reproducible and verification catches a wrong root, missing files and junk files. Every command is documented. |
| **In game** | manual, see below | **Not yet done.** This is the only layer that proves real compatibility. |

The mock implements only the methods BunnyBar calls, and raises an error for anything else. It can't prove that a method exists in the real client, only that the addon is internally consistent.

## Manual in-game test checklist

Run these in WoW Forever and note the client build (shown on the login screen):

1. The addon appears in the AddOns list and isn't marked out of date.
2. Log in with no Lua errors (`/console scriptErrors 1` to show them).
3. The bunny appears just above the highest bottom bar, centred on the main action bar. Run `/bunny bars` and note which names are `missing` on Forever (see [Frame names to verify](#frame-names-to-verify-in-game)). For any bar you can see that's reported missing, hover it with `/fstack` and record its name.
4. Placement: toggle **Action Bar 2** (Edit Mode or Settings → Action Bars) and check that within about a second the bunny moves down onto the XP bar and back up, **without** `/reload`. Then run `/bunny bars` and note the `live updates` and `last trigger` lines. A trigger such as `MultiBarBottomLeft hidden` means the bar hooks work on Forever. If the only triggers are `SettingsPanel hidden` or `EditModeManagerFrame hidden`, the bar hooks don't fire there and placement relies on those fallbacks. Please report which you see. Repeat with the XP bar present and absent, for example on a max-level character or with reputation tracking on or off. Change the UI scale, move bars in Edit Mode, and check after `/reload`.
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
15. **v0.2 options:** Esc → Options → AddOns lists **BunnyBar**, and `/bunny options` opens it. In combat it opens when combat ends. All controls render: square, hue and brightness gradients, hex box, swatch, preview bunny, radios, checkboxes.
16. **v0.2 colour:** drag the square and both sliders, then type `#FFB6C1`, `#87CEEB`, `#000000`, `#FFFFFF` and an invalid value. The bunny and the portrait ears change instantly while the eyes, nose, inner ears and outline stay the same. Watch a hop and a full nap in a non-default colour. `/bunny color #87CEEB` updates the open panel.
17. **v0.2 size:** try each of the five presets (Tiny, Small, Regular, Large, Huge) and check that all five radios fit without overlapping "Portrait Accessories". Then try `/bunny size 48`, which should show "Custom: 48". Check the pixels look sharp and the bunny still sits right on the bar.
18. **v0.2 ear layering (A/B/C diagnostics):** run `/bunny ears debug`:
    - **A**, before Edit Mode;
    - **B**, after moving the player and a party frame in Edit Mode and leaving it. Wait about 5 s so the re-checks finish;
    - **C**, after `/reload`.

    The ears should be fully in front of the portrait and ring in B, with no reload. In B and C, "ears want" should equal "have", and the strata/levels should match. If the ears are still clipped in B, please send all three outputs. A growing "corrected drift" count or a later re-check fixing it points to timing. An overlapping frame above the ears' level points to a frame that isn't inside the unit frame. Repeat after changing the UI scale and after combat.
19. **v0.2 ears:** the ears sit on top of your portrait and on party portraits. Join, leave and re-sort a party. Toggle both checkboxes. Move the player frame in Edit Mode and change the UI scale. Check that clicking and targeting the portraits still works, including in combat, and that there are no "Interface action failed because of an AddOn" or `ADDON_ACTION_BLOCKED` messages after combat, roster changes or `/reload` in combat. Record the portrait frame names with `/fstack` if no ears appear.
20. **v0.2 upgrade:** with a v0.1 `BunnyBarDB`, check that size 32, position, speed and the other settings survive. `/bunny reset` should give Regular (64), the default colour and an updated open panel.
