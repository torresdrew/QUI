-- tests/chat_tab_filters_temporary_frame_taint_test.lua
-- Run: lua tests/chat_tab_filters_temporary_frame_taint_test.lua

function InCombatLockdown() return false end

local createdFrames = {}
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript(script, handler)
        if script == "OnEvent" then
            frame.OnEvent = handler
        end
    end
    createdFrames[#createdFrames + 1] = frame
    return frame
end

local normalFrame = {
    messageTypeList = { "SAY" },
    channelList = {},
}
function normalFrame:IsForbidden() return false end

local tempWhisperFrame = {
    isTemporary = true,
    privateMessageList = { ["noirelle-tarrenmill"] = true },
    messageTypeList = { "SAY" },
    channelList = {},
}
function tempWhisperFrame:IsForbidden() return false end

local calls = {}
function ChatFrame_AddMessageGroup(frame, group)
    calls[#calls + 1] = { op = "addGroup", frame = frame, value = group }
    frame.messageTypeList[#frame.messageTypeList + 1] = group
end
function ChatFrame_RemoveMessageGroup(frame, group)
    calls[#calls + 1] = { op = "removeGroup", frame = frame, value = group }
end
function ChatFrame_AddChannel(frame, channel)
    calls[#calls + 1] = { op = "addChannel", frame = frame, value = channel }
end
function ChatFrame_RemoveChannel(frame, channel)
    calls[#calls + 1] = { op = "removeChannel", frame = frame, value = channel }
end

NUM_CHAT_WINDOWS = 11
_G.ChatFrame1 = normalFrame
_G.ChatFrame11 = tempWhisperFrame
SlashCmdList = {}

local settings = {
    enabled = true,
    tabs = {
        [1] = {
            customized = true,
            groups = { "SAY", "SYSTEM" },
            channels = {},
        },
        [11] = {
            customized = true,
            groups = { "SYSTEM" },
            channels = { "General" },
        },
    },
}

local ns = {
    QUI = {
        Chat = {
            _afterRefresh = {},
            _internals = {
                GetSettings = function() return settings end,
                IsChatEnabled = function(s) return s and s.enabled ~= false end,
                IsChatMessagingLockedDown = function() return false end,
                IsTemporaryChatFrame = function(frame)
                    return frame and frame.isTemporary == true
                end,
            },
        },
    },
}

assert(loadfile("modules/chat/tab_filters.lua"))("QUI", ns)

assert(calls[1] and calls[1].frame == normalFrame and calls[1].value == "SYSTEM",
    "normal chat frames should still reconcile configured message groups")

for i = 1, #calls do
    assert(calls[i].frame ~= tempWhisperFrame,
        "temporary/private whisper frames must not be reconciled through Blizzard chat filter APIs")
end

local before = #calls
ns.QUI.Chat.TabFilters.ReconcileFrame(tempWhisperFrame, 11)
ns.QUI.Chat.TabFilters.SaveTabConfig(11, { "SYSTEM", "WHISPER" }, { "General" })

assert(#calls == before,
    "direct tab-filter calls should also leave temporary/private whisper frames untouched")

print("OK: chat_tab_filters_temporary_frame_taint_test")
