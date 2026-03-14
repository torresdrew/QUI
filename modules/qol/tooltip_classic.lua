--[[
    QUI Tooltip Classic Engine
    Hook-based tooltip system (original implementation).
    Registers with TooltipProvider as the "classic" engine.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local Provider  -- resolved after provider loads
local TooltipInspect

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

-- TAINT SAFETY: For GameTooltip, cursor follow uses a SEPARATE watcher
-- frame instead of HookScript. HookScript on GameTooltip permanently taints
-- its dispatch tables, causing ADDON_ACTION_BLOCKED when the world map's
-- secure context (secureexecuterange) uses GameTooltip for map pins.
local gtCursorWatcher

local function EnsureCursorFollowHooks(tooltip)
    if not tooltip or cursorFollowHooked[tooltip] then return end
    cursorFollowHooked[tooltip] = true

    if tooltip == GameTooltip then
        -- Use a separate watcher frame for GameTooltip to avoid taint
        if not gtCursorWatcher then
            gtCursorWatcher = CreateFrame("Frame")
            gtCursorWatcher:SetScript("OnUpdate", function()
                if not cursorFollowActive[GameTooltip] then return end
                if not GameTooltip:IsShown() then
                    cursorFollowActive[GameTooltip] = nil
                    return
                end
                local settings = Provider:GetSettings()
                if not settings or not settings.enabled or not settings.anchorToCursor then
                    cursorFollowActive[GameTooltip] = nil
                    return
                end
                Provider:PositionTooltipAtCursor(GameTooltip, settings)
            end)
        end
        return
    end

    -- Non-GameTooltip frames can safely use HookScript
    tooltip:HookScript("OnUpdate", function(self)
        if not cursorFollowActive[self] then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.anchorToCursor then
            cursorFollowActive[self] = nil
            return
        end
        -- PositionTooltipAtCursor uses cached UIParent scale (updated on
        -- UI_SCALE_CHANGED) so arithmetic is safe during combat.
        -- GetCursorPosition returns screen coordinates, not combat-restricted data.
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
local pendingSetUnitToken = 0
local tooltipPlayerItemLevelGUID = setmetatable({}, {__mode = "k"})
local DEFAULT_PLAYER_ILVL_BRACKETS = {
    white = 245,
    green = 255,
    blue = 265,
    purple = 275,
    orange = 285,
}

local function RefreshTooltipLayout(tooltip)
    if not tooltip then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    if type(tooltip.UpdateTooltipSize) == "function" then
        pcall(tooltip.UpdateTooltipSize, tooltip)
    end
    pcall(tooltip.Show, tooltip)
end

local function InvalidatePendingSetUnit()
    pendingSetUnitToken = pendingSetUnitToken + 1
end

local function ShouldHideOwnedTooltip(tooltip)
    local owner = tooltip and tooltip.GetOwner and tooltip:GetOwner() or nil
    if not owner then
        return false
    end
    if Provider:IsTransientTooltipOwner(owner) then
        return false
    end
    if Provider:IsOwnerFadedOut(owner) then
        return true
    end
    if not InCombatLockdown() then
        local context = Provider:GetTooltipContext(owner)
        if context and not Provider:ShouldShowTooltip(context) then
            return true
        end
    end
    return false
end

local function ResolveTooltipUnit(tooltip)
    if not tooltip then return nil end

    local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
    if not ok or not unit then return nil end

    if Helpers.IsSecretValue(unit) then
        unit = UnitExists("mouseover") and "mouseover" or nil
    end

    return unit
end

local function GetPlayerItemLevelColor(itemLevel)
    if Helpers.IsSecretValue(itemLevel) then
        return 1, 1, 1
    end

    itemLevel = tonumber(itemLevel)
    if not itemLevel then
        return 1, 1, 1
    end

    local settings = Provider and Provider:GetSettings()
    if not settings or settings.colorPlayerItemLevel == false then
        return 1, 1, 1
    end

    local brackets = settings.itemLevelBrackets or DEFAULT_PLAYER_ILVL_BRACKETS
    local white = tonumber(brackets.white) or DEFAULT_PLAYER_ILVL_BRACKETS.white
    local green = tonumber(brackets.green) or DEFAULT_PLAYER_ILVL_BRACKETS.green
    local blue = tonumber(brackets.blue) or DEFAULT_PLAYER_ILVL_BRACKETS.blue
    local purple = tonumber(brackets.purple) or DEFAULT_PLAYER_ILVL_BRACKETS.purple
    local orange = tonumber(brackets.orange) or DEFAULT_PLAYER_ILVL_BRACKETS.orange

    if itemLevel >= orange then
        return 1, 0.5, 0
    elseif itemLevel >= purple then
        return 0.64, 0.21, 0.93
    elseif itemLevel >= blue then
        return 0, 0.44, 0.87
    elseif itemLevel >= green then
        return 0, 1, 0
    elseif itemLevel >= white then
        return 1, 1, 1
    end

    return 0.62, 0.62, 0.62
end

local function GetPlayerClassColor(classToken)
    if not classToken then
        return 1, 1, 1
    end

    local classColor
    if InCombatLockdown() then
        if C_ClassColor and C_ClassColor.GetClassColor then
            local ok, color = pcall(C_ClassColor.GetClassColor, classToken)
            if ok and color then
                classColor = color
            end
        end
    else
        classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    end

    if classColor then
        return classColor.r, classColor.g, classColor.b
    end

    return 1, 1, 1
end

local function GetPlayerItemLevelLabel(playerData)
    if not playerData then
        return "Player"
    end

    if playerData.specName and playerData.specName ~= "" and playerData.className and playerData.className ~= "" then
        return string.format("%s %s", playerData.specName, playerData.className)
    end

    if playerData.className and playerData.className ~= "" then
        return playerData.className
    end

    return "Player"
end

local function AddPlayerItemLevelToTooltip(tooltip, unit, skipShow)
    if not TooltipInspect or not unit or not tooltip then return false end
    if InCombatLockdown() then return false end

    local playerData = TooltipInspect:GetCachedPlayerData(unit)
    if not playerData or not playerData.itemLevel then
        if not InCombatLockdown() then
            TooltipInspect:QueueInspect(unit)
        end
        return false
    end

    local guid = UnitGUID(unit)
    if tooltipPlayerItemLevelGUID[tooltip] == guid then
        return false
    end

    if Helpers.IsSecretValue(playerData.itemLevel) then
        return false
    end

    local itemLevel = tonumber(playerData.itemLevel)
    if not itemLevel or itemLevel <= 0 then
        return false
    end

    local label = GetPlayerItemLevelLabel(playerData)
    local labelR, labelG, labelB = GetPlayerClassColor(playerData.classToken)
    local valueR, valueG, valueB = GetPlayerItemLevelColor(itemLevel)

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine(label, string.format("%.1f", itemLevel), labelR, labelG, labelB, valueR, valueG, valueB)
    tooltipPlayerItemLevelGUID[tooltip] = guid

    if not skipShow then
        RefreshTooltipLayout(tooltip)
    end

    return true
end

---------------------------------------------------------------------------
-- SETUP HOOKS
---------------------------------------------------------------------------
local function SetupTooltipHook()
    ns.QUI_AnchorTooltipToCursor = AnchorTooltipToCursor

    hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip, parent)
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        if parent and parent.IsForbidden and parent:IsForbidden() then return end

        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end

        InvalidatePendingSetUnit()

        -- Visibility/context checks call methods on Blizzard frames (GetName,
        -- GetAttribute, GetActionInfo) which can taint the execution context
        -- during combat. Skip them — combat hiding is handled by the SetUnit
        -- hook and OnCombatStateChanged instead.
        if not InCombatLockdown() then
            local context = Provider:GetTooltipContext(parent)
            if context and not Provider:ShouldShowTooltip(context) then
                tooltip:Hide()
                tooltip:SetOwner(UIParent, "ANCHOR_NONE")
                tooltip:ClearLines()
                return
            end
        end

        -- Cursor positioning uses cached UIParent scale and
        -- GetCursorPosition (screen coords, not restricted) — safe in combat.
        if settings.anchorToCursor then
            -- Don't call AnchorTooltipToCursor here — it calls SetOwner()
            -- which re-taints the tooltip from addon context, breaking
            -- widget-set layout (secret value arithmetic on child frames).
            -- Blizzard already called SetOwner(parent, "ANCHOR_NONE") inside
            -- GameTooltip_SetDefaultAnchor before this hook fires.
            EnsureCursorFollowHooks(tooltip)
            cursorFollowActive[tooltip] = true
            Provider:PositionTooltipAtCursor(tooltip, settings)
        else
            cursorFollowActive[tooltip] = nil
        end
    end)

    -- TAINT SAFETY: Use TooltipDataProcessor instead of hooksecurefunc(GameTooltip, "SetUnit")
    -- to avoid tainting GameTooltip's dispatch tables.
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip ~= GameTooltip then return end
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end

        if settings.hideInCombat and InCombatLockdown() then
            if not settings.combatKey or settings.combatKey == "NONE" or not Provider:IsModifierActive(settings.combatKey) then
                tooltip:Hide()
                return
            end
        end

        local owner = tooltip:GetOwner()
        local token = pendingSetUnitToken + 1
        pendingSetUnitToken = token
        C_Timer.After(0.1, function()
            if token ~= pendingSetUnitToken then return end
            if tooltip.IsForbidden and tooltip:IsForbidden() then return end
            if not tooltip:IsShown() then return end
            if tooltip:GetOwner() ~= owner then return end
            if owner ~= UIParent then return end
            local unit = ResolveTooltipUnit(tooltip)
            if unit and UnitExists(unit) then return end
            if UnitExists("mouseover") then return end
            if Provider:IsFrameBlockingMouse() then
                tooltip:Hide()
            end
        end)
    end)

    -- Class color player names
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip ~= GameTooltip then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.classColorName then return end

        local unit = ResolveTooltipUnit(tooltip)
        if not unit then return end

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

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip ~= GameTooltip then return end
        if InCombatLockdown() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.showPlayerItemLevel then return end

        local unit = ResolveTooltipUnit(tooltip)
        if not unit then return end

        local okPlayer, isPlayer = pcall(UnitIsPlayer, unit)
        if not okPlayer or not isPlayer then return end

        tooltipPlayerItemLevelGUID[tooltip] = nil
        AddPlayerItemLevelToTooltip(tooltip, unit, true)
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

    -- Spell ID tracking (per-tooltip dedupe signature)
    local tooltipSpellIDAdded = setmetatable({}, {__mode = "k"})

    -- TAINT SAFETY: Use a separate watcher frame to detect GameTooltip
    -- hide/clear instead of HookScript("OnHide"/"OnTooltipCleared").
    -- HookScript on GameTooltip permanently taints its dispatch tables.
    local gtSpellIDWatcher = CreateFrame("Frame")
    local gtSpellIDWasShown = false
    gtSpellIDWatcher:SetScript("OnUpdate", function()
        local shown = GameTooltip:IsShown()
        if gtSpellIDWasShown and not shown then
            InvalidatePendingSetUnit()
            tooltipSpellIDAdded[GameTooltip] = nil
        end
        gtSpellIDWasShown = shown
    end)

    local function ResolveSpellIDFromTooltipData(tooltip, data)
        if data then
            local fromID = data.id
            if type(fromID) == "number" then
                if not (type(issecretvalue) == "function" and issecretvalue(fromID)) then
                    return fromID
                end
            end

            local fromSpellID = data.spellID
            if type(fromSpellID) == "number" then
                if not (type(issecretvalue) == "function" and issecretvalue(fromSpellID)) then
                    return fromSpellID
                end
            end
        end

        if tooltip and tooltip.GetSpell then
            local ok, a, b, c, d = pcall(tooltip.GetSpell, tooltip)
            if ok then
                if type(d) == "number" then return d end
                if type(c) == "number" then return c end
                if type(b) == "number" then return b end
                if type(a) == "number" then return a end
            end
        end

        return nil
    end

    local function BuildSpellIDDedupeKey(data, spellID)
        if not data or type(data.dataInstanceID) ~= "number" then
            return "spell:" .. tostring(spellID)
        end
        return tostring(data.dataInstanceID) .. ":" .. tostring(spellID)
    end

    local function AddSpellIDToTooltip(tooltip, spellID, data, skipShow)
        if not spellID then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled or not settings.showSpellIDs then return end
        if type(spellID) ~= "number" then return end
        if type(issecretvalue) == "function" and issecretvalue(spellID) then return end
        local dedupeKey = BuildSpellIDDedupeKey(data, spellID)
        if tooltipSpellIDAdded[tooltip] == dedupeKey then return end
        tooltipSpellIDAdded[tooltip] = dedupeKey

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
            local spellID = ResolveSpellIDFromTooltipData(tooltip, data)
            if spellID then
                AddSpellIDToTooltip(tooltip, spellID, data)
            end
        end)
    end)

    local auraTooltipType = Enum.TooltipDataType.UnitAura or Enum.TooltipDataType.Aura
    if auraTooltipType then
        TooltipDataProcessor.AddTooltipPostCall(auraTooltipType, function(tooltip, data)
            if InCombatLockdown() then return end
            pcall(function()
                local spellID = ResolveSpellIDFromTooltipData(tooltip, data)
                if spellID then
                    AddSpellIDToTooltip(tooltip, spellID, data, false)
                end
            end)
        end)
    end

    -- TAINT SAFETY: Aura spell ID display now uses TooltipDataProcessor
    -- instead of hooksecurefunc(GameTooltip, auraMethod). The Aura
    -- TooltipDataProcessor callback above already handles spell IDs for
    -- aura tooltips. The per-method hooks were redundant and tainted
    -- GameTooltip's dispatch tables.

    -- TAINT SAFETY: Suppress tooltips that bypass GameTooltip_SetDefaultAnchor.
    -- Uses TooltipDataProcessor instead of hooksecurefunc(GameTooltip, "SetSpellByID"/"SetItemByID")
    -- to avoid tainting GameTooltip's dispatch tables.
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip)
        if tooltip ~= GameTooltip then return end
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end
        InvalidatePendingSetUnit()
        if ShouldHideOwnedTooltip(tooltip) then
            tooltip:Hide()
        end
    end)

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip ~= GameTooltip then return end
        if tooltip.IsForbidden and tooltip:IsForbidden() then return end
        local settings = Provider:GetSettings()
        if not settings or not settings.enabled then return end
        InvalidatePendingSetUnit()
        if ShouldHideOwnedTooltip(tooltip) then
            tooltip:Hide()
        end
    end)

    if TooltipInspect and TooltipInspect.RegisterRefreshCallback then
        TooltipInspect:RegisterRefreshCallback(function(guid)
            if not GameTooltip or not GameTooltip:IsShown() then return end
            if InCombatLockdown() then return end

            local settings = Provider:GetSettings()
            if not settings or not settings.enabled or not settings.showPlayerItemLevel then return end

            local unit = ResolveTooltipUnit(GameTooltip)
            if not unit or UnitGUID(unit) ~= guid then return end

            AddPlayerItemLevelToTooltip(GameTooltip, unit, false)
        end)
    end

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
    if context and not Provider:ShouldShowTooltip(context) then
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
    TooltipInspect = ns.TooltipInspect

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
