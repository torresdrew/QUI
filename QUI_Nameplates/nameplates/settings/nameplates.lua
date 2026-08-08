local ADDON_NAME, ns = ...

local Settings = ns.Settings
local SurfaceFeatures = Settings and Settings.SurfaceFeatures
if not SurfaceFeatures or type(SurfaceFeatures.Register) ~= "function" then
    return
end

local function GetSurface()
    return ns.QUI_NameplatesSettingsSurface
end

local function GetModel()
    return ns.QUI_NameplatesSettingsModel
end

SurfaceFeatures:Register({
    id = "nameplatesPage",
    category = "frames",
    nav = {
        tileId = "nameplates",
        subPageIndex = 1,
    },
    surface = GetSurface,
    model = GetModel,
    searchNavigate = function(entry, context)
        local surface = GetSurface()
        if surface and type(surface.NavigateSearchEntry) == "function" then
            local handled = surface.NavigateSearchEntry(entry)
            if handled and type(context) == "table"
                and type(context.opts) == "table"
                and type(surface.GetSearchRoot) == "function" then
                context.opts.searchRoot = surface.GetSearchRoot()
            end
            return handled
        end
        return false
    end,
})
