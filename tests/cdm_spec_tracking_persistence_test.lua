-- tests/cdm_spec_tracking_persistence_test.lua
-- Headless regression checks for CDM spec-cache scoping.
-- Run: lua tests/cdm_spec_tracking_persistence_test.lua

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local containers = readAll("modules/cdm/cdm_containers.lua")

assert(
    containers:find("GetCurrentCharacterKey", 1, true),
    "CDM spec tracking should derive a current character key"
)

assert(
    containers:find("_lastSpecCharKey", 1, true),
    "cached _lastSpecID should be scoped by character key"
)

assert(
    containers:find("cachedCharKey == currentCharKey", 1, true),
    "cached spec fallback should only trust a cache written by this character"
)

assert(
    containers:find("db._lastSpecCharKey = currentCharKey", 1, true),
    "cross-session detection should persist the character key with _lastSpecID"
)

assert(
    containers:find("local specDB = GetSpecStateDB(true)", 1, true),
    "spec change events should persist _lastSpecID through the character-scoped state helper"
)

assert(
    containers:find("local shouldLoadActiveSpec = true", 1, true),
    "initial login should hydrate the active spec from scoped storage even when no prior spec stamp exists"
)

local snapshotPos = containers:find("local snapshotReady = TrySnapshotBuiltInContainers(containerKeys)", 1, true)
assert(
    snapshotPos and containers:find("SaveSpecProfile(specID)", snapshotPos, true),
    "fresh snapshots should be saved into the scoped spec profile store immediately"
)

assert(
    containers:find("StampActiveProfileSpecOwner", 1, true),
    "hydrating or saving the active spec should stamp which character owns the profile's live containers"
)

assert(
    containers:find("liveStateOwnedByCurrentChar", 1, true),
    "cross-session detection should not save another character's live containers into this character's spec store"
)

assert(
    containers:find("GetSpecProfileStore", 1, true),
    "CDM spec spell profiles should resolve through a scoped store helper"
)

assert(
    containers:find("_specProfilesByProfile", 1, true),
    "CDM spec spell profiles should be stored per character and per AceDB profile"
)

assert(
    containers:find("GetCurrentProfile", 1, true),
    "CDM spec spell profile storage should include the active AceDB profile name"
)

assert(
    containers:find("store[specID] = specData", 1, true),
    "SaveSpecProfile should write to the scoped spec profile store"
)

assert(
    not containers:find("db._specProfiles[specID] = specData", 1, true),
    "SaveSpecProfile must not write spec spell lists into shared profile ncdm._specProfiles"
)

assert(
    not containers:find("return db._specProfiles", 1, true),
    "spec profile storage must not fall back to the shared profile ncdm._specProfiles table"
)

print("OK: cdm_spec_tracking_persistence_test")
