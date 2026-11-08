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
        "StatusTrackingBarManager", "MainMenuExpBar", "ReputationWatchBar", "EditModeManagerFrame",
        "SettingsPanel", "InterfaceOptionsFrame", "Settings", "InterfaceOptions_AddCategory",
        "InterfaceOptionsFrame_OpenToCategory", "PlayerFrame", "PlayerPortrait", "PartyFrame",
        "PartyMemberFrame1", "PartyMemberFrame2", "PartyMemberFrame3", "PartyMemberFrame4",
        "PartyMemberFrame1Portrait", "PartyMemberFrame2Portrait", "PartyMemberFrame3Portrait",
        "PartyMemberFrame4Portrait", "issecretvalue", "SLASH_BUNNYBAR1",
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
    eq(db.size, 64, "new installs default to Regular (64)"); eq(db.speed, 1.0); eq(db.interval, 8)
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
    eq(f:GetWidth(), 480); eq(f:GetHeight(), 64 + 16)
    eq(f._strata, "LOW"); eq(f:IsMouseEnabled(), false, "click-through while locked")
    local s = ns.Bunny:GetDebugState()
    eq(s.state, "idle"); eq(s.x, (480 - 64) / 2, "centre of track"); eq(s.y, 0)
    eq(s.onUpdate, false, "no OnUpdate while idle")
    -- Sprite texture uses nearest-neighbour filtering.
    local sprite
    for _, c in ipairs(f._children) do if c._texture and not sprite then sprite = c end end
    truthy(sprite, "sprite texture")
    eq(sprite._filter, "NEAREST")
    truthy(sprite._texture:find("Interface\\AddOns\\BunnyBar\\Textures\\bunny%-idle%.tga"), sprite._texture)
    eq(sprite:GetWidth(), 64)
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
    -- max hop distance (1.5 x size) over 0.4 s at 60 fps, plus rounding;
    -- e.g. 96 px per hop at size 64 = 4 px per frame. No teleporting.
    local perFrame = math.max(8, db.size * 1.5) / (db.hopDuration * 60) + 0.5
    truthy(maxDx <= perFrame, "per-frame movement too large: " .. maxDx)
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
    for _, c in ipairs(BunnyBarFrame._children) do if c._texture and not sprite then sprite = c end end
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
    for _, c in ipairs(BunnyBarFrame._children) do if c._texture and not sprite then sprite = c end end
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
    eq(db.size, 64); eq(db.speed, 1); eq(db.point, nil); eq(db.locked, true)
    eq(ns2.Bunny:GetDebugState().x, (480 - 64) / 2)
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

----------------------------------------------------------------------------
-- Live repositioning
----------------------------------------------------------------------------

io.write("Live repositioning\n")

-- Count automatic placement passes (each pass calls Placement.Detect once).
local function countDetect(ns2)
    local n = { calls = 0 }
    local orig = ns2.Placement.Detect
    ns2.Placement.Detect = function(...)
        n.calls = n.calls + 1
        return orig(...)
    end
    return n
end

-- Advance until no placement refresh is pending; returns seconds taken.
local function settle(ns2, limit)
    local t0 = mock.now
    while ns2.Placement.IsRefreshPending() do
        if mock.now - t0 > (limit or 5) then error("placement never settled") end
        mock.advance(1 / 60)
    end
    return mock.now - t0
end

test("Action Bar 2 on/off/on: moves within a debounce, then settles", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    eq(anchorY(), 158)
    MultiBarBottomLeft:Hide()
    mock.advance(0.2)
    eq(anchorY(), 106, "down onto the XP bar within 0.2 s")
    truthy(settle(ns2) <= 1.1, "settle re-checks are bounded")
    MultiBarBottomLeft:Show()
    mock.advance(0.2)
    eq(anchorY(), 158, "back above Action Bar 2")
    settle(ns2)
    MultiBarBottomLeft:Hide()
    mock.advance(0.2)
    eq(anchorY(), 106)
    settle(ns2)
    eq(ns2.Placement.IsRefreshPending(), false)
end)

test("XP container hidden / shown as a whole", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false }) })
    mock.advance(1.05)
    MainStatusTrackingBarContainer:Hide()
    mock.advance(0.2)
    eq(anchorY(), 92)
    MainStatusTrackingBarContainer:Show()
    mock.advance(0.2)
    eq(anchorY(), 106)
    settle(ns2)
end)

test("reputation bar replacing the XP bar", function()
    local ns2 = boot(nil, { setup = stdLayout({ ab2 = false, extra = function()
        local sec = mkBar("SecondaryStatusTrackingBarContainer", 674, 92, 572, 8, false)
        sec.bars = { rep = CreateFrame("Frame", nil, sec) }
    end }) })
    mock.advance(1.05)
    eq(anchorY(), 106)
    -- Same container swaps XP for reputation in one go: one pass, no move.
    local n = countDetect(ns2)
    local c = MainStatusTrackingBarContainer
    c.bars.xp:Hide(); c.bars.rep:Show()
    settle(ns2)
    eq(anchorY(), 106); eq(n.calls, 1, "one coalesced pass, nothing moved")
    -- Rep moves to the (shorter) secondary container and the main one empties.
    c.bars.rep:Hide(); c:Hide()
    SecondaryStatusTrackingBarContainer:Show()
    mock.advance(0.2)
    eq(anchorY(), 102, "above the secondary rep bar")
    settle(ns2)
end)

test("Edit Mode: moved bars picked up on layout event or when Edit Mode closes", function()
    local ns2 = boot(nil, { setup = stdLayout({ extra = function()
        mkBar("EditModeManagerFrame", 0, 0, 10, 10)
        mkBar("SettingsPanel", 0, 0, 10, 10, false)
    end }) })
    mock.advance(1.05)
    -- Bar resized silently, Edit Mode closed: OnHide of the manager triggers.
    MultiBarBottomLeft:SetMockRect(674, 106, 572, 90)
    EditModeManagerFrame:Hide()
    mock.advance(0.2)
    eq(anchorY(), 198)
    -- Moved again, layout event only.
    MultiBarBottomLeft:SetMockRect(674, 106, 572, 40)
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED")
    mock.advance(0.2)
    eq(anchorY(), 148)
    -- Toggled in the Settings panel, then the panel is closed.
    SettingsPanel:Show()
    MultiBarBottomLeft._shown = false -- hidden without firing scripts
    SettingsPanel:Hide()
    mock.advance(0.2)
    eq(anchorY(), 106)
    local stats = ns2.Placement.GetStats()
    eq(stats.lastReason, "SettingsPanel hidden")
    settle(ns2)
end)

test("rapid successive changes collapse into one pass", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    local n = countDetect(ns2)
    for i = 1, 50 do
        MultiBarBottomLeft:SetShown(i % 2 == 0)
        MainStatusTrackingBarContainer.bars.xp:SetShown(i % 3 ~= 0)
        mock.advance(0.002)
    end
    -- Final: AB2 shown (i = 50), XP shown (50 % 3 ~= 0).
    eq(n.calls, 0, "nothing evaluated during the burst")
    mock.advance(0.2)
    eq(n.calls, 1, "exactly one pass after the burst")
    eq(anchorY(), 158)
    settle(ns2)
    truthy(n.calls <= 1 + #ns2.Placement.SETTLE)
end)

test("continuous changes still refresh at least every MAX_WAIT", function()
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    local n = countDetect(ns2)
    for i = 1, 30 do -- a change every 0.1 s for 3 s
        MultiBarBottomLeft:SetShown(i % 2 == 0)
        mock.advance(0.1)
    end
    truthy(n.calls >= 4, "refreshed during the storm: " .. n.calls)
    settle(ns2)
    eq(anchorY(), 158)
end)

test("frames laid out after a delay are picked up by a settle pass", function()
    local laidOut = false
    local ns2 = boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    eq(anchorY(), 158)
    -- Hiding AB2 makes Blizzard re-lay out the XP container; its geometry is
    -- unavailable for 0.4 s, then valid at a new position.
    local c = MainStatusTrackingBarContainer
    local origTop = c.GetTop
    c.GetTop = function(self) if laidOut then return origTop(self) end return nil end
    MultiBarBottomLeft:Hide()
    C_Timer.After(0.4, function()
        laidOut = true
        c:SetMockRect(674, 92, 572, 16)
    end)
    mock.advance(0.2)
    eq(anchorY(), 92, "first pass: XP not ready, sits on the main bar")
    mock.advance(0.5)
    eq(anchorY(), 110, "settle pass: above the freshly laid out XP bar")
    settle(ns2)
    -- Geometry that shifts later without any visibility change is caught too.
    MultiBarBottomLeft:Show()
    C_Timer.After(0.25, function() MultiBarBottomLeft:SetMockRect(674, 110, 572, 50) end)
    mock.advance(0.2)
    eq(anchorY(), 158)
    settle(ns2)
    eq(anchorY(), 162, "late shift picked up by the settle pass")
end)

test("settle re-checks stay bounded when geometry never becomes valid", function()
    local ns2 = boot(nil, { setup = stdLayout({ extra = function()
        local b = mkBar("MultiBarBottomRight", 674, 200, 572, 50)
        function b:GetTop() return nil end
    end }) })
    mock.advance(1.05)
    local n = countDetect(ns2)
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED")
    settle(ns2)
    eq(n.calls, 1 + #ns2.Placement.SETTLE)
    mock.advance(10)
    eq(n.calls, 1 + #ns2.Placement.SETTLE, "no further passes")
end)

test("own positioning never re-triggers a refresh (no recursion)", function()
    local ns2 = boot(nil, { setup = stdLayout({ extra = function()
        mkBar("MultiBarBottomRight", 1500, 40, 300, 40) -- off the track, hooked
    end }) })
    mock.advance(1.05)
    local f = BunnyBarFrame
    local orig = f.SetPoint
    f.SetPoint = function(...)
        -- Pathological: something toggles a hooked bar while we anchor.
        MultiBarBottomRight:SetShown(not MultiBarBottomRight:IsShown())
        return orig(...)
    end
    local n = countDetect(ns2)
    MultiBarBottomLeft:Hide()
    mock.advance(5)
    truthy(n.calls <= 1 + #ns2.Placement.SETTLE, "passes: " .. n.calls)
    eq(ns2.Placement.IsRefreshPending(), false)
    f.SetPoint = nil
end)

test("manual position: live changes never move it or schedule work", function()
    local ns2 = boot({ point = "BOTTOM", relativePoint = "BOTTOM", x = 10, y = 400 },
        { setup = stdLayout({ extra = function() mkBar("EditModeManagerFrame", 0, 0, 10, 10) end }) })
    mock.advance(1.05)
    local stats = ns2.Placement.GetStats()
    local requests = stats.requests
    MultiBarBottomLeft:Hide()
    MainStatusTrackingBarContainer.bars.xp:Hide()
    EditModeManagerFrame:Hide()
    for _, ev in ipairs({ "EDIT_MODE_LAYOUTS_UPDATED", "UI_SCALE_CHANGED", "PLAYER_LEVEL_UP" }) do
        mock.fire(ev)
    end
    eq(ns2.Placement.IsRefreshPending(), false)
    mock.advance(2)
    eq(anchorY(), 400); eq(anchorX(), 10)
    eq(stats.requests, requests, "requests ignored for manual positions")
    slash("reset")
    eq(anchorY(), 92, "reset: AB2 and XP hidden -> above the main bar")
end)

test("missing frames, missing HookScript and failing hooks are tolerated", function()
    -- No Blizzard frames at all.
    local ns2 = boot(nil)
    mock.advance(1.05)
    local _, hooks = ns2.Placement.GetStats()
    eq(hooks, 0)
    ns2.Placement.RequestRefresh("test")
    settle(ns2)
    eq(anchorY(), 100)
    -- Frames that can't be hooked: plain table, erroring HookScript.
    ns2 = boot(nil, { setup = function()
        MainActionBar = { IsVisible = function() return true end,
            GetLeft = function() return 674 end, GetRight = function() return 1246 end,
            GetBottom = function() return 40 end, GetTop = function() return 90 end,
            GetEffectiveScale = function() return 1 end }
        local b = mkBar("MultiBarBottomLeft", 674, 106, 572, 50)
        b.HookScript = function() error("not allowed") end
        mkBar("EditModeManagerFrame", 0, 0, 10, 10).HookScript = false -- method absent
    end })
    mock.advance(1.05)
    _, hooks = ns2.Placement.GetStats()
    eq(hooks, 0, "nothing hookable")
    eq(anchorY(), 158, "placement itself still works")
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED") -- events remain a fallback path
    settle(ns2)
    local before = #mock.chat
    slash("bars")
    truthy(table.concat(mock.chat, "\n", before + 1):find("0 frames hooked"))
end)

test("/bunny bars shows live-update diagnostics", function()
    boot(nil, { setup = stdLayout() })
    mock.advance(1.05)
    MultiBarBottomLeft:Hide()
    mock.advance(0.2)
    local before = #mock.chat
    slash("bars")
    local text = table.concat(mock.chat, "\n", before + 1)
    truthy(text:find("live updates: %d+ frames hooked, %d+ refreshes %(%d+ moves%)"), text)
    truthy(text:find("last trigger: MultiBarBottomLeft hidden"), text)
end)

test("unknown layout events on older clients do not break loading", function()
    boot(nil, { setup = function() mock.KNOWN_EVENTS.EDIT_MODE_LAYOUTS_UPDATED = nil end })
    truthy(BunnyBarFrame:IsVisible())
    mock.KNOWN_EVENTS.EDIT_MODE_LAYOUTS_UPDATED = true
end)

----------------------------------------------------------------------------
-- v0.2: colour maths
----------------------------------------------------------------------------

io.write("Colour\n")

test("hex parsing accepts #RRGGBB / RRGGBB in any case", function()
    local U = ns.Util
    local cases = { ["#FFFFFF"] = { "FFFFFF", 1, 1, 1 }, ["#FFB6C1"] = { "FFB6C1", 1, 182 / 255, 193 / 255 },
        ["#87ceeb"] = { "87CEEB", 135 / 255, 206 / 255, 235 / 255 }, ["000000"] = { "000000", 0, 0, 0 },
        ["  #a0522d "] = { "A0522D", 160 / 255, 82 / 255, 45 / 255 } }
    for input, want in pairs(cases) do
        local hex, r, g, b = U.ParseHex(input)
        eq(hex, want[1], input); near(r, want[2]); near(g, want[3]); near(b, want[4])
    end
end)

test("invalid hex input is rejected with a message", function()
    for _, bad in ipairs({ "", "#FFF", "FFF", "#FFFFFFF", "#GGGGGG", "pink", "# FFFFFF", "0xFFFFFF", "#12345" }) do
        local hex, err = ns.Util.ParseHex(bad)
        eq(hex, nil, bad); truthy(type(err) == "string" and err:find("hex"), bad)
    end
    eq((ns.Util.ParseHex(nil)), nil)
    eq((ns.Util.ParseHex(42)), nil)
end)

test("RGB <-> HSV round-trips and known values", function()
    local U = ns.Util
    local h, s, v = U.RGBToHSV(1, 0, 0); near(h, 0); near(s, 1); near(v, 1)
    h, s, v = U.RGBToHSV(0, 1, 0); near(h, 120)
    h, s, v = U.RGBToHSV(0, 0, 1); near(h, 240)
    h, s, v = U.RGBToHSV(0.5, 0.5, 0.5); near(s, 0); near(v, 0.5)
    for r = 0, 255, 15 do for g = 0, 255, 51 do for b = 0, 255, 85 do
        local hex = U.RGBToHex(r / 255, g / 255, b / 255)
        eq(U.RGBToHex(U.HSVToRGB(U.RGBToHSV(r / 255, g / 255, b / 255))), hex, hex)
    end end end
    eq(U.RGBToHex(U.HSVToRGB(360 + 120, 1, 1)), "00FF00", "hue wraps")
end)

----------------------------------------------------------------------------
-- v0.2: SavedVariables migration
----------------------------------------------------------------------------

io.write("Migration\n")

test("v0.1 settings are preserved, new keys get defaults", function()
    local old = { schema = 1, shown = false, locked = false, size = 32, speed = 2, interval = 10,
        trackWidth = 600, hopHeight = 20, hopDuration = 0.5, sleepChance = 0.3,
        point = "BOTTOM", relativePoint = "BOTTOM", x = 15, y = 300 }
    boot(old)
    local db = BunnyBarDB
    eq(db.schema, 2)
    for k, v in pairs(old) do if k ~= "schema" then eq(db[k], v, k) end end
    eq(db.furColor, "F6F3FA"); eq(db.variation, "classic"); eq(db.hat, "none")
    eq(db.earsPlayer, true); eq(db.earsParty, true)
end)

test("v0.1 data with a broken size falls back to the old default 32", function()
    boot({ schema = 1, size = "huge", speed = 1 })
    eq(BunnyBarDB.size, 32)
    boot({ speed = 1 }) -- pre-schema data
    eq(BunnyBarDB.size, 32)
    boot(nil)
    eq(BunnyBarDB.size, 64, "fresh install")
    boot({ schema = 2, size = 48 })
    eq(BunnyBarDB.size, 48, "custom size kept")
end)

test("invalid appearance values are repaired, valid ones canonicalised", function()
    boot({ schema = 2, furColor = "#ffb6c1", variation = "fancy", hat = 7, earsPlayer = "yes" })
    local db = BunnyBarDB
    eq(db.furColor, "FFB6C1"); eq(db.variation, "classic"); eq(db.hat, "none"); eq(db.earsPlayer, true)
    boot({ schema = 2, furColor = "not a colour" })
    eq(BunnyBarDB.furColor, "F6F3FA")
end)

test("appearance registry: classic + none only", function()
    local ns2 = boot(nil)
    local A = ns2.Appearance
    truthy(A.IsValid("variation", "classic")); truthy(A.IsValid("hat", "none"))
    eq(A.IsValid("variation", "fancy"), false); eq(A.IsValid("hat", nil), false)
    eq(#A.List("variation"), 1); eq(#A.List("hat"), 1)
    truthy(A.SheetPath("bunny-idle.tga"):find("BunnyBar\\Textures\\bunny-idle.tga", 1, true))
end)

----------------------------------------------------------------------------
-- v0.2: colour on the sprite
----------------------------------------------------------------------------

io.write("Recolouring\n")

local function bunnyLayers()
    local fur, detail
    for _, ch in ipairs(BunnyBarFrame._children) do
        if ch._texture then
            if not fur then fur = ch elseif not detail then detail = ch end
        end
    end
    return fur, detail
end

test("fur layer is tinted, detail layer never is, both share frames", function()
    local ns2 = boot(nil)
    local fur, detail = bunnyLayers()
    eq(fur._sublevel, 0); eq(detail._sublevel, 1)
    local r, g, b = fur:GetVertexColor()
    near(r, 0xF6 / 255); near(g, 0xF3 / 255); near(b, 0xFA / 255)
    eq(slash("color #87CEEB"), true)
    r, g, b = fur:GetVertexColor()
    near(r, 0x87 / 255); near(g, 0xCE / 255); near(b, 0xEB / 255)
    eq(detail._vertex, nil, "detail layer untinted")
    eq(fur._filter, "NEAREST"); eq(detail._filter, "NEAREST")
    local fl, fr, ft, fb = fur:GetTexCoord()
    local dl, dr, dt, db_ = detail:GetTexCoord()
    eq(fl, dl); eq(fr, dr); eq(ft, 0); eq(fb, 0.5); eq(dt, 0.5); eq(db_, 1)
end)

test("colour stays applied through every animation and sheet change", function()
    math.randomseed(5)
    local ns2 = boot({ schema = 2, sleepChance = 0.5, furColor = "FFB6C1" })
    local fur, detail = bunnyLayers()
    local sheets, poses = {}, {}
    mock.advance(400, 1 / 30, function()
        local r, g, b = fur:GetVertexColor()
        near(r, 1); near(g, 0xB6 / 255); near(b, 0xC1 / 255)
        eq(fur._texture, detail._texture, "layers show the same sheet")
        sheets[fur._texture] = true
        poses[ns2.Bunny:GetDebugState().pose] = true
    end)
    local n = 0
    for _ in pairs(sheets) do n = n + 1 end
    eq(n, 6, "all six sheets shown")
    for _, p in ipairs({ "blink", "jump", "land", "sleep2", "wake3", "drowsy2" }) do truthy(poses[p], p) end
end)

test("/bunny color: validation, reset and query", function()
    boot(nil)
    eq(slash("color pink"), false)
    truthy(lastChat():find("not a colour"))
    eq(BunnyBarDB.furColor, "F6F3FA", "unchanged after bad input")
    eq(slash("color ffb6c1"), true); eq(BunnyBarDB.furColor, "FFB6C1")
    eq(slash("color"), true); truthy(lastChat():find("#FFB6C1"))
    eq(slash("color reset"), true); eq(BunnyBarDB.furColor, "F6F3FA")
end)

----------------------------------------------------------------------------
-- v0.2: Settings panel
----------------------------------------------------------------------------

io.write("Options panel\n")

local function settingsAPI(rec)
    return function()
        Settings = {
            RegisterCanvasLayoutCategory = function(frame, name)
                local cat = { name = name, frame = frame, ID = 4242 }
                function cat:GetID() return self.ID end
                rec.category = cat
                return cat
            end,
            RegisterAddOnCategory = function(cat) rec.registered = cat end,
            OpenToCategory = function(id) rec.opened = id; rec.category.frame:Show() end,
        }
        if rec.extra then rec.extra() end
    end
end

local function bootPanel(saved, extra)
    local rec = { extra = extra }
    local ns2 = boot(saved, { setup = settingsAPI(rec) })
    eq(slash("options"), true)
    return ns2, ns2.Options.controls, rec
end

test("registers an AddOns category and /bunny options opens it", function()
    local ns2, c, rec = bootPanel(nil)
    eq(ns2.Options.mode, "settings")
    eq(rec.category.name, "BunnyBar"); eq(rec.registered, rec.category)
    eq(rec.opened, 4242)
    truthy(ns2.Options.IsBuilt(), "built lazily on first show")
    eq(c.hex:GetText(), "#F6F3FA")
end)

test("panel is not built until it is shown", function()
    local rec = {}
    local ns2 = boot(nil, { setup = settingsAPI(rec) })
    eq(ns2.Options.IsBuilt(), false)
end)

test("legacy InterfaceOptions fallback", function()
    local opened = 0
    local ns2 = boot(nil, { setup = function()
        InterfaceOptions_AddCategory = function(panel) panel._legacy = true end
        InterfaceOptionsFrame_OpenToCategory = function(panel) opened = opened + 1; panel:Show() end
    end })
    eq(ns2.Options.mode, "legacy")
    eq(slash("options"), true)
    eq(opened, 2); truthy(ns2.Options.IsBuilt())
end)

test("no settings API: /bunny options explains instead of failing", function()
    local ns2 = boot(nil)
    eq(ns2.Options.mode, "none")
    eq(slash("options"), false)
    truthy(lastChat():find("isn't available"), lastChat())
end)

test("a failing Settings API falls back safely", function()
    local ns2 = boot(nil, { setup = function()
        Settings = { RegisterCanvasLayoutCategory = function() error("blocked") end,
                     RegisterAddOnCategory = function() end }
    end })
    eq(ns2.Options.mode, "none")
end)

test("/bunny options in combat opens after combat", function()
    local rec = {}
    local ns2 = boot(nil, { setup = settingsAPI(rec) })
    mock.combat = true
    eq(slash("options"), true)
    eq(rec.opened, nil); truthy(lastChat():find("when combat ends"))
    mock.combat = false
    mock.fire("PLAYER_REGEN_ENABLED")
    eq(rec.opened, 4242)
end)

test("missing widget templates degrade to plain widgets", function()
    for _, t in ipairs({ "UIRadioButtonTemplate", "UICheckButtonTemplate", "InputBoxTemplate", "UIPanelButtonTemplate" }) do
        mock.MISSING_TEMPLATES[t] = true
    end
    local ns2, c = bootPanel(nil)
    truthy(ns2.Options.IsBuilt()); eq(c.hex._template, nil); eq(#c.sizes, 5)
    mock.MISSING_TEMPLATES = {}
end)

test("hex box, sliders, square, swatch and bunny stay in sync", function()
    local ns2, c = bootPanel(nil)
    local fur = bunnyLayers()
    c.hex:MockType("#FF0000")
    eq(BunnyBarDB.furColor, "FF0000"); eq(c.hex:GetText(), "#FF0000")
    eq(c.hue:GetValue(), 0); eq(c.brightness:GetValue(), 100)
    local _, _, _, mx, my = c.marker:GetPoint(1)
    near(mx, 150); near(my, 150)
    local r, g, b = fur:GetVertexColor(); near(r, 1); near(g, 0); near(b, 0)
    eq(c.swatch._color[1], 1)

    c.hue:SetValue(120, true) -- user drags hue
    eq(BunnyBarDB.furColor, "00FF00"); eq(c.hex:GetText(), "#00FF00")
    c.brightness:SetValue(50, true) -- user drags brightness
    eq(BunnyBarDB.furColor, "008000"); eq(c.hue:GetValue(), 120)
    _, _, _, mx, my = c.marker:GetPoint(1)
    near(my, 75, 1e-6, "square marker follows the brightness slider")

    -- Drag on the saturation/brightness square: OnUpdate only while held.
    c.square:SetMockRect(100, 100, 150, 150)
    mock.cursor[1], mock.cursor[2] = 175, 250 -- s = 0.5, v = 1
    c.square._scripts.OnMouseDown(c.square)
    truthy(c.square:GetScript("OnUpdate"), "tracking while held")
    eq(BunnyBarDB.furColor, "80FF80")
    eq(c.brightness:GetValue(), 100, "brightness slider follows the square")
    mock.cursor[1], mock.cursor[2] = 100, 100 -- s = 0, v = 0
    mock.advance(1 / 60)
    eq(BunnyBarDB.furColor, "000000")
    c.square._scripts.OnMouseUp(c.square)
    eq(c.square:GetScript("OnUpdate"), nil, "no OnUpdate after release")

    -- A grey keeps the hue the user chose.
    eq(slash("color #808080"), true)
    eq(c.hue:GetValue(), 120); eq(c.hex:GetText(), "#808080")
    -- Slash command -> panel.
    eq(slash("color #87CEEB"), true)
    eq(c.hex:GetText(), "#87CEEB"); eq(c.hue:GetValue(), 197)
end)

test("invalid hex in the panel shows an error and keeps the colour", function()
    local ns2, c = bootPanel({ schema = 2, furColor = "FFB6C1" })
    c.hex:MockType("#GGGGGG")
    eq(BunnyBarDB.furColor, "FFB6C1")
    truthy(c.error:IsShown()); truthy(c.error:GetText():find("not a colour"))
    eq(c.hex:GetText(), "#FFB6C1", "box reverts")
    c.hex:MockType("#87CEEB")
    eq(c.error:IsShown(), false)
    c.reset:Click()
    eq(BunnyBarDB.furColor, "F6F3FA"); eq(c.hex:GetText(), "#F6F3FA")
end)

test("size presets: radios, custom sizes, slash sync", function()
    local ns2, c = bootPanel({ schema = 2, size = 32 })
    local function checked()
        local out = {}
        for i, rb in ipairs(c.sizes) do if rb:GetChecked() then out[#out + 1] = i end end
        return table.concat(out, ",")
    end
    eq(checked(), "2", "Small for an existing 32 user")
    eq(c.customSize:IsShown(), false)
    c.sizes[5]:Click()
    eq(BunnyBarDB.size, 128); eq(checked(), "5", "Huge")
    eq(bunnyLayers():GetWidth(), 128, "applies immediately")
    c.sizes[4]:Click()
    eq(BunnyBarDB.size, 96); eq(checked(), "4", "Large")
    eq(slash("size 48"), true)
    truthy(lastChat():find("custom size"))
    eq(BunnyBarDB.size, 48, "custom size kept, not snapped to a preset")
    eq(checked(), ""); truthy(c.customSize:IsShown()); truthy(c.customSize:GetText():find("48"))
    eq(slash("size 16"), true)
    eq(checked(), "1"); eq(c.customSize:IsShown(), false)
    c.sizes[3]:Click()
    eq(BunnyBarDB.size, 64)
end)

test("five size presets in order; default stays Regular 64", function()
    local ns2 = boot(nil)
    local P = ns2.Config.SIZE_PRESETS
    local got = {}
    for i, p in ipairs(P) do got[i] = p.label .. "=" .. p.size end
    eq(table.concat(got, ","), "Tiny=16,Small=32,Regular=64,Large=96,Huge=128")
    eq(ns2.Config.DEFAULTS.size, 64); eq(BunnyBarDB.size, 64)
    eq(ns2.Config.PresetForSize(96).label, "Large"); eq(ns2.Config.PresetForSize(128).label, "Huge")
    eq(ns2.Config.PresetForSize(48), nil)
    eq(ns2.Config.PresetSizesText(), "16, 32, 64, 96 and 128")
    local before = #mock.chat
    slash("")
    truthy(table.concat(mock.chat, "\n", before + 1):find("presets: 16, 32, 64, 96 and 128"))
end)

test("saved sizes persist and map onto the new presets", function()
    local cases = { { 32, 2 }, { 96, 4 }, { 128, 5 }, { 16, 1 }, { 64, 3 } }
    for _, case in ipairs(cases) do
        local _, c = bootPanel({ schema = 2, size = case[1] })
        eq(BunnyBarDB.size, case[1])
        for i, rb in ipairs(c.sizes) do eq(rb:GetChecked(), i == case[2], case[1] .. " radio " .. i) end
        eq(c.customSize:IsShown(), false)
    end
    -- v0.1 data keeps 32; a v0.2 custom 48 and 100 stay custom.
    boot({ schema = 1, size = 32 }); eq(BunnyBarDB.size, 32)
    for _, custom in ipairs({ 48, 100 }) do
        local _, c = bootPanel({ schema = 2, size = custom })
        eq(BunnyBarDB.size, custom); truthy(c.customSize:IsShown())
    end
    -- A preset chosen in the panel survives a reload.
    local _, c = bootPanel(nil)
    c.sizes[4]:Click()
    local saved = BunnyBarDB
    boot(saved)
    eq(BunnyBarDB.size, 96)
    eq(slash("size 96"), true); eq(lastChat():find("custom"), nil, "96 is a preset now")
    eq(slash("size 97"), true); truthy(lastChat():find("custom size; presets are 16, 32, 64, 96 and 128"))
end)

test("five radios fit above the Portrait Accessories section", function()
    local ns2, c = bootPanel({ schema = 2, size = 48 })
    local L = ns2.Options.layout
    local RADIO_H, LABEL_H = 18, 12
    for i, rb in ipairs(c.sizes) do
        local _, _, _, _, y = rb:GetPoint(1)
        truthy(y - RADIO_H > L.portraitTop, "radio " .. i .. " overlaps the portrait section")
        if i > 1 then
            local _, _, _, _, prevY = c.sizes[i - 1]:GetPoint(1)
            truthy(prevY - y >= RADIO_H, "radios " .. (i - 1) .. "/" .. i .. " overlap")
        end
    end
    local _, _, _, _, cy = c.customSize:GetPoint(1)
    local _, _, _, _, lastY = c.sizes[5]:GetPoint(1)
    truthy(cy <= lastY - RADIO_H, "custom label below the last radio")
    truthy(cy - LABEL_H > L.portraitTop, "custom label clear of the portrait section")
    local _, _, _, _, ey = c.ears.earsPlayer:GetPoint(1)
    truthy(ey < L.portraitTop, "checkboxes inside the portrait section")
    truthy(L.stylesTop < L.portraitBottom, "styles below portraits")
end)

test("portrait checkboxes and /bunny ears stay in sync", function()
    local ns2, c = bootPanel(nil)
    eq(c.ears.earsPlayer:GetChecked(), true); eq(c.ears.earsParty:GetChecked(), true)
    c.ears.earsParty:Click()
    eq(BunnyBarDB.earsParty, false)
    eq(slash("ears player off"), true)
    eq(BunnyBarDB.earsPlayer, false); eq(c.ears.earsPlayer:GetChecked(), false)
    eq(slash("ears party on"), true); eq(c.ears.earsParty:GetChecked(), true)
    eq(slash("ears party maybe"), false)
end)

test("/bunny reset restores everything and updates the open panel", function()
    local ns2, c = bootPanel({ schema = 2, size = 128, furColor = "000000", earsPlayer = false })
    slash("reset")
    eq(BunnyBarDB.size, 64); eq(BunnyBarDB.furColor, "F6F3FA"); eq(BunnyBarDB.earsPlayer, true)
    eq(c.hex:GetText(), "#F6F3FA"); eq(c.sizes[3]:GetChecked(), true)
    eq(c.ears.earsPlayer:GetChecked(), true)
    local r = bunnyLayers():GetVertexColor(); near(r, 0xF6 / 255)
end)

test("styles section is informational only (no fake selectors)", function()
    local ns2, c = bootPanel(nil)
    eq(c.styles._kind, "FontString")
    truthy(c.styles:GetText():find("Classic")); truthy(c.styles:GetText():find("None"))
end)

----------------------------------------------------------------------------
-- v0.2: portrait ears
----------------------------------------------------------------------------

io.write("Portrait ears\n")

-- Modern frames: PlayerFrame.PlayerFrameContainer.PlayerPortrait and
-- PartyFrame.MemberFrameN.Portrait. Portrait rect: (l, b, size, size).
local function mkPlayer(l, b, size)
    local pf = CreateFrame("Button", "PlayerFrame", UIParent)
    pf:SetMockRect(l - 20, b - 20, 230, size + 40)
    pf._strata, pf._level = "LOW", 5
    pf.PlayerFrameContainer = CreateFrame("Frame", nil, pf)
    local p = pf.PlayerFrameContainer:CreateTexture(nil, "BACKGROUND")
    p:SetMockRect(l, b, size, size)
    pf.PlayerFrameContainer.PlayerPortrait = p
    return pf
end

local function mkParty(shown)
    local party = CreateFrame("Frame", "PartyFrame", UIParent)
    for i = 1, 4 do
        local m = CreateFrame("Button", nil, party)
        m:SetMockRect(40, 700 - i * 60, 120, 50)
        m.Portrait = m:CreateTexture(nil, "BACKGROUND")
        m.Portrait:SetMockRect(40, 700 - i * 60, 40, 40)
        if i > shown then m:Hide() end
        party["MemberFrame" .. i] = m
    end
    return party
end

local function ears(ns2) return (ns2.Ears.GetState()) end

test("player ears sit centred on top of the portrait, scaled to it", function()
    local ns2 = boot(nil, { setup = function() mkPlayer(100, 900, 60) end })
    local e = ears(ns2).player
    eq(e.shown, true)
    -- width 0.8 x 60 = 48, height 24, overlapping the portrait by 25 %.
    near(e.rect[1], 130); near(e.rect[2], 960 - 6); near(e.rect[3], 48); near(e.rect[4], 24)
    local o = e.overlay
    eq(o._parent, UIParent, "parented to UIParent, not the unit frame")
    local _, rel = o:GetPoint(1)
    eq(rel, UIParent, "anchored to UIParent, never to Blizzard frames")
    eq(o:IsMouseEnabled(), false, "click-through")
    eq(o._strata, "LOW"); eq(o._level, 15, "drawn above the unit frame")
    eq(#PlayerFrame._hooks.OnShow, 1, "post-hook only")
    eq(PlayerFrame:GetScript("OnShow"), nil, "Blizzard scripts untouched")
end)

test("ears follow portrait visibility and the settings", function()
    local ns2 = boot(nil, { setup = function() mkPlayer(100, 900, 60) end })
    PlayerFrame:Hide()
    mock.advance(0.15)
    eq(ears(ns2).player.shown, false); eq(ears(ns2).player.reason, "hidden")
    PlayerFrame:Show()
    mock.advance(0.15)
    eq(ears(ns2).player.shown, true)
    slash("ears player off")
    eq(ears(ns2).player.shown, false, "immediately")
    slash("ears player on")
    eq(ears(ns2).player.shown, true)
end)

test("party ears: joining, leaving and re-sorting", function()
    local ns2 = boot(nil, { setup = function() mkParty(2) end })
    local st = ears(ns2)
    eq(st.party1.shown, true); eq(st.party2.shown, true); eq(st.party3.shown, false)
    eq(st.player.reason, "missing")
    -- A third member joins.
    PartyFrame.MemberFrame3:Show()
    mock.fire("GROUP_ROSTER_UPDATE")
    mock.advance(0.15)
    eq(ears(ns2).party3.shown, true)
    -- Member 2 leaves.
    PartyFrame.MemberFrame2:Hide()
    mock.advance(0.15)
    eq(ears(ns2).party2.shown, false)
    -- Frames re-sorted (positions change without show/hide).
    PartyFrame.MemberFrame1.Portrait:SetMockRect(40, 400, 40, 40)
    mock.fire("GROUP_ROSTER_UPDATE")
    mock.advance(0.15)
    near(ears(ns2).party1.rect[1], 60); near(ears(ns2).party1.rect[2], 440 - 4)
    slash("ears party off")
    st = ears(ns2)
    eq(st.party1.shown, false); eq(st.party3.shown, false)
end)

test("legacy portrait globals are supported", function()
    local ns2 = boot(nil, { setup = function()
        local pf = CreateFrame("Button", "PlayerFrame", UIParent)
        local p = pf:CreateTexture(nil, "BACKGROUND")
        p:SetMockRect(50, 950, 64, 64)
        PlayerPortrait = p
        local m = CreateFrame("Button", "PartyMemberFrame1", UIParent)
        local mp = m:CreateTexture(nil, "BACKGROUND")
        mp:SetMockRect(30, 700, 37, 37)
        PartyMemberFrame1Portrait = mp
    end })
    local st = ears(ns2)
    eq(st.player.shown, true); eq(st.party1.shown, true); eq(st.party2.reason, "missing")
end)

test("missing portrait frames: nothing created, nothing breaks", function()
    local ns2 = boot(nil)
    for key, e in pairs(ears(ns2)) do
        eq(e.shown, false, key); eq(e.reason, "missing", key); eq(e.overlay, nil, key)
    end
    mock.fire("GROUP_ROSTER_UPDATE"); mock.advance(1)
end)

test("invalid portrait geometry hides the ears", function()
    local SECRET = {}
    local ns2 = boot(nil, { setup = function()
        issecretvalue = function(v) return v == SECRET end
        mkPlayer(100, 900, 60)
        local p = PlayerFrame.PlayerFrameContainer.PlayerPortrait
        function p:GetTop() return SECRET end
    end })
    eq(ears(ns2).player.shown, false); eq(ears(ns2).player.reason, "no geometry")
end)

test("UI scale and Edit Mode moves are followed", function()
    local ns2 = boot(nil, { setup = function() mkPlayer(100, 900, 60) end })
    PlayerFrame.PlayerFrameContainer.PlayerPortrait:SetMockRect(300, 500, 60, 60)
    mock.fire("EDIT_MODE_LAYOUTS_UPDATED")
    mock.advance(0.15)
    near(ears(ns2).player.rect[1], 330); near(ears(ns2).player.rect[2], 554)
    -- UI scale 0.8 with the portrait at effective scale 1.0.
    UIParent._scale = 0.8
    PlayerFrame.PlayerFrameContainer.PlayerPortrait._scale = 1.0
    mock.fire("UI_SCALE_CHANGED")
    mock.advance(0.15)
    near(ears(ns2).player.rect[3], 60, 1e-6, "48 / 0.8")
    UIParent._scale = 1
end)

test("combat: hooks wait for combat end; protected overlays are deferred", function()
    mock.combat = false
    local ns2 = boot(nil, { setup = function()
        mkPlayer(100, 900, 60)
        mock.combat = true -- /reload in combat
    end })
    local _, deferred, hooksPending = ns2.Ears.GetState()
    eq(hooksPending, true, "no hooks installed in combat")
    eq(PlayerFrame._hooks.OnShow, nil)
    eq(ears(ns2).player.shown, true, "unprotected overlay still updates in combat")
    -- If our overlay were ever protected, changes wait for combat to end.
    local o = ears(ns2).player.overlay
    o._protected = true
    PlayerFrame.PlayerFrameContainer.PlayerPortrait:SetMockRect(200, 800, 60, 60)
    ns2.Ears.Refresh()
    _, deferred = ns2.Ears.GetState()
    eq(deferred, true); near(ears(ns2).player.rect[1], 130, 1e-6, "not moved in combat")
    mock.combat = false
    o._protected = false
    mock.fire("PLAYER_REGEN_ENABLED")
    mock.advance(0.15)
    _, deferred, hooksPending = ns2.Ears.GetState()
    eq(hooksPending, false); eq(deferred, false)
    eq(#PlayerFrame._hooks.OnShow, 1)
    near(ears(ns2).player.rect[1], 230, 1e-6, "applied after combat")
end)

test("ears share the bunny's fur colour", function()
    local ns2 = boot({ schema = 2, furColor = "FFB6C1" }, { setup = function() mkPlayer(100, 900, 60) end })
    local o = ears(ns2).player.overlay
    local fur, detail
    for _, ch in ipairs(o._children) do
        if ch._texture then if not fur then fur = ch else detail = ch end end
    end
    truthy(fur._texture:find("bunny%-ears%.tga"))
    local _, g = fur:GetVertexColor(); near(g, 0xB6 / 255)
    slash("color #87CEEB")
    local r = fur:GetVertexColor(); near(r, 0x87 / 255)
    eq(detail._vertex, nil)
    eq(fur._layer, "OVERLAY")
end)

-- A modern-style player frame: unit frame -> container -> portrait, plus a
-- ring frame drawn over the portrait and Edit Mode's Selection child.
local function mkLayeredPlayer(opts)
    opts = opts or {}
    local pf = CreateFrame("Button", "PlayerFrame", UIParent)
    pf:SetMockRect(80, 880, 230, 100)
    pf._strata, pf._level = opts.strata or "LOW", opts.level or 5
    local cont = CreateFrame("Frame", nil, pf)
    cont._level = opts.containerLevel or 6
    cont._strata = opts.containerStrata
    pf.PlayerFrameContainer = cont
    local p = cont:CreateTexture(nil, "BACKGROUND")
    p:SetMockRect(100, 900, 60, 60)
    cont.PlayerPortrait = p
    local ring = CreateFrame("Frame", nil, cont)
    ring._level = opts.ringLevel or 8
    pf.Ring = ring
    local sel = CreateFrame("Frame", nil, pf)
    sel._strata, sel._level = "DIALOG", 900
    sel:Hide()
    pf.Selection = sel
    return pf
end

local function earsLayer(ns2)
    local e = ears(ns2).player
    return e.overlay:GetFrameStrata(), e.overlay:GetFrameLevel(), e.layerSource
end

test("layering: above nested portrait frames, not just the unit frame", function()
    local ns2 = boot(nil, { setup = function()
        mkLayeredPlayer({ level = 5, containerLevel = 30, ringLevel = 40 })
    end })
    local strata, level, src = earsLayer(ns2)
    eq(strata, "LOW"); eq(level, 50, "ring (40) + 10, not unit frame (5) + 10"); eq(src, "scan")
end)

test("layering: a container with its own higher strata wins", function()
    local ns2 = boot(nil, { setup = function()
        mkLayeredPlayer({ strata = "LOW", level = 200, containerStrata = "MEDIUM", containerLevel = 3, ringLevel = 4 })
    end })
    local strata, level = earsLayer(ns2)
    eq(strata, "MEDIUM", "higher strata beats any level"); eq(level, 14)
end)

test("layering: hidden frames (Edit Mode selection) are ignored until shown", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer() end })
    eq(select(1, earsLayer(ns2)), "LOW")
    -- In Edit Mode the selection overlay is shown at DIALOG/900.
    PlayerFrame.Selection:Show()
    ns2.Ears.Refresh()
    local strata, level = earsLayer(ns2)
    eq(strata, "DIALOG"); eq(level, 910)
    PlayerFrame.Selection:Hide()
    ns2.Ears.Refresh()
    eq(select(1, earsLayer(ns2)), "LOW", "back to normal after Edit Mode")
end)

test("Edit Mode drag: raised frames and new position picked up on drop", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ level = 5, containerLevel = 6, ringLevel = 8 }) end })
    eq(select(2, earsLayer(ns2)), 18)
    -- Dragging raises the unit frame (whole subtree re-levelled) and moves it.
    PlayerFrame._level, PlayerFrame.PlayerFrameContainer._level, PlayerFrame.Ring._level = 505, 506, 508
    PlayerFrame.PlayerFrameContainer.PlayerPortrait:SetMockRect(400, 600, 60, 60)
    PlayerFrame.Selection._hooks.OnDragStop[1](PlayerFrame.Selection)
    mock.advance(0.15)
    local e = ears(ns2).player
    eq(e.level, 518, "re-layered above the raised ring")
    near(e.rect[1], 430); near(e.rect[2], 660 - 6)
end)

test("Edit Mode exit via EventRegistry triggers a refresh", function()
    local callbacks = {}
    local ns2 = boot(nil, { setup = function()
        mkLayeredPlayer()
        EventRegistry = { RegisterCallback = function(_, ev, fn, owner) callbacks[ev] = { fn, owner } end }
    end })
    truthy(callbacks["EditMode.Exit"] and callbacks["EditMode.Enter"])
    PlayerFrame.PlayerFrameContainer.PlayerPortrait:SetMockRect(250, 700, 60, 60)
    local cb = callbacks["EditMode.Exit"]
    cb[1](cb[2])
    mock.advance(0.15)
    near(ears(ns2).player.rect[1], 280)
    EventRegistry = nil
end)

test("layering is idempotent: repeated refreshes never ratchet levels", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ ringLevel = 40 }) end })
    local o = ears(ns2).player.overlay
    local sets = 0
    local orig = o.SetFrameLevel
    o.SetFrameLevel = function(...) sets = sets + 1; return orig(...) end
    for _ = 1, 20 do ns2.Ears.Refresh(); mock.fire("GROUP_ROSTER_UPDATE"); mock.advance(0.2) end
    eq(select(2, earsLayer(ns2)), 50); eq(sets, 0, "unchanged layer is not re-applied")
    o.SetFrameLevel = nil
end)

test("layering: levels are capped below the client maximum", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ ringLevel = 9995 }) end })
    eq(select(2, earsLayer(ns2)), 9900)
end)

test("layering: secret or broken strata/levels fall back safely", function()
    local SECRET = {}
    local ns2 = boot(nil, { setup = function()
        issecretvalue = function(v) return v == SECRET end
        local pf = mkLayeredPlayer()
        for _, f in ipairs({ pf, pf.PlayerFrameContainer, pf.Ring, pf.Selection }) do
            f.GetFrameStrata = function() return SECRET end
            f.GetFrameLevel = function() error("blocked") end
        end
    end })
    local strata, _, src = earsLayer(ns2)
    eq(strata, "HIGH"); eq(src, "fallback")
    eq(ears(ns2).player.shown, true, "ears still shown")
    -- GetChildren failing: the portrait's owner chain still gives a layer.
    ns2 = boot(nil, { setup = function()
        local pf = mkLayeredPlayer({ containerLevel = 30 })
        pf.GetChildren = function() error("forbidden") end
    end })
    local s2, l2 = earsLayer(ns2)
    eq(s2, "LOW"); eq(l2, 40)
end)

test("layering never touches Blizzard frames, also in combat", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ ringLevel = 40 }) end })
    for _, f in ipairs({ PlayerFrame, PlayerFrame.PlayerFrameContainer, PlayerFrame.Ring }) do
        f.SetFrameLevel = function() error("must not modify Blizzard frames") end
        f.SetFrameStrata = function() error("must not modify Blizzard frames") end
        f.SetPoint = function() error("must not modify Blizzard frames") end
    end
    mock.combat = true
    PlayerFrame.Ring._level = 70
    mock.fire("PLAYER_REGEN_ENABLED") -- refresh path; reads only
    ns2.Ears.Refresh()
    eq(select(2, earsLayer(ns2)), 80, "re-layered in combat (our frame is unprotected)")
    eq(ears(ns2).player.overlay:IsMouseEnabled(), false)
    mock.combat = false
end)

test("layering follows UI scale changes and party re-sorts", function()
    local ns2 = boot(nil, { setup = function()
        mkLayeredPlayer({ ringLevel = 12 })
        local party = mkParty(2)
        party._strata, party._level = "LOW", 3
        party.MemberFrame1._level = 25
    end })
    eq(ears(ns2).party1.level, 35); eq(ears(ns2).party1.strata, "LOW")
    UIParent._scale = 0.8
    mock.fire("UI_SCALE_CHANGED")
    mock.advance(0.15)
    eq(ears(ns2).player.level, 22, "layer unchanged by scale")
    near(ears(ns2).player.rect[3], 60, 1e-6, "size follows scale")
    UIParent._scale = 1
    -- Re-sort: member 2 now raised above member 1.
    PartyFrame.MemberFrame2._level = 60
    mock.fire("GROUP_ROSTER_UPDATE")
    mock.advance(0.15)
    eq(ears(ns2).party2.level, 70)
end)

test("legacy party portrait without a unit frame uses its owner chain", function()
    local ns2 = boot(nil, { setup = function()
        local m = CreateFrame("Button", "PartyMemberFrame1", UIParent)
        m._strata, m._level = "LOW", 7
        local mp = m:CreateTexture(nil, "BACKGROUND")
        mp:SetMockRect(30, 700, 37, 37)
        PartyMemberFrame1Portrait = mp
    end })
    eq(ears(ns2).party1.strata, "LOW"); eq(ears(ns2).party1.level, 17)
end)

test("reload: same layout gives the same layer and position", function()
    local function run()
        local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ containerLevel = 30, ringLevel = 40 }) end })
        local e = ears(ns2).player
        return e.strata, e.level, e.rect[1], e.rect[2]
    end
    local a = { run() }
    local b = { run() }
    for i = 1, 4 do eq(a[i], b[i]) end
end)

test("no per-frame work from ears or options while idle", function()
    local ns2 = boot(nil, { setup = function() mkPlayer(100, 900, 60); mkParty(4) end })
    mock.advance(2)
    for _, f in ipairs(mock.frames) do
        if f ~= BunnyBarFrame then eq(f:GetScript("OnUpdate"), nil) end
    end
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
