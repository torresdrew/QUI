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
local CHROME_LEVELS = (ns.QUI_GroupFrameChrome and ns.QUI_GroupFrameChrome.LEVELS)
    or { AURA_HOST = 12 }
local function GetFrameUnit(frame)
    local GF = ns.QUI_GroupFrames
    return GF and GF.GetFrameUnit and GF.GetFrameUnit(frame) or nil
end
-- Unified element renderer (groupframes_aura_render.lua). Resolved lazily at
-- render time via GetRender() so file load order can't matter.
local function GetRender() return ns.QUI_GroupFrameAuraRender end

-- The shipped default strip bucket lives in the model shim (always loaded,
-- TOC line above this file) — NOT Options-side: E.EnsureSeeded LATCHES
-- elementsSeeded after seeding, so an Options-only bucket would let an
-- Options-disabled install latch an EMPTY "*" bucket and permanently lose
-- the shipped strips.
--
-- Surface-aware shipped bucket: the defensives strip defaults enabled on
-- party, disabled on raid. Two static closures so the hot render path never
-- allocates one per call.
local _bucketFnParty = function() return AuraModel.DefaultStripBucket("party") end
local _bucketFnRaid  = function() return AuraModel.DefaultStripBucket("raid") end
local function BucketFnFor(frame)
    return (frame and frame._isRaid) and _bucketFnRaid or _bucketFnParty
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
    if mode == "tracked" and (element.displayType == "healthTint" or element.displayType == "border") then return true end
    -- filterStrip + tracked icon/square/bar => secure CustomAuraContainer.
    return false
end
QUI_GFA.EngineRendersElement = EngineRendersElement

-- Surface-owned presentation fields that are not part of an aura element.
-- Both the live secure-container path and the settings preview call this
-- function, so Debuff Border by Type and icon-skin ownership cannot drift.
function QUI_GFA.ProfileOverrides(auras, gfdb, surfaceKey, dispelColorCurve)
    gfdb = gfdb or GetDB()
    return {
        showDispelBorder = auras and auras.debuffBorderByType == true,
        dispelColorCurve = dispelColorCurve,
        externalSkinning = gfdb and gfdb.externalSkinning == true,
        iconSkin = (gfdb and gfdb.iconSkin) or "Default",
        externalSkinKey = surfaceKey or "groupauras",
    }
end

-- Build render work for one unit frame from the unified element model.
-- specID: the unit's active spec (or nil). cache: that unit's unitAuraCache entry.
-- frame: the owning unit frame (used to pick the surface-aware default bucket).
-- Returns a list of { element = <element>, matches = <table|nil> } for the renderer.
local function BuildElementRenderList(auras, specID, cache, frame)
    local work = {}
    if not auras then return work end
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras, BucketFnFor(frame)) end
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
--     typedDebuffs           = { [instID] = true },     -- any known dispel type, incl. Bleed/Enrage
--     typedDebuffOrder       = { instID, ... },
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

-- 68675: RAID on HARMFUL = "the PLAYER can dispel" — the personal cleanse
-- classifier this feeds (playerDispellable overlay). RAID_PLAYER_DISPELLABLE
-- widened to "anyone in the raid can dispel" and would light the overlay for
-- dispels the player cannot touch.
local DISPEL_FILTER = "HARMFUL|RAID"
-- PAGE size for the slot scan, NOT a coverage cap: GetAuraSlots is paginated
-- via its continuationToken (UnitAuraDocumentation) and ScanUnitAurasBySlot
-- loops until the token comes back nil, so aura 41+ is still scanned.
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
    local filteredOut = IsAuraFilteredOut(unit, instID, DISPEL_FILTER) -- @secret-safe: caller-gated: ClassifyDispellable runs only from the full-scan (703) / delta (766) paths behind AurasAreSecret
    if filteredOut == nil or IsSecretValue(filteredOut) then return nil end
    return filteredOut == false
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
        typedDebuffs = {},
        typedDebuffOrder = {},
        -- Bookkeeping
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
    wipe(cache.typedDebuffs)
    wipe(cache.typedDebuffOrder)
    cache.hasFullScan = false
end

local function RebuildBuffMaps(_unit, cache)
    wipe(cache.buffsByID)
    wipe(cache.buffsIndexByID)
    wipe(cache.buffsBySpellID)
    wipe(cache.buffsByName)

    local buffs = cache.buffs
    local buffsByID = cache.buffsByID
    local buffsIndexByID = cache.buffsIndexByID
    local buffsBySpellID = cache.buffsBySpellID
    local buffsByName = cache.buffsByName

    -- Per-spell always-secret auras survive the AurasAreSecret() gate —
    -- probe before truth-tests (see RebuildDebuffMaps).
    for i = 1, #buffs do
        local auraData = buffs[i]
        if IsSecretValue(auraData) then
            -- @secret-policy: reject-secret-value
            auraData = nil
        end
        local instID = auraData and auraData.auraInstanceID
        if IsSecretValue(instID) then
            -- @secret-policy: reject-secret-ids
            instID = nil
        end
        if instID then
            buffsByID[instID] = auraData
            buffsIndexByID[instID] = i
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

-- >>> QUI_TEST_EXTRACT RebuildDebuffMaps
local function RebuildDebuffMaps(unit, cache)
    wipe(cache.debuffsByID)
    wipe(cache.debuffsIndexByID)
    wipe(cache.debuffsBySpellID)
    wipe(cache.debuffsByName)
    wipe(cache.playerDispellable)
    wipe(cache.playerDispellableOrder)
    wipe(cache.allDispellable)
    wipe(cache.typedDebuffs)
    wipe(cache.typedDebuffOrder)

    local debuffs = cache.debuffs
    local debuffsByID = cache.debuffsByID
    local debuffsIndexByID = cache.debuffsIndexByID
    local debuffsBySpellID = cache.debuffsBySpellID
    local debuffsByName = cache.debuffsByName
    local playerDispellable = cache.playerDispellable
    local playerDispellableOrder = cache.playerDispellableOrder
    local allDispellable = cache.allDispellable
    local typedDebuffs = cache.typedDebuffs
    local typedDebuffOrder = cache.typedDebuffOrder

    -- Per-spell always-secret auras survive the AurasAreSecret() gate
    -- (SecretPredicatesDocumentation: "Individual spells may be flagged as
    -- never or always secret, which takes priority over restrictions"), so
    -- every field read below probes BEFORE any truth-test or compare.
    for i = 1, #debuffs do
        local auraData = debuffs[i]
        if IsSecretValue(auraData) then
            -- @secret-policy: reject-secret-value — an opaque AuraData entry
            -- is unusable for map/dispel classification; skip it.
            auraData = nil
        end
        local instID = auraData and auraData.auraInstanceID
        if IsSecretValue(instID) then
            -- @secret-policy: reject-secret-ids — cannot key maps on an
            -- opaque aura instance id.
            instID = nil
        end
        if instID then
            debuffsByID[instID] = auraData
            debuffsIndexByID[instID] = i

            local dispelName = auraData.dispelName
            local hasDispelType = false
            if IsSecretValue(dispelName) then
                -- @secret-policy: reject-secret-value — a secret dispel type
                -- is INDETERMINATE; never derive "dispellable" from secrecy.
                hasDispelType = false
            elseif dispelName ~= nil then
                hasDispelType = true
            end
            if hasDispelType then
                allDispellable[instID] = true
            end

            local dispelEnum = auraData.dispelType
            if IsSecretValue(dispelEnum) then
                -- @secret-policy: reject-secret-value — never compare an
                -- opaque enum; the player-dispellable classifier below may
                -- still establish typed membership without revealing it.
                dispelEnum = nil
            end
            local classified = ClassifyDispellable(unit, instID)
            local hasTypedEnum = dispelEnum == 1 or dispelEnum == 2
                or dispelEnum == 3 or dispelEnum == 4
                or dispelEnum == 9 or dispelEnum == 11
            if hasDispelType or hasTypedEnum or classified == true then
                typedDebuffs[instID] = true
                typedDebuffOrder[#typedDebuffOrder + 1] = instID
            end
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
-- <<< QUI_TEST_EXTRACT RebuildDebuffMaps

local function ResolveAuraBucket(unit, auraData)
    if not auraData then return nil end

    local instID = auraData.auraInstanceID
    if instID and IsAuraFilteredOut then
        local buffFiltered = IsAuraFilteredOut(unit, instID, "HELPFUL") -- @secret-safe: caller-gated: ResolveAuraBucket runs only from the delta path behind the 766 AurasAreSecret gate
        if buffFiltered ~= nil and not IsSecretValue(buffFiltered) then
            if buffFiltered == false then
                return "buffs"
            end
            local debuffFiltered = IsAuraFilteredOut(unit, instID, "HARMFUL") -- @secret-safe: caller-gated: same delta-path AurasAreSecret gate as the HELPFUL probe above
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

local function AddBuffDerivedData(_unit, cache, auraData)
    -- Probe-first parity with AddDebuffDerivedData: per-spell always-secret
    -- auras pass the global gate and throw on `not x` truth-tests.
    if IsSecretValue(auraData) then
        -- @secret-policy: reject-secret-value
        auraData = nil
    end
    local instID = auraData and auraData.auraInstanceID
    if IsSecretValue(instID) then
        -- @secret-policy: reject-secret-ids
        instID = nil
    end
    if not instID then return end

    local spellID = SafeValue(auraData.spellId, nil)
    if spellID then
        cache.buffsBySpellID[spellID] = auraData
    end

    local spellName = SafeValue(auraData.name, nil)
    if spellName then
        cache.buffsByName[spellName] = auraData
    end
end

local function RemoveBuffDerivedData(cache, auraData, instID)
    if not auraData or not instID then return end

    local spellID = SafeValue(auraData.spellId, nil)
    if spellID and cache.buffsBySpellID[spellID] == auraData then
        RefreshSpellIDLookupAfterRemoval(cache.buffs, cache.buffsBySpellID, spellID)
    end

    local spellName = SafeValue(auraData.name, nil)
    if spellName and cache.buffsByName[spellName] == auraData then
        RefreshSpellNameLookupAfterRemoval(cache.buffs, cache.buffsByName, spellName)
    end
end

local function AddDebuffDerivedData(unit, cache, auraData)
    -- Per-spell always-secret auras pass the global AurasAreSecret() gate —
    -- probe BEFORE every truth-test (a secret instID/dispelName throws on
    -- `not x` / `~= nil`).
    if IsSecretValue(auraData) then
        -- @secret-policy: reject-secret-value — opaque AuraData carries no
        -- usable identity for derived maps.
        auraData = nil
    end
    local instID = auraData and auraData.auraInstanceID
    if IsSecretValue(instID) then
        -- @secret-policy: reject-secret-ids
        instID = nil
    end
    if not instID then return end

    local dispelName = auraData.dispelName
    local hasDispelType = false
    if IsSecretValue(dispelName) then
        -- @secret-policy: reject-secret-value — secret dispel type is
        -- INDETERMINATE; never derive "dispellable" from secrecy.
        hasDispelType = false
    elseif dispelName ~= nil then
        hasDispelType = true
    end
    if hasDispelType then
        cache.allDispellable[instID] = true
    end

    local dispelEnum = auraData.dispelType
    if IsSecretValue(dispelEnum) then
        -- @secret-policy: reject-secret-value
        dispelEnum = nil
    end
    local classified = ClassifyDispellable(unit, instID)
    local hasTypedEnum = dispelEnum == 1 or dispelEnum == 2
        or dispelEnum == 3 or dispelEnum == 4
        or dispelEnum == 9 or dispelEnum == 11
    if hasDispelType or hasTypedEnum or classified == true then
        if not cache.typedDebuffs[instID] then
            cache.typedDebuffOrder[#cache.typedDebuffOrder + 1] = instID
        end
        cache.typedDebuffs[instID] = true
    end
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
    cache.typedDebuffs[instID] = nil
    RemoveIDFromOrder(cache.playerDispellableOrder, instID)
    RemoveIDFromOrder(cache.typedDebuffOrder, instID)
end

local function AppendAuraToBucket(unit, cache, bucketName, auraData)
    local bucket = bucketName == "buffs" and cache.buffs or cache.debuffs
    local byID = bucketName == "buffs" and cache.buffsByID or cache.debuffsByID
    local indexByID = bucketName == "buffs" and cache.buffsIndexByID or cache.debuffsIndexByID
    local instID = auraData and auraData.auraInstanceID

    -- Idempotent re-add: a duplicate addedAuras entry (or an add for an
    -- already-cached instance with no intervening remove) must overwrite in
    -- place, NOT append. Re-appending would push a second copy of instID into
    -- the dedup ORDER array (playerDispellableOrder) whose set guard already
    -- holds it; a single RemoveIDFromOrder on removal then strips only one,
    -- leaving a phantom that keeps the dispel overlay lit after the aura is
    -- gone.
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
        AddBuffDerivedData(unit, cache, auraData)
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
        RemoveBuffDerivedData(cache, oldAura, instID)
    else
        RemoveDebuffDerivedData(cache, oldAura, instID)
    end

    return true
end

local function ReplaceAuraInBucket(_unit, cache, bucketName, instID, auraData)
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

    return true
end

-- Returns GetAuraSlots' outContinuationToken (vararg position 1) so the
-- caller can page; slots start at position 2 (StrideIndex = 1).
local function AppendSlotAuras(unit, dst, ...)
    local n = select("#", ...)
    for i = 2, n do
        local slot = select(i, ...)
        if slot then
            local auraData = GetAuraDataBySlot(unit, slot) -- @secret-safe: caller-gated: AppendSlotAuras is only reached via ScanUnitAuras, which bails at its AurasAreSecret gate
            -- Per-spell always-secret auras still pass that gate — probe the
            -- returned AuraData and its instance id before any truth-test.
            if IsSecretValue(auraData) then
                -- @secret-policy: reject-secret-value — opaque entries can't
                -- be keyed or classified downstream; drop from the scan cache.
                auraData = nil
            end
            local instID = auraData and auraData.auraInstanceID
            if IsSecretValue(instID) then
                -- @secret-policy: reject-secret-ids
                instID = nil
            end
            if instID then
                dst[#dst + 1] = auraData
            end
        end
    end
    local token
    if n >= 1 then
        token = select(1, ...)
    end
    if IsSecretValue(token) then
        -- @secret-policy: reject-secret-value — an unreadable continuation
        -- token can't drive pagination; stop paging with the partial scan.
        token = nil
    end
    return token
end

-- Page through GetAuraSlots until the continuation token comes back nil
-- (UnitAuraDocumentation pagination contract) — a single call returns at
-- most maxSlots entries and silently truncates heavy raid aura sets.
local function ScanSlotFilter(unit, dst, filter)
    local token
    repeat
        token = AppendSlotAuras(unit, dst, GetAuraSlots(unit, filter, MAX_SCAN_AURAS, token)) -- @secret-safe: caller-gated: ScanSlotFilter is only reached via ScanUnitAuras, which bails at its AurasAreSecret gate
    until token == nil
end

local function ScanUnitAurasBySlot(unit, cache)
    if not GetAuraSlots or not GetAuraDataBySlot then
        return false
    end

    ScanSlotFilter(unit, cache.debuffs, "HARMFUL")
    ScanSlotFilter(unit, cache.buffs, "HELPFUL")
    return true
end

-- Copy a raw GetUnitAuras array into a cache bucket, dropping per-spell
-- always-secret entries: those survive the AurasAreSecret() gate (array
-- readable ≠ elements readable) and would throw at every downstream
-- truth-test/map key.
local function CopyReadableAuras(src, dst)
    local n = 0
    for i = 1, #src do
        local auraData = src[i]
        if IsSecretValue(auraData) then
            -- @secret-policy: reject-secret-value — opaque entries are
            -- unusable for the cache's identity maps; drop from the copy.
            auraData = nil
        end
        if auraData ~= nil then
            local instID = auraData.auraInstanceID
            if IsSecretValue(instID) then
                -- @secret-policy: reject-secret-ids — GetUnitAuras' return
                -- is ConditionalSecretContents (secret ELEMENTS proven;
                -- this per-field probe is defense-in-depth for the observed
                -- readable-struct/secret-scalar shapes). A retained entry
                -- with a secret instance id can never join the byID/index
                -- maps, and RemoveAuraFromBucket's reindex walk truth-tests
                -- this exact field on every retained bucket entry. Drop it,
                -- matching AppendSlotAuras' slot-path handling.
                auraData = nil
            end
        end
        if auraData ~= nil then
            n = n + 1
            dst[n] = auraData
        end
    end
end

local function ScanUnitAurasLegacy(unit, cache)
    local GetUnitAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras
    if not GetUnitAuras then return false end

    -- maxCount is nilable (UnitAuraDocumentation) and GetUnitAuras has no
    -- continuation token — omit the cap so the full list returns; a literal
    -- cap here silently dropped aura 41+ on heavy raid aura sets.
    local debuffs = GetUnitAuras(unit, "HARMFUL") -- @secret-safe: caller-gated: ScanUnitAurasLegacy is only reached via ScanUnitAuras, which bails at its AurasAreSecret gate
    if debuffs then
        CopyReadableAuras(debuffs, cache.debuffs)
    end

    local buffs = GetUnitAuras(unit, "HELPFUL") -- @secret-safe: caller-gated: same ScanUnitAuras AurasAreSecret gate as the HARMFUL scan above
    if buffs then
        CopyReadableAuras(buffs, cache.buffs)
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
-- ApplyAuraDelta publishes which aura BUCKETS changed (helpful/harmful) and the
-- set of spellIDs added/removed/updated, into a single reusable table. The
-- render fan-out reads it to dirty-flag frames and individual elements: a
-- frame/element whose tracked auras the delta never touched skips re-dispatch
-- entirely. Only valid when ApplyAuraDelta returns true (an incremental
-- patch); a full scan / fallback sets dirty = nil (render everything).
-- spellsUncertain = a changed aura's spellId was secret/unreadable, so tracked
-- elements must be treated as dirty (conservative, never stale).
local _deltaSummary = { helpful = false, harmful = false,
                        spellsUncertain = false, spells = {} }
local function ResetDeltaSummary()
    _deltaSummary.helpful = false
    _deltaSummary.harmful = false
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

-- INPUT CONTRACT (production): the sole caller chain is the aura router
-- (core/aura_events.lua) → ProcessUnitAuraSetChange. PayloadIsSecret there
-- promotes whole-secret payloads/arrays, secret ELEMENTS of all three delta
-- arrays, and secret identity fields (auraInstanceID/spellId/spellID) of
-- added auras to the full-update sentinel before any subscriber runs — so
-- the array walks, field truth-tests, and byID keying below may assume
-- element-level readability. Any caller that bypasses the router (tests,
-- future direct wiring) MUST pre-sanitize to the same guarantee.
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
            AppendAuraToBucket(unit, cache, bucketName, auraData)
            SummaryAddSpell(auraData)
            if bucketName == "buffs" then
                buffsDirty = true
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
                    -- GetAuraDataByAuraInstanceID is SecretWhenUnitAuraRestricted:
                    -- a per-spell always-secret aura returns WHOLE-secret
                    -- AuraData even while the global gate is false — probe
                    -- before the truth-test; opaque = fall back to full scan.
                    if IsSecretValue(freshAura) then
                        -- @secret-policy: reject-secret-value
                        return false
                    end
                    if not freshAura then
                        return false
                    end
                    local replaced = ReplaceAuraInBucket(unit, cache, bucketName, instID, freshAura)
                    if not replaced then
                        return false
                    end
                    SummaryAddSpell(freshAura)
                    if bucketName == "buffs" then
                        buffsDirty = true
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
            -- derived data (playerDispellable) can never linger and strand the
            -- dispel overlay lit after the aura is gone.
            -- Separate `if`s (not else): an instID present in both is fully purged.
            local rb = cache.buffsByID[instID]
            if rb then
                local removed = RemoveAuraFromBucket(cache, "buffs", instID)
                if removed then
                    buffsDirty = true
                    SummaryAddSpell(rb)
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
    -- now maintains the spellID/name/instance maps incrementally. Dispel
    -- classification is spell-fixed, so a stack/duration update can't change it
    -- -- the add/remove paths already keep playerDispellable/allDispellable and
    -- typedDebuffs current.

    -- Publish the dirty summary for the render fan-out (valid only on this true
    -- return; a false return falls back to a full scan + full render).
    _deltaSummary.helpful = buffsDirty
    _deltaSummary.harmful = debuffsDirty
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

-- Expose cache for other modules (dispel overlay)
QUI_GFA.unitAuraCache = unitAuraCache
-- QUI_GFA.auraStats is exported by SetupDebugInstrumentation (debug gate)
QUI_GFA.ScanUnitAuras = ScanUnitAuras
QUI_GFA.ApplyAuraDelta = ApplyAuraDelta
QUI_GFA.PruneAuraCache = PruneAuraCache

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

-- Resolve a frame's role gate inputs for AuraElements.ElementAppliesToRole:
-- assigned group role ("TANK"/"HEALER"/"DAMAGER"/nil) + whether the frame is the
-- player's own. Roles are stable within an encounter, so re-resolving per render
-- is cheap and always current on roster/spec change. Guarded for the headless
-- test harness (WoW role APIs absent there).
local function FrameRoleGate(frame)
    local unit = GetFrameUnit(frame)
    if not unit then return nil, false end
    -- No `or nil` collapse on the call result — under identity restriction
    -- UnitGroupRolesAssigned can return a secret, and `secret or nil`
    -- truth-tests it. Probe FIRST, then compare freely.
    -- @secret-policy: collapse-only — unreadable role = no role gate
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
    if IsSecretValue(role) then role = nil end
    if role == "NONE" then role = nil end
    -- Probe before the ==: UnitIsUnit can return a secret under identity
    -- restriction, and the old `X and call() or false` truth-tested it.
    local isSelf = false
    if UnitIsUnit then
        local raw = UnitIsUnit(unit, "player")
        if IsSecretValue(raw) then raw = nil end
        isSelf = raw == true
    end
    return role, isSelf
end

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
    -- emitters — MRB (helpful-dirty), the healthTint + border tracked feeders.
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
    if not frame then return end
    local unit = GetFrameUnit(frame)
    if not unit then return end
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
    if AuraModel.EnsureSeeded then AuraModel.EnsureSeeded(auras, BucketFnFor(frame)) end

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
    -- Role gate inputs for this frame (applyToRoles); stable within an encounter.
    local frameRole, frameIsSelf = FrameRoleGate(frame)
    -- Shared-overlay families: border / healthTint draw ONE per-frame overlay
    -- owned by whichever element matched last (R.RenderBorder /
    -- R.RenderHealthTint owner field). If ANY element of a family is dirty,
    -- EVERY element of that family must dispatch this pass: when the owner's
    -- aura drops, a clean sibling with a live match has to re-claim the
    -- overlay — the per-element dirty skip below would otherwise leave the
    -- indicator hidden while its aura is still active.
    local borderFamilyDirty, tintFamilyDirty = false, false
    if dirty then
        if dirty.spellsUncertain then
            borderFamilyDirty, tintFamilyDirty = true, true
        else
            for i = 1, #elements do
                local e = elements[i]
                if e.mode == "tracked"
                    and (e.displayType == "border" or e.displayType == "healthTint")
                    and type(e.spells) == "table" then
                    for j = 1, #e.spells do
                        if dirty.spells[e.spells[j]] then
                            if e.displayType == "border" then
                                borderFamilyDirty = true
                            else
                                tintFamilyDirty = true
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    for i = 1, #elements do
        local element = elements[i]
        -- The engine only renders MRB + the healthTint/border tracked feeders.
        -- filterStrip AND tracked icon/square/bar are drawn by their own secure
        -- CustomAuraContainer — skip both entirely (no id recorded, so the
        -- release reconciliation tears down any lingering widgets from a
        -- pre-cutover pass and never re-acquires them). A role-gated-out element
        -- is likewise skipped (id not recorded → released if it rendered before).
        if EngineRendersElement(element)
            and AuraModel.ElementAppliesToRole(element, frameRole, frameIsSelf) then
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
                    elseif element.displayType == "border" then
                        elementDirty = borderFamilyDirty
                    elseif element.displayType == "healthTint" then
                        elementDirty = tintFamilyDirty
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
                        matches = MRB:BuildMatches(unit, element, _missingRaidBuffMatchesScratch)
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
    -- Health-tint / border owner that no element rendered this pass (e.g. its
    -- element was removed or role-gated out) must be cleared too.
    local tintOwner = frame._quiAuraRenderHealthTintOwner
    if tintOwner and not current[tintOwner] then
        Render:Release(frame, tintOwner)
    end
    local borderOwner = frame._quiAuraRenderBorderOwner
    if borderOwner and not current[borderOwner] then
        Render:Release(frame, borderOwner)
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
-- pooling) and container anchoring are combat-legal since PTR7 68914 (earlier
-- 12.1 builds crashed the client; proven in-game 2026-07-24), so the full pass
-- runs live in combat. The restriction-aware AuraGlue.QueueRegenWork (regen
-- event + restriction poll) still replays work skipped under the 12.1 aura
-- SECRECY restriction (post-birth child styling/anchoring, aura_slots.lua) —
-- secrecy is a separate mechanism from combat lockdown.
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

-- Combat/restriction-deferral: route skipped forbidden work through the shared
-- restriction-aware replay queue (core/aura_glue.lua QueueRegenWork), the same
-- path Unit Frames use. It fires only when BOTH combat lockdown AND the 12.1
-- aura restriction are clear, and POLLS while a restriction is up outside
-- combat — a PLAYER_REGEN_ENABLED-only flush left tracked slots stale when
-- secrecy began and ended without a combat-lockdown window (regen never fires).

-- Forward decl: the replay closure calls ApplyStripContainers, defined below.
local ApplyStripContainers

local function QueueContainerCombatWork(frame)
    AuraGlue = AuraGlue or ns.AuraGlue
    if not AuraGlue then return end
    AuraGlue.QueueRegenWork(frame, function(f)
        if ApplyStripContainers then ApplyStripContainers(f) end
    end)
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
    AuraModel.EnsureSeeded(auras, BucketFnFor(frame))
    local specID = GetPlayerSpecID()
    local elements = AuraModel.ActiveElementsForSpec(auras, specID)
    local role, isSelf = FrameRoleGate(frame)
    for i = 1, #elements do
        local e = elements[i]
        if (e.mode == "filterStrip"
            or (e.mode == "tracked" and e.displayType ~= "healthTint" and e.displayType ~= "border"))
            and AuraModel.ElementAppliesToRole(e, role, isSelf) then
            _activeElems[#_activeElems + 1] = e
        end
    end
    return _activeElems
end

-- Anchor a container relative to its unit frame at the element's anchor
-- corner. AuraSkin.LayoutAnchor(profile) returns the flow-origin corner
-- (grow + profile.wrap); pinning THAT corner to the frame's matching anchor
-- point makes the auto-sized container hang off the frame edge, with multi-row
-- growth extending AWAY from the frame. The per-element offset is folded in
-- here (the engine, not QUI, positions buttons/slots). Container SetPoint is
-- combat-legal (proven pre- and post-group registration, 2026-07-24) — only
-- CHILD-frame anchoring stays combat-gated (aura_slots.lua).
local function AnchorElementContainer(container, frame, element)
    local profile = AuraGlue.ElementProfile(element)
    container:ClearAllPoints()
    container:SetPoint(AuraSkin.LayoutAnchor(profile), frame, element.anchor or "TOPLEFT",
        (element.offsetX or 0), (element.offsetY or 0))
end

-- One container per active element, pooled by ORDINAL on the frame. Containers
-- are engine objects that can't be destroyed; a changing element list
-- re-purposes them (group retire inside AuraSkin.Configure via RunConfigPass,
-- slot park via AuraSlots.Park). Creation, registration and container
-- anchoring run unconditionally (combat-legal since PTR7 68914); work skipped
-- under the 12.1 aura SECRECY restriction (or by an allowCreate=false caller)
-- sets `incomplete`, which queues a full replay via the restriction-aware
-- AuraGlue.QueueRegenWork.
local function ApplyElementPass(frame, allowCreate)
    if not frame then return end
    local unit = GetFrameUnit(frame)
    if not unit then return end
    if not ResolveAuraDeps() then return end
    local AuraSurface = ns.AuraSurface
    if not AuraSurface then return end

    local auras = GetFrameAuraSettings(frame)
    local curve = ns.QUI_GroupFrameAuraBorderCurve
        and ns.QUI_GroupFrameAuraBorderCurve(frame._isRaid) or nil
    local profileOverrides = QUI_GFA.ProfileOverrides(auras, GetDB(), "groupauras", curve)
    local elems = ResolveContainerElements(frame)

    AuraSurface.ApplyElementPass(frame, elems, {
        unit = unit,
        allowCreate = allowCreate == true,
        cancelEligible = false,
        profileOverrides = profileOverrides,
        profileFor = function(element)
            return AuraGlue.ElementProfile(element, profileOverrides)
        end,
        anchorContainer = function(container, host, element)
            AnchorElementContainer(container, host, element)
        end,
        onContainerReady = function(container, host)
            local desiredLevel = host:GetFrameLevel() + CHROME_LEVELS.AURA_HOST
            if not InCombatLockdown() then
                container:SetFrameLevel(desiredLevel)
                return true
            end
            return container:GetFrameLevel() == desiredLevel
        end,
        onIncomplete = QueueContainerCombatWork,
    })
end

-- Full pass entry (the forward-declared name + the QUI_GFA export; also what
-- the QueueRegenWork closure replays once combat AND the aura restriction
-- clear). Always allowCreate: the full pass is combat-legal since PTR7 68914.
function ApplyStripContainers(frame)
    ApplyElementPass(frame, true)
end
QUI_GFA.ApplyStripContainers = ApplyStripContainers

-- Public entry: (re)apply the per-element container config for one frame. The
-- full pass (creation + reconcile + container anchoring) is combat-legal since
-- PTR7 68914; in combat it keeps a SafeCall belt — a surprise restriction must
-- not error out of the event handler — and a failed pass queues the
-- restriction-aware replay (the pass itself queues its own partial gaps).
-- The containers self-drive UNIT_AURA, so this is config-only — not a per-event
-- render loop.
local function UpdateStripContainers(frame)
    if not frame or not GetFrameUnit(frame) then return end
    if InCombatLockdown() then
        local ok = ns.SafeCall("best-effort-style", ApplyElementPass, frame, true)
        if not ok then
            QueueContainerCombatWork(frame)
        end
        return
    end
    ApplyElementPass(frame, true)
end
QUI_GFA.UpdateStripContainers = UpdateStripContainers

-- True when any of this frame's tracked containers was last reconciled
-- against a live-assist probe value that no longer matches. Judged against
-- the APPLIED state Sync itself records (_quiAssistApplied, written only
-- by AuraSlots.Sync/Park) — a reader-side cache cannot track it: config
-- passes run Sync from roster/settings/regen paths under whatever probe
-- value holds at that moment. Callers re-run UpdateStripContainers on true.
function QUI_GFA.TrackedAssistStale(frame)
    local pool = frame and frame._quiAuraContainers
    if not pool then return false end
    local AuraSlots = ns.AuraSlots
    if not (AuraSlots and AuraSlots.LiveAssistProbe) then return false end
    local live, probed
    for i = 1, #pool do
        local container = pool[i]
        local applied = container and container._quiAssistApplied
        if applied ~= nil then
            if not probed then
                probed = true
                live = AuraSlots.LiveAssistProbe(GetFrameUnit(frame)) == true
            end
            if live ~= applied then return true end
        end
    end
    return false
end

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
                -- showing stale icons all fight; SafeCall-guard so a surprise
                -- restriction can't error out, and reconcile at regen.
                local ok, complete = ns.SafeCall("best-effort-style", RetireContainer, container, false)
                if not ok or not complete then incomplete = true end
            else
                if not RetireContainer(container, true) then incomplete = true end
            end
        end
    end
    -- Retirement is container-level mutation (combat-legal); only a SafeCall
    -- failure or partial retire needs the restriction-aware replay.
    if incomplete then
        QueueContainerCombatWork(frame)
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
    -- enabled element in any REACHABLE bucket keeps the aura pipeline alive for
    -- the unit. Dormant legacy "i"/"e" context buckets (removed Encounters
    -- cascade) are skipped — the resolver can never activate them.
    for key, bucket in pairs(elements) do
        if (key == "*" or type(key) == "number") and type(bucket) == "table" then
            for _, e in ipairs(bucket) do
                if type(e) == "table" and e.enabled ~= false then
                    return true
                end
            end
        end
    end
    return false
end

local function HasDispelConsumer(vdb)
    local healer = vdb and vdb.healer
    local dispel = healer and healer.dispelOverlay
    local glow = healer and healer.cleanseGlow
    return (dispel and (dispel.enabled ~= false or dispel.showIcon == true))
        or (glow and glow.enabled == true)
end

-- A context has active aura consumers when it has any enabled aura element
-- (the unified model — strips + tracked auras) OR a healer dispel overlay
-- (that still consumes the shared cache for classification subsets).
local function HasActiveAuraConsumers(isRaid)
    local vdb = GetVisualDBForContext(isRaid)
    if not vdb then return false end

    if HasActiveAuraElements(vdb) then return true end
    if HasDispelConsumer(vdb) then return true end

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

function QUI_GFA:HasActiveConsumersForFrame(frame)
    return FrameHasActiveAuraConsumers(frame)
end

-- The legacy buff/debuff panel renderer (UpdateFrameAuras) and its refresh gate
-- (PanelRefreshNeededForFrame) were retired by the unified element renderer.
-- RenderFrameElements (above) is now the sole per-frame aura render path; the
-- shared cache still feeds it, plus the dispel overlay.

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
            -- re-running on refresh ticks. The previous `dirty.harmful` gate
            -- could SKIP the clear: the flag reports which bucket the delta
            -- mutated, but a lingering dispel set entry can survive a delta
            -- whose summary flags the OTHER bucket (or whose shape the summary
            -- under-reports), leaving the overlay lit after the debuff is gone.
            -- The overlay readers are a cheap pre-classified set walk, so
            -- re-checking each set-change is effectively free.
            if GF.UpdateDispelOverlay then
                GF:UpdateDispelOverlay(frame)
            end
            -- Engine element pass (MRB synthetic icons + the healthTint feeder).
            -- Strips + tracked icon/square/bar self-draw on their secure
            -- CustomAuraContainers — so the dispel overlay above no longer
            -- gates or feeds this call.
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
-- The shared cache drives the dispel subset and the unified renderer resolves
-- filterStrip matches at render time, so settings changes need no cache
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
    local unit = GetFrameUnit(frame)
    if unit and FrameHasActiveAuraConsumers(frame) then
        ScanUnitAuras(unit)
    end
    RenderFrameElements(frame, unit and unitAuraCache[unit] or nil)
end

function QUI_GFA:RenderFrame(frame)
    local unit = GetFrameUnit(frame)
    RenderFrameElements(frame, unit and unitAuraCache[unit] or nil)
end
