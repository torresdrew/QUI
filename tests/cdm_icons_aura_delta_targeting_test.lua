-- tests/cdm_icons_aura_delta_targeting_test.lua
-- Run: lua tests/cdm_icons_aura_delta_targeting_test.lua

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

local resolveCounts = {}
local layoutRequests = 0
local subscriptions = {}
local buffContainerShows = 0
local itemAuraDur = { token = "item-aura-duration" }
local itemAuraAppliedDuration
local itemAuraReverse

local function makeIcon(name, cooldownID)
    local icon = {
        name = name,
        _spellEntry = {
            id = cooldownID,
            spellID = cooldownID,
            name = name,
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
    name = "buffAura",
    kind = "aura",
    viewerType = "buff",
    type = "spell",
}
buffAuraIcon._blizzMirrorCooldownID = nil
buffAuraIcon._shown = false
local itemAuraIcon = makeIcon("itemAura", 241288)
itemAuraIcon._spellEntry = {
    id = 241288,
    itemID = 241288,
    name = "itemAura",
    kind = "cooldown",
    viewerType = "essential",
    type = "item",
}
itemAuraIcon._runtimeSpellID = 241288
itemAuraIcon._blizzMirrorCooldownID = nil
itemAuraIcon.Cooldown.SetCooldownFromDurationObject = function(_, durObj)
    itemAuraAppliedDuration = durObj
end
itemAuraIcon.Cooldown.SetReverse = function(_, reverse)
    itemAuraReverse = reverse
end

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
        QueryItemSpell = function(itemID)
            if itemID == 241288 then
                return "Potion Use", 1236994
            end
            return nil, nil
        end,
        QueryCooldownAuraBySpellID = function(spellID)
            if spellID == 1236994 then
                return 555001
            end
            return nil
        end,
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID)
            return mirrorStates[cooldownID]
        end,
    },
    CDMResolvers = {
        BuildCooldownStateContext = BuildCooldownStateContext,
        _textureCycleCache = {},
        _FinalizeImports = noop,
        Subscribe = function(eventName, handler)
            subscriptions[eventName] = handler
        end,
        GetSpellTexture = function() return nil end,
        ResolveMacro = function() return nil end,
        GetEntryTexture = function() return nil end,
        IsAuraEntry = function(entry) return entry and entry.kind == "aura" end,
        ResolveSpellActiveState = function() return nil end,
        ResolveCooldownActivityState = function()
            return {
                isOnCooldown = false,
                rechargeActive = false,
                hasChargesRemaining = false,
                hasCharges = false,
            }
        end,
        ResolveCooldownState = function(context)
            local entry = context and context.entry
            local name = entry and entry.name
            if name then
                resolveCounts[name] = (resolveCounts[name] or 0) + 1
            end
            if name == "buffAura" then
                return {
                    mode = "aura",
                    active = true,
                    isActive = true,
                    sourceID = "aura:direct:48707",
                    spellID = 48707,
                    auraResolved = true,
                    auraInstanceID = 621,
                    auraUnit = "player",
                    resolvedAuraSpellID = 48707,
                }
            end
            if name == "itemAura" then
                return {
                    mode = "aura",
                    active = true,
                    isActive = true,
                    durObj = itemAuraDur,
                    sourceID = "item-aura-instance:241288",
                    spellID = 1236994,
                    auraResolved = true,
                    auraActive = true,
                    auraIsActive = true,
                    auraInstanceID = 622,
                    auraUnit = "player",
                    resolvedAuraSpellID = 555001,
                    isOnCooldown = false,
                    hasDurationObject = true,
                    hasRenderableCooldown = true,
                }
            end
            return {
                mode = "inactive",
                active = false,
                isActive = false,
            }
        end,
    },
    CDMIconFactory = {
        _iconPools = {
            essential = { matchingIcon, unrelatedIcon, nonMirrorIcon, itemAuraIcon },
            buff = { buffAuraIcon },
        },
        _recyclePool = {},
        _FinalizeImports = noop,
        AcquireIcon = noop,
        ReleaseIcon = noop,
        SyncCooldownBling = noop,
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

dofile("tests/helpers/load_cdm_icon_runtime.lua")(ns)
assert(loadfile("modules/cdm/cdm_icons.lua"))("QUI", ns)

local icons = assert(ns.CDMIcons, "CDMIcons should be exported")
icons.HandleRuntimeRefresh("UNIT_AURA", "target", {
    updatedAuraInstanceIDs = { 101 },
})

assert(resolveCounts.matching == 1, "matching aura-instance icon should be re-resolved")
assert(resolveCounts.unrelated == nil, "unrelated mirror aura instance should not be re-resolved")
assert(resolveCounts.nonMirror == nil, "non-mirror icons should not be reached by a target aura-instance delta")

icons.HandleRuntimeRefresh("UNIT_AURA", "player", {
    isFullUpdate = false,
    addedAuras = {
        { spellId = 48707, auraInstanceID = 621 },
    },
})

assert(resolveCounts.buffAura == 1, "added player aura should re-resolve matching buff aura icon by spell ID")
assert(buffAuraIcon._shown == true, "active buff aura icon should be shown by the aura-delta visibility path")
assert(layoutRequests > 0, "buff aura visibility flips should request buff icon layout")
assert(buffContainerShows > 0, "buff aura visibility flips should wake the owning buff container")

icons.HandleRuntimeRefresh("UNIT_AURA", "player", {
    isFullUpdate = false,
    addedAuras = {
        { spellId = 555001, auraInstanceID = 622 },
    },
})

assert(resolveCounts.itemAura == 1,
    "added player aura should re-resolve matching item icon through item use aura mapping")
assert(itemAuraIcon._auraActive == true,
    "added player item aura should stamp active aura metadata on the item icon")
assert(itemAuraAppliedDuration == itemAuraDur,
    "added player item aura should bind the aura DurationObject to the item icon")
assert(itemAuraReverse == true,
    "added player item aura should use aura/reverse cooldown mode")

buffAuraIcon._shown = false
buffAuraIcon._auraActive = false
layoutRequests = 0
resolveCounts.buffAura = 0

icons.HandleRuntimeRefresh("UNIT_AURA", "player", nil)

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

resolveCounts.itemAura = 0
itemAuraIcon._auraActive = false
itemAuraIcon._lastDurObjKey = nil
itemAuraIcon._lastDurObj = nil
itemAuraIcon._lastAuraDurObj = nil
itemAuraAppliedDuration = nil
itemAuraReverse = nil

cooldownChanged("CDM:COOLDOWN_CHANGED", 1236994, nil, "scanner_item")

assert(resolveCounts.itemAura == 1, "scanner item refresh should re-resolve item-backed icons")
assert(itemAuraIcon._auraActive == true,
    "scanner item refresh should stamp active aura metadata on the item icon")
assert(itemAuraAppliedDuration == itemAuraDur,
    "scanner item refresh should bind the aura DurationObject to the item icon")
assert(itemAuraReverse == true,
    "scanner item refresh should use aura/reverse cooldown mode")

print("OK: cdm_icons_aura_delta_targeting_test")
