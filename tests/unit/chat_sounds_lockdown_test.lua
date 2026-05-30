-- tests/unit/chat_sounds_lockdown_test.lua
-- Run: lua tests/unit/chat_sounds_lockdown_test.lua

local function noop() end

local settings = {
    enabled = true,
    newMessageSound = {
        enabled = true,
        entries = {
            { channel = "party", sound = "Ping" },
        },
    },
}

local eventFrame
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent(event) self[event] = true end
    function frame:UnregisterEvent(event) self[event] = nil end
    function frame:SetScript(script, handler)
        if script == "OnEvent" then
            eventFrame = frame
            frame.OnEvent = handler
        end
    end
    return frame
end

local hasSecretChecks = 0
local soundsPlayed = 0

function PlaySoundFile()
    soundsPlayed = soundsPlayed + 1
end

function UnitGUID()
    return "Player-1-SELF"
end

function UnitName()
    return "Tester"
end

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        HasSecretValue = function()
            hasSecretChecks = hasSecretChecks + 1
            return true
        end,
    },
    LSM = {
        Fetch = function(_, _, name) return name end,
    },
    QUI = {
        Chat = {
            _internals = {
                GetSettings = function() return settings end,
                IsChatEnabled = function(s) return s and s.enabled ~= false end,
                IsChatMessagingLockedDown = function() return true end,
            },
        },
    },
}

assert(loadfile("modules/chat/sounds.lua"))("QUI", ns)
ns.QUI.Chat.Sounds.Setup()

assert(eventFrame and eventFrame.OnEvent, "sound event frame should be installed")

eventFrame.OnEvent(eventFrame, "CHAT_MSG_PARTY", "secret text", "PartyMember-Realm")

assert(hasSecretChecks == 0, "chat sounds must not inspect party payloads during chat messaging lockdown")
assert(soundsPlayed == 0, "chat sounds must not play while chat messaging lockdown is active")

print("OK: chat_sounds_lockdown_test")
