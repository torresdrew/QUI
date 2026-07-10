-- tests/unit/nameplates_aura_filters_test.lua
-- Run: lua tests/unit/nameplates_aura_filters_test.lua
--
-- The aura filter model's pure functions (plans/009-nameplates.md):
-- server-side filter-string composition, allow/block/important resolution
-- from clean spellIDs, and per-context enables.

local function fail(msg)
    print("FAIL: nameplates_aura_filters_test - " .. msg)
    os.exit(1)
end

local ns = { Helpers = { IsSecretValue = function() return false end } }
assert(loadfile("QUI_Nameplates/nameplates/shared.lua"))("QUI_Nameplates", ns)
-- plate_auras needs UIKit/Addon only for rendering paths; stub minimal.
ns.UIKit = { CreateIcon = function() return {} end, CreateText = function() return {} end,
    ResolveFontPath = function() return "" end, UpdateIconLayout = function() end }
ns.Addon = { Pixels = function(_, v) return v end, SetPixelPerfectSize = function() end,
    ApplyFont = function() end }
CreateFrame = function()
    local f = { SetScript = function() end, Hide = function() end, Show = function() end,
        SetSize = function() end, SetPoint = function() end, ClearAllPoints = function() end,
        SetAllPoints = function() end, SetFrameLevel = function() end,
        GetFrameLevel = function() return 1 end, CreateTexture = function() return {
            SetPoint = function() end, SetColorTexture = function() end, SetAlpha = function() end,
            SetAllPoints = function() end } end,
        SetDrawEdge = function() end, SetHideCountdownNumbers = function() end }
    return f
end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
C_Timer = { NewTicker = function() return { Cancel = function() end } end, After = function() end }

assert(loadfile("QUI_Nameplates/nameplates/plate_auras.lua"))("QUI_Nameplates", ns)
local Auras = ns.QUI_Nameplates.Auras
if not Auras then fail("NP.Auras not exported") end

---------------------------------------------------------------------------
-- ComposeFilter
---------------------------------------------------------------------------
local function eq(a, b, label)
    if a ~= b then fail(label .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end
end

eq(Auras.ComposeFilter("debuffs", { mineOnly = true }), "HARMFUL|INCLUDE_NAME_PLATE_ONLY|PLAYER", "debuffs mine-only")
eq(Auras.ComposeFilter("debuffs", { mineOnly = false }), "HARMFUL|INCLUDE_NAME_PLATE_ONLY", "debuffs all-source")
eq(Auras.ComposeFilter("debuffs", {}), "HARMFUL|INCLUDE_NAME_PLATE_ONLY|PLAYER", "debuffs default is mine-only")
eq(Auras.ComposeFilter("buffs", {}), "HELPFUL|INCLUDE_NAME_PLATE_ONLY", "buffs")
eq(Auras.ComposeFilter("cc", { mineOnly = true }), "HARMFUL|CROWD_CONTROL", "cc ignores mine-only")
eq(Auras.ComposeFilter("bogus", {}), nil, "unknown channel")

---------------------------------------------------------------------------
-- ResolveSpellLists
---------------------------------------------------------------------------
local important = { [589] = true }

-- block beats everything
eq(Auras.ResolveSpellLists(589, { blockList = { [589] = true } }, important), "block", "block wins")
-- allow list present: membership required
local allowCh = { allowList = { [116] = true } }
eq(Auras.ResolveSpellLists(116, allowCh, nil), "allow", "allow member")
eq(Auras.ResolveSpellLists(589, allowCh, nil), "excluded", "allow non-member excluded")
eq(Auras.ResolveSpellLists(116, { allowList = { [116] = true } }, { [116] = true }), "important", "allow + important")
-- no lists: important or default
eq(Auras.ResolveSpellLists(589, {}, important), "important", "important emphasis")
eq(Auras.ResolveSpellLists(116, {}, important), "default", "default")
-- secret/nil spellId never touches tables
eq(Auras.ResolveSpellLists(nil, { blockList = { [589] = true } }, important), "default", "nil spellId is default")
eq(Auras.ResolveSpellLists("x", {}, important), "default", "non-number spellId is default")
-- empty allow list table does NOT lock out everything
eq(Auras.ResolveSpellLists(589, { allowList = {} }, nil), "default", "empty allow list ignored")

---------------------------------------------------------------------------
-- IsContextEnabled
---------------------------------------------------------------------------
local s = { enableWorld = true, enableDungeon = false, enableRaid = true }
eq(Auras.IsContextEnabled(s, "world"), true, "world on")
eq(Auras.IsContextEnabled(s, "dungeon"), false, "dungeon off")
eq(Auras.IsContextEnabled(s, "raid"), true, "raid on")
eq(Auras.IsContextEnabled({}, "world"), true, "defaults all-on")
eq(Auras.IsContextEnabled({}, "raid"), true, "defaults all-on raid")

print("OK: nameplates_aura_filters_test")
