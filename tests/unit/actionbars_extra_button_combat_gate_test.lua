-- tests/unit/actionbars_extra_button_combat_gate_test.lua
-- Run: lua tests/unit/actionbars_extra_button_combat_gate_test.lua
--
-- Regression guard for the extra-action-button / zone-ability combat gates and
-- the container-anchor topology.
--
-- ExtraActionBarFrame owns the secure ExtraActionButton1
-- (SecureActionButtonTemplate), so it (and its ancestors) cannot be reparented
-- or repinned in combat -- SetScale/SetParent/ClearAllPoints/SetPoint would be
-- ADDON_ACTION_BLOCKED.  Two rules keep this taint-free:
--
--   1. Combat gate: every refresh entry point bails during InCombatLockdown()
--      and marks pending; PLAYER_REGEN_ENABLED reconciles.
--   2. Container-anchor: the EXTRA path anchors the shared ExtraAbilityContainer
--      (a stable Blizzard frame Blizzard never reparents on a grant), NOT
--      ExtraActionBarFrame.  A button granted mid-combat lands in a container
--      that already sits on the user's mover -- zero in-combat protected calls.
--      The ZONE path reparents the unprotected ZoneAbilityFrame onto its own
--      mover (two independent movers preserved).
--
-- This test proves: (a) combat entry points touch NO protected geometry, on
-- ExtraActionBarFrame OR the container; (b) out of combat the EXTRA path anchors
-- the CONTAINER (never ExtraActionBarFrame:SetParent); (c) the ZONE path
-- reparents ZoneAbilityFrame.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local CHUNK = "QUI_ActionBars/actionbars/actionbars_extra_buttons.lua"

---------------------------------------------------------------------------
-- Behavioral harness: load the real chunk with a stubbed environment.
---------------------------------------------------------------------------

local ns = {}

assert(loadfile("QUI_ActionBars/actionbars/actionbars_env.lua"))("QUI", ns)
local env = ns.ActionBarsEnv

-- Records every protected geometry call made against a Blizzard frame.
local geomCalls = {}
local function record(name)
    geomCalls[#geomCalls + 1] = name
end

-- Frame that scales/reparents/repins (ExtraActionBarFrame, ZoneAbilityFrame).
local function recordingFrame(name)
    local f = { __name = name, button = nil, Style = nil }
    function f:GetParent() return nil end
    function f:SetScale() record(name .. ":SetScale") end
    function f:SetParent() record(name .. ":SetParent") end
    function f:ClearAllPoints() record(name .. ":ClearAllPoints") end
    function f:SetPoint() record(name .. ":SetPoint") end
    function f:GetWidth() return 64 end
    function f:GetHeight() return 64 end
    function f:SetAlpha() end
    function f:IsMouseEnabled() return false end
    function f:EnableMouse() record(name .. ":EnableMouse") end
    return f
end

-- ExtraAbilityContainer stub: EditMode system frame with *Base point setters.
-- Base and non-Base variants record under the same normalized name so the
-- assertions do not care which path the code takes.
local function recordingContainer(name)
    local c = { __name = name, Selection = nil }
    function c:GetParent() return nil end
    function c:SetParent() record(name .. ":SetParent") end
    function c:ClearAllPoints() record(name .. ":ClearAllPoints") end
    function c:SetPoint() record(name .. ":SetPoint") end
    function c:ClearAllPointsBase() record(name .. ":ClearAllPoints") end
    function c:SetPointBase() record(name .. ":SetPoint") end
    function c:SetIsLayoutFrame() end
    function c:SetScript() end
    function c:AddFrame() end
    return c
end

local extraFrame = recordingFrame("ExtraActionBarFrame")
local zoneFrame = recordingFrame("ZoneAbilityFrame")
local container = recordingContainer("ExtraAbilityContainer")

local function stubHolder()
    return { SetSize = function() end }
end

local scheduled = {}
local inCombat = true

env.InCombatLockdown = function() return inCombat end
env.ExtraActionBarFrame = extraFrame
env.ZoneAbilityFrame = zoneFrame
env.ExtraAbilityContainer = container
env.hooksecurefunc = function() end
env.C_Timer = { After = function(_, fn) scheduled[#scheduled + 1] = fn end }
env.ActionBarsOwned = {}
env.Helpers = {
    SafeToNumber = function(v, d)
        local n = tonumber(v)
        if n == nil then return d end
        return n
    end,
}
env.GetCore = function()
    return {
        db = { profile = { actionBars = { bars = {
            extraActionButton = { enabled = true, scale = 1.0 },
            zoneAbility       = { enabled = true, scale = 1.0 },
        } } } },
    }
end

assert(loadfile(CHUNK))("QUI", ns)

env.extraBtnState.extraActionHolder = stubHolder()
env.extraBtnState.zoneAbilityHolder = stubHolder()

local ApplyExtraButtonSettings = assert(env.ApplyExtraButtonSettings,
    "chunk must declare ApplyExtraButtonSettings")
local RefreshExtraButtons = assert(env.RefreshExtraButtons,
    "chunk must declare RefreshExtraButtons")
local QueueExtraButtonReanchor = assert(env.QueueExtraButtonReanchor,
    "chunk must declare QueueExtraButtonReanchor")

local function resetGeom()
    for i = #geomCalls, 1, -1 do geomCalls[i] = nil end
end
local function runScheduled()
    local pending = scheduled
    scheduled = {}
    for _, fn in ipairs(pending) do fn() end
end
local function geomSummary()
    return #geomCalls == 0 and "(none)" or table.concat(geomCalls, ", ")
end
local function seenSet()
    local seen = {}
    for _, c in ipairs(geomCalls) do seen[c] = true end
    return seen
end

---------------------------------------------------------------------------
-- IN COMBAT: no protected geometry call on ANY frame, refresh marked pending.
---------------------------------------------------------------------------

inCombat = true

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
ApplyExtraButtonSettings("extraActionButton")
assert(#geomCalls == 0,
    "ApplyExtraButtonSettings(extra) must make no protected geometry call in combat; got: " .. geomSummary())
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "ApplyExtraButtonSettings must mark a pending refresh when gated in combat")

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
ApplyExtraButtonSettings("zoneAbility")
assert(#geomCalls == 0,
    "ApplyExtraButtonSettings(zone) must make no protected geometry call in combat; got: " .. geomSummary())

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
RefreshExtraButtons()
assert(#geomCalls == 0,
    "RefreshExtraButtons must make no protected geometry call in combat; got: " .. geomSummary())
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "RefreshExtraButtons must mark a pending refresh when gated in combat")

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
QueueExtraButtonReanchor("extraActionButton")
runScheduled()
assert(#geomCalls == 0,
    "QueueExtraButtonReanchor callback must make no protected geometry call in combat; got: " .. geomSummary())
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "QueueExtraButtonReanchor must mark a pending refresh when gated in combat")

---------------------------------------------------------------------------
-- POSITIVE CONTROL (out of combat): EXTRA anchors the CONTAINER, never
-- ExtraActionBarFrame; ZONE reparents ZoneAbilityFrame.  Proves the test can
-- detect a regression instead of passing vacuously.
---------------------------------------------------------------------------

inCombat = false

resetGeom()
ApplyExtraButtonSettings("extraActionButton")
local extraSeen = seenSet()
for _, expected in ipairs({
    "ExtraActionBarFrame:SetScale",       -- visual scale still on the bar
    "ExtraAbilityContainer:SetParent",    -- position owned via the CONTAINER
    "ExtraAbilityContainer:ClearAllPoints",
    "ExtraAbilityContainer:SetPoint",
}) do
    assert(extraSeen[expected],
        "positive control (extra): out of combat must call " .. expected .. "; got: " .. geomSummary())
end
assert(not extraSeen["ExtraActionBarFrame:SetParent"],
    "extra path must NOT reparent ExtraActionBarFrame (Blizzard keeps it in the container); got: " .. geomSummary())

resetGeom()
ApplyExtraButtonSettings("zoneAbility")
local zoneSeen = seenSet()
for _, expected in ipairs({
    "ZoneAbilityFrame:SetScale",
    "ZoneAbilityFrame:SetParent",
    "ZoneAbilityFrame:ClearAllPoints",
    "ZoneAbilityFrame:SetPoint",
}) do
    assert(zoneSeen[expected],
        "positive control (zone): out of combat must call " .. expected .. "; got: " .. geomSummary())
end

---------------------------------------------------------------------------
-- SOURCE GUARD: gates, container-anchor topology, and honest comments present.
---------------------------------------------------------------------------

local source = readFile(CHUNK)

assert(not source:find("combat%-legal"),
    "source must not claim in-combat repin is 'combat-legal'")

assert(source:find("function ApplyExtraActionContainerAnchor", 1, true),
    "extra path must anchor ExtraAbilityContainer via ApplyExtraActionContainerAnchor")
assert(source:find("container:SetParent(holder)", 1, true),
    "ApplyExtraActionContainerAnchor must parent the container to the holder")

-- Never call the destructive ExtraAbilityContainer:RemoveFrame.
assert(source:find("RemoveFrame", 1, true) and source:find("never call", 1, true),
    "source must document that ExtraAbilityContainer:RemoveFrame is destructive and must not be called")

-- Every combat entry point must gate on InCombatLockdown() and mark pending.
local gateCount = select(2, source:gsub("ActionBarsOwned%.pendingExtraButtonRefresh = true", ""))
assert(gateCount >= 4,
    "expected >= 4 combat gates marking pendingExtraButtonRefresh, found " .. gateCount)

print("OK: actionbars_extra_button_combat_gate_test")
