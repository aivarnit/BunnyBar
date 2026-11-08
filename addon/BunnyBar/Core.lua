-- BunnyBar: addon bootstrap and event handling.
-- Loaded last (see BunnyBar.toc), after Util, Config and Animation.

local addonName, ns = ...

local events = CreateFrame("Frame")
ns.eventFrame = events

-- Events that only matter while the bunny uses automatic placement. They are
-- all one-shot layout notifications, not periodic polling. Registered with
-- pcall because registering an event the client doesn't know raises an error.
local LAYOUT_EVENTS = { "EDIT_MODE_LAYOUTS_UPDATED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }

local function tryRegister(event)
    return pcall(events.RegisterEvent, events, event)
end

local function refreshAutoPosition()
    if ns.db and ns.Bunny:IsAutoPositioned() then ns.Bunny:ApplyPosition() end
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
    bunny:ApplyPosition()
    bunny:SetLocked(db.locked)
    bunny:SetShown(db.shown)
    for i = 1, #LAYOUT_EVENTS do tryRegister(LAYOUT_EVENTS[i]) end
    -- Edit Mode applies the action bar layout shortly after login; place the
    -- bunny again once that has settled.
    C_Timer.After(1, refreshAutoPosition)
end

handlers.EDIT_MODE_LAYOUTS_UPDATED = refreshAutoPosition
handlers.UI_SCALE_CHANGED = refreshAutoPosition
handlers.DISPLAY_SIZE_CHANGED = refreshAutoPosition

events:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then handler(...) end
end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
