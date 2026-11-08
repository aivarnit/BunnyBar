-- BunnyBar: pure helper functions.
-- Nothing in this file touches the WoW API, so it can be unit-tested with a
-- stock Lua 5.1 / LuaJIT interpreter (see tests/lua/).

local _, ns = ...

local Util = {}
ns.Util = Util

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

function Util.Clamp(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

function Util.Round(value)
    return floor(value + 0.5)
end

-- Uniform random number in [lo, hi]. `rand` defaults to math.random and may be
-- injected by tests for determinism.
function Util.RandomRange(lo, hi, rand)
    return lo + (hi - lo) * (rand or math.random)()
end

-- Height of a parabolic hop at normalised time t in [0, 1].
-- Peaks at `height` when t = 0.5 and is 0 at both ends.
function Util.HopArc(t, height)
    t = Util.Clamp(t, 0, 1)
    return 4 * height * t * (1 - t)
end

-- Horizontal movement range (left edge of the sprite) inside a track.
function Util.TrackBounds(trackWidth, size)
    return 0, max(0, trackWidth - size)
end

-- Pick a destination inside [minX, maxX] that is at least `minDistance` away
-- from `currentX` when the track allows it. Never returns a value outside the
-- bounds, so the bunny can never wander off its track.
function Util.ChooseDestination(currentX, minX, maxX, minDistance, rand)
    rand = rand or math.random
    if maxX <= minX then return minX end
    local span = maxX - minX
    minDistance = min(minDistance or 0, span / 2)
    local dest = minX + span * rand()
    if abs(dest - currentX) < minDistance then
        -- Mirror away from the current position instead of re-rolling, so the
        -- function always terminates in one step.
        if currentX - minX > maxX - currentX then
            dest = currentX - minDistance
        else
            dest = currentX + minDistance
        end
    end
    return Util.Clamp(dest, minX, maxX)
end

-- Landing point of the next hop when travelling from currentX to destX with a
-- maximum horizontal distance of maxStep per hop.
function Util.NextHopX(currentX, destX, maxStep)
    local delta = destX - currentX
    if abs(delta) <= maxStep then return destX end
    return currentX + (delta > 0 and maxStep or -maxStep)
end

-- Number of hops needed to reach destX from currentX.
function Util.HopCount(currentX, destX, maxStep)
    if maxStep <= 0 then return 0 end
    local n = abs(destX - currentX) / maxStep
    local whole = floor(n)
    return (n > whole) and (whole + 1) or whole
end

-- Split "/bunny <command> <args>" input into a lower-case command and the
-- trimmed remainder. Empty input yields "" (help).
function Util.ParseCommand(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    if not cmd then return "", "" end
    return cmd:lower(), rest
end

-- Validate a numeric argument against a spec:
--   { label = "size", min = 16, max = 128, integer = true }
-- Returns the number, or nil and a human-readable error message.
function Util.ParseNumber(text, spec)
    text = (text or ""):match("^%s*(.-)%s*$")
    local range = ("%s to %s"):format(tostring(spec.min), tostring(spec.max))
    if text == "" then
        return nil, ("%s needs a value (%s)."):format(spec.label, range)
    end
    -- Only plain decimal numbers: rejects hex, exponents, "nan", "inf".
    if not (text:match("^[-+]?%d+%.?%d*$") or text:match("^[-+]?%.%d+$")) then
        return nil, ("'%s' is not a number. Use %s."):format(text, range)
    end
    local value = tonumber(text)
    if not value or value ~= value then
        return nil, ("'%s' is not a number. Use %s."):format(text, range)
    end
    if spec.integer and value ~= floor(value) then
        return nil, ("%s must be a whole number (%s)."):format(spec.label, range)
    end
    if value < spec.min or value > spec.max then
        return nil, ("%s must be between %s and %s."):format(
            spec.label, tostring(spec.min), tostring(spec.max))
    end
    return value
end
