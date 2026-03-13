--[[
    QUI Tooltip Inspect Service
    Provides cached, serialized inspect-backed player tooltip data.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local TooltipInspect = {}

local GameTooltip = GameTooltip
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

local CACHE_TTL = 600
local CACHE_MAX_SIZE = 200
local REQUEST_DELAY = 0.05
local REQUEST_TIMEOUT = 1.5

local cache = {}
local cacheSize = 0
local accessCounter = 0
local activeRequest = nil
local activeTimeout = nil
local queuedRequest = nil
local refreshCallback = nil

local function GetInspectFrame()
    return _G.InspectFrame
end

local COUNTED_SLOTS = {
    [INVSLOT_HEAD] = true,
    [INVSLOT_NECK] = true,
    [INVSLOT_SHOULDER] = true,
    [INVSLOT_BACK] = true,
    [INVSLOT_CHEST] = true,
    [INVSLOT_WAIST] = true,
    [INVSLOT_LEGS] = true,
    [INVSLOT_FEET] = true,
    [INVSLOT_WRIST] = true,
    [INVSLOT_HAND] = true,
    [INVSLOT_FINGER1] = true,
    [INVSLOT_FINGER2] = true,
    [INVSLOT_TRINKET1] = true,
    [INVSLOT_TRINKET2] = true,
    [INVSLOT_MAINHAND] = true,
    [INVSLOT_OFFHAND] = true,
}

local function TouchCacheEntry(entry)
    accessCounter = accessCounter + 1
    entry.lastAccess = accessCounter
end

local function RemoveCacheEntry(guid)
    if cache[guid] then
        cache[guid] = nil
        cacheSize = math.max(0, cacheSize - 1)
    end
end

local function PruneCache()
    if cacheSize <= CACHE_MAX_SIZE then return end

    local oldestGUID, oldestAccess = nil, nil
    for guid, entry in pairs(cache) do
        local entryAccess = entry.lastAccess or 0
        if not oldestAccess or entryAccess < oldestAccess then
            oldestGUID = guid
            oldestAccess = entryAccess
        end
    end

    if oldestGUID then
        RemoveCacheEntry(oldestGUID)
    end
end

local function GetCacheEntry(guid)
    if not guid then return nil end

    local entry = cache[guid]
    if not entry then return nil end

    if (GetTime() - (entry.timestamp or 0)) > CACHE_TTL then
        RemoveCacheEntry(guid)
        return nil
    end

    TouchCacheEntry(entry)
    return entry
end

local function StoreCacheEntry(guid, data)
    if not guid or type(data) ~= "table" then return end
    if not data.itemLevel or data.itemLevel <= 0 then return end

    local entry = cache[guid]
    if not entry then
        entry = {}
        cache[guid] = entry
        cacheSize = cacheSize + 1
    end

    entry.itemLevel = data.itemLevel
    entry.specName = data.specName
    entry.className = data.className
    entry.classToken = data.classToken
    entry.timestamp = GetTime()
    TouchCacheEntry(entry)
    PruneCache()
end

local function ResolveTooltipUnit(tooltip)
    if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then return nil end

    local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
    if not ok or not unit then return nil end

    if Helpers.IsSecretValue(unit) then
        unit = UnitExists("mouseover") and "mouseover" or nil
    end

    return unit
end

local function ResolveLiveUnit(guid, preferredUnit)
    if preferredUnit and UnitExists(preferredUnit) and UnitGUID(preferredUnit) == guid then
        return preferredUnit
    end

    local tooltipUnit = ResolveTooltipUnit(GameTooltip)
    if tooltipUnit and UnitGUID(tooltipUnit) == guid then
        return tooltipUnit
    end

    local inspectFrame = GetInspectFrame()
    local inspectUnit = inspectFrame and inspectFrame.unit
    if inspectUnit and UnitExists(inspectUnit) and UnitGUID(inspectUnit) == guid then
        return inspectUnit
    end

    if UnitExists("mouseover") and UnitGUID("mouseover") == guid then
        return "mouseover"
    end

    if UnitExists("target") and UnitGUID("target") == guid then
        return "target"
    end

    if UnitExists("focus") and UnitGUID("focus") == guid then
        return "focus"
    end

    return nil
end

local function IsMainHand2H(unit)
    local itemLink = GetInventoryItemLink(unit, INVSLOT_MAINHAND)
    if not itemLink then return false end

    local ok, _, _, _, _, _, _, _, _, equipSlot = pcall(C_Item.GetItemInfo, itemLink)
    if not ok then return false end
    return equipSlot == "INVTYPE_2HWEAPON"
end

local function CalculateFallbackItemLevel(unit)
    local shared = ns.QUI and ns.QUI.CharacterShared
    local getSlotItemLevel = shared and shared.GetSlotItemLevel
    if not getSlotItemLevel then return nil end

    local totalItemLevel = 0
    local slotCount = 0
    local is2H = IsMainHand2H(unit)

    for slotId in pairs(COUNTED_SLOTS) do
        if slotId == INVSLOT_OFFHAND and is2H then
            local mainHandLevel = getSlotItemLevel(unit, INVSLOT_MAINHAND)
            if mainHandLevel and mainHandLevel > 0 then
                totalItemLevel = totalItemLevel + mainHandLevel
                slotCount = slotCount + 1
            end
        else
            local itemLevel = getSlotItemLevel(unit, slotId)
            if itemLevel and itemLevel > 0 then
                totalItemLevel = totalItemLevel + itemLevel
                slotCount = slotCount + 1
            end
        end
    end

    if slotCount > 0 then
        return totalItemLevel / slotCount
    end

    return nil
end

local function ReadInspectedItemLevel(unit)
    if not unit or not UnitExists(unit) then return nil end

    if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
        local ok, itemLevel = pcall(function()
            return C_PaperDollInfo.GetInspectItemLevel(unit)
        end)
        if ok and itemLevel and itemLevel > 0 then
            return itemLevel
        end
    end

    return CalculateFallbackItemLevel(unit)
end

local function GetClassData(unit)
    if not unit or not UnitExists(unit) then return nil, nil end

    local localizedClassName, classToken, classID = UnitClass(unit)
    if classID and C_CreatureInfo and C_CreatureInfo.GetClassInfo then
        local classInfo = C_CreatureInfo.GetClassInfo(classID)
        if classInfo and classInfo.className then
            localizedClassName = classInfo.className
        end
    end

    return localizedClassName or classToken, classToken
end

local function GetSpecName(unit, useInspectData)
    if not unit or not UnitExists(unit) then return nil end

    if useInspectData then
        local specID = GetInspectSpecialization(unit)
        if specID and specID > 0 then
            local _, specName = GetSpecializationInfoByID(specID)
            return specName
        end
        return nil
    end

    if UnitIsUnit(unit, "player") then
        local specIndex = GetSpecialization()
        if specIndex then
            local _, specName = GetSpecializationInfo(specIndex)
            return specName
        end
    end

    return nil
end

local function BuildPlayerData(unit, itemLevel, useInspectData)
    if not itemLevel or itemLevel <= 0 then return nil end

    local className, classToken = GetClassData(unit)
    return {
        itemLevel = itemLevel,
        specName = GetSpecName(unit, useInspectData),
        className = className,
        classToken = classToken,
    }
end

local function ClearActiveRequest()
    activeRequest = nil

    if activeTimeout and activeTimeout.Cancel then
        activeTimeout:Cancel()
    end
    activeTimeout = nil
end

local ProcessQueuedRequest

local function FinalizeRequest(matchingGUID)
    if activeRequest and activeRequest.guid == matchingGUID then
        if type(ClearInspectPlayer) == "function" then
            pcall(ClearInspectPlayer)
        end
        ClearActiveRequest()
        ProcessQueuedRequest()
    end
end

function TooltipInspect:RegisterRefreshCallback(callback)
    refreshCallback = callback
end

function TooltipInspect:GetCachedPlayerData(unit)
    if not unit or not UnitExists(unit) then return nil end

    local guid = UnitGUID(unit)
    if not guid then return nil end

    if UnitIsUnit(unit, "player") then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local playerData = BuildPlayerData(unit, equipped, false)
            if playerData then
                StoreCacheEntry(guid, playerData)
                return playerData
            end
        end
    end

    return GetCacheEntry(guid)
end

function TooltipInspect:GetCachedItemLevel(unit)
    local playerData = self:GetCachedPlayerData(unit)
    return playerData and playerData.itemLevel or nil
end

function TooltipInspect:QueueInspect(unit)
    if not unit or not UnitExists(unit) or InCombatLockdown() then return false end
    if not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return false end

    local guid = UnitGUID(unit)
    if not guid or GetCacheEntry(guid) then return false end

    -- Avoid competing with the dedicated inspect pane's own NotifyInspect flow.
    local inspectFrame = GetInspectFrame()
    if inspectFrame and inspectFrame:IsShown() then
        return false
    end

    if activeRequest and activeRequest.guid == guid then
        return false
    end

    if queuedRequest and queuedRequest.guid == guid then
        return false
    end

    local ok, canInspect = pcall(function()
        return CanInspect(unit)
    end)
    if not ok or not canInspect then
        return false
    end

    queuedRequest = {
        guid = guid,
        unit = unit,
    }

    ProcessQueuedRequest()
    return true
end

ProcessQueuedRequest = function()
    if activeRequest or not queuedRequest then return end

    local request = queuedRequest
    queuedRequest = nil

    C_Timer.After(REQUEST_DELAY, function()
        if activeRequest then
            queuedRequest = request
            return
        end

        local unit = request.unit
        local guid = request.guid
        if not unit or not guid then return end
        if not UnitExists(unit) or UnitGUID(unit) ~= guid then return end
        if InCombatLockdown() then return end

        local ok, canInspect = pcall(function()
            return CanInspect(unit)
        end)
        if not ok or not canInspect then
            return
        end

        activeRequest = {
            guid = guid,
            unit = unit,
            startedAt = GetTime(),
        }

        NotifyInspect(unit)

        activeTimeout = C_Timer.After(REQUEST_TIMEOUT, function()
            FinalizeRequest(guid)
        end)
    end)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("INSPECT_READY")
eventFrame:SetScript("OnEvent", function(_, event, guid)
    if event ~= "INSPECT_READY" or not guid then return end

    local preferredUnit = activeRequest and activeRequest.guid == guid and activeRequest.unit or nil
    local unit = ResolveLiveUnit(guid, preferredUnit)
    if unit then
        local itemLevel = ReadInspectedItemLevel(unit)
        if itemLevel and itemLevel > 0 then
            local playerData = BuildPlayerData(unit, itemLevel, true)
            if playerData then
                StoreCacheEntry(guid, playerData)
            end
            if refreshCallback then
                refreshCallback(guid, playerData)
            end
        end
    end

    FinalizeRequest(guid)
end)

ns.TooltipInspect = TooltipInspect
