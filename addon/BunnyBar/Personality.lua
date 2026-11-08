-- BunnyBar: personalities and a lightweight, event-driven mood system.
--
-- Both only change WHICH existing behaviour the scheduler picks (and how long
-- it waits); never animation speed, sprites or timing of an animation.
--
-- Data-driven: every personality and mood is a small table of multipliers
-- applied to the scheduler's existing knobs (Animation.lua decideNext):
--   nap       x sleepChance            (chance to nap)
--   burrow    x Bunny.BURROW_CHANCE    (chance to burrow, after its cooldown)
--   behavior  x Bunny.BEHAVIOR_CHANCE  (chance of an idle behaviour)
--   wait      x the idle wait (interval x U(0.5, 1.5))
--   sleep     x nap length
--   weights   x idle behaviour weights (carrot, wash, scratch, stretch, look)
-- A hop is whatever is left, so fewer naps/behaviours and shorter waits mean
-- more hopping. Balanced with the Happy mood is all 1s: exactly the v0.3
-- scheduler (same random draws), so its frequencies are preserved.
--
-- Moods (happy, sleepy, playful, hungry) evolve ONLY on discrete events -
-- when an activity completes (hop journey, nap, idle behaviour, burrow) -
-- through three small counters (tired, hungry, energy). No timers, no
-- per-frame work, no randomness in transitions (deterministic). Hysteresis
-- (MIN_DWELL events in a mood unless its need was satisfied) prevents rapid
-- oscillation. The mood state is not saved: a fresh session starts Happy.

local _, ns = ...

local Personality = {}
ns.Personality = Personality

Personality.ORDER = { "balanced", "lazy", "energetic", "playful", "sleepy" }
Personality.MOOD_ORDER = { "happy", "sleepy", "playful", "hungry" }

Personality.LABELS = {
    balanced = "Balanced", lazy = "Lazy", energetic = "Energetic", playful = "Playful", sleepy = "Sleepy",
    happy = "Happy", hungry = "Hungry",
}

-- Personality multipliers. `rates` scale how fast the mood counters grow;
-- `noRepeat` = how many recent idle behaviours are excluded from the next
-- pick; `wakeStretch` = chance to stretch right after waking up.
Personality.PROFILES = {
    balanced = {
        nap = 1.0, burrow = 1.0, behavior = 1.0, wait = 1.0, sleep = 1.0,
        weights = {}, rates = { tired = 1.0, hungry = 1.0, energy = 1.0 },
        noRepeat = 1, wakeStretch = 0,
    },
    lazy = {
        nap = 2.2, burrow = 0.5, behavior = 1.3, wait = 1.6, sleep = 1.5,
        weights = { stretch = 1.5, wash = 1.2, look = 0.8 },
        rates = { tired = 1.5, hungry = 1.0, energy = 0.6 },
        noRepeat = 1, wakeStretch = 0.3,
    },
    energetic = {
        nap = 0.4, burrow = 1.2, behavior = 1.1, wait = 0.6, sleep = 0.7,
        weights = { look = 1.5, scratch = 1.3, stretch = 0.7 },
        rates = { tired = 0.7, hungry = 1.3, energy = 1.5 },
        noRepeat = 1, wakeStretch = 0,
    },
    playful = {
        nap = 0.8, burrow = 2.0, behavior = 1.4, wait = 0.9, sleep = 0.9,
        weights = { carrot = 2.0, look = 1.5 },
        rates = { tired = 1.0, hungry = 1.2, energy = 1.8 },
        noRepeat = 2, wakeStretch = 0,
    },
    sleepy = {
        nap = 2.5, burrow = 0.6, behavior = 0.9, wait = 1.3, sleep = 1.6,
        weights = { stretch = 1.4 },
        rates = { tired = 2.0, hungry = 0.8, energy = 0.5 },
        noRepeat = 1, wakeStretch = 0.6,
    },
}

-- Mood multipliers (combined with the personality's by multiplication).
Personality.MOODS = {
    happy   = { nap = 1.0, burrow = 1.0, behavior = 1.0, wait = 1.0, weights = {} },
    sleepy  = { nap = 2.0, burrow = 0.6, behavior = 0.8, wait = 1.2, weights = { stretch = 1.5 } },
    playful = { nap = 0.6, burrow = 1.8, behavior = 0.8, wait = 0.8, weights = { look = 1.5, scratch = 1.2 } },
    hungry  = { nap = 1.0, burrow = 1.0, behavior = 1.6, wait = 1.0, weights = { carrot = 4.0 } },
}
-- Happy is the neutral resting mood (all 1x): "normal activities". So
-- Balanced + Happy is exactly the v0.3 scheduler.

-- Mood counters change on these events. Increases are scaled by the
-- personality's rates; `clear` resets a counter (the need was satisfied).
Personality.EVENTS = {
    hop     = { tired = 1.0, hungry = 0.7, energy = -1.0 },
    burrow  = { tired = 1.5, hungry = 1.0, energy = -3.0 },
    nap     = { clear = "tired", energy = 3.0, hungry = 0.5 },
    carrot  = { clear = "hungry", energy = 1.0 },
    wash    = { hungry = 0.5, energy = 1.0 },
    scratch = { hungry = 0.5, energy = 1.0 },
    stretch = { hungry = 0.5, energy = 1.5, tired = -1.0 },
    look    = { hungry = 0.5, energy = 1.0 },
}

-- A counter at or above its threshold makes the matching mood a candidate.
Personality.THRESHOLDS = { tired = 6, hungry = 6, energy = 5 }
Personality.MOOD_FOR = { tired = "sleepy", hungry = "hungry", energy = "playful" }
Personality.COUNTER_FOR = { sleepy = "tired", hungry = "hungry", playful = "energy" }
Personality.MIN_DWELL = 3      -- events before a non-satisfied mood may change
Personality.COUNTER_MAX = 12
Personality.CHANCE_CAP = 0.9   -- no single knob may push a chance above this

local state = {
    mood = "happy",
    dwell = 0,                 -- events since the last mood change
    counters = { tired = 0, hungry = 0, energy = 0 },
    changes = 0,
    lastEvent = nil,
}

local params = { weights = {} } -- reused result of Params()

local function db() return ns.db end

function Personality.IsValid(id)
    return type(id) == "string" and Personality.PROFILES[id] ~= nil
end

function Personality.Current()
    local d = db()
    local id = d and d.personality
    return Personality.PROFILES[id] and id or "balanced"
end

function Personality.MoodsEnabled()
    local d = db()
    return d ~= nil and d.moods ~= false
end

function Personality.Mood()
    return Personality.MoodsEnabled() and state.mood or nil
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Effective multipliers for the next decision (personality x mood). Returns
-- one reused table; callers must not keep it.
function Personality.Params()
    local P = Personality.PROFILES[Personality.Current()]
    local M = Personality.MoodsEnabled() and Personality.MOODS[state.mood] or nil
    params.nap = P.nap * (M and M.nap or 1)
    params.burrow = P.burrow * (M and M.burrow or 1)
    params.behavior = P.behavior * (M and M.behavior or 1)
    params.wait = P.wait * (M and M.wait or 1)
    params.sleep = P.sleep
    params.noRepeat = P.noRepeat
    params.wakeStretch = P.wakeStretch
    local w = params.weights
    for _, name in ipairs(ns.Bunny.BEHAVIOR_ORDER) do
        w[name] = (P.weights[name] or 1) * (M and M.weights[name] or 1)
    end
    return params
end

-- Scale a base chance by a multiplier, capped.
function Personality.Chance(base, mult)
    if mult == 1 then return base end -- exact v0.3 behaviour for 1x
    return clamp(base * mult, 0, Personality.CHANCE_CAP)
end

-- Re-evaluate the mood after an event (hysteresis: a mood stays at least
-- MIN_DWELL events unless its need was just satisfied).
local function evaluate()
    local c, T = state.counters, Personality.THRESHOLDS
    local best, bestScore = "happy", 1
    for _, key in ipairs({ "tired", "hungry", "energy" }) do
        local score = c[key] / T[key]
        if score >= bestScore then best, bestScore = Personality.MOOD_FOR[key], score end
    end
    if best == state.mood then return end
    local own = Personality.COUNTER_FOR[state.mood]
    local satisfied = own and c[own] < T[own] * 0.5
    if state.mood ~= "happy" and not satisfied and state.dwell < Personality.MIN_DWELL then return end
    if state.mood == "happy" and state.dwell < 1 then return end
    state.mood, state.dwell = best, 0
    state.changes = state.changes + 1
end

-- An activity completed. `event` is one of Personality.EVENTS' keys.
function Personality.OnEvent(event)
    local e = Personality.EVENTS[event]
    if not e or not Personality.MoodsEnabled() then return end
    local c = state.counters
    local rates = Personality.PROFILES[Personality.Current()].rates
    for _, key in ipairs({ "tired", "hungry", "energy" }) do
        local delta = e[key]
        if delta then
            if delta > 0 then delta = delta * rates[key] end
            c[key] = clamp(c[key] + delta, 0, Personality.COUNTER_MAX)
        end
    end
    if e.clear then c[e.clear] = 0 end
    state.dwell = state.dwell + 1
    state.lastEvent = event
    evaluate()
end

function Personality.Reset()
    state.mood, state.dwell, state.changes, state.lastEvent = "happy", 0, 0, nil
    state.counters.tired, state.counters.hungry, state.counters.energy = 0, 0, 0
end

function Personality.GetState()
    return state
end

-- For tests / debug: force a mood (still subject to later events).
function Personality.SetMood(mood)
    if Personality.MOODS[mood] then state.mood, state.dwell = mood, 0 end
end

----------------------------------------------------------------------------
-- Text for /bunny mood
----------------------------------------------------------------------------

function Personality.Describe(debug)
    local lines = {}
    local pid = Personality.Current()
    if not Personality.MoodsEnabled() then
        lines[1] = ("personality: %s | mood system: off"):format(Personality.LABELS[pid])
    else
        lines[1] = ("personality: %s | mood: %s"):format(Personality.LABELS[pid], Personality.LABELS[state.mood])
    end
    if not debug then return lines end
    local c = state.counters
    lines[#lines + 1] = ("  counters: tired %.1f/%d, hungry %.1f/%d, energy %.1f/%d | %d events in mood, %d changes"):format(
        c.tired, Personality.THRESHOLDS.tired, c.hungry, Personality.THRESHOLDS.hungry,
        c.energy, Personality.THRESHOLDS.energy, state.dwell, state.changes)
    local P = Personality.Params()
    local d = db()
    local B = ns.Bunny
    lines[#lines + 1] = ("  chances: nap %.0f%%, burrow %.0f%% (after cooldown), idle behaviour %.0f%% | idle wait x%.2f | nap length x%.2f"):format(
        100 * Personality.Chance(d.sleepChance, P.nap), 100 * Personality.Chance(B.BURROW_CHANCE, P.burrow),
        100 * Personality.Chance(B.BEHAVIOR_CHANCE, P.behavior), P.wait, P.sleep)
    local total, parts = 0, {}
    for _, name in ipairs(B.BEHAVIOR_ORDER) do total = total + B.BEHAVIORS[name].weight * P.weights[name] end
    for _, name in ipairs(B.BEHAVIOR_ORDER) do
        parts[#parts + 1] = ("%s %.0f%%"):format(name, 100 * B.BEHAVIORS[name].weight * P.weights[name] / total)
    end
    lines[#lines + 1] = "  behaviour weights: " .. table.concat(parts, ", ")
    local nextIn = B.GetNextDecisionIn and B:GetNextDecisionIn()
    lines[#lines + 1] = nextIn and ("  next decision in %.1f s"):format(nextIn) or "  next decision: when the current activity ends"
    return lines
end
