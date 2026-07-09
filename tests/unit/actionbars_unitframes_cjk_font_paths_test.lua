-- tests/unit/actionbars_unitframes_cjk_font_paths_test.lua
-- Run: lua tests/unit/actionbars_unitframes_cjk_font_paths_test.lua
--
-- Guards non-skinning text paths from bypassing the CJK/font-family wrapper.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function assertContains(text, needle, reason)
    assert(text:find(needle, 1, true), reason)
end

local function assertAbsent(text, needle, reason)
    assert(not text:find(needle, 1, true), reason)
end

-- The dedicated private-aura anchor subsystem (which recursively re-styled
-- Blizzard-rendered Count/Duration FontStrings via CJKFont) is fully removed:
-- 12.1 AuraContainers render private auras natively. Lock that removal in.
local buffborders = readFile("QUI_ActionBars/actionbars/buffborders.lua")
assertAbsent(buffborders, "pcall(region.SetFont, region, font, fontSize, outline)",
    "buff border child FontStrings must not bypass the CJK fallback wrapper")
assertAbsent(buffborders, "pcall(cdText.SetFont, cdText, font, fontSize, outline)",
    "buff border cooldown FontStrings must not bypass the CJK fallback wrapper")
assertAbsent(buffborders, "pcall(CJKFont, region, font, fontSize, outline)",
    "the dedicated private-aura anchor text styling path must not be reintroduced")
assertAbsent(buffborders, "pcall(CJKFont, cdText, font, fontSize, outline)",
    "the dedicated private-aura anchor cooldown text styling path must not be reintroduced")

-- The surviving buff/debuff icon + temp-enchant-strip stack-count text must
-- still route through the CJK fallback wrapper.
assertContains(buffborders, "CJKFont(icon.Stacks, font, fontSize, outline)",
    "buff/debuff preview icon stack text must route through CJKFont")
assertAbsent(buffborders, "icon.Stacks:SetFont(font, fontSize, outline)",
    "buff/debuff preview icon stack text must not bypass the CJK fallback wrapper")

local castbar = readFile("QUI_UnitFrames/unitframes/castbar.lua")
assertAbsent(castbar, "pcall(probe.SetFont, probe, safeFontPath, safeFontSize, safeFontFlags)",
    "castbar reserve probe must not bypass CJK fallback when measuring")
assertContains(castbar, "nsHelpers.ApplyFontWithFallback, probe, safeFontPath, safeFontSize, safeFontFlags",
    "castbar reserve probe must use CJK fallback when available")

print("OK: actionbars_unitframes_cjk_font_paths_test")
