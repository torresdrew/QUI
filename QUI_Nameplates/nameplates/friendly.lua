--[[
    QUI Nameplates — friendly plates: modes, instance gating, watchers.

    Modes (settings.friendly.mode):
      "nameonly" (default) — Blizzard's name-only plates stay; QUI restores
          the suppressed art and drives the name-only + class-color CVars.
      "bars" — a second, THINNER pool: health + name + raid marker + target
          glow only (no castbar/auras/threat), class-colored for players.
      "off" — the friendly visibility CVar group is relinquished entirely
          (uihider or Blizzard settings own it).

    Honest instance gating: in real instances Blizzard protects friendly
    plates (GetNamePlateForUnit returns nil / forced name-only) — bars mode
    is forced down to name-only there, and friendly NPC plates are
    CVar-disabled. We manage what the API allows and gate the rest.

    Ownership transitions: every non-attackable unit keeps a pending watcher
    (UNIT_FLAGS/UNIT_NAME_UPDATE) that PROMOTES it to a full enemy plate the
    moment it becomes attackable (duels, mind control); the enemy plate's
    own UNIT_FLAGS handler is the demotion mirror. Promotion re-asserts
    suppression before the enemy plate builds, so the Blizzard UF never
    flashes across the swap.

    CVar writes are pcall-wrapped, combat-deferred (via ns.QUI_NameplatesCVars),
    and Blizzard creates plates ASYNCHRONOUSLY after visibility flips — mode
    changes schedule staggered delayed sweeps that re-route any base the
    events missed.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local Helpers = ns.Helpers
local UIKit = ns.UIKit
local QUICore = ns.Addon

local type = type
local pcall = pcall
local pairs = pairs
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitCanAttack = UnitCanAttack
local UnitName = UnitName

local NPFriendly = {}
NP.Friendly = NPFriendly

local friendlyPlates = NP.friendlyPlates
local WHITE8X8 = "Interface\\Buttons\\WHITE8x8"

---------------------------------------------------------------------------
-- MODE RESOLUTION (pure over settings + cached context)
---------------------------------------------------------------------------
function NPFriendly.GetEffectiveMode(friendlySettings, context)
    friendlySettings = friendlySettings or {}
    local mode = friendlySettings.mode or "nameonly"
    if mode == "off" then return "off" end
    -- Real instances force name-only: bars need GetNamePlateForUnit access
    -- that protected friendly plates don't grant.
    if context and context.inInstance == true then
        if friendlySettings.showInInstances == false then
            return "off"
        end
        return "nameonly"
    end
    return mode
end

local function EffectiveMode()
    local s = NP.GetSettings()
    return NPFriendly.GetEffectiveMode(s.friendly, NP.Extras.GetContext())
end

---------------------------------------------------------------------------
-- PENDING WATCHERS (promotion: friendly → enemy)
---------------------------------------------------------------------------
local watchers = {}        -- [unit] = watcher frame
local watcherPool = {}

local function WatcherOnEvent(watcher, event, unit)
    if unit ~= watcher.npUnit then return end
    -- NP.Plain: a secret verdict must not promote (and must not error).
    local ok, attackable = pcall(UnitCanAttack, "player", unit)
    if ok and NP.Plain(attackable, "boolean") == true then
        -- Promote: tear down the friendly representation, keep/re-assert
        -- suppression inside BuildEnemyPlate — no Blizzard UF flash.
        NPFriendly.HandleRemoved(unit)
        if NP.Driver and NP.Driver.BuildEnemyPlate then
            NP.Driver.BuildEnemyPlate(unit)
        end
    end
end

local function AttachWatcher(unit)
    if watchers[unit] then return end
    local watcher = table.remove(watcherPool)
    if not watcher then
        watcher = CreateFrame("Frame")
        watcher:SetScript("OnEvent", WatcherOnEvent)
    end
    watcher.npUnit = unit
    watcher:RegisterUnitEvent("UNIT_FLAGS", unit)
    watcher:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)
    watchers[unit] = watcher
end

local function DetachWatcher(unit)
    local watcher = watchers[unit]
    if not watcher then return end
    watchers[unit] = nil
    watcher:UnregisterAllEvents()
    watcher.npUnit = nil
    watcherPool[#watcherPool + 1] = watcher
end

---------------------------------------------------------------------------
-- BARS MODE: the thinner pool (health + name + marker + target glow only)
---------------------------------------------------------------------------
local barPool = {}
local barGen = 0   -- friendly appearance generation (independent of enemy gen)

local function FriendlyPlateOnEvent(plate, event, unit)
    if event == "UNIT_NAME_UPDATE" then
        NPFriendly.UpdateName(plate)
        return
    end
    -- UNIT_HEALTH / UNIT_MAXHEALTH
    NPFriendly.UpdateHealth(plate)
end

local function BuildFriendlyPlate()
    local plate = CreateFrame("Frame", nil, UIParent)
    plate:Hide()
    plate:SetSize(1, 1)
    -- Scale-decoupled like the enemy pool (see driver.PinPlateScale): base
    -- scale drift must never resize the art.
    if plate.SetIgnoreParentScale then
        plate:SetIgnoreParentScale(true)
    end
    plate:SetScript("OnEvent", FriendlyPlateOnEvent)
    plate.npFriendly = true

    local healthBar = CreateFrame("StatusBar", nil, plate)
    healthBar:SetPoint("CENTER", plate, "CENTER", 0, 0)
    healthBar:SetStatusBarTexture(WHITE8X8)
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(0)
    healthBar:EnableMouse(false)
    plate.healthBar = healthBar
    plate.healthBg = UIKit.CreateBackground(healthBar, 0.12, 0.12, 0.12, 1)
    UIKit.CreateBorderLines(healthBar)

    plate.nameText = UIKit.CreateText(plate, 12, nil, "OUTLINE", "OVERLAY")
    plate.nameText:SetPoint("BOTTOM", healthBar, "TOP", 0, 3)

    local marker = plate:CreateTexture(nil, "OVERLAY")
    marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    marker:Hide()
    plate.npRaidMarker = marker

    local glow = plate:CreateTexture(nil, "BACKGROUND", nil, -7)
    glow:SetTexture(WHITE8X8)
    glow:SetBlendMode("ADD")
    glow:Hide()
    plate.npTargetGlow = glow

    return plate
end

local function ApplyFriendlyAppearance(plate, settings)
    if NP.Driver and NP.Driver.PinPlateScale then
        NP.Driver.PinPlateScale(plate)
    end
    local friendly = settings.friendly or {}
    local highlight = settings.highlight or {}
    local w = friendly.barWidth or 150
    local h = friendly.barHeight or 12
    QUICore:SetPixelPerfectSize(plate.healthBar, w, h)
    local health = settings.health or {}
    UIKit.UpdateBorderLines(plate.healthBar, health.borderSize or 1, 0, 0, 0, 1, (health.borderSize or 1) <= 0)

    QUICore:ApplyFont(plate.nameText, nil, friendly.nameSize or 12, UIKit.ResolveFontPath(), "OUTLINE")

    QUICore:SetPixelPerfectSize(plate.npRaidMarker, 20, 20)
    plate.npRaidMarker:ClearAllPoints()
    plate.npRaidMarker:SetPoint("BOTTOMLEFT", plate.healthBar, "TOPRIGHT", 2, 2)

    local gc = highlight.targetGlowColor or { 0.412, 0.667, 1.0 }
    plate.npTargetGlow:SetVertexColor(gc[1], gc[2], gc[3], highlight.targetGlowAlpha or 1)
    plate.npTargetGlow:ClearAllPoints()
    plate.npTargetGlow:SetPoint("TOPLEFT", plate.healthBar, "TOPLEFT", -4, 4)
    plate.npTargetGlow:SetPoint("BOTTOMRIGHT", plate.healthBar, "BOTTOMRIGHT", 4, -4)
end

function NPFriendly.UpdateHealth(plate)
    local unit = plate.unit
    if not unit then return end
    local IsSecretValue = Helpers.IsSecretValue
    local maxHP = UnitHealthMax(unit)
    local hp = UnitHealth(unit)
    if type(maxHP) == "nil" then maxHP = 1 end
    if IsSecretValue(maxHP) or maxHP ~= plate.npLastMaxHP then
        if not IsSecretValue(maxHP) then plate.npLastMaxHP = maxHP end
        plate.healthBar:SetMinMaxValues(0, maxHP)
    end
    if type(hp) ~= "nil" then
        plate.healthBar:SetValue(hp)
    end
end

function NPFriendly.UpdateName(plate)
    local unit = plate.unit
    if not unit or not UnitExists(unit) then return end
    local ok = pcall(function()
        plate.nameText:SetText(Helpers.TruncateUTF8(UnitName(unit), 28))
    end)
    if not ok then plate.nameText:SetText("") end
end

-- Class color for players, friendly green otherwise — plain values only.
local function ApplyFriendlyColor(plate, settings)
    local friendly = settings.friendly or {}
    local colors = settings.colors or {}
    if friendly.classColorNames ~= false and plate.npIsPlayer == true and plate.npClassToken then
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[plate.npClassToken]
        if c then
            plate.healthBar:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1)
            plate.nameText:SetTextColor(c.r or 1, c.g or 1, c.b or 1)
            return
        end
    end
    local fc = colors.friendly or { 0.314, 0.800, 0.408 }
    plate.healthBar:SetStatusBarColor(fc[1], fc[2], fc[3])
    plate.nameText:SetTextColor(1, 1, 1)
end

local function AcquireFriendlyPlate(base, unit)
    local plate = table.remove(barPool) or BuildFriendlyPlate()
    plate.unit = unit
    plate.npBase = base
    friendlyPlates[unit] = plate
    NP.platesByBase[base] = plate

    plate:SetParent(base)
    plate:ClearAllPoints()
    plate:SetPoint("CENTER", base, "CENTER", 0, 0)
    plate:SetFrameLevel((base:GetFrameLevel() or 0) + 1)

    local settings = NP.GetSettings()
    if plate.npAppearanceGen ~= barGen then
        plate.npAppearanceGen = barGen
        ApplyFriendlyAppearance(plate, settings)
    end

    -- Plain unit state for coloring (NP.Plain — type() can't detect secrets).
    local ok, v = pcall(UnitIsPlayer, unit)
    plate.npIsPlayer = (ok and NP.Plain(v, "boolean")) or false
    local okClass, _, classToken = pcall(UnitClass, unit)
    plate.npClassToken = okClass and NP.Plain(classToken, "string") or nil

    plate:RegisterUnitEvent("UNIT_HEALTH", unit)
    plate:RegisterUnitEvent("UNIT_MAXHEALTH", unit)
    plate:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)

    NPFriendly.UpdateHealth(plate)
    NPFriendly.UpdateName(plate)
    ApplyFriendlyColor(plate, settings)
    if NP.Extras.UpdateRaidMarker then
        plate.npRaidMarkerEnabled = (settings.raidMarker or {}).enabled ~= false
        NP.Extras.UpdateRaidMarker(plate)
    end
    plate:Show()
    return plate
end

local function ReleaseFriendlyPlate(plate)
    local unit = plate.unit
    plate:UnregisterAllEvents()
    if unit and friendlyPlates[unit] == plate then
        friendlyPlates[unit] = nil
    end
    if plate.npBase and NP.platesByBase[plate.npBase] == plate then
        NP.platesByBase[plate.npBase] = nil
    end
    plate.unit = nil
    plate.npBase = nil
    plate.npLastMaxHP = nil
    plate.npIsPlayer = nil
    plate.npClassToken = nil
    plate.npRaidMarker:Hide()
    plate.npTargetGlow:Hide()
    plate:Hide()
    plate:ClearAllPoints()
    plate:SetParent(UIParent)
    barPool[#barPool + 1] = plate
end

---------------------------------------------------------------------------
-- ROUTING (called by the driver)
---------------------------------------------------------------------------
-- The driver suppressed the Blizzard art unconditionally on ADDED. Decide
-- what a settled non-attackable unit gets.
function NPFriendly.HandleAdded(base, unit)
    if not NP.IsEnabled() then
        if NP.Driver and NP.Driver.RestoreBlizzardArt then
            NP.Driver.RestoreBlizzardArt(base)
        end
        return
    end

    AttachWatcher(unit)

    local mode = EffectiveMode()
    if mode == "bars" then
        -- Keep the Blizzard art suppressed; our thin plate replaces it.
        local existing = friendlyPlates[unit]
        if existing then
            ReleaseFriendlyPlate(existing)
        end
        AcquireFriendlyPlate(base, unit)
        return
    end

    -- nameonly / off: give Blizzard its art back (name-only CVars shape it).
    if NP.Driver and NP.Driver.RestoreBlizzardArt then
        NP.Driver.RestoreBlizzardArt(base)
    end
end

function NPFriendly.HandleRemoved(unit)
    DetachWatcher(unit)
    local plate = friendlyPlates[unit]
    if plate then
        ReleaseFriendlyPlate(plate)
    end
end

---------------------------------------------------------------------------
-- CVAR GROUP (mode-shaped; routed through the combat-deferred owner)
---------------------------------------------------------------------------
local function ApplyModeCVars()
    if not NP.IsEnabled() then return end
    local NPCVars = ns.QUI_NameplatesCVars
    if not NPCVars then return end
    local s = NP.GetSettings()
    local friendly = s.friendly or {}
    local mode = EffectiveMode()
    if mode == "off" then return end  -- relinquished

    NPCVars.Set("nameplateShowOnlyNameForFriendlyPlayerUnits", mode == "nameonly" and 1 or 0)
    NPCVars.Set("nameplateUseClassColorForFriendlyPlayerUnitNames", friendly.classColorNames ~= false and 1 or 0)
    if NP.Extras.GetContext().inInstance == true then
        -- Protected in real instances — don't fight the API.
        NPCVars.Set("nameplateShowFriendlyNpcs", 0)
    end
    NPCVars.ApplyFriendlyVisibility()
end
NPFriendly.ApplyModeCVars = ApplyModeCVars

---------------------------------------------------------------------------
-- MODE / ZONE RE-EVALUATION (staggered delayed sweeps)
---------------------------------------------------------------------------
-- Blizzard creates plates asynchronously after visibility CVar flips; the
-- sweeps re-route any base the ADDED/REMOVED events didn't cover.
local function SweepUnmanagedPlates()
    if not NP.IsEnabled() then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local ok, list = pcall(C_NamePlate.GetNamePlates)
    if not ok or type(list) ~= "table" then return end
    for i = 1, #list do
        local base = list[i]
        local token = NP.Plain(base and (base.unitToken or base.namePlateUnitToken), "string")
        if token and not NP.platesByBase[base] then
            local okSelf, isSelf = pcall(UnitIsUnit, token, "player")
            if not (okSelf and NP.Plain(isSelf, "boolean") == true) then
                if NP.Driver and NP.Driver.RouteUnit then
                    NP.Driver.RouteUnit(token)
                end
            end
        end
    end
end

function NPFriendly.Reevaluate()
    if not NP.IsEnabled() then return end
    ApplyModeCVars()
    -- Bars-mode plates whose effective mode changed get re-routed in place.
    local mode = EffectiveMode()
    if mode ~= "bars" then
        for unit, plate in pairs(friendlyPlates) do
            local base = plate.npBase
            ReleaseFriendlyPlate(plate)
            if base and NP.Driver and NP.Driver.RestoreBlizzardArt then
                NP.Driver.RestoreBlizzardArt(base)
            end
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.6, SweepUnmanagedPlates)
        C_Timer.After(1.6, SweepUnmanagedPlates)
    end
end

---------------------------------------------------------------------------
-- EVENTS
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:SetScript("OnEvent", function()
    NPFriendly.Reevaluate()
end)
