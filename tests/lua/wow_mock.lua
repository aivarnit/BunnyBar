-- Minimal, deterministic mock of the WoW UI API surface BunnyBar uses.
--
-- This is NOT an emulator of the game client. It exists so the addon's real
-- Lua files can be loaded and exercised (state machine, slash commands,
-- SavedVariables handling) under a plain Lua 5.1 / LuaJIT interpreter.
-- Methods are implemented explicitly: calling a method the mock does not know
-- raises an error, which catches typos in API names we rely on.

local M = {}
local unpack = unpack or table.unpack -- Lua 5.1 (WoW) vs 5.2+

-- Templates the mock client pretends not to have (tests can add names).
M.MISSING_TEMPLATES = {}

M.now = 0
M.timers = {}
M.frames = {}
M.chat = {}

-- Events the mock client "knows". Registering anything else errors, like the
-- real client does.
M.KNOWN_EVENTS = {
    ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true,
    EDIT_MODE_LAYOUTS_UPDATED = true, UI_SCALE_CHANGED = true, DISPLAY_SIZE_CHANGED = true,
    PLAYER_LEVEL_UP = true, ENABLE_XP_GAIN = true, DISABLE_XP_GAIN = true,
    UPDATE_EXPANSION_LEVEL = true, GROUP_ROSTER_UPDATE = true, PLAYER_REGEN_ENABLED = true,
}

----------------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------------

local Region = {}
Region.__index = Region

local function newRegion(kind, parent)
    local r = setmetatable({
        _kind = kind, _parent = parent, _shown = true, _points = {},
        _width = 0, _height = 0, _scripts = {}, _events = {}, _children = {},
        _mouse = false, _scale = 1, _hooks = {},
    }, Region)
    if parent then table.insert(parent._children, r) end
    return r
end

function Region:IsShown() return self._shown end
function Region:IsVisible()
    if not self._shown then return false end
    if self._parent then return self._parent:IsVisible() end
    return true
end

local function fireVisibility(region, visibleBefore, script)
    -- Fire OnShow/OnHide on this region and visible descendants.
    local fn = region._scripts[script]
    if fn then fn(region) end
    local hooks = region._hooks[script]
    if hooks then for _, h in ipairs(hooks) do h(region) end end
    for _, child in ipairs(region._children) do
        if child._shown then fireVisibility(child, visibleBefore, script) end
    end
end

function Region:Show()
    if self._shown then return end
    self._shown = true
    if self:IsVisible() then fireVisibility(self, false, "OnShow") end
end
function Region:Hide()
    if not self._shown then return end
    local wasVisible = self:IsVisible()
    self._shown = false
    if wasVisible then fireVisibility(self, true, "OnHide") end
end
function Region:SetShown(shown) if shown then self:Show() else self:Hide() end end

function Region:SetSize(w, h) self._width, self._height = w, h end
function Region:GetWidth() return self._width end
function Region:GetHeight() return self._height end
function Region:SetPoint(point, rel, relPoint, x, y)
    -- Replaces an existing anchor with the same point, like the client.
    for i, p in ipairs(self._points) do
        if p[1] == point then table.remove(self._points, i) break end
    end
    table.insert(self._points, { point, rel, relPoint, x or 0, y or 0 })
end
function Region:ClearAllPoints() self._points = {} end
function Region:SetAllPoints(rel) self._points = { { "ALL", rel } } end
function Region:GetPoint(i)
    local p = self._points[i or 1]
    if p then return p[1], p[2], p[3], p[4], p[5] end
end
function Region:GetNumPoints() return #self._points end
function Region:GetEffectiveScale() return self._scale end

-- Geometry: enough for frames anchored BOTTOM->BOTTOM of UIParent, plus an
-- override used to simulate dragging, plus explicit `_geom` rectangles
-- ({ left, bottom, width, height } in the frame's own scale) for bars.
function Region:SetMockRect(left, bottom, width, height)
    self._geom = { left, bottom, width, height }
end
function Region:GetRight()
    if self._geom then return self._geom[1] + self._geom[3] end
    local l = self:GetLeft()
    return l and (l + self._width) or nil
end
function Region:GetLeft()
    if self._geom then return self._geom[1] end
    if self._dragLeft then return self._dragLeft end
    local p = self._points[1]
    if not p then return nil end
    local parentW = self._parent and self._parent._width or 0
    return parentW / 2 + p[4] - self._width / 2
end
function Region:GetBottom()
    if self._geom then return self._geom[2] end
    if self._dragBottom then return self._dragBottom end
    local p = self._points[1]
    return p and p[5] or nil
end
function Region:GetTop()
    if self._geom then return self._geom[2] + self._geom[4] end
    local b = self:GetBottom()
    return b and (b + self._height) or nil
end
function Region:GetCenter()
    local l, b = self:GetLeft(), self:GetBottom()
    if not l then return nil end
    return l + self._width / 2, b + self._height / 2
end

-- Textures
function Region:SetTexture(file, wrapH, wrapV, filter)
    self._texture, self._filter = file, filter
    if type(file) == "string" then M.texturePaths[file] = true end
end
function Region:SetColorTexture(r, g, b, a) self._color = { r, g, b, a } end
function Region:SetTexCoord(l, r, t, b) self._texCoord = { l, r, t, b } end
function Region:GetTexCoord()
    local c = self._texCoord
    return c[1], c[2], c[3], c[4]
end
function Region:SetVertexColor(r, g, b, a) self._vertex = { r, g, b, a or 1 } end
function Region:GetVertexColor()
    local v = self._vertex or { 1, 1, 1, 1 }
    return v[1], v[2], v[3], v[4]
end
function Region:SetGradient(orient, minColor, maxColor)
    assert(type(minColor) == "table" and type(maxColor) == "table", "SetGradient takes ColorMixins")
    self._gradient = { orient, minColor, maxColor }
end
-- Font strings
function Region:SetText(t)
    self._text = t
    if self._kind == "EditBox" then self._cursorText = t end
end
function Region:GetText() return self._text end
function Region:SetJustifyH(j) self._justify = j end
function Region:SetWidth(w) self._width = w end
function Region:SetHeight(h) self._height = h end
function Region:SetTextColor(r, g, b, a) self._textColor = { r, g, b, a } end

-- Alpha and animations (AnimationGroup with Translation / Alpha). Playing a
-- group schedules OnFinished after the longest startDelay + duration.
function Region:SetAlpha(a) self._alpha = a end
function Region:GetAlpha() return self._alpha or 1 end
function Region:CreateAnimationGroup()
    local owner = self
    local ag = { _anims = {}, _scripts = {}, _playing = false, plays = 0 }
    function ag:CreateAnimation(kind)
        local a = { _kind = kind, _duration = 0, _delay = 0 }
        function a:SetOffset(x, y) self._offset = { x, y } end
        function a:SetDuration(d) self._duration = d end
        function a:SetStartDelay(d) self._delay = d end
        function a:SetFromAlpha(v) self._from = v end
        function a:SetToAlpha(v) self._to = v end
        table.insert(self._anims, a)
        return a
    end
    function ag:SetToFinalAlpha(v) self._final = v end
    function ag:SetScript(name, fn) self._scripts[name] = fn end
    function ag:IsPlaying() return self._playing end
    function ag:Play()
        if self._timer then self._timer.cancelled = true end
        local total = 0
        for _, a in ipairs(self._anims) do total = math.max(total, a._delay + a._duration) end
        self._playing = true
        self.plays = self.plays + 1
        self._timer = M.addTimer(total, function()
            self._playing = false
            self._timer = nil
            if self._final then
                for _, a in ipairs(self._anims) do
                    if a._kind == "Alpha" and a._to then owner._alpha = a._to end
                end
            end
            local fn = self._scripts.OnFinished
            if fn then fn(self, false) end
        end)
    end
    function ag:Stop()
        if self._timer then self._timer.cancelled = true; self._timer = nil end
        self._playing = false
    end
    owner._animGroups = owner._animGroups or {}
    table.insert(owner._animGroups, ag)
    return ag
end

-- Frame stacking / protection
function Region:SetFrameLevel(l) self._level = l end
function Region:GetFrameLevel() return self._level or 1 end
-- Like the client: a frame without its own strata uses its parent's.
function Region:GetFrameStrata()
    if self._strata then return self._strata end
    if self._parent then return self._parent:GetFrameStrata() end
    return "MEDIUM"
end
function Region:GetParent() return self._parent end
function Region:GetName() return self._name end
-- Frames only (textures and font strings are regions, not children).
function Region:GetChildren()
    local out = {}
    for _, ch in ipairs(self._children) do
        if ch._kind ~= "Texture" and ch._kind ~= "FontString" then out[#out + 1] = ch end
    end
    return unpack(out)
end
function Region:IsProtected() return self._protected or false, false end

-- Sliders: SetValue fires OnValueChanged like the client (only on change).
function Region:SetOrientation(o) self._orientation = o end
function Region:SetMinMaxValues(lo, hi) self._min, self._max = lo, hi end
function Region:GetMinMaxValues() return self._min, self._max end
function Region:SetValueStep(s) self._step = s end
function Region:SetObeyStepOnDrag(v) self._obey = v end
function Region:SetThumbTexture(t)
    self._thumbFile = t
    self._thumb = self._thumb or newRegion("Texture", self)
end
function Region:GetThumbTexture() return self._thumb end
function Region:GetValue() return self._value or self._min or 0 end
function Region:SetValue(v, userInput)
    if self._min then v = math.max(self._min, math.min(self._max, v)) end
    if self._value == v then return end
    self._value = v
    local fn = self._scripts.OnValueChanged
    if fn then fn(self, v, userInput or false) end
end

-- Edit boxes
function Region:SetAutoFocus(v) self._autoFocus = v end
function Region:SetMaxLetters(n) self._maxLetters = n end
function Region:ClearFocus()
    if self._focus then
        self._focus = false
        local fn = self._scripts.OnEditFocusLost
        if fn then fn(self) end
    end
end
function Region:SetFocus() self._focus = true end
-- Test helper: type text and press Enter.
function Region:MockType(t)
    self:SetFocus()
    self._text = t
    local fn = self._scripts.OnEnterPressed
    if fn then fn(self) end
end

-- Modern dropdown (DropdownButton + Menu API): SetupMenu stores the menu
-- generator; MockMenu() runs it and returns the radios it created.
function Region:SetupMenu(gen) self._menuGen = gen end
function Region:GenerateMenu() self._generated = (self._generated or 0) + 1 end
function Region:MockMenu()
    local radios = {}
    local root = {}
    function root:CreateRadio(text, isSelected, setSelected, data)
        local r = { text = text, isSelected = isSelected, setSelected = setSelected, data = data }
        radios[#radios + 1] = r
        return r
    end
    function root:CreateTitle() end
    self._menuGen(self, root)
    return radios
end

-- Check / radio buttons and buttons
function Region:SetChecked(v) self._checked = v and true or false end
function Region:GetChecked() return self._checked or false end
function Region:Click()
    if self._kind == "CheckButton" then self._checked = not self._checked end
    local fn = self._scripts.OnClick
    if fn then fn(self, "LeftButton") end
end

-- Frames
function Region:SetScript(name, fn) self._scripts[name] = fn end
function Region:HookScript(name, fn)
    -- Textures and font strings have no scripts in the real client.
    if self._kind == "Texture" or self._kind == "FontString" then
        error("attempt to call method 'HookScript' (a nil value)", 2)
    end
    self._hooks[name] = self._hooks[name] or {}
    table.insert(self._hooks[name], fn)
end
function Region:GetScript(name) return self._scripts[name] end
function Region:RegisterEvent(event)
    if not M.KNOWN_EVENTS[event] then
        error("Attempt to register unknown event \"" .. tostring(event) .. "\"", 2)
    end
    self._events[event] = true
end
function Region:UnregisterEvent(event) self._events[event] = nil end
function Region:SetFrameStrata(s) self._strata = s end
function Region:SetClampedToScreen(v) self._clamped = v end
function Region:SetMovable(v) self._movable = v end
function Region:EnableMouse(v) self._mouse = v and true or false end
function Region:IsMouseEnabled() return self._mouse end
function Region:RegisterForDrag(...) self._drag = { ... } end
function Region:StartMoving()
    assert(self._movable, "StartMoving on non-movable frame")
    self._moving = true
end
function Region:StopMovingOrSizing() self._moving = false end
function Region:SetUserPlaced(v) self._userPlaced = v end
function Region:CreateTexture(name, layer, template, sublevel)
    local t = newRegion("Texture", self)
    t._layer, t._sublevel = layer, sublevel
    return t
end
function Region:CreateFontString(name, layer, template)
    local t = newRegion("FontString", self)
    t._layer, t._template = layer, template
    return t
end

----------------------------------------------------------------------------
-- Globals
----------------------------------------------------------------------------

function M.install(env)
    env = env or _G
    M.env = env
    M.now, M.timers, M.frames, M.chat = 0, {}, {}, {}
    M.texturePaths = {} -- every texture file the addon asked for

    local UIParent = newRegion("Frame", nil)
    UIParent:SetSize(1920, 1080)
    M.UIParent = UIParent
    env.UIParent = UIParent

    env.CreateFrame = function(kind, name, parent, template)
        if template and M.MISSING_TEMPLATES[template] then
            error("Couldn't find inherited node \"" .. template .. "\"", 2)
        end
        local f = newRegion(kind, parent)
        f._template = template
        f._name = name
        table.insert(M.frames, f)
        if name then rawset(env, name, f) end
        return f
    end

    env.GetTime = function() return M.now end
    M.cursor = { 0, 0 }
    env.GetCursorPosition = function() return M.cursor[1], M.cursor[2] end
    M.combat = false
    env.InCombatLockdown = function() return M.combat end
    env.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end

    local function addTimer(delay, fn)
        local t = { at = M.now + delay, fn = fn, cancelled = false }
        function t.Cancel(self) self.cancelled = true end
        function t.IsCancelled(self) return self.cancelled end
        table.insert(M.timers, t)
        return t
    end
    M.addTimer = addTimer
    env.C_Timer = {
        NewTimer = function(delay, fn) return addTimer(delay, fn) end,
        After = function(delay, fn) addTimer(delay, fn) end,
    }

    env.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, msg) table.insert(M.chat, msg) end,
    }
    env.SlashCmdList = {}
end

----------------------------------------------------------------------------
-- Driving the simulation
----------------------------------------------------------------------------

function M.fire(event, ...)
    for _, f in ipairs(M.frames) do
        if f._events[event] and f._scripts.OnEvent then
            f._scripts.OnEvent(f, event, ...)
        end
    end
end

function M.pendingTimers()
    local n = 0
    for _, t in ipairs(M.timers) do
        if not t.cancelled and not t.fired then n = n + 1 end
    end
    return n
end

local function runDueTimers()
    local fired = true
    while fired do
        fired = false
        local due
        for _, t in ipairs(M.timers) do
            if not t.cancelled and not t.fired and t.at <= M.now + 1e-9 then
                if not due or t.at < due.at then due = t end
            end
        end
        if due then
            due.fired = true
            due.fn(due)
            fired = true
        end
    end
    -- Drop finished timers so the list stays small during long simulations.
    local keep = {}
    for _, t in ipairs(M.timers) do
        if not t.cancelled and not t.fired then keep[#keep + 1] = t end
    end
    M.timers = keep
end

-- Advance the clock in fixed frame steps, running timers and OnUpdate
-- scripts of visible frames. `onFrame` (optional) is called after each step.
function M.advance(seconds, step, onFrame)
    step = step or (1 / 60)
    local steps = math.floor(seconds / step + 0.5)
    for _ = 1, steps do
        M.now = M.now + step
        runDueTimers()
        for _, f in ipairs(M.frames) do
            local fn = f._scripts.OnUpdate
            if fn and f:IsVisible() then fn(f, step) end
        end
        if onFrame then onFrame() end
    end
end

-- Load the addon's Lua files in TOC order with the (addonName, ns) varargs
-- the client passes to every file.
function M.loadAddon(dir, addonName)
    local files = {}
    for raw in io.lines(dir .. "/" .. addonName .. ".toc") do
        local line = raw:gsub("\r", "")
        if line ~= "" and not line:match("^#") then files[#files + 1] = line end
    end
    local ns = {}
    for _, file in ipairs(files) do
        local chunk = assert(loadfile(dir .. "/" .. file))
        chunk(addonName, ns)
    end
    return ns, files
end

return M
