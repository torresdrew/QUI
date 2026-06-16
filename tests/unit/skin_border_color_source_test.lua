-- tests/unit/skin_border_color_source_test.lua
-- Verifies Helpers.GetSkinBorderColor resolves the global border color from the
-- skinBorderColorSource enum: "theme" -> accent fallback, "class" -> class color,
-- "custom" -> stored color (or accent if the stored color is nil). Also covers the
-- legacy skinBorderUseClassColor back-compat read and the hideSkinBorders alpha=0.
-- Run: lua tests/unit/skin_border_color_source_test.lua

local env = dofile("tools/_addon_env.lua")
local ns = env.LoadCore()          -- loads core/utils.lua -> ns.Helpers
local Helpers = ns.Helpers

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end
local function approx(a, b) return math.abs((a or -1) - (b or -2)) < 1e-6 end

-- Theme/accent color the resolver should fall back to:
-- GetSkinBorderColor -> GetSkinAccentColor -> GetSkinColors -> _G.QUI:GetSkinColor().
-- LoadCore already created _G.QUI; just attach the stub method.
local THEME = { 0.78, 0.19, 0.19 }  -- Horde-ish red
_G.QUI.GetSkinColor = function() return THEME[1], THEME[2], THEME[3], 1 end

-- The harness UnitClass() stub returns "MAGE"; give MAGE a class color so
-- Helpers.GetPlayerClassColor() resolves to a known value.
_G.RAID_CLASS_COLORS = { MAGE = { r = 0.41, g = 0.80, b = 0.94 } }
_G.CUSTOM_CLASS_COLORS = nil

-- Plain profile table (NOT AceDB) so unset keys read as real nil rather than
-- metatable defaults. Point Helpers.GetProfile at it.
local profile = { general = {} }
Helpers.GetProfile = function() return profile end
local general = profile.general

-- theme -> accent fallback
general.skinBorderColorSource = "theme"
do
    local r, g, b = Helpers.GetSkinBorderColor()
    check("theme source returns accent/theme color",
        approx(r, THEME[1]) and approx(g, THEME[2]) and approx(b, THEME[3]),
        ("got %s,%s,%s"):format(r, g, b))
end

-- class -> class color
general.skinBorderColorSource = "class"
do
    local r, g, b = Helpers.GetSkinBorderColor()
    check("class source returns class color",
        approx(r, 0.41) and approx(g, 0.80) and approx(b, 0.94),
        ("got %s,%s,%s"):format(r, g, b))
end

-- custom + color table -> that color
general.skinBorderColorSource = "custom"
general.skinBorderColor = { 0.1, 0.2, 0.3, 1 }
do
    local r, g, b = Helpers.GetSkinBorderColor()
    check("custom source returns stored color",
        approx(r, 0.1) and approx(g, 0.2) and approx(b, 0.3),
        ("got %s,%s,%s"):format(r, g, b))
end

-- custom + nil color -> falls back to theme, no crash
general.skinBorderColorSource = "custom"
general.skinBorderColor = nil
do
    local ok, r, g, b = pcall(Helpers.GetSkinBorderColor)
    check("custom source with nil color falls back to theme without error",
        ok and approx(r, THEME[1]) and approx(g, THEME[2]) and approx(b, THEME[3]),
        ("ok=%s got %s,%s,%s"):format(tostring(ok), r, g, b))
end

-- legacy read: no source key but skinBorderUseClassColor=true -> class
general.skinBorderColorSource = nil
general.skinBorderColor = nil
general.skinBorderUseClassColor = true
do
    local r, g, b = Helpers.GetSkinBorderColor()
    check("legacy skinBorderUseClassColor=true resolves to class",
        approx(r, 0.41) and approx(g, 0.80) and approx(b, 0.94),
        ("got %s,%s,%s"):format(r, g, b))
end

-- hideSkinBorders forces alpha 0 regardless of source
general.skinBorderColorSource = "theme"
general.skinBorderUseClassColor = nil
general.hideSkinBorders = true
do
    local _, _, _, a = Helpers.GetSkinBorderColor()
    check("hideSkinBorders forces alpha 0", approx(a, 0), ("got a=%s"):format(a))
end

print(("\n%d failure(s)"):format(failures))
os.exit(failures == 0 and 0 or 1)
