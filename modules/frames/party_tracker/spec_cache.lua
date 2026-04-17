--[[
    QUI Party Tracker — Spec Cache
    Lightweight party member specialization detection and caching.
    Uses NotifyInspect + INSPECT_READY with GUID-keyed cache.
    Falls back to LibOpenRaid UnitInfoUpdate when available.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local SpecCache = {}
ns.PartyTracker_SpecCache = SpecCache

local UnitGUID = UnitGUID
local IsSecretValue = Helpers.IsSecretValue
local SafeCompare = Helpers.SafeCompare
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitIsConnected = UnitIsConnected
local GetInspectSpecialization = GetInspectSpecialization
local NotifyInspect = NotifyInspect
local GetTime = GetTime
local select = select
local pcall = pcall

local CACHE_TTL = 300  -- 5 minutes
local INSPECT_INTERVAL = 0.5
local INSPECT_TIMEOUT = 10

local cache = {}   -- GUID → { specId, classToken, expiry }
local inspectQueue = {}  -- unit tokens needing inspection
local inspectPending = nil  -- unit currently being inspected
local inspectStartTime = 0
local inspectTicker = nil

do local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "PT_Spec_cache",        tbl = cache }
    mp[#mp + 1] = { name = "PT_Spec_inspectQueue", tbl = inspectQueue }
end

local function HasSafeGuid(guid)
    return not IsSecretValue(guid) and guid ~= nil
end

local function IsPlayerUnit(unit, guid)
    if unit == "player" then
        return true
    end

    local unitGuid = guid
    if not HasSafeGuid(unitGuid) then
        unitGuid = UnitGUID(unit)
        if not HasSafeGuid(unitGuid) then
            return false
        end
    end

    local playerGuid = UnitGUID("player")
    if not HasSafeGuid(playerGuid) then
        return false
    end

    -- Compare GUIDs instead of calling UnitIsUnit(), which can return a
    -- secret boolean for units like targettarget during restricted combat paths.
    return SafeCompare(unitGuid, playerGuid) == true
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

function SpecCache.GetSpec(unit)
    if not unit or not UnitExists(unit) then return nil end

    local guid = UnitGUID(unit)

    -- Fast path for the player — avoid UnitIsUnit(), which can return a
    -- secret boolean on restricted unit tokens during combat. Use GUID
    -- comparison instead so player aliases like targettarget -> player still
    -- resolve correctly without touching secret booleans.
    if IsPlayerUnit(unit, guid) then
        local spec = GetSpecialization and GetSpecialization()
        if spec then
            local specId = GetSpecializationInfo(spec)
            if specId and specId > 0 then return specId end
        end
    end

    if not HasSafeGuid(guid) then return nil end
    local entry = cache[guid]
    if entry and entry.specId and GetTime() < entry.expiry then
        return entry.specId
    end
    return nil
end

function SpecCache.GetClass(unit)
    if not unit or not UnitExists(unit) then return nil end
    local _, classToken = UnitClass(unit)
    return classToken
end

function SpecCache.SetSpec(unit, specId)
    if not unit or not specId or specId == 0 then return end
    local guid = UnitGUID(unit)
    if not HasSafeGuid(guid) then return end
    cache[guid] = {
        specId = specId,
        classToken = select(2, UnitClass(unit)),
        expiry = GetTime() + CACHE_TTL,
    }
end

function SpecCache.Clear()
    wipe(cache)
    wipe(inspectQueue)
    inspectPending = nil
end

function SpecCache.RequestInspect(unit)
    if not unit or not UnitExists(unit) then return end
    if not UnitIsConnected(unit) then return end

    local guid = UnitGUID(unit)
    if IsPlayerUnit(unit, guid) or not HasSafeGuid(guid) then return end

    -- Already cached and fresh
    local entry = cache[guid]
    if entry and entry.specId and GetTime() < entry.expiry then return end

    -- Queue for inspection
    for _, queued in ipairs(inspectQueue) do
        if queued == unit then return end
    end
    inspectQueue[#inspectQueue + 1] = unit
    SpecCache.EnsureTicker()
end

---------------------------------------------------------------------------
-- INSPECT LOOP
---------------------------------------------------------------------------

local function ProcessInspectQueue()
    -- Don't compete with the user's open InspectFrame. NotifyInspect is a
    -- singleton: a background call here cancels whatever the user is looking
    -- at, so INSPECT_READY fires for the wrong unit and GetInventoryItemLink
    -- returns nil for every slot the user hovers. Pause until they close it;
    -- the ticker is re-armed from InspectFrame's OnHide hook below.
    if InspectFrame and InspectFrame:IsShown() then
        if inspectTicker then
            inspectTicker:Cancel()
            inspectTicker = nil
        end
        return
    end

    -- Timeout stale inspects
    if inspectPending and (GetTime() - inspectStartTime > INSPECT_TIMEOUT) then
        inspectPending = nil
    end

    -- Already inspecting someone
    if inspectPending then return end

    -- Find next valid unit
    while #inspectQueue > 0 do
        local unit = table.remove(inspectQueue, 1)
        if UnitExists(unit) and UnitIsConnected(unit) then
            local guid = UnitGUID(unit)
            local isPlayer = IsPlayerUnit(unit, guid)
            local hasSafeGuid = HasSafeGuid(guid)
            local entry = hasSafeGuid and not isPlayer and cache[guid] or nil
            if hasSafeGuid and not isPlayer and (not entry or not entry.specId or GetTime() >= entry.expiry) then
                local ok = pcall(NotifyInspect, unit)
                if ok then
                    inspectPending = unit
                    inspectStartTime = GetTime()
                    return
                end
            end
        end
    end

    -- Nothing left, stop the ticker
    if inspectTicker then
        inspectTicker:Cancel()
        inspectTicker = nil
    end
end

function SpecCache.EnsureTicker()
    if inspectTicker then return end
    inspectTicker = C_Timer.NewTicker(INSPECT_INTERVAL, ProcessInspectQueue)
end

---------------------------------------------------------------------------
-- EVENT HANDLING
---------------------------------------------------------------------------

-- When InspectFrame closes, resume background spec scanning if anything is
-- queued. ProcessInspectQueue cancels the ticker when InspectFrame is shown,
-- so without this the queue would stall until the next roster update.
local function InstallInspectFrameOnHide()
    if not InspectFrame or InspectFrame.__qui_spec_cache_hook then return end
    InspectFrame.__qui_spec_cache_hook = true
    InspectFrame:HookScript("OnHide", function()
        if #inspectQueue > 0 then
            SpecCache.EnsureTicker()
        end
    end)
end

C_Timer.After(0, function()
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("INSPECT_READY")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("ADDON_LOADED")

    -- Blizzard_InspectUI is load-on-demand; InstallInspectFrameOnHide is
    -- a no-op if the frame doesn't exist yet. Try now in case it's already
    -- loaded, then again whenever it loads.
    InstallInspectFrameOnHide()

    local function QueueAllPartyInspects()
        local numGroup = GetNumGroupMembers() or 0
        if numGroup > 0 then
            local prefix = IsInRaid() and "raid" or "party"
            local max = IsInRaid() and numGroup or (numGroup - 1)
            for i = 1, max do
                SpecCache.RequestInspect(prefix .. i)
            end
        end
    end

    eventFrame:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" and arg1 == "Blizzard_InspectUI" then
            InstallInspectFrameOnHide()
            return
        end

        if event == "INSPECT_READY" then
            if inspectPending then
                local specId = GetInspectSpecialization()
                if specId and specId > 0 and UnitExists(inspectPending) then
                    SpecCache.SetSpec(inspectPending, specId)
                end
                inspectPending = nil
                if #inspectQueue > 0 then
                    SpecCache.EnsureTicker()
                end
            end

        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            -- Party member changed spec mid-dungeon — invalidate their
            -- cached spec and re-inspect. Fires for any unit in the group.
            if arg1 and UnitExists(arg1) then
                local guid = UnitGUID(arg1)
                if HasSafeGuid(guid) then cache[guid] = nil end
                SpecCache.RequestInspect(arg1)
            else
                -- No unit arg or unknown — re-inspect all party members
                QueueAllPartyInspects()
            end

        elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            QueueAllPartyInspects()
        end
    end)
end)

---------------------------------------------------------------------------
-- LIBOPENRAID FALLBACK
---------------------------------------------------------------------------

C_Timer.After(2, function()
    local openRaidLib = LibStub and LibStub:GetLibrary("LibOpenRaid-1.0", true)
    if not openRaidLib then return end

    local callbackObj = {}
    function callbackObj.OnUnitInfoUpdate(unitId, unitInfo)
        if unitInfo and unitInfo.specId and unitInfo.specId > 0 then
            SpecCache.SetSpec(unitId, unitInfo.specId)
        end
    end
    openRaidLib.RegisterCallback(callbackObj, "UnitInfoUpdate", "OnUnitInfoUpdate")
end)
