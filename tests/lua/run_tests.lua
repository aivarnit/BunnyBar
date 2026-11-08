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
        "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBar5", "MultiBar6", "MultiBar7",
        "OverrideActionBar", "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer",
        "StatusTrackingBarManager", "MainMenuExpBar", "ReputationWatchBar", "issecretvalue", "SLASH_BUNNYBAR1",
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

test("/bunny test triggers a hop immediately from idle", function()
    local ns2 = boot(nil)
    slash("test")
    eq(ns2.Bunny:GetDebugState().state, "prep")
    mock.advance(0.2)
    eq(ns2.Bunny:GetDebugState().state, "air")
end)

----------------------------------------------------------------------------
-- Sleep animation
----------------------------------------------------------------------------

io.write("Sleep animation\n")

local STEP = 1 / 120

-- Boot with naps forced and advance until the nap starts (state "drowsy").
local function bootNap(seed)
    math.randomseed(seed or 11)
    local ns2 = boot({ sleepChance = 1 })
    mock.advance(1.05) -- one-shot post-login layout timer
    for _ = 1, 2000 do
        if ns2.Bunny:GetDebugState().state == "drowsy" then return ns2 end
        mock.advance(STEP)
    end
    error("nap never started")
end

-- Advance until `pred(state)` is true; returns elapsed seconds.
local function advanceUntil(ns2, pred, limit)
    local t0 = mock.now
    while not pred(ns2.Bunny:GetDebugState()) do
        if mock.now - t0 > (limit or 60) then error("condition not reached") end
        mock.advance(STEP)
    end
    return mock.now - t0
end

-- Record (pose, start time) for every pose change until `pred` holds.
local function recordPoses(ns2, pred, limit)
    local log = { { pose = ns2.Bunny:GetDebugState().pose, at = mock.now } }
    local t0 = mock.now
    while true do
        local s = ns2.Bunny:GetDebugState()
        if s.pose ~= log[#log].pose then log[#log + 1] = { pose = s.pose, at = mock.now } end
        if pred(s) then break end
        if mock.now - t0 > (limit or 60) then error("recording limit reached") end
        mock.advance(STEP)
    end
    for i = 1, #log - 1 do log[i].dur = log[i + 1].at - log[i].at end
    return log
end

local function seqTotal(seq)
    local t = 0
    for i = 1, #seq do t = t + seq[i][2] end
    return t
end

test("sequence definitions: frame counts, order and timing windows", function()
    local B = ns.Bunny
    local S = B.SEQUENCES
    local function names(seq)
        local out = {}
        for i = 1, #seq do out[i] = seq[i][1] end
        return table.concat(out, ",")
    end
    eq(names(S.drowsy), "drowsy1,drowsy2,drowsy3")
    eq(names(S.liedown), "liedown1,liedown2,liedown3,liedown4")
    eq(names(S.breathe), "sleep1,sleep2,sleep3,sleep4")
    eq(names(S.wake), "wake1,wake2,wake3,wake4")
    eq(names(S.rise), "liedown4,liedown3,liedown2,liedown1")
    local function within(v, lo, hi, what)
        truthy(v >= lo - 1e-9 and v <= hi + 1e-9, ("%s total %.2fs not in %.1f-%.1f"):format(what, v, lo, hi))
    end
    within(seqTotal(S.drowsy), 0.5, 0.8, "getting sleepy")
    within(seqTotal(S.liedown), 0.5, 0.8, "lying down")
    within(seqTotal(S.breathe), 2.0, 3.0, "breathing loop")
    within(seqTotal(S.wake), 0.6, 1.0, "waking up")
    -- Every pose maps to a real frame inside its sheet.
    for name, pose in pairs(B.POSES) do
        local sheet = B.SHEETS[pose[1]]
        truthy(sheet, "sheet for " .. name)
        truthy(pose[2] >= 1 and pose[2] <= sheet.count, "frame index for " .. name)
    end
    for name, sheet in pairs(B.SHEETS) do
        truthy(sheet.slots >= sheet.count, name .. " slots >= count")
        local p = sheet.slots
        while p > 1 and p % 2 == 0 do p = p / 2 end
        eq(p, 1, name .. " slots is a power of two")
    end
end)

test("texture coordinates address padded sheets by slot", function()
    local ns2 = bootNap(5)
    local sprite
    for _, c in ipairs(BunnyBarFrame._children) do if c._texture then sprite = c end end
    advanceUntil(ns2, function(s) return s.pose == "liedown4" end)
    truthy(sprite._texture:find("bunny%-sleepy%.tga"), sprite._texture)
    local l, r = sprite:GetTexCoord()
    if l > r then l, r = r, l end
    near(l, 6 / 8); near(r, 7 / 8)
end)

test("a full nap plays every phase in order with the specified timing", function()
    local ns2 = bootNap(21)
    local x0 = ns2.Bunny:GetDebugState().x
    local onUpdateSeen = false
    local napStart = mock.now
    local log = recordPoses(ns2, function(s)
        if s.onUpdate then onUpdateSeen = true end
        truthy(s.x == x0 and s.y == 0, "bunny must not move while napping")
        return s.state == "idle"
    end, 60)
    local napLength = mock.now - napStart
    eq(onUpdateSeen, false, "no per-frame updates during a nap")

    local poses = {}
    for i = 1, #log do poses[i] = log[i].pose end
    local seqStr = table.concat(poses, " ")
    -- Expected grammar: drowsy x3, liedown x4, (breath cycle [twitch])+, wake x4, idle
    local i = 1
    local function expect(name)
        eq(poses[i], name, "frame " .. i .. " in: " .. seqStr)
        i = i + 1
    end
    for _, n in ipairs({ "drowsy1", "drowsy2", "drowsy3", "liedown1", "liedown2", "liedown3", "liedown4" }) do
        expect(n)
    end
    local cycles = 0
    while poses[i] == "sleep1" do
        for _, n in ipairs({ "sleep1", "sleep2", "sleep3", "sleep4" }) do expect(n) end
        cycles = cycles + 1
        if poses[i] == "sleepEar" or poses[i] == "sleepNose" then i = i + 1 end
    end
    for _, n in ipairs({ "wake1", "wake2", "wake3", "wake4", "idle" }) do expect(n) end
    eq(poses[i], nil, "nothing after idle")
    truthy(cycles >= 3, "breathing cycles: " .. cycles)

    -- Durations match the sequence tables (to within one simulation step).
    local want = {}
    for _, seqName in ipairs({ "drowsy", "liedown", "breathe", "wake" }) do
        for _, step in ipairs(ns2.Bunny.SEQUENCES[seqName]) do want[step[1]] = step[2] end
    end
    want.sleepEar, want.sleepNose = 0.3, 0.3
    for k = 1, #log - 1 do
        local w = want[log[k].pose]
        -- Timers fire on frame boundaries (as in the client), so allow a
        -- little over two frames of quantisation.
        if w then near(log[k].dur, w, STEP * 2.5, log[k].pose .. " duration") end
    end
    -- Whole nap: 0.74 s drowsy + 0.64 s lying + 10-25 s asleep (rounded up
    -- to whole breaths, plus twitches) + 0.88 s waking.
    truthy(napLength >= 0.74 + 0.64 + 10 + 0.88 - 0.05, "nap too short: " .. napLength)
    truthy(napLength <= 0.74 + 0.64 + 25 + 2.4 + 0.3 + 0.88 + 0.05, "nap too long: " .. napLength)
end)

test("twitches happen occasionally, only between breaths", function()
    math.randomseed(99)
    local ns2 = boot({ sleepChance = 1, interval = 2 })
    local prevPose, seen = nil, { sleepEar = 0, sleepNose = 0 }
    local afterTwitch
    mock.advance(900, STEP * 4, function()
        local p = ns2.Bunny:GetDebugState().pose
        if p ~= prevPose then
            if p == "sleepEar" or p == "sleepNose" then
                eq(prevPose, "sleep4", "twitch follows the exhale frame")
                seen[p] = seen[p] + 1
                afterTwitch = true
            elseif afterTwitch then
                truthy(p == "sleep1", "breathing resumes after a twitch, got " .. tostring(p))
                afterTwitch = false
            end
            prevPose = p
        end
    end)
    truthy(seen.sleepEar >= 2 and seen.sleepNose >= 2,
        ("ear %d, nose %d"):format(seen.sleepEar, seen.sleepNose))
end)

test("waking only starts from the resting (exhaled) frame", function()
    for seed = 1, 5 do
        local ns2 = bootNap(seed)
        local log = recordPoses(ns2, function(s) return s.pose == "wake1" end, 40)
        local before = log[#log - 1].pose
        truthy(before == "sleep4" or before == "sleepEar" or before == "sleepNose",
            "frame before waking: " .. before)
    end
end)

test("/bunny test while getting sleepy hops straight away", function()
    local ns2 = bootNap(3)
    slash("test")
    eq(ns2.Bunny:GetDebugState().state, "prep")
end)

test("/bunny test while lying down rises in reverse, then hops", function()
    local ns2 = bootNap(4)
    advanceUntil(ns2, function(s) return s.pose == "liedown3" end)
    local log
    slash("test")
    log = recordPoses(ns2, function(s) return s.state == "prep" end, 5)
    local poses = {}
    for i = 1, #log do poses[i] = log[i].pose end
    eq(table.concat(poses, ","), "liedown2,liedown1,prep")
end)

test("/bunny test while asleep plays the wake-up, then hops", function()
    local ns2 = bootNap(6)
    advanceUntil(ns2, function(s) return s.pose == "sleep2" end)
    slash("test")
    eq(ns2.Bunny:GetDebugState().state, "waking")
    local log = recordPoses(ns2, function(s) return s.state == "prep" end, 5)
    local poses = {}
    for i = 1, #log do poses[i] = log[i].pose end
    eq(table.concat(poses, ","), "wake1,wake2,wake3,wake4,prep")
    near(log[#log].at - log[1].at, seqTotal(ns2.Bunny.SEQUENCES.wake), STEP * 6, "wake duration")
end)

test("/bunny test while waking finishes waking, then hops instead of idling", function()
    local ns2 = bootNap(8)
    advanceUntil(ns2, function(s) return s.pose == "wake2" end, 40)
    slash("test")
    local log = recordPoses(ns2, function(s) return s.state == "prep" end, 5)
    local poses = {}
    for i = 1, #log do poses[i] = log[i].pose end
    eq(table.concat(poses, ","), "wake2,wake3,wake4,prep")
end)

test("hiding mid-nap pauses cleanly and resumes the nap", function()
    for _, phase in ipairs({ "drowsy2", "liedown2", "sleep3", "sleepEar" }) do
        local ns2 = bootNap(phase == "sleepEar" and 31 or 12)
        advanceUntil(ns2, function(s) return s.pose == phase end, 120)
        local left = ns2.Bunny:GetDebugState().sleepUntil - mock.now
        slash("hide")
        local s = ns2.Bunny:GetDebugState()
        eq(s.state, "stopped", phase)
        eq(s.onUpdate, false); eq(s.y, 0)
        eq(mock.pendingTimers(), 0, "no timers while hidden (" .. phase .. ")")
        eq(s.pose, "sleep1", "hidden in a valid sleeping pose (" .. phase .. ")")
        mock.advance(120) -- time passes while hidden
        eq(ns2.Bunny:GetDebugState().pose, "sleep1")
        slash("show")
        s = ns2.Bunny:GetDebugState()
        eq(s.state, "sleep", "resumes asleep (" .. phase .. ")")
        near(s.sleepUntil - mock.now, math.max(left, 1), 1e-6, "remaining nap kept")
        advanceUntil(ns2, function(st) return st.state == "idle" end, 40)
    end
end)

test("hiding while waking resumes awake", function()
    local ns2 = bootNap(13)
    advanceUntil(ns2, function(s) return s.pose == "wake3" end, 40)
    UIParent:Hide()
    eq(ns2.Bunny:GetDebugState().pose, "idle")
    eq(mock.pendingTimers(), 0)
    UIParent:Show()
    eq(ns2.Bunny:GetDebugState().state, "idle")
end)

test("changing settings mid-nap keeps the bunny asleep", function()
    local ns2 = bootNap(14)
    advanceUntil(ns2, function(s) return s.state == "sleep" end)
    eq(slash("size 48"), true)
    local s = ns2.Bunny:GetDebugState()
    eq(s.state, "sleep"); eq(s.pose, "sleep1")
    advanceUntil(ns2, function(st) return st.state == "idle" end, 40)
end)

test("after a nap the bunny hops again before napping twice", function()
    local ns2 = bootNap(15)
    advanceUntil(ns2, function(s) return s.state == "idle" end, 40)
    advanceUntil(ns2, function(s) return s.state ~= "idle" end, 20)
    eq(ns2.Bunny:GetDebugState().state, "prep", "next action is a hop")
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

-- Screen 1920x1080 at scale 1. Default bottom layout used below:
--   MainActionBar        x 674-1246, y  40- 90
--   XP container         x 674-1246, y  92-104 (bars: xp, rep)
--   MultiBarBottomLeft   x 674-1246, y 106-156 (Action Bar 2)
local function mkBar(name, l, b, w, h, shown)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetMockRect(l, b, w, h)
    if shown == false then f:Hide() end
    return f
end

local function stdLayout(cfg)
    cfg = cfg or {}
    return function()
        mkBar("MainActionBar", 674, 40, 572, 50, cfg.main ~= false)
        mkBar("MultiBarBottomLeft", 674, 106, 572, 50, cfg.ab2 ~= false)
        local xpOn, repOn = cfg.xp ~= false, cfg.rep == true
        local c = mkBar("MainStatusTrackingBarContainer", 674, 92, 572, 12,
            cfg.container ~= nil and cfg.container or (xpOn or repOn))
        c.bars = { xp = CreateFrame("Frame", nil, c), rep = CreateFrame("Frame", nil, c) }
        c.bars.xp:SetShown(xpOn)
        c.bars.rep:SetShown(repOn)
        if cfg.extra then cfg.extra() end
    end
end

local function anchorY()
    local _, _, _, _, y = BunnyBarFrame:GetPoint(1)
    return y
end
local function anchorX()
    local _, _, _, x = BunnyBarFrame:GetPoint(1)
    return x
end

test("Action Bar 2 on, XP bar on: above Action Bar 2", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    local ox, oy, found, anchor = ns2.Bunny.DetectDefaultOffset()
    eq(found, true); eq(anchor, "MultiBarBottomLeft"); eq(ox, 0); eq(oy, 158)
    eq(anchorY(), 158); eq(anchorX(), 0)
end)

test("Action Bar 2 off, XP bar on: directly above the XP bar", function()
    boot(nil, { setup = stdLayout({ ab2 = false }) })
    local _, oy, found, anchor = ns.Placement.Detect(480)
    eq(found, true); eq(anchor, "MainStatusTrackingBarContainer"); eq(oy, 106)
    eq(anchorY(), 106)
end)

test("Action Bar 2 off, XP bar off: above the main action bar", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false, xp = false }) })
    local _, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "MainActionBar"); eq(oy, 92); eq(anchorY(), 92)
end)

test("XP bar hidden but reputation bar shown: above the rep bar", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false, xp = false, rep = true }) })
    local _, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "MainStatusTrackingBarContainer"); eq(oy, 106)
end)

test("legacy XP / reputation frames are recognised", function()
    local ns2 = boot(nil, { setup = function()
        mkBar("MainMenuBar", 674, 0, 1024, 53)
        mkBar("MainMenuExpBar", 674, 53, 1024, 10, false)
        mkBar("ReputationWatchBar", 674, 53, 1024, 8)
    end })
    local _, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "ReputationWatchBar"); eq(oy, 63)
end)

test("a visible but empty status container is ignored", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false, xp = false, rep = false, container = true }) })
    local _, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "MainActionBar"); eq(oy, 92)
end)

test("all candidate bars hidden or missing: safe fallback", function()
    local ns2 = boot(nil, { setup = stdLayout({ main = false, ab2 = false, xp = false }) })
    local ox, oy, found, anchor = ns2.Placement.Detect(480)
    eq(found, false); eq(anchor, nil); eq(ox, 0); eq(oy, 100)
    eq(anchorY(), 100)
    local ns3 = boot(nil)
    eq(select(3, ns3.Placement.Detect(480)), false)
    eq(anchorY(), 100)
end)

test("invalid or unavailable geometry is skipped, next bar used", function()
    local SECRET = setmetatable({}, { __lt = function() error("secret compare") end })
    local ns2 = boot(nil, { setup = stdLayout({ extra = function()
        issecretvalue = function(v) return v == SECRET end
        -- Action Bar 2: secret top. Bar 3: errors. Bar 6: nil geometry.
        -- Bar 7: zero size. Override bar: NaN. XP container is valid.
        function MultiBarBottomLeft:GetTop() return SECRET end
        local b3 = mkBar("MultiBarBottomRight", 674, 200, 572, 50)
        function b3:GetLeft() error("forbidden") end
        local b6 = mkBar("MultiBar5", 674, 200, 572, 50)
        function b6:GetTop() return nil end
        mkBar("MultiBar6", 674, 300, 0, 0)
        local ov = mkBar("OverrideActionBar", 674, 0, 572, 50)
        function ov:GetBottom() return 0 / 0 end
        local tall = mkBar("MultiBar7", 674, 0, 572, 400)
        tall:Show()
    end }) })
    local _, oy, _, anchor, results = ns2.Placement.Detect(480)
    eq(anchor, "MainStatusTrackingBarContainer"); eq(oy, 106)
    local reasons = {}
    for _, r in ipairs(results) do reasons[r.name] = r.reason end
    eq(reasons.MultiBarBottomLeft, "no geometry")
    eq(reasons.MultiBarBottomRight, "geometry error")
    eq(reasons.MultiBar5, "no geometry")
    eq(reasons.MultiBar6, "zero size")
    eq(reasons.OverrideActionBar, "no geometry")
    eq(reasons.MultiBar7, "too tall")
end)

test("secret visibility flags are skipped safely", function()
    local SECRET = setmetatable({}, { __index = function() error("secret test") end })
    local ns2 = boot(nil, { setup = stdLayout({ extra = function()
        issecretvalue = function(v) return v == SECRET end
        function MultiBarBottomLeft:IsVisible() return SECRET end
    end }) })
    local _, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "MainStatusTrackingBarContainer"); eq(oy, 106)
end)

test("custom bar positions: follows a moved main bar, ignores off-track bars", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false, extra = function()
        -- Edit Mode: main bar + XP moved left, Action Bar 3 parked bottom-right,
        -- Action Bar 6 moved to the top of the screen.
        MainActionBar:SetMockRect(200, 40, 572, 50)
        MainStatusTrackingBarContainer:SetMockRect(200, 92, 572, 12)
        mkBar("MultiBarBottomRight", 1400, 40, 400, 120)
        mkBar("MultiBar5", 674, 900, 572, 50)
    end }) })
    local ox, oy, _, anchor, results = ns2.Placement.Detect(480)
    eq(anchor, "MainStatusTrackingBarContainer")
    eq(ox, 486 - 960, "centred on the moved main bar"); eq(oy, 106)
    local reasons = {}
    for _, r in ipairs(results) do reasons[r.name] = r.reason end
    eq(reasons.MultiBarBottomRight, "off track")
    eq(reasons.MultiBar5, "not at bottom")
    -- A wider track reaches the side bar, which is the highest.
    eq(slash("width 2000"), true)
    _, oy, _, anchor = ns2.Placement.Detect(2000)
    eq(anchor, "MultiBarBottomRight"); eq(oy, 162); eq(anchorY(), 162)
end)

test("without a main bar the bunny centres on the bar it sits on", function()
    local ns2 = boot(nil, { setup = stdLayout({ main = false, ab2 = false, extra = function()
        MainStatusTrackingBarContainer:SetMockRect(800, 0, 400, 12)
    end }) })
    local ox, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "MainStatusTrackingBarContainer"); eq(ox, 1000 - 960); eq(oy, 14)
end)

test("UI scale: bar coordinates are converted to UIParent units", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false }) })
    eq(anchorY(), 106)
    -- UI scale 0.8: UIParent grows to 2400x1350 units; a bar that keeps an
    -- effective scale of 1.0 now spans more UIParent units.
    UIParent._scale = 0.8
    UIParent:SetSize(2400, 1350)
    MainActionBar._scale, MainStatusTrackingBarContainer._scale = 0.8, 1.0
    mock.fire("UI_SCALE_CHANGED")
    mock.advance(0.3)
    local _, oy, _, anchor = ns2.Placement.Detect(480)
    eq(anchor, "MainStatusTrackingBarContainer")
    eq(oy, 130 + 2, "104 * 1.0 / 0.8 + gap"); eq(anchorY(), 132)
    UIParent._scale = 1
    UIParent:SetSize(1920, 1080)
end)

test("toggling Action Bar 2 re-places the bunny (coalesced, deferred)", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    eq(anchorY(), 158)
    MultiBarBottomLeft:Hide()
    MultiBarBottomLeft:Show()
    MultiBarBottomLeft:Hide()
    eq(ns2.Placement.IsRefreshPending(), true)
    eq(mock.pendingTimers(), 3, "1 refresh + bunny idle/fidget timers") -- refresh is coalesced
    eq(anchorY(), 158, "not moved until the deferred refresh")
    mock.advance(0.3)
    eq(anchorY(), 106, "now above the XP bar")
    MultiBarBottomLeft:Show()
    mock.advance(0.3)
    eq(anchorY(), 158)
end)

test("XP bar appearing / disappearing re-places the bunny", function()
    boot(nil, { setup = stdLayout({ ab2 = false }) })
    mock.advance(1.05)
    eq(anchorY(), 106)
    -- Level cap: XP bar inside the container hides (container stays shown).
    MainStatusTrackingBarContainer.bars.xp:Hide()
    mock.fire("PLAYER_LEVEL_UP", 80)
    mock.advance(0.3)
    eq(anchorY(), 92, "back above the main bar")
    -- Reputation tracking shows a bar again.
    MainStatusTrackingBarContainer.bars.rep:Show()
    mock.advance(0.3)
    eq(anchorY(), 106)
end)

test("level-up and Edit Mode events trigger a refresh", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    for _, ev in ipairs({ "PLAYER_LEVEL_UP", "ENABLE_XP_GAIN", "DISABLE_XP_GAIN",
        "EDIT_MODE_LAYOUTS_UPDATED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
        "PLAYER_ENTERING_WORLD", "UPDATE_EXPANSION_LEVEL" }) do
        MultiBarBottomLeft:SetMockRect(674, 106, 572, 60) -- change silently
        mock.fire(ev)
        eq(ns2.Placement.IsRefreshPending(), true, ev)
        mock.advance(0.3)
        eq(anchorY(), 168, ev)
        MultiBarBottomLeft:SetMockRect(674, 106, 572, 50)
        mock.fire(ev); mock.advance(0.3)
        eq(anchorY(), 158, ev)
    end
end)

test("unchanged results do not re-anchor the frame", function()
    boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    local calls = 0
    local orig = BunnyBarFrame.SetPoint
    BunnyBarFrame.SetPoint = function(...) calls = calls + 1; return orig(...) end
    for _ = 1, 5 do mock.fire("PLAYER_ENTERING_WORLD"); mock.advance(0.3) end
    eq(calls, 0)
    BunnyBarFrame.SetPoint = nil
end)

test("manual position overrides automatic placement until reset", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    slash("unlock")
    local f = BunnyBarFrame
    f._scripts.OnDragStart(f)
    f._dragLeft, f._dragBottom = 300, 500
    f._scripts.OnDragStop(f)
    f._dragLeft, f._dragBottom = nil, nil
    slash("lock")
    eq(anchorY(), 500)
    MultiBarBottomLeft:Hide()
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(ns2.Placement.IsRefreshPending(), false, "no refresh scheduled for a manual position")
    mock.advance(0.5)
    eq(anchorY(), 500, "manual position kept")
    slash("reset")
    eq(BunnyBarDB.point, nil)
    eq(anchorY(), 106, "reset recalculates immediately (AB2 hidden -> above XP)")
end)

test("saved manual position is restored on reload", function()
    boot({ point = "BOTTOM", relativePoint = "BOTTOM", x = -50, y = 400 }, { setup = stdLayout() })
    mock.advance(1.05)
    eq(anchorY(), 400); eq(anchorX(), -50)
end)

test("Alt+Z: no refresh while hidden, correct position when shown", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    UIParent:Hide()
    eq(ns2.Placement.IsRefreshPending(), false)
    eq(mock.pendingTimers(), 0)
    MultiBarBottomLeft:Hide() -- changed while the UI was hidden
    UIParent:Show()
    eq(anchorY(), 106, "re-placed immediately on show, no fallback flash")
end)

test("/bunny bars reports the anchor and each candidate", function()
    boot(nil, { setup = stdLayout({ ab2 = false }) })
    local before = #mock.chat
    slash("bars")
    local text = table.concat(mock.chat, "\n", before + 1)
    truthy(text:find("auto position: above MainStatusTrackingBarContainer"), text)
    truthy(text:find("MultiBarBottomLeft: hidden"), text)
    truthy(text:find("MainActionBar: visible, top 90"), text)
    truthy(text:find("<%- anchor"), text)
    truthy(text:find("not present on this client:.*MainMenuBar"), text)
end)

test("bar hooks are installed once and never replace Blizzard scripts", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    local own = function() end
    MultiBarBottomLeft:SetScript("OnShow", own)
    ns2.Placement.HookBars(); ns2.Placement.HookBars()
    eq(#MultiBarBottomLeft._hooks.OnShow, 1)
    eq(#MainStatusTrackingBarContainer.bars.xp._hooks.OnHide, 1)
    eq(MultiBarBottomLeft:GetScript("OnShow"), own)
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
