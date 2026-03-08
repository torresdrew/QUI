local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local C = GUI.Colors
local Shared = ns.QUI_Options
local QUICore = ns.Addon
local UIKit = ns.UIKit

-- Local references for shared infrastructure
local CreateScrollableContent = Shared.CreateScrollableContent

local GetCore = ns.Helpers.GetCore

--------------------------------------------------------------------------------
-- Helper: Create a scrollable text box container
--------------------------------------------------------------------------------
local function CreateScrollableTextBox(parent, height, text)
    return GUI:CreateScrollableTextBox(parent, height, text)
end

local function ApplyImportSurface(frame, bgColor, borderColor)
    if not frame then return end

    if not frame.bg then
        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        frame.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        if UIKit and UIKit.DisablePixelSnap then
            UIKit.DisablePixelSnap(frame.bg)
        end
    end
    frame.bg:SetVertexColor((bgColor or C.bg)[1], (bgColor or C.bg)[2], (bgColor or C.bg)[3], (bgColor or C.bg)[4] or 1)

    if UIKit and UIKit.CreateBackdropBorder then
        frame.Border = UIKit.CreateBackdropBorder(
            frame,
            1,
            (borderColor or C.border)[1],
            (borderColor or C.border)[2],
            (borderColor or C.border)[3],
            (borderColor or C.border)[4] or 1
        )
    end
end

--------------------------------------------------------------------------------
-- SUB-TAB BUILDER: Import/Export (user profile import/export)
--------------------------------------------------------------------------------
local function BuildImportExportTab(tabContent)
    local y = -10
    local PAD = 10

    GUI:SetSearchContext({tabIndex = 13, tabName = "Import & Export Strings", subTabIndex = 1, subTabName = "Import/Export"})

    local info = GUI:CreateLabel(tabContent, "Import and export QUI profiles", 11, C.textMuted)
    info:SetPoint("TOPLEFT", PAD, y)
    info:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    info:SetJustifyH("LEFT")
    y = y - 28

    local validationNote = GUI:CreateLabel(tabContent, "Import now validates payload structure and may reject incompatible or corrupted strings.", 10, C.textMuted)
    validationNote:SetPoint("TOPLEFT", PAD, y)
    validationNote:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    validationNote:SetJustifyH("LEFT")
    y = y - 20

    -- Export Section Header
    local exportHeader = GUI:CreateSectionHeader(tabContent, "Export Current Profile")
    exportHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - exportHeader.gap

    -- Export text box
    local exportContainer = CreateScrollableTextBox(tabContent, 100, "")
    exportContainer:SetPoint("TOPLEFT", PAD, y)
    exportContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    local exportEditBox = exportContainer.editBox
    exportEditBox:SetTextColor(0.8, 0.85, 0.9, 1)
    exportEditBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    -- Populate export string
    local function RefreshExportString()
        local core = GetCore()
        if core and core.ExportProfileToString then
            local str = core:ExportProfileToString()
            exportEditBox:SetText(str or "Error generating export string")
        else
            exportEditBox:SetText("QUICore not available")
        end
    end
    RefreshExportString()

    y = y - 115

    -- SELECT ALL button (themed)
    local selectBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 28, function()
        RefreshExportString()
        exportEditBox:SetFocus()
        exportEditBox:HighlightText()
    end)
    selectBtn:SetPoint("TOPLEFT", PAD, y)

    -- Hint text
    local copyHint = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    copyHint:SetPoint("LEFT", selectBtn, "RIGHT", 12, 0)

    y = y - 50

    -- Import Section Header
    local importHeader = GUI:CreateSectionHeader(tabContent, "Import Profile String")
    importHeader:SetPoint("TOPLEFT", PAD, y)

    -- Paste hint next to header
    local pasteHint = GUI:CreateLabel(tabContent, "press Ctrl+V to paste", 11, C.textMuted)
    pasteHint:SetPoint("LEFT", importHeader, "RIGHT", 12, 0)

    y = y - importHeader.gap

    -- Import text box (user pastes string here)
    local importContainer = CreateScrollableTextBox(tabContent, 100, "")
    importContainer:SetPoint("TOPLEFT", PAD, y)
    importContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    importContainer:EnableMouse(true)
    local importEditBox = importContainer.editBox
    importEditBox:SetTextColor(0.8, 0.85, 0.9, 1)
    importContainer:SetScript("OnMouseDown", function()
        importEditBox:SetFocus()
    end)

    y = y - 115

    -- IMPORT AND RELOAD button (themed)
    local importBtn = GUI:CreateButton(tabContent, "IMPORT AND RELOAD", 200, 28, function()
        local str = importEditBox:GetText()
        if not str or str == "" then
            print("|cffff0000QUI: No import string provided.|r")
            return
        end
        local core = GetCore()
        if core and core.ImportProfileFromString then
            local ok, err = core:ImportProfileFromString(str)
            local printFeedback = (Shared and Shared.PrintImportFeedback) or ns.PrintImportFeedback
            if printFeedback then
                printFeedback(ok, err, ok)
            elseif ok then
                print("|cff34D399QUI:|r " .. (err or "Profile imported successfully!"))
                print("|cff34D399QUI:|r Please type |cFFFFD700/reload|r to apply changes.")
            else
                print("|cffff4d4dQUI:|r Import failed: " .. tostring(err or "Unknown error"))
            end
        else
            print("|cffff0000QUI: QUICore not available for import.|r")
        end
    end)
    importBtn:SetPoint("TOPLEFT", PAD, y)
    y = y - 40

    tabContent:SetHeight(math.abs(y) + 20)
end

--------------------------------------------------------------------------------
-- SUB-TAB BUILDER: Quazii's Strings (preset import strings)
--------------------------------------------------------------------------------
local function BuildQuaziiStringsTab(tabContent)
    local y = -10
    local PAD = 10
    local BOX_HEIGHT = 70

    GUI:SetSearchContext({tabIndex = 13, tabName = "Import & Export Strings", subTabIndex = 2, subTabName = "Quazii's Strings"})

    -- Disclaimer banner
    local warnBg = CreateFrame("Frame", nil, tabContent)
    warnBg:SetPoint("TOPLEFT", PAD, y)
    warnBg:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    ApplyImportSurface(warnBg, {0.5, 0.25, 0.0, 0.25}, {0.961, 0.620, 0.043, 0.6})

    local warnTitle = warnBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warnTitle:SetFont(GUI.FONT_PATH or "Fonts\\FRIZQT__.TTF", 12, "")
    warnTitle:SetTextColor(0.961, 0.620, 0.043)
    warnTitle:SetText("Warning: These strings are outdated")
    warnTitle:SetPoint("TOPLEFT", 10, -8)

    local warnText = warnBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warnText:SetFont(GUI.FONT_PATH or "Fonts\\FRIZQT__.TTF", 11, "")
    warnText:SetTextColor(0.8, 0.75, 0.65)
    warnText:SetText("These profile strings may no longer match the current version of QUI and could cause unexpected issues. The Edit Mode string in particular may conflict with QUI's skinning and anchoring. Use with caution \226\128\148 for a reliable starting point, use the Edit Mode string on the Welcome tab instead.")
    warnText:SetPoint("TOPLEFT", warnTitle, "BOTTOMLEFT", 0, -4)
    warnText:SetPoint("RIGHT", warnBg, "RIGHT", -10, 0)
    warnText:SetJustifyH("LEFT")
    warnText:SetWordWrap(true)

    -- Size the banner to fit the wrapped text
    warnBg:SetScript("OnShow", function(self)
        C_Timer.After(0, function()
            local textHeight = warnText:GetStringHeight() or 14
            self:SetHeight(textHeight + 32)
        end)
    end)
    warnBg:SetHeight(60)  -- initial estimate, OnShow will correct

    y = y - 68

    -- Store all text boxes for clearing selections
    local allTextBoxes = {}

    -- Helper to clear all selections except the target
    local function selectOnly(targetEditBox)
        for _, editBox in ipairs(allTextBoxes) do
            if editBox ~= targetEditBox then
                editBox:ClearFocus()
                editBox:HighlightText(0, 0)
            end
        end
        targetEditBox:SetFocus()
        targetEditBox:HighlightText()
    end

    -- =====================================================
    -- DETAILS! STRING
    -- =====================================================
    local detailsHeader = GUI:CreateSectionHeader(tabContent, "Details! String")
    detailsHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - detailsHeader.gap

    local detailsString = ""
    if _G.QUI and _G.QUI.imports and _G.QUI.imports.QuaziiDetails then
        detailsString = _G.QUI.imports.QuaziiDetails.data or ""
    end

    local detailsContainer = CreateScrollableTextBox(tabContent, BOX_HEIGHT, detailsString)
    detailsContainer:SetPoint("TOPLEFT", PAD, y)
    detailsContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    table.insert(allTextBoxes, detailsContainer.editBox)

    y = y - BOX_HEIGHT - 8

    local detailsBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 24, function()
        selectOnly(detailsContainer.editBox)
    end)
    detailsBtn:SetPoint("TOPLEFT", PAD, y)

    local detailsTip = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    detailsTip:SetPoint("LEFT", detailsBtn, "RIGHT", 10, 0)
    y = y - 40

    -- =====================================================
    -- PLATER STRING
    -- =====================================================
    local platerHeader = GUI:CreateSectionHeader(tabContent, "Plater String")
    platerHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - platerHeader.gap

    local platerString = ""
    if _G.QUI and _G.QUI.imports and _G.QUI.imports.Plater then
        platerString = _G.QUI.imports.Plater.data or ""
    end

    local platerContainer = CreateScrollableTextBox(tabContent, BOX_HEIGHT, platerString)
    platerContainer:SetPoint("TOPLEFT", PAD, y)
    platerContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    table.insert(allTextBoxes, platerContainer.editBox)

    y = y - BOX_HEIGHT - 8

    local platerBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 24, function()
        selectOnly(platerContainer.editBox)
    end)
    platerBtn:SetPoint("TOPLEFT", PAD, y)

    local platerTip = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    platerTip:SetPoint("LEFT", platerBtn, "RIGHT", 10, 0)
    y = y - 40

    -- =====================================================
    -- PLATYNATOR STRING
    -- =====================================================
    local platHeader = GUI:CreateSectionHeader(tabContent, "Platynator String")
    platHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - platHeader.gap

    local platString = ""
    if _G.QUI and _G.QUI.imports and _G.QUI.imports.Platynator then
        platString = _G.QUI.imports.Platynator.data or ""
    end

    local platContainer = CreateScrollableTextBox(tabContent, BOX_HEIGHT, platString)
    platContainer:SetPoint("TOPLEFT", PAD, y)
    platContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    table.insert(allTextBoxes, platContainer.editBox)

    y = y - BOX_HEIGHT - 8

    local platBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 24, function()
        selectOnly(platContainer.editBox)
    end)
    platBtn:SetPoint("TOPLEFT", PAD, y)

    local platTip = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    platTip:SetPoint("LEFT", platBtn, "RIGHT", 10, 0)
    y = y - 40

    -- =====================================================
    -- QUI IMPORT/EXPORT STRING - DEFAULT PROFILE
    -- =====================================================
    local quiHeader = GUI:CreateSectionHeader(tabContent, "QUI Import/Export String - Default Profile")
    quiHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - quiHeader.gap

    local quiString = ""
    if _G.QUI and _G.QUI.imports and _G.QUI.imports.QUIProfile then
        quiString = _G.QUI.imports.QUIProfile.data or ""
    end

    local quiContainer = CreateScrollableTextBox(tabContent, BOX_HEIGHT, quiString)
    quiContainer:SetPoint("TOPLEFT", PAD, y)
    quiContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    table.insert(allTextBoxes, quiContainer.editBox)

    y = y - BOX_HEIGHT - 8

    local quiBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 24, function()
        selectOnly(quiContainer.editBox)
    end)
    quiBtn:SetPoint("TOPLEFT", PAD, y)

    local quiTip = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    quiTip:SetPoint("LEFT", quiBtn, "RIGHT", 10, 0)
    y = y - 40

    -- =====================================================
    -- QUI IMPORT/EXPORT STRING - DARK MODE
    -- =====================================================
    local quiDarkHeader = GUI:CreateSectionHeader(tabContent, "QUI Import/Export String - Dark Mode")
    quiDarkHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - quiDarkHeader.gap

    local quiDarkString = ""
    if _G.QUI and _G.QUI.imports and _G.QUI.imports.QUIProfileDarkMode then
        quiDarkString = _G.QUI.imports.QUIProfileDarkMode.data or ""
    end

    local quiDarkContainer = CreateScrollableTextBox(tabContent, BOX_HEIGHT, quiDarkString)
    quiDarkContainer:SetPoint("TOPLEFT", PAD, y)
    quiDarkContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    table.insert(allTextBoxes, quiDarkContainer.editBox)

    y = y - BOX_HEIGHT - 8

    local quiDarkBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 24, function()
        selectOnly(quiDarkContainer.editBox)
    end)
    quiDarkBtn:SetPoint("TOPLEFT", PAD, y)

    local quiDarkTip = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    quiDarkTip:SetPoint("LEFT", quiDarkBtn, "RIGHT", 10, 0)
    y = y - 40

    -- =====================================================
    -- QUAZII EDIT MODE STRING
    -- =====================================================
    local editModeHeader = GUI:CreateSectionHeader(tabContent, "Quazii Edit Mode String")
    editModeHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - editModeHeader.gap

    local editModeString = ""
    if _G.QUI and _G.QUI.imports and _G.QUI.imports.EditMode then
        editModeString = _G.QUI.imports.EditMode.data or ""
    end

    local editModeContainer = CreateScrollableTextBox(tabContent, BOX_HEIGHT, editModeString)
    editModeContainer:SetPoint("TOPLEFT", PAD, y)
    editModeContainer:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    table.insert(allTextBoxes, editModeContainer.editBox)

    y = y - BOX_HEIGHT - 8

    local editModeBtn = GUI:CreateButton(tabContent, "SELECT ALL", 120, 24, function()
        selectOnly(editModeContainer.editBox)
    end)
    editModeBtn:SetPoint("TOPLEFT", PAD, y)

    local editModeTip = GUI:CreateLabel(tabContent, "then press Ctrl+C to copy", 11, C.textMuted)
    editModeTip:SetPoint("LEFT", editModeBtn, "RIGHT", 10, 0)
    y = y - 30

    tabContent:SetHeight(math.abs(y) + 30)
end

--------------------------------------------------------------------------------
-- PAGE: QUI Import/Export (with sub-tabs)
--------------------------------------------------------------------------------
local function CreateImportExportPage(parent)
    local scroll, content = CreateScrollableContent(parent)

    GUI:CreateSubTabs(content, {
        {name = "Import/Export", builder = BuildImportExportTab},
        {name = "Quazii's Strings", builder = BuildQuaziiStringsTab},
    })

    content:SetHeight(550)
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------
ns.QUI_ImportOptions = {
    CreateImportExportPage = CreateImportExportPage,
    BuildImportExportTab = BuildImportExportTab,
    BuildQuaziiStringsTab = BuildQuaziiStringsTab,
}
