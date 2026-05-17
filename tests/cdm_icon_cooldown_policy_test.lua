-- tests/cdm_icon_cooldown_policy_test.lua
-- Run: lua tests/cdm_icon_cooldown_policy_test.lua

local ns = {}
assert(loadfile("modules/cdm/cdm_icon_cooldown_policy.lua"))("QUI", ns)

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
assert(queryCount == 1, "trusted GCD capture should query once per spell snapshot")

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
policy:UpdateIconChargeMirrorCycle(chargeIcon, "charge", 777)
assert(chargeIcon._lastChargeMirrorCooldownID == 42,
    "charge mode should remember the mirror cooldownID")
assert(chargeIcon._lastChargeMirrorCategory == "utility",
    "charge mode should remember the mirror category")
assert(chargeIcon._lastChargeRuntimeSpellID == 777,
    "charge mode should remember the runtime spellID")

mirrorStates["42:utility"] = { isActive = true }
policy:UpdateIconChargeMirrorCycle(chargeIcon, "inactive", 777)
assert(chargeIcon._lastChargeMirrorCooldownID == 42,
    "inactive mode should preserve charge memory while mirror remains active")

mirrorStates["42:utility"] = { isActive = false }
policy:UpdateIconChargeMirrorCycle(chargeIcon, "inactive", 777)
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
    state = { isActive = true },
}) == true, "matching active mirror payload should match the recent charge cycle")

print("OK: cdm_icon_cooldown_policy_test")
