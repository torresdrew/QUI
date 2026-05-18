---------------------------------------------------------------------------
-- QUI Chat Modifier — Channel Shortening
-- Shortens channel-prefix tokens in chat messages after Blizzard has safely
-- formatted and added each line.
--
-- Two preset modes:
--   Letter -> [Guild]/[G], [Officer]/[O], [Party]/[P], [Raid]/[R],
--             [Instance]/[I], [Say]/[S], [Yell]/[Y]; numbered chat channels
--             use a name-based abbreviation: [1. General] -> [Gen],
--             [2. Trade - Stormwind] -> [T], [4. Trade (Services)] -> [S],
--             [N. CustomChannel] -> [Cus] (first 3 chars capitalized).
--   Number -> static chat types shorten the same way as Letter; numbered
--             chat channels are reduced to just the number, e.g.
--             [1. General] -> [1], [4. Trade (Services)] -> [4].
--
-- Important: do not override CHAT_<EVENT>_GET globals. Blizzard reads those
-- templates on protected chat paths before creating chat-history access IDs;
-- addon-tainted templates can make secret sender GUIDs unsafe to lowercase.
---------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local I = assert(ns.QUI.Chat and ns.QUI.Chat._internals,
    "QUI Chat: channel_shorten.lua loaded before chat.lua. Check chat.xml — chat.lua must precede channel_shorten.lua.")

local Helpers = ns.Helpers

-- ---------------------------------------------------------------------------
-- Preset shortening tables
-- ---------------------------------------------------------------------------

-- Maps Blizzard chat-event-type tags to short labels. The actual global
-- key is "CHAT_<TAG>_GET" (e.g., CHAT_GUILD_GET, CHAT_PARTY_GET).
local letterShort = {
    GUILD                = "G",
    OFFICER              = "O",
    PARTY                = "P",
    PARTY_LEADER         = "PL",
    RAID                 = "R",
    RAID_LEADER          = "RL",
    RAID_WARNING         = "RW",
    INSTANCE_CHAT        = "I",
    INSTANCE_CHAT_LEADER = "IL",
    SAY                  = "S",
    YELL                 = "Y",
}

-- Both presets reuse the static letterShort table for chat-type events
-- (CHAT_MSG_GUILD, CHAT_MSG_PARTY, …). Numbered chat channels
-- (CHAT_MSG_CHANNEL) don't use a CHAT_*_GET template — they're rendered
-- inline as "[N. ChannelName]" — and are handled separately below: Letter
-- abbreviates the channel name, Number drops the name and keeps the number.
local numberShort = letterShort

-- Built-in abbreviations for well-known Blizzard channels (Letter preset).
-- Lookup tries the full channel name first (so "Trade (Services)" -> "S"),
-- then strips a trailing " - Zone" suffix and tries again. Unknown channels
-- fall through to the first-three-alphanumerics rule in abbrevForChannel.
local DEFAULT_CHANNEL_ABBREV = {
    General              = "Gen",
    Trade                = "T",
    ["Trade (Services)"] = "S",
    LocalDefense         = "LD",
    WorldDefense         = "WD",
    LookingForGroup      = "LFG",
    GuildRecruitment     = "GR",
    World                = "W",
}

-- ---------------------------------------------------------------------------
-- Template manipulation
-- ---------------------------------------------------------------------------

local SAVED_TEMPLATES = {}  -- captures original Blizzard strings for locale-aware matching

local function captureOriginals()
    if next(SAVED_TEMPLATES) ~= nil then return end  -- already captured
    for tag in pairs(letterShort) do
        local key = "CHAT_" .. tag .. "_GET"
        SAVED_TEMPLATES[key] = _G[key]
    end
end

local function escapePattern(text)
    return (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function buildReplacements(preset)
    captureOriginals()
    local table_ = (preset == "number") and numberShort or letterShort
    local replacements = {}

    for tag, shortLabel in pairs(table_) do
        local key = "CHAT_" .. tag .. "_GET"
        local original = SAVED_TEMPLATES[key]
        if type(original) == "string" then
            local longBracket = original:match("%[[^%]]+%]")
            if longBracket then
                replacements[tag] = {
                    pattern = escapePattern(longBracket),
                    replacement = "[" .. shortLabel .. "]",
                }
            end
        end
    end

    return replacements
end

-- ---------------------------------------------------------------------------
-- Rendered-line transform
-- ---------------------------------------------------------------------------

local EVENT_TO_TAG = {}
for tag in pairs(letterShort) do
    EVENT_TO_TAG["CHAT_MSG_" .. tag] = tag
end

local ACTIVE_REPLACEMENTS = nil
local CURRENT_PRESET = nil
local hookedFrames = setmetatable({}, { __mode = "k" })

local function IsSecret(value)
    return Helpers and Helpers.IsSecretValue and Helpers.IsSecretValue(value)
end

local function IsChatMessagingLockedDown()
    return I.IsChatMessagingLockedDown and I.IsChatMessagingLockedDown()
end

-- ---------------------------------------------------------------------------
-- Numbered-channel transforms (Letter / Number presets)
-- ---------------------------------------------------------------------------

local function abbrevForChannel(name)
    if type(name) ~= "string" or name == "" then return name end

    -- Try the full channel name first (handles "Trade (Services)" -> "S").
    local hit = DEFAULT_CHANNEL_ABBREV[name]
    if hit then return hit end

    -- Strip optional " - Zone" suffix (handles "Trade - Stormwind" -> "Trade").
    local base = name:match("^(.-)%s%-%s")
    if base then
        hit = DEFAULT_CHANNEL_ABBREV[base]
        if hit then return hit end
    end

    -- Fallback: first three alphanumeric chars, capitalized first letter.
    local source = base or name
    local stripped = source:gsub("[^%w]", "")
    if stripped == "" then return source end
    local short = stripped:sub(1, 3)
    return short:sub(1, 1):upper() .. short:sub(2):lower()
end

local CHANNEL_LINK_PATTERN = "^(.-)|Hchannel:channel:(%d+)|h%[(%d+)%. ([^%]]+)%]|h(%s*)()"

local function getChannelPrefix(message)
    if type(message) ~= "string" then return nil end

    local prefix, _, channelNumber, channelName, spacing, restIndex = message:match(CHANNEL_LINK_PATTERN)
    if not prefix then return nil end
    if prefix:find("|H", 1, true) then return nil end

    return prefix, channelNumber, channelName, spacing, restIndex
end

local function hasChannelPrefix(message)
    return getChannelPrefix(message) ~= nil
end

-- Numbered channel lines start with a channel hyperlink. Replace that whole
-- leading hyperlink with plain text so later player/item hyperlinks keep
-- their original marker boundaries.
local function transformChannelPrefix(message, preset)
    local prefix, channelNumber, channelName, spacing, restIndex = getChannelPrefix(message)
    if not prefix then return message end

    local label = channelNumber
    if preset == "letter" then
        label = abbrevForChannel(channelName)
    end

    return prefix .. "[" .. label .. "]" .. spacing .. message:sub(restIndex)
end

local function shouldTransformMessage(message, r, g, b, infoID, accessID, typeID, event)
    if not ACTIVE_REPLACEMENTS or not event then return false end
    if IsChatMessagingLockedDown() then return false end
    if IsSecret(message) then return false end
    if type(message) ~= "string" or message == "" then return false end

    local tag = EVENT_TO_TAG[event]
    if tag then
        local replacement = ACTIVE_REPLACEMENTS[tag]
        if replacement and message:find(replacement.pattern) ~= nil then
            return true
        end
    end

    if event == "CHAT_MSG_CHANNEL"
       and (CURRENT_PRESET == "letter" or CURRENT_PRESET == "number") then
        if hasChannelPrefix(message) then
            return true
        end
    end

    return false
end

local function transformMessage(message, r, g, b, infoID, accessID, typeID, event, eventArgs, formatter, ...)
    if IsChatMessagingLockedDown() then
        return message, r, g, b, infoID, accessID, typeID, event, eventArgs, formatter, ...
    end

    local tag = event and EVENT_TO_TAG[event]
    local replacement = tag and ACTIVE_REPLACEMENTS and ACTIVE_REPLACEMENTS[tag]

    if replacement and not IsSecret(message) then
        if type(message) == "string" then
            message = message:gsub(replacement.pattern, replacement.replacement, 1)
        end
    end

    if event == "CHAT_MSG_CHANNEL"
       and type(message) == "string"
       and not IsSecret(message) then
        if CURRENT_PRESET == "letter" or CURRENT_PRESET == "number" then
            message = transformChannelPrefix(message, CURRENT_PRESET)
        end
    end

    return message, r, g, b, infoID, accessID, typeID, event, eventArgs, formatter, ...
end

local function onAddMessage(frame, message, r, g, b, infoID, accessID, typeID, event)
    if not ACTIVE_REPLACEMENTS or not event then return end
    if IsChatMessagingLockedDown() then return end

    local tag = EVENT_TO_TAG[event]
    local hasStaticReplacement = tag and ACTIVE_REPLACEMENTS[tag]
    local hasChannelReplacement = (event == "CHAT_MSG_CHANNEL"
        and (CURRENT_PRESET == "letter" or CURRENT_PRESET == "number"))

    if not hasStaticReplacement and not hasChannelReplacement then return end
    if not frame or not frame.TransformMessages then return end

    frame:TransformMessages(shouldTransformMessage, transformMessage)
end

local function hookFrame(frame)
    if not frame or hookedFrames[frame] then return end
    hookedFrames[frame] = true
    hooksecurefunc(frame, "AddMessage", onAddMessage)
end

local function hookAllChatFrames()
    local n = _G.NUM_CHAT_WINDOWS or 10
    for i = 1, n do
        hookFrame(_G["ChatFrame" .. i])
    end
end

-- ---------------------------------------------------------------------------
-- Apply based on settings (called from _afterRefresh and PLAYER_LOGIN)
-- ---------------------------------------------------------------------------

local function ApplyEnabled()
    local settings = I.GetSettings and I.GetSettings()
    local s = (I.IsChatEnabled and I.IsChatEnabled(settings))
        and settings.modifiers and settings.modifiers.channelShorten
    local enabled = s and s.enabled
    local preset = (s and s.preset) or "letter"

    if enabled then
        if CURRENT_PRESET ~= preset then
            ACTIVE_REPLACEMENTS = buildReplacements(preset)
            CURRENT_PRESET = preset
        end
        hookAllChatFrames()
    else
        ACTIVE_REPLACEMENTS = nil
        CURRENT_PRESET = nil
    end
end

-- Initial application. Runs at file-load time. Settings may not be ready
-- yet (AceDB constructed in OnInitialize), in which case this is a no-op
-- and PLAYER_LOGIN below picks up the actual activation.
ApplyEnabled()

-- ---------------------------------------------------------------------------
-- PLAYER_LOGIN re-evaluation + after-refresh hook registration
-- ---------------------------------------------------------------------------

-- PLAYER_LOGIN fires after all addons' OnInitialize, so QUI.db is ready.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        ApplyEnabled()
    end
end)

-- Hook into chat module's centralized after-refresh dispatcher so live
-- setting toggles (and profile switch / import) re-apply.
table.insert(ns.QUI.Chat._afterRefresh, ApplyEnabled)

if hooksecurefunc and _G.FCF_OpenNewWindow then
    hooksecurefunc("FCF_OpenNewWindow", function()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, hookAllChatFrames)
        else
            hookAllChatFrames()
        end
    end)
end

if hooksecurefunc and _G.FCF_OpenTemporaryWindow then
    hooksecurefunc("FCF_OpenTemporaryWindow", function()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, hookAllChatFrames)
        else
            hookAllChatFrames()
        end
    end)
end
