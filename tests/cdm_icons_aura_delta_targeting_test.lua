-- tests/cdm_icons_aura_delta_targeting_test.lua
-- Run: lua tests/cdm_icons_aura_delta_targeting_test.lua

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

local resolveCounts = {}
local layoutRequests = 0
local subscriptions = {}
local buffContainerShows = 0

local function makeIcon(name, cooldownID)
    local icon = {
        name = name,
        _spellEntry = {
            id = cooldownID,
            spellID = cooldownID,
            viewerType = "essential",
            type = "spell",
        },
        _blizzMirrorCooldownID = cooldownID,
        _blizzMirrorCategory = "essential",
        Cooldown = {
            Clear = noop,
            SetReverse = noop,
        },
        Icon = {
            SetDesaturated = noop,
            SetAlpha = noop,
            SetTexture = noop,
        },
        Border = { SetAlpha = noop },
        DurationText = { SetAlpha = noop },
        StackText = { SetAlpha = noop },
    }
    function icon:IsShown() return self._shown ~= false end
    function icon:Show() self._shown = true end
    function icon:Hide() self._shown = false end
    function icon:SetAlpha(value) self._alpha = value end
    return icon
end

local matchingIcon = makeIcon("matching", 88001)
local unrelatedIcon = makeIcon("unrelated", 88002)
local nonMirrorIcon = makeIcon("nonMirror", 88003)
nonMirrorIcon._blizzMirrorCooldownID = nil
local buffAuraIcon = makeIcon("buffAura", 48707)
buffAuraIcon._spellEntry = {
    id = 48707,
    spellID = 48707,
    kind = "aura",
    viewerType = "buff",
    type = "spell",
}
buffAuraIcon._blizzMirrorCooldownID = nil
buffAuraIcon._shown = false

local mirrorStates = {
    [88001] = {
        auraInstanceID = 101,
        auraUnit = "target",
        isActive = true,
    },
    [88002] = {
        auraInstanceID = 202,
        auraUnit = "target",
        isActive = true,
    },
}

local ns = {
    Helpers = {
        GetGeneralFont = function() return "Fonts\\FRIZQT__.TTF" end,
        GetGeneralFontOutline = function() return "" end,
        CreateDBGetter = function()
            return function()
                return {
                    essential = {
                        iconDisplayMode = "always",
                        rangeIndicator = false,
                        usabilityIndicator = false,
                    },
                    buff = {
                        iconDisplayMode = "active",
                        rangeIndicator = false,
                        usabilityIndicator = false,
                    },
                }
            end
        end,
        IsSecretValue = function() return false end,
        SafeValue = function(value) return value end,
        SafeToNumber = function(value) return value end,
        CanAccessTable = function(tbl) return type(tbl) == "table" end,
        IsEditModeActive = function() return false end,
        IsLayoutModeActive = function() return false end,
    },
    Addon = {
        db = {
            profile = {
                ncdm = {
                    essential = { iconDisplayMode = "always" },
                    buff = { iconDisplayMode = "active" },
                    containers = {},
                },
            },
            char = { ncdm = {} },
        },
    },
    CDMShared = {
        IsRuntimeEnabled = function() return true end,
        IsSafeNumeric = function(value) return type(value) == "number" end,
    },
    CDMSources = {
        QuerySpellUsable = function() return true, false end,
        QuerySpellHasRange = function() return false end,
        QuerySpellInRange = function() return true end,
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID)
            return mirrorStates[cooldownID]
        end,
    },
    CDMResolvers = {
        _textureCycleCache = {},
        _FinalizeImports = noop,
        Subscribe = function(eventName, handler)
            subscriptions[eventName] = handler
        end,
        BeginRuntimeQueryBatch = noop,
        EndRuntimeQueryBatch = noop,
        QueryCharges = function() return nil end,
        QueryCooldown = function() return nil end,
        QueryDuration = function() return nil end,
        QueryChargeDuration = function() return nil end,
        QueryOverrideSpell = function() return nil end,
        QueryDisplayCount = function() return nil end,
        QuerySpellCount = function() return nil end,
        GetSpellTexture = function() return nil end,
        ResolveMacro = function() return nil end,
        GetEntryTexture = function() return nil end,
        HasRealCooldownState = function() return false end,
        ResolveAuraStateForIcon = function() return nil end,
        ResolveAuraDurationObjectForIcon = function() return nil end,
        IsAuraEntry = function(entry) return entry and entry.kind == "aura" end,
        GetChargeMetadataDB = function() return nil end,
        IsItemLikeEntry = function() return false end,
        ResolveItemCooldownIdentity = function() return nil end,
        ResolveEntryItemID = function() return nil end,
        ClassifySpellCooldownState = function() return nil end,
        ResolveSpellActiveState = function() return nil end,
        ResolveCooldownActivityState = function()
            return {
                isOnCooldown = false,
                rechargeActive = false,
                hasChargesRemaining = false,
                hasCharges = false,
            }
        end,
        ResolveIconDurationObject = function(icon)
            resolveCounts[icon.name] = (resolveCounts[icon.name] or 0) + 1
            if icon == buffAuraIcon then
                icon._auraActive = true
                icon._auraInstanceID = 621
                icon._auraUnit = "player"
                return nil, "aura", "aura:direct:48707"
            end
            return nil, "inactive", nil
        end,
    },
    CDMIconFactory = {
        _iconPools = {
            essential = { matchingIcon, unrelatedIcon, nonMirrorIcon },
            buff = { buffAuraIcon },
        },
        _recyclePool = {},
        _FinalizeImports = noop,
        AcquireIcon = noop,
        ReleaseIcon = noop,
        SyncCooldownBling = noop,
        UpdateIconCooldown = noop,
    },
    CDMRuntimeStore = {
        SetIconState = noop,
    },
    CDMBuffLayout = {
        OnLayoutReady = function()
            layoutRequests = layoutRequests + 1
        end,
    },
    CDMContainers = {
        GetContainer = function(viewerType)
            if viewerType ~= "buff" then return nil end
            return {
                Show = function()
                    buffContainerShows = buffContainerShows + 1
                end,
            }
        end,
    },
    _OwnedSwipe = {
        ApplyToIcon = noop,
        GetSettings = function()
            return {
                showGCDSwipe = true,
                showCooldownSwipe = true,
            }
        end,
    },
}

assert(loadfile("modules/cdm/cdm_icons.lua"))("QUI", ns)

local icons = assert(ns.CDMIcons, "CDMIcons should be exported")
icons.HandleUnitAuraChanged("target", {
    updatedAuraInstanceIDs = { 101 },
})

assert(resolveCounts.matching == 1, "matching aura-instance icon should be re-resolved")
assert(resolveCounts.unrelated == nil, "unrelated mirror aura instance should not be re-resolved")
assert(resolveCounts.nonMirror == nil, "non-mirror icons should not be reached by a target aura-instance delta")

icons.HandleUnitAuraChanged("player", {
    isFullUpdate = false,
    addedAuras = {
        { spellId = 48707, auraInstanceID = 621 },
    },
})

assert(resolveCounts.buffAura == 1, "added player aura should re-resolve matching buff aura icon by spell ID")
assert(buffAuraIcon._shown == true, "active buff aura icon should be shown by the aura-delta visibility path")
assert(layoutRequests > 0, "buff aura visibility flips should request buff icon layout")
assert(buffContainerShows > 0, "buff aura visibility flips should wake the owning buff container")

buffAuraIcon._shown = false
buffAuraIcon._auraActive = false
layoutRequests = 0
resolveCounts.buffAura = 0

icons.HandleUnitAuraChanged("player", nil)

assert(resolveCounts.buffAura == 1, "full aura refresh should re-resolve buff aura icons")
assert(buffAuraIcon._shown == true, "full aura refresh should apply buff aura visibility immediately")
assert(layoutRequests > 0, "full aura refresh active flips should request buff icon layout")

buffAuraIcon._shown = false
buffAuraIcon._auraActive = false
layoutRequests = 0
resolveCounts.buffAura = 0
buffContainerShows = 0

local cooldownChanged = assert(subscriptions["CDM:COOLDOWN_CHANGED"],
    "cooldown subscriber should be registered")
cooldownChanged("CDM:COOLDOWN_CHANGED", 48707, nil, "refresh")

assert(resolveCounts.buffAura == 1, "per-spell cooldown refresh should re-resolve matching aura icons")
assert(buffAuraIcon._shown == true,
    "per-spell cooldown refresh should apply aura visibility after resolving aura state")
assert(layoutRequests > 0,
    "per-spell cooldown refresh should request buff layout when aura state flips active")
assert(buffContainerShows > 0,
    "per-spell cooldown refresh should wake hidden active-only buff containers")

print("OK: cdm_icons_aura_delta_targeting_test")
