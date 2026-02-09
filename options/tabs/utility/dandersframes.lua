--[[
    QUI Options - DandersFrames Integration Tab
    Anchoring controls for DandersFrames party/raid/pinned containers
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local C = GUI.Colors
local Shared = ns.QUI_Options

local PADDING = Shared.PADDING
local CreateScrollableContent = Shared.CreateScrollableContent

local function GetCore()
    return (_G.QUI and _G.QUI.QUICore) or ns.Addon
end

-- 9-point anchor options
local ANCHOR_POINTS = {
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

-- Container display info
local CONTAINERS = {
    {key = "party", label = "Party Frames"},
    {key = "raid", label = "Raid Frames"},
    {key = "pinned1", label = "Pinned Set 1"},
    {key = "pinned2", label = "Pinned Set 2"},
}

---------------------------------------------------------------------------
-- BUILD CONTAINER SECTION
---------------------------------------------------------------------------
local function BuildContainerSection(content, containerInfo, y, db, anchorOptions)
    local PAD = PADDING
    local FORM_ROW = 32
    local cfg = db[containerInfo.key]
    if not cfg then return y end

    local function Refresh()
        if ns.QUI_DandersFrames then
            ns.QUI_DandersFrames:ApplyPosition(containerInfo.key)
        end
    end

    -- Section header
    local header = GUI:CreateSectionHeader(content, containerInfo.label)
    header:SetPoint("TOPLEFT", PAD, y)
    y = y - header.gap

    -- Enable toggle
    local enableCheck = GUI:CreateFormCheckbox(content, "Enable Anchoring", "enabled", cfg, Refresh)
    enableCheck:SetPoint("TOPLEFT", PAD, y)
    enableCheck:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    y = y - FORM_ROW

    -- Anchor To dropdown
    local anchorDropdown = GUI:CreateFormDropdown(content, "Anchor To", anchorOptions, "anchorTo", cfg, Refresh)
    anchorDropdown:SetPoint("TOPLEFT", PAD, y)
    anchorDropdown:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    y = y - FORM_ROW

    -- Source Point dropdown (point on the DF container)
    local sourceDropdown = GUI:CreateFormDropdown(content, "Container Point", ANCHOR_POINTS, "sourcePoint", cfg, Refresh)
    sourceDropdown:SetPoint("TOPLEFT", PAD, y)
    sourceDropdown:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    y = y - FORM_ROW

    -- Target Point dropdown (point on the QUI element)
    local targetDropdown = GUI:CreateFormDropdown(content, "Target Point", ANCHOR_POINTS, "targetPoint", cfg, Refresh)
    targetDropdown:SetPoint("TOPLEFT", PAD, y)
    targetDropdown:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    y = y - FORM_ROW

    -- X Offset slider
    local xSlider = GUI:CreateFormSlider(content, "X Offset", -200, 200, 1, "offsetX", cfg, Refresh)
    xSlider:SetPoint("TOPLEFT", PAD, y)
    xSlider:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    y = y - FORM_ROW

    -- Y Offset slider
    local ySlider = GUI:CreateFormSlider(content, "Y Offset", -200, 200, 1, "offsetY", cfg, Refresh)
    ySlider:SetPoint("TOPLEFT", PAD, y)
    ySlider:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    y = y - FORM_ROW

    -- Extra spacing between sections
    y = y - 10

    return y
end

---------------------------------------------------------------------------
-- PAGE BUILDER
---------------------------------------------------------------------------
local function CreateDandersFramesPage(parent)
    local scroll, content = CreateScrollableContent(parent)
    local y = -15
    local PAD = PADDING

    -- Set search context
    GUI:SetSearchContext({tabIndex = 9, tabName = "DandersFrames"})

    -- Check if DandersFrames is available
    local dfAvailable = ns.QUI_DandersFrames and ns.QUI_DandersFrames:IsAvailable()

    if not dfAvailable then
        local info = GUI:CreateLabel(content, "DandersFrames not detected. Install DandersFrames v4.0.0+ to use this feature.", 12, C.textMuted)
        info:SetPoint("TOPLEFT", PAD, y)
        info:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
        info:SetJustifyH("LEFT")
        return scroll
    end

    -- Description
    local info = GUI:CreateLabel(content, "Anchor DandersFrames containers to QUI elements. When enabled, QUI controls the container position instead of DandersFrames.", 11, C.textMuted)
    info:SetPoint("TOPLEFT", PAD, y)
    info:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    info:SetJustifyH("LEFT")
    y = y - 28

    local core = GetCore()
    local db = core and core.db and core.db.profile and core.db.profile.dandersFrames
    if not db then
        local errorLabel = GUI:CreateLabel(content, "Database not loaded. Please reload UI.", 12, {1, 0.3, 0.3, 1})
        errorLabel:SetPoint("TOPLEFT", PAD, y)
        return scroll
    end

    -- Build anchor options list
    local anchorOptions = ns.QUI_DandersFrames:BuildAnchorOptions()

    -- Build a section for each container
    for _, containerInfo in ipairs(CONTAINERS) do
        y = BuildContainerSection(content, containerInfo, y, db, anchorOptions)
    end

    return scroll
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------
ns.QUI_DandersFramesOptions = {
    CreateDandersFramesPage = CreateDandersFramesPage
}
