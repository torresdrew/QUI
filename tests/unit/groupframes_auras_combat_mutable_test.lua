-- tests/unit/groupframes_auras_combat_mutable_test.lua
-- Run: lua tests/unit/groupframes_auras_combat_mutable_test.lua
--
-- Port of the buffborders combat-mutation split to the group-frame strips.
-- Creation of the forbidden CustomAuraContainer is combat-restricted; mutation
-- of pre-created ones (SetUnit / filters / enable / anchor) is combat-legal.
-- With pre-allocation, a member joining mid-combat lands on a child whose
-- containers exist — the mutable pass points them at the unit LIVE instead of
-- showing nothing until regen. DisableStripContainers likewise hides a cleared
-- unit's strips live instead of showing stale auras all fight.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_GroupFrames/groupframes/groupframes_auras.lua")

local function slice(marker)
    local startPos = src:find(marker, 1, true)
    assert(startPos, "missing: " .. marker)
    local endPos = src:find("\nend", startPos, true)
    assert(endPos, "unterminated function at: " .. marker)
    return src:sub(startPos, endPos)
end

-- Shared pass gates creation on allowCreate; mutation branch re-flows existing.
local pass = slice("local function ApplyStripPass(frame, allowCreate)")
local gate = pass:find("if allowCreate then", 1, true)
assert(gate, "ApplyStripPass must branch on allowCreate")
local ensure = pass:find("EnsureStripContainers(frame, buffElems, debuffElems)", 1, true)
assert(ensure and ensure > gate, "creation (EnsureStripContainers) must be allowCreate-only")

-- Per-zone group config: OOC configures directly, combat pcall-guards
-- AuraSkin.Configure and falls back to the always combat-legal AuraSkin.Restyle
-- (mirrors the unitframe_auras / buffborders ConfigureZoneAuraContainer pattern).
assert(pass:find("AuraSkin.Configure", 1, true),
    "pass must configure zone groups via AuraSkin.Configure")
assert(pass:find("pcall(AuraSkin.Configure", 1, true),
    "combat zone configuration must be pcall-guarded")
assert(pass:find("AuraSkin.Restyle", 1, true),
    "combat zone configuration must fall back to AuraSkin.Restyle")
assert(not pass:find("AuraSkin.Reflow", 1, true),
    "AuraSkin.Reflow no longer exists; ApplyStripPass must not call it")

assert(pass:find("AnchorZoneContainer", 1, true),
    "the mutation branch must re-anchor the containers")

-- The public full-pass name survives.
assert(src:find("function ApplyStripContainers(frame)", 1, true),
    "ApplyStripContainers must keep its (forward-declared) name")

-- UpdateStripContainers: combat = pcall mutable + STILL queue.
local update = slice("local function UpdateStripContainers(frame)")
assert(update:find("pcall(ApplyStripPass, frame, false)", 1, true),
    "UpdateStripContainers must pcall the mutation pass immediately in combat")
assert(update:find("QueueContainerCombatWork(frame)", 1, true),
    "UpdateStripContainers must STILL queue the full pass for regen (self-heal)")

-- DisableStripContainers: cleared unit hides live in combat.
local disable = slice("local function DisableStripContainers(frame)")
assert(disable:find("pcall", 1, true) and disable:find("QueueContainerCombatWork(frame)", 1, true),
    "DisableStripContainers must pcall the live disable in combat and still queue")

print("OK: groupframes_auras_combat_mutable_test")
