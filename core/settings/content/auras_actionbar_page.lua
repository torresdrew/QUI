--[[
    QUI Options V2 — Auras hub, Buff/Debuff Frames sub-page.

    Simplest of the three surface mounts: no context selector, no preview.
    The buff/debuff editor already exists as a self-contained tab body
    (QUI_BuffDebuffOptions.BuildBuffDebuffTab, the exact tab the Action Bars
    tile's own "Buff/Debuff" inner tab renders) that anchors its rows
    directly to the frame passed in and sets that frame's height itself.
    This file just mounts it as-is.
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local Settings = ns.Settings
local Registry = Settings and Settings.Registry
local Schema = Settings and Settings.Schema
if not Registry or type(Registry.RegisterFeature) ~= "function"
    or not Schema or type(Schema.Feature) ~= "function"
    or type(Schema.Section) ~= "function" then
    return
end

local function BuildAurasActionBarContent(host, ctx, section)
    local AB = ns.QUI_BuffDebuffOptions
    if AB and type(AB.BuildBuffDebuffTab) == "function" then
        AB.BuildBuffDebuffTab(host) -- self-contained; sets host:SetHeight itself
    end

    -- BuildBuffDebuffTab (above) sets the search context to its OLD surface
    -- route (Action Bars tile, "Buff/Debuff" sub-page -- see
    -- action_bars_buffdebuff_content.lua). Re-assert the hub route LAST so
    -- subsequently-tagged widgets and the tab/subtab nav entry point back
    -- here, not at the removed surface sub-page.
    if GUI and type(GUI.SetSearchContext) == "function" then
        GUI:SetSearchContext({
            tabIndex = 21,
            tabName = ns.L["Auras"],
            subTabIndex = 4,
            subTabName = ns.L["Buff/Debuff Frames"],
            tileId = "auras",
            subPageIndex = 4,
            featureId = "aurasActionBarPage",
        })
    end

    return host:GetHeight() or 80
end

Registry:RegisterFeature(Schema.Feature({
    id = "aurasActionBarPage",
    category = "frames",
    nav = { tileId = "auras", subPageIndex = 4 },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = BuildAurasActionBarContent,
        }),
    },
}))
