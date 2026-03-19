---------------------------------------------------------------------------
-- QUI Event Mixin
-- Lightweight event handling without AceEvent-3.0 overhead.
-- Uses a single hidden frame per consumer with direct handler lookup.
-- API mirrors AceEvent for familiarity.
--
-- Usage:
--   local MyModule = {}
--   ns.EventMixin:Embed(MyModule)
--   MyModule:RegisterEvent("PLAYER_REGEN_ENABLED", function(self, event) ... end)
--   MyModule:RegisterUnitEvent("UNIT_HEALTH", "player", function(self, event, unit) ... end)
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local type = type
local pairs = pairs
local wipe = wipe
local CreateFrame = CreateFrame

local EventMixin = {}
ns.EventMixin = EventMixin

--- Embed event methods into a target table.
--- Creates a hidden frame for event dispatch and wires convenience methods.
--- @param target table The module or object to embed into
function EventMixin:Embed(target)
    local frame = CreateFrame("Frame")
    local handlers = {}

    frame:SetScript("OnEvent", function(_, event, ...)
        local cb = handlers[event]
        if cb then
            cb(target, event, ...)
        end
    end)

    target._eventFrame = frame
    target._eventHandlers = handlers

    function target:RegisterEvent(event, callback)
        if type(callback) == "string" then
            local methodName = callback
            handlers[event] = function(s, e, ...) s[methodName](s, e, ...) end
        elseif type(callback) == "function" then
            handlers[event] = callback
        else
            -- No callback: dispatch to self[event]
            handlers[event] = function(s, e, ...) s[e](s, e, ...) end
        end
        frame:RegisterEvent(event)
    end

    function target:RegisterUnitEvent(event, unit1, unit2, callback)
        -- Support both (event, unit, callback) and (event, unit1, unit2, callback)
        if type(unit2) == "function" then
            callback = unit2
            unit2 = nil
        end
        if type(callback) == "function" then
            handlers[event] = callback
        else
            handlers[event] = function(s, e, ...) s[e](s, e, ...) end
        end
        if unit2 then
            frame:RegisterUnitEvent(event, unit1, unit2)
        else
            frame:RegisterUnitEvent(event, unit1)
        end
    end

    function target:UnregisterEvent(event)
        handlers[event] = nil
        frame:UnregisterEvent(event)
    end

    function target:UnregisterAllEvents()
        for event in pairs(handlers) do
            frame:UnregisterEvent(event)
        end
        wipe(handlers)
    end

    function target:IsEventRegistered(event)
        return handlers[event] ~= nil
    end
end
