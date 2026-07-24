--[[
    QUI Options V2 — Auras hub, Unit Frames sub-page.

    Thin mount: the aura editor itself already exists as a self-contained
    render function (QUI_UnitFramesSettingsSchema.RenderIconsTab, the exact
    tab body the Unit Frames tile's own "Icons" inner tab renders). This
    file adds a standalone unit selector above it and, because sub-page
    tiles don't wire a per-feature preview through RegisterFeatureTile (see
    below), builds the Unit Frames surface's in-page mock preview block
    inline so the Auras hub gets the same live mock the real Unit Frames
    tile shows.
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

local function BuildAurasUnitContent(host, ctx, section)
    local FullSurface = Settings and Settings.FullSurface
    local UF = ns.QUI_UnitFramesSettingsSchema
    local UFModel = ns.QUI_UnitFramesSettingsModel
    local UFSurface = ns.QUI_UnitFramesSettingsSurface

    -- State.selectedUnit in unit_frames_surface.lua is a MODULE-LEVEL
    -- singleton also displayed/mutated by the real Unit Frames settings
    -- tile -- it is the single source of truth for this selector. Read it
    -- rather than keeping an independently-defaulted page-local copy, or
    -- cold entry here (defaulting to "player") would stomp whatever unit
    -- the UF tile was last left on and desync the mock from the editor.
    local unitKey = (UFSurface and type(UFSurface.GetSelectedUnit) == "function" and UFSurface.GetSelectedUnit())
        or (UFModel and type(UFModel.NormalizeUnitKey) == "function" and UFModel.NormalizeUnitKey(nil))
        or "player"

    -- Unit selector at the top; re-render this section on change (mirrors
    -- auras_group_page.lua's Party/Raid selector pattern).
    local y = 0
    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local options = (UFModel and type(UFModel.GetUnitOptions) == "function" and UFModel.GetUnitOptions()) or {}
        local built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            label = ns.L["Unit"],
            stateKey = "_selectedUnit",
            selectedValue = unitKey,
            options = options,
            meta = { description = ns.L["Select which unit frame's aura icons to configure."] },
            height = 30,
            onChanged = function(value)
                -- Write-through to the shared surface ONLY on actual user
                -- change (SetSelectedUnit itself normalizes/no-ops as needed).
                if UFSurface and type(UFSurface.SetSelectedUnit) == "function" then
                    UFSurface.SetSelectedUnit(value)
                end
                if ctx and type(ctx.RerenderSection) == "function" then
                    ctx:RerenderSection(section.id)
                end
            end,
        })
        local rowHeight = (built and built.row and built.row.GetHeight and built.row:GetHeight()) or 30
        y = rowHeight + 8
    end

    -- Live mock preview, docked below the selector. ns.QUI_UnitFramesSettingsSurface.preview
    -- is an IN-PAGE MOCK block (dropdown + scaled unit-frame mock built via
    -- FullSurface.BuildDropdownPreviewBlock), NOT a detached panel like Group
    -- Frames' ShowPreviewOn. RegisterFeatureTile only reads feature.preview
    -- for tiles registered with a single top-level featureId (shared.lua:
    -- `local feature = hasSingle and GetRegisteredFeature(spec.featureId)`);
    -- since the "auras" tile is registered with subPages, that path never
    -- fires, so a `preview = {...}` block on this Schema.Feature would be
    -- silently inert. Build the host inline and call Surface.preview.build
    -- directly instead -- exactly what the real Unit Frames tile does at
    -- the framework level (framework.lua:6356).
    if UFSurface and UFSurface.preview and type(UFSurface.preview.build) == "function" then
        local previewHeight = UFSurface.preview.height or 220
        local previewHost = CreateFrame("Frame", nil, host)
        previewHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
        previewHost:SetPoint("RIGHT", host, "RIGHT", 0, 0)
        previewHost:SetHeight(previewHeight)
        -- showDropdown = false: this page already renders its own unit
        -- selector above (BuildContextDropdownRow, wired to the same
        -- SetSelectedUnit/RerenderSection loop) -- showing the preview
        -- block's embedded dropdown too would duplicate the selector and,
        -- because that embedded dropdown drives selection without updating
        -- this page's own dropdown/editor, desync the two into a
        -- misleading state. Suppress it here; the real Unit Frames tile's
        -- preview call (framework.lua:6361, 1-arg) is unaffected and keeps
        -- its dropdown.
        UFSurface.preview.build(previewHost, { showDropdown = false })
        y = y + previewHeight + 10
    end

    -- Editor host below the selector/preview; mount the existing
    -- self-contained tab.
    local editorHost = CreateFrame("Frame", nil, host)
    editorHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    editorHost:SetPoint("RIGHT", host, "RIGHT", 0, 0)
    editorHost:SetHeight(1)
    if UF and type(UF.RenderIconsTab) == "function" then
        -- RenderIconsTab returns a boolean (success flag), not a height --
        -- it routes through Schema:RenderFeature -> LayoutSections, which
        -- calls editorHost:SetHeight(...) internally. Read the height back
        -- off the frame rather than the return value.
        UF.RenderIconsTab(editorHost, unitKey)
    end

    local total = y + ((editorHost.GetHeight and editorHost:GetHeight()) or 1)
    host:SetHeight(total)

    -- UF.RenderIconsTab (above) sets the search context to its OLD surface
    -- route (Unit Frames tile, "icons" tab -- see CreateUnitSearchContext in
    -- unit_frames_schema.lua) as it builds each inner section. Re-assert
    -- the hub route LAST so subsequently-tagged widgets and the tab/subtab
    -- nav entry point back here, not at the removed surface tab.
    if GUI and type(GUI.SetSearchContext) == "function" then
        GUI:SetSearchContext({
            tabIndex = 21,
            tabName = ns.L["Auras"],
            subTabIndex = 3,
            subTabName = ns.L["Unit Frames"],
            tileId = "auras",
            subPageIndex = 3,
            featureId = "aurasUnitPage",
        })
    end

    return total
end

Registry:RegisterFeature(Schema.Feature({
    id = "aurasUnitPage",
    category = "frames",
    nav = { tileId = "auras", subPageIndex = 3 },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = BuildAurasUnitContent,
        }),
    },
}))
