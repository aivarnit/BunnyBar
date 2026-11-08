-- BunnyBar: the bunny frame, sprite poses and the behaviour state machine.
--
-- One PRIMARY behaviour runs at a time (idle, hop, nap, an idle behaviour such
-- as eating a carrot, or burrowing). Secondary effects (hover hearts,
-- Hearts.lua) run independently and never change this state.
--
-- Performance model
--   * Waiting and every sprite-sequence step are driven by C_Timer, so
--     nothing runs per frame while the bunny is on the ground.
--   * An OnUpdate script is attached only while the bunny is airborne
--     (~0.4 s per hop) and removed on landing.
--   * Sequences are data; callbacks are file-level functions (no per-frame
--     tables or closures).
--   * Everything stops when the frame is hidden (OnHide), including Alt+Z;
--     temporary textures (burrow holes) are cleaned up.

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
-- style (appearance variation); every style has the same sheets.
Bunny.SHEETS = {
    idle   = { file = "bunny-idle.tga",   count = 4,  slots = 4 },
    hop    = { file = "bunny-hop.tga",    count = 8,  slots = 8 },
    sleepy = { file = "bunny-sleepy.tga", count = 7,  slots = 8 },
    sleep  = { file = "bunny-sleep.tga",  count = 6,  slots = 8 },
    wake   = { file = "bunny-wake.tga",   count = 4,  slots = 4 },
    carrot = { file = "bunny-carrot.tga", count = 13, slots = 16 },
    groom  = { file = "bunny-groom.tga",  count = 11, slots = 16 },
    moves  = { file = "bunny-moves.tga",  count = 7,  slots = 8 },
    burrow = { file = "bunny-burrow.tga", count = 13, slots = 16 },
}

-- Burrow hole effect: (back, front) layers, shared by all styles, untinted.
Bunny.FX_SHEET = { file = "bunny-burrow-fx.tga", count = 5, slots = 8, fx = true }

-- Pose name -> { sheet, frame index }. Mirrored by POSES in
-- scripts/generate_sprites.py (the tests check they are identical).
Bunny.POSES = {
    idle = { "idle", 1 }, blink = { "idle", 2 }, twitch = { "idle", 3 }, breathe = { "idle", 4 },
    -- hop: anticipation, push-off, rising, apex, falling, contact, squash, recovery
    prep = { "hop", 1 }, push = { "hop", 2 }, jump = { "hop", 3 }, apex = { "hop", 4 },
    fall = { "hop", 5 }, contact = { "hop", 6 }, land = { "hop", 7 }, recover = { "hop", 8 },
    -- getting sleepy, lying down
    drowsy1 = { "sleepy", 1 }, drowsy2 = { "sleepy", 2 }, drowsy3 = { "sleepy", 3 },
    liedown1 = { "sleepy", 4 }, liedown2 = { "sleepy", 5 }, liedown3 = { "sleepy", 6 }, liedown4 = { "sleepy", 7 },
    -- asleep: rest, inhale (+1 px torso), hold, exhale; plus twitches
    sleep1 = { "sleep", 1 }, sleep2 = { "sleep", 2 }, sleep3 = { "sleep", 3 }, sleep4 = { "sleep", 4 },
    sleepEar = { "sleep", 5 }, sleepNose = { "sleep", 6 },
    -- waking up
    wake1 = { "wake", 1 }, wake2 = { "wake", 2 }, wake3 = { "wake", 3 }, wake4 = { "wake", 4 },
    -- carrot
    carrotNotice = { "carrot", 1 }, carrotSniffA = { "carrot", 2 }, carrotSniffB = { "carrot", 3 },
    carrotPull = { "carrot", 4 }, carrotPop = { "carrot", 5 }, carrotHold = { "carrot", 6 },
    carrotBite1 = { "carrot", 7 }, carrotChew1 = { "carrot", 8 }, carrotBite2 = { "carrot", 9 },
    carrotChew2 = { "carrot", 10 }, carrotBite3 = { "carrot", 11 }, carrotChew3 = { "carrot", 12 },
    carrotDone = { "carrot", 13 },
    -- face washing, ear scratching
    washUp = { "groom", 1 }, washRubA = { "groom", 2 }, washRubB = { "groom", 3 },
    washWiggleA = { "groom", 4 }, washWiggleB = { "groom", 5 }, washDown = { "groom", 6 },
    scratchSit = { "groom", 7 }, scratchFootUp = { "groom", 8 }, scratchA = { "groom", 9 },
    scratchB = { "groom", 10 }, scratchFootDown = { "groom", 11 },
    -- stretching, looking around
    stretchReach = { "moves", 1 }, stretchDeep = { "moves", 2 }, stretchHold = { "moves", 3 },
    stretchBack = { "moves", 4 }, lookFront = { "moves", 5 }, lookBack = { "moves", 6 }, lookUp = { "moves", 7 },
    -- burrowing
    burrowSniffA = { "burrow", 1 }, burrowSniffB = { "burrow", 2 },
    burrowDigA = { "burrow", 3 }, burrowDigB = { "burrow", 4 },
    burrowSink1 = { "burrow", 5 }, burrowSink2 = { "burrow", 6 },
    burrowSink3 = { "burrow", 7 }, burrowSink4 = { "burrow", 8 },
    burrowEmerge1 = { "burrow", 9 }, burrowEmerge2 = { "burrow", 10 },
    burrowPop = { "burrow", 11 }, burrowShakeA = { "burrow", 12 }, burrowShakeB = { "burrow", 13 },
}

-- Multi-frame sequences: { pose, seconds } in playback order. Not scaled by
-- the speed setting. Mirrored by SEQUENCES in scripts/generate_sprites.py,
-- which renders the animated previews from them.
Bunny.SEQUENCES = {
    drowsy  = { { "drowsy1", 0.24 }, { "drowsy2", 0.28 }, { "drowsy3", 0.22 } },
    liedown = { { "liedown1", 0.15 }, { "liedown2", 0.15 }, { "liedown3", 0.16 }, { "liedown4", 0.18 } },
    breathe = { { "sleep1", 0.65 }, { "sleep2", 0.55 }, { "sleep3", 0.65 }, { "sleep4", 0.55 } },
    wake    = { { "wake1", 0.22 }, { "wake2", 0.20 }, { "wake3", 0.26 }, { "wake4", 0.20 } },
    -- Getting up early (interrupted while lying down): lie-down in reverse.
    rise    = { { "liedown4", 0.10 }, { "liedown3", 0.10 }, { "liedown2", 0.10 }, { "liedown1", 0.10 } },
    carrot  = {
        { "carrotNotice", 0.30 }, { "carrotSniffA", 0.20 }, { "carrotSniffB", 0.20 },
        { "carrotSniffA", 0.20 }, { "carrotSniffB", 0.20 }, { "carrotPull", 0.35 },
        { "carrotPop", 0.30 }, { "carrotHold", 0.35 }, { "carrotBite1", 0.18 },
        { "carrotChew1", 0.30 }, { "carrotBite2", 0.18 }, { "carrotChew2", 0.30 },
        { "carrotBite3", 0.18 }, { "carrotChew3", 0.35 }, { "carrotDone", 0.45 },
    },
    wash    = {
        { "washUp", 0.25 }, { "washRubA", 0.15 }, { "washRubB", 0.15 }, { "washRubA", 0.15 },
        { "washRubB", 0.15 }, { "washRubA", 0.15 }, { "washWiggleA", 0.14 }, { "washWiggleB", 0.14 },
        { "washWiggleA", 0.14 }, { "washWiggleB", 0.14 }, { "washDown", 0.20 },
    },
    scratch = {
        { "scratchSit", 0.25 }, { "scratchFootUp", 0.15 },
        { "scratchA", 0.08 }, { "scratchB", 0.08 }, { "scratchA", 0.08 }, { "scratchB", 0.08 },
        { "scratchA", 0.08 }, { "scratchB", 0.08 }, { "scratchA", 0.08 }, { "scratchB", 0.08 },
        { "scratchA", 0.08 }, { "scratchB", 0.08 },
        { "scratchFootDown", 0.15 }, { "scratchSit", 0.15 },
    },
    stretch = {
        { "stretchReach", 0.25 }, { "stretchDeep", 0.30 }, { "stretchHold", 0.50 },
        { "stretchReach", 0.25 }, { "stretchBack", 0.20 },
    },
    look    = { { "lookFront", 0.20 }, { "lookBack", 0.70 }, { "lookFront", 0.20 }, { "lookUp", 0.50 } },
    burrowSniff  = { { "burrowSniffA", 0.30 }, { "burrowSniffB", 0.30 }, { "burrowSniffA", 0.25 }, { "burrowSniffB", 0.30 } },
    burrowDig    = {
        { "burrowDigA", 0.15 }, { "burrowDigB", 0.15 }, { "burrowDigA", 0.15 }, { "burrowDigB", 0.15 },
        { "burrowDigA", 0.15 }, { "burrowDigB", 0.15 }, { "burrowDigA", 0.15 }, { "burrowDigB", 0.15 },
    },
    burrowSink   = { { "burrowSink1", 0.12 }, { "burrowSink2", 0.12 }, { "burrowSink3", 0.12 }, { "burrowSink4", 0.12 } },
    burrowEmerge = { { "burrowEmerge1", 0.20 }, { "burrowEmerge2", 0.20 }, { "burrowPop", 0.20 } },
    burrowShake  = {
        { "burrowShakeA", 0.12 }, { "burrowShakeB", 0.12 }, { "burrowShakeA", 0.12 },
        { "burrowShakeB", 0.12 }, { "idle", 0.20 },
    },
}

-- Hole effect changes at sequence steps: [sequence][step] = { holes, fx frame
-- or false to hide }. Mirrored by BURROW_FX in generate_sprites.py.
Bunny.BURROW_FX = {
    burrowDig    = { [1] = { "A", 1 }, [4] = { "A", 2 }, [7] = { "A", 3 } },
    burrowEmerge = { [1] = { "B", 3 } },
    burrowShake  = { [3] = { "AB", 4 }, [4] = { "AB", 5 }, [5] = { "AB", false } },
}

-- Hop ground phases (seconds at speed 1.0) and the air pose by hop progress.
-- Mirrored by HOP_TIMING / AIR_POSES in generate_sprites.py.
Bunny.HOP_TIMING = { prep = 0.09, push = 0.05, contact = 0.04, land = 0.07, recover = 0.06 }
Bunny.AIR_POSES = { { 0.38, "jump" }, { 0.64, "apex" }, { 1.01, "fall" } }

-- Idle behaviours: sequence + the setting that enables it (all need idleExtras).
Bunny.BEHAVIORS = {
    carrot  = { sequence = "carrot",  weight = 2.0, setting = "carrot" },
    wash    = { sequence = "wash",    weight = 2.0 },
    scratch = { sequence = "scratch", weight = 2.0 },
    stretch = { sequence = "stretch", weight = 1.5 },
    look    = { sequence = "look",    weight = 2.0 },
}
Bunny.BEHAVIOR_ORDER = { "carrot", "wash", "scratch", "stretch", "look" }

local SHEETS, POSES, SEQUENCES = Bunny.SHEETS, Bunny.POSES, Bunny.SEQUENCES
local HOP, AIR_POSES, BURROW_FX = Bunny.HOP_TIMING, Bunny.AIR_POSES, Bunny.BURROW_FX

----------------------------------------------------------------------------
-- Timing
----------------------------------------------------------------------------

local SLEEP_MIN, SLEEP_MAX = 10, 25 -- time spent asleep (whole breaths)
local TWITCH_CHANCE = 0.3   -- per breath: chance of an ear or nose twitch
local TWITCH_TIME = 0.3
local FIDGET_MIN, FIDGET_MAX = 2.5, 6
Bunny.BEHAVIOR_CHANCE = 0.35 -- per decision: an idle behaviour instead of a hop
Bunny.BURROW_CHANCE = 0.35   -- per decision, once the cooldown has passed
-- Minimum seconds between burrows by frequency setting (and after login).
Bunny.BURROW_COOLDOWN = { rare = 420, normal = 240, often = 120 }
Bunny.BURROW_UNDERGROUND = 0.6 -- mirrored by BURROW_UNDERGROUND in the generator
Bunny.BURROW_HOLE_OPEN = 0.25  -- mirrored by BURROW_HOLE_OPEN

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local frame, sprite, backdrop, label
local layers -- layered sprite textures (sprite == layers[1])
local holes  -- burrow hole effect textures: holes.A / holes.B = { back, front }
local db

-- stopped | idle | prep | push | air | contact | land | recover |
-- drowsy | liedown | sleep | rise | waking | behavior | burrow
local state = "stopped"
local x, y = nil, 0     -- sprite offset inside the track (x = left edge)
local facing = 1        -- 1 = right, -1 = left
local destX = 0
local hopFromX, hopToX, hopElapsed, hopDur = 0, 0, 0, 0.4
local lastWasNap = false
local lastBehavior
local currentBehavior
local sleepUntil = 0
local resumeSleepFor        -- seconds of nap left when hidden mid-nap
local seq, seqIndex, seqDone, seqFx -- sequence player
local burrow = { active = false, fromX = 0, toX = 0, underground = false, lastAt = nil }
local spriteHidden = false

local actionTimer, poseTimer
local currentPose, currentFacing

local stats = { hops = 0, journeys = 0, naps = 0, airTime = 0, since = nil, behaviors = {}, burrows = 0 }

-- Forward declarations (mutually recursive state functions).
local enterIdle, decideNext, enterSleep, lieDown, startBreath, breathEnd, startJourney
local beginHop, pushOff, launch, touchDown, squash, afterLand, idleFidget, idleRestore, onUpdate
local burrowDig, burrowSink, burrowUnder, burrowOpen, burrowEmerge, burrowShake, burrowDone

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

local function setSpriteShown(shown)
    spriteHidden = not shown
    for i = 1, #layers do layers[i]:SetShown(shown) end
end

----------------------------------------------------------------------------
-- Burrow hole effects (BunnyBar's own textures; never game terrain)
----------------------------------------------------------------------------

local function createHole()
    -- Back layer under the bunny (BORDER), front rim over it (OVERLAY).
    local back = frame:CreateTexture(nil, "BORDER")
    local front = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    for _, tex in ipairs({ back, front }) do
        tex:SetTexture(ns.Appearance.TEXTURE_PATH .. Bunny.FX_SHEET.file, "CLAMP", "CLAMP", "NEAREST")
        tex:Hide()
    end
    return { back = back, front = front }
end

local function setHole(key, fxFrame, holeX)
    local h = holes[key]
    if not fxFrame then
        h.back:Hide()
        h.front:Hide()
        h.frame = nil
        return
    end
    local slots = Bunny.FX_SHEET.slots
    local l, r = (fxFrame - 1) / slots, fxFrame / slots
    h.back:SetTexCoord(l, r, 0, 0.5)
    h.front:SetTexCoord(l, r, 0.5, 1)
    if holeX then h.x = holeX end
    for _, tex in ipairs({ h.back, h.front }) do
        tex:SetSize(db.size, db.size)
        tex:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Util.Round(h.x or 0), 0)
        tex:Show()
    end
    h.frame = fxFrame
end

local function applyFx(fx)
    local which, fxFrame = fx[1], fx[2]
    for i = 1, #which do
        local key = which:sub(i, i)
        setHole(key, fxFrame or nil, key == "A" and burrow.fromX or burrow.toX)
    end
end

-- Remove every temporary burrow texture and make the bunny visible again.
local function burrowCleanup()
    if holes then
        setHole("A", nil)
        setHole("B", nil)
    end
    if spriteHidden then setSpriteShown(true) end
    burrow.active, burrow.underground = false, false
end

----------------------------------------------------------------------------
-- Sequence player
----------------------------------------------------------------------------

-- Shows each { pose, seconds } step on a C_Timer and calls `done` after the
-- last one; optional per-step hole effects. No per-frame work.
local function seqStep()
    actionTimer = nil
    seqIndex = seqIndex + 1
    local step = seq[seqIndex]
    if not step then
        local done = seqDone
        seq, seqDone, seqFx = nil, nil, nil
        done()
        return
    end
    setPose(step[1])
    local fx = seqFx and seqFx[seqIndex]
    if fx then applyFx(fx) end
    schedule(step[2], seqStep)
end

local function playSequence(sequence, newState, done, first, fx)
    -- Cancel whatever was pending (e.g. the next breathing frame when woken
    -- early); seqStep() clears the handle without cancelling it.
    cancelTimers()
    state = newState
    seq, seqIndex, seqDone, seqFx = sequence, (first or 1) - 1, done, fx
    seqStep()
end

----------------------------------------------------------------------------
-- Idle and decisions
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
    currentBehavior = nil
    state = "idle"
    y = 0
    place()
    setPose("idle")
    if poseTimer then poseTimer:Cancel() end
    poseTimer = C_Timer.NewTimer(Util.RandomRange(1.5, FIDGET_MAX), idleFidget)
    local interval = db.interval
    schedule(Util.RandomRange(interval * 0.5, interval * 1.5), decideNext)
end

-- `forced` (/bunny test burrow) ignores the on/off setting and the cooldown;
-- the track must always be wide enough.
local function canBurrow(forced)
    local minX, maxX = bounds()
    if maxX - minX < db.size * 1.5 then return false end -- track too short
    if forced then return true end
    if not db.burrow then return false end
    local cooldown = Bunny.BURROW_COOLDOWN[db.burrowFrequency] or Bunny.BURROW_COOLDOWN.normal
    return GetTime() - (burrow.lastAt or stats.since or GetTime()) >= cooldown
end

-- Weighted pick among enabled behaviours, never the same one twice in a row.
function Bunny.PickBehavior(rand, exclude)
    rand = rand or random
    if not db.idleExtras then return nil end
    local total = 0
    for _, name in ipairs(Bunny.BEHAVIOR_ORDER) do
        local b = Bunny.BEHAVIORS[name]
        if name ~= exclude and (not b.setting or db[b.setting]) then total = total + b.weight end
    end
    if total <= 0 then return nil end
    local r = rand() * total
    for _, name in ipairs(Bunny.BEHAVIOR_ORDER) do
        local b = Bunny.BEHAVIORS[name]
        if name ~= exclude and (not b.setting or db[b.setting]) then
            r = r - b.weight
            if r <= 0 then return name end
        end
    end
    return nil
end

local function playBehavior(name)
    local b = Bunny.BEHAVIORS[name]
    if poseTimer then poseTimer:Cancel(); poseTimer = nil end
    currentBehavior, lastBehavior = name, name
    stats.behaviors[name] = (stats.behaviors[name] or 0) + 1
    playSequence(SEQUENCES[b.sequence], "behavior", enterIdle)
end

local startBurrow -- forward

function decideNext()
    actionTimer = nil
    if not lastWasNap and random() < db.sleepChance then
        lastWasNap = true
        enterSleep()
        return
    end
    lastWasNap = false
    if canBurrow(false) and random() < Bunny.BURROW_CHANCE then
        startBurrow()
        return
    end
    if db.idleExtras and random() < Bunny.BEHAVIOR_CHANCE then
        local name = Bunny.PickBehavior(random, lastBehavior)
        if name then
            playBehavior(name)
            return
        end
    end
    local minX, maxX = bounds()
    startJourney(Util.ChooseDestination(x, minX, maxX, db.size, random))
end

----------------------------------------------------------------------------
-- Naps
----------------------------------------------------------------------------

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

-- Get out of whatever we're doing (napping, an idle behaviour, a burrow)
-- in a natural way, then call `done`.
local function wakeThen(done)
    if state == "drowsy" or state == "behavior" then
        -- Upright poses: close enough to idle to cut straight to `done`.
        if actionTimer then actionTimer:Cancel(); actionTimer = nil end
        seq, seqDone, seqFx = nil, nil, nil
        currentBehavior = nil
        done()
    elseif state == "burrow" then
        cancelTimers()
        seq, seqDone, seqFx = nil, nil, nil
        burrowCleanup()
        y = 0
        place()
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

----------------------------------------------------------------------------
-- Hopping: anticipation, push-off, air (rising/apex/falling), contact,
-- squash, recovery. Ground phases are timers; the air uses OnUpdate.
----------------------------------------------------------------------------

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
    schedule(HOP.prep / speed(), pushOff)
end

function pushOff()
    actionTimer = nil
    state = "push"
    setPose("push")
    schedule(HOP.push / speed(), launch)
end

function launch()
    actionTimer = nil
    state = "air"
    hopFromX = x
    hopToX = Util.NextHopX(x, destX, maxStep())
    hopElapsed = 0
    hopDur = db.hopDuration / speed()
    stats.hops = stats.hops + 1
    setPose(AIR_POSES[1][2])
    frame:SetScript("OnUpdate", onUpdate)
end

-- Air pose by hop progress (setPose is a no-op unless the pose changes, so
-- this costs three texture swaps per hop).
function Bunny.AirPose(t)
    for i = 1, #AIR_POSES do
        if t < AIR_POSES[i][1] then return AIR_POSES[i][2] end
    end
    return AIR_POSES[#AIR_POSES][2]
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
        touchDown()
    else
        setPose(Bunny.AirPose(t))
    end
end

function touchDown()
    state = "contact"
    x, y = hopToX, 0
    place()
    setPose("contact")
    schedule(HOP.contact / speed(), squash)
end

function squash()
    actionTimer = nil
    state = "land"
    setPose("land")
    schedule(HOP.land / speed(), afterLand)
end

function afterLand()
    actionTimer = nil
    if abs(destX - x) > 0.5 then
        beginHop() -- next hop of the journey: straight into anticipation
    else
        state = "recover"
        setPose("recover")
        schedule(HOP.recover / speed(), enterIdle)
    end
end

----------------------------------------------------------------------------
-- Burrowing: sniff, dig a hole, sink into it, travel underground, a second
-- hole opens on the far side, ears first, pop out, shake off, holes close.
----------------------------------------------------------------------------

-- Destination on the opposite side of the track (always within bounds).
function Bunny.BurrowDestination(fromX, minX, maxX, rand)
    rand = rand or random
    local span = maxX - minX
    local margin = span * 0.25 * rand()
    if fromX - minX > maxX - fromX then
        return Util.Clamp(minX + margin, minX, maxX)
    end
    return Util.Clamp(maxX - margin, minX, maxX)
end

function startBurrow(target)
    if poseTimer then poseTimer:Cancel(); poseTimer = nil end
    local minX, maxX = bounds()
    if not holes then holes = { A = createHole(), B = createHole() } end
    burrow.active, burrow.underground = true, false
    burrow.fromX = x
    burrow.toX = Util.Clamp(target or Bunny.BurrowDestination(x, minX, maxX, random), minX, maxX)
    burrow.lastAt = GetTime()
    if burrow.toX ~= x then facing = (burrow.toX > x) and 1 or -1 end
    stats.burrows = stats.burrows + 1
    playSequence(SEQUENCES.burrowSniff, "burrow", burrowDig)
end

function burrowDig()
    playSequence(SEQUENCES.burrowDig, "burrow", burrowSink, nil, BURROW_FX.burrowDig)
end

function burrowSink()
    playSequence(SEQUENCES.burrowSink, "burrow", burrowUnder, nil, BURROW_FX.burrowSink)
end

function burrowUnder()
    -- Fully underground: the bunny is invisible, so it may move instantly.
    setSpriteShown(false)
    burrow.underground = true
    x = burrow.toX
    destX = x
    place()
    schedule(Bunny.BURROW_UNDERGROUND, burrowOpen)
end

function burrowOpen()
    actionTimer = nil
    setHole("B", 1, burrow.toX)
    schedule(Bunny.BURROW_HOLE_OPEN, burrowEmerge)
end

function burrowEmerge()
    actionTimer = nil
    burrow.underground = false
    setSpriteShown(true)
    playSequence(SEQUENCES.burrowEmerge, "burrow", burrowShake, nil, BURROW_FX.burrowEmerge)
end

function burrowShake()
    playSequence(SEQUENCES.burrowShake, "burrow", burrowDone, nil, BURROW_FX.burrowShake)
end

function burrowDone()
    burrowCleanup()
    enterIdle()
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
    if ns.Hearts then ns.Hearts.OnBunnyShown() end
end
local function onHide()
    Bunny:Stop()
    if ns.Hearts then ns.Hearts.OnBunnyHidden() end
end

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

function Bunny:GetFrame()
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
-- timers, no OnUpdate, no burrow holes, bunny visible, either upright or
-- (when hidden mid-nap) asleep.
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
    seq, seqDone, seqFx = nil, nil, nil
    currentBehavior = nil
    burrowCleanup() -- x stays where the bunny currently is (start or end hole)
    y = 0
    state = "stopped"
    if frame and x then
        place()
        setPose(resumeSleepFor and "sleep1" or "idle")
    end
end

-- Re-show the current pose (e.g. after the style changed). Doesn't restart
-- or reset the current behaviour.
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

local HOPPING = { prep = true, push = true, air = true, contact = true, land = true, recover = true, between = true }

local function testJourney()
    lastWasNap = false
    local minX, maxX = bounds()
    startJourney(Util.ChooseDestination(x, minX, maxX, db.size, random))
end

local pendingAction
local function runPending()
    local action = pendingAction
    pendingAction = nil
    if action == "hop" then
        testJourney()
    elseif action == "burrow" then
        startBurrow()
    elseif action == "nap" then
        lastWasNap = true
        enterSleep()
    elseif Bunny.BEHAVIORS[action] then
        playBehavior(action)
    end
end

-- Perform an action now (used by /bunny test ...). Napping, idle behaviours
-- and burrows end naturally first (waking / rising sequences). Returns
-- false and a reason if it can't run right now.
--   action: "hop" | "carrot" | "wash" | "scratch" | "stretch" | "look" | "burrow" | "nap"
function Bunny:Perform(action)
    if not frame or not frame:IsVisible() then return false, "hidden" end
    if HOPPING[state] then
        if action == "hop" then return true end -- already hopping
        return false, "busy"
    end
    if action == "burrow" and not canBurrow(true) then return false, "track" end
    if state == "stopped" then self:Start() end
    pendingAction = action
    if state == "idle" then
        cancelTimers()
        runPending()
    else
        wakeThen(runPending)
    end
    return true
end

-- Backwards compatible: /bunny test.
function Bunny:TestHop()
    return (self:Perform("hop"))
end

----------------------------------------------------------------------------
-- Hit testing (hover hearts): is a UIParent point over the visible bunny?
----------------------------------------------------------------------------

-- Tight box of the current frame's visible pixels in UIParent units, or nil
-- when nothing is visible (hidden, underground).
function Bunny:GetSpriteBox()
    if not frame or not frame:IsVisible() or spriteHidden or not currentPose then return nil end
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    if not (usable(left) and usable(bottom)) then return nil end
    local pose = POSES[currentPose]
    local sheet = SHEETS[pose[1]]
    local data = ns.SpriteData
    local style = data and (data[db.variation] or data.classic)
    local boxes = style and style[sheet.file]
    local b = boxes and boxes[pose[2]]
    if not b or b[3] <= b[1] then return nil end
    local x0, y0, x1, y1 = b[1], b[2], b[3], b[4]
    if facing < 0 then x0, x1 = 32 - x1, 32 - x0 end
    local k = db.size / 32
    local sx, sy = left + Util.Round(x), bottom + Util.Round(y)
    return sx + x0 * k, sx + x1 * k, sy + (32 - y1) * k, sy + (32 - y0) * k
end

function Bunny:HitTest(px, py, pad)
    local l, r, b, t = self:GetSpriteBox()
    if not l then return false end
    pad = pad or 0
    return px >= l - pad and px <= r + pad and py >= b - pad and py <= t + pad
end

----------------------------------------------------------------------------
-- Debug and stats
----------------------------------------------------------------------------

-- Snapshot used by /bunny stats and the test-suite.
function Bunny:GetDebugState()
    return {
        state = state, x = x, y = y, facing = facing, destX = destX,
        pose = currentPose, sleepUntil = sleepUntil, resumeSleepFor = resumeSleepFor,
        onUpdate = frame and frame:GetScript("OnUpdate") ~= nil or false,
        hops = stats.hops, journeys = stats.journeys, naps = stats.naps,
        airTime = stats.airTime, since = stats.since,
        behavior = currentBehavior, behaviors = stats.behaviors, burrows = stats.burrows,
        burrowing = burrow.active, underground = burrow.underground, spriteHidden = spriteHidden,
        burrowFrom = burrow.fromX, burrowTo = burrow.toX,
        holeA = holes and holes.A.frame or nil, holeB = holes and holes.B.frame or nil,
    }
end

function Bunny:GetHoles()
    return holes
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
    lines[#lines + 1] = ("state: %s | style: %s | shown: %s | locked: %s | position: %s"):format(
        s.state, tostring(ns.db.variation), tostring(ns.db.shown), tostring(ns.db.locked),
        self:IsAutoPositioned() and "auto (above action bar)" or "custom")
    local b = {}
    for _, name in ipairs(Bunny.BEHAVIOR_ORDER) do b[#b + 1] = ("%s %d"):format(name, s.behaviors[name] or 0) end
    lines[#lines + 1] = ("hops: %d in %d journeys | naps: %d | burrows: %d"):format(s.hops, s.journeys, s.naps, s.burrows)
    lines[#lines + 1] = "behaviours: " .. table.concat(b, ", ")
    if s.since then
        local session = max(GetTime() - s.since, 0.001)
        lines[#lines + 1] = ("per-frame updates active %.2f%% of the time (only while airborne)"):format(
            100 * s.airTime / session)
    end
    if ns.Hearts then lines[#lines + 1] = ns.Hearts.StatsLine() end
    local kb = getMemoryKB()
    lines[#lines + 1] = kb and ("memory: %.1f KB"):format(kb) or "memory: not available on this client"
    local ms = getRecentCpuMs()
    lines[#lines + 1] = ms and ("CPU (recent average): %.4f ms per frame"):format(ms)
        or "CPU: per-addon profiler not available on this client"
    return lines
end

