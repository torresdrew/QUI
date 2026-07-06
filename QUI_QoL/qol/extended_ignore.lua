local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- EXTENDED IGNORE
-- A user-managed name list (beyond Blizzard's ignore cap) that both suppresses
-- public chat from those names and auto-declines their party invites / duels.
--
-- Chat suppression uses ChatFrameUtil.AddMessageEventFilter — QUI's custom chat
-- honors these filters (message_capture.lua calls ProcessMessageEventFilters and
-- discards on a truthy first return), and Blizzard skips filter callbacks on
-- secret payloads, so we never see secret sender values here.
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local ignoreSet = {}   -- [normalizedName] = true
local setEmpty = true

-- Normalize a name for matching: strip realm ("Name-Realm" -> "Name"), drop
-- whitespace, lowercase. Keeps matching forgiving of how the user typed it.
-- <<< QUI_TEST_EXTRACT normalize_name
local function NormalizeName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local base = name:match("^([^-]+)") or name
    base = base:gsub("%s+", "")
    if base == "" then return nil end
    return base:lower()
end
-- <<< QUI_TEST_EXTRACT normalize_name

local function RebuildSet()
    wipe(ignoreSet)
    local settings = GetSettings()
    local cfg = settings and settings.extendedIgnore
    local text = cfg and cfg.names
    if type(text) == "string" then
        for token in string.gmatch(text, "[^,\n\r]+") do
            local norm = NormalizeName(token)
            if norm then ignoreSet[norm] = true end
        end
    end
    setEmpty = next(ignoreSet) == nil
end

local function IsInSet(name)
    if setEmpty then return false end
    local norm = NormalizeName(name)
    return norm ~= nil and ignoreSet[norm] == true
end

-- Predicate consumed by qol.lua's PARTY_INVITE / DUEL handlers (and trade below).
-- `enabled` is the master toggle (defaults false → the `not cfg.enabled` gate).
-- `autoDecline`/`suppressChat` are sub-toggles that default to TRUE, so they use
-- `== false` ("on unless explicitly turned off") — the same idiom petwarning uses
-- for petCombatWarning. nil never reaches the sub-check with enabled true (AceDB
-- fills the defaults; the only nil path is an empty reset table, gated by enabled).
function ns.ShouldAutoDeclineFrom(name)
    local settings = GetSettings()
    local cfg = settings and settings.extendedIgnore
    if not cfg or not cfg.enabled or cfg.autoDecline == false then return false end
    return IsInSet(name)
end

---------------------------------------------------------------------------
-- CHAT SUPPRESSION
---------------------------------------------------------------------------

local CHAT_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_CHANNEL", "CHAT_MSG_WHISPER",
}

-- Filter signature: (chatFrame, event, msg, sender, ...) -> discard, ...
local function ChatFilter(_, _, _, sender)
    local settings = GetSettings()
    local cfg = settings and settings.extendedIgnore
    if not cfg or not cfg.enabled or cfg.suppressChat == false then return false end
    if IsInSet(sender) then return true end
    return false
end

local filtersInstalled = false
local function InstallChatFilters()
    if filtersInstalled then return end
    if not (_G.ChatFrameUtil and _G.ChatFrameUtil.AddMessageEventFilter) then return end
    for _, ev in ipairs(CHAT_EVENTS) do
        _G.ChatFrameUtil.AddMessageEventFilter(ev, ChatFilter)
    end
    filtersInstalled = true
end

---------------------------------------------------------------------------
-- TRADE AUTO-DECLINE
---------------------------------------------------------------------------

-- Trade partner is GetUnitName("NPC") at TRADE_SHOW (verified vs FrameXML
-- TradeFrame.lua:72). CancelTrade() closes the trade window (PlayerScript API).
local tradeWatcher = CreateFrame("Frame")
tradeWatcher:RegisterEvent("TRADE_SHOW")
tradeWatcher:SetScript("OnEvent", function()
    local partner = GetUnitName("NPC")
    if partner and ns.ShouldAutoDeclineFrom(partner) then
        CancelTrade()
    end
end)

---------------------------------------------------------------------------
-- LIFECYCLE
---------------------------------------------------------------------------

local function Refresh()
    RebuildSet()
    InstallChatFilters()
end
ns.RefreshExtendedIgnore = Refresh

if ns.WhenLoggedIn then
    ns.WhenLoggedIn(Refresh)
end

if ns.Registry then
    ns.Registry:Register("extendedIgnore", {
        refresh = Refresh,
        priority = 30,
        group = "qol",
        importCategories = { "qol" },
    })
end
