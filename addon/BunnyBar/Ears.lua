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
Ears.LEVEL_BOOST = 10    -- frame levels above the unit frame

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
    if unitFrame then
        local okS, strata = pcall(unitFrame.GetFrameStrata, unitFrame)
        local okL, level = pcall(unitFrame.GetFrameLevel, unitFrame)
        if okS and type(strata) == "string" and not Util.IsSecret(strata) then
            overlay:SetFrameStrata(strata)
        end
        if okL and Util.IsUsableNumber(level) then
            overlay:SetFrameLevel(level + Ears.LEVEL_BOOST)
        end
    end
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
        end
    end
    for _, name in ipairs(Ears.WATCH_FRAMES) do hook(field(_G, name)) end
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
        }
    end
    return out, deferred, hooksPending
end
