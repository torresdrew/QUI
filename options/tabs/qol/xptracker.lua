--[[
    QUI Options - XP Tracker Tab
    BuildXPTrackerTab for General & QoL page
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local C = GUI.Colors

-- Import shared utilities
local Shared = ns.QUI_Options

local function BuildXPTrackerTab(tabContent)
    -- XP Tracker settings moved to Edit Mode settings panel.
    local PADDING = Shared.PADDING
    local info = GUI:CreateLabel(tabContent, "XP Tracker settings have moved to Edit Mode. Open Edit Mode and click the XP Tracker frame.", 12, C.textMuted or {0.5,0.5,0.5,1})
    info:SetPoint("TOPLEFT", PADDING, -10)
    info:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    info:SetJustifyH("LEFT")
    info:SetWordWrap(true)
    tabContent:SetHeight(80)
end

-- Export
ns.QUI_XPTrackerOptions = {
    BuildXPTrackerTab = BuildXPTrackerTab
}
