-- tests/unit/groupframes_auras_combat_mutable_test.lua
-- Run: lua tests/unit/groupframes_auras_combat_mutable_test.lua
--
-- Combat-mutation split for the per-element group-frame aura containers.
-- Creation of a forbidden CustomAuraContainer (+ its AddAuraGroup/AddAuraSlot
-- button pooling) is combat-restricted; mutation of pre-created ones (SetUnit /
-- filters / enable) is combat-legal. With pre-allocation, a member joining
-- mid-combat lands on a child whose containers exist — the mutable pass points
-- them at the unit LIVE instead of showing nothing until regen; any forbidden
-- work skipped in combat sets `incomplete` and queues a regen replay.
-- DisableStripContainers likewise hides a cleared unit's containers live.

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

-- ApplyElementPass: the single per-element pass, allowCreate-gated.
local pass = slice("local function ApplyElementPass(frame, allowCreate)")

-- Forbidden CREATION (container frame) is allowCreate AND OOC only.
assert(pass:find("if allowCreate and not InCombatLockdown() and CreateFrame then", 1, true),
    "container creation must be gated on allowCreate + not InCombatLockdown()")
assert(pass:find('CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")', 1, true),
    "creation uses the CustomAuraContainerTemplate")

-- Forbidden-frame SetPoint (anchor) is OOC only; mutation of SetUnit is not.
local anchorGate = pass:find("if not InCombatLockdown() then", 1, true)
local anchorCall = pass:find("AnchorElementContainer(container, frame, element)", 1, true)
assert(anchorGate and anchorCall and anchorGate < anchorCall,
    "AnchorElementContainer (forbidden SetPoint) must be gated on not InCombatLockdown()")
assert(pass:find("container:SetUnit(unit)", 1, true),
    "SetUnit is combat-legal mutation and runs unconditionally")

-- Group / slot reconcile flows through the shared core glue; the combat
-- pcall(Configure)/Restyle fallback lives INSIDE AuraGlue.RunConfigPass, so
-- this file just threads allowCreate through — it never pcalls Configure itself.
assert(pass:find("AuraGlue.RunConfigPass(container, profile, groups, allowCreate)", 1, true),
    "filter strips reconcile groups via AuraGlue.RunConfigPass(..., allowCreate)")
assert(pass:find("AuraGlue.ElementGroups(unit, element, profile, false)", 1, true),
    "filter strips build descriptors via AuraGlue.ElementGroups")
assert(pass:find("AuraSlots.Sync(container, element, allowCreate)", 1, true),
    "tracked elements reconcile slots via AuraSlots.Sync(..., allowCreate)")
assert(not pass:find("pcall(AuraSkin", 1, true),
    "the combat Configure guard lives in core (AuraGlue.RunConfigPass), not here")
assert(not pass:find("AuraSkin.Reflow", 1, true),
    "AuraSkin.Reflow no longer exists")

-- Skipped forbidden work queues a regen replay.
assert(pass:find("QueueContainerCombatWork(frame)", 1, true),
    "incomplete (forbidden work skipped in combat) must queue a regen replay")

-- The public full-pass name survives (forward-declared).
assert(src:find("function ApplyStripContainers(frame)", 1, true),
    "ApplyStripContainers must keep its (forward-declared) name")
assert(src:find("ApplyElementPass(frame, not InCombatLockdown())", 1, true),
    "ApplyStripContainers replays the full pass (OOC at regen)")

-- UpdateStripContainers: combat = pcall'd mutable pass now + STILL queue.
local update = slice("local function UpdateStripContainers(frame)")
assert(update:find("pcall(ApplyElementPass, frame, false)", 1, true),
    "UpdateStripContainers must pcall the mutation-only pass immediately in combat")
assert(update:find("QueueContainerCombatWork(frame)", 1, true),
    "UpdateStripContainers must STILL queue the full pass for regen (self-heal)")
assert(update:find("ApplyElementPass(frame, true)", 1, true),
    "UpdateStripContainers runs the full creating pass OOC")

-- RetireContainer: the shared retire recipe (empty groups + park + disable + hide).
local retire = slice("local function RetireContainer(container, allowCreate)")
assert(retire:find("AuraGlue.RunConfigPass", 1, true) and retire:find("AuraSlots.Park", 1, true),
    "retire = empty groups (RunConfigPass) + park slots")
assert(retire:find("SetEnabled(false)", 1, true) and retire:find(":Hide()", 1, true),
    "retire disables + hides the container")

-- DisableStripContainers: retire every pooled container; combat pcall-guards
-- the live retire and still queues a regen replay.
local disable = slice("local function DisableStripContainers(frame)")
assert(disable:find("frame._quiAuraContainers", 1, true),
    "DisableStripContainers iterates the per-element pool")
assert(disable:find("pcall(RetireContainer, container, false)", 1, true),
    "DisableStripContainers must pcall the live retire in combat")
assert(disable:find("RetireContainer(container, true)", 1, true),
    "DisableStripContainers retires directly OOC")
assert(disable:find("QueueContainerCombatWork(frame)", 1, true),
    "DisableStripContainers queues a regen replay in combat")

print("OK: groupframes_auras_combat_mutable_test")
