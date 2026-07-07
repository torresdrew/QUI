local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- SOUND MUTE — engine
--
-- Mutes the game sounds the user ticks in QoL > Sound Mute. The set of
-- mutable sounds lives in sound_mute_catalog.lua (ns.SoundMuteCatalog); this
-- file reconciles the client mute state against the saved selection.
--
-- MuteSoundFile / UnmuteSoundFile each take a single fileDataID. They are
-- legacy engine globals (present since Legion) and are absent from both the
-- generated API docs and this repo's FrameXML snapshot; their signature and
-- behaviour (mutes/unmutes one fileDataID, persists for the session until
-- unmuted) are confirmed by identical usage across several shipped reference
-- addons. Client mute state is per-session and resets on login/reload, so we
-- (re)apply from saved settings at login and whenever the settings panel calls
-- ns.RefreshSoundMute.
--
-- Not protected / no secret data involved: safe to call any time, no combat
-- gate needed (matches how the sounds are muted at init elsewhere).
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

-- Flatten the catalog to entryKey -> ids once. Ids are static at runtime.
local ENTRY_IDS
local function EntryIndex()
    if ENTRY_IDS then return ENTRY_IDS end
    ENTRY_IDS = {}
    local cat = ns.SoundMuteCatalog
    if cat and cat.categories then
        for _, category in ipairs(cat.categories) do
            for _, entry in ipairs(category.entries) do
                ENTRY_IDS[entry.key] = entry.ids
            end
        end
    end
    return ENTRY_IDS
end

-- <<< QUI_TEST_EXTRACT mute_delta
-- Pure set reconciliation: given the entry keys currently applied (muted this
-- session) and the keys wanted now, return which to unmute and which to mute.
-- Both inputs are key -> true sets; result order is unspecified.
local function ComputeMuteDelta(applied, want)
    local toUnmute, toMute = {}, {}
    for key in pairs(applied) do
        if not want[key] then toUnmute[#toUnmute + 1] = key end
    end
    for key in pairs(want) do
        if not applied[key] then toMute[#toMute + 1] = key end
    end
    return toUnmute, toMute
end
-- <<< QUI_TEST_EXTRACT mute_delta

local applied = {} -- entryKey -> true : currently muted this session

local function Apply()
    local index = EntryIndex()
    local s = GetSettings()
    local sm = s and s.soundMute
    local want = {}
    if sm and sm.enabled then
        for key in pairs(index) do
            if sm[key] then want[key] = true end
        end
    end

    local toUnmute, toMute = ComputeMuteDelta(applied, want)
    for _, key in ipairs(toUnmute) do
        local ids = index[key]
        if ids then
            for _, id in ipairs(ids) do UnmuteSoundFile(id) end
        end
        applied[key] = nil
    end
    for _, key in ipairs(toMute) do
        local ids = index[key]
        if ids then
            for _, id in ipairs(ids) do MuteSoundFile(id) end
        end
        applied[key] = true
    end
end

ns.RefreshSoundMute = Apply

if ns.WhenLoggedIn then
    ns.WhenLoggedIn(Apply)
end
