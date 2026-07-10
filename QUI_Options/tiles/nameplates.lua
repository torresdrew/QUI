--[[
    QUI Options V2 — Nameplates tile
    Pattern mirrors tiles/group_frames.lua (minus the layout-mode CTA and
    docked preview — plates aren't movable frames and have no mock preview).

    tabIndex 21 is a fresh static route id: the legacy tab bar never had a
    Nameplates page, so unlike the older tiles there is no historical index
    to preserve. 21 is the next free constant after Bags (19) and Alts (20).
    Must stay in sync with NAMEPLATES_SEARCH_TAB_INDEX in
    QUI_Nameplates/nameplates/settings/nameplates_schema.lua.
]]

local ADDON_NAME, ns = ...

local V2 = {}
ns.QUI_NameplatesTile = V2

local SEARCH_TAB_INDEX = 21

function V2.Register(frame)
    local Opts = ns.QUI_Options
    if not Opts or type(Opts.RegisterFeatureTile) ~= "function" then
        return
    end

    Opts.RegisterFeatureTile(frame, {
        featureId = "nameplatesPage",
        id = "nameplates",
        icon = "N",
        name = ns.L["Nameplates"],
        navRoutes = {
            { tabIndex = SEARCH_TAB_INDEX, subTabIndex = 0, subPageIndex = 1 },
            { tabIndex = SEARCH_TAB_INDEX, subTabIndex = 1, subPageIndex = 1 },
            { tabIndex = SEARCH_TAB_INDEX, subTabIndex = 2, subPageIndex = 1 },
            { tabIndex = SEARCH_TAB_INDEX, subTabIndex = 3, subPageIndex = 1 },
            { tabIndex = SEARCH_TAB_INDEX, subTabIndex = 4, subPageIndex = 1 },
            { tabIndex = SEARCH_TAB_INDEX, subTabIndex = 5, subPageIndex = 1 },
        },
        searchContext = {
            tabIndex = SEARCH_TAB_INDEX,
            tabName = ns.L["Nameplates"],
            subTabIndex = 0,
            subTabName = ns.L["Nameplates"],
        },
        renderOptions = { surface = "full" },
        relatedSettings = {
            { label = ns.L["Unit Frames"],  tileId = "unit_frames" },
            { label = ns.L["Group Frames"], tileId = "group_frames" },
        },
    })
end
