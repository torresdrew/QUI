local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local C = GUI.Colors
local Shared = ns.QUI_Options

-- Local references
local PADDING = Shared.PADDING
local CreateScrollableContent = Shared.CreateScrollableContent
local GetDB = Shared.GetDB
local GetTextureList = Shared.GetTextureList
local GetFontList = Shared.GetFontList
local RefreshAll = Shared.RefreshAll

-- Forward declaration for Totem Bar sub-tab (defined below Action Bars page)
local BuildTotemBarTab

local GetCore = ns.Helpers.GetCore

---------------------------------------------------------------------------
-- PAGE: Action Bars
---------------------------------------------------------------------------
local function CreateActionBarsPage(parent)
    local scroll, content = CreateScrollableContent(parent)
    local db = GetDB()

    -- Safety check
    if not db or not db.actionBars then
        local errorLabel = GUI:CreateLabel(content, "Action Bars settings not available. Please reload UI.", 12, C.text)
        errorLabel:SetPoint("TOPLEFT", PADDING, -15)
        content:SetHeight(100)
        return scroll, content
    end

    local actionBars = db.actionBars
    local global = actionBars.global
    local fade = actionBars.fade
    local bars = actionBars.bars

    -- Refresh callback
    local function RefreshActionBars()
        if _G.QUI_RefreshActionBars then
            _G.QUI_RefreshActionBars()
        end
    end

    ---------------------------------------------------------
    -- SUB-TAB: Mouseover Hide
    ---------------------------------------------------------
    local function BuildMouseoverHideTab(tabContent)
        local y = -15
        local PAD = PADDING
        local FORM_ROW = 32

        -- Set search context for widget auto-registration
        GUI:SetSearchContext({tabIndex = 7, tabName = "Action Bars", subTabIndex = 2, subTabName = "Mouseover Hide"})

        ---------------------------------------------------------
        -- Warning: Enable Blizzard Action Bars
        ---------------------------------------------------------
        local warningText = GUI:CreateLabel(tabContent,
            "Important: Enable all 8 action bars in Game Menu > Options > Gameplay > Action Bars for mouseover hide to work correctly. To remove the default dragon texture, open Edit Mode, select Action Bar 1, check 'Hide Bar Art', then reload.",
            11, C.warning)
        warningText:SetPoint("TOPLEFT", PAD, y)
        warningText:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        warningText:SetJustifyH("LEFT")
        warningText:SetWordWrap(true)
        warningText:SetHeight(45)
        y = y - 55

        local openSettingsBtn = GUI:CreateButton(tabContent, "Open Game Settings", 160, 26, function()
            if InCombatLockdown() then return end
            if SettingsPanel then
                SettingsPanel:Open()
            end
        end)
        openSettingsBtn:SetPoint("TOPLEFT", PAD, y)
        openSettingsBtn:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - 46  -- Extra spacing before main content

        ---------------------------------------------------------
        -- Section: Mouseover Hide
        ---------------------------------------------------------
        local fadeHeader = GUI:CreateSectionHeader(tabContent, "Mouseover Hide")
        fadeHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - fadeHeader.gap

        local fadeCheck = GUI:CreateFormCheckbox(tabContent, "Enable Mouseover Hide",
            "enabled", fade, RefreshActionBars)
        fadeCheck:SetPoint("TOPLEFT", PAD, y)
        fadeCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local fadeTip = GUI:CreateLabel(tabContent,
            "Bars hide when mouse is not over them. Hover to reveal.",
            11, C.textMuted)
        fadeTip:SetPoint("TOPLEFT", PAD, y)
        fadeTip:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        fadeTip:SetJustifyH("LEFT")
        y = y - 24

        local fadeInSlider = GUI:CreateFormSlider(tabContent, "Fade In Speed (sec)",
            0.1, 1.0, 0.05, "fadeInDuration", fade, RefreshActionBars)
        fadeInSlider:SetPoint("TOPLEFT", PAD, y)
        fadeInSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local fadeOutSlider = GUI:CreateFormSlider(tabContent, "Fade Out Speed (sec)",
            0.1, 1.0, 0.05, "fadeOutDuration", fade, RefreshActionBars)
        fadeOutSlider:SetPoint("TOPLEFT", PAD, y)
        fadeOutSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local fadeAlphaSlider = GUI:CreateFormSlider(tabContent, "Faded Opacity",
            0, 1, 0.05, "fadeOutAlpha", fade, RefreshActionBars)
        fadeAlphaSlider:SetPoint("TOPLEFT", PAD, y)
        fadeAlphaSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local fadeDelaySlider = GUI:CreateFormSlider(tabContent, "Fade Out Delay (sec)",
            0, 2.0, 0.1, "fadeOutDelay", fade, RefreshActionBars)
        fadeDelaySlider:SetPoint("TOPLEFT", PAD, y)
        fadeDelaySlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local combatCheck = GUI:CreateFormCheckbox(tabContent, "Do Not Hide In Combat",
            "alwaysShowInCombat", fade, RefreshActionBars)
        combatCheck:SetPoint("TOPLEFT", PAD, y)
        combatCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local spellBookCheck = GUI:CreateFormCheckbox(tabContent, "Show Bars While Spellbook Is Open",
            "showWhenSpellBookOpen", fade, RefreshActionBars)
        spellBookCheck:SetPoint("TOPLEFT", PAD, y)
        spellBookCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local leaveVehicleCheck = GUI:CreateFormCheckbox(tabContent, "Keep Leave Vehicle Button Visible",
            "keepLeaveVehicleVisible", fade, RefreshActionBars)
        leaveVehicleCheck:SetPoint("TOPLEFT", PAD, y)
        leaveVehicleCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local maxLevelCheck = GUI:CreateFormCheckbox(tabContent, "Disable Below Max Level",
            "disableBelowMaxLevel", fade, RefreshActionBars)
        maxLevelCheck:SetPoint("TOPLEFT", PAD, y)
        maxLevelCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local maxLevelDesc = GUI:CreateLabel(tabContent,
            "Keeps action bars visible while leveling. Mouseover hide starts at max level.",
            11, C.textMuted)
        maxLevelDesc:SetPoint("TOPLEFT", PAD, y)
        maxLevelDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        maxLevelDesc:SetJustifyH("LEFT")
        y = y - 24

        local linkBarsCheck = GUI:CreateFormCheckbox(tabContent, "Link Action Bars 1-8 on Mouseover",
            "linkBars1to8", fade, RefreshActionBars)
        linkBarsCheck:SetPoint("TOPLEFT", PAD, y)
        linkBarsCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local linkBarsDesc = GUI:CreateLabel(tabContent,
            "When enabled, hovering any action bar (1-8) reveals all bars 1-8 together.",
            11, C.textMuted)
        linkBarsDesc:SetPoint("TOPLEFT", PAD, y)
        linkBarsDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        linkBarsDesc:SetJustifyH("LEFT")
        y = y - 24

        -- Always Show toggles (bars that ignore mouseover hide)
        local alwaysShowTip = GUI:CreateLabel(tabContent,
            "Bars checked below will always remain visible, ignoring mouseover hide.",
            11, C.textMuted)
        alwaysShowTip:SetPoint("TOPLEFT", PAD, y)
        alwaysShowTip:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        alwaysShowTip:SetJustifyH("LEFT")
        y = y - 24

        local alwaysShowBars = {
            { key = "bar1", label = "Always Show Bar 1" },
            { key = "bar2", label = "Always Show Bar 2" },
            { key = "bar3", label = "Always Show Bar 3" },
            { key = "bar4", label = "Always Show Bar 4" },
            { key = "bar5", label = "Always Show Bar 5" },
            { key = "bar6", label = "Always Show Bar 6" },
            { key = "bar7", label = "Always Show Bar 7" },
            { key = "bar8", label = "Always Show Bar 8" },
            { key = "microbar", label = "Always Show Microbar" },
            { key = "bags", label = "Always Show Bags" },
            { key = "pet", label = "Always Show Pet Bar" },
            { key = "stance", label = "Always Show Stance Bar" },
            { key = "extraActionButton", label = "Always Show Extra Action" },
            { key = "zoneAbility", label = "Always Show Zone Ability" },
        }

        for _, barInfo in ipairs(alwaysShowBars) do
            local barDB = bars[barInfo.key]
            if barDB then
                local check = GUI:CreateFormCheckbox(tabContent, barInfo.label,
                    "alwaysShow", barDB, RefreshActionBars)
                check:SetPoint("TOPLEFT", PAD, y)
                check:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
                y = y - FORM_ROW
            end
        end

        tabContent:SetHeight(math.abs(y) + 50)
    end  -- End BuildMouseoverHideTab

    ---------------------------------------------------------
    -- SUB-TAB: Master Visual Settings (existing global settings)
    ---------------------------------------------------------
    local function BuildMasterSettingsTab(tabContent)
        local y = -15
        local PAD = PADDING
        local FORM_ROW = 32

        -- Set search context for auto-registration
        GUI:SetSearchContext({tabIndex = 7, tabName = "Action Bars", subTabIndex = 1, subTabName = "Master Settings"})

        ---------------------------------------------------------
        -- Quick Keybind Mode (prominent tool at top)
        ---------------------------------------------------------
        local keybindModeBtn = GUI:CreateButton(tabContent, "Quick Keybind Mode", 180, 28, function()
            if InCombatLockdown() then return end
            local LibKeyBound = LibStub("LibKeyBound-1.0", true)
            if LibKeyBound then
                LibKeyBound:Toggle()
            elseif QuickKeybindFrame then
                ShowUIPanel(QuickKeybindFrame)
            end
        end)
        keybindModeBtn:SetPoint("TOPLEFT", PAD, y)
        y = y - 38

        local keybindTip = GUI:CreateLabel(tabContent,
            "Hover over action buttons and press a key to bind. Type /kb anytime.",
            11, C.textMuted)
        keybindTip:SetPoint("TOPLEFT", PAD, y)
        keybindTip:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        keybindTip:SetJustifyH("LEFT")
        keybindTip:SetWordWrap(true)
        keybindTip:SetHeight(15)
        y = y - 30

        ---------------------------------------------------------
        -- Section: General
        ---------------------------------------------------------
        local generalHeader = GUI:CreateSectionHeader(tabContent, "General")
        generalHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - generalHeader.gap

        local enableCheck = GUI:CreateFormCheckbox(tabContent, "Enable QUI Action Bars",
            "enabled", actionBars, function(val)
                GUI:ShowConfirmation({
                    title = "Reload Required",
                    message = "Action Bar styling requires a UI reload to take effect.",
                    acceptText = "Reload Now",
                    cancelText = "Later",
                    isDestructive = false,
                    onAccept = function()
                        QUI:SafeReload()
                    end,
                })
            end)
        enableCheck:SetPoint("TOPLEFT", PAD, y)
        enableCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local tipText = GUI:CreateLabel(tabContent,
            "QUI hooks into Blizzard action bars to skin them. Position, resize, and style bars via QUI Edit Mode. If you need actionbar paging (stance/form swapping), want to use action bars as your CDM, or prefer more control - disable QUI Action Bars and use a dedicated addon.",
            11, C.warning)
        tipText:SetPoint("TOPLEFT", PAD, y)
        tipText:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        tipText:SetJustifyH("LEFT")
        tipText:SetWordWrap(true)
        tipText:SetHeight(45)
        y = y - 55

        ---------------------------------------------------------
        -- Section: Behavior
        ---------------------------------------------------------
        local behaviorHeader = GUI:CreateSectionHeader(tabContent, "Behavior")
        behaviorHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - behaviorHeader.gap

        local tooltipsCheck = GUI:CreateFormCheckbox(tabContent, "Show Tooltips",
            "showTooltips", global)
        tooltipsCheck:SetPoint("TOPLEFT", PAD, y)
        tooltipsCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local hideEmptySlotsCheck = GUI:CreateFormCheckbox(tabContent, "Hide Empty Slots",
            "hideEmptySlots", global, RefreshActionBars)
        hideEmptySlotsCheck:SetPoint("TOPLEFT", PAD, y)
        hideEmptySlotsCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Action Button Lock - combined lock + override key in one clear dropdown
        local lockOptions = {
            {value = "unlocked", text = "Unlocked"},
            {value = "shift", text = "Locked - Shift to drag"},
            {value = "alt", text = "Locked - Alt to drag"},
            {value = "ctrl", text = "Locked - Ctrl to drag"},
            {value = "none", text = "Fully Locked"},
        }
        -- Proxy that reads/writes to Blizzard's CVars
        local lockProxy = setmetatable({}, {
            __index = function(t, k)
                if k == "buttonLock" then
                    local isLocked = GetCVar("lockActionBars") == "1"
                    if not isLocked then return "unlocked" end
                    local modifier = GetModifiedClick("PICKUPACTION") or "SHIFT"
                    if modifier == "NONE" then return "none" end
                    return modifier:lower()
                end
            end,
            __newindex = function(t, k, v)
                if InCombatLockdown() then return end
                if k == "buttonLock" and type(v) == "string" then
                    if v == "unlocked" then
                        SetCVar("lockActionBars", "0")
                    else
                        SetCVar("lockActionBars", "1")
                        local modifier = (v == "none") and "NONE" or v:upper()
                        SetModifiedClick("PICKUPACTION", modifier)
                        SaveBindings(GetCurrentBindingSet())
                    end
                end
            end
        })
        local lockDropdown = GUI:CreateFormDropdown(tabContent, "Action Button Lock", lockOptions,
            "buttonLock", lockProxy, RefreshActionBars)
        lockDropdown:SetPoint("TOPLEFT", PAD, y)
        lockDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        -- Refresh from Blizzard settings on show
        lockDropdown:HookScript("OnShow", function(self)
            self.SetValue(lockProxy.buttonLock, true)
        end)
        y = y - FORM_ROW

        local rangeCheck = GUI:CreateFormCheckbox(tabContent, "Out of Range Indicator",
            "rangeIndicator", global, RefreshActionBars)
        rangeCheck:SetPoint("TOPLEFT", PAD, y)
        rangeCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local rangeColorPicker = GUI:CreateFormColorPicker(tabContent, "Out of Range Color",
            "rangeColor", global, RefreshActionBars)
        rangeColorPicker:SetPoint("TOPLEFT", PAD, y)
        rangeColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local usabilityCheck = GUI:CreateFormCheckbox(tabContent, "Dim Unusable Buttons",
            "usabilityIndicator", global, RefreshActionBars)
        usabilityCheck:SetPoint("TOPLEFT", PAD, y)
        usabilityCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local desaturateCheck = GUI:CreateFormCheckbox(tabContent, "Desaturate Unusable",
            "usabilityDesaturate", global, RefreshActionBars)
        desaturateCheck:SetPoint("TOPLEFT", PAD, y)
        desaturateCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local manaColorPicker = GUI:CreateFormColorPicker(tabContent, "Out of Mana Color",
            "manaColor", global, RefreshActionBars)
        manaColorPicker:SetPoint("TOPLEFT", PAD, y)
        manaColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local fastUpdates = GUI:CreateFormCheckbox(tabContent, "Unthrottled CPU Usage",
            "fastUsabilityUpdates", global, RefreshActionBars)
        fastUpdates:SetPoint("TOPLEFT", PAD, y)
        fastUpdates:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local fastDesc = GUI:CreateLabel(tabContent, "Updates range/mana/unusable states 5x faster. Only enable if using action bars as your primary rotation display. Enabling while bars are hidden wastes CPU.", 11, {1, 0.6, 0})
        fastDesc:SetPoint("TOPLEFT", PAD, y + 4)
        y = y - 18

        local layoutTipText = GUI:CreateLabel(tabContent, "Enable 'Out of Range', 'Unusable' and 'Out of Mana' ONLY if you use Action Bars to replace CDM. They eat CPU resources.", 11, {1, 0.6, 0})
        layoutTipText:SetPoint("TOPLEFT", PAD, y)
        layoutTipText:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        layoutTipText:SetJustifyH("LEFT")
        layoutTipText:SetWordWrap(true)
        y = y - 40

        local editModeTip = GUI:CreateLabel(tabContent, "Button appearance, text display, and layout settings are configured per-bar in QUI Edit Mode. Click a bar's mover to access its settings.", 11, C.textMuted)
        editModeTip:SetPoint("TOPLEFT", PAD, y)
        editModeTip:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        editModeTip:SetJustifyH("LEFT")
        editModeTip:SetWordWrap(true)
        editModeTip:SetHeight(30)
        y = y - 40

        tabContent:SetHeight(math.abs(y) + 50)
    end  -- End BuildMasterSettingsTab

    -- Per-Bar Overrides moved to QUI Edit Mode settings panel

    local function BuildExtraButtonsTab(tabContent)
        local y = -15
        local PAD = PADDING
        local FORM_ROW = 32

        -- Set search context
        GUI:SetSearchContext({tabIndex = 7, tabName = "Action Bars", subTabIndex = 4, subTabName = "Extra Buttons"})

        -- Refresh callback
        local function RefreshExtraButtons()
            if _G.QUI_RefreshExtraButtons then
                _G.QUI_RefreshExtraButtons()
            end
        end

        -- Description
        local descLabel = GUI:CreateLabel(tabContent,
            "Customize the Extra Action Button (boss encounters, quests) and Zone Ability Button (garrison, covenant, zone abilities) separately.",
            11, C.textMuted)
        descLabel:SetPoint("TOPLEFT", PAD, y)
        descLabel:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        descLabel:SetJustifyH("LEFT")
        descLabel:SetWordWrap(true)
        descLabel:SetHeight(30)
        y = y - 40

        -- Toggle Movers Button
        local moverBtn = GUI:CreateButton(tabContent, "Toggle Position Movers", 200, 28, function()
            if _G.QUI_ToggleExtraButtonMovers then
                _G.QUI_ToggleExtraButtonMovers()
            end
        end)
        moverBtn:SetPoint("TOPLEFT", PAD, y)
        y = y - 35

        local moverTip = GUI:CreateLabel(tabContent,
            "Click to show draggable movers. Drag to position, use sliders for fine-tuning.",
            10, C.textMuted)
        moverTip:SetPoint("TOPLEFT", PAD, y)
        moverTip:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        moverTip:SetJustifyH("LEFT")
        y = y - 25

        -- Extra Action Button settings moved to Edit Mode settings panel.

        -- Zone Ability Button settings moved to Edit Mode settings panel.

        tabContent:SetHeight(math.abs(y) + 50)
    end  -- End BuildExtraButtonsTab

    local PAD = PADDING

    GUI:SetSearchContext({tabIndex = 7, tabName = "Action Bars"})

    -- Host frame for sub-tabs
    local subTabHost = CreateFrame("Frame", nil, content)
    subTabHost:SetPoint("TOPLEFT", 0, -8)
    subTabHost:SetPoint("BOTTOMRIGHT", 0, 0)

    local subTabs = {
        {name = "General", builder = BuildMasterSettingsTab},
        {name = "Mouseover Hide", builder = BuildMouseoverHideTab},
        {name = "Extra Buttons", builder = BuildExtraButtonsTab},
        {name = "Totem Bar", builder = BuildTotemBarTab},
    }

    GUI:CreateSubTabs(subTabHost, subTabs)

    content:SetHeight(700)
    return scroll, content
end

---------------------------------------------------------------------------
-- SUB-TAB: Totem Bar (Shaman only)
---------------------------------------------------------------------------
-- Totem Bar settings moved to Edit Mode settings panel.
BuildTotemBarTab = function(tabContent)
    local PAD = PADDING
    local info = GUI:CreateLabel(tabContent, "Totem Bar settings have moved to Edit Mode. Open Edit Mode and click the Totem Bar frame.", 12, C.textMuted or {0.5,0.5,0.5,1})
    info:SetPoint("TOPLEFT", PAD, -15)
    info:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    info:SetJustifyH("LEFT")
    info:SetWordWrap(true)
    tabContent:SetHeight(80)
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------
ns.QUI_ActionBarsOptions = {
    CreateActionBarsPage = CreateActionBarsPage
}
