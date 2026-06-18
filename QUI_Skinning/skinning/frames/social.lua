---------------------------------------------------------------------------
-- SOCIAL FRAMES SKINNING
--
--   - FriendsFrame      (ButtonFrameTemplate,            LOD Blizzard_FriendsFrame)
--   - CommunitiesFrame  (ButtonFrameTemplateMinimizable, LOD Blizzard_Communities)
--
-- Both inherit a ButtonFrameTemplate variant, so SkinBase.SkinButtonFrameTemplate
-- handles chrome strip + backdrop + close-button styling. Frame-specific
-- sub-elements (friends scroll list, club channel tree, member list) are
-- left for follow-up commits.
---------------------------------------------------------------------------

local addonName, ns = ...
local SkinBase = ns.SkinBase
local GetCore = ns.Helpers.GetCore

local function IsSettingEnabled(key)
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    return settings and settings[key]
end

local RefreshBackdropColors = SkinBase.RefreshFrameBackdropColors

-- Pooled list rows (friends / who / ignore / community roster) are ScrollBox-
-- recycled and Blizzard re-applies their font OBJECT on every acquire / rebind
-- / presence update (FriendsFrame.lua, CommunitiesMemberList.lua), reverting a
-- one-shot SkinFrameText. Lock each acquired row's fontstrings so the QUI face
-- survives (fontOnly keeps Blizzard's class / status text colors).
local function HookListRows(scrollBox, depth)
    -- Guarded per-row font lock (runs the recursive pass once; the LockFontObject
    -- hooks re-assert the QUI face on every later acquire/presence/state rebind).
    -- The unguarded form was the guild/friends open-window hitch.
    SkinBase.HookScrollBoxRowFonts(scrollBox, depth or 3)
end

local function LockGuildNameAlertText(frame)
    local alert = frame and frame.GuildNameAlertFrame and frame.GuildNameAlertFrame.Alert
    if not alert then return end
    SkinBase.SkinFontString(alert, { fontOnly = true })
    SkinBase.LockFontObject(alert, { fontOnly = true })
end

---------------------------------------------------------------------------
-- FriendsFrame
---------------------------------------------------------------------------
local function SkinFriends()
    if not IsSettingEnabled("skinFriends") then return end
    local frame = _G.FriendsFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    SkinBase.SkinButtonFrameTemplate(frame)
    -- FriendsFrameTab1..4: Friends / Quick Join / Who / Raid
    -- (per Blizzard_FriendsFrame/Mainline/FriendsFrame.lua:273-276).
    local tabs = {}
    for i = 1, 4 do
        local tab = _G["FriendsFrameTab" .. i]
        if tab then tabs[#tabs + 1] = tab end
    end
    SkinBase.SkinTabGroup(tabs, frame)
    SkinBase.SkinFrameText(frame, { recurse = true })
    -- Friends / Ignore / Who pooled list rows (FriendsFrame.lua:312/326/343).
    if _G.FriendsListFrame then HookListRows(_G.FriendsListFrame.ScrollBox) end
    if frame.IgnoreListWindow then HookListRows(frame.IgnoreListWindow.ScrollBox) end
    if _G.WhoFrame then HookListRows(_G.WhoFrame.ScrollBox) end
    SkinBase.MarkSkinned(frame)
end

local function RefreshFriends() RefreshBackdropColors(_G.FriendsFrame) end
_G.QUI_RefreshFriendsColors = RefreshFriends
if ns.Registry then
    ns.Registry:Register("skinFriends", {
        refresh = RefreshFriends,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- CommunitiesFrame
---------------------------------------------------------------------------
local function SkinCommunities()
    if not IsSettingEnabled("skinCommunities") then return end
    local frame = _G.CommunitiesFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    SkinBase.SkinButtonFrameTemplate(frame)
    SkinBase.SkinFrameText(frame, { recurse = true })
    -- Community / guild roster rows (CommunitiesMemberList.lua:459) re-font on
    -- acquire + presence/state refresh.
    if frame.MemberList then HookListRows(frame.MemberList.ScrollBox) end
    if frame.CommunitiesList then HookListRows(frame.CommunitiesList.ScrollBox) end
    if frame.ApplicantList then HookListRows(frame.ApplicantList.ScrollBox) end
    if frame.GuildBenefitsFrame and frame.GuildBenefitsFrame.Rewards then
        HookListRows(frame.GuildBenefitsFrame.Rewards.ScrollBox)
    end
    LockGuildNameAlertText(frame)
    SkinBase.MarkSkinned(frame)
end

local function RefreshCommunities()
    RefreshBackdropColors(_G.CommunitiesFrame)
    LockGuildNameAlertText(_G.CommunitiesFrame)
end
_G.QUI_RefreshCommunitiesColors = RefreshCommunities
if ns.Registry then
    ns.Registry:Register("skinCommunities", {
        refresh = RefreshCommunities,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------
SkinBase.OnAddOnLoaded("Blizzard_FriendsFrame", SkinFriends,     0)
SkinBase.OnAddOnLoaded("Blizzard_Communities",  SkinCommunities, 0)
