-- tests/unit/cdm_resolvers_runtime_query_cache_test.lua
-- Run: lua tests/unit/cdm_resolvers_runtime_query_cache_test.lua

local function noop() end

function InCombatLockdown() return true end
function geterrorhandler() return function(err) error(err) end end
function CreateFrame()
    return {
        RegisterEvent = noop,
        RegisterUnitEvent = noop,
        SetScript = noop,
    }
end

local cooldownCalls = 0
local chargeCalls = 0
local durationCalls = 0
local chargeDurationCalls = 0
local overrideCalls = 0
local displayCountCalls = 0
local spellCountCalls = 0

local cooldownInfo = { isActive = true }
local chargeInfo = { currentCharges = 1, maxCharges = 2, isActive = true }
local durationObject = { token = "cooldown-duration" }
local chargeDurationObject = { token = "charge-duration" }
local secretDisplayCount = { token = "secret-display-count" }
local secretSpellCount = { token = "secret-spell-count" }

function issecretvalue(value)
    return rawequal(value, secretDisplayCount) or rawequal(value, secretSpellCount)
end

local ns = {
    Helpers = {},
    CDMShared = {
        IsSafeNumeric = function(value) return type(value) == "number" end,
        SafeBoolean = function(value)
            return type(value) == "boolean" and value or nil
        end,
    },
    CDMSources = {
        QuerySpellCooldown = function(spellID)
            cooldownCalls = cooldownCalls + 1
            if spellID == 101 then return cooldownInfo end
            return nil
        end,
        QuerySpellCharges = function(spellID)
            chargeCalls = chargeCalls + 1
            if spellID == 101 then return chargeInfo end
            return nil
        end,
        QuerySpellCooldownDuration = function(spellID, ignoreGCD)
            durationCalls = durationCalls + 1
            if spellID == 101 and ignoreGCD == true then return durationObject end
            return nil
        end,
        QuerySpellChargeDuration = function(spellID)
            chargeDurationCalls = chargeDurationCalls + 1
            if spellID == 101 then return chargeDurationObject end
            return nil
        end,
        QueryOverrideSpell = function(spellID)
            overrideCalls = overrideCalls + 1
            if spellID == 101 then return 202 end
            return nil
        end,
        QuerySpellDisplayCount = function(spellID)
            displayCountCalls = displayCountCalls + 1
            if spellID == 101 then return secretDisplayCount end
            return nil
        end,
        QuerySpellCount = function(spellID)
            spellCountCalls = spellCountCalls + 1
            if spellID == 101 then return secretSpellCount end
            return nil
        end,
    },
}

local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("modules/cdm/cdm_runtime.lua", "cdm_runtime_queries.lua")("QUI", ns)

local runtime = assert(ns.CDMRuntimeQueries, "CDMRuntimeQueries should be exported")
assert(type(runtime.BeginRuntimeQueryBatch) == "function",
    "runtime query batching should expose BeginRuntimeQueryBatch")
assert(type(runtime.EndRuntimeQueryBatch) == "function",
    "runtime query batching should expose EndRuntimeQueryBatch")

runtime.QueryCooldown(101)
runtime.QueryCooldown(101)
assert(cooldownCalls == 2,
    "outside a batch cooldown queries should remain live reads")

runtime.BeginRuntimeQueryBatch()
assert(runtime.QueryCooldown(101) == cooldownInfo,
    "ownerless batched cooldown query should return source payload")
assert(runtime.QueryCooldown(101) == cooldownInfo,
    "ownerless duplicate cooldown query should remain a live source read")
assert(runtime.QueryCharges(101) == chargeInfo,
    "ownerless batched charge query should return source payload")
assert(runtime.QueryCharges(101) == chargeInfo,
    "ownerless duplicate charge query should remain a live source read")
assert(runtime.QueryDuration(101) == durationObject,
    "ownerless cooldown DurationObject query should return source payload")
assert(runtime.QueryDuration(101) == durationObject,
    "ownerless duplicate DurationObject query should remain a live source read")
assert(runtime.QueryChargeDuration(101) == chargeDurationObject,
    "ownerless charge DurationObject query should return source payload")
assert(runtime.QueryChargeDuration(101) == chargeDurationObject,
    "ownerless duplicate charge DurationObject query should remain a live source read")
assert(runtime.QueryOverrideSpell(101) == 202,
    "batched override query should return source payload")
assert(runtime.QueryOverrideSpell(101) == 202,
    "duplicate batched override query should return cached payload")
assert(rawequal(runtime.QueryDisplayCount(101), secretDisplayCount),
    "batched display-count query should forward secret source payload")
assert(rawequal(runtime.QueryDisplayCount(101), secretDisplayCount),
    "ownerless duplicate secret display-count query should forward source payload")
assert(rawequal(runtime.QuerySpellCount(101), secretSpellCount),
    "batched spell-count query should forward secret source payload")
assert(rawequal(runtime.QuerySpellCount(101), secretSpellCount),
    "ownerless duplicate secret spell-count query should forward source payload")

assert(runtime.QueryCooldown(404) == nil,
    "batched nil cooldown result should pass through")
assert(runtime.QueryCooldown(404) == nil,
    "ownerless duplicate nil cooldown result should remain a live source read")
assert(runtime.QueryCharges(404) == nil,
    "batched nil charge result should pass through")
assert(runtime.QueryCharges(404) == nil,
    "ownerless duplicate nil charge result should remain a live source read")
runtime.EndRuntimeQueryBatch()

assert(cooldownCalls == 6,
    "ownerless cooldown activity should not use a central batch cache")
assert(chargeCalls == 4,
    "ownerless charge activity should not use a central batch cache")
assert(durationCalls == 2,
    "ownerless cooldown DurationObject activity should not use a central batch cache")
assert(chargeDurationCalls == 2,
    "ownerless charge DurationObject activity should not use a central batch cache")
assert(overrideCalls == 1,
    "override queries should use the stable identity cache")
assert(displayCountCalls == 2,
    "ownerless display-count payloads should not use a central batch cache")
assert(spellCountCalls == 2,
    "ownerless spell-count payloads should not use a central batch cache")

local owner = { _spellEntry = { viewerType = "essential", type = "spell", id = 101 } }
runtime.BeginRuntimeQueryBatch()
assert(runtime.QueryCooldown(101, owner) == cooldownInfo,
    "owner cooldown query should return source payload")
assert(runtime.QueryCooldown(101, owner) == cooldownInfo,
    "duplicate owner cooldown query should use the owner fact cache")
assert(runtime.QueryCharges(101, owner) == chargeInfo,
    "owner charge query should return source payload")
assert(runtime.QueryCharges(101, owner) == chargeInfo,
    "duplicate owner charge query should use the owner fact cache")
assert(runtime.QueryDuration(101, owner) == durationObject,
    "owner cooldown DurationObject query should return source payload")
assert(runtime.QueryDuration(101, owner) == durationObject,
    "duplicate owner cooldown DurationObject query should use the owner fact cache")
assert(runtime.QueryChargeDuration(101, owner) == chargeDurationObject,
    "owner charge DurationObject query should return source payload")
assert(runtime.QueryChargeDuration(101, owner) == chargeDurationObject,
    "duplicate owner charge DurationObject query should use the owner fact cache")
assert(rawequal(runtime.QueryDisplayCount(101, owner), secretDisplayCount),
    "owner display-count query should forward secret source payload")
assert(rawequal(runtime.QueryDisplayCount(101, owner), secretDisplayCount),
    "duplicate owner secret display-count query should use the owner fact cache")
assert(rawequal(runtime.QuerySpellCount(101, owner), secretSpellCount),
    "owner spell-count query should forward secret source payload")
assert(rawequal(runtime.QuerySpellCount(101, owner), secretSpellCount),
    "duplicate owner secret spell-count query should use the owner fact cache")
assert(runtime.QueryCooldown(404, owner) == nil,
    "owner nil cooldown result should pass through")
assert(runtime.QueryCooldown(404, owner) == nil,
    "duplicate owner nil cooldown result should use the owner fact cache")
assert(runtime.QueryCharges(404, owner) == nil,
    "owner nil charge result should pass through")
assert(runtime.QueryCharges(404, owner) == nil,
    "duplicate owner nil charge result should use the owner fact cache")
runtime.EndRuntimeQueryBatch()

assert(owner._cdmRuntimeState and owner._cdmRuntimeState.queryCache,
    "owner runtime query facts should live on the owner runtime state table")
assert(cooldownCalls == 8,
    "owner cooldown facts should share one source read per spell in the batch")
assert(chargeCalls == 6,
    "owner charge facts should share one source read per spell in the batch")
assert(durationCalls == 3,
    "owner cooldown DurationObject facts should share one source read in the batch")
assert(chargeDurationCalls == 3,
    "owner charge DurationObject facts should share one source read in the batch")
assert(displayCountCalls == 3,
    "owner display-count facts should cache even secret payloads without comparing them")
assert(spellCountCalls == 3,
    "owner spell-count facts should cache even secret payloads without comparing them")

runtime.QueryCooldown(101)
assert(cooldownCalls == 9,
    "ending a batch should restore live cooldown reads")

runtime.BeginRuntimeQueryBatch()
assert(runtime.QueryOverrideSpell(101) == 202,
    "override queries should reuse the stable cache across batches")
runtime.EndRuntimeQueryBatch()
assert(overrideCalls == 1,
    "stable override cache should avoid repeat source reads across batches")

assert(type(runtime.ClearStableCaches) == "function",
    "runtime query cache should expose stable-cache invalidation")
runtime.ClearStableCaches()
runtime.BeginRuntimeQueryBatch()
assert(runtime.QueryOverrideSpell(101) == 202,
    "stable override cache should repopulate after invalidation")
runtime.EndRuntimeQueryBatch()
assert(overrideCalls == 2,
    "stable override invalidation should allow the next batch to refresh source data")

local nestedOwner = { _spellEntry = { viewerType = "essential", type = "spell", id = 101 } }
local cooldownCallsBeforeNested = cooldownCalls
runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101, nestedOwner)
runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101, nestedOwner)
runtime.EndRuntimeQueryBatch()
runtime.QueryCooldown(101, nestedOwner)
runtime.EndRuntimeQueryBatch()
assert(cooldownCalls == cooldownCallsBeforeNested + 1,
    "nested owner batches should share the owner fact cache until the final EndRuntimeQueryBatch")

runtime.ResetRuntimeQueryBatch()
local cooldownCallsBeforeNextBatches = cooldownCalls
local chargeCallsBeforeNextBatches = chargeCalls

runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101)
runtime.QueryCharges(101)
runtime.EndRuntimeQueryBatch()
assert(cooldownCalls == cooldownCallsBeforeNextBatches + 1,
    "first post-reset cooldown batch should query source")
assert(chargeCalls == chargeCallsBeforeNextBatches + 1,
    "first post-reset charge batch should query source")

runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101)
runtime.QueryCharges(101)
runtime.EndRuntimeQueryBatch()
assert(cooldownCalls == cooldownCallsBeforeNextBatches + 2,
    "cooldown activity should not be cached across runtime batches")
assert(chargeCalls == chargeCallsBeforeNextBatches + 2,
    "charge activity should not be cached across runtime batches")

runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101)
runtime.QueryCharges(101)
runtime.EndRuntimeQueryBatch()
assert(cooldownCalls == cooldownCallsBeforeNextBatches + 3,
    "third cooldown batch should still query fresh source data")
assert(chargeCalls == chargeCallsBeforeNextBatches + 3,
    "third charge batch should still query fresh source data")

print("OK: cdm_resolvers_runtime_query_cache_test")
