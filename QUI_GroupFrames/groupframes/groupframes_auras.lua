--[[
    QUI Group Frames - Aura System
    Compact aura display for group frames with priority filtering,
    table pooling, shared aura timer, and duration color coding.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local IsSecretValue = Helpers.IsSecretValue
local SafeValue = Helpers.SafeValue
local SafeToNumber = Helpers.SafeToNumber
local GetDB = Helpers.CreateDBGetter("quiGroupFrames")
local AuraModel = ns.QUI_GroupFramesAuraModel
-- Unified element renderer (groupframes_aura_render.lua). Resolved lazily at
-- render time via GetRender() so file load order can't matter.
local function GetRender() return ns.QUI_GroupFrameAuraRender end

-- The shipped default strip bucket lives in the model shim (always loaded,
-- TOC line above this file) — NOT Options-side: E.EnsureSeeded LATCHES
-- elementsSeeded after seeding, so an Options-only bucket would let an
-- Options-disabled install latch an EMPTY "*" bucket and permanently lose
-- the shipped strips.
local function DefaultStripBucket()
    return AuraModel.DefaultStripBucket()
end

-- Upvalue hot-path globals
local pairs = pairs
local ipairs = ipairs
local type = type
local wipe = wipe
local C_UnitAuras = C_UnitAuras
local table_remove = table.remove

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_GFA = {}
ns.QUI_GroupFrameAuras = QUI_GFA

---------------------------------------------------------------------------
-- ELEMENT-MODEL GLUE
---------------------------------------------------------------------------

-- CONTAINER CUTOVER: the generic buff/debuff STRIP display AND the tracked
-- ICON/SQUARE/BAR display render on Blizzard's secure per-unit
-- CustomAuraContainer — one container PER active element (see the LIVE AURA
-- CONTAINERS section below; tracked rides AddAuraSlot via core/aura_slots.lua).
-- The v46 element engine renderer now emits ONLY:
--   * `missingRaidBuff` — Missing Raid Buffs synthetic icons (unchanged), and
--   * `tracked` with displayType == "healthTint" — the health-bar tint feeder
--     consumed by R.RenderHealthTint / R.SyncHealthBarTint (unchanged).
-- EngineRendersElement is the single gate every engine consumer below routes
-- through, so the container/renderer split stays in one place and MRB + tint
-- keep flowing through the (untouched) renderer.
local function EngineRendersElement(element)
    if not element then return false end
    local mode = element.mode
    if mode == "missingRaidBuff" then return true end
    if mode == "tracked" and element.displayType == "healthTint" then return true end
    -- filterStrip + tracked icon/square/bar => secure CustomAuraContainer.
    return false
end
QUI_GFA.EngineRendersElement = EngineRendersElement

-- Build render work for one unit frame from the unified element model.
-- specID: the unit's active spec (or nil). cache: that unit's unitAuraCache entry.
-- Returns a list of { element = <element>, matches = <table|nil> } for the renderer.
local function BuildElementRenderList(auras, specID, cache)
    local work = {}
    if not auras then return work end
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras, DefaultStripBucket) end
    if auras.enabled == false then return work end
    local elements = AuraModel.ActiveElementsForSpec(auras, specID)
    for _, element in ipairs(elements) do
        -- Strips (now container-driven) and dropped tracked displays are skipped;
        -- only MRB + the healthTint feeder reach the renderer.
        if EngineRendersElement(element) then
            local matches
            if element.mode == "tracked" then
                matches = AuraModel.PopulateElementMatches(element, cache)
            end
            work[#work + 1] = { element = element, matches = matches }
        end
    end
    return work
end
QUI_GFA.BuildElementRenderList = BuildElementRenderList

---------------------------------------------------------------------------
-- SHARED AURA CACHE: One authoritative per-unit aura state for group frames
---------------------------------------------------------------------------
-- Populated once per throttle window, read by all consumers. All
-- classification, filtering, and sorting work happens here at delta time so
-- frame render is a trivial walk over pre-computed subsets.
--
-- Structure: unitAuraCache[unit] = {
--     -- Raw aura arrays (single source of truth)
--     buffs                  = {auraData...},
--     debuffs                = {auraData...},
--     -- Instance-ID-keyed lookups (used by render-time map probes)
--     buffsByID              = { [instID] = auraData },
--     debuffsByID            = { [instID] = auraData },
--     buffsIndexByID         = { [instID] = arrayIndex },
--     debuffsIndexByID       = { [instID] = arrayIndex },
--     buffsBySpellID         = { [spellID] = auraData },
--     debuffsBySpellID       = { [spellID] = auraData },
--     buffsByName            = { [spellName] = auraData },
--     debuffsByName          = { [spellName] = auraData },
--     -- Pre-classified subsets — render walks the orders / probes the sets
--     playerDispellable      = { [instID] = true },     -- player can dispel
--     playerDispellableOrder = { instID, ... },
--     allDispellable         = { [instID] = true },     -- anyone can dispel (any dispelName)
--     defensives             = { [instID] = true },     -- matches defensive classifier
--     defensiveOrder         = { instID, ... },
--     -- Bookkeeping
--     hasFullScan            = boolean,
-- }
--
-- Full scans rebuild the entire structure; UNIT_AURA deltas patch it
-- incrementally and re-run the rebuilders for any side that changed.
local unitAuraCache = {}
local auraStats -- debug counters; nil until QUI_Debug activates instrumentation
local function SetupDebugInstrumentation()
    auraStats = {
        fullScans = 0,
        slotScans = 0,
        legacyScans = 0,
        deltaApplied = 0,
        deltaFallback = 0,
        fastUpdates = 0,
        fullUpdateEvents = 0,
        deltaAddedAuras = 0,
        deltaRemovedAuras = 0,
        deltaUpdatedIDs = 0,
        deltaUpdatedSkipped = 0,
        deltaFreshFetches = 0,
        deltaMixedDeltas = 0,
        mixedIconRefreshes = 0,
        panelBuffRebuilds = 0,
        panelDebuffRebuilds = 0,
        panelBuffIncrementalAttempts = 0,
        panelBuffIncremental = 0,
        panelBuffIncrementalDirtySkip = 0,
        panelBuffIncrementalFilterSkip = 0,
        panelBuffIncrementalChanged = 0,
        panelBuffIncrementalNoop = 0,
        defensiveSetChanges = 0,
        curatedMatchRefreshes = 0,
        indicatorMatchChanges = 0,
        pinnedMatchChanges = 0,
        indicatorFrameRefreshes = 0,
        indicatorFrameSkips = 0,
        pinnedFrameRefreshes = 0,
        pinnedFrameSkips = 0,
        panelFrameRefreshes = 0,
        panelFrameSkips = 0,
        panelFrameDisplaySkips = 0,
        panelNoDisplay = 0,
        panelIconUpdates = 0,
        panelIconSkips = 0,
        noConsumerSkips = 0,
        framesRefreshed = 0,
        -- Dirty-flag + storm-budget effectiveness (this rework).
        heavyDeferred = 0,     -- units bumped to the drain queue (budget overflow)
        drainProcessed = 0,    -- units processed by the drain ticker
        frameSkips = 0,        -- whole frames skipped by DeltaTouchesFrame
        elementSkips = 0,      -- elements skipped by the per-element dirty gate
        elementsDispatched = 0,-- elements that actually re-dispatched (skip ratio denom)
    }
    local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "GF_unitAuraCache", tbl = unitAuraCache }
    mp[#mp + 1] = { name = "GF_auraFullScans", fn = function() return auraStats.fullScans end, counter = true }
    mp[#mp + 1] = { name = "GF_auraSlotScans", fn = function() return auraStats.slotScans end, counter = true }
    mp[#mp + 1] = { name = "GF_auraLegacyScans", fn = function() return auraStats.legacyScans end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDeltaApplied", fn = function() return auraStats.deltaApplied end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDeltaFallback", fn = function() return auraStats.deltaFallback end, counter = true }
    mp[#mp + 1] = { name = "GF_auraFastUpdates", fn = function() return auraStats.fastUpdates end, counter = true }
    mp[#mp + 1] = { name = "GF_auraFullUpdateEvents", fn = function() return auraStats.fullUpdateEvents end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDeltaAdded", fn = function() return auraStats.deltaAddedAuras end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDeltaRemoved", fn = function() return auraStats.deltaRemovedAuras end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDeltaUpdated", fn = function() return auraStats.deltaUpdatedIDs end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDeltaUpdatedSkipped", fn = function() return auraStats.deltaUpdatedSkipped end, counter = true }
    mp[#mp + 1] = { name = "GF_auraFreshFetches", fn = function() return auraStats.deltaFreshFetches end, counter = true }
    mp[#mp + 1] = { name = "GF_auraMixedDeltas", fn = function() return auraStats.deltaMixedDeltas end, counter = true }
    mp[#mp + 1] = { name = "GF_auraMixedIconRefreshes", fn = function() return auraStats.mixedIconRefreshes end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffRebuilds", fn = function() return auraStats.panelBuffRebuilds end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelDebuffRebuilds", fn = function() return auraStats.panelDebuffRebuilds end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffIncAttempts", fn = function() return auraStats.panelBuffIncrementalAttempts end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffIncremental", fn = function() return auraStats.panelBuffIncremental end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffIncDirtySkip", fn = function() return auraStats.panelBuffIncrementalDirtySkip end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffIncFilterSkip", fn = function() return auraStats.panelBuffIncrementalFilterSkip end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffChanges", fn = function() return auraStats.panelBuffIncrementalChanged end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelBuffNoops", fn = function() return auraStats.panelBuffIncrementalNoop end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDefensiveSetChanges", fn = function() return auraStats.defensiveSetChanges end, counter = true }
    mp[#mp + 1] = { name = "GF_auraCuratedRefreshes", fn = function() return auraStats.curatedMatchRefreshes end, counter = true }
    mp[#mp + 1] = { name = "GF_auraIndicatorMatchChanges", fn = function() return auraStats.indicatorMatchChanges end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPinnedMatchChanges", fn = function() return auraStats.pinnedMatchChanges end, counter = true }
    mp[#mp + 1] = { name = "GF_auraIndicatorRefreshes", fn = function() return auraStats.indicatorFrameRefreshes end, counter = true }
    mp[#mp + 1] = { name = "GF_auraIndicatorRefreshSkips", fn = function() return auraStats.indicatorFrameSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPinnedRefreshes", fn = function() return auraStats.pinnedFrameRefreshes end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPinnedRefreshSkips", fn = function() return auraStats.pinnedFrameSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelRefreshes", fn = function() return auraStats.panelFrameRefreshes end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelRefreshSkips", fn = function() return auraStats.panelFrameSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelDisplaySkips", fn = function() return auraStats.panelFrameDisplaySkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelNoDisplay", fn = function() return auraStats.panelNoDisplay end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelIconUpdates", fn = function() return auraStats.panelIconUpdates end, counter = true }
    mp[#mp + 1] = { name = "GF_auraPanelIconSkips", fn = function() return auraStats.panelIconSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraNoConsumerSkips", fn = function() return auraStats.noConsumerSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraFramesRefreshed", fn = function() return auraStats.framesRefreshed end, counter = true }
    mp[#mp + 1] = { name = "GF_auraHeavyDeferred", fn = function() return auraStats.heavyDeferred end, counter = true }
    mp[#mp + 1] = { name = "GF_auraDrainProcessed", fn = function() return auraStats.drainProcessed end, counter = true }
    mp[#mp + 1] = { name = "GF_auraFrameSkips", fn = function() return auraStats.frameSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraElementSkips", fn = function() return auraStats.elementSkips end, counter = true }
    mp[#mp + 1] = { name = "GF_auraElementsDispatched", fn = function() return auraStats.elementsDispatched end, counter = true }
    QUI_GFA.auraStats = auraStats -- debug export tracks the live table (nil until activation)
end
if ns.DebugRegister then -- gate contract: core/debug_gate.lua
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation() -- standalone test harness: no gate, run eagerly
end

local DISPEL_FILTER = "HARMFUL|RAID_PLAYER_DISPELLABLE"
local MAX_SCAN_AURAS = 40

-- Classify a single harmful aura as dispellable by the current player.
-- Returns true/false; returns nil when the API is unavailable.
-- No pcall — IsAuraFilteredOutByInstanceID is C-side, returns nil on error.
local IsAuraFilteredOut = C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID
local GetAuraSlots = C_UnitAuras and C_UnitAuras.GetAuraSlots
local GetAuraDataBySlot = C_UnitAuras and C_UnitAuras.GetAuraDataBySlot

-- 12.1: the index/slot aura getters above (GetAuraSlots/GetAuraDataBySlot) and
-- C_UnitAuras.GetUnitAuras all THROW while aura data is secret. ShouldAurasBeSecret
-- is the global gate — true in combat when auras are restricted — so the full scan
-- skips (cache freezes) rather than erroring.
local C_Secrets = C_Secrets
local function AurasAreSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

local function ClassifyDispellable(unit, instID)
    if not instID or IsSecretValue(instID) then return nil end
    if not IsAuraFilteredOut then return nil end
    local filteredOut = IsAuraFilteredOut(unit, instID, DISPEL_FILTER)
    if filteredOut == nil or IsSecretValue(filteredOut) then return nil end
    return filteredOut == false
end

-- Classify a single helpful aura as a verified defensive (big or external).
-- Delegates to the groupframes.lua classifier which owns the spell-ID fast
-- path and the BigDefensive/ExternalDefensive filter cache.
local function ClassifyDefensive(unit, auraData)
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.IsVerifiedDefensiveAura then return false end
    return GF.IsVerifiedDefensiveAura(unit, auraData) == true
end

local function CreateAuraCacheEntry()
    return {
        -- Raw aura arrays (single source of truth)
        buffs = {},
        debuffs = {},
        -- Instance-ID-keyed lookups
        buffsByID = {},
        debuffsByID = {},
        buffsIndexByID = {},
        debuffsIndexByID = {},
        buffsBySpellID = {},
        debuffsBySpellID = {},
        buffsByName = {},
        debuffsByName = {},
        -- Pre-classified subsets maintained by the rebuilders
        playerDispellable = {},
        playerDispellableOrder = {},
        allDispellable = {},
        defensives = {},
        defensiveOrder = {},
        -- Bookkeeping
        defensiveSetChanged = true,
        hasFullScan = false,
    }
end

local function EnsureAuraCache(unit)
    local cache = unitAuraCache[unit]
    if cache then
        return cache
    end
    cache = CreateAuraCacheEntry()
    unitAuraCache[unit] = cache
    return cache
end

local function ResetAuraCache(cache)
    wipe(cache.buffs)
    wipe(cache.debuffs)
    wipe(cache.buffsByID)
    wipe(cache.debuffsByID)
    wipe(cache.buffsIndexByID)
    wipe(cache.debuffsIndexByID)
    wipe(cache.buffsBySpellID)
    wipe(cache.debuffsBySpellID)
    wipe(cache.buffsByName)
    wipe(cache.debuffsByName)
    wipe(cache.playerDispellable)
    wipe(cache.playerDispellableOrder)
    wipe(cache.allDispellable)
    wipe(cache.defensives)
    wipe(cache.defensiveOrder)
    cache.defensiveSetChanged = true
    cache.hasFullScan = false
end

local function RebuildBuffMaps(unit, cache)
    wipe(cache.buffsByID)
    wipe(cache.buffsIndexByID)
    wipe(cache.buffsBySpellID)
    wipe(cache.buffsByName)
    wipe(cache.defensives)
    wipe(cache.defensiveOrder)

    local buffs = cache.buffs
    local buffsByID = cache.buffsByID
    local buffsIndexByID = cache.buffsIndexByID
    local buffsBySpellID = cache.buffsBySpellID
    local buffsByName = cache.buffsByName
    local defensives = cache.defensives
    local defensiveOrder = cache.defensiveOrder

    for i = 1, #buffs do
        local auraData = buffs[i]
        local instID = auraData and auraData.auraInstanceID
        if instID then
            buffsByID[instID] = auraData
            buffsIndexByID[instID] = i
            if ClassifyDefensive(unit, auraData) then
                defensives[instID] = true
                defensiveOrder[#defensiveOrder + 1] = instID
            end
        end

        local spellID = SafeValue(auraData and auraData.spellId, nil)
        if spellID then
            buffsBySpellID[spellID] = auraData
        end

        local spellName = SafeValue(auraData and auraData.name, nil)
        if spellName then
            buffsByName[spellName] = auraData
        end
    end
end

local function RebuildDebuffMaps(unit, cache)
    wipe(cache.debuffsByID)
    wipe(cache.debuffsIndexByID)
    wipe(cache.debuffsBySpellID)
    wipe(cache.debuffsByName)
    wipe(cache.playerDispellable)
    wipe(cache.playerDispellableOrder)
    wipe(cache.allDispellable)

    local debuffs = cache.debuffs
    local debuffsByID = cache.debuffsByID
    local debuffsIndexByID = cache.debuffsIndexByID
    local debuffsBySpellID = cache.debuffsBySpellID
    local debuffsByName = cache.debuffsByName
    local playerDispellable = cache.playerDispellable
    local playerDispellableOrder = cache.playerDispellableOrder
    local allDispellable = cache.allDispellable

    for i = 1, #debuffs do
        local auraData = debuffs[i]
        local instID = auraData and auraData.auraInstanceID
        if instID then
            debuffsByID[instID] = auraData
            debuffsIndexByID[instID] = i

            local dispelName = auraData.dispelName
            local hasDispelType = dispelName ~= nil and not IsSecretValue(dispelName)
            if hasDispelType then
                allDispellable[instID] = true
            end

            local classified = ClassifyDispellable(unit, instID)
            if classified == true or (classified == nil and hasDispelType) then
                playerDispellable[instID] = true
                playerDispellableOrder[#playerDispellableOrder + 1] = instID
            end
        end

        local spellID = SafeValue(auraData and auraData.spellId, nil)
        if spellID then
            debuffsBySpellID[spellID] = auraData
        end

        local spellName = SafeValue(auraData and auraData.name, nil)
        if spellName then
            debuffsByName[spellName] = auraData
        end
    end
end

local function ResolveAuraBucket(unit, auraData)
    if not auraData then return nil end

    local instID = auraData.auraInstanceID
    if instID and IsAuraFilteredOut then
        local buffFiltered = IsAuraFilteredOut(unit, instID, "HELPFUL")
        if buffFiltered ~= nil and not IsSecretValue(buffFiltered) then
            if buffFiltered == false then
                return "buffs"
            end
            local debuffFiltered = IsAuraFilteredOut(unit, instID, "HARMFUL")
            if debuffFiltered ~= nil and not IsSecretValue(debuffFiltered) then
                if debuffFiltered == false then
                    return "debuffs"
                end
            end
        end
    end

    local isHelpful = SafeValue(auraData.isHelpful, nil)
    if isHelpful == true then
        return "buffs"
    end

    local isHarmful = SafeValue(auraData.isHarmful, nil)
    if isHarmful == true then
        return "debuffs"
    end

    return nil
end

local function RefreshSpellIDLookupAfterRemoval(bucket, lookup, spellID)
    if not spellID or not lookup then return end
    lookup[spellID] = nil
    for i = 1, #bucket do
        local auraData = bucket[i]
        if SafeValue(auraData and auraData.spellId, nil) == spellID then
            lookup[spellID] = auraData
        end
    end
end

local function RefreshSpellNameLookupAfterRemoval(bucket, lookup, spellName)
    if not spellName or not lookup then return end
    lookup[spellName] = nil
    for i = 1, #bucket do
        local auraData = bucket[i]
        if SafeValue(auraData and auraData.name, nil) == spellName then
            lookup[spellName] = auraData
        end
    end
end

local function RemoveIDFromOrder(order, instID)
    if not order then return end
    for i = 1, #order do
        if order[i] == instID then
            table_remove(order, i)
            return
        end
    end
end

local function AddBuffDerivedData(unit, cache, auraData)
    local instID = auraData and auraData.auraInstanceID
    if not instID then return end

    local spellID = SafeValue(auraData.spellId, nil)
    if spellID then
        cache.buffsBySpellID[spellID] = auraData
    end

    local spellName = SafeValue(auraData.name, nil)
    if spellName then
        cache.buffsByName[spellName] = auraData
    end

    if ClassifyDefensive(unit, auraData) then
        -- Append to the order array only when the set didn't already hold the
        -- instID, so defensiveOrder stays a faithful dedup mirror of defensives.
        -- An unconditional append could push a second copy whose single
        -- RemoveIDFromOrder on removal leaves a phantom (see UpdateDispelOverlay).
        if not cache.defensives[instID] then
            cache.defensiveOrder[#cache.defensiveOrder + 1] = instID
        end
        cache.defensives[instID] = true
        return true
    end
    return false
end

local function RemoveBuffDerivedData(cache, auraData, instID)
    if not auraData or not instID then return false end
    local defensiveChanged = cache.defensives[instID] == true

    local spellID = SafeValue(auraData.spellId, nil)
    if spellID and cache.buffsBySpellID[spellID] == auraData then
        RefreshSpellIDLookupAfterRemoval(cache.buffs, cache.buffsBySpellID, spellID)
    end

    local spellName = SafeValue(auraData.name, nil)
    if spellName and cache.buffsByName[spellName] == auraData then
        RefreshSpellNameLookupAfterRemoval(cache.buffs, cache.buffsByName, spellName)
    end

    cache.defensives[instID] = nil
    RemoveIDFromOrder(cache.defensiveOrder, instID)
    return defensiveChanged
end

local function AddDebuffDerivedData(unit, cache, auraData)
    local instID = auraData and auraData.auraInstanceID
    if not instID then return end

    local dispelName = auraData.dispelName
    local hasDispelType = dispelName ~= nil and not IsSecretValue(dispelName)
    if hasDispelType then
        cache.allDispellable[instID] = true
    end

    local classified = ClassifyDispellable(unit, instID)
    if classified == true or (classified == nil and hasDispelType) then
        -- Dedup-guard the order append against the set so playerDispellableOrder
        -- stays a faithful mirror of playerDispellable; an unconditional append
        -- can leave a phantom that RemoveIDFromOrder (first-match) won't fully
        -- clear, keeping the dispel overlay lit after the debuff is gone.
        if not cache.playerDispellable[instID] then
            cache.playerDispellableOrder[#cache.playerDispellableOrder + 1] = instID
        end
        cache.playerDispellable[instID] = true
    end

    local spellID = SafeValue(auraData.spellId, nil)
    if spellID then
        cache.debuffsBySpellID[spellID] = auraData
    end

    local spellName = SafeValue(auraData.name, nil)
    if spellName then
        cache.debuffsByName[spellName] = auraData
    end
end

local function RemoveDebuffDerivedData(cache, auraData, instID)
    if not auraData or not instID then return end

    local spellID = SafeValue(auraData.spellId, nil)
    if spellID and cache.debuffsBySpellID[spellID] == auraData then
        RefreshSpellIDLookupAfterRemoval(cache.debuffs, cache.debuffsBySpellID, spellID)
    end

    local spellName = SafeValue(auraData.name, nil)
    if spellName and cache.debuffsByName[spellName] == auraData then
        RefreshSpellNameLookupAfterRemoval(cache.debuffs, cache.debuffsByName, spellName)
    end

    cache.playerDispellable[instID] = nil
    cache.allDispellable[instID] = nil
    RemoveIDFromOrder(cache.playerDispellableOrder, instID)
end

local function AppendAuraToBucket(unit, cache, bucketName, auraData)
    local bucket = bucketName == "buffs" and cache.buffs or cache.debuffs
    local byID = bucketName == "buffs" and cache.buffsByID or cache.debuffsByID
    local indexByID = bucketName == "buffs" and cache.buffsIndexByID or cache.debuffsIndexByID
    local instID = auraData and auraData.auraInstanceID

    -- Idempotent re-add: a duplicate addedAuras entry (or an add for an
    -- already-cached instance with no intervening remove) must overwrite in
    -- place, NOT append. Re-appending would push a second copy of instID into
    -- the dedup ORDER arrays (playerDispellableOrder / defensiveOrder) whose
    -- set guards already hold it; a single RemoveIDFromOrder on removal then
    -- strips only one, leaving a phantom that keeps the dispel overlay /
    -- defensive indicator lit after the aura is gone.
    if instID and byID[instID] then
        local idx = indexByID[instID]
        if idx then bucket[idx] = auraData end
        byID[instID] = auraData
        return
    end

    bucket[#bucket + 1] = auraData
    if not instID then
        return
    end

    if bucketName == "buffs" then
        cache.buffsByID[instID] = auraData
        cache.buffsIndexByID[instID] = #bucket
        return AddBuffDerivedData(unit, cache, auraData)
    else
        cache.debuffsByID[instID] = auraData
        cache.debuffsIndexByID[instID] = #bucket
        AddDebuffDerivedData(unit, cache, auraData)
    end
end

local function RemoveAuraFromBucket(cache, bucketName, instID)
    local bucket, indexMap, byInstanceID
    if bucketName == "buffs" then
        bucket = cache.buffs
        indexMap = cache.buffsIndexByID
        byInstanceID = cache.buffsByID
    else
        bucket = cache.debuffs
        indexMap = cache.debuffsIndexByID
        byInstanceID = cache.debuffsByID
    end

    local idx = indexMap[instID]
    if not idx then
        return false
    end

    local oldAura = byInstanceID[instID]
    table_remove(bucket, idx)
    indexMap[instID] = nil
    byInstanceID[instID] = nil

    for i = idx, #bucket do
        local auraData = bucket[i]
        local auraInstID = auraData and auraData.auraInstanceID
        if auraInstID then
            indexMap[auraInstID] = i
        end
    end

    if bucketName == "buffs" then
        return true, RemoveBuffDerivedData(cache, oldAura, instID)
    else
        RemoveDebuffDerivedData(cache, oldAura, instID)
    end

    return true
end

local function ReplaceAuraInBucket(unit, cache, bucketName, instID, auraData)
    local bucket, indexMap, byInstanceID, bySpellID, byName
    if bucketName == "buffs" then
        bucket = cache.buffs
        indexMap = cache.buffsIndexByID
        byInstanceID = cache.buffsByID
        bySpellID = cache.buffsBySpellID
        byName = cache.buffsByName
    else
        bucket = cache.debuffs
        indexMap = cache.debuffsIndexByID
        byInstanceID = cache.debuffsByID
        bySpellID = cache.debuffsBySpellID
        byName = cache.debuffsByName
    end

    local idx = indexMap[instID]
    if not idx then
        return false
    end

    -- Repoint the spellID / name maps off the OLD aura object onto the fresh one
    -- (same instance, new data after a stack/duration change). Clearing by the old
    -- key first covers the rare case where the updated aura's spellID/name differs,
    -- so the full RebuildBuffMaps/RebuildDebuffMaps on the updated path is unneeded.
    local old = bucket[idx]
    if old then
        local oldSpell = SafeValue(old.spellId, nil)
        if oldSpell and bySpellID[oldSpell] == old then bySpellID[oldSpell] = nil end
        local oldName = SafeValue(old.name, nil)
        if oldName and byName[oldName] == old then byName[oldName] = nil end
    end

    bucket[idx] = auraData
    byInstanceID[instID] = auraData
    local newSpell = SafeValue(auraData.spellId, nil)
    if newSpell then bySpellID[newSpell] = auraData end
    local newName = SafeValue(auraData.name, nil)
    if newName then byName[newName] = auraData end

    -- Defensive flip detection (buffs only): report a change only when membership
    -- actually moves, instead of forcing a defensive re-eval on every buff tick.
    local defensiveChanged = false
    if bucketName == "buffs" then
        local was = cache.defensives[instID] == true
        local isDef = ClassifyDefensive(unit, auraData) == true
        if isDef ~= was then
            defensiveChanged = true
            if isDef then
                cache.defensives[instID] = true
                cache.defensiveOrder[#cache.defensiveOrder + 1] = instID
            else
                cache.defensives[instID] = nil
                local order = cache.defensiveOrder
                for i = #order, 1, -1 do
                    if order[i] == instID then table.remove(order, i); break end
                end
            end
        end
    end

    return true, defensiveChanged
end

local function AppendSlotAuras(unit, dst, ...)
    local n = select("#", ...)
    for i = 2, n do
        local slot = select(i, ...)
        if slot then
            local auraData = GetAuraDataBySlot(unit, slot)
            if auraData and auraData.auraInstanceID then
                dst[#dst + 1] = auraData
            end
        end
    end
end

local function ScanUnitAurasBySlot(unit, cache)
    if not GetAuraSlots or not GetAuraDataBySlot then
        return false
    end

    AppendSlotAuras(unit, cache.debuffs, GetAuraSlots(unit, "HARMFUL", MAX_SCAN_AURAS))
    AppendSlotAuras(unit, cache.buffs, GetAuraSlots(unit, "HELPFUL", MAX_SCAN_AURAS))
    return true
end

local function ScanUnitAurasLegacy(unit, cache)
    local GetUnitAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras
    if not GetUnitAuras then return false end

    local debuffs = GetUnitAuras(unit, "HARMFUL", MAX_SCAN_AURAS)
    if debuffs then
        local dst = cache.debuffs
        for i = 1, #debuffs do
            dst[i] = debuffs[i]
        end
    end

    local buffs = GetUnitAuras(unit, "HELPFUL", MAX_SCAN_AURAS)
    if buffs then
        local dst = cache.buffs
        for i = 1, #buffs do
            dst[i] = buffs[i]
        end
    end
    return true
end

local function ScanUnitAuras(unit)
    local cache = EnsureAuraCache(unit)
    -- 12.1: GetAuraSlots/GetUnitAuras throw while auras are secret (combat). We
    -- can't rescan then — keep the previous cache (frozen) instead of erroring.
    -- The render fan-out still runs: MRB resolves live via DirectAuraLookup
    -- (GetUnitAura/PlayerAuraBySpellID); the healthTint feeder holds its last
    -- state until combat ends and a full scan repopulates the cache.
    if AurasAreSecret() then
        return cache
    end
    ResetAuraCache(cache)

    if auraStats then auraStats.fullScans = auraStats.fullScans + 1 end
    if ScanUnitAurasBySlot(unit, cache) then
        if auraStats then auraStats.slotScans = auraStats.slotScans + 1 end
    elseif ScanUnitAurasLegacy(unit, cache) then
        if auraStats then auraStats.legacyScans = auraStats.legacyScans + 1 end
    else
        return cache
    end

    RebuildDebuffMaps(unit, cache)
    RebuildBuffMaps(unit, cache)
    cache.hasFullScan = true
    return cache
end

-- DELTA DIRTY SUMMARY ------------------------------------------------------
-- ApplyAuraDelta publishes which aura BUCKETS changed (helpful/harmful), whether
-- the defensive set moved, and the set of spellIDs added/removed/updated, into a
-- single reusable table. The render fan-out reads it to dirty-flag frames and
-- individual elements: a frame/element whose tracked auras the delta never
-- touched skips re-dispatch entirely. Only valid when ApplyAuraDelta returns
-- true (an incremental patch); a full scan / fallback sets dirty = nil (render
-- everything). spellsUncertain = a changed aura's spellId was secret/unreadable,
-- so tracked elements must be treated as dirty (conservative, never stale).
local _deltaSummary = { helpful = false, harmful = false, defensive = false,
                        spellsUncertain = false, spells = {} }
local function ResetDeltaSummary()
    _deltaSummary.helpful = false
    _deltaSummary.harmful = false
    _deltaSummary.defensive = false
    _deltaSummary.spellsUncertain = false
    wipe(_deltaSummary.spells)
end
local function SummaryAddSpell(auraData)
    if not auraData then _deltaSummary.spellsUncertain = true; return end
    local sid = SafeValue(auraData.spellId, nil)
    if sid then
        _deltaSummary.spells[sid] = true
    else
        _deltaSummary.spellsUncertain = true
    end
end

local function ApplyAuraDelta(unit, updateInfo)
    local cache = unitAuraCache[unit]
    if not cache or not cache.hasFullScan or type(updateInfo) ~= "table" then
        return false
    end

    -- 12.1 PTR4: while auras are secret the UNIT_AURA payload is fully secret --
    -- addedAuras structs and the updated/removed instanceID arrays carry secret
    -- values (auraInstanceID/spellId/name). This delta path keys the cache maps
    -- by auraInstanceID and compares instanceIDs; a secret TABLE KEY poisons the
    -- whole map (assertsafe hard-error, per Blizzard_AuraContainerGroups
    -- CreateSecureAuraInstanceMap) and a secret == throws. We can't patch the
    -- cache safely then -- and ScanUnitAuras also freezes while secret -- so bail
    -- to the full-scan/frozen fallback (return false). No scan storm: the
    -- fallback ScanUnitAuras returns immediately at its own AurasAreSecret gate.
    if AurasAreSecret() then
        return false
    end

    ResetDeltaSummary()
    local buffsDirty = false
    local debuffsDirty = false
    cache.defensiveSetChanged = false
    local GetAuraByInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
    local nAdded = updateInfo.addedAuras and #updateInfo.addedAuras or 0
    local nRemoved = updateInfo.removedAuraInstanceIDs and #updateInfo.removedAuraInstanceIDs or 0
    local nUpdated = updateInfo.updatedAuraInstanceIDs and #updateInfo.updatedAuraInstanceIDs or 0

    -- The mixed-delta condition is intentionally repeated in the functional
    -- skipUpdatedFetches expression below; the guard body is stats-only and
    -- must never absorb functional logic.
    if auraStats then
        auraStats.deltaAddedAuras = auraStats.deltaAddedAuras + nAdded
        auraStats.deltaRemovedAuras = auraStats.deltaRemovedAuras + nRemoved
        auraStats.deltaUpdatedIDs = auraStats.deltaUpdatedIDs + nUpdated
        if nUpdated > 0 and (nAdded > 0 or nRemoved > 0) then
            auraStats.deltaMixedDeltas = auraStats.deltaMixedDeltas + 1
        end
    end
    local skipUpdatedFetches = nUpdated > 0
        and (nAdded > 0 or nRemoved > 0)
        and C_UnitAuras
        and C_UnitAuras.GetAuraDuration

    if updateInfo.addedAuras then
        for i = 1, #updateInfo.addedAuras do
            local auraData = updateInfo.addedAuras[i]
            local bucketName = ResolveAuraBucket(unit, auraData)
            if not bucketName then
                return false
            end
            local defensiveChanged = AppendAuraToBucket(unit, cache, bucketName, auraData)
            SummaryAddSpell(auraData)
            if bucketName == "buffs" then
                buffsDirty = true
                if defensiveChanged then
                    cache.defensiveSetChanged = true
                end
            else
                debuffsDirty = true
            end
        end
    end

    if updateInfo.updatedAuraInstanceIDs and #updateInfo.updatedAuraInstanceIDs > 0 then
        if skipUpdatedFetches then
            if auraStats then auraStats.deltaUpdatedSkipped = auraStats.deltaUpdatedSkipped + nUpdated end
            -- Updated instances weren't re-fetched, so their spellIDs are unknown
            -- this pass. Mark uncertain so tracked elements re-dispatch (a stack
            -- change on a tracked aura must reach its icon).
            _deltaSummary.spellsUncertain = true
        else
            if not GetAuraByInstanceID then
                return false
            end

            for i = 1, #updateInfo.updatedAuraInstanceIDs do
                local instID = updateInfo.updatedAuraInstanceIDs[i]
                local bucketName = nil
                if cache.buffsByID[instID] then
                    bucketName = "buffs"
                elseif cache.debuffsByID[instID] then
                    bucketName = "debuffs"
                end

                if bucketName then
                    if auraStats then auraStats.deltaFreshFetches = auraStats.deltaFreshFetches + 1 end
                    local freshAura = GetAuraByInstanceID(unit, instID)
                    if not freshAura then
                        return false
                    end
                    local replaced, defChanged = ReplaceAuraInBucket(unit, cache, bucketName, instID, freshAura)
                    if not replaced then
                        return false
                    end
                    SummaryAddSpell(freshAura)
                    if bucketName == "buffs" then
                        buffsDirty = true
                        if defChanged then cache.defensiveSetChanged = true end
                    else
                        debuffsDirty = true
                    end
                end
            end
        end
    end

    if updateInfo.removedAuraInstanceIDs then
        for i = 1, #updateInfo.removedAuraInstanceIDs do
            local instID = updateInfo.removedAuraInstanceIDs[i]
            -- A removed instID should live in exactly ONE bucket, but a
            -- ResolveAuraBucket flip across events (secret isHelpful/isHarmful in
            -- combat) can leave a stale copy in the other bucket. Clean BOTH so
            -- derived data (playerDispellable / defensives) can never linger and
            -- strand the dispel / defensive overlay lit after the aura is gone.
            -- Separate `if`s (not else): an instID present in both is fully purged.
            local rb = cache.buffsByID[instID]
            if rb then
                local removed, defensiveChanged = RemoveAuraFromBucket(cache, "buffs", instID)
                if removed then
                    buffsDirty = true
                    SummaryAddSpell(rb)
                    if defensiveChanged then
                        cache.defensiveSetChanged = true
                    end
                end
            end
            local rd = cache.debuffsByID[instID]
            if rd and RemoveAuraFromBucket(cache, "debuffs", instID) then
                debuffsDirty = true
                SummaryAddSpell(rd)
            end
        end
    end

    -- No full RebuildBuffMaps/RebuildDebuffMaps on the updated path: ReplaceAuraInBucket
    -- now maintains the spellID/name/instance maps and the defensive set incrementally.
    -- Dispel/defensive classification is spell-fixed, so a stack/duration update can't
    -- change it -- the add/remove paths already keep playerDispellable/allDispellable current.
    if cache.defensiveSetChanged then
        if auraStats then auraStats.defensiveSetChanges = auraStats.defensiveSetChanges + 1 end
    end

    -- Publish the dirty summary for the render fan-out (valid only on this true
    -- return; a false return falls back to a full scan + full render).
    _deltaSummary.helpful = buffsDirty
    _deltaSummary.harmful = debuffsDirty
    _deltaSummary.defensive = cache.defensiveSetChanged
    return true
end

-- Evict stale cache entries for units no longer in the group.
-- Called on GROUP_ROSTER_UPDATE from the centralized event dispatcher.
local function PruneAuraCache()
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.unitFrameMap then return end
    for unit in pairs(unitAuraCache) do
        if not GF.unitFrameMap[unit] then
            unitAuraCache[unit] = nil
        end
    end
end

-- Expose cache for other modules (dispel overlay, defensive indicator)
QUI_GFA.unitAuraCache = unitAuraCache
-- QUI_GFA.auraStats is exported by SetupDebugInstrumentation (debug gate)
QUI_GFA.ScanUnitAuras = ScanUnitAuras
QUI_GFA.ApplyAuraDelta = ApplyAuraDelta
QUI_GFA.PruneAuraCache = PruneAuraCache

-- Spec-change handlers call this before refreshing frames so every cached unit
-- re-scans against the new spec's aura state. Does not re-render frames.
function QUI_GFA:RescanCachedUnits()
    for unit in pairs(unitAuraCache) do
        ScanUnitAuras(unit)
    end
end

-- Table reuse: unitAuraCache[unit] sub-tables are created once per unit and
-- then mutated in place across full scans and deltas. Blizzard auraData tables
-- are still C-side allocated, but the shared cache avoids rebuilding per-
-- consumer lookup tables on every roster aura change.

---------------------------------------------------------------------------
-- CLASSIFICATION FILTER
---------------------------------------------------------------------------
-- The DB-toggle to Blizzard filter-string maps, the per-spell
-- whitelist/blacklist, the inline classification query, and the dispel/boss
-- priority sort all moved to the shared core modules: the element filter
-- compiler now lives in core/aura_elements.lua (E.CompileFilters /
-- E.CompileCandidateFilters) and the container glue in core/aura_glue.lua
-- (AuraGlue.ElementGroups). This file no longer owns any Lua-side strip filter
-- primitive -- the per-element containers filter C-side on secret-safe data.

---------------------------------------------------------------------------
-- UNIFIED ELEMENT RENDER (groupframes_aura_render.lua is the sole consumer)
---------------------------------------------------------------------------
-- The v46 aura element model (groupframes_aura_model.lua) drives every group-
-- frame aura visual. For each visible frame we resolve the unit's active spec,
-- build the element work list (tracked matches pre-resolved by the model;
-- filterStrip matches resolved here from the shared cache via the element's own
-- filter config), dispatch each to the renderer, and release any element id
-- whose frames linger from a prior pass (element removed/disabled/spec change).

-- Forward declarations: GetFrameAuraSettings (and its GetVisualDB* helpers) are
-- defined just below in the panel-render section; the unified render path runs
-- only at runtime, so the upvalues are bound by the time it is called.
local GetFrameAuraSettings
local _renderCurrentIDs = {}

-- Active player spec (mirrors the editor + the retired pinned-aura module).
-- Cached on the module table: spec only changes on PLAYER_SPECIALIZATION_CHANGED,
-- so the two C calls don't belong in the per-frame render path. `false` = the
-- "computed, no spec" sentinel so a genuinely nil spec isn't recomputed each call.
local function GetPlayerSpecID()
    local cached = QUI_GFA._cachedSpecID
    if cached ~= nil then
        return cached or nil
    end
    local specIndex = GetSpecialization and GetSpecialization()
    if specIndex and GetSpecializationInfo then
        cached = (GetSpecializationInfo(specIndex)) or false
    else
        cached = false
    end
    QUI_GFA._cachedSpecID = cached
    return cached or nil
end

-- Invalidate the spec cache on spec/loadout swap and login. Frame held alive by
-- the event system (no persistent local needed -> no main-chunk upvalue added).
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_ENTERING_WORLD" or unit == "player" then
            QUI_GFA._cachedSpecID = nil
        end
    end)
end

-- The legacy Lua-side strip match builder (BuildFilterStripMatches), its
-- `_strip*` scratch + priority-sort helper, and the orphaned strip-filter
-- primitives (AuraPassesFilter / AuraPassesSpellFilter / GetAuraPriority) were
-- all REMOVED. Every container-rendered element is now drawn by its own secure
-- per-unit CustomAuraContainer (LIVE AURA CONTAINERS section), which filters
-- C-side on secret-safe data via the shared core glue (AuraGlue / AuraSlots).
-- No classification map survives in this file -- the filter compiler moved to
-- core/aura_elements.lua.

-- Reusable scratch for the zero-alloc engine render path. Each is filled and
-- fully consumed within a single RenderFrameElements pass (Render:Dispatch only
-- reads the match tables synchronously and never retains them), so sharing
-- across frames in the UNIT_AURA combat fan-out is safe and eliminates per-frame
-- GC churn. _trackedMatchesScratch feeds the healthTint feeder;
-- _missingRaidBuffMatchesScratch feeds MRB.
local _activeElementsScratch = {}
local _trackedMatchesScratch = {}
local _missingRaidBuffMatchesScratch = {}

-- Per-frame element render: dispatch the work list and release stale element
-- frames. `cache` is the unit's shared aura cache entry (may be nil → only
-- empty/health-clear renders happen). The set of element ids rendered last pass
-- is tracked on frame._quiRenderedAuraElementIDs so any id that drops out (an
-- element removed/disabled, or a spec change) gets released this pass.
local function ReleaseAllRenderedElements(frame, Render)
    local prev = frame._quiRenderedAuraElementIDs
    if prev then
        for id in pairs(prev) do
            Render:Release(frame, id)
            prev[id] = nil
        end
    end
    -- A health-tint element may own the tint without a tracked id snapshot.
    if frame._quiAuraRenderHealthTintOwner then
        Render:Release(frame, frame._quiAuraRenderHealthTintOwner)
    end
end

-- AURA RELEVANCE DESCRIPTOR (reverse lookup for the dirty fan-out) -----------
-- Per aura-config: which buckets it shows a strip for, whether it has any tracked
-- element, and the union of tracked spellIDs. Lets the render fan-out skip a
-- whole frame whose elements the delta never touched, in O(changed spells)
-- instead of rebuilding the element list. Cached per (config table, spec, gen);
-- the generation bumps on any settings change (InvalidateLayout / RefreshAll).
-- Held weak-keyed so it never lands in SavedVariables and GC'd configs don't leak.
local _relGeneration = 0
QUI_GFA._configGeneration = 0  -- public mirror of _relGeneration for the renderer's icon-config gate
local _relCache = setmetatable({}, { __mode = "k" })
local function GetAuraRelevance(auras, specID)
    local rel = _relCache[auras]
    if rel and rel.gen == _relGeneration and rel.specID == specID then
        return rel
    end
    if not rel then
        rel = { trackedSpells = {} }
        _relCache[auras] = rel
    end
    rel.gen = _relGeneration
    rel.specID = specID
    rel.hasMissingRaidBuff = false
    rel.hasTracked = false
    wipe(rel.trackedSpells)
    -- Rare path (only on spec/settings change): a plain alloc here is fine.
    -- Strips + tracked icon/square/bar are container-driven (self-drive
    -- UNIT_AURA), so the relevance descriptor only tracks the engine's remaining
    -- emitters — MRB (helpful-dirty) and the healthTint tracked feeder (by spell).
    local elements = AuraModel.ActiveElementsForSpec(auras, specID)
    for i = 1, #elements do
        local e = elements[i]
        if EngineRendersElement(e) then
            if e.mode == "missingRaidBuff" then
                rel.hasMissingRaidBuff = true
            elseif e.mode == "tracked" then
                rel.hasTracked = true
                local spells = e.spells
                if spells then
                    for j = 1, #spells do rel.trackedSpells[spells[j]] = true end
                end
            end
        end
    end
    return rel
end

-- True if this delta could change anything the frame's engine elements render
-- (MRB + the healthTint feeder; container-rendered elements self-drive).
local function DeltaTouchesFrame(rel, dirty)
    if dirty.helpful and rel.hasMissingRaidBuff then return true end
    if rel.hasTracked then
        if dirty.spellsUncertain then return true end
        for sid in pairs(dirty.spells) do
            if rel.trackedSpells[sid] then return true end
        end
    end
    return false
end

-- `dirty` (optional): the delta summary from ApplyAuraDelta. When present, frames
-- and elements the delta never touched skip re-dispatch (their widgets stay as
-- they are). nil = full render (settings refresh / full scan / cold) → all.
local function RenderFrameElements(frame, cache, dirty)
    if not frame or not frame.unit then return end
    local pf = ns.QUI_PerfFlags  -- dev A/B harness; nil in normal play
    if pf and pf.disabled and pf.disabled.auras then return end
    local Render = GetRender()
    if not Render then return end

    local auras = GetFrameAuraSettings(frame)

    -- Auras disabled (or no config): tear down every element on this frame.
    if not auras or auras.enabled == false then
        ReleaseAllRenderedElements(frame, Render)
        return
    end

    local specID = GetPlayerSpecID()
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras, DefaultStripBucket) end

    -- Frame-level dirty skip: if this delta can't touch any element this frame
    -- shows, leave every widget exactly as-is (no element rebuild, no release).
    local rel = GetAuraRelevance(auras, specID)
    if dirty and not DeltaTouchesFrame(rel, dirty) then
        if auraStats then auraStats.frameSkips = auraStats.frameSkips + 1 end
        return
    end

    -- Zero-alloc render: iterate the active elements directly into reusable
    -- scratch tables. Render:Dispatch only reads matches synchronously and never
    -- retains them, so the scratch is safe to reuse across frames/events.
    local elements = AuraModel.ActiveElementsForSpec(auras, specID, _activeElementsScratch)

    local rendered = frame._quiRenderedAuraElementIDs
    if not rendered then
        rendered = {}
        frame._quiRenderedAuraElementIDs = rendered
    end

    local current = _renderCurrentIDs
    wipe(current)
    for i = 1, #elements do
        local element = elements[i]
        -- The engine only renders MRB + the healthTint tracked feeder.
        -- filterStrip AND tracked icon/square/bar are drawn by their own secure
        -- CustomAuraContainer — skip both entirely (no id recorded, so the
        -- release reconciliation tears down any lingering widgets from a
        -- pre-cutover pass and never re-acquires them).
        if EngineRendersElement(element) then
            -- Per-element dirty gate: skip the (expensive) match build + Dispatch
            -- for elements the delta didn't touch, but still record the id so the
            -- release reconciliation below never drops a clean element.
            local elementDirty = (dirty == nil)
            if not elementDirty then
                if element.mode == "missingRaidBuff" then
                    elementDirty = dirty.helpful
                elseif element.mode == "tracked" then
                    if dirty.spellsUncertain then
                        elementDirty = true
                    else
                        local spells = element.spells
                        if spells then
                            for j = 1, #spells do
                                if dirty.spells[spells[j]] then elementDirty = true; break end
                            end
                        end
                    end
                end
            end
            current[element.id] = true
            if elementDirty then
                if auraStats then auraStats.elementsDispatched = auraStats.elementsDispatched + 1 end
                local matches
                if element.mode == "missingRaidBuff" then
                    local MRB = ns.QUI_GroupFrameMissingRaidBuffs
                    if MRB and MRB.BuildMatches then
                        matches = MRB:BuildMatches(frame.unit, element, _missingRaidBuffMatchesScratch)
                    end
                elseif element.mode == "tracked" then
                    matches = AuraModel.PopulateElementMatches(element, cache, _trackedMatchesScratch)
                end
                Render:Dispatch(frame, element, matches)
            elseif auraStats then
                auraStats.elementSkips = auraStats.elementSkips + 1
            end
        end
    end

    -- Release element ids that rendered last pass but are gone this pass.
    for id in pairs(rendered) do
        if not current[id] then
            -- `:` already passes Render as self; R.Release(self, frame, elementID).
            -- The old `Render:Release(Render, frame, id)` shifted args (frame=Render,
            -- elementID=frame), so removed elements never actually released and their
            -- icons lingered on live frames until a /reload rebuilt them.
            Render:Release(frame, id)
        end
    end
    -- Snapshot the current set for the next pass (reuse the table).
    wipe(rendered)
    for id in pairs(current) do rendered[id] = true end
    -- Health-tint owner that no element rendered this pass (e.g. its element was
    -- removed) must be cleared too.
    local tintOwner = frame._quiAuraRenderHealthTintOwner
    if tintOwner and not current[tintOwner] then
        Render:Release(frame, tintOwner)
    end
end
QUI_GFA.RenderFrameElements = RenderFrameElements

---------------------------------------------------------------------------
-- UPDATE: Auras for a single frame
---------------------------------------------------------------------------
-- Pure duration/stack updates stay on the icon fast path below. Set changes
-- flow through the shared cache first, then refresh consumers from that state.

local function GetVisualDBForContext(isRaid)
    local db = GetDB()
    if not db then return nil end

    return (isRaid and db.raid or db.party) or db
end

local function GetVisualDBForFrame(frame)
    return GetVisualDBForContext(frame and frame._isRaid)
end

-- Assigns the forward-declared upvalue (declared in the unified-render block
-- above) so RenderFrameElements can resolve a frame's auras config.
function GetFrameAuraSettings(frame)
    local vdb = GetVisualDBForFrame(frame)
    return vdb and vdb.auras or nil
end

---------------------------------------------------------------------------
-- LIVE AURA CONTAINERS — one secure CustomAuraContainer PER active element
---------------------------------------------------------------------------
-- Every container-rendered element (filterStrip + tracked icon/square/bar) gets
-- its OWN secure CustomAuraContainer, themed by the shared core glue: element →
-- AuraGlue.ElementProfile + AuraGlue.ElementGroups → AuraGlue.RunConfigPass
-- (AuraSkin.Configure OOC / Restyle in combat), tracked slots via AuraSlots.Sync
-- (AddAuraSlot). The container self-drives UNIT_AURA and reads aura data C-side,
-- so no QUI Lua ever reads a secret aura field on this path.
--
-- Containers pool on the frame by ORDINAL (frame._quiAuraContainers[i]) — they
-- are engine objects that can't be destroyed, so a changing element list
-- re-purposes them (group retire inside AuraSkin.Configure, slot park via
-- AuraSlots.Park). CREATION (CreateFrame + AddAuraGroup/AddAuraSlot button
-- pooling) is combat-restricted (crashes the 12.1 client) and stays queued for
-- PLAYER_REGEN_ENABLED. MUTATION of a pre-created container (anchor / filters /
-- SetUnit / enable) is combat-legal, so the update path applies that subset live
-- in combat and STILL queues the full pass so a wrong assumption self-heals.
--
-- MRB synthetic icons + the health-bar tint feeder remain on the v46 element
-- engine (RenderFrameElements above) — only container-rendered elements live here.

-- ONE lazy resolver for the three shared deps. AuraGlue/AuraSlots live in the
-- QUI core addon (a dependency, loaded before this file); AuraSkin needs the
-- live secure button template so it may bind slightly later — resolve all lazily
-- following the file's existing `AuraSkin = AuraSkin or ...` idiom.
local AuraSkin = (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
local AuraGlue = ns.AuraGlue
local AuraSlots = ns.AuraSlots
local function ResolveAuraDeps()
    AuraSkin  = AuraSkin  or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    AuraGlue  = AuraGlue  or ns.AuraGlue
    AuraSlots = AuraSlots or ns.AuraSlots
    return AuraSkin and AuraGlue and AuraSlots
end

-- Combat-deferral queue. [frame] = true → re-apply config OOC.
local _containerPendingCombatWork = {}
local _containerCombatDeferFrame

-- Forward decl: FlushContainerCombatWork calls ApplyStripContainers, defined below.
local ApplyStripContainers

local function FlushContainerCombatWork()
    for frame in pairs(_containerPendingCombatWork) do
        _containerPendingCombatWork[frame] = nil
        if frame and ApplyStripContainers then
            ApplyStripContainers(frame)
        end
    end
end

local function EnsureContainerCombatDeferFrame()
    if _containerCombatDeferFrame then return end
    _containerCombatDeferFrame = CreateFrame("Frame")
    _containerCombatDeferFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    _containerCombatDeferFrame:SetScript("OnEvent", FlushContainerCombatWork)
end

local function QueueContainerCombatWork(frame)
    EnsureContainerCombatDeferFrame()
    _containerPendingCombatWork[frame] = true
end

-- Resolve the active CONTAINER-RENDERED elements for a frame: filterStrips +
-- tracked (icon/square/bar) in bucket order. healthTint tracked elements and
-- missingRaidBuff stay on the element-renderer path (EngineRendersElement).
-- Returns a SHARED module scratch (do not retain across a re-resolve).
local _activeElems = {}
local function ResolveContainerElements(frame)
    for i = #_activeElems, 1, -1 do _activeElems[i] = nil end
    local auras = GetFrameAuraSettings(frame)
    if not auras or auras.enabled == false then return _activeElems end
    AuraModel.EnsureSeeded(auras, DefaultStripBucket)
    local specID = GetPlayerSpecID()
    local elements = AuraModel.ActiveElementsForSpec(auras, specID)
    for i = 1, #elements do
        local e = elements[i]
        if e.mode == "filterStrip"
            or (e.mode == "tracked" and e.displayType ~= "healthTint") then
            _activeElems[#_activeElems + 1] = e
        end
    end
    return _activeElems
end

-- Anchor a container OOC relative to its unit frame at the element's anchor
-- corner. AuraSkin.LayoutAnchor(profile) returns the flow-origin corner
-- (grow + profile.wrap); pinning THAT corner to the frame's matching anchor
-- point makes the auto-sized container hang off the frame edge, with multi-row
-- growth extending AWAY from the frame. The per-element offset is folded in
-- here (the engine, not QUI, positions buttons/slots). The container is
-- forbidden → SetPoint is NEVER called in combat (callers gate on
-- InCombatLockdown / QueueContainerCombatWork).
local function AnchorElementContainer(container, frame, element)
    local profile = AuraGlue.ElementProfile(element)
    container:ClearAllPoints()
    container:SetPoint(AuraSkin.LayoutAnchor(profile), frame, element.anchor or "TOPLEFT",
        (element.offsetX or 0), (element.offsetY or 0))
end

-- One container per active element, pooled by ORDINAL on the frame. Containers
-- are engine objects that can't be destroyed; a changing element list
-- re-purposes them (group retire inside AuraSkin.Configure via RunConfigPass,
-- slot park via AuraSlots.Park). allowCreate=false (combat) NEVER creates
-- containers or slots and never SetPoints; it only mutates pre-created
-- containers (pcall-guarded group reconcile with a Restyle fallback, inside
-- AuraGlue.RunConfigPass). Any forbidden work skipped in combat sets
-- `incomplete`, which queues a full replay for PLAYER_REGEN_ENABLED.
local function ApplyElementPass(frame, allowCreate)
    if not frame or not frame.unit then return end
    if not ResolveAuraDeps() then return end
    local elems = ResolveContainerElements(frame)
    local pool = frame._quiAuraContainers
    if not pool then
        pool = {}
        frame._quiAuraContainers = pool
    end
    local incomplete = false
    for i = 1, #elems do
        local element = elems[i]
        local container = pool[i]
        if not container then
            if allowCreate and not InCombatLockdown() and CreateFrame then
                container = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
                pool[i] = container
            else
                incomplete = true
            end
        end
        if container then
            -- SetUnit BEFORE group configuration so the container's eager group
            -- registration (inside AuraSkin.Configure) has a valid unit.
            container:SetUnit(frame.unit)
            if not InCombatLockdown() then
                AnchorElementContainer(container, frame, element)
            end
            if element.mode == "tracked" then
                -- Retire any strip groups a re-purposed container carries, then
                -- reconcile the tracked slots (AddAuraSlot) onto it.
                if not AuraGlue.RunConfigPass(container, AuraGlue.ElementProfile(element), {}, allowCreate) then incomplete = true end
                if not AuraSlots.Sync(container, element, allowCreate) then incomplete = true end
            else
                local profile = AuraGlue.ElementProfile(element)
                local groups = AuraGlue.ElementGroups(frame.unit, element, profile, false)
                if not AuraGlue.RunConfigPass(container, profile, groups, allowCreate) then incomplete = true end
                AuraSlots.Park(container)
            end
            container:SetEnabled(true)
            container:Show()
        end
    end
    -- Retire pooled containers beyond the active element count: empty groups +
    -- park slots + disable + hide (all combat-legal on a pre-created container).
    for i = #elems + 1, #pool do
        local container = pool[i]
        if not AuraGlue.RunConfigPass(container, container._quiProfile or {}, {}, allowCreate) then incomplete = true end
        AuraSlots.Park(container)
        container:SetEnabled(false)
        container:Hide()
    end
    if incomplete then
        QueueContainerCombatWork(frame)
    end
end

-- Full pass entry (the forward-declared name + the QUI_GFA export; also what
-- the combat-flush closure replays at PLAYER_REGEN_ENABLED, always OOC there).
function ApplyStripContainers(frame)
    ApplyElementPass(frame, not InCombatLockdown())
end
QUI_GFA.ApplyStripContainers = ApplyStripContainers

-- Public entry: (re)apply the per-element container config for one frame. In
-- combat, mutation of pre-created containers is legal (SetUnit / filters /
-- enable), so run the mutation-only pass immediately AND queue the full pass
-- (creation + reconcile) for regen so any skipped forbidden work self-heals.
-- The containers self-drive UNIT_AURA, so this is config-only — not a per-event
-- render loop.
local function UpdateStripContainers(frame)
    if not frame or not frame.unit then return end
    if InCombatLockdown() then
        -- Mutation of pre-created containers is 12.1-PTR-legal (SetUnit /
        -- filters / enable); pcall-guard the whole mutable pass (a surprise
        -- combat restriction must not error out of the event handler) and
        -- STILL queue the full pass (creation + reconcile) for regen.
        pcall(ApplyElementPass, frame, false)
        QueueContainerCombatWork(frame)
        return
    end
    ApplyElementPass(frame, true)
end
QUI_GFA.UpdateStripContainers = UpdateStripContainers

-- Disable + hide every aura container on a frame (unit cleared / frame hidden):
-- retire each (empty groups + park slots + disable + hide). Group/slot mutation
-- and SetEnabled/Hide on a pre-created container are combat-legal; RunConfigPass
-- pcall-guards Configure in combat. Forbidden work skipped in combat queues a
-- regen replay.
local function RetireContainer(container, allowCreate)
    local ok = AuraGlue.RunConfigPass(container, container._quiProfile or {}, {}, allowCreate)
    AuraSlots.Park(container)
    container:SetEnabled(false)
    container:Hide()
    return ok
end

local function DisableStripContainers(frame)
    if not frame then return end
    local pool = frame._quiAuraContainers
    if not pool or #pool == 0 then return end
    if not ResolveAuraDeps() then return end
    local inCombat = InCombatLockdown()
    local incomplete = false
    for i = 1, #pool do
        local container = pool[i]
        if container then
            if inCombat then
                -- SetEnabled/Hide/park on a pre-created container is combat-
                -- legal mutation: hide the cleared unit's auras NOW instead of
                -- showing stale icons all fight; pcall-guard so a surprise
                -- restriction can't error out, and reconcile at regen.
                local ok, complete = pcall(RetireContainer, container, false)
                if not ok or not complete then incomplete = true end
            else
                if not RetireContainer(container, true) then incomplete = true end
            end
        end
    end
    if incomplete or inCombat then
        QueueContainerCombatWork(frame)
    end
end
QUI_GFA.DisableStripContainers = DisableStripContainers

-- Pre-create (OOC) one container per active element for a header child, even a
-- unitless padding child (ResolveContainerElements keys on frame._isRaid,
-- stamped at child birth by the decorate bridge — no unit needed). Called by
-- the header preallocator so a member joining MID-COMBAT lands on a child whose
-- forbidden containers already exist + are anchored: creation is combat-forbidden
-- (crashes the 12.1 client), but SetUnit/filter/enable on a pre-created
-- container is combat-legal mutation. Cheap re-entry: skips when the pool
-- already holds enough containers (config-time RunConfigPass handles growth).
function QUI_GFA.EnsureContainersForFrame(frame)
    if not frame or InCombatLockdown() then return end
    if not ResolveAuraDeps() or not CreateFrame then return end
    local elems = ResolveContainerElements(frame)
    local want = #elems
    if want == 0 then return end
    local pool = frame._quiAuraContainers
    if not pool then
        pool = {}
        frame._quiAuraContainers = pool
    end
    if #pool >= want then return end
    for i = #pool + 1, want do
        local container = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
        pool[i] = container
        AnchorElementContainer(container, frame, elems[i])
    end
end

-- True when the unit's context has at least one enabled aura element.
local function HasActiveAuraElements(vdb)
    local auras = vdb and vdb.auras
    if not auras or auras.enabled == false then return false end
    local elements = auras.elements
    if type(elements) ~= "table" then return false end
    -- The "*" bucket plus any per-spec bucket can carry enabled elements. We do
    -- not resolve the live spec here (this is a cheap activity gate); any
    -- enabled element in any bucket keeps the aura pipeline alive for the unit.
    for _, bucket in pairs(elements) do
        if type(bucket) == "table" then
            for _, e in ipairs(bucket) do
                if type(e) == "table" and e.enabled ~= false then
                    return true
                end
            end
        end
    end
    return false
end

local function HasDispelOverlay(vdb)
    local healer = vdb and vdb.healer
    local dispel = healer and healer.dispelOverlay
    return dispel and dispel.enabled ~= false
end

local function HasDefensiveIndicator(vdb)
    local healer = vdb and vdb.healer
    local defensive = healer and healer.defensiveIndicator
    return defensive and defensive.enabled == true
end

-- A context has active aura consumers when it has any enabled aura element
-- (the unified model — strips + tracked auras) OR a healer dispel/defensive
-- overlay (those still consume the shared cache for classification subsets).
local function HasActiveAuraConsumers(isRaid)
    local vdb = GetVisualDBForContext(isRaid)
    if not vdb then return false end

    if HasActiveAuraElements(vdb) then return true end
    if HasDispelOverlay(vdb) then return true end
    if HasDefensiveIndicator(vdb) then return true end

    return false
end

local function FrameHasActiveAuraConsumers(frame)
    return frame and HasActiveAuraConsumers(frame._isRaid) == true
end

local function AnyVisibleFrameHasActiveAuraConsumers(frames, nFrames)
    local partyActive = nil
    local raidActive = nil
    for i = 1, nFrames do
        local frame = frames[i]
        if frame and frame:IsShown() then
            if frame._isRaid then
                if raidActive == nil then
                    raidActive = HasActiveAuraConsumers(true)
                end
                if raidActive then return true end
            else
                if partyActive == nil then
                    partyActive = HasActiveAuraConsumers(false)
                end
                if partyActive then return true end
            end
        end
    end
    return false
end

function QUI_GFA:HasActiveConsumersForContext(isRaid)
    return HasActiveAuraConsumers(isRaid)
end

function QUI_GFA:HasActiveConsumersForFrame(frame)
    return FrameHasActiveAuraConsumers(frame)
end

-- The legacy buff/debuff panel renderer (UpdateFrameAuras) and its refresh gate
-- (PanelRefreshNeededForFrame) were retired by the unified element renderer.
-- RenderFrameElements (above) is now the sole per-frame aura render path; the
-- shared cache still feeds it, plus the dispel/defensive overlays.

---------------------------------------------------------------------------
-- EVENT HOOKUP: Listen to UNIT_AURA via the group frame event system
---------------------------------------------------------------------------
-- Aura processing is inline in the dispatcher callback so all group-frame
-- consumers render from the same shared cache mutation. The unified element
-- renderer owns icon mouse-propagation, the duration timer, and per-instance
-- swipe refresh (Render:RefreshUpdatedIcons / RefreshUpdatedBars) — the legacy
-- panel mouse-fix + icon refresh helpers were retired with the panel renderer.

-- Subscribe to centralized aura dispatcher for group frame aura updates.
-- Stack/duration-only updates stay on the icon fast path. Add/remove/full
-- changes mutate the shared cache first, then all consumers read that state.
--
-- Pure stack/duration updates (the dominant raid path — 80%+ of events) skip
-- the entire scan + overlay + filter/sort pipeline and just refresh visible
-- icon cooldown swipes via DurationObject (zero Lua allocation).
--
-- Set changes try the shared delta path first; full updates still rescan.
-- AURA-STORM BUDGET: M+ pulls / raid-wide debuffs fire UNIT_AURA on ~40 units in
-- one frame. Even with per-frame dirty-skipping, full-update events bypass the
-- delta path and cost a full scan + full render each, so a wall of them in one
-- frame hitches. Cap the heavy path at AURA_HEAVY_BUDGET units/frame; overflow
-- units are queued and drained ~budget/frame by a hidden OnUpdate ticker, each
-- replayed with nil updateInfo (forced full scan — lossless, never a stale
-- delta). The stack/duration fast path and the first budget units stay instant;
-- steady state never exceeds budget, so normal play sees no added latency.
local AURA_HEAVY_BUDGET = 10
local _auraFrameStamp = 0
local _auraBudgetUsed = 0
local _auraDirtyUnits = {}
local _auraDrainFrame

local function HeavyBudgetAvailable()
    local now = (GetTime and GetTime()) or 0
    if now ~= _auraFrameStamp then
        _auraFrameStamp = now
        _auraBudgetUsed = 0
    end
    if _auraBudgetUsed >= AURA_HEAVY_BUDGET then return false end
    _auraBudgetUsed = _auraBudgetUsed + 1
    return true
end

-- Process one unit's set-change / full-update: update the shared cache, then run
-- the dirty-gated render fan-out across its frames. updateInfo == nil forces a
-- full scan + full render (used by the drain queue and any fallback path).
local function ProcessUnitAuraSetChange(unit, updateInfo)
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.initialized then return end
    local frames = GF.unitFrameMap[unit]
    if not frames then return end
    local nFrames = #frames
    if nFrames == 0 then return end

    -- Keep the shared cache authoritative: full scan on full/fallback, else patch
    -- from the UNIT_AURA delta (which also publishes the dirty summary).
    local cacheUpdated = false
    local triedDelta = false
    if type(updateInfo) == "table" and not updateInfo.isFullUpdate then
        triedDelta = true
        cacheUpdated = ApplyAuraDelta(unit, updateInfo)
    elseif type(updateInfo) == "table" and updateInfo.isFullUpdate then
        if auraStats then auraStats.fullUpdateEvents = auraStats.fullUpdateEvents + 1 end
    end
    if cacheUpdated then
        if auraStats then auraStats.deltaApplied = auraStats.deltaApplied + 1 end
    else
        if triedDelta then
            if auraStats then auraStats.deltaFallback = auraStats.deltaFallback + 1 end
        end
        ScanUnitAuras(unit)
    end

    local cache = unitAuraCache[unit]
    local Render = GetRender()
    -- dirty == nil on a full scan / fallback → full render; else the gated path.
    local dirty = cacheUpdated and _deltaSummary or nil
    for f = 1, nFrames do
        local frame = frames[f]
        if frame:IsShown() then
            if auraStats then auraStats.framesRefreshed = auraStats.framesRefreshed + 1 end
            -- Healer overlays re-evaluate on EVERY aura set-change (and every full
            -- scan), never gated by the delta's per-bucket dirty flags. This path
            -- only runs for add/remove/full events — pure stack/duration updates
            -- return on the fast path in the subscriber and never reach here — so
            -- the unconditional re-check matches the set-change cadence without
            -- re-running on refresh ticks. The previous `dirty.harmful` /
            -- `dirty.defensive` gate could SKIP the clear: the flag reports which
            -- bucket the delta mutated, but a lingering dispel/defensive set entry
            -- can survive a delta whose summary flags the OTHER bucket (or whose
            -- shape the summary under-reports), leaving the overlay lit after the
            -- debuff is gone. The overlay readers are a cheap pre-classified set
            -- walk, so re-checking each set-change is effectively free.
            if GF.UpdateDispelOverlay then
                GF:UpdateDispelOverlay(frame)
            end
            if GF.UpdateDefensiveIndicator then
                GF:UpdateDefensiveIndicator(frame)
            end
            -- Engine element pass (MRB synthetic icons + the healthTint feeder).
            -- Strips + tracked icon/square/bar self-draw on their secure
            -- CustomAuraContainers — so the dispel/defensive overlays above no
            -- longer gate or feed this call.
            RenderFrameElements(frame, cache, dirty)
        end
    end

    -- Mixed delta (updated + added/removed): reseat C-side bar timers on the
    -- updated instances so the fill drains from the live DurationObject.
    if cacheUpdated and Render and type(updateInfo) == "table"
        and updateInfo.updatedAuraInstanceIDs
        and (updateInfo.addedAuras or updateInfo.removedAuraInstanceIDs)
    then
        local updated = updateInfo.updatedAuraInstanceIDs
        if Render.RefreshUpdatedBars then
            if Render:RefreshUpdatedBars(frames, nFrames, unit, updated) then
                if auraStats then auraStats.mixedIconRefreshes = auraStats.mixedIconRefreshes + 1 end
            end
        end
    end
end

local function EnsureAuraDrainFrame()
    if _auraDrainFrame then return _auraDrainFrame end
    _auraDrainFrame = CreateFrame("Frame")
    _auraDrainFrame:Hide()
    _auraDrainFrame:SetScript("OnUpdate", function(self)
        for unit in pairs(_auraDirtyUnits) do
            if HeavyBudgetAvailable() then
                _auraDirtyUnits[unit] = nil
                -- The queued delta is stale by now → full scan (nil updateInfo).
                ProcessUnitAuraSetChange(unit, nil)
                if auraStats then auraStats.drainProcessed = auraStats.drainProcessed + 1 end
            else
                break -- budget spent this frame; resume next frame
            end
        end
        if not next(_auraDirtyUnits) then self:Hide() end
    end)
    return _auraDrainFrame
end

if ns.AuraEvents then
    ns.AuraEvents:Subscribe("roster", function(unit, updateInfo)
        local GF = ns.QUI_GroupFrames
        if not GF or not GF.initialized then return end

        local frames = GF.unitFrameMap[unit]
        if not frames then return end
        local nFrames = #frames
        if nFrames == 0 then return end
        if not AnyVisibleFrameHasActiveAuraConsumers(frames, nFrames) then
            if auraStats then auraStats.noConsumerSkips = auraStats.noConsumerSkips + 1 end
            return
        end

        -- Fast path: pure stack/duration update (no auras added or removed).
        -- The display set is identical — skip full scan + all overlay updates.
        -- Only refresh the specific icons whose aura actually updated. Never
        -- budgeted: it's zero-alloc and latency-critical. C-side, secret-safe.
        if type(updateInfo) == "table"
            and not updateInfo.isFullUpdate
            and not updateInfo.addedAuras
            and not updateInfo.removedAuraInstanceIDs
            and updateInfo.updatedAuraInstanceIDs
            and unitAuraCache[unit]
            and unitAuraCache[unit].hasFullScan
        then
            local updated = updateInfo.updatedAuraInstanceIDs
            local nUpdated = #updated
            if nUpdated == 0 then return end
            -- 12.1 PTR4: updatedAuraInstanceIDs are secret while auras are secret;
            -- the icon/bar reseat (RefreshUpdatedIcons/Bars) matches them with ==,
            -- which throws on a secret value. Skip the reseat during secret windows
            -- -- swipes hold their last C-side SetCooldown, and skipping keeps this
            -- zero-alloc hot path storm-free (no fall-through to a full scan).
            if AurasAreSecret() then return end
            if auraStats then auraStats.fastUpdates = auraStats.fastUpdates + 1 end

            -- Reseat only the C-side swipes/bars on element visuals whose aura
            -- instance updated (zero alloc) — no element-list rebuild.
            local Render = GetRender()
            if Render then
                if Render.RefreshUpdatedIcons then
                    Render:RefreshUpdatedIcons(frames, nFrames, unit, updated)
                end
                if Render.RefreshUpdatedBars then
                    Render:RefreshUpdatedBars(frames, nFrames, unit, updated)
                end
            end
            return
        end

        -- Heavy path (set change / full update): budget to spread aura storms.
        -- Under budget → process inline (instant). Over → queue + drain over the
        -- next frames. Steady state never exceeds budget, so no added latency.
        if HeavyBudgetAvailable() then
            _auraDirtyUnits[unit] = nil
            ProcessUnitAuraSetChange(unit, updateInfo)
        else
            _auraDirtyUnits[unit] = true
            if auraStats then auraStats.heavyDeferred = auraStats.heavyDeferred + 1 end
            EnsureAuraDrainFrame():Show()
        end
    end)
end

---------------------------------------------------------------------------
-- PUBLIC: Invalidate aura layout (call when aura settings change in options)
---------------------------------------------------------------------------
-- The shared cache drives the dispel/defensive subsets and the unified renderer
-- resolves filterStrip matches at render time, so settings changes need no cache
-- mutation here. It MUST bump the relevance generation, though: a config edit
-- (add/remove/retarget an element) changes which spells/buckets each frame cares
-- about, invalidating the cached dirty-skip descriptors.
function QUI_GFA:InvalidateLayout()
    _relGeneration = _relGeneration + 1
    QUI_GFA._configGeneration = _relGeneration
end

---------------------------------------------------------------------------
-- PUBLIC: Refresh all frames
---------------------------------------------------------------------------
function QUI_GFA:RefreshAll()
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.initialized then return end

    -- Full refresh = settings may have changed; invalidate cached dirty-skip
    -- descriptors so the next render rebuilds them from the current config.
    _relGeneration = _relGeneration + 1
    QUI_GFA._configGeneration = _relGeneration
    for unit, list in pairs(GF.unitFrameMap) do
        local shouldScan = AnyVisibleFrameHasActiveAuraConsumers(list, #list)
        if shouldScan then
            ScanUnitAuras(unit)
        end
        local cache = unitAuraCache[unit]
        for i = 1, #list do
            local frame = list[i]
            if frame and frame:IsShown() then
                RenderFrameElements(frame, cache)
            end
        end
    end
end

function QUI_GFA:RefreshFrame(frame)
    if frame and frame.unit and FrameHasActiveAuraConsumers(frame) then
        ScanUnitAuras(frame.unit)
    end
    RenderFrameElements(frame, frame and frame.unit and unitAuraCache[frame.unit] or nil)
end

function QUI_GFA:RenderFrame(frame)
    RenderFrameElements(frame, frame and frame.unit and unitAuraCache[frame.unit] or nil)
end
