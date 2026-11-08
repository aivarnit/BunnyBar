-- BunnyBar: settings, SavedVariables and slash commands.

local addonName, ns = ...
local Util = ns.Util

local Config = {}
ns.Config = Config

Config.SCHEMA_VERSION = 1

-- Default settings. `point == nil` means "auto": place the track just above
-- the default action bar (see Animation.lua, Bunny:ApplyPosition).
Config.DEFAULTS = {
    schema = Config.SCHEMA_VERSION,
    shown = true,
    locked = true,
    size = 32,          -- on-screen sprite size, UI units
    speed = 1.0,        -- animation speed multiplier
    interval = 8,       -- average seconds between hops (random 50%..150%)
    trackWidth = 480,   -- horizontal track width, UI units
    hopHeight = 16,     -- peak of the hop arc, UI units
    hopDuration = 0.4,  -- seconds in the air at speed 1.0
    sleepChance = 0.15, -- chance that an idle period ends in a nap
    -- Saved position (nil = auto placement above the action bar).
    point = nil, relativePoint = nil, x = nil, y = nil,
}

-- Validation rules for numeric settings. Shared by the slash commands and by
-- Sanitize(), which repairs corrupt or hand-edited SavedVariables.
Config.LIMITS = {
    size        = { label = "Size",        min = 16,   max = 128,  integer = true },
    speed       = { label = "Speed",       min = 0.25, max = 4 },
    interval    = { label = "Interval",    min = 2,    max = 120 },
    trackWidth  = { label = "Track width", min = 64,   max = 2000, integer = true },
    hopHeight   = { label = "Hop height",  min = 0,    max = 64,   integer = true },
    hopDuration = { label = "Hop duration", min = 0.1, max = 2 },
    sleepChance = { label = "Sleep chance", min = 0,   max = 1 },
}

local VALID_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Return a clean settings table: unknown keys dropped, missing keys filled
-- from DEFAULTS, out-of-range numbers clamped, wrong types replaced.
function Config.Sanitize(db)
    if type(db) ~= "table" then db = {} end
    local clean = {}
    for key, default in pairs(Config.DEFAULTS) do
        local v = db[key]
        local limit = Config.LIMITS[key]
        if limit then
            if isFiniteNumber(v) then
                v = Util.Clamp(v, limit.min, limit.max)
                if limit.integer then v = Util.Round(v) end
            else
                v = default
            end
        elseif type(default) == "boolean" then
            if type(v) ~= "boolean" then v = default end
        end
        clean[key] = v
    end
    clean.schema = Config.SCHEMA_VERSION

    -- Position is all-or-nothing.
    if VALID_POINTS[db.point] and VALID_POINTS[db.relativePoint]
        and isFiniteNumber(db.x) and isFiniteNumber(db.y) then
        clean.point, clean.relativePoint = db.point, db.relativePoint
        clean.x, clean.y = db.x, db.y
    else
        clean.point, clean.relativePoint, clean.x, clean.y = nil, nil, nil, nil
    end
    return clean
end

function Config.Load()
    BunnyBarDB = Config.Sanitize(BunnyBarDB)
    ns.db = BunnyBarDB
    return ns.db
end

function Config.ResetAll()
    BunnyBarDB = Config.Sanitize(nil)
    ns.db = BunnyBarDB
    return ns.db
end

----------------------------------------------------------------------------
-- Chat output
----------------------------------------------------------------------------

local PREFIX = "|cffffb6c1BunnyBar|r: "

function ns.Print(msg)
    local frame = DEFAULT_CHAT_FRAME
    if frame then frame:AddMessage(PREFIX .. msg) end
end

----------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------

local HELP = {
    "|cffffd200/bunny show|r / |cffffd200hide|r - show or hide the bunny",
    "|cffffd200/bunny lock|r / |cffffd200unlock|r - lock position or enable dragging",
    "|cffffd200/bunny reset|r - restore default settings and position",
    "|cffffd200/bunny size <16-128>|r - sprite size (default 32)",
    "|cffffd200/bunny speed <0.25-4>|r - hop speed multiplier (default 1.0)",
    "|cffffd200/bunny interval <2-120>|r - average seconds between hops (default 8)",
    "|cffffd200/bunny width <64-2000>|r - track width (default 480)",
    "|cffffd200/bunny height <0-64>|r - hop height (default 16)",
    "|cffffd200/bunny test|r - trigger a test hop",
    "|cffffd200/bunny stats|r - performance and status info",
}

-- Numeric commands: command word -> settings key.
local NUMERIC = {
    size = "size",
    speed = "speed",
    interval = "interval",
    width = "trackWidth",
    height = "hopHeight",
}

local function fmt(v)
    if v == math.floor(v) then return tostring(v) end
    return ("%.2f"):format(v)
end

local function bunny() return ns.Bunny end

Config.Handlers = {
    [""] = function()
        ns.Print("commands:")
        for i = 1, #HELP do ns.Print(HELP[i]) end
    end,
    show = function()
        ns.db.shown = true
        bunny():SetShown(true)
        ns.Print("bunny shown.")
    end,
    hide = function()
        ns.db.shown = false
        bunny():SetShown(false)
        ns.Print("bunny hidden. Type /bunny show to bring it back.")
    end,
    lock = function()
        ns.db.locked = true
        bunny():SetLocked(true)
        ns.Print("position locked.")
    end,
    unlock = function()
        ns.db.locked = false
        bunny():SetLocked(false)
        ns.Print("unlocked: drag the highlighted track to move it, then /bunny lock.")
    end,
    reset = function()
        Config.ResetAll()
        bunny():ApplySettings(true)
        bunny():ApplyPosition()
        bunny():SetLocked(ns.db.locked)
        bunny():SetShown(ns.db.shown)
        ns.Print("settings and position restored to defaults.")
    end,
    test = function()
        if not ns.db.shown then
            ns.Print("the bunny is hidden. Type /bunny show first.")
            return
        end
        bunny():TestHop()
        ns.Print("hop!")
    end,
    stats = function()
        local lines = bunny():GetStats()
        for i = 1, #lines do ns.Print(lines[i]) end
    end,
}
Config.Handlers.help = Config.Handlers[""]
Config.Handlers.status = Config.Handlers.stats

-- Returns true if handled; prints an error and returns false otherwise.
function Config.HandleSlash(msg)
    local cmd, rest = Util.ParseCommand(msg)
    local handler = Config.Handlers[cmd]
    if handler then
        handler(rest)
        return true
    end

    local key = NUMERIC[cmd]
    if key then
        local limit = Config.LIMITS[key]
        if rest == "" then
            ns.Print(("%s is %s (allowed %s to %s)."):format(
                limit.label, fmt(ns.db[key]), fmt(limit.min), fmt(limit.max)))
            return true
        end
        local value, err = Util.ParseNumber(rest, limit)
        if not value then
            ns.Print("|cffff6060" .. err .. "|r")
            return false
        end
        ns.db[key] = value
        bunny():ApplySettings()
        ns.Print(("%s set to %s."):format(limit.label, fmt(value)))
        return true
    end

    ns.Print(("|cffff6060unknown command '%s'.|r Type /bunny for help."):format(cmd))
    return false
end

function Config.RegisterSlash()
    SLASH_BUNNYBAR1 = "/bunny"
    SLASH_BUNNYBAR2 = "/bunnybar"
    SlashCmdList.BUNNYBAR = Config.HandleSlash
end
