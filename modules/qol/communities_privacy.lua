local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- COMMUNITIES CHAT PRIVACY
--
-- Stream-safety: hides the Communities/guild chat panel and member list
-- behind an opaque "click the eye to reveal" cover until explicitly
-- revealed. Reveal is per-open — reopening the window hides again.
--
-- Mechanism (no protected calls anywhere): plain :Hide()/:Show() on the
-- CommunitiesFrame.Chat / .MemberList child frames + an overlay Frame with
-- instructional text, toggled by an eye Button. Child names verified against
-- 12.x Blizzard_Communities/CommunitiesFrame.lua (COMMUNITIES_FRAME_DISPLAY_MODES
-- lists "Chat"/"MemberList"; CommunitiesFrameMixin:GetDisplayMode and the
-- DisplayModeChanged mixin event exist). Blizzard_Communities is LoadOnDemand
-- — init on its ADDON_LOADED.
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local initialized = false
local revealed = false
local overlay, overlayText, eyeButton

local function Enabled()
    local s = GetSettings()
    return s and s.communitiesPrivacy == true
end

local function IsHidden()
    return Enabled() and not revealed
end

local function DisplayModeShows(childKey)
    local frame = _G.CommunitiesFrame
    local mode = frame and frame.GetDisplayMode and frame:GetDisplayMode()
    if type(mode) ~= "table" then return false end
    for _, key in ipairs(mode) do
        if key == childKey then return true end
    end
    return false
end

local function EnsureOverlay()
    if overlay then return end
    local frame = _G.CommunitiesFrame
    overlay = CreateFrame("Frame", nil, frame)
    overlay:SetFrameStrata("HIGH")
    overlay:SetFrameLevel(frame:GetFrameLevel() + 10)
    overlay:EnableMouse(false)
    local bg = overlay:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
    overlayText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    overlayText:SetPoint("CENTER")
    overlayText:SetWidth(280)
    overlayText:SetWordWrap(true)
    overlayText:SetText(ns.L["Chat hidden. Click the eye button in the top right to reveal."])
    overlay:Hide()
end

local function SetEyeTexture()
    if not eyeButton then return end
    -- LFG eye sheet: 4x4 frames of 64px on 512x256; frame 1 = open, 4 = closed.
    local tex = eyeButton:GetNormalTexture()
    if not tex then return end
    if revealed then
        tex:SetTexCoord(0, 0.125, 0, 0.25)
    else
        tex:SetTexCoord(0.375, 0.5, 0, 0.25)
    end
end

local Apply -- fwd

local function EnsureEyeButton()
    if eyeButton then return end
    local frame = _G.CommunitiesFrame
    eyeButton = CreateFrame("Button", nil, frame)
    eyeButton:SetSize(22, 22)
    local anchor = frame.MaximizeMinimizeFrame or frame
    if frame.MaximizeMinimizeFrame then
        eyeButton:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    else
        eyeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -28, -4)
    end
    eyeButton:SetNormalTexture("Interface\\LFGFrame\\LFG-Eye")
    SetEyeTexture()
    eyeButton:SetScript("OnClick", function()
        revealed = not revealed
        Apply()
    end)
    eyeButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(revealed and ns.L["Hide community chat"] or ns.L["Reveal community chat"])
        GameTooltip:Show()
    end)
    eyeButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

Apply = function()
    local frame = _G.CommunitiesFrame
    if not frame then return end

    if not Enabled() then
        if overlay then overlay:Hide() end
        if eyeButton then eyeButton:Hide() end
        -- Restore whatever the current display mode wants visible.
        if frame.Chat and DisplayModeShows("Chat") then frame.Chat:Show() end
        if frame.MemberList and DisplayModeShows("MemberList") then frame.MemberList:Show() end
        return
    end

    EnsureOverlay()
    EnsureEyeButton()
    eyeButton:Show()
    SetEyeTexture()

    if IsHidden() then
        if frame.Chat then frame.Chat:Hide() end
        if frame.MemberList then frame.MemberList:Hide() end
        -- Cover the chat area (or the member list when chat isn't part of
        -- the current display mode).
        local target = (DisplayModeShows("Chat") and frame.Chat)
            or (DisplayModeShows("MemberList") and frame.MemberList) or nil
        if target then
            overlay:ClearAllPoints()
            overlay:SetPoint("TOPLEFT", target, "TOPLEFT", 0, 0)
            overlay:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 0, 0)
            overlay:Show()
        else
            overlay:Hide()
        end
    else
        overlay:Hide()
        if frame.Chat and DisplayModeShows("Chat") then frame.Chat:Show() end
        if frame.MemberList and DisplayModeShows("MemberList") then frame.MemberList:Show() end
    end
end

local function Initialize()
    if initialized then return end
    local frame = _G.CommunitiesFrame
    if not frame then return end
    initialized = true

    if frame.RegisterCallback and CommunitiesFrameMixin and CommunitiesFrameMixin.Event
        and CommunitiesFrameMixin.Event.DisplayModeChanged then
        frame:RegisterCallback(CommunitiesFrameMixin.Event.DisplayModeChanged, function()
            Apply()
        end, {})
    end
    frame:HookScript("OnShow", function()
        revealed = false -- re-hide on every open (stream safety)
        Apply()
    end)
    frame:HookScript("OnHide", function()
        revealed = false
    end)
    Apply()
end

local frame = CreateFrame("Frame")
-- Literal RegisterEvent call so tools/generate_event_allowlist.lua detects it.
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, addonName)
    if addonName == "Blizzard_Communities" then
        Initialize()
    end
end)

if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Communities") then
    Initialize()
end

ns.RefreshCommunitiesPrivacy = function()
    if initialized then Apply() end
end
