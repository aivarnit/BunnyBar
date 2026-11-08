-- BunnyBar offline test-suite.
--
-- Runs the real addon files against tests/lua/wow_mock.lua under a stock
-- Lua 5.1 or LuaJIT interpreter (the WoW client embeds a modified Lua 5.1).
--
--   luajit tests/lua/run_tests.lua      (or: lua5.1 tests/lua/run_tests.lua)
--
-- These are static/offline tests. They do not prove in-game behaviour.

local ROOT = (arg and arg[0] or ""):match("^(.*)/tests/lua/[^/]+$") or "."
package.path = ROOT .. "/tests/lua/?.lua;" .. package.path

local mock = require("wow_mock")
local ADDON_DIR = ROOT .. "/addon/BunnyBar"
local ADDON = "BunnyBar"

----------------------------------------------------------------------------
-- Tiny test framework
----------------------------------------------------------------------------

local passed, failed, failures = 0, 0, {}
local current

local function test(name, fn)
    current = name
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        failures[#failures + 1] = name .. "\n" .. tostring(err)
        io.write("  FAIL ", name, "\n")
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(msg or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function near(actual, expected, tol, msg)
    if math.abs(actual - expected) > (tol or 1e-6) then
        error(("%s: expected ~%s, got %s"):format(msg or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or "expected truthy value", 2) end
end

local function lastChat()
    return mock.chat[#mock.chat] or ""
end

----------------------------------------------------------------------------
-- Environment
----------------------------------------------------------------------------

local ALLOWED_GLOBALS = {
    BunnyBarDB = true, SLASH_BUNNYBAR1 = true, SLASH_BUNNYBAR2 = true,
}
local leakedGlobals = {}

-- Fresh client + addon load. `saved` simulates SavedVariables from disk.
local function boot(saved, opts)
    opts = opts or {}
    setmetatable(_G, nil)
    for _, name in ipairs({ "BunnyBarDB", "BunnyBarFrame", "MainActionBar", "MainMenuBar",
        "MultiBarBottomLeft", "MultiBarBottomRight", "issecretvalue", "SLASH_BUNNYBAR1",
        "SLASH_BUNNYBAR2", "C_AddOns", "C_AddOnProfiler", "Enum", "UpdateAddOnMemoryUsage",
        "GetAddOnMemoryUsage" }) do
        _G[name] = nil
    end
    mock.install(_G)
    if opts.setup then opts.setup() end
    -- Track accidental globals written by the addon.
    setmetatable(_G, {
        __newindex = function(t, k, v)
            if not ALLOWED_GLOBALS[k] then leakedGlobals[k] = true end
            rawset(t, k, v)
        end,
    })
    local ns = mock.loadAddon(ADDON_DIR, ADDON)
    BunnyBarDB = saved -- the client restores SavedVariables before ADDON_LOADED
    mock.fire("ADDON_LOADED", "SomeOtherAddon")
    mock.fire("ADDON_LOADED", ADDON)
    if not opts.noLogin then mock.fire("PLAYER_LOGIN") end
    return ns
end

local function slash(msg)
    return SlashCmdList.BUNNYBAR(msg)
end

----------------------------------------------------------------------------
-- Util
----------------------------------------------------------------------------

io.write("Util\n")
local ns = boot(nil)
local U = ns.Util

test("ParseCommand splits and lower-cases", function()
    local c, r = U.ParseCommand("  SIZE   48  ")
    eq(c, "size"); eq(r, "48")
    c, r = U.ParseCommand("")
    eq(c, ""); eq(r, "")
    c, r = U.ParseCommand(nil)
    eq(c, ""); eq(r, "")
    c, r = U.ParseCommand("show")
    eq(c, "show"); eq(r, "")
    c, r = U.ParseCommand("speed 1.5 extra")
    eq(c, "speed"); eq(r, "1.5 extra")
end)

test("ParseNumber accepts valid input", function()
    local spec = { label = "Speed", min = 0.25, max = 4 }
    eq(U.ParseNumber("1.0", spec), 1)
    eq(U.ParseNumber(" 2.5 ", spec), 2.5)
    eq(U.ParseNumber(".5", spec), 0.5)
    eq(U.ParseNumber("4", spec), 4)
    eq(U.ParseNumber("+3", spec), 3)
end)

test("ParseNumber rejects invalid input with messages", function()
    local spec = { label = "Size", min = 16, max = 128, integer = true }
    for _, bad in ipairs({ "", "abc", "0x20", "1e2", "nan", "inf", "-inf", "32px", "3..2", "." }) do
        local v, err = U.ParseNumber(bad, spec)
        eq(v, nil, "value for '" .. bad .. "'")
        truthy(type(err) == "string" and #err > 0, "error message for '" .. bad .. "'")
    end
    local v, err = U.ParseNumber("33.5", spec)
    eq(v, nil); truthy(err:find("whole number"), err)
    v, err = U.ParseNumber("8", spec)
    eq(v, nil); truthy(err:find("between"), err)
    v, err = U.ParseNumber("129", spec)
    eq(v, nil); truthy(err:find("between"), err)
end)

test("HopArc is a parabola peaking at the hop height", function()
    near(U.HopArc(0, 16), 0)
    near(U.HopArc(1, 16), 0)
    near(U.HopArc(0.5, 16), 16)
    near(U.HopArc(0.25, 16), 12)
    near(U.HopArc(0.25, 16), U.HopArc(0.75, 16))
    near(U.HopArc(-1, 16), 0); near(U.HopArc(2, 16), 0)
end)

test("TrackBounds keeps the sprite inside the track", function()
    local lo, hi = U.TrackBounds(480, 32)
    eq(lo, 0); eq(hi, 448)
    lo, hi = U.TrackBounds(20, 32)
    eq(lo, 0); eq(hi, 0)
end)

test("ChooseDestination stays in bounds and moves far enough", function()
    math.randomseed(1234)
    for _ = 1, 20000 do
        local cur = math.random() * 448
        local d = U.ChooseDestination(cur, 0, 448, 32)
        truthy(d >= 0 and d <= 448, "destination out of bounds: " .. d)
        truthy(math.abs(d - cur) >= 32 - 1e-9, "destination too close: " .. cur .. " -> " .. d)
    end
    eq(U.ChooseDestination(0, 0, 0, 32), 0)
    -- Tiny track: min distance shrinks to half the span.
    local d = U.ChooseDestination(5, 0, 10, 32, function() return 0.5 end)
    truthy(d >= 0 and d <= 10)
end)

test("NextHopX and HopCount step towards the destination", function()
    eq(U.NextHopX(0, 100, 48), 48)
    eq(U.NextHopX(100, 0, 48), 52)
    eq(U.NextHopX(10, 20, 48), 20)
    eq(U.HopCount(0, 100, 48), 3)
    eq(U.HopCount(0, 96, 48), 2)
    eq(U.HopCount(0, 0, 48), 0)
end)

----------------------------------------------------------------------------
-- Config / SavedVariables
----------------------------------------------------------------------------

io.write("Config\n")

test("defaults match the specification", function()
    local ns2 = boot(nil)
    local db = BunnyBarDB
    eq(ns2.db, db, "ns.db is the SavedVariables table")
    eq(db.shown, true); eq(db.locked, true)
    eq(db.size, 32); eq(db.speed, 1.0); eq(db.interval, 8)
    eq(db.trackWidth, 480); eq(db.hopHeight, 16); eq(db.hopDuration, 0.4)
    eq(db.point, nil, "auto position by default")
end)

test("Sanitize repairs corrupt SavedVariables", function()
    boot({ size = "big", speed = 99, interval = -5, trackWidth = 0 / 0, hopHeight = 1 / 0,
        shown = "yes", locked = false, junk = 1, point = "NOPE", relativePoint = "BOTTOM", x = 1, y = 2 })
    local db = BunnyBarDB
    eq(db.size, 32); eq(db.speed, 4); eq(db.interval, 2); eq(db.trackWidth, 480)
    eq(db.hopHeight, 16); eq(db.shown, true); eq(db.locked, false); eq(db.junk, nil)
    eq(db.point, nil); eq(db.x, nil)
end)

test("Sanitize keeps a valid saved position and rounds integers", function()
    boot({ size = 47.6, point = "BOTTOM", relativePoint = "BOTTOM", x = -120, y = 140 })
    local db = BunnyBarDB
    eq(db.size, 48); eq(db.point, "BOTTOM"); eq(db.x, -120); eq(db.y, 140)
    local p, rel, relPoint, x, y = BunnyBarFrame:GetPoint(1)
    eq(p, "BOTTOM"); eq(rel, UIParent); eq(relPoint, "BOTTOM"); eq(x, -120); eq(y, 140)
end)

test("slash commands are registered", function()
    boot(nil)
    eq(SLASH_BUNNYBAR1, "/bunny")
    eq(type(SlashCmdList.BUNNYBAR), "function")
end)

----------------------------------------------------------------------------
-- Rendering and behaviour
----------------------------------------------------------------------------

io.write("Behaviour\n")

test("bunny spawns centred, idle, crisp, with no per-frame work", function()
    boot(nil)
    local f = BunnyBarFrame
    truthy(f:IsVisible(), "frame visible")
    eq(f:GetWidth(), 480); eq(f:GetHeight(), 48)
    eq(f._strata, "LOW"); eq(f:IsMouseEnabled(), false, "click-through while locked")
    local s = ns.Bunny:GetDebugState()
    eq(s.state, "idle"); eq(s.x, 224, "centre of track"); eq(s.y, 0)
    eq(s.onUpdate, false, "no OnUpdate while idle")
    -- Sprite texture uses nearest-neighbour filtering.
    local sprite
    for _, c in ipairs(f._children) do if c._texture then sprite = c end end
    truthy(sprite, "sprite texture")
    eq(sprite._filter, "NEAREST")
    truthy(sprite._texture:find("Interface\\AddOns\\BunnyBar\\Textures\\bunny%-idle%.tga"), sprite._texture)
    eq(sprite:GetWidth(), 32)
end)

test("ten simulated minutes: bounded, smooth, flips, rests, mostly idle", function()
    math.randomseed(42)
    local ns2 = boot(nil)
    local B = ns2.Bunny
    local db = BunnyBarDB
    local minX, maxX = ns2.Util.TrackBounds(db.trackWidth, db.size)
    local prev = B:GetDebugState()
    local frames, updateFrames, maxDx, flips = 0, 0, 0, 0
    local lastFacing = prev.facing
    local seenPoses = {}
    local idleStart, minIdle = nil, math.huge
    mock.advance(600, 1 / 60, function()
        local s = B:GetDebugState()
        frames = frames + 1
        if s.onUpdate then updateFrames = updateFrames + 1 end
        truthy(s.x >= minX - 1e-6 and s.x <= maxX + 1e-6, "x out of bounds: " .. s.x)
        truthy(s.y >= 0 and s.y <= db.hopHeight + 1e-6, "y out of range: " .. s.y)
        if s.onUpdate then eq(s.state, "air", "OnUpdate only while airborne") end
        local dx = math.abs(s.x - prev.x)
        if dx > maxDx then maxDx = dx end
        if s.facing ~= lastFacing then flips = flips + 1; lastFacing = s.facing end
        if s.state == "air" and s.destX ~= s.x then
            eq(s.facing, s.destX > s.x and 1 or -1, "faces direction of travel")
        end
        seenPoses[s.pose] = true
        -- Measure idle waits that end in a hop.
        if s.state == "idle" and prev.state ~= "idle" then idleStart = mock.now end
        if s.state == "prep" and prev.state == "idle" and idleStart then
            local waited = mock.now - idleStart
            if waited < minIdle then minIdle = waited end
        end
        prev = s
    end)
    local s = B:GetDebugState()
    truthy(s.hops > 40, "expected many hops, got " .. s.hops)
    truthy(s.journeys > 20, "journeys " .. s.journeys)
    truthy(s.naps >= 1, "expected at least one nap")
    truthy(flips >= 5, "expected direction flips, got " .. flips)
    -- 48 px per 0.4 s hop at 60 fps = 2 px per frame; no teleporting.
    truthy(maxDx <= 2.5, "per-frame movement too large: " .. maxDx)
    truthy(minIdle >= 4 - 0.05, "idle wait shorter than interval*0.5: " .. minIdle)
    local fraction = updateFrames / frames
    truthy(fraction < 0.15, ("OnUpdate active %.1f%% of frames"):format(fraction * 100))
    for _, pose in ipairs({ "idle", "blink", "prep", "jump", "land", "sleep1", "sleep2" }) do
        truthy(seenPoses[pose], "pose never shown: " .. pose)
    end
    -- Timers should not pile up.
    truthy(mock.pendingTimers() <= 3, "pending timers: " .. mock.pendingTimers())
end)

test("sprite mirrors when facing left", function()
    math.randomseed(7)
    local ns2 = boot(nil)
    local sprite
    for _, c in ipairs(BunnyBarFrame._children) do if c._texture then sprite = c end end
    local sawLeft, sawRight = false, false
    mock.advance(300, 1 / 30, function()
        local s = ns2.Bunny:GetDebugState()
        local l, r = sprite:GetTexCoord()
        if s.facing < 0 then truthy(l > r, "mirrored coords"); sawLeft = true
        else truthy(l < r, "normal coords"); sawRight = true end
    end)
    truthy(sawLeft and sawRight, "saw both directions")
end)

test("hiding stops all work; showing resumes", function()
    math.randomseed(3)
    local ns2 = boot(nil)
    mock.advance(1.05) -- let the one-shot post-login layout timer fire
    slash("test")
    mock.advance(0.3)
    eq(ns2.Bunny:GetDebugState().state, "air")
    slash("hide")
    eq(BunnyBarDB.shown, false)
    local s = ns2.Bunny:GetDebugState()
    eq(s.state, "stopped"); eq(s.onUpdate, false); eq(s.y, 0)
    eq(mock.pendingTimers(), 0, "timers cancelled")
    local x = s.x
    mock.advance(60)
    eq(ns2.Bunny:GetDebugState().x, x, "no movement while hidden")
    slash("show")
    eq(ns2.Bunny:GetDebugState().state, "idle")
    truthy(mock.pendingTimers() > 0)
end)

test("hiding the whole UI (Alt+Z) pauses the bunny", function()
    local ns2 = boot(nil)
    mock.advance(1.05)
    UIParent:Hide()
    eq(ns2.Bunny:GetDebugState().state, "stopped")
    eq(mock.pendingTimers(), 0)
    UIParent:Show()
    eq(ns2.Bunny:GetDebugState().state, "idle")
end)

test("hidden setting persists across reload", function()
    local ns2 = boot({ shown = false })
    eq(BunnyBarFrame:IsShown(), false)
    eq(ns2.Bunny:GetDebugState().state, "stopped")
    eq(mock.pendingTimers() <= 1, true, "only the one-shot layout timer")
end)

test("/bunny test triggers a hop immediately and wakes a sleeper", function()
    local ns2 = boot(nil)
    slash("test")
    eq(ns2.Bunny:GetDebugState().state, "prep")
    mock.advance(0.2)
    eq(ns2.Bunny:GetDebugState().state, "air")
    -- Put the bunny to sleep, then wake it with /bunny test.
    mock.advance(5)
    ns2.Bunny:Stop(); ns2.Bunny:Start()
    BunnyBarDB.sleepChance = 1
    for _ = 1, 600 do
        if ns2.Bunny:GetDebugState().state == "sleep" then break end
        mock.advance(0.1)
    end
    eq(ns2.Bunny:GetDebugState().state, "sleep")
    slash("test")
    eq(ns2.Bunny:GetDebugState().state, "prep", "woke up and hopped")
end)

----------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------

io.write("Slash commands\n")

test("/bunny with no args prints help", function()
    boot(nil)
    local before = #mock.chat
    slash("")
    truthy(#mock.chat - before >= 10, "help lines printed")
end)

test("numeric commands validate and apply", function()
    local ns2 = boot(nil)
    eq(slash("size 64"), true); eq(BunnyBarDB.size, 64)
    eq(BunnyBarFrame:GetHeight(), 64 + 16)
    eq(slash("size 12"), false); eq(BunnyBarDB.size, 64); truthy(lastChat():find("between"))
    eq(slash("size abc"), false); truthy(lastChat():find("not a number"))
    eq(slash("speed 1.5"), true); eq(BunnyBarDB.speed, 1.5)
    eq(slash("speed 0"), false); eq(BunnyBarDB.speed, 1.5)
    eq(slash("interval 8"), true); eq(BunnyBarDB.interval, 8)
    eq(slash("interval 1"), false)
    eq(slash("width 200"), true); eq(BunnyBarFrame:GetWidth(), 200)
    local s = ns2.Bunny:GetDebugState()
    truthy(s.x <= 200 - 64, "bunny clamped into the narrower track")
    eq(slash("height 24"), true); eq(BunnyBarDB.hopHeight, 24)
    eq(slash("size"), true); truthy(lastChat():find("Size is 64"))
end)

test("unknown commands report an error", function()
    boot(nil)
    eq(slash("dance"), false)
    truthy(lastChat():find("unknown command 'dance'"))
end)

test("lock / unlock toggle dragging and the track highlight", function()
    boot(nil)
    local f = BunnyBarFrame
    slash("unlock")
    eq(BunnyBarDB.locked, false); eq(f:IsMouseEnabled(), true)
    local backdrop = f._children[1]
    eq(backdrop._color ~= nil, true); eq(backdrop:IsShown(), true)
    -- Simulate a drag.
    f._scripts.OnDragStart(f)
    eq(f._moving, true)
    f._dragLeft, f._dragBottom = 100, 300
    f._scripts.OnDragStop(f)
    f._dragLeft, f._dragBottom = nil, nil
    eq(BunnyBarDB.point, "BOTTOM"); eq(BunnyBarDB.relativePoint, "BOTTOM")
    eq(BunnyBarDB.x, 100 + 240 - 960); eq(BunnyBarDB.y, 300)
    eq(f._userPlaced, false)
    slash("lock")
    eq(BunnyBarDB.locked, true); eq(f:IsMouseEnabled(), false); eq(backdrop:IsShown(), false)
    -- Dragging is ignored while locked.
    f._scripts.OnDragStart(f)
    eq(f._moving, false)
end)

test("/bunny reset restores defaults and auto position", function()
    local ns2 = boot({ size = 64, speed = 2, point = "BOTTOM", relativePoint = "BOTTOM", x = 5, y = 500, locked = false })
    slash("reset")
    local db = BunnyBarDB
    eq(db.size, 32); eq(db.speed, 1); eq(db.point, nil); eq(db.locked, true)
    eq(ns2.Bunny:GetDebugState().x, 224)
    local _, _, _, x, y = BunnyBarFrame:GetPoint(1)
    eq(x, 0); eq(y, 100, "fallback offset when no action bar is found")
end)

test("/bunny stats works without optional profiling APIs", function()
    boot(nil)
    local before = #mock.chat
    slash("stats")
    truthy(#mock.chat - before >= 4)
    truthy(lastChat():find("not available"))
end)

test("/bunny stats reports memory and CPU when available", function()
    boot(nil, { setup = function()
        UpdateAddOnMemoryUsage = function() end
        GetAddOnMemoryUsage = function() return 42.5 end
        Enum = { AddOnProfilerMetric = { RecentAverageTime = 1 } }
        C_AddOnProfiler = { GetAddOnMetric = function() return 0.0012 end }
    end })
    slash("stats")
    local text = table.concat(mock.chat, "\n")
    truthy(text:find("memory: 42.5 KB"), text)
    truthy(text:find("0.0012 ms"), text)
end)

----------------------------------------------------------------------------
-- Positioning
----------------------------------------------------------------------------

io.write("Positioning\n")

local function fakeBar(top, centerX, visible)
    local f = { _top = top, _cx = centerX, _visible = visible ~= false }
    function f:IsVisible() return self._visible end
    function f:GetTop() return self._top end
    function f:GetCenter() return self._cx, 0 end
    function f:GetEffectiveScale() return 1 end
    return f
end

test("auto position sits just above the detected action bars", function()
    local ns2 = boot(nil, { setup = function()
        MainActionBar = fakeBar(60, 960)
        MultiBarBottomLeft = fakeBar(105, 960)
        MultiBarBottomRight = fakeBar(150, 960, false) -- hidden bars are ignored
    end })
    local ox, oy, found = ns2.Bunny.DetectDefaultOffset()
    eq(found, true); eq(ox, 0); eq(oy, 107)
    local _, _, _, x, y = BunnyBarFrame:GetPoint(1)
    eq(x, 0); eq(y, 107)
end)

test("bars moved to the top of the screen are ignored", function()
    local ns2 = boot(nil, { setup = function() MainActionBar = fakeBar(1000, 960) end })
    local _, oy, found = ns2.Bunny.DetectDefaultOffset()
    eq(found, false); eq(oy, 100)
end)

test("secret geometry values fall back safely", function()
    local SECRET = setmetatable({}, { __lt = function() error("secret compare") end })
    local ns2 = boot(nil, { setup = function()
        issecretvalue = function(v) return v == SECRET end
        MainActionBar = fakeBar(SECRET, 960)
    end })
    local _, oy, found = ns2.Bunny.DetectDefaultOffset()
    eq(found, false); eq(oy, 100)
end)

test("secret visibility flags fall back safely", function()
    local SECRET = setmetatable({}, { __index = function() error("secret test") end })
    local ns2 = boot(nil, { setup = function()
        issecretvalue = function(v) return v == SECRET end
        local bar = fakeBar(60, 960)
        function bar:IsVisible() return SECRET end
        MainActionBar = bar
    end })
    local _, oy, found = ns2.Bunny.DetectDefaultOffset()
    eq(found, false); eq(oy, 100)
end)

test("erroring bar APIs are contained", function()
    local ns2 = boot(nil, { setup = function()
        local bar = fakeBar(60, 960)
        function bar:GetTop() error("forbidden") end
        MainMenuBar = bar
    end })
    local _, oy, found = ns2.Bunny.DetectDefaultOffset()
    eq(found, false); eq(oy, 100)
end)

test("Edit Mode layout changes re-place an auto-positioned bunny only", function()
    local ns2 = boot(nil, { setup = function() MainActionBar = fakeBar(60, 960) end })
    MainActionBar._top = 80
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED")
    local _, _, _, _, y = BunnyBarFrame:GetPoint(1)
    eq(y, 82)
    BunnyBarDB.point, BunnyBarDB.relativePoint, BunnyBarDB.x, BunnyBarDB.y = "BOTTOM", "BOTTOM", 0, 400
    ns2.Bunny:ApplyPosition()
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED")
    _, _, _, _, y = BunnyBarFrame:GetPoint(1)
    eq(y, 400)
end)

test("unknown layout events on older clients do not break loading", function()
    boot(nil, { setup = function() mock.KNOWN_EVENTS.EDIT_MODE_LAYOUTS_UPDATED = nil end })
    truthy(BunnyBarFrame:IsVisible())
    mock.KNOWN_EVENTS.EDIT_MODE_LAYOUTS_UPDATED = true
end)

----------------------------------------------------------------------------
-- Hygiene
----------------------------------------------------------------------------

io.write("Hygiene\n")

test("addon writes no unexpected globals", function()
    local names = {}
    for k in pairs(leakedGlobals) do names[#names + 1] = k end
    table.sort(names)
    eq(#names, 0, "leaked globals: " .. table.concat(names, ", "))
end)

----------------------------------------------------------------------------

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
for _, f in ipairs(failures) do io.write("\n--- ", f, "\n") end
os.exit(failed == 0 and 0 or 1)
