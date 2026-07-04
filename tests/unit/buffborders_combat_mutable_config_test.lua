-- tests/unit/buffborders_combat_mutable_config_test.lua
-- Run: lua tests/unit/buffborders_combat_mutable_config_test.lua
--
-- 12.1 PTR contract: CREATING a forbidden CustomAuraContainer/AuraButton in
-- combat is restricted (crashes the client today), but MUTATING pre-created
-- ones (SetPoint / SetSize / filters / enable) is legal in combat. The old
-- ApplyOrDefer deferred ALL config to PLAYER_REGEN_ENABLED; the split applies
-- the combat-legal subset immediately and still queues the full pass (secure
-- cancel-header attributes, private-aura anchor registration, and any missing
-- creation are OOC-only), so a wrong PTR assumption self-heals at regen.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_ActionBars/actionbars/buffborders.lua")

-- Slice helper: function start → next line-leading `end`.
local function slice(marker)
    local startPos = src:find(marker, 1, true)
    assert(startPos, "missing: " .. marker)
    local endPos = src:find("\nend", startPos, true)
    assert(endPos, "unterminated function at: " .. marker)
    return src:sub(startPos, endPos)
end

-- The shared pass must exist and gate creation-class work on allowCreate.
local pass = slice("local function ApplyConfigPass(allowCreate)")
local gatePos = pass:find("if allowCreate then", 1, true)
assert(gatePos, "ApplyConfigPass must gate OOC-only work on allowCreate")
local headerPos = pass:find("ConfigureBuffCancelHeader(", 1, true)
assert(headerPos, "ApplyConfigPass must still configure the cancel header on the full pass")
assert(headerPos > gatePos,
    "ConfigureBuffCancelHeader (secure SetAttribute = combat-blocked) must sit behind the allowCreate gate")
local paPos = pass:find("SetupPrivateAuras()", 1, true)
assert(paPos and paPos > gatePos,
    "SetupPrivateAuras (anchor re-registration) must sit behind the allowCreate gate")

-- Zone config: creation only via EnsureZoneContainer under allowCreate; the
-- mutation branch re-flows existing buttons (never creates) and re-anchors.
local zone = slice("local function ConfigureZoneAuraContainer(")
local zoneGate = zone:find("if allowCreate then", 1, true)
assert(zoneGate, "ConfigureZoneAuraContainer must branch on allowCreate")
local ensurePos = zone:find("EnsureZoneContainer(anchorFrame, profile)", 1, true)
assert(ensurePos and ensurePos > zoneGate,
    "container creation (EnsureZoneContainer) must be allowCreate-only")
assert(zone:find("AuraSkin.Reflow", 1, true),
    "the mutation branch must re-flow existing buttons via AuraSkin.Reflow (creation-free)")
assert(not zone:find("CreateFrame", 1, true),
    "ConfigureZoneAuraContainer must not CreateFrame directly")

-- ApplyOrDefer: in combat, apply the mutable subset now AND queue the full pass.
local apply = slice("local function ApplyOrDefer()")
assert(apply:find("InCombatLockdown()", 1, true),
    "ApplyOrDefer must still branch on combat lockdown")
assert(apply:find("ApplyMutableConfig()", 1, true),
    "ApplyOrDefer must apply the combat-legal mutation pass immediately in combat")
assert(apply:find("QueueContainerWork()", 1, true),
    "ApplyOrDefer must STILL queue the full pass for PLAYER_REGEN_ENABLED (self-heal)")

-- The combat pass must pcall-guard forbidden-container mutation (PTR-observed
-- legality; a restriction error must not abort the rest of the pass).
assert(pass:find("pcall(ConfigureZoneAuraContainer", 1, true),
    "the mutation pass must pcall the per-zone container mutation")

print("OK: buffborders_combat_mutable_config_test")
