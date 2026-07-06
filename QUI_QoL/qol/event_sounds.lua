local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- EVENT SOUND ALERTS
-- Plays a chosen sound when a selected event fires (incoming whisper, ready
-- check, LFG proposal, resurrection offer). Each event has its own sound; a
-- value of "None" disables that event. Sound resolution mirrors
-- focuscastalert.lua: LSM:Fetch("sound", name) -> PlaySoundFile(path, "Master").
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local function PlayEventSound(soundName)
    if not soundName or soundName == "None" or soundName == "" then return end
    local LSM = ns.LSM
    local path = LSM and LSM:Fetch("sound", soundName)
    if path and type(path) == "string" then
        PlaySoundFile(path, "Master")
    end
end

-- Event -> config key. Both whisper events map to the same "whisper" sound.
local EVENT_TO_KEY = {
    CHAT_MSG_WHISPER    = "whisper",
    CHAT_MSG_BN_WHISPER = "whisper",
    READY_CHECK         = "readyCheck",
    LFG_PROPOSAL_SHOW   = "lfgProposal",
    RESURRECT_REQUEST   = "resurrect",
}

-- Mail alert is a special case: UPDATE_PENDING_MAIL fires on state changes AND
-- at login, so we only play on a false->true transition, and only once a login
-- baseline is established (mailReady) — otherwise existing mail pings on login.
-- HasNewMail() verified vs FrameXML (Blizzard_Minimap/Minimap.lua uses it).
local hadMail = false
local mailReady = false

local frame = CreateFrame("Frame")
-- Literal RegisterEvent calls so tools/generate_event_allowlist.lua detects them.
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("CHAT_MSG_BN_WHISPER")
frame:RegisterEvent("READY_CHECK")
frame:RegisterEvent("LFG_PROPOSAL_SHOW")
frame:RegisterEvent("RESURRECT_REQUEST")
frame:RegisterEvent("UPDATE_PENDING_MAIL")

frame:SetScript("OnEvent", function(_, event)
    if event == "UPDATE_PENDING_MAIL" then
        local nowMail = HasNewMail() and true or false
        local wasMail = hadMail
        hadMail = nowMail
        if mailReady and nowMail and not wasMail then
            local settings = GetSettings()
            local cfg = settings and settings.eventSounds
            if cfg and cfg.enabled then
                PlayEventSound(cfg.mail)
            end
        end
        return
    end

    local settings = GetSettings()
    local cfg = settings and settings.eventSounds
    if not cfg or not cfg.enabled then return end
    local key = EVENT_TO_KEY[event]
    if key then
        PlayEventSound(cfg[key])
    end
end)

-- Establish the login mail baseline so pre-existing mail doesn't ping on login.
if ns.WhenLoggedIn then
    ns.WhenLoggedIn(function()
        hadMail = HasNewMail() and true or false
        mailReady = true
    end)
end
