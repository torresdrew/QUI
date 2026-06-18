---------------------------------------------------------------------------
-- ACHIEVEMENT FRAME SKINNING
--
-- AchievementFrame doesn't use PortraitFrameTemplate / ButtonFrameTemplate
-- (per Blizzard_AchievementUI/Mainline/Blizzard_AchievementUI.xml:1505 —
-- inherits BackdropTemplate with the global BACKDROP_ACHIEVEMENTS_0_64
-- KeyValue). Its chrome is bespoke achievement-themed artwork:
--   - .Background              (UI-Achievement-AchievementBackground)
--   - .BackgroundBlackCover    (dark cover overlay)
--   - AchievementFrameMetalBorder{Left,Right,Top,Bottom}  ($parent-prefixed globals)
--   - AchievementFrameCategoriesBG  (parchment for the left category column)
--   - AchievementFrameWaterMark     (watermark dragon)
--   - AchievementFrameGuildEmblem{Left,Right}  (hidden by default)
-- Close button lives at AchievementFrameHeader.CloseButton.
---------------------------------------------------------------------------

local addonName, ns = ...
local SkinBase = ns.SkinBase
local GetCore = ns.Helpers.GetCore

local function IsSettingEnabled(key)
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    return settings and settings[key]
end

local function HideAchievementChrome()
    local frame = _G.AchievementFrame
    if not frame then return end

    if frame.Background then frame.Background:Hide() end
    if frame.BackgroundBlackCover then frame.BackgroundBlackCover:Hide() end

    -- $parent-named globals (Texture without parentKey, accessed via _G).
    local globals = {
        "AchievementFrameMetalBorderLeft", "AchievementFrameMetalBorderRight",
        "AchievementFrameMetalBorderTop",  "AchievementFrameMetalBorderBottom",
        "AchievementFrameCategoriesBG",    "AchievementFrameWaterMark",
        "AchievementFrameGuildEmblemLeft", "AchievementFrameGuildEmblemRight",
    }
    for _, name in ipairs(globals) do
        local tex = _G[name]
        if tex and tex.Hide then tex:Hide() end
    end

    -- The Blizzard backdrop also draws a BackdropTemplate frame border —
    -- zero its colors so it doesn't peek through the QUI backdrop.
    if frame.SetBackdrop then
        pcall(frame.SetBackdrop, frame, nil)
    end
end

-- Category / achievement / stat rows are ScrollBox-pooled and Blizzard swaps
-- their font OBJECT on hover / selection / re-bind, so the one-shot
-- SkinFrameText above reverts. Lock each acquired row's fontstrings (and the
-- initial pass) so the QUI font survives. Idempotent (HookScrollBoxAcquired
-- guards with qScrollHooked, LockFontObject with qFontLocked).
local function HookAchievementLists()
    for _, host in ipairs({ "AchievementFrameCategories", "AchievementFrameAchievements", "AchievementFrameStats" }) do
        local listFrame = _G[host]
        local scrollBox = listFrame and listFrame.ScrollBox
        if scrollBox then
            SkinBase.HookScrollBoxAcquired(scrollBox, function(row)
                SkinBase.LockFrameTextObjects(row, 3)
            end)
        end
    end
end

-- Blizzard hardcodes the achievement Description to BLACK (0,0,0) in its
-- saturate paths (Blizzard_AchievementUI.lua AchievementComparisonPlayerButton_
-- Saturate :2998) because it expects the light parchment row background. The
-- Summary tab's "Latest Unlocked Achievements" rows are earned -> saturated, so
-- their description goes black; on QUI's dark theme that reads as black-on-black.
-- Post-hook the summary saturate and re-assert a readable light color (matches
-- Blizzard's own Desaturate white variant). Scoped to summary rows (isSummary)
-- so the main achievement list -- which keeps a visible parchment -- is left
-- with Blizzard's intended colors. Gated on skinAchievement so disabling the
-- skin restores stock behavior. hooksecurefunc is permanent -> guard once.
local achievementSummaryColorHooked
local function RecolorSummaryDescription(button)
    if button and button.isSummary and button.Description then
        button.Description:SetTextColor(0.95, 0.95, 0.95, 1)
    end
end
local function HookSummaryAchievementColors()
    if achievementSummaryColorHooked then return end
    if type(_G.AchievementComparisonPlayerButton_Saturate) ~= "function" then return end
    hooksecurefunc("AchievementComparisonPlayerButton_Saturate", function(self)
        if not IsSettingEnabled("skinAchievement") then return end
        RecolorSummaryDescription(self)
    end)
    achievementSummaryColorHooked = true
    -- Recolor any rows already saturated before the hook existed (summary open
    -- when the skin is enabled at runtime).
    local summary = _G.AchievementFrameSummaryAchievements
    if summary and summary.buttons then
        for _, button in ipairs(summary.buttons) do
            RecolorSummaryDescription(button)
        end
    end
end

local function SkinAchievement()
    if not IsSettingEnabled("skinAchievement") then return end
    local frame = _G.AchievementFrame
    if not frame or SkinBase.IsSkinned(frame) then return end

    HideAchievementChrome()
    local sr, sg, sb, sa, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()
    SkinBase.CreateBackdrop(frame, sr, sg, sb, sa, bgr, bgg, bgb, bga)

    local header = _G.AchievementFrameHeader
    if header and header.CloseButton then
        SkinBase.SkinCloseButton(header.CloseButton)
    end

    SkinBase.SkinFrameText(frame, { recurse = true })
    HookAchievementLists()
    HookSummaryAchievementColors()
    SkinBase.MarkSkinned(frame)
end

local function RefreshAchievement()
    local frame = _G.AchievementFrame
    if not frame then return end
    if SkinBase.IsSkinned(frame) then
        HookAchievementLists()
        HookSummaryAchievementColors()
    end
    local bd = SkinBase.GetBackdrop(frame)
    if not bd then return end
    local sr, sg, sb, sa, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()
    bd:SetBackdropColor(bgr, bgg, bgb, bga)
    bd:SetBackdropBorderColor(sr, sg, sb, sa)
end

_G.QUI_RefreshAchievementColors = RefreshAchievement
if ns.Registry then
    ns.Registry:Register("skinAchievement", {
        refresh = RefreshAchievement,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

SkinBase.OnAddOnLoaded("Blizzard_AchievementUI", SkinAchievement, 0.1)
