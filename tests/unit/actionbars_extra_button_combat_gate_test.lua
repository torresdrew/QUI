-- tests/unit/actionbars_extra_button_combat_gate_test.lua
-- Run: lua tests/unit/actionbars_extra_button_combat_gate_test.lua
--
-- Regression guard for the extra-action-button / zone-ability combat handling,
-- the container-anchor topology, and session-long disable behavior.
--
-- ExtraActionBarFrame owns the secure ExtraActionButton1
-- (SecureActionButtonTemplate), so it (and its ancestors, the shared
-- ExtraAbilityContainer included) cannot be reparented or repinned in combat --
-- SetScale/SetParent/ClearAllPoints/SetPoint would be ADDON_ACTION_BLOCKED.
-- ZoneAbilityFrame has NO secure descendant (its spell buttons inherit no
-- secure template), and Blizzard re-adds it to the shared container from
-- UNIT_AURA / SPELLS_CHANGED / ACTIONBAR_SLOT_CHANGED / vehicle events -- all
-- of which fire mid-combat.  The per-path rules:
--
--   1. EXTRA path: combat-gated.  Ownership is established out of combat by
--      anchoring the shared ExtraAbilityContainer (a stable Blizzard frame
--      Blizzard never reparents on a grant) to the mover, NOT
--      ExtraActionBarFrame.  A mid-combat refresh marks pending;
--      PLAYER_REGEN_ENABLED reconciles.
--   2. ZONE path: no blanket combat gate.  The unprotected ZoneAbilityFrame
--      is reparented onto its own mover, including mid-combat, so an
--      in-combat grant/reparent is reclaimed immediately instead of
--      stranding the button at the Blizzard position until regen.  The
--      reclaim PROBES live protection/anchoring state first (secret-capable
--      returns probed before truth-testing) and defers to regen if the
--      client reports the frame restricted.
--   3. DISABLE path: toggling a surface off resets stock appearance but keeps
--      ownership until /reload.  Live hand-back would mutate protected
--      managed-layout state; next session with both settings off leaves
--      Blizzard untouched.
--
-- This test proves: (a) in combat the EXTRA path touches NO protected
-- geometry on ExtraActionBarFrame OR the container and marks pending; (b) in
-- combat the ZONE path DOES reclaim ZoneAbilityFrame; (c) out of combat the
-- EXTRA path anchors the CONTAINER (never ExtraActionBarFrame:SetParent);
-- (d) disabling keeps ownership monotonic and resets styling.

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
local function recordingFrame(name, width, height)
    local f = {
        __name = name, button = nil, Style = nil,
        -- Live protection/anchoring answers for the zone in-combat probe.
        protectedNow = false, anchoringRestricted = false,
    }
    function f:GetParent() return nil end
    function f:SetScale(v) self.lastScale = v; record(name .. ":SetScale") end
    function f:SetParent(p) self.lastParent = p; record(name .. ":SetParent") end
    function f:ClearAllPoints() record(name .. ":ClearAllPoints") end
    function f:SetPoint() record(name .. ":SetPoint") end
    function f:GetWidth() return width or 64 end
    function f:GetHeight() return height or 64 end
    function f:SetAlpha(a) self.lastAlpha = a end
    function f:IsMouseEnabled() return false end
    function f:EnableMouse() record(name .. ":EnableMouse") end
    function f:IsProtected() return self.protectedNow end
    function f:IsAnchoringRestricted() return self.anchoringRestricted end
    return f
end

-- ExtraAbilityContainer stub: EditMode system frame with *Base point setters.
-- Base and non-Base variants record under the same normalized name so the
-- assertions do not care which path the code takes.
local function recordingContainer(name)
    local c = {
        __name = name,
        Selection = nil,
        minimumWidth = 250,
        fixedHeight = 120,
        scripts = {},
    }
    function c:GetParent() return nil end
    function c:SetParent(p) self.lastParent = p; record(name .. ":SetParent") end
    function c:ClearAllPoints() record(name .. ":ClearAllPoints") end
    function c:SetPoint(_, _, _, x, y)
        self.lastPointX, self.lastPointY = x, y
        record(name .. ":SetPoint")
    end
    function c:ClearAllPointsBase() record(name .. ":ClearAllPoints") end
    function c:SetPointBase(_, _, _, x, y)
        self.lastPointX, self.lastPointY = x, y
        record(name .. ":SetPoint")
    end
    function c:SetIsLayoutFrame() end
    function c:GetScript(which) return self.scripts[which] end
    function c:SetScript(which, fn) self.scripts[which] = fn end
    function c:AddFrame() end
    function c:Layout() end
    function c:MarkDirty() end
    return c
end

local extraFrame = recordingFrame("ExtraActionBarFrame", 256, 128)
local zoneFrame = recordingFrame("ZoneAbilityFrame")
local container = recordingContainer("ExtraAbilityContainer")
container.frames = { { frame = zoneFrame } }
local originalContainerLayout = container.Layout
local originalContainerMarkDirty = container.MarkDirty

-- Seed Blizzard scripts so the neutralize/restore round-trip is observable.
local blizzOnShow = function() end
local blizzOnHide = function() end
container.scripts.OnShow = blizzOnShow
container.scripts.OnHide = blizzOnHide

local function stubHolder(name)
    return { __name = name, SetSize = function() end }
end

local scheduled = {}
local inCombat = true

env.InCombatLockdown = function() return inCombat end
env.issecretvalue = function() return false end
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
local extraSettings = { enabled = true, scale = 1.0 }
local zoneSettings = { enabled = true, scale = 1.0 }
env.GetCore = function()
    return {
        db = { profile = { actionBars = { bars = {
            extraActionButton = extraSettings,
            zoneAbility       = zoneSettings,
        } } } },
    }
end

assert(loadfile(CHUNK))("QUI", ns)

local extraHolder = stubHolder("extraHolder")
local zoneHolder = stubHolder("zoneHolder")
env.extraBtnState.extraActionHolder = extraHolder
env.extraBtnState.zoneAbilityHolder = zoneHolder

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
local function assertNoProtectedExtraCalls(label)
    local seen = seenSet()
    for _, forbidden in ipairs({
        "ExtraActionBarFrame:SetScale",
        "ExtraActionBarFrame:SetParent",
        "ExtraActionBarFrame:ClearAllPoints",
        "ExtraActionBarFrame:SetPoint",
        "ExtraAbilityContainer:SetParent",
        "ExtraAbilityContainer:ClearAllPoints",
        "ExtraAbilityContainer:SetPoint",
    }) do
        assert(not seen[forbidden],
            label .. " must not call " .. forbidden .. " in combat; got: " .. geomSummary())
    end
end

---------------------------------------------------------------------------
-- IN COMBAT: the protected EXTRA path defers and marks pending; the
-- unprotected ZONE path reclaims immediately (mid-fight grants).
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
local zoneCombatSeen = seenSet()
for _, expected in ipairs({
    "ZoneAbilityFrame:SetScale",
    "ZoneAbilityFrame:SetParent",
    "ZoneAbilityFrame:ClearAllPoints",
    "ZoneAbilityFrame:SetPoint",
}) do
    assert(zoneCombatSeen[expected],
        "ApplyExtraButtonSettings(zone) must reclaim the unprotected frame IN combat"
            .. " (mid-fight grants); missing " .. expected .. "; got: " .. geomSummary())
end
assertNoProtectedExtraCalls("ApplyExtraButtonSettings(zone)")

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
RefreshExtraButtons()
assertNoProtectedExtraCalls("RefreshExtraButtons")
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "RefreshExtraButtons must mark the extra path pending when gated in combat")
assert(seenSet()["ZoneAbilityFrame:SetParent"],
    "RefreshExtraButtons must still apply the unprotected zone path in combat; got: " .. geomSummary())

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
QueueExtraButtonReanchor("extraActionButton")
runScheduled()
assertNoProtectedExtraCalls("QueueExtraButtonReanchor(extra) callback")
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "QueueExtraButtonReanchor(extra) must mark a pending refresh when gated in combat")

resetGeom()
QueueExtraButtonReanchor("zoneAbility")
runScheduled()
assert(seenSet()["ZoneAbilityFrame:SetParent"],
    "QueueExtraButtonReanchor(zone) callback must reclaim in combat; got: " .. geomSummary())

---------------------------------------------------------------------------
-- ZONE PROBE: the in-combat reclaim trusts the client over the static
-- "unprotected" expectation.  A frame reporting protected or
-- anchoring-restricted (or answering with a secret) defers to regen
-- instead of drawing ADDON_ACTION_BLOCKED.
---------------------------------------------------------------------------

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
zoneFrame.anchoringRestricted = true
ApplyExtraButtonSettings("zoneAbility")
assert(#geomCalls == 0,
    "anchoring-restricted zone frame must not be touched in combat; got: " .. geomSummary())
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "anchoring-restricted zone reclaim must defer to regen")
zoneFrame.anchoringRestricted = false

resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
zoneFrame.protectedNow = true
ApplyExtraButtonSettings("zoneAbility")
assert(#geomCalls == 0,
    "protected zone frame must not be touched in combat; got: " .. geomSummary())
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "protected zone reclaim must defer to regen")
zoneFrame.protectedNow = false

-- The getters' returns are secret-capable (ObjectSecurity aspect); an
-- unreadable answer counts as restricted, and the probe must run BEFORE
-- any truth-test (truth-testing a secret throws).
resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
local SECRET = setmetatable({}, { __tostring = function() return "SECRET" end })
env.issecretvalue = function(v) return v == SECRET end
zoneFrame.protectedNow = SECRET
ApplyExtraButtonSettings("zoneAbility")
assert(#geomCalls == 0,
    "secret protection answer must count as restricted; got: " .. geomSummary())
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "secret protection answer must defer the reclaim to regen")
zoneFrame.protectedNow = false
env.issecretvalue = function() return false end

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
assert(not extraSeen["ExtraActionBarFrame:ClearAllPoints"] and not extraSeen["ExtraActionBarFrame:SetPoint"],
    "extra path must leave ExtraActionBarFrame anchoring to Blizzard's secure layout; got: " .. geomSummary())
assert(container.Layout == originalContainerLayout and container.MarkDirty == originalContainerMarkDirty,
    "extra path must not replace ExtraAbilityContainer Layout/MarkDirty methods")
assert(container.lastPointX == 0 and container.lastPointY == 4,
    ("native-scale container compensation must be (0, 4); got (%s, %s)")
        :format(tostring(container.lastPointX), tostring(container.lastPointY)))

-- Enabling extra management neutralizes the container's own scripts (they are
-- what re-runs Blizzard managed layout) and remembers the originals.
assert(env.extraBtnState.containerNeutralized == true,
    "enabled extra path must neutralize the container")
assert(container.scripts.OnShow == nil and container.scripts.OnHide == nil,
    "neutralize must clear the container's OnShow/OnHide scripts")

resetGeom()
extraSettings.scale = 1.5
ApplyExtraButtonSettings("extraActionButton")
assert(container.lastPointX == -64 and container.lastPointY == 36,
    ("scaled container compensation must center the visual bar; got (%s, %s)")
        :format(tostring(container.lastPointX), tostring(container.lastPointY)))
extraSettings.scale = 1.0

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
-- DISABLE / SESSION OWNERSHIP: toggles reset stock appearance.  Container and
-- zone ownership remain monotonic until /reload, preserving separate movers
-- without mutating Blizzard's managed-frame or ability bookkeeping tables.
---------------------------------------------------------------------------

-- Zone off while extra is ON: zone stays evicted onto its own holder
-- (stock scale, position only), and stale QUI styling from the enabled
-- state (hideArtwork alpha) resets to stock.
zoneFrame.Style = { alpha = nil, SetAlpha = function(self, a) self.alpha = a end }
zoneSettings.hideArtwork = true
ApplyExtraButtonSettings("zoneAbility")   -- enabled + hideArtwork: styles it
assert(zoneFrame.Style.alpha == 0,
    "precondition: enabled hideArtwork hides the zone artwork")
resetGeom()
zoneSettings.enabled = false
ApplyExtraButtonSettings("zoneAbility")
local zoneInvariantSeen = seenSet()
assert(zoneInvariantSeen["ZoneAbilityFrame:SetParent"] and zoneInvariantSeen["ZoneAbilityFrame:SetPoint"],
    "zone-off + extra-on must still evict the zone frame to its own holder; got: " .. geomSummary())
assert(env.extraBtnState.zoneOwned == true,
    "dual-mover invariant keeps zone ownership while extra owns the container")
assert(zoneFrame.ignoreFramePositionManager == true,
    "dual-mover invariant keeps the zone position-manager opt-out")
assert(zoneFrame.Style.alpha == 1,
    "zone-off eviction must reset stale hideArtwork styling to stock")
zoneSettings.enabled = true
zoneSettings.hideArtwork = nil
zoneFrame.Style = nil

-- Extra off IN COMBAT: stock reset/re-anchor is protected -- defer, keep
-- session ownership and make no protected geometry call.
inCombat = true
resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
extraSettings.enabled = false
ApplyExtraButtonSettings("extraActionButton")
assertNoProtectedExtraCalls("disabled extra session ownership (combat)")
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "in-combat disable of the extra path must defer its stock reset to regen")
assert(env.extraBtnState.containerOwned == true,
    "in-combat disable must keep session ownership")

-- Extra off OUT of combat: reset stock styling, but keep the container pinned,
-- neutralized, and opted out for the rest of the session.
inCombat = false
extraFrame.lastScale = 1.5
extraFrame.lastAlpha = 0.4
extraFrame.button = { style = { alpha = 0, SetAlpha = function(self, a) self.alpha = a end } }
resetGeom()
ApplyExtraButtonSettings("extraActionButton")
assert(seenSet()["ExtraAbilityContainer:SetParent"],
    "disabling extra must keep the container on its holder; got: " .. geomSummary())
assert(env.extraBtnState.containerOwned == true and env.extraBtnState.containerNeutralized == true,
    "disabling extra must retain session ownership and neutralization")
assert(container.scripts.OnShow == nil and container.scripts.OnHide == nil,
    "disabling extra must not restore managed-layout scripts live")
assert(container.ignoreFramePositionManager == true and container.ignoreInLayout == true,
    "disabling extra must retain managed-layout opt-out flags")
assert(container.lastParent == extraHolder,
    "session-owned container must remain on the extra holder")
assert(extraFrame.lastScale == 1,
    "disabling extra must reset ExtraActionBarFrame scale to stock")
assert(extraFrame.lastAlpha == 1,
    "disabling extra must reset ExtraActionBarFrame alpha to stock")
assert(extraFrame.button.style.alpha == 1,
    "disabling extra must reset stale hideArtwork styling on the button artwork")
extraFrame.button = nil

-- BOTH off IN COMBAT: zone remains on its separate holder and resets to stock
-- appearance immediately when live protection probes allow it.  MarkDirty is
-- deferred because the shared container can still own the protected extra bar.
inCombat = true
resetGeom()
env.ActionBarsOwned.pendingExtraButtonRefresh = false
zoneSettings.enabled = false
ApplyExtraButtonSettings("zoneAbility")
local bothOffCombatSeen = seenSet()
assert(bothOffCombatSeen["ZoneAbilityFrame:SetParent"]
        and bothOffCombatSeen["ZoneAbilityFrame:ClearAllPoints"]
        and bothOffCombatSeen["ZoneAbilityFrame:SetPoint"],
    "disabled zone must stay on its separate holder in combat; got: " .. geomSummary())
assertNoProtectedExtraCalls("both disabled zone ownership (combat)")
assert(env.ActionBarsOwned.pendingExtraButtonRefresh == true,
    "in-combat zone MarkDirty must defer to regen")
assert(env.extraBtnState.zoneOwned == true,
    "both disabled must retain zone session ownership")

-- BOTH off OUT of combat: both movers stay owned, with stock appearance.
inCombat = false
resetGeom()
ApplyExtraButtonSettings("extraActionButton")
ApplyExtraButtonSettings("zoneAbility")
local bothOffSeen = seenSet()
assert(bothOffSeen["ExtraAbilityContainer:SetParent"]
        and bothOffSeen["ZoneAbilityFrame:SetParent"]
        and bothOffSeen["ZoneAbilityFrame:SetScale"],
    "both disabled must retain separate session-owned movers; got: " .. geomSummary())
assert(zoneFrame.lastParent == zoneHolder,
    "zone frame must remain on its own holder for the session")
assert(zoneFrame.lastScale == 1,
    "disabled zone must reset scale to stock")
assert(env.extraBtnState.containerOwned == true and env.extraBtnState.zoneOwned == true,
    "both disabled must keep ownership monotonic until reload")
assert(container.ignoreFramePositionManager == true and container.ignoreInLayout == true,
    "both disabled must keep empty container shell out of managed layout")

-- Simulated next session with BOTH off: fresh state leaves Blizzard untouched.
env.extraBtnState.containerOwned = false
env.extraBtnState.containerNeutralized = false
env.extraBtnState.zoneOwned = false
container.ignoreFramePositionManager = nil
container.ignoreInLayout = nil
container.scripts.OnShow = blizzOnShow
container.scripts.OnHide = blizzOnHide
resetGeom()
ApplyExtraButtonSettings("extraActionButton")
ApplyExtraButtonSettings("zoneAbility")
assert(#geomCalls == 0,
    "fresh session with both disabled must leave Blizzard frames untouched; got: " .. geomSummary())
assert(env.extraBtnState.containerOwned == false and env.extraBtnState.zoneOwned == false,
    "fresh session with both disabled must not acquire ownership")

-- Fresh ZONE-only session: extra branch acquires the shared container shell
-- before zone extraction.  Container may remain internally shown because its
-- Blizzard frames entry still counts ZoneAbilityFrame, but it cannot register
-- or reserve the 250x120 bottom-managed layout slot.
zoneSettings.enabled = true
resetGeom()
ApplyExtraButtonSettings("extraActionButton")
ApplyExtraButtonSettings("zoneAbility")
assert(env.extraBtnState.containerOwned == true and env.extraBtnState.containerNeutralized == true,
    "zone-only session must acquire and neutralize the shared container shell")
assert(container.ignoreFramePositionManager == true and container.ignoreInLayout == true,
    "zone-only session must opt the empty container shell out of managed layout")
assert(#container.frames == 1 and container.frames[1].frame == zoneFrame,
    "zone-only ownership must leave Blizzard container membership untouched")
assert(container.lastParent == extraHolder,
    "zone-only container shell must stay on the QUI extra holder, not managed layout")
assert(zoneFrame.lastParent == zoneHolder and env.extraBtnState.zoneOwned == true,
    "zone-only session must keep ZoneAbilityFrame on its separate mover")

zoneSettings.enabled = true
extraSettings.enabled = true

---------------------------------------------------------------------------
-- SOURCE GUARD: gates, container-anchor topology, and honest comments present.
---------------------------------------------------------------------------

local source = readFile(CHUNK)

-- The PROTECTED extra path must keep its load-bearing combat gate (dropping
-- it on a "both frames are unprotected" premise shipped live taint once).
assert(source:find("COMBAT GATE (load-bearing)", 1, true),
    "extra path must document and keep its combat gate")

-- The zone path's in-combat reclaim rests on the no-secure-descendant fact;
-- keep that justification in the source next to the behavior.
assert(source:find("no secure descendant", 1, true),
    "zone path must document why its in-combat reclaim is safe")

assert(source:find("function ApplyExtraActionContainerAnchor", 1, true),
    "extra path must anchor ExtraAbilityContainer via ApplyExtraActionContainerAnchor")
assert(source:find("container:SetParent(holder)", 1, true),
    "ApplyExtraActionContainerAnchor must parent the container to the holder")
assert(not source:find("container.Layout =", 1, true),
    "extra path must not replace ExtraAbilityContainer.Layout")
assert(not source:find("container.MarkDirty =", 1, true),
    "extra path must not replace ExtraAbilityContainer.MarkDirty")
assert(not source:find('bar:SetPoint("CENTER", holder', 1, true),
    "extra path must not fight Blizzard's secure child layout")

-- Never call the destructive ExtraAbilityContainer:RemoveFrame.
assert(source:find("RemoveFrame", 1, true) and source:find("never call", 1, true),
    "source must document that ExtraAbilityContainer:RemoveFrame is destructive and must not be called")

-- Ownership must be session-long.  Live Restore* paths re-enter Blizzard's
-- protected manager and container layout from insecure code.
assert(source:find("SESSION-LONG OWNERSHIP", 1, true),
    "source must document session-long ownership")
assert(not source:find("function RestoreExtraAbilityContainer", 1, true)
        and not source:find("function RestoreZoneAbilityFrame", 1, true),
    "live disable path must not restore Blizzard ownership")

-- The dual-mover requirement is load-bearing: extra action and zone ability
-- each keep their OWN mover; the zone frame never rides the extra mover.
assert(source:find("DUAL-MOVER INVARIANT", 1, true),
    "source must document the dual-mover invariant")
assert(source:find("function IsZoneAbilityManaged", 1, true),
    "zone management must be active whenever either surface is enabled")
assert(source:find("function ShouldOwnExtraAbilityContainer", 1, true),
    "either enabled surface must acquire the shared container shell")

-- Protected extra acquisition and restricted zone/MarkDirty paths mark pending
-- for the PLAYER_REGEN_ENABLED reconcile.
local gateCount = select(2, source:gsub("ActionBarsOwned%.pendingExtraButtonRefresh = true", ""))
assert(gateCount >= 2,
    "expected >= 2 combat gates marking pendingExtraButtonRefresh, found " .. gateCount)

-- NEVER write into the manager's showingFrames table: an insecure write
-- (raw key removal included) taints it, and the manager's secure pairs()
-- walk then blocks protected ClearAllPoints on the OTHER managed frames
-- (live ADDON_ACTION_BLOCKED).  The transient UpdateManagedFrames clobber
-- is repaired by the container hooks instead.
assert(not source:find("showingFrames[", 1, true)
        and not source:find("showingFrames%s*%["),
    "takeover must never write into the manager's showingFrames table (taint)")
assert(source:find("showingFrames", 1, true),
    "source must document why showingFrames stays untouched")

-- Blizzard alone owns ExtraAbilityContainer.frames membership.  Zone stays in
-- that bookkeeping table while its frame is visually reparented.
assert(not source:find("container%.frames%s*%[")
        and not source:find("table%.remove%s*%(container%.frames"),
    "QUI must never mutate ExtraAbilityContainer.frames")

-- The zone in-combat reclaim must probe live protection/anchoring state
-- (secret-capable returns probed before any truth-test) instead of assuming
-- the static no-secure-descendant topology.
assert(source:find("IsAnchoringRestricted", 1, true),
    "zone reclaim must probe IsAnchoringRestricted before in-combat mutation")
assert(source:find("issecretvalue(", 1, true),
    "protection probes must issecretvalue-probe their secret-capable returns")

-- Fresh defaults must present truly independent movers.
local defaults = readFile("core/defaults.lua")
local frameAnchoringStart = assert(defaults:find("        frameAnchoring = {", 1, true),
    "missing frameAnchoring defaults")
local zoneDefaultStart = assert(defaults:find("            zoneAbility = {", frameAnchoringStart, true),
    "missing zoneAbility frame anchor default")
local zoneDefaultEnd = assert(defaults:find("            },", zoneDefaultStart, true),
    "unterminated zoneAbility frame anchor default")
local zoneDefault = defaults:sub(zoneDefaultStart, zoneDefaultEnd)
assert(zoneDefault:find('parent = "screen"', 1, true)
        and not zoneDefault:find('parent = "extraActionButton"', 1, true),
    "fresh zone mover default must be screen-anchored, not parented to extra mover")

print("OK: actionbars_extra_button_combat_gate_test")
