-- BunnyBar: settings, SavedVariables and slash commands.
--
-- Every change, whether from a slash command or the options panel, goes
-- through Config.Set(), which validates the value, stores it and calls
-- Config.Notify() so the bunny, portrait ears and options panel stay in sync.

local addonName, ns = ...
local Util = ns.Util

local Config = {}
ns.Config = Config

-- 1: v0.1 (size default 32). 2: appearance, portrait ears, size default 64.
-- 3: styles, idle behaviours, burrowing, hover hearts.
-- 4: furColor is an optional override (nil = use the style's default).
-- 5: personality and mood system.
-- 6: style-specific special effects (on/off + frequency).
Config.SCHEMA_VERSION = 6
Config.LEGACY_DEFAULT_SIZE = 32

-- Default settings. `point == nil` means "auto": place the track just above
-- the highest visible bottom bar (see Placement.lua).
Config.DEFAULTS = {
    schema = Config.SCHEMA_VERSION,
    shown = true,
    locked = true,
    size = 64,          -- on-screen sprite size, UI units (new installs)
    speed = 1.0,        -- animation speed multiplier
    interval = 8,       -- average seconds between hops (random 50%..150%)
    trackWidth = 480,   -- horizontal track width, UI units
    hopHeight = 16,     -- peak of the hop arc, UI units
    hopDuration = 0.4,  -- seconds in the air at speed 1.0
    sleepChance = 0.15, -- chance that an idle period ends in a nap
    -- Appearance (see Appearance.lua)
    -- furColor: custom fur colour override ("RRGGBB") or nil = the current
    -- style's own default (Appearance registry `defaultFur`). Not listed
    -- here because nil is a meaningful value; see Config.FurColor().
    variation = "classic",
    hat = "none",
    -- Portrait ears (see Ears.lua)
    earsPlayer = true,
    earsParty = true,
    -- Behaviours (see Animation.lua)
    idleExtras = true,          -- carrot, face washing, scratching, stretching, looking around
    carrot = true,
    burrow = true,
    burrowFrequency = "normal", -- rare | normal | often
    -- Interactions (see Hearts.lua)
    hearts = true,
    heartIntensity = "normal",  -- subtle | normal | extra
    -- Personality / moods (see Personality.lua)
    personality = "balanced",   -- balanced | lazy | energetic | playful | sleepy
    moods = true,
    -- Style-specific special behaviours (see Animation.lua, SpecialData.lua)
    effects = true,
    effectsFrequency = "normal", -- rare | normal | often
    -- Saved position (nil = auto placement above the bottom bars).
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

-- Size presets offered in the options panel. Any whole size 16-128 remains
-- valid via /bunny size and is shown there as "Custom".
Config.SIZE_PRESETS = {
    { key = "tiny",    label = "Tiny",    size = 16 },
    { key = "small",   label = "Small",   size = 32 },
    { key = "regular", label = "Regular", size = 64 },
    { key = "large",   label = "Large",   size = 96 },
    { key = "huge",    label = "Huge",    size = 128 },
}

-- "16, 32, 64, 96 and 128"
function Config.PresetSizesText()
    local sizes = {}
    for i, p in ipairs(Config.SIZE_PRESETS) do sizes[i] = tostring(p.size) end
    local last = table.remove(sizes)
    return table.concat(sizes, ", ") .. " and " .. last
end

function Config.PresetForSize(size)
    for _, p in ipairs(Config.SIZE_PRESETS) do
        if p.size == size then return p end
    end
    return nil
end

local VALID_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

Config.ENUMS = {
    burrowFrequency = { "rare", "normal", "often" },
    heartIntensity = { "subtle", "normal", "extra" },
    personality = { "balanced", "lazy", "energetic", "playful", "sleepy" },
    effectsFrequency = { "rare", "normal", "often" },
}

local function enumValidator(key)
    return function(v)
        if type(v) ~= "string" then return nil end
        v = v:lower()
        for _, allowed in ipairs(Config.ENUMS[key]) do
            if v == allowed then return v end
        end
        return nil
    end
end

-- String settings: return the canonical value or nil if invalid.
local STRING_VALIDATORS = {
    burrowFrequency = enumValidator("burrowFrequency"),
    heartIntensity = enumValidator("heartIntensity"),
    personality = enumValidator("personality"),
    effectsFrequency = enumValidator("effectsFrequency"),
    furColor = function(v) return (Util.ParseHex(v)) end,
    variation = function(v)
        return ns.Appearance and ns.Appearance.IsValid("variation", v) and v or nil
    end,
    hat = function(v)
        return ns.Appearance and ns.Appearance.IsValid("hat", v) and v or nil
    end,
}

-- Return a clean settings table: unknown keys dropped, missing keys filled
-- from DEFAULTS, out-of-range numbers clamped, wrong types replaced.
-- Migration: data saved before schema 2 keeps its size; if that size is
-- missing or broken it falls back to the old default (32), not the new 64.
function Config.Sanitize(db)
    local fresh = type(db) ~= "table" or next(db) == nil
    if type(db) ~= "table" then db = {} end
    local legacy = not fresh and not (isFiniteNumber(db.schema) and db.schema >= 2)

    local clean = {}
    -- Optional fur colour override; resolved against the style below.
    clean.furColor = STRING_VALIDATORS.furColor(db.furColor)
    for key, default in pairs(Config.DEFAULTS) do
        local v = db[key]
        local limit = Config.LIMITS[key]
        if key == "size" and legacy then default = Config.LEGACY_DEFAULT_SIZE end
        if limit then
            if isFiniteNumber(v) then
                v = Util.Clamp(v, limit.min, limit.max)
                if limit.integer then v = Util.Round(v) end
            else
                v = default
            end
        elseif type(default) == "boolean" then
            if type(v) ~= "boolean" then v = default end
        elseif STRING_VALIDATORS[key] then
            v = STRING_VALIDATORS[key](v) or default
        end
        clean[key] = v
    end
    -- Before schema 4 the colour was always stored. A stored colour equal to
    -- the style's default meant "not customised", so it becomes no override.
    local oldSchema = isFiniteNumber(db.schema) and db.schema or 0
    if oldSchema < 4 and clean.furColor == Config.StyleDefaultFur(clean.variation) then
        clean.furColor = nil
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
-- Change propagation
----------------------------------------------------------------------------

local APPEARANCE_KEYS = { furColor = true, variation = true, hat = true }
local EAR_KEYS = { earsPlayer = true, earsParty = true }
local HEART_KEYS = { hearts = true, heartIntensity = true }

-- Push a settings change to every part of the addon. `key == nil` means
-- "everything changed" (reset).
function Config.Notify(key)
    if not ns.db then return end
    local bunny = ns.Bunny
    if key == nil then
        if bunny then
            bunny:ApplySettings(true)
            bunny:ApplyPosition()
            bunny:SetLocked(ns.db.locked)
            bunny:SetShown(ns.db.shown)
        end
        if ns.Appearance then ns.Appearance.Apply() end
        if ns.Ears then ns.Ears.Refresh() end
        if ns.Hearts then ns.Hearts.Refresh() end
    elseif key == "effects" then
        if bunny and not ns.db.effects then bunny:CancelSpecial() end
    elseif HEART_KEYS[key] then
        if ns.Hearts then ns.Hearts.Refresh() end
    elseif APPEARANCE_KEYS[key] then
        if ns.Appearance then ns.Appearance.Apply() end
    elseif EAR_KEYS[key] then
        if ns.Ears then ns.Ears.Refresh() end
    elseif Config.LIMITS[key] then
        if bunny then bunny:ApplySettings() end
    end
    if ns.Options then ns.Options.Refresh() end
end

-- Validate and store one setting. Returns true, or false and an error.
function Config.Set(key, value)
    local db = ns.db
    if not db or (Config.DEFAULTS[key] == nil and key ~= "furColor") then
        return false, "unknown setting " .. tostring(key)
    end
    if key == "furColor" and value == nil then
        return Config.ResetFurColor()
    end
    local limit = Config.LIMITS[key]
    if limit then
        if not isFiniteNumber(value) then
            return false, ("%s must be a number."):format(limit.label)
        end
        if limit.integer and value ~= math.floor(value) then
            return false, ("%s must be a whole number."):format(limit.label)
        end
        if value < limit.min or value > limit.max then
            return false, ("%s must be between %s and %s."):format(
                limit.label, tostring(limit.min), tostring(limit.max))
        end
    elseif STRING_VALIDATORS[key] then
        local canonical = STRING_VALIDATORS[key](value)
        if not canonical then
            if key == "furColor" then return false, select(2, Util.ParseHex(value)) end
            return false, ("'%s' is not available."):format(tostring(value))
        end
        value = canonical
    elseif type(Config.DEFAULTS[key]) == "boolean" then
        value = value and true or false
    end
    if db[key] ~= value then
        db[key] = value
        Config.Notify(key)
    end
    return true
end

-- The default fur colour of a style, from the Appearance registry
-- (`defaultFur`); "F6F3FA" (classic) if the style is unknown.
Config.CLASSIC_FUR = "F6F3FA"
function Config.StyleDefaultFur(id)
    local def = ns.Appearance and ns.Appearance.Get("variation", id)
    return def and def.defaultFur or Config.CLASSIC_FUR
end

-- The fur colour actually shown: the custom override, else the style's own.
function Config.FurColor(db)
    db = db or ns.db
    if not db then return Config.CLASSIC_FUR end
    return db.furColor or Config.StyleDefaultFur(db.variation)
end

function Config.HasCustomFur(db)
    db = db or ns.db
    return db ~= nil and db.furColor ~= nil
end

-- Clear the custom colour: the current style's default applies again.
function Config.ResetFurColor()
    local db = ns.db
    if not db then return false end
    if db.furColor ~= nil then
        db.furColor = nil
        Config.Notify("furColor")
    end
    return true
end

-- Switch style. Without a custom colour the bunny takes the new style's own
-- default (Config.FurColor resolves it); a custom colour - even one equal to
-- some style's default, or white - is kept. Returns true, or false and an error.
function Config.SetStyle(id)
    if type(id) ~= "string" then return false, "Choose a style." end
    id = id:lower()
    if not (ns.Appearance and ns.Appearance.IsValid("variation", id)) then
        local names = {}
        for _, def in ipairs(ns.Appearance.List("variation")) do names[#names + 1] = def.id end
        return false, ("'%s' is not a style. Choose %s."):format(id, table.concat(names, ", "))
    end
    local db = ns.db
    if db.variation ~= id then
        db.variation = id
        Config.Notify("variation") -- also re-tints: the default may change
    end
    return true
end

----------------------------------------------------------------------------
-- Chat output
----------------------------------------------------------------------------

local PREFIX = "|cffffb6c1BunnyBar|r: "

function ns.Print(msg)
    local frame = DEFAULT_CHAT_FRAME
    if frame then frame:AddMessage(PREFIX .. msg) end
end

local function printError(msg)
    ns.Print("|cffff6060" .. msg .. "|r")
end

----------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------

local HELP = {
    "|cffffd200/bunny options|r - open the BunnyBar settings",
    "|cffffd200/bunny show|r / |cffffd200hide|r - show or hide the bunny",
    "|cffffd200/bunny lock|r / |cffffd200unlock|r - lock position or enable dragging",
    "|cffffd200/bunny reset|r - restore default settings and position",
    "|cffffd200/bunny style <classic|devil|angel|dragon|zombie>|r - bunny style",
    "|cffffd200/bunny color <#RRGGBB|reset>|r - fur colour",
    "|cffffd200/bunny size <16-128>|r - sprite size (presets: " .. Config.PresetSizesText() .. ")",
    "|cffffd200/bunny ears <player|party> <on|off>|r - bunny ears on portraits",
    "|cffffd200/bunny speed <0.25-4>|r - hop speed multiplier (default 1.0)",
    "|cffffd200/bunny interval <2-120>|r - average seconds between hops (default 8)",
    "|cffffd200/bunny width <64-2000>|r - track width (default 480)",
    "|cffffd200/bunny height <0-64>|r - hop height (default 16)",
    "|cffffd200/bunny test [hop|carrot|wash|scratch|stretch|look|burrow|nap|special|hearts]|r - try a behaviour",
    "|cffffd200/bunny idle|carrot|burrow <on|off>|r, |cffffd200/bunny burrow rare|normal|often|r - behaviours",
    "|cffffd200/bunny hearts <on|off|subtle|normal|extra>|r - hover hearts",
    "|cffffd200/bunny effects [on|off|rare|normal|often]|r - style-specific special effects",
    "|cffffd200/bunny personality <balanced|lazy|energetic|playful|sleepy>|r - personality",
    "|cffffd200/bunny mood [on|off]|r - current mood and personality",
    "|cffffd200/bunny stats|r - performance and status info",
    "|cffffd200/bunny bars|r - show which bottom bars the bunny detected",
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

local ON = { on = true, ["1"] = true, yes = true, show = true, enable = true, enabled = true, ["true"] = true }
local OFF = { off = true, ["0"] = true, no = true, hide = true, disable = true, disabled = true, ["false"] = true }

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
        Config.Notify(nil)
        ns.Print("settings and position restored to defaults.")
    end,
    test = function(rest)
        if not ns.db.shown then
            ns.Print("the bunny is hidden. Type /bunny show first.")
            return
        end
        local what = rest:lower()
        if what == "" then what = "hop" end
        if what == "hearts" then
            if not ns.db.hearts then
                printError("hover hearts are off. Type /bunny hearts on first.")
                return false
            end
            ns.Hearts.Burst()
            ns.Print("hearts!")
            return
        end
        local valid = { hop = true, carrot = true, wash = true, scratch = true, stretch = true,
                        look = true, burrow = true, nap = true, special = true }
        if not valid[what] then
            printError(("unknown test '%s'. Try hop, carrot, wash, scratch, stretch, look, burrow, nap, special or hearts."):format(what))
            return false
        end
        local ok, why = bunny():Perform(what)
        if ok and what == "special" then
            ns.Print(("%s!"):format(bunny():GetSpecialLabel() or "special"))
        elseif ok then
            ns.Print(what == "hop" and "hop!" or (what .. "!"))
        elseif why == "busy" then
            ns.Print("the bunny is mid-hop. Try again in a moment.")
        elseif why == "track" then
            printError("the track is too short to burrow. Try /bunny width 480.")
            return false
        end
    end,
    style = function(rest)
        if rest == "" then
            local names = {}
            for _, def in ipairs(ns.Appearance.List("variation")) do names[#names + 1] = def.id end
            ns.Print(("style is %s. Choose %s."):format(ns.db.variation, table.concat(names, ", ")))
            return
        end
        local ok, err = Config.SetStyle(rest)
        if not ok then printError(err); return false end
        ns.Print(("style set to %s."):format(ns.db.variation))
    end,
    hearts = function(rest)
        local v = rest:lower()
        if ON[v] or OFF[v] then
            Config.Set("hearts", ON[v] and true or false)
        elseif Config.ENUMS.heartIntensity and (v == "subtle" or v == "normal" or v == "extra") then
            Config.Set("heartIntensity", v)
            Config.Set("hearts", true)
        elseif v ~= "" then
            printError("use /bunny hearts on, off, subtle, normal or extra.")
            return false
        end
        ns.Print(("hover hearts: %s (%s)."):format(ns.db.hearts and "on" or "off", ns.db.heartIntensity))
    end,
    burrow = function(rest)
        local v = rest:lower()
        if ON[v] or OFF[v] then
            Config.Set("burrow", ON[v] and true or false)
        elseif v == "rare" or v == "normal" or v == "often" then
            Config.Set("burrowFrequency", v)
            Config.Set("burrow", true)
        elseif v ~= "" then
            printError("use /bunny burrow on, off, rare, normal or often.")
            return false
        end
        ns.Print(("burrowing: %s (%s)."):format(ns.db.burrow and "on" or "off", ns.db.burrowFrequency))
    end,
    effects = function(rest)
        local v = rest:lower()
        if ON[v] or OFF[v] then
            Config.Set("effects", ON[v] and true or false)
            -- "off" also ends a special started with /bunny test special
            if OFF[v] then bunny():CancelSpecial() end
        elseif v == "rare" or v == "normal" or v == "often" then
            Config.Set("effectsFrequency", v)
            Config.Set("effects", true)
        elseif v ~= "" then
            printError("use /bunny effects, /bunny effects on|off or /bunny effects rare|normal|often.")
            return false
        end
        ns.Print(("style effects: %s (%s). %s's special: %s - try /bunny test special."):format(
            ns.db.effects and "on" or "off", ns.db.effectsFrequency,
            ns.Appearance.CurrentVariation().label, bunny():GetSpecialLabel() or "none"))
    end,
    idle = function(rest)
        local v = rest:lower()
        if ON[v] or OFF[v] then
            Config.Set("idleExtras", ON[v] and true or false)
        elseif v ~= "" then
            printError("use /bunny idle on or off.")
            return false
        end
        ns.Print(("idle behaviours: %s."):format(ns.db.idleExtras and "on" or "off"))
    end,
    personality = function(rest)
        local v = rest:lower()
        if v == "" then
            ns.Print(("personality is %s. Choose %s."):format(
                ns.Personality.LABELS[ns.Personality.Current()], table.concat(Config.ENUMS.personality, ", ")))
            return
        end
        local ok, err = Config.Set("personality", v)
        if not ok then
            printError(("'%s' is not a personality. Choose %s."):format(rest, table.concat(Config.ENUMS.personality, ", ")))
            return false
        end
        ns.Print(("personality set to %s."):format(ns.Personality.LABELS[ns.db.personality]))
    end,
    mood = function(rest)
        local v = rest:lower()
        if ON[v] or OFF[v] then
            Config.Set("moods", ON[v] and true or false)
        elseif v ~= "" and v ~= "debug" then
            printError("use /bunny mood, /bunny mood on|off or /bunny mood debug.")
            return false
        end
        local lines = ns.Personality.Describe(v == "debug")
        for i = 1, #lines do ns.Print(lines[i]) end
    end,
    carrot = function(rest)
        local v = rest:lower()
        if ON[v] or OFF[v] then
            Config.Set("carrot", ON[v] and true or false)
        elseif v ~= "" then
            printError("use /bunny carrot on or off.")
            return false
        end
        ns.Print(("carrot eating: %s."):format(ns.db.carrot and "on" or "off"))
    end,
    stats = function()
        local lines = bunny():GetStats()
        for i = 1, #lines do ns.Print(lines[i]) end
    end,
    bars = function()
        local lines = ns.Placement.Describe(ns.db.trackWidth)
        for i = 1, #lines do ns.Print(lines[i]) end
    end,
    options = function()
        -- (Not `ns.Options and ns.Options.Open()`: `and` would drop the
        -- second return value, the error message.)
        local ok, err = false, nil
        if ns.Options then ok, err = ns.Options.Open() end
        if not ok then
            printError(err or "the options panel is not available.")
            return false
        end
    end,
    color = function(rest)
        if rest == "" then
            ns.Print(("fur colour is #%s (%s). Use /bunny color #RRGGBB or /bunny color reset."):format(
                Config.FurColor(), Config.HasCustomFur() and "custom" or ("default for " .. ns.db.variation)))
            return
        end
        if rest:lower() == "reset" then
            Config.ResetFurColor()
            ns.Print(("fur colour reset to the %s default #%s."):format(ns.db.variation, Config.FurColor()))
            return
        end
        local ok, err = Config.Set("furColor", rest)
        if not ok then printError(err); return false end
        ns.Print(("fur colour set to #%s."):format(Config.FurColor()))
    end,
    ears = function(rest)
        -- Development diagnostics (deliberately not in the help list).
        if rest:lower() == "debug" then
            local lines = ns.Ears.Describe()
            for i = 1, #lines do ns.Print(lines[i]) end
            return
        end
        local which, state = rest:lower():match("^(%S*)%s*(%S*)$")
        local key = (which == "player" and "earsPlayer") or (which == "party" and "earsParty") or nil
        if not key or not (ON[state] or OFF[state]) then
            ns.Print(("portrait ears: player %s, party %s. Use /bunny ears <player|party> <on|off>."):format(
                ns.db.earsPlayer and "on" or "off", ns.db.earsParty and "on" or "off"))
            return (which == "" and state == "") or false
        end
        Config.Set(key, ON[state] and true or false)
        ns.Print(("%s portrait ears %s."):format(which, ns.db[key] and "on" or "off"))
    end,
}
Config.Handlers.help = Config.Handlers[""]
Config.Handlers.status = Config.Handlers.stats
Config.Handlers.config = Config.Handlers.options
Config.Handlers.settings = Config.Handlers.options
Config.Handlers.colour = Config.Handlers.color

-- Returns true if handled; prints an error and returns false otherwise.
function Config.HandleSlash(msg)
    local cmd, rest = Util.ParseCommand(msg)
    local handler = Config.Handlers[cmd]
    if handler then
        return handler(rest) ~= false
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
            printError(err)
            return false
        end
        Config.Set(key, value)
        local extra = ""
        if key == "size" and not Config.PresetForSize(value) then
            extra = " (custom size; presets are " .. Config.PresetSizesText() .. ")"
        end
        ns.Print(("%s set to %s.%s"):format(limit.label, fmt(value), extra))
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
