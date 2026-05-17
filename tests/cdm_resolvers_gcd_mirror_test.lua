-- tests/cdm_resolvers_gcd_mirror_test.lua
-- Run: lua tests/cdm_resolvers_gcd_mirror_test.lua

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

local mirrorDuration = { token = "stale-mirror-duration" }
local gcdDuration = { token = "gcd-duration" }
local liveChargeDuration = { token = "live-charge-duration" }
local misleadingCooldownDuration = { token = "misleading-cooldown-duration" }
local realCooldownDuration = { token = "real-cooldown-duration" }
local auraChildFrameDuration = { token = "aura-child-frame-duration" }
local auraMirrorDuration = { token = "aura-mirror-duration" }
local auraMirrorData = { token = "aura-mirror-data", icon = 98765 }
local mirrorSource = "aura-child-frame"
local gcdSpellFallbackEnabled = false
local cooldownQueryCounts = {}
local auraDataQueryCount = 0
local SECRET_COOLDOWN_FIELD = { token = "secret-cooldown-field" }

function issecretvalue(value)
    return value == SECRET_COOLDOWN_FIELD
end

local ns = {
    Helpers = {},
    CDMSources = {
        QueryMirroredCooldownState = function(spellID, viewerType)
            if spellID == 44444 and viewerType == "essential" then
                return {
                    cooldownID = 777,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "spell-cooldown",
                    mirrorEpoch = 5,
                    spellID = spellID,
                    cooldownIsActive = false,
                }
            end
            if spellID == 55555 and viewerType == "essential" then
                return {
                    cooldownID = 777,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "gcd-duration",
                    resolvedMode = "gcd-only",
                    mirrorEpoch = 5,
                    spellID = spellID,
                }
            end
            if spellID == 1227280 and viewerType == "essential" then
                return {
                    cooldownID = 8203,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "gcd-duration",
                    resolvedMode = "gcd-only",
                    mirrorEpoch = 19,
                    spellID = spellID,
                }
            end
            if spellID == 1227281 and viewerType == "essential" then
                return {
                    cooldownID = 8204,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "spell-cooldown",
                    resolvedMode = "cooldown",
                    mirrorEpoch = 21,
                    spellID = spellID,
                }
            end
            if spellID == 202020 and viewerType == "essential" then
                return {
                    cooldownID = 781,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "spell-cooldown",
                    resolvedMode = "gcd-only",
                    mirrorEpoch = 10,
                    spellID = spellID,
                }
            end
            if (spellID == 11111 or spellID == 181818 or spellID == 181819 or spellID == 181820) and viewerType == "essential" then
                return {
                    cooldownID = 777,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "spell-cooldown",
                    mirrorEpoch = 5,
                    spellID = spellID,
                    childIsActive = (spellID == 181818 or spellID == 181819 or spellID == 181820) and true or nil,
                    wasSetFromCooldown = (spellID == 181818 or spellID == 181819 or spellID == 181820) and true or nil,
                }
            end
            if spellID == 181821 and viewerType == "essential" then
                return {
                    cooldownID = 781,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "gcd-duration",
                    resolvedMode = "gcd-only",
                    mirrorEpoch = 9,
                    spellID = spellID,
                    childIsActive = true,
                    wasSetFromCooldown = true,
                }
            end
            if spellID == 191919 and viewerType == "essential" then
                return {
                    cooldownID = 780,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "spell-cooldown",
                    mirrorEpoch = 9,
                    spellID = spellID,
                    childIsActive = true,
                    cooldownIsActive = true,
                    wasSetFromCooldown = true,
                }
            end
            if (spellID == 161616 or spellID == 171717) and viewerType == "essential" then
                return {
                    cooldownID = 779,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "cooldown-frame",
                    mirrorEpoch = 7,
                    spellID = spellID,
                }
            end
            if (spellID == 66666 or spellID == 66667) and viewerType == "essential" then
                return {
                    cooldownID = 778,
                    isActive = true,
                    durObj = mirrorDuration,
                    durObjSource = "spell-charge",
                    mirrorEpoch = 6,
                    spellID = spellID,
                }
            end
        end,
        QuerySpellCharges = function(spellID)
            if spellID == 66666 then
                return { currentCharges = 2, maxCharges = 2, isActive = false }
            end
            if spellID == 66667 then
                return { currentCharges = 1, maxCharges = 2, isActive = true }
            end
            if spellID == 88888 then
                return { currentCharges = 2, maxCharges = 2, isActive = false }
            end
            if spellID == 1227280 then
                return { currentCharges = 1, maxCharges = 2, isActive = true }
            end
            if spellID == 1227281 then
                return { currentCharges = 1, maxCharges = 2, isActive = true }
            end
            return nil
        end,
        QuerySpellChargeDuration = function(spellID)
            if spellID == 1227280 or spellID == 1227281 then
                return liveChargeDuration
            end
            return nil
        end,
        QuerySpellCooldown = function(spellID)
            cooldownQueryCounts[spellID] = (cooldownQueryCounts[spellID] or 0) + 1
            if spellID == 12345 then
                return { isActive = true }
            end
            if spellID == 33333 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 55555 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 11111 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 77777 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 66666 or spellID == 66667 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 88888 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 99999 then
                return { isActive = true, isOnGCD = true, activeCategory = "spell" }
            end
            if spellID == 121212 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 131313 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 141414 then
                return { isActive = true, isOnGCD = false, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 141415 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 151515 then
                return { isActive = true, isOnGCD = false, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 151516 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 161616 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 171717 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 44444 then
                return { isActive = false }
            end
            if spellID == 181818 then
                return { isActive = false, isOnGCD = nil }
            end
            if spellID == 181819 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 181820 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 181821 then
                return { isActive = false, isOnGCD = false }
            end
            if spellID == 191919 then
                return { isActive = true, isOnGCD = true, activeCategory = SECRET_COOLDOWN_FIELD }
            end
            if spellID == 212121 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 232323 then
                return { isActive = true, isOnGCD = true }
            end
            if spellID == 22222 or spellID == 54321 then
                return { isActive = false }
            end
        end,
        QuerySpellCooldownDuration = function(spellID, ignoreGCD)
            if spellID == 61304 and gcdSpellFallbackEnabled then
                return gcdDuration
            end
            if spellID == 88888 then
                if ignoreGCD == true then
                    return misleadingCooldownDuration
                end
                return nil
            end
            if spellID == 11111 then
                if ignoreGCD == true then
                    return misleadingCooldownDuration
                end
                return nil
            end
            if spellID == 99999 and ignoreGCD == true then
                return realCooldownDuration
            end
            if spellID == 121212 then
                if ignoreGCD == true then
                    return misleadingCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 131313 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 141414 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return nil
            end
            if spellID == 141415 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 151515 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return nil
            end
            if spellID == 151516 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 161616 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 171717 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return nil
            end
            if spellID == 181820 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 191919 then
                if ignoreGCD == true then
                    return realCooldownDuration
                end
                return gcdDuration
            end
            if spellID == 212121 then
                if ignoreGCD == true then
                    return nil
                end
                return gcdDuration
            end
            if spellID == 232323 then
                if ignoreGCD == true then
                    return nil
                end
                return gcdDuration
            end
            if spellID == 55555 or spellID == 77777 or spellID == 66666 or spellID == 66667 then
                return nil
            end
            if spellID ~= 12345
               and spellID ~= 22222
               and spellID ~= 33333
               and spellID ~= 54321 then
                return nil
            end
            if ignoreGCD == true then
                return nil
            end
            return gcdDuration
        end,
        QuerySpellUsable = function(spellID)
            if spellID == 141414 or spellID == 141415 or spellID == 181820 or spellID == 191919 then
                return true, false
            end
            if spellID == 151515 or spellID == 151516 or spellID == 212121 then
                return false, true
            end
            return nil, nil
        end,
        QueryOverrideSpell = function() return nil end,
        QueryAuraDataByAuraInstanceID = function(unit, auraInstanceID)
            auraDataQueryCount = auraDataQueryCount + 1
            if unit == "player" and auraInstanceID == 808 then
                return auraMirrorData
            end
            return nil
        end,
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID, viewerCategory)
            if cooldownID == 888 and viewerCategory == "essential" then
                return {
                    cooldownID = cooldownID,
                    isActive = true,
                    durObj = auraChildFrameDuration,
                    durObjSource = mirrorSource,
                    mirrorEpoch = 6,
                    spellID = 54321,
                }
            end
            if cooldownID == 889 and viewerCategory == "buff" then
                return {
                    cooldownID = cooldownID,
                    isActive = true,
                    durObj = auraMirrorDuration,
                    durObjSource = "aura-duration",
                    resolvedMode = "aura",
                    mirrorEpoch = 13,
                    spellID = 70765,
                    viewerCategory = "buff",
                    selfAura = true,
                    auraInstanceID = 808,
                    auraUnit = "player",
                }
            end
            if cooldownID == 890 and viewerCategory == "essential" then
                return {
                    cooldownID = cooldownID,
                    isActive = false,
                    durObj = nil,
                    durObjSource = "spell-cooldown",
                    resolvedMode = "cooldown",
                    mirrorEpoch = 14,
                    spellID = 232323,
                    viewerCategory = "essential",
                }
            end
            if cooldownID == 891 and viewerCategory == "buff" then
                return {
                    cooldownID = cooldownID,
                    isActive = true,
                    durObj = auraMirrorDuration,
                    durObjSource = "aura-duration",
                    resolvedMode = "aura",
                    mirrorEpoch = 15,
                    spellID = 70766,
                    viewerCategory = "buff",
                    selfAura = true,
                    auraInstanceID = 809,
                    auraUnit = "player",
                    auraData = auraMirrorData,
                }
            end
        end,
    },
}

assert(loadfile("modules/cdm/cdm_runtime_queries.lua"))("QUI", ns)
assert(loadfile("modules/cdm/cdm_resolvers.lua"))("QUI", ns)

local function setTrustedGCDState(values)
    local spellState = ns.CDMRuntimeQueries.ResetTrustedGCDSnapshot(1)
    for spellID, value in pairs(values or {}) do
        spellState[spellID] = value
    end
    ns.CDMRuntimeQueries.SetTrustIsOnGCDForBatch(values ~= nil)
end

setTrustedGCDState({
    [12345] = true,
    [22222] = true,
    [54321] = true,
})

local function getPreservedRealDurationObject(icon)
    if not (icon and icon._lastDurObj and type(icon._lastDurObjKey) == "string") then
        return nil, nil, nil
    end
    local mode, sourceID = icon._lastDurObjKey:match("^([^:]+):(.+)$")
    if mode == "cooldown" or mode == "charge" or mode == "item-cooldown" then
        return icon._lastDurObj, mode, sourceID
    end
    return nil, nil, nil
end

local function ResolveIconFields(icon)
    local entry = icon and icon._spellEntry
    local preservedDurObj, preservedMode, preservedSourceID =
        getPreservedRealDurationObject(icon)
    local context = ns.CDMResolvers.BuildCooldownStateContext(icon, entry, icon and icon._runtimeSpellID, {
        containerKey = entry and entry.viewerType,
        totemSlot = icon and icon._totemSlot,
        useBuffSwipe = false,
        skipAuraPhase = false,
        showGCDSwipe = true,
        priorCooldownActive = icon and icon._hasCooldownActive == true,
        priorRealCooldownActive = icon and icon._hasRealCooldownActive == true,
        priorShowingRealCooldownSwipe = icon and icon._showingRealCooldownSwipe == true,
        priorResolvedCooldownMode = icon and icon._resolvedCooldownMode,
        preservedRealDurObj = preservedDurObj,
        preservedRealMode = preservedMode,
        preservedRealSourceID = preservedSourceID,
        lastChargeMirrorCooldownID = icon and icon._lastChargeMirrorCooldownID,
        lastChargeMirrorCategory = icon and icon._lastChargeMirrorCategory,
        lastChargeRuntimeSpellID = icon and icon._lastChargeRuntimeSpellID,
    })
    context.mirrorCooldownID = icon and icon._blizzMirrorCooldownID
    context.mirrorCategory = icon and icon._blizzMirrorCategory
    local state = ns.CDMResolvers.ResolveCooldownState(context)
    return state.durObj,
        state.mode,
        state.sourceID,
        state.start,
        state.duration,
        state.spellID,
        state.mirrorBacked == true,
        state.mirrorBacked == true and state or nil
end

local icon = {
    _spellEntry = {
        id = 12345,
        spellID = 12345,
        viewerType = "essential",
        type = "spell",
    },
}

local durObj, mode, sourceID = ResolveIconFields(icon)

assert(durObj == gcdDuration, "trusted GCD state should resolve when no active mirror duration exists")
assert(mode == "gcd-only", "trusted GCD state should resolve as gcd-only")
assert(sourceID == 12345, "GCD-only source should be the runtime spellID")

setTrustedGCDState(nil)

local liveCooldownGCDIcon = {
    _spellEntry = {
        id = 33333,
        spellID = 33333,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(liveCooldownGCDIcon)

assert(durObj == gcdDuration, "live isOnGCD should render GCD when trusted batch state is absent")
assert(mode == "gcd-only", "live isOnGCD should resolve as gcd-only")
assert(sourceID == 33333, "live isOnGCD source should be the runtime spellID")

local mirroredGCDIcon = {
    _spellEntry = {
        id = 55555,
        spellID = 55555,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(mirroredGCDIcon)

assert(durObj == mirrorDuration, "GCD mirror duration should be reused when spell-specific GCD duration is missing")
assert(mode == "gcd-only", "GCD mirror duration should resolve as gcd-only")
assert(sourceID == 55555, "GCD mirror source should use the runtime spellID for stable binding")
assert(cooldownQueryCounts[55555] == nil, "valid mirror duration should bypass live cooldown state queries")

local misleadingMirroredCooldownIcon = {
    _spellEntry = {
        id = 11111,
        spellID = 11111,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(misleadingMirroredCooldownIcon)

assert(durObj == mirrorDuration, "spell-cooldown mirror duration should be returned directly during live GCD")
assert(mode == "cooldown", "spell-cooldown mirror source should remain cooldown mode, got " .. tostring(mode))
assert(sourceID == "mirror:777:5", "spell-cooldown mirror source should keep its mirror key")

local cooldownFrameMirroredGCDIcon = {
    _spellEntry = {
        id = 161616,
        spellID = 161616,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(cooldownFrameMirroredGCDIcon)

assert(durObj == mirrorDuration, "cooldown-frame mirror should win over an explicit live GCD duration")
assert(mode == "cooldown", "cooldown-frame mirror source should remain cooldown mode, got " .. tostring(mode))
assert(sourceID == "mirror:779:7", "cooldown-frame mirror source should keep its mirror key")

local cooldownFrameMirroredGCDWithoutExplicitDurationIcon = {
    _spellEntry = {
        id = 171717,
        spellID = 171717,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(cooldownFrameMirroredGCDWithoutExplicitDurationIcon)

assert(durObj == mirrorDuration, "cooldown-frame mirror should be returned directly when no explicit live GCD duration exists")
assert(mode == "cooldown", "cooldown-frame mirror source should remain cooldown mode, got " .. tostring(mode))
assert(sourceID == "mirror:779:7", "cooldown-frame mirror source should keep its mirror key")

gcdSpellFallbackEnabled = true
local gcdSpellFallbackIcon = {
    _spellEntry = {
        id = 77777,
        spellID = 77777,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(gcdSpellFallbackIcon)

assert(durObj == gcdDuration, "GCD spell duration should be used when spell-specific duration is missing")
assert(mode == "gcd-only", "GCD spell fallback should resolve as gcd-only")
assert(sourceID == 77777, "GCD spell fallback source should remain the runtime spellID")
gcdSpellFallbackEnabled = false

local staleChargeMirrorGCDIcon = {
    _spellEntry = {
        id = 66666,
        spellID = 66666,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(staleChargeMirrorGCDIcon)

assert(durObj == mirrorDuration, "inactive live charge state should not override an active charge mirror duration")
assert(mode == "charge", "active charge mirror should remain charge mode during GCD, got " .. tostring(mode))
assert(sourceID == "mirror:778:6", "active charge mirror should keep its mirror source key")

local activeChargeMirrorIcon = {
    _spellEntry = {
        id = 66667,
        spellID = 66667,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(activeChargeMirrorIcon)

assert(durObj == mirrorDuration, "active charge mirror should remain selected")
assert(mode == "charge", "active charge mirror should remain charge mode even during GCD")

local activeLiveChargeOverGCDMirrorIcon = {
    _spellEntry = {
        id = 1227280,
        spellID = 1227280,
        viewerType = "essential",
        type = "spell",
        hasCharges = true,
    },
}

durObj, mode, sourceID = ResolveIconFields(activeLiveChargeOverGCDMirrorIcon)

assert(durObj == liveChargeDuration, "active live recharge should override a mirror GCD duration")
assert(mode == "charge", "active live recharge should resolve as charge over mirror GCD, got " .. tostring(mode))
assert(sourceID == "1227280:0", "active live recharge source should use the charge duration key")

local activeLiveChargeOverCooldownMirrorIcon = {
    _spellEntry = {
        id = 1227281,
        spellID = 1227281,
        viewerType = "essential",
        type = "spell",
        hasCharges = true,
    },
}

durObj, mode, sourceID = ResolveIconFields(activeLiveChargeOverCooldownMirrorIcon)

assert(durObj == mirrorDuration, "active live recharge should not override a mirror cooldown duration")
assert(mode == "cooldown", "active mirror cooldown should stay cooldown mode over live charge, got " .. tostring(mode))
assert(sourceID == "mirror:8204:21", "active mirror cooldown should keep its mirror source key")

local misleadingLiveCooldownIcon = {
    _spellEntry = {
        id = 88888,
        spellID = 88888,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(misleadingLiveCooldownIcon)

assert(durObj == misleadingCooldownDuration, "inactive charge live cooldown duration should be reused as GCD when no GCD duration is available")
assert(mode == "gcd-only", "inactive charge live cooldown duration during GCD should resolve as gcd-only, got " .. tostring(mode))
assert(sourceID == 88888, "inactive charge live cooldown GCD source should use runtime spellID")

local realCooldownDuringGCDIcon = {
    _spellEntry = {
        id = 99999,
        spellID = 99999,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(realCooldownDuringGCDIcon)

assert(durObj == realCooldownDuration, "real cooldown duration should remain selected during GCD")
assert(mode == "cooldown", "real cooldown duration should remain cooldown mode during GCD")
assert(sourceID == 99999, "real cooldown source should use runtime spellID")

local unknownRealCooldownDuringGCDIcon = {
    _spellEntry = {
        id = 121212,
        spellID = 121212,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(unknownRealCooldownDuringGCDIcon)

assert(durObj == gcdDuration, "unknown real-cooldown proof during live GCD should prefer explicit GCD duration")
assert(mode == "gcd-only", "unknown real-cooldown proof during live GCD should resolve as gcd-only")
assert(sourceID == 121212, "unknown real-cooldown GCD source should use runtime spellID")

local knownRealCooldownDuringLaterGCDIcon = {
    _hasRealCooldownActive = true,
    _showingRealCooldownSwipe = true,
    _spellEntry = {
        id = 131313,
        spellID = 131313,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(knownRealCooldownDuringLaterGCDIcon)

assert(durObj == realCooldownDuration, "resolved state should preserve a prior real cooldown during GCD when context supplies prior activity")
assert(mode == "cooldown", "prior real-cooldown activity should keep cooldown mode over a later GCD")
assert(sourceID == 131313, "known real cooldown source should use runtime spellID")

local usableResourceCooldownIcon = {
    _spellEntry = {
        id = 141414,
        spellID = 141414,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(usableResourceCooldownIcon)

assert(durObj == nil, "usable resource cooldown should not bind a real cooldown duration")
assert(mode == "inactive", "usable resource cooldown should resolve inactive outside GCD")
assert(sourceID == nil, "usable resource cooldown should not keep a cooldown source")

local usableResourceDuringGCDIcon = {
    _hasRealCooldownActive = true,
    _showingRealCooldownSwipe = true,
    _spellEntry = {
        id = 141415,
        spellID = 141415,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(usableResourceDuringGCDIcon)

assert(durObj == gcdDuration, "usable resource spell should render GCD during a later GCD pulse")
assert(mode == "gcd-only", "usable resource spell should not keep stale real-cooldown mode during GCD")
assert(sourceID == 141415, "usable resource GCD source should use runtime spellID")

local resourceBlockedCooldownIcon = {
    _spellEntry = {
        id = 151515,
        spellID = 151515,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(resourceBlockedCooldownIcon)

assert(durObj == realCooldownDuration, "resource-blocked cooldown should bind its real duration")
assert(mode == "cooldown", "resource-blocked cooldown should stay in cooldown mode")
assert(sourceID == 151515, "resource-blocked cooldown should keep its runtime spellID source")

local resourceBlockedDuringGCDIcon = {
    _hasRealCooldownActive = true,
    _showingRealCooldownSwipe = true,
    _spellEntry = {
        id = 151516,
        spellID = 151516,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(resourceBlockedDuringGCDIcon)

assert(durObj == realCooldownDuration, "resource-blocked spell should preserve its real cooldown duration during a later GCD")
assert(mode == "cooldown", "resource-blocked spell should keep real-cooldown mode during a later GCD")
assert(sourceID == 151516, "resource-blocked cooldown source should use runtime spellID")

local resourceBlockedPriorMirrorDuringGCDIcon = {
    _hasRealCooldownActive = true,
    _showingRealCooldownSwipe = true,
    _lastDurObjKey = "cooldown:mirror:27927:2218",
    _lastDurObj = mirrorDuration,
    _spellEntry = {
        id = 212121,
        spellID = 212121,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(resourceBlockedPriorMirrorDuringGCDIcon)

assert(durObj == mirrorDuration, "resolved state should preserve a prior mirror binding during a later GCD pulse")
assert(mode == "cooldown", "prior mirror preservation belongs to the resolved cooldown state")
assert(sourceID == "mirror:27927:2218", "prior mirror source should remain stable while preserved")

local activeChildMirrorLiveInactiveIcon = {
    _spellEntry = {
        id = 181818,
        spellID = 181818,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(activeChildMirrorLiveInactiveIcon)

assert(durObj == nil, "live isActive=false should clear a stale active child mirror duration")
assert(mode == "inactive", "live isActive=false should resolve the stale mirror as inactive")
assert(sourceID == nil, "stale mirror source should clear when live cooldown state is inactive")

local activeChildMirrorDuringLaterGCDIcon = {
    _spellEntry = {
        id = 181819,
        spellID = 181819,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(activeChildMirrorDuringLaterGCDIcon)

assert(durObj == mirrorDuration, "active child mirror duration should not downgrade during a later GCD")
assert(mode == "cooldown", "active child mirror should remain cooldown mode during a later GCD")
assert(sourceID == "mirror:777:5", "active child mirror should keep its mirror source during a later GCD")

local activeChildUsableMirrorDuringGCDIcon = {
    _spellEntry = {
        id = 181820,
        spellID = 181820,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(activeChildUsableMirrorDuringGCDIcon)

assert(durObj == mirrorDuration, "usable active child mirror duration should not downgrade during GCD")
assert(mode == "cooldown", "usable active child mirror should remain cooldown mode during GCD")
assert(sourceID == "mirror:777:5", "usable active child mirror should keep its mirror source during GCD")

local usableActiveMirrorIcon = {
    _spellEntry = {
        id = 191919,
        spellID = 191919,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(usableActiveMirrorIcon)

assert(durObj == mirrorDuration, "active mirror cooldown should win over live usable/GCD fallback")
assert(mode == "cooldown", "active mirror spell-cooldown source should remain cooldown mode")
assert(sourceID == "mirror:780:9", "active mirror cooldown should keep its mirror source key")

local resolvedModeMirrorIcon = {
    _spellEntry = {
        id = 202020,
        spellID = 202020,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(resolvedModeMirrorIcon)

assert(durObj == mirrorDuration, "resolver should return active mirror duration when resolvedMode is present")
assert(mode == "gcd-only", "resolver should trust mirror resolvedMode before source fallback")
assert(sourceID == 202020, "GCD-only mirror resolvedMode should keep runtime spellID source")

local authoritativeGCDMirrorIcon = {
    _spellEntry = {
        id = 181821,
        spellID = 181821,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(authoritativeGCDMirrorIcon)

assert(durObj == mirrorDuration, "authoritative GCD mirror duration should be returned directly")
assert(mode == "gcd-only", "authoritative GCD mirror mode should not be recomputed from live cooldown state")
assert(sourceID == 181821, "authoritative GCD mirror source should use the runtime spellID")

local staleInactiveMirrorIcon = {
    _spellEntry = {
        id = 44444,
        spellID = 44444,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(staleInactiveMirrorIcon)

assert(durObj == nil, "resolver should clear active mirror duration when live cooldown is inactive")
assert(mode == "inactive", "active mirror duration should resolve inactive when live cooldown is inactive")
assert(sourceID == nil, "stale mirror source should clear when live cooldown is inactive")

assert(ns.CDMResolvers.GetMirrorPolicyStats == nil,
    "resolver should not expose mirror policy counters after mirror ownership is restored")
assert(ns.CDMResolvers.ShouldUseMirroredCooldownDuration == nil,
    "resolver should not expose mirror policy adjudication after mirror ownership is restored")

setTrustedGCDState({
    [12345] = true,
    [22222] = true,
    [54321] = true,
})

local inactiveCooldownGCDIcon = {
    _spellEntry = {
        id = 22222,
        spellID = 22222,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode, sourceID = ResolveIconFields(inactiveCooldownGCDIcon)

assert(durObj == gcdDuration, "trusted isOnGCD should render GCD even when cooldown isActive is false")
assert(mode == "gcd-only", "inactive cooldown GCD state should resolve as gcd-only")
assert(sourceID == 22222, "inactive cooldown GCD source should be the runtime spellID")

local auraBackedCooldownIcon = {
    _blizzMirrorCooldownID = 888,
    _blizzMirrorCategory = "essential",
    _spellEntry = {
        id = 54321,
        spellID = 54321,
        viewerType = "essential",
        type = "spell",
    },
}

durObj, mode = ResolveIconFields(auraBackedCooldownIcon)

assert(durObj == auraChildFrameDuration, "child-frame aura mirror duration should be selected")
assert(mode == "aura", "child-frame aura mirror source should resolve as aura mode even during GCD")

mirrorSource = "aura-related-child"
durObj, mode = ResolveIconFields(auraBackedCooldownIcon)

assert(durObj == auraChildFrameDuration, "related-child aura mirror duration should be selected")
assert(mode == "aura", "related-child aura mirror source should resolve as aura mode")

local auraMirrorIcon = {
    _blizzMirrorCooldownID = 889,
    _blizzMirrorCategory = "buff",
    _spellEntry = {
        id = 70765,
        spellID = 70765,
        viewerType = "buff",
        kind = "aura",
        type = "spell",
    },
}

local mirrorBacked, mirrorPayload
durObj, mode, sourceID, _, _, _, mirrorBacked, mirrorPayload =
    ResolveIconFields(auraMirrorIcon)

assert(durObj == auraMirrorDuration, "valid aura mirror should bypass aura resolver adjudication")
assert(mode == "aura", "valid aura mirror should pass its own mode to render")
assert(sourceID == "mirror:889:13", "valid aura mirror should keep its mirror source key")
assert(mirrorBacked == true, "valid aura mirror should mark the result mirror-backed")
assert(mirrorPayload and mirrorPayload.state and mirrorPayload.state.durObj == auraMirrorDuration,
    "valid aura mirror should pass the mirror payload through to render")
assert(mirrorPayload.auraData == auraMirrorData,
    "valid aura mirror should resolve auraData from the stamped auraInstanceID")
assert(auraDataQueryCount == 1,
    "valid aura mirror should query auraData exactly once for the payload")

auraDataQueryCount = 0
function InCombatLockdown() return true end
durObj, mode, sourceID, _, _, _, mirrorBacked, mirrorPayload =
    ResolveIconFields(auraMirrorIcon)
function InCombatLockdown() return false end

assert(durObj == auraMirrorDuration, "combat aura mirror should still keep the DurationObject")
assert(mirrorPayload.auraData == auraMirrorData,
    "combat aura mirror should resolve auraData from the stamped auraInstanceID")
assert(auraDataQueryCount == 1,
    "combat aura mirror should query auraData by non-secret auraInstanceID")

auraDataQueryCount = 0
local directAuraDataMirrorIcon = {
    _blizzMirrorCooldownID = 891,
    _blizzMirrorCategory = "buff",
    _spellEntry = {
        id = 70766,
        spellID = 70766,
        viewerType = "buff",
        kind = "aura",
        type = "spell",
    },
}
durObj, mode, sourceID, _, _, _, mirrorBacked, mirrorPayload =
    ResolveIconFields(directAuraDataMirrorIcon)

assert(durObj == auraMirrorDuration, "direct child auraData mirror should keep the mirror DurationObject")
assert(mirrorPayload.auraData == auraMirrorData,
    "direct child auraData mirror should pass through the child-sourced auraData")
assert(auraDataQueryCount == 0,
    "direct child auraData mirror should not re-query auraData by auraInstanceID")

auraDataQueryCount = 0
function InCombatLockdown() return true end
durObj, mode, sourceID, _, _, _, mirrorBacked, mirrorPayload =
    ResolveIconFields(directAuraDataMirrorIcon)
function InCombatLockdown() return false end

assert(durObj == auraMirrorDuration, "combat direct child auraData mirror should keep the mirror DurationObject")
assert(mirrorPayload.auraData == auraMirrorData,
    "combat direct child auraData mirror should pass through child-sourced auraData")
assert(auraDataQueryCount == 0,
    "combat direct child auraData mirror should not query auraData by auraInstanceID")

cooldownQueryCounts[232323] = nil
local inactiveMirrorIcon = {
    _blizzMirrorCooldownID = 890,
    _blizzMirrorCategory = "essential",
    _spellEntry = {
        id = 232323,
        spellID = 232323,
        viewerType = "essential",
        kind = "cooldown",
        type = "spell",
    },
}

durObj, mode, sourceID, _, _, _, mirrorBacked, mirrorPayload =
    ResolveIconFields(inactiveMirrorIcon)

assert(durObj == nil, "inactive valid mirror should not be replaced by live GCD duration")
assert(mode == "inactive", "inactive valid mirror should pass inactive state to render")
assert(sourceID == "mirror:890:14", "inactive valid mirror should keep its mirror source key")
assert(mirrorBacked == true, "inactive valid mirror should still mark the result mirror-backed")
assert(mirrorPayload and mirrorPayload.active == false,
    "inactive valid mirror should pass inactive payload through to render")
assert(cooldownQueryCounts[232323] == nil,
    "inactive valid mirror should bypass live cooldown state queries")

local trackedBarEntry = {
    id = 67890,
    spellID = 67890,
    viewerType = "trackedBar",
    type = "spell",
}
local trackedBarIcon = {
    _spellEntry = trackedBarEntry,
}

durObj, mode = ResolveIconFields(trackedBarIcon)

assert(durObj == nil, "trackedBar entries should not resolve a cooldown DurationObject from cooldown APIs")
assert(mode == "inactive", "trackedBar entries should use aura shape, not real-cooldown shape")
assert(cooldownQueryCounts[67890] == nil,
    "trackedBar entries should not query spell cooldown state as real-cooldown entries")

print("OK: cdm_resolvers_gcd_mirror_test")
