local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local Shared = ns.QUI_Options

local CreateScrollableContent = Shared.CreateScrollableContent

--------------------------------------------------------------------------------
-- PAGE: Autohide & Skinning (coordinator - subtabs from separate files)
--------------------------------------------------------------------------------
local function CreateAutohidesPage(parent)
    local scroll, content = CreateScrollableContent(parent)

    GUI:CreateSubTabs(content, {
        {name = "Autohide", builder = ns.QUI_AutohideOptions.BuildAutohideTab},
        {name = "Skinning", builder = ns.QUI_SkinningOptions.BuildSkinningTab},
    })

    content:SetHeight(600)
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------
ns.QUI_AutohidesOptions = {
    CreateAutohidesPage = CreateAutohidesPage,
}
