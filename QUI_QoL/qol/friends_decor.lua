local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- FRIENDS LIST DECOR
-- Class-colors the names in the WoW friends list (regular friends and
-- Battle.net friends currently playing WoW). Pure post-hook on the Blizzard
-- button update: reads friend info, recolors button.name (a FontString) by
-- class. Visual-only + hooksecurefunc on a named global -> taint-safe.
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

-- GetPlayerInfoByGUID(guid) verified vs PlayerScriptDocumentation:
--   Returns localizedClass, englishClass, ... ; MayReturnNothing = true
--   (nil for an unknown/uncached GUID -> must guard before indexing).
local function ClassColorForGUID(guid)
    if not guid then return nil end
    local _, englishClass = GetPlayerInfoByGUID(guid)
    if not englishClass then return nil end
    return RAID_CLASS_COLORS and RAID_CLASS_COLORS[englishClass] or nil
end

local function DecorateFriendButton(button)
    local settings = GetSettings()
    if not settings or settings.friendsClassColor == false then return end
    if not button or not button.name or button.buttonType == nil then return end

    local color
    if button.buttonType == FRIENDS_BUTTON_TYPE_WOW then
        local info = C_FriendList.GetFriendInfoByIndex(button.id)
        if info and info.connected and info.guid then
            color = ClassColorForGUID(info.guid)
        end
    elseif button.buttonType == FRIENDS_BUTTON_TYPE_BNET then
        local accountInfo = C_BattleNet.GetFriendAccountInfo(button.id)
        local ga = accountInfo and accountInfo.gameAccountInfo
        if ga and ga.isOnline and ga.playerGuid and ga.clientProgram == BNET_CLIENT_WOW then
            color = ClassColorForGUID(ga.playerGuid)
        end
    end

    if color then
        button.name:SetTextColor(color.r, color.g, color.b)
    end
end

---------------------------------------------------------------------------
-- INSTALL
---------------------------------------------------------------------------

local hooked = false
local function InstallHook()
    if hooked then return end
    if type(_G.FriendsFrame_UpdateFriendButton) ~= "function" then return end
    hooksecurefunc("FriendsFrame_UpdateFriendButton", DecorateFriendButton)
    hooked = true
end

-- Re-run the visible list so a settings change / theme refresh recolors now.
local function RefreshFriendsDecor()
    InstallHook()
    if _G.FriendsListFrame and _G.FriendsListFrame:IsShown()
        and type(_G.FriendsList_Update) == "function" then
        _G.FriendsList_Update()
    end
end
ns.RefreshFriendsDecor = RefreshFriendsDecor

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", function(_, _, loadedAddon)
    if loadedAddon == "Blizzard_FriendsFrame" then
        InstallHook()
    end
end)

if ns.WhenLoggedIn then
    ns.WhenLoggedIn(function()
        -- FriendsFrame ships with the base UI in retail, but guard for LoD.
        InstallHook()
        if not hooked and C_AddOns and C_AddOns.IsAddOnLoaded
            and not C_AddOns.IsAddOnLoaded("Blizzard_FriendsFrame") then
            -- Will install via ADDON_LOADED when the social panel first opens.
        end
    end)
end

if ns.Registry then
    ns.Registry:Register("friendsDecor", {
        refresh = RefreshFriendsDecor,
        priority = 30,
        group = "qol",
        importCategories = { "qol" },
    })
end
