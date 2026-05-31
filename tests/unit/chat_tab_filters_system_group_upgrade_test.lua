-- tests/unit/chat_tab_filters_system_group_upgrade_test.lua
-- Run: lua tests/unit/chat_tab_filters_system_group_upgrade_test.lua

function InCombatLockdown() return false end

function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript(script, handler)
        if script == "OnEvent" then
            frame.OnEvent = handler
        end
    end
    return frame
end

local normalFrame = {
    messageTypeList = { "SYSTEM" },
    channelList = {},
}
function normalFrame:IsForbidden() return false end

local calls = {}
local function appendUnique(list, value)
    for i = 1, #list do
        if list[i] == value then return end
    end
    list[#list + 1] = value
end

local function removeValue(list, value)
    for i = #list, 1, -1 do
        if list[i] == value then
            table.remove(list, i)
        end
    end
end

function ChatFrame_AddMessageGroup(frame, group)
    calls[#calls + 1] = { op = "addGroup", frame = frame, value = group }
    appendUnique(frame.messageTypeList, group)
end

function ChatFrame_RemoveMessageGroup(frame, group)
    calls[#calls + 1] = { op = "removeGroup", frame = frame, value = group }
    removeValue(frame.messageTypeList, group)
end

function ChatFrame_AddChannel(frame, channel)
    calls[#calls + 1] = { op = "addChannel", frame = frame, value = channel }
end

function ChatFrame_RemoveChannel(frame, channel)
    calls[#calls + 1] = { op = "removeChannel", frame = frame, value = channel }
end

NUM_CHAT_WINDOWS = 1
_G.ChatFrame1 = normalFrame
SlashCmdList = {}

local settings = {
    enabled = true,
    tabs = {
        [1] = {
            customized = true,
            groups = { "SYSTEM" },
            channels = {},
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
                IsTemporaryChatFrame = function() return false end,
            },
        },
    },
}

local function hasGroup(list, group)
    for i = 1, #list do
        if list[i] == group then return true end
    end
    return false
end

local function sawCall(op, value)
    for i = 1, #calls do
        if calls[i].op == op and calls[i].value == value then return true end
    end
    return false
end

assert(loadfile("modules/chat/tab_filters.lua"))("QUI", ns)

local groups = ns.QUI.Chat.TabFilters.GetStandardGroups()
assert(hasGroup(groups, "PING"), "tab filter group choices must include PING")
assert(hasGroup(groups, "BN_INLINE_TOAST_ALERT"), "tab filter group choices must include inline toast alerts")

assert(hasGroup(settings.tabs[1].groups, "PING"),
    "legacy SYSTEM tab filters should be upgraded to include ping messages")
assert(hasGroup(settings.tabs[1].groups, "BN_INLINE_TOAST_ALERT"),
    "legacy SYSTEM tab filters should be upgraded to include inline toast alerts")
assert(sawCall("addGroup", "PING"), "upgraded ping group should be applied to the chat frame")
assert(settings.tabs[1]._groupsVersion == ns.QUI.Chat.TabFilters.GROUPS_VERSION,
    "upgraded tab filters should be version-stamped")

calls = {}
settings.tabs[1].groups = { "SYSTEM" }
settings.tabs[1]._groupsVersion = ns.QUI.Chat.TabFilters.GROUPS_VERSION
normalFrame.messageTypeList = { "SYSTEM", "PING" }

ns.QUI.Chat.TabFilters.ReconcileFrame(normalFrame, 1)

assert(not hasGroup(settings.tabs[1].groups, "PING"),
    "current-version configs should preserve an explicit ping deselection")
assert(sawCall("removeGroup", "PING"),
    "current-version configs should still be able to remove ping from a tab")

print("OK: chat_tab_filters_system_group_upgrade_test")
