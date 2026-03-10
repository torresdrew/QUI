--[[
    QUI Tooltip Classic Engine
    Hook-based tooltip system (original implementation).
    Registers with TooltipProvider as the "classic" engine.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local Provider  -- resolved after provider loads

-- Locals for performance
local GameTooltip = GameTooltip
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown

---------------------------------------------------------------------------
-- CLASSIC ENGINE TABLE
---------------------------------------------------------------------------
local ClassicEngine = {}

---------------------------------------------------------------------------
-- Cursor Follow State (engine-local)
---------------------------------------------------------------------------
local cursorFollowActive = setmetatable({}, {__mode = "k"})
local cursorFollowHooked = setmetatable({}, {__mode = "k"})

local function EnsureCursorFollowHooks(tooltip)
    if not tooltip or cursorFollowHooked[tooltip] then return end
    cursorFollowHooked[tooltip] = true

    tooltip:HookScript("OnUpdate", function(self)
        if not cursorFollowActive[self] then return end
        if InCombatLockdown() then
            cursorFollowActive[self] = nil
            return
        end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.anchorToCursor then
            cursorFollowActive[self] = nil
            return
        end
        Provider:PositionTooltipAtCursor(self, settings)
    end)

    tooltip:HookScript("OnHide", function(self)
        cursorFollowActive[self] = nil
    end)
end

local function AnchorTooltipToCursor(tooltip, parent, settings)
    if not tooltip then return false end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return false end
    EnsureCursorFollowHooks(tooltip)
    tooltip:SetOwner(parent or UIParent, "ANCHOR_NONE")
    cursorFollowActive[tooltip] = true
    Provider:PositionTooltipAtCursor(tooltip, settings or Provider:GetSettings())
    return true
end

---------------------------------------------------------------------------
-- DEBOUNCE STATE
---------------------------------------------------------------------------
local pendingSetUnit = nil

---------------------------------------------------------------------------
-- SETUP HOOKS
---------------------------------------------------------------------------
local function SetupTooltipHook()
    ns.QUI_AnchorTooltipToCursor = AnchorTooltipToCursor

    hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip, parent)
        if InCombatLockdown() then return end
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        if parent and parent.IsForbidden and parent:IsForbidden() then return end

        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end

        local context = Provider:GetTooltipContext(parent)
        if not Provider:ShouldShowTooltip(context) then
            tooltip:Hide()
            tooltip:SetOwner(UIParent, "ANCHOR_NONE")
            tooltip:ClearLines()
            return
        end

        if settings.anchorToCursor then
            AnchorTooltipToCursor(tooltip, parent, settings)
        else
            cursorFollowActive[tooltip] = nil
        end
    end)

    hooksecurefunc(GameTooltip, "SetUnit", function(tooltip)
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end

        if settings.hideInCombat and InCombatLockdown() then
            if not settings.combatKey or settings.combatKey == "NONE" or not Provider:IsModifierActive(settings.combatKey) then
                tooltip:Hide()
                return
            end
        end

        if pendingSetUnit then return end
        pendingSetUnit = C_Timer.After(0.1, function()
            pendingSetUnit = nil
            if tooltip.IsForbidden and tooltip:IsForbidden() then return end
            if tooltip:GetOwner() == UIParent and Provider:IsFrameBlockingMouse() then
                tooltip:Hide()
            end
        end)
    end)

    -- Class color player names
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip ~= GameTooltip then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.classColorName then return end

        local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
        if not ok or not unit then return end
        if Helpers.IsSecretValue(unit) then
            unit = UnitExists("mouseover") and "mouseover" or nil
            if not unit then return end
        end

        local okPlayer, isPlayer = pcall(UnitIsPlayer, unit)
        if not okPlayer or not isPlayer then return end
        local okClass, _, class = pcall(UnitClass, unit)
        if not okClass or not class then return end

        local classColor
        if InCombatLockdown() then
            if C_ClassColor and C_ClassColor.GetClassColor then
                local okColor, color = pcall(C_ClassColor.GetClassColor, class)
                if okColor and color then classColor = color end
            end
        else
            classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        end

        if classColor then
            local nameLine = tooltip.GetLeftLine and tooltip:GetLeftLine(1) or GameTooltipTextLeft1
            if nameLine then
                local okText, text = pcall(nameLine.GetText, nameLine)
                if okText and text and not Helpers.IsSecretValue(text) then
                    pcall(nameLine.SetTextColor, nameLine, classColor.r, classColor.g, classColor.b)
                end
            end
        end
    end)

    -- Hide health bar
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip ~= GameTooltip then return end
        if InCombatLockdown() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end

        if settings.hideHealthBar then
            if GameTooltipStatusBar and not (GameTooltipStatusBar.IsForbidden and GameTooltipStatusBar:IsForbidden()) then
                pcall(GameTooltipStatusBar.SetShown, GameTooltipStatusBar, false)
                pcall(GameTooltipStatusBar.SetAlpha, GameTooltipStatusBar, 0)
            end
        end
    end)

    -- Spell ID tracking
    local tooltipSpellIDAdded = setmetatable({}, {__mode = "k"})

    GameTooltip:HookScript("OnHide", function(tooltip)
        tooltipSpellIDAdded[tooltip] = nil
    end)
    GameTooltip:HookScript("OnTooltipCleared", function(tooltip)
        tooltipSpellIDAdded[tooltip] = nil
    end)

    local function IsBlockedValue(value)
        if value == nil then return false end
        if type(issecretvalue) == "function" and issecretvalue(value) then return true end
        if type(canaccessvalue) == "function" and not canaccessvalue(value) then return true end
        return false
    end

    local function CanAccessAuraArgs(unit, token)
        if IsBlockedValue(unit) then return false end
        if IsBlockedValue(token) then return false end
        return true
    end

    local function RefreshTooltipLayout(tooltip)
        if not tooltip then return end
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        if type(tooltip.UpdateTooltipSize) == "function" then
            pcall(tooltip.UpdateTooltipSize, tooltip)
        end
        pcall(tooltip.Show, tooltip)
    end

    local function AddSpellIDToTooltip(tooltip, spellID, skipShow)
        if not spellID then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.showSpellIDs then return end
        if type(spellID) ~= "number" then return end
        if type(issecretvalue) == "function" and issecretvalue(spellID) then return end
        if tooltipSpellIDAdded[tooltip] then return end
        tooltipSpellIDAdded[tooltip] = true

        local iconID = nil
        if C_Spell and C_Spell.GetSpellTexture then
            local iconOk, result = pcall(C_Spell.GetSpellTexture, spellID)
            if iconOk and result and type(result) == "number" then
                iconID = result
            end
        end

        tooltip:AddLine(" ")
        tooltip:AddDoubleLine("Spell ID:", tostring(spellID), 0.5, 0.8, 1, 1, 1, 1)
        if iconID then
            tooltip:AddDoubleLine("Icon ID:", tostring(iconID), 0.5, 0.8, 1, 1, 1, 1)
        end

        if not skipShow then
            RefreshTooltipLayout(tooltip)
        end
    end

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
        if InCombatLockdown() then return end
        pcall(function()
            if data and data.id and type(data.id) == "number" then
                AddSpellIDToTooltip(tooltip, data.id)
            end
        end)
    end)

    if Enum.TooltipDataType.Aura then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Aura, function(tooltip, data)
            if InCombatLockdown() then return end
            pcall(function()
                if data and data.id and type(data.id) == "number" then
                    AddSpellIDToTooltip(tooltip, data.id, false)
                end
            end)
        end)
    end

    local function HookAuraTooltip(methodName, getAuraFunc, isGeneric)
        if not GameTooltip[methodName] then return end
        hooksecurefunc(GameTooltip, methodName, function(tooltip, unit, indexOrID, filter)
            if not CanAccessAuraArgs(unit, indexOrID) then return end
            pcall(function()
                local auraData
                if filter ~= nil then
                    auraData = getAuraFunc(unit, indexOrID, filter)
                else
                    auraData = getAuraFunc(unit, indexOrID)
                end
                if type(canaccesstable) == "function" and auraData and not canaccesstable(auraData) then
                    return
                end
                if auraData and auraData.spellId then
                    AddSpellIDToTooltip(tooltip, auraData.spellId, isGeneric or false)
                end
            end)
        end)
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        HookAuraTooltip("SetUnitAura", C_UnitAuras.GetAuraDataByIndex, false)
    end
    if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        HookAuraTooltip("SetUnitBuff", C_UnitAuras.GetBuffDataByIndex, false)
    end
    if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
        HookAuraTooltip("SetUnitDebuff", C_UnitAuras.GetDebuffDataByIndex, false)
    end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        HookAuraTooltip("SetUnitBuffByAuraInstanceID", C_UnitAuras.GetAuraDataByAuraInstanceID, false)
        HookAuraTooltip("SetUnitDebuffByAuraInstanceID", C_UnitAuras.GetAuraDataByAuraInstanceID, false)
        HookAuraTooltip("SetUnitAuraByAuraInstanceID", C_UnitAuras.GetAuraDataByAuraInstanceID, true)
    end

    -- Suppress tooltips that bypass GameTooltip_SetDefaultAnchor
    hooksecurefunc(GameTooltip, "SetSpellByID", function(tooltip)
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end
        local owner = tooltip:GetOwner()
        if Provider:IsOwnerFadedOut(owner) then
            tooltip:Hide()
            return
        end
        local context = Provider:GetTooltipContext(owner)
        if not Provider:ShouldShowTooltip(context) then
            tooltip:Hide()
        end
    end)

    hooksecurefunc(GameTooltip, "SetItemByID", function(tooltip)
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end
        local owner = tooltip:GetOwner()
        if Provider:IsOwnerFadedOut(owner) then
            tooltip:Hide()
            return
        end
        local context = Provider:GetTooltipContext(owner)
        if not Provider:ShouldShowTooltip(context) then
            tooltip:Hide()
        end
    end)

    -- Safety net for combat tooltip issues
    hooksecurefunc("GameTooltip_Hide", function()
        C_Timer.After(0, function()
            if GameTooltip.IsForbidden and GameTooltip:IsForbidden() then return end
            if InCombatLockdown() and GameTooltip:IsVisible() then
                GameTooltip:Hide()
            end
        end)
    end)

    -- Tooltip sticking monitor (combat only)
    local tooltipMonitor = CreateFrame("Frame")
    local monitorElapsed = 0

    local function TooltipMonitorOnUpdate(self, delta)
        monitorElapsed = monitorElapsed + delta
        if monitorElapsed < 0.25 then return end
        monitorElapsed = 0
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end
        if settings.hideInCombat then return end
        if not GameTooltip:IsVisible() then return end
        local owner = GameTooltip:GetOwner()
        if not owner then return end
        local mouseFrame = Provider:GetTopMouseFrame()
        if not mouseFrame then return end
        local isOverOwner = false
        local checkFrame = mouseFrame
        while checkFrame do
            if checkFrame == owner then
                isOverOwner = true
                break
            end
            local ok, parent = pcall(checkFrame.GetParent, checkFrame)
            checkFrame = ok and parent or nil
        end
        if not isOverOwner then
            GameTooltip:Hide()
        end
    end

    tooltipMonitor:RegisterEvent("PLAYER_REGEN_DISABLED")
    tooltipMonitor:RegisterEvent("PLAYER_REGEN_ENABLED")
    tooltipMonitor:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            monitorElapsed = 0
            self:SetScript("OnUpdate", TooltipMonitorOnUpdate)
        else
            self:SetScript("OnUpdate", nil)
        end
    end)
end

---------------------------------------------------------------------------
-- Modifier / Combat Event Handlers
---------------------------------------------------------------------------
local function OnModifierStateChanged()
    if not GameTooltip:IsShown() then return end
    local settings = Provider:GetSettings()
    if not settings or not settings.enabled then return end
    local owner = GameTooltip:GetOwner()
    local context = Provider:GetTooltipContext(owner)
    if not Provider:ShouldShowTooltip(context) then
        GameTooltip:Hide()
    end
end

local function OnCombatStateChanged(inCombat)
    local settings = Provider:GetSettings()
    if not settings or not settings.enabled or not settings.hideInCombat then return end
    if inCombat then
        if not settings.combatKey or settings.combatKey == "NONE" or not Provider:IsModifierActive(settings.combatKey) then
            GameTooltip:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- ENGINE CONTRACT
---------------------------------------------------------------------------

function ClassicEngine:Initialize()
    Provider = ns.TooltipProvider

    SetupTooltipHook()

    -- Event handlers
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:SetScript("OnEvent", function(self, event)
        if event == "MODIFIER_STATE_CHANGED" then
            OnModifierStateChanged()
        elseif event == "PLAYER_REGEN_DISABLED" then
            OnCombatStateChanged(true)
        elseif event == "PLAYER_REGEN_ENABLED" then
            OnCombatStateChanged(false)
        end
    end)
end

function ClassicEngine:Refresh()
    -- Settings apply on next tooltip show
end

function ClassicEngine:SetEnabled(enabled)
    -- Classic engine hooks are permanent once installed
end

---------------------------------------------------------------------------
-- REGISTER WITH PROVIDER
---------------------------------------------------------------------------
ns.TooltipProvider:RegisterEngine("classic", ClassicEngine)
