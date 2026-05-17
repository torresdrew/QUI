-- cdm_debug.lua
-- Single home for the QUI CDM owned-engine debug surface.
--
-- Loaded last among the engine files in cdm.xml, so it can:
--   * Attach functions onto the engine module tables (ns.CDMIcons,
--     ns.CDMBlizzMirror, etc.) that other files have already populated.
--   * Reach into engine internals (iconPools, ns.CDMSpellData, ...) at
--     call time without forward-reference juggling.
--
-- Slash command:
--   /cdmdebug                       List command groups and subsystem flags.
--   /cdmdebug flags <name> [...]    Toggle icon/bar/blizz/aura/charge/totem/taint flags.
--   /cdmdebug spell <target> [...]  One-spell report/watch/events/trace/charge/flicker.
--   /cdmdebug mirror [...]          Mirror info, child dumps, raw dumps, cooldown tests.
--   /cdmdebug cache [status|reset]  CDM cache status/reset via the always-loaded support path.
--   /cdmdebug profile [status|clean] Dump or clean CDM profile/spec state.
--   /cdmdebug probe                 Resolver/mirror parity sweep.

local _, ns = ...

local Helpers     = ns.Helpers
local CDMIcons    = ns.CDMIcons
local iconPools   = ns.CDMIconFactory and ns.CDMIconFactory._iconPools or {}
local Sources     = ns.CDMSources
local Resolvers   = ns.CDMResolvers
local GetTime     = GetTime

local function TrimText(text)
    return (text and tostring(text) or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function DebugIsSecretValue(value)
    if Helpers and Helpers.IsSecretValue then
        local ok, isSecret = pcall(Helpers.IsSecretValue, value)
        if ok and isSecret then return true end
    end
    if issecretvalue then
        local ok, isSecret = pcall(issecretvalue, value)
        if ok and isSecret then return true end
    end
    return false
end

local function EventTraceCooldownInfoField(info, key)
    if Resolvers and Resolvers.GetCooldownInfoField then
        return Resolvers.GetCooldownInfoField(info, key)
    end
    if not info then return nil, false end

    local value = info[key]
    if DebugIsSecretValue(value) then
        return value, true
    end
    return value, false
end

local function EventTraceGetItemUseSpellID(itemID)
    if not itemID then return nil end

    if Sources and Sources.QueryItemSpell then
        local _, spellID = Sources.QueryItemSpell(itemID)
        if spellID then
            return spellID
        end
    end

    if Sources and Sources.QueryFirstTriggeredSpellForItem then
        local itemQuality
        if Sources.QueryItemQualityByID then
            local quality = Sources.QueryItemQualityByID(itemID)
            if quality ~= nil then
                itemQuality = quality
            end
        end

        local spellID = Sources.QueryFirstTriggeredSpellForItem(itemID, itemQuality)
        if spellID then
            return spellID
        end
    end

    return nil
end

local function EventTraceIsItemLikeEntry(entry)
    return entry and (entry.type == "item" or entry.type == "trinket" or entry.type == "slot")
end

local function EventTraceResolveItemCooldownIdentity(entry)
    if not entry then return nil, nil, nil, nil end

    local itemID, slotID
    if entry.type == "item" then
        itemID = entry.id
    elseif entry.type == "trinket" or entry.type == "slot" then
        slotID = entry.id
        if Sources and Sources.QueryInventoryItemID then
            itemID = Sources.QueryInventoryItemID("player", slotID)
        end
        itemID = itemID or entry.itemID
    elseif entry.type == "macro" and Resolvers and Resolvers.ResolveMacro then
        local resolvedID, resolvedType = Resolvers.ResolveMacro(entry)
        if resolvedType == "item" then
            itemID = resolvedID
        end
    end

    if not itemID then return nil, slotID, nil, nil end

    local itemSpellID = EventTraceGetItemUseSpellID(itemID)
    local keySource = slotID and (tostring(slotID) .. ":" .. tostring(itemID)) or tostring(itemID)
    return itemID, slotID, itemSpellID, keySource
end

---------------------------------------------------------------------------
-- VALUE FORMATTING (event-trace)
---------------------------------------------------------------------------
function CDMIcons.EventTraceValue(value)
    if DebugIsSecretValue(value) then return "<SECRET:" .. type(value) .. ">" end
    if value == nil then return "nil" end
    return tostring(value)
end

function CDMIcons.EventTraceSpellIDMatches(targetID, value)
    if not targetID or value == nil then return false end
    return value == targetID
end

---------------------------------------------------------------------------
-- ICON / ITEM MATCHING (event-trace)
---------------------------------------------------------------------------
local function EventTraceIDList(ids)
    if type(ids) ~= "table" or #ids == 0 then return "nil" end
    local out = {}
    for i, id in ipairs(ids) do
        out[i] = tostring(id)
    end
    return table.concat(out, ",")
end

local function EventTraceMirrorState(icon)
    local mirror = ns.CDMBlizzMirror
    if not (icon and icon._blizzMirrorCooldownID
        and mirror and mirror.GetStateByCooldownID) then
        return nil
    end
    return mirror.GetStateByCooldownID(icon._blizzMirrorCooldownID, icon._blizzMirrorCategory)
end

local function EventTraceMirrorStateMatches(targetID, state)
    if not (targetID and state) then return false end
    if CDMIcons.EventTraceSpellIDMatches(targetID, state.cooldownID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, state.spellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, state.overrideSpellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, state.overrideTooltipSpellID) then return true end
    if type(state.linkedSpellIDs) == "table" then
        for _, linkedID in ipairs(state.linkedSpellIDs) do
            if CDMIcons.EventTraceSpellIDMatches(targetID, linkedID) then return true end
        end
    end
    return false
end

function CDMIcons.EventTraceIconMatches(icon, targetID)
    local entry = icon and icon._spellEntry
    if not entry or not targetID then return false end
    if CDMIcons.EventTraceSpellIDMatches(targetID, icon._runtimeSpellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.overrideSpellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.spellID) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.id) then return true end
    if CDMIcons.EventTraceSpellIDMatches(targetID, entry.itemID) then return true end
    if (entry.type == "trinket" or entry.type == "slot")
       and Sources and Sources.QueryInventoryItemID then
        local itemID = Sources.QueryInventoryItemID("player", entry.id)
        if CDMIcons.EventTraceSpellIDMatches(targetID, itemID) then return true end
    end
    if EventTraceMirrorStateMatches(targetID, EventTraceMirrorState(icon)) then return true end
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
               and EventTraceIsItemLikeEntry(entry) then
                local _, _, itemSpellID = EventTraceResolveItemCooldownIdentity(entry)
                if itemSpellID == spellID then
                    return true
                end
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- FRAME-EVENT FILTER (event-trace)
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
-- SUMMARIES (event-trace)
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
                    local m = EventTraceMirrorState(icon)
                    local shown = icon.IsShown and icon:IsShown() and "shown" or "hidden"
                    parts[#parts + 1] = string.format(
                        "%s/%s %s eid=%s espell=%s eov=%s ecid=%s runtime=%s kind=%s type=%s elinks=%s mode=%s aura=%s cd=%s real=%s gcd=%s key=%s mirror=%s/%s mspell=%s mov=%s mtooltip=%s mlinks=%s",
                        tostring(entry.name or "?"),
                        tostring(entry.viewerType or "?"),
                        shown,
                        tostring(entry.id),
                        tostring(entry.spellID),
                        tostring(entry.overrideSpellID),
                        tostring(entry.cooldownID),
                        tostring(icon._runtimeSpellID),
                        tostring(entry.kind),
                        tostring(entry.type),
                        EventTraceIDList(entry.linkedSpellIDs),
                        tostring(icon._resolvedCooldownMode),
                        tostring(icon._auraActive == true),
                        tostring(icon._hasCooldownActive == true),
                        tostring(icon._hasRealCooldownActive == true),
                        tostring(icon._showingGCDSwipe == true),
                        tostring(icon._lastDurObjKey),
                        tostring(m and m.viewerCategory or icon._blizzMirrorCategory),
                        tostring(m and m.cooldownID or icon._blizzMirrorCooldownID),
                        tostring(m and m.spellID),
                        tostring(m and m.overrideSpellID),
                        tostring(m and m.overrideTooltipSpellID),
                        EventTraceIDList(m and m.linkedSpellIDs))
                end
            end
        end
    end
    if matches == 0 then return "icons=0" end
    local more = matches > #parts and string.format(" +%d more", matches - #parts) or ""
    return string.format("icons=%d [%s%s]", matches, table.concat(parts, " | "), more)
end

function CDMIcons.EventTraceIconWriteState(icon)
    if not icon then return "" end
    local m = EventTraceMirrorState(icon)
    local entry = icon._spellEntry or {}
    return string.format(
        "eid=%s espell=%s eov=%s ecid=%s runtime=%s kind=%s type=%s elinks=%s mode=%s aura=%s cd=%s real=%s gcd=%s key=%s auraSource=%s auraInst=%s auraUnit=%s activeAura=%s mirror=%s/%s mactive=%s mmode=%s mdur=%s mdurSrc=%s mauraSrc=%s mInst=%s mUnit=%s mepoch=%s mspell=%s mov=%s mtooltip=%s mlinks=%s",
        tostring(entry.id),
        tostring(entry.spellID),
        tostring(entry.overrideSpellID),
        tostring(entry.cooldownID),
        tostring(icon._runtimeSpellID),
        tostring(entry.kind),
        tostring(entry.type),
        EventTraceIDList(entry.linkedSpellIDs),
        tostring(icon._resolvedCooldownMode),
        tostring(icon._auraActive == true),
        tostring(icon._hasCooldownActive == true),
        tostring(icon._hasRealCooldownActive == true),
        tostring(icon._showingGCDSwipe == true),
        tostring(icon._lastDurObjKey),
        tostring(icon._lastAuraSourceID),
        tostring(icon._auraInstanceID),
        tostring(icon._auraUnit),
        tostring(icon._activeAuraSpellID),
        tostring(m and m.viewerCategory or icon._blizzMirrorCategory),
        tostring(m and m.cooldownID or icon._blizzMirrorCooldownID),
        tostring(m and m.isActive),
        tostring(m and m.resolvedMode),
        tostring(m and m.durObj),
        tostring(m and m.durObjSource),
        tostring(m and m.auraDurObjSource),
        tostring(m and m.auraInstanceID),
        tostring(m and m.auraUnit),
        tostring(m and m.mirrorEpoch),
        tostring(m and m.spellID),
        tostring(m and m.overrideSpellID),
        tostring(m and m.overrideTooltipSpellID),
        EventTraceIDList(m and m.linkedSpellIDs))
end

function CDMIcons.EventTraceAPISummary(spellID)
    local cdActive, cdOnGCD = nil, nil
    local chargeActive, currentCharges, maxCharges = nil, nil, nil
    local usable, resourceBlocked = nil, nil
    local itemStart, itemDuration, itemEnabled = nil, nil, nil
    local itemSpellID = EventTraceGetItemUseSpellID(spellID)
    local itemSpellCdActive, itemSpellCdOnGCD = nil, nil

    if Sources and Sources.QuerySpellCooldown then
        local cdInfo = Sources.QuerySpellCooldown(spellID)
        if cdInfo then
            cdActive = EventTraceCooldownInfoField(cdInfo, "isActive")
            cdOnGCD = cdInfo.isOnGCD
        end
        if itemSpellID then
            local itemSpellCdInfo = Sources.QuerySpellCooldown(itemSpellID)
            if itemSpellCdInfo then
                itemSpellCdActive = EventTraceCooldownInfoField(itemSpellCdInfo, "isActive")
                itemSpellCdOnGCD = itemSpellCdInfo.isOnGCD
            end
        end
    end
    if Sources and Sources.QuerySpellCharges then
        local chargeInfo = Sources.QuerySpellCharges(spellID)
        if chargeInfo then
            chargeActive = chargeInfo.isActive
            currentCharges = chargeInfo.currentCharges
            maxCharges = chargeInfo.maxCharges
        end
    end
    if Sources and Sources.QuerySpellUsable then
        local isUsable, isResourceBlocked = Sources.QuerySpellUsable(spellID)
        usable = isUsable
        resourceBlocked = isResourceBlocked
    end
    if Sources and Sources.QueryItemCooldown then
        local startTime, duration, enabled = Sources.QueryItemCooldown(spellID)
        itemStart = startTime
        itemDuration = duration
        itemEnabled = enabled
    end

    return string.format(
        "api cdActive=%s isOnGCD=%s charges=%s/%s chargeActive=%s usable=%s resourceBlocked=%s itemCd=%s/%s/%s itemSpell=%s itemSpellCd=%s/%s",
        CDMIcons.EventTraceValue(cdActive),
        CDMIcons.EventTraceValue(cdOnGCD),
        CDMIcons.EventTraceValue(currentCharges),
        CDMIcons.EventTraceValue(maxCharges),
        CDMIcons.EventTraceValue(chargeActive),
        CDMIcons.EventTraceValue(usable),
        CDMIcons.EventTraceValue(resourceBlocked),
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
-- PRINT (event-trace)
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
-- WRITE PROBE (event-trace)
-- Hooks per-instance writes on the matched icon's textures and the rotation
-- assistant icon. Each hook is installed once via hooksecurefunc and gated
-- at fire time by CDMIcons._eventTraceSpellID, so /cdmdebug spell off silences
-- the output without needing to detach (hooksecurefunc has no inverse).
---------------------------------------------------------------------------

local function FormatColorTuple(r, g, b, a)
    return string.format("(%.2f,%.2f,%.2f,%.2f)", r or 1, g or 1, b or 1, a or 1)
end

function CDMIcons.EventTracePrintWrite(label, icon, value, extra)
    local targetID = CDMIcons._eventTraceSpellID
    if not targetID then return end
    if icon and not CDMIcons.EventTraceIconMatches(icon, targetID) then return end

    local now = GetTime and GetTime() or 0
    local start = CDMIcons._eventTraceStartedAt or now
    local prevField = "_cdmevents_prev_" .. label
    local prev = icon and icon[prevField]
    if icon then icon[prevField] = value end
    local changedNote = (prev == nil) and "(new)"
        or (prev == value and "(unchanged)")
        or ("(was " .. tostring(prev) .. ")")
    local writeState = icon and CDMIcons.EventTraceIconWriteState(icon)
    if writeState and writeState ~= "" then
        extra = extra and (extra .. " " .. writeState) or writeState
    end

    print(string.format(
        "|cffff8800[cdmwrites]|r +%.3f sid=%d %s=%s %s%s",
        now - start,
        targetID,
        label,
        tostring(value),
        changedNote,
        extra and (" " .. extra) or ""))
end

local function InstallIconWriteProbe(icon)
    if not icon or icon._cdmevents_probed then return end
    icon._cdmevents_probed = true

    if icon.Icon then
        if icon.Icon.SetVertexColor then
            hooksecurefunc(icon.Icon, "SetVertexColor", function(_, r, g, b, a)
                local extra = string.format(
                    "rangeTinted=%s usabilityTinted=%s lastVisualState=%s cdDesat=%s greyedOut=%s mode=%s",
                    tostring(icon._rangeTinted),
                    tostring(icon._usabilityTinted),
                    tostring(icon._lastVisualState),
                    tostring(icon._cdDesaturated),
                    tostring(icon._greyedOut),
                    tostring(icon._resolvedCooldownMode))
                CDMIcons.EventTracePrintWrite("Icon:SetVertexColor", icon, FormatColorTuple(r, g, b, a), extra)
            end)
        end
        if icon.Icon.SetDesaturated then
            hooksecurefunc(icon.Icon, "SetDesaturated", function(_, value)
                local extra = string.format(
                    "cdDesat=%s greyedOut=%s mode=%s hasCD=%s hasRealCD=%s",
                    tostring(icon._cdDesaturated),
                    tostring(icon._greyedOut),
                    tostring(icon._resolvedCooldownMode),
                    tostring(icon._hasCooldownActive),
                    tostring(icon._hasRealCooldownActive))
                CDMIcons.EventTracePrintWrite("Icon:SetDesaturated", icon, tostring(value), extra)
            end)
        end
        if icon.Icon.SetAlpha then
            hooksecurefunc(icon.Icon, "SetAlpha", function(_, value)
                CDMIcons.EventTracePrintWrite("Icon:SetAlpha", icon, tostring(value), nil)
            end)
        end
    end
    if icon.Cooldown then
        if icon.Cooldown.SetSwipeColor then
            hooksecurefunc(icon.Cooldown, "SetSwipeColor", function(_, r, g, b, a)
                CDMIcons.EventTracePrintWrite("Cooldown:SetSwipeColor", icon, FormatColorTuple(r, g, b, a), nil)
            end)
        end
        if icon.Cooldown.SetDrawSwipe then
            hooksecurefunc(icon.Cooldown, "SetDrawSwipe", function(_, value)
                CDMIcons.EventTracePrintWrite("Cooldown:SetDrawSwipe", icon, tostring(value), nil)
            end)
        end
        if icon.Cooldown.SetDrawEdge then
            hooksecurefunc(icon.Cooldown, "SetDrawEdge", function(_, value)
                CDMIcons.EventTracePrintWrite("Cooldown:SetDrawEdge", icon, tostring(value), nil)
            end)
        end
    end
end

-- Rotation assistant has its own iconFrame.icon (Texture) and writes
-- SetVertexColor on every Ticker tick. Gate by _eventTraceSpellID being set
-- (any target) — the rotation icon's spell changes per recommendation, so
-- we don't tie its probe to the trace target's ID.
local _raProbed = false
local _raPrev = { r = nil, g = nil, b = nil, a = nil }

local function InstallRotationAssistProbe()
    if _raProbed then return end
    local raAccessor = _G.QUI and _G.QUI.RotationAssistIcon and _G.QUI.RotationAssistIcon.GetFrame
    local raFrame = raAccessor and raAccessor()
    if not raFrame or not raFrame.icon or not raFrame.icon.SetVertexColor then return end
    _raProbed = true

    hooksecurefunc(raFrame.icon, "SetVertexColor", function(_, r, g, b, a)
        if not CDMIcons._eventTraceSpellID then return end
        local now = GetTime and GetTime() or 0
        local start = CDMIcons._eventTraceStartedAt or now
        local changed = (r ~= _raPrev.r) or (g ~= _raPrev.g)
            or (b ~= _raPrev.b) or (a ~= _raPrev.a)
        local prevNote
        if _raPrev.r == nil then
            prevNote = "(new)"
        elseif not changed then
            prevNote = "(unchanged)"
        else
            prevNote = "(was " .. FormatColorTuple(_raPrev.r, _raPrev.g, _raPrev.b, _raPrev.a) .. ")"
        end
        _raPrev.r, _raPrev.g, _raPrev.b, _raPrev.a = r, g, b, a
        print(string.format(
            "|cffff8800[cdmwrites]|r +%.3f rotassist:SetVertexColor=%s %s",
            now - start,
            FormatColorTuple(r, g, b, a),
            prevNote))
    end)
end

function CDMIcons.EventTraceInstallWriteProbes(targetID)
    if not targetID then return 0, false end
    local installed = 0
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if CDMIcons.EventTraceIconMatches(icon, targetID) then
                if not icon._cdmevents_probed then
                    InstallIconWriteProbe(icon)
                    installed = installed + 1
                end
            end
        end
    end
    local raPrior = _raProbed
    InstallRotationAssistProbe()
    local raJustInstalled = _raProbed and not raPrior
    return installed, raJustInstalled
end

---------------------------------------------------------------------------
-- ICON-DEBUG HELPERS
-- Cheap text-print helpers for /run QUI_CDM_ICON_DEBUG = "spell name"
-- workflow.
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

function CDMIcons.ShouldDebugIcon(icon)
    local dbg = _G.QUI_CDM_ICON_DEBUG
    if not dbg then return false end
    local entry = icon and icon._spellEntry
    if not entry then return false end
    if dbg == true then return true end
    local filter = tostring(dbg):lower()
    local name = entry and entry.name and tostring(entry.name):lower() or ""
    local sid = icon and icon._runtimeSpellID and tostring(icon._runtimeSpellID) or ""
    local eid = entry and entry.id and tostring(entry.id) or ""
    return name:find(filter, 1, true) ~= nil
        or sid == filter
        or eid == filter
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

---------------------------------------------------------------------------
-- ICON DUMP (used by /cdmdebug flags icon dump)
---------------------------------------------------------------------------
local function DumpDebugIcon(icon)
    if not CDMIcons.ShouldDebugIcon(icon) then return end
    local entry = icon and icon._spellEntry
    if not entry then return end
    local P = "|cff34D399[CDM-IconDbg]|r"
    print(P, entry.name or "?", "viewerType=", tostring(entry.viewerType),
        "spellID=", tostring(entry.spellID), "entry.id=", tostring(entry.id))
    print(P, "  shown=", tostring(icon:IsShown()),
        "alpha=", tostring(icon.GetAlpha and icon:GetAlpha() or nil),
        "auraActive=", tostring(icon._auraActive),
        "customActive=", tostring(icon._customBarActive),
        "hasCooldownActive=", tostring(icon._hasCooldownActive),
        "hasRealCooldown=", tostring(icon._hasRealCooldownActive),
        "isOnGCD=", tostring(icon._isOnGCD),
        "lastStart=", tostring(icon._lastStart),
        "lastDuration=", tostring(icon._lastDuration),
        "isTotemInstance=", tostring(icon._isTotemInstance),
        "entry._totemSlot=", tostring(entry._totemSlot),
        "icon._totemSlot=", tostring(icon._totemSlot),
        "instanceKey=", tostring(entry._instanceKey))
    local containerDB = CDMIcons.GetTrackerSettings(entry.viewerType)
    if CDMIcons.IsCustomBarContainer(containerDB) then
        local visibility = CDMIcons.ComputeCustomBarVisibility(icon, entry, containerDB, GetTime())
        print(P, "  customVisibility mode=", tostring(visibility.visibilityMode),
            "layout=", tostring(visibility.layoutVisible),
            "render=", tostring(visibility.renderVisible),
            "usable=", tostring(visibility.isUsable),
            "onCD=", tostring(visibility.isOnCooldown),
            "recharge=", tostring(visibility.rechargeActive),
            "active=", tostring(visibility.isActive),
            "dynamic=", tostring(containerDB.dynamicLayout),
            "displayMode=", tostring(containerDB.iconDisplayMode))
    end
    if icon.Icon and icon.Icon.GetTexture then
local okTex = true; local tex = icon.Icon.GetTexture(icon.Icon)
        print(P, "  iconTexture=", okTex and tostring(tex) or "err")
    end
    if icon.StackText and icon.StackText.GetText then
local okStack = true; local stack = icon.StackText.GetText(icon.StackText)
        print(P, "  stackText=", okStack and tostring(tostring(stack)) or "err")
    end
    if icon.DurationText and icon.DurationText.GetText then
local okDur = true; local dur = icon.DurationText.GetText(icon.DurationText)
        print(P, "  durationText=", okDur and tostring(tostring(dur)) or "err")
    end
    if icon._blizzMirrorCooldownID and ns.CDMBlizzMirror
       and ns.CDMBlizzMirror.GetStateByCooldownID then
        local m = ns.CDMBlizzMirror.GetStateByCooldownID(
            icon._blizzMirrorCooldownID,
            icon._blizzMirrorCategory)
        local links = "nil"
        if m and type(m.linkedSpellIDs) == "table" then
            local out = {}
            for i, id in ipairs(m.linkedSpellIDs) do
                out[i] = tostring(id)
            end
            links = table.concat(out, ",")
        end
        print(P, "  blizzMirror=", tostring(icon._blizzMirrorCooldownID),
            "boundCat=", tostring(icon._blizzMirrorCategory),
            "cat=", tostring(m and m.viewerCategory),
            "active=", tostring(m and m.isActive),
            "fromAura=", tostring(m and m.wasSetFromAura),
            "fromCooldown=", tostring(m and m.wasSetFromCooldown),
            "fromCharges=", tostring(m and m.wasSetFromCharges),
            "nativeDurObj=", tostring(icon._mirrorNativeDurObjApplied),
            "spellID=", tostring(m and m.spellID),
            "override=", tostring(m and m.overrideSpellID),
            "tooltip=", tostring(m and m.overrideTooltipSpellID),
            "links=", links)
        if ns.CDMBlizzMirror.GetChildDebugLines then
            local childLines = ns.CDMBlizzMirror.GetChildDebugLines(
                icon._blizzMirrorCooldownID,
                icon._blizzMirrorCategory)
            if type(childLines) == "table" then
                for _, line in ipairs(childLines) do
                    print(P, "  blizzChild", line)
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- SLASH COMMANDS
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Flag command group.
--
-- Usage:
--   /cdmdebug flags                         list subsystems + current state
--   /cdmdebug flags off                     clear all flags
--   /cdmdebug flags <name>                  toggle on/off
--   /cdmdebug flags <name> on|all           enable globally (true)
--   /cdmdebug flags <name> off              disable
--   /cdmdebug flags <name> <filter>         enable with substring filter
--   /cdmdebug flags icon dump [filter]      set filter and walk all icons now
---------------------------------------------------------------------------
local DEBUG_FLAGS = {
    icon   = { global = "QUI_CDM_ICON_DEBUG",   label = "[CDM-Icon]",   takesFilter = true  },
    bar    = { global = "QUI_CDM_BAR_DEBUG",    label = "[CDM-Bar]",    takesFilter = true  },
    blizz  = { global = "QUI_CDM_BLIZZ_DEBUG",  label = "[CDM-Blizz]",  takesFilter = true  },
    aura   = { global = "QUI_CDM_AURA_DEBUG",   label = "[CDM-Aura]",   takesFilter = true  },
    charge = { global = "QUI_CDM_CHARGE_DEBUG", label = "[CDM-Charge]", takesFilter = true  },
    totem  = { global = "QUI_CDM_TOTEM_DEBUG",  label = "[CDM-Totem]",  takesFilter = false },
    taint  = { global = "QUI_CDM_TAINT_DEBUG",  label = "[CDM-Taint]",  takesFilter = true,  requiresReload = true },
}

local DEBUG_FLAG_ORDER = { "icon", "bar", "blizz", "aura", "charge", "totem", "taint" }

local function FormatFlagState(value)
    if value == nil or value == false then return "off" end
    if value == true then return "ON (all)" end
    return "ON [" .. tostring(value) .. "]"
end

local function PrintFlagState(key)
    local def = DEBUG_FLAGS[key]
    print("|cff34D399" .. def.label .. "|r " .. FormatFlagState(_G[def.global]))
end

local function ListDebugFlags()
    print("|cff34D399[CDM-Debug]|r subsystems (use /cdmdebug flags <name> [filter|on|off|all]):")
    for _, key in ipairs(DEBUG_FLAG_ORDER) do
        local def = DEBUG_FLAGS[key]
        local note = def.requiresReload and "  (requires /rl)" or ""
        print(string.format("  %-7s %s%s", key, FormatFlagState(_G[def.global]), note))
    end
    print("  /cdmdebug flags off          -> clear all flags")
    print("  /cdmdebug flags icon dump    -> also walk every icon and dump state")
end

local function RunCDMDebugFlags(msg)
    local text = TrimText(msg)
    if text == "" then
        ListDebugFlags()
        return
    end

    local cmd, rest = text:match("^(%S+)%s*(.-)$")
    local lower = cmd and cmd:lower() or ""

    -- Global "off" / "clear" — wipe all flags.
    if lower == "off" or lower == "clear" then
        for _, key in ipairs(DEBUG_FLAG_ORDER) do
            _G[DEBUG_FLAGS[key].global] = nil
        end
        print("|cff34D399[CDM-Debug]|r all flags cleared")
        return
    end

    local def = DEBUG_FLAGS[lower]
    if not def then
        print("|cffffaa00[CDM-Debug]|r unknown subsystem '" .. cmd .. "'. /cdmdebug for list.")
        return
    end

    local arg = TrimText(rest)
    local argLower = arg:lower()

    -- /cdmdebug icon dump [filter] — set filter (or default true) and walk now.
    if lower == "icon" and (argLower == "dump" or argLower:find("^dump%s+")) then
        local dumpFilter = arg:match("^[Dd]ump%s+(.*)$")
        if dumpFilter and dumpFilter ~= "" then
            _G.QUI_CDM_ICON_DEBUG = dumpFilter
        elseif not _G.QUI_CDM_ICON_DEBUG then
            _G.QUI_CDM_ICON_DEBUG = true
        end
        print("|cff34D399[CDM-Icon]|r dump - filter:", tostring(_G.QUI_CDM_ICON_DEBUG))
        if CDMIcons and CDMIcons.ForEachIcon then
            CDMIcons:ForEachIcon(function(icon)
                DumpDebugIcon(icon)
            end)
        end
        return
    end

    if arg == "" then
        -- No second arg → toggle.
        _G[def.global] = (not _G[def.global]) and true or nil
    elseif argLower == "off" or argLower == "0" or argLower == "false" then
        _G[def.global] = nil
    elseif argLower == "on" or argLower == "all" or argLower == "true" then
        _G[def.global] = true
    elseif def.takesFilter then
        _G[def.global] = arg
    else
        print("|cffffaa00[CDM-Debug]|r '" .. lower .. "' has no filter; use on/off.")
        return
    end

    PrintFlagState(lower)

    if def.requiresReload and _G[def.global] then
        print("|cffffaa00[CDM-Debug]|r " .. lower .. " hooks need /rl to wire up.")
    end
end

---------------------------------------------------------------------------
-- BAR-DEBUG DUMP HOOK
-- Called from the tail of CDMBars:UpdateOwnedBarAura. No-op until
-- /cdmdebug flags bar toggles _G.QUI_CDM_BAR_DEBUG, so the cost on the bar
-- update path is one global lookup + branch.
---------------------------------------------------------------------------
function CDMIcons._OnBarUpdate(bar)
    local dbg = _G.QUI_CDM_BAR_DEBUG
    if not dbg then return end
    if not bar or not bar._spellEntry then return end
    local entry = bar._spellEntry
    local entryName = entry.name or "?"

    if type(dbg) == "string" then
        if not entryName:lower():find(dbg, 1, true)
           and tostring(bar._spellID) ~= dbg then
            return
        end
    end

    local P = "|cff34D399[CDM-BarDbg]|r"
    print(P, entryName, "spellID=", bar._spellID, "entry.id=", entry.id,
          "entry.spellID=", entry.spellID, "entry.overrideSpellID=", entry.overrideSpellID)
    print(P, "  active=", bar._active, "cSideFill=", bar._cSideFill,
          "durObj=", bar._durObj and "yes" or "nil",
          "hideDuration=", tostring(bar._hideDurationText),
          "hasExpiration=", tostring(bar._hasAuraExpirationTime))
    print(P, "  isTotemInstance=", tostring(bar._isTotemInstance),
          "totemSlot=", tostring(bar._totemSlot),
          "instanceKey=", tostring(bar._instanceKey))
    if bar.NameText then
local okName = true; local curName = bar.NameText.GetText(bar.NameText)
        print(P, "  owned NameText=", okName and tostring(curName) or "err")
    end
    if bar.DurationText then
local okDur = true; local curDur = bar.DurationText.GetText(bar.DurationText)
        print(P, "  owned DurationText=", okDur and tostring(curDur) or "err")
    end
    if bar.IconTexture and bar.IconTexture.GetTexture then
local okTex = true; local tex = bar.IconTexture.GetTexture(bar.IconTexture)
        print(P, "  owned IconTexture=", okTex and tostring(tex) or "err")
    end
end

-- Trace events for a specific spellID.
local function RunCDMDebugEvents(msg)
    local text = TrimText(msg)
    if text == "" or text == "off" or text == "clear" then
        CDMIcons._eventTraceSpellID = nil
        CDMIcons._eventTraceStartedAt = nil
        print("|cffffaa00[cdmevents]|r cleared")
        return
    end

    local spellID = tonumber(text:match("^(%d+)"))
    if not spellID then
        print("|cffffaa00[cdmevents]|r Usage: /cdmdebug spell <spellID> events")
        return
    end
    if not CDMIcons:IsRuntimeEnabled() then
        print("|cffffaa00[cdmevents]|r Owned engine not enabled.")
        return
    end

    CDMIcons._eventTraceSpellID = spellID
    CDMIcons._eventTraceStartedAt = GetTime and GetTime() or 0
    print(string.format(
        "|cff34d399[cdmevents]|r tracing events for spellID %d. Use /cdmdebug spell off to stop.",
        spellID))
    print("|cff34d399[cdmevents]|r " .. CDMIcons.EventTraceAPISummary(spellID))
    print("|cff34d399[cdmevents]|r " .. CDMIcons.EventTraceIconSummary(spellID))

    local installed, raInstalled = CDMIcons.EventTraceInstallWriteProbes(spellID)
    print(string.format(
        "|cff34d399[cdmwrites]|r write-probe installed on %d icon(s)%s. Hooks are permanent (gated by trace state); rerun if icons are recycled.",
        installed,
        raInstalled and " + rotation assistant" or ""))
end

-- Log every isActive/isOnGCD transition that ApplyResolvedCooldown sees for
-- the named spell. Empty name to clear.
local function RunCDMDebugTrace(msg)
    local name = TrimText(msg)
    if name == "" then
        CDMIcons._desatTraceName = nil
        for _, pool in pairs(iconPools) do
            for _, icon in ipairs(pool) do
                if icon then icon._desatTracePrev = nil end
            end
        end
        print("|cffffaa00[cdmtrace]|r cleared")
        return
    end
    CDMIcons._desatTraceName = name
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if icon then icon._desatTracePrev = nil end
        end
    end
    print("|cff34d399[cdmtrace]|r tracing transitions for '" .. name .. "'")
end

local function CDMGCDIsSecret(value)
    if Helpers and Helpers.IsSecretValue then
        return Helpers.IsSecretValue(value)
    end
    return issecretvalue and issecretvalue(value) or false
end

local function CDMGCDValue(value)
    if CDMGCDIsSecret(value) then
        return "<SECRET:" .. type(value) .. ">"
    end
    if value == nil then return "nil" end
    if type(value) == "table" or type(value) == "userdata" then
        return "yes"
    end
    return tostring(value)
end

local function CDMGCDIDMatches(value, targetID)
    if CDMGCDIsSecret(value) then return false end
    return value == targetID
end

local function CDMGCDFirstID(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if not CDMGCDIsSecret(value) and value ~= nil then
            return value
        end
    end
    return nil
end

local function CDMGCDCall(owner, methodName)
    if not (owner and owner[methodName]) then
        return "n/a"
    end
    local ok, value = pcall(owner[methodName], owner)
    if not ok then
        return "err"
    end
    return CDMGCDValue(value)
end

local function CDMGCDResolveCooldownState(icon)
    local resolveCooldownState = Resolvers and Resolvers.ResolveCooldownState or CDMIcons.ResolveCooldownState
    if not resolveCooldownState then
        return nil
    end
    local entry = icon and icon._spellEntry
    if not entry then
        return nil
    end
    return resolveCooldownState({
        entry = entry,
        runtimeSpellID = icon._runtimeSpellID,
        mirrorCooldownID = icon._blizzMirrorCooldownID,
        mirrorCategory = icon._blizzMirrorCategory,
        containerKey = entry.viewerType,
        totemSlot = icon._totemSlot,
        useBuffSwipe = CDMIcons.ShouldUseBuffSwipeForIcon
            and CDMIcons.ShouldUseBuffSwipeForIcon(icon, entry) or nil,
        skipAuraPhase = CDMIcons.ShouldSkipAuraPhaseForCooldownIcon
            and CDMIcons.ShouldSkipAuraPhaseForCooldownIcon(icon, entry) or nil,
    })
end

local function CDMGCDMirrorState(icon)
    local mirror = ns.CDMBlizzMirror
    if not (icon and icon._blizzMirrorCooldownID and mirror and mirror.GetStateByCooldownID) then
        return nil
    end
    return mirror.GetStateByCooldownID(icon._blizzMirrorCooldownID, icon._blizzMirrorCategory)
end

local function CDMGCDMirrorSummary(icon)
    local m = CDMGCDMirrorState(icon)
    if not m then
        return "none"
    end
    return string.format(
        "id=%s cat=%s active=%s dur=%s source=%s childActive=%s cooldownActive=%s fromCooldown=%s fromCharges=%s",
        CDMGCDValue(m.cooldownID or icon._blizzMirrorCooldownID),
        CDMGCDValue(m.viewerCategory or icon._blizzMirrorCategory),
        CDMGCDValue(m.isActive),
        CDMGCDValue(m.durObj),
        CDMGCDValue(m.durObjSource),
        CDMGCDValue(m.childIsActive),
        CDMGCDValue(m.cooldownIsActive),
        CDMGCDValue(m.wasSetFromCooldown),
        CDMGCDValue(m.wasSetFromCharges))
end

local function CDMGCDIconMatches(icon, needle, targetID)
    local entry = icon and icon._spellEntry
    if not entry then return false end
    if targetID then
        return CDMGCDIDMatches(icon._runtimeSpellID, targetID)
            or CDMGCDIDMatches(entry.overrideSpellID, targetID)
            or CDMGCDIDMatches(entry.spellID, targetID)
            or CDMGCDIDMatches(entry.id, targetID)
            or CDMGCDIDMatches(entry.itemID, targetID)
    end
    local name = entry.name
    if CDMGCDIsSecret(name) then return false end
    if type(name) ~= "string" then return false end
    return name:lower():find(needle, 1, true) ~= nil
end

local function CDMGCDParseRequest(msg)
    local text = msg and msg:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if text == "" then
        return "", 5, false, false
    end

    local lower = text:lower()
    if lower == "off" or lower == "stop" or lower == "clear" then
        return text, 0, false, true
    end

    local duration = 5
    local once = false
    local base, tail = text:match("^(.-)%s+(%S+)$")
    if base and base ~= "" then
        local tailLower = tail:lower()
        local tailNumber = tonumber(tail)
        if tailLower == "once" then
            text = base
            once = true
        elseif tailLower == "watch" then
            text = base
        elseif tailNumber then
            text = base
            duration = tailNumber
        end
    end

    if duration < 1 then duration = 1 end
    if duration > 15 then duration = 15 end
    return text, duration, once, false
end

local function CDMGCDStopWatch(silent)
    local frame = CDMIcons._gcdWatchFrame
    if frame and frame.SetScript then
        frame:SetScript("OnUpdate", nil)
    end
    CDMIcons._gcdWatchFrame = nil
    if not silent then
        print("|cffffaa00[cdmgcd]|r watch stopped.")
    end
end

local function CDMGCDPrintWatchSample(elapsed, needle, targetID)
    local matches = 0
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if CDMGCDIconMatches(icon, needle, targetID) then
                matches = matches + 1
                local entry = icon._spellEntry
                local sid = CDMGCDFirstID(
                    icon._runtimeSpellID,
                    entry.overrideSpellID,
                    entry.spellID,
                    entry.id,
                    entry.itemID)
                local cdInfo = sid and Sources and Sources.QuerySpellCooldown
                    and Sources.QuerySpellCooldown(sid)
                local cdActive = cdInfo and EventTraceCooldownInfoField(cdInfo, "isActive")
                local cdOnGCD = cdInfo and EventTraceCooldownInfoField(cdInfo, "isOnGCD")
                local gcdDur = sid and Sources and Sources.QuerySpellCooldownDuration
                    and Sources.QuerySpellCooldownDuration(sid, false)
                local realDur = sid and Sources and Sources.QuerySpellCooldownDuration
                    and Sources.QuerySpellCooldownDuration(sid, true)
                local usable, resourceBlocked = nil, nil
                if sid and Sources and Sources.QuerySpellUsable then
                    usable, resourceBlocked = Sources.QuerySpellUsable(sid)
                end
                local resolvedState = CDMGCDResolveCooldownState(icon)
                local mode = resolvedState and resolvedState.mode
                local cd = icon.Cooldown

                print(string.format(
                    "|cff34d399[cdmgcd]|r +%.2f #%d sid=%s active=%s onGCD=%s usable=%s resourceBlocked=%s gcdDur=%s realDur=%s mode=%s showingGCD=%s draw=%s intended=%s shown=%s mirror={%s}",
                    elapsed,
                    matches,
                    CDMGCDValue(sid),
                    CDMGCDValue(cdActive),
                    CDMGCDValue(cdOnGCD),
                    CDMGCDValue(usable),
                    CDMGCDValue(resourceBlocked),
                    CDMGCDValue(gcdDur),
                    CDMGCDValue(realDur),
                    tostring(mode),
                    tostring(icon._showingGCDSwipe),
                    CDMGCDCall(cd, "GetDrawSwipe"),
                    tostring(cd and cd._quiIntendedDrawSwipe),
                    CDMGCDCall(icon, "IsShown"),
                    CDMGCDMirrorSummary(icon)))
            end
        end
    end

    if matches == 0 then
        print(string.format("|cffffaa00[cdmgcd]|r +%.2f no icon found", elapsed))
    end
    return matches
end

local function CDMGCDStartWatch(text, needle, targetID, duration)
    CDMGCDStopWatch(true)
    if not (CreateFrame and GetTime) then
        print("|cffffaa00[cdmgcd]|r watch unavailable.")
        return
    end

    local frame = CreateFrame("Frame")
    local startTime = GetTime()
    local nextSample = 0
    local sampleCount = 0
    local lastMatches = 0
    local interval = 0.2

    CDMIcons._gcdWatchFrame = frame
    print(string.format(
        "|cff34d399[cdmgcd]|r watching '%s' for %.1fs - cast/use it now",
        text,
        duration))

    frame:SetScript("OnUpdate", function(self)
        local elapsed = GetTime() - startTime
        if elapsed < nextSample and elapsed < duration then
            return
        end
        if elapsed > duration then
            elapsed = duration
        end

        sampleCount = sampleCount + 1
        lastMatches = CDMGCDPrintWatchSample(elapsed, needle, targetID)
        nextSample = nextSample + interval

        if elapsed >= duration then
            self:SetScript("OnUpdate", nil)
            if CDMIcons._gcdWatchFrame == self then
                CDMIcons._gcdWatchFrame = nil
            end
            print(string.format(
                "|cff34d399[cdmgcd]|r ended samples=%d matches=%d",
                sampleCount,
                lastMatches))
        end
    end)
end

-- Watch every gate that can suppress GCD swipe.
local function RunCDMDebugGCD(msg)
    local text, duration, once, stop = CDMGCDParseRequest(msg)
    if stop then
        CDMGCDStopWatch(false)
        return
    end
    if text == "" then
        print("|cffffaa00[cdmgcd]|r Usage: /cdmdebug spell <spellID or spell name> [once|watch [seconds]|off]")
        return
    end
    if not CDMIcons:IsRuntimeEnabled() then
        print("|cffffaa00[cdmgcd]|r Owned engine not enabled.")
        return
    end

    local targetID = tonumber(text:match("^(%d+)$"))
    local needle = targetID and nil or text:lower()
    local swipe = ns._OwnedSwipe or (_G.QUI and _G.QUI.CooldownSwipe)
    local settings = swipe and swipe.GetSettings and swipe.GetSettings() or nil
    local settingsShowGCD = settings and settings.showGCDSwipe
    local settingsShowCooldown = settings and settings.showCooldownSwipe
    local runtimeShowGCD = CDMIcons.IsGCDSwipeEnabled and CDMIcons.IsGCDSwipeEnabled()

    print(string.format(
        "|cff34d399[cdmgcd]|r settings showGCDSwipe=%s showCooldownSwipe=%s runtimeGCDEnabled=%s swipeModule=%s",
        CDMGCDValue(settingsShowGCD),
        CDMGCDValue(settingsShowCooldown),
        CDMGCDValue(runtimeShowGCD),
        swipe and "yes" or "nil"))

    local matches = 0
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if CDMGCDIconMatches(icon, needle, targetID) then
                matches = matches + 1
                local entry = icon._spellEntry
                local sid = CDMGCDFirstID(
                    icon._runtimeSpellID,
                    entry.overrideSpellID,
                    entry.spellID,
                    entry.id,
                    entry.itemID)
                local cdInfo = sid and Sources and Sources.QuerySpellCooldown
                    and Sources.QuerySpellCooldown(sid)
                local cdActive = cdInfo and EventTraceCooldownInfoField(cdInfo, "isActive")
                local cdOnGCD = cdInfo and EventTraceCooldownInfoField(cdInfo, "isOnGCD")
                local gcdDur = sid and Sources and Sources.QuerySpellCooldownDuration
                    and Sources.QuerySpellCooldownDuration(sid, false)
                local realDur = sid and Sources and Sources.QuerySpellCooldownDuration
                    and Sources.QuerySpellCooldownDuration(sid, true)
                local chargeDur = sid and Sources and Sources.QuerySpellChargeDuration
                    and Sources.QuerySpellChargeDuration(sid)
                local charges = sid and Sources and Sources.QuerySpellCharges
                    and Sources.QuerySpellCharges(sid)
                local chargeActive = charges and charges.isActive
                local maxCharges = charges and charges.maxCharges
                local usable, resourceBlocked = nil, nil
                if sid and Sources and Sources.QuerySpellUsable then
                    usable, resourceBlocked = Sources.QuerySpellUsable(sid)
                end
                local resolvedState = CDMGCDResolveCooldownState(icon)
                local durObj = resolvedState and resolvedState.durObj
                local mode = resolvedState and resolvedState.mode
                local sourceID = resolvedState and resolvedState.sourceID
                local cd = icon.Cooldown

                print(string.format(
                    "|cff34d399[cdmgcd]|r #%d %s sid=%s viewer=%s kind=%s type=%s shown=%s",
                    matches,
                    CDMGCDValue(entry.name),
                    CDMGCDValue(sid),
                    CDMGCDValue(entry.viewerType),
                    CDMGCDValue(entry.kind),
                    CDMGCDValue(entry.type),
                    CDMGCDCall(icon, "IsShown")))
                print(string.format(
                    "|cff34d399[cdmgcd]|r api isActive=%s isOnGCD=%s usable=%s resourceBlocked=%s gcdDur=%s realDur=%s chargeDur=%s chargeActive=%s maxCharges=%s",
                    CDMGCDValue(cdActive),
                    CDMGCDValue(cdOnGCD),
                    CDMGCDValue(usable),
                    CDMGCDValue(resourceBlocked),
                    CDMGCDValue(gcdDur),
                    CDMGCDValue(realDur),
                    CDMGCDValue(chargeDur),
                    CDMGCDValue(chargeActive),
                    CDMGCDValue(maxCharges)))
                print(string.format(
                    "|cff34d399[cdmgcd]|r mirror %s",
                    CDMGCDMirrorSummary(icon)))
                print(string.format(
                    "|cff34d399[cdmgcd]|r resolver mode=%s durObj=%s source=%s resolvedMode=%s lastKey=%s",
                    tostring(mode),
                    CDMGCDValue(durObj),
                    CDMGCDValue(sourceID),
                    tostring(icon._resolvedCooldownMode),
                    tostring(icon._lastDurObjKey)))
                print(string.format(
                    "|cff34d399[cdmgcd]|r icon showingGCD=%s showingReal=%s hasReal=%s hasCooldown=%s aura=%s",
                    tostring(icon._showingGCDSwipe),
                    tostring(icon._showingRealCooldownSwipe),
                    tostring(icon._hasRealCooldownActive),
                    tostring(icon._hasCooldownActive),
                    tostring(icon._auraActive)))
                print(string.format(
                    "|cff34d399[cdmgcd]|r cooldown drawSwipe=%s intendedDrawSwipe=%s drawEdge=%s intendedDrawEdge=%s color=%s",
                    CDMGCDCall(cd, "GetDrawSwipe"),
                    tostring(cd and cd._quiIntendedDrawSwipe),
                    CDMGCDCall(cd, "GetDrawEdge"),
                    tostring(cd and cd._quiIntendedDrawEdge),
                    CDMGCDValue(cd and cd._quiIntendedSwipeColor)))
            end
        end
    end

    if matches == 0 then
        print("|cffffaa00[cdmgcd]|r no icon found for '" .. text .. "'")
    end
    if not once then
        CDMGCDStartWatch(text, needle, targetID, duration)
    end
end

local function CDMDebugClassifySpellCooldownState(spellID)
    if CDMIcons.ClassifySpellCooldownState then
        return CDMIcons.ClassifySpellCooldownState(spellID)
    end
    if not (spellID and Sources and Sources.QuerySpellCooldown) then
        return nil, nil, nil
    end

    local cdInfo = Sources.QuerySpellCooldown(spellID)
    if not cdInfo then
        return nil, nil, nil
    end

    local apiActive, apiSecret = EventTraceCooldownInfoField(cdInfo, "isActive")
    local onGCD, gcdSecret = EventTraceCooldownInfoField(cdInfo, "isOnGCD")
    if apiSecret or gcdSecret then
        return nil, nil, nil
    end

    local realActive
    if apiActive == true then
        if onGCD == true then
            local realDur = Sources.QuerySpellCooldownDuration
                and Sources.QuerySpellCooldownDuration(spellID, true)
            realActive = realDur and true or false
        else
            realActive = true
        end
    elseif apiActive == false then
        realActive = false
    end

    return apiActive, realActive, onGCD
end

-- Diagnostic for charge-spell recharge swipe issues.
-- Walks visible CDM icons, finds entries matching the name, prints the
-- relevant gates: hasCharges, classifier output, charge/cd DurObj presence.
local function RunCDMDebugCharge(msg)
    local targetText = TrimText(msg)
    if targetText == "" then
        print("|cffffaa00[cdmcharge]|r Usage: /cdmdebug spell <spell name> charge")
        return
    end
    local targetID = tonumber(targetText:match("^(%d+)$"))
    local needle = targetID and nil or targetText:lower()
    local matches = 0
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            local entry = icon and icon._spellEntry
            if entry and CDMGCDIconMatches(icon, needle, targetID) then
                matches = matches + 1
                local sid = icon._runtimeSpellID
                    or entry.overrideSpellID or entry.spellID or entry.id
                local apiA, realA, onGCD = CDMDebugClassifySpellCooldownState(sid)
                local chargeDur = Sources and Sources.QuerySpellChargeDuration
                    and Sources.QuerySpellChargeDuration(sid)
                local cdDur = Sources and Sources.QuerySpellCooldownDuration
                    and Sources.QuerySpellCooldownDuration(sid, true)
                print(string.format(
                    "|cff34d399[cdmcharge]|r %s sid=%s hasCharges=%s apiA=%s realA=%s onGCD=%s chargeDur=%s cdDur=%s",
                    tostring(entry.name), tostring(sid),
                    tostring(entry.hasCharges),
                    tostring(apiA), tostring(realA), tostring(onGCD),
                    chargeDur and "yes" or "nil",
                    cdDur and "yes" or "nil"))
            end
        end
    end
    if matches == 0 then
        print("|cffffaa00[cdmcharge]|r no icon found for '" .. targetText .. "'")
    end
end

-- Diagnose flicker by snapshotting icon state
-- every frame for 5 seconds. Logs only TRANSITIONS (when the captured
-- state changes), so output is compact. Used to trace which flag is
-- toggling sub-tick during the aura→cooldown transition.
local function RunCDMDebugFlicker(msg)
    local targetText = TrimText(msg)
    if targetText == "" then
        print("|cffffaa00[cdmflicker]|r Usage: /cdmdebug spell <spell name> flicker")
        return
    end
    if not CDMIcons:IsRuntimeEnabled() then
        print("|cffffaa00[cdmflicker]|r Owned engine not enabled.")
        return
    end

    local target
    local targetID = tonumber(targetText:match("^(%d+)$"))
    local needle = targetID and nil or targetText:lower()
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if icon and icon._spellEntry and CDMGCDIconMatches(icon, needle, targetID) then
                target = icon
                break
            end
        end
        if target then break end
    end
    if not target then
        print("|cffffaa00[cdmflicker]|r Icon not found: " .. targetText)
        return
    end

    print(string.format(
        "|cff34d399[cdmflicker]|r logging '%s' for 5s — cast the spell NOW so the flicker happens within the window",
        targetText))

    local samples = {}
    local lastSig = nil
    local startTime = GetTime()
    local frame = CreateFrame("Frame")

    local function snapshot()
        local now = GetTime() - startTime
        local rState = CDMGCDResolveCooldownState(target)
        local rMode = rState and rState.mode

        local sig = string.format(
            "aA=%s sRC=%s hRC=%s sGCD=%s rMode=%s",
            tostring(target._auraActive),
            tostring(target._showingRealCooldownSwipe),
            tostring(target._hasRealCooldownActive),
            tostring(target._showingGCDSwipe),
            tostring(rMode))

        if sig ~= lastSig then
            samples[#samples+1] = string.format("+%.3f  %s", now, sig)
            lastSig = sig
        end

        if now > 5 then
            frame:SetScript("OnUpdate", nil)
            print(string.format(
                "|cff34d399[cdmflicker]|r '%s' end — %d transitions over 5s",
                targetText, #samples))
            for _, s in ipairs(samples) do
                print(s)
            end
        end
    end

    frame:SetScript("OnUpdate", snapshot)
end

-- Resolver parity probe. Walks every visible CDM icon and
-- prints (entry name, kind, resolver mode, mirror active?, parity?).
local function RunCDMDebugProbe()
    if not CDMIcons:IsRuntimeEnabled() then
        print("|cffffaa00[cdmprobe]|r Owned engine not enabled.")
        return
    end

    local HookTextHasDisplay = CDMIcons.HookTextHasDisplay

    local rows = 0
    local agree = 0
    local disagree = 0
    local resolverInactive = 0

    print("|cff34d399[cdmprobe]|r begin parity sweep")
    print("name | kind | mode | mActive | parity | rText | curText | textPar")

    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            if icon and icon:IsShown() and icon._spellEntry then
                local entry = icon._spellEntry
                local name = entry.name or "?"
                local kind = entry.kind or "?"

                local state = CDMGCDResolveCooldownState(icon)
                local mode = state and state.mode
                local rText = CDMIcons.ResolveIconStackText(icon)
                local curText = icon.StackText and icon.StackText:GetText() or ""
                local textParity
                local rIsSecret = (rText ~= nil) and false
                local cIsSecret = (curText ~= nil) and false
                if rIsSecret or cIsSecret then
                    textParity = "secret"
                elseif not HookTextHasDisplay(rText) and not HookTextHasDisplay(curText) then
                    textParity = "OK"
                elseif rText == curText then
                    textParity = "OK"
                else
                    textParity = "MISMATCH"
                end
                local resolverActive = (mode ~= "inactive")
                local mirrorActive = icon._hasRealCooldownActive == true
                                  or icon._showingRealCooldownSwipe == true
                                  or icon._auraActive == true

                local parity
                if resolverActive == mirrorActive then
                    parity = "OK"
                    agree = agree + 1
                else
                    parity = "MISMATCH"
                    disagree = disagree + 1
                end
                if mode == "inactive" then
                    resolverInactive = resolverInactive + 1
                end

                rows = rows + 1
                local rTextDisplay = rIsSecret and "<secret>" or (rText == nil and "nil" or tostring(rText))
                local curTextDisplay = cIsSecret and "<secret>" or (curText == nil and "nil" or tostring(curText))
                print(string.format("%s | %s | %s | %s | %s | %s | %s | %s",
                    name, kind, mode,
                    mirrorActive and "yes" or "no",
                    parity,
                    rTextDisplay, curTextDisplay, textParity))

                -- Secret values can't be Lua-concatenated into the row above,
                -- but C_StringUtil.WrapString is AllowedWhenTainted and produces
                -- a (possibly-secret) string that AddMessage renders correctly.
                if rIsSecret and C_StringUtil and C_StringUtil.WrapString then
local ok = true; local wrapped = C_StringUtil.WrapString(rText, "  |cff888888\\_ rText[" .. name .. "]:|r ", "")
                    if wrapped then
                        DEFAULT_CHAT_FRAME:AddMessage(wrapped)
                    end
                end
                if cIsSecret and C_StringUtil and C_StringUtil.WrapString then
local ok = true; local wrapped = C_StringUtil.WrapString(curText, "  |cff888888\\_ curText[" .. name .. "]:|r ", "")
                    if wrapped then
                        DEFAULT_CHAT_FRAME:AddMessage(wrapped)
                    end
                end
            end
        end
    end

    print(string.format(
        "|cff34d399[cdmprobe]|r end — %d icons, %d agree, %d mismatch (%.1f%%), %d inactive",
        rows, agree, disagree,
        rows > 0 and (100 * agree / rows) or 0,
        resolverInactive))
end

local _cooldownMethodTestFrame

local function CooldownTestValue(v)
    if issecretvalue and issecretvalue(v) then
        return "<SECRET:" .. type(v) .. ">"
    end
    if v == nil then return "nil" end
    if type(v) == "boolean" then return v and "true" or "false" end
    return tostring(v)
end

local function CooldownTestIsSecret(v)
    return (issecretvalue and issecretvalue(v)) or false
end

local function CooldownTestPlainNumber(v)
    if issecretvalue and issecretvalue(v) then return false end
    return type(v) == "number"
end

local function CooldownTestCall(owner, method, ...)
    local fn = owner and owner[method]
    if not fn then return false, "missing " .. tostring(method) end
    return pcall(fn, owner, ...)
end

local function CooldownTestSummary(cd)
    local okTimes, startMS, durationMS = CooldownTestCall(cd, "GetCooldownTimes")
    local okDuration, displayDuration = CooldownTestCall(cd, "GetCooldownDuration")
    local okShown, shown = CooldownTestCall(cd, "IsShown")
    return string.format("shown=%s times=%s/%s duration=%s",
        okShown and CooldownTestValue(shown) or "err",
        okTimes and CooldownTestValue(startMS) or "err",
        okTimes and CooldownTestValue(durationMS) or "err",
        okDuration and CooldownTestValue(displayDuration) or "err")
end

local COOLDOWN_TEXT_TEST_MAX_ROWS = 12

local function CooldownTestSetDisplayText(fs, value, fallback)
    if not (fs and fs.SetText) then return end
    if value == nil then
        fs:SetText(fallback or "<nil>")
        return
    end
    if CooldownTestIsSecret(value) then
        if C_StringUtil and C_StringUtil.WrapString then
            local wrapped = C_StringUtil.WrapString(value, "", "")
            if wrapped then
                fs:SetText(wrapped)
                return
            end
        end
        fs:SetText(value)
        return
    end

    local text = tostring(value)
    if text == "" then text = "<empty>" end
    fs:SetText(text)
end

local function CooldownTextPrintSecret(prefix, label, shown, value)
    if not (prefix and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage) then return end
    if not (C_StringUtil and C_StringUtil.WrapString) then
        print(prefix, "text", tostring(label), "shown=", shown, "value=<SECRET>")
        return
    end

    local wrapped = C_StringUtil.WrapString(value,
        tostring(prefix) .. " text " .. tostring(label) .. " shown= " .. tostring(shown) .. " value= ",
        "")
    if wrapped then
        DEFAULT_CHAT_FRAME:AddMessage(wrapped)
    else
        print(prefix, "text", tostring(label), "shown=", shown, "value=<SECRET>")
    end
end

local function CooldownTextObjectType(owner)
    local ok, kind = CooldownTestCall(owner, "GetObjectType")
    return ok and kind or nil
end

local function CooldownTextAddProbe(probes, seen, label, owner, readOwner)
    if #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
    local target = readOwner or owner
    if not target or seen[target] then return end
    if not target.GetText then return end
    seen[target] = true

    local okText, text = CooldownTestCall(target, "GetText")
    local okShown, shown = CooldownTestCall(owner or target, "IsShown")
    probes[#probes + 1] = {
        label = label,
        textOk = okText == true,
        text = okText and text or nil,
        shownOk = okShown == true,
        shown = okShown and shown or nil,
    }
end

local function CooldownTextSelectRegion(owner, index)
    if not (owner and owner.GetRegions) then return nil end
    local ok, region = pcall(function()
        return select(index, owner:GetRegions())
    end)
    return ok and region or nil
end

local function CooldownTextSelectChild(owner, index)
    if not (owner and owner.GetChildren) then return nil end
    local ok, child = pcall(function()
        return select(index, owner:GetChildren())
    end)
    return ok and child or nil
end

local function CooldownTextCollectFontStrings(owner, label, probes, seen, visited, depth)
    if not owner or #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
    if visited[owner] or depth > 4 then return end
    visited[owner] = true

    if CooldownTextObjectType(owner) == "FontString" then
        CooldownTextAddProbe(probes, seen, label, owner)
        return
    end

    local okNumRegions, numRegions = CooldownTestCall(owner, "GetNumRegions")
    if okNumRegions and type(numRegions) == "number" then
        for i = 1, numRegions do
            local region = CooldownTextSelectRegion(owner, i)
            if region and CooldownTextObjectType(region) == "FontString" then
                CooldownTextAddProbe(probes, seen, label .. ".region" .. tostring(i), region)
                if #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
            end
        end
    end

    local okNumChildren, numChildren = CooldownTestCall(owner, "GetNumChildren")
    if okNumChildren and type(numChildren) == "number" then
        for i = 1, numChildren do
            local child = CooldownTextSelectChild(owner, i)
            if child then
                CooldownTextCollectFontStrings(child, label .. ".child" .. tostring(i),
                    probes, seen, visited, depth + 1)
                if #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
            end
        end
    elseif owner.GetChildren then
        local okChildren, children = pcall(function()
            return { owner:GetChildren() }
        end)
        if okChildren and type(children) == "table" then
            for i = 1, #children do
                CooldownTextCollectFontStrings(children[i], label .. ".child" .. tostring(i),
                    probes, seen, visited, depth + 1)
                if #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
            end
        end
    end
end

local function CooldownTextCollectDirectFontStrings(owner, label, probes, seen)
    if not owner or #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
    if CooldownTextObjectType(owner) == "FontString" then
        CooldownTextAddProbe(probes, seen, label, owner)
        return
    end

    local okNumRegions, numRegions = CooldownTestCall(owner, "GetNumRegions")
    if not (okNumRegions and type(numRegions) == "number") then return end
    for i = 1, numRegions do
        local region = CooldownTextSelectRegion(owner, i)
        if region and CooldownTextObjectType(region) == "FontString" then
            CooldownTextAddProbe(probes, seen, label .. ".region" .. tostring(i), region)
            if #probes >= COOLDOWN_TEXT_TEST_MAX_ROWS then return end
        end
    end
end

local function CooldownTextBuildProbes(payload)
    local probes = {}
    local seen = {}
    local visited = {}
    local child = payload and payload.child
    local state = payload and payload.state

    if child then
        CooldownTextCollectDirectFontStrings(child, "child", probes, seen)
        CooldownTextAddProbe(probes, seen, "child.DisplayText", child.DisplayText)
        CooldownTextAddProbe(probes, seen, "child.Text", child.Text)
        CooldownTextAddProbe(probes, seen, "child.Count", child.Count)
        CooldownTextAddProbe(probes, seen, "child.StackText", child.StackText)
        CooldownTextAddProbe(probes, seen, "child.Stacks", child.Stacks)
    end

    if state and state.stackText ~= nil then
        probes[#probes + 1] = {
            label = "mirror." .. tostring(state.stackTextSource or "stackText"),
            textOk = true,
            text = state.stackText,
            shownOk = true,
            shown = state.stackTextShown,
        }
    elseif state then
        probes[#probes + 1] = {
            label = "mirror." .. tostring(state.stackTextSource or "stackText"),
            textOk = true,
            text = nil,
            shownOk = true,
            shown = state.stackTextShown,
        }
    end

    if child then
        local applications = child.Applications
        if applications then
            CooldownTextAddProbe(probes, seen, "Applications", applications)
            CooldownTextAddProbe(probes, seen, "Applications.DisplayText", applications.DisplayText)
            CooldownTextAddProbe(probes, seen, "Applications.Applications", applications.Applications)
            CooldownTextCollectFontStrings(applications, "Applications",
                probes, seen, visited, 0)
        end

        local chargeCount = child.ChargeCount
        if chargeCount then
            CooldownTextAddProbe(probes, seen, "ChargeCount", chargeCount)
            CooldownTextAddProbe(probes, seen, "ChargeCount.Current", chargeCount.Current)
            CooldownTextAddProbe(probes, seen, "ChargeCount.DisplayText", chargeCount.DisplayText)
            CooldownTextCollectFontStrings(chargeCount, "ChargeCount",
                probes, seen, visited, 0)
        end

        CooldownTextCollectFontStrings(child.Cooldown, "Cooldown",
            probes, seen, visited, 0)
        CooldownTextCollectFontStrings(child, "child",
            probes, seen, visited, 0)
    end

    return probes
end

local function CooldownTextApplyRows(frame, payload, prefix)
    local rows = frame and frame.textRows
    if not rows then return end

    local probes = CooldownTextBuildProbes(payload)
    for i = 1, #rows do
        local row = rows[i]
        local probe = probes[i]
        if probe then
            local shown = probe.shownOk and CooldownTestValue(probe.shown) or "err"
            row.source:SetText(tostring(probe.label) .. " shown=" .. shown)
            CooldownTestSetDisplayText(row.value, probe.text,
                probe.textOk and "<nil>" or "<GetText error>")
            row:Show()
            if prefix and not CooldownTestIsSecret(probe.text) then
                print(prefix, "text", tostring(probe.label),
                    "shown=", shown,
                    "value=", probe.textOk and CooldownTestValue(probe.text) or "err")
            elseif prefix and probe.textOk then
                CooldownTextPrintSecret(prefix, probe.label, shown, probe.text)
            elseif prefix then
                print(prefix, "text", tostring(probe.label), "shown=", shown, "value=err")
            end
        else
            row.source:SetText("")
            row.value:SetText("")
            row:Hide()
        end
    end
end

local function EnsureCooldownMethodTestFrame()
    if _cooldownMethodTestFrame then return _cooldownMethodTestFrame end
    if InCombatLockdown and InCombatLockdown() then
        return nil, "Run /cdmdebug cdtest <cooldownID> once out of combat to create the test frame."
    end

    local f = CreateFrame("Frame", "QUI_CDMCooldownMethodTestFrame", UIParent)
    f:SetSize(640, 360)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.82)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -5)
    title:SetText("|cff34d399[cdmcdtest]|r child cooldown method test")
    f.title = title

    f.rows = {}
    local labels = {
        { key = "durObj", text = "DurationObj" },
        { key = "set", text = "SetCooldown" },
        { key = "duration", text = "Duration" },
        { key = "expiration", text = "Expiration" },
    }
    for i, item in ipairs(labels) do
        local cell = CreateFrame("Frame", nil, f)
        cell:SetSize(56, 56)
        cell:SetPoint("TOPLEFT", 14 + (i - 1) * 92, -28)

        local tex = cell:CreateTexture(nil, "BACKGROUND")
        tex:SetAllPoints()
        tex:SetColorTexture(0.12, 0.12, 0.12, 1)
        cell.tex = tex

        local cd = CreateFrame("Cooldown", nil, cell, "CooldownFrameTemplate")
        cd:SetAllPoints()
        if cd.SetDrawSwipe then cd:SetDrawSwipe(true) end
        if cd.SetDrawEdge then cd:SetDrawEdge(true) end
        cell.cd = cd

        local label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", cell, "BOTTOM", 0, -3)
        label:SetText(item.text)
        cell.label = label

        f.rows[item.key] = cell
    end

    local textHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    textHeader:SetPoint("TOPLEFT", 14, -94)
    textHeader:SetText("Child text probes")
    f.textHeader = textHeader

    f.textRows = {}
    for i = 1, COOLDOWN_TEXT_TEST_MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(612, 18)
        row:SetPoint("TOPLEFT", 14, -112 - (i - 1) * 19)

        local source = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        source:SetPoint("LEFT")
        source:SetSize(272, 16)
        source:SetJustifyH("LEFT")
        source:SetText("")
        row.source = source

        local value = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        value:SetPoint("LEFT", source, "RIGHT", 8, 0)
        value:SetSize(330, 16)
        value:SetJustifyH("LEFT")
        value:SetText("")
        row.value = value

        f.textRows[i] = row
    end

    _cooldownMethodTestFrame = f
    return f
end

local function ApplyCooldownMethodCell(row, payload, methodKey)
    local cd = row and row.cd
    if not cd then return false, "missing test cooldown", "" end
    CooldownTestCall(cd, "Clear")
    CooldownTestCall(cd, "SetReverse", false)

    if methodKey == "durObj" then
        local durObj = payload.setDurationObjectArg
        if not durObj then return false, "missing DurationObject", CooldownTestSummary(cd) end
        local clear = payload.setDurationObjectClearIfZero
        if clear == nil then
            return CooldownTestCall(cd, "SetCooldownFromDurationObject", durObj, true)
        end
        return CooldownTestCall(cd, "SetCooldownFromDurationObject", durObj, clear)
    elseif methodKey == "set" then
        local startTime = payload.setCooldownStart
        local duration = payload.setCooldownDuration
        if startTime == nil or duration == nil then
            return false, "missing start/duration", CooldownTestSummary(cd)
        end
        if payload.setCooldownModRate ~= nil then
            return CooldownTestCall(cd, "SetCooldown", startTime, duration, payload.setCooldownModRate)
        end
        return CooldownTestCall(cd, "SetCooldown", startTime, duration)
    elseif methodKey == "duration" then
        local duration = payload.setCooldownDurationOnly
        if duration == nil then return false, "missing duration", CooldownTestSummary(cd) end
        if payload.setCooldownDurationModRate ~= nil then
            return CooldownTestCall(cd, "SetCooldownDuration", duration, payload.setCooldownDurationModRate)
        end
        return CooldownTestCall(cd, "SetCooldownDuration", duration)
    elseif methodKey == "expiration" then
        local expiration = payload.setCooldownExpirationTime
        local duration = payload.setCooldownExpirationDuration
        if expiration == nil
           and CooldownTestPlainNumber(payload.setCooldownStart)
           and CooldownTestPlainNumber(duration) then
            expiration = payload.setCooldownStart + duration
        end
        if expiration == nil or duration == nil then
            return false, "missing expiration/duration", CooldownTestSummary(cd)
        end
        if payload.setCooldownExpirationModRate ~= nil then
            return CooldownTestCall(cd, "SetCooldownFromExpirationTime", expiration, duration, payload.setCooldownExpirationModRate)
        end
        return CooldownTestCall(cd, "SetCooldownFromExpirationTime", expiration, duration)
    end

    return false, "unknown method", CooldownTestSummary(cd)
end

local function RunCDMDebugCooldownTest(msg)
    local text = TrimText(msg)
    local cooldownID = tonumber(text:match("^(%d+)"))
    local P = "|cff34d399[cdmcdtest]|r"
    if not cooldownID then
        print(P, "Usage: /cdmdebug cdtest <cooldownID>")
        return
    end

    local mirror = ns.CDMBlizzMirror
    if mirror and mirror.BindNewChildren then
        mirror.BindNewChildren()
    end
    if not (mirror and mirror.GetCooldownMethodTestPayload) then
        print(P, "Mirror payload API unavailable.")
        return
    end

    local payload = mirror.GetCooldownMethodTestPayload(cooldownID)
    if not payload then
        print(P, "No mirrored child payload for cooldownID", tostring(cooldownID))
        return
    end

    local frame, err = EnsureCooldownMethodTestFrame()
    if not frame then
        print(P, err)
        return
    end

    if frame.title then
        frame.title:SetText("|cff34d399[cdmcdtest]|r cdID=" .. tostring(cooldownID)
            .. " cat=" .. tostring(payload.state and payload.state.viewerCategory)
            .. " active=" .. tostring(payload.state and payload.state.isActive == true))
    end
    if frame.Show then frame:Show() end

    print(P, "cdID=", tostring(cooldownID),
        "cat=", tostring(payload.state and payload.state.viewerCategory),
        "active=", tostring(payload.state and payload.state.isActive == true),
        "lastSetter=", tostring(payload.lastCooldownSetter),
        "durObj=", CooldownTestValue(payload.durObj),
        "source=", tostring(payload.durObjSource))
    print(P, "aura",
        "hasInst=", tostring(payload.state and payload.state.hasAuraInstanceID == true),
        "unit=", tostring(payload.state and payload.state.auraUnit),
        "auraDur=", CooldownTestValue(payload.state and payload.state.auraDurObj),
        "auraSource=", tostring(payload.state and payload.state.auraDurObjSource),
        "auraUnknown=", tostring(payload.state and payload.state.auraDurationStateUnknown))
    print(P, "childCd",
        "shown=", tostring(payload.childCooldownShown == true),
        "times=", CooldownTestValue(payload.childCooldownStartMS) .. "/" .. CooldownTestValue(payload.childCooldownDurationMS),
        "duration=", CooldownTestValue(payload.childCooldownDurationValue))
    print(P, "args",
        "start=", CooldownTestValue(payload.setCooldownStart),
        "duration=", CooldownTestValue(payload.setCooldownDuration),
        "durationOnly=", CooldownTestValue(payload.setCooldownDurationOnly),
        "expiration=", CooldownTestValue(payload.setCooldownExpirationTime))
    if type(payload.auraProbeLines) == "table" then
        for _, line in ipairs(payload.auraProbeLines) do
            print(P, line)
        end
    end
    CooldownTextApplyRows(frame, payload, P)

    for key, row in pairs(frame.rows) do
        if row.tex and payload.iconTexture and not (issecretvalue and issecretvalue(payload.iconTexture)) then
            row.tex:SetTexture(payload.iconTexture)
        end
        local ok, result = ApplyCooldownMethodCell(row, payload, key)
        local summary = CooldownTestSummary(row.cd)
        if row.label then
            local textLabel = key
            if key == "durObj" then textLabel = "DurationObj"
            elseif key == "set" then textLabel = "SetCooldown"
            elseif key == "duration" then textLabel = "Duration"
            elseif key == "expiration" then textLabel = "Expiration" end
            row.label:SetText(textLabel .. " " .. (ok and "OK" or "ERR"))
        end
        print(P, key, ok and "OK" or ("ERR " .. tostring(result)), summary)
    end
end

-- Dump _specProfiles contents and current spec state.
local function RunCDMDebugProfiles()
    local P = "|cff34D399[CDM-Profiles]|r"
    local db = ns.Addon and ns.Addon.db and ns.Addon.db.profile and ns.Addon.db.profile.ncdm
    if not db then
        print(P, "No ncdm database found.")
        return
    end

    local currentSpecID = GetSpecialization and GetSpecializationInfo(GetSpecialization()) or "?"
    print(P, "Current spec ID:", currentSpecID)
    print(P, "_lastSpecID:", db._lastSpecID or "nil")

    local profiles = db._specProfiles
    if not profiles or not next(profiles) then
        print(P, "_specProfiles: empty/nil")
        return
    end

    for specID, specData in pairs(profiles) do
        local label = specID
        if GetSpecializationInfoByID then
            local _, specName = GetSpecializationInfoByID(specID)
            if specName then label = specID .. " (" .. specName .. ")" end
        end
        local containerCount = 0
        local totalSpells = 0
        for key, cData in pairs(specData) do
            if type(cData) == "table" and cData.ownedSpells then
                containerCount = containerCount + 1
                local count = type(cData.ownedSpells) == "table" and #cData.ownedSpells or 0
                totalSpells = totalSpells + count
                local spellNames = {}
                if type(cData.ownedSpells) == "table" then
                    for i = 1, math.min(5, #cData.ownedSpells) do
                        local entry = cData.ownedSpells[i]
                        if entry and entry.id then
                            local sname = Sources and Sources.QuerySpellName and Sources.QuerySpellName(entry.id)
                            spellNames[#spellNames + 1] = (sname or "?") .. "(" .. entry.id .. ")"
                        end
                    end
                end
                local dormantCount = 0
                if type(cData.dormantSpells) == "table" then
                    for _ in pairs(cData.dormantSpells) do dormantCount = dormantCount + 1 end
                end
                local removedCount = 0
                if type(cData.removedSpells) == "table" then
                    for _ in pairs(cData.removedSpells) do removedCount = removedCount + 1 end
                end
                print(P, "  " .. key .. ":", count, "owned,", dormantCount, "dormant,", removedCount, "removed")
                if #spellNames > 0 then
                    local suffix = count > 5 and (" +" .. (count - 5) .. " more") or ""
                    print(P, "    ", table.concat(spellNames, ", ") .. suffix)
                end
            end
        end
        print(P, label .. ":", containerCount, "containers,", totalSpells, "total spells")
    end
end

-- Purge cross-class spell corruption from _specProfiles.
-- For each spec belonging to the current character's class, removes spells
-- that IsSpellKnownByPlayer says aren't learned (cross-class contamination).
-- Specs belonging to other classes are left untouched — run the command on
-- each character to clean their own specs.
local function RunCDMDebugClean()
    local P = "|cff34D399[CDM-Clean]|r"

    if InCombatLockdown() then
        print(P, "Cannot clean during combat.")
        return
    end

    local db = ns.Addon and ns.Addon.db and ns.Addon.db.profile and ns.Addon.db.profile.ncdm
    if not db or not db._specProfiles then
        print(P, "No spec profiles to clean.")
        return
    end

    local _, playerClass = UnitClass("player")
    if not playerClass then
        print(P, "Could not determine player class.")
        return
    end

    -- Build set of all spells the current character knows (any spec)
    -- by querying the composer's Blizzard CDM index + spellbook for
    -- comprehensive coverage.
    local knownSpells = {}
    local composer = ns.CDMComposer
    if composer and composer.CollectKnownCDMSpellIDs then
        composer.CollectKnownCDMSpellIDs(knownSpells)
    end
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
local okT = true; local numTabs = C_SpellBook.GetNumSpellBookSkillLines()
        if numTabs then
            for tab = 1, numTabs do
local okL = true; local sli = C_SpellBook.GetSpellBookSkillLineInfo(tab)
                if sli then
                    local offset = sli.itemIndexOffset or 0
                    for i = 1, (sli.numSpellBookItems or 0) do
local okI = true; local ii = C_SpellBook.GetSpellBookItemInfo(offset + i, Enum.SpellBookSpellBank.Player)
                        if ii and ii.spellID then knownSpells[ii.spellID] = true end
                    end
                end
            end
        end
    end

    local totalCleaned = 0
    local profilesChecked = 0

    for specID, specData in pairs(db._specProfiles) do
        local specLabel = tostring(specID)
        local specClass
        if GetSpecializationInfoByID then
            local _, specName, _, _, _, classFile = GetSpecializationInfoByID(specID)
            if specName then specLabel = specID .. " (" .. specName .. ")" end
            specClass = classFile
        end

        if specClass == playerClass then
            -- This spec belongs to our class — surgically remove foreign spells
            profilesChecked = profilesChecked + 1
            local specCleaned = 0
            for containerKey, cData in pairs(specData) do
                if type(cData) == "table" and type(cData.ownedSpells) == "table" then
                    local cleaned = {}
                    local removed = 0
                    for _, entry in ipairs(cData.ownedSpells) do
                        if entry and entry.id and entry.type == "spell" then
                            if knownSpells[entry.id] or IsSpellKnownByPlayer(entry.id) then
                                cleaned[#cleaned + 1] = entry
                            else
                                removed = removed + 1
                                local spellName = Sources and Sources.QuerySpellName and Sources.QuerySpellName(entry.id) or "?"
                                print(P, "  Removed", spellName .. "(" .. entry.id .. ") from", specLabel, containerKey)
                            end
                        else
                            cleaned[#cleaned + 1] = entry
                        end
                    end
                    if removed > 0 then
                        cData.ownedSpells = cleaned
                        specCleaned = specCleaned + removed
                    end
                    if type(cData.dormantSpells) == "table" then
                        for sid in pairs(cData.dormantSpells) do
                            if type(sid) == "number" and not knownSpells[sid] and not IsSpellKnownByPlayer(sid) then
                                cData.dormantSpells[sid] = nil
                                specCleaned = specCleaned + 1
                            end
                        end
                    end
                end
            end
            if specCleaned > 0 then
                totalCleaned = totalCleaned + specCleaned
                print(P, specLabel .. ": cleaned", specCleaned, "foreign spells")
            else
                print(P, specLabel .. ": clean")
            end
        elseif specClass and specClass ~= playerClass then
            -- Different class — surgically remove any of OUR spells that
            -- leaked into their profile, preserving their legitimate spells.
            local specCleaned = 0
            for containerKey, cData in pairs(specData) do
                if type(cData) == "table" and type(cData.ownedSpells) == "table" then
                    local cleaned = {}
                    local removed = 0
                    for _, entry in ipairs(cData.ownedSpells) do
                        if entry and entry.id and entry.type == "spell"
                           and (knownSpells[entry.id] or IsSpellKnownByPlayer(entry.id)) then
                            removed = removed + 1
                            local spellName = Sources and Sources.QuerySpellName and Sources.QuerySpellName(entry.id) or "?"
                            print(P, "  Removed", spellName .. "(" .. entry.id .. ") from", specLabel, containerKey)
                        else
                            cleaned[#cleaned + 1] = entry
                        end
                    end
                    if removed > 0 then
                        cData.ownedSpells = cleaned
                        specCleaned = specCleaned + removed
                    end
                    if type(cData.dormantSpells) == "table" then
                        for sid in pairs(cData.dormantSpells) do
                            if type(sid) == "number" and (knownSpells[sid] or IsSpellKnownByPlayer(sid)) then
                                cData.dormantSpells[sid] = nil
                                specCleaned = specCleaned + 1
                            end
                        end
                    end
                end
            end
            if specCleaned > 0 then
                totalCleaned = totalCleaned + specCleaned
                print(P, specLabel .. ": cleaned", specCleaned, "foreign spells")
            else
                print(P, specLabel .. ": clean")
            end
        else
            print(P, specLabel .. ": skipped (unknown spec)")
        end
    end

    print(P, "Done.", profilesChecked, "profiles checked,", totalCleaned, "foreign spells removed.")
    print(P, "Run /cdmdebug profile to verify. Run this on each character to clean their specs.")
end

---------------------------------------------------------------------------
-- CDMDebug NAMESPACE
-- Emitters and predicates relocated from the engine files. Consumer files
-- declare a `local X = function() end` placeholder at file-top, then in
-- their tail register a _BindDebugImports() that pulls from ns.CDMDebug.
-- We invoke each consumer's _BindDebugImports at the end of THIS file when the
-- load-on-demand debug addon is loaded.
---------------------------------------------------------------------------
local CDMDebug = {}
ns.CDMDebug = CDMDebug

---------------------------------------------------------------------------
-- FILTER MATCHING
-- One predicate that handles all the per-flag filters. flag is nil/false
-- (off), true (match all), or a string (substring on name, or exact match
-- on id). candidates is a list of strings/numbers to test against.
---------------------------------------------------------------------------
function CDMDebug.MatchFilter(flag, ...)
    if not flag then return false end
    if flag == true then return true end
    local needle = tostring(flag):lower()
    if needle == "" then return false end
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v then
            local s = tostring(v):lower()
            if s == needle or s:find(needle, 1, true) then return true end
        end
    end
    return false
end

function CDMDebug.ShouldBar(entry, spellID)
    return CDMDebug.MatchFilter(_G.QUI_CDM_BAR_DEBUG, entry and entry.name, spellID)
end

function CDMDebug.ShouldAura(entryName, spellID, entryID)
    return CDMDebug.MatchFilter(_G.QUI_CDM_AURA_DEBUG, entryName, spellID, entryID)
end

function CDMDebug.ShouldBlizz(entry, lookupIDs)
    local flag = _G.QUI_CDM_BLIZZ_DEBUG or _G.QUI_CDM_ICON_DEBUG
    if not flag then return false end
    if flag == true then return true end
    if CDMDebug.MatchFilter(flag, entry and entry.name, entry and entry.id,
                            entry and entry.spellID, entry and entry.overrideSpellID) then
        return true
    end
    if type(lookupIDs) == "table" then
        for _, id in ipairs(lookupIDs) do
            if CDMDebug.MatchFilter(flag, id) then return true end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- FORMATTERS
---------------------------------------------------------------------------
function CDMDebug.FormatIDList(ids)
    if type(ids) ~= "table" or #ids == 0 then return "nil" end
    local out = {}
    for i, id in ipairs(ids) do
        out[i] = tostring(id)
    end
    return table.concat(out, ",")
end

function CDMDebug.FormatMirrorState(state, sep)
    if not state then return "nil" end
    sep = sep or " "
    return "cdID=" .. tostring(state.cooldownID)
        .. sep .. "cat=" .. tostring(state.viewerCategory)
        .. sep .. "active=" .. tostring(state.isActive == true)
        .. sep .. "dur=" .. tostring(state.durObj and true or false)
        .. sep .. "inst=" .. tostring(state.hasAuraInstanceID == true)
        .. sep .. "unit=" .. tostring(state.auraUnit)
        .. sep .. "fromAura=" .. tostring(state.wasSetFromAura)
        .. sep .. "fromCd=" .. tostring(state.wasSetFromCooldown)
        .. sep .. "fromCharges=" .. tostring(state.wasSetFromCharges)
        .. sep .. "spell=" .. tostring(state.spellID)
        .. sep .. "ov=" .. tostring(state.overrideSpellID)
        .. sep .. "tooltip=" .. tostring(state.overrideTooltipSpellID)
        .. sep .. "links=" .. CDMDebug.FormatIDList(state.linkedSpellIDs)
end

---------------------------------------------------------------------------
-- CHARGE DEBUG
-- /run QUI_CDM_CHARGE_DEBUG = true | "spellName"
-- Throttle keeps tick-based messages to 1/sec per spell+tag.
---------------------------------------------------------------------------
local _chargeDebugThrottle = {}
function CDMDebug.Charge(spellName, ...)
    if not _G.QUI_CDM_CHARGE_DEBUG then return end
    local filter = _G.QUI_CDM_CHARGE_DEBUG
    if type(filter) == "string" and spellName and not spellName:find(filter) then return end
    local tag = select(1, ...) or ""
    if tag == "FWD path:" or tag == "SKIP API path:" or tag == "API path:" or tag == "FWD path CLEAR:"
        or tag == "DESAT charged check:" or tag == "DESAT result:"
        or tag == "MIRROR hook:" then
        local key = (spellName or "") .. tag
        local now = GetTime()
        if _chargeDebugThrottle[key] and now - _chargeDebugThrottle[key] < 1 then return end
        _chargeDebugThrottle[key] = now
    end
    local parts = { "|cff34D399[CDM-Charge]|r", spellName or "?", "-" }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    print(table.concat(parts, " "))
end

---------------------------------------------------------------------------
-- STACKTEXT DEBUG (icon)
-- Moved from cdm_icons.lua. Attached to CDMIcons table so existing
-- CDMIcons.DebugStackText(...) call sites continue to work without churn.
---------------------------------------------------------------------------
function CDMIcons.DebugStackText(icon, action, value, reason)
    if not _G.QUI_CDM_CHARGE_DEBUG then return end
    local entry = icon and icon._spellEntry
    local okShown, shown = false, nil
    local okText, text = false, nil
    if icon then
okShown = true; shown = icon.IsShown(icon)
    end
    if icon and icon.StackText and icon.StackText.GetText then
okText = true; text = icon.StackText.GetText(icon.StackText)
    end
    CDMDebug.Charge(entry and entry.name,
        "STACKTEXT", action,
        "reason=", reason or "nil",
        "value=", tostring(value),
        "oldText=", okText and tostring(text) or "err",
        "iconShown=", okShown and tostring(shown) or "err",
        "entryType=", entry and entry.type,
        "viewerType=", entry and entry.viewerType,
        "hasCharges=", entry and entry.hasCharges,
        "spellID=", entry and entry.spellID,
        "overrideSpellID=", entry and entry.overrideSpellID,
        "runtimeSpellID=", icon and icon._runtimeSpellID,
        "auraActive=", icon and icon._auraActive)
end

---------------------------------------------------------------------------
-- BAR DEBUG
-- Single label-emitter used by cdm_bars.lua. The `_OnBarUpdate` path above
-- handles the per-tick dump separately.
---------------------------------------------------------------------------
function CDMDebug.Bar(entry, spellID, ...)
    if not CDMDebug.ShouldBar(entry, spellID) then return end
    print("|cff34D399[CDM-BarDbg]|r", ...)
end

---------------------------------------------------------------------------
-- BLIZZ-BIND DEBUG
-- /cdmdebug flags blizz toggle. Pre-checked predicate is passed in as `enabled`
-- so caller can compute it once outside a loop.
---------------------------------------------------------------------------
function CDMDebug.Blizz(enabled, entry, label, ...)
    if not enabled then return end
    print("|cff34D399[CDM-BlizzBind]|r",
        tostring(label),
        entry and (entry.name or "?") or "?",
        "viewer=", entry and tostring(entry.viewerType) or "nil",
        "kind=", entry and tostring(entry.kind) or "nil",
        "entryID=", entry and tostring(entry.id) or "nil",
        "spellID=", entry and tostring(entry.spellID) or "nil",
        "override=", entry and tostring(entry.overrideSpellID) or "nil",
        ...)
end

---------------------------------------------------------------------------
-- AURA-STATE DEBUG (secret-safe FontString sink)
--
-- Debug output is split between two sinks so secret values are never
-- destroyed nor crash the resolver:
--
--   * Clean (no secret args) → print() to chat. table.concat is fine
--     when nothing in the parts array is secret-typed.
--   * Secret-bearing → SetText to a dedicated FontString. table.concat
--     errors with "invalid value (secret) at index N" because secrets
--     can't flow through it; C_StringUtil.WrapString (AllowedWhenTainted)
--     produces a string whose secret content is renderable through
--     FontString:SetText (also AllowedWhenTainted) without ever being
--     compared, arithmetic'd, or tostring'd in Lua.
---------------------------------------------------------------------------
local _auraDebugFrame
local _auraDebugFontStrings
local _auraDebugMaxLines = 30
local _auraDebugWriteIdx = 0

local function EnsureAuraDebugFrame()
    if _auraDebugFrame then return end
    _auraDebugFrame = CreateFrame("Frame", "QUI_CDMAuraDebugFrame", UIParent)
    _auraDebugFrame:SetSize(900, _auraDebugMaxLines * 16 + 16)
    _auraDebugFrame:SetPoint("TOPLEFT", 60, -120)
    _auraDebugFrame:SetFrameStrata("DIALOG")
    _auraDebugFrame:EnableMouse(true)
    _auraDebugFrame:SetMovable(true)
    _auraDebugFrame:RegisterForDrag("LeftButton")
    _auraDebugFrame:SetScript("OnDragStart", _auraDebugFrame.StartMoving)
    _auraDebugFrame:SetScript("OnDragStop", _auraDebugFrame.StopMovingOrSizing)
    local bg = _auraDebugFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.7)
    _auraDebugFontStrings = {}
    for i = 1, _auraDebugMaxLines do
        local fs = _auraDebugFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 16)
        fs:SetPoint("RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        _auraDebugFontStrings[i] = fs
    end
end

local function HasSecretArg(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue(select(i, ...)) then return true end
    end
    return false
end

function CDMDebug.Aura(enabled, ...)
    if not enabled then return end

    if not HasSecretArg(...) then
        local parts = { "|cff34D399[CDM-Aura]|r" }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        print(table.concat(parts, " "))
        return
    end

    -- Secret-bearing path: route to a FontString in the dedicated debug
    -- frame. Build the message by chaining C_StringUtil.WrapString
    -- (AllowedWhenTainted) for the secret args and Lua concat for the
    -- non-secret ones. The final string can carry secret content; SetText
    -- accepts it and renders without exposing the value to Lua-level ops.
    EnsureAuraDebugFrame()
    _auraDebugWriteIdx = (_auraDebugWriteIdx % _auraDebugMaxLines) + 1
    local fs = _auraDebugFontStrings and _auraDebugFontStrings[_auraDebugWriteIdx]
    if not fs then return end

    local message = "|cff34D399[CDM-Aura]|r"
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if issecretvalue and issecretvalue(v)
            and C_StringUtil and C_StringUtil.WrapString then
            message = C_StringUtil.WrapString(v, message .. " ", "")
        else
            message = message .. " " .. tostring(v)
        end
    end

    fs:SetText(message)
end

-- Aura formatter — uses "/" separator to match prior cdm_spelldata.lua output.
function CDMDebug.FormatAuraMirrorState(state)
    return CDMDebug.FormatMirrorState(state, "/")
end

---------------------------------------------------------------------------
-- TAINT DEBUG (EditBox sink)
--
-- Toggle: /cdmdebug flags taint on; /rl
-- Filter: /cdmdebug flags taint Sync; /rl
-- Buffer: /run QUI_CDM_TAINT_BUFFER_MAX = 1000; /rl
--
-- Instrumented call sites use Taint(label, k1, v1, k2, v2, ...) to emit a
-- single line describing each field's secrecy status. Secrets are rendered
-- as "<SECRET:type>" so the message string itself never carries secret
-- content (table.concat / SetText both work). Non-secret values render
-- with their type and literal value.
--
-- Output goes to a draggable EditBox panel (QUI_CDMTaintDebugFrame) —
-- print/chat would crash if any value managed to slip through unstripped.
---------------------------------------------------------------------------
local function _formatTaintField(name, v)
    local prefix = tostring(name) .. "="
    if issecretvalue and issecretvalue(v) then
        return prefix .. "<SECRET:" .. type(v) .. ">"
    end
    if v == nil then return prefix .. "nil" end
    local t = type(v)
    if t == "boolean" then return prefix .. (v and "true" or "false") .. ":bool" end
    if t == "number"  then return prefix .. tostring(v) .. ":num" end
    if t == "string"  then return prefix .. "\"" .. v .. "\":str" end
    return prefix .. "<" .. t .. ">"
end

local _taintFrame
local _taintEditBox
local _taintScroll
local _taintBuffer = {}
local _taintBufferMax = 1000
local _taintAutoScroll = true
local _taintLastMessage
local _taintLastRepeat = 0

local function _getTaintBufferMax()
    local n = tonumber(_G.QUI_CDM_TAINT_BUFFER_MAX)
    if not n then return _taintBufferMax end
    if n < 50 then return 50 end
    if n > 5000 then return 5000 end
    return math.floor(n)
end

local function _taintMessageAllowed(label, message)
    local filter = _G.QUI_CDM_TAINT_FILTER
    if type(_G.QUI_CDM_TAINT_DEBUG) == "string" then
        filter = _G.QUI_CDM_TAINT_DEBUG
    end
    if type(filter) ~= "string" or filter == "" then return true end

    local needle = filter:lower()
    local labelText = tostring(label):lower()
    return labelText:find(needle, 1, true) ~= nil
        or message:lower():find(needle, 1, true) ~= nil
end

local function _appendTaintMessage(message)
    if _taintLastMessage == message and #_taintBuffer > 0 then
        _taintLastRepeat = _taintLastRepeat + 1
        _taintBuffer[#_taintBuffer] = message .. " | repeat=" .. tostring(_taintLastRepeat) .. ":num"
    else
        _taintLastMessage = message
        _taintLastRepeat = 1
        _taintBuffer[#_taintBuffer + 1] = message
    end

    local maxLines = _getTaintBufferMax()
    while #_taintBuffer > maxLines do
        table.remove(_taintBuffer, 1)
    end
end

local function _ensureTaintFrame()
    if _taintFrame then return end
    _taintFrame = CreateFrame("Frame", "QUI_CDMTaintDebugFrame", UIParent)
    _taintFrame:SetSize(1100, 500)
    _taintFrame:SetPoint("TOPLEFT", 60, -50)
    _taintFrame:SetFrameStrata("DIALOG")
    _taintFrame:EnableMouse(true)
    _taintFrame:SetMovable(true)
    _taintFrame:RegisterForDrag("LeftButton")
    _taintFrame:SetScript("OnDragStart", _taintFrame.StartMoving)
    _taintFrame:SetScript("OnDragStop", _taintFrame.StopMovingOrSizing)

    local bg = _taintFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.85)

    local title = _taintFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -4)
    title:SetText("|cffFF6699[CDM Taint]|r drag to move \194\183 click text to select \194\183 Ctrl+A / Ctrl+C to copy \194\183 filter: /cdmdebug taint <text>")

    _taintScroll = CreateFrame("ScrollFrame", "QUI_CDMTaintDebugScroll", _taintFrame, "UIPanelScrollFrameTemplate")
    _taintScroll:SetPoint("TOPLEFT", 8, -22)
    _taintScroll:SetPoint("BOTTOMRIGHT", -28, 8)

    _taintEditBox = CreateFrame("EditBox", nil, _taintScroll)
    _taintEditBox:SetMultiLine(true)
    _taintEditBox:SetMaxLetters(0)
    _taintEditBox:SetFontObject("GameFontHighlightSmall")
    _taintEditBox:SetWidth(1060)
    _taintEditBox:SetAutoFocus(false)
    _taintEditBox:EnableMouse(true)
    _taintEditBox:SetScript("OnEscapePressed", _taintEditBox.ClearFocus)
    _taintEditBox:SetScript("OnEditFocusGained", function() _taintAutoScroll = false end)
    _taintEditBox:SetScript("OnEditFocusLost",   function() _taintAutoScroll = true end)
    _taintScroll:SetScrollChild(_taintEditBox)
end

function CDMDebug.Taint(label, ...)
    if not _G.QUI_CDM_TAINT_DEBUG then return end

    local n = select("#", ...)
    local message = "[Taint] " .. tostring(label)
    for i = 1, n, 2 do
        local k = select(i, ...)
        local v = select(i + 1, ...)
        message = message .. " | " .. _formatTaintField(k, v)
    end

    if not _taintMessageAllowed(label, message) then return end

    _ensureTaintFrame()
    if not _taintEditBox then return end

    _appendTaintMessage(message)

    _taintEditBox:SetText(table.concat(_taintBuffer, "\n"))

    if _taintAutoScroll and _taintScroll and C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if _taintScroll then
                local maxScroll = _taintScroll:GetVerticalScrollRange()
                if maxScroll then _taintScroll:SetVerticalScroll(maxScroll) end
            end
        end)
    end
end

local function _renderDebugLinesToEditBox(lines)
    _ensureTaintFrame()
    if not _taintEditBox then return end

    for key in pairs(_taintBuffer) do
        _taintBuffer[key] = nil
    end
    _taintLastMessage = nil
    _taintLastRepeat = 0

    if type(lines) == "table" then
        for i, line in ipairs(lines) do
            _taintBuffer[i] = tostring(line)
        end
    end

    _taintEditBox:SetText(table.concat(_taintBuffer, "\n"))
    if _taintScroll then
        _taintScroll:SetVerticalScroll(0)
    end
end

local function RunCDMDebugRaw()
    local P = "|cff34d399[CDM raw]|r"
    local mirror = ns.CDMBlizzMirror
    if mirror and mirror.BindNewChildren then
        mirror.BindNewChildren()
    end
    if not (mirror and mirror.GetRawCooldownViewerDebugLines) then
        _renderDebugLinesToEditBox({ "[CDM raw] mirror raw dump API unavailable" })
        print(P, "raw dump API unavailable")
        return
    end

    local lines = mirror.GetRawCooldownViewerDebugLines()
    _renderDebugLinesToEditBox(lines)
    print(P, "dumped", tostring(type(lines) == "table" and #lines or 0), "line(s) to the CDM debug text window.")
end

local function RunCDMDebugInfo(msg)
    local arg = TrimText(msg)
    if arg == "" then arg = nil end
    local mirror = ns.CDMBlizzMirror
    if not (mirror and mirror.DumpInfoForSpell) then
        print("|cff60A5FAQUI:|r CDM mirror not loaded.")
        return
    end
    mirror.DumpInfoForSpell(arg)
end

local function RunCDMDebugChild(msg)
    local arg = TrimText(msg)
    local cdIDText, category = arg:match("^(%S+)%s*(%S*)")
    local cdID = tonumber(cdIDText)
    if not cdID then
        print("|cff60A5FAQUI:|r usage: /cdmdebug mirror child <cooldownID> [essential|utility|buff|trackedBar]")
        return
    end
    if category == "" then category = nil end
    local mirror = ns.CDMBlizzMirror
    if not (mirror and mirror.GetChildDebugLines) then
        print("|cff60A5FAQUI:|r CDM mirror not loaded.")
        return
    end
    local lines = mirror.GetChildDebugLines(cdID, category)
    print(("|cff60A5FAQUI CDM child:|r cdID=%d category=%s"):format(cdID, tostring(category or "auto")))
    if type(lines) == "table" then
        for _, line in ipairs(lines) do
            print("  " .. tostring(line))
        end
    end
end

local function FindDebugTargetID(target)
    local numeric = tonumber(target and target:match("^(%d+)$"))
    if numeric then return numeric end
    local needle = TrimText(target):lower()
    if needle == "" then return nil end

    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            local entry = icon and icon._spellEntry
            local name = entry and entry.name
            if type(name) == "string" and name:lower():find(needle, 1, true) then
                return CDMGCDFirstID(
                    icon._runtimeSpellID,
                    entry.overrideSpellID,
                    entry.spellID,
                    entry.id,
                    entry.itemID)
            end
        end
    end
    return nil
end

local function FindDebugTargetName(target)
    local targetText = TrimText(target)
    if targetText == "" then return nil end
    local targetID = tonumber(targetText:match("^(%d+)$"))
    local needle = targetID and nil or targetText:lower()
    for _, pool in pairs(iconPools) do
        for _, icon in ipairs(pool) do
            local entry = icon and icon._spellEntry
            if entry and CDMGCDIconMatches(icon, needle, targetID) then
                return entry.name
            end
        end
    end
    return nil
end

local SPELL_MODES = {
    once = true,
    watch = true,
    events = true,
    event = true,
    writes = true,
    write = true,
    trace = true,
    desat = true,
    charge = true,
    flicker = true,
}

local function ParseSpellDebugRequest(msg)
    local text = TrimText(msg)
    local lower = text:lower()
    if lower == "" then return "", "help", nil end
    if lower == "off" or lower == "clear" or lower == "stop" then
        return "", "off", nil
    end

    local seconds
    local base, tail = text:match("^(.-)%s+(%S+)$")
    if base and tonumber(tail) then
        seconds = tonumber(tail)
        text = TrimText(base)
        lower = text:lower()
    end

    local mode = seconds and "watch" or "once"
    base, tail = text:match("^(.-)%s+(%S+)$")
    if base and tail then
        local tailLower = tail:lower()
        if SPELL_MODES[tailLower] then
            mode = tailLower
            text = TrimText(base)
        end
    elseif SPELL_MODES[lower] then
        return "", lower, seconds
    end

    if mode == "event" then mode = "events" end
    if mode == "write" or mode == "writes" then mode = "events" end
    if mode == "desat" then mode = "trace" end

    return text, mode, seconds
end

local function RunCDMDebugSpell(msg)
    local target, mode, seconds = ParseSpellDebugRequest(msg)
    if mode == "help" then
        print("|cff34D399[CDM-Debug]|r spell usage:")
        print("  /cdmdebug spell <spellID|name>              -> one-shot resolver/API/icon report")
        print("  /cdmdebug spell <spellID|name> watch [sec]  -> timed GCD/swipe watch")
        print("  /cdmdebug spell <spellID|name> events       -> event + write trace")
        print("  /cdmdebug spell <spell name> trace          -> desaturation transition trace")
        print("  /cdmdebug spell <spell name> charge         -> charge-path report")
        print("  /cdmdebug spell <spell name> flicker        -> 5-second transition sampler")
        print("  /cdmdebug spell off                         -> stop spell traces/watchers")
        return
    end

    if mode == "off" then
        RunCDMDebugEvents("off")
        RunCDMDebugTrace("")
        CDMGCDStopWatch(false)
        return
    end

    if target == "" then
        RunCDMDebugSpell("")
        return
    end

    if mode == "events" then
        local targetID = FindDebugTargetID(target)
        if not targetID then
            print("|cffffaa00[cdmevents]|r no spellID found for '" .. tostring(target) .. "'")
            return
        end
        RunCDMDebugEvents(tostring(targetID))
    elseif mode == "trace" then
        RunCDMDebugTrace(FindDebugTargetName(target) or target)
    elseif mode == "charge" then
        RunCDMDebugCharge(target)
    elseif mode == "flicker" then
        RunCDMDebugFlicker(target)
    elseif mode == "watch" then
        local duration = tonumber(seconds) or 5
        RunCDMDebugGCD(target .. " " .. tostring(duration))
    else
        RunCDMDebugGCD(target .. " once")
    end
end

local function RunCDMDebugMirror(msg)
    local text = TrimText(msg)
    if text == "" then
        print("|cff34D399[CDM-Debug]|r mirror usage:")
        print("  /cdmdebug mirror [filter|spellID|cooldownID]       -> sanitized mirror info")
        print("  /cdmdebug mirror child <cooldownID> [category]      -> child frame/text dump")
        print("  /cdmdebug mirror raw                                -> raw viewer/category dump")
        print("  /cdmdebug mirror cdtest <cooldownID>                -> cooldown setter test frame")
        return
    end

    local cmd, rest = text:match("^(%S+)%s*(.-)$")
    local lower = cmd and cmd:lower() or ""
    if lower == "child" then
        RunCDMDebugChild(rest)
    elseif lower == "raw" then
        RunCDMDebugRaw()
    elseif lower == "cdtest" or lower == "test" then
        RunCDMDebugCooldownTest(rest)
    else
        RunCDMDebugInfo(text)
    end
end

local function RunCDMDebugCache(msg)
    local sub = TrimText(msg)
    if sub == "" then sub = "status" end
    if QUI and QUI.SlashCommandOpen then
        QUI:SlashCommandOpen("cdm_cache " .. sub)
    else
        print("|cffffaa00[CDM-Debug]|r cache command unavailable.")
    end
end

local function RunCDMDebugProfile(msg)
    local sub = TrimText(msg):lower()
    if sub == "" or sub == "status" then
        RunCDMDebugProfiles()
    elseif sub == "clean" then
        RunCDMDebugClean()
    else
        print("|cffffaa00[CDM-Debug]|r profile usage: /cdmdebug profile [status|clean]")
    end
end

local function PrintCDMDebugHelp()
    print("|cff34D399[CDM-Debug]|r commands:")
    print("  /cdmdebug status                         -> command help + flag state")
    print("  /cdmdebug flags [name] [on|off|filter]   -> debug flags")
    print("  /cdmdebug spell <target> [mode]           -> spell/icon case report")
    print("  /cdmdebug mirror [filter|child|raw|cdtest] -> mirror/child diagnostics")
    print("  /cdmdebug cache [status|reset]            -> cache status/reset")
    print("  /cdmdebug profile [status|clean]          -> CDM profile tools")
    print("  /cdmdebug probe                           -> resolver/mirror parity sweep")
    print("  direct flag shorthand: /cdmdebug icon on, /cdmdebug taint Sync, /cdmdebug off")
    ListDebugFlags()
end

local function RunCDMDebugCommand(msg)
    local text = TrimText(msg)
    if text == "" or text:lower() == "help" or text:lower() == "status" then
        PrintCDMDebugHelp()
        return
    end

    local cmd, rest = text:match("^(%S+)%s*(.-)$")
    local lower = cmd and cmd:lower() or ""
    if lower == "flags" then
        RunCDMDebugFlags(rest)
    elseif DEBUG_FLAGS[lower] or lower == "off" or lower == "clear" then
        RunCDMDebugFlags(text)
    elseif lower == "spell" then
        RunCDMDebugSpell(rest)
    elseif lower == "mirror" then
        RunCDMDebugMirror(rest)
    elseif lower == "cache" then
        RunCDMDebugCache(rest)
    elseif lower == "profile" or lower == "profiles" then
        RunCDMDebugProfile(rest)
    elseif lower == "raw" then
        RunCDMDebugRaw()
    elseif lower == "probe" then
        RunCDMDebugProbe()
    elseif lower == "cdtest" then
        RunCDMDebugCooldownTest(rest)
    else
        print("|cffffaa00[CDM-Debug]|r unknown command '" .. tostring(cmd) .. "'. Use /cdmdebug help.")
    end
end

SLASH_QUI_CDMDEBUG1 = "/cdmdebug"
SlashCmdList["QUI_CDMDEBUG"] = function(msg)
    RunCDMDebugCommand(msg)
end

---------------------------------------------------------------------------
-- DEFERRED IMPORT BINDING
-- Each consumer file declares `local X = function() end` placeholders at
-- file-top (or file-local upvalues), and registers a _BindDebugImports
-- function that reassigns those upvalues from ns.CDMDebug. We invoke
-- each consumer's binder here, after all CDMDebug.* are defined.
--
-- After binding, hot-path callers in those files keep their existing
-- local-upvalue call form (no per-call table lookup overhead).
---------------------------------------------------------------------------
local function BindAll()
    local mods = {
        ns.CDMIcons,
        ns.CDMIconFactory,
        ns.CDMBars,
        ns.CDMSpellData,
        ns.CDMBlizzMirror,
    }
    for _, mod in ipairs(mods) do
        if mod and mod._BindDebugImports then
            mod._BindDebugImports()
        end
    end
end

-- Re-attach the public surfaces that consumer files captured during
-- their own load (their local upvalues will point at the new functions
-- via BindAll(); these table-method assignments cover external callers
-- that go through the module table — e.g., cdm_blizz_mirror.lua's
-- public CDMBlizzMirror.TaintLog is consumed by cdm_icon_factory.lua).
if ns.CDMBlizzMirror then
    ns.CDMBlizzMirror.TaintLog = CDMDebug.Taint
end
CDMIcons.ChargeDebug = CDMDebug.Charge

BindAll()
