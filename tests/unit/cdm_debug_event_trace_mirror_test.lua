-- tests/unit/cdm_debug_event_trace_mirror_test.lua
-- Run: lua tests/unit/cdm_debug_event_trace_mirror_test.lua

SlashCmdList = {}

local now = 10
function GetTime()
    return now
end

function CreateFrame()
    return {
        SetSize = function() end,
        SetPoint = function() end,
        SetFrameStrata = function() end,
        EnableMouse = function() end,
        SetMovable = function() end,
        RegisterForDrag = function() end,
        SetScript = function() end,
        CreateTexture = function()
            return {
                SetAllPoints = function() end,
                SetColorTexture = function() end,
            }
        end,
        CreateFontString = function()
            return {
                SetPoint = function() end,
                SetJustifyH = function() end,
                SetText = function() end,
            }
        end,
    }
end

local mirrorState = {
    cooldownID = 71001,
    viewerCategory = "buff",
    spellID = 48707,
    overrideSpellID = 48707,
    overrideTooltipSpellID = 48707,
    linkedSpellIDs = { 48707 },
    isActive = true,
    resolvedMode = "aura",
    durObj = {},
    durObjSource = "aura-related-child",
    auraDurObjSource = "aura-related-child",
    auraInstanceID = 422,
    auraUnit = "player",
    mirrorEpoch = 12,
}

local icon = {
    _spellEntry = {
        id = 999001,
        spellID = 999001,
        overrideSpellID = 999002,
        cooldownID = 71001,
        name = "Mirror Backed",
        kind = "aura",
        type = "spell",
        viewerType = "buff",
        linkedSpellIDs = { 999003 },
    },
    _blizzMirrorCooldownID = 71001,
    _blizzMirrorCategory = "buff",
    _resolvedCooldownMode = "aura",
    _lastDurObjKey = "aura:mirror:71001:12",
    _lastAuraSourceID = "aura-related-child:71001:12",
    _auraInstanceID = 422,
    _auraUnit = "player",
    IsShown = function() return true end,
}

local ns = {
    CDMIcons = {
        IsRuntimeEnabled = function() return true end,
    },
    CDMIconFactory = {
        _iconPools = {
            { icon },
        },
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID, category)
            if cooldownID == 71001 and category == "buff" then
                return mirrorState
            end
        end,
    },
    CDMSources = {
        QuerySpellCooldown = function(spellID)
            if spellID == 444347 then
                return { isActive = true, isOnGCD = false }
            elseif spellID == 555001 then
                return { isActive = false, isOnGCD = false }
            end
            return nil
        end,
        QuerySpellCharges = function()
            return { currentCharges = 1, maxCharges = 2, isActive = true }
        end,
        QuerySpellUsable = function()
            return true, false
        end,
        QueryItemCooldown = function(itemID)
            if itemID == 444347 then
                return 10, 30, 1
            end
            return nil, nil, nil
        end,
        QueryItemSpell = function(itemID)
            if itemID == 444347 then
                return "Debug Item Use", 555001
            end
            return nil, nil
        end,
    },
    CDMResolvers = {
        GetCooldownInfoField = function(info, key)
            return info and info[key], false
        end,
    },
}

assert(loadfile("QUI_Debug/cdm_debug.lua"))("QUI_Debug", ns)

assert(ns.CDMIcons.EventTraceIconMatches(icon, 999001) == true,
    "event trace should still match the entry spell ID")
assert(ns.CDMIcons.EventTraceIconMatches(icon, 48707) == true,
    "event trace should match a Blizzard-backed child spell ID")
assert(ns.CDMIcons.EventTraceIconMatches(icon, 71001) == true,
    "event trace should match a Blizzard-backed child cooldownID")
assert(ns.CDMIcons.EventTraceIconMatches(icon, 123456) == false,
    "event trace should reject unrelated IDs")

local summary = ns.CDMIcons.EventTraceIconSummary(48707)
assert(summary:find("icons=1", 1, true), "event trace summary should include the backed icon")
assert(summary:find("mirror=buff/71001", 1, true),
    "event trace summary should include the mirror child identity")
assert(summary:find("eid=999001", 1, true),
    "event trace summary should include the entry ID")
assert(summary:find("eov=999002", 1, true),
    "event trace summary should include the entry override ID")
assert(summary:find("elinks=999003", 1, true),
    "event trace summary should include entry linked spell IDs")

local writeState = ns.CDMIcons.EventTraceIconWriteState(icon)
assert(writeState:find("eid=999001", 1, true),
    "write trace state should include the entry ID")
assert(writeState:find("auraSource=aura-related-child:71001:12", 1, true),
    "write trace state should include the icon aura source")
assert(writeState:find("mirror=buff/71001", 1, true),
    "write trace state should include the mirror child identity")
assert(writeState:find("mauraSrc=aura-related-child", 1, true),
    "write trace state should include the mirror aura duration source")
assert(writeState:find("mInst=422", 1, true),
    "write trace state should include the mirror aura instance")

local apiSummaryOk, apiSummary = pcall(ns.CDMIcons.EventTraceAPISummary, 444347)
assert(apiSummaryOk,
    "event trace API summary should not require legacy CDMIcons helper exports: " .. tostring(apiSummary))
assert(apiSummary:find("cdActive=true", 1, true),
    "event trace API summary should read cooldown fields through the resolver seam")
assert(apiSummary:find("itemSpell=555001", 1, true),
    "event trace API summary should resolve item use spell IDs through source adapters")
assert(apiSummary:find("itemSpellCd=false/false", 1, true),
    "event trace API summary should include item-use spell cooldown state")

local captured = {}
local originalPrint = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    captured[#captured + 1] = table.concat(parts, " ")
end

SlashCmdList["QUI_CDMDEBUG"]("spell 48707 events 0.75")

assert(ns.CDMIcons._eventTraceSpellID == 48707,
    "/cdmdebug spell events should start tracing the requested spell ID")
assert(ns.CDMIcons._eventTraceMinInterval == 0.75,
    "/cdmdebug spell events should accept a trailing throttle interval")
assert(captured[1]:find("0.75s", 1, true),
    "/cdmdebug spell events should announce the selected throttle interval")

captured = {}

ns.CDMIcons._eventTraceSpellID = 48707
ns.CDMIcons._eventTraceStartedAt = 10
ns.CDMIcons._eventTraceMinInterval = 0.5
ns.CDMIcons._eventTraceLastPrintAt = {}
ns.CDMIcons._eventTraceSuppressed = {}

now = 10.00
ns.CDMIcons.EventTracePrint("frame", "SPELL_UPDATE_USABLE")
ns.CDMIcons.EventTracePrintWrite("Cooldown:SetDrawEdge", icon, "true")
now = 10.10
ns.CDMIcons.EventTracePrint("frame", "SPELL_UPDATE_USABLE")
ns.CDMIcons.EventTracePrintWrite("Cooldown:SetDrawEdge", icon, "false")
now = 10.60
ns.CDMIcons.EventTracePrint("frame", "SPELL_UPDATE_USABLE")
ns.CDMIcons.EventTracePrintWrite("Cooldown:SetDrawEdge", icon, "true")

print = originalPrint

assert(#captured == 4, "event trace throttle should allow one events line and one writes line per interval")
assert(captured[3]:find("throttled=1", 1, true),
    "event trace throttle should report suppressed event lines")
assert(captured[4]:find("throttled=1", 1, true),
    "event trace throttle should report suppressed write lines")

ns.CDMIcons._eventTraceSpellID = nil
ns.CDMIcons._eventTraceStartedAt = nil
ns.CDMIcons._eventTraceMinInterval = nil
ns.CDMIcons._eventTraceLastPrintAt = nil
ns.CDMIcons._eventTraceSuppressed = nil

print("OK: cdm_debug_event_trace_mirror_test")
