-- tests/cdm_resolvers_cooldown_state_test.lua
-- Run: lua tests/cdm_resolvers_cooldown_state_test.lua

local function noop() end

function InCombatLockdown() return false end
function geterrorhandler() return function(err) error(err) end end
function CreateFrame()
    return {
        RegisterEvent = noop,
        RegisterUnitEvent = noop,
        SetScript = noop,
    }
end

local auraDur = { token = "aura-dur" }
local cooldownDur = { token = "cooldown-dur" }
local chargeDur = { token = "charge-dur" }
local gcdDur = { token = "gcd-dur" }
local secretChargeZero = { token = "secret-current-charges", value = 0 }
local secretChargeOne = { token = "secret-current-charges", value = 1 }

function issecretvalue(value)
    return value == secretChargeZero or value == secretChargeOne
end

Enum = { LuaCurveType = { Step = "Step" } }
C_CurveUtil = {
    CreateCurve = function()
        return {
            SetType = noop,
            AddPoint = noop,
            Evaluate = function(_, value)
                if value == secretChargeZero then return 1 end
                if value == secretChargeOne then return 0 end
                error("unexpected curve input")
            end,
        }
    end,
}

local states = {}

local function putState(cooldownID, category, state)
    state.cooldownID = cooldownID
    state.viewerCategory = category
    states[category .. ":" .. cooldownID] = state
end

putState(50001, "essential", {
    isActive = true,
    mirrorEpoch = 1,
    spellID = 50001,
    overrideSpellID = 50001,
    durObj = auraDur,
    durObjSource = "aura-duration",
    resolvedMode = "aura",
    auraInstanceID = 9001,
    auraUnit = "player",
    hasAura = true,
    selfAura = true,
    stackText = "3",
    stackTextSource = "Applications",
    stackTextShown = true,
    auraDurObj = auraDur,
    auraDurObjSource = "aura-duration",
    cooldownDurObj = cooldownDur,
    cooldownDurObjSource = "cooldown-frame",
})

putState(50002, "essential", {
    isActive = true,
    mirrorEpoch = 2,
    spellID = 50002,
    overrideSpellID = 50002,
    durObj = cooldownDur,
    durObjSource = "cooldown-frame",
    resolvedMode = "cooldown",
})

local ns = {
    Helpers = {},
    CDMSources = {
        QuerySpellCharges = function(spellID)
            if spellID == 60001 then
                return { maxCharges = 2, isActive = true }
            end
            if spellID == 60002 then
                return { currentCharges = secretChargeOne, maxCharges = 2, isActive = true }
            end
            if spellID == 60003 then
                return { currentCharges = secretChargeZero, maxCharges = 2, isActive = true }
            end
            if spellID == 60004 then
                return { currentCharges = secretChargeZero, maxCharges = 2, isActive = true }
            end
            if spellID == 60005 then
                return { currentCharges = secretChargeOne, maxCharges = 2, isActive = true }
            end
            return nil
        end,
        QuerySpellChargeDuration = function(spellID)
            if spellID == 60001 then return chargeDur end
            if spellID == 60002 then return chargeDur end
            if spellID == 60003 then return chargeDur end
            if spellID == 60004 then return chargeDur end
            if spellID == 60005 then return chargeDur end
            return nil
        end,
        QuerySpellCooldown = function(spellID)
            if spellID == 60002 then
                return { isActive = false, isOnGCD = false }
            end
            if spellID == 60003 or spellID == 60004 then
                return { isActive = true, isOnGCD = false }
            end
            if spellID == 60005 then
                return { isActive = true, isOnGCD = false }
            end
            if spellID == 70001 then
                return { isActive = true, isOnGCD = true }
            end
            return nil
        end,
        QuerySpellCooldownDuration = function(spellID, ignoreGCD)
            if spellID == 70001 and ignoreGCD == false then
                return gcdDur
            end
            return nil
        end,
        QuerySpellUsable = function(spellID)
            if spellID == 60002 then
                return true
            elseif spellID == 60003 then
                return false
            elseif spellID == 60004 then
                return true
            elseif spellID == 60005 then
                return true
            end
            return nil
        end,
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID, category)
            return states[tostring(category) .. ":" .. tostring(cooldownID)]
        end,
        HasChildForCooldownID = function(cooldownID, category)
            return states[tostring(category) .. ":" .. tostring(cooldownID)] ~= nil
        end,
        GetDirectCooldownIDForViewer = function() return nil end,
        GetCooldownIDForViewer = function() return nil end,
    },
}

assert(loadfile("modules/cdm/cdm_runtime_queries.lua"))("QUI", ns)
assert(loadfile("modules/cdm/cdm_resolvers.lua"))("QUI", ns)

local resolvers = assert(ns.CDMResolvers, "CDMResolvers should be exported")
local resolve = assert(resolvers.ResolveCooldownState, "ResolveCooldownState should be exported")

local function cooldownEntry(spellID)
    return {
        type = "spell",
        kind = "cooldown",
        id = spellID,
        spellID = spellID,
        viewerType = "essential",
    }
end

local state = resolve({
    entry = cooldownEntry(50001),
    runtimeSpellID = 50001,
    mirrorCooldownID = 50001,
    mirrorCategory = "essential",
    containerKey = "essential",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura", "mirror aura lane should resolve as aura")
assert(state.active == true, "mirror aura lane should be active")
assert(state.isActive == true, "isActive alias should match active")
assert(state.isAuraMode == true, "aura lane should publish isAuraMode")
assert(state.isRealCooldownMode == false, "aura lane should not publish real cooldown mode")
assert(state.hasDurationObject == true, "aura lane should report its DurationObject")
assert(state.hasRenderableCooldown == true, "aura lane should report renderable swipe state")
assert(state.auraActive == true, "mirror aura lane should mark the aura active")
assert(state.auraIsActive == true, "auraIsActive alias should match auraActive")
assert(state.durObj == auraDur, "mirror aura lane should carry aura DurationObject")
assert(state.sourceID == "mirror:50001:1", "source should identify mirror cooldown and epoch")
assert(state.mirrorBacked == true, "mirror lane should mark mirrorBacked")
assert(state.mirrorCooldownID == 50001, "mirror cooldown ID should be copied")
assert(state.mirrorCategory == "essential", "mirror category should be copied")
assert(state.auraInstanceID == 9001, "aura instance should be copied")
assert(state.auraUnit == "player", "aura unit should be copied")
assert(state.countSinkText == "3", "mirror count sink text should be copied")
assert(state.countValue == 3, "mirror count numeric value should be copied when readable")
assert(state.countShown == true, "mirror count visibility should be copied")
assert(state.countSource == "Applications", "mirror count source should be copied")
assert(state.countMirrorBacked == true, "mirror count should be marked mirror-backed")

state = resolve({
    entry = cooldownEntry(50001),
    runtimeSpellID = 50001,
    mirrorCooldownID = 50001,
    mirrorCategory = "essential",
    containerKey = "essential",
    useBuffSwipe = false,
    skipAuraPhase = true,
})

assert(state.mode == "cooldown", "skip aura phase should select cooldown lane")
assert(state.durObj == cooldownDur, "skip aura phase should carry cooldown DurationObject")
assert(state.mirrorBacked == true, "cooldown phase should preserve mirror backing")
assert(state.auraActive == true, "cooldown phase should preserve active aura facts")
assert(state.isRealCooldownMode == true, "cooldown phase should publish real cooldown mode")
assert(state.hasRenderableCooldown == true, "cooldown phase should report renderable swipe state")

state = resolve({
    entry = {
        type = "spell",
        kind = "cooldown",
        id = 60001,
        spellID = 60001,
        viewerType = "essential",
        hasCharges = true,
    },
    runtimeSpellID = 60001,
    containerKey = "essential",
    useBuffSwipe = false,
})

assert(state.mode == "charge", "live recharge should resolve as charge")
assert(state.active == true, "live recharge should be active")
assert(state.durObj == chargeDur, "live recharge should carry charge DurationObject")
assert(state.sourceID == "60001:0", "charge source should identify spell and serial")
assert(state.mirrorBacked == nil, "live recharge without mirror should not be mirror-backed")
assert(state.hasCharges == true, "charge mode should publish hasCharges")
assert(state.isRealCooldownMode == true, "charge mode should publish real cooldown mode")
assert(state.hasDurationObject == true, "charge mode should report its DurationObject")

state = resolve({
    entry = {
        type = "spell",
        kind = "cooldown",
        id = 60002,
        spellID = 60002,
        viewerType = "essential",
        hasCharges = true,
    },
    runtimeSpellID = 60002,
    containerKey = "essential",
    useBuffSwipe = false,
})

assert(state.mode == "charge", "usable live recharge should resolve as charge")
assert(state.rechargeActive == true, "usable live recharge should publish rechargeActive")
assert(state.isOnCooldown == false, "usable live recharge with charges remaining should not be treated as unavailable")
assert(state.hasChargesRemaining == true,
    "usable live recharge should publish hasChargesRemaining for desaturation and visibility policy")

state = resolve({
    entry = {
        type = "spell",
        kind = "cooldown",
        id = 60003,
        spellID = 60003,
        viewerType = "essential",
        hasCharges = true,
    },
    runtimeSpellID = 60003,
    containerKey = "essential",
    useBuffSwipe = false,
})

assert(state.mode == "charge", "zero-charge live recharge should still resolve as charge")
assert(state.rechargeActive == true, "zero-charge live recharge should publish rechargeActive")
assert(state.isOnCooldown == true,
    "unusable live recharge must be treated as unavailable without reading currentCharges")
assert(state.hasChargesRemaining == false,
    "zero-charge live recharge must not publish hasChargesRemaining")

state = resolve({
    entry = {
        type = "spell",
        kind = "cooldown",
        id = 60004,
        spellID = 60004,
        viewerType = "essential",
        hasCharges = true,
    },
    runtimeSpellID = 60004,
    containerKey = "essential",
    useBuffSwipe = false,
})

assert(state.mode == "charge", "active cooldown with a secret charge count should stay in charge mode")
assert(state.rechargeActive == true, "active cooldown with a secret charge count should keep the recharge swipe")
assert(state.isOnCooldown == true,
    "active cooldown should mark the charged spell unavailable even when the usable boolean is true")
assert(state.hasChargesRemaining == false,
    "active cooldown should not publish hasChargesRemaining when charge count is secret")

state = resolve({
    entry = {
        type = "spell",
        kind = "cooldown",
        id = 60005,
        spellID = 60005,
        viewerType = "essential",
        hasCharges = true,
    },
    runtimeSpellID = 60005,
    containerKey = "essential",
    useBuffSwipe = false,
})

assert(state.mode == "charge", "active cooldown with one secret charge should stay in charge mode")
assert(state.rechargeActive == true, "active cooldown with one secret charge should keep the recharge swipe")
assert(state.isOnCooldown == false,
    "one-charge live recharge should decode currentCharges to a Lua-safe available state")
assert(state.hasChargesRemaining == true,
    "one-charge live recharge should publish hasChargesRemaining even while the cooldown API is active")

state = resolve({
    entry = cooldownEntry(70001),
    runtimeSpellID = 70001,
    containerKey = "essential",
    useBuffSwipe = false,
    showGCDSwipe = true,
})

assert(state.mode == "gcd-only", "GCD-only state should resolve as gcd-only")
assert(state.active == true, "GCD-only state should be active")
assert(state.durObj == gcdDur, "GCD-only state should carry GCD DurationObject")
assert(state.sourceID == 70001, "GCD-only source should identify the spell")
assert(state.gcdOnly == true, "GCD-only state should publish gcdOnly")
assert(state.isGCDOnly == true, "GCD-only state should publish isGCDOnly")
assert(state.isRealCooldownMode == false, "GCD-only state should not publish real cooldown mode")

state = resolve({
    entry = cooldownEntry(80001),
    runtimeSpellID = 80001,
    containerKey = "essential",
    useBuffSwipe = false,
})

assert(state.mode == "inactive", "missing runtime facts should resolve inactive")
assert(state.active == false, "inactive state should not be active")
assert(state.durObj == nil, "inactive state should not carry a DurationObject")
assert(state.mirrorBacked == nil, "inactive state should not be mirror-backed")
assert(state.hasDurationObject == false, "inactive state should not report a DurationObject")
assert(state.hasRenderableCooldown == false, "inactive state should not report renderable swipe state")

state = resolvers.NormalizeResolvedCooldownStateContract({
    mode = "unknown",
    active = true,
    isOnCooldown = "truthy",
    rechargeActive = nil,
})
assert(state.mode == "inactive", "contract normalization should reject unknown modes")
assert(state.active == false and state.isActive == false,
    "contract normalization should clear active aliases for inactive states")
assert(state.isOnCooldown == false, "contract normalization should coerce cooldown flags")

print("OK: cdm_resolvers_cooldown_state_test")
