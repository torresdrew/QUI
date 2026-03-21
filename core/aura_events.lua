--[[
    QUI Centralized Aura Event Dispatcher
    Single UNIT_AURA registration with pub-sub dispatch to all consumers.
    Eliminates 7+ independent event handlers each doing their own aura scanning.

    Usage:
        ns.AuraEvents:Subscribe("player", callback)    -- player auras only
        ns.AuraEvents:Subscribe("group", callback)      -- party/raid units
        ns.AuraEvents:Subscribe("all", callback)        -- all units
    Callback signature: callback(unit, updateInfo)
]]

local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- DISPATCHER
---------------------------------------------------------------------------
local AuraEvents = {}
ns.AuraEvents = AuraEvents

-- Subscriber lists by filter
local subscribers = {
    player = {},   -- only unit == "player"
    group  = {},   -- party/raid units (not player)
    all    = {},   -- every UNIT_AURA event
}

function AuraEvents:Subscribe(filter, callback)
    local list = subscribers[filter]
    if not list then
        error("AuraEvents:Subscribe invalid filter '" .. tostring(filter) .. "', use 'player', 'group', or 'all'")
    end
    -- Avoid duplicate subscriptions
    for _, cb in ipairs(list) do
        if cb == callback then return end
    end
    list[#list + 1] = callback
end

function AuraEvents:Unsubscribe(filter, callback)
    local list = subscribers[filter]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == callback then
            table.remove(list, i)
            return
        end
    end
end

---------------------------------------------------------------------------
-- COALESCING FRAME: batches all UNIT_AURA events within the same render
-- frame into a single dispatch pass (zero-allocation, automatic).
---------------------------------------------------------------------------
local pendingUnits = {}  -- [unit] = updateInfo or true
local coalesceFrame = CreateFrame("Frame")
coalesceFrame:Hide()

coalesceFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    for unit, updateInfo in pairs(pendingUnits) do
        local info = updateInfo ~= true and updateInfo or nil

        -- Dispatch to "all" subscribers
        for _, cb in ipairs(subscribers.all) do
            cb(unit, info)
        end

        -- Dispatch to filtered subscribers
        if unit == "player" then
            for _, cb in ipairs(subscribers.player) do
                cb(unit, info)
            end
        else
            for _, cb in ipairs(subscribers.group) do
                cb(unit, info)
            end
        end
    end
    wipe(pendingUnits)
end)

---------------------------------------------------------------------------
-- SINGLE EVENT REGISTRATION
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:SetScript("OnEvent", function(self, event, unit, updateInfo)
    -- Store updateInfo; if any event for this unit is a full update, mark full.
    local existing = pendingUnits[unit]
    if existing == true then
        -- Already marked as full update
    elseif updateInfo and updateInfo.isFullUpdate then
        pendingUnits[unit] = true
    else
        pendingUnits[unit] = updateInfo or true
    end
    coalesceFrame:Show()
end)
