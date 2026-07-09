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

print("OK: groupframes_container_prealloc_test")
