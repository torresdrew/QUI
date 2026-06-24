-- tests/unit/skinbase_apply_button_fonts_badself_test.lua
-- Run: lua tests/unit/skinbase_apply_button_fonts_badself_test.lua
--
-- ApplyButtonFontObjectsDeep walks a skinned frame's whole child tree to drive
-- button font OBJECTS. In 12.x GetChildren() can surface a descendant whose
-- widget method table is reachable via __index (so `frame.GetObjectType` is
-- truthy) but which has no valid widget handle, so `frame:GetObjectType()`
-- raises "calling 'GetObjectType' on bad self". Repro from the wild: skinning
-- TradeFrame walks into TradePlayerInputMoneyFrame (TradeFrame.xml:449) and the
-- unguarded probe crashed the whole SkinWindow pass.
--
-- The walker must be as defensive as its siblings (SkinFrameText /
-- LockFrameTextObjects): run SafeWalkSkip first and guard the type probe so a
-- bad-self / restricted node is skipped, not fatal.
-- luacheck: globals STANDARD_TEXT_FONT

STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"

local ns = {
    Helpers = {
        CHROME = { BORDER_PX = 1, BG_FALLBACK = { 0.05, 0.05, 0.05, 0.95 }, BORDER_FALLBACK = { 0, 0, 0, 1 }, BUTTON_BOOST = 0.07, SCROLLROW_BOOST = 0.03, DEPTH = { PANEL = { boost = 0, alpha = 0.95 }, SUBPANEL = { boost = 0.04, alpha = 0.85 }, ROW = { boost = 0.07, alpha = 0.75 } } },
        CreateStateTable = function()
            local tbl = setmetatable({}, { __mode = "k" })
            local function get(key) local s = tbl[key]; if not s then s = {}; tbl[key] = s end; return s end
            return tbl, get
        end,
        GetCore = function() return { GetPixelSize = function() return 0.5 end } end,
        SafeToNumber = function(v, d) return tonumber(v) or d end,
        GetSkinBorderColor = function() return 0.6, 0.7, 0.8, 1 end,
        GetSkinBgColorWithOverride = function() return 0.1, 0.2, 0.3, 0.9 end,
        GetSkinBarColor = function() return 0.5, 0.55, 0.6, 1 end,
        GetGeneralFont = function() return "Interface\\QUIFont.ttf" end,
        GetGeneralFontOutline = function() return "OUTLINE" end,
    },
    UIKit = { RegisterScaleRefresh = function() end },
}

assert(loadfile("core/uikit.lua"))("QUI", ns)
local SkinBase = ns.SkinBase

-- Spy the terminal verb so we can assert real buttons are still driven.
local driven = {}
SkinBase.ApplyButtonFontObjects = function(btn) driven[btn] = true end

local function NewFontString()
    return { SetFont = function() end }
end

-- A widget whose method table is reachable but whose self is invalid: any
-- widget-method call raises the engine's "bad self" error.
local function NewBadSelfFrame(name)
    local bad = { name = name }
    bad.GetObjectType = function() error("calling 'GetObjectType' on bad self") end
    bad.GetChildren = function() error("calling 'GetChildren' on bad self") end
    bad.GetFontString = function() error("calling 'GetFontString' on bad self") end
    return bad
end

local function NewButton(name)
    local fs = NewFontString()
    return {
        name = name,
        GetObjectType = function() return "Button" end,
        GetFontString = function() return fs end,
        GetChildren = function() end,
    }
end

-- Parent frame holding a real button AND a bad-self descendant side by side.
local badChild = NewBadSelfFrame("TradePlayerInputMoneyFrame")
local goodButton = NewButton("OkayButton")
local parent = {
    name = "TradeFrame",
    GetObjectType = function() return "Frame" end,
    GetChildren = function() return goodButton, badChild end,
}

local ok, err = pcall(SkinBase.ApplyButtonFontObjectsDeep, parent, 4)
assert(ok, "ApplyButtonFontObjectsDeep must not propagate a bad-self widget error: " .. tostring(err))
assert(driven[goodButton], "real button alongside a bad-self sibling must still be driven")

-- A bad-self node passed directly (as the top frame) must also be survived.
local ok2, err2 = pcall(SkinBase.ApplyButtonFontObjectsDeep, NewBadSelfFrame("Direct"), 4)
assert(ok2, "bad-self frame as the walk root must not crash: " .. tostring(err2))

print("ok skinbase_apply_button_fonts_badself")
