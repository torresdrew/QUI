local ADDON_NAME, ns = ...

local Settings = ns.Settings
local Registry = Settings and Settings.Registry
local Schema = Settings and Settings.Schema
if not Registry or type(Registry.RegisterFeature) ~= "function"
    or not Schema or type(Schema.Feature) ~= "function"
    or type(Schema.Section) ~= "function" then
    return
end

local function RenderBuilder(host, ownerName, fnName)
    local owner = ns[ownerName]
    local render = owner and owner[fnName]
    if type(render) ~= "function" then
        return nil
    end
    local result = render(host)
    if type(result) == "number" then
        return result
    end
    return host and host.GetHeight and host:GetHeight() or nil
end

local function RenderLayoutRoute(host, options, fallbackKey)
    local U = ns.QUI_LayoutMode_Utils
    if not host or not U or type(U.BuildPositionCollapsible) ~= "function"
        or type(U.BuildOpenFullSettingsLink) ~= "function"
        or type(U.StandardRelayout) ~= "function" then
        return 80
    end

    local routeKey = options and options.providerKey or fallbackKey
    if type(routeKey) ~= "string" or routeKey == "" then
        routeKey = fallbackKey
    end
    if type(routeKey) ~= "string" or routeKey == "" then
        return 80
    end

    local sections = {}
    local function relayout()
        U.StandardRelayout(host, sections)
    end

    U.BuildPositionCollapsible(host, routeKey, nil, sections, relayout)
    U.BuildOpenFullSettingsLink(host, routeKey, sections, relayout)
    relayout()
    return host:GetHeight()
end

Registry:RegisterFeature(Schema.Feature({
    id = "actionBarsGeneral",
    moverKey = "bar1",
    lookupKeys = { "extraActionButton", "zoneAbility", "totemBar", "raidMarkersBar" },
    category = "frames",
    nav = {
        tileId = "action_bars",
        subPageIndex = 1,
    },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = function(host)
                return RenderBuilder(host, "QUI_ActionBarsOptions", "BuildMasterSettingsTab")
            end,
        }),
    },
    render = {
        layout = function(host, options)
            return RenderLayoutRoute(host, options, "extraActionButton")
        end,
    },
}))

-- The Buff/Debuff OPTIONS sub-page was removed from the action_bars tile
-- (moved to the Auras hub, tabIndex 21 subTabIndex 4 -- see tiles/auras.lua
-- and core/settings/content/auras_actionbar_page.lua, which calls
-- BuildBuffDebuffTab directly). This Schema.Feature registration stays,
-- though: Layout Mode's buffFrame/debuffFrame mover drawers resolve their
-- inline position panel AND "Open full settings" link through
-- moverKey/lookupKeys (Nav:GetLookupTarget -> layoutmode_settings.lua
-- BuildContent / layoutmode_utils.lua BuildOpenFullSettingsLink), which is
-- independent of the removed tile subPage. `nav` below is repointed at the
-- hub so that link (and the Cooldown Manager tile's "Buff/Debuff" related-
-- setting, tiles/cooldown_manager.lua) lands in the right place instead of
-- a subPageIndex that no longer exists.
Registry:RegisterFeature(Schema.Feature({
    id = "actionBarsBuffDebuff",
    moverKey = "buffDebuff",
    lookupKeys = { "buffFrame", "debuffFrame" },
    category = "frames",
    nav = {
        tileId = "auras",
        subPageIndex = 4,
    },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = function(host)
                return RenderBuilder(host, "QUI_BuffDebuffOptions", "BuildBuffDebuffTab")
            end,
        }),
    },
    render = {
        layout = function(host, options)
            return RenderLayoutRoute(host, options, "buffFrame")
        end,
    },
}))
