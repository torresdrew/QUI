-- cdm_debug.lua
-- Debug / event-trace helpers for the QUI CDM owned engine.
-- Loaded after cdm_icons.lua so ns.CDMIcons and ns.CDMIconFactory are
-- both populated; functions are attached to the existing CDMIcons table
-- so call sites in cdm_icons.lua and cdm_icon_factory.lua resolve as
-- before.

local _, ns = ...

local CDMIcons    = ns.CDMIcons
local iconPools   = ns.CDMIconFactory and ns.CDMIconFactory._iconPools or {}
local GetTime     = GetTime
local C_Spell     = C_Spell
local C_Item      = C_Item

---------------------------------------------------------------------------
-- VALUE FORMATTING
---------------------------------------------------------------------------
function CDMIcons.EventTraceValue(value)
    if value == nil then return "nil" end
    return tostring(value)
end

function CDMIcons.EventTraceSpellIDMatches(targetID, value)
    if not targetID or value == nil then return false end
    return value == targetID
end

---------------------------------------------------------------------------
-- ICON / ITEM MATCHING
---------------------------------------------------------------------------
function CDMIcons.EventTraceIconMatches(icon, targetID)
    local entry = icon and icon._spellEntry
    if not entry or not targetID then return false end
    if CDMIcons.EventTraceSpellIDMatches(targetID, icon._runtimeSpellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.overrideSpellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.spellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.id) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.itemID) then return true end
    if (entry.type == "trinket" or entry.type == "slot") and GetInventoryItemID then
        local itemID = GetInventoryItemID("player", entry.id)
        if CDMIcons.EventTraceSpellIDMatches(targetID, itemID) then return true end
    end
    return false
end

function CDMIcons.EventTraceItemUseSpellMatches(targetID, value)
    if not targetID or value == nil then return false end
    local spellID = value
    if not spellID then return false end

    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            local entry = icon and icon._spellEntry
            if CDMIcons.EventTraceIconMatches(icon, targetID)
               and CDMIcons.IsItemLikeEntry(entry) then
                local _, _, itemSpellID = CDMIcons.ResolveItemCooldownIdentity(entry)
                if itemSpellID == spellID then
                    return true
                end
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- FRAME-EVENT FILTER
---------------------------------------------------------------------------
function CDMIcons.EventTraceShouldPrintFrameEvent(event, arg1, arg2, arg3)
    local targetID = CDMIcons._eventTraceSpellID
    if not targetID then return false end

    if event == "UNIT_SPELLCAST_START"
       or event == "UNIT_SPELLCAST_STOP"
       or event == "UNIT_SPELLCAST_SUCCEEDED"
       or event == "UNIT_SPELLCAST_CHANNEL_START"
       or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        return arg1 == "player" and (
            CDMIcons.EventTraceSpellIDMatches(targetID, arg2)
            or CDMIcons.EventTraceSpellIDMatches(targetID, arg3)
            or CDMIcons.EventTraceItemUseSpellMatches(targetID, arg2)
            or CDMIcons.EventTraceItemUseSpellMatches(targetID, arg3)
        )
    end

    return true
end

---------------------------------------------------------------------------
-- SUMMARIES
---------------------------------------------------------------------------
function CDMIcons.EventTraceIconSummary(targetID)
    local parts = {}
    local matches = 0
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if CDMIcons.EventTraceIconMatches(icon, targetID) then
                matches = matches + 1
                if #parts < 3 then
                    local entry = icon._spellEntry
                    local shown = icon.IsShown and icon:IsShown() and "shown" or "hidden"
                    parts[#parts + 1] = string.format(
                        "%s/%s %s mode=%s aura=%s cd=%s real=%s gcd=%s key=%s",
                        tostring(entry.name or "?"),
                        tostring(entry.viewerType or "?"),
                        shown,
                        tostring(icon._resolvedCooldownMode),
                        tostring(icon._auraActive == true),
                        tostring(icon._hasCooldownActive == true),
                        tostring(icon._hasRealCooldownActive == true),
                        tostring(icon._showingGCDSwipe == true),
                        tostring(icon._lastDurObjKey))
                end
            end
        end
    end
    if matches == 0 then return "icons=0" end
    local more = matches > #parts and string.format(" +%d more", matches - #parts) or ""
    return string.format("icons=%d [%s%s]", matches, table.concat(parts, " | "), more)
end

function CDMIcons.EventTraceAPISummary(spellID)
    local cdActive, cdOnGCD = nil, nil
    local chargeActive, currentCharges, maxCharges = nil, nil, nil
    local usable, noMana = nil, nil
    local itemStart, itemDuration, itemEnabled = nil, nil, nil
    local itemSpellID = CDMIcons.GetItemUseSpellID(spellID)
    local itemSpellCdActive, itemSpellCdOnGCD = nil, nil

    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, cdInfo = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok and cdInfo then
            cdActive = CDMIcons.GetCooldownInfoField(cdInfo, "isActive")
            cdOnGCD = cdInfo.isOnGCD
        end
        if itemSpellID then
            local okItemSpell, itemSpellCdInfo = pcall(C_Spell.GetSpellCooldown, itemSpellID)
            if okItemSpell and itemSpellCdInfo then
                itemSpellCdActive = CDMIcons.GetCooldownInfoField(itemSpellCdInfo, "isActive")
                itemSpellCdOnGCD = itemSpellCdInfo.isOnGCD
            end
        end
    end
    if C_Spell and C_Spell.GetSpellCharges then
        local ok, chargeInfo = pcall(C_Spell.GetSpellCharges, spellID)
        if ok and chargeInfo then
            chargeActive = chargeInfo.isActive
            currentCharges = chargeInfo.currentCharges
            maxCharges = chargeInfo.maxCharges
        end
    end
    if C_Spell and C_Spell.IsSpellUsable then
        local ok, isUsable, isNoMana = pcall(C_Spell.IsSpellUsable, spellID)
        if ok then
            usable = isUsable
            noMana = isNoMana
        end
    end
    if C_Item and C_Item.GetItemCooldown then
        local ok, startTime, duration, enabled = pcall(C_Item.GetItemCooldown, spellID)
        if ok then
            itemStart = startTime
            itemDuration = duration
            itemEnabled = enabled
        end
    end

    return string.format(
        "api cdActive=%s isOnGCD=%s charges=%s/%s chargeActive=%s usable=%s noMana=%s itemCd=%s/%s/%s itemSpell=%s itemSpellCd=%s/%s",
        CDMIcons.EventTraceValue(cdActive),
        CDMIcons.EventTraceValue(cdOnGCD),
        CDMIcons.EventTraceValue(currentCharges),
        CDMIcons.EventTraceValue(maxCharges),
        CDMIcons.EventTraceValue(chargeActive),
        CDMIcons.EventTraceValue(usable),
        CDMIcons.EventTraceValue(noMana),
        CDMIcons.EventTraceValue(itemStart),
        CDMIcons.EventTraceValue(itemDuration),
        CDMIcons.EventTraceValue(itemEnabled),
        CDMIcons.EventTraceValue(itemSpellID),
        CDMIcons.EventTraceValue(itemSpellCdActive),
        CDMIcons.EventTraceValue(itemSpellCdOnGCD))
end

function CDMIcons.EventTraceAuraInfo(updateInfo)
    if type(updateInfo) ~= "table" then return "auraInfo=nil" end
    local added = type(updateInfo.addedAuras) == "table" and #updateInfo.addedAuras or 0
    local updated = type(updateInfo.updatedAuraInstanceIDs) == "table" and #updateInfo.updatedAuraInstanceIDs or 0
    local removed = type(updateInfo.removedAuraInstanceIDs) == "table" and #updateInfo.removedAuraInstanceIDs or 0
    return string.format(
        "aura full=%s added=%d updated=%d removed=%d",
        CDMIcons.EventTraceValue(updateInfo.isFullUpdate),
        added, updated, removed)
end

---------------------------------------------------------------------------
-- PRINT
---------------------------------------------------------------------------
function CDMIcons.EventTracePrint(source, event, arg1, arg2, arg3, extra)
    local targetID = CDMIcons._eventTraceSpellID
    if not targetID then return end
    local frameSource = source == "frame" or source == "frame-pre" or source == "frame-post"
    if frameSource and not CDMIcons.EventTraceShouldPrintFrameEvent(event, arg1, arg2, arg3) then
        return
    end

    local now = GetTime and GetTime() or 0
    local start = CDMIcons._eventTraceStartedAt or now
    print(string.format(
        "|cff34d399[cdmevents]|r +%.3f sid=%d %s:%s args=(%s,%s,%s) %s %s %s",
        now - start,
        targetID,
        tostring(source or "?"),
        tostring(event or "?"),
        CDMIcons.EventTraceValue(arg1),
        CDMIcons.EventTraceValue(arg2),
        CDMIcons.EventTraceValue(arg3),
        CDMIcons.EventTraceAPISummary(targetID),
        CDMIcons.EventTraceIconSummary(targetID),
        extra or ""))
end

---------------------------------------------------------------------------
-- ICON-DEBUG HELPERS
-- Cheap text-print helpers for /run QUI_CDM_ICON_DEBUG = "spell name"
-- workflow. ShouldDebugIcon lives in cdm_icons.lua because the swipe and
-- icon-dump paths there reference it directly; it's exposed on CDMIcons
-- so this file can share it.
---------------------------------------------------------------------------
function CDMIcons.ShouldDebugSpell(spellID, spellName)
    local dbg = _G.QUI_CDM_ICON_DEBUG
    if not dbg then return false end
    if dbg == true then return true end
    local filter = tostring(dbg):lower()
    if spellID and tostring(spellID) == filter then return true end
    local name = spellName and tostring(spellName):lower() or ""
    return name ~= "" and name:find(filter, 1, true) ~= nil
end

function CDMIcons.DebugSpellEvent(spellID, spellName, label, ...)
    if not CDMIcons.ShouldDebugSpell(spellID, spellName) then return end
    print("|cff34D399[CDM-IconTrace]|r", tostring(label), tostring(spellName or "?"), "spellID=", tostring(spellID), ...)
end

function CDMIcons.DebugIconEvent(icon, label, ...)
    if not CDMIcons.ShouldDebugIcon(icon) then return end
    local now = GetTime()
    icon._debugEventTimes = icon._debugEventTimes or {}
    local last = icon._debugEventTimes[label]
    if last and (now - last) < 0.25 then return end
    icon._debugEventTimes[label] = now
    local entry = icon._spellEntry
    print("|cff34D399[CDM-IconTrace]|r", tostring(label),
        entry and (entry.name or "?") or "?",
        "viewer=", entry and tostring(entry.viewerType) or "nil",
        "entryID=", entry and tostring(entry.id) or "nil",
        ...)
end

function CDMIcons.DebugEntryBuild(entry, spellEntry, viewerType)
    if not CDMIcons.ShouldDebugSpell(spellEntry and (spellEntry.spellID or spellEntry.id), spellEntry and spellEntry.name) then return end
    print("|cff34D399[CDM-IconTrace]|r", "build",
        spellEntry and (spellEntry.name or "?") or "?",
        "viewer=", tostring(viewerType),
        "entryType=", entry and tostring(entry.type) or "nil",
        "entryID=", entry and tostring(entry.id) or "nil",
        "spellID=", spellEntry and tostring(spellEntry.spellID) or "nil",
        "kind=", spellEntry and tostring(spellEntry.kind) or "nil",
        "isAura=", spellEntry and tostring(spellEntry.isAura) or "nil")
end

function CDMIcons.DebugLayoutFilter(icon, filterHides, settings, effectiveOnCD)
    CDMIcons.DebugIconEvent(icon, "layout-filter",
        "hide=", tostring(filterHides and true or false),
        "effectiveOnCD=", tostring(effectiveOnCD),
        "dynamic=", tostring(settings and settings.dynamicLayout),
        "containerType=", tostring(settings and settings.containerType),
        "showOnlyOnCooldown=", tostring(settings and settings.showOnlyOnCooldown))
end
