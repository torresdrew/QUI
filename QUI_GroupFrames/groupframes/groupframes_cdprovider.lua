--[[
    QUI Group Frames - External Cooldown-Tracker Frame Provider

    Hands QUI's party frames to an external cooldown-tracker addon's public
    frame-provider API so its per-member cooldown icons anchor to our party
    frames. Party only -- raid is intentionally excluded.

    Self-contained adapter: no edits to groupframes.lua. Reads the published
    module handle ns.QUI_GroupFrames and hooks its public refresh methods.
]]

local ADDON_NAME, ns = ...

local QUI_GF = ns.QUI_GroupFrames

-- Upvalue standard globals used on callback paths.
local pairs = pairs
local type = type
local IsInRaid = IsInRaid
local C_Timer = C_Timer

local registered = false       -- provider handed to the external API (once/session)
local refreshCb                -- consumer-supplied "frames changed" callback
local notifyScheduled = false  -- debounce flag for Notify

---------------------------------------------------------------------------
-- Provider object handed to the external API.
---------------------------------------------------------------------------
local provider = {
    Name = "QUI",

    -- Flat array of the CURRENT party unit frames. Party only: empty while
    -- IsInRaid(), and raid* unit tokens are filtered out. The consumer reads
    -- each frame's secure unit attribute itself (GetAttribute("unit")).
    GetFrames = function()
        local out = {}
        if not (QUI_GF and QUI_GF.IsEnabled and QUI_GF:IsEnabled()) then
            return out
        end
        if IsInRaid() then
            return out
        end
        local map = QUI_GF.unitFrameMap
        if map then
            for unit, list in pairs(map) do
                if type(unit) == "string" and not unit:find("^raid%d") then
                    for i = 1, #list do
                        out[#out + 1] = list[i]
                    end
                end
            end
        end
        return out
    end,

    -- Store the consumer's callback; QUI calls it when the party frame set changes.
    RegisterRefreshFrames = function(cb)
        refreshCb = cb
    end,
}

---------------------------------------------------------------------------
-- Registration handshake (one-shot; handles either load order).
---------------------------------------------------------------------------
local function TryRegister()
    if registered then return true end
    local api = _G.MiniCCApi
    if not (api and api.v1 and api.v1.RegisterFrameProvider) then
        return false
    end
    -- bulkhead: never let a third-party error break QUI login/refresh.
    local ok = ns.SafeCallMethod("bulkhead", api.v1, "RegisterFrameProvider", provider)
    if ok then
        registered = true
    end
    return registered
end

---------------------------------------------------------------------------
-- Refresh notification (debounced one frame).
---------------------------------------------------------------------------
local function Notify()
    if not (registered and refreshCb) then return end
    if notifyScheduled then return end
    notifyScheduled = true
    C_Timer.After(0, function()
        notifyScheduled = false
        local cb = refreshCb
        if cb then ns.SafeCall("bulkhead", cb) end
    end)
end

-- Notify on the module's central refresh choke point (roster + settings/layout)
-- and on teardown (frames gone -> GetFrames now empty).
if QUI_GF then
    if QUI_GF.RefreshAllFrames then
        hooksecurefunc(QUI_GF, "RefreshAllFrames", Notify)
    end
    if QUI_GF.Disable then
        hooksecurefunc(QUI_GF, "Disable", Notify)
    end
end

---------------------------------------------------------------------------
-- Event driver: attempt registration at login and whenever another addon
-- loads (covers the external addon loading after us). Probe the global only.
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self)
    if TryRegister() then
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
