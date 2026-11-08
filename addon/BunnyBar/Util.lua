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

----------------------------------------------------------------------------
-- Colours
----------------------------------------------------------------------------

-- Parse "#RRGGBB" / "RRGGBB" (case-insensitive, surrounding spaces allowed).
-- Returns the canonical upper-case "RRGGBB" and r, g, b in 0..1, or nil and
-- an error message.
function Util.ParseHex(text)
    if type(text) ~= "string" then return nil, "Enter a colour like #FFB6C1." end
    local hex = text:match("^%s*#?(%x%x%x%x%x%x)%s*$")
    if not hex then
        return nil, ("'%s' is not a colour. Use six hex digits, e.g. #FFB6C1."):format(text)
    end
    hex = hex:upper()
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    return hex, r, g, b
end

-- r, g, b in 0..1 -> "RRGGBB"
function Util.RGBToHex(r, g, b)
    local function byte(v) return Util.Clamp(floor(v * 255 + 0.5), 0, 255) end
    return ("%02X%02X%02X"):format(byte(r), byte(g), byte(b))
end

-- r, g, b in 0..1 -> h in [0, 360), s, v in 0..1
function Util.RGBToHSV(r, g, b)
    local hi, lo = max(r, g, b), min(r, g, b)
    local d = hi - lo
    local h = 0
    if d > 0 then
        if hi == r then
            h = 60 * (((g - b) / d) % 6)
        elseif hi == g then
            h = 60 * ((b - r) / d + 2)
        else
            h = 60 * ((r - g) / d + 4)
        end
    end
    local s = hi > 0 and d / hi or 0
    return h % 360, s, hi
end

-- h in degrees (any value, wrapped), s, v in 0..1 -> r, g, b in 0..1
function Util.HSVToRGB(h, s, v)
    h = (h % 360) / 60
    local i = floor(h)
    local f = h - i
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    end
    return v, p, q
end

----------------------------------------------------------------------------
-- Safe reads of Blizzard frames
----------------------------------------------------------------------------

-- Midnight-era clients can return "secret" values that addons may display
-- but not compare or do arithmetic with.
function Util.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

function Util.IsUsableNumber(v)
    if Util.IsSecret(v) then return false end
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- True only if f:IsVisible() succeeds and returns a real `true`.
function Util.IsShown(f)
    if type(f) ~= "table" or type(f.IsVisible) ~= "function" then return false end
    local ok, visible = pcall(f.IsVisible, f)
    return ok and not Util.IsSecret(visible) and visible == true
end

local function readRect(f)
    return f:GetLeft(), f:GetRight(), f:GetBottom(), f:GetTop(), f:GetEffectiveScale()
end

-- Rectangle of a region in UIParent units, or nil if unavailable.
function Util.ReadRect(f)
    if type(f) ~= "table" then return nil end
    local ok, l, r, b, t, scale = pcall(readRect, f)
    if not ok then return nil end
    for _, v in ipairs({ l, r, b, t, scale }) do
        if not Util.IsUsableNumber(v) then return nil end
    end
    if scale <= 0 or r <= l or t <= b then return nil end
    local k = scale / UIParent:GetEffectiveScale()
    return l * k, r * k, b * k, t * k
end

function Util.InCombat()
    return InCombatLockdown ~= nil and InCombatLockdown() and true or false
end
