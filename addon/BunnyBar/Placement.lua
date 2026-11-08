-- BunnyBar: automatic placement above the highest visible bottom UI bar.
--
-- Candidates are Blizzard's bottom action bars and the XP / reputation
-- ("status tracking") bars. For each one that exists, is visible, has sane
-- geometry, sits in the lower part of the screen and horizontally overlaps
-- the bunny's track, we take its top edge; the bunny sits GAP units above
-- the highest of them.
--
-- Safety
--   * Geometry is only *read* (IsVisible/GetLeft/GetRight/GetBottom/GetTop/
--     GetEffectiveScale), each call inside pcall, and "secret" values are
--     rejected. Nothing is anchored to, resized on, or called on these frames.
--   * Visibility changes are observed with HookScript("OnShow"/"OnHide"),
--     which adds a post-hook without replacing Blizzard's handler or
--     touching action buttons. The hook only schedules a deferred refresh.
--   * Refreshes are debounced (trailing, with a cap) into one C_Timer call,
--     followed by at most a couple of short "settle" re-checks while the
--     result is still changing. There is no per-frame positioning loop.

local _, ns = ...
local Util = ns.Util

local Placement = {}
ns.Placement = Placement

Placement.GAP = 2               -- UI units between the bar top and the bunny
Placement.FALLBACK_Y = 100      -- used when no candidate bar is found
Placement.BOTTOM_FRACTION = 0.45 -- ignore bars whose top is above this share of the screen
Placement.MAX_BAR_HEIGHT = 200  -- ignore implausibly tall frames
Placement.DEBOUNCE = 0.15       -- wait this long after the *last* change...
Placement.MAX_WAIT = 0.6        -- ...but never longer than this after the first
Placement.SETTLE = { 0.35, 1.0 } -- follow-up re-checks while the layout settles

-- Frame names differ between client generations. Names that don't exist are
-- skipped. kind = "main" (centres the bunny), "action" or "status".
-- On WoW Forever these names are UNVERIFIED in game: use /bunny bars and
-- /fstack to confirm them (see docs/ARCHITECTURE.md).
-- Non-candidate frames whose closing usually follows a bar layout change
-- (toggling bars in Edit Mode or Settings). OnHide only requests a refresh.
Placement.TRIGGER_FRAMES = { "EditModeManagerFrame", "SettingsPanel", "InterfaceOptionsFrame" }

Placement.CANDIDATES = {
    { name = "MainActionBar",        kind = "main" },   -- Action Bar 1 (11.2+ name)
    { name = "MainMenuBar",          kind = "main" },   -- Action Bar 1 (older name)
    { name = "MultiBarBottomLeft",   kind = "action" }, -- Action Bar 2
    { name = "MultiBarBottomRight",  kind = "action" }, -- Action Bar 3
    { name = "MultiBar5",            kind = "action" }, -- Action Bars 6-8, if Edit
    { name = "MultiBar6",            kind = "action" }, --   Mode puts them at the
    { name = "MultiBar7",            kind = "action" }, --   bottom of the screen
    { name = "OverrideActionBar",    kind = "action" }, -- vehicle bar
    { name = "MainStatusTrackingBarContainer",      kind = "status" }, -- XP / rep (10.0+)
    { name = "SecondaryStatusTrackingBarContainer", kind = "status" }, -- 2nd tracked bar
    { name = "StatusTrackingBarManager", kind = "status" }, -- XP / rep (8.0-9.x)
    { name = "MainMenuExpBar",           kind = "status" }, -- XP (classic layout)
    { name = "ReputationWatchBar",       kind = "status" }, -- rep (classic layout)
}

local function isSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

local function usable(v)
    if isSecret(v) then return false end
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isShown(f)
    if type(f) ~= "table" or not f.IsVisible then return false end
    local ok, visible = pcall(f.IsVisible, f)
    return ok and not isSecret(visible) and visible == true
end

local function readGeometry(f)
    return f:GetLeft(), f:GetRight(), f:GetBottom(), f:GetTop(), f:GetEffectiveScale()
end

-- Status containers can stay visible while empty (e.g. no XP at level cap).
-- When the frame exposes its bars, require at least one of them to be shown.
local function hasVisibleContent(f)
    local bars = f.bars
    if type(bars) ~= "table" or isSecret(bars) then return true end
    for _, bar in pairs(bars) do
        if isShown(bar) then return true end
    end
    return false -- no bars, or none of them shown
end

-- Evaluate one candidate. Returns a geometry table (UIParent units) or nil
-- and a short reason (shown by /bunny bars).
function Placement.Evaluate(entry)
    local f = _G[entry.name]
    if type(f) ~= "table" then return nil, "missing" end
    if not isShown(f) then return nil, "hidden" end
    if entry.kind == "status" and not hasVisibleContent(f) then return nil, "empty" end
    local ok, left, right, bottom, top, scale = pcall(readGeometry, f)
    if not ok then return nil, "geometry error" end
    if not (usable(left) and usable(right) and usable(bottom) and usable(top)
        and usable(scale) and scale > 0) then
        return nil, "no geometry"
    end
    local parent = UIParent
    local k = scale / parent:GetEffectiveScale()
    left, right, bottom, top = left * k, right * k, bottom * k, top * k
    if right <= left or top <= bottom then return nil, "zero size" end
    if top - bottom > Placement.MAX_BAR_HEIGHT then return nil, "too tall" end
    if top <= 0 or top > parent:GetHeight() * Placement.BOTTOM_FRACTION then
        return nil, "not at bottom"
    end
    return { name = entry.name, kind = entry.kind, left = left, right = right,
             bottom = bottom, top = top, cx = (left + right) / 2 }
end

-- Compute the automatic position.
-- Returns xOffset (from screen centre), yOffset (from screen bottom),
-- found (boolean), anchorName (or nil), the per-candidate results, and
-- `unstable` (a shown candidate had no usable geometry yet).
function Placement.Detect(trackWidth)
    local parent = UIParent
    local screenW = parent:GetWidth()
    local results, eligible = {}, {}
    local main
    local unstable = false
    for i, entry in ipairs(Placement.CANDIDATES) do
        local info, reason = Placement.Evaluate(entry)
        results[i] = { name = entry.name, info = info, reason = reason }
        -- A shown bar without usable geometry may simply not be laid out yet.
        if reason == "no geometry" or reason == "geometry error" or reason == "zero size" then
            unstable = true
        end
        if info then
            eligible[#eligible + 1] = info
            if info.kind == "main" and not main then main = info end
        end
    end

    -- Centre on the main action bar when we have it, else on the screen.
    local refX = main and main.cx or screenW / 2
    local half = (trackWidth or 480) / 2
    local best
    for _, info in ipairs(eligible) do
        -- Only bars underneath the bunny's track matter.
        if info.right > refX - half and info.left < refX + half then
            if not best or info.top > best.top then best = info end
        else
            info.offTrack = true
        end
    end
    for _, r in ipairs(results) do
        if r.info and r.info.offTrack then r.info, r.reason = nil, "off track" end
    end
    if not best then
        return 0, Placement.FALLBACK_Y, false, nil, results, unstable
    end
    if not main then refX = best.cx end
    return Util.Round(refX - screenW / 2), Util.Round(best.top + Placement.GAP), true, best.name,
        results, unstable
end

----------------------------------------------------------------------------
-- Refresh scheduling
----------------------------------------------------------------------------

local timer          -- pending C_Timer handle (debounce or settle)
local firstRequestAt -- start of the current debounce window
local settlePass = 0 -- follow-up re-checks done for the current change
local refreshing = false
local hooked = {}    -- frame -> name, for frames we hooked
local hookCount = 0
local stats = { requests = 0, refreshes = 0, moves = 0, lastReason = nil, lastAt = nil }

local function canAutoPlace()
    return ns.db and ns.Bunny and ns.Bunny:IsAutoPositioned() and UIParent:IsVisible()
end

local function cancelTimer()
    if timer then timer:Cancel(); timer = nil end
end

local runRefresh -- forward

local function scheduleSettle()
    settlePass = settlePass + 1
    timer = C_Timer.NewTimer(Placement.SETTLE[settlePass], runRefresh)
end

-- One placement pass. Re-checks a little later (bounded by #SETTLE) while
-- the bunny keeps moving or a shown bar has no geometry yet, because
-- Blizzard lays bottom bars out over the following frames.
function runRefresh()
    timer, firstRequestAt = nil, nil
    if not canAutoPlace() then settlePass = 0; return end
    refreshing = true
    Placement.HookBars()
    local ok, moved, unstable = pcall(ns.Bunny.ApplyPosition, ns.Bunny)
    refreshing = false
    stats.refreshes = stats.refreshes + 1
    if ok and moved then stats.moves = stats.moves + 1 end
    if ok and (moved or unstable) and settlePass < #Placement.SETTLE then
        scheduleSettle()
    else
        settlePass = 0
    end
end

-- Apply the automatic position now (no-op for a manually placed bunny or
-- while the UI is hidden: every bar reads as hidden then, and the bunny
-- re-places itself when it is shown again).
function Placement.Refresh()
    cancelTimer()
    settlePass = 0
    runRefresh()
end

-- Ask for a refresh soon. Trailing debounce: every request pushes the
-- refresh back by DEBOUNCE, but never beyond MAX_WAIT after the first one,
-- so a burst of show/hide changes collapses into a single pass that runs
-- after Blizzard's layout has settled. `reason` is kept for /bunny bars.
function Placement.RequestRefresh(reason)
    -- Ignore changes caused by our own positioning.
    if refreshing then return end
    if not canAutoPlace() then return end
    stats.requests = stats.requests + 1
    stats.lastReason, stats.lastAt = reason or "request", GetTime()
    local now = GetTime()
    if not firstRequestAt or settlePass > 0 then firstRequestAt = now end
    settlePass = 0
    cancelTimer()
    local delay = Placement.DEBOUNCE
    local remaining = Placement.MAX_WAIT - (now - firstRequestAt)
    if remaining < delay then delay = remaining > 0 and remaining or 0 end
    timer = C_Timer.NewTimer(delay, runRefresh)
end

local function onHookedShow(f)
    Placement.RequestRefresh((hooked[f] or "frame") .. " shown")
end
local function onHookedHide(f)
    Placement.RequestRefresh((hooked[f] or "frame") .. " hidden")
end

local function hook(f, name, showToo)
    if hooked[f] or type(f) ~= "table" or type(f.HookScript) ~= "function" then return end
    local ok1 = showToo and pcall(f.HookScript, f, "OnShow", onHookedShow) or false
    local ok2 = pcall(f.HookScript, f, "OnHide", onHookedHide)
    if ok1 or ok2 then
        hooked[f] = name
        hookCount = hookCount + 1
    end
end

-- Hook visibility changes of every candidate that exists (and of the bars
-- inside status containers), plus the closing of Edit Mode / Settings.
-- Safe to call repeatedly; each frame is hooked once. Frames created later
-- are picked up on the next refresh.
function Placement.HookBars()
    for _, entry in ipairs(Placement.CANDIDATES) do
        local f = _G[entry.name]
        if type(f) == "table" then
            hook(f, entry.name, true)
            if entry.kind == "status" and type(f.bars) == "table" and not isSecret(f.bars) then
                for key, bar in pairs(f.bars) do hook(bar, entry.name .. "." .. tostring(key), true) end
            end
        end
    end
    for _, name in ipairs(Placement.TRIGGER_FRAMES) do
        local f = _G[name]
        if type(f) == "table" then hook(f, name, false) end
    end
end

function Placement.IsRefreshPending()
    return timer ~= nil
end

function Placement.GetStats()
    return stats, hookCount
end

-- Human-readable report for /bunny bars.
function Placement.Describe(trackWidth)
    local ox, oy, found, anchor, results = Placement.Detect(trackWidth)
    local lines = {}
    if ns.Bunny:IsAutoPositioned() then
        lines[1] = found
            and ("auto position: above %s (x %+d, y %d)"):format(anchor, ox, oy)
            or ("auto position: no bar found, using fallback (y %d)"):format(oy)
    else
        lines[1] = "custom position (dragged). /bunny reset returns to automatic placement."
    end
    local missing = {}
    for _, r in ipairs(results) do
        if r.reason == "missing" then
            missing[#missing + 1] = r.name
        elseif r.info then
            lines[#lines + 1] = ("  %s: visible, top %d%s"):format(
                r.name, Util.Round(r.info.top), r.name == anchor and "  <- anchor" or "")
        else
            lines[#lines + 1] = ("  %s: %s"):format(r.name, r.reason)
        end
    end
    if #missing > 0 then
        lines[#lines + 1] = "  not present on this client: " .. table.concat(missing, ", ")
    end
    lines[#lines + 1] = ("live updates: %d frames hooked, %d refreshes (%d moves) from %d requests"):format(
        hookCount, stats.refreshes, stats.moves, stats.requests)
    if stats.lastReason then
        lines[#lines + 1] = ("  last trigger: %s, %.1f s ago"):format(stats.lastReason, GetTime() - stats.lastAt)
    else
        lines[#lines + 1] = "  last trigger: none yet (toggle a bar to test)"
    end
    return lines
end
