-- BunnyBar: little pink hearts when the cursor hovers over the bunny.
--
-- Click-through by design: the bunny frame never enables the mouse (action
-- buttons underneath must keep working), and a mouse-disabled frame never
-- gets OnEnter. So hovering is detected by checking the cursor position on
-- a throttled C_Timer:
--   * FAR_INTERVAL (4x a second) while the cursor is away from the track,
--   * NEAR_INTERVAL (20x a second) only while it is near the track,
--   * nothing at all while hearts are disabled or the bunny is hidden.
-- The hit test uses the tight bounding box of the CURRENT sprite frame
-- (SpriteData.lua, generated), so empty parts of the track never count.
--
-- Hearts are a SECONDARY effect: they never change the bunny's behaviour
-- (a sleeping bunny keeps sleeping). Each heart is a pooled texture on its
-- own click-through child frame, animated by a native AnimationGroup
-- (Translation + Alpha) - no per-frame Lua - and hidden again when its
-- animation finishes.

local _, ns = ...
local Util = ns.Util

local Hearts = {}
ns.Hearts = Hearts

Hearts.TEXTURE = { file = "bunny-heart.tga", count = 1, slots = 1, height = 16, layers = 1 }
Hearts.FAR_INTERVAL = 0.25
Hearts.NEAR_INTERVAL = 0.05
Hearts.NEAR_MARGIN = 24      -- UI units around the track that count as "near"
Hearts.HIT_PAD = 1           -- forgiving edge around the sprite box (UI units)
-- Emission rate and maximum simultaneous hearts per intensity setting.
Hearts.INTENSITY = {
    subtle = { interval = 0.60, max = 3 },
    normal = { interval = 0.35, max = 6 },
    extra  = { interval = 0.18, max = 10 },
}
-- Mirrored by HEART_PARTICLE in generate_sprites.py (preview GIF). Sizes are
-- relative to the bunny size.
Hearts.PARTICLE = { duration = 1.4, rise = 0.55, drift = 0.15, size = 0.28, fadeDelay = 0.5 }
Hearts.POOL_SIZE = 10

local layer          -- click-through frame holding the heart textures
local pool = {}      -- { tex, ag, move, fade, busy }
local timer
local hovering = false
local nextEmit = 0
local stats = { emitted = 0, checks = 0, hovered = 0 }

local function db() return ns.db end

local function intensity()
    return Hearts.INTENSITY[db().heartIntensity] or Hearts.INTENSITY.normal
end

local function onFinished(ag)
    local p = ag.particle
    p.busy = false
    p.tex:Hide()
end

local function createParticle()
    local tex = layer:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(ns.Appearance.TEXTURE_PATH .. Hearts.TEXTURE.file, "CLAMP", "CLAMP", "NEAREST")
    tex:Hide()
    if type(tex.CreateAnimationGroup) ~= "function" then return nil end -- unsupported client
    local ag = tex:CreateAnimationGroup()
    local move = ag:CreateAnimation("Translation")
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    ag:SetToFinalAlpha(true)
    ag:SetScript("OnFinished", onFinished)
    local p = { tex = tex, ag = ag, move = move, fade = fade, busy = false }
    ag.particle = p
    return p
end

local function ensureLayer()
    local frame = ns.Bunny and ns.Bunny:GetFrame()
    if not frame then return nil end
    if not layer then
        layer = CreateFrame("Frame", nil, frame)
        layer:SetAllPoints(frame)
        layer:EnableMouse(false) -- hearts must never catch clicks
    end
    return layer
end

local function busyCount()
    local n = 0
    for i = 1, #pool do if pool[i].busy then n = n + 1 end end
    return n
end

-- Emit one heart at UIParent coordinates (cx, cy). Returns true if emitted.
function Hearts.Emit(cx, cy, rand)
    rand = rand or math.random
    if not ensureLayer() then return false end
    if busyCount() >= intensity().max then return false end
    local p
    for i = 1, #pool do if not pool[i].busy then p = pool[i]; break end end
    if not p then
        if #pool >= Hearts.POOL_SIZE then return false end
        p = createParticle()
        if not p then return false end
        pool[#pool + 1] = p
    end
    local frame = ns.Bunny:GetFrame()
    local size = db().size
    local P = Hearts.PARTICLE
    local s = math.max(6, Util.Round(size * P.size))
    local left, bottom = frame:GetLeft() or 0, frame:GetBottom() or 0
    p.tex:SetSize(s, s)
    p.tex:ClearAllPoints()
    p.tex:SetPoint("BOTTOM", frame, "BOTTOMLEFT", Util.Round(cx - left), Util.Round(cy - bottom))
    p.ag:Stop()
    p.move:SetOffset(Util.Round((rand() * 2 - 1) * size * P.drift), Util.Round(size * P.rise))
    p.move:SetDuration(P.duration)
    p.fade:SetStartDelay(P.fadeDelay)
    p.fade:SetDuration(P.duration - P.fadeDelay)
    p.tex:SetAlpha(1)
    p.tex:Show()
    p.busy = true
    p.ag:Play()
    stats.emitted = stats.emitted + 1
    return true
end

-- Emit a heart from just above the bunny's head, slightly randomised.
function Hearts.EmitFromBunny(rand)
    rand = rand or math.random
    local l, r, _, t = ns.Bunny:GetSpriteBox()
    if not l then return false end
    local w = r - l
    local face = ns.Bunny:GetDebugState().facing
    -- Head side of the box, a little above the top.
    local cx = l + w * (face < 0 and 0.35 or 0.65) + (rand() * 2 - 1) * w * 0.15
    return Hearts.Emit(cx, t - db().size * 0.1, rand)
end

----------------------------------------------------------------------------
-- Hover detection
----------------------------------------------------------------------------

-- Hearts need the cursor position API; without it they stay off quietly.
function Hearts.IsSupported()
    return type(GetCursorPosition) == "function"
end

local function cursor()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    if not (Util.IsUsableNumber(x) and Util.IsUsableNumber(y) and Util.IsUsableNumber(scale)) or scale <= 0 then
        return nil
    end
    return x / scale, y / scale
end

local function nearTrack(cx, cy)
    local frame = ns.Bunny:GetFrame()
    local l, r, b, t = Util.ReadRect(frame)
    if not l then return false end
    local m = Hearts.NEAR_MARGIN
    return cx >= l - m and cx <= r + m and cy >= b - m and cy <= t + m + db().size
end

function Hearts.IsActive()
    local frame = ns.Bunny and ns.Bunny:GetFrame()
    return db() ~= nil and db().hearts and Hearts.IsSupported() and frame ~= nil and frame:IsVisible()
end

local check -- forward

local function scheduleCheck(delay)
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(delay, check)
end

function check()
    timer = nil
    if not Hearts.IsActive() then hovering = false; return end
    stats.checks = stats.checks + 1
    local cx, cy = cursor()
    if not cx or not nearTrack(cx, cy) then
        hovering = false
        scheduleCheck(Hearts.FAR_INTERVAL)
        return
    end
    local over = ns.Bunny:HitTest(cx, cy, Hearts.HIT_PAD)
    if over then
        if not hovering then stats.hovered = stats.hovered + 1 end
        local now = GetTime()
        if now >= nextEmit then
            Hearts.EmitFromBunny()
            nextEmit = now + intensity().interval
        end
    end
    hovering = over
    scheduleCheck(Hearts.NEAR_INTERVAL)
end

-- Start / stop the throttled check (bunny shown/hidden, setting changed).
function Hearts.Refresh()
    if Hearts.IsActive() then
        if not timer then scheduleCheck(Hearts.FAR_INTERVAL) end
    else
        Hearts.Stop()
    end
end

function Hearts.Stop()
    if timer then timer:Cancel(); timer = nil end
    hovering = false
    for i = 1, #pool do
        local p = pool[i]
        if p.busy then
            p.ag:Stop()
            p.busy = false
        end
        p.tex:Hide()
    end
end

function Hearts.OnBunnyShown() Hearts.Refresh() end
function Hearts.OnBunnyHidden() Hearts.Stop() end

-- /bunny test hearts: a short burst, regardless of hovering.
local burstLeft = 0
local function burstStep()
    if burstLeft <= 0 or not Hearts.IsActive() then burstLeft = 0; return end
    burstLeft = burstLeft - 1
    Hearts.EmitFromBunny()
    if burstLeft > 0 then C_Timer.After(intensity().interval * 0.6, burstStep) end
end

function Hearts.Burst()
    if not Hearts.IsActive() then return false end
    burstLeft = intensity().max
    burstStep()
    return true
end

function Hearts.GetState()
    return {
        active = Hearts.IsActive() and true or false,
        polling = timer ~= nil,
        hovering = hovering,
        busy = busyCount(),
        pool = #pool,
        emitted = stats.emitted,
        checks = stats.checks,
        layer = layer,
    }
end

function Hearts.StatsLine()
    local s = Hearts.GetState()
    return ("hearts: %s, %d emitted, %d on screen, hover checks %d"):format(
        db().hearts and ("on (" .. tostring(db().heartIntensity) .. ")") or "off", s.emitted, s.busy, s.checks)
end
