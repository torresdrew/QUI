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
-- ELEMENT-MODEL GLUE (inert — wired in a later flip task)
---------------------------------------------------------------------------

-- STEP D1a CUTOVER: the generic buff/debuff STRIP display moved to Blizzard's
-- secure per-unit CustomAuraContainer (see the LIVE STRIP CONTAINER section
-- below). The v46 element engine no longer produces or renders `filterStrip`
-- elements, and the `tracked` ICON/SQUARE/BAR display was DROPPED entirely
-- (owner decision). The engine now emits ONLY:
--   * `missingRaidBuff` — Missing Raid Buffs synthetic icons (unchanged), and
--   * `tracked` with displayType == "healthTint" — the health-bar tint feeder
--     consumed by R.RenderHealthTint / R.SyncHealthBarTint (unchanged).
-- EngineRendersElement is the single gate every engine consumer below routes
-- through, so the strip/tracked drop stays in one place and MRB + tint keep
-- flowing through the (untouched) renderer.
local function EngineRendersElement(element)
    if not element then return false end
    local mode = element.mode
    if mode == "missingRaidBuff" then return true end
    if mode == "tracked" and element.displayType == "healthTint" then return true end
    -- filterStrip => secure CustomAuraContainer; tracked icon/square/bar => dropped.
    return false
end
QUI_GFA.EngineRendersElement = EngineRendersElement

-- Build render work for one unit frame from the unified element model.
-- specID: the unit's active spec (or nil). cache: that unit's unitAuraCache entry.
-- Returns a list of { element = <element>, matches = <table|nil> } for the renderer.
local function BuildElementRenderList(auras, specID, cache)
    local work = {}
    if not auras then return work end
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras) end
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
-- CLASSIFICATION FILTER: Build filter strings and check auras
---------------------------------------------------------------------------
-- Maps DB toggle keys to Blizzard classification filter strings
local BUFF_CLASSIFICATION_MAP = {
    raid              = "HELPFUL|RAID",
    raidInCombat      = "HELPFUL|RAID_IN_COMBAT",
    cancelable        = "HELPFUL|CANCELABLE",
    notCancelable     = "HELPFUL|NOT_CANCELABLE",
    bigDefensive      = "HELPFUL|BIG_DEFENSIVE",
    externalDefensive = "HELPFUL|EXTERNAL_DEFENSIVE",
}

local DEBUFF_CLASSIFICATION_MAP = {
    raid         = "HARMFUL|RAID",
    -- NOTE: no raidInCombat here. RAID_IN_COMBAT is a HELPFUL-only AuraFilters
    -- token (Blizzard doc: "Combine with Player & Helpful to return self-cast
    -- HoTs"); "HARMFUL|RAID_IN_COMBAT" is an invalid combo and C_UnitAuras.
    -- GetUnitAuras hard-errors on it. It only ever made sense for the buff zone.
    crowdControl = "HARMFUL|CROWD_CONTROL",
}

-- STEP D1b: the per-spell whitelist/blacklist (AuraPassesSpellFilter), the
-- inline classification query (AuraPassesFilter), and the dispel/boss priority
-- sort (GetAuraPriority + its PRIORITY_* constants) were REMOVED. They were the
-- last Lua-side strip-filter primitives, retained "for a later step" after the
-- D1a cutover but never re-wired: the live strip now filters C-side in the
-- secure CustomAuraContainer (BuildZoneFilters consumes the classification maps
-- above directly), so these had zero callers across QUI_GroupFrames/. The two
-- BUFF/DEBUFF_CLASSIFICATION_MAP tables are RETAINED — the container path
-- (CONTAINER_*_CLASS_MAP) still maps classification toggles → filter strings.

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

-- STEP D1a: the legacy BuildFilterStripMatches builder (Lua-side filter +
-- priority-sort that fed the strip's icon renderer) was REMOVED — the generic
-- buff/debuff strip is now drawn by the secure per-unit CustomAuraContainer
-- (LIVE STRIP CONTAINER section), which filters C-side on secret-safe data. The
-- `_strip*` scratch tables and the StripPrioritySort helper that only served it
-- are gone with it. STEP D1b then dropped the last orphaned strip-filter
-- primitives (AuraPassesFilter / AuraPassesSpellFilter / GetAuraPriority); only
-- the BUFF/DEBUFF_CLASSIFICATION_MAP tables survive, consumed C-side by the
-- container's BuildZoneFilters.

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
    -- STEP D1a: strips are container-driven and tracked icon/square/bar are
    -- dropped, so the relevance descriptor only tracks the engine's remaining
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
-- (MRB + the healthTint feeder; strips/tracked-icon left the engine in D1a).
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
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras) end

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
        -- STEP D1a: the engine only renders MRB + the healthTint tracked feeder.
        -- filterStrip is drawn by the secure CustomAuraContainer, and tracked
        -- icon/square/bar were dropped — skip both entirely (no id recorded, so
        -- the release reconciliation tears down any lingering widgets from a
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
-- LIVE STRIP CONTAINER — secure per-unit CustomAuraContainer (STEP D1a)
---------------------------------------------------------------------------
-- The generic buff/debuff STRIP display is rendered by Blizzard's secure
-- CustomAuraContainer (one buff + one debuff container per group/raid unit
-- frame), themed by QUI.AuraSkin. The container self-drives UNIT_AURA and reads
-- aura data C-side, so no QUI Lua ever reads a secret aura field on this path.
-- This mirrors the unit-frame cutover (QUI_UnitFrames/.../unitframe_auras.lua):
--   classification → AddAuraFilter strings, SetUnit(frame.unit), SetEnabled(true).
--
-- The container is a FORBIDDEN object: create / pool / anchor / filter changes
-- are restricted in combat, so all such work is queued during InCombatLockdown()
-- and replayed on PLAYER_REGEN_ENABLED.
--
-- MRB synthetic icons + the health-bar tint feeder remain on the v46 element
-- engine (RenderFrameElements above) — only the strips moved here.

local AuraSkin = (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)

-- Map a GF filterStrip element's classification toggles → Blizzard filter strings.
-- Keyed identically to the legacy strip filter logic (BUFF/DEBUFF_CLASSIFICATION_MAP
-- above) so the container applies the SAME C-side inclusion test the strip used.
local CONTAINER_BUFF_CLASS_MAP = BUFF_CLASSIFICATION_MAP
local CONTAINER_DEBUFF_CLASS_MAP = DEBUFF_CLASSIFICATION_MAP

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

-- Resolve the active filterStrip elements for a frame, split by zone. Returns
-- two arrays (buffElems, debuffElems) of enabled HELPFUL / HARMFUL strips for
-- the unit's active spec bucket. Empty arrays = that zone shows nothing.
local _stripBuffElems = {}
local _stripDebuffElems = {}
local function ResolveStripElements(frame)
    wipe(_stripBuffElems)
    wipe(_stripDebuffElems)
    local auras = GetFrameAuraSettings(frame)
    if not auras or auras.enabled == false then
        return _stripBuffElems, _stripDebuffElems
    end
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras) end
    local specID = GetPlayerSpecID()
    local elements = AuraModel.ActiveElementsForSpec(auras, specID)
    for i = 1, #elements do
        local e = elements[i]
        if e.mode == "filterStrip" then
            if e.auraType == "HARMFUL" then
                _stripDebuffElems[#_stripDebuffElems + 1] = e
            else
                _stripBuffElems[#_stripBuffElems + 1] = e
            end
        end
    end
    return _stripBuffElems, _stripDebuffElems
end

-- Build the Blizzard filter-string list for one zone from its enabled strips.
-- Each strip contributes one filter string (OR-unioned across strips): a
-- classification-mode strip emits its per-toggle classification strings; an
-- off / whitelist-mode strip emits the bare base (HELPFUL / HARMFUL) so the
-- container shows every aura of that polarity (per-spell whitelist/blacklist is
-- folded into the container filter set in a later step). Returns a fresh array.
local function BuildZoneFilters(elems, isDebuff)
    local base = isDebuff and "HARMFUL" or "HELPFUL"
    local map = isDebuff and CONTAINER_DEBUFF_CLASS_MAP or CONTAINER_BUFF_CLASS_MAP
    local filters = {}
    local seen = {}
    local function addFilter(str)
        if str and not seen[str] then seen[str] = true; filters[#filters + 1] = str end
    end
    for i = 1, #elems do
        local e = elems[i]
        local emitted = false
        if (e.filterMode or "off") == "classification" and e.classifications then
            for key, filterStr in pairs(map) do
                if e.classifications[key] then addFilter(filterStr); emitted = true end
            end
        end
        -- off / whitelist / classification-with-nothing-checked → show the
        -- whole polarity so a strip never silently displays nothing.
        if not emitted then addFilter(base) end
    end
    if #filters == 0 then addFilter(base) end
    return filters
end

-- Derive a FULL grid profile (icon metrics + layout) from the first enabled
-- strip. AuraSkin.Attach lays the buttons out relative to the container's anchor
-- corner using this profile, so the strip's anchor / offset / grow / spacing all
-- live in the profile; AnchorZoneContainer only pins the container's anchor
-- corner to the unit frame (the per-icon offset is carried by the buttons, so it
-- is NOT applied again at the container point). GF strip elements have no
-- maxPerRow key, so the grid stays a single line (maxPerRow = 0).
local function ZoneProfile(elems, isDebuff)
    local e = elems[1]
    local defAnchor = isDebuff and "BOTTOMRIGHT" or "TOPLEFT"
    if not e then
        return { maxIcons = 0, iconSize = 16, spacing = 2, grow = "RIGHT",
                 maxPerRow = 0, offsetX = 0, offsetY = 0, anchor = defAnchor,
                 borderSize = 1, fontSize = 11, hideSwipe = false, reverseSwipe = false }
    end
    return {
        maxIcons     = e.maxIcons and e.maxIcons > 0 and e.maxIcons or 32,
        iconSize     = e.iconSize or 16,
        spacing      = e.spacing or 2,
        grow         = e.growDirection or "RIGHT",
        maxPerRow    = 0,
        offsetX      = e.offsetX or 0,
        offsetY      = e.offsetY or 0,
        anchor       = e.anchor or defAnchor,
        borderSize   = e.borderSize or 1,
        fontSize     = e.fontSize or 11,
        hideSwipe    = e.hideSwipe or false,
        reverseSwipe = e.reverseSwipe or false,
    }
end

-- Anchor a container OOC relative to its unit frame at the first enabled strip's
-- anchor corner. The per-icon offset (e.offsetX / e.offsetY) is carried by the
-- pooled buttons in ZoneProfile, so it is NOT applied here — only the corner is
-- pinned. The container is forbidden → SetPoint is NEVER called in combat
-- (callers gate via QueueContainerCombatWork / InCombatLockdown).
local function AnchorZoneContainer(container, frame, elems, isDebuff)
    local e = elems[1]
    local anchor = (e and e.anchor) or (isDebuff and "BOTTOMRIGHT" or "TOPLEFT")
    container:ClearAllPoints()
    container:SetPoint(anchor, frame, anchor, 0, 0)
end

-- Create (OOC) the two zone containers for a unit frame and theme/pool via
-- AuraSkin. Idempotent — re-attaches/re-themes if maxIcons grew.
local function EnsureStripContainers(frame, buffElems, debuffElems)
    AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    if not AuraSkin or not CreateFrame then return false end

    if not frame.debuffContainer then
        frame.debuffContainer = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
    end
    if not frame.buffContainer then
        frame.buffContainer = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
    end

    AuraSkin.Attach(frame.debuffContainer, ZoneProfile(debuffElems, true))
    AuraSkin.Attach(frame.buffContainer, ZoneProfile(buffElems, false))

    AnchorZoneContainer(frame.debuffContainer, frame, debuffElems, true)
    AnchorZoneContainer(frame.buffContainer, frame, buffElems, false)
    return true
end

-- The container's AddAuraFilter eagerly runs C_UnitAuras.GetUnitAuras(unit,
-- filterString) (Blizzard_CustomAuraContainer ParseAllAuras). Some AuraFilters
-- tokens are only valid in a specific polarity combo and the C API HARD-ERRORS
-- on a bad one — and because this runs inside SecureGroupHeader_Update's
-- SetAttribute chain, the error taints + aborts the whole header. Worse,
-- AddAuraFilter table.inserts the filter BEFORE the throwing GetUnitAuras, so a
-- pcall around AddAuraFilter would leave a poisoned filter that re-throws on
-- every later UNIT_AURA. So pre-validate the string with our own (insecure,
-- addon-allowed) GetUnitAuras and only hand accepted strings to the container.
local function FilterStringUsable(unit, filterString)
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuras) then return true end
    return (pcall(C_UnitAuras.GetUnitAuras, unit, filterString))
end

-- Add a zone's pre-built filter strings to its container, dropping any the C
-- API rejects, and guaranteeing at least the base polarity (always valid) so a
-- zone never silently shows nothing when every classification filter is dropped.
local function AddZoneFilters(container, unit, filters, base, maxIcons)
    local added = 0
    for _, filterString in ipairs(filters) do
        if FilterStringUsable(unit, filterString) then
            container:AddAuraFilter(filterString, { maxFrameCount = maxIcons })
            added = added + 1
        end
    end
    if added == 0 then
        container:AddAuraFilter(base, { maxFrameCount = maxIcons })
    end
end

-- Apply enable/disable + filter + unit config to the live strip containers.
-- This is the heart of the live strip path: filters + SetEnabled change, the
-- container self-drives the rest. Runs OOC only (callers defer via the queue).
-- (Forward-declared above so the combat-flush closure can reach it.)
function ApplyStripContainers(frame)
    if not frame or not frame.unit then return end
    local buffElems, debuffElems = ResolveStripElements(frame)
    local showBuffs = #buffElems > 0
    local showDebuffs = #debuffElems > 0

    if not EnsureStripContainers(frame, buffElems, debuffElems) then return end

    -- Per-zone icon cap: maxFrameCount caps how many auras the container shows
    -- (it never assigns past the Nth registered button). Match each zone's pooled
    -- button count, derived from the first enabled strip's maxIcons (ZoneProfile).
    local debuffMaxIcons = ZoneProfile(debuffElems, true).maxIcons
    local buffMaxIcons = ZoneProfile(buffElems, false).maxIcons

    -- Debuff zone (HARMFUL strips). SetUnit BEFORE the filters so the
    -- container's eager GetUnitAuras (inside AddAuraFilter) has a valid unit.
    local dc = frame.debuffContainer
    dc:SetUnit(frame.unit)
    dc:ClearAuraFilters()
    if showDebuffs then
        AddZoneFilters(dc, frame.unit, BuildZoneFilters(debuffElems, true), "HARMFUL", debuffMaxIcons)
        dc:SetEnabled(true)
        dc:Show()
    else
        dc:SetEnabled(false)
        dc:Hide()
    end

    -- Buff zone (HELPFUL strips).
    local bc = frame.buffContainer
    bc:SetUnit(frame.unit)
    bc:ClearAuraFilters()
    if showBuffs then
        AddZoneFilters(bc, frame.unit, BuildZoneFilters(buffElems, false), "HELPFUL", buffMaxIcons)
        bc:SetEnabled(true)
        bc:Show()
    else
        bc:SetEnabled(false)
        bc:Hide()
    end
end
QUI_GFA.ApplyStripContainers = ApplyStripContainers

-- Public entry: (re)apply the strip container config for one frame, deferring to
-- OOC if the forbidden container can't be touched right now. The container self-
-- drives UNIT_AURA, so this is config-only — not a per-event render loop.
local function UpdateStripContainers(frame)
    if not frame or not frame.unit then return end
    if InCombatLockdown() then
        QueueContainerCombatWork(frame)
        return
    end
    ApplyStripContainers(frame)
end
QUI_GFA.UpdateStripContainers = UpdateStripContainers

-- Disable + hide both strip containers for a frame (unit cleared / frame hidden).
-- Forbidden-object SetEnabled/Hide → OOC only; defer in combat.
local function DisableStripContainers(frame)
    if not frame then return end
    if not frame.buffContainer and not frame.debuffContainer then return end
    if InCombatLockdown() then
        QueueContainerCombatWork(frame)
        return
    end
    if frame.debuffContainer then
        frame.debuffContainer:SetEnabled(false)
        frame.debuffContainer:Hide()
    end
    if frame.buffContainer then
        frame.buffContainer:SetEnabled(false)
        frame.buffContainer:Hide()
    end
end
QUI_GFA.DisableStripContainers = DisableStripContainers

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
            -- The generic buff/debuff strips left this path in D1a — they now
            -- self-draw on the secure CustomAuraContainer — so the dispel/
            -- defensive overlays above no longer gate or feed this call.
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
