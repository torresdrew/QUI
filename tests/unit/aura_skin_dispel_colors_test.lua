-- tests/unit/aura_skin_dispel_colors_test.lua
-- Task 10: dispel border custom colors (profile-driven). buildButtonArt gains
-- a `container` parameter so it can read container._quiProfile.dispelColors
-- at button-birth time and pass it through to SetAuraBorder's options as
-- customDispelColorMap (68824 CustomAuraButtonBorderOptions.customDispelColorMap).
-- Run: lua tests/unit/aura_skin_dispel_colors_test.lua

local fails = 0
local function check(name, ok, detail)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name .. (detail and ("  " .. detail) or "")) end
end

----------------------------------------------------------------------------
-- Part A: brief's source-text floor (verbatim from task-10-brief.md).
----------------------------------------------------------------------------
local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a"); f:close()
    return (data:gsub("\r\n", "\n"))
end
local skin = readAll("core/aura_skin.lua")
assert(skin:find("customDispelColorMap", 1, true),
    "buildButtonArt must pass customDispelColorMap when profile provides dispelColors")
local glue = readAll("core/aura_glue.lua")
assert(glue:find("dispelColors", 1, true),
    "ElementProfile whitelist must map dispelColors (passthrough pin)")
print("OK aura_skin_dispel_colors_test (source-text floor)")

----------------------------------------------------------------------------
-- Part B: behavioral harness (mirrors tests/unit/
-- aura_skin_button_enumeration_test.lua's stub pattern). Drives
-- MakeInitializer's initializer through the REAL call site
-- (AuraSkin.Configure -> AddAuraGroup -> initializeFrame -> buildButtonArt)
-- against a stub button + container, proving customDispelColorMap actually
-- reaches SetAuraBorder's options table -- present when the profile carries
-- a dispelColors table, absent (not merely falsy) when it doesn't -- not
-- just that the source text mentions the field somewhere.
----------------------------------------------------------------------------
_G.InCombatLockdown = function() return false end
_G.AuraContainerSortMethod = { Default = 1 }
_G.AuraContainerSortDirection = { Normal = 1 }
_G.AnchorUtil = { FlowDirection = { Left = -1, Right = 1, Up = 1, Down = -1 }, FlowLayoutAxis = { Horizontal = 0, Vertical = 1 } }

local function Stub()
    local t = {}
    function t:SetAllPoints() end
    function t:SetPoint() end
    function t:ClearAllPoints() end
    function t:SetColorTexture() end
    function t:SetTexCoord() end
    function t:DisablePixelSnap() end
    function t:SetTextColor() end
    function t:SetAlpha() end
    function t:SetFont() end
    function t:SetHideCountdownNumbers() end
    function t:SetDrawSwipe() end
    function t:SetReverse() end
    function t:SetText() end
    function t:CreateTexture() return Stub() end
    function t:CreateFontString() return Stub() end
    return t
end
_G.CreateFrame = function() return Stub() end

-- Extends the established MakeButton pattern (aura_skin_button_enumeration_
-- test.lua) with a RECORDING SetAuraBorder -- that suite's stub discards its
-- options argument; this test needs to inspect it.
local function MakeButton(name)
    local b = Stub()
    b._name = name
    b._auraBorderOpts = nil
    function b:SetCancelAuraButtons() end
    function b:SetSize() end
    function b:SetIcon() end
    function b:SetAuraBorder(_dispel, opts) b._auraBorderOpts = opts end
    function b:SetAuraSymbol() end
    function b:SetDurationCooldown() end
    function b:SetDurationText() end
    function b:SetApplicationCount() end
    return b
end

-- Minimal fake container: one group, births a single button synchronously
-- through the real MakeInitializer closure (same shape as
-- MakeIncapableContainer in the enumeration test) and stashes it for
-- inspection.
local function MakeContainer()
    local c = { _addCalls = {}, _registeredKeys = {} }
    function c:HasAuraGroup(key) return self._registeredKeys[key] == true end
    function c:AddAuraGroup(key, filter, opts)
        c._addCalls[#c._addCalls + 1] = { key = key, filter = filter }
        c._registeredKeys[key] = true
        c._birthedButton = MakeButton(key .. "#1")
        opts.initializeFrame(c._birthedButton)
    end
    function c:SetAuraGroupMaxFrameCount() end
    function c:SetAuraGroupSortMethod() end
    function c:SetAuraGroupCandidateFilters() end
    function c:SetAuraGroupLayout() end
    function c:SetFlowLayoutAnchorPoint() end
    function c:SetFlowLayoutGrowthDirection() end
    function c:SetFlowLayoutPadding() end
    function c:SetFlowLayoutAxis() end
    function c:SetFlowLayoutMaximumLineSize() end
    return c
end

local ns = {}
assert(loadfile("core/aura_theme.lua"))("QUI", ns)
assert(loadfile("core/aura_skin.lua"))("QUI", ns)
assert(loadfile("core/aura_elements.lua"))("QUI", ns)
local AuraSkin = ns.Addon.AuraSkin
check("core/aura_skin.lua publishes ns.Addon.AuraSkin", AuraSkin ~= nil)

----------------------------------------------------------------------------
-- (1) Profile carries dispelColors: the birthed button's SetAuraBorder
-- options must carry customDispelColorMap == the SAME table (buildButtonArt
-- passes the profile's table straight through -- SetAuraBorder itself
-- securecopies it, not QUI -- so identity, not a deep copy, is expected
-- here).
----------------------------------------------------------------------------
local withColors = MakeContainer()
local dispelMap = { SILENCE = { r = 1, g = 0, b = 0 } }
local profileWithColors = { iconSize = 20, dispelColors = dispelMap }
AuraSkin.Configure(withColors, profileWithColors,
    { { key = "s1", filter = "HARMFUL", maxFrameCount = 5 } })

local btn1 = withColors._birthedButton
check("button born", btn1 ~= nil)
if btn1 then
    check("SetAuraBorder options carry customDispelColorMap when profile has dispelColors",
        btn1._auraBorderOpts ~= nil and btn1._auraBorderOpts.customDispelColorMap == dispelMap,
        btn1._auraBorderOpts and tostring(btn1._auraBorderOpts.customDispelColorMap))
    check("customDispelColorMap does not clobber the style/showWhen fields",
        btn1._auraBorderOpts.style == 3 and btn1._auraBorderOpts.showWhenHarmful == true
            and btn1._auraBorderOpts.showWhenHelpful == false)
end

----------------------------------------------------------------------------
-- (2) Profile carries NO dispelColors: the key must be entirely ABSENT
-- (nil), not merely falsy -- guards against a stray unconditional
-- `customDispelColorMap = nil` field write, which is indistinguishable from
-- "not present" only at the value level, not the intent level.
----------------------------------------------------------------------------
local noColors = MakeContainer()
local profileNoColors = { iconSize = 20 }
AuraSkin.Configure(noColors, profileNoColors,
    { { key = "s1", filter = "HARMFUL", maxFrameCount = 5 } })

local btn2 = noColors._birthedButton
check("second button born", btn2 ~= nil)
if btn2 then
    check("SetAuraBorder options omit customDispelColorMap when profile has no dispelColors",
        btn2._auraBorderOpts ~= nil and btn2._auraBorderOpts.customDispelColorMap == nil,
        btn2._auraBorderOpts and tostring(btn2._auraBorderOpts.customDispelColorMap))
end

----------------------------------------------------------------------------
-- (3) Non-table dispelColors (defensive: a stray non-table value on the
-- profile field) must NOT be passed through -- proves buildButtonArt's own
-- type(prof.dispelColors) == "table" guard, not just presence-checking.
----------------------------------------------------------------------------
local badColors = MakeContainer()
local profileBadColors = { iconSize = 20, dispelColors = "not-a-table" }
AuraSkin.Configure(badColors, profileBadColors,
    { { key = "s1", filter = "HARMFUL", maxFrameCount = 5 } })

local btn3 = badColors._birthedButton
check("third button born", btn3 ~= nil)
if btn3 then
    check("non-table dispelColors is not passed through as customDispelColorMap",
        btn3._auraBorderOpts ~= nil and btn3._auraBorderOpts.customDispelColorMap == nil,
        btn3._auraBorderOpts and tostring(btn3._auraBorderOpts.customDispelColorMap))
end

if fails > 0 then error(fails .. " failure(s) in aura_skin_dispel_colors_test") end
print("OK: aura_skin_dispel_colors_test (all checks passed)")
