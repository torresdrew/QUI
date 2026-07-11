-- tests/unit/groupframes_container_prealloc_test.lua
-- Run: lua tests/unit/groupframes_container_prealloc_test.lua
--
-- Group frames are SecureGroupHeader children that can be born MID-COMBAT
-- (secure header update). Creating a forbidden CustomAuraContainer in combat
-- crashes the 12.1 client, so a child born in combat would show no auras until
-- regen. Fix: pre-allocate the header's MAXIMUM children OOC via the
-- startingIndex attribute (FrameXML configureChildren: numDisplayed =
-- unitCount - (startingIndex - 1); negative value inflates needButtons up to
-- unitsPerColumn * maxColumns), then pre-create containers on every child OOC.
-- Mid-combat roster growth then reuses pre-created children + containers.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local function slice(src, marker)
    local startPos = src:find(marker, 1, true)
    assert(startPos, "missing: " .. marker)
    local endPos = src:find("\nend", startPos, true)
    assert(endPos, "unterminated function at: " .. marker)
    return src:sub(startPos, endPos)
end

local auras = readAll("QUI_GroupFrames/groupframes/groupframes_auras.lua")

-- Per-frame pre-creation entry: OOC-only, cheap-idempotent, one container per
-- active element pre-created into the ordinal pool.
local ensure = slice(auras, "function QUI_GFA.EnsureContainersForFrame(frame)")
assert(ensure:find("InCombatLockdown()", 1, true),
    "EnsureContainersForFrame must be OOC-only (container creation is combat-forbidden)")
assert(ensure:find("if #pool >= want then return", 1, true),
    "EnsureContainersForFrame must skip frames whose pool already holds enough containers (cheap re-entry)")
assert(ensure:find("ResolveContainerElements(frame)", 1, true),
    "EnsureContainersForFrame must resolve the container-rendered elements for the frame's context")
assert(ensure:find('CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")', 1, true),
    "EnsureContainersForFrame must pre-create one CustomAuraContainer per active element")
assert(ensure:find("AnchorElementContainer(container, frame, elems[i])", 1, true),
    "EnsureContainersForFrame must anchor each pre-created container OOC (mid-combat joiner ready)")

local gf = readAll("QUI_GroupFrames/groupframes/groupframes.lua")

-- The preallocator: OOC-only method on QUI_GF (200-local limit in that chunk).
local prealloc = slice(gf, "function QUI_GF:PreallocateAuraContainers()")
assert(prealloc:find("InCombatLockdown()", 1, true),
    "PreallocateAuraContainers must be OOC-only")
-- startingIndex force-allocation with immediate restore.
assert(prealloc:find('"startingIndex", -(wanted - 1)', 1, true),
    "must force child allocation via a negative startingIndex")
assert(prealloc:find('"startingIndex", saved or 1', 1, true),
    "must restore startingIndex immediately after forcing")
-- Skip the dance when the header already has its max children.
assert(prealloc:find('GetAttribute("child" .. wanted)', 1, true),
    "must skip the force when child<wanted> already exists")
-- Every child gets containers pre-created.
assert(prealloc:find("EnsureContainersForFrame(child)", 1, true),
    "must pre-create containers on every allocated child")
-- All header surfaces covered.
assert(prealloc:find("self.headers.party", 1, true)
    and prealloc:find("self.headers.raid", 1, true)
    and prealloc:find("self.headers.self", 1, true)
    and prealloc:find("raidGroupHeaders", 1, true)
    and prealloc:find("spotlightHeader", 1, true),
    "must cover party, raid, self, raid-group and spotlight headers")

-- Trigger points: post-roster deferred work + combat end.
local gru = slice(gf, "local function GRU_DeferredWork()")
assert(gru:find("PreallocateAuraContainers", 1, true),
    "GRU_DeferredWork must preallocate after secure headers settle")
local regenPos = gf:find('elseif event == "PLAYER_REGEN_ENABLED" then', 1, true)
assert(regenPos, "regen handler must exist")
local regenBlock = gf:sub(regenPos, regenPos + 2500)
assert(regenBlock:find("PreallocateAuraContainers", 1, true),
    "the PLAYER_REGEN_ENABLED block must preallocate (covers rosters grown in combat)")

---------------------------------------------------------------------------
-- Wave 4 Task 1: hybrid prealloc headroom.
--
-- Bare container SHELLS (above) are not enough: AddAuraGroup (real secure
-- button batches) never runs until the child's normal per-unit config pass
-- fires, and that ONLY ever runs on a frame with a real side-state unit
-- (UpdateStripContainers / ApplyElementPass both guard on it). A member
-- joining MID-COMBAT into a shell-only slot therefore binds a container
-- with zero registered groups: AuraSkin.Configure's own
-- "elseif not InCombatLockdown() then container:AddAuraGroup(...)" guard
-- (core/aura_skin.lua) skips registration in combat, so nothing shows until
-- PLAYER_REGEN_ENABLED replays. Fix: pre-register the groups OOC, for the
-- roster + PREALLOC_HEADROOM spare children, so the real join's SetUnit
-- (already combat-legal + unconditional — see
-- groupframes_auras_combat_mutable_test.lua) lands on an ALREADY-REGISTERED
-- key (Configure's "if registered[key] or container:HasAuraGroup(key)"
-- branch: mutators only, no AddAuraGroup needed).
---------------------------------------------------------------------------

-- The headroom constant: exported (not a file local) so both files share one
-- source of truth and it is mutation-verifiable by exact literal.
assert(auras:find("QUI_GFA.PREALLOC_HEADROOM = 5", 1, true),
    "PREALLOC_HEADROOM must be exported as exactly 5")

-- PrebuildHeadroomGroups: OOC-only full build (containers + groups) for a
-- header child with NO roster occupant yet.
local prebuild = slice(auras, "function QUI_GFA.PrebuildHeadroomGroups(frame)")
assert(prebuild:find("if not frame or GetFrameUnit(frame) or InCombatLockdown() then return end", 1, true),
    "PrebuildHeadroomGroups must refuse an already-assigned frame (would wrongly re-hide a live strip) AND be OOC-only")
assert(prebuild:find("QUI_GFA.EnsureContainersForFrame(frame)", 1, true),
    "PrebuildHeadroomGroups must ensure the container shells exist first")
-- Blizzard_AuraContainer.lua's SetUnit asserts a STRING (no nil tolerance),
-- so an unoccupied child is probed with a stand-in token, not a nil unit.
assert(auras:find('local PREALLOC_PROBE_UNIT = "player"', 1, true),
    "must define a stand-in probe unit for genuinely unitless children")
assert(prebuild:find("container:SetUnit(PREALLOC_PROBE_UNIT)", 1, true),
    "must SetUnit the probe token BEFORE group configuration (eager registration needs a valid unit)")
assert(prebuild:find("AuraGlue.RunConfigPass(container, AuraGlue.ElementProfile(element), {}, true)", 1, true)
    and prebuild:find("AuraSlots.Sync(container, element, true)", 1, true),
    "tracked elements must reconcile slots via AuraSlots.Sync(..., allowCreate=true), same as the live per-unit pass")
assert(prebuild:find("AuraGlue.ElementGroups(PREALLOC_PROBE_UNIT, element, profile, false)", 1, true)
    and prebuild:find("AuraGlue.RunConfigPass(container, profile, groups, true)", 1, true),
    "filter strips must build + register real groups OOC (allowCreate=true), not just anchor a shell")
-- Must stay dormant: SetEnabled(true)/Show() belongs ONLY to the real join.
assert(prebuild:find("container:SetEnabled(false)", 1, true) and prebuild:find("container:Hide()", 1, true),
    "a headroom container must be left disabled + hidden until a real unit binds it")

-- PreallocateAuraContainers: the roster + headroom window, wired around the
-- existing shell loop (no second queue -- same OOC call, same trigger points
-- already pinned above).
assert(prealloc:find("local headroom = GFA.PREALLOC_HEADROOM or 5", 1, true),
    "PreallocateAuraContainers must read the shared headroom constant")
assert(prealloc:find("if QUI_GF.GetFrameUnit(child) then assignedCount = assignedCount + 1 end", 1, true),
    "must count the CURRENTLY-assigned children to size the headroom window")
assert(prealloc:find("local buildCount = math.min(assignedCount + headroom, wanted)", 1, true),
    "the build window must be roster size + headroom, capped at the header's max capacity")
assert(prealloc:find("if not QUI_GF.GetFrameUnit(child) then", 1, true)
    and prealloc:find("GFA.PrebuildHeadroomGroups(child)", 1, true),
    "must only fully build UNOCCUPIED children inside the window (assigned children are already fully" ..
    " configured by RefreshAllFrames, which runs before this in GRU_DeferredWork)")

-- Regen replay restores headroom consumed by a mid-combat join: no NEW
-- trigger is needed -- PreallocateAuraContainers is ONE function that now
-- ALWAYS recomputes the roster+headroom window (assignedCount/buildCount
-- above are computed fresh on every call, not cached), and it is already
-- unconditionally called from BOTH GRU_DeferredWork (pinned above, fires on
-- every GROUP_ROSTER_UPDATE while OOC) AND the PLAYER_REGEN_ENABLED block
-- (pinned above, fires once combat ends) -- so a headroom slot consumed by
-- a mid-combat join is rebuilt the moment either trigger next fires OOC.

-- SETTINGS-EDIT trigger (review finding): RefreshSettings' frame walk
-- (RefreshAllFrames) only iterates unitFrameMap -- ASSIGNED frames -- so a
-- settings/filter edit would leave the headroom SPARES keyed to the STALE
-- canonical filter until the next roster/regen trigger; a mid-combat join
-- onto a stale spare in that window reproduces the zero-groups bug
-- (Configure's registered-key check misses the new key, the combat gate
-- skips AddAuraGroup). RefreshSettings must therefore rebuild the headroom
-- window itself, AFTER the assigned-frame walk. PreallocateAuraContainers
-- is internally OOC-gated, so the call is unconditional; in-combat settings
-- edits reach the spares via the existing regen replay (deferred
-- RefreshSettings + the regen block's own PreallocateAuraContainers call,
-- both pinned above).
-- Newline+indent prefix makes this a STATEMENT-position pin: a plain
-- substring would still match the call inside a commented-out line, letting
-- a comment-out mutation survive (mutation-verified: it did, before this
-- tightening).
local refreshSettings = slice(gf, "function QUI_GF:RefreshSettings()")
local rsWalk = refreshSettings:find("\n        self:RefreshAllFrames()", 1, true)
local rsPrealloc = refreshSettings:find("\n    self:PreallocateAuraContainers()", 1, true)
assert(rsPrealloc,
    "RefreshSettings must rebuild the headroom window (PreallocateAuraContainers) on settings change")
assert(rsWalk and rsWalk < rsPrealloc,
    "the headroom rebuild must come AFTER the assigned-frame walk (RefreshAllFrames)")

print("OK: groupframes_container_prealloc_test")
