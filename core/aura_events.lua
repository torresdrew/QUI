--[[
    QUI Centralized Aura Event Dispatcher
    Shared UNIT_AURA routing with roster units filtered at RegisterUnitEvent.
    Eliminates 7+ independent event handlers each doing their own aura scanning.

    Usage:
        ns.AuraEvents:Subscribe("player", callback)    -- unit == "player" only
        ns.AuraEvents:Subscribe("group",  callback)    -- party1..4 / raid1..40 (not player)
        ns.AuraEvents:Subscribe("roster", callback)    -- player + party + raid
        ns.AuraEvents:Subscribe("all",    callback)    -- every UNIT_AURA incl. nameplates/target/focus/boss/arena

    Callback signature: callback(unit, updateInfo)

    Nameplates/target/focus/boss/arena/pet/mouseover never reach player/group/roster
    subscribers — use "all" if you need them.
]]

local ADDON_NAME, ns = ...

-- Upvalue hot-path globals
local pairs = pairs
local ipairs = ipairs
local type = type
local wipe = wipe
local tostring = tostring
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local issecretvalue = issecretvalue

---------------------------------------------------------------------------
-- DISPATCHER
---------------------------------------------------------------------------
local AuraEvents = {}
ns.AuraEvents = AuraEvents

-- Subscriber lists by filter
local subscribers = {
    player = {},   -- only unit == "player"
    group  = {},   -- party/raid units (not player)
    roster = {},   -- player + party1..4 + raid1..40 only (skips target/focus/boss/nameplate/arena)
    nameplate = {},-- nameplate1..40 (lazy per-unit frames, created on first Subscribe)
    all    = {},   -- every UNIT_AURA event
}

-- Static roster unit set. UNIT_AURA fires for every unit token in the world
-- (player, party1..4, raid1..40, target, focus, boss1..5, arena1..5, pet,
-- mouseover, nameplate1..40, targettarget, focustarget, ...). In a raid with
-- many nameplates, the non-roster events dominate — an O(1) table lookup here
-- avoids dispatching to subscribers that would just early-out anyway.
local rosterUnits = { player = true }
for i = 1, 4 do rosterUnits["party" .. i] = true end
for i = 1, 40 do rosterUnits["raid" .. i] = true end

-- Static nameplate unit set (nameplate1..40). Registration frames are
-- created lazily on first "nameplate" Subscribe — see EnsureNameplateFrames.
local nameplateUnits = {}
for i = 1, 40 do nameplateUnits["nameplate" .. i] = true end

local EnsureNameplateFrames -- forward decl (defined after QueueAuraEvent)

function AuraEvents:Subscribe(filter, callback)
    local list = subscribers[filter]
    if not list then
        error("AuraEvents:Subscribe invalid filter '" .. tostring(filter) .. "', use 'player', 'group', 'roster', 'nameplate', or 'all'")
    end
    if filter == "nameplate" then
        EnsureNameplateFrames()
    end
    -- Avoid duplicate subscriptions
    for _, cb in ipairs(list) do
        if cb == callback then return end
    end
    list[#list + 1] = callback
    if self._RecountSubscribers then self:_RecountSubscribers() end
end

function AuraEvents:Unsubscribe(filter, callback)
    local list = subscribers[filter]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == callback then
            table.remove(list, i)
            if self._RecountSubscribers then self:_RecountSubscribers() end
            return
        end
    end
end

local pendingUnits = {}
local pendingAllEligible = {}
local coalesceFrame = CreateFrame("Frame")
coalesceFrame:Hide()

-- Cache subscriber list lengths in hot-path locals to avoid the ipairs
-- iterator cost on every pending unit. Updated inside Subscribe/Unsubscribe.
local nAll, nRoster, nPlayer, nGroup, nNameplate = 0, 0, 0, 0, 0
local subAll, subRoster, subPlayer, subGroup, subNameplate =
    subscribers.all, subscribers.roster, subscribers.player, subscribers.group, subscribers.nameplate

local function ProtectedFanout(list, n, unit, info)
    for i = 1, n do
        local ok, err = pcall(list[i], unit, info)
        if not ok then
            geterrorhandler()(err)
        end
    end
end

local function DispatchUnit(unit, info, isRoster, isNameplate, allEligible)
    if not isNameplate or allEligible then
        ProtectedFanout(subAll, nAll, unit, info)
    end

    if isNameplate then
        ProtectedFanout(subNameplate, nNameplate, unit, info)
    elseif isRoster then
        ProtectedFanout(subRoster, nRoster, unit, info)

        -- Player/group split is roster-scoped: "group" means
        -- party+raid (not player). Non-roster units like nameplates,
        -- target, focus, boss, arena never reach player/group
        -- subscribers — they go through "all" if they need them.
        if unit == "player" then
            ProtectedFanout(subPlayer, nPlayer, unit, info)
        else
            ProtectedFanout(subGroup, nGroup, unit, info)
        end
    end
end

coalesceFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    for unit, updateInfo in pairs(pendingUnits) do
        local info = updateInfo ~= true and updateInfo or nil

        local ok, err = pcall(DispatchUnit, unit, info, rosterUnits[unit],
            nameplateUnits[unit], pendingAllEligible[unit])
        if not ok then
            geterrorhandler()(err)
        end

        -- Clear merged accumulator so it's ready for reuse next frame.
        -- info is nil when updateInfo was `true` (full-update sentinel), so
        -- the nil check is enough without a type() call.
        if info and info._isMerged then
            info._isMerged = nil
            wipe(info.addedAuras)
            wipe(info.removedAuraInstanceIDs)
            wipe(info.updatedAuraInstanceIDs)
        end
    end
    wipe(pendingUnits)
    wipe(pendingAllEligible)
end)

local function RecountSubscribers()
    nAll = #subAll
    nRoster = #subRoster
    nPlayer = #subPlayer
    nGroup = #subGroup
    nNameplate = #subNameplate
end
AuraEvents._RecountSubscribers = RecountSubscribers

---------------------------------------------------------------------------
-- DELTA MERGING: When multiple UNIT_AURA events arrive for the same unit
-- in one render frame, merge deltas instead of falling back to a full scan.
-- This preserves the incremental update path downstream (group frame auras)
-- which is dramatically cheaper than a full C_UnitAuras.GetUnitAuras call.
---------------------------------------------------------------------------
-- Per-unit scratch tables for merging (pre-allocated, reused via wipe)
local mergedInfoPool = {}  -- [unit] = { addedAuras = {}, removed... = {}, updated... = {} }
-- AuraEvt_mergedInfoPool memprobe anchor

local function GetMergedInfo(unit)
    local m = mergedInfoPool[unit]
    if not m then
        m = { addedAuras = {}, removedAuraInstanceIDs = {}, updatedAuraInstanceIDs = {} }
        mergedInfoPool[unit] = m
    end
    return m
end

-- Copy delta arrays from updateInfo into the merged accumulator
local function AppendDeltaField(merged, updateInfo, field)
    local src = updateInfo[field]
    -- 12.1: UNIT_AURA delta arrays arrive as SecretValue while auras are
    -- restricted. ipairs over a secret value throws (and would leak secrets
    -- into the merged accumulator), so skip a secret field — QueueAuraEvent
    -- promotes the whole event to a full update when the payload is secret.
    if src and not (issecretvalue and issecretvalue(src)) then
        local dst = merged[field]
        for _, v in ipairs(src) do
            dst[#dst + 1] = v
        end
    end
end

local function AccumulateDelta(merged, updateInfo)
    AppendDeltaField(merged, updateInfo, "addedAuras")
    AppendDeltaField(merged, updateInfo, "removedAuraInstanceIDs")
    AppendDeltaField(merged, updateInfo, "updatedAuraInstanceIDs")
end

local function AnyIDElementSecret(arr)
    if not arr then return false end
    for i = 1, #arr do
        if issecretvalue(arr[i]) then return true end -- @secret-policy: report-secret-detected
    end
    return false
end

local function AnyAddedAuraSecret(arr)
    if not arr then return false end
    for i = 1, #arr do
        local data = arr[i]
        if issecretvalue(data) then return true end -- @secret-policy: report-secret-detected
        if data ~= nil
            and (issecretvalue(data.auraInstanceID)
                or issecretvalue(data.spellId)
                or issecretvalue(data.spellID)) then
            return true -- @secret-policy: report-secret-detected
        end
    end
    return false
end

local function PayloadIsSecret(updateInfo)
    if not issecretvalue then return false end
    if issecretvalue(updateInfo) then return true end -- @secret-policy: report-secret-detected
    if not updateInfo then return false end
    if issecretvalue(updateInfo.isFullUpdate)
        or issecretvalue(updateInfo.addedAuras)
        or issecretvalue(updateInfo.updatedAuraInstanceIDs)
        or issecretvalue(updateInfo.removedAuraInstanceIDs) then
        return true -- @secret-policy: report-secret-detected
    end
    return AnyAddedAuraSecret(updateInfo.addedAuras)
        or AnyIDElementSecret(updateInfo.updatedAuraInstanceIDs)
        or AnyIDElementSecret(updateInfo.removedAuraInstanceIDs)
end

---------------------------------------------------------------------------
-- NON-ROSTER INTEREST PREDICATE
--
-- Non-roster units (nameplates, target, focus, boss, arena, pet, mouseover,
-- targettarget, ...) only reach "all" subscribers. Current "all" consumers
-- want at most two things:
--   1. `unit == "target"` — kept cheap for any future target consumer (CDM's
--      target refresh registers UNIT_AURA directly, not through this router).
--   2. The unit the GameTooltip is currently showing — tooltip.lua
--      OnUnitAuraChanged, which refreshes that one tooltip's mount line.
--
-- The tooltip consumer self-gates twice: it bails in combat, and it discards
-- any unit that isn't the one the tooltip is showing (token-equality against
-- GameTooltip:GetUnit). So passing EVERY non-roster token through whenever a
-- tooltip happens to be up — the old behaviour — flooded the dispatcher in
-- raids/M+ (40 enemy nameplates ticking DoTs the instant any tooltip appears),
-- and every one of those events was then thrown away by the subscriber. That
-- was a large, sustained FPS drop the moment the cursor touched a unit frame.
--
-- Scope the pass to exactly what a subscriber can act on:
--   * `target` always (cdm path, in and out of combat),
--   * out of combat, the tooltip's OWN unit token only.
-- Combat needs nothing else here (the tooltip consumer bails), so we drop the
-- whole storm with a single InCombatLockdown check before touching the tooltip.
---------------------------------------------------------------------------
local function IsNonRosterEventInteresting(unit)
    if unit == "target" then return true end
    -- In combat the only "all" consumer bails, so nothing non-target is useful.
    -- This is the hot path during a pull — keep it a single cheap C call.
    if InCombatLockdown() then return false end
    local tt = _G.GameTooltip
    if not (tt and tt:IsShown()) then return false end
    -- Match the subscriber's own contract: ResolveTooltipUnit() == changedUnit,
    -- i.e. token equality against GameTooltip:GetUnit()'s unit return.
    local _, ttUnit = tt:GetUnit()
    if ttUnit == nil then return false end
    if issecretvalue and issecretvalue(ttUnit) then return false end -- @secret-policy: reject-secret-value (unknown tooltip unit = not interesting)
    return unit == ttUnit
end

local canaccesstable = canaccesstable

local function QueueAuraEvent(unit, updateInfo)
    if canaccesstable and not (issecretvalue and issecretvalue(updateInfo))
        and type(updateInfo) == "table" and not canaccesstable(updateInfo) then
        updateInfo = nil
    end
    local existing = pendingUnits[unit]
    if existing == true then
    elseif issecretvalue and issecretvalue(updateInfo) then
        pendingUnits[unit] = true -- @secret-policy: report-secret-detected (full-update sentinel promotion)
    elseif PayloadIsSecret(updateInfo) then
        -- Secret delta (combat, restricted auras): the arrays can't be merged
        -- or iterated, and/or the isFullUpdate flag itself is a secret boolean
        -- that would throw under the boolean test below (which is why this
        -- branch MUST run before that test). Promote to a full-update
        -- sentinel; consumers gate their scans.
        pendingUnits[unit] = true
    elseif updateInfo and updateInfo.isFullUpdate then
        pendingUnits[unit] = true
    elseif not updateInfo then
        pendingUnits[unit] = true
    elseif existing then
        -- Multiple deltas for same unit in one frame — merge instead of full scan.
        -- This preserves the incremental path downstream which avoids expensive
        -- C_UnitAuras.GetUnitAuras calls (20+ per cycle in a raid).
        local merged = GetMergedInfo(unit)
        if type(existing) == "table" and not existing._isMerged then
            -- First merge: copy existing delta into accumulator
            wipe(merged.addedAuras)
            wipe(merged.removedAuraInstanceIDs)
            wipe(merged.updatedAuraInstanceIDs)
            merged._isMerged = true
            AccumulateDelta(merged, existing)
        end
        AccumulateDelta(merged, updateInfo)
        pendingUnits[unit] = merged
    else
        pendingUnits[unit] = updateInfo
    end
    coalesceFrame:Show()
end

---------------------------------------------------------------------------
-- ROSTER UNIT REGISTRATION
---------------------------------------------------------------------------
local rosterFrames = {}
for unit in pairs(rosterUnits) do
    local f = CreateFrame("Frame")
    f:RegisterUnitEvent("UNIT_AURA", unit)
    -- 68569: the whole payload (including the unit arg itself) can be secret
    -- while auras are restricted. RegisterUnitEvent already filters this
    -- frame to fire only for `unit` -- that registered token is the only
    -- trusted unit identity here. The payload's own unit arg is never read.
    f:SetScript("OnEvent", function(_, _, _, updateInfo)
        QueueAuraEvent(unit, updateInfo)
    end)
    rosterFrames[unit] = f
end

---------------------------------------------------------------------------
-- NAMEPLATE UNIT REGISTRATION (lazy)
--
-- 40 per-unit frames mirroring the roster pattern, created on the first
-- "nameplate" Subscribe so the tier is free until a consumer exists.
-- Deliberately NOT folded into IsNonRosterEventInteresting: extending the
-- predicate would put a Lua call on the global UNIT_AURA hot path and fan
-- nameplate events out to every "all" subscriber.
---------------------------------------------------------------------------
local nameplateFrames = nil
EnsureNameplateFrames = function()
    if nameplateFrames then return end
    nameplateFrames = {}
    for unit in pairs(nameplateUnits) do
        local f = CreateFrame("Frame")
        f:RegisterUnitEvent("UNIT_AURA", unit)
        -- Same trusted-token contract as the roster frames: only the
        -- registered token identifies the unit; payload args are not read.
        f:SetScript("OnEvent", function(_, _, _, updateInfo)
            QueueAuraEvent(unit, updateInfo)
        end)
        nameplateFrames[unit] = f
    end
end

---------------------------------------------------------------------------
-- NON-ROSTER REGISTRATION
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:SetScript("OnEvent", function(self, event, unit, updateInfo)
    -- 68569: a secret unit token cannot be identified -- restricted
    -- global-unit discovery is dropped by design; the post-restriction
    -- rescan (Task 3) covers the gap. Probe FIRST, before any other check
    -- (including IsNonRosterEventInteresting's InCombatLockdown/tooltip
    -- work) touches the unit.
    if issecretvalue and issecretvalue(unit) then
        return
    end
    if rosterUnits[unit] then
        return
    end
    if nameplateUnits[unit] then
        -- The "all" tier keeps its narrow contract for nameplate units.
        if IsNonRosterEventInteresting(unit) then
            pendingAllEligible[unit] = true
            if nameplateFrames then
                -- Dedicated frame queues this same event — queueing here too
                -- would double the merged deltas.
                coalesceFrame:Show()
            else
                QueueAuraEvent(unit, updateInfo)
            end
        end
        return
    end
    if not IsNonRosterEventInteresting(unit) then
        return
    end
    QueueAuraEvent(unit, updateInfo)
end)

---------------------------------------------------------------------------
-- RESTRICTION LIFT: while auras are restricted the router intentionally
-- drops non-roster discovery (NON-ROSTER REGISTRATION above) and delivers
-- opaque full-update sentinels for roster units instead of deltas
-- (QueueAuraEvent's issecretvalue/PayloadIsSecret branches). A unit whose
-- auras don't change again while restricted never gets a follow-up
-- UNIT_AURA to resync it once the restriction lifts. Poke every roster
-- unit + target with a full-update sentinel on lift so consumers converge
-- via their normal (unit, nil) full-rescan path -- no new consumer API.
--
-- 68569: no dedicated "aura restrictions changed" event exists in the local
-- docs. ADDON_RESTRICTION_STATE_CHANGED (RestrictedActionsDocumentation.lua)
-- is the closest thing to one and is used ALONE (no fallback stack needed):
--   Name = "AddonRestrictionStateChanged", LiteralName = "ADDON_RESTRICTION_STATE_CHANGED"
--   Documentation = { "Fired when the state of an addon restriction type is
--     changing. This event is sequenced such that it will always be fired
--     before a restriction becomes active, or after it is deactivated." }
-- It fires for EVERY AddOnRestrictionType (Combat/Encounter/ChallengeMode/
-- PvPMatch/Map/Chat), which is a superset of what can drive aura secrecy --
-- SecretPredicatesDocumentation.lua's SecretWhenAurasRestricted: "Guarded
-- APIs and events produce secret values when combat, encounter, challenge
-- mode, or PvP match addon restrictions are in effect." One registration
-- covers all of those transitions; C_Secrets.ShouldAurasBeSecret() (not the
-- event payload) is the actual gate below, since the event only says
-- something changed, not whether auras specifically are affected or which
-- direction -- so every firing is treated as "maybe lifted" and the real
-- answer is read live.
---------------------------------------------------------------------------
local liftFrame = CreateFrame("Frame")
liftFrame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
liftFrame:SetScript("OnEvent", function()
    local C_Secrets = _G.C_Secrets
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        return -- still restricted; a later lift event will land it
    end
    for unit in pairs(rosterUnits) do
        QueueAuraEvent(unit, nil)
    end
    QueueAuraEvent("target", nil)
end)

-- Perf profiler opt-in: coalesceFrame.OnUpdate runs the aura subscriber fan-out
-- (group frames, CDM, raidbuffs, atonement, etc). Wrapping it measures total
-- aura dispatch cost as one "AuraDispatch" line.
local function SetupDebugInstrumentation()
    local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "AuraEvt_mergedInfoPool", tbl = mergedInfoPool } -- AuraEvt_mergedInfoPool memprobe anchor
    ns.QUI_PerfRegistry = ns.QUI_PerfRegistry or {}
    ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "AuraDispatch", frame = coalesceFrame, scriptType = "OnUpdate" }
    ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "AuraRouter", frame = eventFrame }
end
if ns.DebugRegister then -- gate contract: core/debug_gate.lua
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation() -- standalone test harness: no gate, run eagerly
end
