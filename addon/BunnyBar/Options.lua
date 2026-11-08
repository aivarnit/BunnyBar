-- BunnyBar: Escape -> Options -> AddOns -> BunnyBar
--
-- Registered with the modern Settings API as a canvas-layout category when
-- available (Settings.RegisterCanvasLayoutCategory + RegisterAddOnCategory),
-- falling back to the legacy InterfaceOptions_AddCategory. Controls are
-- built lazily the first time the panel is shown.
--
-- Colour controls are BunnyBar's own (Blizzard's ColorPickerFrame is a
-- modal popup, not an inline control): a saturation/brightness square, a
-- hue slider, a brightness slider, a hex box, a swatch and a live bunny
-- preview. Every control writes through Config.Set(), and Options.Refresh()
-- (called from Config.Notify) pushes the saved values back into all of
-- them, so the panel, slash commands and the bunny always agree.

local _, ns = ...
local Util = ns.Util

local Options = {}
ns.Options = Options

Options.mode = nil -- "settings" | "legacy" | "none"

local panel, category
local built = false
local pendingOpen = false
local c = {}          -- controls, exposed for tests as Options.controls
Options.controls = c

-- Current colour as HSV. Kept here (not only as hex) so hue survives greys.
local hsv = { h = 0, s = 0, v = 1 }
local shownHex        -- the hex value the controls currently display
local syncing = false -- true while Refresh() writes into the controls

local SQUARE = 150
local SLIDER_W, SLIDER_H = 150, 14

-- Right column layout. Section positions are derived from the number of
-- size presets, so adding presets can never overlap the next section.
local RIGHT_X, TOP_Y = 320, -70
local ROW = 22           -- radio / checkbox row height
local SECTION_GAP = 24   -- space between sections
Options.layout = {}

----------------------------------------------------------------------------
-- Registration and opening
----------------------------------------------------------------------------

local function onPanelShow()
    Options.Build()
    Options.Refresh()
end

function Options.Register()
    if panel then return Options.mode ~= "none" end
    panel = CreateFrame("Frame")
    panel.name = "BunnyBar"
    panel:Hide()
    panel:SetScript("OnShow", onPanelShow)
    Options.panel = panel

    local S = Settings
    if type(S) == "table" and type(S.RegisterCanvasLayoutCategory) == "function"
        and type(S.RegisterAddOnCategory) == "function" then
        local ok, cat = pcall(S.RegisterCanvasLayoutCategory, panel, "BunnyBar")
        if ok and cat and pcall(S.RegisterAddOnCategory, cat) then
            category = cat
            Options.category = cat
            Options.mode = "settings"
            return true
        end
    end
    if type(InterfaceOptions_AddCategory) == "function" and pcall(InterfaceOptions_AddCategory, panel) then
        Options.mode = "legacy"
        return true
    end
    Options.mode = "none"
    return false
end

local function categoryID()
    if type(category.GetID) == "function" then
        local ok, id = pcall(category.GetID, category)
        if ok and id ~= nil then return id end
    end
    return category.ID or "BunnyBar"
end

-- Returns true, or false and a message for the user.
function Options.Open()
    if Options.mode == nil then Options.Register() end
    if Options.mode == "none" then
        return false, "the settings panel isn't available on this client. Use /bunny commands instead."
    end
    if Util.InCombat() then
        pendingOpen = true
        ns.Print("the options will open when combat ends.")
        return true
    end
    pendingOpen = false
    local ok
    if Options.mode == "settings" then
        ok = pcall(Settings.OpenToCategory, categoryID())
    else
        -- The legacy panel needs two calls to scroll to an addon category.
        ok = pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
    end
    if not ok then return false, "couldn't open the settings panel." end
    return true
end

function Options.OnCombatEnd()
    if pendingOpen then Options.Open() end
end

----------------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------------

local function make(kind, parent, template)
    if template then
        local ok, f = pcall(CreateFrame, kind, nil, parent, template)
        if ok and f then return f end
    end
    return CreateFrame(kind, nil, parent)
end

local function text(parent, font, str, point, rel, relPoint, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetPoint(point, rel, relPoint, x, y)
    fs:SetText(str)
    fs:SetJustifyH("LEFT")
    return fs
end

-- Two-colour gradient on a texture, with fallbacks for older clients.
local function gradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if type(CreateColor) == "function" and type(tex.SetGradient) == "function" then
        if pcall(tex.SetGradient, tex, orient, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2)) then
            return
        end
    end
    if type(tex.SetGradientAlpha) == "function"
        and pcall(tex.SetGradientAlpha, tex, orient, r1, g1, b1, a1, r2, g2, b2, a2) then
        return
    end
    tex:SetColorTexture((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
end

local function header(str, x, y)
    local fs = text(panel, "GameFontNormal", str, "TOPLEFT", panel, "TOPLEFT", x, y)
    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetSize(220, 1)
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    return fs
end

local function slider(x, y, min, max)
    local s = make("Slider", panel)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(SLIDER_W, SLIDER_H)
    s:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    s:SetMinMaxValues(min, max)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = s:GetThumbTexture()
    if thumb then thumb:SetSize(16, 24) end
    s:EnableMouse(true)
    return s
end

----------------------------------------------------------------------------
-- Colour logic (shared by every colour control)
----------------------------------------------------------------------------

-- Apply an HSV colour from a control: save it, then sync everything.
function Options.SetHSV(h, s, v)
    hsv.h, hsv.s, hsv.v = h % 360, Util.Clamp(s, 0, 1), Util.Clamp(v, 0, 1)
    local hex = Util.RGBToHex(Util.HSVToRGB(hsv.h, hsv.s, hsv.v))
    shownHex = hex -- keep our hue even if the hex alone can't express it
    ns.Config.Set("furColor", hex)
    Options.Refresh()
end

-- Apply typed hex text. Returns true, or false and an error.
function Options.SetHexText(str)
    local hex, err = Util.ParseHex(str)
    if not hex then
        if c.error then c.error:SetText(err); c.error:Show() end
        if c.hex then c.hex:SetText("#" .. ns.db.furColor) end
        return false, err
    end
    if c.error then c.error:Hide() end
    ns.Config.Set("furColor", hex)
    Options.Refresh()
    return true
end

function Options.GetHSV()
    return hsv.h, hsv.s, hsv.v
end

-- Map a cursor position over the square to saturation (x) and value (y).
local function squareFromCursor()
    local scale = c.square:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    local left, bottom = c.square:GetLeft(), c.square:GetBottom()
    local w, h = c.square:GetWidth(), c.square:GetHeight()
    if not (left and bottom) or w <= 0 or h <= 0 then return end
    local s = Util.Clamp((cx / scale - left) / w, 0, 1)
    local v = Util.Clamp((cy / scale - bottom) / h, 0, 1)
    Options.SetHSV(hsv.h, s, v)
end

-- OnUpdate exists only while the mouse button is held on the square.
local function squareDrag() squareFromCursor() end
local function squareDown(self)
    squareFromCursor()
    self:SetScript("OnUpdate", squareDrag)
end
local function squareUp(self) self:SetScript("OnUpdate", nil) end

local function hueChanged(_, value)
    if syncing then return end
    Options.SetHSV(value, hsv.s, hsv.v)
end

local function brightnessChanged(_, value)
    if syncing then return end
    Options.SetHSV(hsv.h, hsv.s, value / 100)
end

local function hexEnter(self)
    Options.SetHexText(self:GetText())
    self:ClearFocus()
end

local function hexEscape(self)
    self:SetText("#" .. ns.db.furColor)
    self:ClearFocus()
end

local function resetColour()
    if c.error then c.error:Hide() end
    ns.Config.Set("furColor", ns.Config.DEFAULTS.furColor)
    Options.Refresh()
end

----------------------------------------------------------------------------
-- Building
----------------------------------------------------------------------------

local function buildColour(x, y)
    header("Bunny Appearance", x, y)

    -- Saturation (x) / brightness (y) square on top of the current hue.
    local sq = make("Frame", panel)
    sq:SetSize(SQUARE, SQUARE)
    sq:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y - 24)
    sq:EnableMouse(true)
    sq:SetScript("OnMouseDown", squareDown)
    sq:SetScript("OnMouseUp", squareUp)
    sq:SetScript("OnHide", squareUp)
    c.square = sq
    c.squareHue = sq:CreateTexture(nil, "BACKGROUND")
    c.squareHue:SetAllPoints(sq)
    local white = sq:CreateTexture(nil, "BORDER")
    white:SetAllPoints(sq)
    gradient(white, "HORIZONTAL", 1, 1, 1, 1, 1, 1, 1, 0)
    local black = sq:CreateTexture(nil, "ARTWORK")
    black:SetAllPoints(sq)
    gradient(black, "VERTICAL", 0, 0, 0, 1, 0, 0, 0, 0)
    local ring = sq:CreateTexture(nil, "OVERLAY", nil, 1)
    ring:SetColorTexture(0, 0, 0, 1)
    ring:SetSize(8, 8)
    local dot = sq:CreateTexture(nil, "OVERLAY", nil, 2)
    dot:SetColorTexture(1, 1, 1, 1)
    dot:SetSize(4, 4)
    dot:SetPoint("CENTER", ring, "CENTER", 0, 0)
    c.marker = ring

    -- Hue: six gradient segments red -> yellow -> green -> cyan -> blue -> magenta -> red.
    local hy = y - 24 - SQUARE - 22
    text(panel, "GameFontHighlightSmall", "Hue", "BOTTOMLEFT", panel, "TOPLEFT", x, hy + 2)
    c.hue = slider(x, hy, 0, 359)
    local stops = { { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 }, { 0, 1, 1 }, { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 } }
    for i = 1, 6 do
        local seg = c.hue:CreateTexture(nil, "BACKGROUND")
        seg:SetSize(SLIDER_W / 6, SLIDER_H - 6)
        seg:SetPoint("LEFT", c.hue, "LEFT", (i - 1) * SLIDER_W / 6, 0)
        local a, b = stops[i], stops[i + 1]
        gradient(seg, "HORIZONTAL", a[1], a[2], a[3], 1, b[1], b[2], b[3], 1)
    end
    c.hue:SetScript("OnValueChanged", hueChanged)

    -- Brightness: black -> fully bright current hue/saturation.
    local by = hy - 30
    text(panel, "GameFontHighlightSmall", "Brightness", "BOTTOMLEFT", panel, "TOPLEFT", x, by + 2)
    c.brightness = slider(x, by, 0, 100)
    c.brightnessBar = c.brightness:CreateTexture(nil, "BACKGROUND")
    c.brightnessBar:SetSize(SLIDER_W, SLIDER_H - 6)
    c.brightnessBar:SetPoint("LEFT", c.brightness, "LEFT", 0, 0)
    c.brightness:SetScript("OnValueChanged", brightnessChanged)

    -- Hex entry, swatch, live bunny preview, reset.
    local ey = by - 36
    text(panel, "GameFontHighlightSmall", "Hex", "TOPLEFT", panel, "TOPLEFT", x, ey - 4)
    local hex = make("EditBox", panel, "InputBoxTemplate")
    hex:SetSize(80, 20)
    hex:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 34, ey)
    hex:SetAutoFocus(false)
    hex:SetMaxLetters(7)
    hex:SetScript("OnEnterPressed", hexEnter)
    hex:SetScript("OnEscapePressed", hexEscape)
    hex:SetScript("OnEditFocusLost", hexEscape)
    c.hex = hex

    local swatch = panel:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(20, 20)
    swatch:SetPoint("LEFT", hex, "RIGHT", 10, 0)
    c.swatch = swatch

    c.error = text(panel, "GameFontRedSmall", "", "TOPLEFT", panel, "TOPLEFT", x, ey - 26)
    c.error:SetWidth(SQUARE + 90)
    c.error:Hide()

    local reset = make("Button", panel, "UIPanelButtonTemplate")
    reset:SetSize(110, 22)
    reset:SetPoint("TOPLEFT", panel, "TOPLEFT", x, ey - 44)
    reset:SetText("Reset Color")
    reset:SetScript("OnClick", resetColour)
    c.reset = reset

    -- Live preview of the actual sprite (tinted like the real bunny).
    local pv = make("Frame", panel)
    pv:SetSize(64, 64)
    pv:SetPoint("TOPLEFT", sq, "TOPRIGHT", 12, 0)
    local layers = ns.Appearance.CreateLayers(pv, "ARTWORK")
    layers[1]:SetAllPoints(pv)
    local idle = ns.Bunny.SHEETS.idle
    ns.Appearance.SetFrame(layers, ns.Appearance.SheetPath(idle.file), 1, idle.slots, false)
    c.preview = pv
end

local function presetClick(self)
    ns.Config.Set("size", self.presetSize)
    Options.Refresh()
end

local function buildSize(x, y)
    header("Bunny Size", x, y)
    c.sizes = {}
    for i, p in ipairs(ns.Config.SIZE_PRESETS) do
        local rb = make("CheckButton", panel, "UIRadioButtonTemplate")
        rb:SetSize(18, 18)
        rb:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y - ROW - (i - 1) * ROW)
        rb.presetSize = p.size
        rb:SetScript("OnClick", presetClick)
        text(panel, "GameFontHighlight", ("%s (%d)"):format(p.label, p.size), "LEFT", rb, "RIGHT", 4, 0)
        c.sizes[i] = rb
    end
    local customY = y - ROW - #ns.Config.SIZE_PRESETS * ROW - 2
    c.customSize = text(panel, "GameFontDisableSmall", "", "TOPLEFT", panel, "TOPLEFT", x, customY)
    return customY - 12 -- bottom of the section (custom label ~12 high)
end

local function earClick(self)
    ns.Config.Set(self.settingKey, self:GetChecked() and true or false)
    Options.Refresh()
end

local function buildPortraits(x, y)
    header("Portrait Accessories", x, y)
    c.ears = {}
    local rows = {
        { key = "earsPlayer", label = "Bunny ears on my portrait" },
        { key = "earsParty", label = "Bunny ears on party portraits" },
    }
    for i, row in ipairs(rows) do
        local cb = make("CheckButton", panel, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", x - 3, y - 20 - (i - 1) * 26)
        cb.settingKey = row.key
        cb:SetScript("OnClick", earClick)
        text(panel, "GameFontHighlight", row.label, "LEFT", cb, "RIGHT", 2, 0)
        c.ears[row.key] = cb
    end
    return y - 20 - #rows * 26
end

-- Future cosmetics: only informational until more than one choice exists,
-- so no selector pretends there is something to choose.
local function buildStyles(x, y)
    header("Styles", x, y)
    local A = ns.Appearance
    local variation = A.CurrentVariation()
    local hat = A.Get("hat", ns.db.hat) or A.Get("hat", "none")
    c.styles = text(panel, "GameFontHighlightSmall",
        ("Style: %s   Hat: %s\nMore bunny styles, hats and accessories are planned."):format(
            variation.label, hat.label),
        "TOPLEFT", panel, "TOPLEFT", x, y - 22)
    c.styles:SetWidth(260)
end

function Options.Build()
    if built or not panel then return end
    built = true
    text(panel, "GameFontNormalLarge", "BunnyBar", "TOPLEFT", panel, "TOPLEFT", 16, -16)
    text(panel, "GameFontHighlightSmall",
        "A tiny pixel-art bunny that lives above your action bar. Changes apply immediately.",
        "TOPLEFT", panel, "TOPLEFT", 16, -40)
    buildColour(16, TOP_Y)
    local L = Options.layout
    L.sizeTop = TOP_Y
    L.sizeBottom = buildSize(RIGHT_X, L.sizeTop)
    L.portraitTop = L.sizeBottom - SECTION_GAP
    L.portraitBottom = buildPortraits(RIGHT_X, L.portraitTop)
    L.stylesTop = L.portraitBottom - SECTION_GAP
    buildStyles(RIGHT_X, L.stylesTop)
end

function Options.IsBuilt()
    return built
end

----------------------------------------------------------------------------
-- Refresh: saved settings -> controls
----------------------------------------------------------------------------

function Options.Refresh()
    if not built or not ns.db then return end
    local db = ns.db
    syncing = true

    -- Re-derive HSV only when the colour was changed elsewhere (slash command,
    -- hex box, reset), so dragging keeps the exact hue the user picked.
    if db.furColor ~= shownHex then
        local _, r, g, b = Util.ParseHex(db.furColor)
        local h, s, v = Util.RGBToHSV(r, g, b)
        if s > 0 and v > 0 then hsv.h = h end -- greys keep the previous hue
        hsv.s, hsv.v = s, v
        shownHex = db.furColor
    end
    local hr, hg, hb = Util.HSVToRGB(hsv.h, 1, 1)
    c.squareHue:SetColorTexture(hr, hg, hb, 1)
    c.marker:ClearAllPoints()
    c.marker:SetPoint("CENTER", c.square, "BOTTOMLEFT", hsv.s * SQUARE, hsv.v * SQUARE)
    c.hue:SetValue(Util.Round(hsv.h) % 360)
    c.brightness:SetValue(Util.Round(hsv.v * 100))
    local fr, fg, fb = Util.HSVToRGB(hsv.h, hsv.s, 1)
    gradient(c.brightnessBar, "HORIZONTAL", 0, 0, 0, 1, fr, fg, fb, 1)
    local _, r, g, b = Util.ParseHex(db.furColor)
    c.swatch:SetColorTexture(r, g, b, 1)
    c.hex:SetText("#" .. db.furColor)

    local preset = ns.Config.PresetForSize(db.size)
    for _, rb in ipairs(c.sizes) do rb:SetChecked(rb.presetSize == db.size) end
    if preset then
        c.customSize:SetText("")
        c.customSize:Hide()
    else
        c.customSize:SetText(("Custom: %d (set with /bunny size)"):format(db.size))
        c.customSize:Show()
    end

    c.ears.earsPlayer:SetChecked(db.earsPlayer)
    c.ears.earsParty:SetChecked(db.earsParty)
    syncing = false
end
