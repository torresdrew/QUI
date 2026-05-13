-- tests/cdm_aura_priority_integration_test.lua
-- Run: lua tests/cdm_aura_priority_integration_test.lua
--
-- Locks the swipe-priority contract end-to-end across mirror lane selection
-- and resolver payload classification:
--
--     aura entries:     aura > charge/recharge > cd > gcd
--     cooldown entries: aura > charge/recharge > cd > gcd by default,
--                       charge/recharge > cd > gcd when
--                       Show Buff/Debuff Phase on Cooldown Icons is off.
--
-- Regression coverage for cooldown entries that also have a player aura up.
-- The aura lane is still mirrored for stack/active state, but cooldown-kind
-- icons can be configured to skip the aura DurationObject as their swipe.
-- The fix lives at two layers:
--
--   1. cdm_blizz_mirror.lua's SelectDurationForState keeps aura-first mirror
--      state and SetDurationLane(gcd) no longer wipes the cooldown lane.
--      Verified end-to-end in cdm_blizz_mirror_duration_test.lua.
--   2. cdm_resolvers.lua's ResolveMirrorRenderPayloadForEntry passes the
--      mirror's selected mode through to the icon factory.  Verified here.
--
-- Failure mode this test catches: when the new option is disabled, a cooldown
-- entry still selects the aura lane ahead of recharge/cooldown, causing the
-- icon to render the buff/debuff duration phase instead of the actual charge
-- or cooldown phase.

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
local chargeDur = { token = "charge-dur" }
local cooldownDur = { token = "cooldown-dur" }
local gcdDur = { token = "gcd-dur" }

-- Mirror states keyed by (cooldownID, category).  Each state mirrors what
-- cdm_blizz_mirror.lua's SelectDurationForState would produce after a real
-- sequence of Cooldown:SetCooldownFromDurationObject calls.  durObj /
-- durObjSource / resolvedMode are set as if RefreshSelectedDurationState
-- ran on tail of the last write — the resolver consumes those fields.
local states = {}

local function makeState(cooldownID, category, lanes, selected)
    states[category .. ":" .. cooldownID] = {
        cooldownID = cooldownID,
        viewerCategory = category,
        isActive = true,
        mirrorEpoch = 1,
        auraDurObj = lanes.aura,
        auraDurObjSource = lanes.aura and "aura-duration" or nil,
        cooldownDurObj = lanes.cooldown,
        cooldownDurObjSource = lanes.cooldown and "cooldown-frame" or nil,
        resourceDurObj = lanes.resource,
        resourceDurObjSource = lanes.resource and "spell-charge" or nil,
        gcdDurObj = lanes.gcd,
        gcdDurObjSource = lanes.gcd and "gcd-duration" or nil,
        durObj = selected.durObj,
        durObjSource = selected.durObjSource,
        resolvedMode = selected.resolvedMode,
    }
end

-- Scenario A: aura up + cooldown running on a non-aura cooldown entry.
-- Mirror's SelectDurationForState picks aura; the resolver can override it
-- when the cooldown-icon aura phase option is off.
makeState(50001, "essential",
    { aura = auraDur, cooldown = cooldownDur },
    { durObj = auraDur, durObjSource = "aura-duration", resolvedMode = "aura" })

-- Scenario B: aura up + recharge + cooldown.
makeState(50002, "essential",
    { aura = auraDur, resource = chargeDur, cooldown = cooldownDur },
    { durObj = auraDur, durObjSource = "aura-duration", resolvedMode = "aura" })

-- Scenario C: recharge + cooldown, no aura.  Recharge wins over cooldown.
makeState(50003, "essential",
    { resource = chargeDur, cooldown = cooldownDur },
    { durObj = chargeDur, durObjSource = "spell-charge", resolvedMode = "charge" })

-- Scenario D: cooldown + gcd, no aura, no charge.  Real CD wins over GCD.
makeState(50004, "essential",
    { cooldown = cooldownDur, gcd = gcdDur },
    { durObj = cooldownDur, durObjSource = "cooldown-frame", resolvedMode = "cooldown" })

-- Scenario E: gcd only, no other lanes.  GCD is the floor.
makeState(50005, "essential",
    { gcd = gcdDur },
    { durObj = gcdDur, durObjSource = "gcd-duration", resolvedMode = "gcd-only" })

-- Scenario F: aura-viewer entry with aura lane populated.  Aura mode is
-- the only mode an aura-viewer can select; this proves the resolver does
-- not downgrade aura-viewer payloads to cooldown when no cooldownDur is
-- present.
makeState(50006, "buff",
    { aura = auraDur },
    { durObj = auraDur, durObjSource = "aura-duration", resolvedMode = "aura" })

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        SafeValue = function(v) return v end,
    },
    CDMSources = {
        QueryMirroredCooldownState = function() return nil end,
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID, category)
            return states[tostring(category) .. ":" .. tostring(cooldownID)]
        end,
        HasChildForCooldownID = function(cooldownID, category)
            return states[tostring(category) .. ":" .. tostring(cooldownID)] ~= nil
        end,
        GetCooldownIDForViewer = function() return nil end,
        GetDirectCooldownIDForViewer = function() return nil end,
    },
}

assert(loadfile("modules/cdm/cdm_resolvers.lua"))("QUI", ns)

local resolvers = assert(ns.CDMResolvers, "CDMResolvers not exported")
local resolveMirror = assert(resolvers.ResolveMirrorRenderPayloadForEntry,
    "ResolveMirrorRenderPayloadForEntry not exported")

local function entry(spellID)
    return {
        id = spellID,
        spellID = spellID,
        type = "spell",
        kind = "cooldown",
        viewerType = "essential",
    }
end

-- Scenario A: default keeps aura phase for cooldown entries
local payload = resolveMirror(entry(50001), 50001, "essential", 50001)
assert(payload, "scenario A: aura+cooldown state should produce a mirror payload")
assert(payload.mode == "aura",
    "scenario A: cooldown entry with aura up should resolve to aura mode by default (got " .. tostring(payload.mode) .. ")")
assert(payload.durObj == auraDur,
    "scenario A: cooldown entry with aura up should carry the aura DurationObject by default")
assert(payload.active == true, "scenario A: payload should be active")

-- Scenario B: mirror payload keeps aura phase by default when recharge exists
payload = resolveMirror(entry(50002), 50002, "essential", 50002)
assert(payload, "scenario B: aura+charge+cooldown state should produce a mirror payload")
assert(payload.mode == "aura",
    "scenario B: cooldown entry with aura up + recharge should resolve to aura mode by default (got " .. tostring(payload.mode) .. ")")
assert(payload.durObj == auraDur,
    "scenario B: cooldown entry with aura up + recharge should carry the aura DurationObject by default")

-- Scenario C: charge > cooldown
payload = resolveMirror(entry(50003), 50003, "essential", 50003)
assert(payload, "scenario C: charge+cooldown state should produce a mirror payload")
assert(payload.mode == "charge",
    "scenario C: cooldown entry with recharge should resolve to charge mode (got " .. tostring(payload.mode) .. ")")
assert(payload.durObj == chargeDur,
    "scenario C: cooldown entry with recharge should carry the charge DurationObject")

-- Scenario D: cooldown > gcd
payload = resolveMirror(entry(50004), 50004, "essential", 50004)
assert(payload, "scenario D: cooldown+gcd state should produce a mirror payload")
assert(payload.mode == "cooldown",
    "scenario D: cooldown entry with real CD + transient GCD should resolve to cooldown mode (got " .. tostring(payload.mode) .. ")")
assert(payload.durObj == cooldownDur,
    "scenario D: cooldown entry with real CD + transient GCD should carry the cooldown DurationObject")

-- Scenario E: gcd-only floor
payload = resolveMirror(entry(50005), 50005, "essential", 50005)
assert(payload, "scenario E: gcd-only state should produce a mirror payload")
assert(payload.mode == "gcd-only",
    "scenario E: cooldown entry with only GCD should resolve to gcd-only mode (got " .. tostring(payload.mode) .. ")")
assert(payload.durObj == gcdDur,
    "scenario E: cooldown entry with only GCD should carry the GCD DurationObject")

-- Scenario F: aura-viewer entry with aura lane populated
local auraEntry = {
    id = 50006,
    spellID = 50006,
    type = "spell",
    kind = "aura",
    viewerType = "buff",
}
payload = resolveMirror(auraEntry, 50006, "buff", 50006)
assert(payload, "scenario F: aura-viewer state should produce a mirror payload")
assert(payload.mode == "aura",
    "scenario F: aura-viewer entry with aura lane should resolve to aura mode (got " .. tostring(payload.mode) .. ")")
assert(payload.durObj == auraDur,
    "scenario F: aura-viewer entry should carry the aura DurationObject")

local showCooldownIconAuraPhase = true
resolvers._FinalizeImports({
    ShouldSkipAuraPhaseForCooldownIcon = function(_, e)
        return e and e.kind == "cooldown" and showCooldownIconAuraPhase == false
    end,
    ApplyAuraStateToIcon = function()
        return nil, false, nil
    end,
    IsGCDSwipeEnabled = function()
        return false
    end,
})

local function resolveIcon(spellID)
    return resolvers.ResolveIconDurationObject({
        _spellEntry = entry(spellID),
        _blizzMirrorCooldownID = spellID,
        _blizzMirrorCategory = "essential",
    })
end

-- Default-on option: cooldown icons keep the buff/debuff phase.
local durObj, mode = resolveIcon(50001)
assert(mode == "aura",
    "default option state should keep cooldown icons on aura phase (got " .. tostring(mode) .. ")")
assert(durObj == auraDur,
    "default option state should keep the aura DurationObject")

-- Option disabled: cooldown icons skip aura and use cooldown/recharge phase.
showCooldownIconAuraPhase = false
durObj, mode = resolveIcon(50001)
assert(mode == "cooldown",
    "disabled cooldown-icon aura phase should resolve aura+cooldown to cooldown mode (got " .. tostring(mode) .. ")")
assert(durObj == cooldownDur,
    "disabled cooldown-icon aura phase should carry the cooldown DurationObject")

durObj, mode = resolveIcon(50002)
assert(mode == "charge",
    "disabled cooldown-icon aura phase should resolve aura+charge+cooldown to charge mode (got " .. tostring(mode) .. ")")
assert(durObj == chargeDur,
    "disabled cooldown-icon aura phase should carry the charge DurationObject")

print("OK: cdm_aura_priority_integration_test")
