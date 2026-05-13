-- tests/cdm_icons_mirror_refresh_targeting_test.lua
-- Run: lua tests/cdm_icons_mirror_refresh_targeting_test.lua

local function noop() end

function InCombatLockdown() return false end
function UnitAffectingCombat() return false end
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

local function makeIcon(name, cooldownID, category)
    local icon = {
        name = name,
        _spellEntry = {
            id = cooldownID,
            spellID = cooldownID,
            kind = "cooldown",
            viewerType = category,
            type = "spell",
        },
        _blizzMirrorCooldownID = cooldownID,
        _blizzMirrorCategory = category,
        Cooldown = {
            Clear = noop,
            SetReverse = noop,
            SetCooldownFromDurationObject = noop,
        },
        Icon = {
            SetDesaturated = noop,
            SetAlpha = noop,
            SetTexture = noop,
            SetVertexColor = noop,
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

local matchingIcon = makeIcon("matching", 88001, "essential")
local sameIDWrongCategoryIcon = makeIcon("sameIDWrongCategory", 88001, "buff")
local unrelatedIcon = makeIcon("unrelated", 88002, "essential")

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
                        iconDisplayMode = "always",
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
                    buff = { iconDisplayMode = "always" },
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
    CDMResolvers = {
        _textureCycleCache = {},
        _FinalizeImports = noop,
        Subscribe = noop,
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
        IsAuraEntry = function(entry)
            return entry and entry.kind == "aura"
        end,
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
            return nil, "inactive", nil
        end,
    },
    CDMIconFactory = {
        _iconPools = {
            essential = { matchingIcon, unrelatedIcon },
            buff = { sameIDWrongCategoryIcon },
        },
        _recyclePool = {},
        _FinalizeImports = noop,
        AcquireIcon = noop,
        ReleaseIcon = noop,
        SyncCooldownBling = noop,
        UpdateIconCooldown = function(icon)
            resolveCounts[icon.name] = (resolveCounts[icon.name] or 0) + 1
        end,
    },
    CDMRuntimeStore = {
        SetIconState = noop,
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
assert(type(icons.RebuildBlizzMirrorIconIndex) == "function",
    "icons should expose a way to rebuild the mirror icon index")
assert(type(icons.RequestMirrorTextRefresh) == "function",
    "icons should expose scoped mirror refresh requests")

icons.RebuildBlizzMirrorIconIndex()

local fullUpdates = 0
icons.UpdateAllCooldowns = function()
    fullUpdates = fullUpdates + 1
end

icons:RequestMirrorTextRefresh(88001, "essential", "test")

assert(resolveCounts.matching == 1,
    "matching mirror icon should be re-resolved")
assert(resolveCounts.sameIDWrongCategory == nil,
    "same cooldownID in a different mirror category should not be re-resolved")
assert(resolveCounts.unrelated == nil,
    "unrelated mirror icons should not be reached by scoped refresh")
assert(fullUpdates == 0,
    "scoped mirror refresh must not call UpdateAllCooldowns")

icons:RequestMirrorTextRefresh(nil, nil, "unknown-test")
assert(fullUpdates == 0,
    "unknown mirror refresh fallback should schedule through CDM update flow, not call UpdateAllCooldowns immediately")

local stats = icons:GetCacheStats()
assert(stats.mirrorRefreshTargeted == 1,
    "mirror refresh stats should count targeted refreshes")
assert(stats.mirrorRefreshFallback == 1,
    "mirror refresh stats should count scheduler-backed fallbacks")

assert(type(icons.RecordEventProfile) == "function",
    "icons should expose CDM-local event profiling")
icons.RecordEventProfile("SPELL_UPDATE_USABLE", 4)
icons.RecordEventProfile("SPELL_UPDATE_USABLE", 6)
icons.RecordEventProfile("SPELL_RANGE_CHECK_UPDATE", 1)

stats = icons:GetCacheStats()
assert(type(stats.iconEventProfileTop) == "table",
    "icon cache stats should expose event-profile rows")
assert(stats.iconEventProfileTop[1].event == "SPELL_UPDATE_USABLE",
    "event profile should sort by elapsed time")
assert(stats.iconEventProfileTop[1].calls == 2,
    "event profile should report per-window call counts")
assert(stats.iconEventProfileTop[1].ms == 10,
    "event profile should report per-window elapsed time")

print("OK: cdm_icons_mirror_refresh_targeting_test")
