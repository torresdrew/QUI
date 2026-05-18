local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CDM Runtime Queries
--
-- Shared runtime query/cache seam for cooldown resolver consumers. This
-- keeps source reads, short batch caches, trusted GCD state, and charge
-- metadata persistence out of CDMResolvers' factual state interface.
---------------------------------------------------------------------------

local CDMRuntimeQueries = {}
ns.CDMRuntimeQueries = CDMRuntimeQueries

local pairs = pairs
local type = type
local wipe = wipe or function(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local Sources = ns.CDMSources

local trustedGCDSpellState = {}
local trustedGCDStamp
local trustIsOnGCDForBatch = false
local chargeDurationObjectSerial = 0
local transientCooldownCache
local transientCooldownStamps
local transientChargeCache
local transientChargeStamps

function CDMRuntimeQueries.ResetTrustedGCDSnapshot(stamp)
    wipe(trustedGCDSpellState)
    trustedGCDStamp = stamp or GetTime()
    return trustedGCDSpellState, trustedGCDStamp
end

function CDMRuntimeQueries.GetTrustedGCDSnapshot()
    return trustedGCDSpellState, trustedGCDStamp
end

function CDMRuntimeQueries.GetTrustedGCDStamp()
    return trustedGCDStamp
end

function CDMRuntimeQueries.SetTrustIsOnGCDForBatch(enabled)
    local previous = trustIsOnGCDForBatch
    trustIsOnGCDForBatch = enabled == true
    return previous
end

function CDMRuntimeQueries.IsTrustingGCDForBatch()
    return trustIsOnGCDForBatch == true
end

function CDMRuntimeQueries.GetTrustedIsOnGCD(spellID)
    if trustIsOnGCDForBatch == true then
        local trusted = spellID and trustedGCDSpellState[spellID]
        if type(trusted) == "boolean" then
            return trusted
        end
    end
    return nil
end

function CDMRuntimeQueries.NoteChargeDurationObjectsUpdated()
    chargeDurationObjectSerial = chargeDurationObjectSerial + 1
    wipe(transientChargeCache)
    wipe(transientChargeStamps)
end

function CDMRuntimeQueries.GetChargeDurationObjectSerial()
    return chargeDurationObjectSerial
end

local function GetChargeMetadataDB()
    local db = QUI and QUI.db and QUI.db.global
    if not db then return nil end
    if not db.cdmChargeSpells then db.cdmChargeSpells = {} end
    return db.cdmChargeSpells
end
CDMRuntimeQueries.GetChargeMetadataDB = GetChargeMetadataDB

local NIL_SENTINEL = {}
local TRANSIENT_QUERY_TTL = 0.12
local runtimeQueryBatchDepth = 0
local runtimeCooldownCache = {}
local runtimeChargeCache = {}
local runtimeDurationCache = {}
local runtimeGCDDurationCache = {}
local runtimeChargeDurationCache = {}
local runtimeOverrideCache = {}
local runtimeDisplayCountCache = {}
local runtimeSpellCountCache = {}
local stableOverrideCache = {}
transientCooldownCache = {}
transientCooldownStamps = {}
transientChargeCache = {}
transientChargeStamps = {}
local nextTransientPrune = 0
local runtimeQueryStats = {
    batches = 0,
    cooldownSource = 0,
    cooldownHits = 0,
    chargeSource = 0,
    chargeHits = 0,
    durationSource = 0,
    durationHits = 0,
    chargeDurationSource = 0,
    chargeDurationHits = 0,
    overrideSource = 0,
    overrideHits = 0,
    displayCountSource = 0,
    displayCountHits = 0,
    spellCountSource = 0,
    spellCountHits = 0,
}

do
    local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "CDM_queryCacheBatches", counter = true, fn = function() return runtimeQueryStats.batches end }
    mp[#mp + 1] = { name = "CDM_queryCacheSource", counter = true, fn = function()
        return runtimeQueryStats.cooldownSource
            + runtimeQueryStats.chargeSource
            + runtimeQueryStats.durationSource
            + runtimeQueryStats.chargeDurationSource
            + runtimeQueryStats.overrideSource
            + runtimeQueryStats.displayCountSource
            + runtimeQueryStats.spellCountSource
    end }
    mp[#mp + 1] = { name = "CDM_queryCacheHits", counter = true, fn = function()
        return runtimeQueryStats.cooldownHits
            + runtimeQueryStats.chargeHits
            + runtimeQueryStats.durationHits
            + runtimeQueryStats.chargeDurationHits
            + runtimeQueryStats.overrideHits
            + runtimeQueryStats.displayCountHits
            + runtimeQueryStats.spellCountHits
    end }
    mp[#mp + 1] = { name = "CDM_queryCacheCooldownSource", counter = true, fn = function() return runtimeQueryStats.cooldownSource end }
    mp[#mp + 1] = { name = "CDM_queryCacheChargeSource", counter = true, fn = function() return runtimeQueryStats.chargeSource end }
    mp[#mp + 1] = { name = "CDM_queryCacheDurationSource", counter = true, fn = function() return runtimeQueryStats.durationSource end }
    mp[#mp + 1] = { name = "CDM_queryCacheChargeDurationSource", counter = true, fn = function() return runtimeQueryStats.chargeDurationSource end }
    mp[#mp + 1] = { name = "CDM_queryCacheOverrideSource", counter = true, fn = function() return runtimeQueryStats.overrideSource end }
    mp[#mp + 1] = { name = "CDM_queryCacheDisplayCountSource", counter = true, fn = function() return runtimeQueryStats.displayCountSource end }
    mp[#mp + 1] = { name = "CDM_queryCacheSpellCountSource", counter = true, fn = function() return runtimeQueryStats.spellCountSource end }
end

local function ClearRuntimeQueryCaches()
    wipe(runtimeCooldownCache)
    wipe(runtimeChargeCache)
    wipe(runtimeDurationCache)
    wipe(runtimeGCDDurationCache)
    wipe(runtimeChargeDurationCache)
    wipe(runtimeOverrideCache)
    wipe(runtimeDisplayCountCache)
    wipe(runtimeSpellCountCache)
end

function CDMRuntimeQueries.ClearStableCaches()
    wipe(stableOverrideCache)
    wipe(runtimeOverrideCache)
    wipe(transientCooldownCache)
    wipe(transientCooldownStamps)
    wipe(transientChargeCache)
    wipe(transientChargeStamps)
end

local function GetTransientCacheTime()
    if runtimeQueryBatchDepth <= 0 then return nil end
    if not (InCombatLockdown and InCombatLockdown()) then return nil end
    if not GetTime then return nil end
    return GetTime()
end

local function PruneTransientCache(cache, stamps, now)
    for key, stamp in pairs(stamps) do
        if not stamp or (now - stamp) > TRANSIENT_QUERY_TTL then
            stamps[key] = nil
            cache[key] = nil
        end
    end
end

local function PruneTransientCaches(now)
    if not now or now < nextTransientPrune then return end
    nextTransientPrune = now + 1
    PruneTransientCache(transientCooldownCache, transientCooldownStamps, now)
    PruneTransientCache(transientChargeCache, transientChargeStamps, now)
end

function CDMRuntimeQueries.BeginRuntimeQueryBatch()
    if runtimeQueryBatchDepth == 0 then
        ClearRuntimeQueryCaches()
        runtimeQueryStats.batches = runtimeQueryStats.batches + 1
        PruneTransientCaches(GetTransientCacheTime())
    end
    runtimeQueryBatchDepth = runtimeQueryBatchDepth + 1
end

function CDMRuntimeQueries.EndRuntimeQueryBatch()
    if runtimeQueryBatchDepth <= 0 then
        ClearRuntimeQueryCaches()
        runtimeQueryBatchDepth = 0
        return
    end

    runtimeQueryBatchDepth = runtimeQueryBatchDepth - 1
    if runtimeQueryBatchDepth == 0 then
        ClearRuntimeQueryCaches()
    end
end

function CDMRuntimeQueries.ResetRuntimeQueryBatch()
    runtimeQueryBatchDepth = 0
    ClearRuntimeQueryCaches()
    wipe(transientCooldownCache)
    wipe(transientCooldownStamps)
    wipe(transientChargeCache)
    wipe(transientChargeStamps)
end

local function ReadRuntimeCache(cache, key, hitStat)
    if runtimeQueryBatchDepth <= 0 then return nil, false end
    local cached = cache[key]
    if cached ~= nil then
        runtimeQueryStats[hitStat] = runtimeQueryStats[hitStat] + 1
        if cached == NIL_SENTINEL then
            return nil, true
        end
        return cached, true
    end
    return nil, false
end

local function StoreRuntimeCache(cache, key, value, sourceStat)
    if runtimeQueryBatchDepth <= 0 then return value end
    cache[key] = value == nil and NIL_SENTINEL or value
    runtimeQueryStats[sourceStat] = runtimeQueryStats[sourceStat] + 1
    return value
end

local function ReadTransientRuntimeCache(cache, stamps, key, hitStat)
    local now = GetTransientCacheTime()
    if not now then return nil, false end
    local cached = cache[key]
    if cached == nil then return nil, false end
    local stamp = stamps[key]
    if not stamp or (now - stamp) > TRANSIENT_QUERY_TTL then
        cache[key] = nil
        stamps[key] = nil
        return nil, false
    end
    runtimeQueryStats[hitStat] = runtimeQueryStats[hitStat] + 1
    if cached == NIL_SENTINEL then
        return nil, true
    end
    return cached, true
end

local function StoreTransientRuntimeCache(cache, stamps, key, value)
    local now = GetTransientCacheTime()
    if not now then return end
    cache[key] = value == nil and NIL_SENTINEL or value
    stamps[key] = now
end

function CDMRuntimeQueries.QueryCharges(spellID)
    if not spellID then return nil end
    local cached, found = ReadRuntimeCache(runtimeChargeCache, spellID, "chargeHits")
    if found then return cached end
    cached, found = ReadTransientRuntimeCache(transientChargeCache, transientChargeStamps, spellID, "chargeHits")
    if found then return cached end

    local chargeInfo
    if Sources and Sources.QuerySpellCharges then
        chargeInfo = Sources.QuerySpellCharges(spellID)
    end
    if not InCombatLockdown() then
        if chargeInfo then
            local maxC = chargeInfo.maxCharges
            if maxC and maxC > 1 then
                local svDB = GetChargeMetadataDB()
                if svDB then svDB[spellID] = maxC end
            elseif maxC then
                local svDB = GetChargeMetadataDB()
                if svDB and svDB[spellID] then svDB[spellID] = nil end
            end
        else
            local svDB = GetChargeMetadataDB()
            if svDB and svDB[spellID] then svDB[spellID] = nil end
        end
    end
    StoreTransientRuntimeCache(transientChargeCache, transientChargeStamps, spellID, chargeInfo)
    return StoreRuntimeCache(runtimeChargeCache, spellID, chargeInfo, "chargeSource")
end

function CDMRuntimeQueries.QueryCooldown(spellID)
    if not spellID then return nil end
    local cached, found = ReadRuntimeCache(runtimeCooldownCache, spellID, "cooldownHits")
    if found then return cached end
    cached, found = ReadTransientRuntimeCache(transientCooldownCache, transientCooldownStamps, spellID, "cooldownHits")
    if found then return cached end

    local info
    if Sources and Sources.QuerySpellCooldown then
        info = Sources.QuerySpellCooldown(spellID)
    end
    StoreTransientRuntimeCache(transientCooldownCache, transientCooldownStamps, spellID, info)
    return StoreRuntimeCache(runtimeCooldownCache, spellID, info, "cooldownSource")
end

local function QueryCooldownDuration(spellID, ignoreGCD)
    if not spellID then return nil end
    local cache = ignoreGCD and runtimeDurationCache or runtimeGCDDurationCache
    local cached, found = ReadRuntimeCache(cache, spellID, "durationHits")
    if found then return cached end

    local durObj
    if Sources and Sources.QuerySpellCooldownDuration then
        durObj = Sources.QuerySpellCooldownDuration(spellID, ignoreGCD and true or false)
    end
    return StoreRuntimeCache(cache, spellID, durObj, "durationSource")
end

function CDMRuntimeQueries.QueryDuration(spellID)
    if not spellID then return nil end
    return QueryCooldownDuration(spellID, true)
end

function CDMRuntimeQueries.QueryGCDDuration(spellID)
    if not spellID then return nil end
    return QueryCooldownDuration(spellID, false)
end

function CDMRuntimeQueries.QueryChargeDuration(spellID)
    if not spellID then return nil end
    local cached, found = ReadRuntimeCache(runtimeChargeDurationCache, spellID, "chargeDurationHits")
    if found then return cached end

    local durObj
    if Sources and Sources.QuerySpellChargeDuration then
        durObj = Sources.QuerySpellChargeDuration(spellID)
    end
    return StoreRuntimeCache(runtimeChargeDurationCache, spellID, durObj, "chargeDurationSource")
end

function CDMRuntimeQueries.QueryOverrideSpell(spellID)
    if not spellID then return nil end
    local stable = stableOverrideCache[spellID]
    if stable ~= nil then
        runtimeQueryStats.overrideHits = runtimeQueryStats.overrideHits + 1
        if stable == NIL_SENTINEL then
            return nil
        end
        return stable
    end

    local cached, found = ReadRuntimeCache(runtimeOverrideCache, spellID, "overrideHits")
    if found then return cached end

    local overrideID
    if Sources and Sources.QueryOverrideSpell then
        overrideID = Sources.QueryOverrideSpell(spellID)
    end
    stableOverrideCache[spellID] = overrideID == nil and NIL_SENTINEL or overrideID
    return StoreRuntimeCache(runtimeOverrideCache, spellID, overrideID, "overrideSource")
end

function CDMRuntimeQueries.QueryDisplayCount(spellID)
    if not spellID then return nil end
    local cached, found = ReadRuntimeCache(runtimeDisplayCountCache, spellID, "displayCountHits")
    if found then return cached end

    local count
    if Sources and Sources.QuerySpellDisplayCount then
        count = Sources.QuerySpellDisplayCount(spellID)
    end
    return StoreRuntimeCache(runtimeDisplayCountCache, spellID, count, "displayCountSource")
end

function CDMRuntimeQueries.QuerySpellCount(spellID)
    if not spellID then return nil end
    local cached, found = ReadRuntimeCache(runtimeSpellCountCache, spellID, "spellCountHits")
    if found then return cached end

    local count
    if Sources and Sources.QuerySpellCount then
        count = Sources.QuerySpellCount(spellID)
    end
    return StoreRuntimeCache(runtimeSpellCountCache, spellID, count, "spellCountSource")
end
