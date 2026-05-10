-- tests/cdm_blizz_mirror_duration_test.lua
-- Run: lua tests/cdm_blizz_mirror_duration_test.lua

local function noop() end

local hooks = {}
function hooksecurefunc(owner, method, hook)
    hooks[#hooks + 1] = { owner = owner, method = method, hook = hook }
    local original = owner[method] or noop
    owner[method] = function(self, ...)
        original(self, ...)
        hook(self, ...)
    end
end

function InCombatLockdown() return false end
function GetTime() return 123 end
function wipe(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end
function CreateFrame()
    return {
        RegisterEvent = noop,
        RegisterUnitEvent = noop,
        SetScript = noop,
    }
end

local cooldownDuration = { token = "cooldown-duration-object" }
local chargeDuration = { token = "charge-duration-object" }
local auraSpellCooldownDuration = { token = "aura-spell-cooldown-duration-object" }

C_Spell = {
    GetSpellCooldownDuration = function(spellID, ignoreGCD)
        if spellID == 1233448 and ignoreGCD == true then
            return cooldownDuration
        end
        if spellID == 1242998 and ignoreGCD == true then
            return auraSpellCooldownDuration
        end
    end,
    GetSpellChargeDuration = function(spellID)
        if spellID == 444347 then
            return chargeDuration
        end
    end,
}

local child = {
    cooldownID = 27902,
    isActive = true,
    Cooldown = {
        SetCooldown = noop,
        SetCooldownFromDurationObject = noop,
        SetCooldownFromExpirationTime = noop,
        SetCooldownDuration = noop,
        SetCooldownUNIX = noop,
        Clear = noop,
    },
    Show = noop,
    Hide = noop,
}
child.Cooldown.GetParent = function() return child end

local auraChild = {
    cooldownID = 73542,
    isActive = true,
    Cooldown = {
        SetCooldown = noop,
        SetCooldownFromDurationObject = noop,
        SetCooldownFromExpirationTime = noop,
        SetCooldownDuration = noop,
        SetCooldownUNIX = noop,
        Clear = noop,
    },
    Show = noop,
    Hide = noop,
}
auraChild.Cooldown.GetParent = function() return auraChild end

EssentialCooldownViewer = {
    GetChildren = function()
        return child
    end,
}
UtilityCooldownViewer = { GetChildren = function() end }
BuffIconCooldownViewer = {
    GetChildren = function()
        return auraChild
    end,
}
BuffBarCooldownViewer = { GetChildren = function() end }

C_CooldownViewer = {
    GetCooldownViewerCategorySet = function(category)
        if category == 0 then
            return { 27902 }
        end
        if category == 2 then
            return { 73542 }
        end
        return {}
    end,
    GetCooldownViewerCooldownInfo = function(cooldownID)
        if cooldownID == 27902 then
            return {
                cooldownID = 27902,
                spellID = 1233448,
                overrideSpellID = 1233448,
                overrideTooltipSpellID = nil,
                linkedSpellIDs = { 1235391 },
                selfAura = true,
                hasAura = true,
                charges = false,
                isKnown = true,
            }
        end
        if cooldownID == 73542 then
            return {
                cooldownID = 73542,
                spellID = 137007,
                overrideSpellID = 137007,
                overrideTooltipSpellID = 1242998,
                linkedSpellIDs = { 1242998 },
                selfAura = true,
                hasAura = false,
                charges = false,
                isKnown = true,
            }
        end
    end,
}

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
    },
}

assert(loadfile("modules/cdm/cdm_sources.lua"))("QUI", ns)
assert(loadfile("modules/cdm/cdm_blizz_mirror.lua"))("QUI", ns)

ns.CDMBlizzMirror.ForceRescan()
child.Cooldown:SetCooldown()

local state = assert(ns.CDMBlizzMirror.GetStateByCooldownID(27902), "mirror state missing")
assert(state.isActive == true, "SetCooldown should mark the mirror active")
assert(state.durObj == cooldownDuration, "SetCooldown should derive a safe spell cooldown DurationObject")

auraChild.Cooldown:SetCooldown()

local auraState = assert(ns.CDMBlizzMirror.GetStateByCooldownID(73542), "aura mirror state missing")
assert(auraState.isActive == true, "aura SetCooldown should mark the mirror active")
assert(auraState.durObj == nil, "aura viewer entries must not derive spell cooldown DurationObjects")
assert(auraState.durObjSource == nil, "aura viewer entries must not report spell cooldown as their duration source")

print("OK: cdm_blizz_mirror_duration_test")
