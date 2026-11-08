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
Ears.SETTLE = 0.5        -- one re-check after the layout has settled
Ears.LEVEL_BOOST = 10    -- frame levels above the highest frame drawn there
Ears.MAX_LEVEL = 9900    -- frame levels top out at 10000
Ears.FALLBACK_STRATA = "HIGH" -- when no strata/level can be read safely
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
    local okS, strata = pcall(f.GetFrameStrata, f)
    local okL, level = pcall(f.GetFrameLevel, f)
    if not okS or Util.IsSecret(strata) or not STRATA_ORDER[strata] then strata = nil end
    if not okL or not Util.IsUsableNumber(level) then level = nil end
    return strata, level
end

local function collectChildren(f)
    return { f:GetChildren() }
end

-- Where must the ears go to be drawn in front of the portrait?
--
-- The portrait texture is drawn by its owning frame (portrait:GetParent()),
-- usually nested inside the unit frame, and the portrait ring / status
-- icons by other descendants. Their levels are NOT simply "unit frame + 1":
-- containers carry their own offsets and strata, and Edit Mode raises a
-- dragged frame, re-levelling its whole subtree. So we take the highest
-- (strata, level) among
--   * the portrait's owner and its ancestors up to the unit frame, and
--   * every *shown* frame in the unit frame's subtree (bounded scan),
-- and go LEVEL_BOOST above it. Our overlays are parented to UIParent, so
-- they are never part of the scan: refreshing can't ratchet levels upward.
-- Returns strata, level (level may be nil), and the source ("scan" or
-- "fallback").
function Ears.ComputeLayer(portrait, unitFrame)
    local bestS, bestL
    local seen, count = {}, 0
    local function consider(f, requireShown)
        if type(f) ~= "table" or seen[f] or count >= Ears.SCAN_LIMIT then return end
        seen[f] = true
        count = count + 1
        if requireShown and not Util.IsShown(f) then return end
        local strata, level = readLayer(f)
        if not (strata and level) then return end
        if not bestS or STRATA_ORDER[strata] > STRATA_ORDER[bestS] then
            bestS, bestL = strata, level
        elseif strata == bestS and level > bestL then
            bestL = level
        end
    end

    -- 1. The portrait's owner chain (always counts: it draws the portrait).
    local ok, f = false, nil
    if type(portrait) == "table" and type(portrait.GetParent) == "function" then
        ok, f = pcall(portrait.GetParent, portrait)
    end
    local depth = 0
    while ok and type(f) == "table" and depth < 8 do
        consider(f, false)
        if f == unitFrame or f == UIParent then break end
        ok, f = pcall(f.GetParent, f)
        depth = depth + 1
    end

    -- 2. Shown frames in the unit frame's subtree (borders, rings, icons).
    local function walk(frame, d)
        if count >= Ears.SCAN_LIMIT or d > Ears.SCAN_DEPTH then return end
        if not Util.IsShown(frame) then return end -- hidden subtrees don't draw
        consider(frame, true)
        if type(frame.GetChildren) ~= "function" then return end
        local okC, kids = pcall(collectChildren, frame)
        if not okC then return end
        for i = 1, #kids do walk(kids[i], d + 1) end
    end
    if type(unitFrame) == "table" then walk(unitFrame, 0) end

    if not bestS then return Ears.FALLBACK_STRATA, nil, "fallback" end
    return bestS, math.min(bestL + Ears.LEVEL_BOOST, Ears.MAX_LEVEL), "scan"
end

local function hide(target, reason)
    target.reason = reason
    if target.overlay and target.overlay:IsShown() then target.overlay:Hide() end
end

-- Update one target. Returns true if it changed position, size or visibility.
local function update(target)
    local db = ns.db
    if not db or not db[target.setting] then hide(target, "disabled"); return end
    local ok, portrait, unitFrame = pcall(target.resolve)
    if not ok or not portrait then hide(target, "missing"); return end
    if not Util.IsShown(portrait) then hide(target, "hidden"); return end
    local l, r, _, t = Util.ReadRect(portrait)
    if not l then hide(target, "no geometry"); return end

    local overlay = target.overlay or createOverlay(target)
    -- Defensive: our overlay is never anchored to protected frames, so this
    -- should not trigger; if it ever is protected, wait for combat to end.
    if Util.InCombat() and overlay.IsProtected and overlay:IsProtected() then
        deferred = true
        target.reason = "deferred (combat)"
        return
    end

    local w = (r - l) * Ears.WIDTH_RATIO
    local h = w / 2
    local cx, bottom = (l + r) / 2, t - h * Ears.OVERLAP
    overlay:SetSize(w, h)
    overlay:ClearAllPoints()
    overlay:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", cx, bottom)
    -- Layer: in front of everything drawn by the portrait's frames. Only
    -- applied when it changes (no churn on repeated refreshes).
    local strata, level, source = Ears.ComputeLayer(portrait, unitFrame)
    if target.strata ~= strata then
        overlay:SetFrameStrata(strata)
        target.strata = strata
    end
    if level and target.level ~= level then
        overlay:SetFrameLevel(level)
        target.level = level
    end
    target.layerSource = source
    target.reason = "shown"
    target.rect = target.rect or {}
    target.rect[1], target.rect[2], target.rect[3], target.rect[4] = cx, bottom, w, h
    overlay:Show()
end

----------------------------------------------------------------------------
-- Hooks and refresh scheduling
----------------------------------------------------------------------------

local hooked = {}
local hooksPending = true
local timer, settleTimer

function Ears.Refresh()
    deferred = false
    for _, target in ipairs(Ears.TARGETS) do update(target) end
end

local function onSettle()
    settleTimer = nil
    Ears.Refresh()
end

local function onDebounced()
    timer = nil
    if hooksPending then Ears.InstallHooks() end
    Ears.Refresh()
    if settleTimer then settleTimer:Cancel() end
    settleTimer = C_Timer.NewTimer(Ears.SETTLE, onSettle)
end

-- Coalesce bursts of changes (a party re-sort shows/hides several frames).
function Ears.RequestRefresh()
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(Ears.DEBOUNCE, onDebounced)
end

local function hook(f)
    if hooked[f] or type(f) ~= "table" or type(f.HookScript) ~= "function" then return end
    local ok1 = pcall(f.HookScript, f, "OnShow", Ears.RequestRefresh)
    local ok2 = pcall(f.HookScript, f, "OnHide", Ears.RequestRefresh)
    if ok1 or ok2 then hooked[f] = true end
end

-- Edit Mode drags a unit frame through its "Selection" child; refresh when
-- a drag ends so the ears follow the new position and re-layer at once.
local function hookSelection(f)
    local sel = field(f, "Selection")
    if not sel or hooked[sel] or type(sel.HookScript) ~= "function" then return end
    local ok1 = pcall(sel.HookScript, sel, "OnDragStop", Ears.RequestRefresh)
    local ok2 = pcall(sel.HookScript, sel, "OnMouseUp", Ears.RequestRefresh)
    if ok1 or ok2 then hooked[sel] = true end
end

local editModeCallbacks = false

-- Blizzard's EventRegistry announces entering/leaving Edit Mode.
local function registerEditModeCallbacks()
    if editModeCallbacks then return end
    local reg = EventRegistry
    if type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then return end
    local ok1 = pcall(reg.RegisterCallback, reg, "EditMode.Enter", Ears.RequestRefresh, Ears)
    local ok2 = pcall(reg.RegisterCallback, reg, "EditMode.Exit", Ears.RequestRefresh, Ears)
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
            hook(unitFrame)
            hook(portrait)
            hookSelection(unitFrame)
        end
    end
    for _, name in ipairs(Ears.WATCH_FRAMES) do
        local f = field(_G, name)
        hook(f)
        hookSelection(f)
    end
    registerEditModeCallbacks()
    return true
end

-- Events (wired in Core.lua).
function Ears.OnEvent(event)
    if event == "PLAYER_REGEN_ENABLED" and hooksPending then Ears.InstallHooks() end
    -- Also after combat: portraits may have moved while we couldn't hook.
    Ears.RequestRefresh()
end

function Ears.Init()
    Ears.InstallHooks()
    Ears.Refresh()
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
        }
    end
    return out, deferred, hooksPending
end
