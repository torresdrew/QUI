--[[
    QUI Options V2 — Action Bars tile
]]

local ADDON_NAME, ns = ...

local V2 = {}
ns.QUI_ActionBarsTile = V2

function V2.Register(frame)
    local Opts = ns.QUI_Options
    if not Opts or type(Opts.RegisterFeatureTile) ~= "function" then
        return
    end

    Opts.RegisterFeatureTile(frame, {
        id = "action_bars",
        icon = "A",
        name = ns.L["Action Bars"],
        primaryCTA = { label = ns.L["Edit in Layout Mode"], moverKey = "bar1" },
        preview = {
            height = 110,
            build = function(pv)
                if ns.QUI_ActionBarsOptions and ns.QUI_ActionBarsOptions.BuildActionBarsPreview then
                    ns.QUI_ActionBarsOptions.BuildActionBarsPreview(pv)
                end
            end,
        },
        -- Buff/Debuff sub-page removed (moved to the Auras hub tile, tabIndex
        -- 21 subTabIndex 4 = Buff/Debuff Frames -- see tiles/auras.lua). The
        -- actionBarsBuffDebuff feature registration (action_bars.lua) stays
        -- alive: Layout Mode's buffFrame/debuffFrame mover drawers still
        -- resolve through it via moverKey/lookupKeys, now repointed at the
        -- hub. "Per-Bar" shifted from array position 3 to 2 -- its own nav
        -- (action_bars_per_bar.lua) was updated to match.
        subPages = {
            {
                id = "general",
                name = ns.L["General"],
                featureId = "actionBarsGeneral",
                navRoutes = { { tabIndex = 8, subTabIndex = 0 } },
                searchContext = {
                    tabIndex = 8,
                    tabName = ns.L["Action Bars"],
                    subTabIndex = 0,
                    subTabName = ns.L["General"],
                },
            },
            {
                id = "perBar",
                name = ns.L["Per-Bar"],
                featureId = "actionBarsPerBar",
                searchContext = {
                    tabIndex = 8,
                    tabName = ns.L["Action Bars"],
                    subTabIndex = 3,
                    subTabName = ns.L["Per-Bar"],
                },
            },
        },
    })
end
