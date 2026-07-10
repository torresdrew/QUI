local ADDON_NAME, ns = ...

local Model = ns.QUI_NameplatesSettingsModel or {}
ns.QUI_NameplatesSettingsModel = Model
local ModelKit = ns.Settings and ns.Settings.ModelKit

local function RenderSchema(methodName, host, label)
    return ModelKit.RenderSchema(ns.QUI_NameplatesSettingsSchema, methodName, host, nil, label, ns.L[" settings unavailable (module not loaded)."])
end

local function BuildSchemaRender(methodName, label)
    return function(host)
        RenderSchema(methodName, host, label)
    end
end

local RenderDisplay = BuildSchemaRender("RenderDisplayTab", ns.L["Display"])
local RenderAuras = BuildSchemaRender("RenderAurasTab", ns.L["Auras"])
local RenderCastbars = BuildSchemaRender("RenderCastbarsTab", ns.L["Castbars"])
local RenderColors = BuildSchemaRender("RenderColorsTab", ns.L["Colors"])
local RenderBehavior = BuildSchemaRender("RenderBehaviorTab", ns.L["Behavior"])

-- Order only; no context options (nameplates have no party/raid-style split).
local TAB_DEFINITIONS = {
    { key = "display", label = ns.L["Display"], render = RenderDisplay },
    { key = "auras", label = ns.L["Auras"], render = RenderAuras },
    { key = "castbars", label = ns.L["Castbars"], render = RenderCastbars },
    { key = "colors", label = ns.L["Colors"], render = RenderColors },
    { key = "behavior", label = ns.L["Behavior"], render = RenderBehavior },
}

function Model.GetTabDefinitions()
    return ModelKit.NormalizeTabDefinitions(TAB_DEFINITIONS)
end
