-- BunnyBar: appearance registry and layered, recolourable sprites.
--
-- Every sprite texture holds two layers of the same frames, stacked
-- vertically (see scripts/generate_sprites.py):
--   top half    fur only, normalised to white  -> tinted with the fur colour
--   bottom half outline, eyes, nose, inner ears -> drawn untinted on top
-- So recolouring is one SetVertexColor on the fur layer: eyes, nose, inner
-- ears, outlines, transparency and shading are preserved, nothing is
-- generated at runtime, and nearest-neighbour filtering is kept.
--
-- Extensibility: variations (alternate sprite sets / fur patterns) and hats
-- are registries. Movement and animation timing (Animation.lua) only ask
-- this module to show "sheet X, frame N" and never know about cosmetics.

local addonName, ns = ...
local Util = ns.Util

local Appearance = {}
ns.Appearance = Appearance

Appearance.TEXTURE_PATH = "Interface\\AddOns\\" .. addonName .. "\\Textures\\"

-- Layers inside every sheet texture, bottom-most first.
Appearance.LAYERS = {
    { key = "fur",    top = 0,   bottom = 0.5, tinted = true,  sublevel = 0 },
    { key = "detail", top = 0.5, bottom = 1,   tinted = false, sublevel = 1 },
}

----------------------------------------------------------------------------
-- Registries
----------------------------------------------------------------------------

local registry = { variation = {}, hat = {} }
local ordered = { variation = {}, hat = {} }

-- Register a cosmetic. kind = "variation" or "hat".
--   variation: { label, path, defaultFur }
--       path       = folder holding this style's copy of every sheet
--       defaultFur = suggested fur colour (used when the player hasn't
--                    picked their own, see Config.SetStyle)
--   hat:       { label, ... }      future: own sheet + anchor, tint key
function Appearance.Register(kind, id, def)
    assert(registry[kind], "unknown appearance kind")
    def.id = id
    if not registry[kind][id] then table.insert(ordered[kind], def) end
    registry[kind][id] = def
    return def
end

function Appearance.IsValid(kind, id)
    return type(id) == "string" and registry[kind] ~= nil and registry[kind][id] ~= nil
end

function Appearance.Get(kind, id)
    return registry[kind] and registry[kind][id]
end

-- Ordered list of registered definitions (used to decide whether a
-- selector is worth showing at all).
function Appearance.List(kind)
    return ordered[kind]
end

-- Styles ("variations"). Every style has the same sheets and frames, drawn
-- from shared pose data by scripts/generate_sprites.py; only the extras
-- differ (horns, halo, wings, tails, patches). Classic keeps the original
-- folder so v0.2 paths stay valid.
local P = Appearance.TEXTURE_PATH
Appearance.Register("variation", "classic", { label = "Classic", path = P, defaultFur = "F6F3FA" })
Appearance.Register("variation", "devil", { label = "Devil", path = P .. "devil\\", defaultFur = "E06E7C" })
Appearance.Register("variation", "angel", { label = "Angel", path = P .. "angel\\", defaultFur = "FFF6E6" })
Appearance.Register("variation", "dragon", { label = "Dragon", path = P .. "dragon\\", defaultFur = "86C784" })
Appearance.Register("variation", "zombie", { label = "Zombie", path = P .. "zombie\\", defaultFur = "A9C4A2" })
Appearance.Register("hat", "none", { label = "None" })

function Appearance.CurrentVariation()
    local db = ns.db
    return registry.variation[db and db.variation] or registry.variation.classic
end

function Appearance.SheetPath(fileName)
    return Appearance.CurrentVariation().path .. fileName
end

----------------------------------------------------------------------------
-- Colour
----------------------------------------------------------------------------

local DEFAULT_HEX = "F6F3FA"

-- Current fur colour as r, g, b (0..1): the custom override, else the
-- selected style's own default (Config.FurColor).
function Appearance.FurRGB()
    local current = ns.Config and ns.Config.FurColor() or DEFAULT_HEX
    local hex, r, g, b = Util.ParseHex(current)
    if not hex then
        local _
        _, r, g, b = Util.ParseHex(DEFAULT_HEX)
    end
    return r, g, b
end

local furTextures = {} -- every tinted fur layer we created

local function tint(tex)
    local r, g, b = Appearance.FurRGB()
    tex:SetVertexColor(r, g, b, 1)
end

----------------------------------------------------------------------------
-- Layered sprites
----------------------------------------------------------------------------

local shownFile = {} -- texture -> file currently set

-- Create the stacked layer textures on `frame`. Position and size the first
-- one; the others follow it. Returns the array of textures.
function Appearance.CreateLayers(frame, drawLayer)
    local list = {}
    for i, layer in ipairs(Appearance.LAYERS) do
        local tex = frame:CreateTexture(nil, drawLayer or "ARTWORK", nil, layer.sublevel)
        list[i] = tex
        if i > 1 then tex:SetAllPoints(list[1]) end
        if layer.tinted then
            furTextures[#furTextures + 1] = tex
            tint(tex)
        end
    end
    return list
end

-- Show frame `slot` (1-based) of a sheet with `slots` frame columns on every
-- layer, optionally mirrored horizontally. `path` is the full texture path.
function Appearance.SetFrame(list, path, slot, slots, mirror)
    local left, right = (slot - 1) / slots, slot / slots
    if mirror then left, right = right, left end
    for i, layer in ipairs(Appearance.LAYERS) do
        local tex = list[i]
        if shownFile[tex] ~= path then
            tex:SetTexture(path, "CLAMP", "CLAMP", "NEAREST")
            shownFile[tex] = path
            if layer.tinted then tint(tex) end -- in case SetTexture reset it
        end
        tex:SetTexCoord(left, right, layer.top, layer.bottom)
    end
end

-- Re-apply colours (and, via the bunny, sheet paths) after a change.
function Appearance.Apply()
    for i = 1, #furTextures do tint(furTextures[i]) end
    if ns.Bunny and ns.Bunny.RefreshAppearance then ns.Bunny:RefreshAppearance() end
end
