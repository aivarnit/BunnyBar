-- Minimal, deterministic mock of the WoW UI API surface BunnyBar uses.
--
-- This is NOT an emulator of the game client. It exists so the addon's real
-- Lua files can be loaded and exercised (state machine, slash commands,
-- SavedVariables handling) under a plain Lua 5.1 / LuaJIT interpreter.
-- Methods are implemented explicitly: calling a method the mock does not know
-- raises an error, which catches typos in API names we rely on.

local M = {}

M.now = 0
M.timers = {}
M.frames = {}
M.chat = {}

-- Events the mock client "knows". Registering anything else errors, like the
-- real client does.
M.KNOWN_EVENTS = {
    ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true,
    EDIT_MODE_LAYOUTS_UPDATED = true, UI_SCALE_CHANGED = true, DISPLAY_SIZE_CHANGED = true,
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
        _mouse = false, _scale = 1,
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
-- override used to simulate dragging.
function Region:GetLeft()
    if self._dragLeft then return self._dragLeft end
    local p = self._points[1]
    if not p then return nil end
    local parentW = self._parent and self._parent._width or 0
    return parentW / 2 + p[4] - self._width / 2
end
function Region:GetBottom()
    if self._dragBottom then return self._dragBottom end
    local p = self._points[1]
    return p and p[5] or nil
end
function Region:GetTop()
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
end
function Region:SetColorTexture(r, g, b, a) self._color = { r, g, b, a } end
function Region:SetTexCoord(l, r, t, b) self._texCoord = { l, r, t, b } end
function Region:GetTexCoord()
    local c = self._texCoord
    return c[1], c[2], c[3], c[4]
end
-- Font strings
function Region:SetText(t) self._text = t end
function Region:GetText() return self._text end

-- Frames
function Region:SetScript(name, fn) self._scripts[name] = fn end
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
function Region:CreateTexture(name, layer)
    local t = newRegion("Texture", self)
    t._layer = layer
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

    local UIParent = newRegion("Frame", nil)
    UIParent:SetSize(1920, 1080)
    M.UIParent = UIParent
    env.UIParent = UIParent

    env.CreateFrame = function(kind, name, parent)
        local f = newRegion(kind, parent)
        table.insert(M.frames, f)
        if name then rawset(env, name, f) end
        return f
    end

    env.GetTime = function() return M.now end

    local function addTimer(delay, fn)
        local t = { at = M.now + delay, fn = fn, cancelled = false }
        function t.Cancel(self) self.cancelled = true end
        function t.IsCancelled(self) return self.cancelled end
        table.insert(M.timers, t)
        return t
    end
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
