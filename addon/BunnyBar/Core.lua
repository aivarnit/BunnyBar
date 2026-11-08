-- BunnyBar: addon bootstrap and event handling.
-- Loaded last (see BunnyBar.toc), after Util, Config and Animation.

local addonName, ns = ...

local events = CreateFrame("Frame")
ns.eventFrame = events

-- Events that can change which bottom bars are visible or where they are.
-- They are occasional notifications, not polling; each one only requests a
-- coalesced, deferred re-placement (see Placement.lua), which does nothing
-- for a manually positioned bunny. Bar show/hide (e.g. toggling Action Bar 2,
-- the XP bar appearing) is caught by OnShow/OnHide hooks on the bars.
-- Registered with pcall because registering an unknown event raises an error.
local LAYOUT_EVENTS = {
    "EDIT_MODE_LAYOUTS_UPDATED", -- Edit Mode moved / toggled bars
    "UI_SCALE_CHANGED",
    "DISPLAY_SIZE_CHANGED",
    "PLAYER_ENTERING_WORLD",     -- reloads, zoning (bar layouts can change)
    "PLAYER_LEVEL_UP",           -- XP bar may hide at the level cap
    "ENABLE_XP_GAIN",            -- XP bar shown again
    "DISABLE_XP_GAIN",           -- XP bar hidden
    "UPDATE_EXPANSION_LEVEL",    -- level cap raised: XP bar returns
}

local function tryRegister(event)
    return pcall(events.RegisterEvent, events, event)
end

local function requestRefresh(event)
    ns.Placement.RequestRefresh(event)
end

local handlers = {}

function handlers.ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    events:UnregisterEvent("ADDON_LOADED")
    ns.Config.Load()
    ns.Config.RegisterSlash()
end

function handlers.PLAYER_LOGIN()
    events:UnregisterEvent("PLAYER_LOGIN")
    local db = ns.db or ns.Config.Load()
    local bunny = ns.Bunny
    bunny:Create()
    ns.Placement.HookBars()
    bunny:ApplyPosition()
    bunny:SetLocked(db.locked)
    bunny:SetShown(db.shown)
    for i = 1, #LAYOUT_EVENTS do tryRegister(LAYOUT_EVENTS[i]) end
    -- Edit Mode applies the action bar layout shortly after login; place the
    -- bunny again once that has settled.
    C_Timer.After(1, ns.Placement.Refresh)
end

local isLayoutEvent = {}
for i = 1, #LAYOUT_EVENTS do isLayoutEvent[LAYOUT_EVENTS[i]] = true end

events:SetScript("OnEvent", function(_, event, ...)
    if isLayoutEvent[event] then
        requestRefresh(event)
        return
    end
    local handler = handlers[event]
    if handler then handler(...) end
end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
