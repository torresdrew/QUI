--[[
    QUI Nameplates — castbar (consumes the shared cast engine, ns.CastEngine).

    Every plate unit is non-player, so the secret-timing/engine-driven path
    is the PRIMARY path: SetTimerDuration(durationObj, 0, direction) set once
    per cast — casts/empowered fill (0), channels drain (1) — and the C
    engine animates. No per-frame Lua for the fill.

    Timer text runs on ONE shared 10 Hz ticker with a refcount (active while
    any plate is casting), reading GetRemainingDuration under pcall into
    SetFormattedText("%.1f") via CastEngine.UpdateTimerText.

    Uninterruptible state can be secret: a user-facing grey overlay + shield
    icon are driven by SetAlphaFromBoolean(secret, ...) — no Lua branch ever
    inspects the secret. Clean booleans take the direct color path.

    Cast events arrive via one global dispatcher frame (13 UNIT_SPELLCAST_*
    events) routing through the unit registry — never per-plate registration.

    Teardown decisions use UnitExists (plain false when the mob despawns);
    UnitCastingInfo truthiness is the "stale secret channel info" hazard.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local Helpers = ns.Helpers
local UIKit = ns.UIKit
local QUICore = ns.Addon
local LSM = ns.LSM
local CastEngine = ns.CastEngine

local type = type
local pcall = pcall
local GetTime = GetTime
local CreateFrame = CreateFrame
local UnitExists = UnitExists

local NPCastbar = {}
NP.Castbar = NPCastbar

local WHITE8X8 = "Interface\\Buttons\\WHITE8x8"
local SHIELD_TEXTURE = "Interface\\RaidFrame\\Shield-Overshield"

local function GetBarTexture(name)
    if LSM and name then
        local ok, path = pcall(LSM.Fetch, LSM, "statusbar", name, true)
        if ok and path then return path end
    end
    return WHITE8X8
end

---------------------------------------------------------------------------
-- SHARED 10 Hz TIMER-TEXT TICKER (refcounted)
---------------------------------------------------------------------------
local activeCastPlates = {}   -- [plate] = true
local activeCount = 0
local textTicker = nil

local function TickCastText()
    for plate in pairs(activeCastPlates) do
        local castBar = plate.castBar
        if castBar and plate.npShowCastTimer then
            CastEngine.UpdateTimerText(castBar)
        end
        -- Despawn teardown: UnitExists returns a plain false once the unit
        -- is gone even when cast info would still read as a truthy secret.
        local unit = plate.unit
        if not unit or not UnitExists(unit) then
            NPCastbar.StopCast(plate)
        end
    end
end

local function CastTickerAcquire(plate)
    if activeCastPlates[plate] then return end
    activeCastPlates[plate] = true
    activeCount = activeCount + 1
    if not textTicker and C_Timer and C_Timer.NewTicker then
        textTicker = C_Timer.NewTicker(0.1, TickCastText)
    end
end

local function CastTickerRelease(plate)
    if not activeCastPlates[plate] then return end
    activeCastPlates[plate] = nil
    activeCount = activeCount - 1
    if activeCount <= 0 then
        activeCount = 0
        if textTicker then
            textTicker:Cancel()
            textTicker = nil
        end
    end
end

---------------------------------------------------------------------------
-- KICK TICK (v1.1): where the player's interrupt lands on the cast timeline
---------------------------------------------------------------------------
-- Construction: a second StatusBar (invisible fill) anchored to the cast
-- fill texture's leading edge, value domain = the cast's total duration
-- (possibly secret — SetMinMaxValues is a secret sink), engine-animated
-- with the INTERRUPT's cooldown DurationObject draining toward zero. Both
-- edges animate C-side, so the tick (a texture pinned to the kick bar's
-- fill edge) converges onto the cast's leading edge exactly when the kick
-- comes off cooldown. Both anchors are re-pinned together on
-- SPELL_UPDATE_COOLDOWN/USABLE or the tick drifts.

-- Class interrupt candidates, first known wins (player spells — cooldown
-- values are always plain).
local INTERRUPT_SPELLS = {
    1766,   -- Rogue: Kick
    6552,   -- Warrior: Pummel
    2139,   -- Mage: Counterspell
    57994,  -- Shaman: Wind Shear
    96231,  -- Paladin: Rebuke
    47528,  -- Death Knight: Mind Freeze
    106839, -- Druid: Skull Bash
    116705, -- Monk: Spear Hand Strike
    183752, -- Demon Hunter: Disrupt
    147362, -- Hunter: Counter Shot
    187707, -- Hunter (SV): Muzzle
    351338, -- Evoker: Quell
    15487,  -- Priest: Silence
    119910, -- Warlock: Spell Lock (command demon)
}

local interruptSpellID = nil
local interruptResolved = false

local function ResolveInterruptSpell()
    interruptResolved = true
    interruptSpellID = nil
    local isKnown = IsSpellKnown
    local isPlayerSpell = IsPlayerSpell
    for i = 1, #INTERRUPT_SPELLS do
        local id = INTERRUPT_SPELLS[i]
        local known = false
        if isPlayerSpell then
            local ok, v = pcall(isPlayerSpell, id)
            known = ok and NP.Plain(v, "boolean") == true
        end
        if not known and isKnown then
            local ok, v = pcall(isKnown, id)
            known = ok and NP.Plain(v, "boolean") == true
        end
        if known then
            interruptSpellID = id
            return id
        end
    end
    return nil
end

local function GetInterruptSpell()
    if not interruptResolved then
        ResolveInterruptSpell()
    end
    return interruptSpellID
end

-- Plain remaining seconds of the player's interrupt CD. Player-spell
-- cooldowns are plain in practice, but GetSpellCooldown is a cooldown-secret
-- source by contract — unwrap through SafeToNumber (secret ⇒ 0 ⇒ no tick,
-- fail closed). Returns 0 when ready or unknown.
local SafeToNumber = Helpers.SafeToNumber
local function GetInterruptRemaining()
    local spellID = GetInterruptSpell()
    if not spellID or not (C_Spell and C_Spell.GetSpellCooldown) then return 0 end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or type(info) ~= "table" then return 0 end
    local start = SafeToNumber(info.startTime, 0)
    local duration = SafeToNumber(info.duration, 0)
    -- Ignore the GCD (short duration) — only a real CD produces a tick.
    if duration <= 1.6 then return 0 end
    local remaining = (start + duration) - GetTime()
    if remaining < 0 then remaining = 0 end
    return remaining
end

-- Re-pin BOTH anchors and re-arm the drain. Fill textures are re-created by
-- SetStatusBarTexture and the engine re-bases on new duration objects, so
-- partial refreshes drift.
local function PinKickTick(plate)
    local castBar = plate.castBar
    local kickBar = plate.kickBar
    if not kickBar or not plate.npCasting or not plate.npKickTickEnabled then return end

    if GetInterruptRemaining() <= 0 then
        kickBar:Hide()
        return
    end
    local durationObj = castBar.durationObj
    if durationObj == nil then
        kickBar:Hide()
        return
    end

    -- Anchor 1: kick bar starts at the cast fill's leading edge.
    local fillTex = castBar:GetStatusBarTexture()
    if not fillTex then
        kickBar:Hide()
        return
    end
    kickBar:ClearAllPoints()
    kickBar:SetPoint("TOPLEFT", fillTex, "TOPRIGHT", 0, 0)
    kickBar:SetPoint("BOTTOMLEFT", fillTex, "BOTTOMRIGHT", 0, 0)

    -- Value domain: the cast's total duration — possibly secret, and
    -- SetMinMaxValues accepts it raw.
    local okTotal, total = pcall(function()
        local getter = durationObj.GetTotalDuration or durationObj.GetDuration or durationObj.GetMaxDuration
        return getter and getter(durationObj) or nil
    end)
    if not okTotal or total == nil then
        kickBar:Hide()
        return
    end
    pcall(kickBar.SetMinMaxValues, kickBar, 0, total)

    -- Drain the interrupt's cooldown DurationObject C-side (direction 1).
    local armed = false
    if C_Spell and C_Spell.GetSpellCooldownDuration then
        local spellID = GetInterruptSpell()
        local okCD, cdObj = pcall(C_Spell.GetSpellCooldownDuration, spellID)
        if okCD and cdObj ~= nil then
            armed = CastEngine.ApplyTimerDriven(kickBar, cdObj, 1)
        end
    end
    if not armed then
        -- Static fallback: plain remaining, no animation (still re-pinned on
        -- every cooldown event).
        kickBar:SetValue(GetInterruptRemaining())
    end
    kickBar:Show()
end

-- Cooldown events re-pin every casting plate's tick (module-level frame;
-- these events are player-scoped and infrequent outside spam).
local kickEventFrame = CreateFrame("Frame")
kickEventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
kickEventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
kickEventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
kickEventFrame:RegisterEvent("SPELLS_CHANGED")
kickEventFrame:RegisterEvent("UI_SCALE_CHANGED")
kickEventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
kickEventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "SPELLS_CHANGED" then
        interruptResolved = false
        return
    end
    if event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        -- Re-pin lift-overlay scale for every managed plate (rare event).
        for _, plate in pairs(NP.plates) do
            if plate.npLiftOverlay and NPCastbar.ApplyLift then
                NPCastbar.ApplyLift(plate)
            end
        end
        return
    end
    if activeCount == 0 then return end
    for plate in pairs(activeCastPlates) do
        if plate.npKickTickEnabled and plate.npCasting then
            PinKickTick(plate)
        end
    end
end)

local ApplyLift -- defined in the LIFT OVERLAY section below

---------------------------------------------------------------------------
-- BUILD (once per pooled plate)
---------------------------------------------------------------------------
function NPCastbar.Build(plate)
    local castBar = CreateFrame("StatusBar", nil, plate)
    castBar:SetStatusBarTexture(WHITE8X8)
    castBar:SetMinMaxValues(0, 1)
    castBar:SetValue(0)
    castBar:EnableMouse(false)
    castBar:Hide()
    plate.castBar = castBar

    plate.castBg = UIKit.CreateBackground(castBar, 0.1, 0.1, 0.1, 0.9)
    UIKit.CreateBorderLines(castBar)

    -- Grey uninterruptible overlay: alpha driven by the (possibly secret)
    -- notInterruptible boolean via SetAlphaFromBoolean — never branched on.
    local overlay = castBar:CreateTexture(nil, "ARTWORK", nil, 2)
    overlay:SetAllPoints(castBar)
    overlay:SetColorTexture(0.45, 0.45, 0.45, 0.85)
    overlay:SetAlpha(0)
    plate.castUninterruptibleOverlay = overlay

    local shield = castBar:CreateTexture(nil, "OVERLAY")
    shield:SetTexture(SHIELD_TEXTURE)
    shield:SetAlpha(0)
    plate.castShield = shield

    local icon = castBar:CreateTexture(nil, "ARTWORK")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    plate.castIcon = icon

    plate.castSpellText = UIKit.CreateText(castBar, 10, nil, "OUTLINE", "OVERLAY")
    plate.castSpellText:SetPoint("LEFT", castBar, "LEFT", 2, 0)
    plate.castSpellText:SetJustifyH("LEFT")

    -- Field name `timeText` is the CastEngine.UpdateTimerText contract.
    castBar.timeText = UIKit.CreateText(castBar, 10, nil, "OUTLINE", "OVERLAY")
    castBar.timeText:SetPoint("RIGHT", castBar, "RIGHT", -2, 0)
    castBar.timeText:SetJustifyH("RIGHT")

    -- Kick tick: invisible drain bar + tick texture on its fill edge.
    local kickBar = CreateFrame("StatusBar", nil, castBar)
    kickBar:SetStatusBarTexture(WHITE8X8)
    kickBar:SetStatusBarColor(0, 0, 0, 0)
    kickBar:SetFrameLevel(castBar:GetFrameLevel() + 2)
    kickBar:EnableMouse(false)
    kickBar:Hide()
    plate.kickBar = kickBar

    local kickTick = kickBar:CreateTexture(nil, "OVERLAY", nil, 6)
    kickTick:SetColorTexture(0.92, 0.35, 0.20, 1)
    local kickFill = kickBar:GetStatusBarTexture()
    if kickFill then
        kickTick:SetPoint("CENTER", kickFill, "RIGHT", 0, 0)
    end
    plate.kickTick = kickTick
end

---------------------------------------------------------------------------
-- APPEARANCE (generation-gated static styling)
---------------------------------------------------------------------------
function NPCastbar.ApplyAppearance(plate, settings)
    local cast = settings.castbar or {}
    local health = settings.health or {}
    local castBar = plate.castBar

    plate.npCastEnabled = cast.enabled ~= false
    plate.npShowCastTimer = cast.showTimer ~= false
    plate.npKickTickEnabled = cast.kickTick ~= false
    plate.npLiftOverlay = cast.liftOverlay == true

    local width = health.width or 210
    local height = cast.height or 17
    QUICore:SetPixelPerfectSize(plate.kickTick, 2, height + 4)
    -- Width caps the drain bar's extent so a long CD can't spill past the
    -- bar; the engine clamps the fill to the (secret) cast-domain max.
    plate.kickBar:SetWidth(QUICore:Pixels(width, plate))
    QUICore:SetPixelPerfectSize(castBar, width, height)
    castBar:ClearAllPoints()
    castBar:SetPoint("TOP", plate.healthBar, "BOTTOM", 0, -QUICore:Pixels((cast.gap or 0) + 1, plate))
    castBar:SetStatusBarTexture(GetBarTexture(health.texture))
    local tex = castBar:GetStatusBarTexture()
    if tex then
        tex:SetHorizTile(false)
        tex:SetVertTile(false)
    end
    UIKit.UpdateBorderLines(castBar, health.borderSize or 1, 0, 0, 0, 1, (health.borderSize or 1) <= 0)

    local iconSize = height
    plate.castIcon:ClearAllPoints()
    plate.castIcon:SetPoint("RIGHT", castBar, "LEFT", -QUICore:Pixels(2, plate), 0)
    QUICore:SetPixelPerfectSize(plate.castIcon, iconSize, iconSize)
    if cast.showIcon == false then plate.castIcon:Hide() else plate.castIcon:Show() end

    plate.castShield:ClearAllPoints()
    plate.castShield:SetPoint("CENTER", plate.castIcon, "CENTER", 0, 0)
    QUICore:SetPixelPerfectSize(plate.castShield, iconSize + 6, iconSize + 6)

    local fontPath = UIKit.ResolveFontPath()
    QUICore:ApplyFont(plate.castSpellText, nil, cast.nameSize or 10, fontPath, "OUTLINE")
    QUICore:ApplyFont(plate.castBar.timeText, nil, cast.timerSize or 10, fontPath, "OUTLINE")
    if cast.showSpellName == false then plate.castSpellText:Hide() else plate.castSpellText:Show() end
    if cast.showTimer == false then castBar.timeText:Hide() else castBar.timeText:Show() end

    plate.castSpellText:SetWidth(QUICore:Pixels(width - 34, plate))

    -- Lift overlay reparenting last: the castBar keeps its cross-tree anchor
    -- to the health bar, so position is unchanged — only strata/scale move.
    ApplyLift(plate)
end

---------------------------------------------------------------------------
-- LIFT OVERLAY (v1.1): render the castbar above neighboring plates
---------------------------------------------------------------------------
-- Reparents the REAL castbar (never a mirror bar) into a HIGH-strata
-- per-plate container under UIParent. SetIgnoreParentScale(true) with
-- effective-scale pinning keeps it pixel-identical — valid ONLY because the
-- CVar block pins plate scale to 1. Container visibility follows the plate
-- via OnShow/OnHide hooks; anchors track the health bar across bases.
ApplyLift = function(plate)
    local castBar = plate.castBar
    if not castBar then return end

    if not plate.npLiftOverlay then
        if plate.npLiftContainer then
            plate.npLiftContainer:Hide()
        end
        if castBar:GetParent() ~= plate then
            castBar:SetParent(plate)
            -- ApplyAppearance re-anchors below the health bar right after.
        end
        return
    end

    local container = plate.npLiftContainer
    if not container then
        container = CreateFrame("Frame", nil, UIParent)
        container:SetFrameStrata("HIGH")
        container:SetSize(1, 1)
        if container.SetIgnoreParentScale then
            container:SetIgnoreParentScale(true)
        end
        plate.npLiftContainer = container
        -- Visibility sync: the container lives outside the plate tree.
        plate:HookScript("OnHide", function() container:Hide() end)
        plate:HookScript("OnShow", function()
            if plate.npLiftOverlay then container:Show() end
        end)
    end

    local okScale, scale = pcall(plate.GetEffectiveScale, plate)
    scale = okScale and NP.Plain(scale, "number") or nil
    if scale and scale > 0 then
        container:SetScale(scale)
    end
    container:ClearAllPoints()
    container:SetPoint("TOP", plate.healthBar, "BOTTOM", 0, 0)
    container:SetShown(plate:IsShown())

    castBar:SetParent(container)
end
NPCastbar.ApplyLift = ApplyLift

---------------------------------------------------------------------------
-- CAST LIFECYCLE
---------------------------------------------------------------------------
local function ApplyInterruptibleVisuals(plate, notInterruptible, settings)
    local colors = (settings or NP.GetSettings()).colors or {}
    local castBar = plate.castBar

    -- NP.Plain, not type(): a SECRET boolean reports type "boolean" and
    -- errors on its first truthiness test (the live 12.0 combat scar).
    local plainNI = NP.Plain(notInterruptible, "boolean")
    if plainNI ~= nil then
        -- Clean boolean: direct color path, overlay off.
        local c = plainNI and (colors.castUninterruptible or { 0.45, 0.45, 0.45 })
            or (colors.castInterruptible or { 0.70, 0.40, 0.90 })
        castBar:SetStatusBarColor(c[1], c[2], c[3])
        plate.castUninterruptibleOverlay:SetAlpha(0)
        plate.castShield:SetAlpha(plainNI and 1 or 0)
        return
    end

    -- Secret (or unavailable): interruptible base color; the grey overlay and
    -- shield consume the secret through the C-side boolean-alpha sink.
    local c = colors.castInterruptible or { 0.70, 0.40, 0.90 }
    castBar:SetStatusBarColor(c[1], c[2], c[3])
    if type(notInterruptible) ~= "nil"
        and plate.castUninterruptibleOverlay.SetAlphaFromBoolean then
        pcall(plate.castUninterruptibleOverlay.SetAlphaFromBoolean,
            plate.castUninterruptibleOverlay, notInterruptible, 1, 0)
        pcall(plate.castShield.SetAlphaFromBoolean, plate.castShield, notInterruptible, 1, 0)
    else
        plate.castUninterruptibleOverlay:SetAlpha(0)
        plate.castShield:SetAlpha(0)
    end
end

-- Full setup on START only; DELAYED/CHANNEL_UPDATE re-arm the timer only.
local function StartCast(plate)
    if not plate.npCastEnabled then return end
    local unit = plate.unit
    if not unit then return end

    local spellName, text, texture, startTimeMS, endTimeMS, notInterruptible,
        _, isChanneled, _, durationObj, hasSecretTiming = CastEngine.GetCastInfo(unit)

    local castBar = plate.castBar
    local canShow, useTimerDriven, startTime, endTime = CastEngine.ResolveNonPlayerTiming(
        spellName, startTimeMS, endTimeMS, durationObj, castBar, hasSecretTiming)
    if not canShow then
        NPCastbar.StopCast(plate)
        return
    end

    plate.npCasting = true
    plate.npInterrupted = nil
    plate.npChanneled = isChanneled
    castBar.durationObj = durationObj

    if useTimerDriven then
        -- Engine fill: casts/empowered fill (0), channels drain (1).
        CastEngine.ApplyTimerDriven(castBar, durationObj, isChanneled and 1 or 0)
        plate.npCastStart, plate.npCastEnd = nil, nil
    elseif durationObj then
        -- Clean timing but a duration object exists — still let the engine
        -- animate (zero per-frame Lua beats manual progress math).
        CastEngine.ApplyTimerDriven(castBar, durationObj, isChanneled and 1 or 0)
        plate.npCastStart, plate.npCastEnd = nil, nil
    else
        -- Rare fallback: no duration object. Static min/max + a coarse fill
        -- from the shared ticker (10 Hz is fine for a plate).
        plate.npCastStart, plate.npCastEnd = startTime, endTime
        castBar:SetMinMaxValues(startTime or 0, endTime or 1)
        castBar:SetValue(startTime or 0)
    end

    -- Spell name/icon/timer: straight to C-side sinks (accept secrets).
    pcall(plate.castIcon.SetTexture, plate.castIcon, texture)
    local okName = pcall(plate.castSpellText.SetText, plate.castSpellText, text or spellName)
    if not okName then plate.castSpellText:SetText("") end
    castBar.timeText:SetText("")

    ApplyInterruptibleVisuals(plate, notInterruptible)

    castBar:Show()
    CastTickerAcquire(plate)

    if plate.npKickTickEnabled then
        PinKickTick(plate)
    end
end

-- DELAYED / CHANNEL_UPDATE: re-arm the engine timer only.
local function RearmCast(plate)
    if not plate.npCasting then return end
    local unit = plate.unit
    if not unit then return end
    local spellName, _, _, startTimeMS, endTimeMS, _, _, isChanneled, _, durationObj, hasSecretTiming =
        CastEngine.GetCastInfo(unit)
    local castBar = plate.castBar
    local canShow, useTimerDriven = CastEngine.ResolveNonPlayerTiming(
        spellName, startTimeMS, endTimeMS, durationObj, castBar, hasSecretTiming)
    if not canShow then return end
    castBar.durationObj = durationObj
    if useTimerDriven or durationObj then
        CastEngine.ApplyTimerDriven(castBar, durationObj, isChanneled and 1 or 0)
    end
    -- The cast domain changed (pushback/haste re-read) — re-pin the tick.
    if plate.npKickTickEnabled then
        PinKickTick(plate)
    end
end

function NPCastbar.StopCast(plate)
    plate.npCasting = nil
    plate.npInterrupted = nil
    plate.npChanneled = nil
    plate.npCastStart, plate.npCastEnd = nil, nil
    local castBar = plate.castBar
    if castBar then
        castBar.durationObj = nil
        castBar._durationGetter = nil
        castBar._durationGetterObj = nil
        castBar:Hide()
    end
    if plate.kickBar then
        plate.kickBar:Hide()
    end
    CastTickerRelease(plate)
end

---------------------------------------------------------------------------
-- INTERRUPTED FLASH
---------------------------------------------------------------------------
local INTERRUPT_HOLD_FALLBACK = 1.0

local function ShowInterrupted(plate, interrupterGUID)
    local settings = NP.GetSettings()
    local colors = settings.colors or {}
    local castBar = plate.castBar
    if not plate.npCastEnabled then return end

    plate.npCasting = nil
    plate.npInterrupted = true
    castBar.durationObj = nil

    local c = colors.castInterrupted or { 0.8, 0, 0 }
    castBar:SetStatusBarColor(c[1], c[2], c[3])
    castBar:SetMinMaxValues(0, 1)
    castBar:SetValue(1)
    plate.castUninterruptibleOverlay:SetAlpha(0)
    plate.castShield:SetAlpha(0)
    castBar.timeText:SetText("")

    -- Interrupter name from the event-arg GUID, class-colored. The GUID is
    -- SECRET in restricted combat — only a verifiably plain GUID feeds the
    -- name lookup (a secret one just shows the bare "Interrupted" label).
    local label = _G.INTERRUPTED or "Interrupted"
    local plainGUID = NP.Plain(interrupterGUID, "string")
    if plainGUID and plainGUID ~= "" then
        local okInfo, _, classToken, _, _, _, interrupterName = pcall(GetPlayerInfoByGUID, plainGUID)
        interrupterName = NP.Plain(interrupterName, "string")
        classToken = NP.Plain(classToken, "string")
        if okInfo and interrupterName and interrupterName ~= "" then
            local cc = RAID_CLASS_COLORS and classToken and RAID_CLASS_COLORS[classToken]
            if cc and cc.colorStr then
                label = label .. ": |c" .. cc.colorStr .. interrupterName .. "|r"
            else
                label = label .. ": " .. interrupterName
            end
        end
    end
    plate.castSpellText:SetText(label)
    castBar:Show()

    -- Hold the flash, guarded against late STOPs (_interrupted) and death.
    local holdFor = (settings.castbar and settings.castbar.interruptedHoldTime) or INTERRUPT_HOLD_FALLBACK
    local unitAtFlash = plate.unit
    C_Timer.After(holdFor, function()
        if plate.npInterrupted and plate.unit == unitAtFlash then
            NPCastbar.StopCast(plate)
        end
    end)
end

---------------------------------------------------------------------------
-- GLOBAL CAST DISPATCHER (one frame, 13 events, registry routing)
---------------------------------------------------------------------------
local CAST_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_STOP",
    "UNIT_SPELLCAST_EMPOWER_UPDATE",
    "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local dispatcher = CreateFrame("Frame")
for i = 1, #CAST_EVENTS do
    dispatcher:RegisterEvent(CAST_EVENTS[i])
end

dispatcher:SetScript("OnEvent", function(_, event, unit, arg2, arg3, arg4)
    local plate = NP.plates[unit]
    if not plate then return end

    if event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_EMPOWER_START" then
        StartCast(plate)
    elseif event == "UNIT_SPELLCAST_DELAYED"
        or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
        or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        RearmCast(plate)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- 12.0 payload: unit, castGUID, spellID, interrupterGUID (defensive).
        ShowInterrupted(plate, arg4 or arg3)
    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_EMPOWER_STOP"
        or event == "UNIT_SPELLCAST_FAILED" then
        -- Late STOPs during the interrupted flash must not cut it short.
        if not plate.npInterrupted then
            NPCastbar.StopCast(plate)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        if plate.npCasting then ApplyInterruptibleVisuals(plate, false) end
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        if plate.npCasting then ApplyInterruptibleVisuals(plate, true) end
    end
end)

-- A plate acquired mid-cast (spawn during a pull) misses the START event;
-- the driver's deferred phase probes once.
function NPCastbar.ProbeCast(plate)
    if plate.npCasting or plate.npInterrupted then return end
    StartCast(plate)
end

---------------------------------------------------------------------------
-- PERF INSTRUMENTATION
---------------------------------------------------------------------------
local function SetupDebugInstrumentation()
    ns.QUI_PerfRegistry = ns.QUI_PerfRegistry or {}
    ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "NameplateCast", frame = dispatcher }
end
if ns.DebugRegister then
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation()
end
