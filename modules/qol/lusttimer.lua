---------------------------------------------------------------------------
-- QUI Lust Timer
-- Shows a draining bar + countdown for an active Bloodlust-family buff on the
-- player (Bloodlust / Heroism / Time Warp / Primal Rage / Fury of the Aspects /
-- Drums). The bar fill is a C-side DurationObject (GetAuraDuration is NOT
-- SecretWhenUnitAuraRestricted), so it drains into combat without ever reading a
-- number in Lua. The Lust family is flagged never-secret on Blizzard's aura
-- whitelist (priority over the combat restriction), so its spellId stays a real
-- Lua value in combat — detection works at the application edge whether the cast
-- lands in or out of combat. removedAuraInstanceIDs (never secret) drives hide.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local QUI = ns.QUI or {}
ns.QUI = QUI
local QUICore = ns.Addon
local Helpers = ns.Helpers
local UIKit = ns.UIKit

local function CJKFont(fs, p, s, f)
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(fs, p, s, f)
    else
        fs:SetFont(p, s, f)
    end
end

local C_UnitAuras = C_UnitAuras
local issecretvalue = issecretvalue

-- Bloodlust family (haste burst) + the Sated/Exhaustion lockout (which we never
-- track). No shared table exists in the repo, so these are owned here.
local LUST_SPELLS = {
    [2825]   = true,  -- Bloodlust
    [32182]  = true,  -- Heroism
    [80353]  = true,  -- Time Warp
    [264667] = true,  -- Primal Rage (Hunter pet)
    [390386] = true,  -- Fury of the Aspects (Evoker)
    [466904] = true,  -- Drums (current expansion)
}
local SATED_SPELLS = {
    [57723]  = true,  -- Exhaustion
    [57724]  = true,  -- Sated
    [80354]  = true,  -- Temporal Displacement
    [264689] = true,  -- Fatigued
    [390435] = true,  -- Exhaustion (Evoker)
}

local STATUS_BAR_INTERPOLATION_IMMEDIATE = 0
local STATUS_BAR_TIMER_REMAINING = 1

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local State = {
    frame = nil,
    isPreviewMode = false,
    activeInstanceID = nil,
}

---------------------------------------------------------------------------
-- DB
---------------------------------------------------------------------------
local GetSettings = Helpers.CreateDBGetter("lustTimer")

---------------------------------------------------------------------------
-- Secret-safe bar fill: bind the aura's DurationObject. The object is consumed
-- entirely C-side (SetTimerDuration / SetCooldownFromDurationObject), so no
-- secret number is ever read into Lua. Returns true if a live timer was bound.
---------------------------------------------------------------------------
local function BindDuration(bar, count, instanceID)
    if not bar or not instanceID then return false end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDuration) then return false end
    local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, "player", instanceID)
    if not ok or not durObj then return false end

    local appliedBar = ns.SafeCallMethod("sink-forward", bar, "SetTimerDuration", durObj,
        STATUS_BAR_INTERPOLATION_IMMEDIATE, STATUS_BAR_TIMER_REMAINING)
    ns.SafeCallMethodIfPresent("sink-forward", count, "SetCooldownFromDurationObject", durObj)
    return appliedBar and true or false
end

---------------------------------------------------------------------------
-- Frame creation (bar + countdown overlay)
---------------------------------------------------------------------------
local function CreateTimerFrame()
    if State.frame then return end

    local frame = CreateFrame("Frame", "QUI_LustTimer", UIParent, "BackdropTemplate")
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
    frame:SetSize(160, 22)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(50)

    frame:SetBackdrop(UIKit.GetBackdropInfo(nil, nil, frame))
    local bgr, bgg, bgb = 0, 0, 0
    if Helpers and Helpers.GetSkinBgColor then bgr, bgg, bgb = Helpers.GetSkinBgColor() end
    frame:SetBackdropColor(bgr, bgg, bgb, 0.6)
    UIKit.CreateBorderLines(frame)
    UIKit.UpdateBorderLines(frame, 1, 0, 0, 0, 1)

    -- Draining StatusBar (DurationObject fill)
    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    bar:SetMinMaxValues(0, 1)        -- required for SetTimerDuration normalization
    bar:SetValue(0)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    bar:SetStatusBarColor(0.6, 0.2, 0.2, 1)
    frame.bar = bar

    -- Countdown number: a Cooldown frame draws the remaining time C-side from the
    -- same DurationObject (secret-safe in combat); swipe/edge off so only the
    -- number shows.
    local count = CreateFrame("Cooldown", nil, bar, "CooldownFrameTemplate")
    count:SetAllPoints(bar)
    count:SetDrawSwipe(false)
    count:SetDrawEdge(false)
    count:SetHideCountdownNumbers(false)
    frame.count = count

    -- Optional label (e.g. "Lust") shown left of the bar.
    local label = bar:CreateFontString(nil, "OVERLAY")
    label:SetPoint("LEFT", bar, "LEFT", 4, 0)
    CJKFont(label, (Helpers and Helpers.GetGeneralFont and Helpers.GetGeneralFont()) or "Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    label:SetTextColor(1, 1, 1, 1)
    label:SetText(ns.L and ns.L["Lust"] or "Lust")
    frame.label = label

    frame:Hide()
    State.frame = frame
end

---------------------------------------------------------------------------
-- Appearance from settings
---------------------------------------------------------------------------
local function UpdateAppearance()
    if not State.frame then CreateTimerFrame() end
    local settings = GetSettings()
    if not settings then return end
    local frame = State.frame

    local width = settings.width or 160
    local height = settings.height or 22
    frame:SetSize(width, height)

    local xOffset = settings.xOffset or 0
    local yOffset = settings.yOffset or -120
    if not (_G.QUI_HasFrameAnchor and _G.QUI_HasFrameAnchor("lustTimer")) then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", xOffset, yOffset)
    end

    -- Bar texture + color
    local texturePath = (ns.LSM and ns.LSM.Fetch and ns.LSM:Fetch("statusbar", settings.barTexture or "Solid"))
        or "Interface\\Buttons\\WHITE8x8"
    frame.bar:SetStatusBarTexture(texturePath)
    local bc = settings.barColor or { 0.6, 0.2, 0.2, 1 }
    frame.bar:SetStatusBarColor(bc[1], bc[2], bc[3], bc[4] or 1)

    -- Label
    local fontSize = settings.fontSize or 13
    local fontName = settings.useCustomFont and settings.font or (QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.general and QUICore.db.profile.general.font) or "Quazii"
    local fontPath = UIKit.ResolveFontPath(fontName)
    CJKFont(frame.label, fontPath, fontSize, "OUTLINE")
    local tc = settings.textColor or { 1, 1, 1, 1 }
    frame.label:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
    if settings.showLabel == false then frame.label:Hide() else frame.label:Show() end

    -- Backdrop / border (mirrors combat timer)
    local borderSize = settings.borderSize or 1
    local bR, bG, bB, bA = Helpers.GetSkinBorderColor(settings, "")
    local bgColor = settings.backdropColor or { 0, 0, 0, 0.6 }
    frame:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.6)
    UIKit.CreateBorderLines(frame)
    UIKit.UpdateBorderLines(frame, borderSize, bR, bG, bB, bA, settings.hideBorder)
end

---------------------------------------------------------------------------
-- Show / hide on detection
---------------------------------------------------------------------------
local function ShowFor(instanceID)
    local settings = GetSettings()
    if not settings or not settings.enabled then return end
    if State.isPreviewMode then return end
    CreateTimerFrame()
    UpdateAppearance()
    State.activeInstanceID = instanceID
    if not BindDuration(State.frame.bar, State.frame.count, instanceID) then
        -- Duration bind failed (GetAuraDuration gated/restricted): drop any
        -- previous instance's stale drain and show a static full bar — Lust
        -- IS active (we just resolved its aura), only its timing is
        -- unreadable. In-game note: if a prior SetTimerDuration binding
        -- keeps engine-driving the fill past SetValue, this still beats
        -- rendering the OLD instance's drain.
        if State.frame.count then State.frame.count:Clear() end
        State.frame.bar:SetMinMaxValues(0, 1)
        State.frame.bar:SetValue(1)
    end
    State.frame:Show()
end

local function HideTimer()
    State.activeInstanceID = nil
    if State.frame and not State.isPreviewMode then
        if State.frame.count then State.frame.count:Clear() end
        State.frame:Hide()
    end
end

---------------------------------------------------------------------------
-- Player aura handler (coalesced UNIT_AURA delta)
---------------------------------------------------------------------------
local function ScanForLust()
    -- Probe by literal spellID. GetPlayerAuraBySpellID is RequiresNonSecretAura:
    -- it returns the AuraData when the aura is readable, nil when it is secret.
    -- The Lust family is flagged never-secret on Blizzard's whitelist, so this
    -- resolves in combat too (where Lust is actually cast) — no OOC gate.
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return end
    for spellID in pairs(LUST_SPELLS) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
        aura = Helpers.SafeValue(aura)
        if ok and aura and aura.auraInstanceID then
            ShowFor(aura.auraInstanceID)
            return
        end
    end

    -- No Lust resolved. When auras are NOT restricted that is definitive —
    -- the tracked instance is gone, so clear it (otherwise a full update that
    -- swallowed the removal delta leaves the bar up forever). Under
    -- restriction nil is ambiguous (whitelist fate is an in-game unknown), so
    -- retain the bound bar and let the PLAYER_REGEN_ENABLED rescan below give
    -- the definitive answer once restriction lifts.
    if State.activeInstanceID then
        local restricted = C_Secrets and C_Secrets.ShouldAurasBeSecret
            and C_Secrets.ShouldAurasBeSecret()
        if not restricted then
            HideTimer()
        end
    end
end

local function OnPlayerAura(_, info)
    local settings = GetSettings()
    if not settings or not settings.enabled then return end

    if info == nil then
        -- Full update: per-aura delta is gone. Re-probe by spellID (works in
        -- combat for the whitelisted Lust family); if it can't resolve, keep
        -- whatever is currently bound (the DurationObject keeps draining).
        ScanForLust()
        return
    end

    -- Element readability is router-guaranteed: core/aura_events.lua promotes
    -- any delta with secret arrays, elements, or added-aura identity fields to
    -- the full-update sentinel (info == nil), so the compares below are safe.
    if info.removedAuraInstanceIDs and State.activeInstanceID then
        for _, instID in ipairs(info.removedAuraInstanceIDs) do
            if instID == State.activeInstanceID then
                HideTimer()
                break
            end
        end
    end

    -- Additions: match the added aura's spellId against the Lust set. The Lust
    -- family is whitelisted non-secret so this resolves in combat; the
    -- issecretvalue guard still protects the table-index if it ever isn't.
    if info.addedAuras then
        for _, data in ipairs(info.addedAuras) do
            local sid = data and data.spellId
            local secret = issecretvalue and issecretvalue(sid)
            if sid and not secret and LUST_SPELLS[sid] and not SATED_SPELLS[sid] then
                ShowFor(data.auraInstanceID)
                break
            end
        end
    end
end

---------------------------------------------------------------------------
-- Refresh / preview
---------------------------------------------------------------------------
local function RefreshLustTimer()
    local settings = GetSettings()
    if (not settings or not settings.enabled) and not State.isPreviewMode then
        HideTimer()
        return
    end
    UpdateAppearance()
    -- Re-probe in case a Lust is already up when the feature is toggled on.
    if settings and settings.enabled and not State.isPreviewMode then
        ScanForLust()
    end
end

local function TogglePreview(enable)
    CreateTimerFrame()
    if not State.frame then return end
    State.isPreviewMode = enable
    if enable then
        UpdateAppearance()
        State.frame.bar:SetMinMaxValues(0, 1)
        State.frame.bar:SetValue(0.66)
        if State.frame.count then State.frame.count:Clear() end
        State.frame:Show()
    else
        local settings = GetSettings()
        if not (settings and settings.enabled and State.activeInstanceID) then
            State.frame:Hide()
        end
    end
end

local function IsPreviewMode()
    return State.isPreviewMode
end

---------------------------------------------------------------------------
-- Init (login install + aura subscription)
---------------------------------------------------------------------------
if ns.WhenLoggedIn then
    ns.WhenLoggedIn(function()
        CreateTimerFrame()
        if ns.AuraEvents and ns.AuraEvents.Subscribe then
            ns.AuraEvents:Subscribe("player", OnPlayerAura)
        end
        RefreshLustTimer()
    end)
end

-- Restriction-lift recovery: if Lust expired while aura data was restricted
-- (removal delta swallowed, restricted rescans ambiguous), the bar survives
-- combat. Regen is the practical lift point — one definitive rescan clears or
-- rebinds it. Only re-probe when a bar is actually up.
local regenFrame = CreateFrame("Frame")
regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
regenFrame:SetScript("OnEvent", function()
    if State.activeInstanceID and not State.isPreviewMode then
        ScanForLust()
    end
end)

---------------------------------------------------------------------------
-- Globals + registry
---------------------------------------------------------------------------
_G.QUI_RefreshLustTimer = RefreshLustTimer
_G.QUI_ToggleLustTimerPreview = TogglePreview

QUI.LustTimer = {
    Refresh = RefreshLustTimer,
    TogglePreview = TogglePreview,
    IsPreviewMode = IsPreviewMode,
}

if ns.Registry then
    ns.Registry:Register("lustTimer", {
        refresh = _G.QUI_RefreshLustTimer,
        priority = 40,
        group = "trackers",
        importCategories = { "trackersTimers" },
    })
    ns.Registry:Register("lustTimerSkin", {
        refresh = _G.QUI_RefreshLustTimer,
        priority = 40,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

if Helpers and Helpers.BorderRegistry then
    Helpers.BorderRegistry.Register({
        key = "lustTimer", label = "Lust Timer", category = "Trackers", prefix = "",
        db = function(p) return p.lustTimer end,
        refresh = function() if _G.QUI_RefreshLustTimer then _G.QUI_RefreshLustTimer() end end,
        legacy = { useClass = "useClassColorBorder", accent = "useAccentColorBorder" },
    })
end
