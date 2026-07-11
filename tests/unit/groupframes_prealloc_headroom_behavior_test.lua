-- tests/unit/groupframes_prealloc_headroom_behavior_test.lua
-- Wave 4 Task 1: behavioral proof of the mechanism QUI_GFA.PrebuildHeadroomGroups
-- (QUI_GroupFrames/groupframes/groupframes_auras.lua) and
-- QUI_GF:PreallocateAuraContainers (QUI_GroupFrames/groupframes/groupframes.lua)
-- depend on.
--
-- groupframes_auras.lua needs real WoW frames + the AuraEvents subscription
-- and cannot run headless (see tests/unit/groupframes_aura_glue_test.lua's own
-- comment), so its headroom wiring is pinned by source text in
-- tests/unit/groupframes_container_prealloc_test.lua. What CAN run headless
-- is the shared core glue those functions call through
-- (core/aura_glue.lua's AuraGlue.RunConfigPass -> core/aura_skin.lua's
-- AuraSkin.Configure) -- this file loads that real production code (mirrors
-- tests/unit/aura_skin_filter_canonicalize_test.lua's harness) against a
-- fake container that SPIES on AddAuraGroup, and proves the actual claim
-- headroom prealloc rests on:
--
--   (a) an OOC RunConfigPass(..., allowCreate=true) registers the group
--       (AddAuraGroup called; container._quiGroups is no longer empty) --
--       this is what QUI_GFA.PrebuildHeadroomGroups does to a headroom slot
--       before any real roster member ever occupies it.
--   (b) a LATER "combat join" -- RunConfigPass(..., allowCreate=false) on
--       that SAME (already-registered) container -- does NOT call
--       AddAuraGroup again (spy count unchanged) yet still reconciles the
--       group's live mutators (SetAuraGroupMaxFrameCount etc.), proving the
--       container is fully bound and rendering without any forbidden call.
--       This is the mid-combat join: SetUnit (already combat-legal +
--       unconditional, see groupframes_auras_combat_mutable_test.lua) +
--       this reconcile is the entire cost of binding a pre-built container.
--   (c) contrast: a FRESH (never OOC-configured) container run through the
--       exact same combat pass gets ZERO groups registered -- this is the
--       shell-only bug headroom prealloc exists to close: without the OOC
--       pre-registration, Configure's combat guard
--       ("elseif not InCombatLockdown() then container:AddAuraGroup(...)")
--       silently skips, and the member is left with no aura groups until
--       PLAYER_REGEN_ENABLED replays.
--
-- Run: lua tests/unit/groupframes_prealloc_headroom_behavior_test.lua

local fails = 0
local function check(name, ok, detail)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name .. (detail and ("  " .. detail) or "")) end
end

----------------------------------------------------------------------------
-- Combat-state toggle: RunConfigPass/Configure both read InCombatLockdown()
-- live, so a single mutable upvalue drives both the "OOC prealloc" and
-- "combat join" phases of this test.
----------------------------------------------------------------------------
local inCombat = false
_G.InCombatLockdown = function() return inCombat end
_G.AuraContainerSortMethod = { Default = 1 }
_G.AuraContainerSortDirection = { Normal = 1 }
_G.AnchorUtil = { FlowDirection = { Left = -1, Right = 1, Up = 1, Down = -1 } }

local function Stub()
    local t = {}
    function t:SetAllPoints() end
    function t:SetPoint() end
    function t:ClearAllPoints() end
    function t:SetColorTexture() end
    function t:SetTexCoord() end
    function t:DisablePixelSnap() end
    function t:SetTextColor() end
    function t:SetAlpha() end
    function t:SetFont() end
    function t:SetHideCountdownNumbers() end
    function t:SetDrawSwipe() end
    function t:SetReverse() end
    function t:SetText() end
    function t:CreateTexture() return Stub() end
    function t:CreateFontString() return Stub() end
    return t
end
_G.CreateFrame = function() return Stub() end

local function MakeButton()
    local b = Stub()
    function b:SetCancelAuraButtons() end
    function b:SetSize() end
    function b:SetIcon() end
    function b:SetAuraBorder() end
    function b:SetAuraSymbol() end
    function b:SetDurationCooldown() end
    function b:SetDurationText() end
    function b:SetApplicationCount() end
    return b
end

-- Fake CustomAuraContainer with an AddAuraGroup SPY: records every call so
-- the test can assert an EXACT count across the OOC and combat phases (not
-- just "some calls happened").
local function MakeContainer()
    local c = { _addAuraGroupCalls = 0, _mutatorCalls = 0, _registeredKeys = {}, _maxFrameCounts = {} }
    function c:HasAuraGroup(key) return self._registeredKeys[key] == true end
    function c:AddAuraGroup(key, filter, opts)
        c._addAuraGroupCalls = c._addAuraGroupCalls + 1
        c._registeredKeys[key] = true
        c._maxFrameCounts[key] = opts.maxFrameCount
        c._lastInitFn = opts.initializeFrame
        c._capturedButton = MakeButton()
        c._lastInitFn(c._capturedButton)
    end
    function c:SetAuraGroupMaxFrameCount(key, count)
        self._mutatorCalls = self._mutatorCalls + 1
        self._maxFrameCounts[key] = count
    end
    function c:SetAuraGroupSortMethod() self._mutatorCalls = self._mutatorCalls + 1 end
    function c:SetAuraGroupCandidateFilters() self._mutatorCalls = self._mutatorCalls + 1 end
    function c:SetAuraGroupLayout() self._mutatorCalls = self._mutatorCalls + 1 end
    function c:SetAuraLayoutAnchorPoint() end
    function c:SetAuraLayoutGrowthDirection() end
    function c:SetAuraLayoutPadding() end
    function c:SetAuraLayoutRowWidth() end
    -- SetUnit: mirrors Blizzard_AuraContainer.lua's real contract closely
    -- enough for this test -- asserts a STRING (no nil tolerance), same as
    -- the real AuraContainerSharedMixin:SetUnit (Blizzard_AuraContainer.lua:41)
    -- that motivates PrebuildHeadroomGroups' PREALLOC_PROBE_UNIT stand-in.
    function c:SetUnit(unitToken)
        assert(type(unitToken) == "string", "SetUnit requires a string unit token")
        self.unitToken = unitToken
    end
    function c:SetEnabled(v) self.enabled = v end
    function c:Show() self.shown = true end
    function c:Hide() self.shown = false end
    return c
end

local ns = {}
assert(loadfile("core/aura_theme.lua"))("QUI", ns)
assert(loadfile("core/aura_skin.lua"))("QUI", ns)
assert(loadfile("core/aura_elements.lua"))("QUI", ns)
assert(loadfile("core/aura_glue.lua"))("QUI", ns)
local AuraGlue = ns.AuraGlue
check("core/aura_glue.lua publishes ns.AuraGlue", AuraGlue ~= nil)
check("core/aura_skin.lua publishes ns.Addon.AuraSkin", ns.Addon and ns.Addon.AuraSkin ~= nil)

local profile = { iconSize = 20, maxIcons = 5 }
local groups = { { key = "s1", filter = "HELPFUL", maxFrameCount = 5 } }

----------------------------------------------------------------------------
-- (a) OOC "headroom prealloc" pass: PrebuildHeadroomGroups always calls
-- RunConfigPass with allowCreate=true (it only ever runs OOC -- its own
-- guard bails on InCombatLockdown()), on a container that's never been
-- configured before -- exactly the state a freshly shell-created headroom
-- container is in.
----------------------------------------------------------------------------
inCombat = false
local headroomContainer = MakeContainer()
headroomContainer:SetUnit("player")  -- PREALLOC_PROBE_UNIT stand-in
local okOOC = AuraGlue.RunConfigPass(headroomContainer, profile, groups, true)
check("OOC RunConfigPass(allowCreate=true) succeeds", okOOC == true)
check("AddAuraGroup was called exactly once (group registered)",
    headroomContainer._addAuraGroupCalls == 1, tostring(headroomContainer._addAuraGroupCalls))
check("the group key is registered on the container",
    headroomContainer._registeredKeys["s1|HELPFUL"] == true)

----------------------------------------------------------------------------
-- (b) Simulated mid-combat join: the roster now assigns this SAME
-- pre-built container a real unit. Bind order matches ApplyElementPass
-- (SetUnit unconditional, THEN RunConfigPass) and combat gives allowCreate
-- =false (mirrors UpdateStripContainers' combat branch:
-- "pcall(ApplyElementPass, frame, false)").
----------------------------------------------------------------------------
inCombat = true
headroomContainer:SetUnit("party3")  -- the real join overwrites the probe token
local callsBeforeCombat = headroomContainer._addAuraGroupCalls
local mutatorsBefore = headroomContainer._mutatorCalls
local okCombat = AuraGlue.RunConfigPass(headroomContainer, profile, groups, false)
check("combat RunConfigPass(allowCreate=false) still reports success (pcall around an already-registered Configure never throws)",
    okCombat == true)
check("AddAuraGroup is NOT called again in combat (already-registered key reused)",
    headroomContainer._addAuraGroupCalls == callsBeforeCombat,
    tostring(headroomContainer._addAuraGroupCalls) .. " vs " .. tostring(callsBeforeCombat))
check("the live mutators (SetAuraGroupMaxFrameCount et al) DO run in combat -- the container is actually reconciled, not a no-op",
    headroomContainer._mutatorCalls > mutatorsBefore)
check("the group registered during the OOC phase is still present after the combat pass",
    headroomContainer._registeredKeys["s1|HELPFUL"] == true)

----------------------------------------------------------------------------
-- (c) Contrast: a FRESH container (the shell-only bug this task fixes --
-- creation happened OOC, but no headroom prebuild ever ran on it) put
-- through the IDENTICAL combat join sequence gets ZERO groups. This is the
-- "raid member joining mid-combat gets a frame with zero aura groups until
-- regen" bug from the task brief, reproduced against the real Configure
-- code so the fix above is proven against the actual failure mode, not a
-- hypothetical.
----------------------------------------------------------------------------
local freshContainer = MakeContainer()
freshContainer:SetUnit("party4")
local okFreshCombat = AuraGlue.RunConfigPass(freshContainer, profile, groups, false)
check("a shell-only container's combat RunConfigPass does not throw (Configure just silently skips the unregistered key)",
    okFreshCombat == true)
check("a shell-only container's combat join registers ZERO groups (the pre-headroom bug)",
    freshContainer._addAuraGroupCalls == 0, tostring(freshContainer._addAuraGroupCalls))
check("AddAuraGroup was never called on the fresh container in combat",
    next(freshContainer._registeredKeys) == nil)

----------------------------------------------------------------------------
-- (d) Settings/filter edit refreshes the SPARES (review finding): the
-- assigned-frame walk in RefreshSettings (RefreshAllFrames) never touches
-- unassigned headroom containers, so RefreshSettings now also calls
-- PreallocateAuraContainers -> PrebuildHeadroomGroups on every spare (wiring
-- pinned in groupframes_container_prealloc_test.lua). What that re-prebuild
-- MUST accomplish, proven here against the real Configure code: the spare's
-- registry gains the NEW canonical key OOC (AddAuraGroup) and retires the
-- stale one (maxFrameCount 0 -- PTR4 groups are unremovable), so a
-- mid-combat join AFTER the settings edit binds the NEW filter with no
-- forbidden AddAuraGroup call. Raw filter deliberately un-canonical
-- ("PLAYER|HELPFUL") to prove headroom re-keys CANONICALLY (Task 4
-- integration -- a stale-raw-keyed spare would defeat the registered-key
-- reuse the combat join depends on).
----------------------------------------------------------------------------
inCombat = false
local newGroups = { { key = "s1", filter = "PLAYER|HELPFUL", maxFrameCount = 5 } }
local addCallsBeforeEdit = headroomContainer._addAuraGroupCalls
local okEdit = AuraGlue.RunConfigPass(headroomContainer, profile, newGroups, true)
check("OOC settings-edit re-prebuild succeeds", okEdit == true)
check("the NEW canonical key is registered on the spare via AddAuraGroup (exactly one new call)",
    headroomContainer._registeredKeys["s1|HELPFUL|PLAYER"] == true
    and headroomContainer._addAuraGroupCalls == addCallsBeforeEdit + 1,
    tostring(headroomContainer._addAuraGroupCalls))
check("the STALE key is retired to zero frames (groups are unremovable)",
    headroomContainer._maxFrameCounts["s1|HELPFUL"] == 0,
    tostring(headroomContainer._maxFrameCounts["s1|HELPFUL"]))
check("the NEW key carries the live maxFrameCount",
    headroomContainer._maxFrameCounts["s1|HELPFUL|PLAYER"] == 5,
    tostring(headroomContainer._maxFrameCounts["s1|HELPFUL|PLAYER"]))

-- The payoff: a mid-combat join AFTER the settings edit finds the NEW key
-- already registered -- no AddAuraGroup in combat, mutators still reconcile.
inCombat = true
headroomContainer:SetUnit("party5")
local addCallsBeforeJoin = headroomContainer._addAuraGroupCalls
local okJoin = AuraGlue.RunConfigPass(headroomContainer, profile, newGroups, false)
check("post-edit combat join succeeds without AddAuraGroup (new key pre-registered by the settings-edit prebuild)",
    okJoin == true and headroomContainer._addAuraGroupCalls == addCallsBeforeJoin,
    tostring(headroomContainer._addAuraGroupCalls) .. " vs " .. tostring(addCallsBeforeJoin))
inCombat = false

----------------------------------------------------------------------------
-- Mutation-verify the combat gate itself: AuraSkin.Configure's own guard
-- ("elseif not InCombatLockdown() then container:AddAuraGroup") is what (c)
-- exercises above; pin its exact source text so a flipped condition
-- (e.g. "InCombatLockdown()" without the "not") is caught even though it
-- would make this exact test pass by accident (an inverted guard would
-- allow AddAuraGroup OOC-never / combat-always, and a container probed
-- OOC-first would still show 1 call in (a) -- but (c)'s "ZERO calls in
-- combat on a fresh container" would flip to "one call", so (c) alone
-- already falsifies that mutation. This source pin adds a second,
-- independent check.).
----------------------------------------------------------------------------
do
    local skinSrc = assert(io.open("core/aura_skin.lua", "rb")):read("*a")
    check("AuraSkin.Configure's combat gate is exactly 'not InCombatLockdown()'",
        skinSrc:find("elseif not InCombatLockdown() then\n            container:AddAuraGroup(key, filter, {", 1, true) ~= nil)
end

if fails > 0 then error(fails .. " failure(s) in groupframes_prealloc_headroom_behavior_test") end
print("OK: groupframes_prealloc_headroom_behavior_test (all checks passed)")
