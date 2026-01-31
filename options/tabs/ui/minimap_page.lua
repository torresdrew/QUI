local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local Shared = ns.QUI_Options

local CreateScrollableContent = Shared.CreateScrollableContent

--------------------------------------------------------------------------------
-- PAGE: Minimap & Datatext (coordinator - subtabs from separate files)
--------------------------------------------------------------------------------
local function CreateMinimapPage(parent)
    local scroll, content = CreateScrollableContent(parent)

    GUI:CreateSubTabs(content, {
        {name = "Minimap", builder = ns.QUI_MinimapOptions.BuildMinimapTab},
        {name = "Datatext", builder = ns.QUI_MinimapOptions.BuildDatatextTab},
    })

    content:SetHeight(700)
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------
ns.QUI_MinimapPageOptions = {
    CreateMinimapPage = CreateMinimapPage,
}
