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

local SLOW = os.getenv("BUNNY_SLOW") -- print tests slower than this many seconds

local function test(name, fn)
    current = name
    local t0 = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    local dt = os.clock() - t0
    if SLOW and dt > tonumber(SLOW) then io.write(("  [%.1fs] %s\n"):format(dt, name)) end
    io.flush()
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
    -- Balanced without moods = the exact v0.3 scheduler (moods vary waits).
    local ns2 = boot({ schema = 5, moods = false }) -- schema set: keeps the size-64 default
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
        -- Burrowing moves the bunny while it's invisible underground.
        if dx > maxDx and not s.spriteHidden and not prev.spriteHidden then maxDx = dx end
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
    local ns2 = boot({ sleepChance = 1, moods = false }) -- v0.3 nap behaviour
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
    BunnyBarDB.idleExtras, BunnyBarDB.burrow = false, false -- only nap vs hop
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
    local base = mock.pendingTimers()
    MultiBarBottomLeft:Hide()
    MultiBarBottomLeft:Show()
    MultiBarBottomLeft:Hide()
    eq(ns2.Placement.IsRefreshPending(), true)
    eq(mock.pendingTimers(), base + 1, "exactly one refresh timer") -- refresh is coalesced
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
    eq(db.schema, 5)
    for k, v in pairs(old) do if k ~= "schema" then eq(db[k], v, k) end end
    eq(db.furColor, nil, "no override"); eq(ns.Config.FurColor(db), "F6F3FA"); eq(db.variation, "classic"); eq(db.hat, "none")
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
    eq(BunnyBarDB.furColor, nil); eq(ns.Config.FurColor(BunnyBarDB), "F6F3FA")
end)

test("appearance registry: five styles + no hat yet", function()
    local ns2 = boot(nil)
    local A = ns2.Appearance
    truthy(A.IsValid("variation", "classic")); truthy(A.IsValid("hat", "none"))
    eq(A.IsValid("variation", "fancy"), false); eq(A.IsValid("hat", nil), false)
    eq(#A.List("variation"), 5); eq(#A.List("hat"), 1)
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
    -- Make sure the rarer sheets show up whatever the random sequence.
    for i, what in ipairs({ "burrow", "carrot", "wash", "stretch", "nap" }) do
        C_Timer.After(40 * i, function() slash("test " .. what) end)
    end
    mock.advance(400, 1 / 30, function()
        local r, g, b = fur:GetVertexColor()
        near(r, 1); near(g, 0xB6 / 255); near(b, 0xC1 / 255)
        eq(fur._texture, detail._texture, "layers show the same sheet")
        sheets[fur._texture] = true
        poses[ns2.Bunny:GetDebugState().pose] = true
    end)
    local n = 0
    for _ in pairs(sheets) do n = n + 1 end
    eq(n, 9, "all nine sheets shown")
    for _, p in ipairs({ "blink", "jump", "land", "sleep2", "wake3", "drowsy2" }) do truthy(poses[p], p) end
end)

test("/bunny color: validation, reset and query", function()
    boot(nil)
    eq(slash("color pink"), false)
    truthy(lastChat():find("not a colour"))
    eq(BunnyBarDB.furColor, nil, "unchanged after bad input")
    eq(slash("color ffb6c1"), true); eq(BunnyBarDB.furColor, "FFB6C1")
    eq(slash("color"), true); truthy(lastChat():find("#FFB6C1"))
    eq(slash("color reset"), true); eq(BunnyBarDB.furColor, nil); eq(ns.Config.FurColor(BunnyBarDB), "F6F3FA")
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
    eq(BunnyBarDB.furColor, nil); eq(c.hex:GetText(), "#F6F3FA")
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
    eq(BunnyBarDB.size, 64); eq(BunnyBarDB.furColor, nil); eq(BunnyBarDB.earsPlayer, true)
    eq(c.hex:GetText(), "#F6F3FA"); eq(c.sizes[3]:GetChecked(), true)
    eq(c.ears.earsPlayer:GetChecked(), true)
    local r = bunnyLayers():GetVertexColor(); near(r, 0xF6 / 255)
end)

test("panel sections never overlap; every control sits inside its section", function()
    local ns2, c = bootPanel({ schema = 3, size = 48 })
    local L = ns2.Options.layout
    local cols = {}
    for name, sec in pairs(L) do
        cols[sec.x] = cols[sec.x] or {}
        table.insert(cols[sec.x], { name = name, top = sec.top, bottom = sec.bottom })
        truthy(sec.bottom < sec.top, name .. " has height")
    end
    for x, list in pairs(cols) do
        table.sort(list, function(a, b) return a.top > b.top end)
        for i = 2, #list do
            truthy(list[i].top < list[i - 1].bottom,
                ("%s overlaps %s"):format(list[i].name, list[i - 1].name))
        end
    end
    -- Widths: grid radio ~130, inline radio ~70, checkbox + label ~260.
    local function inside(ctrl, secName, h, w)
        local _, _, _, cx, cy = ctrl:GetPoint(1)
        local sec = L[secName]
        truthy(cy <= sec.top and cy - h >= sec.bottom - 2,
            ("%s control at y=%s outside [%s, %s]"):format(secName, cy, sec.bottom, sec.top))
        truthy(cx + (w or 130) <= 660, secName .. " control too far right: " .. cx)
        return cx, cy
    end
    local seen = {}
    local function unique(ctrl, secName, h, w)
        local cx, cy = inside(ctrl, secName, h, w)
        local key = cx .. "," .. cy
        truthy(not seen[key], "two controls at " .. key)
        seen[key] = true
    end
    for _, rb in ipairs(c.styles) do unique(rb, "style", 18) end
    for _, rb in ipairs(c.sizes) do unique(rb, "size", 18) end
    inside(c.customSize, "size", 12)
    truthy(c.customSize:IsShown(), "custom 48 shown")
    for _, cb in pairs(c.behaviors) do unique(cb, "behaviors", 24, 260) end
    for _, rb in ipairs(c.burrowFrequency) do unique(rb, "behaviors", 18, 70) end
    unique(c.hearts, "interactions", 24, 260)
    for _, rb in ipairs(c.heartIntensity) do unique(rb, "interactions", 18, 70) end
    for _, cb in pairs(c.ears) do unique(cb, "portrait", 24, 260) end
    eq(#c.sizes, 5)
end)

test("style radios list every registered style and select the current one", function()
    local ns2, c = bootPanel({ schema = 3, variation = "dragon" })
    local got = {}
    for i, rb in ipairs(c.styles) do got[i] = rb.value end
    eq(table.concat(got, ","), "classic,devil,angel,dragon,zombie")
    for _, rb in ipairs(c.styles) do eq(rb:GetChecked(), rb.value == "dragon", rb.value) end
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
    cont:SetMockRect(80, 880, 230, 100)
    pf.PlayerFrameContainer = cont
    local p = cont:CreateTexture(nil, "BACKGROUND")
    p:SetMockRect(100, 900, 60, 60)
    cont.PlayerPortrait = p
    -- Decorative ring drawn over the portrait edge (overlaps the ears).
    local ring = CreateFrame("Frame", nil, cont)
    ring._level = opts.ringLevel or 8
    ring:SetMockRect(96, 896, 68, 68)
    pf.Ring = ring
    -- Edit Mode selection highlight covering the whole unit frame.
    local sel = CreateFrame("Frame", nil, pf)
    sel._strata, sel._level = "DIALOG", 900
    sel:SetMockRect(80, 880, 230, 100)
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

test("layering: Edit Mode selection overlays never lift the ears", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer() end })
    eq(select(1, earsLayer(ns2)), "LOW")
    -- In Edit Mode the selection overlay is shown at DIALOG/900.
    PlayerFrame.Selection:Show()
    ns2.Ears.Refresh()
    local strata, level = earsLayer(ns2)
    eq(strata, "LOW", "not lifted to DIALOG"); eq(level, 18)
    PlayerFrame.Selection:Hide()
end)

test("Edit Mode drag: raised frames and new position picked up on drop", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ level = 5, containerLevel = 6, ringLevel = 8 }) end })
    eq(select(2, earsLayer(ns2)), 18)
    -- Dragging raises the unit frame (whole subtree re-levelled) and moves it.
    PlayerFrame._level, PlayerFrame.PlayerFrameContainer._level, PlayerFrame.Ring._level = 505, 506, 508
    PlayerFrame.PlayerFrameContainer.PlayerPortrait:SetMockRect(400, 600, 60, 60)
    PlayerFrame.PlayerFrameContainer:SetMockRect(380, 580, 230, 100)
    PlayerFrame.Ring:SetMockRect(396, 596, 68, 68)
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

-- Helpers for the Edit Mode scenarios.
local function editModeAPI(rec)
    EventRegistry = { RegisterCallback = function(_, ev, fn, owner) rec[ev] = { fn, owner } end }
end
local function fireCallback(rec, ev) local cb = rec[ev]; cb[1](cb[2]) end
local function setPlayerLevels(unit, cont, ring)
    PlayerFrame._level, PlayerFrame.PlayerFrameContainer._level, PlayerFrame.Ring._level = unit, cont, ring
end
local function settleEars(ns2, limit)
    local t0 = mock.now
    while (ns2.Ears.IsRefreshPending()) do
        if mock.now - t0 > (limit or 10) then error("ears refresh never settled") end
        mock.advance(1 / 60)
    end
    return mock.now - t0
end

test("Edit Mode raises levels, then restores them later: ears follow both", function()
    local rec = {}
    local ns2 = boot(nil, { setup = function() editModeAPI(rec); mkLayeredPlayer() end })
    eq(select(2, earsLayer(ns2)), 18, "A: before Edit Mode")
    fireCallback(rec, "EditMode.Enter")
    setPlayerLevels(600, 601, 608) -- drag raises the subtree
    PlayerFrame.Selection._hooks.OnDragStop[1](PlayerFrame.Selection)
    mock.advance(0.15)
    eq(select(2, earsLayer(ns2)), 618, "in front of the raised ring right after the drop")
    fireCallback(rec, "EditMode.Exit")
    -- Blizzard restores normal levels 1 s after exit (after our first pass).
    C_Timer.After(1.0, function() setPlayerLevels(5, 6, 8) end)
    mock.advance(0.15)
    eq(select(2, earsLayer(ns2)), 618)
    settleEars(ns2)
    eq(select(2, earsLayer(ns2)), 18, "re-check caught the restore: same as after /reload")
end)

test("a portrait descendant changing strata (no movement) is picked up", function()
    local rec = {}
    local ns2 = boot(nil, { setup = function() editModeAPI(rec); mkLayeredPlayer() end })
    fireCallback(rec, "EditMode.Exit")
    C_Timer.After(0.5, function() PlayerFrame.Ring._strata = "MEDIUM" end)
    settleEars(ns2)
    local strata, level = earsLayer(ns2)
    eq(strata, "MEDIUM"); eq(level, 18)
    near(ears(ns2).player.rect[1], 130, 1e-6, "position untouched")
end)

test("layout changes long after Edit Mode exit are caught by the bounded series", function()
    local rec = {}
    local ns2 = boot(nil, { setup = function() editModeAPI(rec); mkLayeredPlayer() end })
    fireCallback(rec, "EditMode.Exit")
    -- Applying the saved layout re-levels the container 2 s later.
    C_Timer.After(2.0, function() PlayerFrame.PlayerFrameContainer._level = 700 end)
    local took = settleEars(ns2)
    eq(select(2, earsLayer(ns2)), 710)
    truthy(took < 6, "series is bounded: " .. took)
end)

test("consecutive drags restart the series and end in the right place", function()
    local rec = {}
    local ns2 = boot(nil, { setup = function() editModeAPI(rec); mkLayeredPlayer() end })
    local n = { calls = 0 }
    local orig = ns2.Ears.ComputeLayer
    ns2.Ears.ComputeLayer = function(...) n.calls = n.calls + 1; return orig(...) end
    fireCallback(rec, "EditMode.Enter")
    local drop = PlayerFrame.Selection._hooks.OnDragStop[1]
    for i = 1, 3 do
        local x = 100 + i * 100
        PlayerFrame.PlayerFrameContainer.PlayerPortrait:SetMockRect(x, 900, 60, 60)
        PlayerFrame.PlayerFrameContainer:SetMockRect(x - 20, 880, 230, 100)
        PlayerFrame.Ring:SetMockRect(x - 4, 896, 68, 68)
        setPlayerLevels(600 + i * 10, 601 + i * 10, 608 + i * 10)
        drop(PlayerFrame.Selection)
        mock.advance(0.3)
    end
    fireCallback(rec, "EditMode.Exit")
    settleEars(ns2)
    near(ears(ns2).player.rect[1], 430); eq(select(2, earsLayer(ns2)), 648)
    -- Each burst: one debounced pass + at most #RECHECKS re-checks (x1 target).
    truthy(n.calls <= 4 * (1 + #ns2.Ears.RECHECKS), "passes bounded: " .. n.calls)
end)

test("runtime refresh after Edit Mode equals a fresh /reload", function()
    local rec = {}
    local final = { x = 520, unit = 640, cont = 641, ring = 655, ringStrata = "MEDIUM" }
    local function applyFinal()
        local pf = PlayerFrame
        pf.PlayerFrameContainer.PlayerPortrait:SetMockRect(final.x, 700, 60, 60)
        pf.PlayerFrameContainer:SetMockRect(final.x - 20, 680, 230, 100)
        pf.Ring:SetMockRect(final.x - 4, 696, 68, 68)
        setPlayerLevels(final.unit, final.cont, final.ring)
        pf.Ring._strata = final.ringStrata
    end
    -- Runtime: start default, then Edit Mode moves and re-levels things late.
    local ns2 = boot(nil, { setup = function() editModeAPI(rec); mkLayeredPlayer() end })
    fireCallback(rec, "EditMode.Enter")
    PlayerFrame.Selection:Show()
    PlayerFrame.Selection._hooks.OnDragStop[1](PlayerFrame.Selection)
    PlayerFrame.Selection:Hide()
    fireCallback(rec, "EditMode.Exit")
    C_Timer.After(0.6, applyFinal)
    settleEars(ns2)
    local a = ears(ns2).player
    local runtime = { a.strata, a.level, a.rect[1], a.rect[2], a.overlay:GetFrameStrata(), a.overlay:GetFrameLevel() }
    -- Reload: boot straight into the final state.
    ns2 = boot(nil, { setup = function() mkLayeredPlayer(); applyFinal() end })
    local b = ears(ns2).player
    local reload = { b.strata, b.level, b.rect[1], b.rect[2], b.overlay:GetFrameStrata(), b.overlay:GetFrameLevel() }
    for i = 1, #reload do eq(runtime[i], reload[i], "field " .. i) end
end)

test("drift: the overlay's actual layer is corrected, not trusted from cache", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer({ ringLevel = 40 }) end })
    local o = ears(ns2).player.overlay
    eq(o:GetFrameLevel(), 50)
    o._level = 3 -- something else lowered our overlay
    mock.fire("GROUP_ROSTER_UPDATE")
    mock.advance(0.15)
    eq(o:GetFrameLevel(), 50, "restored")
    eq(ears(ns2).player.drift, 1)
    -- SetFrameStrata resetting the level must not leave a stale level.
    local origS = o.SetFrameStrata
    o.SetFrameStrata = function(self, st) origS(self, st); self._level = 0 end
    PlayerFrame.Ring._strata = "MEDIUM"
    ns2.Ears.Refresh()
    eq(o:GetFrameStrata(), "MEDIUM"); eq(o:GetFrameLevel(), 50, "level re-applied after strata change")
    o.SetFrameStrata = nil
end)

test("only frames overlapping the ears count; never above HIGH", function()
    local ns2 = boot(nil, { setup = function()
        local pf = mkLayeredPlayer({ ringLevel = 8 })
        -- A tall status widget elsewhere in the unit frame at a high level.
        local far = CreateFrame("Frame", nil, pf)
        far._level = 300
        far:SetMockRect(250, 880, 40, 20)
    end })
    eq(select(2, earsLayer(ns2)), 18, "unrelated descendants don't lift the ears")
    PlayerFrame.Ring._strata = "DIALOG"
    ns2.Ears.Refresh()
    local strata, level, src = earsLayer(ns2)
    eq(strata, "HIGH"); eq(level, 9900); eq(src, "capped")
end)

test("non-Edit Mode triggers stop re-checking once nothing changes", function()
    local ns2 = boot(nil, { setup = function() mkLayeredPlayer() end })
    mock.advance(1)
    local n = { calls = 0 }
    local orig = ns2.Ears.ComputeLayer
    ns2.Ears.ComputeLayer = function(...) n.calls = n.calls + 1; return orig(...) end
    mock.fire("GROUP_ROSTER_UPDATE")
    settleEars(ns2)
    eq(n.calls, 1, "one pass, no re-checks when stable")
end)

test("in combat: reads only, bounded series, no OnUpdate", function()
    local rec = {}
    local ns2 = boot(nil, { setup = function() editModeAPI(rec); mkLayeredPlayer() end })
    for _, f in ipairs({ PlayerFrame, PlayerFrame.PlayerFrameContainer, PlayerFrame.Ring }) do
        f.SetFrameLevel = function() error("must not modify Blizzard frames") end
        f.SetFrameStrata = function() error("must not modify Blizzard frames") end
    end
    mock.combat = true
    fireCallback(rec, "EditMode.Exit")
    C_Timer.After(0.4, function() PlayerFrame.Ring._level = 90 end)
    local took = settleEars(ns2)
    eq(select(2, earsLayer(ns2)), 100)
    truthy(took <= 0.1 + 0.25 + 0.75 + 1.5 + 3.0 + 0.1, "bounded: " .. took)
    eq(ears(ns2).player.overlay:GetScript("OnUpdate"), nil)
    mock.combat = false
end)

test("/bunny ears debug reports names, layers and scheduling safely", function()
    local rec = {}
    local SECRET = {}
    local ns2 = boot(nil, { setup = function()
        editModeAPI(rec)
        mkLayeredPlayer({ ringLevel = 40 })
        local em = CreateFrame("Frame", "EditModeManagerFrame", UIParent)
        function em:IsEditModeActive() return true end
        mkParty(1)
        issecretvalue = function(v) return v == SECRET end
        PartyFrame.MemberFrame1.GetFrameLevel = function() return SECRET end
    end })
    fireCallback(rec, "EditMode.Exit")
    local before = #mock.chat
    eq(slash("ears debug"), true)
    local text = table.concat(mock.chat, "\n", before + 1)
    truthy(text:find("Edit Mode active: yes"), text)
    truthy(text:find("refresh scheduled: yes"), text)
    truthy(text:find("last trigger: EditMode.Exit"), text)
    truthy(text:find("player: shown %(scan%)"), text)
    truthy(text:find("unit frame PlayerFrame"), text)
    truthy(text:find("portrait owner %(unnamed%) at LOW/6"), text)
    truthy(text:find("highest overlapping %(unnamed%) at LOW/40"), text)
    truthy(text:find("ears want LOW/50, have LOW/50, corrected drift 0"), text)
    truthy(text:find("party1: shown"), text)
    truthy(text:find("party1: shown %(fallback%)"), text) -- secret level -> safe fallback
    truthy(text:find("at MEDIUM/%?"), text)                -- secret value printed as "?"
    truthy(text:find("party2: hidden"), text)
    -- The help list stays free of the debug command.
    before = #mock.chat
    slash("")
    eq(table.concat(mock.chat, "\n", before + 1):find("debug"), nil)
end)

test("no per-frame work from ears or options while idle", function()
    local ns2 = boot(nil, { setup = function() mkPlayer(100, 900, 60); mkParty(4) end })
    mock.advance(2)
    for _, f in ipairs(mock.frames) do
        if f ~= BunnyBarFrame then eq(f:GetScript("OnUpdate"), nil) end
    end
end)

----------------------------------------------------------------------------
-- v0.3: hopping
----------------------------------------------------------------------------

io.write("v0.3 hopping\n")

-- One hop journey from idle (destination one hop away) with pose log.
local function oneHop(opts)
    opts = opts or {}
    math.randomseed(opts.seed or 3)
    local ns2 = boot({ schema = 3, idleExtras = false, burrow = false, speed = opts.speed or 1, size = 64 })
    mock.advance(1.05)
    local B = ns2.Bunny
    local s0 = B:GetDebugState()
    local step = opts.step or (1 / 120)
    local log, ys = {}, {}
    local prev
    B:Perform("hop")
    local t0 = mock.now
    while true do
        local s = B:GetDebugState()
        if s.pose ~= prev then log[#log + 1] = { pose = s.pose, at = mock.now - t0, state = s.state }; prev = s.pose end
        ys[#ys + 1] = { state = s.state, y = s.y }
        if s.state == "idle" then break end
        mock.advance(step, step) -- (seconds, step): one frame of `step`
        if mock.now - t0 > 10 then error("hop never finished") end
    end
    return ns2, log, ys, s0
end

test("hop plays all 8 phases in order with the specified timing", function()
    local ns2, log = oneHop({ step = 1 / 240 })
    local H = ns2.Bunny.HOP_TIMING
    local poses = {}
    for i, e in ipairs(log) do poses[i] = e.pose end
    local str = table.concat(poses, ",")
    -- A journey may take several hops: (prep push jump apex fall contact land)+ recover idle
    truthy(str:match("^prep,push,jump,apex,fall,contact,land"), str)
    truthy(str:match("recover,idle$"), str)
    local want = { prep = H.prep, push = H.push, contact = H.contact, land = H.land, recover = H.recover }
    for i = 1, #log - 1 do
        local w = want[log[i].pose]
        if w then near(log[i + 1].at - log[i].at, w, 2.5 / 240, log[i].pose) end
    end
end)

test("hop phases scale with speed; air poses follow progress thresholds", function()
    local ns2, log = oneHop({ speed = 2, step = 1 / 240 })
    local H = ns2.Bunny.HOP_TIMING
    for i = 1, #log - 1 do
        if log[i].pose == "prep" then near(log[i + 1].at - log[i].at, H.prep / 2, 2.5 / 240, "prep at 2x") end
    end
    local A = ns2.Bunny.AirPose
    eq(A(0.0), "jump"); eq(A(0.37), "jump"); eq(A(0.38), "apex"); eq(A(0.63), "apex")
    eq(A(0.64), "fall"); eq(A(0.99), "fall"); eq(A(1.0), "fall")
end)

test("grounded hop phases have no vertical offset (no jitter)", function()
    local _, _, ys = oneHop({ step = 1 / 240 })
    for _, e in ipairs(ys) do
        if e.state ~= "air" then eq(e.y, 0, "y in " .. e.state) end
    end
end)

test("hop is frame-rate independent", function()
    local function run(step)
        local ns2, log = oneHop({ seed = 9, step = step })
        local s = ns2.Bunny:GetDebugState()
        return log[#log].at, s.x, s.hops, s.airTime
    end
    local t30, x30, h30, air30 = run(1 / 30)
    local t144, x144, h144, air144 = run(1 / 144)
    eq(x30, x144, "same landing spot"); eq(h30, h144, "same number of hops")
    near(air30, air144, 1e-9, "air time doesn't depend on the frame rate")
    -- Timer phases end on frame boundaries (as in the client), so each of the
    -- ~5 ground phases per hop may round up by at most one 30 fps frame.
    near(t30, t144, (h30 * 5 + 2) / 30, "same duration within frame quantisation")
end)

----------------------------------------------------------------------------
-- v0.3: idle behaviours
----------------------------------------------------------------------------

io.write("v0.3 behaviours\n")

local function seqNames(seq)
    local out = {}
    for i, st in ipairs(seq) do out[i] = st[1] end
    return out
end

-- Play a behaviour via /bunny test and record its poses until idle.
local function playTest(what, saved)
    local ns2 = boot(saved or { schema = 3 })
    mock.advance(1.05)
    local x0 = ns2.Bunny:GetDebugState().x
    eq(slash("test " .. what), true, "/bunny test " .. what)
    local log = recordPoses(ns2, function(s) return s.state == "idle" end, 20)
    return ns2, log, x0
end

test("carrot: full sequence with three shrinking bites, then idle", function()
    local ns2, log, x0 = playTest("carrot")
    local poses = {}
    for i = 1, #log - 1 do poses[i] = log[i].pose end
    eq(table.concat(poses, ","), table.concat(seqNames(ns2.Bunny.SEQUENCES.carrot), ","))
    -- Carrot gets smaller: bite1 (full) -> chew1 -> bite2 -> chew2 -> bite3 -> chew3 (gone)
    local order = {}
    for _, p in ipairs(poses) do if p:find("^carrotBite") or p:find("^carrotChew") then order[#order + 1] = p end end
    eq(table.concat(order, ","), "carrotBite1,carrotChew1,carrotBite2,carrotChew2,carrotBite3,carrotChew3")
    local total = 0
    for _, st in ipairs(ns2.Bunny.SEQUENCES.carrot) do total = total + st[2] end
    truthy(total >= 3 and total <= 5, "carrot lasts 3-5 s: " .. total)
    near(log[#log].at - log[1].at, total, 0.1, "played at its real timing")
    eq(ns2.Bunny:GetDebugState().x, x0, "no movement while eating")
    eq(ns2.Bunny:GetDebugState().onUpdate, false)
end)

test("wash, scratch, stretch and look each play their own frames, then idle", function()
    for _, name in ipairs({ "wash", "scratch", "stretch", "look" }) do
        local ns2, log, x0 = playTest(name)
        local poses = {}
        for i = 1, #log - 1 do poses[i] = log[i].pose end
        local want = seqNames(ns2.Bunny.SEQUENCES[name])
        -- consecutive duplicate poses collapse in the log
        local dedup = {}
        for _, p in ipairs(want) do if dedup[#dedup] ~= p then dedup[#dedup + 1] = p end end
        eq(table.concat(poses, ","), table.concat(dedup, ","), name)
        local distinct = {}
        for _, p in ipairs(want) do distinct[p] = true end
        local n = 0
        for _ in pairs(distinct) do n = n + 1 end
        truthy(n >= 4 or (name == "look" and n >= 3), name .. " has enough distinct frames: " .. n)
        eq(ns2.Bunny:GetDebugState().x, x0, name .. ": no movement")
        eq(log[#log].pose, "idle")
    end
end)

test("look-around returns to the previous facing", function()
    local ns2 = boot({ schema = 3 })
    mock.advance(1.05)
    local f0 = ns2.Bunny:GetDebugState().facing
    slash("test look")
    advanceUntil(ns2, function(s) return s.state == "idle" end, 10)
    eq(ns2.Bunny:GetDebugState().facing, f0)
end)

test("behaviour choice respects settings and never repeats", function()
    local ns2 = boot({ schema = 3 })
    local P = ns2.Bunny.PickBehavior
    local counts = {}
    for i = 1, 2000 do
        local r = (i - 0.5) / 2000
        local b = P(function() return r end, "wash")
        counts[b] = (counts[b] or 0) + 1
        truthy(b ~= "wash", "excluded behaviour never picked")
    end
    truthy(counts.carrot and counts.scratch and counts.stretch and counts.look)
    BunnyBarDB.carrot = false
    for i = 1, 200 do truthy(P(function() return (i - 0.5) / 200 end) ~= "carrot") end
    BunnyBarDB.idleExtras = false
    eq(P(math.random), nil)
end)

test("thirty simulated minutes: behaviours, naps, hops, rare burrows, no leaks", function()
    math.randomseed(77)
    local ns2 = boot({ schema = 3, burrowFrequency = "often" })
    local B = ns2.Bunny
    local db = BunnyBarDB
    local minX, maxX = ns2.Util.TrackBounds(db.trackWidth, db.size)
    local updates, frames = 0, 0
    mock.advance(1800, 1 / 20, function()
        local s = B:GetDebugState()
        frames = frames + 1
        if s.onUpdate then updates = updates + 1; eq(s.state, "air") end
        truthy(s.x >= minX - 1e-6 and s.x <= maxX + 1e-6, "x in bounds")
        if s.state ~= "burrow" then
            eq(s.spriteHidden, false, "sprite visible outside burrows")
            truthy(not s.holeA and not s.holeB, "no stray holes outside burrows (" .. s.state .. ")")
        end
    end)
    local s = B:GetDebugState()
    local total = 0
    for _, n in pairs(s.behaviors) do total = total + n end
    truthy(total >= 10, "behaviours: " .. total)
    truthy(s.naps >= 2, "naps: " .. s.naps)
    truthy(s.hops >= 50, "hops: " .. s.hops)
    truthy(s.burrows >= 3 and s.burrows <= 15, "burrows with a 2-min cooldown: " .. s.burrows)
    truthy(updates / frames < 0.15, "OnUpdate rarely active")
    truthy(mock.pendingTimers() <= 6, "timers don't pile up: " .. mock.pendingTimers())
end)

----------------------------------------------------------------------------
-- v0.3: burrowing
----------------------------------------------------------------------------

io.write("v0.3 burrowing\n")

local function bootAt(xFraction)
    local ns2 = boot({ schema = 3, idleExtras = false })
    mock.advance(1.05)
    -- Move the bunny to a known spot by hopping there (public API only).
    local B = ns2.Bunny
    local minX, maxX = ns2.Util.TrackBounds(BunnyBarDB.trackWidth, BunnyBarDB.size)
    return ns2, minX, maxX
end

local function burrowRun(ns2)
    local log = { }
    local prevPose, prevHidden
    local states = {}
    local t0 = mock.now
    while true do
        local s = ns2.Bunny:GetDebugState()
        if s.pose ~= prevPose or s.spriteHidden ~= prevHidden then
            log[#log + 1] = { pose = s.spriteHidden and "(underground)" or s.pose, a = s.holeA, b = s.holeB, x = s.x, at = mock.now - t0 }
            prevPose, prevHidden = s.pose, s.spriteHidden
        end
        if s.state == "idle" and #log > 1 then break end
        mock.advance(1 / 120)
        if mock.now - t0 > 20 then error("burrow never finished") end
    end
    return log
end

test("burrow left-to-right and right-to-left: full sequence, holes, cleanup", function()
    for _, dir in ipairs({ 1, -1 }) do
        local ns2, minX, maxX = bootAt()
        local B = ns2.Bunny
        -- Place the bunny at one end via a direct journey.
        B:Perform("hop")
        advanceUntil(ns2, function(s) return s.state == "idle" end, 10)
        local s = B:GetDebugState()
        eq(slash("test burrow"), true)
        local from = B:GetDebugState().burrowFrom
        local to = B:GetDebugState().burrowTo
        truthy(to >= minX and to <= maxX, "destination within track")
        local span = maxX - minX
        if from - minX > maxX - from then truthy(to <= minX + span * 0.25 + 1e-6, "goes to the far (left) side")
        else truthy(to >= maxX - span * 0.25 - 1e-6, "goes to the far (right) side") end
        eq(B:GetDebugState().facing, to > from and 1 or -1, "faces the travel direction")
        local log = burrowRun(ns2)
        local seq = {}
        for _, e in ipairs(log) do seq[#seq + 1] = e.pose end
        local str = table.concat(seq, ",")
        truthy(str:find("burrowSniffA,burrowSniffB", 1, true), str)
        truthy(str:find("burrowDigA,burrowDigB", 1, true), str)
        truthy(str:find("burrowSink1,burrowSink2,burrowSink3,burrowSink4,(underground),burrowEmerge1,burrowEmerge2,burrowPop", 1, true), str)
        truthy(str:find("burrowShakeA,burrowShakeB", 1, true), str)
        -- Holes: A appears while digging and grows; B appears after the trip.
        local sawA, sawB, sawBothOpen = {}, false, false
        for _, e in ipairs(log) do
            if e.a then sawA[e.a] = true end
            if e.b then sawB = true end
            if e.a == 3 and e.b == 3 then sawBothOpen = true end
            if e.pose == "(underground)" then eq(e.a, 3, "origin hole open while underground") end
        end
        truthy(sawA[1] and sawA[2] and sawA[3], "origin hole mound -> hole")
        truthy(sawB and sawBothOpen, "second hole opens")
        local final = B:GetDebugState()
        eq(final.holeA, nil); eq(final.holeB, nil); eq(final.spriteHidden, false)
        eq(final.x, to, "bunny ends at the destination")
        local holes = B:GetHoles()
        for _, h in pairs(holes) do eq(h.back:IsShown(), false); eq(h.front:IsShown(), false) end
        eq(final.onUpdate, false)
    end
end)

test("burrow holes stay aligned with the ground and the bunny frame", function()
    local ns2 = boot({ schema = 3, idleExtras = false })
    mock.advance(1.05)
    slash("test burrow")
    advanceUntil(ns2, function(s) return s.holeA == 3 end, 10)
    local h = ns2.Bunny:GetHoles().A
    local p, rel, rp, x, y = h.back:GetPoint(1)
    eq(p, "BOTTOMLEFT"); eq(rel, BunnyBarFrame); eq(y, 0, "on the ground line")
    eq(h.back:GetWidth(), BunnyBarDB.size)
    eq(h.back._layer, "BORDER", "behind the bunny"); eq(h.front._layer, "OVERLAY", "rim in front")
    local fl, fr, ft, fb = h.front:GetTexCoord()
    eq(ft, 0.5); eq(fb, 1)
end)

test("burrow interrupted in every phase cleans up completely", function()
    for _, phase in ipairs({ "burrowSniffA", "burrowDigB", "burrowSink3", "(underground)", "burrowEmerge1", "burrowShakeA" }) do
        for _, how in ipairs({ "hide", "uihide", "reset", "size", "test" }) do
            local ns2 = boot({ schema = 3, idleExtras = false })
            mock.advance(1.05)
            slash("test burrow")
            advanceUntil(ns2, function(s)
                return (phase == "(underground)" and s.spriteHidden) or s.pose == phase
            end, 10)
            if how == "hide" then slash("hide")
            elseif how == "uihide" then UIParent:Hide()
            elseif how == "reset" then slash("reset")
            elseif how == "size" then slash("size 48")
            else slash("test") end
            local s = ns2.Bunny:GetDebugState()
            local label = phase .. "/" .. how
            eq(s.holeA, nil, label); eq(s.holeB, nil, label); eq(s.spriteHidden, false, label)
            eq(s.burrowing, false, label)
            local holes = ns2.Bunny:GetHoles()
            for _, h in pairs(holes) do eq(h.back:IsShown(), false, label); eq(h.front:IsShown(), false, label) end
            if how == "hide" or how == "uihide" then
                eq(s.state, "stopped", label); eq(mock.pendingTimers() <= 1, true, label .. " timers")
            end
            if how == "uihide" then UIParent:Show() end
            if how == "hide" then slash("show") end
            mock.advance(30)
            s = ns2.Bunny:GetDebugState()
            local minX, maxX = ns2.Util.TrackBounds(BunnyBarDB.trackWidth, BunnyBarDB.size)
            truthy(s.x >= minX and s.x <= maxX, label .. " in bounds")
        end
    end
end)

test("burrow rarity: cooldown by frequency, off switch, too-short track", function()
    local function countBurrows(freq, minutes)
        math.randomseed(5)
        local ns2 = boot({ schema = 3, idleExtras = false, sleepChance = 0, burrowFrequency = freq })
        mock.advance(minutes * 60, 1 / 10)
        return ns2.Bunny:GetDebugState().burrows
    end
    eq(countBurrows("normal", 3.9), 0, "nothing before the 4-minute cooldown")
    local rare, often = countBurrows("rare", 30), countBurrows("often", 30)
    truthy(often > rare, ("often %d > rare %d"):format(often, rare))
    truthy(rare <= 30 / 7 + 1, "rare respects its 7-minute cooldown: " .. rare)
    math.randomseed(5)
    local ns2 = boot({ schema = 3, idleExtras = false, burrow = false, burrowFrequency = "often" })
    mock.advance(1800, 1 / 10)
    eq(ns2.Bunny:GetDebugState().burrows, 0, "burrow off")
    -- A track barely wider than the bunny can't burrow.
    ns2 = boot({ schema = 3, trackWidth = 80 })
    mock.advance(1.05)
    eq(slash("test burrow"), false); truthy(lastChat():find("too short"))
end)

----------------------------------------------------------------------------
-- v0.3: styles
----------------------------------------------------------------------------

io.write("v0.3 styles\n")

test("five styles: textures from their own folder, same frames", function()
    for _, id in ipairs({ "classic", "devil", "angel", "dragon", "zombie" }) do
        local ns2 = boot({ schema = 3, variation = id })
        local fur = bunnyLayers()
        local folder = id == "classic" and "Textures\\bunny%-idle%.tga" or ("Textures\\" .. id .. "\\bunny%-idle%.tga")
        truthy(fur._texture:find(folder), id .. ": " .. fur._texture)
        local data = ns2.SpriteData[id]
        truthy(data, "sprite data for " .. id)
        for key, sheet in pairs(ns2.Bunny.SHEETS) do
            eq(#data[sheet.file], sheet.count, id .. " " .. sheet.file .. " frame count")
        end
    end
end)

test("style follows its default fur unless a custom colour was picked", function()
    local ns2 = boot({ schema = 3 })
    eq(slash("style devil"), true)
    eq(BunnyBarDB.variation, "devil"); eq(BunnyBarDB.furColor, nil); eq(ns.Config.FurColor(BunnyBarDB), "E06E7C", "devil default fur")
    eq(slash("style angel"), true); eq(ns.Config.FurColor(BunnyBarDB), "FFF6E6")
    eq(slash("color #87CEEB"), true)
    eq(slash("style dragon"), true)
    eq(BunnyBarDB.variation, "dragon"); eq(BunnyBarDB.furColor, "87CEEB", "custom colour kept")
    eq(slash("color reset"), true); eq(BunnyBarDB.furColor, nil, "reset clears the override")
    eq(ns.Config.FurColor(BunnyBarDB), "86C784", "reset -> style default")
    eq(slash("style ghost"), false); truthy(lastChat():find("not a style"))
    eq(BunnyBarDB.variation, "dragon")
    eq(slash("style"), true); truthy(lastChat():find("style is dragon"))
end)

test("fur colour applies on every style and every sheet", function()
    for _, id in ipairs({ "classic", "devil", "angel", "dragon", "zombie" }) do
        math.randomseed(13)
        local ns2 = boot({ schema = 3, variation = id, furColor = "FFB6C1", sleepChance = 0.4, burrowFrequency = "often" })
        local fur, detail = bunnyLayers()
        local sheets = {}
        mock.advance(400, 1 / 15, function()
            local r, g, b = fur:GetVertexColor()
            near(r, 1); near(g, 0xB6 / 255); near(b, 0xC1 / 255)
            eq(detail._vertex, nil)
            sheets[fur._texture] = true
        end)
        local n = 0
        for _ in pairs(sheets) do n = n + 1 end
        truthy(n >= 5, id .. " sheets seen: " .. n)
    end
end)

test("changing style mid-nap or mid-behaviour doesn't reset the animation", function()
    local ns2 = bootNap(21)
    advanceUntil(ns2, function(s) return s.pose == "sleep2" end, 30)
    local before = ns2.Bunny:GetDebugState()
    slash("style zombie")
    local after = ns2.Bunny:GetDebugState()
    eq(after.state, before.state); eq(after.pose, "sleep2")
    truthy(bunnyLayers()._texture:find("zombie"), "texture switched immediately")
    -- mid-behaviour
    ns2 = boot({ schema = 3 })
    mock.advance(1.05)
    slash("test carrot")
    advanceUntil(ns2, function(s) return s.pose == "carrotHold" end, 10)
    slash("style angel")
    eq(ns2.Bunny:GetDebugState().state, "behavior"); eq(ns2.Bunny:GetDebugState().pose, "carrotHold")
    truthy(bunnyLayers()._texture:find("angel\\bunny%-carrot"))
end)

test("schema 2 settings migrate to 3 with behaviour and heart defaults", function()
    boot({ schema = 2, size = 96, furColor = "112233", variation = "classic", earsParty = false, speed = 1.5 })
    local db = BunnyBarDB
    eq(db.schema, 5); eq(db.size, 96); eq(db.furColor, "112233"); eq(db.earsParty, false); eq(db.speed, 1.5)
    eq(db.idleExtras, true); eq(db.carrot, true); eq(db.burrow, true); eq(db.burrowFrequency, "normal")
    eq(db.hearts, true); eq(db.heartIntensity, "normal"); eq(db.variation, "classic")
    boot({ schema = 3, burrowFrequency = "SOMETIMES", heartIntensity = "EXTRA", variation = "Devil" })
    eq(BunnyBarDB.burrowFrequency, "normal"); eq(BunnyBarDB.heartIntensity, "extra")
    eq(BunnyBarDB.variation, "classic", "unknown spelling falls back")
end)

----------------------------------------------------------------------------
-- v0.3: hover hearts
----------------------------------------------------------------------------

io.write("v0.3 hover hearts\n")

local function bootHearts(saved)
    local ns2 = boot(saved or { schema = 3, idleExtras = false, burrow = false, sleepChance = 0 })
    mock.advance(1.05)
    return ns2
end

local function pointAt(ns2, fx, fy)
    -- A point inside the current sprite box at fractions (fx, fy).
    local l, r, b, t = ns2.Bunny:GetSpriteBox()
    return l + (r - l) * fx, b + (t - b) * fy
end

test("hit test: sprite box only, mirrored, nothing when underground", function()
    local ns2 = bootHearts()
    local B = ns2.Bunny
    local l, r, b, t = B:GetSpriteBox()
    truthy(l and r > l and t > b)
    truthy(B:HitTest(pointAt(ns2, 0.5, 0.5)))
    -- Empty parts of the track never count.
    local f = BunnyBarFrame
    eq(B:HitTest(f:GetLeft() + 2, f:GetBottom() + 2), false, "far left of the track")
    eq(B:HitTest(r + 20, (b + t) / 2), false, "beside the bunny")
    eq(B:HitTest((l + r) / 2, t + 20), false, "above the bunny")
    -- The box is tight (smaller than the 64x64 frame).
    truthy(r - l < BunnyBarDB.size and t - b < BunnyBarDB.size + 0.01)
    -- Underground: invisible, so not hoverable.
    slash("test burrow")
    advanceUntil(ns2, function(s) return s.spriteHidden end, 10)
    eq(B:GetSpriteBox(), nil); eq(B:HitTest((l + r) / 2, (b + t) / 2), false)
end)

test("hearts appear while hovering, never while hovering empty track", function()
    local ns2 = bootHearts()
    local cx, cy = pointAt(ns2, 0.5, 0.6)
    mock.cursor[1], mock.cursor[2] = cx, cy
    mock.advance(2)
    local st = ns2.Hearts.GetState()
    truthy(st.emitted >= 4, "emitted while hovering: " .. st.emitted)
    truthy(st.busy <= ns2.Hearts.INTENSITY.normal.max)
    local before = st.emitted
    local f = BunnyBarFrame
    mock.cursor[1], mock.cursor[2] = f:GetLeft() + 5, f:GetBottom() + 5
    mock.advance(2)
    eq(ns2.Hearts.GetState().emitted, before, "no hearts over empty track")
end)

test("hearts never wake a sleeping bunny; sleep and hearts run independently", function()
    local ns2 = bootNap(21)
    advanceUntil(ns2, function(s) return s.state == "sleep" end, 30)
    local wakeAt = ns2.Bunny:GetDebugState().sleepUntil
    mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5)
    local log = recordPoses(ns2, function(s) return s.state == "waking" end, 40)
    truthy(ns2.Hearts.GetState().emitted >= 5, "hearts while asleep")
    truthy(mock.now >= wakeAt - 0.01, "woke only when the nap was over")
    for i = 1, #log - 1 do
        local p = log[i].pose
        truthy(p:find("^sleep") or p:find("^liedown"), "only sleep poses until waking: " .. p)
    end
end)

test("hearts work during hops, behaviours and digging", function()
    for _, what in ipairs({ "hop", "carrot", "burrow" }) do
        local ns2 = bootHearts({ schema = 3, idleExtras = false, sleepChance = 0 })
        slash("test " .. what)
        local emitted = 0
        mock.advance(1.2, 1 / 60, function()
            local l = ns2.Bunny:GetSpriteBox()
            if l then mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5) end
        end)
        truthy(ns2.Hearts.GetState().emitted >= 2, what .. ": " .. ns2.Hearts.GetState().emitted)
    end
end)

test("click-through: bunny, hearts layer and particles never take the mouse", function()
    local ns2 = bootHearts()
    mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5)
    mock.advance(1)
    eq(BunnyBarFrame:IsMouseEnabled(), false)
    local layer = ns2.Hearts.GetState().layer
    truthy(layer, "hearts layer exists")
    eq(layer:IsMouseEnabled(), false)
    eq(layer._parent, BunnyBarFrame, "contained in BunnyBar's own frame")
    eq(BunnyBarFrame:GetScript("OnEnter"), nil, "no reliance on OnEnter")
end)

test("hover polling is throttled: slow when far, fast only when near, off when unused", function()
    local ns2 = bootHearts()
    mock.cursor[1], mock.cursor[2] = 10, 1000 -- far away
    local c0 = ns2.Hearts.GetState().checks
    mock.advance(10)
    local far = ns2.Hearts.GetState().checks - c0
    truthy(far >= 36 and far <= 44, "about 4 checks per second when far: " .. far)
    mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5)
    c0 = ns2.Hearts.GetState().checks
    mock.advance(10)
    local nearChecks = ns2.Hearts.GetState().checks - c0
    truthy(nearChecks >= 180 and nearChecks <= 210, "about 20 per second when near: " .. nearChecks)
    slash("hearts off")
    eq(ns2.Hearts.GetState().polling, false, "no polling when hearts are off")
    c0 = ns2.Hearts.GetState().checks
    mock.advance(5)
    eq(ns2.Hearts.GetState().checks, c0)
    slash("hearts on")
    eq(ns2.Hearts.GetState().polling, true)
    UIParent:Hide()
    eq(ns2.Hearts.GetState().polling, false, "stops when the UI is hidden")
    UIParent:Show()
    eq(ns2.Hearts.GetState().polling, true)
    slash("hide")
    eq(ns2.Hearts.GetState().polling, false, "stops when the bunny is hidden")
end)

test("heart particles: animated, limited per intensity, removed when done", function()
    local ns2 = bootHearts({ schema = 3, idleExtras = false, burrow = false, sleepChance = 0, heartIntensity = "subtle" })
    mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5)
    mock.advance(5, 1 / 30, function()
        truthy(ns2.Hearts.GetState().busy <= 3, "subtle: at most 3 at once")
    end)
    local layer = ns2.Hearts.GetState().layer
    local tex
    for _, ch in ipairs(layer._children) do if ch._animGroups then tex = ch end end
    truthy(tex, "particle texture")
    local ag = tex._animGroups[1]
    local kinds = {}
    for _, a in ipairs(ag._anims) do kinds[a._kind] = a end
    truthy(kinds.Translation and kinds.Alpha, "rises and fades with native animations")
    eq(kinds.Translation._offset[2], math.floor(BunnyBarDB.size * 0.55 + 0.5), "rises above the bunny")
    eq(kinds.Alpha._to, 0)
    -- Move away: every particle finishes and is hidden; pool stays small.
    mock.cursor[1], mock.cursor[2] = 10, 1000
    mock.advance(2)
    eq(ns2.Hearts.GetState().busy, 0)
    for _, ch in ipairs(layer._children) do eq(ch:IsShown(), false) end
    truthy(ns2.Hearts.GetState().pool <= ns2.Hearts.POOL_SIZE)
    -- Hiding the bunny clears hearts immediately.
    mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5)
    mock.advance(0.5)
    truthy(ns2.Hearts.GetState().busy > 0)
    slash("hide")
    eq(ns2.Hearts.GetState().busy, 0)
    for _, ch in ipairs(layer._children) do eq(ch:IsShown(), false) end
end)

test("/bunny test hearts bursts; settings commands validate", function()
    local ns2 = bootHearts()
    eq(slash("test hearts"), true)
    mock.advance(2)
    truthy(ns2.Hearts.GetState().emitted >= 4)
    eq(slash("hearts extra"), true); eq(BunnyBarDB.heartIntensity, "extra")
    eq(slash("hearts off"), true); eq(BunnyBarDB.hearts, false)
    eq(slash("test hearts"), false); truthy(lastChat():find("hearts are off"))
    eq(slash("hearts sometimes"), false)
    eq(slash("burrow rare"), true); eq(BunnyBarDB.burrowFrequency, "rare")
    eq(slash("burrow off"), true); eq(BunnyBarDB.burrow, false)
    eq(slash("idle off"), true); eq(BunnyBarDB.idleExtras, false)
    eq(slash("carrot off"), true); eq(BunnyBarDB.carrot, false)
    eq(slash("test dance"), false); truthy(lastChat():find("unknown test"))
end)

test("hearts without cursor or animation APIs stay off quietly", function()
    local ns2 = bootHearts()
    local saved = GetCursorPosition
    rawset(_G, "GetCursorPosition", nil) -- (rawset: test setup, not an addon global)
    ns2.Hearts.Refresh()
    eq(ns2.Hearts.IsActive(), false)
    eq(ns2.Hearts.GetState().polling, false)
    mock.advance(2)
    rawset(_G, "GetCursorPosition", saved)
    -- Textures without CreateAnimationGroup: Emit refuses instead of erroring.
    local ns3 = bootHearts()
    local orig = nil
    local mt = getmetatable(BunnyBarFrame).__index
    orig = mt.CreateAnimationGroup
    mt.CreateAnimationGroup = nil
    local ok = ns3.Hearts.Emit(1000, 200)
    eq(ok, false)
    mt.CreateAnimationGroup = orig
end)

test("hearts work in combat (no protected operations)", function()
    local ns2 = bootHearts()
    mock.combat = true
    mock.cursor[1], mock.cursor[2] = pointAt(ns2, 0.5, 0.5)
    mock.advance(1)
    truthy(ns2.Hearts.GetState().emitted >= 2)
    mock.combat = false
end)

test("behaviour and heart settings persist and sync with the panel", function()
    local ns2, c = bootPanel({ schema = 3 })
    c.behaviors.carrot:Click()
    c.burrowFrequency[1]:Click()
    c.heartIntensity[3]:Click()
    c.hearts:Click()
    eq(BunnyBarDB.carrot, false); eq(BunnyBarDB.burrowFrequency, "rare")
    eq(BunnyBarDB.heartIntensity, "extra"); eq(BunnyBarDB.hearts, false)
    eq(ns2.Hearts.GetState().polling, false)
    local saved = BunnyBarDB
    local ns3, c3 = bootPanel(saved)
    eq(c3.behaviors.carrot:GetChecked(), false); eq(c3.burrowFrequency[1]:GetChecked(), true)
    eq(c3.heartIntensity[3]:GetChecked(), true); eq(c3.hearts:GetChecked(), false)
    slash("burrow often")
    eq(c3.burrowFrequency[3]:GetChecked(), true, "slash -> panel")
    c3.styles[2]:Click()
    eq(BunnyBarDB.variation, "devil")
end)

----------------------------------------------------------------------------
-- v0.3 fixes: style default colours and the style-aware preview
----------------------------------------------------------------------------

io.write("v0.3 colour reset and preview\n")

local STYLE_DEFAULTS = { classic = "F6F3FA", devil = "E06E7C", angel = "FFF6E6",
                         dragon = "86C784", zombie = "A9C4A2" }

local function hexOf(r, g, b) return ns.Util.RGBToHex(r, g, b) end

test("style defaults come from the Appearance registry", function()
    local ns2 = boot({ schema = 4 })
    for id, hex in pairs(STYLE_DEFAULTS) do
        eq(ns2.Config.StyleDefaultFur(id), hex, id)
        eq(ns2.Appearance.Get("variation", id).defaultFur, hex, id)
    end
end)

test("Reset Color restores the selected style's default and clears the override", function()
    for id, hex in pairs(STYLE_DEFAULTS) do
        local ns2, c = bootPanel({ schema = 4, variation = id, furColor = "123456" })
        eq(ns2.Config.HasCustomFur(), true)
        local x0, state0 = ns2.Bunny:GetDebugState().x, ns2.Bunny:GetDebugState().state
        c.reset:Click()
        eq(BunnyBarDB.furColor, nil, id .. ": override cleared")
        eq(ns2.Config.FurColor(), hex, id .. ": style default")
        local fur = bunnyLayers()
        eq(hexOf(fur:GetVertexColor()), hex, id .. ": live bunny")
        eq(hexOf(c.previewLayers[1]:GetVertexColor()), hex, id .. ": preview")
        eq(c.hex:GetText(), "#" .. hex, id .. ": hex box")
        eq(hexOf(c.swatch._color[1], c.swatch._color[2], c.swatch._color[3]), hex, id .. ": swatch")
        local h, sat, v = ns2.Util.RGBToHSV(ns2.Util.HSVToRGB(ns2.Options.GetHSV()))
        eq(ns2.Util.RGBToHex(ns2.Util.HSVToRGB(ns2.Options.GetHSV())), hex, id .. ": HSV state")
        eq(c.brightness:GetValue(), math.floor(v * 100 + 0.5), id .. ": brightness slider")
        eq(ns2.Bunny:GetDebugState().state, state0, "main bunny state untouched")
        eq(ns2.Bunny:GetDebugState().x, x0)
        -- Reset persists across /reload.
        local saved = BunnyBarDB
        local ns3 = boot(saved)
        eq(BunnyBarDB.furColor, nil); eq(ns3.Config.FurColor(), hex, id .. " after reload")
    end
end)

test("switching style without an override uses each style's own colour", function()
    local ns2, c = bootPanel({ schema = 4 })
    for i, id in ipairs({ "devil", "angel", "dragon", "zombie", "classic" }) do
        if i % 2 == 0 then slash("style " .. id) else
            for _, rb in ipairs(c.styles) do if rb.value == id then rb:Click() end end
        end
        eq(BunnyBarDB.variation, id); eq(BunnyBarDB.furColor, nil)
        eq(hexOf(bunnyLayers():GetVertexColor()), STYLE_DEFAULTS[id], id .. ": bunny")
        eq(hexOf(c.previewLayers[1]:GetVertexColor()), STYLE_DEFAULTS[id], id .. ": preview")
        eq(c.hex:GetText(), "#" .. STYLE_DEFAULTS[id], id .. ": hex box follows")
    end
end)

test("custom colours, including white and other styles' defaults, persist across styles", function()
    for _, custom in ipairs({ "FFFFFF", "87CEEB", "E06E7C", "F6F3FA" }) do
        local ns2, c = bootPanel({ schema = 4 })
        c.hex:MockType("#" .. custom)
        eq(BunnyBarDB.furColor, custom, custom .. " stored as an override")
        eq(ns2.Config.HasCustomFur(), true)
        for _, id in ipairs({ "devil", "angel", "dragon", "zombie", "classic" }) do
            slash("style " .. id)
            eq(ns2.Config.FurColor(), custom, custom .. " kept on " .. id)
            eq(hexOf(c.previewLayers[1]:GetVertexColor()), custom)
        end
        local saved = BunnyBarDB
        local ns3 = boot(saved)
        eq(BunnyBarDB.furColor, custom, custom .. " survives /reload")
        eq(ns3.Config.HasCustomFur(), true)
    end
end)

test("the preview shows the selected style's sprites and follows every change", function()
    local ns2, c = bootPanel({ schema = 4 })
    local pv, fur, detail = c.preview, c.previewLayers[1], c.previewLayers[2]
    local _, rel, rp, px, py = pv:GetPoint(1)
    eq(pv:GetWidth(), 64); eq(pv:GetHeight(), 64)
    truthy(fur._texture:find("Textures\\bunny%-idle%.tga"), fur._texture)
    for _, id in ipairs({ "devil", "angel", "dragon", "zombie" }) do
        slash("style " .. id)
        truthy(fur._texture:find("Textures\\" .. id .. "\\bunny%-idle%.tga"), id .. ": " .. fur._texture)
        eq(detail._texture, fur._texture, "both layers use the style's sheet")
        local l, r, t, b = fur:GetTexCoord()
        eq(l, 0); eq(r, 0.25); eq(t, 0); eq(b, 0.5)
        local _, rel2, rp2, px2, py2 = pv:GetPoint(1)
        eq(rel2, rel); eq(px2, px); eq(py2, py); eq(pv:GetWidth(), 64)
    end
    -- Colour change and reset reach the preview immediately.
    c.hex:MockType("#336699")
    eq(hexOf(fur:GetVertexColor()), "336699")
    eq(detail._vertex, nil, "detail layer never tinted")
    c.reset:Click()
    eq(hexOf(fur:GetVertexColor()), STYLE_DEFAULTS.zombie)
    -- Changes made while the panel is closed show when it reopens.
    ns2.Options.panel:Hide()
    slash("style angel")
    slash("color #AA5500")
    ns2.Options.panel:Show()
    truthy(fur._texture:find("angel"), "reopened panel shows the new style")
    eq(hexOf(fur:GetVertexColor()), "AA5500")
end)

test("updating the preview never changes the main bunny's animation", function()
    local ns2, c = bootPanel({ schema = 4 })
    slash("test carrot")
    advanceUntil(ns2, function(s) return s.pose == "carrotHold" end, 10)
    local before = ns2.Bunny:GetDebugState()
    for _ = 1, 5 do ns2.Options.UpdatePreview(); ns2.Options.Refresh() end
    local after = ns2.Bunny:GetDebugState()
    eq(after.state, before.state); eq(after.pose, before.pose); eq(after.x, before.x)
    eq(c.preview:GetScript("OnUpdate"), nil, "no animation loop for the preview")
end)

test("older saves: a stored style default becomes 'no override', custom colours stay", function()
    local cases = {
        { { schema = 2, furColor = "F6F3FA" }, nil },                          -- v0.2 untouched
        { { schema = 3, variation = "devil", furColor = "E06E7C" }, nil },     -- followed style
        { { schema = 3, variation = "classic", furColor = "E06E7C" }, "E06E7C" }, -- custom
        { { schema = 3, variation = "angel", furColor = "FFFFFF" }, "FFFFFF" },   -- custom white
        { { schema = 3, furColor = "nonsense" }, nil },
        { { schema = 4, variation = "devil", furColor = "E06E7C" }, "E06E7C" },  -- explicit in v4
    }
    for i, case in ipairs(cases) do
        local ns2 = boot(case[1])
        eq(BunnyBarDB.furColor, case[2], "case " .. i)
        eq(BunnyBarDB.schema, 5)
    end
end)

test("/bunny color reports custom vs style default", function()
    local ns2 = boot({ schema = 4, variation = "dragon" })
    slash("color")
    truthy(lastChat():find("#86C784") and lastChat():find("default for dragon"), lastChat())
    slash("color #FFFFFF")
    slash("color")
    truthy(lastChat():find("#FFFFFF") and lastChat():find("custom"), lastChat())
    slash("color reset")
    truthy(lastChat():find("dragon default #86C784"), lastChat())
    eq(BunnyBarDB.furColor, nil)
end)

----------------------------------------------------------------------------
-- Regression: portrait ears with styles / optional fur colour (v0.3)
----------------------------------------------------------------------------

io.write("Portrait ears regression\n")

-- "Interface\AddOns\BunnyBar\Textures\x.tga" -> does the file exist on disk?
local function textureExists(path)
    local rel = path:gsub("^Interface\\AddOns\\BunnyBar\\", ADDON_DIR .. "/"):gsub("\\", "/")
    local f = io.open(rel, "rb")
    if f then f:close() return true end
    return false
end

local function earLayers(ns2, key)
    local o = ns2.Ears.GetState()[key or "player"].overlay
    local fur, detail
    for _, ch in ipairs(o._children) do
        if ch._texture then if not fur then fur = ch else detail = ch end end
    end
    return fur, detail, o
end

local ALL_STYLES = { "classic", "devil", "angel", "dragon", "zombie" }

test("every texture requested at login exists, for every saved style", function()
    for _, id in ipairs(ALL_STYLES) do
        local ns2 = boot({ schema = 4, variation = id },
            { setup = function() mkPlayer(100, 900, 60); mkParty(2); mkLayeredPlayer() end })
        slash("test burrow"); mock.advance(3)       -- burrow holes
        slash("test hearts"); mock.advance(0.5)     -- heart particles
        local n = 0
        for path in pairs(mock.texturePaths) do
            n = n + 1
            truthy(textureExists(path), id .. ": missing texture " .. path)
        end
        local T = "Interface\\AddOns\\BunnyBar\\Textures\\"
        truthy(mock.texturePaths[T .. "bunny-ears.tga"], id .. ": ears requested")
        truthy(mock.texturePaths[T .. "bunny-burrow-fx.tga"], id .. ": burrow holes requested")
        truthy(n >= 4, id .. ": textures requested " .. n)
    end
end)

test("portrait ears load the shared texture with every saved style", function()
    for _, id in ipairs(ALL_STYLES) do
        local ns2 = boot({ schema = 4, variation = id },
            { setup = function() mkPlayer(100, 900, 60); mkParty(2) end })
        for _, key in ipairs({ "player", "party1", "party2" }) do
            local e = ns2.Ears.GetState()[key]
            eq(e.shown, true, id .. " " .. key .. " shown")
            local fur, detail = earLayers(ns2, key)
            eq(fur._texture, "Interface\\AddOns\\BunnyBar\\Textures\\bunny-ears.tga", id .. " " .. key)
            eq(detail._texture, fur._texture)
            truthy(textureExists(fur._texture))
            eq(hexOf(fur:GetVertexColor()), STYLE_DEFAULTS[id], id .. " " .. key .. " tinted with the style default")
            eq(detail._vertex, nil)
        end
    end
end)

test("portrait ear tint follows every colour path", function()
    local ns2, c = bootPanel({ schema = 4 }, function() mkPlayer(100, 900, 60); mkParty(1) end)
    local function earsAre(hex, why)
        for _, key in ipairs({ "player", "party1" }) do
            eq(hexOf(earLayers(ns2, key):GetVertexColor()), hex, why .. " (" .. key .. ")")
        end
        eq(hexOf(bunnyLayers():GetVertexColor()), hex, why .. " (bunny)")
    end
    earsAre("F6F3FA", "no custom colour")
    slash("color #87CEEB"); earsAre("87CEEB", "custom colour")
    slash("color #FFFFFF"); earsAre("FFFFFF", "explicit white")
    eq(BunnyBarDB.furColor, "FFFFFF")
    slash("style devil"); earsAre("FFFFFF", "custom kept on style change")
    c.reset:Click(); earsAre("E06E7C", "panel Reset Color -> devil default")
    slash("style zombie"); earsAre("A9C4A2", "style change without override")
    slash("color #123456"); slash("color reset"); earsAre("A9C4A2", "/bunny color reset")
    -- /reload with the saved state
    local saved = BunnyBarDB
    local ns3 = boot(saved, { setup = function() mkPlayer(100, 900, 60) end })
    eq(hexOf(earLayers(ns3):GetVertexColor()), "A9C4A2", "after /reload")
    truthy(textureExists(earLayers(ns3)._texture))
end)

test("migrated saves keep working portrait ears", function()
    for _, saved in ipairs({
        { schema = 2, furColor = "F6F3FA" },
        { schema = 3, variation = "dragon", furColor = "86C784" },
        { schema = 3, variation = "angel", furColor = "FFFFFF" },
    }) do
        local ns2 = boot(saved, { setup = function() mkPlayer(100, 900, 60) end })
        local fur = earLayers(ns2)
        eq(ns2.Ears.GetState().player.shown, true)
        truthy(textureExists(fur._texture))
        eq(hexOf(fur:GetVertexColor()), ns2.Config.FurColor())
    end
end)

test("ear visibility toggles keep layering, anchoring and click-through", function()
    local ns2 = boot({ schema = 4, variation = "devil" },
        { setup = function() mkLayeredPlayer({ ringLevel = 40 }); mkParty(1) end })
    local _, _, o = earLayers(ns2)
    local strata, level = o:GetFrameStrata(), o:GetFrameLevel()
    eq(level, 50, "above the portrait ring")
    slash("ears player off"); eq(ns2.Ears.GetState().player.shown, false)
    eq(ns2.Ears.GetState().party1.shown, true, "party unaffected")
    slash("ears party off"); eq(ns2.Ears.GetState().party1.shown, false)
    slash("ears player on"); slash("ears party on")
    local st = ns2.Ears.GetState()
    eq(st.player.shown, true); eq(st.party1.shown, true)
    eq(o:GetFrameStrata(), strata); eq(o:GetFrameLevel(), level)
    local _, rel = o:GetPoint(1)
    eq(rel, UIParent); eq(o:IsMouseEnabled(), false)
end)

----------------------------------------------------------------------------
-- v0.4: personalities and moods
----------------------------------------------------------------------------

io.write("v0.4 personalities and moods\n")

local PERSONALITIES = { "balanced", "lazy", "energetic", "playful", "sleepy" }

-- Long seeded simulation; returns stats and behaviour/stretch-after-wake counts.
local function simulate(saved, minutes, seed)
    math.randomseed(seed or 101)
    local ns2 = boot(saved)
    local wakeStretch, prev, asleep = 0, nil, 0
    mock.advance(minutes * 60, 1 / 10, function()
        local s = ns2.Bunny:GetDebugState()
        if prev == "waking" and s.state == "behavior" and s.behavior == "stretch" then wakeStretch = wakeStretch + 1 end
        if s.state == "sleep" or s.state == "liedown" or s.state == "drowsy" then asleep = asleep + 0.1 end
        prev = s.state
    end)
    local s = ns2.Bunny:GetDebugState()
    s.asleep = asleep
    return s, wakeStretch, ns2
end

test("personality: default Balanced, slash selection, validation, persistence", function()
    local ns2 = boot(nil)
    eq(BunnyBarDB.personality, "balanced"); eq(BunnyBarDB.moods, true)
    eq(slash("personality"), true); truthy(lastChat():find("personality is Balanced"))
    for _, id in ipairs(PERSONALITIES) do
        eq(slash("personality " .. id:upper()), true, id)
        eq(BunnyBarDB.personality, id)
        truthy(lastChat():find("personality set to"), lastChat())
    end
    eq(slash("personality grumpy"), false)
    truthy(lastChat():find("'grumpy' is not a personality"), lastChat())
    eq(BunnyBarDB.personality, "sleepy", "unchanged after bad input")
    local saved = BunnyBarDB
    boot(saved)
    eq(BunnyBarDB.personality, "sleepy", "persists across /reload")
end)

test("Balanced without moods is exactly the v0.3 scheduler", function()
    local ns2 = boot({ schema = 5, moods = false })
    local P = ns2.Personality.Params()
    eq(P.nap, 1); eq(P.burrow, 1); eq(P.behavior, 1); eq(P.wait, 1); eq(P.sleep, 1); eq(P.wakeStretch, 0)
    for _, name in ipairs(ns2.Bunny.BEHAVIOR_ORDER) do eq(P.weights[name], 1, name) end
    eq(ns2.Personality.Chance(0.15, 1), 0.15)
    -- Happy is neutral too: Balanced + Happy = v0.3.
    BunnyBarDB.moods = true
    ns2.Personality.Reset()
    P = ns2.Personality.Params()
    eq(P.nap, 1); eq(P.behavior, 1); eq(P.wait, 1); eq(P.burrow, 1)
end)

test("personalities change behaviour selection as described (seeded)", function()
    local function run(id)
        return (simulate({ schema = 5, personality = id, moods = false, burrowFrequency = "often" }, 60, 202))
    end
    local r = {}
    for _, id in ipairs(PERSONALITIES) do r[id] = run(id) end
    local function carrots(s) return s.behaviors.carrot or 0 end
    local function behaviours(s) local n = 0 for _, v in pairs(s.behaviors) do n = n + v end return n end
    truthy(r.energetic.hops > r.balanced.hops and r.balanced.hops > r.lazy.hops,
        ("hops: energetic %d > balanced %d > lazy %d"):format(r.energetic.hops, r.balanced.hops, r.lazy.hops))
    truthy(r.sleepy.naps > r.balanced.naps and r.balanced.naps > r.energetic.naps,
        ("naps: sleepy %d > balanced %d > energetic %d"):format(r.sleepy.naps, r.balanced.naps, r.energetic.naps))
    truthy(r.lazy.asleep > r.balanced.asleep * 1.25,
        ("time asleep: lazy %.0fs > balanced %.0fs"):format(r.lazy.asleep, r.balanced.asleep))
    truthy(r.sleepy.asleep > r.lazy.asleep, "sleepy sleeps the most")
    truthy(r.playful.burrows > r.balanced.burrows,
        ("burrows: playful %d > balanced %d"):format(r.playful.burrows, r.balanced.burrows))
    truthy(carrots(r.playful) > carrots(r.balanced),
        ("carrots: playful %d > balanced %d"):format(carrots(r.playful), carrots(r.balanced)))
    truthy(behaviours(r.energetic) > behaviours(r.lazy), "energetic does more idle activities overall")
end)

test("Sleepy (and Lazy) sometimes stretch right after waking; Balanced never", function()
    local _, sleepyStretch = simulate({ schema = 5, personality = "sleepy", moods = false }, 60, 303)
    local _, balancedStretch = simulate({ schema = 5, personality = "balanced", moods = false }, 60, 303)
    truthy(sleepyStretch >= 2, "sleepy wake stretches: " .. sleepyStretch)
    eq(balancedStretch, 0)
end)

test("personalities never change animation speed or sprites", function()
    for _, id in ipairs(PERSONALITIES) do
        local ns2 = boot({ schema = 5, personality = id, variation = "devil", size = 64, speed = 1.5 })
        local fur = bunnyLayers()
        truthy(fur._texture:find("devil"), id)
        eq(fur:GetWidth(), 64)
        eq(ns2.Bunny.HOP_TIMING.prep, 0.09)
        eq(BunnyBarDB.speed, 1.5)
        eq(ns2.Bunny.SEQUENCES.carrot[1][2], 0.30)
    end
end)

test("moods evolve deterministically on activity events, with hysteresis", function()
    local ns2 = boot({ schema = 5 })
    local M = ns2.Personality
    M.Reset()
    eq(M.Mood(), "happy")
    local seen = {}
    for i = 1, 8 do M.OnEvent("hop"); seen[i] = M.Mood() end
    eq(seen[1], "happy"); eq(M.Mood(), "sleepy", "tired after many hops")
    eq(M.GetState().counters.tired >= 6, true)
    M.OnEvent("nap")
    truthy(M.Mood() ~= "sleepy", "a nap satisfies sleepiness at once (no dwell needed)")
    eq(M.GetState().counters.tired, 0)
    -- (8 hops also made it hungry, so it may now be hungry rather than happy.)
    M.OnEvent("carrot")
    eq(M.Mood(), "happy", "fed and rested: happy again")
    -- Hunger: idle behaviours and hops add hunger; a carrot clears it.
    M.Reset()
    for _ = 1, 14 do M.OnEvent("wash") end
    truthy(M.Mood() == "hungry" or M.Mood() == "playful", "needs grew: " .. M.Mood())
    M.Reset()
    for _ = 1, 9 do M.OnEvent("hop") ; M.OnEvent("look") end
    M.OnEvent("carrot")
    eq(M.GetState().counters.hungry, 0, "carrot clears hunger")
    -- Same events -> same moods (deterministic, no randomness).
    local function trace()
        M.Reset()
        local out = {}
        for i, e in ipairs({ "hop", "hop", "wash", "burrow", "hop", "look", "hop", "carrot", "hop", "hop", "nap", "stretch" }) do
            M.OnEvent(e); out[i] = M.Mood()
        end
        return table.concat(out, ",")
    end
    math.randomseed(1); local a = trace()
    math.randomseed(999); local b = trace()
    eq(a, b)
end)

test("moods don't oscillate rapidly", function()
    local ns2 = boot({ schema = 5, personality = "playful" })
    local M = ns2.Personality
    M.Reset()
    -- Alternate events that push opposite needs.
    local events = { "burrow", "wash", "look", "hop", "scratch", "burrow", "look", "wash" }
    for i = 1, 200 do M.OnEvent(events[i % #events + 1]) end
    truthy(M.GetState().changes <= 200 / ns2.Personality.MIN_DWELL,
        "changes " .. M.GetState().changes)
end)

test("personality influences how fast moods change", function()
    local function hopsToSleepy(id)
        local ns2 = boot({ schema = 5, personality = id })
        local M = ns2.Personality
        M.Reset()
        for i = 1, 30 do
            M.OnEvent("hop")
            if M.Mood() == "sleepy" then return i end
        end
        return 99
    end
    truthy(hopsToSleepy("sleepy") < hopsToSleepy("balanced"), "sleepy tires faster")
    truthy(hopsToSleepy("balanced") < hopsToSleepy("energetic"), "energetic tires slower")
end)

test("moods shift behaviour weights and chances", function()
    local ns2 = boot({ schema = 5 })
    local M, B = ns2.Personality, ns2.Bunny
    local function share(target)
        local n = 0
        for i = 1, 1000 do
            if B.PickBehavior(function() return (i - 0.5) / 1000 end) == target then n = n + 1 end
        end
        return n / 1000
    end
    M.SetMood("happy"); local happyCarrot = share("carrot")
    M.SetMood("hungry"); local hungryCarrot = share("carrot")
    truthy(hungryCarrot > happyCarrot * 2, ("carrot share hungry %.2f vs happy %.2f"):format(hungryCarrot, happyCarrot))
    eq(M.Params().behavior, 1.6)
    M.SetMood("sleepy"); eq(M.Params().nap, 2.0)
    M.SetMood("playful"); eq(M.Params().burrow, 1.8); truthy(M.Params().wait < 1)
    eq(M.Chance(0.6, 2.0), M.CHANCE_CAP, "chances are capped")
end)

test("no immediate repetition; Playful avoids the last two behaviours", function()
    for _, id in ipairs({ "balanced", "playful" }) do
        math.randomseed(17)
        local ns2 = boot({ schema = 5, personality = id, burrow = false, sleepChance = 0 })
        local history = {}
        local prev
        mock.advance(1800, 1 / 10, function()
            local s = ns2.Bunny:GetDebugState()
            if s.state == "behavior" and s.behavior ~= prev then history[#history + 1] = s.behavior end
            prev = s.state == "behavior" and s.behavior or nil
        end)
        truthy(#history >= 20, id .. " behaviours: " .. #history)
        for i = 2, #history do
            truthy(history[i] ~= history[i - 1], id .. ": repeated " .. history[i])
            if id == "playful" and i >= 3 then
                truthy(history[i] ~= history[i - 2], "playful repeated within two: " .. history[i])
            end
        end
    end
end)

test("mood system off: no mood, events ignored, /bunny mood reports it", function()
    local ns2 = boot({ schema = 5 })
    eq(slash("mood off"), true); eq(BunnyBarDB.moods, false)
    truthy(lastChat():find("mood system: off"), lastChat())
    local M = ns2.Personality
    eq(M.Mood(), nil)
    local before = M.GetState().counters.tired
    for _ = 1, 10 do M.OnEvent("hop") end
    eq(M.GetState().counters.tired, before, "events ignored")
    eq(M.Params().nap, 1)
    eq(slash("mood on"), true)
    eq(slash("mood"), true); truthy(lastChat():find("personality: Balanced | mood: Happy"), lastChat())
    eq(slash("mood sideways"), false)
end)

test("/bunny mood debug shows weights and the next decision, only when asked", function()
    local ns2 = boot({ schema = 5, personality = "lazy" })
    mock.advance(1.05)
    local before = #mock.chat
    mock.advance(120) -- no chat output from the mood system on its own
    eq(#mock.chat, before, "no continuous logging")
    advanceUntil(ns2, function(s) return s.state == "idle" end, 30)
    eq(slash("mood debug"), true)
    local text = table.concat(mock.chat, "\n", before + 1)
    truthy(text:find("personality: Lazy"), text)
    truthy(text:find("counters: tired"), text)
    truthy(text:find("chances: nap %d+%%"), text)
    truthy(text:find("behaviour weights: carrot %d+%%"), text)
    truthy(text:find("next decision in %d"), text)
end)

test("mood events fire only for completed activities", function()
    local ns2 = boot({ schema = 5 })
    mock.advance(1.05)
    local M = ns2.Personality
    M.Reset()
    -- Interrupted carrot: no event.
    slash("test carrot")
    advanceUntil(ns2, function(s) return s.pose == "carrotHold" end, 10)
    slash("hide")
    eq(M.GetState().lastEvent, nil, "hidden mid-carrot")
    slash("show")
    -- Completed carrot: event.
    slash("test carrot")
    advanceUntil(ns2, function(s) return s.state == "idle" end, 10)
    eq(M.GetState().lastEvent, "carrot")
    -- Completed burrow and hop journey.
    slash("test burrow")
    advanceUntil(ns2, function(s) return s.state == "idle" end, 15)
    eq(M.GetState().lastEvent, "burrow")
    slash("test")
    advanceUntil(ns2, function(s) return s.state == "idle" end, 15)
    eq(M.GetState().lastEvent, "hop")
    -- Interrupting a nap (test hop) doesn't count as a nap.
    slash("test nap")
    advanceUntil(ns2, function(s) return s.state == "sleep" end, 10)
    slash("test")
    eq(M.GetState().lastEvent, "hop")
end)

test("moods add no timers and no idle frame updates", function()
    local function run(moods)
        math.randomseed(55)
        local ns2 = boot({ schema = 5, moods = moods, personality = "playful" })
        local maxTimers, updates, idleUpdates = 0, 0, 0
        mock.advance(900, 1 / 20, function()
            local s = ns2.Bunny:GetDebugState()
            if s.onUpdate then updates = updates + 1; if s.state ~= "air" then idleUpdates = idleUpdates + 1 end end
            local t = mock.pendingTimers()
            if t > maxTimers then maxTimers = t end
        end)
        return maxTimers, idleUpdates
    end
    local tOn, idleOn = run(true)
    local tOff, idleOff = run(false)
    eq(idleOn, 0); eq(idleOff, 0)
    truthy(tOn <= tOff + 1 and tOn <= 7, ("pending timers with moods %d, without %d"):format(tOn, tOff))
end)

test("schema 4 saves migrate without touching appearance, ears, colour or position", function()
    local old = { schema = 4, variation = "dragon", furColor = "FFFFFF", size = 96, earsPlayer = false,
        earsParty = true, point = "BOTTOM", relativePoint = "BOTTOM", x = -40, y = 300, hearts = false }
    local ns2 = boot(old, { setup = function() mkParty(1) end })
    local db = BunnyBarDB
    eq(db.schema, 5); eq(db.personality, "balanced"); eq(db.moods, true)
    for k, v in pairs(old) do if k ~= "schema" then eq(db[k], v, k) end end
    eq(ns2.Ears.GetState().player.shown, false); eq(ns2.Ears.GetState().party1.shown, true)
    boot({ schema = 5, personality = "Grumpy", moods = "yes" })
    eq(BunnyBarDB.personality, "balanced"); eq(BunnyBarDB.moods, true)
end)

test("personality changes leave styles, colours, preview and portrait ears alone", function()
    local ns2, c = bootPanel({ schema = 5, variation = "angel", furColor = "87CEEB" },
        function() mkPlayer(100, 900, 60) end)
    slash("personality sleepy"); slash("mood off"); slash("personality playful")
    eq(BunnyBarDB.variation, "angel"); eq(ns2.Config.FurColor(), "87CEEB")
    truthy(bunnyLayers()._texture:find("angel"))
    truthy(c.previewLayers[1]._texture:find("angel"))
    local e = ns2.Ears.GetState().player
    eq(e.shown, true)
    eq(e.overlay._children[1]._texture, "Interface\\AddOns\\BunnyBar\\Textures\\bunny-ears.tga")
    eq(hexOf(e.overlay._children[1]:GetVertexColor()), "87CEEB")
end)

test("settings panel: personality dropdown and mood checkbox", function()
    local ns2, c = bootPanel({ schema = 5 })
    eq(c.personalityMode, "dropdown")
    local radios = c.personality:MockMenu()
    local labels = {}
    for i, r in ipairs(radios) do labels[i] = r.text end
    eq(table.concat(labels, ","), "Balanced,Lazy,Energetic,Playful,Sleepy")
    eq(radios[1].isSelected(radios[1].data), true)
    radios[3].setSelected(radios[3].data)
    eq(BunnyBarDB.personality, "energetic")
    radios = c.personality:MockMenu()
    eq(radios[3].isSelected(radios[3].data), true); eq(radios[1].isSelected(radios[1].data), false)
    eq(c.moods:GetChecked(), true)
    c.moods:Click(); eq(BunnyBarDB.moods, false)
    slash("personality lazy")
    eq(c.personality:MockMenu()[2].isSelected("lazy"), true, "slash -> panel")
    -- layout: inside the Behaviors section
    local L = ns2.Options.layout
    local _, _, _, px, py = c.personality:GetPoint(1)
    truthy(py <= L.behaviors.top and py - 22 >= L.behaviors.bottom - 2, "dropdown inside Behaviors")
    truthy(px + 120 <= 660)
    local _, _, _, mx, my = c.moods:GetPoint(1)
    truthy(my - 24 >= L.behaviors.bottom - 2 and mx + 90 <= 660, "mood checkbox inside")
end)

test("settings panel: dropdown fallback when the modern template is missing", function()
    mock.MISSING_TEMPLATES.WowStyle1DropdownTemplate = true
    local ns2, c = bootPanel({ schema = 5 })
    eq(c.personalityMode, "cycle")
    eq(c.personality:GetText(), "Balanced")
    c.personality:Click(); eq(BunnyBarDB.personality, "lazy"); eq(c.personality:GetText(), "Lazy")
    for _ = 1, 4 do c.personality:Click() end
    eq(BunnyBarDB.personality, "balanced", "cycles around")
    mock.MISSING_TEMPLATES = {}
end)

test("panel isn't refreshed while closed; it catches up when reopened", function()
    local ns2, c = bootPanel({ schema = 5 })
    local before = c.personality._generated or 0
    ns2.Options.panel:Hide()
    slash("personality sleepy"); slash("color #123456"); slash("size 96")
    eq(c.personality._generated or 0, before, "no refresh while closed")
    ns2.Options.panel:Show()
    truthy((c.personality._generated or 0) > before)
    eq(c.hex:GetText(), "#123456"); eq(c.sizes[4]:GetChecked(), true)
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
