-- BunnyBar: pixel-art bunny ears above the player and party portraits.
--
-- A purely local, cosmetic overlay:
--   * Each pair of ears is BunnyBar's own frame, parented to UIParent and
--     positioned with plain coordinates read from the portrait. It is NOT
--     anchored or parented to Blizzard's unit frames, because a frame
--     anchored to a protected frame becomes implicitly protected and could
--     not be moved, shown or hidden in combat. Ours stay unprotected.
--   * Blizzard's frames are only read (geometry, visibility, strata) inside
--     pcall, and observed with HookScript("OnShow"/"OnHide") post-hooks that
--     only request a refresh. No attributes, scripts, textures or children
--     of the unit frames are created or changed, so there is nothing to taint.
--   * Overlays are click-through (EnableMouse(false)).
--   * Hooks are installed out of combat; anything that would need a
--     restricted operation in combat is deferred to PLAYER_REGEN_ENABLED.
--   * Refreshes are event-driven and debounced; no OnUpdate is used.
--   * Ear colour follows the bunny's fur colour (Appearance.lua).

local _, ns = ...
local Util = ns.Util

local Ears = {}
ns.Ears = Ears

-- Two stacked 32x16 layers (fur, detail); see generate_sprites.py.
Ears.TEXTURE = { file = "bunny-ears.tga", count = 1, slots = 1, height = 16 }
Ears.WIDTH_RATIO = 0.8   -- ears width relative to the portrait width
Ears.OVERLAP = 0.25      -- share of the ears' height overlapping the portrait
Ears.DEBOUNCE = 0.1
-- Bounded re-checks after a trigger (seconds after the previous pass).
-- Blizzard keeps re-levelling / re-parenting frames for a while after an
-- Edit Mode drop or exit, so one immediate pass is not enough. Edit Mode
-- triggers always run the whole series; other triggers stop at the first
-- pass that changes nothing.
Ears.RECHECKS = { 0.25, 0.75, 1.5, 3.0 }
Ears.LEVEL_BOOST = 10    -- frame levels above the highest frame drawn there
Ears.MAX_LEVEL = 9900    -- frame levels top out at 10000
Ears.FALLBACK_STRATA = "HIGH" -- when no strata/level can be read safely
Ears.MAX_STRATA = "HIGH" -- never above HIGH: dialogs, menus, tooltips stay on top
Ears.SCAN_LIMIT = 200    -- max frames inspected per unit frame
Ears.SCAN_DEPTH = 5      -- max nesting depth inspected

-- Rendering order between frames: strata first, then frame level. Texture
-- draw layers (BACKGROUND..OVERLAY) only order regions *within* one frame,
-- so the ears' own draw layer cannot lift them over another frame.
Ears.STRATA_ORDER = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

local function field(t, key)
    if type(t) ~= "table" then return nil end
    local v = t[key]
    return type(v) == "table" and v or nil
end

-- Resolvers return (portrait region, owning unit frame). Modern names first,
-- then pre-10.0 globals. All of them are UNVERIFIED on WoW Forever.
local function playerPortrait()
    local pf = field(_G, "PlayerFrame")
    local p = field(field(pf, "PlayerFrameContainer"), "PlayerPortrait")
    if p then return p, pf end
    p = field(_G, "PlayerPortrait")
    if p then return p, pf end
end

local function partyPortrait(i)
    local m = field(field(_G, "PartyFrame"), "MemberFrame" .. i)
    local p = field(m, "Portrait")
    if p then return p, m end
    m = field(_G, "PartyMemberFrame" .. i)
    p = field(_G, "PartyMemberFrame" .. i .. "Portrait") or field(m, "portrait")
    if p then return p, m end
end

Ears.TARGETS = {
    { key = "player", setting = "earsPlayer", resolve = playerPortrait },
}
for i = 1, 4 do
    Ears.TARGETS[#Ears.TARGETS + 1] = {
        key = "party" .. i, setting = "earsParty",
        resolve = function() return partyPortrait(i) end,
    }
end

-- Extra frames whose visibility affects portraits (party container, Edit
-- Mode closing).
Ears.WATCH_FRAMES = { "PartyFrame", "EditModeManagerFrame" }

----------------------------------------------------------------------------
-- Overlays
----------------------------------------------------------------------------

local function createOverlay(target)
    local f = CreateFrame("Frame", nil, UIParent)
    f:EnableMouse(false) -- click-through: never blocks targeting
    f:Hide()
    local layers = ns.Appearance.CreateLayers(f, "OVERLAY")
    layers[1]:SetAllPoints(f)
    local t = Ears.TEXTURE
    ns.Appearance.SetFrame(layers, ns.Appearance.SheetPath(t.file), 1, t.slots, false)
    target.overlay, target.layers = f, layers
    return f
end

local deferred = false
local STRATA_ORDER = Ears.STRATA_ORDER

local function readLayer(f)
    if type(f) ~= "table" or type(f.GetFrameStrata) ~= "function" or type(f.GetFrameLevel) ~= "function" then
        return nil, nil
    end
    local okS, strata = pcall(f.GetFrameStrata, f)
    local okL, level = pcall(f.GetFrameLevel, f)
    if not okS or Util.IsSecret(strata) or not STRATA_ORDER[strata] then strata = nil end
    if not okL or not Util.IsUsableNumber(level) then level = nil end
    return strata, level
end

local function collectChildren(f)
    return { f:GetChildren() }
end

-- Readable name for diagnostics (never errors, never returns a secret).
function Ears.NameOf(f)
    if type(f) ~= "table" then return "none" end
    for _, method in ipairs({ "GetDebugName", "GetName" }) do
        if type(f[method]) == "function" then
            local ok, name = pcall(f[method], f)
            if ok and type(name) == "string" and not Util.IsSecret(name) and name ~= "" then return name end
        end
    end
    return "(unnamed)"
end

local function higher(s1, l1, s2, l2)
    if not s2 then return true end
    if STRATA_ORDER[s1] ~= STRATA_ORDER[s2] then return STRATA_ORDER[s1] > STRATA_ORDER[s2] end
    return l1 > l2
end

local function overlaps(f, er)
    local l, r, b, t = Util.ReadRect(f)
    if not l then return nil end -- unknown geometry
    return r > er[1] and l < er[2] and t > er[3] and b < er[4]
end

-- Edit Mode's selection/highlight overlays are not portrait decoration;
-- never lift the ears to them.
local function editModeOverlays(unitFrame)
    local ex = {}
    local sel = field(unitFrame, "Selection")
    if sel then ex[sel] = true end
    local partySel = field(field(_G, "PartyFrame"), "Selection")
    if partySel then ex[partySel] = true end
    return ex
end

-- Where must the ears go to be drawn in front of the portrait and its ring?
--
-- WoW draws frames by strata, then frame level; texture draw layers only
-- order regions inside one frame. The portrait texture is drawn by its
-- owning frame (portrait:GetParent()), the ring / icons by other frames in
-- the unit frame's subtree, at their own levels (and sometimes strata), and
-- Edit Mode raises a dragged frame, re-levelling its whole subtree.
--
-- We take the highest (strata, level) among
--   * the portrait's owner and its ancestors up to the unit frame, and
--   * every shown frame in the unit frame's subtree whose rectangle
--     overlaps the ears (`earRect` = {left, right, bottom, top}, UIParent
--     units), excluding Edit Mode selection overlays (bounded scan),
-- then go LEVEL_BOOST above it, never above MAX_STRATA.
-- Returns strata, level (nil = leave as is), source, info (diagnostics).
function Ears.ComputeLayer(portrait, unitFrame, earRect)
    local info = { scanned = 0 }
    local bestS, bestL, bestF
    local seen, count = {}, 0
    local exclude = editModeOverlays(unitFrame)

    local function consider(f)
        local strata, level = readLayer(f)
        if strata and level and higher(strata, level, bestS, bestL) then
            bestS, bestL, bestF = strata, level, f
        end
    end

    -- 1. The portrait's owner chain: these draw the portrait, always count.
    local ok, f = false, nil
    if type(portrait) == "table" and type(portrait.GetParent) == "function" then
        ok, f = pcall(portrait.GetParent, portrait)
    end
    info.owner = ok and f or nil
    info.ownerStrata, info.ownerLevel = readLayer(info.owner)
    local depth = 0
    while ok and type(f) == "table" and depth < 8 do
        seen[f] = true
        consider(f)
        if f == unitFrame or f == UIParent then break end
        ok, f = pcall(f.GetParent, f)
        depth = depth + 1
    end

    -- 2. Shown frames in the unit frame's subtree that overlap the ears.
    local function walk(frame, d)
        if count >= Ears.SCAN_LIMIT or d > Ears.SCAN_DEPTH then return end
        if exclude[frame] or not Util.IsShown(frame) then return end
        count = count + 1
        if not seen[frame] then
            seen[frame] = true
            if not earRect or overlaps(frame, earRect) then consider(frame) end
        end
        if type(frame.GetChildren) ~= "function" then return end
        local okC, kids = pcall(collectChildren, frame)
        if not okC then return end
        for i = 1, #kids do walk(kids[i], d + 1) end
    end
    if type(unitFrame) == "table" then walk(unitFrame, 0) end
    info.scanned = count
    info.best, info.bestStrata, info.bestLevel = bestF, bestS, bestL

    if not bestS then return Ears.FALLBACK_STRATA, nil, "fallback", info end
    if STRATA_ORDER[bestS] > STRATA_ORDER[Ears.MAX_STRATA] then
        return Ears.MAX_STRATA, Ears.MAX_LEVEL, "capped", info
    end
    return bestS, math.min(bestL + Ears.LEVEL_BOOST, Ears.MAX_LEVEL), "scan", info
end

local function hide(target, reason)
    local changed = target.reason == "shown"
    target.reason = reason
    if target.overlay and target.overlay:IsShown() then target.overlay:Hide(); changed = true end
    return changed
end

-- Make the overlay's ACTUAL layer match the desired one. Compares with what
-- the client reports, not with what we last asked for: a cached value can go
-- stale (e.g. SetFrameStrata may reset the level), which is exactly the kind
-- of drift that only a /reload used to clear. Strata is always set before
-- the level. Returns true if anything had to be changed.
local function applyLayer(target, overlay, strata, level)
    local curS, curL = readLayer(overlay)
    local changed = false
    if curS ~= strata then
        overlay:SetFrameStrata(strata)
        changed = true
        curS, curL = readLayer(overlay)
    end
    if level and curL ~= level then
        overlay:SetFrameLevel(level)
        changed = true
    end
    if changed and target.strata == strata and target.level == level then
        -- We had already applied this layer; something else changed it.
        target.drift = (target.drift or 0) + 1
    end
    target.strata, target.level = strata, level
    return changed
end

-- Update one target. Returns true if anything changed (visibility,
-- position, size, strata or level).
local function update(target)
    local db = ns.db
    if not db or not db[target.setting] then return hide(target, "disabled") end
    local ok, portrait, unitFrame = pcall(target.resolve)
    if not ok or not portrait then return hide(target, "missing") end
    target.portrait, target.unitFrame = portrait, unitFrame
    if not Util.IsShown(portrait) then return hide(target, "hidden") end
    local l, r, _, t = Util.ReadRect(portrait)
    if not l then return hide(target, "no geometry") end

    local overlay = target.overlay or createOverlay(target)
    -- Defensive: our overlay is never anchored to protected frames, so this
    -- should not trigger; if it ever is protected, wait for combat to end.
    if Util.InCombat() and overlay.IsProtected and overlay:IsProtected() then
        deferred = true
        target.reason = "deferred (combat)"
        return false
    end

    -- Position (unchanged by the layering fixes).
    local w = (r - l) * Ears.WIDTH_RATIO
    local h = w / 2
    local cx, bottom = (l + r) / 2, t - h * Ears.OVERLAP
    local rect = target.rect
    local moved = not rect or rect[1] ~= cx or rect[2] ~= bottom or rect[3] ~= w or rect[4] ~= h
    if moved then
        overlay:SetSize(w, h)
        overlay:ClearAllPoints()
        overlay:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", cx, bottom)
        target.rect = rect or {}
        target.rect[1], target.rect[2], target.rect[3], target.rect[4] = cx, bottom, w, h
    end

    -- Layer: in front of everything that draws where the ears are.
    target.earRect = target.earRect or {}
    local er = target.earRect
    er[1], er[2], er[3], er[4] = cx - w / 2, cx + w / 2, bottom, bottom + h
    local strata, level, source, info = Ears.ComputeLayer(portrait, unitFrame, er)
    local relayered = applyLayer(target, overlay, strata, level)
    target.layerSource, target.layerInfo = source, info

    local wasShown = target.reason == "shown" and overlay:IsShown()
    target.reason = "shown"
    overlay:Show()
    return moved or relayered or not wasShown
end

----------------------------------------------------------------------------
-- Hooks and refresh scheduling
----------------------------------------------------------------------------

local hooked = {}
local hooksPending = true
local timer          -- pending debounce or re-check timer
local recheckIndex = 0
local fullSeries = false -- Edit Mode trigger: run every re-check
local status = { reason = nil, at = nil, passes = 0, lastChangeAt = nil }

-- Reasons that come from Edit Mode always get the full re-check series.
local function isEditModeReason(reason)
    return type(reason) == "string" and (reason:find("EditMode", 1, true) or reason:find("Selection", 1, true)
        or reason == "EDIT_MODE_LAYOUTS_UPDATED") and true or false
end

-- One pass over every target. Returns true if anything changed.
function Ears.Refresh()
    deferred = false
    local changed = false
    for _, target in ipairs(Ears.TARGETS) do
        if update(target) then changed = true end
    end
    status.passes = status.passes + 1
    if changed then status.lastChangeAt = GetTime() end
    return changed
end

local runPass -- forward

local function scheduleNext(changed)
    if recheckIndex < #Ears.RECHECKS and (fullSeries or changed) then
        recheckIndex = recheckIndex + 1
        timer = C_Timer.NewTimer(Ears.RECHECKS[recheckIndex], runPass)
    else
        timer, recheckIndex, fullSeries = nil, 0, false
    end
end

function runPass()
    timer = nil
    if hooksPending then Ears.InstallHooks() end
    scheduleNext(Ears.Refresh())
end

-- Coalesce bursts of changes (a party re-sort shows/hides several frames,
-- an Edit Mode drop fires several hooks). A new trigger restarts the
-- debounce and the re-check series; the series length is bounded.
function Ears.RequestRefresh(reason)
    if timer then timer:Cancel() end
    status.reason, status.at = reason or "request", GetTime()
    recheckIndex = 0
    fullSeries = fullSeries or isEditModeReason(reason)
    timer = C_Timer.NewTimer(Ears.DEBOUNCE, runPass)
end

function Ears.IsRefreshPending()
    return timer ~= nil, recheckIndex, #Ears.RECHECKS
end

-- Hook handlers carry a reason (built once per hooked frame, not per call).
local function hookScripts(f, scripts, label)
    if hooked[f] or type(f) ~= "table" or type(f.HookScript) ~= "function" then return end
    local any = false
    for _, script in ipairs(scripts) do
        local reason = label .. " " .. script
        if pcall(f.HookScript, f, script, function() Ears.RequestRefresh(reason) end) then any = true end
    end
    if any then hooked[f] = true end
end

-- Edit Mode drags a unit frame through its "Selection" child.
local function hookSelection(f, label)
    hookScripts(field(f, "Selection"), { "OnDragStop", "OnMouseUp" }, label .. ".Selection")
end

local editModeCallbacks = false

-- Blizzard's EventRegistry announces entering/leaving Edit Mode.
local function registerEditModeCallbacks()
    if editModeCallbacks then return end
    local reg = EventRegistry
    if type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then return end
    local ok1 = pcall(reg.RegisterCallback, reg, "EditMode.Enter",
        function() Ears.RequestRefresh("EditMode.Enter") end, Ears)
    local ok2 = pcall(reg.RegisterCallback, reg, "EditMode.Exit",
        function() Ears.RequestRefresh("EditMode.Exit") end, Ears)
    editModeCallbacks = ok1 or ok2
end

-- Post-hook visibility of unit frames and portraits. Only done out of
-- combat; in combat it is retried on PLAYER_REGEN_ENABLED.
function Ears.InstallHooks()
    if Util.InCombat() then hooksPending = true; return false end
    hooksPending = false
    for _, target in ipairs(Ears.TARGETS) do
        local ok, portrait, unitFrame = pcall(target.resolve)
        if ok then
            hookScripts(unitFrame, { "OnShow", "OnHide" }, target.key)
            hookScripts(portrait, { "OnShow", "OnHide" }, target.key .. " portrait")
            hookSelection(unitFrame, target.key)
        end
    end
    for _, name in ipairs(Ears.WATCH_FRAMES) do
        local f = field(_G, name)
        hookScripts(f, { "OnShow", "OnHide" }, name)
        hookSelection(f, name)
    end
    registerEditModeCallbacks()
    return true
end

-- Events (wired in Core.lua).
function Ears.OnEvent(event)
    if event == "PLAYER_REGEN_ENABLED" and hooksPending then Ears.InstallHooks() end
    -- Also after combat: portraits may have moved while we couldn't hook.
    Ears.RequestRefresh(event)
end

function Ears.Init()
    Ears.InstallHooks()
    Ears.Refresh()
    status.reason, status.at = "login", GetTime()
end

----------------------------------------------------------------------------
-- Diagnostics (/bunny ears debug)
----------------------------------------------------------------------------

local function isEditModeActive()
    local m = field(_G, "EditModeManagerFrame")
    if not m then return "unknown (no EditModeManagerFrame)" end
    if type(m.IsEditModeActive) == "function" then
        local ok, active = pcall(m.IsEditModeActive, m)
        if ok and type(active) == "boolean" then return active and "yes" or "no" end
    end
    return Util.IsShown(m) and "yes (manager shown)" or "no (manager hidden)"
end

local function layerText(strata, level)
    return ("%s/%s"):format(strata or "?", level and tostring(level) or "?")
end

function Ears.Describe()
    local lines = {}
    local pending, index, max = Ears.IsRefreshPending()
    lines[1] = ("ears: Edit Mode active: %s | refresh scheduled: %s%s | passes: %d"):format(
        isEditModeActive(), pending and "yes" or "no",
        pending and (" (re-check %d/%d)"):format(index, max) or "", status.passes)
    lines[2] = ("  last trigger: %s%s | last change: %s"):format(
        status.reason or "none",
        status.at and (" (%.1f s ago)"):format(GetTime() - status.at) or "",
        status.lastChangeAt and ("%.1f s ago"):format(GetTime() - status.lastChangeAt) or "never")
    for _, target in ipairs(Ears.TARGETS) do
        local ok, portrait, unitFrame = pcall(target.resolve)
        if ok and portrait then
            local o, info = target.overlay, target.layerInfo or {}
            local actualS, actualL = readLayer(o)
            lines[#lines + 1] = ("%s: %s (%s)"):format(target.key, target.reason or "not updated", target.layerSource or "-")
            lines[#lines + 1] = ("  portrait %s, unit frame %s"):format(Ears.NameOf(portrait), Ears.NameOf(unitFrame))
            lines[#lines + 1] = ("  portrait owner %s at %s"):format(Ears.NameOf(info.owner),
                layerText(info.ownerStrata, info.ownerLevel))
            lines[#lines + 1] = ("  highest overlapping %s at %s (%d frames scanned)"):format(
                Ears.NameOf(info.best), layerText(info.bestStrata, info.bestLevel), info.scanned or 0)
            lines[#lines + 1] = ("  ears want %s, have %s, corrected drift %d time(s)"):format(
                layerText(target.strata, target.level), layerText(actualS, actualL), target.drift or 0)
        else
            lines[#lines + 1] = ("%s: no portrait found"):format(target.key)
        end
    end
    return lines
end

-- Snapshot for tests and /bunny stats.
function Ears.GetState()
    local out = {}
    for _, target in ipairs(Ears.TARGETS) do
        local o = target.overlay
        out[target.key] = {
            shown = o ~= nil and o:IsShown() or false,
            reason = target.reason,
            rect = target.rect,
            overlay = o,
            strata = target.strata,
            level = target.level,
            layerSource = target.layerSource,
            layerInfo = target.layerInfo,
            drift = target.drift or 0,
        }
    end
    return out, deferred, hooksPending
end
