-- tests/unit/cdm_icon_cooldown_policy_test.lua
-- Run: lua tests/unit/cdm_icon_cooldown_policy_test.lua

local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("modules/cdm/cdm_icon_renderer.lua", "cdm_icon_cooldown_policy.lua")("QUI", ns)

local policyModule = assert(ns.CDMIconCooldownPolicy, "CDMIconCooldownPolicy should be exported")

local cooldowns = {}
local queryCount = 0
local mirrorStates = {}

local policy = policyModule.Create({
    queryOverrideSpell = function(spellID)
        if spellID == 100 then
            return 200
        end
        return nil
    end,
    queryCooldown = function(spellID)
        queryCount = queryCount + 1
        return cooldowns[spellID]
    end,
    getMirror = function()
        return {
            GetStateByCooldownID = function(cooldownID, category)
                return mirrorStates[tostring(cooldownID) .. ":" .. tostring(category)]
            end,
        }
    end,
})

local icon = {
    _spellEntry = { spellID = 100 },
    _isOnGCD = false,
}
local secondIcon = {
    _spellEntry = { spellID = 100 },
}
local spellState = {}
cooldowns[200] = { isOnGCD = true }

assert(policy:CaptureTrustedGCDStateForIcon(icon, spellState, 10) == true,
    "first trusted GCD capture should report changed state")
assert(icon._isOnGCD == true, "trusted GCD capture should stamp the icon")
assert(icon._isOnGCDTrustedAt == 10, "trusted GCD capture should stamp the snapshot time")
assert(policy:CaptureTrustedGCDStateForIcon(secondIcon, spellState, 10) == true,
    "second icon should consume the shared trusted spell state")
assert(queryCount == 2, "trusted GCD capture should query base and override spell IDs once per snapshot")

local baseGCDOverrideCooldownIcon = {
    _spellEntry = { spellID = 100 },
}
spellState = {}
cooldowns[100] = { isOnGCD = true }
cooldowns[200] = { isOnGCD = false }
queryCount = 0

assert(policy:CaptureTrustedGCDStateForIcon(baseGCDOverrideCooldownIcon, spellState, 12) == true,
    "base spell GCD state should win when the override reports a separate cooldown")
assert(baseGCDOverrideCooldownIcon._isOnGCD == true,
    "trusted GCD capture should stamp true when any base/override candidate is on GCD")
assert(spellState[100] == true, "base spell GCD fact should be cached for resolver lookup")
assert(spellState[200] == false, "override non-GCD fact should also be cached")

local staleIcon = {
    _spellEntry = { spellID = 300 },
    _isOnGCD = true,
    _isOnGCDTrustedAt = 5,
}
cooldowns[300] = { isOnGCD = nil }
assert(policy:CaptureTrustedGCDStateForIcon(staleIcon, spellState, 11) == true,
    "unknown GCD state should clear stale trusted state")
assert(staleIcon._isOnGCD == nil, "unknown GCD state should clear icon flag")
assert(staleIcon._isOnGCDTrustedAt == nil, "unknown GCD state should clear trusted timestamp")

policy:MarkGCDSwipe(icon)
assert(icon._showingGCDSwipe == true, "MarkGCDSwipe should stamp GCD swipe state")
assert(icon._showingRealCooldownSwipe == nil, "MarkGCDSwipe should clear real cooldown swipe state")
policy:ClearGCDSwipe(icon)
assert(icon._showingGCDSwipe == nil, "ClearGCDSwipe should clear GCD swipe state")

local chargeIcon = {
    _blizzMirrorCooldownID = 42,
    _blizzMirrorCategory = "utility",
}
-- Resolver no longer emits mode=="charge"; charge spells now flow through
-- mode=="cooldown" with the entry-level hasCharges flag carrying the
-- "this is a charge spell" signal.
policy:UpdateIconChargeMirrorCycle(chargeIcon, "cooldown", 777, true)
assert(chargeIcon._lastChargeMirrorCooldownID == 42,
    "cooldown+hasCharges should remember the mirror cooldownID")
assert(chargeIcon._lastChargeMirrorCategory == "utility",
    "cooldown+hasCharges should remember the mirror category")
assert(chargeIcon._lastChargeRuntimeSpellID == 777,
    "cooldown+hasCharges should remember the runtime spellID")

-- Without the hasCharges flag, cooldown mode is treated as a plain cooldown
-- and the charge-cycle memory is left untouched.
local nonChargeIcon = {
    _blizzMirrorCooldownID = 99,
    _blizzMirrorCategory = "utility",
}
policy:UpdateIconChargeMirrorCycle(nonChargeIcon, "cooldown", 888, false)
assert(nonChargeIcon._lastChargeMirrorCooldownID == nil,
    "cooldown without hasCharges should not remember the mirror cooldownID")

-- Mirror "active" in the new model: aura attribution or totem ownership
-- is event-bound on the state. Any of childIsActive / auraInstanceID /
-- auraDurObj / totemDurObj / totemSlot signals an active state.
mirrorStates["42:utility"] = { auraInstanceID = 9999 }
policy:UpdateIconChargeMirrorCycle(chargeIcon, "inactive", 777, true)
assert(chargeIcon._lastChargeMirrorCooldownID == 42,
    "inactive mode should preserve charge memory while mirror remains active")

mirrorStates["42:utility"] = {}
policy:UpdateIconChargeMirrorCycle(chargeIcon, "inactive", 777, true)
assert(chargeIcon._lastChargeMirrorCooldownID == nil,
    "inactive mode should clear charge memory once mirror is inactive")

assert(policy:MirrorPayloadHasChargeState({
    state = { stackTextSource = "ChargeCount", stackTextShown = true },
}) == true, "charge-count mirror text should count as charge state")

chargeIcon._lastChargeMirrorCooldownID = 51
chargeIcon._lastChargeMirrorCategory = "essential"
assert(policy:MirrorPayloadMatchesRecentChargeCycle(chargeIcon, {
    cooldownID = 51,
    category = "essential",
    active = true,
    state = {},
}) == true, "matching active mirror payload should match the recent charge cycle")

print("OK: cdm_icon_cooldown_policy_test")
