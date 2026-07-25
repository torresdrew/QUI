--[[
    QUI Modules - Shared settings-content layout helpers.

    The HUD/crosshair/autohide/visibility settings pages all use the same
    "MakeLayout" body-builder rhythm (accent-dot header + settings card group +
    cursor advance) and the same single-row wrapper. This module hosts one
    parameterized copy so the layout cadence lives in a single place.

    Loaded by the core QUI.toc (before QUI_Options), so ns.QUI_Options is read
    lazily inside the helpers — never captured at file scope.
]]

local _, ns = ...

local SettingsLayout = {}
ns.QUI_ModulesSettingsLayout = SettingsLayout

local HEADER_GAP = 26
local SECTION_GAP = 14

-- Canonical 9-point anchor dropdown options (value + display text), shared by
-- the layout composer and the third-party anchoring settings surface; single
-- retained instance from the core factory.
SettingsLayout.NINE_POINT_OPTIONS = ns.QUI_SettingsLayoutShared.BuildNinePointAnchorOptions()

-- Build a body-layout helper bound to `content`. `startY` defaults to -10.
-- The returned table exposes headerAt/sectionAt/closeSection/placeCustom/finish.
function SettingsLayout.MakeLayout(content, startY)
    -- Delegates to THE builder (core/settings_layout_shared.lua); this
    -- surface has no layout-mode utils (nil U); startY passes through
    -- (hud_layering starts at -38 below its page banner).
    return ns.QUI_SettingsLayoutShared.MakeLayout(content, nil, startY)
end

-- Single settings row wrapper (label + widget + optional description).
function SettingsLayout.Row(parent, label, widget, desc)
    return ns.QUI_Options.BuildSettingRow(parent, label, widget, desc)
end

-- Add a flat list of pre-built cells to `card` two-per-row, trailing the last
-- cell on its own row when the count is odd.
function SettingsLayout.PairCells(card, cells)
    local i = 1
    while i <= #cells do
        local left = cells[i]
        local right = cells[i + 1]
        if right then
            card.AddRow(left, right)
            i = i + 2
        else
            card.AddRow(left)
            i = i + 1
        end
    end
end
