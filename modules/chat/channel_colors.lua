---------------------------------------------------------------------------
-- QUI Chat Module — Per-Channel Color Overrides
-- Stores user-chosen colors for built-in chat types (SAY/YELL/...) and
-- joined custom channels by NAME (not slot). Re-applies on PLAYER_LOGIN
-- and CHANNEL_UI_UPDATE so a channel's color follows its name across
-- rejoins / sessions / characters.
--
-- Storage: db.profile.chat.channelColors = { [key] = {r, g, b}, ... }
--   - Built-in keys: uppercase strings (SAY, RAID, WHISPER, ...).
--   - Custom keys: channel name as joined ("Trade", "LookingForGroup").
--
-- Baselines: captured at PLAYER_LOGIN BEFORE applying overrides, used to
-- restore Blizzard's default color when the user resets a row. Not
-- persisted; recaptured each session.
---------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local I = assert(ns.QUI.Chat and ns.QUI.Chat._internals,
    "QUI Chat: channel_colors.lua loaded before chat.lua. Check chat.xml — chat.lua must precede channel_colors.lua.")

ns.QUI.Chat.ChannelColors = ns.QUI.Chat.ChannelColors or {}
local ChannelColors = ns.QUI.Chat.ChannelColors

-- Public list of editable built-in chat-type keys, in dropdown display order.
local BUILTIN_KEYS = {
    "SAY", "YELL", "EMOTE",
    "PARTY", "PARTY_LEADER",
    "RAID", "RAID_LEADER", "RAID_WARNING",
    "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER",
    "GUILD", "OFFICER",
    "WHISPER", "WHISPER_INFORM",
    "BN_WHISPER", "BN_WHISPER_INFORM",
    "SYSTEM",
}
ChannelColors.BUILTIN_KEYS = BUILTIN_KEYS

-- Friendly display labels for the dropdown.
local BUILTIN_LABELS = {
    SAY = "Say",
    YELL = "Yell",
    EMOTE = "Emote",
    PARTY = "Party",
    PARTY_LEADER = "Party Leader",
    RAID = "Raid",
    RAID_LEADER = "Raid Leader",
    RAID_WARNING = "Raid Warning",
    INSTANCE_CHAT = "Instance",
    INSTANCE_CHAT_LEADER = "Instance Leader",
    GUILD = "Guild",
    OFFICER = "Officer",
    WHISPER = "Whisper",
    WHISPER_INFORM = "Whisper (sent)",
    BN_WHISPER = "BN Whisper",
    BN_WHISPER_INFORM = "BN Whisper (sent)",
    SYSTEM = "System",
}
ChannelColors.BUILTIN_LABELS = BUILTIN_LABELS

-- Closed-set membership for fast O(1) discrimination of built-in chat-type
-- keys vs. arbitrary channel names. Built once at file load.
local BUILTIN_SET = {}
for i = 1, #BUILTIN_KEYS do BUILTIN_SET[BUILTIN_KEYS[i]] = true end

local CHANNEL_SLOT_CAP = 20  -- Blizzard's hard cap for numbered channels.

-- File-local: baselines[key] = {r, g, b} for built-ins + every CHANNEL%d slot.
local baselines = {}
local baselinesCaptured = false

-- Built-in chat-type keys are a closed set defined above; channel names are
-- arbitrary user strings. Use literal membership rather than a regex so
-- channel names that happen to be all uppercase (e.g. "PVP", "EU", "LFG")
-- aren't misclassified as built-ins.
local function isBuiltinKey(key)
    if type(key) ~= "string" then return false end
    return BUILTIN_SET[key] == true
end

local function captureBaselines()
    if type(ChatTypeInfo) ~= "table" then return end

    -- Built-ins. Skip keys that already have a baseline so we don't echo our
    -- own override back as the "default" if the function is called twice.
    for i = 1, #BUILTIN_KEYS do
        local key = BUILTIN_KEYS[i]
        if not baselines[key] then
            local info = ChatTypeInfo[key]
            if info and info.r ~= nil then
                baselines[key] = { info.r, info.g, info.b }
            end
        end
    end

    -- CHANNEL slots. Some entries init lazily, so this function is allowed to
    -- be called multiple times — first PLAYER_LOGIN, then again on every
    -- CHANNEL_UI_UPDATE — to fill in slots as Blizzard initializes them.
    for slot = 1, CHANNEL_SLOT_CAP do
        local key = "CHANNEL" .. slot
        if not baselines[key] then
            local info = ChatTypeInfo[key]
            if info and info.r ~= nil then
                baselines[key] = { info.r, info.g, info.b }
            end
        end
    end

    baselinesCaptured = true
end

-- Walk GetChannelList() and return a name → "CHANNEL%d" map.
-- GetChannelList returns id1, name1, header1, id2, name2, header2, ...
local function buildNameToSlotMap()
    local map = {}
    if type(GetChannelList) ~= "function" then return map end
    local data = { GetChannelList() }
    for i = 1, #data, 3 do
        local slot, name, header = data[i], data[i + 1], data[i + 2]
        if slot and name and not header then
            map[name] = "CHANNEL" .. slot
        end
    end
    return map
end

local function getDB()
    local db = _G.QUI and _G.QUI.db and _G.QUI.db.profile and _G.QUI.db.profile.chat
    if not db then return nil end
    db.channelColors = db.channelColors or {}
    return db.channelColors
end

local function applyBuiltins()
    local store = getDB()
    if not store then return end
    if type(ChangeChatColor) ~= "function" then return end
    for i = 1, #BUILTIN_KEYS do
        local key = BUILTIN_KEYS[i]
        local c = store[key]
        if c then ChangeChatColor(key, c[1], c[2], c[3]) end
    end
end

local function applyCustoms()
    local store = getDB()
    if not store then return end
    if type(ChangeChatColor) ~= "function" then return end
    local nameToSlot = buildNameToSlotMap()
    for name, slotKey in pairs(nameToSlot) do
        local c = store[name]
        if c then ChangeChatColor(slotKey, c[1], c[2], c[3]) end
    end
end

local function applyAll()
    applyBuiltins()
    applyCustoms()
end

-- Walk every key we manage (built-ins + currently joined channels). For
-- each key NOT overridden by the active profile, restore its baseline.
-- Used on profile import/switch where the previous profile's overrides
-- may still be live in ChatTypeInfo from when they were applied.
local function revertUnmanaged()
    local store = getDB()
    if not store then return end
    if type(ChangeChatColor) ~= "function" then return end

    for i = 1, #BUILTIN_KEYS do
        local key = BUILTIN_KEYS[i]
        if store[key] == nil then
            local b = baselines[key]
            if b then ChangeChatColor(key, b[1], b[2], b[3]) end
        end
    end

    local nameToSlot = buildNameToSlotMap()
    for name, slotKey in pairs(nameToSlot) do
        if store[name] == nil then
            local b = baselines[slotKey]
            if b then ChangeChatColor(slotKey, b[1], b[2], b[3]) end
        end
    end
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

-- Returns "CHANNEL%d" for a given joined channel name, or nil if the user
-- isn't currently in that channel.
function ChannelColors.SlotForChannel(name)
    if type(name) ~= "string" or name == "" then return nil end
    return buildNameToSlotMap()[name]
end

function ChannelColors.IsBuiltin(key)
    return isBuiltinKey(key)
end

function ChannelColors.HasOverride(key)
    local store = getDB()
    return (store and store[key] ~= nil) or false
end

-- Returns r, g, b for the currently effective color (override if set,
-- else captured baseline, else live ChatTypeInfo, else white).
function ChannelColors.GetEffective(key)
    local store = getDB()
    local c = store and store[key]
    if c then return c[1], c[2], c[3] end

    -- Baseline lookup. For customs, baseline is keyed by the CURRENT slot.
    local lookupKey = key
    if not isBuiltinKey(key) then
        lookupKey = ChannelColors.SlotForChannel(key)
    end
    local b = lookupKey and baselines[lookupKey]
    if b then return b[1], b[2], b[3] end

    -- Last-resort live read (covers entries that init after baseline capture).
    local info = lookupKey and type(ChatTypeInfo) == "table" and ChatTypeInfo[lookupKey]
    if info and info.r then return info.r, info.g, info.b end
    return 1, 1, 1
end

function ChannelColors.Set(key, r, g, b)
    if type(key) ~= "string" or key == "" then return end
    local store = getDB()
    if not store then return end
    store[key] = { r, g, b }
    if type(ChangeChatColor) ~= "function" then return end
    if isBuiltinKey(key) then
        ChangeChatColor(key, r, g, b)
    else
        local slotKey = ChannelColors.SlotForChannel(key)
        if slotKey then ChangeChatColor(slotKey, r, g, b) end
    end
end

function ChannelColors.Clear(key)
    if type(key) ~= "string" or key == "" then return end
    local store = getDB()
    if not store then return end
    store[key] = nil
    if type(ChangeChatColor) ~= "function" then return end
    if isBuiltinKey(key) then
        local b = baselines[key]
        if b then ChangeChatColor(key, b[1], b[2], b[3]) end
    else
        local slotKey = ChannelColors.SlotForChannel(key)
        if slotKey then
            local b = baselines[slotKey]
            if b then ChangeChatColor(slotKey, b[1], b[2], b[3]) end
        end
    end
end

function ChannelColors.ClearAll()
    local store = getDB()
    if not store then return end
    -- Only touch keys we manage: BUILTIN_KEYS + currently joined channels.
    -- Leaves orphan imported keys (e.g. MONSTER_SAY) untouched in SV — the
    -- apply pipeline ignores them anyway.
    local touched = {}
    for i = 1, #BUILTIN_KEYS do
        local key = BUILTIN_KEYS[i]
        if store[key] ~= nil then
            store[key] = nil
            touched[key] = true
        end
    end
    local nameToSlot = buildNameToSlotMap()
    for name, slotKey in pairs(nameToSlot) do
        if store[name] ~= nil then
            store[name] = nil
            touched[slotKey] = true
        end
    end
    if type(ChangeChatColor) ~= "function" then return end
    for key in pairs(touched) do
        local b = baselines[key]
        if b then ChangeChatColor(key, b[1], b[2], b[3]) end
    end
end

-----------------------------------------------------------------------
-- Profile-import refresh hook (ns.QUI.Chat._afterRefresh)
-----------------------------------------------------------------------
local function ApplyEnabled()
    local settings = I.GetSettings and I.GetSettings()
    if not (I.IsChatEnabled and I.IsChatEnabled(settings)) then
        -- Master chat toggle is off — revert every override and stop.
        revertUnmanaged()  -- restores any unset entries
        local store = getDB()
        if store and type(ChangeChatColor) == "function" then
            for i = 1, #BUILTIN_KEYS do
                local key = BUILTIN_KEYS[i]
                if store[key] then
                    local b = baselines[key]
                    if b then ChangeChatColor(key, b[1], b[2], b[3]) end
                end
            end
            local nameToSlot = buildNameToSlotMap()
            for name, slotKey in pairs(nameToSlot) do
                if store[name] then
                    local b = baselines[slotKey]
                    if b then ChangeChatColor(slotKey, b[1], b[2], b[3]) end
                end
            end
        end
        return
    end
    revertUnmanaged()
    applyAll()
end

-----------------------------------------------------------------------
-- Event wiring
-----------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHANNEL_UI_UPDATE")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        captureBaselines()
        applyAll()
    elseif event == "CHANNEL_UI_UPDATE" then
        captureBaselines()  -- fills slots that init lazily
        applyCustoms()
    end
end)

table.insert(ns.QUI.Chat._afterRefresh, ApplyEnabled)
