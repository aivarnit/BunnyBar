-- BunnyBar: the bunny frame, sprite poses and the hop/idle/sleep state machine.
--
-- Performance model
--   * Waiting (idle, sleeping, between hops) and every sprite-sequence step
--     (getting sleepy, lying down, breathing, waking) is driven by C_Timer,
--     so nothing runs per frame while the bunny is on the ground.
--   * An OnUpdate script is attached only while the bunny is airborne
--     (~0.4 s per hop) and removed on landing.
--   * No tables or closures are created per frame; all callbacks are
--     file-level functions.
--   * Everything stops when the frame is hidden (OnHide), including when the
--     whole UI is hidden with Alt+Z.

local addonName, ns = ...
local Util = ns.Util

local Bunny = {}
ns.Bunny = Bunny

local C_Timer, GetTime = C_Timer, GetTime
local random, abs, max = math.random, math.abs, math.max

----------------------------------------------------------------------------
-- Sprites
----------------------------------------------------------------------------

-- Each sheet is a horizontal strip of 32x32 frames (two stacked layers, see
-- Appearance.lua). `slots` is the strip width in frames (a power of two;
-- unused slots are transparent padding). The folder comes from the current
-- appearance variation.
Bunny.SHEETS = {
    idle   = { file = "bunny-idle.tga",   count = 4, slots = 4 },
    hop    = { file = "bunny-hop.tga",    count = 2, slots = 2 },
    land   = { file = "bunny-land.tga",   count = 1, slots = 1 },
    sleepy = { file = "bunny-sleepy.tga", count = 7, slots = 8 },
    sleep  = { file = "bunny-sleep.tga",  count = 6, slots = 8 },
    wake   = { file = "bunny-wake.tga",   count = 4, slots = 4 },
}

-- Pose name -> { sheet, frame index }
Bunny.POSES = {
    idle    = { "idle", 1 },
    blink   = { "idle", 2 },
    twitch  = { "idle", 3 },
    breathe = { "idle", 4 },
    prep    = { "hop", 1 },
    jump    = { "hop", 2 },
    land    = { "land", 1 },
    -- getting sleepy: heavy eyelids, yawn, nodding off
    drowsy1 = { "sleepy", 1 },
    drowsy2 = { "sleepy", 2 },
    drowsy3 = { "sleepy", 3 },
    -- lying down (eased from nodding to curled up)
    liedown1 = { "sleepy", 4 },
    liedown2 = { "sleepy", 5 },
    liedown3 = { "sleepy", 6 },
    liedown4 = { "sleepy", 7 },
    -- asleep: rest, inhale (+1 px torso), hold, exhale; plus twitches
    sleep1 = { "sleep", 1 },
    sleep2 = { "sleep", 2 },
    sleep3 = { "sleep", 3 },
    sleep4 = { "sleep", 4 },
    sleepEar  = { "sleep", 5 },
    sleepNose = { "sleep", 6 },
    -- waking up: eyes open, rise, stretch, sit up
    wake1 = { "wake", 1 },
    wake2 = { "wake", 2 },
    wake3 = { "wake", 3 },
    wake4 = { "wake", 4 },
}

-- Multi-frame sequences: { pose, seconds } in playback order. These are not
-- scaled by the speed setting. scripts/generate_sprites.py mirrors these
-- timings for the animated preview; the tests keep the two in sync.
Bunny.SEQUENCES = {
    drowsy  = { { "drowsy1", 0.24 }, { "drowsy2", 0.28 }, { "drowsy3", 0.22 } },
    liedown = { { "liedown1", 0.15 }, { "liedown2", 0.15 }, { "liedown3", 0.16 }, { "liedown4", 0.18 } },
    breathe = { { "sleep1", 0.65 }, { "sleep2", 0.55 }, { "sleep3", 0.65 }, { "sleep4", 0.55 } },
    wake    = { { "wake1", 0.22 }, { "wake2", 0.20 }, { "wake3", 0.26 }, { "wake4", 0.20 } },
}
-- Getting up early (interrupted while lying down): the lie-down frames in
-- reverse, a little quicker.
Bunny.SEQUENCES.rise = {
    { "liedown4", 0.10 }, { "liedown3", 0.10 }, { "liedown2", 0.10 }, { "liedown1", 0.10 },
}

local SHEETS, POSES, SEQUENCES = Bunny.SHEETS, Bunny.POSES, Bunny.SEQUENCES

----------------------------------------------------------------------------
-- Timing (seconds at speed 1.0; hop duration itself comes from settings)
----------------------------------------------------------------------------

local PREP_TIME = 0.14      -- crouch before take-off
local LAND_TIME = 0.12      -- squash after landing
local BETWEEN_HOPS = 0.08   -- pause between hops of one journey
local SLEEP_MIN, SLEEP_MAX = 10, 25 -- time spent asleep (whole breaths)
local TWITCH_CHANCE = 0.3   -- per breath: chance of an ear or nose twitch
local TWITCH_TIME = 0.3
local FIDGET_MIN, FIDGET_MAX = 2.5, 6

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local frame, sprite, backdrop, label
local layers -- layered sprite textures (sprite == layers[1])
local db

-- stopped | idle | prep | air | land | between | drowsy | liedown | sleep | rise | waking
local state = "stopped"
local x, y = nil, 0     -- sprite offset inside the track (x = left edge)
local facing = 1        -- 1 = right, -1 = left
local destX = 0
local hopFromX, hopToX, hopElapsed, hopDur = 0, 0, 0, 0.4
local lastWasNap = false
local sleepUntil = 0
local resumeSleepFor        -- seconds of nap left when hidden mid-nap
local seq, seqIndex, seqDone -- sequence player

local actionTimer, poseTimer
local currentPose, currentFacing

local stats = { hops = 0, journeys = 0, naps = 0, airTime = 0, since = nil }

-- Forward declarations (mutually recursive state functions).
local enterIdle, decideNext, enterSleep, lieDown, startBreath, breathEnd, startJourney
local beginHop, launch, land, afterLand, idleFidget, idleRestore, onUpdate

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function bounds()
    return Util.TrackBounds(db.trackWidth, db.size)
end

local function maxStep()
    return max(8, db.size * 1.5)
end

local function speed()
    return db.speed
end

local function schedule(delay, fn)
    if actionTimer then actionTimer:Cancel() end
    actionTimer = C_Timer.NewTimer(delay, fn)
end

local function cancelTimers()
    if actionTimer then actionTimer:Cancel(); actionTimer = nil end
    if poseTimer then poseTimer:Cancel(); poseTimer = nil end
end

local function setPose(name)
    if currentPose == name and currentFacing == facing then return end
    local pose = POSES[name]
    local sheet = SHEETS[pose[1]]
    ns.Appearance.SetFrame(layers, ns.Appearance.SheetPath(sheet.file), pose[2], sheet.slots, facing < 0)
    currentPose, currentFacing = name, facing
end

local function place()
    sprite:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Util.Round(x), Util.Round(y))
end

----------------------------------------------------------------------------
-- State machine
----------------------------------------------------------------------------

function idleFidget()
    poseTimer = nil
    if state ~= "idle" then return end
    local r, pose, duration = random(), "blink", 0.14
    if r < 0.2 then
        pose, duration = "twitch", 0.3
    elseif r < 0.35 then
        pose, duration = "breathe", 0.6
    end
    setPose(pose)
    poseTimer = C_Timer.NewTimer(duration, idleRestore)
end

function idleRestore()
    poseTimer = nil
    if state ~= "idle" then return end
    setPose("idle")
    poseTimer = C_Timer.NewTimer(Util.RandomRange(FIDGET_MIN, FIDGET_MAX), idleFidget)
end

function enterIdle()
    state = "idle"
    y = 0
    place()
    setPose("idle")
    if poseTimer then poseTimer:Cancel() end
    poseTimer = C_Timer.NewTimer(Util.RandomRange(1.5, FIDGET_MAX), idleFidget)
    local interval = db.interval
    schedule(Util.RandomRange(interval * 0.5, interval * 1.5), decideNext)
end

function decideNext()
    actionTimer = nil
    if not lastWasNap and random() < db.sleepChance then
        lastWasNap = true
        enterSleep()
        return
    end
    lastWasNap = false
    local minX, maxX = bounds()
    startJourney(Util.ChooseDestination(x, minX, maxX, db.size, random))
end

-- Sequence player: shows each { pose, seconds } step on a C_Timer and calls
-- `done` after the last one. No per-frame work, no per-step closures.
local function seqStep()
    actionTimer = nil
    seqIndex = seqIndex + 1
    local step = seq[seqIndex]
    if not step then
        local done = seqDone
        seq, seqDone = nil, nil
        done()
        return
    end
    setPose(step[1])
    schedule(step[2], seqStep)
end

local function playSequence(sequence, newState, done, first)
    -- Cancel whatever was pending (e.g. the next breathing frame when woken
    -- early); seqStep() clears the handle without cancelling it.
    cancelTimers()
    state = newState
    seq, seqIndex, seqDone = sequence, (first or 1) - 1, done
    seqStep()
end

local function sleepDuration()
    return Util.RandomRange(SLEEP_MIN, SLEEP_MAX)
end

-- idle -> getting sleepy -> lying down -> breathing loop -> waking -> idle
function enterSleep()
    stats.naps = stats.naps + 1
    sleepUntil = GetTime() + sleepDuration()
    playSequence(SEQUENCES.drowsy, "drowsy", lieDown)
end

function lieDown()
    playSequence(SEQUENCES.liedown, "liedown", startBreath)
end

function startBreath()
    playSequence(SEQUENCES.breathe, "sleep", breathEnd)
end

-- Runs between breaths (resting pose, torso down): wake up, twitch, or keep
-- breathing. Waking only happens here, so it never starts mid-inhale.
function breathEnd()
    if GetTime() >= sleepUntil then
        playSequence(SEQUENCES.wake, "waking", enterIdle)
    elseif random() < TWITCH_CHANCE then
        setPose(random() < 0.5 and "sleepEar" or "sleepNose")
        schedule(TWITCH_TIME, startBreath)
    else
        startBreath()
    end
end

-- Get up from whatever stage of a nap we are in, then call `done`.
local function wakeThen(done)
    if state == "drowsy" then
        -- Still sitting up: drowsy frames are close enough to idle to cut.
        if actionTimer then actionTimer:Cancel(); actionTimer = nil end
        seq, seqDone = nil, nil
        done()
    elseif state == "liedown" then
        -- Reverse from the frame currently shown (k): next is k-1.
        local n = #SEQUENCES.rise
        playSequence(SEQUENCES.rise, "rise", done, n + 2 - seqIndex)
    elseif state == "sleep" then
        playSequence(SEQUENCES.wake, "waking", done)
    elseif state == "waking" or state == "rise" then
        seqDone = done -- already getting up; continue afterwards
    else
        done()
    end
end

function startJourney(target)
    destX = target
    if target ~= x then facing = (target > x) and 1 or -1 end
    stats.journeys = stats.journeys + 1
    beginHop()
end

function beginHop()
    if poseTimer then poseTimer:Cancel(); poseTimer = nil end
    state = "prep"
    setPose("prep")
    schedule(PREP_TIME / speed(), launch)
end

function launch()
    actionTimer = nil
    state = "air"
    hopFromX = x
    hopToX = Util.NextHopX(x, destX, maxStep())
    hopElapsed = 0
    hopDur = db.hopDuration / speed()
    stats.hops = stats.hops + 1
    setPose("jump")
    frame:SetScript("OnUpdate", onUpdate)
end

function onUpdate(_, elapsed)
    hopElapsed = hopElapsed + elapsed
    local t = hopElapsed / hopDur
    if t >= 1 then t = 1 end
    -- Constant horizontal speed + parabolic height = a natural ballistic arc.
    x = hopFromX + (hopToX - hopFromX) * t
    y = Util.HopArc(t, db.hopHeight)
    place()
    if t >= 1 then
        frame:SetScript("OnUpdate", nil)
        stats.airTime = stats.airTime + hopDur
        land()
    end
end

function land()
    state = "land"
    x, y = hopToX, 0
    place()
    setPose("land")
    schedule(LAND_TIME / speed(), afterLand)
end

function afterLand()
    actionTimer = nil
    if abs(destX - x) > 0.5 then
        state = "between"
        setPose("idle")
        schedule(BETWEEN_HOPS / speed(), beginHop)
    else
        enterIdle()
    end
end

----------------------------------------------------------------------------
-- Positioning
----------------------------------------------------------------------------

-- Automatic placement lives in Placement.lua; kept here for compatibility.
function Bunny.DetectDefaultOffset()
    return ns.Placement.Detect(ns.db.trackWidth)
end

local lastAutoX, lastAutoY

local function usable(v)
    if issecretvalue and issecretvalue(v) then return false end
    return type(v) == "number" and v == v
end

-- Position the track: the saved (dragged) position wins; otherwise sit just
-- above the highest visible bottom bar. Unchanged auto positions are not
-- re-applied, so frequent refresh requests cost almost nothing.
-- Returns `moved` and `unstable` (see Placement.Detect) for auto placement.
function Bunny:ApplyPosition()
    if not frame then return false, false end
    db = ns.db
    if db.point then
        lastAutoX, lastAutoY = nil, nil
        frame:ClearAllPoints()
        frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
        return false, false
    end
    local ox, oy, _, _, _, unstable = ns.Placement.Detect(db.trackWidth)
    if ox == lastAutoX and oy == lastAutoY and frame:GetNumPoints() > 0 then
        return false, unstable
    end
    lastAutoX, lastAutoY = ox, oy
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOM", UIParent, "BOTTOM", ox, oy)
    return true, unstable
end

function Bunny:IsAutoPositioned()
    return ns.db.point == nil
end

-- Store the dragged position relative to the bottom-centre of the screen, so
-- it survives resolution and UI-scale changes sensibly.
local function savePosition()
    local left, bottom, width = frame:GetLeft(), frame:GetBottom(), frame:GetWidth()
    if not (left and bottom and width) then return end
    db.point, db.relativePoint = "BOTTOM", "BOTTOM"
    db.x = Util.Round(left + width / 2 - UIParent:GetWidth() / 2)
    db.y = Util.Round(bottom)
    lastAutoX, lastAutoY = nil, nil
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

local function onDragStart(self)
    if not db.locked then self:StartMoving() end
end

local function onDragStop(self)
    self:StopMovingOrSizing()
    if self.SetUserPlaced then self:SetUserPlaced(false) end -- we persist it ourselves
    savePosition()
end

local function onShow()
    -- Bars may have changed while we were hidden (e.g. Alt+Z, level-up).
    if Bunny:IsAutoPositioned() then Bunny:ApplyPosition() end
    Bunny:Start()
end
local function onHide() Bunny:Stop() end

function Bunny:Create()
    if frame then return frame end
    db = ns.db

    frame = CreateFrame("Frame", "BunnyBarFrame", UIParent)
    frame:Hide()
    frame:SetFrameStrata("LOW") -- below action buttons (MEDIUM) if they ever overlap
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(false)    -- click-through while locked
    frame:RegisterForDrag("LeftButton")

    backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints(frame)
    backdrop:SetColorTexture(0.45, 0.65, 1.0, 0.25)
    backdrop:Hide()

    label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOM", frame, "TOP", 0, 2)
    label:SetText("BunnyBar: drag to move, then type /bunny lock")
    label:Hide()

    layers = ns.Appearance.CreateLayers(frame, "ARTWORK")
    sprite = layers[1]

    frame:SetScript("OnShow", onShow)
    frame:SetScript("OnHide", onHide)
    frame:SetScript("OnDragStart", onDragStart)
    frame:SetScript("OnDragStop", onDragStop)

    self:ApplySettings()
    return frame
end

-- Re-apply size/track settings. Restarts the behaviour loop if it was running.
function Bunny:ApplySettings(recenter)
    if not frame then return end
    db = ns.db
    local wasRunning = state ~= "stopped"
    self:Stop()
    frame:SetSize(db.trackWidth, db.size + db.hopHeight)
    sprite:SetSize(db.size, db.size)
    local minX, maxX = bounds()
    if x == nil or recenter then x = (minX + maxX) / 2 end
    x = Util.Clamp(x, minX, maxX)
    destX = x
    place()
    setPose(resumeSleepFor and "sleep1" or "idle")
    if self:IsAutoPositioned() then self:ApplyPosition() end
    if wasRunning or frame:IsVisible() then self:Start() end
end

function Bunny:Start()
    if not frame or state ~= "stopped" or not frame:IsVisible() then return end
    db = ns.db
    stats.since = stats.since or GetTime()
    local minX, maxX = bounds()
    x = Util.Clamp(x or (minX + maxX) / 2, minX, maxX)
    if resumeSleepFor then
        -- Hidden mid-nap: carry on sleeping for the time that was left.
        sleepUntil = GetTime() + resumeSleepFor
        resumeSleepFor = nil
        y = 0
        place()
        startBreath()
    else
        enterIdle()
    end
end

local NAPPING = { drowsy = true, liedown = true, sleep = true }

-- Pause everything. Leaves a consistent resting state: on the ground, no
-- timers, no OnUpdate, either upright or (when hidden mid-nap) asleep.
function Bunny:Stop()
    if state == "stopped" then return end
    cancelTimers()
    if frame then frame:SetScript("OnUpdate", nil) end
    if state == "air" then x = hopToX end -- finish the hop (invisible: we're hidden)
    if NAPPING[state] then
        resumeSleepFor = max(sleepUntil - GetTime(), 1)
    else
        resumeSleepFor = nil
    end
    seq, seqDone = nil, nil
    y = 0
    state = "stopped"
    if frame and x then
        place()
        setPose(resumeSleepFor and "sleep1" or "idle")
    end
end

-- Re-show the current pose (e.g. after the appearance variation changed).
function Bunny:RefreshAppearance()
    if not frame or not currentPose then return end
    local pose = currentPose
    currentPose = nil
    setPose(pose)
end

function Bunny:SetShown(shown)
    if frame then frame:SetShown(shown and true or false) end
end

function Bunny:SetLocked(locked)
    if not frame then return end
    if locked then frame:StopMovingOrSizing() end
    frame:EnableMouse(not locked)
    backdrop:SetShown(not locked)
    label:SetShown(not locked)
end

local function testJourney()
    lastWasNap = false
    local minX, maxX = bounds()
    startJourney(Util.ChooseDestination(x, minX, maxX, db.size, random))
end

-- Start a hop journey right now (used by /bunny test). A napping bunny wakes
-- up properly first (waking or rising sequence), then hops.
function Bunny:TestHop()
    if not frame or not frame:IsVisible() then return false end
    if state == "prep" or state == "air" or state == "land" or state == "between" then
        return true -- already hopping
    end
    if state == "stopped" then self:Start() end
    if state == "idle" then
        cancelTimers()
        testJourney()
    else
        wakeThen(testJourney)
    end
    return true
end

-- Snapshot used by /bunny stats and the test-suite.
function Bunny:GetDebugState()
    return {
        state = state, x = x, y = y, facing = facing, destX = destX,
        pose = currentPose, sleepUntil = sleepUntil, resumeSleepFor = resumeSleepFor,
        onUpdate = frame and frame:GetScript("OnUpdate") ~= nil or false,
        hops = stats.hops, journeys = stats.journeys, naps = stats.naps,
        airTime = stats.airTime, since = stats.since,
    }
end

local function getMemoryKB()
    local update = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
    local get = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
    if not (update and get) then return nil end
    local ok, kb = pcall(function() update(); return get(addonName) end)
    if ok and usable(kb) then return kb end
    return nil
end

local function getRecentCpuMs()
    local profiler = C_AddOnProfiler
    local metric = Enum and Enum.AddOnProfilerMetric and Enum.AddOnProfilerMetric.RecentAverageTime
    if not (profiler and profiler.GetAddOnMetric and metric) then return nil end
    local ok, ms = pcall(profiler.GetAddOnMetric, addonName, metric)
    if ok and usable(ms) then return ms end
    return nil
end

function Bunny:GetStats()
    local s = self:GetDebugState()
    local lines = {}
    lines[#lines + 1] = ("state: %s | shown: %s | locked: %s | position: %s"):format(
        s.state, tostring(ns.db.shown), tostring(ns.db.locked),
        self:IsAutoPositioned() and "auto (above action bar)" or "custom")
    lines[#lines + 1] = ("hops: %d in %d journeys | naps: %d"):format(s.hops, s.journeys, s.naps)
    if s.since then
        local session = max(GetTime() - s.since, 0.001)
        lines[#lines + 1] = ("per-frame updates active %.2f%% of the time (only while airborne)"):format(
            100 * s.airTime / session)
    end
    local kb = getMemoryKB()
    lines[#lines + 1] = kb and ("memory: %.1f KB"):format(kb) or "memory: not available on this client"
    local ms = getRecentCpuMs()
    lines[#lines + 1] = ms and ("CPU (recent average): %.4f ms per frame"):format(ms)
        or "CPU: per-addon profiler not available on this client"
    return lines
end
