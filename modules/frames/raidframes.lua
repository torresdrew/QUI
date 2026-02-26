--[[
    QUI Raid Frames
    Group-based grid layout for raid1-raid40 with full indicator support.
    Loads after unitframes.lua; reuses shared helpers from QUI_UF.
]]
local ADDON_NAME, ns = ...
local QUICore = ns.Addon
local LSM = LibStub("LibSharedMedia-3.0")
local Helpers = ns.Helpers
local IsSecretValue = Helpers.IsSecretValue
local SafeValue = Helpers.SafeValue
local GetDB = Helpers.CreateDBGetter("quiUnitFrames")

---------------------------------------------------------------------------
-- SHARED MODULE REFERENCE
---------------------------------------------------------------------------
local QUI_UF = ns.QUI_UnitFrames
if not QUI_UF then return end

-- Import exposed helpers from unitframes.lua
local GetUnitSettings      = QUI_UF._GetUnitSettings
local GetGeneralSettings   = QUI_UF._GetGeneralSettings
local GetFontPath          = QUI_UF._GetFontPath
local GetFontOutline       = QUI_UF._GetFontOutline
local UpdateFrame          = QUI_UF._UpdateFrame
local UpdateHealth         = QUI_UF._UpdateHealth
local UpdateAbsorbs        = QUI_UF._UpdateAbsorbs
local UpdateHealPrediction = QUI_UF._UpdateHealPrediction
local UpdatePower          = QUI_UF._UpdatePower
local UpdatePowerText      = QUI_UF._UpdatePowerText
local UpdateName           = QUI_UF._UpdateName
local UpdateTargetMarker   = QUI_UF._UpdateTargetMarker
local UpdateRoleIcon       = QUI_UF._UpdateRoleIcon
local UpdateReadyCheck     = QUI_UF._UpdateReadyCheck
local UpdateResurrectIcon  = QUI_UF._UpdateResurrectIcon
local UpdateSummonIcon     = QUI_UF._UpdateSummonIcon
local UpdateDebuffHighlight = QUI_UF._UpdateDebuffHighlight
local UpdateThreatIndicator = QUI_UF._UpdateThreatIndicator
local GetHealthBarColor    = QUI_UF._GetHealthBarColor
local GetTexturePath       = QUI_UF._GetTexturePath
local GetAbsorbTexturePath = QUI_UF._GetAbsorbTexturePath
local GetTextAnchorInfo    = QUI_UF._GetTextAnchorInfo
local TruncateName         = QUI_UF._TruncateName
local ShowUnitTooltip      = QUI_UF._ShowUnitTooltip
local HideUnitTooltip      = QUI_UF._HideUnitTooltip
local ROLE_ICON_TEXCOORDS  = QUI_UF._ROLE_ICON_TEXCOORDS
local Scale                = QUI_UF._Scale

-- Reference to castbar module
local QUI_Castbar = ns.QUI_Castbar

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_RF = {}
ns.QUI_RaidFrames = QUI_RF

-- Frame pool: frames indexed by "raid1".."raid40", created once, reused
QUI_RF.framePool = {}
-- Active frames: currently shown, keyed by "raid1".."raid40"
QUI_RF.activeFrames = {}
-- Preview mode state
QUI_RF.previewMode = false

-- Range fade ticker
local raidRangeTicker = nil
local RAID_RANGE_INTERVAL = 0.5

-- Layout throttle
local layoutPending = false
local layoutThrottleHandle = nil
local LAYOUT_THROTTLE = 0.2

-- Deferred work
QUI_RF.pendingInitialize = false
QUI_RF.pendingLayout = false

-- Role sort priority
local ROLE_SORT_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3, NONE = 4 }

---------------------------------------------------------------------------
-- COMPOSITE UPDATE
---------------------------------------------------------------------------
local function UpdateRaidFrame(frame)
    if not frame then return end
    UpdateFrame(frame)
    UpdateRoleIcon(frame)
    UpdateReadyCheck(frame)
    UpdateResurrectIcon(frame)
    UpdateSummonIcon(frame)
    UpdateDebuffHighlight(frame)
    UpdateThreatIndicator(frame)
end

---------------------------------------------------------------------------
-- CREATE: Raid Frame
---------------------------------------------------------------------------
local function CreateRaidFrame(unit, frameKey, raidIndex)
    local settings = GetUnitSettings("raid")
    local general = GetGeneralSettings()
    if not settings then return nil end

    local frameName = "QUI_Raid" .. raidIndex
    local frame = CreateFrame("Button", frameName, UIParent, "SecureUnitButtonTemplate, BackdropTemplate, PingableUnitFrameTemplate")

    frame.unit = unit           -- "raid1", "raid2", etc.
    frame.unitKey = "raid"      -- Shared settings key
    frame.raidIndex = raidIndex

    -- Size
    local width = (QUICore.PixelRound and QUICore:PixelRound(settings.width or 72, frame)) or (settings.width or 72)
    local height = (QUICore.PixelRound and QUICore:PixelRound(settings.height or 36, frame)) or (settings.height or 36)
    frame:SetSize(width, height)

    -- Initial position (will be overridden by layout engine)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)

    -- Secure unit attributes for click targeting
    frame:SetAttribute("unit", unit)
    frame:SetAttribute("*type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")

    -- Tooltip
    frame:HookScript("OnEnter", function(self)
        ShowUnitTooltip(self)
    end)
    frame:HookScript("OnLeave", HideUnitTooltip)

    -- Visibility state driver
    RegisterStateDriver(frame, "visibility", "[@" .. unit .. ",exists] show; hide")

    -- Refresh when raid member appears
    frame:HookScript("OnShow", function(self)
        if QUI_RF.previewMode then return end
        UpdateRaidFrame(self)
    end)

    -- Background
    local bgColor = { 0.1, 0.1, 0.1, 0.9 }
    if general and general.darkMode then
        bgColor = general.darkModeBgColor or { 0.25, 0.25, 0.25, 1 }
    end

    local borderPx = settings.borderSize or 1
    local borderSize = borderPx > 0 and QUICore:Pixels(borderPx, frame) or 0

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = borderSize > 0 and "Interface\\Buttons\\WHITE8x8" or nil,
        edgeSize = borderSize > 0 and borderSize or nil,
    })
    frame:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1)
    if borderSize > 0 then
        frame:SetBackdropBorderColor(0, 0, 0, 1)
    end

    -- Health bar
    local powerHeight = settings.showPowerBar and QUICore:PixelRound(settings.powerBarHeight or 2, frame) or 0
    local separatorHeight = (settings.showPowerBar and settings.powerBarBorder ~= false) and QUICore:GetPixelSize(frame) or 0
    local healthBar = CreateFrame("StatusBar", nil, frame)
    healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", borderSize, -borderSize)
    healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -borderSize, borderSize + powerHeight + separatorHeight)
    healthBar:SetStatusBarTexture(GetTexturePath(settings.texture))
    healthBar:SetMinMaxValues(0, 100)
    healthBar:SetValue(100)
    healthBar:EnableMouse(false)
    frame.healthBar = healthBar

    -- Absorb bar
    local absorbSettings = settings.absorbs or {}
    local absorbBar = CreateFrame("StatusBar", nil, healthBar)
    absorbBar:SetStatusBarTexture(GetAbsorbTexturePath(absorbSettings.texture))
    local absorbBarTex = absorbBar:GetStatusBarTexture()
    if absorbBarTex then
        absorbBarTex:SetHorizTile(false)
        absorbBarTex:SetVertTile(false)
        absorbBarTex:SetTexCoord(0, 1, 0, 1)
    end
    local ac = absorbSettings.color or { 1, 1, 1 }
    local aa = absorbSettings.opacity or 0.7
    absorbBar:SetStatusBarColor(ac[1], ac[2], ac[3], aa)
    absorbBar:SetFrameLevel(healthBar:GetFrameLevel() + 1)
    absorbBar:SetPoint("TOP", healthBar, "TOP", 0, 0)
    absorbBar:SetPoint("BOTTOM", healthBar, "BOTTOM", 0, 0)
    absorbBar:SetMinMaxValues(0, 1)
    absorbBar:SetValue(0)
    absorbBar:Hide()
    frame.absorbBar = absorbBar

    -- Heal absorb bar
    local healAbsorbBar = CreateFrame("StatusBar", nil, healthBar)
    healAbsorbBar:SetStatusBarTexture(GetTexturePath(settings.texture))
    healAbsorbBar:SetFrameLevel(healthBar:GetFrameLevel() + 2)
    healAbsorbBar:SetAllPoints(healthBar)
    healAbsorbBar:SetMinMaxValues(0, 1)
    healAbsorbBar:SetValue(0)
    healAbsorbBar:SetStatusBarColor(0.6, 0.1, 0.1, 0.8)
    healAbsorbBar:SetReverseFill(true)
    frame.healAbsorbBar = healAbsorbBar

    -- Heal prediction bar
    local hpSettings = settings.healPrediction or {}
    if hpSettings.enabled ~= false then
        local healPredictionBar = CreateFrame("StatusBar", nil, healthBar)
        healPredictionBar:SetStatusBarTexture(GetTexturePath(settings.texture))
        local hpc = hpSettings.color or { 0.2, 1, 0.2 }
        local hpa = hpSettings.opacity or 0.5
        healPredictionBar:SetStatusBarColor(hpc[1], hpc[2], hpc[3], hpa)
        healPredictionBar:SetFrameLevel(healthBar:GetFrameLevel() + 1)
        healPredictionBar:SetAllPoints(healthBar)
        healPredictionBar:SetMinMaxValues(0, 1)
        healPredictionBar:SetValue(0)
        healPredictionBar:Hide()
        frame.healPredictionBar = healPredictionBar
    end

    -- Initial health bar color
    if general and general.darkMode then
        local c = general.darkModeHealthColor or { 0.15, 0.15, 0.15, 1 }
        healthBar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 1)
    else
        local r, g, b, a = GetHealthBarColor(unit, settings)
        healthBar:SetStatusBarColor(r, g, b, a)
    end

    -- Power bar
    if settings.showPowerBar then
        local powerBar = CreateFrame("StatusBar", nil, frame)
        powerBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", borderSize, borderSize)
        powerBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -borderSize, borderSize)
        powerBar:SetHeight(powerHeight)
        powerBar:SetStatusBarTexture(GetTexturePath(settings.texture))
        local powerColor = settings.powerBarColor or { 0, 0.5, 1, 1 }
        powerBar:SetStatusBarColor(powerColor[1], powerColor[2], powerColor[3], powerColor[4] or 1)
        powerBar:SetMinMaxValues(0, 100)
        powerBar:SetValue(100)
        powerBar:EnableMouse(false)
        frame.powerBar = powerBar

        if settings.powerBarBorder ~= false then
            local separator = powerBar:CreateTexture(nil, "OVERLAY")
            separator:SetHeight(QUICore:GetPixelSize(powerBar))
            separator:SetPoint("BOTTOMLEFT", powerBar, "TOPLEFT", 0, 0)
            separator:SetPoint("BOTTOMRIGHT", powerBar, "TOPRIGHT", 0, 0)
            separator:SetTexture("Interface\\Buttons\\WHITE8x8")
            separator:SetVertexColor(0, 0, 0, 1)
            frame.powerBarSeparator = separator
        end
    end

    -- Name text
    if settings.showName then
        local nameAnchorInfo = GetTextAnchorInfo(settings.nameAnchor or "LEFT")
        local nameOffsetX = QUICore:PixelRound(settings.nameOffsetX or 2, healthBar)
        local nameOffsetY = QUICore:PixelRound(settings.nameOffsetY or 0, healthBar)
        local nameText = healthBar:CreateFontString(nil, "OVERLAY")
        nameText:SetFont(GetFontPath(), settings.nameFontSize or 10, GetFontOutline())
        nameText:SetShadowOffset(0, 0)
        nameText:SetPoint(nameAnchorInfo.point, healthBar, nameAnchorInfo.point, nameOffsetX, nameOffsetY)
        nameText:SetJustifyH(nameAnchorInfo.justify)
        nameText:SetText("Raid " .. raidIndex)
        frame.nameText = nameText
    end

    -- Health text
    if settings.showHealth then
        local healthAnchorInfo = GetTextAnchorInfo(settings.healthAnchor or "RIGHT")
        local healthOffsetX = QUICore:PixelRound(settings.healthOffsetX or -2, healthBar)
        local healthOffsetY = QUICore:PixelRound(settings.healthOffsetY or 0, healthBar)
        local healthText = healthBar:CreateFontString(nil, "OVERLAY")
        healthText:SetFont(GetFontPath(), settings.healthFontSize or 10, GetFontOutline())
        healthText:SetShadowOffset(0, 0)
        healthText:SetPoint(healthAnchorInfo.point, healthBar, healthAnchorInfo.point, healthOffsetX, healthOffsetY)
        healthText:SetJustifyH(healthAnchorInfo.justify)
        healthText:SetText("100%")
        frame.healthText = healthText
    end

    -- Power text
    local powerAnchorInfo = GetTextAnchorInfo(settings.powerTextAnchor or "BOTTOMRIGHT")
    local powerText = healthBar:CreateFontString(nil, "OVERLAY")
    powerText:SetFont(GetFontPath(), settings.powerTextFontSize or 9, GetFontOutline())
    powerText:SetShadowOffset(0, 0)
    local pOffX = QUICore:PixelRound(settings.powerTextOffsetX or -2, healthBar)
    local pOffY = QUICore:PixelRound(settings.powerTextOffsetY or 1, healthBar)
    powerText:SetPoint(powerAnchorInfo.point, healthBar, powerAnchorInfo.point, pOffX, pOffY)
    powerText:SetJustifyH(powerAnchorInfo.justify)
    powerText:Hide()
    frame.powerText = powerText

    -- Target marker (raid icons)
    if settings.targetMarker then
        local indicatorFrame = CreateFrame("Frame", nil, frame)
        indicatorFrame:SetAllPoints()
        indicatorFrame:SetFrameLevel(healthBar:GetFrameLevel() + 5)
        frame.indicatorFrame = indicatorFrame

        local marker = settings.targetMarker
        local targetMarker = indicatorFrame:CreateTexture(nil, "OVERLAY")
        targetMarker:SetTexture([[Interface\TargetingFrame\UI-RaidTargetingIcons]])
        targetMarker:SetSize(marker.size or 14, marker.size or 14)
        local anchorInfo = GetTextAnchorInfo(marker.anchor or "TOP")
        targetMarker:SetPoint(anchorInfo.point, frame, anchorInfo.point, marker.xOffset or 0, marker.yOffset or 6)
        targetMarker:Hide()
        frame.targetMarker = targetMarker
    end

    -- ===== Raid indicators (same set as party) =====
    local indicatorLevel = healthBar:GetFrameLevel() + 6

    -- Role icon (tank/healer/dps)
    local roleSettings = settings.roleIcon or {}
    local roleIcon = frame:CreateTexture(nil, "OVERLAY")
    roleIcon:SetTexture([[Interface\LFGFrame\UI-LFG-ICON-PORTRAITROLES]])
    roleIcon:SetSize(roleSettings.size or 12, roleSettings.size or 12)
    local roleAnchorInfo = GetTextAnchorInfo(roleSettings.anchor or "TOPLEFT")
    roleIcon:SetPoint(roleAnchorInfo.point, frame, roleAnchorInfo.point, roleSettings.xOffset or 1, roleSettings.yOffset or -1)
    roleIcon:SetDrawLayer("OVERLAY", 7)
    roleIcon:Hide()
    frame.roleIcon = roleIcon

    -- Ready check icon
    local rcSettings = settings.readyCheck or {}
    local readyCheckIcon = frame:CreateTexture(nil, "OVERLAY")
    readyCheckIcon:SetSize(rcSettings.size or 18, rcSettings.size or 18)
    readyCheckIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    readyCheckIcon:SetDrawLayer("OVERLAY", 7)
    readyCheckIcon:Hide()
    frame.readyCheckIcon = readyCheckIcon

    -- Resurrect icon
    local rezSettings = settings.resurrectIcon or {}
    local resurrectIcon = frame:CreateTexture(nil, "OVERLAY")
    resurrectIcon:SetTexture([[Interface\RaidFrame\Raid-Icon-Rez]])
    resurrectIcon:SetSize(rezSettings.size or 18, rezSettings.size or 18)
    resurrectIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    resurrectIcon:SetDrawLayer("OVERLAY", 7)
    resurrectIcon:Hide()
    frame.resurrectIcon = resurrectIcon

    -- Summon icon
    local sumSettings = settings.summonIcon or {}
    local summonIcon = frame:CreateTexture(nil, "OVERLAY")
    summonIcon:SetTexture([[Interface\RaidFrame\Raid-Icon-SummonPending]])
    summonIcon:SetSize(sumSettings.size or 18, sumSettings.size or 18)
    summonIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    summonIcon:SetDrawLayer("OVERLAY", 7)
    summonIcon:Hide()
    frame.summonIcon = summonIcon

    -- Debuff highlight border
    local debuffHighlight = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    debuffHighlight:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
    debuffHighlight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
    debuffHighlight:SetFrameLevel(indicatorLevel)
    debuffHighlight:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = QUICore:Pixels(2, debuffHighlight),
    })
    debuffHighlight:SetBackdropBorderColor(0, 0, 0, 0)
    debuffHighlight:Hide()
    frame.debuffHighlight = debuffHighlight

    -- Threat border
    local threatBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    threatBorder:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
    threatBorder:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
    threatBorder:SetFrameLevel(indicatorLevel - 1)
    threatBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = QUICore:Pixels(1, threatBorder),
    })
    threatBorder:SetBackdropBorderColor(0, 0, 0, 0)
    threatBorder:Hide()
    frame.threatBorder = threatBorder

    -- ===== Event registration =====
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateHealth(self)
                UpdateAbsorbs(self)
                UpdateHealPrediction(self)
            end
        elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" or event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateAbsorbs(self)
            end
        elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdatePower(self)
                UpdatePowerText(self)
            end
        elseif event == "UNIT_NAME_UPDATE" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateName(self)
                UpdateRoleIcon(self)
            end
        elseif event == "RAID_TARGET_UPDATE" then
            UpdateTargetMarker(self)
        elseif event == "UNIT_THREAT_SITUATION_UPDATE" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateThreatIndicator(self)
            end
        elseif event == "UNIT_AURA" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateDebuffHighlight(self)
            end
        elseif event == "READY_CHECK" or event == "READY_CHECK_CONFIRM" then
            UpdateReadyCheck(self)
        elseif event == "READY_CHECK_FINISHED" then
            C_Timer.After(6, function()
                if self.readyCheckIcon then
                    self.readyCheckIcon:Hide()
                end
            end)
        elseif event == "INCOMING_RESURRECT_CHANGED" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateResurrectIcon(self)
            end
        elseif event == "INCOMING_SUMMON_CHANGED" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateSummonIcon(self)
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            UpdateRaidFrame(self)
        elseif event == "UNIT_HEAL_PREDICTION" then
            local eventUnit = ...
            if eventUnit == self.unit then
                UpdateHealPrediction(self)
            end
        end
    end)

    -- Unit-specific events
    frame:RegisterUnitEvent("UNIT_HEALTH", unit)
    frame:RegisterUnitEvent("UNIT_MAXHEALTH", unit)
    frame:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", unit)
    frame:RegisterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED", unit)
    frame:RegisterUnitEvent("UNIT_POWER_UPDATE", unit)
    frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", unit)
    frame:RegisterUnitEvent("UNIT_MAXPOWER", unit)
    frame:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)
    frame:RegisterUnitEvent("UNIT_THREAT_SITUATION_UPDATE", unit)
    frame:RegisterUnitEvent("UNIT_AURA", unit)
    frame:RegisterUnitEvent("UNIT_HEAL_PREDICTION", unit)
    frame:RegisterUnitEvent("INCOMING_RESURRECT_CHANGED", unit)
    frame:RegisterUnitEvent("INCOMING_SUMMON_CHANGED", unit)
    -- Global events
    frame:RegisterEvent("RAID_TARGET_UPDATE")
    frame:RegisterEvent("READY_CHECK")
    frame:RegisterEvent("READY_CHECK_CONFIRM")
    frame:RegisterEvent("READY_CHECK_FINISHED")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")

    -- Register with Clique if available
    if _G.ClickCastFrames then
        _G.ClickCastFrames[frame] = true
    end

    return frame
end

---------------------------------------------------------------------------
-- FRAME POOL
---------------------------------------------------------------------------
local function GetOrCreateFrame(raidIndex)
    local key = "raid" .. raidIndex
    if QUI_RF.framePool[key] then
        return QUI_RF.framePool[key]
    end
    if InCombatLockdown() then return nil end
    local frame = CreateRaidFrame(key, key, raidIndex)
    if frame then
        QUI_RF.framePool[key] = frame
        QUI_UF.frames[key] = frame
    end
    return frame
end

---------------------------------------------------------------------------
-- RANGE FADE TICKER
---------------------------------------------------------------------------
local function StartRaidRangeTicker()
    if raidRangeTicker then return end
    local RangeLib = LibStub("LibRangeCheck-3.0", true)
    if not RangeLib then return end

    raidRangeTicker = C_Timer.NewTicker(RAID_RANGE_INTERVAL, function()
        local settings = GetUnitSettings("raid")
        local rangeSettings = settings and settings.rangeFade
        if not rangeSettings or not rangeSettings.enabled then return end

        local inAlpha = rangeSettings.inRangeAlpha or 1.0
        local outAlpha = rangeSettings.outOfRangeAlpha or 0.4

        for key, frame in pairs(QUI_RF.activeFrames) do
            if frame and frame:IsShown() and UnitExists(frame.unit) then
                local ok, minRange = pcall(RangeLib.GetRange, RangeLib, frame.unit)
                if ok and minRange and minRange <= 40 then
                    frame:SetAlpha(inAlpha)
                else
                    frame:SetAlpha(outAlpha)
                end
            end
        end
    end)
end

local function StopRaidRangeTicker()
    if raidRangeTicker then
        raidRangeTicker:Cancel()
        raidRangeTicker = nil
    end
end

---------------------------------------------------------------------------
-- LAYOUT ENGINE: Group-based grid
---------------------------------------------------------------------------
function QUI_RF:LayoutRaidGrid()
    if InCombatLockdown() then
        self.pendingLayout = true
        return
    end

    local settings = GetUnitSettings("raid")
    if not settings or not settings.enabled then return end

    local layout = settings.layout or {}
    local groupGap = layout.groupGap or 8
    local memberSpacing = layout.memberSpacing or 2
    local groupGrowDir = layout.groupGrowDirection or "RIGHT"
    local memberGrowDir = layout.memberGrowDirection or "DOWN"
    local sortByRole = layout.sortByRole or false
    local visibleGroups = layout.visibleGroups or { true, true, true, true, true, true, true, true }
    local frameWidth = (QUICore.PixelRound and QUICore:PixelRound(settings.width or 72)) or (settings.width or 72)
    local frameHeight = (QUICore.PixelRound and QUICore:PixelRound(settings.height or 36)) or (settings.height or 36)
    local anchorX = settings.offsetX or -300
    local anchorY = settings.offsetY or 100

    -- 1. Build group membership from raid roster
    local groups = {}
    for g = 1, 8 do
        groups[g] = {}
    end

    local numMembers = GetNumGroupMembers()
    if numMembers > 0 and IsInRaid() then
        for i = 1, numMembers do
            local name, _, subgroup = GetRaidRosterInfo(i)
            if name and subgroup then
                local entry = {
                    raidIndex = i,
                    name = name,
                    role = UnitGroupRolesAssigned("raid" .. i) or "NONE",
                }
                table.insert(groups[subgroup], entry)
            end
        end
    end

    -- 2. Optional sort within each group by role
    if sortByRole then
        for g = 1, 8 do
            table.sort(groups[g], function(a, b)
                local orderA = ROLE_SORT_ORDER[a.role] or 4
                local orderB = ROLE_SORT_ORDER[b.role] or 4
                if orderA ~= orderB then return orderA < orderB end
                return a.raidIndex < b.raidIndex
            end)
        end
    end

    -- 3. Position frames in group-based grid
    wipe(self.activeFrames)
    local groupOffset = 0

    for groupNum = 1, 8 do
        if visibleGroups[groupNum] and #groups[groupNum] > 0 then
            local memberOffset = 0

            for _, memberInfo in ipairs(groups[groupNum]) do
                local frame = GetOrCreateFrame(memberInfo.raidIndex)
                if frame then
                    frame:ClearAllPoints()
                    frame:SetSize(frameWidth, frameHeight)

                    -- Calculate position
                    local x, y
                    if groupGrowDir == "LEFT" then
                        x = anchorX - groupOffset
                    else -- RIGHT (default)
                        x = anchorX + groupOffset
                    end

                    if memberGrowDir == "UP" then
                        y = anchorY + memberOffset
                    else -- DOWN (default)
                        y = anchorY - memberOffset
                    end

                    frame:SetPoint("TOPLEFT", UIParent, "CENTER", x, y)
                    self.activeFrames[frame.unit] = frame

                    memberOffset = memberOffset + frameHeight + memberSpacing
                end
            end

            groupOffset = groupOffset + frameWidth + groupGap
        end
    end

    -- 4. Hide frames for members no longer in active set
    for key, frame in pairs(self.framePool) do
        if not self.activeFrames[frame.unit] and not InCombatLockdown() then
            -- State driver handles visibility, but clear position
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", -10000, -10000)
        end
    end
end

---------------------------------------------------------------------------
-- REFRESH: Apply settings changes to all raid frames
---------------------------------------------------------------------------
function QUI_RF:RefreshRaidFrames()
    local settings = GetUnitSettings("raid")
    local general = GetGeneralSettings()
    if not settings then return end

    if InCombatLockdown() then
        for _, frame in pairs(self.activeFrames) do
            UpdateRaidFrame(frame)
        end
        return
    end

    local borderPx = settings.borderSize or 1
    local texturePath = GetTexturePath(settings.texture)

    for _, frame in pairs(self.framePool) do
        local borderSize = borderPx > 0 and QUICore:Pixels(borderPx, frame) or 0
        local powerHeight = settings.showPowerBar and QUICore:PixelRound(settings.powerBarHeight or 2, frame) or 0
        local separatorHeight = (settings.showPowerBar and settings.powerBarBorder ~= false) and QUICore:GetPixelSize(frame) or 0

        -- Colors and opacity
        local bgColor, healthOpacity, bgOpacity
        if general and general.darkMode then
            bgColor = general.darkModeBgColor or { 0.25, 0.25, 0.25, 1 }
            healthOpacity = general.darkModeHealthOpacity or general.darkModeOpacity or 1.0
            bgOpacity = general.darkModeBgOpacity or general.darkModeOpacity or 1.0
        else
            bgColor = general and general.defaultBgColor or { 0.1, 0.1, 0.1, 0.9 }
            healthOpacity = general and general.defaultHealthOpacity or general and general.defaultOpacity or 1.0
            bgOpacity = general and general.defaultBgOpacity or general and general.defaultOpacity or 1.0
        end
        local bgAlpha = (bgColor[4] or 1) * bgOpacity

        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = borderSize > 0 and "Interface\\Buttons\\WHITE8x8" or nil,
            edgeSize = borderSize > 0 and borderSize or nil,
        })
        frame:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgAlpha)
        if borderSize > 0 then
            frame:SetBackdropBorderColor(0, 0, 0, 1)
        end

        frame.healthBar:SetAlpha(healthOpacity)
        if frame.powerBar then frame.powerBar:SetAlpha(healthOpacity) end

        -- Health bar texture and position
        frame.healthBar:SetStatusBarTexture(texturePath)
        frame.healthBar:ClearAllPoints()
        frame.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", borderSize, -borderSize)
        frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -borderSize, borderSize + powerHeight + separatorHeight)

        -- Power bar
        if frame.powerBar then
            if settings.showPowerBar then
                frame.powerBar:SetStatusBarTexture(texturePath)
                frame.powerBar:ClearAllPoints()
                frame.powerBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", borderSize, borderSize)
                frame.powerBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -borderSize, borderSize)
                frame.powerBar:SetHeight(powerHeight)
                frame.powerBar:Show()
            else
                frame.powerBar:Hide()
            end
        end

        -- Power bar separator
        if frame.powerBarSeparator then
            if settings.showPowerBar and settings.powerBarBorder ~= false then
                frame.powerBarSeparator:Show()
            else
                frame.powerBarSeparator:Hide()
            end
        end

        -- Absorb bar texture
        local absorbSettings = settings.absorbs or {}
        if frame.absorbBar then
            frame.absorbBar:SetStatusBarTexture(GetAbsorbTexturePath(absorbSettings.texture))
            local ac2 = absorbSettings.color or { 1, 1, 1 }
            local aa2 = absorbSettings.opacity or 0.7
            frame.absorbBar:SetStatusBarColor(ac2[1], ac2[2], ac2[3], aa2)
        end

        -- Name text
        if settings.showName then
            if not frame.nameText then
                local nameText = frame.healthBar:CreateFontString(nil, "OVERLAY")
                nameText:SetShadowOffset(0, 0)
                frame.nameText = nameText
            end
            frame.nameText:SetFont(GetFontPath(), settings.nameFontSize or 10, GetFontOutline())
            local nameAnchorInfo = GetTextAnchorInfo(settings.nameAnchor or "LEFT")
            local nameOffsetX = QUICore:PixelRound(settings.nameOffsetX or 2, frame.healthBar)
            local nameOffsetY = QUICore:PixelRound(settings.nameOffsetY or 0, frame.healthBar)
            frame.nameText:ClearAllPoints()
            frame.nameText:SetPoint(nameAnchorInfo.point, frame.healthBar, nameAnchorInfo.point, nameOffsetX, nameOffsetY)
            frame.nameText:SetJustifyH(nameAnchorInfo.justify)
            frame.nameText:Show()
        elseif frame.nameText then
            frame.nameText:Hide()
        end

        -- Health text
        if settings.showHealth then
            if not frame.healthText then
                local healthText = frame.healthBar:CreateFontString(nil, "OVERLAY")
                healthText:SetShadowOffset(0, 0)
                frame.healthText = healthText
            end
            frame.healthText:SetFont(GetFontPath(), settings.healthFontSize or 10, GetFontOutline())
            local healthAnchorInfo = GetTextAnchorInfo(settings.healthAnchor or "RIGHT")
            local healthOffsetX = QUICore:PixelRound(settings.healthOffsetX or -2, frame.healthBar)
            local healthOffsetY = QUICore:PixelRound(settings.healthOffsetY or 0, frame.healthBar)
            frame.healthText:ClearAllPoints()
            frame.healthText:SetPoint(healthAnchorInfo.point, frame.healthBar, healthAnchorInfo.point, healthOffsetX, healthOffsetY)
            frame.healthText:SetJustifyH(healthAnchorInfo.justify)
            frame.healthText:Show()
        elseif frame.healthText then
            frame.healthText:Hide()
        end

        -- Power text
        if settings.showPowerText then
            if not frame.powerText then
                local powerTextNew = frame.healthBar:CreateFontString(nil, "OVERLAY")
                powerTextNew:SetShadowOffset(0, 0)
                frame.powerText = powerTextNew
            end
            frame.powerText:SetFont(GetFontPath(), settings.powerTextFontSize or 9, GetFontOutline())
            frame.powerText:ClearAllPoints()
            local powerAnchorInfo = GetTextAnchorInfo(settings.powerTextAnchor or "BOTTOMRIGHT")
            local powerOffsetX = QUICore:PixelRound(settings.powerTextOffsetX or -2, frame.healthBar)
            local powerOffsetY = QUICore:PixelRound(settings.powerTextOffsetY or 1, frame.healthBar)
            frame.powerText:SetPoint(powerAnchorInfo.point, frame.healthBar, powerAnchorInfo.point, powerOffsetX, powerOffsetY)
            frame.powerText:SetJustifyH(powerAnchorInfo.justify)
            frame.powerText:Show()
        elseif frame.powerText then
            frame.powerText:Hide()
        end

        -- Target marker
        if frame.targetMarker and settings.targetMarker then
            local marker = settings.targetMarker
            frame.targetMarker:SetSize(marker.size or 14, marker.size or 14)
            frame.targetMarker:ClearAllPoints()
            local anchorInfo = GetTextAnchorInfo(marker.anchor or "TOP")
            frame.targetMarker:SetPoint(anchorInfo.point, frame, anchorInfo.point, marker.xOffset or 0, marker.yOffset or 6)
            UpdateTargetMarker(frame)
        end

        -- Role icon refresh
        if frame.roleIcon then
            local roleSettings = settings.roleIcon or {}
            frame.roleIcon:SetSize(roleSettings.size or 12, roleSettings.size or 12)
            frame.roleIcon:ClearAllPoints()
            local roleAnchorInfo = GetTextAnchorInfo(roleSettings.anchor or "TOPLEFT")
            frame.roleIcon:SetPoint(roleAnchorInfo.point, frame, roleAnchorInfo.point, roleSettings.xOffset or 1, roleSettings.yOffset or -1)
        end

        -- Update with real data if not in preview mode
        if not self.previewMode then
            UpdateRaidFrame(frame)
        end

        -- Refresh raid castbar if it exists
        local raidKey = "raid" .. frame.raidIndex
        local castbar = QUI_UF.castbars[raidKey]
        if castbar and QUI_Castbar and QUI_Castbar.RefreshBossCastbar then
            local castSettings = settings.castbar
            if castSettings then
                QUI_Castbar:RefreshBossCastbar(castbar, raidKey, castSettings, frame)
            end
        end

        -- Restore edit overlay if in Edit Mode
        if QUI_UF.editModeActive then
            QUI_UF:RestoreEditOverlayIfNeeded(raidKey)
        end
    end

    -- Re-run layout for position/spacing changes
    self:LayoutRaidGrid()

    -- Manage range ticker
    if settings.rangeFade and settings.rangeFade.enabled then
        StartRaidRangeTicker()
    else
        StopRaidRangeTicker()
    end
end

---------------------------------------------------------------------------
-- PREVIEW MODE (for edit mode / options)
---------------------------------------------------------------------------
function QUI_RF:ShowPreview()
    if InCombatLockdown() then return end
    self.previewMode = true

    local settings = GetUnitSettings("raid")
    if not settings then return end

    local layout = settings.layout or {}
    local groupGap = layout.groupGap or 8
    local memberSpacing = layout.memberSpacing or 2
    local groupGrowDir = layout.groupGrowDirection or "RIGHT"
    local memberGrowDir = layout.memberGrowDirection or "DOWN"
    local frameWidth = (QUICore.PixelRound and QUICore:PixelRound(settings.width or 72)) or (settings.width or 72)
    local frameHeight = (QUICore.PixelRound and QUICore:PixelRound(settings.height or 36)) or (settings.height or 36)
    local anchorX = settings.offsetX or -300
    local anchorY = settings.offsetY or 100

    -- Create preview frames across 4 groups of 5
    local previewGroups = {
        { "Tank", "Healer", "DPS 1", "DPS 2", "DPS 3" },
        { "Tank", "Healer", "DPS 1", "DPS 2", "DPS 3" },
        { "Healer", "Healer", "DPS 1", "DPS 2", "DPS 3" },
        { "Healer", "DPS 1", "DPS 2", "DPS 3", "DPS 4" },
    }

    wipe(self.activeFrames)
    local frameIdx = 0
    local groupOffset = 0

    for g, group in ipairs(previewGroups) do
        local memberOffset = 0
        for _, memberName in ipairs(group) do
            frameIdx = frameIdx + 1
            local frame = GetOrCreateFrame(frameIdx)
            if frame then
                -- Unregister state driver during preview
                UnregisterStateDriver(frame, "visibility")
                frame:ClearAllPoints()
                frame:SetSize(frameWidth, frameHeight)
                frame:Show()

                local x, y
                if groupGrowDir == "LEFT" then
                    x = anchorX - groupOffset
                else
                    x = anchorX + groupOffset
                end
                if memberGrowDir == "UP" then
                    y = anchorY + memberOffset
                else
                    y = anchorY - memberOffset
                end

                frame:SetPoint("TOPLEFT", UIParent, "CENTER", x, y)
                self.activeFrames[frame.unit] = frame

                -- Set preview name
                if frame.nameText then
                    frame.nameText:SetText(memberName)
                end
                if frame.healthText then
                    frame.healthText:SetText("100%")
                end
                frame.healthBar:SetValue(70 + math.random(30))

                -- Set a preview color
                local classColors = {
                    { 0.78, 0.61, 0.43 },  -- Warrior-ish
                    { 0.96, 0.55, 0.73 },  -- Paladin-ish
                    { 0.67, 0.83, 0.45 },  -- Hunter-ish
                    { 1.0, 0.96, 0.41 },   -- Rogue-ish
                    { 0.0, 0.44, 0.87 },   -- Shaman-ish
                }
                local color = classColors[(frameIdx % #classColors) + 1]
                frame.healthBar:SetStatusBarColor(color[1], color[2], color[3], 1)

                memberOffset = memberOffset + frameHeight + memberSpacing
            end
        end
        groupOffset = groupOffset + frameWidth + groupGap
    end

    -- Hide remaining pool frames
    for key, frame in pairs(self.framePool) do
        if not self.activeFrames[frame.unit] then
            frame:Hide()
        end
    end
end

function QUI_RF:HidePreview()
    if InCombatLockdown() then return end
    self.previewMode = false

    -- Restore state drivers and hide all preview frames
    for key, frame in pairs(self.framePool) do
        RegisterStateDriver(frame, "visibility", "[@" .. frame.unit .. ",exists] show; hide")
    end

    -- Re-layout with real data
    self:LayoutRaidGrid()
end

---------------------------------------------------------------------------
-- INITIALIZE / TEARDOWN
---------------------------------------------------------------------------
function QUI_RF:Initialize()
    if InCombatLockdown() then
        self.pendingInitialize = true
        return
    end

    local db = GetDB()
    if not db or not db.raid or not db.raid.enabled then return end

    -- Pre-create all 40 frames (avoids combat creation issues)
    for i = 1, 40 do
        GetOrCreateFrame(i)
    end

    -- Build initial layout
    self:LayoutRaidGrid()

    -- Setup aura tracking for all created frames
    if QUI_UF.SetupAuraTracking then
        for _, frame in pairs(self.framePool) do
            QUI_UF.SetupAuraTracking(frame)
        end
    end

    -- Start range fade ticker
    if db.raid.rangeFade and db.raid.rangeFade.enabled then
        StartRaidRangeTicker()
    end
end

function QUI_RF:Teardown()
    StopRaidRangeTicker()
    if not InCombatLockdown() then
        for _, frame in pairs(self.framePool) do
            UnregisterStateDriver(frame, "visibility")
            frame:Hide()
        end
    end
    wipe(self.activeFrames)
end

---------------------------------------------------------------------------
-- EVENT FRAME: Roster changes & combat end
---------------------------------------------------------------------------
local raidEventFrame = CreateFrame("Frame")
raidEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
raidEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
raidEventFrame:SetScript("OnEvent", function(self, event)
    local db = GetDB()
    if not db or not db.raid or not db.raid.enabled then return end

    if event == "GROUP_ROSTER_UPDATE" then
        -- Throttle layout rebuilds
        if not layoutPending then
            layoutPending = true
            C_Timer.After(LAYOUT_THROTTLE, function()
                layoutPending = false
                QUI_RF:LayoutRaidGrid()
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if QUI_RF.pendingInitialize then
            QUI_RF.pendingInitialize = false
            QUI_RF:Initialize()
        end
        if QUI_RF.pendingLayout then
            QUI_RF.pendingLayout = false
            QUI_RF:LayoutRaidGrid()
        end
    end
end)

---------------------------------------------------------------------------
-- EXPOSE: Global refresh callback for options panel
---------------------------------------------------------------------------
_G.QUI_RefreshRaidFrames = function()
    QUI_RF:RefreshRaidFrames()
end
