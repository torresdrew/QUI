--[[
    QUI CDM Bar Factory

    Creates and manages addon-owned bar frames for the CDM tracked bar system.
    All bars are simple Frame objects with StatusBar children — no protected
    attributes, eliminating combat taint concerns for frame operations.

    All bar state is derived from QUI's resolver pipeline (composer entries +
    C_Spell + C_UnitAuras). Blizzard CDM viewer children are not consulted.

    Pattern mirrors cdm_icons.lua pool management.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local QUICore = ns.Addon
local LSM = ns.LSM

---------------------------------------------------------------------------
-- MODULE
---------------------------------------------------------------------------
local CDMBars = {}
ns.CDMBars = CDMBars
local CDMCooldown = ns.CDMCooldown

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------
local GetGeneralFont = Helpers.GetGeneralFont
local GetGeneralFontOutline = Helpers.GetGeneralFontOutline
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

-- Upvalue hot-path globals
local type = type
local ipairs = ipairs
local pcall = pcall
local string_format = string.format
local math_floor = math.floor
local CreateFrame = CreateFrame

---------------------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------------------
local MAX_RECYCLE_POOL_SIZE = 20

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local barPool = {}       -- active bars (array)
local recyclePool = {}   -- recycled bars (array, max MAX_RECYCLE_POOL_SIZE)
local barTimerFrame = CreateFrame("Frame")
local barTimerGroup = barTimerFrame:CreateAnimationGroup()
local barTimerAnim = barTimerGroup:CreateAnimation()
barTimerAnim:SetDuration(0.1)  -- 100ms = ~10 FPS
barTimerGroup:SetLooping("REPEAT")

do local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "CDM_barPool",      tbl = barPool }
    mp[#mp + 1] = { name = "CDM_barRecycle",   tbl = recyclePool }
end

-- Stored refs for periodic re-layout after ticker updates _active state
local _lastContainer = nil
local _lastSettings = nil

---------------------------------------------------------------------------
-- DEFERRED RESIZE
-- The buff-bar container must keep adjusting its size during combat so
-- frames anchored to its growth edge track when bars activate/deactivate
-- mid-combat (and so the container itself follows an autoWidth parent that
-- resizes). LayoutBars is reached via UNIT_AURA dispatch, which
-- enters with taint inherited from the secure event chain; calling
-- container:SetSize directly fires ADDON_ACTION_BLOCKED 'UNKNOWN()' on the
-- protection check (pcall catches the Lua error but not the event itself).
-- C_Timer.After(0) defers the SetSize one tick into clean main-loop context,
-- breaking the taint chain so the call passes the protection check on a
-- non-protected QUI Frame. Multiple in-flight requests coalesce: each
-- container only resizes once per flush, with the latest target dimensions.
---------------------------------------------------------------------------
local _pendingResize = nil

local function _flushPendingResizes()
    local q = _pendingResize
    _pendingResize = nil
    if not q then return end
    for container, dims in pairs(q) do
        if container.SetSize then
            container:SetSize(dims.w, dims.h)
        end
        if _G.QUI_SetCDMViewerBounds then
            _G.QUI_SetCDMViewerBounds(container, dims.w, dims.h)
        end
    end
end

local function ResizeContainer(container, w, h)
    if not container then return end
    if container._lastBarLayoutW == w and container._lastBarLayoutH == h then
        return
    end
    container._lastBarLayoutW = w
    container._lastBarLayoutH = h

    if (not InCombatLockdown()) or ns._inInitSafeWindow then
        container:SetSize(w, h)
        if _G.QUI_SetCDMViewerBounds then
            _G.QUI_SetCDMViewerBounds(container, w, h)
        end
        return
    end

    if not _pendingResize then
        _pendingResize = {}
        C_Timer.After(0, _flushPendingResizes)
    end
    local entry = _pendingResize[container]
    if entry then
        entry.w = w
        entry.h = h
    else
        _pendingResize[container] = { w = w, h = h }
    end
end

---------------------------------------------------------------------------
-- PERMANENT-AURA OVERLAY DRIVE (curve trick via IsZero bool)
--
-- DurationObject:IsZero() returns a (potentially-secret) bool that is
-- stable for the aura's lifetime — it's a property of the durObj itself,
-- not derived from elapsed/remaining time, so it doesn't oscillate as
-- the aura ticks.
--
-- C_CurveUtil.EvaluateColorValueFromBoolean is a C-side helper that
-- selects between two numbers based on a (potentially-secret) bool —
-- the secret never crosses into Lua compares. The result is a normal
-- scalar that can be sent to a C-side sink (Texture:SetAlpha /
-- FontString:SetAlpha) without taint.
--
-- Mapping for the bar overlay:
--   IsZero=true  (permanent) → alpha 1 (overlay visible — bar full)
--   IsZero=false (timed)     → alpha 0 (overlay invisible — bar shows
--                                       SetTimerDuration animation)
--
-- Mapping for the duration text:
--   IsZero=true  (permanent) → alpha 0 (text hidden — no countdown)
--   IsZero=false (timed)     → alpha 1 (text visible — countdown shows)
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- BAR FRAME FACTORY
---------------------------------------------------------------------------
local function CreateBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(200, 25)

    -- StatusBar for duration progress
    local statusBar = CreateFrame("StatusBar", nil, bar)
    statusBar:SetMinMaxValues(0, 1)
    statusBar:SetValue(0)
    bar.StatusBar = statusBar

    -- PermanentFill overlay: full-bar texture rendered above the StatusBar
    -- fill but below text. Alpha is curve-driven from the durObj's total
    -- duration in UpdateOwnedBarAura — visible only for no-expiration
    -- auras, completely invisible (no visual effect) for timed auras.
    local permanentFill = statusBar:CreateTexture(nil, "OVERLAY", nil, 1)
    permanentFill:SetAllPoints(statusBar)
    permanentFill:SetAlpha(0)
    bar.PermanentFill = permanentFill

    -- Background texture (BACKGROUND, sublevel -8)
    local bg = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetColorTexture(0, 0, 0, 1)
    bar.Background = bg

    -- Icon container frame
    local iconContainer = CreateFrame("Frame", nil, bar)
    iconContainer:SetSize(25, 25)
    bar.IconContainer = iconContainer

    -- Icon texture inside container
    local iconTex = iconContainer:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints(iconContainer)
    iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    bar.IconTexture = iconTex

    -- Border container with 4-edge textures
    local borderFrame = CreateFrame("Frame", nil, bar)
    borderFrame:SetFrameLevel((bar.GetFrameLevel and bar:GetFrameLevel() or 1) + 5)
    borderFrame._top = borderFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    borderFrame._top:SetColorTexture(0, 0, 0, 1)
    borderFrame._bottom = borderFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    borderFrame._bottom:SetColorTexture(0, 0, 0, 1)
    borderFrame._left = borderFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    borderFrame._left:SetColorTexture(0, 0, 0, 1)
    borderFrame._right = borderFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    borderFrame._right:SetColorTexture(0, 0, 0, 1)
    bar.BorderContainer = borderFrame

    -- Text overlay frame (renders above StatusBar fill texture)
    local textOverlay = CreateFrame("Frame", nil, statusBar)
    textOverlay:SetAllPoints(statusBar)
    textOverlay:SetFrameLevel((statusBar.GetFrameLevel and statusBar:GetFrameLevel() or 1) + 2)
    bar.TextOverlay = textOverlay

    -- Name text (spell name)
    local nameText = textOverlay:CreateFontString(nil, "OVERLAY", nil, 7)
    nameText:SetFont(GetGeneralFont(), 14, GetGeneralFontOutline())
    nameText:SetPoint("LEFT", statusBar, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1, 1)
    nameText:SetShadowColor(0, 0, 0, 1)
    nameText:SetShadowOffset(1, -1)
    bar.NameText = nameText

    -- Duration text (remaining time)
    local durationText = textOverlay:CreateFontString(nil, "OVERLAY", nil, 7)
    durationText:SetFont(GetGeneralFont(), 14, GetGeneralFontOutline())
    durationText:SetPoint("RIGHT", statusBar, "RIGHT", -4, 0)
    durationText:SetJustifyH("RIGHT")
    durationText:SetTextColor(1, 1, 1, 1)
    durationText:SetShadowColor(0, 0, 0, 1)
    durationText:SetShadowOffset(1, -1)
    bar.DurationText = durationText

    -- State tracking
    bar._spellEntry = nil
    bar._spellID = nil
    bar._active = false
    bar._cSideFill = nil
    bar._preferDurObjFill = nil

    bar:Hide()
    return bar
end

---------------------------------------------------------------------------
-- Helper functions for color overrides
---------------------------------------------------------------------------

-- Build a color-override key set from the bar's bound composer entry. Key
-- shape mirrors the legacy Blizzard-child-derived spellData (spellID /
-- baseSpellID / overrideSpellID / cooldownID) so colorOverride profiles
-- imported from earlier versions still match.
local function GetBarSpellData(bar)
    local entry = bar and bar._spellEntry
    if not entry then return nil end
    local baseSpellID = entry.spellID or entry.id
    local overrideSpellID = entry.overrideSpellID
    local resolvedSpellID = overrideSpellID or baseSpellID
    if not resolvedSpellID and not entry.name then return nil end
    return {
        spellID = resolvedSpellID,
        baseSpellID = baseSpellID or resolvedSpellID,
        overrideSpellID = overrideSpellID,
        name = entry.name,
        cooldownID = entry.cooldownID,
    }
end

local function ShouldDebugBarEntry(entry, spellID)
    local dbg = _G.QUI_CDM_BAR_DEBUG
    if not dbg then return false end
    if dbg == true then return true end
    if type(dbg) ~= "string" then return false end
    local entryName = entry and entry.name
    if type(entryName) == "string" and entryName:lower():find(dbg, 1, true) then
        return true
    end
    return tostring(spellID) == dbg
end

local function DebugBarLabel(entry, spellID, ...)
    if not ShouldDebugBarEntry(entry, spellID) then return end
    print("|cff34D399[CDM-BarDbg]|r", ...)
end

local function ShouldHideAuraDurationText(r)
    if not r or not r.isActive then return false end
    if r.isTotemInstance then return false end
    if r.hideDurationText or r.hasExpirationTime == false then return true end
    if not r.auraData then return false end

    local duration = r.auraData.duration
    if duration == nil then
        return true
    end
    local readableDuration = duration
    return not readableDuration or readableDuration <= 0
end

local function GetTrackedBarOverrideColor(settings, spellData)
    local overrides = settings and settings.colorOverrides
    if type(overrides) ~= "table" or type(spellData) ~= "table" then
        return nil
    end

    local color = spellData.spellID and overrides[spellData.spellID]
    if type(color) == "table" then
        return color
    end

    color = spellData.overrideSpellID and overrides[spellData.overrideSpellID]
    if type(color) == "table" then
        return color
    end

    color = spellData.baseSpellID and overrides[spellData.baseSpellID]
    if type(color) == "table" then
        return color
    end

    color = spellData.cooldownID and overrides[spellData.cooldownID]
    if type(color) == "table" then
        return color
    end

    return nil
end

---------------------------------------------------------------------------
-- CONFIGURE BAR (clean rewrite of ApplyBarStyle for owned frames)
---------------------------------------------------------------------------
function CDMBars.ConfigureBar(bar, settings, overrideWidth)
    if not bar then return end

    local barHeight = settings.barHeight or 25
    local barWidth = overrideWidth or settings.barWidth or 215
    local texture = settings.texture or "Quazii v5"
    local useClassColor = settings.useClassColor
    local barColor = settings.barColor or {0.376, 0.647, 0.980, 1}
    local barOpacity = settings.barOpacity or 1.0
    local borderSize = settings.borderSize or 2
    local bgColor = settings.bgColor or {0, 0, 0, 1}
    local bgOpacity = settings.bgOpacity or 0.5
    local textSize = settings.textSize or 14
    local hideIcon = settings.hideIcon
    local hideText = settings.hideText

    -- Inactive visual settings
    local inactiveMode = settings.inactiveMode or "hide"
    if inactiveMode ~= "always" and inactiveMode ~= "fade" and inactiveMode ~= "hide" then
        inactiveMode = "always"
    end
    local inactiveAlpha = settings.inactiveAlpha or 0.3
    if inactiveAlpha < 0 then inactiveAlpha = 0 end
    if inactiveAlpha > 1 then inactiveAlpha = 1 end
    local desaturateInactive = (settings.desaturateInactive == true)

    -- Vertical bar settings
    local orientation = settings.orientation or "horizontal"
    local isVertical = (orientation == "vertical")
    local fillDirection = settings.fillDirection or "up"
    local iconPosition = settings.iconPosition or "top"
    local showTextOnVertical = settings.showTextOnVertical or false

    local isActive = bar._active
    local spellData = GetBarSpellData(bar)
    local overrideColor = GetTrackedBarOverrideColor(settings, spellData)

    -- For vertical bars: swap width/height conceptually
    local frameWidth, frameHeight
    if isVertical then
        frameWidth = barHeight
        frameHeight = barWidth
    else
        frameWidth = barWidth
        frameHeight = barHeight
    end

    -- Set bar dimensions
    bar:SetSize(frameWidth, frameHeight)

    local statusBar = bar.StatusBar
    if statusBar then
        statusBar:SetSize(frameWidth, frameHeight)
        if statusBar.SetOrientation then
            statusBar:SetOrientation(isVertical and "VERTICAL" or "HORIZONTAL")
        end
        if isVertical and statusBar.SetReverseFill then
            statusBar:SetReverseFill(fillDirection == "down")
        end
    end

    -- Icon container
    local iconContainer = bar.IconContainer
    if iconContainer then
        if hideIcon then
            iconContainer:Hide()
            iconContainer:SetAlpha(0)
        else
            iconContainer:Show()
            iconContainer:SetAlpha(1)
            local iconSize = isVertical and frameWidth or frameHeight
            iconContainer:SetSize(iconSize, iconSize)

            -- Apply optional desaturation for inactive entries
            if bar.IconTexture and bar.IconTexture.SetDesaturated then
                bar.IconTexture:SetDesaturated((not isActive) and desaturateInactive and inactiveMode ~= "always")
            end
        end
    end

    -- Position statusBar and icon based on orientation
    if statusBar then
        statusBar:ClearAllPoints()
        if isVertical then
            if hideIcon or not iconContainer then
                statusBar:SetAllPoints(bar)
            else
                iconContainer:ClearAllPoints()
                if iconPosition == "bottom" then
                    iconContainer:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
                    statusBar:SetPoint("TOP", bar, "TOP", 0, 0)
                    statusBar:SetPoint("LEFT", bar, "LEFT", 0, 0)
                    statusBar:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
                    statusBar:SetPoint("BOTTOM", iconContainer, "TOP", 0, 0)
                else -- "top" (default)
                    iconContainer:SetPoint("TOP", bar, "TOP", 0, 0)
                    statusBar:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
                    statusBar:SetPoint("LEFT", bar, "LEFT", 0, 0)
                    statusBar:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
                    statusBar:SetPoint("TOP", iconContainer, "BOTTOM", 0, 0)
                end
            end
        else
            if hideIcon or not iconContainer then
                statusBar:SetPoint("LEFT", bar, "LEFT", 0, 0)
            else
                iconContainer:ClearAllPoints()
                iconContainer:SetPoint("LEFT", bar, "LEFT", 0, 0)
                statusBar:SetPoint("LEFT", iconContainer, "RIGHT", 0, 0)
            end
            statusBar:SetPoint("TOP", bar, "TOP", 0, 0)
            statusBar:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
            statusBar:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
        end
    end

    -- Apply StatusBar texture (and mirror onto PermanentFill so the
    -- no-expiration overlay matches the bar's texture/style).
    local resolvedTexturePath
    if statusBar and statusBar.SetStatusBarTexture then
        resolvedTexturePath = LSM:Fetch("statusbar", texture) or LSM:Fetch("statusbar", "Quazii v5")
        if resolvedTexturePath then
            statusBar:SetStatusBarTexture(resolvedTexturePath)
        end
    end
    if bar.PermanentFill and resolvedTexturePath then
        bar.PermanentFill:SetTexture(resolvedTexturePath)
    end

    -- Apply bar color (override > class > custom) with opacity. Mirror the
    -- resolved color onto PermanentFill via SetVertexColor so the overlay
    -- matches the bar's fill color.
    local resolvedR, resolvedG, resolvedB, resolvedA
    if statusBar and statusBar.SetStatusBarColor then
        local c = barColor
        if overrideColor then
            resolvedR, resolvedG, resolvedB, resolvedA =
                overrideColor[1] or 0.2, overrideColor[2] or 0.8, overrideColor[3] or 0.6, barOpacity
        elseif useClassColor then
            local _, class = UnitClass("player")
            local safeClass = tostring(class)
            local color = safeClass and RAID_CLASS_COLORS[safeClass]
            if color then
                resolvedR, resolvedG, resolvedB, resolvedA = color.r, color.g, color.b, barOpacity
            else
                resolvedR, resolvedG, resolvedB, resolvedA =
                    c[1] or 0.2, c[2] or 0.8, c[3] or 0.6, barOpacity
            end
        else
            resolvedR, resolvedG, resolvedB, resolvedA =
                c[1] or 0.2, c[2] or 0.8, c[3] or 0.6, barOpacity
        end
        statusBar:SetStatusBarColor(resolvedR, resolvedG, resolvedB, resolvedA)
    end
    if bar.PermanentFill and resolvedR then
        bar.PermanentFill:SetVertexColor(resolvedR, resolvedG, resolvedB, resolvedA or 1)
    end

    -- Background
    local bg = bar.Background
    if bg then
        local bgR, bgG, bgB = bgColor[1] or 0, bgColor[2] or 0, bgColor[3] or 0
        bg:SetColorTexture(bgR, bgG, bgB, 1)
        if statusBar then
            bg:ClearAllPoints()
            bg:SetAllPoints(statusBar)
        end
        bg:SetAlpha(bgOpacity)
        bg:Show()
    end

    -- Border (4-edge technique)
    local borderFrame = bar.BorderContainer
    if borderFrame then
        if borderSize > 0 then
            borderFrame:ClearAllPoints()
            borderFrame:SetPoint("TOPLEFT", bar, "TOPLEFT", -borderSize, borderSize)
            borderFrame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", borderSize, -borderSize)

            borderFrame._top:ClearAllPoints()
            borderFrame._top:SetPoint("TOPLEFT", borderFrame, "TOPLEFT", 0, 0)
            borderFrame._top:SetPoint("TOPRIGHT", borderFrame, "TOPRIGHT", 0, 0)
            borderFrame._top:SetHeight(borderSize)

            borderFrame._bottom:ClearAllPoints()
            borderFrame._bottom:SetPoint("BOTTOMLEFT", borderFrame, "BOTTOMLEFT", 0, 0)
            borderFrame._bottom:SetPoint("BOTTOMRIGHT", borderFrame, "BOTTOMRIGHT", 0, 0)
            borderFrame._bottom:SetHeight(borderSize)

            borderFrame._left:ClearAllPoints()
            borderFrame._left:SetPoint("TOPLEFT", borderFrame, "TOPLEFT", 0, 0)
            borderFrame._left:SetPoint("BOTTOMLEFT", borderFrame, "BOTTOMLEFT", 0, 0)
            borderFrame._left:SetWidth(borderSize)

            borderFrame._right:ClearAllPoints()
            borderFrame._right:SetPoint("TOPRIGHT", borderFrame, "TOPRIGHT", 0, 0)
            borderFrame._right:SetPoint("BOTTOMRIGHT", borderFrame, "BOTTOMRIGHT", 0, 0)
            borderFrame._right:SetWidth(borderSize)

            borderFrame:Show()
        else
            borderFrame:Hide()
        end
    end

    -- Text
    local generalFont = GetGeneralFont()
    local generalOutline = GetGeneralFontOutline()
    local showText = not hideText and (not isVertical or showTextOnVertical)

    if bar.NameText then
        bar.NameText:SetFont(generalFont, textSize, generalOutline)
        bar.NameText:SetAlpha(showText and 1 or 0)
    end
    if bar.DurationText then
        bar.DurationText:SetFont(generalFont, textSize, generalOutline)
        local durationBaseAlpha = showText and 1 or 0
        bar.DurationText:SetAlpha(durationBaseAlpha)
        -- Captured so the curve-driven text-hide path (UpdateOwnedBarAura
        -- durObj branch) and the alpha restore sites (inactive branch,
        -- ReleaseBar, _hideDurationText branch) all agree on the
        -- configured visibility — never override a "hide text" setting.
        bar._durationTextBaseAlpha = durationBaseAlpha
    end

    -- Apply frame alpha based on active state
    local targetAlpha = 1
    if not isActive then
        if inactiveMode == "fade" then
            targetAlpha = inactiveAlpha
        elseif inactiveMode == "hide" then
            targetAlpha = 0
        end
    end
    bar:SetAlpha(targetAlpha)
end

---------------------------------------------------------------------------
-- POOL MANAGEMENT
---------------------------------------------------------------------------
local function AcquireBar(parent)
    local bar
    if #recyclePool > 0 then
        bar = table.remove(recyclePool)
        bar:SetParent(parent)
    else
        bar = CreateBar(parent)
    end
    bar:Show()
    barPool[#barPool + 1] = bar
    return bar
end

local function ReleaseBar(bar)
    bar:Hide()
    bar:ClearAllPoints()
    bar._spellEntry = nil
    bar._spellID = nil
    bar._instanceKey = nil
    bar._active = false
    bar._cSideFill = nil
    bar._preferDurObjFill = nil
    bar._lastPosKey = nil
    bar._lastAnchor = nil
    bar._desiredTexture = nil
    bar._isTotemInstance = nil
    bar._totemSlot = nil
    bar._totemIconCache = nil
    bar._totemNameCache = nil
    bar._hideDurationText = nil
    bar._hasAuraExpirationTime = nil
    bar.NameText:SetText("")
    bar.DurationText:SetText("")
    bar.IconTexture:SetTexture(nil)
    bar.StatusBar:SetValue(0)
    if bar.PermanentFill then
        bar.PermanentFill:SetAlpha(0)
    end
    -- Restore configured base alpha (or default to 1 for never-configured
    -- bars) so the next ConfigureBar call doesn't have to fight a stale
    -- curve-driven 0 from a previous permanent state.
    bar.DurationText:SetAlpha(bar._durationTextBaseAlpha or 1)

    if #recyclePool < MAX_RECYCLE_POOL_SIZE then
        recyclePool[#recyclePool + 1] = bar
    end
end

function CDMBars:ClearPool()
    for i = #barPool, 1, -1 do
        ReleaseBar(barPool[i])
        barPool[i] = nil
    end
end

function CDMBars:GetActiveBars()
    return barPool
end

-- Aggressive reset: clear per-bar caches stamped during totem/aura
-- mirroring. Repopulated on the next bar update tick.
function CDMBars:ClearPerBarCaches()
    for i = 1, #barPool do
        local bar = barPool[i]
        if bar then
            bar._totemIconCache = nil
            bar._totemNameCache = nil
        end
    end
end

function CDMBars:GetCacheStats()
    return {
        activeBars = #barPool,
    }
end

---------------------------------------------------------------------------
-- BUILD BARS FROM OWNED SPELL LIST: Create bars from owned spell data.
-- All state (StatusBar fill, IconTexture, NameText, DurationText) is driven
-- by UpdateOwnedBarAura → CDMSpellData:ResolveAuraState (composer entries +
-- C_Spell + C_UnitAuras). Blizzard CDM viewer children are not consulted.
---------------------------------------------------------------------------
function CDMBars:BuildBarsFromOwned(container, spellList)
    if not container then return end
    if not spellList or #spellList == 0 then
        -- No owned spells — clear pool and return
        self:ClearPool()
        return
    end

    -- Check if we need to rebuild: compare spell count + IDs with current pool
    local needsRebuild = (#spellList ~= #barPool)
    if not needsRebuild then
        for i, bar in ipairs(barPool) do
            local entry = spellList[i]
            local entrySpellID = entry.overrideSpellID or entry.spellID or entry.id
            if not entry or bar._spellID ~= entrySpellID or bar._instanceKey ~= entry._instanceKey then
                needsRebuild = true
                break
            end
        end
    end

    -- Force rebuild if bars are parented to wrong frame
    if not needsRebuild and #barPool > 0 then
        local firstParent = barPool[1]:GetParent()
        if firstParent ~= container then
            needsRebuild = true
        end
    end

    -- No rebuild needed — refresh active state per bar via the resolver path.
    if not needsRebuild then
        for _, bar in ipairs(barPool) do
            if bar._isOwnedBar and bar._spellID then
                self:UpdateOwnedBarAura(bar)
            end
        end
        return
    end

    -- Clear existing pool
    self:ClearPool()

    -- Create owned bars for each spell entry
    for _, entry in ipairs(spellList) do
        local bar = AcquireBar(container)
        bar._spellEntry = entry
        bar._isOwnedBar = true
        bar._instanceKey = entry._instanceKey
        bar._isTotemInstance = entry._isTotemInstance and true or false
        bar._totemSlot = entry._totemSlot

        local spellID = entry.overrideSpellID or entry.spellID or entry.id
        bar._spellID = spellID

        -- Set initial texture from composer entry / direct C-side APIs.
        -- Totem-instance bars defer to UpdateOwnedBarAura's totemIcon path.
        if bar.IconTexture and spellID and not bar._isTotemInstance then
            local texID
            if entry.type == "item" or entry.type == "slot" then
                if entry.type == "slot" then
                    texID = GetInventoryItemTexture("player", entry.id)
                else
                    local _, _, _, _, icon = C_Item.GetItemInfoInstant(spellID)
                    texID = icon
                end
            elseif entry.type == "spell" then
                -- Cooldown bars use overrideSpellID for talent replacements.
                -- Aura bars keep their configured entry identity.
                local iconSid
                if entry.isAura then
                    iconSid = entry.overrideSpellID or entry.spellID or entry.id or spellID
                else
                    iconSid = entry.overrideSpellID or entry.id or spellID
                end
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(iconSid)
                texID = info and info.iconID
            end
            if texID then
                pcall(bar.IconTexture.SetTexture, bar.IconTexture, texID)
                bar._desiredTexture = texID
            end
        end

        -- Set initial name text from the composer entry. Talent rename for
        -- non-aura bars follows via UpdateOwnedBarAura's runtime override
        -- lookup. Totem-instance bars defer to UpdateOwnedBarAura's
        -- totemName path.
        if bar.NameText and not bar._isTotemInstance then
            local displayName = entry and entry.name
                or (ns.CDMSpellData and ns.CDMSpellData:ResolveDisplayName(entry))
            if displayName then
                bar.NameText:SetText(displayName)
            end
        end

        -- Update active state from aura data
        self:UpdateOwnedBarAura(bar)
    end
end

---------------------------------------------------------------------------
-- UPDATE OWNED BAR AURA: Delegates to shared CDMSpellData:ResolveAuraState()
-- and applies results to bar StatusBar fill / duration text / stacks.
---------------------------------------------------------------------------
-- Phase B.3: drive bar fill from item / trinket-slot cooldowns. Custom
-- auraBar containers accept item entries alongside spells; duration-bar
-- rendering needs its own path since ResolveAuraState is aura-only.
local function UpdateItemBarCooldown(bar, entry)
    local itemID
    if entry.type == "slot" or entry.type == "trinket" then
        itemID = GetInventoryItemID("player", entry.id)
    else
        itemID = entry.id
    end

    -- Texture refresh (trinket swap case)
    if bar.IconTexture and itemID then
        local ok, tex = pcall(C_Item.GetItemIconByID, itemID)
        if ok and tex then
            pcall(bar.IconTexture.SetTexture, bar.IconTexture, tex)
            bar._desiredTexture = tex
        end
    end

    -- Name
    if bar.NameText and itemID then
        local ok, n = pcall(C_Item.GetItemNameByID, itemID)
        if ok and n then pcall(bar.NameText.SetText, bar.NameText, n) end
    end

    -- Active-state detection: SpellScanner maps item → buff spellID; if
    -- the buff is up on the player, treat the item as active (filled bar
    -- from aura duration). Falls back to cooldown display otherwise.
    local scanner = _G.QUI and _G.QUI.SpellScanner
    local isActive, auraDur, auraRemaining
    if scanner and scanner.IsItemActive and itemID then
        local ok, active, expiration, duration = pcall(scanner.IsItemActive, itemID)
        local readableDuration = duration
        local readableExpiration = expiration
        if ok and active and readableDuration and readableDuration > 0 then
            isActive = true
            auraDur = readableDuration
            if readableExpiration then
                auraRemaining = readableExpiration - GetTime()
            end
        end
    end

    if isActive and auraRemaining and auraRemaining > 0 then
        bar._active = true
        bar._hideDurationText = nil
        bar._hasAuraExpirationTime = nil
        bar._totalDuration = auraDur
        bar._expirationTime = GetTime() + auraRemaining
        if bar.StatusBar then
            pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
            pcall(bar.StatusBar.SetValue, bar.StatusBar, auraRemaining / auraDur)
        end
        return
    end

    -- Cooldown display
    local startTime, duration
    if entry.type == "slot" or entry.type == "trinket" then
        if CDMCooldown and CDMCooldown.GetSlotCooldown then
            startTime, duration = CDMCooldown.GetSlotCooldown(entry.id)
        end
    elseif itemID and C_Item.GetItemCooldown then
        if CDMCooldown and CDMCooldown.GetItemCooldown then
            startTime, duration = CDMCooldown.GetItemCooldown(itemID)
        end
    end

    if startTime and duration
       and true
       and true
       and duration > 0 then
        local remaining = (startTime + duration) - GetTime()
        if remaining > 0 then
            bar._active = true
            bar._hideDurationText = nil
            bar._hasAuraExpirationTime = nil
            bar._totalDuration = duration
            bar._expirationTime = startTime + duration
            if bar.StatusBar then
                pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                pcall(bar.StatusBar.SetValue, bar.StatusBar, remaining / duration)
            end
            return
        end
    end

    -- Not active, not on cooldown
    bar._active = false
    bar._hideDurationText = nil
    bar._hasAuraExpirationTime = nil
    bar._totalDuration = nil
    bar._expirationTime = nil
    bar._preferDurObjFill = nil
    if bar.StatusBar then
        pcall(bar.StatusBar.SetValue, bar.StatusBar, 0)
    end
    if bar.DurationText then
        bar.DurationText:SetText("")
    end
end

function CDMBars:UpdateOwnedBarAura(bar)
    if not bar or not bar._spellID then return end
    local spellID = bar._spellID
    local entry = bar._spellEntry
    if not ns.CDMSpellData then return end

    -- Phase B.3: item / trinket-slot entries take the item cooldown path
    if entry and (entry.type == "item" or entry.type == "trinket" or entry.type == "slot") then
        UpdateItemBarCooldown(bar, entry)
        return
    end

    local Helpers = ns.Helpers

    local p = bar._auraParams or {}
    bar._auraParams = p
    p.spellID = spellID
    p.entrySpellID = entry and entry.spellID
    p.entryID = entry and entry.id
    p.entryName = entry and entry.name
    p.entryKind = entry and entry.kind
    p.entryIsAura = entry and ns.CDMSpellData.IsAuraEntry
        and ns.CDMSpellData.IsAuraEntry(entry, entry.viewerType)
    p.viewerType = entry and entry.viewerType
    p.totemSlot = bar._totemSlot
    p.disableLooseVisibilityFallback = true

    local r = ns.CDMSpellData:ResolveAuraState(p)

    local _bname = entry and entry.name

    if r.isActive then
        bar._active = true
        bar._auraDataUnit = r.auraUnit
        bar._hasAuraExpirationTime = r.hasExpirationTime
        bar._hideDurationText = ShouldHideAuraDurationText(r)

        -- Active-aura fallback: when the resolver returns no DurationObject
        -- AND auraData.duration is nil / secret / non-positive, treat it
        -- like permanent. The existing _hideDurationText branch then runs
        -- SetValue(1) and blanks the duration text. SafeToNumber collapses
        -- secret/nil/non-numeric inputs to 0 via the C-side issecretvalue
        -- check (which doesn't taint), so the comparison is on a plain
        -- non-secret 0 — no Lua compare against any secret value.
        if not bar._hideDurationText and not r.durObj and r.auraData then
            local readableDur = (r.auraData.duration or 0)
            if readableDur <= 0 then
                bar._hideDurationText = true
            end
        end

        if bar._hideDurationText then
            bar._durObj = nil
            bar._cSideFill = nil
            bar._preferDurObjFill = nil
            bar._lastDurationText = nil
            bar._lastDurationBucket = nil
            bar._totalDuration = nil
            bar._expirationTime = nil
            if bar.StatusBar then
                pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                pcall(bar.StatusBar.SetValue, bar.StatusBar, 1)
            end
            -- Explicit SetValue(1) handles the OOC-resolved permanent
            -- case; the curve-driven PermanentFill overlay is only for
            -- the in-combat case where we can't read the bool. Hide it
            -- here so we don't double-render full.
            if bar.PermanentFill then
                pcall(bar.PermanentFill.SetAlpha, bar.PermanentFill, 0)
            end
            if bar.DurationText then
                pcall(bar.DurationText.SetText, bar.DurationText, "")
                -- Restore the configured base alpha — never override a
                -- "hide text" setting (vertical bars without text, etc.).
                pcall(bar.DurationText.SetAlpha, bar.DurationText,
                    bar._durationTextBaseAlpha or 1)
            end
        end

        -- Cache readable duration/expiration from OOC auraData (for OnUpdate timer text)
        if r.auraData and not bar._hideDurationText then
            local rawDur = r.auraData.duration
            if rawDur and true and rawDur > 0 then
                bar._totalDuration = rawDur
            end
        end

        -- Bar fill via DurationObject
        local durObj = r.durObj
        if durObj and not bar._hideDurationText then
            local prevDurObj = bar._durObj
            bar._durObj = durObj
            local canUseTimerDuration = bar.StatusBar and bar.StatusBar.SetTimerDuration
            bar._preferDurObjFill = canUseTimerDuration and true or nil
            if bar._cSideFill then
                -- C-side SetTimerDuration is already driving the fill
                -- animation.  Re-calling it would restart the animation
                -- and cause visible flickering.  Detect aura refreshes
                -- by comparing the DurationObject reference (C userdata
                -- identity check — safe in combat, no secret values).
                if durObj ~= prevDurObj then
                    if canUseTimerDuration then
                        pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                        local ok = pcall(bar.StatusBar.SetTimerDuration, bar.StatusBar, durObj, nil, 1)
                        if not ok then
                            bar._preferDurObjFill = nil
                            bar._cSideFill = nil
                        end
                    end
                end
            elseif bar.StatusBar then
                pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                if canUseTimerDuration then
                    local ok = pcall(bar.StatusBar.SetTimerDuration, bar.StatusBar, durObj, nil, 1)
                    if ok then
                        bar._cSideFill = true
                    else
                        bar._preferDurObjFill = nil
                        bar._cSideFill = nil
                    end
                end
            end

            -- No-expiration overlay + text drive (curve trick via IsZero).
            -- See header doc above the helpers. IsZero is a stable
            -- per-aura property (not derived from elapsed/remaining),
            -- so timed auras like Metamorphosis don't briefly cross a
            -- threshold during animation and produce flicker.
            if durObj.IsZero
               and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
                local okZ, isZero = pcall(durObj.IsZero, durObj)
                if okZ then
                    -- Overlay alpha: permanent → 1 (visible), timed → 0.
                    if bar.PermanentFill then
                        local okA, alpha = pcall(C_CurveUtil.EvaluateColorValueFromBoolean,
                            isZero, 1, 0)
                        if okA then
                            pcall(bar.PermanentFill.SetAlpha, bar.PermanentFill, alpha)
                        end
                    end
                    -- Duration-text alpha: permanent → 0 (hidden), timed → 1.
                    -- Skip when the configured base alpha is 0 (hideText /
                    -- vertical-no-text settings) — the timed-aura output is
                    -- 1 (visible), which would otherwise override the
                    -- user's "hide text" choice.
                    if bar.DurationText and (bar._durationTextBaseAlpha or 1) ~= 0 then
                        local okT, textAlpha = pcall(C_CurveUtil.EvaluateColorValueFromBoolean,
                            isZero, 0, 1)
                        if okT then
                            pcall(bar.DurationText.SetAlpha, bar.DurationText, textAlpha)
                        end
                    end
                end
            end
        end

        -- Icon: totem instances use slot-bound display from ResolveAuraState's
        -- totemIcon payload. Other bars rely on the desired texture pinned in
        -- BuildBarsFromOwned plus auraData.icon as a runtime override (talent
        -- swaps, debuff overlays). Falls back to C_Spell.GetSpellTexture for
        -- aura entries whose buff icon differs from the entry's stored icon.
        if bar.IconTexture then
            if bar._isTotemInstance then
                if r.totemIcon ~= nil then
                    bar._totemIconCache = r.totemIcon
                end
                if bar._totemIconCache ~= nil then
                    pcall(bar.IconTexture.SetTexture, bar.IconTexture, bar._totemIconCache)
                end
            else
                local runtimeTex
                if r.auraData then
                    local aIcon = r.auraData.icon
                    if aIcon and aIcon ~= 0 then runtimeTex = aIcon end
                end
                if not runtimeTex and entry and entry.isAura
                    and C_Spell and C_Spell.GetSpellTexture then
                    local sid = entry.overrideSpellID or entry.spellID or entry.id
                    if sid then
                        local ok, tex = pcall(C_Spell.GetSpellTexture, sid)
                        if ok and tex then runtimeTex = tex end
                    end
                end
                if runtimeTex then
                    pcall(bar.IconTexture.SetTexture, bar.IconTexture, runtimeTex)
                elseif bar._desiredTexture ~= nil then
                    pcall(bar.IconTexture.SetTexture, bar.IconTexture, bar._desiredTexture)
                end
            end
        end

        -- Name + stacks text.  Display-count payloads are already formatted
        -- by C_UnitAuras, while auraData applications are numeric counts.
        -- Keep both paths in C-side helpers so secret values are forwarded
        -- without Lua concatenation.
        if bar.NameText then
            local name
            if bar._isTotemInstance then
                if r.totemName ~= nil then
                    bar._totemNameCache = r.totemName
                end
                name = bar._totemNameCache
            elseif entry and entry.isAura then
                name = entry.name or ns.CDMSpellData:ResolveDisplayName(entry)
            else
                name = ns.CDMSpellData:ResolveDisplayName(entry)
            end
            if name ~= nil then
                local stacks = ""
                local stackMethod = "none"
                local stackOk, stackText
                if r.stacks then
                    if r.stackSource == "display-count" then
                        stackMethod = "wrap-display-count"
                        stackOk, stackText = pcall(C_StringUtil.WrapString, r.stacks, " (", ")")
                    elseif type(r.stacks) == "number" then
                        stackMethod = "truncate-wrap-number"
                        stackOk, stackText = pcall(function()
                            return C_StringUtil.WrapString(
                                C_StringUtil.TruncateWhenZero(r.stacks), " (", ")")
                        end)
                    else
                        stackMethod = "wrap-text"
                        stackOk, stackText = pcall(C_StringUtil.WrapString, r.stacks, " (", ")")
                    end
                    stacks = stackOk and stackText or ""
                end
                local setOk, setErr = pcall(bar.NameText.SetFormattedText, bar.NameText, "%s%s", name, stacks)
                DebugBarLabel(entry, spellID,
                    "label",
                    "name=", tostring(name),
                    "stackNil=", tostring(r.stacks == nil),
                    "stackSecret=", tostring(false),
                    "stackSource=", tostring(r.stackSource),
                    "stackMethod=", stackMethod,
                    "stackOk=", tostring(stackOk),
                    "stackText=", tostring(stackText),
                    "setOk=", tostring(setOk),
                    "setErr=", setOk and "nil" or tostring(setErr))
            end
        end
    else
        bar._active = false
        bar._durObj = nil
        bar._cSideFill = nil
        bar._preferDurObjFill = nil
        bar._totalDuration = nil
        bar._expirationTime = nil
        bar._hideDurationText = nil
        bar._hasAuraExpirationTime = nil
        if not InCombatLockdown() then
            bar._resolvedAuraID = nil
        end
        if bar.StatusBar then
            pcall(bar.StatusBar.SetValue, bar.StatusBar, 0)
        end
        if bar.PermanentFill then
            pcall(bar.PermanentFill.SetAlpha, bar.PermanentFill, 0)
        end
        if bar.DurationText then
            bar.DurationText:SetText("")
            -- Restore the configured base alpha — never override a
            -- "hide text" setting (vertical bars without text, etc.).
            pcall(bar.DurationText.SetAlpha, bar.DurationText,
                bar._durationTextBaseAlpha or 1)
        end

        -- Always restore name via C-side SetText — no Lua string comparison
        -- (GetText returns a secret value in combat causing taint on ==).
        -- SetText deduplicates on the C side when text is unchanged.
        -- Skip for totem instances: each slot's per-totem name (e.g.
        -- "Dreadstalker" / "Charhound") is owned by the totem-icon path
        -- on the active branch; forcing entry.name ("Call Dreadstalkers")
        -- here would flicker the cached display.
        if bar.NameText and entry and entry.name and entry.name ~= ""
            and not bar._isTotemInstance then
            pcall(bar.NameText.SetText, bar.NameText, entry.name)
        end
    end
end

---------------------------------------------------------------------------
-- FORCE ALL ACTIVE: For Edit Mode, force all bars with names visible
-- so the mover overlay shows the full expected area.
---------------------------------------------------------------------------
function CDMBars:ForceAllActive()
    for _, bar in ipairs(barPool) do
        local name = bar.NameText and bar.NameText:GetText()
        if name and name ~= "" then
            bar._active = true
        end
    end
end

---------------------------------------------------------------------------
-- LAYOUT BARS: Pure math positioning, no Blizzard frame interaction.
-- Stacks bars vertically (default) or horizontally (vertical orientation).
---------------------------------------------------------------------------
function CDMBars:LayoutBars(container, settings)
    if not container then return end
    if not settings then return end

    local barHeight = settings.barHeight or 25
    local barWidth = settings.barWidth or 215

    local count = #barPool

    -- Even with 0 bars, set a minimum container size so the Edit Mode
    -- overlay is draggable and visible (not 1x1).
    if count == 0 then
        local orientation = settings.orientation or "horizontal"
        local w, h
        if orientation == "vertical" then
            w, h = barHeight, barWidth
        else
            w, h = barWidth, barHeight
        end
        ResizeContainer(container, w, h)
        return
    end

    local stylingEnabled = settings.enabled
    local spacing = settings.spacing or 2
    local growFromBottom = (settings.growUp ~= false)
    local orientation = settings.orientation or "horizontal"
    local isVertical = (orientation == "vertical")
    local inactiveMode = settings.inactiveMode or "hide"
    local reserveSlotWhenInactive = (settings.reserveSlotWhenInactive == true)

    -- For vertical bars, swap dimensions
    local effectiveBarWidth, effectiveBarHeight
    if isVertical then
        effectiveBarWidth = barHeight
        effectiveBarHeight = barWidth
    else
        effectiveBarWidth = barWidth
        effectiveBarHeight = barHeight
    end

    -- Apply HUD layer priority (skip during layout mode — the handle
    -- system owns strata/level while frames are reparented to movers).
    local layoutActive = Helpers.IsLayoutModeActive()
    local hudLayering = QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.hudLayering
    local layerPriority = hudLayering and hudLayering.buffBar or 5
    local frameLevel = 200
    if QUICore and QUICore.GetHUDFrameLevel then
        frameLevel = QUICore:GetHUDFrameLevel(layerPriority)
    end
    if not layoutActive then
        container:SetFrameStrata("MEDIUM")
        container:SetFrameLevel(frameLevel)
    end

    -- Configure and position each bar
    local editModeActive = Helpers.IsEditModeActive()
        or Helpers.IsLayoutModeActive()
        or (_G.QUI_IsCDMEditModeActive and _G.QUI_IsCDMEditModeActive())
    local visibleIndex = 0
    -- Build a lightweight config fingerprint so ConfigureBar is skipped
    -- when settings haven't changed between LayoutBars calls.
    local cfgFingerprint = (settings.barHeight or 0)
        + (barWidth or 0) * 7
        + (settings.borderSize or 0) * 97
        + (settings.textSize or 0) * 1009
        + ((settings.barOpacity or 1) * 10000)
        + ((settings.useClassColor and 1 or 0) * 100003)
    for _, bar in ipairs(barPool) do
        -- In edit/layout mode, force bar active BEFORE ConfigureBar so that
        -- inactive styling (alpha=0 for "hide" mode) doesn't apply.
        if editModeActive then
            bar._active = true
            if bar.StatusBar then
                pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                pcall(bar.StatusBar.SetValue, bar.StatusBar, 0.65)
            end
            if bar.DurationText then
                bar.DurationText:SetText("0:32")
            end
        end

        -- Apply styling (skip if settings unchanged and bar was already configured)
        if bar._cfgFingerprint ~= cfgFingerprint or bar._cfgActive ~= bar._active then
            bar._cfgFingerprint = cfgFingerprint
            bar._cfgActive = bar._active
            CDMBars.ConfigureBar(bar, settings, barWidth)
        end

        -- Apply strata/level (skip if already correct to avoid layout invalidation)
        if bar._lastFrameLevel ~= frameLevel then
            bar._lastFrameLevel = frameLevel
            bar:SetFrameStrata("MEDIUM")
            bar:SetFrameLevel(frameLevel)
            if bar.StatusBar then
                bar.StatusBar:SetFrameStrata("MEDIUM")
                bar.StatusBar:SetFrameLevel(frameLevel + 1)
            end
            if bar.TextOverlay then
                bar.TextOverlay:SetFrameStrata("MEDIUM")
                bar.TextOverlay:SetFrameLevel(frameLevel + 3)
            end
            if bar.IconContainer then
                bar.IconContainer:SetFrameStrata("MEDIUM")
                bar.IconContainer:SetFrameLevel(frameLevel + 1)
            end
        end

        -- Determine visibility using display mode for owned bars
        local shouldShow = true

        -- In edit/layout mode, force all bars visible (ignore visibility settings)
        if not editModeActive then
            local displayMode = settings.iconDisplayMode or "always"
            local effectiveDisplayMode = displayMode
            if effectiveDisplayMode == "combat" then
                effectiveDisplayMode = InCombatLockdown() and "always" or "active"
            end

            if effectiveDisplayMode == "active" then
                -- Active-only: only show bars with active auras/cooldowns
                if not bar._active then
                    shouldShow = false
                end
            elseif effectiveDisplayMode == "always" then
                -- Always mode: use existing inactiveMode for inactive bars
                if not bar._active then
                    if inactiveMode == "hide" and not reserveSlotWhenInactive then
                        shouldShow = false
                    end
                end
            else
                -- Fallback to existing behavior
                if not bar._active then
                    if inactiveMode == "hide" and not reserveSlotWhenInactive then
                        shouldShow = false
                    end
                end
            end
        end

        if shouldShow then
            local offsetIndex = visibleIndex

            -- Compute desired anchor point and offset, then skip
            -- ClearAllPoints+SetPoint when the bar is already there.
            -- Redundant point writes cause layout invalidation every tick,
            -- which is the primary visual source of bar flickering.
            local anchor, relAnchor, offsetX, offsetY
            if isVertical then
                if growFromBottom then
                    anchor, relAnchor = "LEFT", "LEFT"
                    offsetX = QUICore:PixelRound(offsetIndex * (effectiveBarWidth + spacing))
                    offsetY = 0
                else
                    anchor, relAnchor = "RIGHT", "RIGHT"
                    offsetX = QUICore:PixelRound(-offsetIndex * (effectiveBarWidth + spacing))
                    offsetY = 0
                end
            else
                if growFromBottom then
                    anchor, relAnchor = "BOTTOM", "BOTTOM"
                    offsetX = 0
                    offsetY = QUICore:PixelRound(offsetIndex * (effectiveBarHeight + spacing))
                else
                    anchor, relAnchor = "TOP", "TOP"
                    offsetX = 0
                    offsetY = QUICore:PixelRound(-offsetIndex * (effectiveBarHeight + spacing))
                end
            end

            local posKey = offsetIndex
            if bar._lastPosKey ~= posKey or bar._lastAnchor ~= anchor
                or not bar:IsShown() then
                bar._lastPosKey = posKey
                bar._lastAnchor = anchor
                bar:ClearAllPoints()
                bar:SetPoint(anchor, container, relAnchor, offsetX, offsetY)
            end

            bar:Show()
            visibleIndex = visibleIndex + 1
        else
            if bar:IsShown() then
                bar._lastPosKey = nil
                bar._lastAnchor = nil
                bar:Hide()
            end
        end
    end

    -- Set container size from calculated bounds
    local totalW, totalH
    if visibleIndex == 0 then
        -- All bars hidden by inactiveMode — use settings dimensions so
        -- the container (and Edit Mode overlay) stays a reasonable size.
        totalW = effectiveBarWidth
        totalH = effectiveBarHeight
    elseif isVertical then
        totalW = (visibleIndex * effectiveBarWidth) + ((visibleIndex - 1) * spacing)
        totalH = effectiveBarHeight
    else
        totalW = effectiveBarWidth
        totalH = (visibleIndex * effectiveBarHeight) + ((visibleIndex - 1) * spacing)
    end
    totalW = QUICore:PixelRound(totalW)
    totalH = QUICore:PixelRound(totalH)

    -- Must run in combat too: a bar going active mid-combat would
    -- otherwise leave the container frozen at the previous height,
    -- so frames anchored to its growth edge stop tracking. The combat
    -- branch defers SetSize one tick to escape inherited taint — see
    -- the DEFERRED RESIZE block at the top of the file.
    ResizeContainer(container, totalW, totalH)
end

---------------------------------------------------------------------------
-- REFRESH: Rebuild + re-layout (called from buffbar.lua)
---------------------------------------------------------------------------
function CDMBars:Refresh(container, settings, overrideWidth, containerKey)
    if not container then return end
    if not settings then return end

    -- Update barWidth if autoWidth provides an override
    if overrideWidth then
        settings = setmetatable({ barWidth = overrideWidth }, { __index = settings })
    end

    -- Store refs so the periodic ticker can re-layout after _active changes
    _lastContainer = container
    _lastSettings = settings

    -- All bars are sourced from the composer's owned-spells snapshot.
    if ns.CDMSpellData then
        local spellList = ns.CDMSpellData:GetSpellList(containerKey or "trackedBar")
        self:BuildBarsFromOwned(container, spellList)
    else
        self:ClearPool()
    end
    self:LayoutBars(container, settings)
end

---------------------------------------------------------------------------
-- UPDATE ALL OWNED BARS: Periodic aura poll for owned bars.
-- Called from the CDMIcons update ticker (piggybacks on existing 0.5s tick).
---------------------------------------------------------------------------
function CDMBars:UpdateOwnedBars()
    local anyChanged = false
    local anyActive = false
    for _, bar in ipairs(barPool) do
        if bar._isOwnedBar and bar._spellID then
            local wasPreviouslyActive = bar._active
            self:UpdateOwnedBarAura(bar)
            if bar._active ~= wasPreviouslyActive then
                anyChanged = true
            end
            if bar._active then anyActive = true end
        end
    end
    -- Ensure the bar timer is running when any bar is active.
    if anyActive and not barTimerGroup:IsPlaying() then
        barTimerGroup:Play()
    end
    -- Re-layout when any bar's active state changed so Show/Hide updates
    if anyChanged and _lastContainer and _lastSettings then
        self:LayoutBars(_lastContainer, _lastSettings)
    end
end

---------------------------------------------------------------------------
-- OWNED BAR TIMER: 100ms AnimationGroup loop for duration text + bar fill.
-- This loop is ONLY responsible for visual updates (text, fill).
-- Active-state management and layout are owned exclusively by
-- UpdateOwnedBars (called from the 250ms safety ticker + event debounce).
-- Keeping one owner for state+layout prevents the two systems from
-- competing and causing flickering.
---------------------------------------------------------------------------
barTimerGroup:SetScript("OnLoop", function()
    local Helpers = ns.Helpers
    local anyActive = false
    for _, bar in ipairs(barPool) do
        if bar._isOwnedBar and bar._active and bar:IsShown() then
            if bar._hideDurationText then
                anyActive = true
                bar._lastDurationText = nil
                bar._lastDurationBucket = nil
                if bar.DurationText then
                    pcall(bar.DurationText.SetText, bar.DurationText, "")
                end
                if bar.StatusBar then
                    pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                    pcall(bar.StatusBar.SetValue, bar.StatusBar, 1)
                end
            else
                local durObj = bar._durObj
                -- Guard: GetCooldownDuration can return 0 (a number) when inactive.
                -- Numbers must never be indexed, so only treat userdata/tables as DurationObjects.
                if durObj and type(durObj) == "number" then
                    bar._durObj = nil
                    durObj = nil
                end
                -- Gate on durObj presence (the userdata reference, NOT any
                -- value derived from it). GetRemainingDuration's return is a
                -- secret number in combat — never compare it (`~= nil`,
                -- `> 0`) or do arithmetic on it in Lua. Forward straight to
                -- C-side sinks. SetFormattedText accepts secret numbers and
                -- formats them on the C side. C-side SetTimerDuration drives
                -- the StatusBar fill independently of this loop. Expiration
                -- detection is handled by UpdateOwnedBars (event-driven), not
                -- by Lua-side comparison here.
                if durObj and durObj.GetRemainingDuration then
                    anyActive = true
                    local rok, remaining = pcall(durObj.GetRemainingDuration, durObj)
                    if rok and bar.DurationText and not bar._hideDurationText then
                        pcall(bar.DurationText.SetFormattedText, bar.DurationText, "%.1f", remaining)
                    end
                    -- StatusBar fill: when C-side SetTimerDuration is bound,
                    -- it owns the fill animation entirely. When it isn't,
                    -- pin the bar visibly active without inventing a Lua
                    -- fraction (any division would taint a secret value).
                    if not bar._cSideFill and bar.StatusBar then
                        pcall(bar.StatusBar.SetMinMaxValues, bar.StatusBar, 0, 1)
                        pcall(bar.StatusBar.SetValue, bar.StatusBar, 1)
                    end
                end
            end
        end
    end
    -- Stop the animation when no bars need ticking to avoid idle CPU cost.
    if not anyActive then
        barTimerGroup:Stop()
    end
end)

---------------------------------------------------------------------------
-- DEBUG: /cdmbardebug — toggle per-tick bar state dump.
-- Shows spellID, active state, DurationObject, fill mode — everything
-- needed to diagnose Roll the Bones etc. without any Blizzard CDM viewer
-- child reads.
---------------------------------------------------------------------------
SLASH_QUI_CDMBARDEBUG1 = "/cdmbardebug"
SlashCmdList["QUI_CDMBARDEBUG"] = function(msg)
    local filter = msg and strtrim(msg) or ""
    if filter == "" then
        _G.QUI_CDM_BAR_DEBUG = not _G.QUI_CDM_BAR_DEBUG
        print("|cff34D399[CDM-BarDebug]|r", _G.QUI_CDM_BAR_DEBUG and "ON (all bars)" or "OFF")
        return
    end
    _G.QUI_CDM_BAR_DEBUG = filter:lower()
    print("|cff34D399[CDM-BarDebug]|r ON — filter:", filter)
end

-- Inject debug print into UpdateOwnedBarAura (post-resolve)
local _origUpdateOwnedBarAura = CDMBars.UpdateOwnedBarAura
function CDMBars:UpdateOwnedBarAura(bar)
    _origUpdateOwnedBarAura(self, bar)

    local dbg = _G.QUI_CDM_BAR_DEBUG
    if not dbg then return end
    if not bar or not bar._spellEntry then return end
    local entry = bar._spellEntry
    local entryName = entry.name or "?"

    -- Filter check
    if type(dbg) == "string" then
        if not entryName:lower():find(dbg, 1, true)
           and tostring(bar._spellID) ~= dbg then
            return
        end
    end

    local P = "|cff34D399[CDM-BarDbg]|r"
    local Helpers = ns.Helpers
    print(P, entryName, "spellID=", bar._spellID, "entry.id=", entry.id,
          "entry.spellID=", entry.spellID, "entry.overrideSpellID=", entry.overrideSpellID)
    print(P, "  active=", bar._active, "cSideFill=", bar._cSideFill,
          "durObj=", bar._durObj and "yes" or "nil",
          "hideDuration=", tostring(bar._hideDurationText),
          "hasExpiration=", tostring(bar._hasAuraExpirationTime))
    print(P, "  isTotemInstance=", tostring(bar._isTotemInstance),
          "totemSlot=", tostring(bar._totemSlot),
          "instanceKey=", tostring(bar._instanceKey))
    if bar.NameText then
        local okName, curName = pcall(bar.NameText.GetText, bar.NameText)
        print(P, "  owned NameText=", okName and tostring(curName) or "err")
    end
    if bar.DurationText then
        local okDur, curDur = pcall(bar.DurationText.GetText, bar.DurationText)
        print(P, "  owned DurationText=", okDur and tostring(curDur) or "err")
    end
    if bar.IconTexture and bar.IconTexture.GetTexture then
        local okTex, tex = pcall(bar.IconTexture.GetTexture, bar.IconTexture)
        print(P, "  owned IconTexture=", okTex and tostring(tex) or "err")
    end
end
