-- tests/cdm_icons_charge_mirror_active_test.lua
-- Run: lua tests/cdm_icons_charge_mirror_active_test.lua

local BuildCooldownStateContext = dofile("tests/helpers/cdm_context_builder_stub.lua")

local function noop() end

function InCombatLockdown() return false end
function GetTime() return 100 end
function wipe(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

function CreateFrame()
    return {
        RegisterEvent = noop,
        RegisterUnitEvent = noop,
        UnregisterAllEvents = noop,
        SetScript = noop,
    }
end

C_Timer = {
    After = function(_, callback) callback() end,
    NewTimer = function()
        return { Cancel = noop }
    end,
}

local chargeDuration = { token = "charge-duration" }
local storedState

local ns = {
    Helpers = {
        GetGeneralFont = function() return "Fonts\\FRIZQT__.TTF" end,
        GetGeneralFontOutline = function() return "" end,
        CreateDBGetter = function()
            return function()
                return {
                    essential = {
                        desaturateOnCooldown = true,
                    },
                }
            end
        end,
        IsSecretValue = function() return false end,
        SafeValue = function(value) return value end,
        SafeToNumber = function(value) return value end,
        CanAccessTable = function(tbl) return type(tbl) == "table" end,
    },
    Addon = {
        db = {
            profile = { ncdm = {} },
            char = { ncdm = {} },
        },
    },
    CDMShared = {
        IsRuntimeEnabled = function() return true end,
        IsSafeNumeric = function(value) return type(value) == "number" end,
    },
    CDMSources = {
        QuerySpellUsable = function() return true, false end,
        QuerySpellCharges = function()
            error("mirror-backed charge apply must not query spell charges")
        end,
        QuerySpellCooldown = function(spellID)
            if spellID == 444347 then
                return {
                    startTime = 0,
                    duration = 0,
                    isActive = false,
                    isOnGCD = false,
                }
            end
            return nil
        end,
    },
    CDMResolvers = {
        BuildCooldownStateContext = BuildCooldownStateContext,
        _textureCycleCache = {},
        _FinalizeImports = noop,
        Subscribe = noop,
        GetSpellTexture = function() return nil end,
        ResolveMacro = function() return nil end,
        GetEntryTexture = function() return nil end,
        IsAuraEntry = function(entry) return entry and entry.kind == "aura" end,
        ResolveSpellActiveState = function() return nil end,
        ResolveCooldownActivityState = function() return nil end,
        ResolveCooldownState = function()
            local state = {
                cooldownID = 8203,
                viewerCategory = "essential",
                isActive = true,
                resolvedMode = "charge",
            }
            return {
                mode = "charge",
                active = true,
                isActive = true,
                durObj = chargeDuration,
                sourceID = "charge:mirror:8203:183",
                spellID = 444347,
                mirrorBacked = true,
                isOnCooldown = false,
                rechargeActive = true,
                hasCharges = true,
                hasChargesRemaining = true,
                gcdOnly = false,
                cooldownInfo = {
                    startTime = 0,
                    duration = 0,
                    isActive = false,
                    isOnGCD = false,
                },
                cooldownInfoActive = false,
                cooldownInfoOnGCD = false,
                mirrorCooldownID = 8203,
                mirrorCategory = "essential",
                cooldownID = 8203,
                category = "essential",
                state = state,
                mirrorState = state,
            }
        end,
    },
    CDMIconFactory = {
        _FinalizeImports = noop,
        AcquireIcon = noop,
        ReleaseIcon = noop,
    },
    CDMRuntimeStore = {
        SetIconState = function(_, state)
            storedState = state
        end,
    },
}

dofile("tests/helpers/load_cdm_icon_runtime.lua")(ns)
assert(loadfile("modules/cdm/cdm_icons.lua"))("QUI", ns)

local appliedDuration
local cleared = false
local desaturated

local icon = {
    Cooldown = {
        SetCooldownFromDurationObject = function(_, durObj)
            appliedDuration = durObj
        end,
        SetReverse = noop,
        SetSwipeTexture = noop,
        Clear = function()
            cleared = true
        end,
    },
    Icon = {
        SetDesaturated = function(_, value)
            desaturated = value
        end,
        SetVertexColor = noop,
    },
    _spellEntry = {
        id = 444347,
        spellID = 444347,
        kind = "cooldown",
        type = "spell",
        viewerType = "essential",
        name = "Charged Mirror Spell",
    },
}

local applied = ns.CDMIcons.ApplyResolvedCooldown(icon)

assert(applied == true, "active charge mirror should report an applied cooldown")
assert(appliedDuration == chargeDuration, "active charge mirror should keep the recharge DurationObject bound")
assert(cleared == false, "active charge mirror must not clear the cooldown frame")
assert(icon._resolvedCooldownMode == "charge",
    "normal cooldown inactivity should not downgrade active charge mirror mode")
assert(icon._hasCooldownActive == false, "charge mirror with inactive spell cooldown should not mark the spell unavailable")
assert(icon._hasRealCooldownActive == false, "charge mirror with inactive spell cooldown should not mark a real cooldown")
assert(desaturated == false, "charge mirror with inactive spell cooldown should keep the icon saturated")
assert(storedState and storedState.mode == "charge", "runtime store should keep charge mode")
assert(storedState and storedState.active == false, "runtime store should store availability separately from recharge mode")
assert(storedState and storedState.hasCharges == true, "runtime store should mark charge-mode activity facts")
assert(storedState and storedState.rechargeActive == true, "runtime store should preserve active recharge separately")
assert(storedState and storedState.isOnCooldown == false, "runtime store should preserve cooldown lock separately")
assert(storedState and storedState.hasChargesRemaining == true,
    "runtime store should preserve remaining-charge activity for custom bars")

print("OK: cdm_icons_charge_mirror_active_test")
