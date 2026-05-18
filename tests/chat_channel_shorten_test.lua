-- tests/chat_channel_shorten_test.lua
-- Run: lua tests/chat_channel_shorten_test.lua

local unpack = unpack

local function noop() end

local settings = {
    enabled = true,
    modifiers = {
        channelShorten = {
            enabled = true,
            preset = "number",
        },
    },
}

local function newChatFrame()
    local frame = { messages = {} }

    function frame:AddMessage(message, r, g, b, infoID, accessID, typeID, event, eventArgs, formatter, ...)
        self.messages[#self.messages + 1] = {
            message, r, g, b, infoID, accessID, typeID, event, eventArgs, formatter, ...
        }
    end

    function frame:TransformMessages(predicate, transform)
        for i = 1, #self.messages do
            local message = self.messages[i]
            if predicate(unpack(message)) then
                self.messages[i] = { transform(unpack(message)) }
            end
        end
    end

    return frame
end

function hooksecurefunc(target, method, func)
    if type(target) == "table" then
        local original = target[method] or noop
        target[method] = function(self, ...)
            local results = { original(self, ...) }
            func(self, ...)
            return unpack(results)
        end
        return
    end
end

function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript() end
    return frame
end

local chatFrame = newChatFrame()
NUM_CHAT_WINDOWS = 1
ChatFrame1 = chatFrame

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
    },
    QUI = {
        Chat = {
            _afterRefresh = {},
            _internals = {
                GetSettings = function() return settings end,
                IsChatEnabled = function(s) return s and s.enabled ~= false end,
                IsChatMessagingLockedDown = function() return false end,
            },
        },
    },
}

assert(loadfile("modules/chat/modifiers/channel_shorten.lua"))("QUI", ns)

local playerLink = "|Hplayer:Dailyk-Sargeras:357:CHANNEL:2|h[Dailyk]|h"
local itemLink = "|Hitem:213257::::::::80:250:::::::::|h[4. Crafted Thing]|h"

chatFrame:AddMessage(
    "|Hchannel:channel:2|h[2. Trade - Services]|h " .. playerLink .. ": LF crafter " .. itemLink,
    1, 1, 1,
    1, 0, 0,
    "CHAT_MSG_CHANNEL",
    { [11] = 357 }
)

assert(
    chatFrame.messages[1][1] == "[2] " .. playerLink .. ": LF crafter " .. itemLink,
    "number preset should replace only the leading channel hyperlink; actual: " .. tostring(chatFrame.messages[1][1])
)

chatFrame:AddMessage(
    "[2] " .. playerLink .. ": LF crafter " .. itemLink,
    1, 1, 1,
    1, 0, 0,
    "CHAT_MSG_CHANNEL",
    { [11] = 358 }
)

assert(
    chatFrame.messages[2][1] == "[2] " .. playerLink .. ": LF crafter " .. itemLink,
    "already-shortened channel lines must not rewrite body hyperlinks; actual: " .. tostring(chatFrame.messages[2][1])
)

settings.modifiers.channelShorten.preset = "letter"
ns.QUI.Chat._afterRefresh[1]()

chatFrame:AddMessage(
    "8:35 AM |Hchannel:channel:2|h[2. Trade - Stormwind]|h " .. playerLink .. ": LF crafter",
    1, 1, 1,
    1, 0, 0,
    "CHAT_MSG_CHANNEL",
    { [11] = 359 }
)

assert(
    chatFrame.messages[3][1] == "8:35 AM [T] " .. playerLink .. ": LF crafter",
    "letter preset should shorten the leading channel hyperlink after timestamps; actual: " .. tostring(chatFrame.messages[3][1])
)

print("OK: chat_channel_shorten_test")
