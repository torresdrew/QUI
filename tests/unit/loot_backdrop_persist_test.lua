-- tests/unit/loot_backdrop_persist_test.lua
-- Run: lua tests/unit/loot_backdrop_persist_test.lua
--
-- Regression guard for the "loot/roll window shows the correct bg color but then
-- turns white" bug.
--
-- Root cause: SkinBase.ApplyPixelBackdrop registers the frame for scale refreshes.
-- When one fires (a pop-up itself queues one by creating its pixel borders),
-- RefreshPixelBackdrop rebuilds the backdrop via SetBackdrop -- which resets the
-- backdrop textures to white -- and only re-applies a color it can find in
-- data.bgColor or the frame's _quiBg*/_quiBorder* backup fields. A bare
-- frame:SetBackdropColor() never populates those, so the rebuild drops the color
-- and the frame goes white.
--
-- The fix routes loot.lua's color writes through Helpers.SetFrameBackdropColor /
-- Helpers.SetFrameBackdropBorderColor (core/utils.lua), which set the live color
-- AND record _quiBg*/_quiBorder* so the rebuild preserves it. This test exercises
-- the real SkinBase rebuild path to prove that contract.

-- luacheck: globals CreateFrame

-- A frame whose backdrop API mirrors WoW: SetBackdrop recreates the backdrop
-- textures and resets their color to white until SetBackdrop*Color is called.
local function NewBackdropFrame()
    local f = { frameLevel = 4 }
    function f:GetFrameLevel() return self.frameLevel end
    function f:SetFrameLevel(l) self.frameLevel = l end
    function f:SetAllPoints() end
    function f:ClearAllPoints() end
    function f:SetPoint() end
    function f:GetEffectiveScale() return 1 end
    function f:SetBackdrop(info)
        self.backdrop = info
        if info then
            -- WoW resets the backdrop textures to white on (re)apply.
            self.bgColor = { 1, 1, 1, 1 }
            self.borderColor = { 1, 1, 1, 1 }
        else
            self.bgColor, self.borderColor = nil, nil
        end
    end
    function f:GetBackdrop() return self.backdrop end
    function f:SetBackdropColor(r, g, b, a) self.bgColor = { r, g, b, a or 1 } end
    function f:SetBackdropBorderColor(r, g, b, a) self.borderColor = { r, g, b, a or 1 } end
    return f
end

local function CreateStateTable()
    local tbl = setmetatable({}, { __mode = "k" })
    return tbl
end

-- Capture scale-refresh callbacks so the test can fire one on demand.
local scaleRefreshers = {}
local function SimulateScaleRefresh()
    for _, fn in ipairs(scaleRefreshers) do fn() end
end

local ns = {
    Helpers = {
        CreateStateTable = CreateStateTable,
        GetCore = function() return { GetPixelSize = function() return 0.5 end } end,
        SafeToNumber = function(v, d) return tonumber(v) or d end,
        GetSkinBorderColor = function() return 0.6, 0.7, 0.8, 1 end,
        GetSkinBgColorWithOverride = function() return 0.1, 0.2, 0.3, 0.9 end,
        GetSkinBarColor = function() return 0.5, 0.5, 0.5, 1 end,
        GetGeneralFont = function() return "Interface\\QUIFont.ttf" end,
        GetGeneralFontOutline = function() return "OUTLINE" end,
    },
    UIKit = {
        RegisterScaleRefresh = function(owner, _, fn)
            scaleRefreshers[#scaleRefreshers + 1] = function() fn(owner) end
        end,
    },
}

CreateFrame = function() return NewBackdropFrame() end

assert(loadfile("modules/skinning/base.lua"))("QUI", ns)
local SkinBase = ns.SkinBase
assert(type(SkinBase.ApplyPixelBackdrop) == "function", "SkinBase.ApplyPixelBackdrop must exist")

-- Mirror the blessed persisting helpers (core/utils.lua) without loading the full
-- Helpers module. These are exactly what the loot.lua fix calls.
local function SetFrameBackdropColor(frame, r, g, b, a)
    frame:SetBackdropColor(r, g, b, a)
    frame._quiBgR, frame._quiBgG, frame._quiBgB, frame._quiBgA = r, g, b, a
end
local function SetFrameBackdropBorderColor(frame, r, g, b, a)
    frame:SetBackdropBorderColor(r, g, b, a)
    frame._quiBorderR, frame._quiBorderG, frame._quiBorderB, frame._quiBorderA = r, g, b, a
end

local BG = { 0.1, 0.12, 0.14, 0.95 }
local BORDER = { 0.6, 0.7, 0.8, 0.3 }

----------------------------------------------------------------------------
-- 1) Document the root cause: a bare SetBackdropColor is lost on rebuild.
----------------------------------------------------------------------------
local buggy = NewBackdropFrame()
SkinBase.ApplyPixelBackdrop(buggy, 1, true, false)
buggy:SetBackdropColor(BG[1], BG[2], BG[3], BG[4])
buggy:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], BORDER[4])
assert(buggy.bgColor[1] == BG[1] and buggy.bgColor[4] == BG[4],
    "precondition: themed bg color is applied right after styling")

SimulateScaleRefresh()
assert(buggy.bgColor[1] == 1 and buggy.bgColor[2] == 1 and buggy.bgColor[3] == 1,
    "ROOT CAUSE: bare SetBackdropColor is dropped when RefreshPixelBackdrop rebuilds the backdrop (frame turns white)")

----------------------------------------------------------------------------
-- 2) The fix: persisted bg + border colors survive the scale-refresh rebuild.
----------------------------------------------------------------------------
local fixed = NewBackdropFrame()
SkinBase.ApplyPixelBackdrop(fixed, 1, true, false)
SetFrameBackdropColor(fixed, BG[1], BG[2], BG[3], BG[4])
SetFrameBackdropBorderColor(fixed, BORDER[1], BORDER[2], BORDER[3], BORDER[4])

SimulateScaleRefresh()
assert(fixed.bgColor[1] == BG[1] and fixed.bgColor[2] == BG[2]
    and fixed.bgColor[3] == BG[3] and fixed.bgColor[4] == BG[4],
    "FIX: persisted bg color must survive a scale-refresh rebuild, not go white")
assert(fixed.borderColor[1] == BORDER[1] and fixed.borderColor[4] == BORDER[4],
    "FIX: persisted border color must survive a scale-refresh rebuild")

----------------------------------------------------------------------------
-- 3) Border-only icon borders (quality color) must persist too.
----------------------------------------------------------------------------
local iconBorder = NewBackdropFrame()
SkinBase.ApplyPixelBackdrop(iconBorder, 2, false, false)
SetFrameBackdropBorderColor(iconBorder, 0.64, 0.21, 0.93, 1) -- epic purple

SimulateScaleRefresh()
assert(iconBorder.borderColor[1] == 0.64 and iconBorder.borderColor[2] == 0.21
    and iconBorder.borderColor[3] == 0.93,
    "FIX: persisted quality icon-border color must survive a scale-refresh rebuild")

print("OK: loot_backdrop_persist_test")
