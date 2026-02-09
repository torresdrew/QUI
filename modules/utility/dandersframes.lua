--[[
    QUI DandersFrames Integration Module
    Anchors DandersFrames party/raid/pinned containers to QUI elements
    Requires DandersFrames v4.0.0+ API
]]

local ADDON_NAME, ns = ...
local QUICore = ns.Addon

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_DandersFrames = {}
ns.QUI_DandersFrames = QUI_DandersFrames

-- Pending combat-deferred updates
local pendingUpdate = false

-- Debounce timer handle for GROUP_ROSTER_UPDATE
local rosterTimer = nil

---------------------------------------------------------------------------
-- DATABASE ACCESS
---------------------------------------------------------------------------
local function GetDB()
    if QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.dandersFrames then
        return QUICore.db.profile.dandersFrames
    end
    return nil
end

---------------------------------------------------------------------------
-- DF AVAILABILITY
---------------------------------------------------------------------------
function QUI_DandersFrames:IsAvailable()
    return type(DandersFrames_IsReady) == "function" and DandersFrames_IsReady()
end

---------------------------------------------------------------------------
-- CONTAINER FRAME RESOLUTION
---------------------------------------------------------------------------
function QUI_DandersFrames:GetContainerFrame(containerKey)
    if not self:IsAvailable() then return nil end

    if containerKey == "party" and type(DandersFrames_GetPartyContainer) == "function" then
        return DandersFrames_GetPartyContainer()
    elseif containerKey == "raid" and type(DandersFrames_GetRaidContainer) == "function" then
        return DandersFrames_GetRaidContainer()
    elseif containerKey == "pinned1" and type(DandersFrames_GetPinnedContainer) == "function" then
        return DandersFrames_GetPinnedContainer(1)
    elseif containerKey == "pinned2" and type(DandersFrames_GetPinnedContainer) == "function" then
        return DandersFrames_GetPinnedContainer(2)
    end

    return nil
end

---------------------------------------------------------------------------
-- ANCHOR FRAME RESOLUTION
---------------------------------------------------------------------------
function QUI_DandersFrames:GetAnchorFrame(anchorName)
    if not anchorName or anchorName == "disabled" then
        return nil
    end

    -- Hardcoded QUI element map
    if anchorName == "essential" then
        return _G["EssentialCooldownViewer"]
    elseif anchorName == "utility" then
        return _G["UtilityCooldownViewer"]
    elseif anchorName == "primary" then
        return QUICore and QUICore.powerBar
    elseif anchorName == "secondary" then
        return QUICore and QUICore.secondaryPowerBar
    elseif anchorName == "playerCastbar" then
        return ns.QUI_Castbar and ns.QUI_Castbar.castbars and ns.QUI_Castbar.castbars["player"]
    elseif anchorName == "playerFrame" then
        return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.player
    end

    -- Registry fallback
    if ns.QUI_Anchoring and ns.QUI_Anchoring.GetAnchorTarget then
        return ns.QUI_Anchoring:GetAnchorTarget(anchorName)
    end

    return nil
end

---------------------------------------------------------------------------
-- ANCHOR OPTIONS FOR DROPDOWNS
---------------------------------------------------------------------------
function QUI_DandersFrames:BuildAnchorOptions()
    local options = {
        {value = "disabled", text = "Disabled"},
        {value = "essential", text = "Essential Cooldowns"},
        {value = "utility", text = "Utility Cooldowns"},
        {value = "primary", text = "Primary Resource Bar"},
        {value = "secondary", text = "Secondary Resource Bar"},
        {value = "playerCastbar", text = "Player Castbar"},
        {value = "playerFrame", text = "Player Frame"},
    }

    -- Add registered anchor targets from the anchoring system
    if ns.QUI_Anchoring and ns.QUI_Anchoring.anchorTargets then
        for name, data in pairs(ns.QUI_Anchoring.anchorTargets) do
            -- Skip targets already in our hardcoded list
            if name ~= "disabled" and name ~= "essential" and name ~= "utility"
               and name ~= "primary" and name ~= "secondary" and name ~= "playerCastbar"
               and name ~= "playerFrame" then
                local displayName = data.options and data.options.displayName or name
                displayName = displayName:gsub("^%l", string.upper)
                displayName = displayName:gsub("([a-z])([A-Z])", "%1 %2")
                table.insert(options, {value = name, text = displayName})
            end
        end
    end

    return options
end

---------------------------------------------------------------------------
-- POSITIONING
---------------------------------------------------------------------------
function QUI_DandersFrames:ApplyPosition(containerKey)
    local db = GetDB()
    if not db or not db[containerKey] then return end

    local cfg = db[containerKey]
    if not cfg.enabled or cfg.anchorTo == "disabled" then return end

    -- Defer during combat (DF containers parent secure headers)
    if InCombatLockdown() then
        pendingUpdate = true
        return
    end

    local container = self:GetContainerFrame(containerKey)
    if not container then return end

    local anchorFrame = self:GetAnchorFrame(cfg.anchorTo)
    if not anchorFrame then return end

    local ok = pcall(function()
        container:ClearAllPoints()
        container:SetPoint(
            cfg.sourcePoint or "TOP",
            anchorFrame,
            cfg.targetPoint or "BOTTOM",
            cfg.offsetX or 0,
            cfg.offsetY or -5
        )
    end)

    if not ok then
        pendingUpdate = true
    end
end

function QUI_DandersFrames:ApplyAllPositions()
    self:ApplyPosition("party")
    self:ApplyPosition("raid")
    self:ApplyPosition("pinned1")
    self:ApplyPosition("pinned2")
end

---------------------------------------------------------------------------
-- EVENT HANDLING
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

local function OnEvent(self, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1.5, function()
            QUI_DandersFrames:Initialize()
        end)

    elseif event == "ADDON_LOADED" and arg1 == "DandersFrames" then
        C_Timer.After(1.5, function()
            QUI_DandersFrames:Initialize()
        end)

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingUpdate then
            pendingUpdate = false
            C_Timer.After(0.1, function()
                QUI_DandersFrames:ApplyAllPositions()
            end)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Debounce roster updates
        if rosterTimer then
            rosterTimer:Cancel()
        end
        rosterTimer = C_Timer.NewTimer(0.3, function()
            rosterTimer = nil
            QUI_DandersFrames:ApplyAllPositions()
        end)
    end
end

eventFrame:SetScript("OnEvent", OnEvent)
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

---------------------------------------------------------------------------
-- INITIALIZE
---------------------------------------------------------------------------
local initialized = false

function QUI_DandersFrames:Initialize()
    if initialized then return end
    if not self:IsAvailable() then return end

    initialized = true
    self:ApplyAllPositions()

    -- Hook into CDM layout update callback
    local previousUpdateAnchoredFrames = _G.QUI_UpdateAnchoredFrames
    if previousUpdateAnchoredFrames then
        _G.QUI_UpdateAnchoredFrames = function(...)
            previousUpdateAnchoredFrames(...)
            QUI_DandersFrames:ApplyAllPositions()
        end
    end
end
