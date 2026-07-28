--[[
    QUI Nameplates — health/absorb bars + health/name text.

    Hot-path discipline: everything static (sizes, fonts, anchors, textures,
    cached format strings) is applied in ApplyAppearance under the appearance
    generation counter; the UNIT_HEALTH tick is SetMinMaxValues/SetValue/
    SetFormattedText only.

    Secret rules (see shared.lua header): values flow raw into StatusBars;
    percent comes from UnitHealthPercent under pcall and lands in
    SetFormattedText("%.0f%%") — %d would silently no-op on secrets.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local Helpers = ns.Helpers
local UIKit = ns.UIKit
local QUICore = ns.Addon
local LSM = ns.LSM
local IsSecretValue = Helpers.IsSecretValue

local type = type
local pcall = pcall
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
local UnitHealthPercent = UnitHealthPercent
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitName = UnitName

local NPHealth = {}
NP.Health = NPHealth

local WHITE8X8 = "Interface\\Buttons\\WHITE8x8"

local function GetBarTexture(name)
    if LSM and name then
        local ok, path = pcall(LSM.Fetch, LSM, "statusbar", name, true)
        if ok and path then return path end
    end
    return WHITE8X8
end

---------------------------------------------------------------------------
-- PERCENT (never computed in Lua)
---------------------------------------------------------------------------
-- Returns the (possibly secret) 0..100 percent, or nil when unavailable.
-- Secret at full HP is NORMAL — never nil-compare the result.
local function GetHealthPct(unit)
    if type(UnitHealthPercent) == "function" then
        if CurveConstants and CurveConstants.ScaleTo100 then
            local ok, pct = pcall(UnitHealthPercent, unit, true, CurveConstants.ScaleTo100)
            if ok then return pct end
        end
        local ok, pct = pcall(UnitHealthPercent, unit, true)
        if ok then return pct end
    end
    return nil
end

---------------------------------------------------------------------------
-- BUILD (once per pooled frame)
---------------------------------------------------------------------------
function NPHealth.Build(plate)
    -- Health bar
    local healthBar = CreateFrame("StatusBar", nil, plate)
    healthBar:SetPoint("CENTER", plate, "CENTER", 0, 0)
    healthBar:SetStatusBarTexture(WHITE8X8)
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(0)
    healthBar:EnableMouse(false)
    plate.healthBar = healthBar

    plate.healthBg = UIKit.CreateBackground(healthBar, 0.12, 0.12, 0.12, 1)
    UIKit.CreateBorderLines(healthBar)

    -- Absorb bar: engine-proportioned single forward bar. Anchored to the
    -- health FILL TEXTURE's empty-side edge with the same value domain as
    -- the health bar, so the C engine renders the correct proportional width
    -- for clean AND secret values alike — no Lua split math.
    local absorbBar = CreateFrame("StatusBar", nil, healthBar)
    absorbBar:SetStatusBarTexture(WHITE8X8)
    absorbBar:SetFrameLevel(healthBar:GetFrameLevel() + 1)
    absorbBar:EnableMouse(false)
    absorbBar:Hide()
    plate.absorbBar = absorbBar

    -- GPU mask clips the absorb fill to the health bar bounds (no clip-frames).
    local mask = healthBar:CreateMaskTexture()
    mask:SetTexture(WHITE8X8, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(healthBar)
    plate.absorbMask = mask
    local absorbTex = absorbBar:GetStatusBarTexture()
    if absorbTex and absorbTex.AddMaskTexture then
        pcall(absorbTex.AddMaskTexture, absorbTex, mask)
    end

    -- Name + health text live on a dedicated carrier frame leveled above
    -- the bar frames: regions render below any sibling FRAME regardless of
    -- draw layer, so text placed over the bar (configurable anchors) would
    -- otherwise hide behind the health/absorb fills.
    local textCarrier = CreateFrame("Frame", nil, plate)
    textCarrier:SetAllPoints(plate)
    textCarrier:SetFrameLevel(healthBar:GetFrameLevel() + 10)
    plate.npTextCarrier = textCarrier

    plate.nameText = UIKit.CreateText(textCarrier, 11, nil, "OUTLINE", "OVERLAY")
    plate.nameText:SetPoint("BOTTOM", healthBar, "TOP", 0, 4)
    plate.healthText = UIKit.CreateText(textCarrier, 10, nil, "OUTLINE", "OVERLAY")
    plate.healthText:SetPoint("RIGHT", healthBar, "RIGHT", -2, 0)
end

---------------------------------------------------------------------------
-- APPEARANCE (generation-gated static styling)
---------------------------------------------------------------------------
function NPHealth.ApplyAppearance(plate, settings)
    local health = settings.health or {}
    local nameS = settings.name or {}
    local textS = settings.healthText or {}
    local absorbS = settings.absorbs or {}

    local healthBar = plate.healthBar
    QUICore:SetPixelPerfectSize(healthBar, health.width or 210, health.height or 24)
    healthBar:SetStatusBarTexture(GetBarTexture(health.texture))
    local fillTex = healthBar:GetStatusBarTexture()
    if fillTex then
        fillTex:SetHorizTile(false)
        fillTex:SetVertTile(false)
    end

    local bg = health.bgColor or { 0.12, 0.12, 0.12 }
    plate.healthBg:SetVertexColor(bg[1], bg[2], bg[3], health.bgAlpha or 1)

    UIKit.UpdateBorderLines(healthBar, health.borderSize or 1, 0, 0, 0, 1, (health.borderSize or 1) <= 0)

    -- Absorb bar: full health-bar width, anchored to the fill edge.
    local absorbBar = plate.absorbBar
    absorbBar:ClearAllPoints()
    if fillTex then
        absorbBar:SetPoint("TOPLEFT", fillTex, "TOPRIGHT", 0, 0)
        absorbBar:SetPoint("BOTTOMLEFT", fillTex, "BOTTOMRIGHT", 0, 0)
    else
        absorbBar:SetPoint("TOPLEFT", healthBar, "TOPLEFT", 0, 0)
        absorbBar:SetPoint("BOTTOMLEFT", healthBar, "BOTTOMLEFT", 0, 0)
    end
    absorbBar:SetWidth(QUICore:Pixels(health.width or 210, plate))
    absorbBar:SetStatusBarTexture(GetBarTexture(health.texture))
    local ac = absorbS.color or { 1, 1, 1 }
    absorbBar:SetStatusBarColor(ac[1], ac[2], ac[3], absorbS.opacity or 0.3)
    plate.npAbsorbsEnabled = absorbS.enabled ~= false

    -- Fonts + configurable text placement (point → health bar point with
    -- pixel-snapped offsets; justify is independent of the anchor).
    local fontPath = UIKit.ResolveFontPath()

    QUICore:ApplyFont(plate.nameText, nil, nameS.size or 11, fontPath, "OUTLINE")
    plate.nameText:ClearAllPoints()
    plate.nameText:SetPoint(
        nameS.point or "BOTTOM",
        healthBar,
        nameS.relativePoint or "TOP",
        QUICore:Pixels(nameS.offsetX or 0, plate),
        QUICore:Pixels(nameS.offsetY or 4, plate))
    plate.nameText:SetJustifyH(nameS.justify or "CENTER")
    if nameS.enabled == false then plate.nameText:Hide() else plate.nameText:Show() end

    QUICore:ApplyFont(plate.healthText, nil, textS.size or 10, fontPath, "OUTLINE")
    plate.healthText:ClearAllPoints()
    plate.healthText:SetPoint(
        textS.point or "RIGHT",
        healthBar,
        textS.relativePoint or "RIGHT",
        QUICore:Pixels(textS.offsetX or -2, plate),
        QUICore:Pixels(textS.offsetY or 0, plate))
    plate.healthText:SetJustifyH(textS.justify or "RIGHT")

    -- Precompute hot-path format strings (style time, not tick time).
    local style = textS.style or "percent"
    if textS.enabled == false then style = "none" end
    plate.npHealthTextStyle = style
    plate.npPctFmt = (textS.hidePercentSymbol == true) and "%.0f" or "%.0f%%"
    plate.npBothFmt = "%s | " .. plate.npPctFmt
end

---------------------------------------------------------------------------
-- HOT PATH: health tick
---------------------------------------------------------------------------
function NPHealth.UpdateHealth(plate)
    local unit = plate.unit
    if not unit then return end
    local healthBar = plate.healthBar

    -- Values flow raw into the StatusBar (C-side handles secrets). Max is
    -- dirty-checked with the secret-aware latch: secret ⇒ always write,
    -- never cache.
    local maxHP = UnitHealthMax(unit)
    local hp = UnitHealth(unit)
    if type(maxHP) == "nil" then maxHP = 1 end
    if IsSecretValue(maxHP) or maxHP ~= plate.npLastMaxHP then
        if not IsSecretValue(maxHP) then plate.npLastMaxHP = maxHP end
        healthBar:SetMinMaxValues(0, maxHP)
    end
    if type(hp) ~= "nil" then
        healthBar:SetValue(hp)
    end

    -- Health text
    local style = plate.npHealthTextStyle
    if style == "none" then
        return
    end
    local healthText = plate.healthText

    -- Death check: UnitIsDeadOrGhost gives a plain boolean out of combat and
    -- for most plate units; only a verifiably plain true short-circuits
    -- (NP.Plain — a secret boolean would error on the comparison).
    local okDead, dead = pcall(UnitIsDeadOrGhost, unit)
    if okDead and NP.Plain(dead, "boolean") == true then
        healthText:SetText("0%")
        return
    end

    local ok
    if style == "absolute" then
        local abbr = AbbreviateNumbers or AbbreviateLargeNumbers
        if abbr then
            ok = pcall(healthText.SetText, healthText, abbr(hp))
        else
            ok = pcall(healthText.SetFormattedText, healthText, "%s", hp)
        end
    elseif style == "both" then
        local pct = GetHealthPct(unit)
        local abbr = AbbreviateNumbers or AbbreviateLargeNumbers
        if abbr then
            ok = pcall(healthText.SetFormattedText, healthText, plate.npBothFmt, abbr(hp), pct)
        else
            ok = pcall(healthText.SetFormattedText, healthText, plate.npBothFmt, hp, pct)
        end
    else -- percent
        local pct = GetHealthPct(unit)
        ok = pcall(healthText.SetFormattedText, healthText, plate.npPctFmt, pct)
    end
    if not ok then
        healthText:SetText("")
    end
end

---------------------------------------------------------------------------
-- HOT PATH: absorbs
---------------------------------------------------------------------------
function NPHealth.UpdateAbsorbs(plate)
    local unit = plate.unit
    if not unit or not plate.npAbsorbsEnabled then return end
    local absorbBar = plate.absorbBar

    local amount = UnitGetTotalAbsorbs(unit)
    if type(amount) == "nil" then
        if not plate.npAbsorbHidden then
            plate.npAbsorbHidden = true
            absorbBar:Hide()
        end
        return
    end

    -- Zero-latch for the common no-shield case: only a verifiably clean zero
    -- hides the bar; secret amounts always render (the engine draws 0-width
    -- for a secret zero anyway — hiding is just the cheaper steady state).
    if not IsSecretValue(amount) and amount == 0 then -- @secret-safe: probe leads this compound; short-circuit keeps the compare off secrets
        if not plate.npAbsorbHidden then
            plate.npAbsorbHidden = true
            absorbBar:Hide()
        end
        return
    end

    if plate.npAbsorbHidden then
        plate.npAbsorbHidden = false
        absorbBar:Show()
    end

    -- Same value domain as the health bar: the engine proportions the fill.
    local maxHP = UnitHealthMax(unit)
    if type(maxHP) == "nil" then maxHP = 1 end
    if IsSecretValue(maxHP) or maxHP ~= plate.npLastAbsorbMax then
        if not IsSecretValue(maxHP) then plate.npLastAbsorbMax = maxHP end
        absorbBar:SetMinMaxValues(0, maxHP)
    end
    absorbBar:SetValue(amount)
end

---------------------------------------------------------------------------
-- NAME
---------------------------------------------------------------------------
function NPHealth.UpdateName(plate)
    local unit = plate.unit
    if not unit then return end
    local nameText = plate.nameText

    -- Keep-last-good: a transiently missing unit keeps the previous name
    -- instead of flashing blank.
    if not UnitExists(unit) then return end

    local name = UnitName(unit)
    -- TruncateUTF8 is secret-safe; result goes straight into SetText.
    local ok = pcall(function()
        nameText:SetText(Helpers.TruncateUTF8(name, 28))
    end)
    if not ok then
        nameText:SetText("")
    end

    -- Class-colored names for players (plain values from driver state).
    local settings = NP.GetSettings()
    local nameS = settings.name or {}
    if nameS.classColorPlayers ~= false and plate.npIsPlayer == true and plate.npClassToken then
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[plate.npClassToken]
        if c then
            nameText:SetTextColor(c.r or 1, c.g or 1, c.b or 1)
            return
        end
    end
    nameText:SetTextColor(1, 1, 1)
end

---------------------------------------------------------------------------
-- COLOR (skip-if-unchanged latch; resolver guarantees plain values)
---------------------------------------------------------------------------
function NPHealth.UpdateColor(plate, settings, context)
    local r, g, b = NP.Colors.Resolve(plate, settings, context)
    if r ~= plate.npLastR or g ~= plate.npLastG or b ~= plate.npLastB then
        plate.npLastR, plate.npLastG, plate.npLastB = r, g, b
        plate.healthBar:SetStatusBarColor(r, g, b)
    end
end
