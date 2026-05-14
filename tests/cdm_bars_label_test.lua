-- tests/cdm_bars_label_test.lua
-- Run: lua tests/cdm_bars_label_test.lua

local secretValueMT = {
    __eq = function()
        error("secret value compared")
    end,
    __lt = function()
        error("secret value compared")
    end,
    __le = function()
        error("secret value compared")
    end,
    __tostring = function()
        error("secret value stringified")
    end,
}

local function NewSecretValue(label)
    return setmetatable({ label = label }, secretValueMT)
end

local wrappedSecretStacks = { token = "wrapped-secret-stacks" }

local inCombatLockdown = false
function InCombatLockdown() return inCombatLockdown end
function CreateFrame()
    local frame = {}
    function frame:SetScript() end
    function frame:CreateAnimationGroup()
        local group = {}
        function group:CreateAnimation()
            return { SetDuration = function() end }
        end
        function group:SetLooping() end
        function group:SetScript() end
        return group
    end
    return frame
end

C_StringUtil = {
    WrapString = function(value, prefix, suffix)
        if getmetatable(value) == secretValueMT then
            if value.label == "empty" then
                return ""
            end
            return wrappedSecretStacks
        end
        if value == nil or value == "" then
            return ""
        end
        return prefix .. tostring(value) .. suffix
    end,
    TruncateWhenZero = function(value)
        if value == 0 then return nil end
        return value
    end,
}

local ns = {
    Helpers = {
        GetGeneralFont = function() return "Fonts\\FRIZQT__.TTF" end,
        GetGeneralFontOutline = function() return "" end,
        IsSecretValue = function(value)
            return getmetatable(value) == secretValueMT
        end,
    },
}

assert(loadfile("modules/cdm/cdm_bars.lua"))("QUI", ns)

local bars = assert(ns.CDMBars, "CDMBars table was not exported")
assert(bars.ApplyNameTextWithStacks == nil, "legacy bar stack label helper should not be exported")
local applyNameText = assert(bars.ApplyNameTextWithCount, "bar count label helper was not exported")

local calls = {}
local fontString = {
    SetFormattedText = function(self, formatString, ...)
        calls[#calls + 1] = {
            formatString = formatString,
            args = { ... },
        }
        return true
    end,
}

local secretStacks = NewSecretValue("stacks")
local ok, method = applyNameText(fontString, "Aura Name", {
    sinkText = secretStacks,
    shown = true,
    source = "display-count",
})

assert(ok == true, "secret display-count stack should be applied")
assert(method == "wrapped-count", "secret display-count stack should use C-side wrapping")
assert(calls[1].formatString == "%s%s", "secret stack suffix should be passed as a SetFormattedText argument")
assert(calls[1].args[1] == "Aura Name", "name should remain the first formatted arg")
assert(rawequal(calls[1].args[2], wrappedSecretStacks), "wrapped secret stack should be forwarded without Lua conversion")

calls = {}
local secretEmptyStacks = NewSecretValue("empty")
ok, method = applyNameText(fontString, "Aura Name", {
    sinkText = secretEmptyStacks,
    shown = true,
    source = "display-count",
})

assert(ok == true, "empty secret display-count stack should still write the name")
assert(method == "name-only", "empty secret display-count stack should not emit empty parentheses")
assert(calls[1].formatString == "%s", "empty secret display-count stack should use name-only formatting")

calls = {}
ok, method = applyNameText(fontString, "Aura Name", nil)

assert(ok == true, "missing stack should still write the name")
assert(method == "name-only", "missing stack should use name-only path")
assert(calls[1].formatString == "%s", "name-only path should not add stack punctuation")

calls = {}
ok, method = applyNameText(fontString, "Aura Name", {
    sinkText = secretStacks,
    shown = true,
    source = "mirror-stack-text",
})

assert(ok == true, "shared secret count payload should be applied")
assert(method == "wrapped-count", "shared secret count should use C-side wrapping")
assert(calls[1].formatString == "%s%s", "shared secret count should append through SetFormattedText")
assert(calls[1].args[1] == "Aura Name", "shared count should preserve the clean name argument")
assert(rawequal(calls[1].args[2], wrappedSecretStacks),
    "shared secret count should be wrapped C-side and forwarded without Lua conversion")

calls = {}
ok, method = applyNameText(fontString, "Aura Name", {
    value = 6,
    shown = true,
    source = "display-count",
})

assert(ok == true, "shared count payload should use the safe numeric value when sink text is absent")
assert(method == "wrapped-count", "shared display count value should use count formatting")
assert(calls[1].formatString == "%s%s", "shared display count should append to the name")
assert(calls[1].args[2] == " (6)", "shared count value should be the rendered suffix")

local capturedParams
ns.CDMSpellData = {
    IsAuraEntry = function(entry, viewerType)
        return entry and entry.kind == "aura" and viewerType == "trackedBar"
    end,
    ResolveAuraState = function(_, params)
        capturedParams = params
        return { isActive = false }
    end,
}

local bar = {
    _spellID = 195182,
    _spellEntry = {
        id = 195182,
        spellID = 195182,
        name = "Marrowrend",
        kind = "aura",
        type = "spell",
        viewerType = "trackedBar",
        cooldownID = 5872,
    },
}

bars:UpdateOwnedBarAura(bar)

assert(capturedParams, "bar update should call ResolveAuraState")
assert(capturedParams.blizzardMirrorCooldownID == 5872,
    "bar resolver params should carry the exact mirror cooldownID")
assert(capturedParams.blizzardMirrorCategory == "trackedBar",
    "bar resolver params should carry the exact mirror category")

capturedParams = nil
bar._spellEntry.viewerType = "customBar"
bar._spellEntry.cooldownID = 91002

bars:UpdateOwnedBarAura(bar)

assert(capturedParams, "custom bar update should call ResolveAuraState")
assert(capturedParams.blizzardMirrorCooldownID == 91002,
    "custom bar resolver params should still carry the exact mirror cooldownID")
assert(capturedParams.blizzardMirrorCategory == nil,
    "custom bar resolver params should not invent a non-native mirror category")

local sharedIdentityEntry
ns.CDMResolvers = {
    ResolveBlizzardMirrorIdentity = function(entry)
        sharedIdentityEntry = entry
        return 73542, "buff"
    end,
}
capturedParams = nil
bar._spellEntry = {
    id = 1242998,
    spellID = 1242998,
    name = "Blood Shield",
    kind = "aura",
    type = "spell",
    viewerType = "customBar",
}
bar._spellID = 1242998

bars:UpdateOwnedBarAura(bar)

assert(sharedIdentityEntry == bar._spellEntry,
    "bar aura update should use the shared entry mirror identity resolver")
assert(capturedParams.blizzardMirrorCooldownID == 73542,
    "bar resolver params should carry shared mirror cooldownID")
assert(capturedParams.blizzardMirrorCategory == "buff",
    "bar resolver params should carry shared mirror category")

local barMirrorDuration = { token = "bar-mirror-duration" }
local barMirrorAuraData = { icon = 98765 }
local mirrorPayloadEntry
local mirrorPayloadCooldownID
local mirrorPayloadCategory
local mirrorPayloadSpellID
local resolveAuraStateCalls = 0
local appliedMirrorAuraTexture
ns.CDMResolvers = {
    ResolveBlizzardMirrorIdentity = function(entry)
        sharedIdentityEntry = entry
        return 73543, "trackedBar"
    end,
    ResolveMirrorRenderPayloadForEntry = function(entry, cooldownID, category, spellID)
        mirrorPayloadEntry = entry
        mirrorPayloadCooldownID = cooldownID
        mirrorPayloadCategory = category
        mirrorPayloadSpellID = spellID
        return {
            mirrorBacked = true,
            active = true,
            mode = "aura",
            durObj = barMirrorDuration,
            auraUnit = "target",
            auraData = barMirrorAuraData,
            hasExpirationTime = true,
            count = {
                value = 4,
                sinkText = 4,
                shown = true,
                source = "mirror-text",
            },
            state = {
                cooldownID = cooldownID,
                viewerCategory = category,
                durObj = barMirrorDuration,
            },
        }
    end,
}
ns.CDMSpellData.ResolveAuraState = function()
    resolveAuraStateCalls = resolveAuraStateCalls + 1
    return { isActive = false }
end

bar._spellEntry = {
    id = 343294,
    spellID = 343294,
    name = "Soul Reaper",
    kind = "aura",
    type = "spell",
    viewerType = "trackedBar",
}
bar._spellID = 343294
bar.IconTexture = {
    SetTexture = function(_, texture)
        appliedMirrorAuraTexture = texture
    end,
}

bars:UpdateOwnedBarAura(bar)

assert(sharedIdentityEntry == bar._spellEntry,
    "bar mirror payload lookup should use the shared mirror identity resolver")
assert(mirrorPayloadEntry == bar._spellEntry,
    "bar mirror payload lookup should receive the bar entry")
assert(mirrorPayloadCooldownID == 73543,
    "bar mirror payload lookup should receive the resolved mirror cooldownID")
assert(mirrorPayloadCategory == "trackedBar",
    "bar mirror payload lookup should receive the resolved mirror category")
assert(mirrorPayloadSpellID == 343294,
    "bar mirror payload lookup should receive the bar spellID")
assert(resolveAuraStateCalls == 0,
    "valid bar mirror payload should bypass ResolveAuraState adjudication")
assert(bar._active == true, "valid bar mirror payload should render as active")
assert(bar._auraDataUnit == "target", "valid bar mirror payload should pass aura unit to render")
assert(appliedMirrorAuraTexture == 98765,
    "valid bar mirror payload should pass auraData through to runtime texture rendering")

local spellCooldownDurObj = { token = "spell-cooldown-duration" }
local spellCooldownTimerDuration
local spellCooldownAuraStateCalls = 0
local spellCooldownQueryID
ns.CDMResolvers = {
    ResolveBlizzardMirrorIdentity = function()
        return nil
    end,
    ResolveMirrorRenderPayloadForEntry = function()
        return nil
    end,
    QueryCooldown = function(spellID)
        spellCooldownQueryID = spellID
        return { isActive = true, isOnGCD = false }
    end,
    QueryChargeDuration = function()
        return nil
    end,
    QueryDuration = function(spellID)
        spellCooldownQueryID = spellID
        return spellCooldownDurObj
    end,
}
ns.CDMSpellData.ResolveAuraState = function()
    spellCooldownAuraStateCalls = spellCooldownAuraStateCalls + 1
    return { isActive = false }
end
ns.CDMSpellData.ResolveDisplayName = function(_, entry)
    return entry and entry.name
end

local spellCooldownBar = {
    _spellID = 47528,
    _spellEntry = {
        id = 47528,
        spellID = 47528,
        name = "Mind Freeze",
        kind = "cooldown",
        type = "spell",
        viewerType = "customBar",
    },
    StatusBar = {
        SetMinMaxValues = function() end,
        SetValue = function() end,
        SetTimerDuration = function(_, durObj)
            spellCooldownTimerDuration = durObj
        end,
    },
    DurationText = {
        SetText = function() end,
        SetAlpha = function() end,
    },
    PermanentFill = {
        SetAlpha = function() end,
    },
    IconTexture = {
        SetTexture = function() end,
    },
    NameText = {
        SetText = function() end,
        SetFormattedText = function() end,
    },
}

bars:UpdateOwnedBarAura(spellCooldownBar)

assert(spellCooldownQueryID == 47528,
    "non-mirror spell cooldown bar should query the cooldown spellID")
assert(spellCooldownAuraStateCalls == 0,
    "non-mirror spell cooldown bar should not fall through to aura resolution")
assert(spellCooldownBar._active == true,
    "non-mirror spell cooldown bar should render active from cooldown state")
assert(spellCooldownBar._durObj == spellCooldownDurObj,
    "non-mirror spell cooldown bar should retain the cooldown DurationObject")
assert(spellCooldownTimerDuration == spellCooldownDurObj,
    "non-mirror spell cooldown bar should drive status-bar fill from the cooldown DurationObject")

local combatAuraDataDurObj = { token = "combat-auraData-duration" }
local combatAuraDataTimerDuration
local combatAuraData = {
    duration = NewSecretValue("duration"),
    icon = 87654,
}
ns.CDMResolvers = {
    ResolveBlizzardMirrorIdentity = function()
        return 80808, "trackedBar"
    end,
    ResolveMirrorRenderPayloadForEntry = function()
        return {
            mirrorBacked = true,
            active = true,
            mode = "aura",
            durObj = combatAuraDataDurObj,
            auraUnit = "player",
            auraData = combatAuraData,
            hasExpirationTime = true,
        }
    end,
}

local combatAuraDataBar = {
    _spellID = 80808,
    _spellEntry = {
        id = 80808,
        spellID = 80808,
        name = "Combat Aura",
        kind = "aura",
        type = "spell",
        viewerType = "trackedBar",
    },
    StatusBar = {
        SetMinMaxValues = function() end,
        SetValue = function() end,
        SetTimerDuration = function(_, durObj)
            combatAuraDataTimerDuration = durObj
        end,
    },
    DurationText = {
        SetText = function() end,
        SetAlpha = function() end,
    },
    PermanentFill = {
        SetAlpha = function() end,
    },
    IconTexture = {
        SetTexture = function() end,
    },
    NameText = {
        SetText = function() end,
        SetFormattedText = function() end,
    },
}

inCombatLockdown = true
ok = pcall(function()
    bars:UpdateOwnedBarAura(combatAuraDataBar)
end)
inCombatLockdown = false

assert(ok == true,
    "combat bar mirror should not compare secret fields from child-sourced auraData")
assert(combatAuraDataBar._active == true,
    "combat bar mirror should render active with child-sourced auraData")
assert(combatAuraDataTimerDuration == combatAuraDataDurObj,
    "combat bar mirror should still bind the child DurationObject")

local immediateRemaining = NewSecretValue("remaining-duration")
local immediateDurObj = {
    GetRemainingDuration = function()
        return immediateRemaining
    end,
}
local immediateDurationFormat
local immediateDurationValue
local immediateTimerDuration
local immediateTimerInterpolation
local immediateTimerDirection
local immediateMinMaxCalls = 0
ns.CDMResolvers = {
    ResolveBlizzardMirrorIdentity = function()
        return 48707, "trackedBar"
    end,
    ResolveMirrorRenderPayloadForEntry = function()
        return {
            mirrorBacked = true,
            active = true,
            mode = "aura",
            durObj = immediateDurObj,
            auraUnit = "player",
            hasExpirationTime = true,
        }
    end,
}

local immediateTextBar = {
    _spellID = 48707,
    _spellEntry = {
        id = 48707,
        spellID = 48707,
        name = "Immediate Text Aura",
        kind = "aura",
        type = "spell",
        viewerType = "trackedBar",
    },
    StatusBar = {
        SetMinMaxValues = function()
            immediateMinMaxCalls = immediateMinMaxCalls + 1
        end,
        SetValue = function() end,
        SetTimerDuration = function(_, durObj, interpolation, direction)
            immediateTimerDuration = durObj
            immediateTimerInterpolation = interpolation
            immediateTimerDirection = direction
        end,
    },
    DurationText = {
        SetText = function() end,
        SetAlpha = function() end,
        SetFormattedText = function(_, format, value)
            immediateDurationFormat = format
            immediateDurationValue = value
        end,
    },
    PermanentFill = {
        SetAlpha = function() end,
    },
    IconTexture = {
        SetTexture = function() end,
    },
    NameText = {
        SetText = function() end,
        SetFormattedText = function() end,
    },
}

inCombatLockdown = true
ok = pcall(function()
    bars:UpdateOwnedBarAura(immediateTextBar)
end)
inCombatLockdown = false

assert(ok == true,
    "combat bar mirror should write initial duration text without reading secrets in Lua")
assert(immediateTimerDuration == immediateDurObj,
    "immediate duration text bar should still bind the child DurationObject")
assert(immediateTimerInterpolation == 0,
    "bar DurationObject fill should use Immediate interpolation")
assert(immediateTimerDirection == 1,
    "bar DurationObject fill should use RemainingTime direction")
assert(immediateMinMaxCalls == 0,
    "bar DurationObject fill should leave status-bar range to SetTimerDuration")
assert(immediateDurationFormat == "%.1f",
    "active timed bar should write the first duration text immediately")
assert(rawequal(immediateDurationValue, immediateRemaining),
    "initial duration text should forward the secret remaining duration to the C-side formatter")

print("OK: cdm_bars_label_test")
