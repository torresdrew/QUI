--[[
    QUI Aura Instance/Encounter Context

    Tracker for the current instance (raid/dungeon) mapID AND the currently-
    pulled encounter (boss) id, exposed as two optional cascade rungs:
    `E.EncounterBucketKey` (tried FIRST — a boss delta) then
    `E.InstanceBucketKey` (the instance delta), both ahead of specID in
    `E.ActiveElementsForSpec`'s bucket resolution. Group-frame aura render is
    pull-based (it re-resolves the active element list every render pass), so
    this module only needs to (a) know the current keys and (b) nudge a refresh
    when either changes -- it never touches aura data itself.

    Instance key: zone events fire OOC, so the refresh is deferred to
    PLAYER_REGEN_ENABLED in the (unexpected) combat case. Encounter key:
    ENCOUNTER_START/_END fire IN combat by design -- the whole point is applying
    a boss delta on pull. That refresh runs LIVE regardless of lockdown because
    the downstream render pass is combat-split: candidateFilter mutation on an
    already-registered aura group is combat-legal (SetAuraGroupCandidateFilters),
    and any group that would need CREATION self-heals via the OOC replay queue.
]]

local ADDON_NAME, ns = ...

local AC = {}
ns.QUI_AuraContext = AC

-- Cached "i"..mapID key (or nil when not in an instance); pendingRefresh is
-- set if a key change is ever observed while (unexpectedly) in combat, and
-- flushed on the next PLAYER_REGEN_ENABLED.
local cachedKey
local pendingRefresh = false
-- Cached "e"..encounterID key (or nil when no boss is pulled).
local cachedEncounterKey

-- Combat-SAFE aura-only refresh across EVERY surface that resolves the cascade
-- (group frames, unit frames, action-bar buff borders). Each surface's entry is
-- itself combat-split -- OOC it runs the full pass; in combat it applies the
-- candidateFilter mutation subset live and queues any forbidden creation for
-- PLAYER_REGEN_ENABLED. Safe to call from OOC (zone) AND in-combat (encounter)
-- events alike, so both context changes route through this one driver.
-- Entries are published on the shared suite `ns` by each surface addon (not _G,
-- per the global-assignment ratchet); absent entries (surface not loaded) skip.
local function RefreshAuraSurfaces()
    if ns.QUI_RefreshGroupFrameAuras then ns.QUI_RefreshGroupFrameAuras() end
    if ns.QUI_RefreshUnitFrameAuras then ns.QUI_RefreshUnitFrameAuras() end
    if ns.QUI_RefreshBuffBorderAuras then ns.QUI_RefreshBuffBorderAuras() end
end

-- PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA handler. Both fire OOC; the
-- combat-split entries do the full pass there. pendingRefresh survives the
-- (unexpected) in-combat case to the next PLAYER_REGEN_ENABLED.
local function OnZoneContextEvent()
    local inInst = IsInInstance()
    local mapID = inInst and GetBestMapForUnit and GetBestMapForUnit("player") or nil
    local newKey = ns.AuraElements.InstanceBucketKey(mapID)
    if newKey ~= cachedKey then
        cachedKey = newKey
        if not InCombatLockdown() then
            RefreshAuraSurfaces()
        else
            pendingRefresh = true
        end
    end
end

local function OnRegenEnabled()
    if pendingRefresh then
        pendingRefresh = false
        RefreshAuraSurfaces()
    end
end

-- ENCOUNTER_START(encounterID) / ENCOUNTER_END(encounterID). Both fire IN
-- combat; the refresh runs live (see file header) so the boss delta lands on
-- pull. ENCOUNTER_END clears back to the instance/spec bucket.
local function OnEncounterStart(encounterID)
    local newKey = ns.AuraElements.EncounterBucketKey(encounterID)
    if newKey ~= cachedEncounterKey then
        cachedEncounterKey = newKey
        RefreshAuraSurfaces()
    end
end

local function OnEncounterEnd()
    if cachedEncounterKey ~= nil then
        cachedEncounterKey = nil
        RefreshAuraSurfaces()
    end
end

-- Guarded so this module loads without error under the headless lua5.1 test
-- harness (WoW globals may be absent outside it).
if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("ENCOUNTER_START")
    f:RegisterEvent("ENCOUNTER_END")
    -- Spec swap: per-spec buckets re-resolve AND compiled candidateFilters
    -- that depend on the player's capabilities (dispelTypes="mine" sentinel)
    -- recompile. The surface entries are combat-split, so firing this live
    -- is safe (loadout swaps can land near combat edges).
    f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "PLAYER_REGEN_ENABLED" then
            OnRegenEnabled()
        elseif event == "ENCOUNTER_START" then
            OnEncounterStart(arg1)
        elseif event == "ENCOUNTER_END" then
            OnEncounterEnd()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            if arg1 == "player" or arg1 == nil then
                RefreshAuraSurfaces()
            end
        else
            OnZoneContextEvent()
        end
    end)
end

-- Current instance bucket key ("i"..mapID) or nil when not in an instance
-- (or before the first PEW/zone event has landed).
function AC.InstanceKey()
    return cachedKey
end

-- Current encounter bucket key ("e"..encounterID) or nil when no boss pulled.
function AC.EncounterKey()
    return cachedEncounterKey
end

-- Fill `scratch` (a caller-owned reusable array) with the active cascade keys
-- in priority order (encounter first, then instance), compacted so there are no
-- nil holes (ipairs stops at the first nil). Returns `scratch` when it holds at
-- least one key, else nil so callers can pass it straight to ActiveElementsForSpec.
function AC.FillContextKeys(scratch)
    local n = 0
    if cachedEncounterKey ~= nil then n = n + 1; scratch[n] = cachedEncounterKey end
    if cachedKey ~= nil then n = n + 1; scratch[n] = cachedKey end
    for i = #scratch, n + 1, -1 do scratch[i] = nil end
    if n == 0 then return nil end
    return scratch
end

return AC
