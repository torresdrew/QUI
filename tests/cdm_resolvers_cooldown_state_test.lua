-- tests/cdm_resolvers_cooldown_state_test.lua
-- Run: lua tests/cdm_resolvers_cooldown_state_test.lua

local function noop() end

local inCombat = false
function InCombatLockdown() return inCombat end
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
local itemAuraDur = { token = "item-aura-dur" }
local secretItemStart = { token = "secret-item-start" }
local secretItemDuration = { token = "secret-item-duration" }
local secretChargeZero = { token = "secret-current-charges", value = 0 }
local secretChargeOne = { token = "secret-current-charges", value = 1 }
local now = 120
local createdDurationObjects = {}
local durationObjectSetCalls = {}

function GetTime() return now end

function issecretvalue(value)
    return value == secretChargeZero
        or value == secretChargeOne
        or value == secretItemStart
        or value == secretItemDuration
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

C_DurationUtil = {
    CreateDuration = function()
        local durObj = { token = "created-duration-" .. tostring(#createdDurationObjects + 1) }
        function durObj:SetTimeFromStart(startTime, duration)
            table.insert(durationObjectSetCalls, {
                object = self,
                start = startTime,
                duration = duration,
            })
        end
        table.insert(createdDurationObjects, durObj)
        return durObj
    end,
}

local states = {}
local itemAuraActive = true
local itemCooldownActive = false
local itemAuraDurationObjectAvailable = true
local itemRuntimeAuraInstanceActive = false
local itemRuntimeAuraDataAvailable = false
local itemRuntimeAuraDataExpiration = 165
local itemRuntimeAuraDataDuration = 45
local itemAuraScannedDuration = 30
local itemAuraScannedExpiration = 140
local directAuraQueriesAvailable = true
local capturedCooldownAuraActive = false
local itemSlotCooldownActive = false
local slotCooldownEnabled = true
local slotCooldownStart = 11418.804
local slotCooldownDuration = 90
local itemUseSpellCooldownActive = false
local itemUseSpellCooldownDur = { token = "item-use-spell-cooldown-dur" }
local chargeQueryCounts = {}

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
            chargeQueryCounts[spellID] = (chargeQueryCounts[spellID] or 0) + 1
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
            if spellID == 91004 and itemUseSpellCooldownActive then
                return { isActive = true, isOnGCD = false }
            end
            return nil
        end,
        QuerySpellCooldownDuration = function(spellID, ignoreGCD)
            if spellID == 70001 and ignoreGCD == false then
                return gcdDur
            end
            if spellID == 91004 and itemUseSpellCooldownActive then
                return itemUseSpellCooldownDur
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
        QueryItemSpell = function(itemID)
            if itemID == 90001 then
                return "Use Item Aura", 91001
            end
            if itemID == 90002 then
                return "Secret Item Use", 91002
            end
            if itemID == 90003 then
                return "Clean Item Use", 91003
            end
            if itemID == 90004 then
                return "Slot Item Use", 91004
            end
            return nil, nil
        end,
        QueryInventoryItemID = function(unit, slotID)
            if unit == "player" and slotID == 13 then
                return 90004
            end
            return nil
        end,
        QueryScannedItemAuraInfo = function(itemID, itemSpellID)
            if itemID == 90001 and itemSpellID == 91001 then
                if itemRuntimeAuraInstanceActive then
                    return {
                        active = true,
                        useSpellID = 91001,
                        auraInstanceID = 94001,
                        auraUnit = "player",
                    }
                end
                return {
                    active = itemAuraActive,
                    useSpellID = 91001,
                    buffSpellID = 92001,
                    duration = itemAuraScannedDuration,
                    expiration = itemAuraScannedExpiration,
                    name = "Related Item Aura",
                }
            end
            return nil
        end,
        QueryCooldownAuraBySpellID = function(spellID)
            if spellID == 91001 then
                return 92001
            end
            return nil
        end,
        QueryUnitAuraBySpellID = function(unit, spellID)
            if directAuraQueriesAvailable
               and unit == "player" and spellID == 92001 and itemAuraActive then
                return { auraInstanceID = 93001, spellId = 92001 }
            end
            return nil
        end,
        QueryPlayerAuraBySpellID = function(spellID)
            if directAuraQueriesAvailable and spellID == 92001 and itemAuraActive then
                return { auraInstanceID = 93001, spellId = 92001 }
            end
            return nil
        end,
        QueryAuraDataBySpellID = function(unit, spellID, filter)
            if directAuraQueriesAvailable
               and unit == "player" and spellID == 92001 and itemAuraActive then
                return { auraInstanceID = 93001, spellId = 92001 }
            end
            return nil
        end,
        QueryAuraDuration = function(unit, auraInstanceID)
            if unit == "player"
               and auraInstanceID == 93001
               and itemAuraActive
               and itemAuraDurationObjectAvailable then
                return itemAuraDur
            end
            if unit == "player"
               and auraInstanceID == 94001
               and itemRuntimeAuraInstanceActive
               and itemAuraDurationObjectAvailable then
                return itemAuraDur
            end
            return nil
        end,
        QueryAuraDataByAuraInstanceID = function(unit, auraInstanceID)
            if unit == "player"
               and auraInstanceID == 94001
               and itemRuntimeAuraInstanceActive
               and itemRuntimeAuraDataAvailable then
                return {
                    auraInstanceID = auraInstanceID,
                    expirationTime = itemRuntimeAuraDataExpiration,
                    duration = itemRuntimeAuraDataDuration,
                }
            end
            return nil
        end,
        QueryItemCooldown = function(itemID)
            if itemID == 90001 and itemCooldownActive then
                return 100, 60, 1
            end
            if itemID == 90002 then
                return secretItemStart, secretItemDuration, true
            end
            if itemID == 90003 then
                return 200, 90, 1
            end
            if itemID == 90004 and itemSlotCooldownActive then
                return 11418.804, 90, true
            end
            return nil, nil, nil
        end,
    },
    CDMSpellData = {
        GetCapturedAuraForLookup = function(spellIDs)
            if not capturedCooldownAuraActive then return nil end
            for _, spellID in ipairs(spellIDs or {}) do
                if spellID == 92001 then
                    return { auraInstanceID = 93001, unit = "player", spellID = 92001 }
                end
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

function GetInventoryItemCooldown(unit, slotID)
    if unit == "player" and slotID == 13 then
        return slotCooldownStart, slotCooldownDuration, slotCooldownEnabled
    end
    return nil, nil, nil
end

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

itemAuraActive = true
itemCooldownActive = false
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Related Aura",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura", "item entry should use scanned related aura while the buff is active")
assert(state.active == true, "item related aura should mark the cooldown state active")
assert(state.auraResolved == true, "item related aura should publish auraResolved for icon state stamping")
assert(state.auraActive == true, "item related aura should publish auraActive for icon state stamping")
assert(state.durObj == itemAuraDur, "item related aura should carry the aura DurationObject")
assert(state.resolvedAuraSpellID == 92001, "item related aura should publish the buff spell ID")
assert(state.isOnCooldown == false, "item related aura should not be treated as a real cooldown")

inCombat = true
directAuraQueriesAvailable = false
capturedCooldownAuraActive = true
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Captured Mapped Aura",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura",
    "item entry should use captured player aura mapped from item use spell in combat")
assert(state.durObj == itemAuraDur,
    "captured cooldown-aura mapping should carry the aura DurationObject")
assert(state.auraResolved == true,
    "captured cooldown-aura mapping should publish auraResolved for icon state stamping")
assert(state.auraActive == true,
    "captured cooldown-aura mapping should publish auraActive for icon state stamping")
assert(state.auraUnit == "player", "captured cooldown-aura mapping should keep the player unit")

inCombat = false
directAuraQueriesAvailable = true
capturedCooldownAuraActive = false

itemAuraActive = false
itemRuntimeAuraInstanceActive = true
itemCooldownActive = false
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Runtime Aura Instance",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura", "item entry should use runtime aura instance captured from UNIT_AURA")
assert(state.durObj == itemAuraDur, "runtime aura instance should carry the aura DurationObject")
assert(state.auraResolved == true, "runtime aura instance should publish auraResolved for icon state stamping")
assert(state.auraActive == true, "runtime aura instance should publish auraActive for icon state stamping")
assert(state.auraInstanceID == 94001, "runtime aura instance should publish auraInstanceID")

itemAuraActive = false
itemRuntimeAuraInstanceActive = true
itemRuntimeAuraDataAvailable = true
itemAuraDurationObjectAvailable = false
itemCooldownActive = true
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Runtime Aura Instance",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura", "runtime aura instance should fall back to clean AuraData timing")
assert(state.durObj == nil, "clean AuraData fallback should not invent a DurationObject")
assert(state.auraResolved == true, "clean AuraData fallback should publish auraResolved for icon state stamping")
assert(state.auraActive == true, "clean AuraData fallback should publish auraActive for icon state stamping")
assert(state.numericCooldownActive == true, "clean AuraData fallback should publish numeric timing")
assert(state.start == 120 and state.duration == 45,
    "clean AuraData fallback should carry start and duration")
assert(state.isOnCooldown == false,
    "clean AuraData fallback should suppress the underlying item cooldown")

itemAuraActive = true
itemRuntimeAuraInstanceActive = false
itemRuntimeAuraDataAvailable = false
itemAuraDurationObjectAvailable = false
itemCooldownActive = false
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Related Aura",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura", "item entry should keep aura mode from scanner timing without a DurationObject")
assert(state.durObj == nil, "scanner numeric aura fallback should not invent a DurationObject")
assert(state.auraResolved == true, "scanner numeric aura fallback should publish auraResolved for icon state stamping")
assert(state.auraActive == true, "scanner numeric aura fallback should publish auraActive for icon state stamping")
assert(state.numericCooldownActive == true, "scanner numeric aura fallback should publish clean timing")
assert(state.start == 110 and state.duration == 30, "scanner numeric aura fallback should carry start and duration")

itemAuraActive = true
itemRuntimeAuraInstanceActive = false
itemAuraDurationObjectAvailable = false
itemAuraScannedDuration = nil
itemAuraScannedExpiration = nil
itemCooldownActive = true
createdDurationObjects = {}
durationObjectSetCalls = {}
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Durationless Related Aura",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "aura",
    "active durationless item aura should suppress item cooldown fallback")
assert(state.durObj == nil, "durationless item aura should not publish a DurationObject")
assert(state.auraResolved == true, "durationless item aura should publish auraResolved for icon state stamping")
assert(state.auraActive == true, "durationless item aura should publish auraActive for icon state stamping")
assert(state.numericCooldownActive == nil,
    "durationless item aura should not publish numeric cooldown timing")
assert(state.hasRenderableCooldown == false,
    "durationless item aura should not render the underlying item cooldown")
assert(state.isOnCooldown == false,
    "durationless item aura should not be treated as a real cooldown")
assert(state.hideDurationText == true,
    "durationless item aura should hide duration text")
assert(#createdDurationObjects == 0,
    "durationless item aura should not create an item cooldown DurationObject")

itemAuraActive = false
itemAuraDurationObjectAvailable = true
itemAuraScannedDuration = 30
itemAuraScannedExpiration = 140
itemCooldownActive = true
createdDurationObjects = {}
durationObjectSetCalls = {}
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90001,
        itemID = 90001,
        name = "Item With Related Aura",
        viewerType = "custom",
    },
    runtimeSpellID = 91001,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "item-cooldown", "item entry should fall back to its item cooldown after the aura ends")
assert(state.isOnCooldown == true, "item cooldown fallback should publish cooldown activity")
assert(state.durObj == createdDurationObjects[1],
    "item cooldown fallback should use a DurationObject for cooldown frames")
assert(state.numericCooldownActive == true, "clean DurationObject item cooldown should retain numeric timing")
assert(state.start == 100 and state.duration == 60,
    "clean DurationObject item cooldown should carry timing for bar fills")
assert(durationObjectSetCalls[1].start == 100 and durationObjectSetCalls[1].duration == 60,
    "clean item cooldown should seed the DurationObject from raw item timing")

createdDurationObjects = {}
durationObjectSetCalls = {}
itemAuraActive = false
itemRuntimeAuraInstanceActive = false
itemCooldownActive = false
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90002,
        itemID = 90002,
        name = "Secret Item Cooldown",
        viewerType = "custom",
    },
    runtimeSpellID = 91002,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "item-cooldown", "secret item timing should still resolve as an item cooldown")
assert(state.isOnCooldown == true, "secret item DurationObject should publish cooldown activity")
assert(state.durObj == createdDurationObjects[1],
    "secret item timing should be passed through a DurationObject")
assert(state.numericCooldownActive == nil, "secret item timing must not publish numeric cooldown timing")
assert(state.start == nil and state.duration == nil, "secret item timing must not be exposed as SetCooldown timing")
assert(durationObjectSetCalls[1].start == secretItemStart
    and durationObjectSetCalls[1].duration == secretItemDuration,
    "secret item cooldown values should pass directly into DurationObject setup")

createdDurationObjects = {}
durationObjectSetCalls = {}
state = resolve({
    entry = {
        type = "item",
        kind = "cooldown",
        id = 90003,
        itemID = 90003,
        name = "Clean Item Cooldown",
        viewerType = "custom",
    },
    runtimeSpellID = 91003,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "item-cooldown", "clean item timing should resolve as an item cooldown")
assert(state.isOnCooldown == true, "clean item DurationObject should publish cooldown activity")
assert(state.durObj == createdDurationObjects[1], "clean item timing should prefer the DurationObject path")
assert(state.numericCooldownActive == true, "clean item timing should remain available to non-frame consumers")
assert(state.start == 200 and state.duration == 90, "clean item timing should be published on the state")
assert(durationObjectSetCalls[1].start == 200 and durationObjectSetCalls[1].duration == 90,
    "clean item cooldown should use raw start and duration for the DurationObject")

createdDurationObjects = {}
durationObjectSetCalls = {}
itemUseSpellCooldownActive = true
itemSlotCooldownActive = false
slotCooldownStart = 11418.804
slotCooldownDuration = 90
slotCooldownEnabled = true
state = resolve({
    entry = {
        type = "slot",
        kind = "cooldown",
        id = 13,
        name = "Slot Cooldown",
        viewerType = "custom",
    },
    runtimeSpellID = 91004,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "item-cooldown", "slot item cooldown with enabled=true should resolve as an item cooldown")
assert(state.isOnCooldown == true, "slot item cooldown with enabled=true should publish cooldown activity")
assert(state.durObj == createdDurationObjects[1], "slot item cooldown should use a DurationObject")
assert(state.durObj ~= itemUseSpellCooldownDur,
    "slot item cooldown should prefer real slot timing over the item-use spell cooldown")
assert(state.sourceID == "item-duration:13:90004",
    "slot item cooldown should identify the real item duration source")
assert(state.numericCooldownActive == true, "slot item cooldown should publish clean numeric timing")
assert(state.start == 11418.804 and state.duration == 90,
    "slot item cooldown should carry timing for custom bars")
assert(durationObjectSetCalls[1].start == 11418.804 and durationObjectSetCalls[1].duration == 90,
    "slot item cooldown should seed the DurationObject from slot timing")

createdDurationObjects = {}
durationObjectSetCalls = {}
itemSlotCooldownActive = true
slotCooldownStart = 0
slotCooldownDuration = 0
slotCooldownEnabled = true
state = resolve({
    entry = {
        type = "slot",
        kind = "cooldown",
        id = 13,
        name = "Slot Item Cooldown Fallback",
        viewerType = "custom",
    },
    runtimeSpellID = 91004,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "item-cooldown",
    "slot item cooldown should fall back to item timing when slot timing is inactive")
assert(state.isOnCooldown == true, "slot item cooldown fallback should publish cooldown activity")
assert(state.durObj == createdDurationObjects[1], "slot item cooldown fallback should use a DurationObject")
assert(state.durObj ~= itemUseSpellCooldownDur,
    "slot item cooldown fallback should prefer real item timing over the item-use spell cooldown")
assert(state.sourceID == "item-duration:13:90004",
    "slot item cooldown fallback should identify the real item duration source")
assert(state.numericCooldownActive == true, "slot item cooldown fallback should publish clean numeric timing")
assert(state.start == 11418.804 and state.duration == 90,
    "slot item cooldown fallback should carry item timing for custom bars")

createdDurationObjects = {}
durationObjectSetCalls = {}
itemSlotCooldownActive = false
slotCooldownStart = 11418.804
slotCooldownDuration = 90
slotCooldownEnabled = false
itemUseSpellCooldownActive = false
state = resolve({
    entry = {
        type = "slot",
        kind = "cooldown",
        id = 13,
        name = "Disabled Slot Cooldown",
        viewerType = "custom",
    },
    runtimeSpellID = 91004,
    containerKey = "custom",
    useBuffSwipe = true,
    showGCDSwipe = true,
})

assert(state.mode == "inactive", "slot item cooldown with enabled=false should resolve inactive")

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

inCombat = true
local unknownChargeQueries = chargeQueryCounts[80001] or 0
state = resolve({
    entry = cooldownEntry(80001),
    runtimeSpellID = 80001,
    containerKey = "essential",
    useBuffSwipe = false,
})
assert((chargeQueryCounts[80001] or 0) == unknownChargeQueries,
    "combat cooldown resolution should not probe charge state for unknown non-charge spells")
inCombat = false

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
