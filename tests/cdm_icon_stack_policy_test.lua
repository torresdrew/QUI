-- tests/cdm_icon_stack_policy_test.lua
-- Run: lua tests/cdm_icon_stack_policy_test.lua

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
assert(loadfile("modules/cdm/cdm_icon_stack_text.lua"))("QUI", ns)
assert(loadfile("modules/cdm/cdm_icon_stack_policy.lua"))("QUI", ns)

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
local text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == "6", "mirror stack text should win over API fallback")
assert(source == "Applications", "mirror stack source should be preserved")
assert(mirrorBacked == true, "mirror stack resolution should mark mirror authority")

mirrorStates["43:essential"] = {
    stackTextShown = false,
    stackTextSource = "ChargeCount",
}
icon._blizzMirrorCooldownID = 43
text, source, mirrorBacked = policy:ResolveIconStackText(icon)
assert(text == nil, "mirror-hidden stack text should resolve empty")
assert(source == "ChargeCount", "mirror-hidden stack source should be preserved")
assert(mirrorBacked == true, "mirror-hidden stack should remain authoritative")

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

renderedIcon, writes = makeIcon({ kind = "cooldown", viewerType = "essential" })
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

spellCounts[500] = 3
local count, countSource = policy:GetSpellCountForEntry(500, nil, {})
assert(count == 3, "spell count fallback should return positive action-button counts")
assert(countSource == "spell-cast-count", "spell count fallback should report its source")

print("OK: cdm_icon_stack_policy_test")
