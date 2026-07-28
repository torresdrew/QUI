--[[
    QUI Options V2 — Nameplates tile surface.
    Shared surface wrapper for the schema-owned Nameplates settings page: a
    live mock-plate preview band pinned ABOVE the inner tab strip (always
    visible on every tab), then the tab strip over a scroll-wrapped content
    host. No context dropdown — plates have a single configuration context.
]]

local ADDON_NAME, ns = ...

local Settings = ns.Settings
local FullSurface = Settings and Settings.FullSurface
local ClearFrame = FullSurface and FullSurface.ClearFrame

local function ResolveModel(feature)
    local model = feature and feature.model or nil
    if type(model) == "function" then
        model = model()
    end
    if type(model) == "table" then
        return model
    end
    return ns.QUI_NameplatesSettingsModel
end

---------------------------------------------------------------------------
-- Shared state — read/written by the tab strip callbacks on the tile body.
---------------------------------------------------------------------------
local State = {
    activeTab = "display",
    activeBody = nil,
    repaintTabs = nil,
}

local TabModel
local EnsureTabModel

local function SetActiveTab(tabKey)
    if type(tabKey) ~= "string" or tabKey == "" then
        return false
    end

    local tabModel = EnsureTabModel()
    if not tabModel or type(tabModel.SetActiveKey) ~= "function" then
        return false
    end

    if type(tabModel.GetTabs) == "function" then
        local found = false
        for _, tab in ipairs(tabModel:GetTabs() or {}) do
            if type(tab) == "table" and tab.key == tabKey then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end

    local activeKey = type(tabModel.GetActiveKey) == "function" and tabModel:GetActiveKey() or nil
    if activeKey == tabKey then
        return true
    end

    tabModel:SetActiveKey(tabKey)
    if State.repaintTabs then
        State.repaintTabs()
    end
    return true
end

local function NavigateSearchEntry(entry)
    if type(entry) ~= "table" then
        return false
    end
    return SetActiveTab(entry.surfaceTabKey)
end

local function GetSearchRoot()
    return State.activeBody
end

EnsureTabModel = function(feature)
    if TabModel then
        return TabModel
    end

    local model = ResolveModel(feature)
    local getTabDefinitions = model and model.GetTabDefinitions
    local tabDefinitions = type(getTabDefinitions) == "function" and getTabDefinitions() or {}

    TabModel = FullSurface and FullSurface.CreateTabModel
        and FullSurface.CreateTabModel(State, {
            stateKey = "activeTab",
            defaultKey = "display",
            tabs = tabDefinitions,
        })

    return TabModel
end

---------------------------------------------------------------------------
-- TAB STRIP — style matches cooldown_manager.lua (11pt labels, 2px accent
-- underline on the active tab).
---------------------------------------------------------------------------
local function BuildTabStrip(parent)
    return FullSurface.CreateTabStrip(parent)
end

---------------------------------------------------------------------------
-- PREVIEW BAND — a fixed-height strip above the tab strip hosting the mock
-- plate (nameplates_preview_driver.lua). Built after ClearFrame wipes the
-- body, so it is recreated on every page render; the driver rebinds.
---------------------------------------------------------------------------
local PREVIEW_BAND_HEIGHT = 170

local function BuildPreviewBand(body)
    if not ns.QUI_BuildNameplatePreview then
        return 0
    end

    local band = CreateFrame("Frame", nil, body)
    band:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -4)
    band:SetPoint("TOPRIGHT", body, "TOPRIGHT", -8, -4)
    band:SetHeight(PREVIEW_BAND_HEIGHT)

    local UIKit = ns.UIKit
    if UIKit then
        if UIKit.CreateBackground then
            UIKit.CreateBackground(band, 0, 0, 0, 0.25)
        end
        if UIKit.CreateBorderLines and UIKit.UpdateBorderLines then
            UIKit.CreateBorderLines(band)
            UIKit.UpdateBorderLines(band, 1, 1, 1, 1, 0.08, false)
        end
    end

    local gui = QUI and QUI.GUI
    if gui and gui.CreateLabel then
        local title = gui:CreateLabel(band, ns.L["Preview"], 11)
        title:SetPoint("TOPLEFT", band, "TOPLEFT", 8, -6)
        if title.SetTextColor then
            title:SetTextColor(1, 1, 1, 0.45)
        end
    end

    ns.QUI_BuildNameplatePreview(band)
    return PREVIEW_BAND_HEIGHT + 8
end

---------------------------------------------------------------------------
-- TILE BODY — preview band + inner tab strip + scroll-wrapped content host.
---------------------------------------------------------------------------
local function BuildTileBody(body, _, _, feature)
    local tabModel = EnsureTabModel(feature)
    return FullSurface.BuildScrollTabBody(body, {
        cacheTabBodies = true,
        state = State,
        clearFrame = ClearFrame,
        createTabStrip = BuildTabStrip,
        initialize = function()
            State.activeTab = State.activeTab or "display"
            -- Runs right after ClearFrame wiped the body: rebuild the
            -- preview band; the tab strip starts below it (tabTopOffset).
            BuildPreviewBand(body)
        end,
        tabTopOffset = -(4 + (ns.QUI_BuildNameplatePreview and (PREVIEW_BAND_HEIGHT + 8) or 0)),
        getTabs = function()
            return tabModel:GetTabs()
        end,
        getActiveTab = function()
            return tabModel:GetActiveKey()
        end,
        setActiveTab = function(tabKey)
            tabModel:SetActiveKey(tabKey)
        end,
        render = function(host, activeTab)
            return tabModel:RenderKey(host, activeTab)
        end,
    })
end

ns.QUI_NameplatesSettingsSurface = {
    SetActiveTab = SetActiveTab,
    NavigateSearchEntry = NavigateSearchEntry,
    GetSearchRoot = GetSearchRoot,
    RenderPage = BuildTileBody,
}
