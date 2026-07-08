-- tests/unit/unitframe_auras_combat_mutable_test.lua
-- Run: lua tests/unit/unitframe_auras_combat_mutable_test.lua
--
-- Port of the buffborders combat-mutation split: creating a forbidden
-- CustomAuraContainer is combat-restricted (crashes the 12.1 client), but
-- MUTATING a pre-created one (SetPoint / filters / SetUnit / enable) is
-- combat-legal. UpdateAuras used to defer ALL config to PLAYER_REGEN_ENABLED;
-- now it applies the mutation subset immediately (pcall-guarded) AND still
-- queues the full pass so a wrong PTR assumption self-heals at regen.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_UnitFrames/unitframes/unitframe_auras.lua")

local function slice(marker)
    local startPos = src:find(marker, 1, true)
    assert(startPos, "missing: " .. marker)
    local endPos = src:find("\nend", startPos, true)
    assert(endPos, "unterminated function at: " .. marker)
    return src:sub(startPos, endPos)
end

-- Shared pass gates creation on allowCreate.
local pass = slice("local function ApplyContainerConfigPass(frame, allowCreate)")
local gate = pass:find("if allowCreate then", 1, true)
assert(gate, "pass must branch on allowCreate")
local ensure = pass:find("EnsureContainers(frame, auraSettings)", 1, true)
assert(ensure and ensure > gate, "container creation (EnsureContainers) must be allowCreate-only")
assert(pass:find("ReflowContainers(frame, auraSettings)", 1, true),
    "the mutation branch must re-flow existing containers (creation-free)")

-- Per-zone group config: OOC configures directly, combat pcall-guards
-- AuraSkin.Configure and falls back to the always combat-legal AuraSkin.Restyle
-- (mirrors the buffborders ConfigureZoneAuraContainer pattern).
assert(pass:find("AuraSkin.Configure", 1, true),
    "pass must configure zone groups via AuraSkin.Configure")
assert(pass:find("pcall(AuraSkin.Configure", 1, true),
    "combat zone configuration must be pcall-guarded")
assert(pass:find("AuraSkin.Restyle", 1, true),
    "combat zone configuration must fall back to AuraSkin.Restyle")

-- ReflowContainers: re-anchor ONLY (creation-free, group-free — AuraSkin.Reflow
-- no longer exists; group reconcile lives in ApplyContainerConfigPass above).
local reflow = slice("local function ReflowContainers(frame, auraSettings)")
assert(not reflow:find("AuraSkin.Reflow", 1, true),
    "AuraSkin.Reflow no longer exists; ReflowContainers must not call it")
assert(not reflow:find("AuraSkin.Attach", 1, true),
    "AuraSkin.Attach no longer exists; ReflowContainers must not call it")
assert(reflow:find("AnchorContainer", 1, true),
    "ReflowContainers must re-anchor (anchor moves are combat-legal mutation)")
assert(not reflow:find("CreateFrame", 1, true),
    "ReflowContainers must not create anything")

-- UpdateAuras: combat = pcall mutable + STILL queue.
local update = slice("local function UpdateAuras(frame)")
assert(update:find("InCombatLockdown()", 1, true), "UpdateAuras must branch on combat")
assert(update:find("pcall(ApplyContainerConfigPass, frame, false)", 1, true),
    "UpdateAuras must pcall the mutation pass immediately in combat")
assert(update:find("QueueCombatWork(frame)", 1, true),
    "UpdateAuras must STILL queue the full pass for regen (self-heal)")

-- Preview suppression mutates live in combat too (SetEnabled/Hide are legal).
local suppress = slice("local function SuppressContainerForPreview(frame, isDebuff)")
assert(suppress:find("pcall", 1, true) and suppress:find("QueueCombatWork(frame)", 1, true),
    "preview suppression must pcall the live disable in combat and still queue")

-- The public export name survives (callers in unitframes.lua depend on it).
assert(src:find("QUI_UF.ApplyContainerConfig = ApplyContainerConfig", 1, true),
    "QUI_UF.ApplyContainerConfig export must keep its name")

print("OK: unitframe_auras_combat_mutable_test")
