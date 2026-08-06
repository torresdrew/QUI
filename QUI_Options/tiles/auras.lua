--[[
    QUI Options V2 — Auras hub tile.
    First sub-page is the guided Setup Wizard: detect role, preview + apply
    role-appropriate aura intents across group/player/target
    (aurasWizardPage, core/settings/content/auras_wizard_page.lua).
    Second sub-page mounts the group-frame aura editor (aurasGroupPage,
    core/settings/content/auras_group_page.lua). Third sub-page mounts
    the unit-frame aura editor (aurasUnitPage, core/settings/content/
    auras_unit_page.lua). Fourth sub-page mounts the action-bar buff/debuff
    editor (aurasActionBarPage, core/settings/content/auras_actionbar_page.lua),
    labelled "Buff/Debuff Frames". Dispel-overlay settings + role-aware
    dispel hints render inside the Group Frames sub-page (no standalone
    dispel page). More sub-pages (CDM, ...) land in later tasks.
]]

local ADDON_NAME, ns = ...

ns.QUI_AurasTile = ns.QUI_AurasTile or {}

function ns.QUI_AurasTile.Register(frame)
    local Opts = ns.QUI_Options
    if not Opts or type(Opts.RegisterFeatureTile) ~= "function" then
        return
    end

    Opts.RegisterFeatureTile(frame, {
        id = "auras",
        icon = "*",
        name = ns.L["Auras"],
        subtitle = ns.L["Buffs · debuffs · indicators, all in one place"],
        subPages = {
            {
                id = "aurasWizard",
                name = ns.L["Setup Wizard"],
                featureId = "aurasWizardPage",
                navRoutes = { { tabIndex = 21, subTabIndex = 1 } },
                -- The wizard renders its options as raw labels (not registered
                -- widgets), so its step names and intent labels are not harvested
                -- into the search cache the way form widgets are. Surface the key
                -- terms explicitly so a search for "place hots" / "my hots" /
                -- "boss debuffs" lands on the wizard.
                searchAliases = {
                    ns.L["Setup Wizard"], ns.L["Party auras"], ns.L["Place HoTs"],
                    ns.L["My HoTs"], ns.L["Big defensives on allies"], ns.L["All buffs"],
                    ns.L["Dispellable by me"], ns.L["Boss debuffs"], ns.L["Crowd control"],
                    ns.L["Tank"], ns.L["Healer"], ns.L["DPS"],
                },
                searchContext = {
                    tabIndex = 21,
                    tabName = ns.L["Auras"],
                    subTabIndex = 1,
                    subTabName = ns.L["Setup Wizard"],
                },
            },
            {
                id = "aurasGroup",
                name = ns.L["Group Frames"],
                featureId = "aurasGroupPage",
                navRoutes = { { tabIndex = 21, subTabIndex = 2 } },
                searchContext = {
                    tabIndex = 21,
                    tabName = ns.L["Auras"],
                    subTabIndex = 2,
                    subTabName = ns.L["Group Frames"],
                },
            },
            {
                id = "aurasUnit",
                name = ns.L["Unit Frames"],
                featureId = "aurasUnitPage",
                preview = {
                    height = 140,
                    build = function(previewHost)
                        local surface = ns.QUI_UnitFramesSettingsSurface
                        local preview = surface and surface.preview
                        if preview and type(preview.build) == "function" then
                            preview.build(previewHost, {
                                showDropdown = false,
                                bodyOnly = true,
                                autoHeight = true,
                            })
                        end
                    end,
                },
                navRoutes = { { tabIndex = 21, subTabIndex = 3 } },
                searchContext = {
                    tabIndex = 21,
                    tabName = ns.L["Auras"],
                    subTabIndex = 3,
                    subTabName = ns.L["Unit Frames"],
                },
            },
            {
                id = "aurasActionBar",
                name = ns.L["Buff/Debuff Frames"],
                featureId = "aurasActionBarPage",
                navRoutes = { { tabIndex = 21, subTabIndex = 4 } },
                searchContext = {
                    tabIndex = 21,
                    tabName = ns.L["Auras"],
                    subTabIndex = 4,
                    subTabName = ns.L["Buff/Debuff Frames"],
                },
            },
            {
                id = "aurasNameplate",
                name = ns.L["Nameplates"],
                featureId = "aurasNameplatePage",
                navRoutes = { { tabIndex = 21, subTabIndex = 5 } },
                searchContext = {
                    tabIndex = 21,
                    tabName = ns.L["Auras"],
                    subTabIndex = 5,
                    subTabName = ns.L["Nameplates"],
                },
            },
        },
    })
end
