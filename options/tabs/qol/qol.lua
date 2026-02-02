--[[
    QUI QoL Options - General Tab
    BuildGeneralTab for General & QoL page
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local QUICore = ns.Addon
local C = GUI.Colors

-- Import shared utilities
local Shared = ns.QUI_Options

local function BuildGeneralTab(tabContent)
    local y = -10
    local FORM_ROW = 32
    local PADDING = Shared.PADDING
    local db = Shared.GetDB()

    -- Refresh callback for fonts/textures (refreshes everything that uses these defaults)
    local function RefreshAll()
        -- Refresh core CDM viewers
        if QUICore and QUICore.RefreshAll then
            QUICore:RefreshAll()
        end
        -- Refresh unit frames (use global function)
        if _G.QUI_RefreshUnitFrames then
            _G.QUI_RefreshUnitFrames()
        end
        -- Refresh power bars (recreate to apply new fonts/textures)
        if QUICore then
            if QUICore.UpdatePowerBar then
                QUICore:UpdatePowerBar()
            end
            if QUICore.UpdateSecondaryPowerBar then
                QUICore:UpdateSecondaryPowerBar()
            end
        end
        -- Refresh minimap/datatext
        if QUICore and QUICore.Minimap and QUICore.Minimap.Refresh then
            QUICore.Minimap:Refresh()
        end
        -- Refresh buff borders
        if _G.QUI_RefreshBuffBorders then
            _G.QUI_RefreshBuffBorders()
        end
        -- Refresh NCDM (CDM icons)
        if ns and ns.NCDM and ns.NCDM.RefreshAll then
            ns.NCDM:RefreshAll()
        end
        -- Trigger CDM layout refresh
        C_Timer.After(0.1, function()
            if QUICore and QUICore.ApplyViewerLayout then
                QUICore:ApplyViewerLayout("EssentialCooldownViewer")
                QUICore:ApplyViewerLayout("UtilityCooldownViewer")
            end
        end)
    end

    -- Set search context for auto-registration
    GUI:SetSearchContext({tabIndex = 1, tabName = "General & QoL", subTabIndex = 1, subTabName = "General"})

    -- UI Scale Section
    GUI:SetSearchSection("UI Scale")
    local scaleHeader = GUI:CreateSectionHeader(tabContent, "UI Scale")
    scaleHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - scaleHeader.gap

    if db and db.general then
        local scaleSlider = GUI:CreateFormSlider(tabContent, "Global UI Scale", 0.3, 2.0, 0.01,
            "uiScale", db.general, function(val)
                pcall(function() UIParent:SetScale(val) end)
            end, { deferOnDrag = true, precision = 7 })
        scaleSlider:SetPoint("TOPLEFT", PADDING, y)
        scaleSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Quick preset buttons
        local presetLabel = GUI:CreateLabel(tabContent, "Quick UI Scale Presets:", 12, C.text)
        presetLabel:SetPoint("TOPLEFT", PADDING, y)

        local function ApplyPreset(val, name)
            db.general.uiScale = val
            pcall(function() UIParent:SetScale(val) end)
            local msg = "|cff34D399[QUI]|r UI scale set to " .. val
            if name then msg = msg .. " (" .. name .. ")" end
            DEFAULT_CHAT_FRAME:AddMessage(msg)
            scaleSlider.SetValue(val, true)
        end

        local function AutoScale()
            local _, height = GetPhysicalScreenSize()
            local scale = 768 / height
            scale = math.max(0.3, math.min(2.0, scale))
            ApplyPreset(scale, "Auto")
        end

        -- Button container aligned with slider track (180px) to editbox right edge
        local buttonContainer = CreateFrame("Frame", nil, tabContent)
        buttonContainer:SetPoint("LEFT", scaleSlider, "LEFT", 180, 0)
        buttonContainer:SetPoint("RIGHT", scaleSlider, "RIGHT", 0, 0)
        buttonContainer:SetPoint("TOP", presetLabel, "TOP", 0, 0)
        buttonContainer:SetHeight(26)

        local BUTTON_GAP = 6
        local NUM_BUTTONS = 5
        local buttons = {}

        -- Create buttons with placeholder width (will be set dynamically)
        buttons[1] = GUI:CreateButton(buttonContainer, "1080p", 50, 26, function() ApplyPreset(0.7111111, "1080p") end)
        buttons[2] = GUI:CreateButton(buttonContainer, "1440p", 50, 26, function() ApplyPreset(0.5333333, "1440p") end)
        buttons[3] = GUI:CreateButton(buttonContainer, "1440p+", 50, 26, function() ApplyPreset(0.64, "1440p+") end)
        buttons[4] = GUI:CreateButton(buttonContainer, "4K", 50, 26, function() ApplyPreset(0.3555556, "4K") end)
        buttons[5] = GUI:CreateButton(buttonContainer, "Auto", 50, 26, AutoScale)

        -- Dynamically size and position buttons when container width is known
        buttonContainer:SetScript("OnSizeChanged", function(self, width)
            if width and width > 0 then
                local buttonWidth = (width - (NUM_BUTTONS - 1) * BUTTON_GAP) / NUM_BUTTONS
                for i, btn in ipairs(buttons) do
                    btn:SetWidth(buttonWidth)
                    btn:ClearAllPoints()
                    if i == 1 then
                        btn:SetPoint("LEFT", self, "LEFT", 0, 0)
                    else
                        btn:SetPoint("LEFT", buttons[i-1], "RIGHT", BUTTON_GAP, 0)
                    end
                end
            end
        end)

        -- Tooltip data for preset buttons
        local tooltipData = {
            { title = "1080p", desc = "Scale: 0.7111111\nPixel-perfect for 1920x1080" },
            { title = "1440p", desc = "Scale: 0.5333333\nPixel-perfect for 2560x1440" },
            { title = "1440p+", desc = "Scale: 0.64\nQuazii's personal setting - larger and more readable.\nRequires manual adjustment for pixel perfection." },
            { title = "4K", desc = "Scale: 0.3555556\nPixel-perfect for 3840x2160" },
            { title = "Auto", desc = "Computes pixel-perfect scale based on your resolution.\nFormula: 768 / screen height" },
        }

        -- Add tooltips to buttons
        for i, btn in ipairs(buttons) do
            local data = tooltipData[i]
            btn:HookScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(data.title, 1, 1, 1)
                GameTooltip:AddLine(data.desc, 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            btn:HookScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        y = y - FORM_ROW - 6

        -- Single summary line
        local presetSummary = GUI:CreateLabel(tabContent,
            "Hover over any preset for details. 1440p+ is Quazii's personal setting.",
            11, C.textMuted)
        presetSummary:SetPoint("TOPLEFT", PADDING, y)
        y = y - 20

        -- Big picture advice
        local bigPicture = GUI:CreateLabel(tabContent,
            "UI scale is highly personal-it depends on your monitor size, resolution, and preference. If you already have a scale you like from years of playing WoW, stick with it. These presets are just common values people tend to use.",
            11, C.textMuted)
        bigPicture:SetPoint("TOPLEFT", PADDING, y)
        bigPicture:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        bigPicture:SetJustifyH("LEFT")
        y = y - 36
    end

    -- Default Font Section
    GUI:SetSearchSection("Default Font Settings")
    local fontTexHeader = GUI:CreateSectionHeader(tabContent, "Default Font Settings")
    fontTexHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - fontTexHeader.gap

    local tipText = GUI:CreateLabel(tabContent, "These settings apply throughout the UI. Individual elements with their own font options will override these defaults.", 11, C.textMuted)
    tipText:SetPoint("TOPLEFT", PADDING, y)
    tipText:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    tipText:SetJustifyH("LEFT")
    y = y - 28

    if db and db.general then
        local fontList = {}
        local LSM = LibStub("LibSharedMedia-3.0", true)
        if LSM then
            for name in pairs(LSM:HashTable("font")) do
                table.insert(fontList, {value = name, text = name})
            end
            table.sort(fontList, function(a, b) return a.text < b.text end)
        else
            fontList = {{value = "Friz Quadrata TT", text = "Friz Quadrata TT"}}
        end

        local fontDropdown = GUI:CreateFormDropdown(tabContent, "Default Font", fontList, "font", db.general, RefreshAll)
        fontDropdown:SetPoint("TOPLEFT", PADDING, y)
        fontDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local outlineOptions = {
            {value = "", text = "None"},
            {value = "OUTLINE", text = "Outline"},
            {value = "THICKOUTLINE", text = "Thick Outline"},
        }
        local outlineDropdown = GUI:CreateFormDropdown(tabContent, "Font Outline", outlineOptions, "fontOutline", db.general, RefreshAll)
        outlineDropdown:SetPoint("TOPLEFT", PADDING, y)
        outlineDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW
    end

    y = y - 10

    -- Quazii Recommended FPS Settings Section
    local fpsHeader = GUI:CreateSectionHeader(tabContent, "Quazii Recommended FPS Settings")
    fpsHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - fpsHeader.gap

    local fpsDesc = GUI:CreateLabel(tabContent,
        "Apply Quazii's optimized graphics settings for competitive play. " ..
        "Your current settings are automatically saved when you click Apply - use 'Restore Previous Settings' to revert anytime. " ..
        "Caution: Clicking Apply again will overwrite your backup with these settings.",
        11, C.textMuted)
    fpsDesc:SetPoint("TOPLEFT", PADDING, y)
    fpsDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    fpsDesc:SetJustifyH("LEFT")
    fpsDesc:SetWordWrap(true)
    fpsDesc:SetHeight(30)
    y = y - 40

    local restoreFpsBtn
    local fpsStatusText

    local function UpdateFPSStatus()
        local allMatch, matched, total = Shared.CheckCVarsMatch()
        -- Some CVars can't be verified (protected/restart required), so threshold at 50+
        if matched >= 50 then
            fpsStatusText:SetText("Settings: All applied")
            fpsStatusText:SetTextColor(C.accent[1], C.accent[2], C.accent[3], 1)
        else
            fpsStatusText:SetText(string.format("Settings: %d/%d match", matched, total))
            fpsStatusText:SetTextColor(C.textMuted[1], C.textMuted[2], C.textMuted[3], 1)
        end
    end

    local applyFpsBtn = GUI:CreateButton(tabContent, "Apply FPS Settings", 180, 28, function()
        Shared.ApplyQuaziiFPSSettings()
        restoreFpsBtn:SetAlpha(1)
        restoreFpsBtn:Enable()
        UpdateFPSStatus()
    end)
    applyFpsBtn:SetPoint("TOPLEFT", PADDING, y)
    applyFpsBtn:SetPoint("RIGHT", tabContent, "CENTER", -5, 0)

    restoreFpsBtn = GUI:CreateButton(tabContent, "Restore Previous Settings", 180, 28, function()
        if Shared.RestorePreviousFPSSettings() then
            restoreFpsBtn:SetAlpha(0.5)
            restoreFpsBtn:Disable()
        end
        UpdateFPSStatus()
    end)
    restoreFpsBtn:SetPoint("LEFT", tabContent, "CENTER", 5, 0)
    restoreFpsBtn:SetPoint("TOP", applyFpsBtn, "TOP", 0, 0)
    restoreFpsBtn:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    y = y - 38

    fpsStatusText = GUI:CreateLabel(tabContent, "", 11, C.accent)
    fpsStatusText:SetPoint("TOPLEFT", PADDING, y)

    if not db.fpsBackup then
        restoreFpsBtn:SetAlpha(0.5)
        restoreFpsBtn:Disable()
    end

    UpdateFPSStatus()

    y = y - 22

    -- Combat Status Text Indicator Section
    local combatTextHeader = GUI:CreateSectionHeader(tabContent, "Combat Status Text Indicator")
    combatTextHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - combatTextHeader.gap

    local combatTextDesc = GUI:CreateLabel(tabContent,
        "Displays '+Combat' or '-Combat' text on screen when entering or leaving combat. Useful for Shadowmeld skips.",
        11, C.textMuted)
    combatTextDesc:SetPoint("TOPLEFT", PADDING, y)
    combatTextDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    combatTextDesc:SetJustifyH("LEFT")
    combatTextDesc:SetWordWrap(true)
    combatTextDesc:SetHeight(15)
    y = y - 25

    -- Preview buttons
    local previewEnterBtn = GUI:CreateButton(tabContent, "Preview +Combat", 140, 28, function()
        if _G.QUI_PreviewCombatText then _G.QUI_PreviewCombatText("+Combat") end
    end)
    previewEnterBtn:SetPoint("TOPLEFT", PADDING, y)
    previewEnterBtn:SetPoint("RIGHT", tabContent, "CENTER", -5, 0)

    local previewLeaveBtn = GUI:CreateButton(tabContent, "Preview -Combat", 140, 28, function()
        if _G.QUI_PreviewCombatText then _G.QUI_PreviewCombatText("-Combat") end
    end)
    previewLeaveBtn:SetPoint("LEFT", tabContent, "CENTER", 5, 0)
    previewLeaveBtn:SetPoint("TOP", previewEnterBtn, "TOP", 0, 0)
    previewLeaveBtn:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    y = y - 38

    local combatTextDB = db and db.combatText
    if combatTextDB then
        local combatTextCheck = GUI:CreateFormCheckbox(tabContent, "Enable Combat Text", "enabled", combatTextDB, function(val)
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        combatTextCheck:SetPoint("TOPLEFT", PADDING, y)
        combatTextCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local displayTimeSlider = GUI:CreateFormSlider(tabContent, "Display Time (sec)", 0.3, 3.0, 0.1, "displayTime", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        displayTimeSlider:SetPoint("TOPLEFT", PADDING, y)
        displayTimeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local fadeTimeSlider = GUI:CreateFormSlider(tabContent, "Fade Duration (sec)", 0.1, 1.0, 0.05, "fadeTime", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        fadeTimeSlider:SetPoint("TOPLEFT", PADDING, y)
        fadeTimeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local fontSizeSlider = GUI:CreateFormSlider(tabContent, "Font Size", 12, 48, 1, "fontSize", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        fontSizeSlider:SetPoint("TOPLEFT", PADDING, y)
        fontSizeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local xOffsetSlider = GUI:CreateFormSlider(tabContent, "X Position Offset", -2000, 2000, 1, "xOffset", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        xOffsetSlider:SetPoint("TOPLEFT", PADDING, y)
        xOffsetSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local yOffsetSlider = GUI:CreateFormSlider(tabContent, "Y Position Offset", -2000, 2000, 1, "yOffset", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        yOffsetSlider:SetPoint("TOPLEFT", PADDING, y)
        yOffsetSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local enterColorPicker = GUI:CreateFormColorPicker(tabContent, "+Combat Text Color", "enterCombatColor", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        enterColorPicker:SetPoint("TOPLEFT", PADDING, y)
        enterColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local leaveColorPicker = GUI:CreateFormColorPicker(tabContent, "-Combat Text Color", "leaveCombatColor", combatTextDB, function()
            if _G.QUI_RefreshCombatText then _G.QUI_RefreshCombatText() end
        end)
        leaveColorPicker:SetPoint("TOPLEFT", PADDING, y)
        leaveColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW
    end

    y = y - 10

    -- Battle Res Counter Section
    GUI:SetSearchSection("Battle Res Counter")
    local brzHeader = GUI:CreateSectionHeader(tabContent, "Battle Res Counter")
    brzHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - brzHeader.gap

    local brzDesc = GUI:CreateLabel(tabContent,
        "Displays battle res charges and cooldown timer in raids and M+ dungeons.",
        11, C.textMuted)
    brzDesc:SetPoint("TOPLEFT", PADDING, y)
    brzDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    brzDesc:SetJustifyH("LEFT")
    brzDesc:SetWordWrap(true)
    brzDesc:SetHeight(15)
    y = y - 25

    local brzDB = db and db.brzCounter
    if brzDB then
        local brzEnableCheck = GUI:CreateFormCheckbox(tabContent, "Enable Battle Res Counter", "enabled", brzDB, function(val)
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzEnableCheck:SetPoint("TOPLEFT", PADDING, y)
        brzEnableCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Preview toggle
        local brzPreviewState = { enabled = _G.QUI_IsBrezCounterPreviewMode and _G.QUI_IsBrezCounterPreviewMode() or false }
        local brzPreviewCheck = GUI:CreateFormCheckbox(tabContent, "Preview Battle Res Counter", "enabled", brzPreviewState, function(val)
            if _G.QUI_ToggleBrezCounterPreview then
                _G.QUI_ToggleBrezCounterPreview(val)
            end
        end)
        brzPreviewCheck:SetPoint("TOPLEFT", PADDING, y)
        brzPreviewCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Frame size settings
        local brzWidthSlider = GUI:CreateFormSlider(tabContent, "Frame Width", 30, 100, 1, "width", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzWidthSlider:SetPoint("TOPLEFT", PADDING, y)
        brzWidthSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzHeightSlider = GUI:CreateFormSlider(tabContent, "Frame Height", 30, 100, 1, "height", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzHeightSlider:SetPoint("TOPLEFT", PADDING, y)
        brzHeightSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzFontSizeSlider = GUI:CreateFormSlider(tabContent, "Charges Font Size", 10, 28, 1, "fontSize", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzFontSizeSlider:SetPoint("TOPLEFT", PADDING, y)
        brzFontSizeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzTimerFontSlider = GUI:CreateFormSlider(tabContent, "Timer Font Size", 8, 24, 1, "timerFontSize", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzTimerFontSlider:SetPoint("TOPLEFT", PADDING, y)
        brzTimerFontSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzXOffsetSlider = GUI:CreateFormSlider(tabContent, "X Position Offset", -2000, 2000, 1, "xOffset", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzXOffsetSlider:SetPoint("TOPLEFT", PADDING, y)
        brzXOffsetSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzYOffsetSlider = GUI:CreateFormSlider(tabContent, "Y Position Offset", -2000, 2000, 1, "yOffset", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzYOffsetSlider:SetPoint("TOPLEFT", PADDING, y)
        brzYOffsetSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Color pickers
        local brzHasChargesColor = GUI:CreateFormColorPicker(tabContent, "Charges Available Color", "hasChargesColor", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzHasChargesColor:SetPoint("TOPLEFT", PADDING, y)
        brzHasChargesColor:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzNoChargesColor = GUI:CreateFormColorPicker(tabContent, "No Charges Color", "noChargesColor", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzNoChargesColor:SetPoint("TOPLEFT", PADDING, y)
        brzNoChargesColor:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Timer text color with class color toggle
        local brzTimerColorPicker  -- Forward declare

        local brzUseClassColorCheck = GUI:CreateFormCheckbox(tabContent, "Use Class Color for Timer Text", "useClassColorText", brzDB, function(val)
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
            if brzTimerColorPicker and brzTimerColorPicker.SetEnabled then
                brzTimerColorPicker:SetEnabled(not val)
            end
        end)
        brzUseClassColorCheck:SetPoint("TOPLEFT", PADDING, y)
        brzUseClassColorCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        brzTimerColorPicker = GUI:CreateFormColorPicker(tabContent, "Timer Text Color", "timerColor", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzTimerColorPicker:SetPoint("TOPLEFT", PADDING, y)
        brzTimerColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        if brzTimerColorPicker.SetEnabled then
            brzTimerColorPicker:SetEnabled(not brzDB.useClassColorText)
        end
        y = y - FORM_ROW

        -- Font selection with custom toggle
        local brzFontList = Shared.GetFontList()
        local brzFontDropdown  -- Forward declare

        local brzUseCustomFontCheck = GUI:CreateFormCheckbox(tabContent, "Use Custom Font", "useCustomFont", brzDB, function(val)
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
            if brzFontDropdown and brzFontDropdown.SetEnabled then
                brzFontDropdown:SetEnabled(val)
            end
        end)
        brzUseCustomFontCheck:SetPoint("TOPLEFT", PADDING, y)
        brzUseCustomFontCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        brzFontDropdown = GUI:CreateFormDropdown(tabContent, "Font", brzFontList, "font", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzFontDropdown:SetPoint("TOPLEFT", PADDING, y)
        brzFontDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        if brzFontDropdown.SetEnabled then
            brzFontDropdown:SetEnabled(brzDB.useCustomFont == true)
        end
        y = y - FORM_ROW

        -- Backdrop settings
        local brzBackdropCheck = GUI:CreateFormCheckbox(tabContent, "Show Backdrop", "showBackdrop", brzDB, function(val)
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzBackdropCheck:SetPoint("TOPLEFT", PADDING, y)
        brzBackdropCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzBackdropColor = GUI:CreateFormColorPicker(tabContent, "Backdrop Color", "backdropColor", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzBackdropColor:SetPoint("TOPLEFT", PADDING, y)
        brzBackdropColor:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Border settings
        -- Normalize mutually exclusive flags on load (prefer class color)
        if brzDB.useClassColorBorder and brzDB.useAccentColorBorder then
            brzDB.useAccentColorBorder = false
        end

        local brzBorderSizeSlider, brzBorderTextureDropdown, brzUseClassBorderCheck, brzUseAccentBorderCheck, brzBorderColorPicker

        local function UpdateBrzBorderControlsEnabled(enabled)
            if brzBorderSizeSlider and brzBorderSizeSlider.SetEnabled then brzBorderSizeSlider:SetEnabled(enabled) end
            if brzBorderTextureDropdown and brzBorderTextureDropdown.SetEnabled then brzBorderTextureDropdown:SetEnabled(enabled) end
            if brzUseClassBorderCheck and brzUseClassBorderCheck.SetEnabled then brzUseClassBorderCheck:SetEnabled(enabled) end
            if brzUseAccentBorderCheck and brzUseAccentBorderCheck.SetEnabled then brzUseAccentBorderCheck:SetEnabled(enabled) end
            if brzBorderColorPicker and brzBorderColorPicker.SetEnabled then
                brzBorderColorPicker:SetEnabled(enabled and not brzDB.useClassColorBorder and not brzDB.useAccentColorBorder)
            end
        end

        local brzHideBorderCheck = GUI:CreateFormCheckbox(tabContent, "Hide Border", "hideBorder", brzDB, function(val)
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
            UpdateBrzBorderControlsEnabled(not val)
        end)
        brzHideBorderCheck:SetPoint("TOPLEFT", PADDING, y)
        brzHideBorderCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        brzBorderSizeSlider = GUI:CreateFormSlider(tabContent, "Border Size", 1, 5, 0.5, "borderSize", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzBorderSizeSlider:SetPoint("TOPLEFT", PADDING, y)
        brzBorderSizeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local brzBorderList = Shared.GetBorderList()
        brzBorderTextureDropdown = GUI:CreateFormDropdown(tabContent, "Border Texture", brzBorderList, "borderTexture", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzBorderTextureDropdown:SetPoint("TOPLEFT", PADDING, y)
        brzBorderTextureDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        brzUseClassBorderCheck = GUI:CreateFormCheckbox(tabContent, "Use Class Color for Border", "useClassColorBorder", brzDB, function(val)
            if val then
                brzDB.useAccentColorBorder = false
                if brzUseAccentBorderCheck and brzUseAccentBorderCheck.SetChecked then brzUseAccentBorderCheck:SetChecked(false) end
            end
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
            if brzBorderColorPicker and brzBorderColorPicker.SetEnabled then
                brzBorderColorPicker:SetEnabled(not val and not brzDB.useAccentColorBorder and not brzDB.hideBorder)
            end
        end)
        brzUseClassBorderCheck:SetPoint("TOPLEFT", PADDING, y)
        brzUseClassBorderCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        brzUseAccentBorderCheck = GUI:CreateFormCheckbox(tabContent, "Use Accent Color for Border", "useAccentColorBorder", brzDB, function(val)
            if val then
                brzDB.useClassColorBorder = false
                if brzUseClassBorderCheck and brzUseClassBorderCheck.SetChecked then brzUseClassBorderCheck:SetChecked(false) end
            end
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
            if brzBorderColorPicker and brzBorderColorPicker.SetEnabled then
                brzBorderColorPicker:SetEnabled(not val and not brzDB.useClassColorBorder and not brzDB.hideBorder)
            end
        end)
        brzUseAccentBorderCheck:SetPoint("TOPLEFT", PADDING, y)
        brzUseAccentBorderCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        brzBorderColorPicker = GUI:CreateFormColorPicker(tabContent, "Border Color", "borderColor", brzDB, function()
            if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end
        end)
        brzBorderColorPicker:SetPoint("TOPLEFT", PADDING, y)
        brzBorderColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Apply initial border control states
        UpdateBrzBorderControlsEnabled(not brzDB.hideBorder)
    end

    y = y - 10

    -- Combat Timer Section
    local combatTimerHeader = GUI:CreateSectionHeader(tabContent, "Combat Timer")
    combatTimerHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - combatTimerHeader.gap

    local combatTimerDesc = GUI:CreateLabel(tabContent,
        "Displays elapsed combat time. Timer resets each time you leave combat.",
        11, C.textMuted)
    combatTimerDesc:SetPoint("TOPLEFT", PADDING, y)
    combatTimerDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    combatTimerDesc:SetJustifyH("LEFT")
    combatTimerDesc:SetWordWrap(true)
    combatTimerDesc:SetHeight(15)
    y = y - 25

    local combatTimerDB = db and db.combatTimer
    if combatTimerDB then
        local combatTimerCheck = GUI:CreateFormCheckbox(tabContent, "Enable Combat Timer", "enabled", combatTimerDB, function(val)
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        combatTimerCheck:SetPoint("TOPLEFT", PADDING, y)
        combatTimerCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Encounters-only mode toggle
        local encountersOnlyCheck = GUI:CreateFormCheckbox(tabContent, "Only Show In Encounters", "onlyShowInEncounters", combatTimerDB, function(val)
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        encountersOnlyCheck:SetPoint("TOPLEFT", PADDING, y)
        encountersOnlyCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Preview toggle
        local previewState = { enabled = _G.QUI_IsCombatTimerPreviewMode and _G.QUI_IsCombatTimerPreviewMode() or false }
        local previewCheck = GUI:CreateFormCheckbox(tabContent, "Preview Combat Timer", "enabled", previewState, function(val)
            if _G.QUI_ToggleCombatTimerPreview then
                _G.QUI_ToggleCombatTimerPreview(val)
            end
        end)
        previewCheck:SetPoint("TOPLEFT", PADDING, y)
        previewCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Frame size settings
        local timerWidthSlider = GUI:CreateFormSlider(tabContent, "Frame Width", 40, 200, 1, "width", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerWidthSlider:SetPoint("TOPLEFT", PADDING, y)
        timerWidthSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local timerHeightSlider = GUI:CreateFormSlider(tabContent, "Frame Height", 20, 100, 1, "height", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerHeightSlider:SetPoint("TOPLEFT", PADDING, y)
        timerHeightSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local timerFontSizeSlider = GUI:CreateFormSlider(tabContent, "Font Size", 12, 32, 1, "fontSize", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerFontSizeSlider:SetPoint("TOPLEFT", PADDING, y)
        timerFontSizeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local timerXOffsetSlider = GUI:CreateFormSlider(tabContent, "X Position Offset", -2000, 2000, 1, "xOffset", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerXOffsetSlider:SetPoint("TOPLEFT", PADDING, y)
        timerXOffsetSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local timerYOffsetSlider = GUI:CreateFormSlider(tabContent, "Y Position Offset", -2000, 2000, 1, "yOffset", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerYOffsetSlider:SetPoint("TOPLEFT", PADDING, y)
        timerYOffsetSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Text color with class color toggle
        local timerColorPicker  -- Forward declare

        local useClassColorTextCheck = GUI:CreateFormCheckbox(tabContent, "Use Class Color for Text", "useClassColorText", combatTimerDB, function(val)
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
            -- Enable/disable text color picker based on toggle
            if timerColorPicker and timerColorPicker.SetEnabled then
                timerColorPicker:SetEnabled(not val)
            end
        end)
        useClassColorTextCheck:SetPoint("TOPLEFT", PADDING, y)
        useClassColorTextCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        timerColorPicker = GUI:CreateFormColorPicker(tabContent, "Timer Text Color", "textColor", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerColorPicker:SetPoint("TOPLEFT", PADDING, y)
        timerColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        -- Initial state based on setting
        if timerColorPicker.SetEnabled then
            timerColorPicker:SetEnabled(not combatTimerDB.useClassColorText)
        end
        y = y - FORM_ROW

        -- Font selection with custom toggle
        local fontList = Shared.GetFontList()
        local timerFontDropdown  -- Forward declare

        local useCustomFontCheck = GUI:CreateFormCheckbox(tabContent, "Use Custom Font", "useCustomFont", combatTimerDB, function(val)
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
            -- Enable/disable font dropdown based on toggle
            if timerFontDropdown and timerFontDropdown.SetEnabled then
                timerFontDropdown:SetEnabled(val)
            end
        end)
        useCustomFontCheck:SetPoint("TOPLEFT", PADDING, y)
        useCustomFontCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        timerFontDropdown = GUI:CreateFormDropdown(tabContent, "Font", fontList, "font", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        timerFontDropdown:SetPoint("TOPLEFT", PADDING, y)
        timerFontDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        -- Initial state based on setting
        if timerFontDropdown.SetEnabled then
            timerFontDropdown:SetEnabled(combatTimerDB.useCustomFont == true)
        end
        y = y - FORM_ROW

        -- Backdrop settings
        local backdropCheck = GUI:CreateFormCheckbox(tabContent, "Show Backdrop", "showBackdrop", combatTimerDB, function(val)
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        backdropCheck:SetPoint("TOPLEFT", PADDING, y)
        backdropCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local backdropColorPicker = GUI:CreateFormColorPicker(tabContent, "Backdrop Color", "backdropColor", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        backdropColorPicker:SetPoint("TOPLEFT", PADDING, y)
        backdropColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Border settings
        -- Normalize mutually exclusive flags on load (prefer class color)
        if combatTimerDB.useClassColorBorder and combatTimerDB.useAccentColorBorder then
            combatTimerDB.useAccentColorBorder = false
        end

        local borderSizeSlider, borderTextureDropdown, useClassColorCheck, useAccentColorCheck, borderColorPicker

        local function UpdateBorderControlsEnabled(enabled)
            if borderSizeSlider and borderSizeSlider.SetEnabled then borderSizeSlider:SetEnabled(enabled) end
            if borderTextureDropdown and borderTextureDropdown.SetEnabled then borderTextureDropdown:SetEnabled(enabled) end
            if useClassColorCheck and useClassColorCheck.SetEnabled then useClassColorCheck:SetEnabled(enabled) end
            if useAccentColorCheck and useAccentColorCheck.SetEnabled then useAccentColorCheck:SetEnabled(enabled) end
            if borderColorPicker and borderColorPicker.SetEnabled then
                borderColorPicker:SetEnabled(enabled and not combatTimerDB.useClassColorBorder and not combatTimerDB.useAccentColorBorder)
            end
        end

        local hideBorderCheck = GUI:CreateFormCheckbox(tabContent, "Hide Border", "hideBorder", combatTimerDB, function(val)
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
            UpdateBorderControlsEnabled(not val)
        end)
        hideBorderCheck:SetPoint("TOPLEFT", PADDING, y)
        hideBorderCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        borderSizeSlider = GUI:CreateFormSlider(tabContent, "Border Size", 1, 5, 0.5, "borderSize", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        borderSizeSlider:SetPoint("TOPLEFT", PADDING, y)
        borderSizeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        local borderList = Shared.GetBorderList()
        borderTextureDropdown = GUI:CreateFormDropdown(tabContent, "Border Texture", borderList, "borderTexture", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        borderTextureDropdown:SetPoint("TOPLEFT", PADDING, y)
        borderTextureDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        useClassColorCheck = GUI:CreateFormCheckbox(tabContent, "Use Class Color for Border", "useClassColorBorder", combatTimerDB, function(val)
            if val then
                combatTimerDB.useAccentColorBorder = false
                if useAccentColorCheck and useAccentColorCheck.SetChecked then useAccentColorCheck:SetChecked(false) end
            end
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
            if borderColorPicker and borderColorPicker.SetEnabled then
                borderColorPicker:SetEnabled(not val and not combatTimerDB.useAccentColorBorder and not combatTimerDB.hideBorder)
            end
        end)
        useClassColorCheck:SetPoint("TOPLEFT", PADDING, y)
        useClassColorCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        useAccentColorCheck = GUI:CreateFormCheckbox(tabContent, "Use Accent Color for Border", "useAccentColorBorder", combatTimerDB, function(val)
            if val then
                combatTimerDB.useClassColorBorder = false
                if useClassColorCheck and useClassColorCheck.SetChecked then useClassColorCheck:SetChecked(false) end
            end
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
            if borderColorPicker and borderColorPicker.SetEnabled then
                borderColorPicker:SetEnabled(not val and not combatTimerDB.useClassColorBorder and not combatTimerDB.hideBorder)
            end
        end)
        useAccentColorCheck:SetPoint("TOPLEFT", PADDING, y)
        useAccentColorCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        borderColorPicker = GUI:CreateFormColorPicker(tabContent, "Border Color", "borderColor", combatTimerDB, function()
            if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end
        end)
        borderColorPicker:SetPoint("TOPLEFT", PADDING, y)
        borderColorPicker:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW

        -- Apply initial border control states
        UpdateBorderControlsEnabled(not combatTimerDB.hideBorder)
    end

    y = y - 10

    -- QUI Panel Settings
    local panelHeader = GUI:CreateSectionHeader(tabContent, "QUI Panel Settings")
    panelHeader:SetPoint("TOPLEFT", PADDING, y)
    y = y - panelHeader.gap

    local minimapBtnDB = db and db.minimapButton
    if minimapBtnDB then
        local showMinimapIconCheck = GUI:CreateFormCheckbox(tabContent, "Hide QUI Minimap Icon", "hide", minimapBtnDB, function(dbVal)
            local LibDBIcon = LibStub("LibDBIcon-1.0", true)
            if LibDBIcon then
                if dbVal then
                    LibDBIcon:Hide("QUI")
                else
                    LibDBIcon:Show("QUI")
                end
            end
        end)
        showMinimapIconCheck:SetPoint("TOPLEFT", PADDING, y)
        showMinimapIconCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
        y = y - FORM_ROW
    end

    local panelAlphaSlider = GUI:CreateFormSlider(tabContent, "QUI Panel Transparency", 0.3, 1.0, 0.01, "configPanelAlpha", db, function(val)
        local mainFrame = GUI.MainFrame
        if mainFrame then
            local bgColor = GUI.Colors.bg
            mainFrame:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], val)
        end
    end)
    panelAlphaSlider:SetPoint("TOPLEFT", PADDING, y)
    panelAlphaSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    y = y - FORM_ROW

    tabContent:SetHeight(math.abs(y) + 50)
end

-- Export
ns.QUI_QoLOptions = {
    BuildGeneralTab = BuildGeneralTab
}
