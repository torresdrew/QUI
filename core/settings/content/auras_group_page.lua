--[[
    QUI Options V2 — Auras hub, Group Frames sub-page.

    Thin mount: the aura editor itself already exists as a self-contained
    render function (QUI_GroupFramesSettingsSchema.RenderAurasTab, the exact
    tab body the Group Frames tile's own "Auras" inner tab renders). This
    file only adds a standalone Party/Raid selector above it and docks the
    same detached live-preview panel the Group Frames tile uses, so the
    Auras hub gets a first-class page without duplicating any editor code.
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

local HINT_SCHOOLS = {
    { key = "Magic", label = "Magic" },
    { key = "Curse", label = "Curse" },
    { key = "Disease", label = "Disease" },
    { key = "Poison", label = "Poison" },
}

local function BuildDispelHintBlock(host, y)
    local C = GUI.Colors or {}

    local header = GUI:CreateLabel(host, ns.L["What You Can Dispel"], 13, C.accent)
    header:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    y = y + 20

    local dispellable = (ns.QUI_DispelRoles and type(ns.QUI_DispelRoles.PlayerDispelSchools) == "function")
        and ns.QUI_DispelRoles.PlayerDispelSchools() or {}

    for _, school in ipairs(HINT_SCHOOLS) do
        local canDispel = dispellable[school.key] == true
        local hintText = canDispel and ns.L["You can dispel this"] or ns.L["Your class can't dispel this"]
        local color = canDispel and C.accent or C.textMuted
        local row = GUI:CreateLabel(host, string.format("%s — %s", ns.L[school.label], hintText), 12, color)
        row:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
        y = y + 18
    end

    local bleedRow = GUI:CreateLabel(
        host,
        string.format("%s — %s", ns.L["Bleed"], ns.L["Show only — can't be dispelled"]),
        12,
        C.textMuted
    )
    bleedRow:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    y = y + 18

    return y
end

local function BuildAurasGroupContent(host, ctx, section)
    local FullSurface = Settings and Settings.FullSurface
    local GF = ns.QUI_GroupFramesSettingsSchema
    local GFModel = ns.QUI_GroupFramesSettingsModel
    local GFSurface = ns.QUI_GroupFramesSettingsSurface

    -- Seed this cached page's first dropdown from the context currently driving
    -- the shared builders/preview. After build, dropdownDB retains this page's
    -- own selection; ShowPreviewOn restores it whenever the Auras page becomes
    -- visible, independently of the main Group Frames tile's retained choice.
    local contextMode = (GFSurface and type(GFSurface.GetContextMode) == "function" and GFSurface.GetContextMode()) or "party"

    -- Party | Raid selector at the top; re-render this section on change.
    local y = 0
    local built
    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local options = (GFModel and type(GFModel.GetContextOptions) == "function" and GFModel.GetContextOptions())
            or {
                { value = "party", text = ns.L["Party"] },
                { value = "raid", text = ns.L["Raid"] },
            }
        built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            label = ns.L["Unit Group"],
            stateKey = "_contextMode",
            selectedValue = contextMode,
            options = options,
            meta = { description = ns.L["Switch between Party and Raid group-frame aura settings."] },
            height = 30,
            onChanged = function(value)
                -- Write-through to the shared surface ONLY on actual user
                -- change (SetContextMode itself no-ops if value is unchanged).
                if GFSurface and type(GFSurface.SetContextMode) == "function" then
                    GFSurface.SetContextMode(value)
                end
                if ctx and type(ctx.RerenderSection) == "function" then
                    ctx:RerenderSection(section.id)
                end
            end,
        })
        local rowHeight = (built and built.row and built.row.GetHeight and built.row:GetHeight()) or 30
        y = rowHeight + 8
    end

    -- Editor host below the selector; mount the existing self-contained tab.
    local editorHost = CreateFrame("Frame", nil, host)
    editorHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    editorHost:SetPoint("RIGHT", host, "RIGHT", 0, 0)
    editorHost:SetHeight(1)
    local SearchRoute = Settings and Settings.SearchRoute
    local HUB_ROUTE = {
        tabIndex = 21,
        tabName = ns.L["Auras"],
        subTabIndex = 2,
        subTabName = ns.L["Group Frames"],
        tileId = "auras",
        subPageIndex = 2,
        featureId = "aurasGroupPage",
    }
    local h = 1
    if GF and type(GF.RenderAurasTab) == "function" then
        if SearchRoute and type(SearchRoute.With) == "function" then
            h = SearchRoute.With(HUB_ROUTE, GF.RenderAurasTab, editorHost, contextMode) or 1
        else
            h = GF.RenderAurasTab(editorHost, contextMode) or 1
        end
    end

    y = y + (tonumber(h) or (editorHost.GetHeight and editorHost:GetHeight()) or 1) + 16

    local dispelHost = CreateFrame("Frame", nil, host)
    dispelHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    dispelHost:SetPoint("RIGHT", host, "RIGHT", 0, 0)
    dispelHost:SetHeight(1)
    local dispelHeight = 1
    if GF and type(GF.RenderDispelTab) == "function" then
        if SearchRoute and type(SearchRoute.With) == "function" then
            dispelHeight = SearchRoute.With(HUB_ROUTE, GF.RenderDispelTab, dispelHost, contextMode) or 1
        else
            dispelHeight = GF.RenderDispelTab(dispelHost, contextMode) or 1
        end
    end
    y = y + (tonumber(dispelHeight) or (dispelHost.GetHeight and dispelHost:GetHeight()) or 1) + 16

    local hintHost = CreateFrame("Frame", nil, host)
    hintHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    hintHost:SetPoint("RIGHT", host, "RIGHT", 0, 0)
    hintHost:SetHeight(1)
    local hintHeight = BuildDispelHintBlock(hintHost, 0)
    hintHost:SetHeight(hintHeight)
    y = y + hintHeight

    -- Reuse the Group Frames preview: bind the detached panel to the
    -- section's WRAPPER frame (ctx.host, created by BuildFeatureTabPage as a
    -- DIRECT child of tabContent) rather than this callback's own `host`
    -- (the section host, a GRANDCHILD of tabContent created by RenderSection
    -- as a child of ctx.host). GUI:TeardownFrameTree(tabContent) only calls
    -- :Hide() on tabContent's direct children, so an OnHide hooked onto the
    -- grandchild section host would never fire on navigate-away, leaving the
    -- detached preview panel stuck open. ctx.host IS that direct child.
    local previewHost = (ctx and ctx.host) or host
    if GFSurface and type(GFSurface.ShowPreviewOn) == "function" then
        GFSurface.ShowPreviewOn(previewHost, function()
            local db = built and built.dropdownDB
            return (db and db._contextMode) or contextMode
        end)
    end

    host:SetHeight(y)

    return y
end

Registry:RegisterFeature(Schema.Feature({
    id = "aurasGroupPage",
    category = "frames",
    nav = { tileId = "auras", subPageIndex = 2 },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = BuildAurasGroupContent,
        }),
    },
}))
