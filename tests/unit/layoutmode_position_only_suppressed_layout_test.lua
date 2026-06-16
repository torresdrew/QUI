-- tests/unit/layoutmode_position_only_suppressed_layout_test.lua
-- Run: lua tests/unit/layoutmode_position_only_suppressed_layout_test.lua
--
-- Regression guard: in QUI Layout Mode, right-clicking a shared-provider mover
-- (M+ timer, missing raid buffs, pet warning, ready check, M+ progress, minimap)
-- must show ONLY the Position controls + the "Open ... settings" link, NOT the
-- mover's full settings body.
--
-- Root cause: the options-v2 migration moved provider bodies onto the V3
-- primitives CreateSettingsCardGroup + CreateAccentDotLabel (via each module's
-- local MakeLayout). The Layout-Mode position-only suppression only lives inside
-- Utils.CreateCollapsible (returns nil when Utils._layoutModePositionOnly is set
-- and we are not inside the Position collapsible), so the card-group bodies
-- bypassed it and rendered every section.
--
-- Fix: each provider's MakeLayout returns Utils.MakeSuppressedProviderLayout(content)
-- when the flag is set -- an inert layout that mirrors the MakeLayout contract so
-- the build body runs unchanged, but renders nothing and lets only the appended
-- Position collapsible + settings link survive. This test drives the real helper
-- from modules/layout/layoutmode_utils.lua.

local function newFrame()
    local f = { _shown = true, _height = 0 }
    function f:Hide() self._shown = false end
    function f:Show() self._shown = true end
    function f:IsShown() return self._shown end
    function f:SetSize() end
    function f:SetWidth() end
    function f:SetHeight(h) self._height = h or 0 end
    function f:GetHeight() return self._height end
    function f:ClearAllPoints() end
    function f:SetPoint() end
    function f:SetParent(p) self._parent = p end
    function f:GetParent() return self._parent end
    return f
end

_G.CreateFrame = function() return newFrame() end

-- Load the real layout utils under a minimal namespace. The module only touches
-- globals at call time, so a bare ns is enough to define Utils.
local ns = { Helpers = {} }
local chunk = assert(loadfile("modules/layout/layoutmode_utils.lua"))
chunk("QUI", ns)
local Utils = assert(ns.QUI_LayoutMode_Utils, "layoutmode_utils must export Utils")

assert(type(Utils.MakeSuppressedProviderLayout) == "function",
    "Utils.MakeSuppressedProviderLayout must exist")

local content = newFrame()
local L = Utils.MakeSuppressedProviderLayout(content)

-- Contract parity with MakeLayout so provider build bodies run unchanged.
assert(type(L.headerAt) == "function", "L.headerAt must exist")
assert(type(L.sectionAt) == "function", "L.sectionAt must exist")
assert(type(L.closeSection) == "function", "L.closeSection must exist")
assert(type(L.placeCustom) == "function", "L.placeCustom must exist")
assert(type(L.sections) == "table", "L.sections must be a table")
assert(type(L.relayoutSections) == "function", "L.relayoutSections must exist")

-- headerAt renders nothing.
assert(L.headerAt("General") == nil, "headerAt must be a no-op in position-only mode")

-- sectionAt returns an inert card-group stub with a usable (hidden) frame for
-- widget parenting, but AddRow/Finalize do nothing.
local s = L.sectionAt()
assert(type(s) == "table" and s.frame ~= nil, "sectionAt must return a stub with a frame")
assert(s.frame:IsShown() == false, "stub section frame must be hidden")
assert(type(s.AddRow) == "function" and type(s.Finalize) == "function",
    "stub section must expose AddRow/Finalize")

local widget = newFrame()
local parentBefore = widget:GetParent()
s.AddRow(widget)            -- must NOT reparent the widget into a visible row
assert(widget:GetParent() == parentBefore, "stub AddRow must not reparent widgets")
assert(s.Finalize() == nil, "stub Finalize must be a no-op")

-- placeCustom must hide any pre-created custom block so it does not float at the
-- default anchor.
local custom = newFrame()
L.placeCustom(custom, 40)
assert(custom:IsShown() == false, "placeCustom must hide the custom frame in position-only mode")

-- relayoutSections lays out ONLY whatever was appended to L.sections (the
-- Position collapsible + Open Full Settings link) and sizes content to them.
local posSection = newFrame(); posSection:SetHeight(120)
table.insert(L.sections, posSection)
L.relayoutSections()
assert(content:GetHeight() > 0, "relayoutSections must size content to the position section")

print("OK: layoutmode_position_only_suppressed_layout_test")
