-- tests/unit/cdm_icon_stack_policy_test.lua
-- Run: lua tests/unit/cdm_icon_stack_policy_test.lua

local secretStackText = { token = "secret-stack-text" }

function issecretvalue(value)
    return value == secretStackText
end

function InCombatLockdown() return false end

function wipe(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

C_StringUtil = {
    TruncateWhenZero = function(value)
        return value == 0 and "" or tostring(value)
    end,
}

local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("modules/cdm/cdm_icon_renderer.lua", "cdm_icon_stack_text.lua")("QUI", ns)
loadChunk("modules/cdm/cdm_icon_renderer.lua", "cdm_icon_stack_policy.lua")("QUI", ns)

local policyModule = assert(ns.CDMIconStackPolicy, "CDMIconStackPolicy should be exported")

local mirrorStates = {}
local displayCounts = {}
local spellCounts = {}
local auraDisplayQueries = {}
local auraRuntime = {}
local sources = {}
local debugEvents = {}

local function makeIcon(entry)
    local writes = {}
    local icon = {
        _spellEntry = entry,
        StackText = {
            SetText = function(_, value)
                writes[#writes + 1] = { op = "set", value = value }
            end,
            Show = function()
                writes[#writes + 1] = { op = "show" }
            end,
            Hide = function()
                writes[#writes + 1] = { op = "hide" }
            end,
        },
    }
    return icon, writes
end

local policy = policyModule.Create({
    getSink = function() return ns.CDMIconStackText end,
    getSources = function() return sources end,
    getAuraRuntime = function() return auraRuntime end,
    getMirror = function()
        return {
            GetStateByCooldownID = function(cooldownID, category)
                return mirrorStates[tostring(cooldownID) .. ":" .. tostring(category)]
            end,
        }
    end,
    safeBoolean = function(value)
        if value == nil then return nil end
        return value and true or false
    end,
    isAuraEntry = function(entry)
        return entry and entry.kind == "aura"
    end,
    isBuiltinAuraContainerKey = function(containerKey)
        return containerKey == "buff" or containerKey == "trackedBar"
    end,
    resolveAuraActiveState = function(entry)
        if entry and entry.auraInstanceID then
            return true, entry.auraUnit or "player", entry.auraInstanceID
        end
        return false
    end,
    resolveMirrorIdentityState = function(entry)
        if entry and entry.identityCooldownID then
            return {
                cooldownID = entry.identityCooldownID,
                category = entry.identityCategory,
                state = entry.identityState,
            }
        end
        return nil
    end,
    getChargeMetadataDB = function()
        return { [200] = 2 }
    end,
    queryOverrideSpell = function(spellID)
        if spellID == 100 then return 200 end
        return nil
    end,
    queryDisplayCount = function(spellID)
        return displayCounts[spellID]
    end,
    querySpellCount = function(spellID)
        return spellCounts[spellID]
    end,
    getEntryTexture = function(entry)
        return entry and entry.icon
    end,
    getAuraDataInstanceID = function(auraData)
        return auraData and auraData.auraInstanceID
    end,
    getCachedSpellName = function(spellID)
        return spellID == 300 and "Cached Aura" or nil
    end,
    getTrackerSettings = function()
        return {}
    end,
    debugStackText = function(icon, op, value, reason)
        debugEvents[#debugEvents + 1] = { op = op, value = value, reason = reason }
    end,
})

mirrorStates["42:essential"] = {
    stackText = "6",
    stackTextSource = "Applications",
    stackTextShown = true,
}
local icon = {
    _blizzMirrorCooldownID = 42,
    _blizzMirrorCategory = "essential",
    _spellEntry = { kind = "cooldown", type = "spell", spellID = 100 },
}
displayCounts[200] = "9"
local text, source, mirrorBacked, mirrorHidden = policy:ResolveIconStackText(icon)
assert(text == nil, "cooldown mirror Applications text should not bleed into charge count")
assert(source == nil, "suppressed cooldown Applications source should not become a count source")
assert(mirrorBacked == true, "mirror stack resolution should mark mirror authority")
assert(mirrorHidden == true, "cooldown mirror state should remain authoritative when count text is absent")
displayCounts[200] = nil

mirrorStates["43:essential"] = {
    stackTextShown = false,
    stackTextSource = "ChargeCount",
}
icon._blizzMirrorCooldownID = 43
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == nil, "mirror-hidden stack text should resolve empty")
assert(source == "ChargeCount", "mirror-hidden stack source should be preserved")
assert(mirrorBacked == true, "mirror-hidden stack should remain authoritative")

mirrorStates["44:essential"] = {
    stackText = "2",
    stackTextSource = "ChargeCount",
    stackTextShown = true,
    cooldownChargesShown = false,
    chargeCountFrameShown = false,
}
icon._blizzMirrorCooldownID = 44
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == nil, "mirror-hidden ChargeCount visibility should suppress stale stack text")
assert(source == "ChargeCount", "suppressed ChargeCount source should be preserved")
assert(mirrorBacked == true, "suppressed ChargeCount stack should remain mirror authoritative")

mirrorStates["45:essential"] = {
    stackText = "8",
    stackTextSource = "ChargeCount",
    stackTextShown = false,
    cooldownChargesShown = false,
    chargeCountFrameShown = false,
}
icon._blizzMirrorCooldownID = 45
icon._runtimeSpellID = 100
displayCounts[200] = "8"
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == nil, "mirror-hidden non-charge cooldowns should not re-query display count")
assert(source == "ChargeCount", "mirror-hidden non-charge cooldowns should preserve mirror source")
assert(mirrorBacked == true, "mirror-hidden non-charge cooldowns should remain mirror authoritative")

local chargedIcon = {
    _blizzMirrorCooldownID = 45,
    _blizzMirrorCategory = "essential",
    _runtimeSpellID = 100,
    _spellEntry = { kind = "cooldown", type = "spell", spellID = 100, hasCharges = true },
}
text, source, mirrorBacked = policy:ResolveIconStackText(chargedIcon)
assert(text == nil, "charged spells should not replace hidden mirror ChargeCount with display count")
assert(source == "ChargeCount", "charged hidden ChargeCount source should be preserved")
assert(mirrorBacked == true, "charged hidden ChargeCount should remain mirror authoritative")
displayCounts[200] = nil

mirrorStates["46:essential"] = {
    stackText = "8",
    stackTextSource = "ChargeCount",
    stackTextShown = true,
    cooldownChargesShown = true,
    chargeCountFrameShown = false,
    wasSetFromCooldown = true,
    wasSetFromCharges = false,
}
icon._blizzMirrorCooldownID = 46
icon._runtimeSpellID = 55090
icon._spellEntry = { kind = "cooldown", type = "spell", spellID = 55090 }
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == "8", "non-charge cooldown text owner should survive hidden ChargeCount parent state")
assert(source == "ChargeCount", "mirrored child count text should keep its source")
assert(mirrorBacked == true, "mirrored child count text should remain mirror authoritative")
assert(icon.cooldownChargesCount == nil,
    "icon should not invent cooldownChargesCount when the mirror only has stack text")
assert(icon.cooldownChargesShown == true,
    "icon should mirror cooldownChargesShown from the mirror state")
assert(icon.stackText == "8", "icon should mirror stack text from the mirror state")
assert(icon.stackTextShown == true, "icon should mirror stack text shown-state from the mirror state")

mirrorStates["46:essential"].cooldownChargesShown = false
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == nil, "cooldownChargesShown false should suppress cooldown count text")
assert(source == "ChargeCount", "suppressed cooldown count text should keep its source")
assert(icon.cooldownChargesShown == false,
    "icon should update mirrored cooldownChargesShown when the mirror hides the count")
assert(icon.stackText == "8", "icon should preserve hidden mirror stack text for diagnostics")
assert(icon.stackTextShown == true,
    "icon stackTextShown should reflect the mirror state even when cooldownChargesShown hides it")

mirrorStates["47:essential"] = {
    cooldownChargesCount = 0,
    cooldownChargesShown = false,
    chargeTextOwnerShown = true,
    stackText = 0,
    stackTextShown = true,
}
icon._blizzMirrorCooldownID = 47
text, source, mirrorBacked, mirrorHidden = policy:ResolveIconStackText(icon)
assert(text == nil, "explicit hidden cooldown count should suppress a cached zero")
assert(source == "ChargeCount", "explicit hidden cooldown count should remain a ChargeCount decision")
assert(mirrorBacked == true, "explicit hidden cooldown count should remain mirror authoritative")
assert(mirrorHidden == true, "explicit hidden cooldown count should be reported hidden")

mirrorStates["48:essential"] = {
    cooldownChargesCount = "9",
    stackTextSource = "ChargeCount",
}
icon._blizzMirrorCooldownID = 48
text, source, mirrorBacked, mirrorHidden = policy:ResolveIconStackText(icon)
assert(text == nil, "cooldown count without explicit shown state should stay hidden")
assert(source == "ChargeCount", "hidden cooldown count without explicit shown state should keep its source")
assert(mirrorBacked == true, "hidden cooldown count without explicit shown state should remain mirror authoritative")
assert(mirrorHidden == true, "cooldown count without explicit shown state should report hidden")

icon._blizzMirrorCooldownID = nil
icon._runtimeSpellID = 100
displayCounts[200] = 2
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == 2, "multi-charge metadata should use spell display count")
assert(source == "ChargeCount", "multi-charge fallback should report ChargeCount")
assert(mirrorBacked == nil, "non-mirror fallback should not report mirror authority")

auraRuntime.GetApplications = function(unit, auraInstanceID)
    if unit == "target" and auraInstanceID == 9001 then
        return true, secretStackText
    end
    return false
end
local auraIcon = {
    _spellEntry = {
        kind = "aura",
        type = "spell",
        auraInstanceID = 9001,
        auraUnit = "target",
    },
}
text, source = policy:ResolveIconStackText(auraIcon)
assert(rawequal(text, secretStackText), "aura stack text should forward secret values unchanged")
assert(source == "Applications", "aura stack text should report Applications")

sources.QueryAuraApplicationDisplayCount = function(unit, auraInstanceID, minApplications)
    auraDisplayQueries[#auraDisplayQueries + 1] = {
        unit = unit,
        auraInstanceID = auraInstanceID,
        minApplications = minApplications,
    }
    return "4"
end
local apps, appSource = policy:GetAuraApplicationsFromData({
    applications = 1,
    auraInstanceID = 77,
}, "player", "aura-data")
assert(apps == "4", "aura data fallback should ask the display-count source")
assert(appSource == "display-count", "display-count fallback should identify its source")
assert(auraDisplayQueries[1].minApplications == 2,
    "display-count fallback should request displayable stacks only")

local renderedIcon, writes = makeIcon({ kind = "aura", viewerType = "buff" })
policy:ApplyAuraCountText(renderedIcon, {
    sinkText = secretStackText,
    value = 9,
    shown = true,
    source = "display-count",
}, false, false)
assert(rawequal(writes[1].value, secretStackText),
    "resolved count rendering should forward secret sink text unchanged")
assert(writes[2].op == "show", "resolved count rendering should show the FontString")
assert(renderedIcon._stackTextSource == "display-count",
    "resolved count rendering should stamp the source")

renderedIcon, writes = makeIcon({ kind = "aura", viewerType = "buff" })
renderedIcon._rowConfig = { hideStackText = true }
policy:ShowIconStackText(renderedIcon, "8", {}, "test-hide")
assert(writes[1].op == "set" and writes[1].value == "",
    "hidden stack settings should clear stack text")
assert(writes[2].op == "hide", "hidden stack settings should hide stack text")
assert(debugEvents[#debugEvents].reason == "test-hide",
    "hidden stack settings should debug the hide reason")

renderedIcon, writes = makeIcon({ kind = "aura", viewerType = "buff" })
local applied = policy:ApplyMirrorStackText(renderedIcon, {
    stackText = "5",
    stackTextShown = true,
    stackTextSource = "Applications",
    stackTextEpoch = 12,
}, false)
assert(applied == true, "mirror stack payload should apply when shown")
assert(writes[1].op == "set" and writes[1].value == "5",
    "mirror stack payload should write its stack text")
assert(renderedIcon._lastMirrorStackTextEpoch == 12,
    "mirror stack payload should stamp the mirror text epoch")

renderedIcon, writes = makeIcon({ kind = "cooldown", viewerType = "essential" })
applied = policy:ApplyMirrorStackText(renderedIcon, {
    cooldownChargesCount = "8",
    cooldownChargesShown = nil,
    chargeCountFrameShown = false,
    chargeTextOwnerShown = true,
    stackTextShown = false,
    stackTextSource = "ChargeCount",
    stackTextEpoch = 13,
    wasSetFromCooldown = true,
    wasSetFromCharges = false,
}, false)
assert(applied == false, "cooldown count text owner should not apply without visible parent count state")
assert(writes[1] == nil,
    "cooldown count text owner should not write without visible parent count state")

renderedIcon, writes = makeIcon({ kind = "cooldown", viewerType = "essential" })
applied = policy:ApplyMirrorStackText(renderedIcon, {
    cooldownChargesCount = "8",
    cooldownChargesShown = true,
    chargeCountFrameShown = false,
    chargeTextOwnerShown = false,
    stackTextShown = false,
    stackTextSource = "ChargeCount",
    stackTextEpoch = 14,
    wasSetFromCooldown = true,
    wasSetFromCharges = false,
}, false)
assert(applied == true, "explicit visible mirror cooldown count payload should apply")
assert(writes[1].op == "set" and writes[1].value == "8",
    "explicit visible mirror cooldown count payload should write the count text")
assert(writes[2].op == "show",
    "explicit visible mirror cooldown count payload should show the FontString")
assert(renderedIcon._lastMirrorStackTextEpoch == 14,
    "explicit visible mirror cooldown count payload should stamp the mirror text epoch")

spellCounts[500] = 3
local count, countSource = policy:GetSpellCountForEntry(500, nil, {})
assert(count == 3, "spell count fallback should return positive action-button counts")
assert(countSource == "spell-cast-count", "spell count fallback should report its source")

print("OK: cdm_icon_stack_policy_test")
