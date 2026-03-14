--[[
    QUI Options - Buff & Debuff Tab
    BuildBuffDebuffTab for General & QoL page
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local C = GUI.Colors

-- Import shared utilities
local Shared = ns.QUI_Options

local function BuildBuffDebuffTab(tabContent)
    local y = -10
    local FORM_ROW = 32
    local PADDING = Shared.PADDING
    local db = Shared.GetDB()

    -- Buff & Debuff Borders settings moved to Edit Mode settings panel.
    local info = GUI:CreateLabel(tabContent, "Buff & Debuff settings have moved to Edit Mode. Open Edit Mode and click the Buff or Debuff frame.", 12, C.textMuted or {0.5,0.5,0.5,1})
    info:SetPoint("TOPLEFT", PADDING, -10)
    info:SetPoint("RIGHT", tabContent, "RIGHT", -PADDING, 0)
    info:SetJustifyH("LEFT")
    info:SetWordWrap(true)
    tabContent:SetHeight(80)
end

-- Export
ns.QUI_BuffDebuffOptions = {
    BuildBuffDebuffTab = BuildBuffDebuffTab
}
