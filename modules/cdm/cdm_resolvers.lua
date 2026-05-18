-- cdm_resolvers.lua
-- Pure resolution layer for the QUI CDM owned engine.
-- Functions in this file MUST NOT write to frames; they compute and return values.
-- Runtime query wrappers live here because both resolvers and the icon factory's
-- UpdateIconCooldown driver depend on the same source facade calls.

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local Shared = ns.CDMShared

local CDMResolvers = {}
ns.CDMResolvers = CDMResolvers
local Scheduler = ns.CDMScheduler
local Sources = ns.CDMSources

---------------------------------------------------------------------------
-- Event bus
--
-- Synchronous dispatch with a per-call snapshot of the subscriber list. The
-- snapshot is intentional: it freezes which handlers fire for the current
-- publish so that subscribing during dispatch doesn't include the new
-- handler in the in-flight event (verified by tests/cdm_bus_test.lua).
-- Subscribers run in the resolver's tick. Events carry IDs only; subscribers
-- pull fresh state through the runtime query wrappers. See spec:
-- docs/superpowers/specs/2026-05-05-cdm-blizzard-child-decoupling-design.md
---------------------------------------------------------------------------
local _subscribers = {} -- [eventName] = { handler1, handler2, ... }

local function publish(eventName, ...)
    if Scheduler and Scheduler.Publish then
        Scheduler.Publish(eventName, ...)
        return
    end

    local list = _subscribers[eventName]
    if not list then return end
    local n = #list
    if n == 0 then return end
    local snapshot = {}
    for i = 1, n do snapshot[i] = list[i] end
    for i = 1, n do
        xpcall(snapshot[i], geterrorhandler(), eventName, ...)
    end
end

function CDMResolvers.Subscribe(eventName, handler)
    if Scheduler and Scheduler.Subscribe then
        Scheduler.Subscribe(eventName, handler)
        return
    end

    local list = _subscribers[eventName]
    if not list then
        list = {}
        _subscribers[eventName] = list
    end
    list[#list + 1] = handler
end

function CDMResolvers.Unsubscribe(eventName, handler)
    if Scheduler and Scheduler.Unsubscribe then
        Scheduler.Unsubscribe(eventName, handler)
        return
    end

    local list = _subscribers[eventName]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == handler then
            table.remove(list, i)
            return
        end
    end
end

---------------------------------------------------------------------------
-- Catalog publication
--
-- Publishes CDM:CATALOG_REBUILT on lifecycle events. Combat-deferred:
-- TRAIT_TREE_CHANGED fires inside combat, so rebuild waits for
-- PLAYER_REGEN_ENABLED. Aura instance IDs re-randomize on encounter/M+/PvP
-- starts, so those are also rebuild triggers.
---------------------------------------------------------------------------
local _busEventFrame = CreateFrame("Frame")
local _rebuildPending = false

local function RebuildCatalog()
    if InCombatLockdown() then
        _rebuildPending = true
        return
    end
    _rebuildPending = false
    CDMResolvers._catalogVersion = (CDMResolvers._catalogVersion or 0) + 1
    publish("CDM:CATALOG_REBUILT")
end

CDMResolvers._RebuildCatalog = RebuildCatalog

_busEventFrame:RegisterEvent("PLAYER_LOGIN")
_busEventFrame:RegisterEvent("TRAIT_TREE_CHANGED")
_busEventFrame:RegisterEvent("SPELLS_CHANGED")
_busEventFrame:RegisterEvent("ENCOUNTER_START")
_busEventFrame:RegisterEvent("CHALLENGE_MODE_START")
_busEventFrame:RegisterEvent("PVP_MATCH_ACTIVE")
_busEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
_busEventFrame:SetScript("OnEvent", function(_, evt)
    if evt == "PLAYER_REGEN_ENABLED" then
        if _rebuildPending then RebuildCatalog() end
        return
    end
    RebuildCatalog()
end)

---------------------------------------------------------------------------
-- Runtime delta publication
--
-- The resolver owns cooldown/charge runtime event registration and publishes
-- CDM:* events when state changes. Consumers subscribe to the bus and pull
-- fresh state via the runtime query wrappers. UNIT_AURA is handled by
-- cdm_spelldata.lua because its batched payload is the source of truth.
---------------------------------------------------------------------------
local _runtimeFrame = CreateFrame("Frame")
_runtimeFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
_runtimeFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
_runtimeFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
_runtimeFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
_runtimeFrame:SetScript("OnEvent", function(_, evt, arg1, arg2, arg3)
    if evt == "SPELL_UPDATE_COOLDOWN" then
        -- arg1 is Blizzard's spellID hint (may be nil for "update all").
        -- Subscriber chooses per-spell fast-path vs global walk.
        publish("CDM:COOLDOWN_CHANGED", arg1, arg2, "refresh")
    elseif evt == "SPELL_UPDATE_CHARGES" then
        publish("CDM:CHARGES_CHANGED", arg1)
    elseif evt == "UNIT_SPELLCAST_START" then
        if arg1 == "player" then
            publish("CDM:COOLDOWN_CHANGED", arg3, nil, "cast_start")
        end
    elseif evt == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            publish("CDM:COOLDOWN_CHANGED", arg3, nil, "cast_succeeded")
        end
    end
end)

local function IsSafeNumeric(val)
    return Shared and Shared.IsSafeNumeric(val) or type(val) == "number"
end

local function SafeBoolean(val)
    if Shared and Shared.SafeBoolean then
        return Shared.SafeBoolean(val)
    end
    if type(val) == "boolean" then
        return val
    end
    return nil
end

local function GetAuraDataInstanceID(auraData)
    if not auraData then return nil end
local ok = true; local instID = auraData.auraInstanceID
    if not ok then return nil end
    return instID
end

local GCD_MAX_DURATION = 1.75
local GCD_SPELL_ID = 61304
local WoW_IsSecretValue = issecretvalue
local _chargeZeroCurve

local function ResolverIsSecretValue(value)
    if WoW_IsSecretValue then
        return WoW_IsSecretValue(value)
    end
    return false
end

local function HasOpaqueValue(value)
    if ResolverIsSecretValue(value) then
        return true
    end
    return value ~= nil
end

local function CleanOpaqueValue(value)
    if ResolverIsSecretValue(value) then
        return nil
    end
    return value
end

function CDMResolvers.GetCooldownInfoField(info, key)
    -- Returns (value, isSecret). Combat-restricted fields may be secret when
    -- the Blizzard CDM feed is active; callers may pass the raw value to safe
    -- C-side sinks but must not compare it in Lua when isSecret is true.
    if not info then return nil, false end
    local value = info[key]
    if value == nil then return nil, false end
    if ResolverIsSecretValue(value) then
        return value, true
    end
    return value, false
end

function CDMResolvers.GetCooldownInfoStartDuration(info)
    local start, startSecret = CDMResolvers.GetCooldownInfoField(info, "startTime")
    if start == nil and not startSecret then
        start, startSecret = CDMResolvers.GetCooldownInfoField(info, "start")
    end
    local duration, durationSecret = CDMResolvers.GetCooldownInfoField(info, "duration")
    return start, duration, startSecret or durationSecret
end

function CDMResolvers.IsCooldownInfoActive(info)
    local active, activeSecret = CDMResolvers.GetCooldownInfoField(info, "isActive")
    if activeSecret then return nil end
    if type(active) == "boolean" then
        return active
    end
    return nil
end

function CDMResolvers.IsCooldownInfoRealCooldown(info)
    if not info then return false end

    local active = CDMResolvers.IsCooldownInfoActive(info)
    if active == false then
        return false
    end

    local enabled, enabledSecret = CDMResolvers.GetCooldownInfoField(info, "isEnabled")
    if enabledSecret then
        return nil
    end
    if enabled == false then
        return false
    end

    local start, duration, timingSecret = CDMResolvers.GetCooldownInfoStartDuration(info)
    if not timingSecret and IsSafeNumeric(duration) then
        if duration <= GCD_MAX_DURATION then
            return false
        end
        if IsSafeNumeric(start) and start <= 0 then
            return false
        end
        if active == true then
            return true
        end
    end

    local activeCategory, categorySecret = CDMResolvers.GetCooldownInfoField(info, "activeCategory")
    if categorySecret then
        return nil
    end
    if activeCategory ~= nil then
        return true
    end

    local startRecovery, recoverySecret =
        CDMResolvers.GetCooldownInfoField(info, "timeUntilEndOfStartRecovery")
    if not recoverySecret and IsSafeNumeric(startRecovery) and startRecovery > 0 then
        return false
    elseif startRecovery ~= nil and not timingSecret and not recoverySecret then
        return false
    end
    if recoverySecret or timingSecret then
        return nil
    end

    return false
end

local GetCooldownInfoField = CDMResolvers.GetCooldownInfoField
local IsCooldownInfoActive = CDMResolvers.IsCooldownInfoActive
local IsCooldownInfoRealCooldown = CDMResolvers.IsCooldownInfoRealCooldown

local RuntimeQueries = ns.CDMRuntimeQueries

local QueryCharges        = RuntimeQueries.QueryCharges
local QueryCooldown       = RuntimeQueries.QueryCooldown
local QueryDuration       = RuntimeQueries.QueryDuration
local QueryGCDDuration    = RuntimeQueries.QueryGCDDuration
local QueryChargeDuration = RuntimeQueries.QueryChargeDuration
local QueryOverrideSpell  = RuntimeQueries.QueryOverrideSpell
local QueryDisplayCount   = RuntimeQueries.QueryDisplayCount
local QuerySpellCount     = RuntimeQueries.QuerySpellCount


-- IDENTITY RESOLVERS

local function IsItemLikeEntry(entry)
    return entry and (entry.type == "item" or entry.type == "trinket" or entry.type == "slot")
end

local function ResolveBestOwnedItemVariant(itemID)
    if not itemID then return nil end
    if Sources and Sources.QueryBestOwnedItemVariant then
        return Sources.QueryBestOwnedItemVariant(itemID) or itemID
    end
    return itemID
end

local function QueryItemUseSpellID(itemID)
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

local function ResolveItemCooldownIdentity(entry)
    if not entry then return nil, nil, nil, nil end

    local itemID, slotID
    if entry.type == "item" then
        itemID = ResolveBestOwnedItemVariant(entry.id)
    elseif entry.type == "trinket" or entry.type == "slot" then
        slotID = entry.id
        if Sources and Sources.QueryInventoryItemID then
            itemID = Sources.QueryInventoryItemID("player", slotID)
        end
        itemID = itemID or entry.itemID
    elseif entry.type == "macro" then
        local resolvedID, resolvedType = CDMResolvers.ResolveMacro(entry)
        if resolvedType == "item" then
            itemID = resolvedID
        end
    end

    if not itemID then return nil, slotID, nil, nil end

    local itemSpellID = QueryItemUseSpellID(itemID)
    local keySource = slotID and (tostring(slotID) .. ":" .. tostring(itemID)) or tostring(itemID)
    return itemID, slotID, itemSpellID, keySource
end

-- TEXTURE & MACRO RESOLVERS

-- Persistent texture cache: spellID→iconID rarely changes (only on talent
-- swap / spec change), so we keep it across ticks.  Wiped on SPELLS_CHANGED
-- and PLAYER_SPECIALIZATION_CHANGED to pick up new icons.
local _textureCycleCache = {}
do local mp = ns._memprobes or {}; ns._memprobes = mp; mp[#mp + 1] = { name = "CDM_textureCycleCache", tbl = _textureCycleCache } end
CDMResolvers._textureCycleCache = _textureCycleCache

function CDMResolvers.GetSpellTexture(spellID)
    if not spellID then return nil end
    local cached = _textureCycleCache[spellID]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local info
    if Sources and Sources.QuerySpellInfo then
        info = Sources.QuerySpellInfo(spellID)
    end
    local texID = info and info.iconID or nil
    _textureCycleCache[spellID] = texID or false
    return texID
end

---------------------------------------------------------------------------
-- MACRO RESOLUTION
-- Resolve a macro custom entry to its current spell or item via
-- #showtooltip / GetMacroSpell / GetMacroItem.  Re-evaluated every tick
-- so the icon tracks conditional changes (target, modifiers, stance).
---------------------------------------------------------------------------
function CDMResolvers.ResolveMacro(entry)
    local macroName = entry.macroName
    if not macroName then return nil, nil, nil end
    local macroIndex = GetMacroIndexByName(macroName)
    if not macroIndex or macroIndex == 0 then return nil, nil, nil end

    -- GetMacroSpell returns the spellID that #showtooltip resolves to
    local spellID = GetMacroSpell(macroIndex)
    if spellID then
        return spellID, "spell", nil
    end

    -- GetMacroItem returns itemName, itemLink for /use macros
    local itemName, itemLink = GetMacroItem(macroIndex)
    if itemLink then
        local itemID
        if Sources and Sources.QueryItemInfoInstant then
            itemID = Sources.QueryItemInfoInstant(itemLink)
        end
        if itemID then
            return itemID, "item", nil
        end
    end

    -- Fallback: macro's own icon (no resolvable cooldown)
    local _, _, macroIcon = GetMacroInfo(macroIndex)
    return nil, nil, macroIcon
end

function CDMResolvers.GetEntryTexture(entry)
    if not entry then return nil end
    if entry.type == "macro" then
        local resolvedID, resolvedType, fallbackTex = CDMResolvers.ResolveMacro(entry)
        if resolvedID then
            if resolvedType == "item" then
                local _, _, _, _, icon
                if Sources and Sources.QueryItemInfoInstant then
                    _, _, _, _, icon = Sources.QueryItemInfoInstant(resolvedID)
                end
                return icon
            else
                return CDMResolvers.GetSpellTexture(resolvedID)
            end
        end
        return fallbackTex
    end
    if entry.type == "trinket" or entry.type == "slot" then
        -- Trinket/slot entries store the equipment slot number (13/14), not the item ID.
        -- Resolve to the actual equipped item ID before looking up the icon.
        local itemID = entry.itemID
        if not itemID and Sources and Sources.QueryInventoryItemID then
            itemID = Sources.QueryInventoryItemID("player", entry.id)
        end
        if itemID then
            local _, _, _, _, icon
            if Sources and Sources.QueryItemInfoInstant then
                _, _, _, _, icon = Sources.QueryItemInfoInstant(itemID)
            end
            return icon
        end
        return nil
    end
    if entry.type == "item" then
        local _, _, _, _, icon
        if Sources and Sources.QueryItemInfoInstant then
            _, _, _, _, icon = Sources.QueryItemInfoInstant(ResolveBestOwnedItemVariant(entry.id))
        end
        return icon
    end
    return CDMResolvers.GetSpellTexture(entry.overrideSpellID or entry.id)
end

---------------------------------------------------------------------------
-- CLASSIFICATION
-- (IsSafeNumeric/SafeBoolean local helpers and GCD_MAX_DURATION are
--  declared at the top of this file so runtime query
--  functions earlier in the file can also use them.)
---------------------------------------------------------------------------

local function GetTrustedIsOnGCD(spellID)
    return RuntimeQueries and RuntimeQueries.GetTrustedIsOnGCD
        and RuntimeQueries.GetTrustedIsOnGCD(spellID)
        or nil
end

local function GetCooldownInfoBoolean(info, key)
    if not info then
        return nil
    end
    local value, isSecret = GetCooldownInfoField(info, key)
    if isSecret then
        return nil
    end
    if type(value) == "boolean" then
        return value
    end
    return nil
end

local function GetCurrentIsOnGCD(spellID, info)
    local trusted = GetTrustedIsOnGCD(spellID)
    if trusted ~= nil then
        return trusted
    end
    return GetCooldownInfoBoolean(info, "isOnGCD")
end

local function QueryGCDDurationObject(spellID)
    local durObj = nil
    if spellID then
        durObj = QueryGCDDuration(spellID)
    end
    if not durObj and spellID ~= GCD_SPELL_ID then
        durObj = QueryGCDDuration(GCD_SPELL_ID)
    end
    return durObj
end

local function QuerySpellUsableState(spellID)
    if not spellID or not (Sources and Sources.QuerySpellUsable) then
        return nil
    end
    local usable = Sources.QuerySpellUsable(spellID)
    if type(usable) ~= "boolean" then
        usable = nil
    end
    return usable
end

local function SpellMayHaveCharges(entry, spellID)
    if entry and (entry.hasCharges == true or entry.charges == true) then
        return true
    end
    if not spellID then
        return false
    end
    local gdb = QUI and QUI.db and QUI.db.global
    local svCharges = gdb and gdb.cdmChargeSpells
    return svCharges and svCharges[spellID] ~= nil or false
end

local function ClassifyMirrorDurationMode(durObjSource)
    if durObjSource == "aura-duration"
        or durObjSource == "aura-child"
        or durObjSource == "aura-child-frame"
        or durObjSource == "aura-related-child" then
        return "aura"
    end
    if durObjSource == "spell-charge"
        or durObjSource == "resource-duration" then
        return "charge"
    end
    if durObjSource == "gcd-duration" then
        return "gcd-only"
    end
    return "cooldown"
end

local function BuildMirrorDurationSourceKey(mode, sourceCooldownID, sourceSpellID, mirrorEpoch)
    if mode == "gcd-only" then
        return sourceSpellID
    end
    return "mirror:" .. tostring(sourceCooldownID) .. ":" .. tostring(mirrorEpoch)
end

local function IsSupportedMirrorMode(mode)
    return mode == "aura"
        or mode == "cooldown"
        or mode == "charge"
        or mode == "item-cooldown"
        or mode == "gcd-only"
        or mode == "inactive"
end

local function MirrorPayloadAllowsLiveChargeOverride(payload)
    if not payload then
        return false
    end
    return payload.mode == "gcd-only"
        or payload.mode == "inactive"
end

local function IsChargeSpellNotRecharging(spellID, entry)
    if InCombatLockdown and InCombatLockdown()
        and not SpellMayHaveCharges(entry, spellID) then
        return false
    end

    local ci = QueryCharges(spellID)
    if not ci then
        return false
    end
    if SafeBoolean(ci.isActive) ~= false then
        return false
    end
    local maxCharges = ci.maxCharges
    return (entry and entry.hasCharges == true)
        or (IsSafeNumeric(maxCharges) and maxCharges > 1)
end

local function ResolveLiveChargeDurationObject(spellID, entry)
    if not spellID then
        return nil, nil, nil
    end
    if InCombatLockdown and InCombatLockdown()
        and not SpellMayHaveCharges(entry, spellID) then
        return nil, nil, nil
    end

    local ci = QueryCharges(spellID)
    if not ci then
        return nil, nil, nil
    end

    local maxCharges = ci.maxCharges
    local isChargeSpell = (entry and entry.hasCharges == true)
        or (entry and entry.charges == true)
        or (IsSafeNumeric(maxCharges) and maxCharges > 1)
    if not isChargeSpell or SafeBoolean(ci.isActive) ~= true then
        return nil, nil, nil
    end

    local chargeDur = QueryChargeDuration(spellID)
    if chargeDur then
        local serial = RuntimeQueries.GetChargeDurationObjectSerial()
        return chargeDur, "charge", tostring(spellID) .. ":" .. tostring(serial)
    end

    return nil, nil, nil
end

local function GetChargeZeroCurve()
    if _chargeZeroCurve then return _chargeZeroCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateCurve)
        or not (Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step) then
        return nil
    end
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0, 1)
    curve:AddPoint(1, 0)
    _chargeZeroCurve = curve
    return curve
end

-- Decode SpellChargeInfo.currentCharges without a Lua-side compare when the
-- count is secret. The step curve maps 0 -> 1 and 1+ -> 0 C-side; once that
-- scalar is clean, the >= 0.5 comparison produces a normal Lua boolean.
local function ResolveChargeZeroState(chargeInfo, cooldownActive)
    if cooldownActive ~= true or not chargeInfo then
        return nil
    end

    local currentCharges = chargeInfo.currentCharges
    if ResolverIsSecretValue(currentCharges) then
        local curve = GetChargeZeroCurve()
        if curve and curve.Evaluate then
            local ok, value = pcall(curve.Evaluate, curve, currentCharges)
            if ok and not ResolverIsSecretValue(value) then
                local decodeOk, decoded = pcall(function()
                    if type(value) == "number" then
                        return value >= 0.5
                    end
                    return nil
                end)
                if decodeOk then
                    return decoded
                end
            end
        end
        return nil
    end

    if type(currentCharges) ~= "number" then
        return nil
    end
    return currentCharges <= 0
end

local function ShouldTreatLiveDurationAsGCD(spellID, entry, cdInfo, currentOnGCD, spellUsable)
    if currentOnGCD ~= true then
        return false
    end
    if IsChargeSpellNotRecharging(spellID, entry) then
        return true
    end
    if spellUsable == true then
        return true
    end
    local realCooldown = IsCooldownInfoRealCooldown(cdInfo)
    if realCooldown == true then
        return false
    elseif realCooldown == false then
        return true
    end
    -- State truly unknown from cdInfo. Resolved cooldown state is factual and
    -- does not consult renderer frame memory, so trust isOnGCD == true as a
    -- GCD swipe. The catalog
    -- heuristic SpellHasBaseCooldownLongerThanGCD answers "could this spell
    -- ever have a real CD," not "is it on a real CD right now," and was
    -- misclassifying GCD pulses on spells that have a base CD entry.
    return true
end

function CDMResolvers.GetSpellCastInfo(spellID)
    if not spellID or not UnitCastingInfo then return false end
    local _, _, _, startMS, endMS, _, _, _, castSpellID = UnitCastingInfo("player")
    if castSpellID and castSpellID == spellID and startMS and endMS then
        return true, startMS / 1000, (endMS - startMS) / 1000, "cast"
    end
    return false
end

function CDMResolvers.GetSpellChannelInfo(spellID)
    if not spellID or not UnitChannelInfo then return false end
    local _, _, _, startMS, endMS, _, _, channelSpellID = UnitChannelInfo("player")
    if channelSpellID and channelSpellID == spellID and startMS and endMS then
        return true, startMS / 1000, (endMS - startMS) / 1000, "channel"
    end
    return false
end

function CDMResolvers.GetSpellBuffInfo(spellID, icon, entry)
    if not spellID then return false end

    local scanner = QUI and QUI.SpellScanner
    if scanner and scanner.IsSpellActive then
        local active, expiration, duration = scanner.IsSpellActive(spellID)
        if active then
            if IsSafeNumeric(expiration) and IsSafeNumeric(duration) then
                return true, expiration - duration, duration, "buff"
            end
            return true, nil, nil, "buff"
        end
        if InCombatLockdown() then
            return false
        end
    elseif InCombatLockdown() then
        return false
    end

    if Sources and Sources.QueryPlayerAuraBySpellID then
        local auraData = Sources.QueryPlayerAuraBySpellID(spellID)
        if auraData then
            local expiration = auraData.expirationTime
            local duration = auraData.duration
            if IsSafeNumeric(expiration) and IsSafeNumeric(duration) then
                return true, expiration - duration, duration, "buff"
            end
            return true, nil, nil, "buff"
        end
    end

    if icon and icon._auraActive then
        return true, nil, nil, "buff"
    end

    return false
end

function CDMResolvers.ResolveSpellActiveState(spellID, icon, entry)
    if not spellID then return false end

    local active, start, duration, activeType = CDMResolvers.GetSpellCastInfo(spellID)
    if active then return active, start, duration, activeType end

    active, start, duration, activeType = CDMResolvers.GetSpellChannelInfo(spellID)
    if active then return active, start, duration, activeType end

    active, start, duration, activeType = CDMResolvers.GetSpellBuffInfo(spellID, icon, entry)
    if active then return active, start, duration, activeType end

    local overrideID = QueryOverrideSpell(spellID)
    if overrideID and overrideID ~= spellID then
        active, start, duration, activeType = CDMResolvers.GetSpellCastInfo(overrideID)
        if active then return active, start, duration, activeType end
        active, start, duration, activeType = CDMResolvers.GetSpellChannelInfo(overrideID)
        if active then return active, start, duration, activeType end
        active, start, duration, activeType = CDMResolvers.GetSpellBuffInfo(overrideID, icon, entry)
        if active then return active, start, duration, activeType end
    end

    return false
end

local function NewCooldownActivityState(entry)
    return {
        isOnCooldown = false,
        rechargeActive = false,
        hasChargesRemaining = false,
        -- Internal QUI metadata only; do not populate this from secret API
        -- charge predicates.
        hasCharges = entry and entry.hasCharges or false,
        gcdOnly = false,
    }
end

local function ApplyStoredCooldownActivityState(state, storedState)
    if not (state and storedState and storedState.mode) then
        return false
    end

    local mode = storedState.mode
    state.gcdOnly = storedState.gcdOnly == true or mode == "gcd-only"
    if storedState.hasCharges ~= nil then
        state.hasCharges = storedState.hasCharges == true
    end
    if mode == "charge" then
        state.hasCharges = true
    end

    if storedState.isOnCooldown ~= nil
       or storedState.rechargeActive ~= nil
       or storedState.hasChargesRemaining ~= nil then
        state.isOnCooldown = storedState.isOnCooldown == true
        state.rechargeActive = storedState.rechargeActive == true
        state.hasChargesRemaining = storedState.hasChargesRemaining == true
        return true
    end

    if mode == "charge" then
        state.rechargeActive = storedState.durObj ~= nil or storedState.active == true
        state.isOnCooldown = storedState.active == true
        state.hasChargesRemaining = state.rechargeActive == true
            and state.isOnCooldown ~= true
        return true
    elseif mode == "cooldown" or mode == "item-cooldown" then
        state.isOnCooldown = storedState.active == true
        return true
    elseif mode == "gcd-only" or mode == "aura" or mode == "inactive" then
        return true
    end

    return false
end

local function ResolveActivityRuntimeSpellID(icon, entry)
    if icon and icon._runtimeSpellID then
        return icon._runtimeSpellID
    end
    if not entry then return nil, nil end

    if entry.type == "macro" then
        local resolvedID, resolvedType = CDMResolvers.ResolveMacro(entry)
        if resolvedType == "spell" then
            return resolvedID, resolvedType
        end
        return nil, resolvedType
    end

    return entry.spellID or entry.overrideSpellID or entry.id, nil
end

local function MarkKnownChargeSpell(state, spellID)
    if not (state and spellID) or state.hasCharges then return end
    local gdb = QUI and QUI.db and QUI.db.global
    local svCharges = gdb and gdb.cdmChargeSpells
    if svCharges and svCharges[spellID] then
        state.hasCharges = true
    end
end

local function ApplyResolvedCooldownActivityState(state, resolvedState)
    if not (state and resolvedState and resolvedState.mode) then
        return false
    end

    local mode = resolvedState.mode
    state.gcdOnly = resolvedState.gcdOnly == true or mode == "gcd-only"
    state.hasCharges = resolvedState.hasCharges == true
        or state.hasCharges == true
        or mode == "charge"

    if resolvedState.isOnCooldown ~= nil
        or resolvedState.rechargeActive ~= nil
        or resolvedState.hasChargesRemaining ~= nil then
        state.isOnCooldown = resolvedState.isOnCooldown == true
        state.rechargeActive = resolvedState.rechargeActive == true
        state.hasChargesRemaining = resolvedState.hasChargesRemaining == true
        return true
    elseif mode == "cooldown" or mode == "item-cooldown" then
        state.isOnCooldown = resolvedState.active == true
        return true
    elseif mode == "charge" then
        state.rechargeActive = resolvedState.durObj ~= nil
            or resolvedState.active == true
            or resolvedState.isActive == true
        state.isOnCooldown = resolvedState.active == true
        state.hasChargesRemaining = state.rechargeActive == true
            and state.isOnCooldown ~= true
        return true
    elseif mode == "gcd-only" or mode == "aura" or mode == "inactive" then
        return true
    end

    return false
end

function CDMResolvers.ResolveCooldownActivityStateFromResolvedState(entry, resolvedState)
    local state = NewCooldownActivityState(entry)
    if ApplyResolvedCooldownActivityState(state, resolvedState) then
        return state
    end
    return nil
end

local _activityCooldownStateContextOptions = {
    contextKey = "_activityCooldownStateContext",
    mirrorIdentityPolicy = "frame-or-entry",
}

local function BuildActivityCooldownStateContext(icon, entry, containerDB, spellID, runtimeOptions)
    if not (icon and entry) then return nil end

    local options = _activityCooldownStateContextOptions
    options.containerKey = (containerDB and containerDB.viewerType) or entry.viewerType
    options.totemSlot = icon._totemSlot
    options.useBuffSwipe = runtimeOptions and runtimeOptions.useBuffSwipe
    options.skipAuraPhase = runtimeOptions and runtimeOptions.skipAuraPhase == true
    options.showGCDSwipe = runtimeOptions and runtimeOptions.showGCDSwipe == true

    return CDMResolvers.BuildCooldownStateContext(icon, entry, spellID, options)
end

local function ApplyChargeRuntimeFallback(state, entry, spellID, isItemLike)
    if not (state and spellID) or isItemLike then
        return
    end
    if InCombatLockdown and InCombatLockdown()
        and not SpellMayHaveCharges(entry, spellID) then
        return
    end

    local ci = QueryCharges(spellID)
    if ci then
        local maxC = ci.maxCharges
        if IsSafeNumeric(maxC) and maxC > 1 then
            state.hasCharges = true
        end
    end

    if not state.hasCharges then
        return
    end

    local cdInfo = QueryCooldown(spellID)
    local cooldownActive = cdInfo and IsCooldownInfoActive(cdInfo)
    if cooldownActive == true then
        state.rechargeActive = true
        state.isOnCooldown = true
        return
    elseif cooldownActive == false then
        -- Do not use SpellChargeInfo.currentCharges here. The charge info
        -- payload can be restricted in combat; a readable "spell cooldown is
        -- inactive" signal is enough to know the charged spell is not fully
        -- locked out.
        state.hasChargesRemaining = true
        state.isOnCooldown = false
    end

    if ci then
        local chargeActive = SafeBoolean(ci.isActive)
        if chargeActive == true then
            state.rechargeActive = true
        end
    end
end

function CDMResolvers.ResolveCooldownActivityState(icon, entry, containerDB, now, runtimeOptions)
    local state = NewCooldownActivityState(entry)
    if not icon or not entry then return state end

    now = now or GetTime()
    local runtimeStore = ns.CDMRuntimeStore
    local storedState = runtimeStore and runtimeStore.GetFrameState
        and runtimeStore.GetFrameState(icon)
    if ApplyStoredCooldownActivityState(state, storedState) then
        return state
    end

    local spellID, macroResolvedType = ResolveActivityRuntimeSpellID(icon, entry)
    local isItemLike = IsItemLikeEntry(entry)
        or (entry.type == "macro" and macroResolvedType == "item")

    MarkKnownChargeSpell(state, spellID)

    local resolver = CDMResolvers.ResolveCooldownState
    if resolver then
        local resolvedState = resolver(BuildActivityCooldownStateContext(icon, entry, containerDB, spellID, runtimeOptions))
        if ApplyResolvedCooldownActivityState(state, resolvedState) then
            return state
        end
    end

    ApplyChargeRuntimeFallback(state, entry, spellID, isItemLike)

    if state.hasCharges then
        return state
    end

    return state
end


-- DURATION OBJECT RESOLVERS

function CDMResolvers.IsAuraEntry(entry)
    if not entry then return false end
    local CDMSpellData = ns.CDMSpellData
    if CDMSpellData and CDMSpellData.IsAuraEntry then
        return CDMSpellData.IsAuraEntry(entry, entry.viewerType)
    end
    -- Bootstrap fallback (CDMSpellData not yet loaded)
    if entry.kind == "aura" then return true end
    if entry.kind == "cooldown" then return false end
    local vt = entry.viewerType
    return vt == "buff" or vt == "trackedBar"
end

function CDMResolvers.ResolveAuraActiveState(entry)
    if not entry then return false, nil, nil end

    local sid = entry.overrideSpellID or entry.spellID or entry.id
    if not sid then
        return false, nil, nil
    end

    -- Captured UNIT_AURA payloads are combat-safe and include aura IDs that
    -- differ from the configured cast/ability ID.
    local CDMSpellData = ns.CDMSpellData
    if CDMSpellData and CDMSpellData.GetCapturedAuraForLookup then
        local lookupIDs = {}
        local seenLookup = {}
        local function addLookup(id)
            if not id or seenLookup[id] then return end
            seenLookup[id] = true
            lookupIDs[#lookupIDs + 1] = id
        end
        local function addMappedLookups(id)
            if not (id and CDMSpellData.GetAuraIDsForSpell) then return end
            local mappedIDs = CDMSpellData:GetAuraIDsForSpell(id)
            if mappedIDs then
                for _, auraID in ipairs(mappedIDs) do addLookup(auraID) end
            end
        end
        addLookup(sid)
        addLookup(entry.spellID)
        addLookup(entry.id)
        addMappedLookups(sid)
        addMappedLookups(entry.spellID)
        addMappedLookups(entry.id)
        local captured = CDMSpellData.GetCapturedAuraForLookup(lookupIDs, entry.name)
        local auraInstanceID = captured and captured.auraInstanceID
        if captured and HasOpaqueValue(auraInstanceID) then
            return true, captured.unit or "player", auraInstanceID
        end
    end

    -- Direct aura query fallback. If the query returns AuraData, existence is
    -- enough to classify the aura as active; auraInstanceID is forwarded to
    -- downstream C-side consumers.
    if Sources and (Sources.QueryUnitAuraBySpellID or Sources.QueryPlayerAuraBySpellID) then
        local seen = {}
        local function tryQuery(id)
            if not id or seen[id] then return nil end
            seen[id] = true
            if Sources.QueryUnitAuraBySpellID then
                local auraData = Sources.QueryUnitAuraBySpellID("player", id)
                if auraData then return auraData end
            end
            if Sources.QueryPlayerAuraBySpellID then
                local auraData = Sources.QueryPlayerAuraBySpellID(id)
                if auraData then return auraData end
            end
            return nil
        end

        local auraData = tryQuery(sid)
        if auraData then return true, "player", GetAuraDataInstanceID(auraData) end
        auraData = tryQuery(entry.spellID)
        if auraData then return true, "player", GetAuraDataInstanceID(auraData) end
        auraData = tryQuery(entry.id)
        if auraData then return true, "player", GetAuraDataInstanceID(auraData) end

        if CDMSpellData and CDMSpellData.GetAuraIDsForSpell then
            local function tryMappedIDs(id)
                if not id then return false end
                local mappedIDs = CDMSpellData:GetAuraIDsForSpell(id)
                if mappedIDs then
                    for _, auraID in ipairs(mappedIDs) do
                        local mappedAuraData = tryQuery(auraID)
                        if mappedAuraData then
                            return true, "player", GetAuraDataInstanceID(mappedAuraData)
                        end
                    end
                end
                return false
            end
            local active, unit, instID = tryMappedIDs(sid)
            if active then return active, unit, instID end
            active, unit, instID = tryMappedIDs(entry.spellID)
            if active then return active, unit, instID end
            active, unit, instID = tryMappedIDs(entry.id)
            if active then return active, unit, instID end
        end
    end

    -- Name fallback for cast-id vs aura-id mismatches that share names and
    -- are not in the CDM catalog.
    if entry.name and entry.name ~= ""
        and Sources and Sources.QueryAuraDataBySpellName then
        local auraData = Sources.QueryAuraDataBySpellName("player", entry.name, "HELPFUL")
        if auraData then
            return true, "player", GetAuraDataInstanceID(auraData)
        end
    end

    return false, nil, nil
end

local PLAYER_AURA_CAPTURE_LOOKUP_UNITS = { "player", "pet" }

local function QueryCapturedPlayerAuraDuration(spellID, name)
    if not InCombatLockdown()
       or not (Sources and Sources.QueryAuraDuration) then
        return nil
    end

    local CDMSpellData = ns.CDMSpellData
    if not (CDMSpellData and CDMSpellData.GetCapturedAuraForLookup) then
        return nil
    end

    local lookupIDs = {}
    local seen = {}
    local function addLookup(id)
        if ResolverIsSecretValue(id) then return end
        if id == nil then return end
        local idType = type(id)
        if idType ~= "number" and idType ~= "string" then return end
        if seen[id] then return end
        seen[id] = true
        lookupIDs[#lookupIDs + 1] = id
    end
    local function addCooldownAuraLookup(id)
        if ResolverIsSecretValue(id) or id == nil then return end
        if not (Sources and Sources.QueryCooldownAuraBySpellID) then return end
        addLookup(Sources.QueryCooldownAuraBySpellID(id))
    end

    if CDMSpellData.GetAuraIDsForSpell and spellID then
        local catalogIDs = CDMSpellData:GetAuraIDsForSpell(spellID)
        if catalogIDs then
            for _, auraID in ipairs(catalogIDs) do
                addLookup(auraID)
            end
        end
    end
    addCooldownAuraLookup(spellID)
    addLookup(spellID)

    local captured = CDMSpellData.GetCapturedAuraForLookup(
        lookupIDs, name, PLAYER_AURA_CAPTURE_LOOKUP_UNITS, false)
    local auraInstanceID = captured and captured.auraInstanceID
    if not HasOpaqueValue(auraInstanceID) then
        return nil
    end

    return Sources.QueryAuraDuration(captured.unit or "player", auraInstanceID),
        captured.spellID
end

local function QueryPlayerAuraDurationBySpellID(rawSpellID, name)
    if not rawSpellID or not (Sources and Sources.QueryAuraDuration) then
        return nil
    end

    local capturedDurObj, capturedAuraSpellID = QueryCapturedPlayerAuraDuration(rawSpellID, name)
    if capturedDurObj then
        return capturedDurObj, capturedAuraSpellID
    end

    local function queryAuraData(auraSpellID)
        if ResolverIsSecretValue(auraSpellID) or auraSpellID == nil then return nil end
        if Sources.QueryUnitAuraBySpellID then
            local auraData = Sources.QueryUnitAuraBySpellID("player", auraSpellID)
            if auraData then return auraData end
        end
        if Sources.QueryPlayerAuraBySpellID then
            local auraData = Sources.QueryPlayerAuraBySpellID(auraSpellID)
            if auraData then return auraData end
        end
        if Sources.QueryAuraDataBySpellID then
            local auraData = Sources.QueryAuraDataBySpellID("player", auraSpellID, "HELPFUL")
            if auraData then return auraData end
        end
        return nil
    end

    local function queryDuration(auraSpellID)
        local auraData = queryAuraData(auraSpellID)
        local auraInstanceID = GetAuraDataInstanceID(auraData)
        if not HasOpaqueValue(auraInstanceID) then return nil end

        return Sources.QueryAuraDuration("player", auraInstanceID), auraSpellID
    end

    if Sources.QueryCooldownAuraBySpellID then
        local auraSpellID = Sources.QueryCooldownAuraBySpellID(rawSpellID)
        if not ResolverIsSecretValue(auraSpellID) and auraSpellID ~= nil then
            local durObj = queryDuration(auraSpellID)
            if durObj then
                return durObj, auraSpellID
            end
        end
    end

    return queryDuration(rawSpellID)
end

local function QueryPlayerAuraDurationByName(name)
    if type(name) ~= "string"
       or name == ""
       or not (Sources and Sources.QueryAuraDuration) then
        return nil
    end

    local capturedDurObj = QueryCapturedPlayerAuraDuration(nil, name)
    if capturedDurObj then
        return capturedDurObj
    end

    if not Sources.QueryAuraDataBySpellName then
        return nil
    end

    local auraData = Sources.QueryAuraDataBySpellName("player", name, "HELPFUL")
    if not auraData then
        return nil
    end

    local auraInstanceID = GetAuraDataInstanceID(auraData)
    if not HasOpaqueValue(auraInstanceID) then return nil end

    return Sources.QueryAuraDuration("player", auraInstanceID)
end

local function IsUsableMirrorID(value)
    if ResolverIsSecretValue(value) then return false end
    return type(value) == "number" and value > 0
end

local function NormalizeMirrorCategory(category)
    if Shared and Shared.NormalizeMirrorCategory then
        return Shared.NormalizeMirrorCategory(category)
    end
    if ResolverIsSecretValue(category) or type(category) ~= "string" then
        return nil
    end
    if category == "essential" or category == "utility"
        or category == "buff" or category == "trackedBar" then return category end
    return nil
end

local function IsAuraMirrorCategory(category)
    if Shared and Shared.IsAuraMirrorCategory then
        return Shared.IsAuraMirrorCategory(category)
    end
    category = NormalizeMirrorCategory(category)
    return category == "buff" or category == "trackedBar"
end

local function IsCooldownMirrorCategory(category)
    if Shared and Shared.IsCooldownMirrorCategory then
        return Shared.IsCooldownMirrorCategory(category)
    end
    category = NormalizeMirrorCategory(category)
    return category == "essential" or category == "utility"
end

local function ResolveEntryMirrorCategory(entry)
    if not entry then return nil end
    return NormalizeMirrorCategory(entry.blizzardMirrorCategory)
        or NormalizeMirrorCategory(entry.viewerCategory)
        or NormalizeMirrorCategory(entry.viewerType)
end

local function SafeEntryField(entry, key)
    local value = entry and entry[key]
    if ResolverIsSecretValue(value) then return nil end
    return value
end

local function AddMirrorIdentityID(set, id)
    if not IsUsableMirrorID(id) then return end
    set[id] = true
end

local function AddEntryMirrorIdentityID(set, id)
    if not IsUsableMirrorID(id) then return end
    set[id] = true
    local overrideID = QueryOverrideSpell(id)
    if overrideID ~= id then
        AddMirrorIdentityID(set, overrideID)
    end
end

local _mirrorEntryIdentityScratch = {}

local function ClearMirrorEntryIdentityScratch()
    for id in pairs(_mirrorEntryIdentityScratch) do
        _mirrorEntryIdentityScratch[id] = nil
    end
end

local function MirrorStateHasSpellIdentity(state)
    if not state then return false end
    if IsUsableMirrorID(state.overrideTooltipSpellID)
        or IsUsableMirrorID(state.overrideSpellID)
        or IsUsableMirrorID(state.spellID) then
        return true
    end
    local linkedStateIDs = state.linkedSpellIDs
    if type(linkedStateIDs) == "table" then
        for _, linkedID in ipairs(linkedStateIDs) do
            if IsUsableMirrorID(linkedID) then return true end
        end
    end
    return false
end

local function MirrorStateMatchesEntryIdentity(state, entry)
    if not (state and entry) then return true end
    if not MirrorStateHasSpellIdentity(state) then return true end

    local entryIDs = _mirrorEntryIdentityScratch
    ClearMirrorEntryIdentityScratch()
    AddEntryMirrorIdentityID(entryIDs, SafeEntryField(entry, "overrideSpellID"))
    AddEntryMirrorIdentityID(entryIDs, SafeEntryField(entry, "spellID"))
    AddEntryMirrorIdentityID(entryIDs, SafeEntryField(entry, "id"))

    local hasEntryIdentity = false
    for _ in pairs(entryIDs) do
        hasEntryIdentity = true
        break
    end
    if not hasEntryIdentity then return true end

    local sawStateIdentity = false

    local id = state.overrideTooltipSpellID
    if IsUsableMirrorID(id) then
        sawStateIdentity = true
        if entryIDs[id] == true then return true end
    end

    id = state.overrideSpellID
    if IsUsableMirrorID(id) then
        sawStateIdentity = true
        if entryIDs[id] == true then return true end
    end

    id = state.spellID
    if IsUsableMirrorID(id) then
        sawStateIdentity = true
        if entryIDs[id] == true then return true end
    end

    local linkedStateIDs = state.linkedSpellIDs
    if type(linkedStateIDs) == "table" then
        for _, linkedID in ipairs(linkedStateIDs) do
            if IsUsableMirrorID(linkedID) then
                sawStateIdentity = true
                if entryIDs[linkedID] == true then return true end
            end
        end
    end

    return not sawStateIdentity
end

local function MirrorBindingIsStrictAura(entry, entryType, viewerCategory)
    if not entry then return false end
    local entryKind = SafeEntryField(entry, "kind")
    local normalizedEntryType = entryType or SafeEntryField(entry, "type")
    local entryIsAura = SafeEntryField(entry, "isAura")
    return entryKind == "aura"
        or normalizedEntryType == "aura"
        or entryIsAura == true
        or IsAuraMirrorCategory(viewerCategory)
end

local function GetMirrorCategoryCandidates(viewerCategory, strictAuraBinding)
    if viewerCategory == "essential" then
        return "essential", "utility"
    elseif viewerCategory == "utility" then
        return "utility", "essential"
    elseif viewerCategory == "buff" then
        return "buff", "trackedBar"
    elseif viewerCategory == "trackedBar" then
        return "trackedBar", "buff"
    elseif strictAuraBinding then
        return "buff", "trackedBar"
    else
        return "essential", "utility"
    end
end

local function MirrorCategoryMatchesEntry(actualCategory, viewerCategory, strictAuraBinding)
    actualCategory = NormalizeMirrorCategory(actualCategory)
    if not actualCategory then return false end
    if IsCooldownMirrorCategory(viewerCategory) then
        return IsCooldownMirrorCategory(actualCategory)
    end
    if IsAuraMirrorCategory(viewerCategory) then
        return IsAuraMirrorCategory(actualCategory)
    end
    if strictAuraBinding then
        return IsAuraMirrorCategory(actualCategory)
    end
    return IsCooldownMirrorCategory(actualCategory)
end

local function MirrorIdentityStateAccepted(mirror, cooldownID, category, viewerCategory, strictAuraBinding)
    local state
    if mirror.GetStateByCooldownID then
        state = mirror.GetStateByCooldownID(cooldownID, category)
        if not state then return nil, nil end
    end

    local actualCategory = NormalizeMirrorCategory(state and state.viewerCategory) or category
    if not MirrorCategoryMatchesEntry(actualCategory, viewerCategory, strictAuraBinding) then
        return nil, nil
    end

    if mirror.HasChildForCooldownID
        and not mirror.HasChildForCooldownID(cooldownID, actualCategory) then
        return nil, nil
    end

    return actualCategory, state
end

local function ExplicitMirrorIdentityStateAccepted(
    mirror, entry, cooldownID, category, viewerCategory, strictAuraBinding)
    local acceptedCategory, state = MirrorIdentityStateAccepted(
        mirror, cooldownID, category, viewerCategory, strictAuraBinding)
    if not acceptedCategory then
        return nil, nil
    end
    if not MirrorStateMatchesEntryIdentity(state, entry) then
        return nil, nil
    end
    return acceptedCategory, state
end

local function ResolveMirrorIDInCategory(mirror, id, category, viewerCategory, strictAuraBinding)
    if not IsUsableMirrorID(id) then return nil, nil, nil end

    local cooldownID
    if strictAuraBinding and IsAuraMirrorCategory(category) then
        if not mirror.GetDirectCooldownIDForViewer then return nil, nil, nil end
        cooldownID = mirror.GetDirectCooldownIDForViewer(id, category)
    else
        if not mirror.GetCooldownIDForViewer then return nil, nil, nil end
        cooldownID = mirror.GetCooldownIDForViewer(id, category)
    end

    if not IsUsableMirrorID(cooldownID) then return nil, nil, nil end

    local acceptedCategory, state = MirrorIdentityStateAccepted(
        mirror, cooldownID, category, viewerCategory, strictAuraBinding)
    if acceptedCategory then
        return cooldownID, acceptedCategory, state
    end

    return nil, nil, nil
end

local function ResolveMirrorIDAndOverrideInCategory(mirror, id, category, viewerCategory, strictAuraBinding)
    local cooldownID, acceptedCategory, state = ResolveMirrorIDInCategory(
        mirror, id, category, viewerCategory, strictAuraBinding)
    if cooldownID then
        return cooldownID, acceptedCategory, state
    end

    if not IsUsableMirrorID(id) then return nil, nil, nil end
    local overrideID = QueryOverrideSpell(id)
    if overrideID == id then return nil, nil, nil end

    return ResolveMirrorIDInCategory(
        mirror, overrideID, category, viewerCategory, strictAuraBinding)
end

local function ResolveMirrorEntryInCategory(mirror, entry, category, viewerCategory, strictAuraBinding)
    local cooldownID, acceptedCategory, state = ResolveMirrorIDAndOverrideInCategory(
        mirror, entry.overrideSpellID, category, viewerCategory, strictAuraBinding)
    if cooldownID then
        return cooldownID, acceptedCategory, state
    end

    cooldownID, acceptedCategory, state = ResolveMirrorIDAndOverrideInCategory(
        mirror, entry.spellID, category, viewerCategory, strictAuraBinding)
    if cooldownID then
        return cooldownID, acceptedCategory, state
    end

    cooldownID, acceptedCategory, state = ResolveMirrorIDAndOverrideInCategory(
        mirror, entry.id, category, viewerCategory, strictAuraBinding)
    if cooldownID then
        return cooldownID, acceptedCategory, state
    end

    if not strictAuraBinding and type(entry.linkedSpellIDs) == "table" then
        for _, linkedID in ipairs(entry.linkedSpellIDs) do
            cooldownID, acceptedCategory, state = ResolveMirrorIDAndOverrideInCategory(
                mirror, linkedID, category, viewerCategory, strictAuraBinding)
            if cooldownID then
                return cooldownID, acceptedCategory, state
            end
        end
    end

    return nil, nil, nil
end

-- Singleton identity result for the resolver hot path. Callers MUST consume
-- this immediately; the next mirror identity resolution reuses the table.
local _mirrorIdentityScratch = {
    cooldownID = nil,
    category = nil,
    state = nil,
    viewerCategory = nil,
    strictAuraBinding = false,
    source = nil,
    entryType = nil,
}

local function WipeMirrorIdentityScratch()
    local identity = _mirrorIdentityScratch
    identity.cooldownID = nil
    identity.category = nil
    identity.state = nil
    identity.viewerCategory = nil
    identity.strictAuraBinding = false
    identity.source = nil
    identity.entryType = nil
end

local function StoreMirrorIdentity(
    cooldownID, category, state, viewerCategory, strictAuraBinding, source, entryType)
    local identity = _mirrorIdentityScratch
    identity.cooldownID = cooldownID
    identity.category = category
    identity.state = state
    identity.viewerCategory = viewerCategory
    identity.strictAuraBinding = strictAuraBinding == true
    identity.source = source
    identity.entryType = entryType
    return identity
end

local function ResolveExplicitMirrorIdentityState(
    mirror, entry, cooldownID, category, viewerCategory, strictAuraBinding, source, entryType)
    if not (IsUsableMirrorID(cooldownID) and mirror.GetStateByCooldownID) then
        return nil
    end

    local acceptedCategory, state = ExplicitMirrorIdentityStateAccepted(
        mirror, entry, cooldownID, category, viewerCategory, strictAuraBinding)
    if not acceptedCategory then
        return nil
    end

    return StoreMirrorIdentity(
        cooldownID, acceptedCategory, state,
        viewerCategory, strictAuraBinding, source, entryType)
end

local function ValidateMirrorIdentityEntry(entry, mirror)
    if not (entry and mirror) then return false, nil, nil, nil end

    local entryType = SafeEntryField(entry, "type")
    if entryType
        and entryType ~= "spell"
        and entryType ~= "aura"
        and entryType ~= "cooldown" then
        return false, nil, nil, nil
    end

    local viewerCategory = ResolveEntryMirrorCategory(entry)
    local strictAuraBinding = MirrorBindingIsStrictAura(entry, entryType, viewerCategory)
    return true, entryType, viewerCategory, strictAuraBinding
end

local function ResolveBlizzardMirrorIdentityState(entry)
    WipeMirrorIdentityScratch()

    local mirror = ns.CDMBlizzMirror
    local valid, entryType, viewerCategory, strictAuraBinding =
        ValidateMirrorIdentityEntry(entry, mirror)
    if not valid then
        return nil
    end

    local category1, category2 = GetMirrorCategoryCandidates(viewerCategory, strictAuraBinding)

    local explicitCooldownID = entry.cooldownID
    local identity = ResolveExplicitMirrorIdentityState(
        mirror, entry, explicitCooldownID, category1,
        viewerCategory, strictAuraBinding, "entry-cooldownID", entryType)
    if identity then
        return identity
    end

    if category2 then
        identity = ResolveExplicitMirrorIdentityState(
            mirror, entry, explicitCooldownID, category2,
            viewerCategory, strictAuraBinding, "entry-cooldownID", entryType)
        if identity then
            return identity
        end
    end

    local cooldownID, acceptedCategory, state = ResolveMirrorEntryInCategory(
        mirror, entry, category1, viewerCategory, strictAuraBinding)
    if cooldownID then
        return StoreMirrorIdentity(
            cooldownID, acceptedCategory, state,
            viewerCategory, strictAuraBinding, "entry", entryType)
    end

    if category2 then
        cooldownID, acceptedCategory, state = ResolveMirrorEntryInCategory(
            mirror, entry, category2, viewerCategory, strictAuraBinding)
        if cooldownID then
            return StoreMirrorIdentity(
                cooldownID, acceptedCategory, state,
                viewerCategory, strictAuraBinding, "entry", entryType)
        end
    end

    return nil
end

function CDMResolvers.ResolveBlizzardMirrorIdentityState(entry)
    return ResolveBlizzardMirrorIdentityState(entry)
end

local function ResolveCooldownContextMirror(owner, entry, options)
    local policy = options and options.mirrorIdentityPolicy or "frame-or-entry"
    local cooldownID
    local category

    if policy ~= "entry" and policy ~= "entry-or-fallback" then
        cooldownID = options and options.mirrorCooldownID
        category = options and options.mirrorCategory
        if cooldownID == nil and owner then
            cooldownID = owner._blizzMirrorCooldownID
            category = owner._blizzMirrorCategory
        end
    end

    if policy ~= "frame-only"
        and (cooldownID == nil or policy == "entry" or policy == "entry-or-fallback") then
        local identity = ResolveBlizzardMirrorIdentityState(entry)
        if identity and identity.cooldownID ~= nil then
            return identity.cooldownID, identity.category
        end
    end

    if cooldownID == nil and policy == "entry-or-fallback" and entry then
        cooldownID = entry.cooldownID
        category = ResolveEntryMirrorCategory(entry)
    end

    return cooldownID, category
end

local function ClearCooldownStateContext(context)
    context.entry = nil
    context.runtimeSpellID = nil
    context.mirrorCooldownID = nil
    context.mirrorCategory = nil
    context.containerKey = nil
    context.totemSlot = nil
    context.useBuffSwipe = nil
    context.skipAuraPhase = nil
    context.showGCDSwipe = nil
    context.priorCooldownActive = nil
    context.priorRealCooldownActive = nil
    context.priorShowingRealCooldownSwipe = nil
    context.priorResolvedCooldownMode = nil
    context.preservedRealDurObj = nil
    context.preservedRealMode = nil
    context.preservedRealSourceID = nil
    context.lastChargeMirrorCooldownID = nil
    context.lastChargeMirrorCategory = nil
    context.lastChargeRuntimeSpellID = nil
end

function CDMResolvers.BuildCooldownStateContext(owner, entry, runtimeSpellID, options)
    local context = options and options.context
    local contextKey = options and options.contextKey or "_cooldownStateContext"
    if not context and owner then
        context = owner[contextKey]
        if not context then
            context = {}
            owner[contextKey] = context
        end
    end
    if not context then
        context = {}
    end

    ClearCooldownStateContext(context)

    local containerKey = options and options.containerKey
    if containerKey == nil then
        containerKey = entry and entry.viewerType
    end
    if containerKey == nil and options then
        containerKey = options.fallbackContainerKey
    end

    local totemSlot = options and options.totemSlot
    if totemSlot == nil and owner then
        totemSlot = owner._totemSlot
    end

    local mirrorCooldownID, mirrorCategory = ResolveCooldownContextMirror(owner, entry, options)

    context.entry = entry
    context.runtimeSpellID = runtimeSpellID
    context.mirrorCooldownID = mirrorCooldownID
    context.mirrorCategory = mirrorCategory
    context.containerKey = containerKey
    context.totemSlot = totemSlot
    context.useBuffSwipe = options and options.useBuffSwipe
    context.skipAuraPhase = options and options.skipAuraPhase == true
    context.showGCDSwipe = options and options.showGCDSwipe == true
    context.priorCooldownActive = options and options.priorCooldownActive == true
    context.priorRealCooldownActive = options and options.priorRealCooldownActive == true
    context.priorShowingRealCooldownSwipe = options and options.priorShowingRealCooldownSwipe == true
    context.priorResolvedCooldownMode = options and options.priorResolvedCooldownMode
    context.preservedRealDurObj = options and options.preservedRealDurObj
    context.preservedRealMode = options and options.preservedRealMode
    context.preservedRealSourceID = options and options.preservedRealSourceID
    context.lastChargeMirrorCooldownID = options and options.lastChargeMirrorCooldownID
    context.lastChargeMirrorCategory = options and options.lastChargeMirrorCategory
    context.lastChargeRuntimeSpellID = options and options.lastChargeRuntimeSpellID
    return context
end

local function SafeMirrorString(value)
    if ResolverIsSecretValue(value) or type(value) ~= "string" then
        return nil
    end
    return value
end

local function SafeMirrorCountNumber(value)
    if ResolverIsSecretValue(value) or value == nil then
        return nil
    end
    local valueType = type(value)
    if valueType == "number" then
        return value
    end
    if valueType == "string" then
        return tonumber(value)
    end
    return nil
end

-- Singleton scratch tables for mirror payload generation. Both the runtime aura
-- resolver's closure-heavy churn and BuildMirrorRenderPayload's
-- fresh-table-per-call pattern dominated combat GC. The aura resolver was fixed
-- in 2026-05-11; this scratch pair fixes the mirror payload side.
--
-- Callers MUST treat these as consume-immediately. The resolved cooldown
-- state copies count fields into its own scratch table so renderers do not
-- retain this singleton.
local _mirrorPayloadScratch = {
    mirrorBacked = true,
    state = nil, active = false, mode = nil, sourceID = nil,
    cooldownID = nil, category = nil, spellID = nil, auraInstanceID = nil,
    durObj = nil, durationStateUnknown = nil, auraUnit = nil,
    auraData = nil,
    totemSlot = nil, totemName = nil, totemIcon = nil, isTotemInstance = false,
    count = nil, hasExpirationTime = nil, hideDurationText = nil,
}
local _mirrorCountScratch = {
    value = nil, sinkText = nil, shown = false, source = nil,
}

local function WipeMirrorPayloadScratch()
    local p = _mirrorPayloadScratch
    p.state = nil; p.active = false; p.mode = nil; p.sourceID = nil
    p.cooldownID = nil; p.category = nil; p.spellID = nil; p.auraInstanceID = nil
    p.durObj = nil; p.durationStateUnknown = nil; p.auraUnit = nil
    p.auraData = nil
    p.totemSlot = nil; p.totemName = nil; p.totemIcon = nil
    p.isTotemInstance = false
    p.count = nil
    p.hasExpirationTime = nil; p.hideDurationText = nil
end

local function BuildMirrorCountPayload(m)
    if not m then return nil end
    local c = _mirrorCountScratch
    c.value = nil; c.sinkText = nil; c.shown = false; c.source = nil

    local shown = SafeBoolean(m.stackTextShown)
    local source = SafeMirrorString(m.stackTextSource) or "mirror-text"
    if shown == false then
        c.shown = false
        c.source = source
        return c
    end

    local stackText = m.stackText
    if ResolverIsSecretValue(stackText) or stackText ~= nil then
        c.value = SafeMirrorCountNumber(stackText)
        c.sinkText = stackText
        c.shown = true
        c.source = source
        return c
    end

    return nil
end

local function ResolveMirrorPayloadMode(m, active)
    if active ~= true then
        return "inactive"
    end

    local mode = SafeMirrorString(m and m.resolvedMode)
    if not IsSupportedMirrorMode(mode) or mode == "inactive" then
        mode = ClassifyMirrorDurationMode(m and m.durObjSource)
    end
    if not IsSupportedMirrorMode(mode) or mode == "inactive" then
        mode = "cooldown"
    end
    return mode
end

local function ResolveMirrorAuraData(m, auraUnit, active, mode)
    if not active or mode ~= "aura" then return nil end
    if m and type(m.auraData) == "table" then
        return m.auraData
    end
    if not (m and HasOpaqueValue(m.auraInstanceID) and auraUnit
        and Sources and Sources.QueryAuraDataByAuraInstanceID) then
        return nil
    end
    return Sources.QueryAuraDataByAuraInstanceID(auraUnit, m.auraInstanceID)
end

local function IsOwnedMirrorAuraData(auraData)
    return auraData
        and Helpers
        and Helpers.IsAuraOwnedByPlayerOrPet
        and Helpers.IsAuraOwnedByPlayerOrPet(auraData, true) == true
end

local function ResolveOwnedTargetMirrorAuraData(m, auraUnit, auraData)
    if IsOwnedMirrorAuraData(auraData) then
        return auraData
    end
    if not (m and HasOpaqueValue(m.auraInstanceID)
        and auraUnit == "target"
        and Sources and Sources.QueryAuraDataByAuraInstanceID) then
        return nil
    end

    local queried = Sources.QueryAuraDataByAuraInstanceID(auraUnit, m.auraInstanceID)
    if IsOwnedMirrorAuraData(queried) then
        return queried
    end
    return nil
end

local function BuildMirrorRenderPayload(
    m, fallbackCooldownID, fallbackCategory, fallbackSpellID,
    overrideDurObj, overrideSource, overrideMode, overrideUnknown)
    if not m then return nil end

    local payloadDurObj = overrideDurObj or m.durObj
    local active = SafeBoolean(m.isActive)
    if active == nil and payloadDurObj then
        active = true
    end
    active = active == true

    local sourceCooldownID = m.cooldownID or fallbackCooldownID or fallbackSpellID
    local sourceSpellID = m.overrideSpellID or m.spellID or fallbackSpellID
    local mode = overrideMode or ResolveMirrorPayloadMode(m, active)
    local selfAura = SafeBoolean(m.selfAura)
    local auraUnit = SafeMirrorString(m.auraUnit)
        or ((selfAura == false) and "target" or "player")
    local auraInstanceID = m.auraInstanceID
    local auraData = ResolveMirrorAuraData(m, auraUnit, active, mode)

    if active and mode == "aura" and auraUnit == "target" then
        auraData = ResolveOwnedTargetMirrorAuraData(m, auraUnit, auraData)
        if not auraData then
            payloadDurObj = nil
            active = false
            mode = "inactive"
            auraInstanceID = nil
            auraUnit = nil
        end
    end

    local sourceKey = BuildMirrorDurationSourceKey(
        mode, sourceCooldownID, sourceSpellID, m.mirrorEpoch)

    WipeMirrorPayloadScratch()
    local payload = _mirrorPayloadScratch
    payload.mirrorBacked = true
    payload.state = m
    payload.active = active
    payload.mode = mode
    payload.sourceID = sourceKey
    payload.cooldownID = sourceCooldownID
    payload.category = NormalizeMirrorCategory(m.viewerCategory) or fallbackCategory
    payload.spellID = sourceSpellID
    payload.auraInstanceID = auraInstanceID
    payload.durObj = payloadDurObj
    payload.durationStateUnknown = overrideUnknown
    if payload.durationStateUnknown == nil then
        payload.durationStateUnknown = m.durationStateUnknown
    end
    payload.auraUnit = auraUnit
    payload.auraData = auraData
    payload.totemSlot = m.totemSlot
    payload.totemName = m.totemName
    payload.totemIcon = m.totemIcon
    payload.isTotemInstance = m.totemSlot and true or false
    payload.count = BuildMirrorCountPayload(m)

    if active and mode == "aura" and not payloadDurObj then
        payload.hasExpirationTime = false
        payload.hideDurationText = true
    end

    return payload
end

local function SelectMirrorCooldownPhase(m)
    if not m then return nil end
    if m.resourceDurObj then
        return m.resourceDurObj, m.resourceDurObjSource or "resource-duration", m.resourceDurationStateUnknown
    end
    if m.cooldownDurObj then
        return m.cooldownDurObj, m.cooldownDurObjSource or "cooldown-frame", m.cooldownDurationStateUnknown
    end
    if m.gcdDurObj then
        return m.gcdDurObj, m.gcdDurObjSource or "gcd-duration", m.gcdDurationStateUnknown
    end
    return nil
end

local function BuildMirrorCooldownPhasePayload(payload)
    local m = payload and payload.state
    if not m then return nil end

    local durObj, source, unknown = SelectMirrorCooldownPhase(m)
    if not durObj then return nil end

    local mode = ClassifyMirrorDurationMode(source)
    if mode == "aura" or mode == "inactive" then
        return nil
    end

    local cooldownID = payload.cooldownID
    local category = payload.category
    local spellID = payload.spellID
    return BuildMirrorRenderPayload(m, cooldownID, category, spellID, durObj, source, mode, unknown)
end

local function EntryMirrorBindingIsStrictAura(entry, viewerCategory)
    return MirrorBindingIsStrictAura(entry, nil, viewerCategory)
end

local function ResolveMirrorRenderPayloadForEntry(entry, explicitCooldownID, explicitCategory, fallbackSpellID)
    local mirror = ns.CDMBlizzMirror
    if not (entry and mirror) then
        return nil
    end

    local entryType = SafeEntryField(entry, "type")
    if entryType
        and entryType ~= "spell"
        and entryType ~= "aura"
        and entryType ~= "cooldown" then
        return nil
    end

    local viewerCategory = ResolveEntryMirrorCategory(entry)
    local strictAuraBinding = EntryMirrorBindingIsStrictAura(entry, viewerCategory)
    local explicitCat = NormalizeMirrorCategory(explicitCategory)

    local identity = ResolveExplicitMirrorIdentityState(
        mirror, entry, explicitCooldownID, explicitCat,
        viewerCategory, strictAuraBinding, "context", entryType)
    if identity and identity.state then
        return BuildMirrorRenderPayload(
            identity.state, identity.cooldownID, identity.category, fallbackSpellID)
    end

    identity = ResolveBlizzardMirrorIdentityState(entry)
    if identity and identity.state then
        return BuildMirrorRenderPayload(
            identity.state, identity.cooldownID, identity.category, fallbackSpellID)
    end

    if not strictAuraBinding and Sources and Sources.QueryMirroredCooldownState and fallbackSpellID then
        local m = Sources.QueryMirroredCooldownState(fallbackSpellID, entry.viewerType)
        if m then
            return BuildMirrorRenderPayload(
                m,
                m.cooldownID or fallbackSpellID,
                NormalizeMirrorCategory(m.viewerCategory) or viewerCategory,
                fallbackSpellID)
        end
    end

    return nil
end

local QueryItemCooldown
local QuerySlotCooldown

local function BuildDurationObjectFromStart(startTime, duration)
    local startSecret = ResolverIsSecretValue(startTime)
    local durationSecret = ResolverIsSecretValue(duration)
    if not startSecret and startTime == nil then return nil end
    if not durationSecret and duration == nil then return nil end
    if not (C_DurationUtil and C_DurationUtil.CreateDuration) then return nil end

    local okCreate, durObj = pcall(C_DurationUtil.CreateDuration)
    if not okCreate or not durObj or not durObj.SetTimeFromStart then
        return nil
    end

    local okSet = pcall(durObj.SetTimeFromStart, durObj, startTime, duration)
    if okSet then return durObj end
    return nil
end

local function CleanItemCooldownIsDisabled(enabled, requireEnabledOne)
    if ResolverIsSecretValue(enabled) then
        return false
    end
    if enabled == 0 or enabled == false then
        return true
    end
    if requireEnabledOne
        and enabled ~= nil
        and enabled ~= 1
        and enabled ~= true then
        return true
    end
    return false
end

local function CleanItemCooldownIsInactive(startTime, duration, enabled, requireEnabledOne)
    if CleanItemCooldownIsDisabled(enabled, requireEnabledOne) then
        return true
    end
    if ResolverIsSecretValue(startTime) or ResolverIsSecretValue(duration) then
        return false
    end
    if not IsSafeNumeric(startTime) or not IsSafeNumeric(duration) then
        return true
    end
    if startTime <= 0 then
        return true
    end
    if duration <= GCD_MAX_DURATION then
        return true
    end
    if (startTime + duration) <= GetTime() then
        return true
    end
    return false
end

local function CleanItemCooldownIsActive(startTime, duration, enabled, requireEnabledOne)
    if CleanItemCooldownIsDisabled(enabled, requireEnabledOne) then
        return false
    end
    if ResolverIsSecretValue(startTime) or ResolverIsSecretValue(duration) then
        return false
    end
    return IsSafeNumeric(startTime)
        and IsSafeNumeric(duration)
        and startTime > 0
        and duration > GCD_MAX_DURATION
        and (startTime + duration) > GetTime()
end

local function HasItemCooldownTiming(startTime, duration, enabled)
    return startTime ~= nil or duration ~= nil or enabled ~= nil
end

local function ResolveItemDurationObjectForIcon(icon, entry)
    local itemID, slotID, itemSpellID, keySource = ResolveItemCooldownIdentity(entry)
    if not itemID then return nil, "inactive", nil, nil, nil, nil end

    local startTime, duration, enabled
    local requireEnabledOne = slotID ~= nil
    local itemCooldownKnown = false
    if slotID then
        startTime, duration, enabled = QuerySlotCooldown(slotID)
        itemCooldownKnown = HasItemCooldownTiming(startTime, duration, enabled)
        if CleanItemCooldownIsInactive(startTime, duration, enabled, true) then
            local itemStart, itemDuration, itemEnabled = QueryItemCooldown(itemID)
            itemCooldownKnown = itemCooldownKnown or HasItemCooldownTiming(itemStart, itemDuration, itemEnabled)
            if not CleanItemCooldownIsInactive(itemStart, itemDuration, itemEnabled, false) then
                startTime = itemStart
                duration = itemDuration
                enabled = itemEnabled
                requireEnabledOne = false
            end
        end
    else
        startTime, duration, enabled = QueryItemCooldown(itemID)
        itemCooldownKnown = HasItemCooldownTiming(startTime, duration, enabled)
    end

    if not CleanItemCooldownIsInactive(startTime, duration, enabled, requireEnabledOne) then
        local cleanNumericActive = CleanItemCooldownIsActive(startTime, duration, enabled, requireEnabledOne)
        local itemDurObj = BuildDurationObjectFromStart(startTime, duration)
        if itemDurObj then
            return itemDurObj, "item-cooldown",
                "item-duration:" .. tostring(keySource),
                cleanNumericActive and startTime or nil,
                cleanNumericActive and duration or nil,
                itemSpellID
        end

        if cleanNumericActive then
            return nil, "item-cooldown",
                "item:" .. tostring(keySource) .. ":" .. tostring(startTime) .. ":" .. tostring(duration),
                startTime, duration, itemSpellID
        end
    elseif itemCooldownKnown then
        return nil, "inactive", nil, nil, nil, itemSpellID
    end

    if itemSpellID then
        local cdInfo = QueryCooldown(itemSpellID)
        local cdInfoActive = cdInfo and IsCooldownInfoActive(cdInfo)
        if cdInfoActive == true and GetCurrentIsOnGCD(itemSpellID, cdInfo) ~= true then
            local durObj = QueryDuration(itemSpellID)
            if durObj then
                return durObj, "item-cooldown",
                    "spell:" .. tostring(itemSpellID) .. ":" .. tostring(keySource),
                    nil, nil, itemSpellID
            end
        end
    end

    return nil, "inactive", nil, nil, nil, itemSpellID
end

QueryItemCooldown = function(itemID)
    if not itemID or not (Sources and Sources.QueryItemCooldown) then
        return nil, nil, nil
    end
    local startTime, duration, enabled = Sources.QueryItemCooldown(itemID)
    return startTime, duration, enabled
end

QuerySlotCooldown = function(slotID)
    if not slotID or not GetInventoryItemCooldown then
        return nil, nil, nil
    end
    local ok, startTime, duration, enabled = pcall(GetInventoryItemCooldown, "player", slotID)
    if ok then
        return startTime, duration, enabled
    end
    return nil, nil, nil
end

local _cooldownStateCountScratch = {
    value = nil,
    sinkText = nil,
    shown = false,
    source = nil,
}

local _cooldownStateScratch = {
    mode = "inactive",
    active = false,
    isActive = false,
    spellID = nil,
    sourceID = nil,
    durObj = nil,
    start = nil,
    duration = nil,
    mirrorBacked = nil,
    mirrorCooldownID = nil,
    mirrorCategory = nil,
    mirrorState = nil,
    state = nil,
    cooldownID = nil,
    category = nil,
    auraInstanceID = nil,
    auraUnit = nil,
    auraData = nil,
    resolvedAuraSpellID = nil,
    hasExpirationTime = nil,
    hideDurationText = nil,
    durationStateUnknown = nil,
    countValue = nil,
    countSinkText = nil,
    countShown = false,
    countSource = nil,
    countMirrorBacked = nil,
    count = _cooldownStateCountScratch,
    totemSlot = nil,
    totemName = nil,
    totemIcon = nil,
    isTotemInstance = false,
    numericCooldownActive = nil,
    auraResolved = nil,
    auraActive = nil,
    auraIsActive = nil,
    isOnCooldown = false,
    rechargeActive = false,
    hasCharges = false,
    hasChargesRemaining = false,
    gcdOnly = false,
    isGCDOnly = false,
    isAuraMode = false,
    isRealCooldownMode = false,
    hasDurationObject = false,
    hasRenderableCooldown = false,
    cooldownInfo = nil,
    cooldownInfoActive = nil,
    cooldownInfoOnGCD = nil,
}

local function WipeCooldownState()
    local s = _cooldownStateScratch
    s.mode = "inactive"
    s.active = false
    s.isActive = false
    s.spellID = nil
    s.sourceID = nil
    s.durObj = nil
    s.start = nil
    s.duration = nil
    s.mirrorBacked = nil
    s.mirrorCooldownID = nil
    s.mirrorCategory = nil
    s.mirrorState = nil
    s.state = nil
    s.cooldownID = nil
    s.category = nil
    s.auraInstanceID = nil
    s.auraUnit = nil
    s.auraData = nil
    s.resolvedAuraSpellID = nil
    s.hasExpirationTime = nil
    s.hideDurationText = nil
    s.durationStateUnknown = nil
    s.countValue = nil
    s.countSinkText = nil
    s.countShown = false
    s.countSource = nil
    s.countMirrorBacked = nil
    s.totemSlot = nil
    s.totemName = nil
    s.totemIcon = nil
    s.isTotemInstance = false
    s.numericCooldownActive = nil
    s.auraResolved = nil
    s.auraActive = nil
    s.auraIsActive = nil
    s.isOnCooldown = false
    s.rechargeActive = false
    s.hasCharges = false
    s.hasChargesRemaining = false
    s.gcdOnly = false
    s.isGCDOnly = false
    s.isAuraMode = false
    s.isRealCooldownMode = false
    s.hasDurationObject = false
    s.hasRenderableCooldown = false
    s.cooldownInfo = nil
    s.cooldownInfoActive = nil
    s.cooldownInfoOnGCD = nil

    local c = _cooldownStateCountScratch
    c.value = nil
    c.sinkText = nil
    c.shown = false
    c.source = nil
    s.count = c
    return s
end

local function SetCooldownStateActivity(state, active)
    active = active == true
    state.active = active
    state.isActive = active
end

local function CopyCountFactsToState(state, count, mirrorBacked)
    local c = _cooldownStateCountScratch
    if count then
        c.value = count.value
        c.sinkText = count.sinkText
        c.shown = count.shown == true
        c.source = count.source
    else
        c.value = nil
        c.sinkText = nil
        c.shown = false
        c.source = nil
    end
    state.count = c
    state.countValue = c.value
    state.countSinkText = c.sinkText
    state.countShown = c.shown
    state.countSource = c.source
    state.countMirrorBacked = mirrorBacked == true and count ~= nil or nil
end

local function CopyAuraFactsToState(state, aura)
    if not aura then return end
    local auraActive = aura.isActive == true
    state.auraResolved = true
    state.auraActive = auraActive
    state.auraIsActive = auraActive
    state.auraInstanceID = aura.auraInstanceID
    state.auraUnit = aura.auraUnit
    state.auraData = aura.auraData
    state.resolvedAuraSpellID = aura.resolvedAuraSpellID or state.spellID
    state.hasExpirationTime = aura.hasExpirationTime
    state.hideDurationText = aura.hideDurationText
    state.durationStateUnknown = aura.durationStateUnknown
    state.totemSlot = aura.totemSlot
    state.totemName = aura.totemName
    state.totemIcon = aura.totemIcon
    state.isTotemInstance = aura.isTotemInstance and true or false
    CopyCountFactsToState(state, aura.count, false)
end

local function GetAuraStateSourceID(aura, fallbackID)
    if not aura then return fallbackID end
    return aura.auraInstanceID or aura.totemSlot or fallbackID
end

local _cooldownStateAuraParams = {}

local function ResolveAuraRuntimeStateForContext(context, entry, sid, entryIsAura)
    local AuraRuntime = ns.CDMAuraRuntime
    if not (context and entry and sid) then
        return nil
    end
    if not entryIsAura and context.useBuffSwipe == false then
        return nil
    end

    local p = _cooldownStateAuraParams
    p.spellID = sid
    p.entrySpellID = entry.spellID
    p.entryID = entry.id
    p.entryName = entry.name
    p.entryKind = entry.kind
    p.entryType = entry.type
    p.entryIsAura = entryIsAura
    p.entryTexture = CDMResolvers.GetEntryTexture(entry)
    p.viewerType = context.containerKey or entry.viewerType
    p.totemSlot = context.totemSlot
    p.disableLooseVisibilityFallback = true
    p.blizzardMirrorCooldownID = context.mirrorCooldownID
    p.blizzardMirrorCategory = context.mirrorCategory

    if AuraRuntime and AuraRuntime.ResolveState then
        local aura = AuraRuntime.ResolveState(p)
        if aura then
            return aura
        end
    end
    return nil
end

local function ApplyAuraStateToCooldownState(state, aura, fallbackSpellID)
    CopyAuraFactsToState(state, aura)
    if not (aura and aura.isActive) then
        return false
    end
    state.mode = "aura"
    SetCooldownStateActivity(state, true)
    state.durObj = aura.durObj
    state.sourceID = GetAuraStateSourceID(aura, fallbackSpellID)
    state.spellID = aura.resolvedAuraSpellID or fallbackSpellID
    if aura.isActive and aura.hasExpirationTime == nil and not aura.durObj then
        state.hasExpirationTime = false
        state.hideDurationText = true
    end
    return true
end

local function ResolveMirrorPayloadAuraActive(payload)
    if not (payload and payload.active == true) then
        return false
    end
    if payload.mode == "aura" then
        return true
    end
    if payload.auraInstanceID or payload.totemSlot then
        return true
    end
    local m = payload.state
    if m and (m.auraDurObj or m.totemDurObj) then
        return true
    end
    return false
end

local function ApplyMirrorPayloadToCooldownState(state, payload)
    if not payload then return false end
    local auraActive = ResolveMirrorPayloadAuraActive(payload)
    state.mode = payload.mode or "inactive"
    SetCooldownStateActivity(state, payload.active == true)
    state.spellID = payload.spellID
    state.sourceID = payload.sourceID
    state.durObj = payload.durObj
    state.mirrorBacked = true
    state.mirrorCooldownID = payload.cooldownID
    state.mirrorCategory = payload.category
    state.mirrorState = payload.state
    state.state = payload.state
    state.cooldownID = payload.cooldownID
    state.category = payload.category
    state.auraInstanceID = payload.auraInstanceID
    state.auraUnit = payload.auraUnit
    state.auraData = payload.auraData
    state.resolvedAuraSpellID = payload.spellID
    state.hasExpirationTime = payload.hasExpirationTime
    state.hideDurationText = payload.hideDurationText
    state.durationStateUnknown = payload.durationStateUnknown
    state.auraActive = auraActive
    state.auraIsActive = auraActive
    state.totemSlot = payload.totemSlot
    state.totemName = payload.totemName
    state.totemIcon = payload.totemIcon
    state.isTotemInstance = payload.isTotemInstance and true or false
    CopyCountFactsToState(state, payload.count, true)
    if state.active and state.mode == "aura" and state.hasExpirationTime == nil and not state.durObj then
        state.hasExpirationTime = false
        state.hideDurationText = true
    end
    return true
end

local function ApplyCleanItemAuraTiming(state, itemID, spellID, resolvedAuraSpellID, auraUnit, auraInstanceID,
                                        expiration, duration, sourceSuffix)
    if ResolverIsSecretValue(expiration) or ResolverIsSecretValue(duration) then
        return false
    end
    if not (IsSafeNumeric(expiration) and IsSafeNumeric(duration)) then
        return false
    end
    if duration <= 0 or expiration <= GetTime() then
        return false
    end

    state.mode = "aura"
    SetCooldownStateActivity(state, true)
    state.start = expiration - duration
    state.duration = duration
    state.sourceID = "item-aura-" .. tostring(sourceSuffix or "scanner") .. ":" .. tostring(itemID)
    state.spellID = spellID
    state.auraResolved = true
    state.auraActive = true
    state.auraIsActive = true
    state.auraUnit = auraUnit or "player"
    state.auraInstanceID = CleanOpaqueValue(auraInstanceID)
    state.hasAuraInstanceID = HasOpaqueValue(auraInstanceID)
    state.resolvedAuraSpellID = resolvedAuraSpellID or spellID
    return true
end

local function ResolveItemAuraForContext(state, context, entry, itemID, itemSpellID)
    if not (context and entry and itemID) then
        return false
    end

    local function trySpellID(rawSpellID, sourceKey)
        local durObj, resolvedAuraSpellID = QueryPlayerAuraDurationBySpellID(rawSpellID, entry.name)
        if durObj then
            state.mode = "aura"
            SetCooldownStateActivity(state, true)
            state.durObj = durObj
            state.sourceID = "item-aura-spell:" .. tostring(itemID) .. ":" .. sourceKey
            state.spellID = rawSpellID
            state.auraResolved = true
            state.auraActive = true
            state.auraIsActive = true
            state.auraUnit = "player"
            state.resolvedAuraSpellID = resolvedAuraSpellID or rawSpellID
            return true
        end
        return false
    end

    local rawItemSpellID = QueryItemUseSpellID(itemID)
    if trySpellID(rawItemSpellID, "raw-use") then return true end
    if trySpellID(itemSpellID, "use") then return true end

    if Sources and Sources.QueryScannedItemAuraInfo then
        local scanned = Sources.QueryScannedItemAuraInfo(itemID, itemSpellID or rawItemSpellID)
        if scanned then
            local auraInstanceID = scanned.auraInstanceID
            if HasOpaqueValue(auraInstanceID) and Sources.QueryAuraDuration then
                local auraUnit = scanned.auraUnit or "player"
                local durObj = Sources.QueryAuraDuration(auraUnit, auraInstanceID)
                if durObj then
                    local cleanAuraInstanceID = CleanOpaqueValue(auraInstanceID)
                    state.mode = "aura"
                    SetCooldownStateActivity(state, true)
                    state.durObj = durObj
                    state.sourceID = cleanAuraInstanceID
                        and ("item-aura-instance:" .. tostring(itemID) .. ":" .. tostring(cleanAuraInstanceID))
                        or ("item-aura-instance:" .. tostring(itemID))
                    state.spellID = scanned.buffSpellID or scanned.useSpellID or itemSpellID or rawItemSpellID
                    state.auraResolved = true
                    state.auraActive = true
                    state.auraIsActive = true
                    state.auraUnit = auraUnit
                    state.auraInstanceID = cleanAuraInstanceID
                    state.hasAuraInstanceID = true
                    state.resolvedAuraSpellID = scanned.buffSpellID or scanned.useSpellID or state.spellID
                    return true
                end
                if Sources.QueryAuraDataByAuraInstanceID then
                    local auraData = Sources.QueryAuraDataByAuraInstanceID(auraUnit, auraInstanceID)
                    if auraData and ApplyCleanItemAuraTiming(
                        state,
                        itemID,
                        scanned.buffSpellID or scanned.useSpellID or itemSpellID or rawItemSpellID,
                        scanned.buffSpellID or scanned.useSpellID,
                        auraUnit,
                        auraInstanceID,
                        auraData.expirationTime,
                        auraData.duration,
                        "aura-data") then
                        return true
                    end
                end
            end
            if trySpellID(scanned.buffSpellID, "scanner-buff") then return true end
            if trySpellID(scanned.useSpellID, "scanner-use") then return true end
            if trySpellID(scanned.sourceSpellID, "scanner-source") then return true end
            local scannedActive = scanned.active
            if ResolverIsSecretValue(scannedActive) then
                scannedActive = nil
            end
            if scannedActive == true then
                local expiration = scanned.expiration
                local duration = scanned.duration
                local scannedSpellID = scanned.buffSpellID or scanned.useSpellID or itemSpellID or rawItemSpellID
                if ApplyCleanItemAuraTiming(
                    state,
                    itemID,
                    scannedSpellID,
                    scanned.buffSpellID or scanned.useSpellID or scannedSpellID,
                    scanned.auraUnit or "player",
                    scanned.auraInstanceID,
                    expiration,
                    duration,
                    "scanner") then
                    return true
                end

                state.mode = "aura"
                SetCooldownStateActivity(state, true)
                state.sourceID = "item-aura-scanner:" .. tostring(itemID)
                state.spellID = scanned.buffSpellID or scanned.useSpellID or itemSpellID or rawItemSpellID
                state.auraResolved = true
                state.auraActive = true
                state.auraIsActive = true
                state.auraUnit = scanned.auraUnit or "player"
                state.auraInstanceID = CleanOpaqueValue(scanned.auraInstanceID)
                state.hasAuraInstanceID = HasOpaqueValue(scanned.auraInstanceID)
                state.resolvedAuraSpellID = scanned.buffSpellID or scanned.useSpellID or state.spellID
                state.hasExpirationTime = false
                state.hideDurationText = true
                return true
            end
        end
    end

    if trySpellID(entry.spellID, "entry") then return true end
    if trySpellID(entry.overrideSpellID, "override") then return true end
    if trySpellID(entry.id, "id") then return true end

    local durObj = QueryPlayerAuraDurationByName(entry.name)
    if durObj then
        state.mode = "aura"
        SetCooldownStateActivity(state, true)
        state.durObj = durObj
        state.sourceID = "item-aura-name:" .. tostring(itemID)
        state.auraResolved = true
        state.auraActive = true
        state.auraIsActive = true
        state.auraUnit = "player"
        state.resolvedAuraSpellID = itemSpellID
        state.spellID = itemSpellID
        return true
    end

    return false
end

local function IsRealCooldownDurationMode(mode)
    return mode == "cooldown"
        or mode == "charge"
        or mode == "item-cooldown"
end

local function HasDurationObject(value)
    if ResolverIsSecretValue(value) then
        return true
    end
    return value ~= nil
end

function CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    if not state then return state end

    local mode = state.mode
    if not IsSupportedMirrorMode(mode) then
        mode = "inactive"
        state.mode = mode
    end

    local active = state.active == true
    if mode == "inactive" then
        active = false
    end
    state.active = active
    state.isActive = active

    if state.auraActive ~= nil or state.auraIsActive ~= nil then
        local auraActive = state.auraActive == true
        state.auraActive = auraActive
        state.auraIsActive = auraActive
    end

    state.gcdOnly = mode == "gcd-only"
    state.isGCDOnly = state.gcdOnly
    state.isAuraMode = mode == "aura"
    state.isRealCooldownMode = IsRealCooldownDurationMode(mode)
    state.hasCharges = state.hasCharges == true or mode == "charge"
    state.isOnCooldown = state.isOnCooldown == true
    state.rechargeActive = state.rechargeActive == true
    state.hasChargesRemaining = state.hasChargesRemaining == true
    state.numericCooldownActive = state.numericCooldownActive == true or nil

    local hasDurationObject = mode ~= "inactive" and HasDurationObject(state.durObj)
    state.hasDurationObject = hasDurationObject == true
    state.hasRenderableCooldown = mode ~= "inactive"
        and (state.hasDurationObject == true or state.numericCooldownActive == true)

    local count = state.count
    if count then
        count.shown = count.shown == true
        state.countValue = count.value
        state.countSinkText = count.sinkText
        state.countShown = count.shown
        state.countSource = count.source
    else
        state.countValue = nil
        state.countSinkText = nil
        state.countShown = false
        state.countSource = nil
    end

    return state
end

local function IsNumericCooldownActive(startTime, duration)
    return IsSafeNumeric(startTime)
        and IsSafeNumeric(duration)
        and startTime > 0
        and duration > GCD_MAX_DURATION
        and (startTime + duration) > GetTime()
end

local function ClearCooldownBinding(state)
    if not state then return end
    state.mode = "inactive"
    SetCooldownStateActivity(state, false)
    state.durObj = nil
    state.sourceID = nil
    state.start = nil
    state.duration = nil
    state.numericCooldownActive = nil
end

local function ApplyPriorRealCooldownBinding(state, context, sid, entryIsAura)
    if not (state and context and sid) or entryIsAura then
        return
    end
    if state.mode ~= "gcd-only" or state.mirrorBacked == true then
        return
    end

    local hasPriorRealCooldown = context.priorRealCooldownActive == true
        or context.priorShowingRealCooldownSwipe == true
        or IsRealCooldownDurationMode(context.priorResolvedCooldownMode)
    if not hasPriorRealCooldown then
        return
    end

    local preservePriorBinding = context.priorRealCooldownActive == true
        or context.priorCooldownActive == true
    if preservePriorBinding
        and context.preservedRealDurObj
        and IsRealCooldownDurationMode(context.preservedRealMode) then
        state.mode = context.preservedRealMode
        SetCooldownStateActivity(state, true)
        state.durObj = context.preservedRealDurObj
        state.sourceID = context.preservedRealSourceID
        state.spellID = sid
        return
    end

    local realDur = QueryDuration(sid)
    local spellUsable = QuerySpellUsableState(sid)
    if realDur and spellUsable ~= true then
        state.mode = "cooldown"
        SetCooldownStateActivity(state, true)
        state.durObj = realDur
        state.sourceID = sid
        state.spellID = sid
    end
end

local function MirrorPayloadHasChargeState(state)
    if not state then return false end

    local m = state.state
    if not m then return false end
    if SafeMirrorString(m.resolvedMode) == "charge"
        or SafeMirrorString(m.durObjSource) == "spell-charge" then
        return true
    end
    if ResolverIsSecretValue(m.resourceDurObj) or m.resourceDurObj ~= nil then
        return true
    end
    if SafeBoolean(m.cooldownChargesShown) == true
        or SafeBoolean(m.chargeCountFrameShown) == true then
        return true
    end
    return SafeMirrorString(m.stackTextSource) == "ChargeCount"
        and SafeBoolean(m.stackTextShown) ~= false
end

local function MirrorPayloadMatchesRecentChargeCycle(state, context)
    local m = state and state.state
    if not (context and m and SafeBoolean(m.isActive) == true
        and context.lastChargeMirrorCooldownID) then
        return false
    end

    local cooldownID = state.cooldownID or m.cooldownID or context.mirrorCooldownID
    if cooldownID ~= context.lastChargeMirrorCooldownID then
        return false
    end

    local category = state.category
        or NormalizeMirrorCategory(m.viewerCategory)
        or context.mirrorCategory
    return context.lastChargeMirrorCategory == nil
        or category == context.lastChargeMirrorCategory
end

local function GetResolvedCooldownInfo(state, sid)
    if state and state.cooldownInfo then
        return state.cooldownInfo
    end
    local cdInfo = sid and QueryCooldown(sid)
    if state then
        state.cooldownInfo = cdInfo
    end
    return cdInfo
end

local function StampCooldownInfoBooleans(state, cdInfo, sid)
    local active = cdInfo and IsCooldownInfoActive(cdInfo)
    if active == nil then
        active = GetCooldownInfoBoolean(cdInfo, "isActive")
    end
    local onGCD = cdInfo and GetCurrentIsOnGCD(sid, cdInfo)
    if state then
        state.cooldownInfoActive = active
        state.cooldownInfoOnGCD = onGCD
    end
    return active, onGCD
end

local function FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
    if not state then return state end

    ApplyPriorRealCooldownBinding(state, context, sid, entryIsAura)

    local mode = state.mode or "inactive"
    local hasNumericCooldown = (mode == "item-cooldown" or mode == "aura")
        and IsNumericCooldownActive(state.start, state.duration)
    state.numericCooldownActive = hasNumericCooldown == true or nil
    state.gcdOnly = mode == "gcd-only"
    state.hasCharges = (entry and (entry.hasCharges == true or entry.charges == true))
        or mode == "charge"

    state.isOnCooldown = false
    state.rechargeActive = false
    state.hasChargesRemaining = false

    if mode == "inactive" or mode == "aura" or mode == "gcd-only" then
        if mode == "inactive" then
            SetCooldownStateActivity(state, false)
        end
        return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    end

    if mode == "item-cooldown" then
        state.isOnCooldown = HasDurationObject(state.durObj) or hasNumericCooldown == true
        return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    end

    if entryIsAura or itemBackedEntry or not sid then
        state.isOnCooldown = state.active == true
        return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    end

    local mirrorBackedCooldownMode = state.mirrorBacked == true
        and (mode == "cooldown" or mode == "charge" or mode == "item-cooldown")
    local mirrorBackedHasRenderableCooldown = HasDurationObject(state.durObj)
        or hasNumericCooldown == true
    local mirrorBackedRealMode = mirrorBackedCooldownMode
        and mirrorBackedHasRenderableCooldown
    local mirrorChargeMode = state.mirrorBacked == true
        and (mode == "charge"
            or MirrorPayloadHasChargeState(state)
            or MirrorPayloadMatchesRecentChargeCycle(state, context))

    if mode == "charge" then
        state.hasCharges = true
        state.rechargeActive = HasDurationObject(state.durObj)
            or state.active == true
            or state.isActive == true

        local cdInfo = GetResolvedCooldownInfo(state, sid)
        local cdInfoActive, cdInfoOnGCD = StampCooldownInfoBooleans(state, cdInfo, sid)
        local spellUsable = QuerySpellUsableState(sid)
        local chargeInfo = QueryCharges(sid)
        local chargeZero = ResolveChargeZeroState(chargeInfo, cdInfoActive)
        -- Some charged spells report usable while their recharge is active.
        -- Decode the secret currentCharges number through a C-side step curve
        -- when possible so 0 charges is the only unavailable charge state.
        if cdInfoOnGCD == true or cdInfoActive == false then
            state.isOnCooldown = false
        elseif chargeZero ~= nil then
            state.isOnCooldown = chargeZero == true
        elseif cdInfoActive == true then
            state.isOnCooldown = true
        elseif spellUsable == true then
            state.isOnCooldown = false
        elseif state.mirrorBacked == true then
            state.isOnCooldown = mirrorBackedRealMode == true
        end
        state.hasChargesRemaining = state.hasCharges == true
            and state.rechargeActive == true
            and state.isOnCooldown ~= true
        return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    end

    if mirrorBackedCooldownMode
        and not hasNumericCooldown
        and not mirrorChargeMode then
        local cdInfo = GetResolvedCooldownInfo(state, sid)
        if cdInfo then
            local cdInfoActive, cdInfoOnGCD = StampCooldownInfoBooleans(state, cdInfo, sid)
            if cdInfoActive == false then
                ClearCooldownBinding(state)
                state.gcdOnly = false
                return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
            elseif cdInfoOnGCD == true then
                state.isOnCooldown = false
                return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
            elseif cdInfoActive == true then
                state.isOnCooldown = true
                return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
            end
        end
        state.isOnCooldown = mirrorBackedRealMode == true
        return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    end

    if state.mirrorBacked == true then
        state.isOnCooldown = mirrorBackedRealMode == true
        return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
    end

    local cdInfo = GetResolvedCooldownInfo(state, sid)
    if cdInfo then
        local cdInfoActive = StampCooldownInfoBooleans(state, cdInfo, sid)
        local spellUsable = nil
        if mode == "cooldown" then
            spellUsable = QuerySpellUsableState(sid)
        end
        state.isOnCooldown = cdInfoActive == true and spellUsable ~= true
    else
        state.isOnCooldown = false
    end

    return CDMResolvers.NormalizeResolvedCooldownStateContract(state)
end

function CDMResolvers.ResolveCooldownState(context)
    local state = WipeCooldownState()
    local entry = context and context.entry
    if not entry then
        return FinalizeCooldownStateActivity(state, context, entry, nil, nil, nil)
    end

    local entryIsAura = CDMResolvers.IsAuraEntry(entry)
    local macroResolvedID, macroResolvedType
    if entry.type == "macro" then
        macroResolvedID, macroResolvedType = CDMResolvers.ResolveMacro(entry)
    end
    local sid = (macroResolvedType == "spell" and macroResolvedID)
        or context.runtimeSpellID
        or entry.overrideSpellID or entry.spellID or entry.id
    if sid and not entryIsAura then
        sid = QueryOverrideSpell(sid) or sid
    end
    state.spellID = sid

    local itemID, itemSpellID
    local itemBackedEntry = IsItemLikeEntry(entry)
        or (entry.type == "macro" and macroResolvedType == "item")
    if itemBackedEntry then
        itemID, _, itemSpellID = ResolveItemCooldownIdentity(entry)
        if itemSpellID then
            sid = itemSpellID
            state.spellID = sid
        end
    end

    local mirrorPayload = ResolveMirrorRenderPayloadForEntry(
        entry,
        context.mirrorCooldownID,
        context.mirrorCategory,
        sid)
    if mirrorPayload then
        if mirrorPayload.mode ~= "aura" and context.skipAuraPhase ~= true then
            local aura = ResolveAuraRuntimeStateForContext(context, entry, sid, entryIsAura)
            if ApplyAuraStateToCooldownState(state, aura, sid) then
                return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
            end
        end
        if mirrorPayload.mode == "aura" and context.skipAuraPhase == true then
            mirrorPayload = BuildMirrorCooldownPhasePayload(mirrorPayload) or mirrorPayload
        end
        if MirrorPayloadAllowsLiveChargeOverride(mirrorPayload) then
            local chargeDur, chargeMode, chargeSourceID = ResolveLiveChargeDurationObject(sid, entry)
            if chargeDur then
                state.mode = chargeMode
                SetCooldownStateActivity(state, true)
                state.durObj = chargeDur
                state.sourceID = chargeSourceID
                state.spellID = sid
                return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
            end
        end
        ApplyMirrorPayloadToCooldownState(state, mirrorPayload)
        return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
    end

    local aura = ResolveAuraRuntimeStateForContext(context, entry, sid, entryIsAura)
    if ApplyAuraStateToCooldownState(state, aura, sid) then
        return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
    end

    if itemID and ResolveItemAuraForContext(state, context, entry, itemID, itemSpellID) then
        return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
    end

    if itemBackedEntry then
        local itemDur, itemMode, itemSourceID, itemStart, itemDuration, resolvedItemSpellID =
            ResolveItemDurationObjectForIcon(nil, entry)
        if itemMode == "item-cooldown" then
            state.mode = itemMode
            SetCooldownStateActivity(state, true)
            state.durObj = itemDur
            state.sourceID = itemSourceID
            state.start = itemStart
            state.duration = itemDuration
            state.spellID = resolvedItemSpellID
            state.numericCooldownActive = itemStart ~= nil and itemDuration ~= nil or nil
            return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
        end
        if entry.type ~= "macro" or macroResolvedType == "item" then
            state.mode = "inactive"
            state.spellID = resolvedItemSpellID
            return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
        end
    end

    if entryIsAura or not sid then
        state.mode = "inactive"
        state.spellID = sid
        return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
    end

    local gcdCdInfo = QueryCooldown(sid)
    local currentOnGCD = GetCurrentIsOnGCD(sid, gcdCdInfo)
    local gcdDurObj
    if currentOnGCD == true and context.showGCDSwipe == true then
        gcdDurObj = QueryGCDDurationObject(sid)
    end

    do
        local chargeDur, chargeMode, chargeSourceID = ResolveLiveChargeDurationObject(sid, entry)
        if chargeDur then
            state.mode = chargeMode
            SetCooldownStateActivity(state, true)
            state.durObj = chargeDur
            state.sourceID = chargeSourceID
            state.spellID = sid
            return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
        end
    end

    do
        local cdInfo = gcdCdInfo or QueryCooldown(sid)
        local cdInfoActive = cdInfo and IsCooldownInfoActive(cdInfo)
        if cdInfoActive == true then
            local cdInfoOnGCD = GetCurrentIsOnGCD(sid, cdInfo)
            local durObj = QueryDuration(sid)
            local spellUsable = QuerySpellUsableState(sid)
            local durationIsGCD = ShouldTreatLiveDurationAsGCD(
                sid, entry, cdInfo, cdInfoOnGCD, spellUsable)
            if durObj and not durationIsGCD and spellUsable ~= true then
                state.mode = "cooldown"
                SetCooldownStateActivity(state, true)
                state.durObj = durObj
                state.sourceID = sid
                state.spellID = sid
                state.cooldownInfo = cdInfo
                return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
            end
            if cdInfoOnGCD == true and context.showGCDSwipe == true then
                local gcdDur = QueryGCDDurationObject(sid)
                if gcdDur then
                    state.mode = "gcd-only"
                    SetCooldownStateActivity(state, true)
                    state.durObj = gcdDur
                    state.sourceID = sid
                    state.spellID = sid
                    state.cooldownInfo = cdInfo
                    return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
                end
                if durObj and durationIsGCD then
                    state.mode = "gcd-only"
                    SetCooldownStateActivity(state, true)
                    state.durObj = durObj
                    state.sourceID = sid
                    state.spellID = sid
                    state.cooldownInfo = cdInfo
                    return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
                end
            end
        end
    end

    if gcdDurObj then
        state.mode = "gcd-only"
        SetCooldownStateActivity(state, true)
        state.durObj = gcdDurObj
        state.sourceID = sid
        state.spellID = sid
        state.cooldownInfo = gcdCdInfo
        return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
    end

    state.mode = "inactive"
    state.spellID = sid
    return FinalizeCooldownStateActivity(state, context, entry, sid, entryIsAura, itemBackedEntry)
end
