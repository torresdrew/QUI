---------------------------------------------------------------------------
-- QUI XP Tracker
-- Displays experience progress, rested XP, XP/hour rate, time-to-level
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local QUI = ns.QUI or {}
ns.QUI = QUI
local Helpers = ns.Helpers
local UIKit = ns.UIKit

---------------------------------------------------------------------------
-- State tracking
---------------------------------------------------------------------------
local XPTrackerState = {
    frame = nil,
    isPreviewMode = false,
    ticker = nil,
    tickCount = 0,
    -- Session tracking
    sessionStartTime = 0,
    sessionStartXP = 0,
    sessionStartLevel = 0,
    totalSessionXP = 0,       -- Monotonic across level-ups
    levelStartTime = 0,
    lastKnownXP = 0,
    lastKnownLevel = 0,
    -- Ring buffer for XP/hour (10-min window, samples every 5 ticks = 10s)
    samples = {},             -- {time, totalXP} pairs
    maxSampleAge = 600,       -- 10 minutes in seconds
    sessionInitialized = false,
}

---------------------------------------------------------------------------
-- Get settings from database
---------------------------------------------------------------------------
local function GetSettings()
    return Helpers.GetModuleDB("xpTracker")
end

---------------------------------------------------------------------------
-- Format helpers
---------------------------------------------------------------------------
local function FormatXP(value)
    if value >= 1000000 then
        return string.format("%.1fM", value / 1000000)
    elseif value >= 1000 then
        return string.format("%.1fK", value / 1000)
    end
    return tostring(math.floor(value))
end

local function FormatDuration(seconds)
    if seconds < 0 then seconds = 0 end
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    if hours > 0 then
        return string.format("%dh %02dm", hours, mins)
    end
    return string.format("%dm %02ds", mins, secs)
end

local function FormatPercent(value)
    if value >= 100 then
        return "100%"
    end
    return string.format("%.1f%%", value)
end

---------------------------------------------------------------------------
-- XP Rate calculation (ring buffer)
---------------------------------------------------------------------------
local function RecordSample()
    local now = GetTime()
    local samples = XPTrackerState.samples

    -- Prune old samples beyond the window
    local cutoff = now - XPTrackerState.maxSampleAge
    local firstValid = #samples + 1
    for i = 1, #samples do
        if samples[i][1] >= cutoff then
            firstValid = i
            break
        end
    end
    if firstValid > 1 then
        local newSamples = {}
        for i = firstValid, #samples do
            newSamples[#newSamples + 1] = samples[i]
        end
        XPTrackerState.samples = newSamples
        samples = XPTrackerState.samples
    end

    -- Add new sample
    samples[#samples + 1] = {now, XPTrackerState.totalSessionXP}
end

local function GetXPPerHour()
    local samples = XPTrackerState.samples
    if #samples < 2 then return 0 end

    local oldest = samples[1]
    local newest = samples[#samples]
    local timeDelta = newest[1] - oldest[1]
    if timeDelta < 1 then return 0 end

    local xpDelta = newest[2] - oldest[2]
    return (xpDelta / timeDelta) * 3600
end

---------------------------------------------------------------------------
-- Text visibility (for hide-until-hover mode)
---------------------------------------------------------------------------
local function SetTextVisible(frame, visible)
    if not frame then return end
    local alpha = visible and 1 or 0
    frame.headerLeft:SetAlpha(alpha)
    frame.headerRight:SetAlpha(alpha)
    frame.line1:SetAlpha(alpha)
    frame.line2:SetAlpha(alpha)
    frame.line3:SetAlpha(alpha)
    -- Also hide/show backdrop and border so only the bar remains
    local settings = GetSettings()
    if visible then
        local bg = settings and settings.backdropColor or {0.05, 0.05, 0.07, 0.85}
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
        local bc = settings and settings.borderColor or {0, 0, 0, 1}
        UIKit.UpdateBorderLines(frame, 1, bc[1], bc[2], bc[3], bc[4])
        -- Expand hit rect to full frame
        frame:SetHitRectInsets(0, 0, 0, 0)
    else
        frame:SetBackdropColor(0, 0, 0, 0)
        UIKit.UpdateBorderLines(frame, 1, 0, 0, 0, 0, true)
        -- Shrink hit rect to just the bar area at the bottom
        local barHeight = settings and settings.barHeight or 20
        local frameHeight = frame:GetHeight()
        local topInset = frameHeight - barHeight - 6  -- 3px padding on each side
        if topInset < 0 then topInset = 0 end
        frame:SetHitRectInsets(0, 0, topInset, 0)
    end
end

---------------------------------------------------------------------------
-- Create the XP tracker frame
---------------------------------------------------------------------------
local function CreateFrame_XPTracker()
    if XPTrackerState.frame then return end

    local settings = GetSettings()
    if not settings then return end

    local width = settings.width or 250
    local height = settings.height or 90

    local frame = CreateFrame("Frame", "QUI_XPTracker", UIParent, "BackdropTemplate")
    frame:SetPoint("CENTER", UIParent, "CENTER", settings.offsetX or 0, settings.offsetY or 150)
    frame:SetSize(width, height)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(50)
    frame:SetClampedToScreen(true)

    -- Backdrop
    frame:SetBackdrop(UIKit.GetBackdropInfo(nil, nil, frame))
    local bg = settings.backdropColor or {0.05, 0.05, 0.07, 0.85}
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])

    -- Border
    UIKit.CreateBorderLines(frame)
    local bc = settings.borderColor or {0, 0, 0, 1}
    UIKit.UpdateBorderLines(frame, 1, bc[1], bc[2], bc[3], bc[4])

    -- Font settings
    local fontPath, fontOutline = Helpers.GetGeneralFontSettings()
    local headerFontSize = settings.headerFontSize or 12
    local fontSize = settings.fontSize or 11
    local headerLineHeight = settings.headerLineHeight or 18

    -- Header: "Experience" left, "Level X" right
    local headerLeft = frame:CreateFontString(nil, "OVERLAY")
    headerLeft:SetFont(fontPath, headerFontSize, fontOutline)
    headerLeft:SetTextColor(0.9, 0.9, 0.9, 1)
    headerLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -5)
    headerLeft:SetText("Experience")
    frame.headerLeft = headerLeft

    local headerRight = frame:CreateFontString(nil, "OVERLAY")
    headerRight:SetFont(fontPath, headerFontSize, fontOutline)
    headerRight:SetTextColor(1.0, 0.82, 0.0, 1) -- Gold
    headerRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -5)
    headerRight:SetText("Level 1")
    frame.headerRight = headerRight

    -- Stat lines
    local lineY = -(5 + headerLineHeight)
    local lineSpacing = settings.lineHeight or 14

    -- Line 1: Completed / Rested
    local line1 = frame:CreateFontString(nil, "OVERLAY")
    line1:SetFont(fontPath, fontSize, fontOutline)
    line1:SetTextColor(0.8, 0.8, 0.8, 1)
    line1:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, lineY)
    line1:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    line1:SetJustifyH("LEFT")
    line1:SetWordWrap(false)
    frame.line1 = line1

    -- Line 2: XP/hour + Leveling in
    local line2 = frame:CreateFontString(nil, "OVERLAY")
    line2:SetFont(fontPath, fontSize, fontOutline)
    line2:SetTextColor(0.8, 0.8, 0.8, 1)
    line2:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, lineY - lineSpacing)
    line2:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    line2:SetJustifyH("LEFT")
    line2:SetWordWrap(false)
    frame.line2 = line2

    -- Line 3: Level time / Session time
    local line3 = frame:CreateFontString(nil, "OVERLAY")
    line3:SetFont(fontPath, fontSize, fontOutline)
    line3:SetTextColor(0.8, 0.8, 0.8, 1)
    line3:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, lineY - lineSpacing * 2)
    line3:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    line3:SetJustifyH("LEFT")
    line3:SetWordWrap(false)
    frame.line3 = line3

    -- XP Bar container
    local barHeight = settings.barHeight or 20
    local barContainer = CreateFrame("Frame", nil, frame)
    barContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 3, 3)
    barContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    barContainer:SetHeight(barHeight)
    frame.barContainer = barContainer

    -- Bar background
    local barBG = barContainer:CreateTexture(nil, "BACKGROUND")
    barBG:SetAllPoints(barContainer)
    barBG:SetColorTexture(0, 0, 0, 0.5)
    frame.barBG = barBG

    -- XP StatusBar
    local xpBar = CreateFrame("StatusBar", nil, barContainer)
    xpBar:SetAllPoints(barContainer)
    xpBar:SetMinMaxValues(0, 1)
    xpBar:SetValue(0)
    local barColor = settings.barColor or {0.2, 0.5, 1.0, 1}
    local LSM = LibStub("LibSharedMedia-3.0", true)
    local texturePath
    if LSM then
        texturePath = LSM:Fetch("statusbar", settings.barTexture or "Solid")
    end
    if texturePath then
        xpBar:SetStatusBarTexture(texturePath)
    else
        xpBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    end
    xpBar:SetStatusBarColor(barColor[1], barColor[2], barColor[3], barColor[4] or 1)
    frame.xpBar = xpBar

    -- Rested overlay (texture, not a second bar)
    local restedOverlay = barContainer:CreateTexture(nil, "ARTWORK", nil, 1)
    restedOverlay:SetPoint("LEFT", xpBar:GetStatusBarTexture(), "RIGHT", 0, 0)
    restedOverlay:SetHeight(barHeight)
    restedOverlay:SetWidth(0)
    restedOverlay:Hide()
    if texturePath then
        restedOverlay:SetTexture(texturePath)
    else
        restedOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    end
    local restedColor = settings.restedColor or {1.0, 0.7, 0.1, 0.5}
    restedOverlay:SetVertexColor(restedColor[1], restedColor[2], restedColor[3], restedColor[4] or 0.5)
    frame.restedOverlay = restedOverlay

    -- Bar text overlay (parented to xpBar so it draws above the bar fill)
    local barText = xpBar:CreateFontString(nil, "OVERLAY")
    barText:SetFont(fontPath, fontSize - 1, fontOutline)
    barText:SetTextColor(1, 1, 1, 1)
    barText:SetPoint("CENTER", barContainer, "CENTER", 0, 0)
    barText:SetJustifyH("CENTER")
    frame.barText = barText

    -- Hover to reveal text
    frame:SetScript("OnEnter", function(self)
        local s = GetSettings()
        if s and s.hideTextUntilHover then
            SetTextVisible(self, true)
        end
    end)
    frame:SetScript("OnLeave", function(self)
        local s = GetSettings()
        if s and s.hideTextUntilHover then
            SetTextVisible(self, false)
        end
    end)

    -- Dragging support
    frame:SetMovable(not settings.locked)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        local s = GetSettings()
        local isOverridden = _G.QUI_IsFrameOverridden and _G.QUI_IsFrameOverridden(self)
        if s and not s.locked and not isOverridden then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position back to DB
        local s = GetSettings()
        if s then
            local point, _, _, x, y = self:GetPoint(1)
            if point then
                s.offsetX = math.floor((x or 0) + 0.5)
                s.offsetY = math.floor((y or 0) + 0.5)
            end
        end
    end)

    frame:Hide()
    XPTrackerState.frame = frame
end

---------------------------------------------------------------------------
-- Update display with current XP data
---------------------------------------------------------------------------
local function UpdateDisplay()
    local frame = XPTrackerState.frame
    if not frame then return end

    local settings = GetSettings()
    if not settings then return end

    local isPreview = XPTrackerState.isPreviewMode

    local currentXP, maxXP, exhaustion, level, isAtCap, isXPDisabled

    if isPreview then
        -- Fake data for preview
        currentXP = 11000
        maxXP = 13000
        exhaustion = 1260
        level = 72
        isAtCap = false
        isXPDisabled = false
    else
        currentXP = UnitXP("player") or 0
        maxXP = UnitXPMax("player") or 1
        exhaustion = GetXPExhaustion() or 0
        level = UnitLevel("player") or 1
        isAtCap = IsPlayerAtEffectiveLevelCap and IsPlayerAtEffectiveLevelCap() or false
        isXPDisabled = IsXPUserDisabled and IsXPUserDisabled() or false

        -- Auto-hide at max level
        if isAtCap or isXPDisabled then
            frame:Hide()
            return
        end
    end

    if maxXP == 0 then maxXP = 1 end

    local fraction = currentXP / maxXP
    local percent = fraction * 100
    local remaining = maxXP - currentXP

    -- Rested
    local restedPercent = 0
    if exhaustion and exhaustion > 0 and maxXP > 0 then
        restedPercent = (exhaustion / maxXP) * 100
    end

    -- Header
    frame.headerLeft:SetText("Experience")
    frame.headerRight:SetText("Level " .. level)

    -- Line 1: Completed / Rested
    local line1Text = "Completed: " .. FormatPercent(percent)
    if restedPercent > 0 then
        line1Text = line1Text .. "  |  Rested: " .. FormatPercent(restedPercent)
    end
    frame.line1:SetText(line1Text)

    -- XP rate and time-to-level
    local xpPerHour
    if isPreview then
        xpPerHour = 45000
    else
        xpPerHour = GetXPPerHour()
    end

    -- Line 2: XP/hour + Leveling in
    local line2Text
    if xpPerHour > 0 then
        local secondsToLevel = (remaining / xpPerHour) * 3600
        line2Text = FormatXP(xpPerHour) .. "/hr  |  Level in: " .. FormatDuration(secondsToLevel)
    else
        line2Text = "Gathering data..."
    end
    frame.line2:SetText(line2Text)

    -- Line 3: Level time / Session time
    local now = GetTime()
    local levelTime, sessionTime
    if isPreview then
        levelTime = 1845
        sessionTime = 5430
    else
        levelTime = now - XPTrackerState.levelStartTime
        sessionTime = now - XPTrackerState.sessionStartTime
    end
    frame.line3:SetText("Level: " .. FormatDuration(levelTime) .. "  |  Session: " .. FormatDuration(sessionTime))

    -- XP Bar
    frame.xpBar:SetMinMaxValues(0, 1)
    frame.xpBar:SetValue(fraction)

    -- Rested overlay width
    local showRested = settings.showRested ~= false
    if showRested and exhaustion and exhaustion > 0 then
        local barWidth = frame.barContainer:GetWidth()
        if barWidth <= 0 then barWidth = frame:GetWidth() - 6 end
        local restedFraction = exhaustion / maxXP
        -- Clamp so rested doesn't extend past the bar end
        local maxRestedWidth = barWidth * (1 - fraction)
        local restedWidth = math.min(barWidth * restedFraction, maxRestedWidth)
        if restedWidth > 0 then
            frame.restedOverlay:SetWidth(restedWidth)
            frame.restedOverlay:Show()
        else
            frame.restedOverlay:Hide()
        end
    else
        frame.restedOverlay:Hide()
    end

    -- Bar text
    local showBarText = settings.showBarText ~= false
    if showBarText then
        local barTextStr = FormatXP(currentXP) .. "/" .. FormatXP(maxXP)
        barTextStr = barTextStr .. " (" .. FormatXP(remaining) .. ") " .. FormatPercent(percent)
        if restedPercent > 0 then
            barTextStr = barTextStr .. " (" .. FormatPercent(restedPercent) .. " rested)"
        end
        frame.barText:SetText(barTextStr)
        frame.barText:Show()
    else
        frame.barText:Hide()
    end

    frame:Show()

    -- Apply text visibility for hide-until-hover mode (skip if mouse is over frame)
    if settings.hideTextUntilHover and not frame:IsMouseOver() then
        SetTextVisible(frame, false)
    end
end

---------------------------------------------------------------------------
-- Update appearance from settings (without changing data)
---------------------------------------------------------------------------
local function UpdateAppearance()
    if not XPTrackerState.frame then
        CreateFrame_XPTracker()
    end

    local frame = XPTrackerState.frame
    if not frame then return end

    local settings = GetSettings()
    if not settings then return end

    local width = settings.width or 250
    local height = settings.height or 90
    frame:SetSize(width, height)

    -- Position
    if not (_G.QUI_IsFrameOverridden and _G.QUI_IsFrameOverridden(frame)) then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", settings.offsetX or 0, settings.offsetY or 150)
    end

    -- Backdrop
    frame:SetBackdrop(UIKit.GetBackdropInfo(nil, nil, frame))
    local bg = settings.backdropColor or {0.05, 0.05, 0.07, 0.85}
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])

    -- Border
    local bc = settings.borderColor or {0, 0, 0, 1}
    UIKit.UpdateBorderLines(frame, 1, bc[1], bc[2], bc[3], bc[4])

    -- Font
    local fontPath, fontOutline = Helpers.GetGeneralFontSettings()
    local fontSize = settings.fontSize or 11

    local headerFontSize = settings.headerFontSize or 12
    frame.headerLeft:SetFont(fontPath, headerFontSize, fontOutline)
    frame.headerRight:SetFont(fontPath, headerFontSize, fontOutline)
    frame.line1:SetFont(fontPath, fontSize, fontOutline)
    frame.line2:SetFont(fontPath, fontSize, fontOutline)
    frame.line3:SetFont(fontPath, fontSize, fontOutline)
    frame.barText:SetFont(fontPath, fontSize - 1, fontOutline)

    -- Line height (reposition stat lines)
    local headerLineHeight = settings.headerLineHeight or 18
    local lineSpacing = settings.lineHeight or 14
    local lineY = -(5 + headerLineHeight)
    frame.line1:ClearAllPoints()
    frame.line1:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, lineY)
    frame.line1:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    frame.line2:ClearAllPoints()
    frame.line2:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, lineY - lineSpacing)
    frame.line2:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    frame.line3:ClearAllPoints()
    frame.line3:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, lineY - lineSpacing * 2)
    frame.line3:SetPoint("RIGHT", frame, "RIGHT", -6, 0)

    -- Bar height
    local barHeight = settings.barHeight or 20
    frame.barContainer:SetHeight(barHeight)
    frame.restedOverlay:SetHeight(barHeight)

    -- Bar texture
    local LSM = LibStub("LibSharedMedia-3.0", true)
    local texturePath
    if LSM then
        texturePath = LSM:Fetch("statusbar", settings.barTexture or "Solid")
    end
    if texturePath then
        frame.xpBar:SetStatusBarTexture(texturePath)
        frame.restedOverlay:SetTexture(texturePath)
    end

    -- Bar color
    local barColor = settings.barColor or {0.2, 0.5, 1.0, 1}
    frame.xpBar:SetStatusBarColor(barColor[1], barColor[2], barColor[3], barColor[4] or 1)

    -- Rested color
    local restedColor = settings.restedColor or {1.0, 0.7, 0.1, 0.5}
    frame.restedOverlay:SetVertexColor(restedColor[1], restedColor[2], restedColor[3], restedColor[4] or 0.5)

    -- Movable state
    frame:SetMovable(not settings.locked)
end

---------------------------------------------------------------------------
-- Ticker callback (every 2 seconds)
---------------------------------------------------------------------------
local function OnTick()
    if not XPTrackerState.frame then return end

    local settings = GetSettings()
    if not settings or not settings.enabled then return end
    if XPTrackerState.isPreviewMode then return end

    XPTrackerState.tickCount = XPTrackerState.tickCount + 1

    -- Record sample every 5 ticks (10 seconds)
    if XPTrackerState.tickCount % 5 == 0 then
        RecordSample()
    end

    UpdateDisplay()
end

---------------------------------------------------------------------------
-- Handle XP gain events
---------------------------------------------------------------------------
local function OnXPUpdate()
    if XPTrackerState.isPreviewMode then return end
    if not XPTrackerState.sessionInitialized then return end

    local currentXP = UnitXP("player") or 0
    local currentLevel = UnitLevel("player") or 1

    -- Track XP delta
    if currentLevel == XPTrackerState.lastKnownLevel then
        local delta = currentXP - XPTrackerState.lastKnownXP
        if delta > 0 then
            XPTrackerState.totalSessionXP = XPTrackerState.totalSessionXP + delta
        end
    end

    XPTrackerState.lastKnownXP = currentXP
    XPTrackerState.lastKnownLevel = currentLevel

    -- Record a sample immediately on XP gain for responsiveness
    RecordSample()

    UpdateDisplay()
end

---------------------------------------------------------------------------
-- Handle level-up
---------------------------------------------------------------------------
local function OnLevelUp(newLevel)
    if XPTrackerState.isPreviewMode then return end
    if not XPTrackerState.sessionInitialized then return end

    -- PLAYER_XP_UPDATE fires before PLAYER_LEVEL_UP, so XP delta is already tracked

    XPTrackerState.levelStartTime = GetTime()
    XPTrackerState.lastKnownXP = UnitXP("player") or 0
    XPTrackerState.lastKnownLevel = newLevel or UnitLevel("player") or 1

    -- Clear ring buffer on level-up for fresh rate calculation
    XPTrackerState.samples = {}
    RecordSample()

    UpdateDisplay()
end

---------------------------------------------------------------------------
-- Initialize session tracking
---------------------------------------------------------------------------
local function InitializeSession()
    local now = GetTime()
    local currentXP = UnitXP("player") or 0
    local currentLevel = UnitLevel("player") or 1

    XPTrackerState.sessionStartTime = now
    XPTrackerState.sessionStartXP = currentXP
    XPTrackerState.sessionStartLevel = currentLevel
    XPTrackerState.totalSessionXP = 0
    XPTrackerState.levelStartTime = now
    XPTrackerState.lastKnownXP = currentXP
    XPTrackerState.lastKnownLevel = currentLevel
    XPTrackerState.samples = {}
    XPTrackerState.tickCount = 0

    XPTrackerState.sessionInitialized = true
    RecordSample()
end

---------------------------------------------------------------------------
-- Start/stop ticker
---------------------------------------------------------------------------
local function StartTicker()
    if XPTrackerState.ticker then return end
    XPTrackerState.ticker = C_Timer.NewTicker(2, OnTick)
end

local function StopTicker()
    if XPTrackerState.ticker then
        XPTrackerState.ticker:Cancel()
        XPTrackerState.ticker = nil
    end
end

---------------------------------------------------------------------------
-- Refresh (called when settings change)
---------------------------------------------------------------------------
local function RefreshXPTracker()
    local settings = GetSettings()

    if (not settings or not settings.enabled) and not XPTrackerState.isPreviewMode then
        StopTicker()
        if XPTrackerState.frame then
            XPTrackerState.frame:Hide()
        end
        return
    end

    CreateFrame_XPTracker()
    UpdateAppearance()

    if not XPTrackerState.isPreviewMode then
        StartTicker()
    end

    UpdateDisplay()
end

---------------------------------------------------------------------------
-- Toggle preview mode
---------------------------------------------------------------------------
local function TogglePreview(enable)
    CreateFrame_XPTracker()
    if not XPTrackerState.frame then return end

    XPTrackerState.isPreviewMode = enable

    if enable then
        StopTicker()
        UpdateAppearance()
        UpdateDisplay()
    else
        local settings = GetSettings()
        if settings and settings.enabled then
            -- Check if at max level
            local isAtCap = IsPlayerAtEffectiveLevelCap and IsPlayerAtEffectiveLevelCap() or false
            local isXPDisabled = IsXPUserDisabled and IsXPUserDisabled() or false
            if isAtCap or isXPDisabled then
                XPTrackerState.frame:Hide()
            else
                StartTicker()
                UpdateDisplay()
            end
        else
            XPTrackerState.frame:Hide()
        end
    end
end

local function IsPreviewMode()
    return XPTrackerState.isPreviewMode
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_XP_UPDATE")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("UPDATE_EXHAUSTION")
eventFrame:RegisterEvent("PLAYER_UPDATE_RESTING")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, function()
            InitializeSession()
            CreateFrame_XPTracker()

            local settings = GetSettings()
            if settings and settings.enabled then
                local isAtCap = IsPlayerAtEffectiveLevelCap and IsPlayerAtEffectiveLevelCap() or false
                local isXPDisabled = IsXPUserDisabled and IsXPUserDisabled() or false
                if not isAtCap and not isXPDisabled then
                    UpdateAppearance()
                    StartTicker()
                    UpdateDisplay()
                end
            end
        end)
    elseif event == "PLAYER_XP_UPDATE" then
        OnXPUpdate()
    elseif event == "PLAYER_LEVEL_UP" then
        local newLevel = ...
        OnLevelUp(newLevel)
    elseif event == "UPDATE_EXHAUSTION" or event == "PLAYER_UPDATE_RESTING" then
        if XPTrackerState.sessionInitialized then
            UpdateDisplay()
        end
    end
end)

---------------------------------------------------------------------------
-- Global exports
---------------------------------------------------------------------------
_G.QUI_RefreshXPTracker = RefreshXPTracker
_G.QUI_ToggleXPTrackerPreview = TogglePreview
_G.QUI_IsXPTrackerPreviewMode = IsPreviewMode

QUI.XPTracker = {
    Refresh = RefreshXPTracker,
    TogglePreview = TogglePreview,
    IsPreviewMode = IsPreviewMode,
}
