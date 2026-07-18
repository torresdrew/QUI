local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Theme core: accent palette + preset resolution, available AT LOGIN.
--
-- QUI_Options is LoadOnDemand; runtime consumers outside the options panel
-- (core/main.lua login accent apply, layout mode, info bar drag-reorder,
-- datatext providers) read QUI.GUI.Colors / ResolveThemePreset /
-- ApplyAccentColor before the panel ever opens. This file pre-creates
-- QUI.GUI with that surface; QUI_Options/framework.lua merges into the
-- same table on load (its `GUI.Colors = GUI.Colors or {...}` literals stay
-- as fallbacks for the headless generator harness, which loads framework
-- without core) and overrides ApplyAccentColor with the widget-repainting
-- version. Color values here must match framework.lua's fallbacks.
---------------------------------------------------------------------------

QUI = QUI or {}
QUI.GUI = QUI.GUI or {}
local GUI = QUI.GUI

GUI.Colors = GUI.Colors or {
    -- Backgrounds
    bg = {0.051, 0.067, 0.09, 0.97},          -- #0d1117 deep dark
    bgLight = {0.094, 0.11, 0.14, 1},         -- slightly lighter for inactive tabs
    bgDark = {0.03, 0.04, 0.06, 1},
    bgContent = {1, 1, 1, 0.02},              -- card surface (white 2% alpha)
    bgSidebar = {0, 0, 0, 0.25},              -- sidebar panel background
    bgFooter = {0, 0, 0, 0.15},               -- footer bar surface

    -- Accent colors (Mint - derived from ApplyAccentColor)
    accent = {0.204, 0.827, 0.6, 1},          -- #34D399 Soft Mint
    accentLight = {0.431, 0.906, 0.718, 1},
    accentDark = {0.1, 0.5, 0.35, 1},
    accentHover = {0.3, 0.9, 0.65, 1},
    accentFaint = {0.204, 0.827, 0.6, 0.07},  -- active tile bg
    accentGlow = {0.204, 0.827, 0.6, 0.06},   -- content-area radial gradient

    -- Tab colors
    tabSelected = {0.204, 0.827, 0.6, 1},
    tabSelectedText = {1, 1, 1, 1},
    tabNormal = {1, 1, 1, 0.55},
    tabHover = {1, 1, 1, 0.85},

    -- Text colors
    text = {1, 1, 1, 1},
    textBright = {1, 1, 1, 1},
    textMuted = {1, 1, 1, 0.45},
    textDim = {1, 1, 1, 0.6},
    sectionLabel = {1, 1, 1, 0.42},

    -- Borders
    border = {1, 1, 1, 0.06},
    borderStrong = {1, 1, 1, 0.1},
    borderAccent = {0.204, 0.827, 0.6, 1},

    -- Section headers (legacy key kept for compat)
    sectionHeader = {0.431, 0.906, 0.718, 1},   -- legacy V1 section header (lighter mint) — alpha 1 required by CreateSectionHeader

    -- Slider colors
    sliderTrack = {1, 1, 1, 0.12},
    sliderThumb = {1, 1, 1, 1},
    sliderThumbBorder = {0, 0, 0, 0.2},

    -- Toggle switch colors
    toggleOff = {1, 1, 1, 0.12},
    toggleThumb = {1, 1, 1, 1},

    -- Warning/secondary accent
    warning = {0.961, 0.620, 0.043, 1},
}

GUI.ThemePresets = GUI.ThemePresets or {
    { name = "Sky Blue",     color = {0.376, 0.647, 0.980} },
    { name = "Classic Mint", color = {0.204, 0.827, 0.600} },
    { name = "Horde",        color = {0.780, 0.192, 0.192} },
    { name = "Alliance",     color = {0.267, 0.467, 0.800} },
    { name = "Midnight",     color = {0.580, 0.490, 0.890} },
    { name = "Amber",        color = {0.961, 0.620, 0.043} },
    { name = "Rose",         color = {0.914, 0.349, 0.518} },
    { name = "Emerald",      color = {0.196, 0.804, 0.494} },
}
-- Computed presets (not in the table — handled by name):
-- "Class Colored"  — uses RAID_CLASS_COLORS for the player's class
-- "Faction Auto"   — Horde or Alliance based on player faction
-- "Custom"         — user picks via color picker (stored in addonAccentColor)

--- Resolve a theme preset name to RGB values.
--- @param presetName string
--- @return number r, number g, number b
function GUI:ResolveThemePreset(presetName)
    -- Static presets
    for _, preset in ipairs(self.ThemePresets or {}) do
        if preset.name == presetName then
            return preset.color[1], preset.color[2], preset.color[3]
        end
    end
    -- Dynamic presets
    if presetName == "Class Colored" then
        local _, class = UnitClass("player")
        local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if color then return color.r, color.g, color.b end
        return 0.376, 0.647, 0.980
    end
    if presetName == "Faction Auto" then
        local faction = UnitFactionGroup("player")
        if faction == "Horde" then return 0.780, 0.192, 0.192 end
        return 0.267, 0.467, 0.800
    end
    if presetName == "Custom" then
        local db = QUI.QUICore and QUI.QUICore.db and QUI.QUICore.db.profile
        local c = db and db.general and db.general.addonAccentColor
        if c then return c[1], c[2], c[3] end
    end
    -- Fallback
    return 0.376, 0.647, 0.980
end

-- Login-capable accent derivation: identical color math to framework.lua's
-- ApplyAccentColor, WITHOUT the options-widget repaint (RefreshCachedColors
-- and widget walks are framework-local). framework.lua overrides this method
-- when QUI_Options loads; its cached color components are read from these
-- Colors tables at framework load time, so the pre-load derivation carries
-- over correctly.
function GUI:ApplyAccentColor(r, g, b)
    local function lerp(a, b2, t) return a + (b2 - a) * t end
    local C = self.Colors
    -- Update in-place to preserve existing table references
    C.accent[1], C.accent[2], C.accent[3], C.accent[4] = r, g, b, 1
    C.accentFaint[1], C.accentFaint[2], C.accentFaint[3] = r, g, b
    C.accentGlow[1], C.accentGlow[2], C.accentGlow[3] = r, g, b
    C.accentLight[1] = lerp(r, 1, 0.3)
    C.accentLight[2] = lerp(g, 1, 0.3)
    C.accentLight[3] = lerp(b, 1, 0.3)
    C.accentLight[4] = 1
    C.accentDark[1], C.accentDark[2], C.accentDark[3], C.accentDark[4] = r * 0.5, g * 0.5, b * 0.5, 1
    C.accentHover[1] = lerp(r, 1, 0.15)
    C.accentHover[2] = lerp(g, 1, 0.15)
    C.accentHover[3] = lerp(b, 1, 0.15)
    C.accentHover[4] = 1
    C.tabSelected[1], C.tabSelected[2], C.tabSelected[3] = r, g, b
    C.borderAccent[1], C.borderAccent[2], C.borderAccent[3] = r, g, b
    C.sectionHeader[1], C.sectionHeader[2], C.sectionHeader[3] = C.accentLight[1], C.accentLight[2], C.accentLight[3]
end
