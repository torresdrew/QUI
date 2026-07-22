local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local UIKit = ns.UIKit

---------------------------------------------------------------------------
-- FOCUS CAST ALERT
-- Displays a configurable text warning when hostile focus is casting
-- and the player's interrupt is ready.
---------------------------------------------------------------------------

local DEFAULT_SETTINGS = {
    enabled = false,
    text = ns.L["Focus is casting. Kick!"],
    anchorTo = "screen", -- "screen", "essential", "focus"
    offsetX = 0,
    offsetY = -120,
    font = "", -- empty = global QUI font
    fontSize = 26,
    fontOutline = "OUTLINE",
    textColor = {1, 0.2, 0.2, 1},
    useClassColor = false,
    soundEnabled = false,
    sound = "None", -- LSM sound key; "None" = silent
}

local FALLBACK_FONT_PATH = "Fonts\\FRIZQT__.TTF"
local FALLBACK_FONT_OUTLINE = "OUTLINE"

local SafeToString = Helpers.SafeToString

-- Class interrupt spells with base cooldown durations (in seconds).
-- Used for internal CD tracking via UNIT_SPELLCAST_SUCCEEDED instead of
-- C_Spell.GetSpellCooldown which returns tainted values on Midnight.
-- Note: talents may reduce these CDs — using base values means we might
-- hide the alert for a second or two longer than necessary, but never
-- show it when the interrupt is truly on cooldown.
local INTERRUPT_SPELLS_BY_CLASS = {
    DEATHKNIGHT = {{id = 47528,  cd = 15}},    -- Mind Freeze
    DEMONHUNTER = {{id = 183752, cd = 15}},    -- Disrupt
    DRUID       = {{id = 106839, cd = 15},     -- Skull Bash
                   {id = 78675,  cd = 60}},    -- Solar Beam
    EVOKER      = {{id = 351338, cd = 20}},    -- Quell
    HUNTER      = {{id = 147362, cd = 24}},    -- Counter Shot
    MAGE        = {{id = 2139,   cd = 24}},    -- Counterspell
    MONK        = {{id = 116705, cd = 15}},    -- Spear Hand Strike
    PALADIN     = {{id = 96231,  cd = 15}},    -- Rebuke
    PRIEST      = {{id = 15487,  cd = 30}},    -- Silence
    ROGUE       = {{id = 1766,   cd = 15}},    -- Kick
    SHAMAN      = {{id = 57994,  cd = 30}},    -- Wind Shear
    WARLOCK     = {{id = 19647,  cd = 24}},    -- Spell Lock
    WARRIOR     = {{id = 6552,   cd = 15}},    -- Pummel
}

-- Reverse lookup: spellID → base cooldown duration.
local INTERRUPT_SPELL_LOOKUP = {}
for _, spells in pairs(INTERRUPT_SPELLS_BY_CLASS) do
    for _, spell in ipairs(spells) do
        INTERRUPT_SPELL_LOOKUP[spell.id] = spell.cd
    end
end

local state = {
    frame = nil,
    text = nil,
    ticker = nil,
    preview = false,
    -- Raw notInterruptible value from API (may be a Midnight secret value)
    -- or a clean boolean from UNIT_SPELLCAST_INTERRUPTIBLE / NOT_INTERRUPTIBLE events.
    -- Used with SetAlphaFromBoolean to let the rendering system resolve secrets.
    rawNotInterruptible = nil,
    -- READABLE cast evidence from UNIT_SPELLCAST_* events ("cast"/"channel"/
    -- nil). This — never secret-poll status — decides cast-vs-channel getter
    -- choice and "is focus casting?" while the polls are restricted.
    castEvidence = nil,
    -- Internal interrupt CD tracking: { [spellID] = GetTime() of cast }
    interruptCasts = {},
}

local function CopyColor(color)
    if type(color) ~= "table" then
        return {1, 1, 1, 1}
    end
    return {color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1}
end

local function GetGeneralDB()
    return Helpers.GetModuleDB("general")
end

local function GetSettings()
    local general = GetGeneralDB()
    if not general then
        return nil
    end

    if type(general.focusCastAlert) ~= "table" then
        general.focusCastAlert = {}
    end

    local settings = general.focusCastAlert
    Helpers.EnsureDefaults(settings, DEFAULT_SETTINGS)

    if type(settings.textColor) ~= "table" then
        settings.textColor = CopyColor(DEFAULT_SETTINGS.textColor)
    end
    return settings
end

local function GetAnchorFrame(anchorTo)
    if anchorTo == "essential" then
        return _G.QUI_GetCDMViewerFrame and _G.QUI_GetCDMViewerFrame("essential")
    end

    if anchorTo == "focus" then
        return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.focus
    end

    return nil
end

local function PositionAlertFrame()
    if not state.frame then
        return
    end

    -- Skip if anchoring system has overridden this frame
    if _G.QUI_HasFrameAnchor and _G.QUI_HasFrameAnchor("focusCastAlert") then return end

    local settings = GetSettings()
    local offsetX = (settings and settings.offsetX) or DEFAULT_SETTINGS.offsetX
    local offsetY = (settings and settings.offsetY) or DEFAULT_SETTINGS.offsetY
    local anchorTo = (settings and settings.anchorTo) or DEFAULT_SETTINGS.anchorTo

    state.frame:ClearAllPoints()

    if anchorTo == "screen" then
        state.frame:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
        return
    end

    local anchorFrame = GetAnchorFrame(anchorTo)
    if anchorFrame and anchorFrame:IsShown() then
        state.frame:SetPoint("CENTER", anchorFrame, "CENTER", offsetX, offsetY)
    else
        -- Fallback to screen center if anchor is unavailable.
        state.frame:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
    end
end

local IsSecretValue = Helpers.IsSecretValue

local function IsSpellKnownForPlayer(spellID)
    if type(IsSpellKnownOrOverridesKnown) == "function" then
        local ok, known = ns.SafeCall("chain-next", IsSpellKnownOrOverridesKnown, spellID)
        if ok then return known end
    end

    if C_SpellBook and type(C_SpellBook.IsSpellKnown) == "function" then
        local ok, known = ns.SafeCall("chain-next", C_SpellBook.IsSpellKnown, spellID)
        if ok then return known end
    end

    if type(IsPlayerSpell) == "function" then
        local ok, known = ns.SafeCall("chain-next", IsPlayerSpell, spellID)
        if ok then return known end
    end

    if type(IsSpellKnown) == "function" then
        local ok, known = ns.SafeCall("chain-next", IsSpellKnown, spellID)
        if ok then return known end
    end

    return false
end

-- Track player interrupt casts internally via UNIT_SPELLCAST_SUCCEEDED.
-- This avoids C_Spell.GetSpellCooldown which returns tainted values on Midnight.
local function OnPlayerInterruptCast(spellID)
    -- Probe FIRST: `spellID == nil` on a secret spellID is still a compare
    -- OF the secret and throws in-game (cross-type == included) — the old
    -- order ran the == before the probe. IsSecretValue(nil) is safe, so the
    -- probe can lead. ACTION POLICY: a secret spellID cannot key the
    -- interrupt lookup — skip tracking this cast, same outcome as an
    -- unknown spell. (Strict taint scan was green on the old order:
    -- analyzer gap, recorded for the Task 8 header notes.)
    if IsSecretValue(spellID) then return end
    if spellID == nil then return end
    local cd = INTERRUPT_SPELL_LOOKUP[spellID]
    if cd then
        state.interruptCasts[spellID] = GetTime()
    end
end

-- Returns true if at least one known interrupt spell is off cooldown,
-- based on internal tracking (GetTime() since last cast vs base CD).
local function IsInterruptReady()
    local _, classToken = UnitClass("player")
    local interruptSpells = INTERRUPT_SPELLS_BY_CLASS[classToken or ""]
    if not interruptSpells then
        return false
    end

    local now = GetTime()
    for _, spell in ipairs(interruptSpells) do
        if IsSpellKnownForPlayer(spell.id) then
            local castTime = state.interruptCasts[spell.id]
            if not castTime then
                return true -- never cast this session, must be off CD
            end
            if now - castTime >= spell.cd then
                return true -- base CD has elapsed
            end
        end
    end

    return false
end

-- Check if the focus target is a hostile unit that is casting (any cast —
-- interruptibility is handled separately via SetAlphaFromBoolean in UpdateAlert).
local function IsFocusCasting()
    if not UnitExists("focus") then return false end
    if not UnitCanAttack("player", "focus") then return false end

    local castName = UnitCastingInfo("focus")
    local channelName = UnitChannelInfo("focus")
    -- 12.1: these getters are SecretWhenUnitSpellCastRestricted, and a bare
    -- boolean test on a secret value THROWS. A secret is INDETERMINATE — it
    -- must NEVER be converted into "casting" or "not casting" (secrecy
    -- correlating with cast state would itself leak the state the
    -- restriction hides). When the poll is unreadable, fall back to EVENT
    -- evidence: state.castEvidence is maintained by the UNIT_SPELLCAST_*
    -- handlers, which fire regardless of restriction.
    if IsSecretValue(castName) or IsSecretValue(channelName) then
        return state.castEvidence ~= nil
    end
    if not castName and not channelName then
        return false
    end

    return true
end

-- Capture the raw notInterruptible value from the API.
-- On Midnight this is a secret value; on earlier builds a plain boolean.
-- Either way it works with SetAlphaFromBoolean.
local function CaptureNotInterruptibleFlag()
    -- Channel-vs-cast selection must come from READABLE evidence, never
    -- from secret-name status. With event evidence, read the flag from the
    -- getter the event named — the (possibly secret) flag then rides to the
    -- SetAlphaFromBoolean absorb sink untouched.
    local evidence = state.castEvidence
    if evidence == "channel" then
        local _, _, _, _, _, _, notInterruptible = UnitChannelInfo("focus")
        state.rawNotInterruptible = notInterruptible
        return
    end
    if evidence == "cast" then
        local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("focus")
        state.rawNotInterruptible = notInterruptible
        return
    end

    -- No event evidence (catch-up: focus changed, login): only a READABLE
    -- poll may decide. A secret poll is indeterminate — capture nothing;
    -- the alpha path fails closed on nil and the next event re-captures.
    local name, _, _, _, _, _, notInterruptible = UnitChannelInfo("focus")
    if IsSecretValue(name) then
        state.rawNotInterruptible = nil -- @secret-policy: skip-capture-when-unknown
        return
    end
    if name then
        state.rawNotInterruptible = notInterruptible
        return
    end

    name, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("focus")
    if IsSecretValue(name) then
        state.rawNotInterruptible = nil -- @secret-policy: skip-capture-when-unknown
        return
    end
    if not name then
        state.rawNotInterruptible = nil
        return
    end

    state.rawNotInterruptible = notInterruptible
end

local function IsEventUnitFocus(event, unit)
    if event == "PLAYER_FOCUS_CHANGED" then
        return true
    end
    return unit == "focus"
end

-- Play the configured interrupt sound once per cast. Audio is Lua-only logic
-- with no C-side sink to absorb a secret: it requires READABLE evidence that
-- the cast is interruptible (plain false, or the UNIT_SPELLCAST_INTERRUPTIBLE
-- event which stores plain false). A SECRET flag is indeterminate — playing
-- on it could announce a secretly NON-interruptible cast, so it never sounds.
local function MaybePlayInterruptSound()
    if state.soundPlayed then return end
    local settings = GetSettings()
    if not settings or not settings.enabled or not settings.soundEnabled then return end
    local soundName = settings.sound
    if not soundName or soundName == "None" or soundName == "" then return end

    local raw = state.rawNotInterruptible
    -- Probe FIRST: `raw == nil` on a secret value is itself the throw.
    if IsSecretValue(raw) then return end
    if raw == nil then return end
    if raw ~= false then return end

    if not IsInterruptReady() then return end
    local LSM = ns.LSM
    local path = LSM and LSM:Fetch("sound", soundName)
    if path and type(path) == "string" then
        PlaySoundFile(path, "Master")
        state.soundPlayed = true
    end
end

local function HandleEventState(event, unit, spellID)
    if not IsEventUnitFocus(event, unit) then
        return
    end

    if event == "PLAYER_FOCUS_CHANGED" then
        -- New focus: prior cast evidence is void until its own events fire.
        state.castEvidence = nil
        state.rawNotInterruptible = nil
        state.soundPlayed = nil
        CaptureNotInterruptibleFlag()
        return
    end

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- The EVENT is the readable cast-vs-channel evidence — it fires
        -- regardless of restriction, unlike the poll returns.
        state.castEvidence = (event == "UNIT_SPELLCAST_CHANNEL_START") and "channel" or "cast"
        state.rawNotInterruptible = nil
        state.soundPlayed = nil
        CaptureNotInterruptibleFlag()
        return
    end

    if event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        state.rawNotInterruptible = true
        return
    end

    if event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        state.rawNotInterruptible = false
        MaybePlayInterruptSound()
        return
    end

    if event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        if event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            state.castEvidence = "channel"
        end
        CaptureNotInterruptibleFlag()
        return
    end

    if event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        state.castEvidence = nil
        state.rawNotInterruptible = nil
        state.soundPlayed = nil
        return
    end

    -- Fallback: refresh snapshot on other focus-related events.
    CaptureNotInterruptibleFlag()
end


local function SafePlaceholder(value, fallback)
    -- Probe BEFORE the nil compare — `secret == nil` throws in-game (same
    -- ordering rule this file documents for spellID above).
    if IsSecretValue(value) then return fallback end
    if value == nil then return fallback end
    local str = SafeToString(value, fallback)
    return str ~= "" and str or fallback
end

-- Apply the alert text to the FontString, handling Midnight secret values.
-- Uses SetFormattedText so the rendering engine can resolve secret spell names
-- the same way SetText handles them natively.
local function ApplyAlertText(template)
    local text = SafeToString(template, "")
    if text == "" then
        text = DEFAULT_SETTINGS.text
    end

    local hasUnit = text:find("{unit}", 1, true)
    local hasSpell = text:find("{spell}", 1, true)

    -- Fast path: no placeholders.
    if not hasUnit and not hasSpell then
        state.text:SetText(text)
        return
    end

    -- Resolve unit name (typically plain for focus targets). Probe before
    -- the nil-compare; a secret name rides to the formatted-text sink below.
    local unitName
    if hasUnit then
        unitName = UnitName("focus")
        if IsSecretValue(unitName) then
            -- secret: renders via SetFormattedText
        elseif unitName == nil then
            unitName = ns.L["Focus"]
        end
    end

    -- Resolve spell name — raw from the API (may be secret, but renderable).
    -- Getter choice follows event evidence when the polls are unreadable;
    -- every truth/nil test runs only on proven-plain values.
    local rawSpellName
    if hasSpell then
        if state.castEvidence == "channel" then
            rawSpellName = UnitChannelInfo("focus")
        else
            rawSpellName = UnitCastingInfo("focus")
            if IsSecretValue(rawSpellName) then
                -- secret, no channel evidence: keep the cast-slot secret
            elseif rawSpellName == nil then
                rawSpellName = UnitChannelInfo("focus")
            end
        end
        if IsSecretValue(rawSpellName) then
            -- secret: renders via SetFormattedText
        elseif rawSpellName == nil then
            rawSpellName = ""
        end
    end

    -- If no value is secret, safe to do plain string replacement.
    -- Escape % in replacement values so gsub doesn't interpret them as captures.
    if not IsSecretValue(unitName) and not IsSecretValue(rawSpellName) then
        if hasUnit then
            text = text:gsub("{unit}", SafePlaceholder(unitName, ns.L["Focus"]):gsub("%%", "%%%%"))
        end
        if hasSpell then
            text = text:gsub("{spell}", SafePlaceholder(rawSpellName, ""):gsub("%%", "%%%%"))
        end
        state.text:SetText(text)
        return
    end

    -- Has secrets — build a format string for SetFormattedText so the
    -- rendering engine resolves them (same mechanism as SetText with secrets).
    local args = {}
    local replacements = {}
    if hasUnit then
        local s, e = text:find("{unit}", 1, true)
        replacements[#replacements + 1] = {s = s, e = e, value = unitName}
    end
    if hasSpell then
        local s, e = text:find("{spell}", 1, true)
        replacements[#replacements + 1] = {s = s, e = e, value = rawSpellName}
    end
    table.sort(replacements, function(a, b) return a.s < b.s end)

    local segments = {}
    local cursor = 1
    for _, r in ipairs(replacements) do
        if r.s > cursor then
            -- Escape literal % in user text so format() doesn't choke.
            segments[#segments + 1] = text:sub(cursor, r.s - 1):gsub("%%", "%%%%")
        end
        segments[#segments + 1] = "%s"
        args[#args + 1] = r.value
        cursor = r.e + 1
    end
    if cursor <= #text then
        segments[#segments + 1] = text:sub(cursor):gsub("%%", "%%%%")
    end

    local fmt = table.concat(segments)
    local ok = ns.SafeCallMethod("sink-forward", state.text, "SetFormattedText", fmt, unpack(args))
    if not ok then
        -- Fallback: show without secret placeholders.
        local fallback = template
        if hasUnit then fallback = fallback:gsub("{unit}", SafePlaceholder(unitName, ns.L["Focus"])) end
        if hasSpell then fallback = fallback:gsub("{spell}", "") end
        state.text:SetText(fallback)
    end
end

local function ApplyTextStyle()
    if not state.text then return end

    local settings = GetSettings()
    local fontPath
    if settings and settings.font and settings.font ~= "" and UIKit and UIKit.ResolveFontPath then
        fontPath = UIKit.ResolveFontPath(settings.font)
    else
        fontPath = Helpers.GetGeneralFont()
    end
    if not fontPath then
        fontPath = FALLBACK_FONT_PATH
    end

    local fontSize = tonumber((settings and settings.fontSize) or DEFAULT_SETTINGS.fontSize) or DEFAULT_SETTINGS.fontSize
    local fontOutline = (settings and settings.fontOutline)
    if fontOutline == nil then
        fontOutline = Helpers.GetGeneralFontOutline() or DEFAULT_SETTINGS.fontOutline
    end
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        -- ApplyFontWithFallback already falls back to a usable physical font
        -- internally, so no secondary FALLBACK_FONT_PATH retry is needed here.
        ns.Helpers.ApplyFontWithFallback(state.text, fontPath, fontSize, fontOutline)
    else
        local fontSet = state.text:SetFont(fontPath, fontSize, fontOutline)
        if not fontSet then
            state.text:SetFont(FALLBACK_FONT_PATH, fontSize, FALLBACK_FONT_OUTLINE)
        end
    end

    local color
    if settings and settings.useClassColor then
        local r, g, b = Helpers.GetPlayerClassColor()
        color = {r, g, b, 1}
    else
        color = (settings and settings.textColor) or DEFAULT_SETTINGS.textColor
    end
    state.text:SetTextColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
end

local function CreateAlertFrame()
    if state.frame then return end

    local frame = CreateFrame("Frame", "QUI_FocusCastAlertFrame", UIParent)
    frame:SetSize(500, 60)
    frame:SetFrameStrata("HIGH")
    frame:Hide()

    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(text, FALLBACK_FONT_PATH, DEFAULT_SETTINGS.fontSize, FALLBACK_FONT_OUTLINE)
    else
        text:SetFont(FALLBACK_FONT_PATH, DEFAULT_SETTINGS.fontSize, FALLBACK_FONT_OUTLINE)
    end
    text:SetText(DEFAULT_SETTINGS.text)

    state.frame = frame
    state.text = text

    PositionAlertFrame()
    ApplyTextStyle()
end

-- Apply interruptibility to the alert frame's alpha.
-- On Midnight, notInterruptible is a secret value that can't be compared in Lua
-- but works natively with SetAlphaFromBoolean.
-- notInterruptible true  → alpha 0 (hidden)
-- notInterruptible false → alpha 1 (visible)
local function ApplyInterruptAlpha()
    local raw = state.rawNotInterruptible
    -- Probe FIRST (`raw == nil` on a secret throws), then forward the raw
    -- secret straight to the C-side sink — no truth test, no conversion.
    if IsSecretValue(raw) then
        if state.frame.SetAlphaFromBoolean then
            state.frame:SetAlphaFromBoolean(raw, 0, 1)
        else
            state.frame:SetAlpha(0)
        end
        return
    end
    if raw == nil then
        -- Unknown state — hide (fail closed).
        state.frame:SetAlpha(0)
        return
    end

    -- SetAlphaFromBoolean handles both plain booleans and Midnight secret values.
    if state.frame.SetAlphaFromBoolean then
        state.frame:SetAlphaFromBoolean(raw, 0, 1)
    else
        -- Pre-Midnight fallback: plain boolean.
        state.frame:SetAlpha(raw and 0 or 1)
    end
end

local function UpdateAlert()
    if not state.frame then
        CreateAlertFrame()
    end

    local settings = GetSettings()
    if not settings then
        state.frame:Hide()
        return
    end

    if state.preview then
        PositionAlertFrame()
        ApplyTextStyle()
        ApplyAlertText(settings.text)
        state.frame:SetAlpha(1)
        state.frame:Show()
        return
    end

    if not settings.enabled then
        state.frame:Hide()
        return
    end

    -- Skip expensive positioning/styling if there's nothing to show.
    if not IsFocusCasting() then
        state.frame:Hide()
        return
    end

    PositionAlertFrame()
    ApplyTextStyle()

    if not IsInterruptReady() then
        state.frame:Hide()
        return
    end

    ApplyAlertText(settings.text)
    state.frame:Show()
    ApplyInterruptAlpha()
    -- Drive the audio cue off the same interruptibility signal that gates the
    -- visual alpha. Self-gated + latched, so polling it each ticker tick is safe.
    MaybePlayInterruptSound()
end

-- Start or stop the cooldown poll ticker. The ticker only needs to run
-- while the focus is actively casting so we can detect the interrupt
-- coming off cooldown. Events handle cast start/stop transitions.
local function StartTicker()
    if not state.ticker then
        state.ticker = C_Timer.NewTicker(0.25, UpdateAlert)
    end
end

local function StopTicker()
    if state.ticker then
        state.ticker:Cancel()
        state.ticker = nil
    end
end

local function ShouldRunTicker()
    local settings = GetSettings()
    return state.preview or (settings and settings.enabled)
end

local function RefreshFocusCastAlert()
    CreateAlertFrame()
    CaptureNotInterruptibleFlag()
    UpdateAlert()
end

local function TogglePreview(show)
    state.preview = show and true or false
    if state.preview then
        StartTicker()
    else
        StopTicker()
    end
    RefreshFocusCastAlert()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTIBLE", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "focus")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
eventFrame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID, ...)
    if event == "ADDON_LOADED" then
        if unit ~= ADDON_NAME then return end  -- unit is arg1 here
        self:UnregisterEvent("ADDON_LOADED")
        RefreshFocusCastAlert()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        CaptureNotInterruptibleFlag()
        UpdateAlert()
        return
    end

    -- Track player interrupt casts for internal CD tracking.
    -- 68569: registered player-only above (RegisterUnitEvent), so unit is
    -- already C-side filtered — no unit compare needed (and unproven-safe
    -- against a possibly-secret unit token anyway). spellID is probed for
    -- secrecy inside OnPlayerInterruptCast before any table index/store.
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnPlayerInterruptCast(spellID)
        UpdateAlert()
        return
    end

    HandleEventState(event, unit, spellID)

    -- Start the cooldown poll ticker when focus begins casting; stop on cast end.
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        if ShouldRunTicker() then
            StartTicker()
        end
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        StopTicker()
    elseif event == "PLAYER_FOCUS_CHANGED" then
        StopTicker()
        -- New focus may already be mid-cast; restart ticker if so.
        if IsFocusCasting() then
            if ShouldRunTicker() then
                StartTicker()
            end
        end
    end

    UpdateAlert()
end)

-- LOD catch-up: first PEW already fired before this module loads.
-- ns.WhenLoggedIn is nil only in the headless test harness.
if ns.WhenLoggedIn then
    ns.WhenLoggedIn(function()
        CaptureNotInterruptibleFlag()
        UpdateAlert()
    end)
end

_G.QUI_RefreshFocusCastAlert = RefreshFocusCastAlert
_G.QUI_ToggleFocusCastAlertPreview = TogglePreview

if ns.Registry then
    ns.Registry:Register("focusCastAlert", {
        refresh = _G.QUI_RefreshFocusCastAlert,
        priority = 30,
        group = "qol",
        importCategories = { "qol" },
    })
end
