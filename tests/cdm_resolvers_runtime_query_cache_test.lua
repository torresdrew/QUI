-- tests/cdm_resolvers_runtime_query_cache_test.lua
-- Run: lua tests/cdm_resolvers_runtime_query_cache_test.lua

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

local cooldownInfo = { isActive = true }
local chargeInfo = { currentCharges = 1, maxCharges = 2, isActive = true }
local durationObject = { token = "cooldown-duration" }
local chargeDurationObject = { token = "charge-duration" }

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
    },
}

assert(loadfile("modules/cdm/cdm_runtime_queries.lua"))("QUI", ns)

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
    "batched cooldown query should return source payload")
assert(runtime.QueryCooldown(101) == cooldownInfo,
    "duplicate batched cooldown query should return cached payload")
assert(runtime.QueryCharges(101) == chargeInfo,
    "batched charge query should return source payload")
assert(runtime.QueryCharges(101) == chargeInfo,
    "duplicate batched charge query should return cached payload")
assert(runtime.QueryDuration(101) == durationObject,
    "batched cooldown DurationObject query should return source payload")
assert(runtime.QueryDuration(101) == durationObject,
    "duplicate batched cooldown DurationObject query should return cached payload")
assert(runtime.QueryChargeDuration(101) == chargeDurationObject,
    "batched charge DurationObject query should return source payload")
assert(runtime.QueryChargeDuration(101) == chargeDurationObject,
    "duplicate batched charge DurationObject query should return cached payload")
assert(runtime.QueryOverrideSpell(101) == 202,
    "batched override query should return source payload")
assert(runtime.QueryOverrideSpell(101) == 202,
    "duplicate batched override query should return cached payload")

assert(runtime.QueryCooldown(404) == nil,
    "batched nil cooldown result should pass through")
assert(runtime.QueryCooldown(404) == nil,
    "batched nil cooldown result should be cached")
assert(runtime.QueryCharges(404) == nil,
    "batched nil charge result should pass through")
assert(runtime.QueryCharges(404) == nil,
    "batched nil charge result should be cached")
runtime.EndRuntimeQueryBatch()

assert(cooldownCalls == 4,
    "one cached hit and one cached nil should each query cooldown source once inside the batch")
assert(chargeCalls == 2,
    "one cached hit and one cached nil should each query charge source once inside the batch")
assert(durationCalls == 1,
    "duplicate cooldown DurationObject queries should share one source call")
assert(chargeDurationCalls == 1,
    "duplicate charge DurationObject queries should share one source call")
assert(overrideCalls == 1,
    "duplicate override queries should share one source call")

runtime.QueryCooldown(101)
assert(cooldownCalls == 5,
    "ending a batch should restore live cooldown reads")

runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101)
runtime.BeginRuntimeQueryBatch()
runtime.QueryCooldown(101)
runtime.EndRuntimeQueryBatch()
runtime.QueryCooldown(101)
runtime.EndRuntimeQueryBatch()
assert(cooldownCalls == 6,
    "nested batches should share the outer cache until the final EndRuntimeQueryBatch")

print("OK: cdm_resolvers_runtime_query_cache_test")
