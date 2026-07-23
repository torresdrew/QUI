--[[
    QUI Options V2 — Auras hub, Dispel Colors sub-page.

    Thin mount: the dispel-overlay settings card already exists as a
    self-contained render function (QUI_GroupFramesSettingsSchema.
    RenderDispelTab, a standalone one-section tab wrapping the same
    RenderDispelOverlaySection the Group Frames tile's Appearance tab folds
    in). This file adds a standalone Party/Raid selector above it (mirrors
    auras_group_page.lua) and a role-aware hint block below, showing which
    of the five dispel schools the player's own class/spec can cleanse.
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

-- The four dispellable schools the settings card exposes color pickers for.
-- Bleed is shown separately below -- it is never dispellable, only colored
-- for awareness (see group_frames_schema.lua RenderDispelOverlaySection).
local HINT_SCHOOLS = {
    { key = "Magic", label = "Magic" },
    { key = "Curse", label = "Curse" },
    { key = "Disease", label = "Disease" },
    { key = "Poison", label = "Poison" },
}

-- Builds the role-aware hint list into `host`, stacked top-down starting at
-- `y`. Informational only -- NOT a filter; the color-picker settings above
-- still cover all 5 schools regardless of what the player can personally
-- dispel (other raid members may cleanse what this player cannot).
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

local function BuildAurasDispelContent(host, ctx, section)
    local FullSurface = Settings and Settings.FullSurface
    local GF = ns.QUI_GroupFramesSettingsSchema
    local GFModel = ns.QUI_GroupFramesSettingsModel
    local GFSurface = ns.QUI_GroupFramesSettingsSurface

    -- State.contextMode in group_frames_surface.lua is a MODULE-LEVEL
    -- singleton also displayed/mutated by the real Group Frames settings
    -- tile and the Auras hub's Group Frames sub-page -- it is the single
    -- source of truth for this selector. Read it rather than keeping an
    -- independently-defaulted page-local copy, or cold entry here
    -- (defaulting to "party") would stomp whatever bucket was last left on.
    local contextMode = (GFSurface and type(GFSurface.GetContextMode) == "function" and GFSurface.GetContextMode()) or "party"

    -- Party | Raid selector at the top; re-render this section on change.
    local y = 0
    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local options = (GFModel and type(GFModel.GetContextOptions) == "function" and GFModel.GetContextOptions())
            or {
                { value = "party", text = ns.L["Party"] },
                { value = "raid", text = ns.L["Raid"] },
            }
        local built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            label = ns.L["Unit Group"],
            stateKey = "_contextMode",
            selectedValue = contextMode,
            options = options,
            meta = { description = ns.L["Switch between Party and Raid group-frame dispel-color settings."] },
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
    if GF and type(GF.RenderDispelTab) == "function" then
        GF.RenderDispelTab(editorHost, contextMode)
    end
    local editorHeight = (editorHost.GetHeight and editorHost:GetHeight()) or 1
    y = y + (tonumber(editorHeight) or 1) + 16

    -- Role-aware hint block below the card.
    local hintHost = CreateFrame("Frame", nil, host)
    hintHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    hintHost:SetPoint("RIGHT", host, "RIGHT", 0, 0)
    hintHost:SetHeight(1)
    local hintHeight = BuildDispelHintBlock(hintHost, 0)
    hintHost:SetHeight(hintHeight)
    y = y + hintHeight

    local total = y
    host:SetHeight(total)

    -- GF.RenderDispelTab (above) sets the search context to its OLD surface
    -- route (Group Frames tile, "appearance" tab -- see CreateSearchContext
    -- in group_frames_schema.lua) as it builds the card. Re-assert the hub
    -- route LAST so subsequently-tagged widgets and the tab/subtab nav entry
    -- point back here, not at the removed surface tab.
    if GUI and type(GUI.SetSearchContext) == "function" then
        GUI:SetSearchContext({
            tabIndex = 21,
            tabName = ns.L["Auras"],
            subTabIndex = 5,
            subTabName = ns.L["Dispel Colors"],
            tileId = "auras",
            subPageIndex = 5,
            featureId = "aurasDispelPage",
        })
    end

    return total
end

Registry:RegisterFeature(Schema.Feature({
    id = "aurasDispelPage",
    category = "frames",
    nav = { tileId = "auras", subPageIndex = 5 },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = BuildAurasDispelContent,
        }),
    },
}))
