--[[
    QUI Action Bars - Owned Mirror Engine
    Creates addon-owned visual frames that mirror Blizzard action button state
    via hooksecurefunc. Blizzard buttons stay alive at alpha=0 so paging,
    state drivers, and keybinds continue working. Click forwarding uses
    SecureActionButtonTemplate with clickbutton attribute.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local GetCore = Helpers.GetCore
local LSM = LibStub("LibSharedMedia-3.0")

-- ADDON_LOADED safe window flag: during a combat /reload, InCombatLockdown()
-- returns true but protected calls are still allowed. This flag lets
-- initialization sub-functions bypass their combat guards.
local inInitSafeWindow = false

---------------------------------------------------------------------------
-- MIDNIGHT (12.0+) DETECTION
---------------------------------------------------------------------------

local IS_MIDNIGHT = select(4, GetBuildInfo()) >= 120000

---------------------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------------------

-- In-housed textures (self-contained, no external dependencies)
local TEXTURE_PATH = [[Interface\AddOns\QUI\assets\iconskin\]]
local TEXTURES = {
    normal = TEXTURE_PATH .. "Normal",       -- Black border frame
    gloss = TEXTURE_PATH .. "Gloss",         -- ADD blend shine
    highlight = TEXTURE_PATH .. "Highlight", -- Hover state
    pushed = TEXTURE_PATH .. "Pushed",       -- Click state
    checked = TEXTURE_PATH .. "Checked",     -- Selected state
    flash = TEXTURE_PATH .. "Flash",         -- Ready flash
}

-- Icon texture coordinates (crop transparent edges)
local ICON_TEXCOORD = {0.07, 0.93, 0.07, 0.93}

-- Blizzard's range indicator placeholder (to detect and hide)
local RANGE_INDICATOR = RANGE_INDICATOR or "●"

-- Bar frame name mappings (MainMenuBar was renamed to MainActionBar in Midnight 12.0)
local BAR_FRAMES = {
    bar1 = "MainActionBar",
    bar2 = "MultiBarBottomLeft",
    bar3 = "MultiBarBottomRight",
    bar4 = "MultiBarRight",
    bar5 = "MultiBarLeft",
    bar6 = "MultiBar5",
    bar7 = "MultiBar6",
    bar8 = "MultiBar7",
    pet = "PetActionBar",
    stance = "StanceBar",
    -- Non-standard bars (special handling in GetBarButtons)
    microbar = "MicroMenuContainer",
    bags = "BagsBar",
    extraActionButton = "ExtraActionBarFrame",  -- Boss encounters, quests
    zoneAbility = "ZoneAbilityFrame",          -- Garrison, covenant, zone powers
}

-- Button name patterns for each bar
local BUTTON_PATTERNS = {
    bar1 = "ActionButton%d",
    bar2 = "MultiBarBottomLeftButton%d",
    bar3 = "MultiBarBottomRightButton%d",
    bar4 = "MultiBarRightButton%d",
    bar5 = "MultiBarLeftButton%d",
    bar6 = "MultiBar5Button%d",
    bar7 = "MultiBar6Button%d",
    bar8 = "MultiBar7Button%d",
    pet = "PetActionButton%d",
    stance = "StanceButton%d",
}

-- Button counts per bar
local BUTTON_COUNTS = {
    bar1 = 12, bar2 = 12, bar3 = 12, bar4 = 12, bar5 = 12,
    bar6 = 12, bar7 = 12, bar8 = 12, pet = 10, stance = 10,
}

-- Binding command prefixes for LibKeyBound integration
local BINDING_COMMANDS = {
    bar1 = "ACTIONBUTTON",           -- ACTIONBUTTON1-12
    bar2 = "MULTIACTIONBAR1BUTTON",  -- MULTIACTIONBAR1BUTTON1-12
    bar3 = "MULTIACTIONBAR2BUTTON",  -- MULTIACTIONBAR2BUTTON1-12
    bar4 = "MULTIACTIONBAR3BUTTON",  -- MULTIACTIONBAR3BUTTON1-12
    bar5 = "MULTIACTIONBAR4BUTTON",  -- MULTIACTIONBAR4BUTTON1-12
    bar6 = "MULTIACTIONBAR5BUTTON",  -- MULTIACTIONBAR5BUTTON1-12
    bar7 = "MULTIACTIONBAR6BUTTON",  -- MULTIACTIONBAR6BUTTON1-12
    bar8 = "MULTIACTIONBAR7BUTTON",  -- MULTIACTIONBAR7BUTTON1-12
    pet = "BONUSACTIONBUTTON",       -- BONUSACTIONBUTTON1-10
    stance = "SHAPESHIFTBUTTON",     -- SHAPESHIFTBUTTON1-10
}

-- Standard action bar keys (bars 1-8, not pet/stance)
local STANDARD_BAR_KEYS = {"bar1", "bar2", "bar3", "bar4", "bar5", "bar6", "bar7", "bar8"}

---------------------------------------------------------------------------
-- MODULE STATE
---------------------------------------------------------------------------

local ActionBarsOwned = {
    initialized = false,
    containers = {},       -- barKey → container frame
    mirrorButtons = {},    -- barKey → { mirrorButton, ... }
    cachedLayouts = {},    -- barKey → { numCols, numRows, isVertical, numIcons }
    editModeActive = false,
    editOverlays = {},     -- barKey → overlay frame
    pendingExtraButtonRefresh = false,
    pendingExtraButtonInit = false,
}
ns.ActionBarsOwned = ActionBarsOwned

local hiddenBarParent = CreateFrame("Frame")
hiddenBarParent:Hide()

-- Weak-keyed state tables (taint-safe — no writes to Blizzard frames)
local blizzBtnState = setmetatable({}, { __mode = "k" })   -- blizzButton → { mirror = ..., hooked = bool }
local blizzIconState = setmetatable({}, { __mode = "k" })  -- blizzButton.icon → { mirror = mirrorBtn }
local blizzCDState = setmetatable({}, { __mode = "k" })    -- blizzButton.cooldown → { mirror = mirrorBtn }
local blizzCountState = setmetatable({}, { __mode = "k" }) -- blizzButton.Count → { mirror = mirrorBtn }
local blizzHKState = setmetatable({}, { __mode = "k" })    -- blizzButton.HotKey → { mirror = mirrorBtn }

-- Store QUI state outside secure Blizzard frame tables.
-- Writing custom keys directly on action buttons can taint secret values.
-- UNIFIED: both LibKeyBound patch and keybind registration use this single table.
local frameState, GetFrameState = Helpers.CreateStateTable()

---------------------------------------------------------------------------
-- DB ACCESSORS
---------------------------------------------------------------------------

local GetDB = Helpers.CreateDBGetter("actionBars")

local function GetGlobalSettings()
    local db = GetDB()
    return db and db.global
end

local function GetBarSettings(barKey)
    local db = GetDB()
    return db and db.bars and db.bars[barKey]
end

local function GetFadeSettings()
    local db = GetDB()
    return db and db.fade
end

-- Effective settings (global merged with per-bar overrides)
local function GetEffectiveSettings(barKey)
    local global = GetGlobalSettings()
    if not global then return nil end

    local barSettings = GetBarSettings(barKey)
    if not barSettings then
        return global
    end

    local effective = {}
    for key, value in pairs(global) do
        effective[key] = value
    end
    for key, value in pairs(barSettings) do
        effective[key] = value
    end

    return effective
end

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------

-- Safe wrapper for HasAction which may return secret values in Midnight
local function SafeHasAction(action)
    if IS_MIDNIGHT then
        local ok, result = pcall(function()
            local has = HasAction(action)
            -- Force comparison to detect secrets
            if has then return true end
            return false
        end)
        if not ok then return true end  -- Secret value, treat as having action
        return result
    else
        return HasAction(action)
    end
end

local function SafeIsActionInRange(action)
    if IS_MIDNIGHT then
        local ok, result = pcall(function()
            local inRange = IsActionInRange(action)
            if inRange == false then return false end
            if inRange == true then return true end
            return nil
        end)
        if not ok then return nil end
        return result
    else
        return IsActionInRange(action)
    end
end

local function SafeIsUsableAction(action)
    if IS_MIDNIGHT then
        local ok, isUsable, notEnoughMana = pcall(function()
            local usable, noMana = IsUsableAction(action)
            local boolUsable = usable and true or false
            local boolNoMana = noMana and true or false
            return boolUsable, boolNoMana
        end)
        if not ok then return true, false end
        return isUsable, notEnoughMana
    else
        return IsUsableAction(action)
    end
end

local function IsPlayerBelowMaxLevel()
    local level = UnitLevel("player")
    if not level or level <= 0 then return false end

    local maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion() or MAX_PLAYER_LEVEL or 80
    if not maxLevel or maxLevel <= 0 then return false end

    return level < maxLevel
end

local function ShouldSuppressMouseoverHideForLevel()
    local fadeSettings = GetFadeSettings()
    return fadeSettings and fadeSettings.disableBelowMaxLevel and IsPlayerBelowMaxLevel()
end

local function IsLeaveVehicleButtonVisible()
    -- Only apply when player is actually in a vehicle; prevents bar1 staying visible
    -- when keepLeaveVehicleVisible is enabled but player is not in a vehicle
    if not (UnitInVehicle and UnitInVehicle("player")) then
        return false
    end

    if CanExitVehicle and CanExitVehicle() then
        return true
    end

    local mainLeaveButton = _G.MainMenuBarVehicleLeaveButton
    if mainLeaveButton and mainLeaveButton.IsShown and mainLeaveButton:IsShown() then
        return true
    end

    local overrideBar = _G.OverrideActionBar
    local overrideLeaveButton = overrideBar and overrideBar.LeaveButton
    if overrideLeaveButton and overrideLeaveButton.IsShown and overrideLeaveButton:IsShown() then
        return true
    end

    return false
end

local function ShouldKeepLeaveVehicleVisible()
    local fadeSettings = GetFadeSettings()
    if not (fadeSettings and fadeSettings.keepLeaveVehicleVisible) then
        return false
    end
    return IsLeaveVehicleButtonVisible()
end

local function ApplyLeaveVehicleButtonVisibilityOverride(forceVisible)
    local mainLeaveButton = _G.MainMenuBarVehicleLeaveButton
    local overrideBar = _G.OverrideActionBar
    local overrideLeaveButton = overrideBar and overrideBar.LeaveButton
    local leaveButtons = { mainLeaveButton, overrideLeaveButton }

    for _, button in ipairs(leaveButtons) do
        if button then
            local keepOpaque = forceVisible and button.IsShown and button:IsShown()
            if button.SetIgnoreParentAlpha then
                button:SetIgnoreParentAlpha(keepOpaque)
            end
            if keepOpaque then
                button:SetAlpha(1)
            end
        end
    end
end

local function IsSpellBookVisible()
    local spellBookFrame = _G.SpellBookFrame
    if spellBookFrame and spellBookFrame.IsShown and spellBookFrame:IsShown() then
        return true
    end

    local playerSpellsFrame = _G.PlayerSpellsFrame
    if playerSpellsFrame and playerSpellsFrame.IsShown and playerSpellsFrame:IsShown() then
        local embeddedSpellBook = playerSpellsFrame.SpellBookFrame
        if embeddedSpellBook and embeddedSpellBook.IsShown then
            return embeddedSpellBook:IsShown()
        end
        return true
    end

    return false
end

local function ShouldForceShowForSpellBook()
    local fadeSettings = GetFadeSettings()
    return fadeSettings and fadeSettings.showWhenSpellBookOpen and IsSpellBookVisible()
end

local function GetSpellFlyoutSourceButton(flyout)
    if not flyout then return nil end

    local sourceButton = rawget(flyout, "flyoutButton")
    if not sourceButton and flyout.GetParent then
        sourceButton = flyout:GetParent()
    end

    return sourceButton
end

local function GetSpellFlyoutSourceBarKey(flyout)
    local sourceButton = GetSpellFlyoutSourceButton(flyout)
    if not sourceButton then return nil end

    local name = sourceButton.GetName and sourceButton:GetName()
    if not name then return nil end

    if name:match("^ActionButton%d+$") then return "bar1" end
    if name:match("^MultiBarBottomLeftButton%d+$") then return "bar2" end
    if name:match("^MultiBarBottomRightButton%d+$") then return "bar3" end
    if name:match("^MultiBarRightButton%d+$") then return "bar4" end
    if name:match("^MultiBarLeftButton%d+$") then return "bar5" end
    if name:match("^MultiBar5Button%d+$") then return "bar6" end
    if name:match("^MultiBar6Button%d+$") then return "bar7" end
    if name:match("^MultiBar7Button%d+$") then return "bar8" end
    if name:match("^PetActionButton%d+$") then return "pet" end
    if name:match("^StanceButton%d+$") then return "stance" end

    return nil
end

local function IsSpellFlyoutActiveForBar(barKey)
    if not barKey then return false end

    local flyout = _G.SpellFlyout
    if not (flyout and flyout.IsShown and flyout:IsShown()) then
        return false
    end

    local sourceBarKey = GetSpellFlyoutSourceBarKey(flyout)
    if not sourceBarKey then
        return false
    end

    return sourceBarKey == barKey
end

local function ShouldSuspendMouseoverFade(barKey)
    return ShouldForceShowForSpellBook() or IsSpellFlyoutActiveForBar(barKey)
end

local SPELL_UI_FADE_RECHECK_DELAY = 0.1

local function CancelBarFadeTimers(state)
    if not state then return end
    if state.delayTimer then
        state.delayTimer:Cancel()
        state.delayTimer = nil
    end
    if state.leaveCheckTimer then
        state.leaveCheckTimer:Cancel()
        state.leaveCheckTimer = nil
    end
end

local function UpdateLevelSuppressionState()
    local suppress = ShouldSuppressMouseoverHideForLevel()
    if ActionBarsOwned.levelSuppressionActive == suppress then
        return false
    end
    ActionBarsOwned.levelSuppressionActive = suppress
    return true
end

local function GetFontSettings()
    local fontPath = "Fonts\\FRIZQT__.TTF"
    local outline = "OUTLINE"
    local core = GetCore()
    if core and core.db and core.db.profile and core.db.profile.general then
        local general = core.db.profile.general
        if general.font and LSM then
            fontPath = LSM:Fetch("font", general.font) or fontPath
        end
        outline = general.fontOutline or outline
    end
    return fontPath, outline
end

-- Determine bar key from button name
local function GetBarKeyFromButton(button)
    local name = button and button:GetName()
    if not name then return nil end

    if name:match("^ActionButton%d+$") then return "bar1" end
    if name:match("^MultiBarBottomLeftButton%d+$") then return "bar2" end
    if name:match("^MultiBarBottomRightButton%d+$") then return "bar3" end
    if name:match("^MultiBarRightButton%d+$") then return "bar4" end
    if name:match("^MultiBarLeftButton%d+$") then return "bar5" end
    if name:match("^MultiBar5Button%d+$") then return "bar6" end
    if name:match("^MultiBar6Button%d+$") then return "bar7" end
    if name:match("^MultiBar7Button%d+$") then return "bar8" end
    if name:match("^PetActionButton%d+$") then return "pet" end
    if name:match("^StanceButton%d+$") then return "stance" end
    return nil
end

-- Get button index from button name
local function GetButtonIndex(button)
    local name = button and button:GetName()
    if not name then return nil end
    return tonumber(name:match("%d+$"))
end

local function GetBarFrame(barKey)
    local frameName = BAR_FRAMES[barKey]
    local frame = frameName and _G[frameName]
    if not frame and barKey == "bar1" then
        frame = _G["MainMenuBar"]
    end
    return frame
end

local function GetBarButtons(barKey)
    local buttons = {}

    -- Special handling for non-standard bars
    if barKey == "microbar" then
        if MicroMenu then
            for _, child in ipairs({MicroMenu:GetChildren()}) do
                if child.IsObjectType and child:IsObjectType("Button") then
                    table.insert(buttons, child)
                end
            end
        end
        return buttons
    elseif barKey == "bags" then
        if MainMenuBarBackpackButton then
            table.insert(buttons, MainMenuBarBackpackButton)
        end
        for i = 0, 3 do
            local slot = _G["CharacterBag" .. i .. "Slot"]
            if slot then table.insert(buttons, slot) end
        end
        if CharacterReagentBag0Slot then
            table.insert(buttons, CharacterReagentBag0Slot)
        end
        return buttons
    elseif barKey == "extraActionButton" then
        if ExtraActionBarFrame and ExtraActionBarFrame.button then
            table.insert(buttons, ExtraActionBarFrame.button)
        end
        return buttons
    elseif barKey == "zoneAbility" then
        if ZoneAbilityFrame and ZoneAbilityFrame.SpellButtonContainer then
            for button in ZoneAbilityFrame.SpellButtonContainer:EnumerateActive() do
                table.insert(buttons, button)
            end
        end
        return buttons
    end

    -- Standard bars with numbered buttons
    local pattern = BUTTON_PATTERNS[barKey]
    local count = BUTTON_COUNTS[barKey] or 12
    if not pattern then return buttons end

    for i = 1, count do
        local buttonName = string.format(pattern, i)
        local button = _G[buttonName]
        if button then
            table.insert(buttons, button)
        end
    end

    return buttons
end

-- Read the bar's grid layout from Edit Mode API
local function GetBarGridLayout(barFrame, buttons)
    local isVertical = false
    local numCols, numRows

    local EditModeSettings = Enum.EditModeActionBarSetting
    if barFrame and barFrame.GetSettingValue and EditModeSettings then
        local okO, orientation = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.Orientation)
        local okR, editNumRows = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.NumRows)

        if okO and okR and editNumRows and editNumRows > 0 then
            isVertical = (orientation == 1)
            if isVertical then
                numCols = editNumRows
                numRows = math.ceil(#buttons / numCols)
            else
                numRows = editNumRows
                numCols = math.ceil(#buttons / numRows)
            end
        end
    end

    if not numCols then
        -- Fallback: detect from button positions
        if #buttons < 2 then
            numCols = #buttons
        else
            local firstTop = buttons[1]:GetTop()
            if firstTop then
                local buttonHeight = buttons[1]:GetHeight() or 30
                local threshold = buttonHeight * 0.3
                numCols = 1
                for i = 2, #buttons do
                    local top = buttons[i]:GetTop()
                    if not top or math.abs(top - firstTop) > threshold then
                        break
                    end
                    numCols = numCols + 1
                end
            else
                numCols = #buttons
            end
        end
        numRows = math.ceil(#buttons / numCols)
    end

    return numCols, numRows, isVertical
end

-- Get visible icon count from Edit Mode API
local function GetVisibleIconCount(barFrame, totalButtons)
    local EditModeSettings = Enum.EditModeActionBarSetting
    if barFrame and barFrame.GetSettingValue and EditModeSettings then
        local ok, numIcons = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.NumIcons)
        if ok and numIcons and numIcons > 0 then
            return math.min(numIcons, totalButtons)
        end
    end
    return totalButtons
end

---------------------------------------------------------------------------
-- TEXT HELPERS
---------------------------------------------------------------------------

-- Strip WoW color codes from text
local function StripColorCodes(text)
    if not text then return "" end
    return text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

-- Check if keybind text is valid (not empty or placeholder)
local function IsValidKeybindText(text)
    if not text or text == "" then return false end

    local stripped = StripColorCodes(text)
    if stripped == "" then return false end
    if stripped == RANGE_INDICATOR then return false end
    if stripped == "[]" then return false end

    return true
end

---------------------------------------------------------------------------
-- MIDNIGHT LIBKEYBOUND COMPATIBILITY
-- On Midnight (12.0+) we cannot inject methods onto secure action buttons
-- without spreading taint. Instead we override LibKeyBound's Binder methods
-- to consult our external frameState table for binding commands.
-- UNIFIED: keybind registration writes to this same frameState.
---------------------------------------------------------------------------

local libKeyBoundPatched = false

local function PatchLibKeyBoundForMidnight()
    if not IS_MIDNIGHT then return end
    if libKeyBoundPatched then return end

    local LibKeyBound = LibStub("LibKeyBound-1.0", true)
    if not LibKeyBound then return end

    libKeyBoundPatched = true
    local Binder = LibKeyBound.Binder

    -- Helper: get binding command from our external state
    local function GetBindingCommand(button)
        local state = frameState[button]
        return state and state.bindingCommand
    end

    -- Override SetKey: use our frameState binding command when button lacks SetKey
    function Binder:SetKey(button, key)
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage(LibKeyBound.L.CannotBindInCombat, 1, 0.3, 0.3, 1, UIERRORS_HOLD_TIME)
            return
        end

        self:FreeKey(button, key)

        local command = GetBindingCommand(button)
        if command then
            SetBinding(key, command)
        elseif button.SetKey then
            button:SetKey(key)
        else
            SetBindingClick(key, button:GetName(), "LeftButton")
        end

        local msg
        if command then
            msg = format(LibKeyBound.L.BoundKey, GetBindingText(key), command)
        elseif button.GetActionName then
            msg = format(LibKeyBound.L.BoundKey, GetBindingText(key), button:GetActionName())
        else
            msg = format(LibKeyBound.L.BoundKey, GetBindingText(key), button:GetName())
        end
        UIErrorsFrame:AddMessage(msg, 1, 1, 1, 1, UIERRORS_HOLD_TIME)
    end

    -- Override ClearBindings: use our frameState binding command
    function Binder:ClearBindings(button)
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage(LibKeyBound.L.CannotBindInCombat, 1, 0.3, 0.3, 1, UIERRORS_HOLD_TIME)
            return
        end

        local command = GetBindingCommand(button)
        if command then
            while GetBindingKey(command) do
                SetBinding(GetBindingKey(command), nil)
            end
        elseif button.ClearBindings then
            button:ClearBindings()
        else
            local binding = self:ToBinding(button)
            while (GetBindingKey(binding)) do
                SetBinding(GetBindingKey(binding), nil)
            end
        end

        local msg
        if command then
            msg = format(LibKeyBound.L.ClearedBindings, command)
        elseif button.GetActionName then
            msg = format(LibKeyBound.L.ClearedBindings, button:GetActionName())
        else
            msg = format(LibKeyBound.L.ClearedBindings, button:GetName())
        end
        UIErrorsFrame:AddMessage(msg, 1, 1, 1, 1, UIERRORS_HOLD_TIME)
    end

    -- Override GetBindings: use our frameState binding command
    local origGetBindings = Binder.GetBindings
    function Binder:GetBindings(button)
        local command = GetBindingCommand(button)
        if command then
            local keys
            for i = 1, select("#", GetBindingKey(command)) do
                local hotKey = select(i, GetBindingKey(command))
                if keys then
                    keys = keys .. ", " .. GetBindingText(hotKey)
                else
                    keys = GetBindingText(hotKey)
                end
            end
            return keys
        end
        return origGetBindings(self, button)
    end

    -- Override FreeKey: check our frameState binding command for conflict resolution
    local origFreeKey = Binder.FreeKey
    function Binder:FreeKey(button, key)
        local command = GetBindingCommand(button)
        if command then
            local action = GetBindingAction(key)
            if action and action ~= "" and action ~= command then
                SetBinding(key, nil)
                local msg = format(LibKeyBound.L.UnboundKey, GetBindingText(key), action)
                UIErrorsFrame:AddMessage(msg, 1, 0.82, 0, 1, UIERRORS_HOLD_TIME)
            end
        else
            origFreeKey(self, button, key)
        end
    end

    -- Wrap LibKeyBound:Set — only override for buttons tracked in our frameState;
    -- delegate to the original for everything else so future library updates apply.
    local origSet = LibKeyBound.Set
    function LibKeyBound:Set(button, ...)
        -- If the button has no entry in our state, let the original handle it
        if not button or not GetBindingCommand(button) then
            return origSet(self, button, ...)
        end

        if self:IsShown() and not InCombatLockdown() then
            local bindFrame = self.frame
            if bindFrame then
                bindFrame.button = button
                bindFrame:SetAllPoints(button)

                -- Get hotkey text from our external state
                local hotkeyText
                local cmd = GetBindingCommand(button)
                if cmd then
                    local key = GetBindingKey(cmd)
                    if key then
                        hotkeyText = self:ToShortKey(key)
                    end
                end

                bindFrame.text:SetFontObject("GameFontNormalLarge")
                bindFrame.text:SetText(hotkeyText or "")
                if bindFrame.text:GetStringWidth() > bindFrame:GetWidth() then
                    bindFrame.text:SetFontObject("GameFontNormal")
                end
                bindFrame:Show()
                bindFrame:OnEnter()
            end
        elseif self.frame then
            self.frame.button = nil
            self.frame:ClearAllPoints()
            self.frame:Hide()
        end
    end

    -- Wrap Binder:OnEnter — only override for our frameState buttons; delegate
    -- to the original for everything else.
    local origOnEnter = Binder.OnEnter
    function Binder:OnEnter()
        local button = self.button
        if not button or not GetBindingCommand(button) then
            return origOnEnter(self)
        end

        if not InCombatLockdown() then
            if self:GetRight() >= (GetScreenWidth() / 2) then
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            else
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            end

            local command = GetBindingCommand(button)
            GameTooltip:SetText(command, 1, 1, 1)

            local bindings = self:GetBindings(button)
            if bindings and bindings ~= "" then
                GameTooltip:AddLine(bindings, 0, 1, 0)
                GameTooltip:AddLine(LibKeyBound.L.ClearTip)
            else
                GameTooltip:AddLine(LibKeyBound.L.NoKeysBoundTip, 0, 1, 0)
            end
            GameTooltip:Show()
        else
            GameTooltip:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- MIRROR BUTTON FACTORY
---------------------------------------------------------------------------

local mirrorButtonPool = {}
local MAX_RECYCLE = 24

local function CreateMirrorButton(parent, globalName)
    local btn = CreateFrame("Frame", nil, parent)
    btn:SetSize(36, 36)

    -- Icon (ARTWORK layer)
    local icon = btn:CreateTexture(nil, "ARTWORK", nil, 0)
    icon:SetAllPoints()
    btn.Icon = icon

    -- Backdrop (BACKGROUND, behind icon)
    local backdrop = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    backdrop:SetColorTexture(0, 0, 0, 1)
    backdrop:SetAllPoints()
    btn.Backdrop = backdrop

    -- Cooldown frame
    local cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    btn.Cooldown = cd

    -- Text overlay (above cooldown)
    local textOverlay = CreateFrame("Frame", nil, btn)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(btn:GetFrameLevel() + 3)
    btn.TextOverlay = textOverlay

    -- HotKey text
    local hotKey = textOverlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    hotKey:SetPoint("TOPRIGHT", -2, -3)
    hotKey:SetJustifyH("RIGHT")
    btn.HotKey = hotKey

    -- Count text
    local count = textOverlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -2, 2)
    count:SetJustifyH("RIGHT")
    btn.Count = count

    -- Macro name text
    local name = textOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("BOTTOM", 0, 2)
    name:SetJustifyH("CENTER")
    name.maxWidth = 36
    btn.Name = name

    -- Normal border (OVERLAY)
    local normal = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    normal:SetTexture(TEXTURES.normal)
    normal:SetVertexColor(0, 0, 0, 1)
    normal:SetAllPoints()
    btn.Normal = normal

    -- Gloss overlay (ADD blend)
    local gloss = btn:CreateTexture(nil, "OVERLAY", nil, 2)
    gloss:SetTexture(TEXTURES.gloss)
    gloss:SetBlendMode("ADD")
    gloss:SetAllPoints()
    btn.Gloss = gloss

    -- Range/usability tint overlay (MOD blend, above icon)
    local tint = btn:CreateTexture(nil, "ARTWORK", nil, 1)
    tint:SetAllPoints(icon)
    tint:SetBlendMode("MOD")
    tint:SetColorTexture(1, 1, 1, 1)
    tint:Hide()
    btn.TintOverlay = tint

    -- Checked overlay (auto-attack glow)
    local checked = btn:CreateTexture(nil, "OVERLAY", nil, 3)
    checked:SetTexture(TEXTURES.checked)
    checked:SetAllPoints()
    checked:Hide()
    btn.CheckedOverlay = checked

    -- Highlight texture (shown on hover via click overlay)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture(TEXTURES.highlight)
    hl:SetAllPoints()
    hl:Hide()
    btn.Highlight = hl

    -- Pushed texture (shown on mouse down via click overlay)
    local pushed = btn:CreateTexture(nil, "OVERLAY", nil, 4)
    pushed:SetTexture(TEXTURES.pushed)
    pushed:SetAllPoints()
    pushed:Hide()
    btn.Pushed = pushed

    -- Internal state
    btn._blizzButton = nil
    btn._barKey = nil
    btn._buttonIndex = nil
    btn._isEmpty = false
    btn._tinted = nil
    btn._fadeHidden = false
    btn._procGlowing = false

    return btn
end

local function AcquireMirrorButton(parent, globalName)
    local btn
    if #mirrorButtonPool > 0 then
        btn = table.remove(mirrorButtonPool)
        btn:SetParent(parent)
    else
        btn = CreateMirrorButton(parent, globalName)
    end
    btn:Show()
    return btn
end

local function ReleaseMirrorButton(btn)
    btn:Hide()
    btn:ClearAllPoints()
    btn._blizzButton = nil
    btn._barKey = nil
    btn._buttonIndex = nil
    btn._isEmpty = false
    btn._tinted = nil
    btn._fadeHidden = false
    btn._procGlowing = false

    -- Clear glow if active
    if btn._procGlowing then
        local LCG = LibStub("LibCustomGlow-1.0", true)
        if LCG then LCG.HideOverlayGlow(btn) end
        btn._procGlowing = false
    end

    -- Clear click overlay attribute (but don't destroy)
    if btn.ClickOverlay then
        btn.ClickOverlay:Hide()
    end

    btn.Icon:SetTexture(nil)
    btn.Cooldown:Clear()
    btn.Count:SetText("")
    btn.HotKey:SetText("")
    btn.Name:SetText("")
    btn.TintOverlay:Hide()
    btn.CheckedOverlay:Hide()
    btn.Highlight:Hide()
    btn.Pushed:Hide()

    if #mirrorButtonPool < MAX_RECYCLE then
        mirrorButtonPool[#mirrorButtonPool + 1] = btn
    end
end

---------------------------------------------------------------------------
-- CLICK OVERLAY (SecureActionButtonTemplate)
---------------------------------------------------------------------------

local function CreateClickOverlay(mirrorBtn, blizzBtn, globalName)
    if mirrorBtn.ClickOverlay then
        -- Reuse existing
        if not InCombatLockdown() then
            mirrorBtn.ClickOverlay:SetAttribute("clickbutton", blizzBtn)
        end
        mirrorBtn.ClickOverlay:Show()
        return mirrorBtn.ClickOverlay
    end

    local click = CreateFrame("Button", globalName, mirrorBtn, "SecureActionButtonTemplate")
    click:SetAllPoints()
    click:RegisterForClicks("AnyUp", "AnyDown")
    click:SetAttribute("type", "click")
    click:SetAttribute("clickbutton", blizzBtn)

    -- Tooltip forwarding
    click:SetScript("OnEnter", function(self)
        local bBtn = self:GetAttribute("clickbutton")
        if bBtn then
            local onEnter = bBtn:GetScript("OnEnter")
            if onEnter then
                onEnter(bBtn)
            end
        end
        -- Show highlight
        local parent = self:GetParent()
        if parent and parent.Highlight then
            parent.Highlight:Show()
        end
        -- Fade system: notify bar enter
        if parent and parent._barKey then
            ActionBarsOwned:OnBarMouseEnter(parent._barKey)
        end
    end)

    click:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        local parent = self:GetParent()
        if parent and parent.Highlight then
            parent.Highlight:Hide()
        end
        if parent and parent._barKey then
            ActionBarsOwned:OnBarMouseLeave(parent._barKey)
        end
    end)

    click:SetScript("OnMouseDown", function(self)
        local parent = self:GetParent()
        if parent and parent.Pushed then
            parent.Pushed:Show()
        end
    end)

    click:SetScript("OnMouseUp", function(self)
        local parent = self:GetParent()
        if parent and parent.Pushed then
            parent.Pushed:Hide()
        end
    end)

    mirrorBtn.ClickOverlay = click
    return click
end

---------------------------------------------------------------------------
-- SKINNING (apply visual settings to a mirror button)
---------------------------------------------------------------------------

local function ApplyMirrorSkin(mirrorBtn, settings)
    if not settings then return end

    local zoom = settings.iconZoom or 0.05
    mirrorBtn.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)

    -- Backdrop
    if settings.showBackdrop then
        mirrorBtn.Backdrop:SetAlpha(settings.backdropAlpha or 0.8)
        mirrorBtn.Backdrop:Show()
    else
        mirrorBtn.Backdrop:Hide()
    end

    -- Normal border
    if settings.showBorders ~= false then
        mirrorBtn.Normal:Show()
    else
        mirrorBtn.Normal:Hide()
    end

    -- Gloss
    if settings.showGloss then
        mirrorBtn.Gloss:SetVertexColor(1, 1, 1, settings.glossAlpha or 0.6)
        mirrorBtn.Gloss:Show()
    else
        mirrorBtn.Gloss:Hide()
    end

    -- Cooldown swipe color
    local cd = mirrorBtn.Cooldown
    if cd.SetSwipeColor then
        cd:SetSwipeColor(0, 0, 0, 0.8)
    end

    -- HotKey text styling
    local hotKey = mirrorBtn.HotKey
    if settings.showKeybinds then
        local fontSize = settings.keybindFontSize or 16
        local font = hotKey:GetFont()
        if font then
            hotKey:SetFont(font, fontSize, "OUTLINE")
        end
        local c = settings.keybindColor
        if c then hotKey:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1) end

        hotKey:ClearAllPoints()
        local anchor = settings.keybindAnchor or "TOPRIGHT"
        local offX = settings.keybindOffsetX or 0
        local offY = settings.keybindOffsetY or -5
        hotKey:SetPoint(anchor, mirrorBtn, anchor, offX, offY)
        hotKey:Show()
    else
        hotKey:Hide()
    end

    -- Count text styling
    local count = mirrorBtn.Count
    if settings.showCounts then
        local fontSize = settings.countFontSize or 14
        local font = count:GetFont()
        if font then
            count:SetFont(font, fontSize, "OUTLINE")
        end
        local c = settings.countColor
        if c then count:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1) end

        count:ClearAllPoints()
        local anchor = settings.countAnchor or "BOTTOMRIGHT"
        local offX = settings.countOffsetX or 0
        local offY = settings.countOffsetY or 0
        count:SetPoint(anchor, mirrorBtn, anchor, offX, offY)
        count:Show()
    else
        count:Hide()
    end

    -- Macro name text styling
    local name = mirrorBtn.Name
    if settings.showMacroNames then
        local fontSize = settings.macroNameFontSize or 10
        local font = name:GetFont()
        if font then
            name:SetFont(font, fontSize, "OUTLINE")
        end
        local c = settings.macroNameColor
        if c then name:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1) end

        name:ClearAllPoints()
        local anchor = settings.macroNameAnchor or "BOTTOM"
        local offX = settings.macroNameOffsetX or 0
        local offY = settings.macroNameOffsetY or 0
        name:SetPoint(anchor, mirrorBtn, anchor, offX, offY)
        name:Show()
    else
        name:Hide()
    end
end

---------------------------------------------------------------------------
-- HOOK INSTALLATION (one-time per Blizzard button)
---------------------------------------------------------------------------

local function InstallBlizzButtonHooks(blizzBtn, mirrorBtn)
    local state = blizzBtnState[blizzBtn]
    if not state then
        state = {}
        blizzBtnState[blizzBtn] = state
    end
    state.mirror = mirrorBtn

    if state.hooked then return end
    state.hooked = true

    -- Icon texture hook
    local blizzIcon = blizzBtn.icon or blizzBtn.Icon
    if blizzIcon then
        blizzIconState[blizzIcon] = { mirror = mirrorBtn }

        hooksecurefunc(blizzIcon, "SetTexture", function(self, texture)
            local s = blizzIconState[self]
            if s and s.mirror then
                s.mirror.Icon:SetTexture(texture)
            end
        end)

        -- TexCoord changes (some bars modify for flyouts)
        if blizzIcon.SetTexCoord then
            hooksecurefunc(blizzIcon, "SetTexCoord", function(self, ...)
                -- We apply our own zoom, so ignore Blizzard's TexCoord changes
                -- (our zoom is applied in ApplyMirrorSkin)
            end)
        end
    end

    -- Cooldown hook
    local blizzCD = blizzBtn.cooldown or blizzBtn.Cooldown
    if blizzCD then
        blizzCDState[blizzCD] = { mirror = mirrorBtn }

        hooksecurefunc(blizzCD, "SetCooldown", function(self, start, duration)
            local s = blizzCDState[self]
            if s and s.mirror then
                pcall(s.mirror.Cooldown.SetCooldown, s.mirror.Cooldown, start, duration)
            end
        end)

        -- SetCooldownFromDurationObject if available (Midnight)
        if blizzCD.SetCooldownFromDurationObject then
            hooksecurefunc(blizzCD, "SetCooldownFromDurationObject", function(self, obj)
                local s = blizzCDState[self]
                if s and s.mirror and s.mirror.Cooldown.SetCooldownFromDurationObject then
                    pcall(s.mirror.Cooldown.SetCooldownFromDurationObject, s.mirror.Cooldown, obj)
                end
            end)
        end
    end

    -- Count text hook
    local blizzCount = blizzBtn.Count
    if blizzCount and blizzCount.SetText then
        blizzCountState[blizzCount] = { mirror = mirrorBtn }

        hooksecurefunc(blizzCount, "SetText", function(self, text)
            local s = blizzCountState[self]
            if s and s.mirror then
                s.mirror.Count:SetText(text or "")
            end
        end)
    end

    -- HotKey text hook
    local blizzHK = blizzBtn.HotKey or blizzBtn.hotKey
    if blizzHK and blizzHK.SetText then
        blizzHKState[blizzHK] = { mirror = mirrorBtn }

        hooksecurefunc(blizzHK, "SetText", function(self, text)
            local s = blizzHKState[self]
            if s and s.mirror then
                -- Apply keybind abbreviation
                local abbreviated = text
                if text and text ~= "" and ns.FormatKeybind then
                    abbreviated = ns.FormatKeybind(text)
                end
                s.mirror.HotKey:SetText(abbreviated or "")
            end
        end)
    end

    -- Checked state hook (auto-attack active, aura active)
    if blizzBtn.GetChecked then
        hooksecurefunc(blizzBtn, "SetChecked", function(self, checked)
            local s = blizzBtnState[self]
            if s and s.mirror then
                if checked then
                    s.mirror.CheckedOverlay:Show()
                else
                    s.mirror.CheckedOverlay:Hide()
                end
            end
        end)
    end
end

-- Update the mirror mapping without reinstalling hooks
local function UpdateMirrorMapping(blizzBtn, mirrorBtn)
    local state = blizzBtnState[blizzBtn]
    if state then
        state.mirror = mirrorBtn
    end

    local blizzIcon = blizzBtn.icon or blizzBtn.Icon
    if blizzIcon and blizzIconState[blizzIcon] then
        blizzIconState[blizzIcon].mirror = mirrorBtn
    end

    local blizzCD = blizzBtn.cooldown or blizzBtn.Cooldown
    if blizzCD and blizzCDState[blizzCD] then
        blizzCDState[blizzCD].mirror = mirrorBtn
    end

    local blizzCount = blizzBtn.Count
    if blizzCount and blizzCountState[blizzCount] then
        blizzCountState[blizzCount].mirror = mirrorBtn
    end

    local blizzHK = blizzBtn.HotKey or blizzBtn.hotKey
    if blizzHK and blizzHKState[blizzHK] then
        blizzHKState[blizzHK].mirror = mirrorBtn
    end
end

---------------------------------------------------------------------------
-- INITIAL STATE SYNC
---------------------------------------------------------------------------

local function SyncInitialState(blizzBtn, mirrorBtn, settings)
    -- Icon texture
    local blizzIcon = blizzBtn.icon or blizzBtn.Icon
    if blizzIcon then
        local ok, tex = pcall(blizzIcon.GetTexture, blizzIcon)
        if ok and tex then
            mirrorBtn.Icon:SetTexture(tex)
        end
    end

    -- Cooldown
    local blizzCD = blizzBtn.cooldown or blizzBtn.Cooldown
    if blizzCD then
        local ok, startMs, durMs = pcall(blizzCD.GetCooldownTimes, blizzCD)
        if ok and startMs and durMs then
            local start = Helpers.SafeToNumber(startMs)
            local dur = Helpers.SafeToNumber(durMs)
            if start and dur and start > 0 and dur > 0 then
                pcall(mirrorBtn.Cooldown.SetCooldown, mirrorBtn.Cooldown, start / 1000, dur / 1000)
            end
        end
    end

    -- Count text
    local blizzCount = blizzBtn.Count
    if blizzCount and blizzCount.GetText then
        local text = blizzCount:GetText()
        mirrorBtn.Count:SetText(text or "")
    end

    -- HotKey text
    local blizzHK = blizzBtn.HotKey or blizzBtn.hotKey
    if blizzHK and blizzHK.GetText then
        local text = blizzHK:GetText()
        if text and text ~= "" and ns.FormatKeybind then
            text = ns.FormatKeybind(text)
        end
        mirrorBtn.HotKey:SetText(text or "")
    end

    -- Macro name
    local blizzName = blizzBtn.Name
    if blizzName and blizzName.GetText then
        mirrorBtn.Name:SetText(blizzName:GetText() or "")
    end

    -- Checked state
    if blizzBtn.GetChecked then
        local ok, checked = pcall(blizzBtn.GetChecked, blizzBtn)
        if ok and checked then
            mirrorBtn.CheckedOverlay:Show()
        else
            mirrorBtn.CheckedOverlay:Hide()
        end
    end

    -- Apply keybind from binding system (more reliable than Blizzard's HotKey text)
    local barKey = mirrorBtn._barKey
    local idx = mirrorBtn._buttonIndex
    local prefix = BINDING_COMMANDS[barKey]
    if prefix and idx then
        local key = GetBindingKey(prefix .. idx)
        if key and ns.FormatKeybind then
            mirrorBtn.HotKey:SetText(ns.FormatKeybind(key))
        elseif not key then
            if settings and not settings.showKeybinds then
                mirrorBtn.HotKey:SetText("")
            end
        end
    end
end

---------------------------------------------------------------------------
-- EMPTY SLOT / USABILITY / PROC GLOW
---------------------------------------------------------------------------

local DRAG_PREVIEW_ALPHA = 0.3

local function CursorHasPlaceableAction()
    local infoType = GetCursorInfo()
    return infoType == "spell" or infoType == "item" or infoType == "macro"
        or infoType == "petaction" or infoType == "mount" or infoType == "flyout"
end

local function UpdateMirrorEmptyState(mirrorBtn, settings)
    if not settings or not mirrorBtn._blizzButton then return end
    local action = Helpers.SafeToNumber(mirrorBtn._blizzButton.action)
    if not action then return end

    if not settings.hideEmptySlots then
        if mirrorBtn._isEmpty then
            mirrorBtn._isEmpty = false
            mirrorBtn:SetAlpha(1)
        end
        return
    end

    local hasAction = SafeHasAction(action)
    if hasAction then
        if mirrorBtn._isEmpty then
            mirrorBtn._isEmpty = false
            mirrorBtn:SetAlpha(1)
        end
    else
        mirrorBtn._isEmpty = true
        if ActionBarsOwned.dragPreviewActive then
            mirrorBtn:SetAlpha(DRAG_PREVIEW_ALPHA)
        else
            mirrorBtn:SetAlpha(0)
        end
    end
end

local function UpdateMirrorUsability(mirrorBtn, settings)
    if not settings or not mirrorBtn._blizzButton then return end
    local action = Helpers.SafeToNumber(mirrorBtn._blizzButton.action)
    if not action then return end

    -- Skip invisible buttons
    if mirrorBtn._isEmpty or mirrorBtn._fadeHidden then
        return
    end

    local tint = mirrorBtn.TintOverlay

    if not settings.rangeIndicator and not settings.usabilityIndicator then
        if mirrorBtn._tinted then
            tint:Hide()
            mirrorBtn._tinted = nil
        end
        return
    end

    -- Range check
    if settings.rangeIndicator then
        local inRange = SafeIsActionInRange(action)
        if inRange == false then
            local c = settings.rangeColor
            tint:SetColorTexture(c and c[1] or 0.8, c and c[2] or 0.1, c and c[3] or 0.1, c and c[4] or 1)
            tint:Show()
            mirrorBtn._tinted = "range"
            return
        end
    end

    -- Usability check
    if settings.usabilityIndicator then
        local isUsable, notEnoughMana = SafeIsUsableAction(action)
        if notEnoughMana then
            local c = settings.manaColor
            tint:SetColorTexture(c and c[1] or 0.5, c and c[2] or 0.5, c and c[3] or 1.0, c and c[4] or 1)
            tint:Show()
            mirrorBtn._tinted = "mana"
            return
        elseif not isUsable then
            if settings.usabilityDesaturate then
                tint:SetColorTexture(0.4, 0.4, 0.4, 1)
            else
                local c = settings.usabilityColor
                tint:SetColorTexture(c and c[1] or 0.4, c and c[2] or 0.4, c and c[3] or 0.4, c and c[4] or 1)
            end
            tint:Show()
            mirrorBtn._tinted = "unusable"
            return
        end
    end

    -- Normal state
    if mirrorBtn._tinted then
        tint:Hide()
        mirrorBtn._tinted = nil
    end
end

-- Proc glow forwarding via overlay glow hooks
local function SetupProcGlowHooks()
    if ActionButton_ShowOverlayGlow then
        hooksecurefunc("ActionButton_ShowOverlayGlow", function(blizzBtn)
            local state = blizzBtnState[blizzBtn]
            if state and state.mirror then
                local LCG = LibStub("LibCustomGlow-1.0", true)
                if LCG then
                    LCG.ShowOverlayGlow(state.mirror)
                    state.mirror._procGlowing = true
                end
            end
        end)
    end

    if ActionButton_HideOverlayGlow then
        hooksecurefunc("ActionButton_HideOverlayGlow", function(blizzBtn)
            local state = blizzBtnState[blizzBtn]
            if state and state.mirror then
                local LCG = LibStub("LibCustomGlow-1.0", true)
                if LCG then
                    LCG.HideOverlayGlow(state.mirror)
                    state.mirror._procGlowing = false
                end
            end
        end)
    end
end

---------------------------------------------------------------------------
-- CONTAINER FACTORY
---------------------------------------------------------------------------

local function CreateBarContainer(barKey)
    local containerName = "QUI_ActionBar_" .. barKey
    local container = CreateFrame("Frame", containerName, UIParent)
    container:SetSize(1, 1)
    container:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    container:Show()
    container:SetClampedToScreen(true)
    return container
end

---------------------------------------------------------------------------
-- LAYOUT ENGINE
---------------------------------------------------------------------------

-- Read layout settings from ownedLayout DB (fully independent of Blizzard Edit Mode)
local function GetOwnedLayout(barKey)
    local barDB = GetBarSettings(barKey)
    local layout = barDB and barDB.ownedLayout
    if not layout then
        return "horizontal", 12, 12, false, false, nil, nil
    end
    return
        layout.orientation or "horizontal",
        layout.columns or 12,
        layout.iconCount or 12,
        layout.growUp or false,
        layout.growLeft or false,
        layout.buttonSize,
        layout.buttonSpacing
end

local function LayoutMirrorButtons(barKey)
    local container = ActionBarsOwned.containers[barKey]
    local mirrors = ActionBarsOwned.mirrorButtons[barKey]
    if not container or not mirrors or #mirrors == 0 then return end

    local blizzButtons = GetBarButtons(barKey)
    if #blizzButtons == 0 then return end

    local orientation, columns, iconCount, growUp, growLeft, sizeOverride, spacingOverride = GetOwnedLayout(barKey)
    local isVertical = (orientation == "vertical")

    local numVisible = math.min(iconCount, #mirrors)

    for i, mirror in ipairs(mirrors) do
        if i <= numVisible then
            if not mirror._isEmpty then
                mirror:Show()
            end
        else
            mirror:Hide()
        end
    end

    local visibleMirrors = {}
    for i = 1, numVisible do
        visibleMirrors[#visibleMirrors + 1] = mirrors[i]
    end
    if #visibleMirrors == 0 then return end

    local btnWidth, btnHeight
    if sizeOverride and sizeOverride > 0 then
        btnWidth = sizeOverride
        btnHeight = sizeOverride
    else
        btnWidth = blizzButtons[1]:GetWidth() or 36
        btnHeight = blizzButtons[1]:GetHeight() or 36
    end

    local spacing
    if spacingOverride then
        spacing = spacingOverride
    else
        local settings = GetGlobalSettings()
        spacing = settings and settings.buttonSpacing or 2
    end

    local numCols, numRows
    if isVertical then
        local buttonsPerCol = math.max(1, columns)
        numRows = buttonsPerCol
        numCols = math.ceil(#visibleMirrors / buttonsPerCol)
    else
        numCols = math.max(1, columns)
        numRows = math.ceil(#visibleMirrors / numCols)
    end

    visibleMirrors[1]:ClearAllPoints()
    visibleMirrors[1]:SetSize(btnWidth, btnHeight)

    if isVertical then
        local buttonsPerCol = numRows
        if growLeft then
            visibleMirrors[1]:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
        else
            visibleMirrors[1]:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        end

        for i = 2, #visibleMirrors do
            visibleMirrors[i]:ClearAllPoints()
            visibleMirrors[i]:SetSize(btnWidth, btnHeight)
            local rowInCol = (i - 1) % buttonsPerCol

            if rowInCol == 0 then
                local prevColStart = i - buttonsPerCol
                if growLeft then
                    visibleMirrors[i]:SetPoint("TOPRIGHT", visibleMirrors[prevColStart], "TOPLEFT", -spacing, 0)
                else
                    visibleMirrors[i]:SetPoint("TOPLEFT", visibleMirrors[prevColStart], "TOPRIGHT", spacing, 0)
                end
            else
                visibleMirrors[i]:SetPoint("TOPLEFT", visibleMirrors[i - 1], "BOTTOMLEFT", 0, -spacing)
            end
        end
    else
        if growUp then
            visibleMirrors[1]:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
        else
            visibleMirrors[1]:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        end

        for i = 2, #visibleMirrors do
            visibleMirrors[i]:ClearAllPoints()
            visibleMirrors[i]:SetSize(btnWidth, btnHeight)
            local colIndex = ((i - 1) % numCols) + 1

            if colIndex == 1 then
                local prevRowStart = visibleMirrors[i - numCols]
                if growUp then
                    visibleMirrors[i]:SetPoint("BOTTOMLEFT", prevRowStart, "TOPLEFT", 0, spacing)
                else
                    visibleMirrors[i]:SetPoint("TOPLEFT", prevRowStart, "BOTTOMLEFT", 0, -spacing)
                end
            else
                if growLeft then
                    visibleMirrors[i]:SetPoint("RIGHT", visibleMirrors[i - 1], "LEFT", -spacing, 0)
                else
                    visibleMirrors[i]:SetPoint("LEFT", visibleMirrors[i - 1], "RIGHT", spacing, 0)
                end
            end
        end
    end

    local groupWidth = numCols * btnWidth + math.max(0, numCols - 1) * spacing
    local groupHeight = numRows * btnHeight + math.max(0, numRows - 1) * spacing
    container:SetSize(groupWidth, groupHeight)

    ActionBarsOwned.cachedLayouts[barKey] = {
        numCols = numCols,
        numRows = numRows,
        isVertical = isVertical,
        numIcons = numVisible,
        btnWidth = btnWidth,
        btnHeight = btnHeight,
    }
end

---------------------------------------------------------------------------
-- CONTAINER POSITIONING
---------------------------------------------------------------------------

local function SaveContainerPosition(barKey)
    local container = ActionBarsOwned.containers[barKey]
    if not container then return end

    if ns.QUI_Anchoring and ns.QUI_Anchoring.overriddenFrames
        and ns.QUI_Anchoring.overriddenFrames[container] then
        return
    end

    local core = GetCore()
    if not core or not core.SnapFramePosition then return end

    local point, _, relPoint, x, y = core:SnapFramePosition(container)
    if not point then return end

    local barDB = GetBarSettings(barKey)
    if barDB then
        barDB.ownedPosition = { point = point, relPoint = relPoint, x = x, y = y }
    end
end

local function RestoreContainerPosition(barKey)
    local container = ActionBarsOwned.containers[barKey]
    if not container then return end

    if ns.QUI_Anchoring and ns.QUI_Anchoring.overriddenFrames
        and ns.QUI_Anchoring.overriddenFrames[container] then
        return true
    end

    local barDB = GetBarSettings(barKey)
    local pos = barDB and barDB.ownedPosition

    if pos and pos.point then
        container:ClearAllPoints()
        container:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
        return true
    end

    local barFrame = GetBarFrame(barKey)
    if barFrame then
        local ok, point, relativeTo, relPoint, x, y = pcall(barFrame.GetPoint, barFrame, 1)
        if ok and point then
            container:ClearAllPoints()
            local cx, cy = barFrame:GetCenter()
            local sx, sy = UIParent:GetCenter()
            if cx and cy and sx and sy then
                container:SetPoint("CENTER", UIParent, "CENTER", cx - sx, cy - sy)
                return true
            end
        end
    end

    return false
end

---------------------------------------------------------------------------
-- FADE SYSTEM
---------------------------------------------------------------------------

local fadeState = {}

local function GetOwnedBarFadeState(barKey)
    if not fadeState[barKey] then
        fadeState[barKey] = {
            isFading = false,
            currentAlpha = 1,
            targetAlpha = 1,
            fadeStart = 0,
            fadeStartAlpha = 1,
            fadeDuration = 0.3,
            isMouseOver = false,
            delayTimer = nil,
            leaveCheckTimer = nil,
        }
    end
    return fadeState[barKey]
end

local IsInEditMode = Helpers.IsEditModeShown

local function SetOwnedBarAlpha(barKey, alpha)
    local container = ActionBarsOwned.containers[barKey]
    if not container then return end

    local mirrors = ActionBarsOwned.mirrorButtons[barKey]
    local settings = GetGlobalSettings()
    local hideEmptyEnabled = settings and settings.hideEmptySlots

    container:SetAlpha(alpha)

    if mirrors then
        for _, mirror in ipairs(mirrors) do
            local hidden = alpha <= 0 or (hideEmptyEnabled and mirror._isEmpty)
            if hidden then
                mirror._fadeHidden = true
                mirror.TintOverlay:Hide()
                mirror.Backdrop:Hide()
                mirror.Normal:Hide()
                mirror.Gloss:Hide()
            elseif mirror._fadeHidden then
                mirror._fadeHidden = false
                local effSettings = GetEffectiveSettings(barKey)
                if effSettings then
                    if effSettings.showBackdrop then mirror.Backdrop:Show() end
                    if effSettings.showBorders ~= false then mirror.Normal:Show() end
                    if effSettings.showGloss then mirror.Gloss:Show() end
                end
            end
        end
    end

    GetOwnedBarFadeState(barKey).currentAlpha = alpha
end

local fadeFrame = nil
local fadeFrameUpdate = nil

local function StartOwnedBarFade(barKey, targetAlpha)
    if targetAlpha < 1 and IsInEditMode() then return end
    if targetAlpha < 1 and ShouldForceShowForSpellBook() then return end

    local state = GetOwnedBarFadeState(barKey)
    local fadeSettings = GetFadeSettings()

    local duration = targetAlpha > state.currentAlpha
        and (fadeSettings and fadeSettings.fadeInDuration or 0.2)
        or (fadeSettings and fadeSettings.fadeOutDuration or 0.3)

    if math.abs(state.currentAlpha - targetAlpha) < 0.01 then
        state.isFading = false
        return
    end

    state.isFading = true
    state.targetAlpha = targetAlpha
    state.fadeStart = GetTime()
    state.fadeStartAlpha = state.currentAlpha
    state.fadeDuration = duration

    if not fadeFrame then
        fadeFrame = CreateFrame("Frame")
        fadeFrameUpdate = function(self, elapsed)
            local now = GetTime()
            local anyFading = false

            for bKey, bState in pairs(fadeState) do
                if bState.isFading then
                    anyFading = true
                    local elapsedTime = now - bState.fadeStart
                    local progress = math.min(elapsedTime / bState.fadeDuration, 1)
                    local easedProgress = progress * (2 - progress)
                    local a = bState.fadeStartAlpha + (bState.targetAlpha - bState.fadeStartAlpha) * easedProgress
                    SetOwnedBarAlpha(bKey, a)

                    if progress >= 1 then
                        bState.isFading = false
                        SetOwnedBarAlpha(bKey, bState.targetAlpha)
                    end
                end
            end

            if not anyFading then
                self:SetScript("OnUpdate", nil)
                self:Hide()
            end
        end
    end
    fadeFrame:SetScript("OnUpdate", fadeFrameUpdate)
    fadeFrame:Show()
end

local function CancelOwnedBarFadeTimers(state)
    if not state then return end
    if state.delayTimer then
        state.delayTimer:Cancel()
        state.delayTimer = nil
    end
    if state.leaveCheckTimer then
        state.leaveCheckTimer:Cancel()
        state.leaveCheckTimer = nil
    end
end

local function IsLinkedBar(barKey)
    for _, key in ipairs(STANDARD_BAR_KEYS) do
        if key == barKey then return true end
    end
    return false
end

local function IsMouseOverOwnedBar(barKey)
    local container = ActionBarsOwned.containers[barKey]
    if container and container:IsMouseOver() then return true end

    local mirrors = ActionBarsOwned.mirrorButtons[barKey]
    if mirrors then
        for _, mirror in ipairs(mirrors) do
            if mirror:IsMouseOver() then return true end
            if mirror.ClickOverlay and mirror.ClickOverlay:IsMouseOver() then return true end
        end
    end
    return false
end

local function IsMouseOverAnyLinkedOwnedBar()
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        if IsMouseOverOwnedBar(barKey) then return true end
    end
    return false
end

function ActionBarsOwned:OnBarMouseEnter(barKey)
    local state = GetOwnedBarFadeState(barKey)
    local fadeSettings = GetFadeSettings()
    local barSettings = GetBarSettings(barKey)

    if ShouldSuppressMouseoverHideForLevel() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForSpellBook() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end

    if barSettings and barSettings.alwaysShow then return end

    local fadeEnabled = barSettings and barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if not fadeEnabled then return end

    state.isMouseOver = true

    if fadeSettings and fadeSettings.linkBars1to8 and IsLinkedBar(barKey) then
        for _, linkedKey in ipairs(STANDARD_BAR_KEYS) do
            if linkedKey ~= barKey then
                local linkedState = GetOwnedBarFadeState(linkedKey)
                CancelOwnedBarFadeTimers(linkedState)
                StartOwnedBarFade(linkedKey, 1)
            end
        end
    end

    CancelOwnedBarFadeTimers(state)
    StartOwnedBarFade(barKey, 1)
end

function ActionBarsOwned:OnBarMouseLeave(barKey)
    if IsInEditMode() then return end

    local state = GetOwnedBarFadeState(barKey)
    local fadeSettings = GetFadeSettings()
    local barSettings = GetBarSettings(barKey)

    if ShouldSuppressMouseoverHideForLevel() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForSpellBook() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end

    if barSettings and barSettings.alwaysShow then return end

    local isMainBar = barKey and barKey:match("^bar%d$")
    if isMainBar and InCombatLockdown() and fadeSettings and fadeSettings.alwaysShowInCombat then
        return
    end

    local fadeEnabled = barSettings and barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if not fadeEnabled then return end

    if state.leaveCheckTimer then
        state.leaveCheckTimer:Cancel()
    end

    state.leaveCheckTimer = C_Timer.NewTimer(0.066, function()
        state.leaveCheckTimer = nil

        if IsMouseOverOwnedBar(barKey) then return end

        if fadeSettings and fadeSettings.linkBars1to8 and IsLinkedBar(barKey) then
            if IsMouseOverAnyLinkedOwnedBar() then return end
            for _, linkedKey in ipairs(STANDARD_BAR_KEYS) do
                local linkedBarSettings = GetBarSettings(linkedKey)
                if not (linkedBarSettings and linkedBarSettings.alwaysShow) then
                    local linkedState = GetOwnedBarFadeState(linkedKey)
                    linkedState.isMouseOver = false
                    local linkedFadeOutAlpha = linkedBarSettings and linkedBarSettings.fadeOutAlpha
                    if linkedFadeOutAlpha == nil then
                        linkedFadeOutAlpha = fadeSettings and fadeSettings.fadeOutAlpha or 0
                    end
                    local delay = fadeSettings and fadeSettings.fadeOutDelay or 0.5
                    CancelOwnedBarFadeTimers(linkedState)
                    linkedState.delayTimer = C_Timer.NewTimer(delay, function()
                        linkedState.delayTimer = nil
                        if not IsMouseOverAnyLinkedOwnedBar() then
                            StartOwnedBarFade(linkedKey, linkedFadeOutAlpha)
                        end
                    end)
                end
            end
            return
        end

        state.isMouseOver = false

        local fadeOutAlpha = barSettings and barSettings.fadeOutAlpha
        if fadeOutAlpha == nil then
            fadeOutAlpha = fadeSettings and fadeSettings.fadeOutAlpha or 0
        end
        local delay = fadeSettings and fadeSettings.fadeOutDelay or 0.5

        if state.delayTimer then
            state.delayTimer:Cancel()
        end
        state.delayTimer = C_Timer.NewTimer(delay, function()
            if state.isMouseOver then
                state.delayTimer = nil
                return
            end
            if ShouldForceShowForSpellBook() then
                SetOwnedBarAlpha(barKey, 1)
                state.delayTimer = nil
                return
            end
            local freshBarSettings = GetBarSettings(barKey)
            local freshFadeSettings = GetFadeSettings()
            local freshFadeOutAlpha = freshBarSettings and freshBarSettings.fadeOutAlpha
            if freshFadeOutAlpha == nil then
                freshFadeOutAlpha = freshFadeSettings and freshFadeSettings.fadeOutAlpha or 0
            end
            StartOwnedBarFade(barKey, freshFadeOutAlpha)
            state.delayTimer = nil
        end)
    end)
end

local function SetupOwnedBarMouseover(barKey)
    if IsInEditMode() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end

    local barSettings = GetBarSettings(barKey)
    local fadeSettings = GetFadeSettings()

    if ShouldSuppressMouseoverHideForLevel() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForSpellBook() then
        SetOwnedBarAlpha(barKey, 1)
        return
    end

    if barSettings and barSettings.alwaysShow then
        SetOwnedBarAlpha(barKey, 1)
        return
    end

    local fadeEnabled = barSettings and barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if not fadeEnabled then
        SetOwnedBarAlpha(barKey, 1)
        return
    end

    local fadeOutAlpha = barSettings and barSettings.fadeOutAlpha
    if fadeOutAlpha == nil then
        fadeOutAlpha = fadeSettings and fadeSettings.fadeOutAlpha or 0
    end

    local state = GetOwnedBarFadeState(barKey)
    state.isFading = false
    CancelOwnedBarFadeTimers(state)

    if not IsMouseOverOwnedBar(barKey) then
        SetOwnedBarAlpha(barKey, fadeOutAlpha)
    end
end

---------------------------------------------------------------------------
-- USABILITY POLLING
---------------------------------------------------------------------------

local usabilityCheckFrame = nil

local function UpdateAllMirrorUsability()
    local globalSettings = GetGlobalSettings()
    if not globalSettings then return end
    if not globalSettings.rangeIndicator and not globalSettings.usabilityIndicator then return end

    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local mirrors = ActionBarsOwned.mirrorButtons[barKey]
        local state = fadeState[barKey]
        if mirrors and (not state or state.currentAlpha > 0) then
            for _, mirror in ipairs(mirrors) do
                if mirror:IsShown() then
                    UpdateMirrorUsability(mirror, globalSettings)
                end
            end
        end
    end
end

local function UpdateUsabilityPolling()
    local settings = GetGlobalSettings()
    if not settings then return end

    local rangeEnabled = settings.rangeIndicator
    local usabilityEnabled = settings.usabilityIndicator

    if not usabilityCheckFrame then
        usabilityCheckFrame = CreateFrame("Frame")
        usabilityCheckFrame.elapsed = 0
    end

    if usabilityEnabled or rangeEnabled then
        usabilityCheckFrame:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
        usabilityCheckFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        usabilityCheckFrame:RegisterEvent("SPELL_UPDATE_USABLE")
        usabilityCheckFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
        usabilityCheckFrame:RegisterEvent("UNIT_POWER_UPDATE")
        usabilityCheckFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

        local updatePending = false
        usabilityCheckFrame:SetScript("OnEvent", function()
            if updatePending then return end
            updatePending = true
            C_Timer.After(0.05, function()
                updatePending = false
                UpdateAllMirrorUsability()
            end)
        end)

        C_Timer.After(0.1, UpdateAllMirrorUsability)
    else
        usabilityCheckFrame:UnregisterAllEvents()
        usabilityCheckFrame:SetScript("OnEvent", nil)
    end

    local RANGE_CHECK_INTERVAL = settings.fastUsabilityUpdates and 0.05 or 0.25
    if rangeEnabled then
        usabilityCheckFrame:SetScript("OnUpdate", function(self, elapsed)
            self.elapsed = self.elapsed + elapsed
            if self.elapsed < RANGE_CHECK_INTERVAL then return end
            self.elapsed = 0
            UpdateAllMirrorUsability()
        end)
        usabilityCheckFrame:Show()
    else
        usabilityCheckFrame:SetScript("OnUpdate", nil)
        usabilityCheckFrame.elapsed = 0
        if not usabilityEnabled then
            usabilityCheckFrame:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- KEYBIND SUPPORT (LibKeyBound)
-- Writes to the UNIFIED frameState so the LibKeyBound patch can find bindings.
---------------------------------------------------------------------------

local function RegisterMirrorKeybindMethods(mirrorBtn, barKey, buttonIndex)
    local prefix = BINDING_COMMANDS[barKey]
    if not prefix then return end

    local bindingCommand = prefix .. buttonIndex
    local state = GetFrameState(mirrorBtn.ClickOverlay or mirrorBtn)
    state.bindingCommand = bindingCommand
    state.keybindMethods = true
end

---------------------------------------------------------------------------
-- EDIT MODE INTEGRATION
---------------------------------------------------------------------------

local function CreateEditOverlay(container, barKey)
    local overlay = CreateFrame("Frame", nil, container, "BackdropTemplate")
    overlay:SetAllPoints(container)
    local core = GetCore()
    local px = (core and core.GetPixelSize and core:GetPixelSize(overlay)) or 1
    local edge2 = 2 * px
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = edge2,
    })
    overlay:SetBackdropColor(0.2, 0.8, 0.6, 0.3)
    overlay:SetBackdropBorderColor(0.2, 1.0, 0.6, 1)
    overlay:EnableMouse(true)
    overlay:SetMovable(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetFrameStrata("HIGH")
    overlay:Hide()

    local text = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    local displayName = barKey:gsub("bar", "Bar ")
    text:SetText(displayName)
    overlay.label = text

    overlay:SetScript("OnDragStart", function()
        container:StartMoving()
    end)

    overlay:SetScript("OnDragStop", function()
        container:StopMovingOrSizing()
        SaveContainerPosition(barKey)
    end)

    return overlay
end

local function OnEditModeEnter()
    ActionBarsOwned.editModeActive = true

    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local container = ActionBarsOwned.containers[barKey]
        if container then
            container:SetMovable(true)

            local state = GetOwnedBarFadeState(barKey)
            state.isFading = false
            CancelOwnedBarFadeTimers(state)
            SetOwnedBarAlpha(barKey, 1)

            if not ActionBarsOwned.editOverlays[barKey] then
                ActionBarsOwned.editOverlays[barKey] = CreateEditOverlay(container, barKey)
            end
            ActionBarsOwned.editOverlays[barKey]:Show()
        end
    end
end

local function OnEditModeExit()
    ActionBarsOwned.editModeActive = false

    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        if ActionBarsOwned.editOverlays[barKey] then
            ActionBarsOwned.editOverlays[barKey]:Hide()
        end

        SaveContainerPosition(barKey)
        LayoutMirrorButtons(barKey)
        SetupOwnedBarMouseover(barKey)
    end
end

---------------------------------------------------------------------------
-- BAR BUILD (creates mirrors for one bar)
---------------------------------------------------------------------------

local function BuildBar(barKey)
    local barFrame = GetBarFrame(barKey)
    local blizzButtons = GetBarButtons(barKey)
    if #blizzButtons == 0 then return end

    if not ActionBarsOwned.containers[barKey] then
        ActionBarsOwned.containers[barKey] = CreateBarContainer(barKey)
    end
    local container = ActionBarsOwned.containers[barKey]

    local oldMirrors = ActionBarsOwned.mirrorButtons[barKey]
    if oldMirrors then
        for _, mirror in ipairs(oldMirrors) do
            ReleaseMirrorButton(mirror)
        end
    end

    local mirrors = {}
    ActionBarsOwned.mirrorButtons[barKey] = mirrors

    local settings = GetEffectiveSettings(barKey)

    if barFrame then
        barFrame:UnregisterAllEvents()
        barFrame:SetParent(hiddenBarParent)
        barFrame:Hide()
    end

    for i, blizzBtn in ipairs(blizzButtons) do
        local globalName = "QUIBarBtn" .. barKey:gsub("bar", "") .. "_" .. i
        local mirror = AcquireMirrorButton(container, globalName)
        mirror._blizzButton = blizzBtn
        mirror._barKey = barKey
        mirror._buttonIndex = i
        mirrors[i] = mirror

        InstallBlizzButtonHooks(blizzBtn, mirror)
        UpdateMirrorMapping(blizzBtn, mirror)

        if settings then
            ApplyMirrorSkin(mirror, settings)
        end

        SyncInitialState(blizzBtn, mirror, settings)

        local clickName = "QUIBarBtn" .. ((tonumber(barKey:match("%d+")) or 0) - 1) * 12 + i
        if not InCombatLockdown() then
            CreateClickOverlay(mirror, blizzBtn, clickName)
        end

        if settings then
            UpdateMirrorEmptyState(mirror, settings)
        end

        RegisterMirrorKeybindMethods(mirror, barKey, i)
    end

    LayoutMirrorButtons(barKey)
    RestoreContainerPosition(barKey)
    SetupOwnedBarMouseover(barKey)
end

---------------------------------------------------------------------------
-- EVENT HANDLING
---------------------------------------------------------------------------

local ownedEventFrame = CreateFrame("Frame")

local function RefreshAllMirrorVisuals()
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local mirrors = ActionBarsOwned.mirrorButtons[barKey]
        local settings = GetEffectiveSettings(barKey)
        if mirrors and settings then
            for _, mirror in ipairs(mirrors) do
                if mirror._blizzButton then
                    SyncInitialState(mirror._blizzButton, mirror, settings)
                    UpdateMirrorEmptyState(mirror, settings)
                end
            end
        end
    end
end

local function RefreshMirrorKeybinds()
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local mirrors = ActionBarsOwned.mirrorButtons[barKey]
        local prefix = BINDING_COMMANDS[barKey]
        if mirrors and prefix then
            for i, mirror in ipairs(mirrors) do
                local key = GetBindingKey(prefix .. i)
                if key and ns.FormatKeybind then
                    mirror.HotKey:SetText(ns.FormatKeybind(key))
                else
                    mirror.HotKey:SetText("")
                end
            end
        end
    end
end

-- Forward declaration for extra button functions used in event handler
local InitializeExtraButtons
local RefreshExtraButtons

local function OnOwnedEvent(self, event, ...)
    if not ActionBarsOwned.initialized then return end

    if event == "ACTIONBAR_SLOT_CHANGED" then
        if InCombatLockdown() then
            ActionBarsOwned.pendingSlotUpdate = true
            return
        end
        C_Timer.After(0.1, RefreshAllMirrorVisuals)

    elseif event == "ACTIONBAR_PAGE_CHANGED"
        or event == "UPDATE_BONUS_ACTIONBAR"
        or event == "UPDATE_SHAPESHIFT_FORM"
        or event == "UPDATE_SHAPESHIFT_FORMS"
        or event == "UPDATE_STEALTH" then
        C_Timer.After(0.05, RefreshAllMirrorVisuals)

    elseif event == "UPDATE_BINDINGS" then
        C_Timer.After(0.1, RefreshMirrorKeybinds)

    elseif event == "CURSOR_CHANGED" then
        local settings = GetGlobalSettings()
        if settings and settings.hideEmptySlots then
            local shouldPreview = CursorHasPlaceableAction()
            if shouldPreview ~= (ActionBarsOwned.dragPreviewActive or false) then
                ActionBarsOwned.dragPreviewActive = shouldPreview or nil
                for _, barKey in ipairs(STANDARD_BAR_KEYS) do
                    local mirrors = ActionBarsOwned.mirrorButtons[barKey]
                    if mirrors then
                        local fState = fadeState[barKey]
                        local targetAlpha = fState and fState.currentAlpha or 1
                        for _, mirror in ipairs(mirrors) do
                            if mirror._isEmpty then
                                mirror:SetAlpha(shouldPreview and (DRAG_PREVIEW_ALPHA * targetAlpha) or 0)
                            end
                        end
                    end
                end
            end
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if ActionBarsOwned.pendingSlotUpdate then
            ActionBarsOwned.pendingSlotUpdate = false
            C_Timer.After(0.1, RefreshAllMirrorVisuals)
        end
        if ActionBarsOwned.pendingClickOverlays then
            ActionBarsOwned.pendingClickOverlays = false
            for _, barKey in ipairs(STANDARD_BAR_KEYS) do
                local mirrors = ActionBarsOwned.mirrorButtons[barKey]
                if mirrors then
                    for i, mirror in ipairs(mirrors) do
                        if mirror._blizzButton and not mirror.ClickOverlay then
                            local clickName = "QUIBarBtn" .. ((tonumber(barKey:match("%d+")) or 0) - 1) * 12 + i
                            CreateClickOverlay(mirror, mirror._blizzButton, clickName)
                        end
                    end
                end
            end
        end
        if ActionBarsOwned.pendingExtraButtonInit then
            ActionBarsOwned.pendingExtraButtonInit = false
            InitializeExtraButtons()
        end
        if ActionBarsOwned.pendingExtraButtonRefresh then
            ActionBarsOwned.pendingExtraButtonRefresh = false
            RefreshExtraButtons()
        end
        if ActionBarsOwned.pendingRefresh then
            ActionBarsOwned.pendingRefresh = false
            ActionBarsOwned:Refresh()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.2, function()
            for _, barKey in ipairs(STANDARD_BAR_KEYS) do
                LayoutMirrorButtons(barKey)
                RestoreContainerPosition(barKey)
            end
            RefreshAllMirrorVisuals()
        end)

    elseif event == "PLAYER_REGEN_DISABLED" then
        local fadeSettings = GetFadeSettings()
        if fadeSettings and fadeSettings.enabled and fadeSettings.alwaysShowInCombat then
            for _, barKey in ipairs(STANDARD_BAR_KEYS) do
                local state = GetOwnedBarFadeState(barKey)
                CancelOwnedBarFadeTimers(state)
                StartOwnedBarFade(barKey, 1)
            end
        end

    elseif event == "PLAYER_LEVEL_UP" then
        if UpdateLevelSuppressionState() then
            if type(_G.QUI_RefreshActionBars) == "function" then
                _G.QUI_RefreshActionBars()
            end
        end
    end
end

ownedEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
ownedEventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
ownedEventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
ownedEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
ownedEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
ownedEventFrame:RegisterEvent("UPDATE_STEALTH")
ownedEventFrame:RegisterEvent("UPDATE_BINDINGS")
ownedEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
ownedEventFrame:RegisterEvent("CURSOR_CHANGED")
ownedEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
ownedEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
ownedEventFrame:RegisterEvent("PLAYER_LEVEL_UP")
ownedEventFrame:SetScript("OnEvent", OnOwnedEvent)

-- Don't process events until Initialize is called
ownedEventFrame:Hide()
ownedEventFrame:UnregisterAllEvents()

---------------------------------------------------------------------------
-- EXTRA BUTTON CUSTOMIZATION (Extra Action Button & Zone Ability)
---------------------------------------------------------------------------

local extraActionHolder = nil
local extraActionMover = nil
local zoneAbilityHolder = nil
local zoneAbilityMover = nil
local extraButtonMoversVisible = false
local hookingSetPoint = false
local extraActionSetPointHooked = false
local zoneAbilitySetPointHooked = false
local hookingSetParent = false
local pageArrowShowHooked = false

local function GetExtraButtonDB(buttonType)
    local core = GetCore()
    if not core or not core.db or not core.db.profile then return nil end
    return core.db.profile.actionBars and core.db.profile.actionBars.bars
        and core.db.profile.actionBars.bars[buttonType]
end

local function CreateExtraButtonNudgeButton(parent, direction, holder, buttonType)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(18, 18)
    btn:SetFrameStrata("HIGH")
    btn:SetFrameLevel(100)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0.1, 0.1, 0.1, 0.7)

    local line1 = btn:CreateTexture(nil, "ARTWORK")
    line1:SetColorTexture(1, 1, 1, 0.9)
    line1:SetSize(7, 2)

    local line2 = btn:CreateTexture(nil, "ARTWORK")
    line2:SetColorTexture(1, 1, 1, 0.9)
    line2:SetSize(7, 2)

    if direction == "DOWN" then
        line1:SetPoint("CENTER", btn, "CENTER", -2, 1)
        line1:SetRotation(math.rad(-45))
        line2:SetPoint("CENTER", btn, "CENTER", 2, 1)
        line2:SetRotation(math.rad(45))
    elseif direction == "UP" then
        line1:SetPoint("CENTER", btn, "CENTER", -2, -1)
        line1:SetRotation(math.rad(45))
        line2:SetPoint("CENTER", btn, "CENTER", 2, -1)
        line2:SetRotation(math.rad(-45))
    elseif direction == "LEFT" then
        line1:SetPoint("CENTER", btn, "CENTER", 1, -2)
        line1:SetRotation(math.rad(-45))
        line2:SetPoint("CENTER", btn, "CENTER", 1, 2)
        line2:SetRotation(math.rad(45))
    elseif direction == "RIGHT" then
        line1:SetPoint("CENTER", btn, "CENTER", -1, -2)
        line1:SetRotation(math.rad(45))
        line2:SetPoint("CENTER", btn, "CENTER", -1, 2)
        line2:SetRotation(math.rad(-45))
    end

    btn:SetScript("OnEnter", function(self)
        line1:SetVertexColor(1, 0.8, 0, 1)
        line2:SetVertexColor(1, 0.8, 0, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        line1:SetVertexColor(1, 1, 1, 0.9)
        line2:SetVertexColor(1, 1, 1, 0.9)
    end)

    btn:SetScript("OnClick", function()
        local dx, dy = 0, 0
        if direction == "UP" then dy = 1
        elseif direction == "DOWN" then dy = -1
        elseif direction == "LEFT" then dx = -1
        elseif direction == "RIGHT" then dx = 1
        end
        if holder.AdjustPointsOffset then
            holder:AdjustPointsOffset(dx, dy)
        else
            local point, relativeTo, relativePoint, xOfs, yOfs = holder:GetPoint(1)
            if point then
                holder:ClearAllPoints()
                holder:SetPoint(point, relativeTo, relativePoint, (xOfs or 0) + dx, (yOfs or 0) + dy)
            end
        end
        local core = GetCore()
        if core and core.SnapFramePosition then
            local point, _, relPoint, x, y = core:SnapFramePosition(holder)
            local db = GetExtraButtonDB(buttonType)
            if db and point then
                db.position = { point = point, relPoint = relPoint, x = x, y = y }
            end
        end
    end)

    return btn
end

local function CreateExtraButtonHolder(buttonType, displayName)
    local settings = GetExtraButtonDB(buttonType)
    if not settings then return nil, nil end

    local holder = CreateFrame("Frame", "QUI_" .. buttonType .. "Holder", UIParent)
    holder:SetSize(64, 64)
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)

    local pos = settings.position
    if pos and pos.point then
        holder:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        if buttonType == "extraActionButton" then
            holder:SetPoint("CENTER", UIParent, "CENTER", -100, -200)
        else
            holder:SetPoint("CENTER", UIParent, "CENTER", 100, -200)
        end
    end

    local mover = CreateFrame("Frame", "QUI_" .. buttonType .. "Mover", holder, "BackdropTemplate")
    mover:SetAllPoints(holder)
    local core = GetCore()
    local px = (core and core.GetPixelSize and core:GetPixelSize(mover)) or 1
    local edge2 = 2 * px
    mover:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = edge2,
    })
    mover:SetBackdropColor(0.2, 0.8, 0.6, 0.5)
    mover:SetBackdropBorderColor(0.2, 1.0, 0.6, 1)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:SetFrameStrata("HIGH")
    mover:Hide()

    local text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetText(displayName)
    mover.text = text

    local nudgeUp = CreateExtraButtonNudgeButton(mover, "UP", holder, buttonType)
    nudgeUp:SetPoint("BOTTOM", mover, "TOP", 0, 4)
    local nudgeDown = CreateExtraButtonNudgeButton(mover, "DOWN", holder, buttonType)
    nudgeDown:SetPoint("TOP", mover, "BOTTOM", 0, -4)
    local nudgeLeft = CreateExtraButtonNudgeButton(mover, "LEFT", holder, buttonType)
    nudgeLeft:SetPoint("RIGHT", mover, "LEFT", -4, 0)
    local nudgeRight = CreateExtraButtonNudgeButton(mover, "RIGHT", holder, buttonType)
    nudgeRight:SetPoint("LEFT", mover, "RIGHT", 4, 0)

    mover:SetScript("OnDragStart", function(self)
        holder:StartMoving()
    end)

    mover:SetScript("OnDragStop", function(self)
        holder:StopMovingOrSizing()
        local core = GetCore()
        if not core or not core.SnapFramePosition then return end
        local point, _, relPoint, x, y = core:SnapFramePosition(holder)
        local db = GetExtraButtonDB(buttonType)
        if db and point then
            db.position = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end)

    return holder, mover
end

local extraButtonOriginalParents = {}

local function ApplyExtraButtonSettings(buttonType)
    if InCombatLockdown() then
        ActionBarsOwned.pendingExtraButtonRefresh = true
        return
    end

    local settings = GetExtraButtonDB(buttonType)
    if not settings or not settings.enabled then return end

    local blizzFrame
    local holder

    if buttonType == "extraActionButton" then
        blizzFrame = ExtraActionBarFrame
        holder = extraActionHolder
    else
        blizzFrame = ZoneAbilityFrame
        holder = zoneAbilityHolder
    end

    if not blizzFrame or not holder then return end

    local scale = settings.scale or 1.0
    blizzFrame:SetScale(scale)

    local offsetX = settings.offsetX or 0
    local offsetY = settings.offsetY or 0

    if not extraButtonOriginalParents[buttonType] then
        extraButtonOriginalParents[buttonType] = blizzFrame:GetParent()
    end
    hookingSetParent = true
    blizzFrame:SetParent(holder)
    hookingSetParent = false
    hookingSetPoint = true
    blizzFrame:ClearAllPoints()
    blizzFrame:SetPoint("CENTER", holder, "CENTER", offsetX, offsetY)
    hookingSetPoint = false

    local width = Helpers.SafeToNumber(blizzFrame:GetWidth(), 64) * scale
    local height = Helpers.SafeToNumber(blizzFrame:GetHeight(), 64) * scale
    holder:SetSize(math.max(width, 64), math.max(height, 64))

    if settings.hideArtwork then
        if buttonType == "extraActionButton" and blizzFrame.button and blizzFrame.button.style then
            blizzFrame.button.style:SetAlpha(0)
        end
        if buttonType == "zoneAbility" and blizzFrame.Style then
            blizzFrame.Style:SetAlpha(0)
        end
    else
        if buttonType == "extraActionButton" and blizzFrame.button and blizzFrame.button.style then
            blizzFrame.button.style:SetAlpha(1)
        end
        if buttonType == "zoneAbility" and blizzFrame.Style then
            blizzFrame.Style:SetAlpha(1)
        end
    end

    if not settings.fadeEnabled then
        blizzFrame:SetAlpha(1)
    end
end

local pendingExtraButtonReanchor = {}

local function QueueExtraButtonReanchor(buttonType)
    if pendingExtraButtonReanchor[buttonType] then return end
    pendingExtraButtonReanchor[buttonType] = true

    C_Timer.After(0, function()
        pendingExtraButtonReanchor[buttonType] = false

        if InCombatLockdown() then
            ActionBarsOwned.pendingExtraButtonRefresh = true
            return
        end

        local settings = GetExtraButtonDB(buttonType)
        if settings and settings.enabled then
            ApplyExtraButtonSettings(buttonType)
        end
    end)
end

local function HookExtraButtonPositioning()
    if ExtraActionBarFrame and not extraActionSetPointHooked then
        extraActionSetPointHooked = true
        hooksecurefunc(ExtraActionBarFrame, "SetPoint", function(self)
            if hookingSetPoint then return end
            C_Timer.After(0, function()
                if hookingSetPoint or InCombatLockdown() then return end
                local settings = GetExtraButtonDB("extraActionButton")
                if extraActionHolder and settings and settings.enabled then
                    QueueExtraButtonReanchor("extraActionButton")
                end
            end)
        end)
    end

    if ZoneAbilityFrame and not zoneAbilitySetPointHooked then
        zoneAbilitySetPointHooked = true
        hooksecurefunc(ZoneAbilityFrame, "SetPoint", function(self)
            if hookingSetPoint then return end
            C_Timer.After(0, function()
                if hookingSetPoint or InCombatLockdown() then return end
                local settings = GetExtraButtonDB("zoneAbility")
                if zoneAbilityHolder and settings and settings.enabled then
                    QueueExtraButtonReanchor("zoneAbility")
                end
            end)
        end)
    end

    local function HookSetParentForType(blizzFrame, buttonType, holder)
        if not blizzFrame then return end
        hooksecurefunc(blizzFrame, "SetParent", function(self, newParent)
            if hookingSetParent then return end
            if newParent == holder then return end
            C_Timer.After(0, function()
                if hookingSetParent or InCombatLockdown() then return end
                local settings = GetExtraButtonDB(buttonType)
                if holder and settings and settings.enabled then
                    hookingSetParent = true
                    blizzFrame:SetParent(holder)
                    hookingSetParent = false
                    QueueExtraButtonReanchor(buttonType)
                end
            end)
        end)
    end
    HookSetParentForType(ExtraActionBarFrame, "extraActionButton", extraActionHolder)
    HookSetParentForType(ZoneAbilityFrame, "zoneAbility", zoneAbilityHolder)
end

local function ShowExtraButtonMovers()
    extraButtonMoversVisible = true
    if extraActionMover then extraActionMover:Show() end
    if zoneAbilityMover then zoneAbilityMover:Show() end
end

local function HideExtraButtonMovers()
    extraButtonMoversVisible = false
    if extraActionMover then extraActionMover:Hide() end
    if zoneAbilityMover then zoneAbilityMover:Hide() end
end

local function ToggleExtraButtonMovers()
    if extraButtonMoversVisible then
        HideExtraButtonMovers()
    else
        ShowExtraButtonMovers()
    end
end

-- Assign to upvalue for forward declaration in event handler
InitializeExtraButtons = function()
    if InCombatLockdown() and not inInitSafeWindow then
        ActionBarsOwned.pendingExtraButtonInit = true
        return
    end

    extraActionHolder, extraActionMover = CreateExtraButtonHolder("extraActionButton", "Extra Action Button")
    zoneAbilityHolder, zoneAbilityMover = CreateExtraButtonHolder("zoneAbility", "Zone Ability")

    C_Timer.After(0.5, function()
        ApplyExtraButtonSettings("extraActionButton")
        ApplyExtraButtonSettings("zoneAbility")
        HookExtraButtonPositioning()
    end)
end

-- Assign to upvalue for forward declaration in event handler
RefreshExtraButtons = function()
    if InCombatLockdown() then
        ActionBarsOwned.pendingExtraButtonRefresh = true
        return
    end
    ApplyExtraButtonSettings("extraActionButton")
    ApplyExtraButtonSettings("zoneAbility")
end

_G.QUI_ToggleExtraButtonMovers = ToggleExtraButtonMovers
_G.QUI_RefreshExtraButtons = RefreshExtraButtons

---------------------------------------------------------------------------
-- PAGE ARROW VISIBILITY
---------------------------------------------------------------------------

local function ApplyPageArrowVisibility(hide)
    local pageNum = MainActionBar and MainActionBar.ActionBarPageNumber
    if not pageNum then return end

    if hide then
        pageNum:Hide()
        if not pageArrowShowHooked then
            pageArrowShowHooked = true
            hooksecurefunc(pageNum, "Show", function(self)
                C_Timer.After(0, function()
                    local db = GetDB()
                    if db and db.bars and db.bars.bar1 and db.bars.bar1.hidePageArrow and self and self.Hide then
                        self:Hide()
                    end
                end)
            end)
        end
    else
        pageNum:Show()
    end
end

_G.QUI_ApplyPageArrowVisibility = ApplyPageArrowVisibility

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

function ActionBarsOwned:Initialize()
    if self.initialized then return end
    self.initialized = true

    -- Patch LibKeyBound Binder methods to work with unified frameState
    PatchLibKeyBoundForMidnight()

    -- Re-register events
    ownedEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    ownedEventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
    ownedEventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
    ownedEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    ownedEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
    ownedEventFrame:RegisterEvent("UPDATE_STEALTH")
    ownedEventFrame:RegisterEvent("UPDATE_BINDINGS")
    ownedEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    ownedEventFrame:RegisterEvent("CURSOR_CHANGED")
    ownedEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    ownedEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    ownedEventFrame:RegisterEvent("PLAYER_LEVEL_UP")
    ownedEventFrame:Show()

    -- Force all action bars enabled so owned buttons function correctly
    C_CVar.SetCVar("SHOW_MULTI_ACTIONBAR_1", "1")
    C_CVar.SetCVar("SHOW_MULTI_ACTIONBAR_2", "1")
    C_CVar.SetCVar("SHOW_MULTI_ACTIONBAR_3", "1")
    C_CVar.SetCVar("SHOW_MULTI_ACTIONBAR_4", "1")

    -- Build all standard bars
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        BuildBar(barKey)
    end

    -- Wipe Blizzard actionButtons tables to prevent iteration on hidden bars
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local barFrame = GetBarFrame(barKey)
        if barFrame and barFrame.actionButtons then
            wipe(barFrame.actionButtons)
        end
    end
    for i = 1, 3 do
        local container = _G["MainActionBarButtonContainer" .. i]
        if container and container.actionButtons then
            wipe(container.actionButtons)
        end
    end

    -- Replace global button handlers with no-ops (would error on wiped tables)
    if MultiActionButtonDown then _G.MultiActionButtonDown = function() end end
    if MultiActionButtonUp then _G.MultiActionButtonUp = function() end end

    -- Setup proc glow forwarding
    SetupProcGlowHooks()

    -- Setup usability polling
    UpdateUsabilityPolling()

    -- Register Edit Mode callbacks
    local core = GetCore()
    if core and core.RegisterEditModeEnter then
        core:RegisterEditModeEnter(OnEditModeEnter)
        core:RegisterEditModeExit(OnEditModeExit)
    end

    -- Hook tooltip suppression
    hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip, parent)
        local global = GetGlobalSettings()
        if not global or global.showTooltips ~= false then return end
        if parent and parent.GetName then
            local name = parent:GetName()
            if name and name:match("^QUIBarBtn") then
                tooltip:Hide()
                tooltip:SetOwner(UIParent, "ANCHOR_NONE")
                tooltip:ClearLines()
            end
        end
    end)

    -- Hook Spellbook visibility for fade system
    local function RefreshFadeForSpellBook()
        if not ActionBarsOwned.initialized then return end
        for _, barKey in ipairs(STANDARD_BAR_KEYS) do
            local state = GetOwnedBarFadeState(barKey)
            state.isFading = false
            CancelOwnedBarFadeTimers(state)
            if ShouldForceShowForSpellBook() then
                SetOwnedBarAlpha(barKey, 1)
            else
                SetupOwnedBarMouseover(barKey)
            end
        end
    end

    local function HookSpellBookFrame(frame)
        if not frame then return end
        frame:HookScript("OnShow", function()
            C_Timer.After(0, RefreshFadeForSpellBook)
        end)
        frame:HookScript("OnHide", function()
            C_Timer.After(0, RefreshFadeForSpellBook)
        end)
    end

    HookSpellBookFrame(_G.SpellBookFrame)
    local psf = _G.PlayerSpellsFrame
    HookSpellBookFrame(psf)
    if psf and psf.SpellBookFrame then
        HookSpellBookFrame(psf.SpellBookFrame)
    end

    -- Initialize extra buttons
    inInitSafeWindow = true
    InitializeExtraButtons()
    inInitSafeWindow = false

    -- Apply page arrow visibility
    local db = GetDB()
    if db and db.bars and db.bars.bar1 then
        ApplyPageArrowVisibility(db.bars.bar1.hidePageArrow)
    end

    -- Hide bars that are disabled in DB
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local barDB = GetBarSettings(barKey)
        if barDB and barDB.enabled == false then
            local container = self.containers[barKey]
            if container then container:Hide() end
        end
    end
end

function ActionBarsOwned:Refresh()
    if not self.initialized then return end

    if InCombatLockdown() then
        self.pendingRefresh = true
        return
    end

    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        BuildBar(barKey)
    end

    -- Hide bars that are disabled in DB
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local barDB = GetBarSettings(barKey)
        if barDB and barDB.enabled == false then
            local container = self.containers[barKey]
            if container then container:Hide() end
        end
    end

    UpdateUsabilityPolling()
end

function ActionBarsOwned:Shutdown()
    if not self.initialized then return end
    self.initialized = false

    ownedEventFrame:UnregisterAllEvents()
    ownedEventFrame:Hide()

    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        local mirrors = self.mirrorButtons[barKey]
        if mirrors then
            for _, mirror in ipairs(mirrors) do
                ReleaseMirrorButton(mirror)
            end
        end
        self.mirrorButtons[barKey] = nil

        local container = self.containers[barKey]
        if container then
            container:Hide()
        end

        local barFrame = GetBarFrame(barKey)
        if barFrame then
            barFrame:SetParent(UIParent)
            barFrame:Show()
        end
    end

    for barKey, overlay in pairs(self.editOverlays) do
        overlay:Hide()
    end

    if usabilityCheckFrame then
        usabilityCheckFrame:UnregisterAllEvents()
        usabilityCheckFrame:SetScript("OnEvent", nil)
        usabilityCheckFrame:SetScript("OnUpdate", nil)
        usabilityCheckFrame:Hide()
    end
end

---------------------------------------------------------------------------
-- GLOBAL REFRESH FUNCTION
---------------------------------------------------------------------------

_G.QUI_RefreshActionBars = function()
    if InCombatLockdown() then
        ActionBarsOwned.pendingRefresh = true
        return
    end
    ActionBarsOwned:Refresh()
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == ADDON_NAME then
        local db = GetDB()
        if not db or not db.enabled then return end
        ActionBarsOwned:Initialize()
    end
end)

---------------------------------------------------------------------------
-- UNLOCK MODE ELEMENT REGISTRATION
---------------------------------------------------------------------------
do
    local function RegisterLayoutModeElements()
        local um = ns.QUI_LayoutMode
        if not um then return end

        local BAR_ELEMENTS = {
            { key = "bar1", label = "Action Bar 1", order = 1 },
            { key = "bar2", label = "Action Bar 2", order = 2 },
            { key = "bar3", label = "Action Bar 3", order = 3 },
            { key = "bar4", label = "Action Bar 4", order = 4 },
            { key = "bar5", label = "Action Bar 5", order = 5 },
            { key = "bar6", label = "Action Bar 6", order = 6 },
            { key = "bar7", label = "Action Bar 7", order = 7 },
            { key = "bar8", label = "Action Bar 8", order = 8 },
            { key = "petBar",    label = "Pet Bar",     order = 9 },
            { key = "stanceBar", label = "Stance Bar",  order = 10 },
            { key = "microMenu", label = "Micro Menu",  order = 11 },
            { key = "bagBar",    label = "Bag Bar",     order = 12 },
        }

        local DB_KEY_MAP = {
            petBar = "pet", stanceBar = "stance",
            microMenu = "microbar", bagBar = "bags",
        }

        for _, info in ipairs(BAR_ELEMENTS) do
            local dbKey = DB_KEY_MAP[info.key] or info.key
            um:RegisterElement({
                key = info.key,
                label = info.label,
                group = "Action Bars",
                order = info.order,
                isOwned = true,
                isEnabled = function()
                    local barDB = GetBarSettings(dbKey)
                    return barDB and barDB.enabled ~= false
                end,
                setEnabled = function(val)
                    local barDB = GetBarSettings(dbKey)
                    if barDB then barDB.enabled = val end
                    local container = ActionBarsOwned.containers and ActionBarsOwned.containers[info.key]
                    if container then
                        if val then
                            container:Show()
                        else
                            container:Hide()
                        end
                    end
                end,
                getFrame = function()
                    local owned = ActionBarsOwned.containers and ActionBarsOwned.containers[info.key]
                    if owned then return owned end
                    local BLIZZARD_FRAMES = {
                        bar1 = "MainActionBar", bar2 = "MultiBarBottomLeft",
                        bar3 = "MultiBarBottomRight", bar4 = "MultiBarRight",
                        bar5 = "MultiBarLeft", bar6 = "MultiBar5",
                        bar7 = "MultiBar6", bar8 = "MultiBar7",
                        petBar = "PetActionBar", stanceBar = "StanceBar",
                        microMenu = "MicroMenuContainer", bagBar = "BagsBar",
                    }
                    return _G[BLIZZARD_FRAMES[info.key]]
                end,
            })
        end
    end

    C_Timer.After(2, RegisterLayoutModeElements)
end

---------------------------------------------------------------------------
-- UNLOCK MODE SETTINGS PROVIDER
---------------------------------------------------------------------------
do
    local function RegisterSettingsProviders()
        local settingsPanel = ns.QUI_LayoutMode_Settings
        if not settingsPanel then return end

        local GUI = QUI and QUI.GUI
        if not GUI then return end

        local C = GUI.Colors or {}
        local U = ns.QUI_LayoutMode_Utils
        local P = U.PlaceRow
        local ACCENT_R, ACCENT_G, ACCENT_B = 0.204, 0.827, 0.600
        local PADDING = 0
        local FORM_ROW = U and U.FORM_ROW or 32

        local function RefreshActionBars()
            for _, bk in ipairs(STANDARD_BAR_KEYS) do
                local mirrors = ActionBarsOwned.mirrorButtons[bk]
                local settings = GetEffectiveSettings(bk)
                if mirrors and settings then
                    for _, mirror in ipairs(mirrors) do
                        ApplyMirrorSkin(mirror, settings)
                        if mirror._blizzButton then
                            SyncInitialState(mirror._blizzButton, mirror, settings)
                            UpdateMirrorEmptyState(mirror, settings)
                        end
                    end
                    LayoutMirrorButtons(bk)
                end
            end
        end

        local anchorOptions = {
            {value = "TOPLEFT", text = "Top Left"},
            {value = "TOP", text = "Top"},
            {value = "TOPRIGHT", text = "Top Right"},
            {value = "LEFT", text = "Left"},
            {value = "CENTER", text = "Center"},
            {value = "RIGHT", text = "Right"},
            {value = "BOTTOMLEFT", text = "Bottom Left"},
            {value = "BOTTOM", text = "Bottom"},
            {value = "BOTTOMRIGHT", text = "Bottom Right"},
        }

        local orientationOptions = {
            {value = "horizontal", text = "Horizontal"},
            {value = "vertical", text = "Vertical"},
        }

        local LAYOUT_BARS = {
            bar1 = true, bar2 = true, bar3 = true, bar4 = true,
            bar5 = true, bar6 = true, bar7 = true, bar8 = true,
        }

        local SETTINGS_DB_KEY_MAP = {
            petBar = "pet", stanceBar = "stance",
            microMenu = "microbar", bagBar = "bags",
        }

        local copyKeys = {
            "iconZoom", "showBackdrop", "backdropAlpha", "showGloss", "glossAlpha", "showBorders",
            "showKeybinds", "hideEmptyKeybinds", "keybindFontSize", "keybindColor",
            "keybindAnchor", "keybindOffsetX", "keybindOffsetY",
            "showMacroNames", "macroNameFontSize", "macroNameColor",
            "macroNameAnchor", "macroNameOffsetX", "macroNameOffsetY",
            "showCounts", "countFontSize", "countColor",
            "countAnchor", "countOffsetX", "countOffsetY",
        }

        local copyBarOptions = {
            {value = "bar1", text = "Bar 1"}, {value = "bar2", text = "Bar 2"},
            {value = "bar3", text = "Bar 3"}, {value = "bar4", text = "Bar 4"},
            {value = "bar5", text = "Bar 5"}, {value = "bar6", text = "Bar 6"},
            {value = "bar7", text = "Bar 7"}, {value = "bar8", text = "Bar 8"},
        }

        local function CreateCollapsible(parent, title, contentHeight, buildFunc, sections, relayout)
            return U.CreateCollapsible(parent, title, contentHeight, buildFunc, sections, relayout)
        end

        local function BuildBarSettings(content, barKey, width)
            local db = GetDB()
            if not db or not db.bars then return 80 end

            local dbKey = SETTINGS_DB_KEY_MAP[barKey] or barKey
            local barDB = db.bars[dbKey]
            if not barDB then return 80 end

            local global = db.global
            local hasLayout = LAYOUT_BARS[barKey]
            local layout = barDB.ownedLayout

            local sections = {}
            local function relayout() U.StandardRelayout(content, sections) end

            -- SECTION: Layout (standard bars only)
            if hasLayout and layout then
                local extraRows = 2
                if barKey == "bar1" then extraRows = extraRows + 1 end
                local numRows = 7 + extraRows
                local descHeight = 16
                CreateCollapsible(content, "Layout", numRows * FORM_ROW + descHeight + 8, function(body)
                    local sy = -4

                    if barKey == "bar1" then
                        sy = P(GUI:CreateFormCheckbox(body,
                            "Hide Default Paging Arrow", "hidePageArrow", barDB,
                            function(val)
                                if _G.QUI_ApplyPageArrowVisibility then
                                    _G.QUI_ApplyPageArrowVisibility(val)
                                end
                            end), body, sy)
                    end

                    local applyAllBtn = CreateFrame("Button", nil, body)
                    applyAllBtn:SetSize(200, 22)
                    applyAllBtn:SetPoint("TOPLEFT", 0, sy)

                    local applyBg = applyAllBtn:CreateTexture(nil, "BACKGROUND")
                    applyBg:SetAllPoints()
                    applyBg:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.25)

                    local applyText = applyAllBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    applyText:SetPoint("CENTER")
                    applyText:SetText("Apply To All Bars")
                    applyText:SetTextColor(1, 1, 1, 1)

                    applyAllBtn:SetScript("OnClick", function()
                        for i = 1, 8 do
                            local otherKey = "bar" .. i
                            if otherKey ~= barKey then
                                local otherDbKey = SETTINGS_DB_KEY_MAP[otherKey] or otherKey
                                local otherDB = db.bars[otherDbKey]
                                if otherDB then
                                    for _, key in ipairs(copyKeys) do
                                        otherDB[key] = barDB[key]
                                    end
                                end
                            end
                        end
                        RefreshActionBars()
                    end)
                    applyAllBtn:SetScript("OnEnter", function()
                        applyBg:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.4)
                    end)
                    applyAllBtn:SetScript("OnLeave", function()
                        applyBg:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.25)
                    end)
                    sy = sy - FORM_ROW

                    local filteredCopyOptions = {}
                    for _, opt in ipairs(copyBarOptions) do
                        if opt.value ~= barKey then
                            table.insert(filteredCopyOptions, opt)
                        end
                    end

                    sy = P(GUI:CreateFormDropdown(body, "Copy Settings From", filteredCopyOptions, nil, nil,
                        function(sourceKey)
                            local sourceDbKey = SETTINGS_DB_KEY_MAP[sourceKey] or sourceKey
                            local sourceDB = db.bars[sourceDbKey]
                            if not sourceDB then return end
                            for _, key in ipairs(copyKeys) do
                                barDB[key] = sourceDB[key]
                            end
                            RefreshActionBars()
                        end), body, sy)

                    local copyDesc = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    copyDesc:SetPoint("TOPLEFT", 2, sy + 4)
                    copyDesc:SetPoint("RIGHT", body, "RIGHT", 0, 0)
                    copyDesc:SetTextColor(0.5, 0.5, 0.5, 1)
                    copyDesc:SetText("Copies visual, keybind, macro, and count settings. Layout is per-bar.")
                    copyDesc:SetJustifyH("LEFT")
                    sy = sy - 16

                    sy = P(GUI:CreateFormDropdown(body, "Orientation",
                        orientationOptions, "orientation", layout, RefreshActionBars), body, sy)

                    sy = P(GUI:CreateFormSlider(body, "Buttons Per Row",
                        1, 12, 1, "columns", layout, RefreshActionBars), body, sy)

                    sy = P(GUI:CreateFormSlider(body, "Visible Buttons",
                        1, 12, 1, "iconCount", layout, RefreshActionBars), body, sy)

                    sy = P(GUI:CreateFormSlider(body, "Button Size",
                        20, 64, 1, "buttonSize", layout, RefreshActionBars), body, sy)

                    sy = P(GUI:CreateFormSlider(body, "Button Spacing",
                        0, 10, 1, "buttonSpacing", layout, RefreshActionBars), body, sy)

                    sy = P(GUI:CreateFormCheckbox(body, "Grow Upward",
                        "growUp", layout, RefreshActionBars), body, sy)

                    P(GUI:CreateFormCheckbox(body, "Grow Left",
                        "growLeft", layout, RefreshActionBars), body, sy)
                end, sections, relayout)
            end

            -- SECTION: Visual
            CreateCollapsible(content, "Visual", 6 * FORM_ROW + 8, function(body)
                local sy = -4
                sy = P(GUI:CreateFormSlider(body, "Icon Crop",
                    0.05, 0.15, 0.01, "iconZoom", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormCheckbox(body, "Show Backdrop",
                    "showBackdrop", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Backdrop Opacity",
                    0, 1, 0.05, "backdropAlpha", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormCheckbox(body, "Show Gloss",
                    "showGloss", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Gloss Opacity",
                    0, 1, 0.05, "glossAlpha", barDB, RefreshActionBars), body, sy)

                P(GUI:CreateFormCheckbox(body, "Show Borders",
                    "showBorders", barDB, RefreshActionBars), body, sy)
            end, sections, relayout)

            -- SECTION: Keybind Text
            CreateCollapsible(content, "Keybind Text", 7 * FORM_ROW + 8, function(body)
                local sy = -4
                sy = P(GUI:CreateFormCheckbox(body, "Show Keybinds",
                    "showKeybinds", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormCheckbox(body, "Hide Empty Keybinds",
                    "hideEmptyKeybinds", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Font Size",
                    8, 18, 1, "keybindFontSize", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormDropdown(body, "Anchor",
                    anchorOptions, "keybindAnchor", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "X-Offset",
                    -20, 20, 1, "keybindOffsetX", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Y-Offset",
                    -20, 20, 1, "keybindOffsetY", barDB, RefreshActionBars), body, sy)

                P(GUI:CreateFormColorPicker(body, "Color",
                    "keybindColor", barDB, RefreshActionBars), body, sy)
            end, sections, relayout)

            -- SECTION: Macro Names
            CreateCollapsible(content, "Macro Names", 6 * FORM_ROW + 8, function(body)
                local sy = -4
                sy = P(GUI:CreateFormCheckbox(body, "Show Macro Names",
                    "showMacroNames", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Font Size",
                    8, 18, 1, "macroNameFontSize", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormDropdown(body, "Anchor",
                    anchorOptions, "macroNameAnchor", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "X-Offset",
                    -20, 20, 1, "macroNameOffsetX", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Y-Offset",
                    -20, 20, 1, "macroNameOffsetY", barDB, RefreshActionBars), body, sy)

                P(GUI:CreateFormColorPicker(body, "Color",
                    "macroNameColor", barDB, RefreshActionBars), body, sy)
            end, sections, relayout)

            -- SECTION: Stack Count
            CreateCollapsible(content, "Stack Count", 6 * FORM_ROW + 8, function(body)
                local sy = -4
                sy = P(GUI:CreateFormCheckbox(body, "Show Counts",
                    "showCounts", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Font Size",
                    8, 20, 1, "countFontSize", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormDropdown(body, "Anchor",
                    anchorOptions, "countAnchor", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "X-Offset",
                    -20, 20, 1, "countOffsetX", barDB, RefreshActionBars), body, sy)

                sy = P(GUI:CreateFormSlider(body, "Y-Offset",
                    -20, 20, 1, "countOffsetY", barDB, RefreshActionBars), body, sy)

                P(GUI:CreateFormColorPicker(body, "Color",
                    "countColor", barDB, RefreshActionBars), body, sy)
            end, sections, relayout)

            -- Position / Anchoring
            U.BuildPositionCollapsible(content, barKey, nil, sections, relayout)

            -- Initial layout
            relayout()
            return content:GetHeight()
        end

        local ALL_BAR_KEYS = {
            "bar1", "bar2", "bar3", "bar4", "bar5", "bar6", "bar7", "bar8",
            "stanceBar", "petBar", "microMenu", "bagBar",
        }

        settingsPanel:RegisterProvider(ALL_BAR_KEYS, {
            build = BuildBarSettings,
        })
    end

    C_Timer.After(3, RegisterSettingsProviders)
end

---------------------------------------------------------------------------
-- EXPOSE MODULE
---------------------------------------------------------------------------

local core = GetCore()
if core then
    core.ActionBars = ActionBarsOwned
end
