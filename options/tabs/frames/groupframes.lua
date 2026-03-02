--[[
    QUI Group Frames Options
    Full settings UI with sub-tabs for all group frame features.
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local C = GUI.Colors
local Shared = ns.QUI_Options
local QUICore = ns.Addon

-- Local references
local PADDING = Shared.PADDING
local CreateScrollableContent = Shared.CreateScrollableContent
local GetDB = Shared.GetDB
local GetTextureList = Shared.GetTextureList
local GetFontList = Shared.GetFontList
local NINE_POINT_ANCHOR_OPTIONS = Shared.NINE_POINT_ANCHOR_OPTIONS

-- Constants
local FORM_ROW = 32
local SECTION_GAP = 46
local SLIDER_HEIGHT = 65
local PAD = 10

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------
local function GetGFDB()
    local db = GetDB()
    return db and db.quiGroupFrames
end

local function RefreshGF()
    if _G.QUI_RefreshGroupFrames then
        _G.QUI_RefreshGroupFrames()
    end
end

local GROW_OPTIONS = {
    { value = "DOWN", text = "Down" },
    { value = "UP", text = "Up" },
}

local GROUP_GROW_OPTIONS = {
    { value = "RIGHT", text = "Right" },
    { value = "LEFT", text = "Left" },
}

local SORT_OPTIONS = {
    { value = "INDEX", text = "Group Index" },
    { value = "NAME", text = "Name" },
}

local GROUP_BY_OPTIONS = {
    { value = "GROUP", text = "Group Number" },
    { value = "ROLE", text = "Role" },
    { value = "CLASS", text = "Class" },
}

local HEALTH_DISPLAY_OPTIONS = {
    { value = "percent", text = "Percentage" },
    { value = "absolute", text = "Absolute" },
    { value = "both", text = "Both" },
    { value = "deficit", text = "Deficit" },
}

local ANCHOR_SIDE_OPTIONS = {
    { value = "LEFT", text = "Left" },
    { value = "RIGHT", text = "Right" },
}

local PET_ANCHOR_OPTIONS = {
    { value = "BOTTOM", text = "Below Group" },
    { value = "RIGHT", text = "Right of Group" },
    { value = "LEFT", text = "Left of Group" },
}

local INDICATOR_TYPE_OPTIONS = {
    { value = "icon", text = "Icon" },
    { value = "square", text = "Colored Square" },
    { value = "bar", text = "Progress Bar" },
    { value = "border", text = "Border Color" },
    { value = "healthcolor", text = "Health Bar Color" },
}

local BAR_ORIENTATION_OPTIONS = {
    { value = "HORIZONTAL", text = "Horizontal" },
    { value = "VERTICAL", text = "Vertical" },
}

local BAR_WIDTH_OPTIONS = {
    { value = "full", text = "Full Width" },
    { value = "half", text = "Half Width" },
}

---------------------------------------------------------------------------
-- PAGE: Group Frames
---------------------------------------------------------------------------
local function CreateGroupFramesPage(parent)
    local scroll, content = CreateScrollableContent(parent)
    local db = GetDB()

    -- Build sub-tabs
    local function BuildGeneralTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 1, subTabName = "General"})

        if not gfdb then
            local info = GUI:CreateLabel(tabContent, "Group frame settings not available - database not loaded", 12, C.textMuted)
            info:SetPoint("TOPLEFT", PAD, y)
            tabContent:SetHeight(100)
            return
        end

        -- Enable checkbox (requires reload)
        local enableCheck = GUI:CreateFormCheckbox(tabContent, "Enable Group Frames (Req. Reload)", "enabled", gfdb, function()
            GUI:ShowConfirmation({
                title = "Reload UI?",
                message = "Enabling or disabling group frames requires a UI reload to take effect.",
                acceptText = "Reload",
                cancelText = "Later",
                onAccept = function() QUI:SafeReload() end,
            })
        end)
        enableCheck:SetPoint("TOPLEFT", PAD, y)
        enableCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Info text
        local infoText = GUI:CreateDescription(tabContent, "Custom party and raid frames. Replaces Blizzard's default group frames when enabled. Compatible with DandersFrames (only one system active at a time).")
        infoText:SetPoint("TOPLEFT", PAD, y)
        infoText:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - 40

        -- Test Mode section
        local testHeader = GUI:CreateSectionHeader(tabContent, "Test / Preview")
        testHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - testHeader.gap

        local testDesc = GUI:CreateLabel(tabContent, "Preview group frames when solo. Also available via /qui grouptest", 11, C.textMuted)
        testDesc:SetPoint("TOPLEFT", PAD, y)
        testDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        testDesc:SetJustifyH("LEFT")
        y = y - 24

        -- Party test button
        local partyTestBtn = GUI:CreateButton(tabContent, "Party Preview (5)", 150, 28, function()
            local editMode = ns.QUI_GroupFrameEditMode
            if editMode then editMode:ToggleTestMode("party") end
        end)
        partyTestBtn:SetPoint("TOPLEFT", PAD, y)

        -- Raid test button
        local raidTestBtn = GUI:CreateButton(tabContent, "Raid Preview", 150, 28, function()
            local editMode = ns.QUI_GroupFrameEditMode
            if editMode then editMode:ToggleTestMode("raid") end
        end)
        raidTestBtn:SetPoint("LEFT", partyTestBtn, "RIGHT", 10, 0)
        y = y - 36

        -- Edit Mode button
        local editBtn = GUI:CreateButton(tabContent, "Toggle Edit Mode", 150, 28, function()
            local editMode = ns.QUI_GroupFrameEditMode
            if editMode then editMode:ToggleEditMode() end
        end)
        editBtn:SetPoint("TOPLEFT", PAD, y)
        y = y - 40

        -- Appearance section
        local appearHeader = GUI:CreateSectionHeader(tabContent, "Appearance")
        appearHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - appearHeader.gap

        local general = gfdb.general
        if not general then gfdb.general = {} general = gfdb.general end

        -- Class colors
        local classColorCheck = GUI:CreateFormCheckbox(tabContent, "Use Class Colors", "useClassColor", general, RefreshGF)
        classColorCheck:SetPoint("TOPLEFT", PAD, y)
        classColorCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Dark mode
        local darkModeCheck = GUI:CreateFormCheckbox(tabContent, "Dark Mode", "darkMode", general, RefreshGF)
        darkModeCheck:SetPoint("TOPLEFT", PAD, y)
        darkModeCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Texture
        local textureDrop = GUI:CreateDropdown(tabContent, "Health Bar Texture", GetTextureList(), "texture", general, RefreshGF)
        textureDrop:SetPoint("TOPLEFT", PAD, y)
        textureDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Border size
        local borderSlider = GUI:CreateFormSlider(tabContent, "Border Size", 0, 3, 1, "borderSize", general, RefreshGF)
        borderSlider:SetPoint("TOPLEFT", PAD, y)
        borderSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Font
        local fontDrop = GUI:CreateDropdown(tabContent, "Font", GetFontList(), "font", general, RefreshGF)
        fontDrop:SetPoint("TOPLEFT", PAD, y)
        fontDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Font size
        local fontSizeSlider = GUI:CreateFormSlider(tabContent, "Font Size", 8, 20, 1, "fontSize", general, RefreshGF)
        fontSizeSlider:SetPoint("TOPLEFT", PAD, y)
        fontSizeSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Tooltips
        local tooltipCheck = GUI:CreateFormCheckbox(tabContent, "Show Tooltips on Hover", "showTooltips", general, RefreshGF)
        tooltipCheck:SetPoint("TOPLEFT", PAD, y)
        tooltipCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildLayoutTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 2, subTabName = "Layout"})

        local layout = gfdb.layout
        if not layout then gfdb.layout = {} layout = gfdb.layout end
        local position = gfdb.position
        if not position then gfdb.position = {} position = gfdb.position end

        -- Grow direction
        local growDrop = GUI:CreateDropdown(tabContent, "Grow Direction", GROW_OPTIONS, "growDirection", layout, RefreshGF)
        growDrop:SetPoint("TOPLEFT", PAD, y)
        growDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Group grow direction (raid)
        local groupGrowDrop = GUI:CreateDropdown(tabContent, "Group Grow Direction (Raid)", GROUP_GROW_OPTIONS, "groupGrowDirection", layout, RefreshGF)
        groupGrowDrop:SetPoint("TOPLEFT", PAD, y)
        groupGrowDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Spacing
        local spacingSlider = GUI:CreateFormSlider(tabContent, "Frame Spacing", 0, 10, 1, "spacing", layout, RefreshGF)
        spacingSlider:SetPoint("TOPLEFT", PAD, y)
        spacingSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Group spacing
        local groupSpacingSlider = GUI:CreateFormSlider(tabContent, "Group Spacing (Raid)", 0, 30, 1, "groupSpacing", layout, RefreshGF)
        groupSpacingSlider:SetPoint("TOPLEFT", PAD, y)
        groupSpacingSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Show player
        local showPlayerCheck = GUI:CreateFormCheckbox(tabContent, "Show Player in Group", "showPlayer", layout, RefreshGF)
        showPlayerCheck:SetPoint("TOPLEFT", PAD, y)
        showPlayerCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Sorting section
        local sortHeader = GUI:CreateSectionHeader(tabContent, "Sorting")
        sortHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - sortHeader.gap

        -- Group By
        local groupByDrop = GUI:CreateDropdown(tabContent, "Group By", GROUP_BY_OPTIONS, "groupBy", layout, RefreshGF)
        groupByDrop:SetPoint("TOPLEFT", PAD, y)
        groupByDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Sort method
        local sortDrop = GUI:CreateDropdown(tabContent, "Sort Method", SORT_OPTIONS, "sortMethod", layout, RefreshGF)
        sortDrop:SetPoint("TOPLEFT", PAD, y)
        sortDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Sort by role
        local roleSortCheck = GUI:CreateFormCheckbox(tabContent, "Sort by Role (Tank > Healer > DPS)", "sortByRole", layout, RefreshGF)
        roleSortCheck:SetPoint("TOPLEFT", PAD, y)
        roleSortCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Position section
        local posHeader = GUI:CreateSectionHeader(tabContent, "Position")
        posHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - posHeader.gap

        local xSlider = GUI:CreateFormSlider(tabContent, "X Offset", -800, 800, 1, "offsetX", position, RefreshGF)
        xSlider:SetPoint("TOPLEFT", PAD, y)
        xSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local ySlider = GUI:CreateFormSlider(tabContent, "Y Offset", -500, 500, 1, "offsetY", position, RefreshGF)
        ySlider:SetPoint("TOPLEFT", PAD, y)
        ySlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildDimensionsTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 3, subTabName = "Dimensions"})

        local dims = gfdb.dimensions
        if not dims then gfdb.dimensions = {} dims = gfdb.dimensions end

        -- Party dimensions
        local partyHeader = GUI:CreateSectionHeader(tabContent, "Party (1-5 players)")
        partyHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - partyHeader.gap

        local partyW = GUI:CreateFormSlider(tabContent, "Width", 80, 400, 1, "partyWidth", dims, RefreshGF)
        partyW:SetPoint("TOPLEFT", PAD, y)
        partyW:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local partyH = GUI:CreateFormSlider(tabContent, "Height", 16, 80, 1, "partyHeight", dims, RefreshGF)
        partyH:SetPoint("TOPLEFT", PAD, y)
        partyH:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Small raid
        local smallHeader = GUI:CreateSectionHeader(tabContent, "Small Raid (6-15 players)")
        smallHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - smallHeader.gap

        local smallW = GUI:CreateFormSlider(tabContent, "Width", 60, 400, 1, "smallRaidWidth", dims, RefreshGF)
        smallW:SetPoint("TOPLEFT", PAD, y)
        smallW:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local smallH = GUI:CreateFormSlider(tabContent, "Height", 14, 60, 1, "smallRaidHeight", dims, RefreshGF)
        smallH:SetPoint("TOPLEFT", PAD, y)
        smallH:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Medium raid
        local medHeader = GUI:CreateSectionHeader(tabContent, "Medium Raid (16-25 players)")
        medHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - medHeader.gap

        local medW = GUI:CreateFormSlider(tabContent, "Width", 50, 300, 1, "mediumRaidWidth", dims, RefreshGF)
        medW:SetPoint("TOPLEFT", PAD, y)
        medW:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local medH = GUI:CreateFormSlider(tabContent, "Height", 12, 50, 1, "mediumRaidHeight", dims, RefreshGF)
        medH:SetPoint("TOPLEFT", PAD, y)
        medH:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Large raid
        local largeHeader = GUI:CreateSectionHeader(tabContent, "Large Raid (26-40 players)")
        largeHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - largeHeader.gap

        local largeW = GUI:CreateFormSlider(tabContent, "Width", 40, 250, 1, "largeRaidWidth", dims, RefreshGF)
        largeW:SetPoint("TOPLEFT", PAD, y)
        largeW:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local largeH = GUI:CreateFormSlider(tabContent, "Height", 10, 40, 1, "largeRaidHeight", dims, RefreshGF)
        largeH:SetPoint("TOPLEFT", PAD, y)
        largeH:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Power bar height
        local powerHeader = GUI:CreateSectionHeader(tabContent, "Power Bar")
        powerHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - powerHeader.gap

        local power = gfdb.power
        if not power then gfdb.power = {} power = gfdb.power end

        local showPowerCheck = GUI:CreateFormCheckbox(tabContent, "Show Power Bar", "showPowerBar", power, RefreshGF)
        showPowerCheck:SetPoint("TOPLEFT", PAD, y)
        showPowerCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local powerH = GUI:CreateFormSlider(tabContent, "Power Bar Height", 1, 10, 1, "powerBarHeight", power, RefreshGF)
        powerH:SetPoint("TOPLEFT", PAD, y)
        powerH:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildHealthPowerTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 4, subTabName = "Health & Power"})

        -- Health section
        local healthHeader = GUI:CreateSectionHeader(tabContent, "Health Text")
        healthHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - healthHeader.gap

        local health = gfdb.health
        if not health then gfdb.health = {} health = gfdb.health end

        local showHealthCheck = GUI:CreateFormCheckbox(tabContent, "Show Health Text", "showHealthText", health, RefreshGF)
        showHealthCheck:SetPoint("TOPLEFT", PAD, y)
        showHealthCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local displayDrop = GUI:CreateDropdown(tabContent, "Display Style", HEALTH_DISPLAY_OPTIONS, "healthDisplayStyle", health, RefreshGF)
        displayDrop:SetPoint("TOPLEFT", PAD, y)
        displayDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local healthFontSlider = GUI:CreateFormSlider(tabContent, "Health Font Size", 8, 20, 1, "healthFontSize", health, RefreshGF)
        healthFontSlider:SetPoint("TOPLEFT", PAD, y)
        healthFontSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local healthAnchorDrop = GUI:CreateDropdown(tabContent, "Health Text Anchor", NINE_POINT_ANCHOR_OPTIONS, "healthAnchor", health, RefreshGF)
        healthAnchorDrop:SetPoint("TOPLEFT", PAD, y)
        healthAnchorDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local healthColor = GUI:CreateFormColorPicker(tabContent, "Health Text Color", "healthTextColor", health, RefreshGF)
        healthColor:SetPoint("TOPLEFT", PAD, y)
        healthColor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Name section
        local nameHeader = GUI:CreateSectionHeader(tabContent, "Name Text")
        nameHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - nameHeader.gap

        local nameDB = gfdb.name
        if not nameDB then gfdb.name = {} nameDB = gfdb.name end

        local showNameCheck = GUI:CreateFormCheckbox(tabContent, "Show Name", "showName", nameDB, RefreshGF)
        showNameCheck:SetPoint("TOPLEFT", PAD, y)
        showNameCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local nameFontSlider = GUI:CreateFormSlider(tabContent, "Name Font Size", 8, 20, 1, "nameFontSize", nameDB, RefreshGF)
        nameFontSlider:SetPoint("TOPLEFT", PAD, y)
        nameFontSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local nameAnchorDrop = GUI:CreateDropdown(tabContent, "Name Anchor", NINE_POINT_ANCHOR_OPTIONS, "nameAnchor", nameDB, RefreshGF)
        nameAnchorDrop:SetPoint("TOPLEFT", PAD, y)
        nameAnchorDrop:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local maxNameSlider = GUI:CreateFormSlider(tabContent, "Max Name Length", 0, 20, 1, "maxNameLength", nameDB, RefreshGF)
        maxNameSlider:SetPoint("TOPLEFT", PAD, y)
        maxNameSlider:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local classColorNameCheck = GUI:CreateFormCheckbox(tabContent, "Use Class Color for Name", "nameTextUseClassColor", nameDB, RefreshGF)
        classColorNameCheck:SetPoint("TOPLEFT", PAD, y)
        classColorNameCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local nameColor = GUI:CreateFormColorPicker(tabContent, "Name Text Color", "nameTextColor", nameDB, RefreshGF)
        nameColor:SetPoint("TOPLEFT", PAD, y)
        nameColor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Absorbs section
        local absorbHeader = GUI:CreateSectionHeader(tabContent, "Absorbs & Heal Prediction")
        absorbHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - absorbHeader.gap

        local absorbDB = gfdb.absorbs
        if not absorbDB then gfdb.absorbs = {} absorbDB = gfdb.absorbs end

        local absorbCheck = GUI:CreateFormCheckbox(tabContent, "Show Absorb Overlay", "enabled", absorbDB, RefreshGF)
        absorbCheck:SetPoint("TOPLEFT", PAD, y)
        absorbCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local absorbOpacity = GUI:CreateFormSlider(tabContent, "Absorb Opacity", 0.1, 1, 0.05, "opacity", absorbDB, RefreshGF)
        absorbOpacity:SetPoint("TOPLEFT", PAD, y)
        absorbOpacity:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local healPredDB = gfdb.healPrediction
        if not healPredDB then gfdb.healPrediction = {} healPredDB = gfdb.healPrediction end

        local healPredCheck = GUI:CreateFormCheckbox(tabContent, "Show Heal Prediction", "enabled", healPredDB, RefreshGF)
        healPredCheck:SetPoint("TOPLEFT", PAD, y)
        healPredCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local healPredOpacity = GUI:CreateFormSlider(tabContent, "Heal Prediction Opacity", 0.1, 1, 0.05, "opacity", healPredDB, RefreshGF)
        healPredOpacity:SetPoint("TOPLEFT", PAD, y)
        healPredOpacity:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildIndicatorsTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 5, subTabName = "Indicators"})

        local ind = gfdb.indicators
        if not ind then gfdb.indicators = {} ind = gfdb.indicators end

        -- Role icon
        local roleHeader = GUI:CreateSectionHeader(tabContent, "Role & Status Icons")
        roleHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - roleHeader.gap

        local roleCheck = GUI:CreateFormCheckbox(tabContent, "Show Role Icon", "showRoleIcon", ind, RefreshGF)
        roleCheck:SetPoint("TOPLEFT", PAD, y)
        roleCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local roleSize = GUI:CreateFormSlider(tabContent, "Role Icon Size", 8, 24, 1, "roleIconSize", ind, RefreshGF)
        roleSize:SetPoint("TOPLEFT", PAD, y)
        roleSize:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local roleAnchor = GUI:CreateDropdown(tabContent, "Role Icon Anchor", NINE_POINT_ANCHOR_OPTIONS, "roleIconAnchor", ind, RefreshGF)
        roleAnchor:SetPoint("TOPLEFT", PAD, y)
        roleAnchor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Ready check
        local readyCheck = GUI:CreateFormCheckbox(tabContent, "Show Ready Check", "showReadyCheck", ind, RefreshGF)
        readyCheck:SetPoint("TOPLEFT", PAD, y)
        readyCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Resurrection indicator
        local resCheck = GUI:CreateFormCheckbox(tabContent, "Show Resurrection Indicator", "showResurrection", ind, RefreshGF)
        resCheck:SetPoint("TOPLEFT", PAD, y)
        resCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Summon pending
        local summonCheck = GUI:CreateFormCheckbox(tabContent, "Show Summon Pending", "showSummonPending", ind, RefreshGF)
        summonCheck:SetPoint("TOPLEFT", PAD, y)
        summonCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Leader icon
        local leaderCheck = GUI:CreateFormCheckbox(tabContent, "Show Leader Icon", "showLeaderIcon", ind, RefreshGF)
        leaderCheck:SetPoint("TOPLEFT", PAD, y)
        leaderCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Target marker
        local markerCheck = GUI:CreateFormCheckbox(tabContent, "Show Raid Target Marker", "showTargetMarker", ind, RefreshGF)
        markerCheck:SetPoint("TOPLEFT", PAD, y)
        markerCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Phase icon
        local phaseCheck = GUI:CreateFormCheckbox(tabContent, "Show Phase Icon", "showPhaseIcon", ind, RefreshGF)
        phaseCheck:SetPoint("TOPLEFT", PAD, y)
        phaseCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Threat border
        local threatHeader = GUI:CreateSectionHeader(tabContent, "Threat")
        threatHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - threatHeader.gap

        local threatCheck = GUI:CreateFormCheckbox(tabContent, "Show Threat Border", "showThreatBorder", ind, RefreshGF)
        threatCheck:SetPoint("TOPLEFT", PAD, y)
        threatCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local threatColor = GUI:CreateFormColorPicker(tabContent, "Threat Color", "threatColor", ind, RefreshGF)
        threatColor:SetPoint("TOPLEFT", PAD, y)
        threatColor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildHealerFeaturesTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 6, subTabName = "Healer Features"})

        local healer = gfdb.healer
        if not healer then gfdb.healer = {} healer = gfdb.healer end

        -- Dispel overlay
        local dispelHeader = GUI:CreateSectionHeader(tabContent, "Dispel Overlay")
        dispelHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - dispelHeader.gap

        local dispelDesc = GUI:CreateLabel(tabContent, "Colors the frame border based on dispellable debuff type (Magic=blue, Curse=purple, Disease=brown, Poison=green)", 11, C.textMuted)
        dispelDesc:SetPoint("TOPLEFT", PAD, y)
        dispelDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        dispelDesc:SetJustifyH("LEFT")
        y = y - 30

        local dispelDB = healer.dispelOverlay
        if not dispelDB then healer.dispelOverlay = {} dispelDB = healer.dispelOverlay end

        local dispelCheck = GUI:CreateFormCheckbox(tabContent, "Enable Dispel Overlay", "enabled", dispelDB, RefreshGF)
        dispelCheck:SetPoint("TOPLEFT", PAD, y)
        dispelCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local dispelOpacity = GUI:CreateFormSlider(tabContent, "Overlay Opacity", 0.1, 1, 0.05, "opacity", dispelDB, RefreshGF)
        dispelOpacity:SetPoint("TOPLEFT", PAD, y)
        dispelOpacity:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Target highlight
        local highlightHeader = GUI:CreateSectionHeader(tabContent, "Target Highlight")
        highlightHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - highlightHeader.gap

        local highlightDB = healer.targetHighlight
        if not highlightDB then healer.targetHighlight = {} highlightDB = healer.targetHighlight end

        local highlightCheck = GUI:CreateFormCheckbox(tabContent, "Highlight Current Target", "enabled", highlightDB, RefreshGF)
        highlightCheck:SetPoint("TOPLEFT", PAD, y)
        highlightCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local highlightColor = GUI:CreateFormColorPicker(tabContent, "Highlight Color", "color", highlightDB, RefreshGF)
        highlightColor:SetPoint("TOPLEFT", PAD, y)
        highlightColor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- My buff indicator
        local myBuffHeader = GUI:CreateSectionHeader(tabContent, "My Buff Indicator")
        myBuffHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - myBuffHeader.gap

        local myBuffDesc = GUI:CreateLabel(tabContent, "Shows a visual overlay when you have an active buff on the unit (e.g., HoTs for healers)", 11, C.textMuted)
        myBuffDesc:SetPoint("TOPLEFT", PAD, y)
        myBuffDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        myBuffDesc:SetJustifyH("LEFT")
        y = y - 30

        local myBuffDB = healer.myBuffIndicator
        if not myBuffDB then healer.myBuffIndicator = {} myBuffDB = healer.myBuffIndicator end

        local myBuffCheck = GUI:CreateFormCheckbox(tabContent, "Enable My Buff Indicator", "enabled", myBuffDB, RefreshGF)
        myBuffCheck:SetPoint("TOPLEFT", PAD, y)
        myBuffCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local myBuffColor = GUI:CreateFormColorPicker(tabContent, "Indicator Color", "color", myBuffDB, RefreshGF)
        myBuffColor:SetPoint("TOPLEFT", PAD, y)
        myBuffColor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Defensive indicator
        local defHeader = GUI:CreateSectionHeader(tabContent, "Defensive Indicator")
        defHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - defHeader.gap

        local defDB = healer.defensiveIndicator
        if not defDB then healer.defensiveIndicator = {} defDB = healer.defensiveIndicator end

        local defCheck = GUI:CreateFormCheckbox(tabContent, "Show Defensive Cooldown Icon", "enabled", defDB, RefreshGF)
        defCheck:SetPoint("TOPLEFT", PAD, y)
        defCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local defSize = GUI:CreateFormSlider(tabContent, "Icon Size", 10, 30, 1, "iconSize", defDB, RefreshGF)
        defSize:SetPoint("TOPLEFT", PAD, y)
        defSize:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildAurasTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 7, subTabName = "Auras"})

        local auras = gfdb.auras
        if not auras then gfdb.auras = {} auras = gfdb.auras end

        -- Debuffs
        local debuffHeader = GUI:CreateSectionHeader(tabContent, "Debuffs")
        debuffHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - debuffHeader.gap

        local debuffCheck = GUI:CreateFormCheckbox(tabContent, "Show Debuffs", "showDebuffs", auras, RefreshGF)
        debuffCheck:SetPoint("TOPLEFT", PAD, y)
        debuffCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local maxDebuffs = GUI:CreateFormSlider(tabContent, "Max Debuff Icons", 0, 8, 1, "maxDebuffs", auras, RefreshGF)
        maxDebuffs:SetPoint("TOPLEFT", PAD, y)
        maxDebuffs:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local debuffSize = GUI:CreateFormSlider(tabContent, "Debuff Icon Size", 8, 32, 1, "debuffIconSize", auras, RefreshGF)
        debuffSize:SetPoint("TOPLEFT", PAD, y)
        debuffSize:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Buffs
        local buffHeader = GUI:CreateSectionHeader(tabContent, "Buffs")
        buffHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - buffHeader.gap

        local buffCheck = GUI:CreateFormCheckbox(tabContent, "Show Buffs", "showBuffs", auras, RefreshGF)
        buffCheck:SetPoint("TOPLEFT", PAD, y)
        buffCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local maxBuffs = GUI:CreateFormSlider(tabContent, "Max Buff Icons", 0, 8, 1, "maxBuffs", auras, RefreshGF)
        maxBuffs:SetPoint("TOPLEFT", PAD, y)
        maxBuffs:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local buffSize = GUI:CreateFormSlider(tabContent, "Buff Icon Size", 8, 32, 1, "buffIconSize", auras, RefreshGF)
        buffSize:SetPoint("TOPLEFT", PAD, y)
        buffSize:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Visual settings
        local visualHeader = GUI:CreateSectionHeader(tabContent, "Visual")
        visualHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - visualHeader.gap

        local durationColorCheck = GUI:CreateFormCheckbox(tabContent, "Duration Color Coding (green → yellow → red)", "showDurationColor", auras, RefreshGF)
        durationColorCheck:SetPoint("TOPLEFT", PAD, y)
        durationColorCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local pulseCheck = GUI:CreateFormCheckbox(tabContent, "Expiring Pulse Animation", "showExpiringPulse", auras, RefreshGF)
        pulseCheck:SetPoint("TOPLEFT", PAD, y)
        pulseCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildAuraIndicatorsTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 8, subTabName = "Aura Indicators"})

        local aidb = gfdb.auraIndicators
        if not aidb then gfdb.auraIndicators = {} aidb = gfdb.auraIndicators end

        -- Enable
        local enableCheck = GUI:CreateFormCheckbox(tabContent, "Enable Aura Indicators", "enabled", aidb, RefreshGF)
        enableCheck:SetPoint("TOPLEFT", PAD, y)
        enableCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local presetCheck = GUI:CreateFormCheckbox(tabContent, "Use Built-in Spec Presets", "usePresets", aidb, RefreshGF)
        presetCheck:SetPoint("TOPLEFT", PAD, y)
        presetCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Load preset button
        local presetDesc = GUI:CreateLabel(tabContent, "Load a preset indicator configuration for your current specialization:", 11, C.textMuted)
        presetDesc:SetPoint("TOPLEFT", PAD, y)
        presetDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        presetDesc:SetJustifyH("LEFT")
        y = y - 22

        local loadPresetBtn = GUI:CreateButton(tabContent, "Load Spec Preset", 160, 28, function()
            local specID = GetSpecializationInfo(GetSpecialization() or 1)
            if specID then
                local GFI = ns.QUI_GroupFrameIndicators
                if GFI then
                    local ok = GFI:LoadPresetForSpec(specID)
                    if ok then
                        print("|cFF34D399[QUI]|r Loaded indicator preset for current spec.")
                    else
                        print("|cFF34D399[QUI]|r No preset available for current spec.")
                    end
                end
            end
        end)
        loadPresetBtn:SetPoint("TOPLEFT", PAD, y)
        y = y - 36

        -- Indicator types info
        local typesHeader = GUI:CreateSectionHeader(tabContent, "Indicator Types")
        typesHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - typesHeader.gap

        local typesDesc = GUI:CreateLabel(tabContent,
            "Available types: Icon (spell texture + cooldown), Colored Square, Progress Bar, Border Color, Health Bar Color.\n" ..
            "Each indicator can be positioned at any of 9 anchor points (TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, RIGHT, BOTTOMLEFT, BOTTOM, BOTTOMRIGHT).",
            11, C.textMuted)
        typesDesc:SetPoint("TOPLEFT", PAD, y)
        typesDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        typesDesc:SetJustifyH("LEFT")
        y = y - 60

        -- Import/Export section
        local ioHeader = GUI:CreateSectionHeader(tabContent, "Import / Export")
        ioHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - ioHeader.gap

        -- Export button
        local exportBtn = GUI:CreateButton(tabContent, "Export Config", 130, 28, function()
            local specID = GetSpecializationInfo(GetSpecialization() or 1)
            local GFI = ns.QUI_GroupFrameIndicators
            if GFI and specID then
                local encoded = GFI:ExportIndicatorConfig(specID)
                if encoded then
                    -- Show in an edit box for copy
                    local popup = GUI:ShowConfirmation({
                        title = "Indicator Config Export",
                        message = "Copy the string below (Ctrl+C):\n\n" .. encoded:sub(1, 100) .. "...",
                        acceptText = "OK",
                        cancelText = nil,
                    })
                else
                    print("|cFF34D399[QUI]|r No indicator config to export for current spec.")
                end
            end
        end)
        exportBtn:SetPoint("TOPLEFT", PAD, y)
        y = y - 36

        -- Healer spec presets info
        local presetsHeader = GUI:CreateSectionHeader(tabContent, "Available Presets")
        presetsHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - presetsHeader.gap

        local presetInfo = {
            "Restoration Druid: Lifebloom, Rejuvenation, Regrowth, Wild Growth, Ironbark",
            "Restoration Shaman: Riptide, Earth Shield, Spirit Link",
            "Discipline Priest: Atonement, PW: Shield, Pain Suppression, Power Infusion",
            "Holy Priest: Renew, Prayer of Mending, Guardian Spirit",
            "Holy Paladin: Beacon of Light, Glimmer, Blessing of Sacrifice",
            "Preservation Evoker: Echo, Reversion, Time Dilation, Lifebind",
            "Mistweaver Monk: Renewing Mist, Enveloping Mist, Essence Font, Life Cocoon",
        }

        for _, text in ipairs(presetInfo) do
            local label = GUI:CreateLabel(tabContent, "• " .. text, 11, C.textMuted)
            label:SetPoint("TOPLEFT", PAD + 4, y)
            label:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
            label:SetJustifyH("LEFT")
            y = y - 18
        end

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildClickCastTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 9, subTabName = "Click-Casting"})

        local cc = gfdb.clickCast
        if not cc then gfdb.clickCast = {} cc = gfdb.clickCast end

        -- Enable
        local enableCheck = GUI:CreateFormCheckbox(tabContent, "Enable Click-Casting", "enabled", cc, function()
            RefreshGF()
            if cc.enabled then
                print("|cFF34D399[QUI]|r Click-casting enabled. Reload recommended.")
            end
        end)
        enableCheck:SetPoint("TOPLEFT", PAD, y)
        enableCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local cliqueNote = GUI:CreateLabel(tabContent, "Note: If Clique addon is loaded, QUI click-casting is disabled by default to avoid conflicts.", 11, C.textMuted)
        cliqueNote:SetPoint("TOPLEFT", PAD, y)
        cliqueNote:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        cliqueNote:SetJustifyH("LEFT")
        y = y - 30

        -- Per-spec toggle
        local perSpecCheck = GUI:CreateFormCheckbox(tabContent, "Per-Spec Bindings", "perSpec", cc, RefreshGF)
        perSpecCheck:SetPoint("TOPLEFT", PAD, y)
        perSpecCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Smart res
        local smartResCheck = GUI:CreateFormCheckbox(tabContent, "Smart Resurrection (auto-swap to res on dead targets)", "smartRes", cc, RefreshGF)
        smartResCheck:SetPoint("TOPLEFT", PAD, y)
        smartResCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Show tooltip
        local tooltipCheck = GUI:CreateFormCheckbox(tabContent, "Show Binding Tooltip on Hover", "showTooltip", cc, RefreshGF)
        tooltipCheck:SetPoint("TOPLEFT", PAD, y)
        tooltipCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Bindings info
        local bindingsHeader = GUI:CreateSectionHeader(tabContent, "Binding Configuration")
        bindingsHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - bindingsHeader.gap

        local bindDesc = GUI:CreateLabel(tabContent,
            "Click-cast bindings are configured via the clickCast.bindings table in your profile.\n" ..
            "Each binding specifies: button (LeftButton, RightButton, MiddleButton, Button4, Button5), " ..
            "modifiers (shift, ctrl, alt, or combinations), and spell name.\n\n" ..
            "Example: { button = \"LeftButton\", modifiers = \"shift\", spell = \"Flash Heal\" }",
            11, C.textMuted)
        bindDesc:SetPoint("TOPLEFT", PAD, y)
        bindDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        bindDesc:SetJustifyH("LEFT")
        y = y - 80

        tabContent:SetHeight(math.abs(y) + 30)
    end

    local function BuildRangeTab(tabContent)
        local y = -10
        local gfdb = GetGFDB()
        if not gfdb then return end

        GUI:SetSearchContext({tabIndex = 5, tabName = "Group Frames", subTabIndex = 10, subTabName = "Range & Misc"})

        -- Range check
        local rangeHeader = GUI:CreateSectionHeader(tabContent, "Range Check")
        rangeHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - rangeHeader.gap

        local range = gfdb.range
        if not range then gfdb.range = {} range = gfdb.range end

        local rangeCheck = GUI:CreateFormCheckbox(tabContent, "Enable Range Check (dim out-of-range members)", "enabled", range, RefreshGF)
        rangeCheck:SetPoint("TOPLEFT", PAD, y)
        rangeCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local rangeAlpha = GUI:CreateFormSlider(tabContent, "Out-of-Range Alpha", 0.1, 0.8, 0.05, "outOfRangeAlpha", range, RefreshGF)
        rangeAlpha:SetPoint("TOPLEFT", PAD, y)
        rangeAlpha:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Portrait
        local portraitHeader = GUI:CreateSectionHeader(tabContent, "Portrait")
        portraitHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - portraitHeader.gap

        local portrait = gfdb.portrait
        if not portrait then gfdb.portrait = {} portrait = gfdb.portrait end

        local portraitCheck = GUI:CreateFormCheckbox(tabContent, "Show Portrait", "showPortrait", portrait, RefreshGF)
        portraitCheck:SetPoint("TOPLEFT", PAD, y)
        portraitCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local portraitSide = GUI:CreateDropdown(tabContent, "Portrait Side", ANCHOR_SIDE_OPTIONS, "portraitSide", portrait, RefreshGF)
        portraitSide:SetPoint("TOPLEFT", PAD, y)
        portraitSide:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local portraitSize = GUI:CreateFormSlider(tabContent, "Portrait Size", 16, 60, 1, "portraitSize", portrait, RefreshGF)
        portraitSize:SetPoint("TOPLEFT", PAD, y)
        portraitSize:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        -- Pet frames
        local petHeader = GUI:CreateSectionHeader(tabContent, "Pet Frames")
        petHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - petHeader.gap

        local pets = gfdb.pets
        if not pets then gfdb.pets = {} pets = gfdb.pets end

        local petCheck = GUI:CreateFormCheckbox(tabContent, "Enable Pet Frames", "enabled", pets, RefreshGF)
        petCheck:SetPoint("TOPLEFT", PAD, y)
        petCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local petW = GUI:CreateFormSlider(tabContent, "Pet Frame Width", 40, 200, 1, "width", pets, RefreshGF)
        petW:SetPoint("TOPLEFT", PAD, y)
        petW:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local petH = GUI:CreateFormSlider(tabContent, "Pet Frame Height", 10, 40, 1, "height", pets, RefreshGF)
        petH:SetPoint("TOPLEFT", PAD, y)
        petH:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        local petAnchor = GUI:CreateDropdown(tabContent, "Pet Anchor", PET_ANCHOR_OPTIONS, "anchorTo", pets, RefreshGF)
        petAnchor:SetPoint("TOPLEFT", PAD, y)
        petAnchor:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        -- Spotlight
        local spotHeader = GUI:CreateSectionHeader(tabContent, "Spotlight")
        spotHeader:SetPoint("TOPLEFT", PAD, y)
        y = y - spotHeader.gap

        local spotDesc = GUI:CreateLabel(tabContent, "Pin specific raid members (by role or name) to a separate highlighted group for tank-watch or healing assignment awareness.", 11, C.textMuted)
        spotDesc:SetPoint("TOPLEFT", PAD, y)
        spotDesc:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        spotDesc:SetJustifyH("LEFT")
        y = y - 30

        local spot = gfdb.spotlight
        if not spot then gfdb.spotlight = {} spot = gfdb.spotlight end

        local spotCheck = GUI:CreateFormCheckbox(tabContent, "Enable Spotlight", "enabled", spot, RefreshGF)
        spotCheck:SetPoint("TOPLEFT", PAD, y)
        spotCheck:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local spotGrow = GUI:CreateDropdown(tabContent, "Spotlight Grow Direction", GROW_OPTIONS, "growDirection", spot, RefreshGF)
        spotGrow:SetPoint("TOPLEFT", PAD, y)
        spotGrow:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - FORM_ROW

        local spotSpacing = GUI:CreateFormSlider(tabContent, "Spotlight Spacing", 0, 10, 1, "spacing", spot, RefreshGF)
        spotSpacing:SetPoint("TOPLEFT", PAD, y)
        spotSpacing:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        y = y - SLIDER_HEIGHT

        tabContent:SetHeight(math.abs(y) + 30)
    end

    -- Create sub-tabs
    local subTabs = {
        {name = "General", builder = BuildGeneralTab},
        {name = "Layout", builder = BuildLayoutTab},
        {name = "Dimensions", builder = BuildDimensionsTab},
        {name = "Health & Power", builder = BuildHealthPowerTab},
        {name = "Indicators", builder = BuildIndicatorsTab},
        {name = "Healer", builder = BuildHealerFeaturesTab},
        {name = "Auras", builder = BuildAurasTab},
        {name = "Aura Indicators", builder = BuildAuraIndicatorsTab},
        {name = "Click-Cast", builder = BuildClickCastTab},
        {name = "Range & Misc", builder = BuildRangeTab},
    }

    GUI:CreateSubTabs(content, subTabs)

    content:SetHeight(600)
end

---------------------------------------------------------------------------
-- EXPORT TO NAMESPACE
---------------------------------------------------------------------------
ns.QUI_GroupFramesOptions = {
    CreateGroupFramesPage = CreateGroupFramesPage
}
