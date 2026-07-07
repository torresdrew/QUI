local ADDON_NAME, ns = ...
local QUICore = ns.Addon
local LSM = ns.LSM
local Sources = ns.CDMSources

local GetCore = ns.Helpers.GetCore

-- Upvalue caching for hot-path performance
local type = type
local pcall = pcall
local ipairs = ipairs
local tostring = tostring
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local hooksecurefunc = hooksecurefunc
local _securecall = securecallfunction or function(fn, ...) return fn(...) end
local table_insert = table.insert

---------------------------------------------------------------------------
-- CDM Buff Layout
-- Owns buffIcon and buffBar viewer layout, styling, refresh, and bounds.
---------------------------------------------------------------------------

local CDMBuffLayout = {}
ns.CDMBuffLayout = CDMBuffLayout

---------------------------------------------------------------------------
-- ADDON_LOADED / PLAYER_ENTERING_WORLD safe window flag: during a combat
-- /reload, InCombatLockdown() returns true but protected calls are still
-- allowed inside the synchronous event handler body. Sub-functions
-- (anchor apply, dimension writes, HUD frame level) check this flag to
-- bypass their combat guards during the safe window.
---------------------------------------------------------------------------
local inInitSafeWindow = false

---------------------------------------------------------------------------
-- HELPER: Get font from general settings (uses shared helpers)
---------------------------------------------------------------------------
local Helpers = ns.Helpers

-- CDM VIEWER FRAME GETTERS (resolve via QUI-owned frame registry)
---------------------------------------------------------------------------
local function GetBuffIconViewer() return _G.QUI_GetCDMViewerFrame("buffIcon") end
local function GetBuffBarViewer() return _G.QUI_GetCDMViewerFrame("buffBar") end
local function GetEssentialViewer() return _G.QUI_GetCDMViewerFrame("essential") end
local function GetUtilityViewer() return _G.QUI_GetCDMViewerFrame("utility") end

---------------------------------------------------------------------------
-- UTILITY FUNCTIONS
---------------------------------------------------------------------------

local floor = math.floor

-- Pixel-snap with pre-computed pixel size (avoids per-call GetEffectiveScale in loops)
local function snapPx(value, px)
    if value == 0 then return 0 end
    return floor(value / px + 0.5) * px
end

-- TAINT SAFETY: Store viewer state in a local weak-keyed table instead of
-- writing custom properties to Blizzard CDM viewer frames.
local viewerBuffState = Helpers.CreateStateTable()  -- viewer → { anchorCache, originalPoints, onUpdateHooked, isHorizontal, goingRight, goingUp }

-- Tolerance-based position check: skip repositioning if within tolerance
-- Prevents jitter from floating-point drift
local abs = math.abs

-- Secret values report their real type() ("string"/"number"/"boolean"), so a
-- type check alone lets them through — and these readers feed sort comparators,
-- table keys, and QuerySpellInfo, where a secret throws on first compare.
-- Reject secrets up front; callers treat the fallback as "unavailable".
local WoW_IsSecretValue = issecretvalue

local function ReadNumber(value, fallback)
    if WoW_IsSecretValue and WoW_IsSecretValue(value) then return fallback end
    local valueType = type(value)
    if valueType == "number" then return value end
    if valueType == "string" then return tonumber(value) or fallback end
    return fallback
end

local function ReadString(value, fallback)
    if WoW_IsSecretValue and WoW_IsSecretValue(value) then return fallback end
    if type(value) == "string" then return value end
    return fallback
end

local function ReadBoolean(value, fallback)
    if WoW_IsSecretValue and WoW_IsSecretValue(value) then return fallback end
    if type(value) == "boolean" then return value end
    return fallback
end

local function PositionMatchesTolerance(icon, expectedX, tolerance)
    if not icon then return false end
    local point, _, _, xOfs = icon:GetPoint(1)
    if not point then return false end
    return abs((xOfs or 0) - expectedX) <= (tolerance or 2)
end

local VALID_ANCHOR_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function IsFrameVisiblyShown(frame)
    if not frame or not frame.IsShown or not frame:IsShown() then
        return false
    end
    local alpha = ReadNumber((frame.GetAlpha and frame:GetAlpha()) or 1, 1)
    if alpha <= 0.01 then
        return false
    end
    local width = ReadNumber(frame.GetWidth and frame:GetWidth(), 0)
    local height = ReadNumber(frame.GetHeight and frame:GetHeight(), 0)
    if width <= 1 or height <= 1 then
        return false
    end
    return true
end

local function GetFrameTopEdge(frame)
    if not frame then return nil end
    local top = ReadNumber(frame.GetTop and frame:GetTop(), nil)
    if type(top) == "number" then
        return top
    end
    local _, rawCenterY = frame.GetCenter and frame:GetCenter()
    local centerY = ReadNumber(rawCenterY, nil)
    local height = ReadNumber(frame.GetHeight and frame:GetHeight(), nil)
    if type(centerY) == "number" and type(height) == "number" then
        return centerY + (height / 2)
    end
    return nil
end

local function GetTopVisibleResourceBarFrame()
    -- Prefer the bounding-box proxy when available.  The proxy represents the
    -- combined outer rectangle of primary + secondary in their visible state
    -- (and shrinks to the visible bar when hidePrimaryOnSwap is active), so
    -- anchoring its TOP edge stays stable across swap toggles regardless of
    -- which bar is currently on top.
    if QUICore and QUICore.GetResourceBarsProxy then
        local proxy = QUICore:GetResourceBarsProxy()
        if proxy and IsFrameVisiblyShown(proxy) then
            -- Only use the proxy when at least one underlying bar is actually
            -- contributing to its bbox.  Otherwise fall through to the bar
            -- scan below (handles startup ordering edge cases).
            local hasPrimary = QUICore.powerBar and IsFrameVisiblyShown(QUICore.powerBar)
            local hasSecondary = QUICore.secondaryPowerBar and IsFrameVisiblyShown(QUICore.secondaryPowerBar)
            if hasPrimary or hasSecondary then
                return proxy
            end
        end
    end

    local candidates = {}
    if QUICore then
        if QUICore.powerBar then
            table_insert(candidates, QUICore.powerBar)
        end
        if QUICore.secondaryPowerBar then
            table_insert(candidates, QUICore.secondaryPowerBar)
        end
    end

    local bestFrame, bestTop
    for _, frame in ipairs(candidates) do
        if IsFrameVisiblyShown(frame) then
            local top = GetFrameTopEdge(frame)
            if type(top) == "number" and (not bestTop or top > bestTop) then
                bestTop = top
                bestFrame = frame
            end
        end
    end

    return bestFrame
end

local function ResolveTrackedBarAnchorFrame(anchorTo)
    if not anchorTo or anchorTo == "disabled" then
        return nil
    end
    if anchorTo == "screen" then
        return UIParent
    elseif anchorTo == "essential" then
        return GetEssentialViewer()
    elseif anchorTo == "utility" then
        return GetUtilityViewer()
    elseif anchorTo == "primary" then
        -- Swap-aware: when the resource bar swap mechanic is active, the
        -- frame at primary's natural slot is the secondary bar.  Routing
        -- through GetSwapAwareBarFor keeps user-anchored buff bars at the
        -- same visual position regardless of swap state.
        if QUICore and QUICore.GetSwapAwareBarFor then
            local f = QUICore:GetSwapAwareBarFor("primary")
            if f then return f end
        end
        return QUICore and QUICore.powerBar
    elseif anchorTo == "secondary" then
        if QUICore and QUICore.GetSwapAwareBarFor then
            local f = QUICore:GetSwapAwareBarFor("secondary")
            if f then return f end
        end
        return QUICore and QUICore.secondaryPowerBar
    elseif anchorTo == "playerFrame" then
        return _G.QUI_UnitFrames and _G.QUI_UnitFrames.player
    elseif anchorTo == "targetFrame" then
        return _G.QUI_UnitFrames and _G.QUI_UnitFrames.target
    end
    return nil
end

local function GetTrackedBarAnchorWidth(anchorTo, anchorFrame)
    if not anchorFrame then return nil end

    local width
    if anchorTo == "essential" or anchorTo == "utility" then
        local afvs = _G.QUI_GetCDMViewerState and _G.QUI_GetCDMViewerState(anchorFrame)
        width = (afvs and afvs.iconWidth) or (afvs and afvs.row1Width) or ReadNumber(anchorFrame:GetWidth())
    else
        width = ReadNumber(anchorFrame:GetWidth())
    end

    if type(width) ~= "number" or width <= 1 then
        return nil
    end
    return width
end

-- True when the viewer's cached anchor matches the requested anchor exactly,
-- meaning a re-anchor would be a no-op.  For absolute (UIParent) pins, px/py
-- capture the resolved target origin so that a MOVED target invalidates the
-- cache and triggers a re-pin on the next OnUpdate poll.  A 0.5-pixel
-- tolerance suppresses float-drift churn.  For relative anchors px/py are the
-- raw offsets and the tolerance comparison is exact (same effect as before).
local function anchorCacheMatches(cache, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py)
    if cache == nil then return false end
    if cache.anchorTo ~= anchorTo then return false end
    if cache.placement ~= placement then return false end
    if cache.anchorFrame ~= anchorFrame then return false end
    if cache.sourcePoint ~= sourcePoint then return false end
    if cache.targetPoint ~= targetPoint then return false end
    if abs((cache.px or 0) - (px or 0)) > 0.5 then return false end
    if abs((cache.py or 0) - (py or 0)) > 0.5 then return false end
    return true
end

-- Persist the applied anchor on the viewer's state so the next call can skip a
-- redundant SetPoint/pin. Only called when the anchor actually succeeded.
-- px, py: for absolute (UIParent) pins, the resolved pixel coords returned by
-- PinFrameToTargetAbsolute; for relative anchors, the raw offsetX/offsetY.
local function writeAnchorCache(viewer, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py)
    viewerBuffState[viewer] = viewerBuffState[viewer] or {}
    viewerBuffState[viewer].anchorCache = {
        anchorTo = anchorTo,
        placement = placement,
        anchorFrame = anchorFrame,
        sourcePoint = sourcePoint,
        targetPoint = targetPoint,
        px = px,
        py = py,
    }
end

local function ApplyTrackedBarAnchor(settings)
    local viewer = GetBuffBarViewer()
    if not viewer then return end
    -- Respect centralized frame anchoring overrides
    if _G.QUI_HasFrameAnchor and _G.QUI_HasFrameAnchor("buffBar") then return end
    -- No combat bail: positioning now pins the viewer to UIParent at absolute
    -- coords (Helpers.PinFrameToTargetAbsolute), reading the target's rect only.
    -- Both are combat-legal, so the OnUpdate poll can re-pin during combat and
    -- the viewer (UIParent-anchored, never anchoring-restricted) stays
    -- SetSize-able for in-combat flex.
    -- Don't reposition during Edit Mode — let the user drag/nudge freely.
    -- Blizzard's Edit Mode system handles position save/restore.
    if Helpers.IsEditModeActive() then return end

    local anchorTo = settings.anchorTo or "disabled"
    local sourcePoint = settings.anchorSourcePoint or "CENTER"
    local targetPoint = settings.anchorTargetPoint or sourcePoint
    local placement = settings.anchorPlacement or "center"
    local spacing = settings.anchorSpacing or 0
    local useTopResourceBars = placement == "onTopResourceBars"
    local spacingX, spacingY = 0, 0
    local offsetX = settings.anchorOffsetX or 0
    local offsetY = settings.anchorOffsetY or 0

    -- sourcePoint is set by the orientation/growth override below; the
    -- placement branches only configure targetPoint and spacing.
    if useTopResourceBars or placement == "onTop" then
        targetPoint = "TOP"
        spacingY = spacing
    elseif placement == "below" then
        targetPoint = "BOTTOM"
        spacingY = -spacing
    elseif placement == "left" then
        targetPoint = "LEFT"
        spacingX = -spacing
    elseif placement == "right" then
        targetPoint = "RIGHT"
        spacingX = spacing
    end

    -- The owned tracked-bar container uses explicit SetSize(), so the source
    -- anchor must match the growth direction. Otherwise WoW expands the frame
    -- from its anchored point (for example, CENTER would grow both ways).
    local orientation = settings.orientation or "horizontal"
    local growUp = settings.growUp ~= false
    if orientation == "vertical" then
        sourcePoint = growUp and "LEFT" or "RIGHT"
    else
        sourcePoint = growUp and "BOTTOM" or "TOP"
    end

    offsetX = QUICore:PixelRound(offsetX + spacingX, viewer)
    offsetY = QUICore:PixelRound(offsetY + spacingY, viewer)

    if not VALID_ANCHOR_POINTS[sourcePoint] then sourcePoint = "CENTER" end
    if not VALID_ANCHOR_POINTS[targetPoint] then targetPoint = sourcePoint end

    if anchorTo == "disabled" and not useTopResourceBars then
        local vbs = viewerBuffState[viewer]
        if vbs then vbs.anchorCache = nil end
        return
    end

    local anchorFrame = useTopResourceBars and GetTopVisibleResourceBarFrame() or ResolveTrackedBarAnchorFrame(anchorTo)
    if not anchorFrame and useTopResourceBars then
        -- Fallback to configured target when no visible resource bar is available.
        anchorFrame = ResolveTrackedBarAnchorFrame(anchorTo)
    end
    if not anchorFrame then return end
    if anchorFrame ~= UIParent and not anchorFrame:IsShown() then return end

    local vbs = viewerBuffState[viewer] or {}

    local ok, px, py
    if Helpers.FrameIsProtected(anchorFrame) or Helpers.FrameIsAnchoringRestricted(anchorFrame) then
        -- Protected target: pin to UIParent absolute so the viewer is never
        -- anchoring-restricted and SetSize flexes in combat.  The returned
        -- px,py encode the target's current origin so the cache detects when
        -- the target moves and re-pins on the next OnUpdate tick.
        ok, px, py = Helpers.PinFrameToTargetAbsolute(viewer, sourcePoint, anchorFrame, targetPoint, offsetX, offsetY)
        if ok and anchorCacheMatches(vbs.anchorCache, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py) then
            return
        end
    else
        -- Insecure target: relative anchoring is taint-safe and follows free.
        -- Cache keyed on the raw offsets (constant) — skip if unchanged.
        px, py = offsetX, offsetY
        if anchorCacheMatches(vbs.anchorCache, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py) then
            return
        end
        ok = pcall(function()
            viewer:ClearAllPoints()
            viewer:SetPoint(sourcePoint, anchorFrame, targetPoint, offsetX, offsetY)
        end)
    end

    -- Only write cache when the anchor succeeded — a held pin (target rect nil/
    -- secret) must not block the OnUpdate retry loop.
    if ok then
        writeAnchorCache(viewer, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py)
    end
end

local function ApplyBuffIconAnchor(settings)
    local viewer = GetBuffIconViewer()
    if not viewer then return end
    -- Respect centralized frame anchoring overrides
    if _G.QUI_HasFrameAnchor and _G.QUI_HasFrameAnchor("buffIcon") then return end
    -- No combat bail: positioning now pins the viewer to UIParent at absolute
    -- coords (Helpers.PinFrameToTargetAbsolute), reading the target's rect only.
    -- Both are combat-legal, so the OnUpdate poll can re-pin during combat and
    -- the viewer (UIParent-anchored, never anchoring-restricted) stays
    -- SetSize-able for in-combat flex.
    if Helpers.IsEditModeActive() then return end

    local anchorTo = settings.anchorTo or "disabled"
    local sourcePoint = settings.anchorSourcePoint or "CENTER"
    local targetPoint = settings.anchorTargetPoint or sourcePoint
    local placement = settings.anchorPlacement or "center"
    local spacing = settings.anchorSpacing or 0
    local spacingX, spacingY = 0, 0
    local offsetX = settings.anchorOffsetX or 0
    local offsetY = settings.anchorOffsetY or 0

    if placement == "onTop" then
        sourcePoint = "BOTTOM"
        targetPoint = "TOP"
        spacingY = spacing
    elseif placement == "below" then
        sourcePoint = "TOP"
        targetPoint = "BOTTOM"
        spacingY = -spacing
    elseif placement == "left" then
        sourcePoint = "RIGHT"
        targetPoint = "LEFT"
        spacingX = -spacing
    elseif placement == "right" then
        sourcePoint = "LEFT"
        targetPoint = "RIGHT"
        spacingX = spacing
    end
    -- center/manual: keep configured source/target points

    offsetX = QUICore:PixelRound(offsetX + spacingX, viewer)
    offsetY = QUICore:PixelRound(offsetY + spacingY, viewer)

    if not VALID_ANCHOR_POINTS[sourcePoint] then sourcePoint = "CENTER" end
    if not VALID_ANCHOR_POINTS[targetPoint] then targetPoint = sourcePoint end

    if anchorTo == "disabled" then
        local vbs = viewerBuffState[viewer] or {}
        local hadAnchor = vbs.anchorCache ~= nil
        local originalPoints = vbs.originalPoints
        if hadAnchor and originalPoints and #originalPoints > 0 then
            pcall(function()
                viewer:ClearAllPoints()
                for _, pointData in ipairs(originalPoints) do
                    viewer:SetPoint(
                        pointData.point,
                        pointData.relativeTo,
                        pointData.relativePoint,
                        pointData.xOfs,
                        pointData.yOfs
                    )
                end
            end)
        end
        if viewerBuffState[viewer] then
            viewerBuffState[viewer].anchorCache = nil
        end
        return
    end

    local anchorFrame = ResolveTrackedBarAnchorFrame(anchorTo)
    if not anchorFrame then return end
    if anchorFrame ~= UIParent and not anchorFrame:IsShown() then return end

    local vbs = viewerBuffState[viewer] or {}

    if not vbs.originalPoints then
        local originalPoints = {}
        local numPoints = viewer:GetNumPoints() or 0
        for i = 1, numPoints do
            local point, relativeTo, relativePoint, xOfs, yOfs = viewer:GetPoint(i)
            if point then
                originalPoints[#originalPoints + 1] = {
                    point = point,
                    relativeTo = relativeTo,
                    relativePoint = relativePoint,
                    xOfs = xOfs or 0,
                    yOfs = yOfs or 0,
                }
            end
        end
        viewerBuffState[viewer] = viewerBuffState[viewer] or {}
        viewerBuffState[viewer].originalPoints = originalPoints
    end

    local ok, px, py
    if Helpers.FrameIsProtected(anchorFrame) or Helpers.FrameIsAnchoringRestricted(anchorFrame) then
        -- Protected target: pin to UIParent absolute so the viewer is never
        -- anchoring-restricted and SetSize flexes in combat.  The returned
        -- px,py encode the target's current origin so the cache detects when
        -- the target moves and re-pins on the next OnUpdate tick.
        ok, px, py = Helpers.PinFrameToTargetAbsolute(viewer, sourcePoint, anchorFrame, targetPoint, offsetX, offsetY)
        if ok and anchorCacheMatches(vbs.anchorCache, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py) then
            return
        end
    else
        -- Insecure target: relative anchoring is taint-safe and follows free.
        -- Cache keyed on the raw offsets (constant) — skip if unchanged.
        px, py = offsetX, offsetY
        if anchorCacheMatches(vbs.anchorCache, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py) then
            return
        end
        ok = pcall(function()
            viewer:ClearAllPoints()
            viewer:SetPoint(sourcePoint, anchorFrame, targetPoint, offsetX, offsetY)
        end)
    end

    -- Only write cache when the anchor succeeded — a held pin (target rect nil/
    -- secret) must not block the OnUpdate retry loop.
    if ok then
        writeAnchorCache(viewer, anchorTo, placement, anchorFrame, sourcePoint, targetPoint, px, py)
    end
end

---------------------------------------------------------------------------
-- DATABASE ACCESS
---------------------------------------------------------------------------

-- DB accessor using shared helpers
local GetDB = Helpers.CreateDBGetter("ncdm")

local function GetBuffSettings()
    local db = GetDB()
    if db and db.buff then
        local buff = db.buff
        -- Migrate old 'shape' setting to new 'aspectRatioCrop'
        if buff.aspectRatioCrop == nil and buff.shape then
            if buff.shape == "rectangle" or buff.shape == "flat" then
                buff.aspectRatioCrop = 1.33  -- 4:3 aspect ratio
            else
                buff.aspectRatioCrop = 1.0  -- square
            end
        end
        return buff
    end
    -- Return defaults if no DB
    return {
        enabled = true,
        iconSize = 42,
        borderSize = 2,
        aspectRatioCrop = 1.0,
        zoom = 0,
        padding = 0,
        opacity = 1.0,
        anchorTo = "disabled",
        anchorPlacement = "center",
        anchorSpacing = 0,
        anchorSourcePoint = "CENTER",
        anchorTargetPoint = "CENTER",
        anchorOffsetX = 0,
        anchorOffsetY = 0,
    }
end

local function GetTrackedBarSettings()
    local db = GetDB()
    if db and db.trackedBar then
        if db.trackedBar.colorOverrides == nil then
            db.trackedBar.colorOverrides = {}
        end
        return db.trackedBar
    end
    -- Return defaults if no DB
    return {
        enabled = true,
        barHeight = 25,
        barWidth = 215,
        texture = "Quazii v5",
        useClassColor = true,
        barColor = {0.376, 0.647, 0.980, 1},
        barOpacity = 1.0,
        borderSize = 2,
        bgColor = {0, 0, 0, 1},
        bgOpacity = 0.5,
        textSize = 14,
        spacing = 2,
        growUp = true,
        hideText = false,
        inactiveMode = "hide",
        inactiveAlpha = 0.3,
        desaturateInactive = false,
        reserveSlotWhenInactive = false,
        autoWidth = false,
        autoWidthOffset = 0,
        anchorTo = "disabled",
        anchorPlacement = "center",
        anchorSpacing = 0,
        anchorSourcePoint = "CENTER",
        anchorTargetPoint = "CENTER",
        anchorOffsetX = 0,
        anchorOffsetY = 0,
        -- Vertical bar settings
        orientation = "horizontal",
        fillDirection = "up",
        iconPosition = "top",
        showTextOnVertical = false,
        colorOverrides = {},
    }
end

local function GetTrackedBarSourceViewer()
    -- Blizzard's BuffBarCooldownViewer is the data source. The QUI-owned
    -- viewer is only the render target, and using it as the scanner source
    -- feeds our own bars back into the model instead of mirroring native CDM.
    return _G["BuffBarCooldownViewer"] or GetBuffBarViewer()
end

local function GetTrackedBarName(frame)
    -- Blizzard's bar StatusBar exposes its FontStrings via parentKey
    -- (CooldownViewer.xml: Name / Duration) — read the Name key directly
    -- instead of scanning regions and inspecting text to guess which one is
    -- the name. The result feeds IDENTITY (QuerySpellInfo rescue, sort keys),
    -- so secret text (combat) is useless here: ReadString rejects it and the
    -- bar keeps its cooldownID/spellID identity; display names resolve from
    -- spell data instead.
    local region = frame and frame.Name
    if not region or not region.GetText then return nil end
    local okText, rawText = pcall(region.GetText, region)
    if not okText then return nil end
    local text = ReadString(rawText, nil)
    if text == "" then return nil end
    return text
end

local function GetTrackedBarSpellData(frame)
    if not frame then return nil end

    local resolvedSpellID, baseSpellID, overrideSpellID, name
    local cdInfo = frame.cooldownInfo
    if cdInfo then
        overrideSpellID = ReadNumber(cdInfo.overrideSpellID, nil)
        baseSpellID = ReadNumber(cdInfo.spellID, nil)
        name = ReadString(cdInfo.name, nil)
        resolvedSpellID = overrideSpellID or baseSpellID
    end

    if (not resolvedSpellID or not name) and frame.cooldownID then
        local apiInfo = ns.CDMCatalog and ns.CDMCatalog.GetCooldownInfo
            and ns.CDMCatalog.GetCooldownInfo(frame.cooldownID)
        if apiInfo then
            overrideSpellID = overrideSpellID or ReadNumber(apiInfo.overrideSpellID, nil)
            baseSpellID = baseSpellID or ReadNumber(apiInfo.spellID, nil)
            name = name or ReadString(apiInfo.name, nil)
            resolvedSpellID = resolvedSpellID or overrideSpellID or baseSpellID
        end
    end

    if not name then
        name = GetTrackedBarName(frame) or GetTrackedBarName(frame.Bar)
    end

    if not resolvedSpellID and name then
        local spellInfo = Sources and Sources.QuerySpellInfo and Sources.QuerySpellInfo(name)
        if spellInfo and spellInfo.spellID then
            baseSpellID = baseSpellID or spellInfo.spellID
            resolvedSpellID = resolvedSpellID or spellInfo.spellID
        end
    end

    if not name and resolvedSpellID then
        local spellInfo = Sources and Sources.QuerySpellInfo and Sources.QuerySpellInfo(resolvedSpellID)
        if spellInfo and spellInfo.name then
            name = spellInfo.name
        end
    end

    if not resolvedSpellID and not name and not frame.cooldownID then
        return nil
    end

    return {
        spellID = resolvedSpellID,
        baseSpellID = baseSpellID or resolvedSpellID,
        overrideSpellID = overrideSpellID,
        name = name,
        cooldownID = frame.cooldownID,
    }
end

local function GetTrackedBarIconTexture(frame, spellData)
    if not frame then return nil end
    local iconContainer = frame.Icon
    local iconTexture = iconContainer and (iconContainer.Icon or iconContainer.icon or iconContainer.texture)
    if iconTexture and iconTexture.GetTexture then
        -- GetTexture returns a secret number in combat (aura-driven icon).
        -- The result feeds identity-adjacent consumers and the ~= compares
        -- below throw on secrets — reject and fall back to the spellID icon.
        local okTex, rawTexture = pcall(iconTexture.GetTexture, iconTexture)
        local texture = okTex and rawTexture or nil
        if WoW_IsSecretValue and WoW_IsSecretValue(texture) then texture = nil end
        if texture and texture ~= 0 and texture ~= "" then
            return texture
        end
    end

    local spellID = spellData and (spellData.overrideSpellID or spellData.spellID or spellData.baseSpellID)
    if spellID then
        local info = Sources and Sources.QuerySpellInfo and Sources.QuerySpellInfo(spellID)
        if info and info.iconID then
            return info.iconID
        end
    end

    return nil
end

local function IsTrackedBarActive(frame)
    if not frame or not frame.IsShown then return false end
    local okShown, shown = pcall(frame.IsShown, frame)
    return okShown and shown or false
end

local function GetTrackedBarRuntimeEntries()
    local viewer = GetTrackedBarSourceViewer()
    if not viewer then return {} end

    local entries = {}
    local selection = viewer.Selection
    -- Use Frame:GetNumChildren() (C-side, no closure) instead of
    -- pcall(function() return select('#', viewer:GetChildren()) end).
    local okN, numChildren = pcall(viewer.GetNumChildren, viewer)
    if not okN or not numChildren or numChildren == 0 then
        return entries
    end

    for ci = 1, numChildren do
        local child = select(ci, viewer:GetChildren())
        if child and child ~= selection and child.IsObjectType and child:IsObjectType("Frame")
            and child.Bar and child.Bar.IsObjectType and child.Bar:IsObjectType("StatusBar")
            and (child.cooldownID or child.layoutIndex) then
            local spellData = GetTrackedBarSpellData(child)
            if spellData then
                entries[#entries + 1] = {
                    spellID = spellData.spellID,
                    baseSpellID = spellData.baseSpellID,
                    overrideSpellID = spellData.overrideSpellID,
                    name = spellData.name or "",
                    iconTexture = GetTrackedBarIconTexture(child, spellData),
                    cooldownID = spellData.cooldownID,
                    layoutIndex = child.layoutIndex or 9999,
                    isActive = IsTrackedBarActive(child),
                    -- Live Blizzard child ref: the renderer mirrors fill/timer
                    -- straight off this frame (secret-safe widget passthrough)
                    -- instead of resolving duration data in Lua. Runtime-only —
                    -- never persisted, excluded from the fingerprint.
                    frame = child,
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        local layoutA = a.layoutIndex or 9999
        local layoutB = b.layoutIndex or 9999
        if layoutA ~= layoutB then
            return layoutA < layoutB
        end
        local nameA = tostring(a.name or "")
        local nameB = tostring(b.name or "")
        if nameA ~= nameB then
            return nameA < nameB
        end
        return (a.spellID or 0) < (b.spellID or 0)
    end)

    return entries
end

local trackedBarRuntimeFingerprint = ""
local trackedBarRuntimeNotifyPending = false

local function BuildTrackedBarRuntimeFingerprint(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return ""
    end

    local parts = {}
    for i, entry in ipairs(entries) do
        parts[i] = table.concat({
            tostring(entry.layoutIndex or 9999),
            tostring(entry.spellID or 0),
            tostring(entry.baseSpellID or 0),
            tostring(entry.overrideSpellID or 0),
            tostring(entry.cooldownID or 0),
        }, ":")
    end
    return table.concat(parts, ",")
end

local function NotifyTrackedBarRuntimeChanged(force)
    local callback = _G.QUI_RefreshTrackedBarColorOverrideList
    if type(callback) ~= "function" then
        return
    end

    local entries = GetTrackedBarRuntimeEntries()
    local fingerprint = BuildTrackedBarRuntimeFingerprint(entries)
    if not force and fingerprint == trackedBarRuntimeFingerprint then
        return
    end
    trackedBarRuntimeFingerprint = fingerprint

    if trackedBarRuntimeNotifyPending then
        return
    end
    trackedBarRuntimeNotifyPending = true

    C_Timer.After(0, function()
        trackedBarRuntimeNotifyPending = false
        local refreshCallback = _G.QUI_RefreshTrackedBarColorOverrideList
        if type(refreshCallback) == "function" then
            pcall(refreshCallback)
        end
    end)
end

---------------------------------------------------------------------------
-- FORWARD DECLARATIONS
---------------------------------------------------------------------------

local LayoutBuffIcons
local LayoutBuffBars

---------------------------------------------------------------------------
-- RE-ENTRY GUARDS: Prevent recursive layout calls
---------------------------------------------------------------------------

local isIconLayoutRunning = false
local isBarLayoutRunning = false

---------------------------------------------------------------------------
-- ARCHITECTURE NOTES:
-- - Hash-based change detection: only layout when count OR settings change
-- - Direct centering: immediate layout on count change (no debounce)
-- - 0.05s polling rate (20 FPS) matches proven stable implementations
-- - Per-icon OnShow hooks REMOVED - they caused cascade during rapid changes
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- LAYOUT SUPPRESSION: Prevents recursive layout calls from our own SetSize()
---------------------------------------------------------------------------

local layoutSuppressed = 0

local function IsLayoutSuppressed()
    return layoutSuppressed > 0
end

local trackedBarReadyFrame
local trackedBarReadyQueued = false
local barViewerLayoutHooked = false
local InstallBarViewerLayoutHook

local function IsCooldownViewerReady()
    local catalog = ns.CDMCatalog
    if catalog and catalog.IsCooldownViewerReady then
        return catalog.IsCooldownViewerReady()
    end

    local api = _G.C_CooldownViewer
    if not api then return false end
    if not api.IsCooldownViewerAvailable then return true end
    local ok, ready = pcall(api.IsCooldownViewerAvailable)
    return ok and ready == true
end

local function QueueTrackedBarLayoutWhenReady()
    if trackedBarReadyQueued then return end
    trackedBarReadyQueued = true

    if not CreateFrame then return end
    if not trackedBarReadyFrame then
        trackedBarReadyFrame = CreateFrame("Frame")
    end

    trackedBarReadyFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    trackedBarReadyFrame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
        self:SetScript("OnEvent", nil)
        trackedBarReadyQueued = false
        local ready = IsCooldownViewerReady()
        if not ready then return end
        if InstallBarViewerLayoutHook then InstallBarViewerLayoutHook() end
        if LayoutBuffBars then LayoutBuffBars() end
    end)
end

InstallBarViewerLayoutHook = function()
    if barViewerLayoutHooked then return end
    if not IsCooldownViewerReady() then
        QueueTrackedBarLayoutWhenReady()
        return
    end

    local blizzBarViewer = _G["BuffBarCooldownViewer"]
    if blizzBarViewer and blizzBarViewer.Layout then
        local function onBarViewerLayout()
            if InCombatLockdown() then return end
            C_Timer.After(0.1, function()
                if isBarLayoutRunning then return end
                LayoutBuffBars()
            end)
        end
        hooksecurefunc(blizzBarViewer, "Layout", function(...) _securecall(onBarViewerLayout, ...) end)
        barViewerLayoutHooked = true
    end
end

---------------------------------------------------------------------------
-- ICON FRAME COLLECTION
---------------------------------------------------------------------------

local function GetBuffIconFrames()
    local pool = ns.CDMIconFactory and ns.CDMIconFactory:GetIconPool("buff")
    if not pool or #pool == 0 then return {} end

    local visible = {}
    for _, icon in ipairs(pool) do
        if icon:IsShown() and icon:GetAlpha() > 0 then
            visible[#visible + 1] = icon
        end
    end

    table.sort(visible, function(a, b)
        local aIdx = (a._spellEntry and a._spellEntry.layoutIndex) or 0
        local bIdx = (b._spellEntry and b._spellEntry.layoutIndex) or 0
        return aIdx < bIdx
    end)

    return visible
end

-- HELPER: Apply icon size, aspect ratio, border, and perfect square fix
---------------------------------------------------------------------------

local function ApplyIconStyle(icon, settings)
    if not icon then return end

    local rowConfig = {
        size = settings.iconSize or 42,
        borderSize = settings.borderSize or 2,
        borderColorSource = settings.borderColorSource,
        borderColor = settings.borderColor or settings.borderColorTable or {0, 0, 0, 1},
        aspectRatioCrop = settings.aspectRatioCrop or 1.0,
        zoom = settings.zoom or 0,
        durationSize = settings.durationSize or 14,
        durationOffsetX = settings.durationOffsetX or 0,
        durationOffsetY = settings.durationOffsetY or 8,
        durationTextColor = settings.durationTextColor or {1, 1, 1, 1},
        durationAnchor = settings.durationAnchor or "TOP",
        stackSize = settings.stackSize or 14,
        stackOffsetX = settings.stackOffsetX or 0,
        stackOffsetY = settings.stackOffsetY or -8,
        stackTextColor = settings.stackTextColor or {1, 1, 1, 1},
        stackAnchor = settings.stackAnchor or "BOTTOM",
        opacity = settings.opacity or 1.0,
        -- Opt-in shield/absorb amount at the bottom edge (buff icons only).
        showAbsorbAmount = settings.showAbsorbAmount or false,
    }
    if ns.CDMIcons and ns.CDMIcons.OnIconRowConfigApplied then
        ns.CDMIcons.OnIconRowConfigApplied(icon, rowConfig)
    end
    local swipeMod = QUI and QUI.CooldownSwipe
    if swipeMod and swipeMod.ApplyToIcon then
        swipeMod.ApplyToIcon(icon)
    end
    if icon.GetScale and icon:GetScale() ~= 1 then
        icon:SetScale(1)
    end
end

---------------------------------------------------------------------------
-- ICON CENTER MANAGER (PARENT-SYNCHRONIZED & STABILIZED)
---------------------------------------------------------------------------

LayoutBuffIcons = function()
    local viewer = GetBuffIconViewer()
    if not viewer then return end
    if isIconLayoutRunning then return end  -- Re-entry guard
    if IsLayoutSuppressed() then return end

    isIconLayoutRunning = true

    local settings = GetBuffSettings()
    if not settings.enabled then
        isIconLayoutRunning = false
        return
    end

    -- Optional anchoring to CDM/resource/unitframe targets.
    ApplyBuffIconAnchor(settings)

    -- Apply HUD layer priority (protected on secure frames — skip in combat).
    -- Exception: during the ADDON_LOADED / PEW safe window, protected calls
    -- are allowed even though InCombatLockdown() reports true on /reload.
    if (not InCombatLockdown()) or inInitSafeWindow then
        local core = GetCore()
        local hudLayering = core and core.db and core.db.profile and core.db.profile.hudLayering
        local layerPriority = hudLayering and hudLayering.buffIcon or 5
        if core and core.GetHUDFrameLevel then
            local frameLevel = core:GetHUDFrameLevel(layerPriority)
            viewer:SetFrameLevel(frameLevel)
        end
    end

    -- Get settings
    local iconSize = settings.iconSize or 42
    local padding = settings.padding or 0
    local aspectRatio = settings.aspectRatioCrop or 1.0
    local growthDirection = settings.growthDirection or "CENTERED_HORIZONTAL"

    -- Calculate dimensions using crop-based aspect ratio
    local iconWidth, iconHeight = iconSize, iconSize
    if aspectRatio > 1.0 then
        -- Wider: height shrinks
        iconHeight = iconSize / aspectRatio
    elseif aspectRatio < 1.0 then
        -- Taller: width shrinks
        iconWidth = iconSize * aspectRatio
    end

    local icons = GetBuffIconFrames()
    local currentCount = #icons

    -- Empty state: size container to one icon so the anchored edge's
    -- midpoint stays fixed across populated ↔ empty transitions.
    -- BUT when the re-anchor engine owns the buff surface it positions chrome SHELLS
    -- (not owned icons), so GetBuffIconFrames() is always empty here -- resizing the
    -- SHARED container to one icon would stomp the re-anchor's RefreshBuiltin size
    -- (the container is containers["buff"], read by both paths + the layout-mode mover).
    -- Leave sizing to the re-anchor; only the legacy owned-icon path resizes.
    if currentCount == 0 then
        if not ns._cdmBoot then
            viewer:SetSize(iconWidth, iconHeight)
            if _G.QUI_SetCDMViewerBounds then
                _G.QUI_SetCDMViewerBounds(viewer, iconWidth, iconHeight)
            end
        end
        isIconLayoutRunning = false
        return
    end

    local targetCount = currentCount

    -- Determine if vertical or horizontal layout
    local isVertical = (growthDirection == "UP" or growthDirection == "DOWN")

    -- Cache pixel size once for the layout pass (avoids repeated GetEffectiveScale in loops)
    local px = QUICore:GetPixelSize()

    -- Calculate total size using our settings
    local totalWidth, totalHeight
    if isVertical then
        totalWidth = iconWidth
        totalHeight = (targetCount * iconHeight) + ((targetCount - 1) * padding)
        totalHeight = snapPx(totalHeight, px)
    else
        totalWidth = (targetCount * iconWidth) + ((targetCount - 1) * padding)
        totalWidth = snapPx(totalWidth, px)
        totalHeight = iconHeight
    end

    -- Calculate starting position — icons anchor at CENTER of viewer.
    -- This keeps icons stable regardless of Blizzard's auto-sized viewer height
    -- (same approach as Essential/Utility viewers).
    local startX, startY
    if isVertical then
        startX = 0
        if growthDirection == "UP" then
            -- Grow up: icon 1 at bottom of stack, icons stack upward
            startY = -(totalHeight / 2) + iconHeight / 2
        else -- DOWN
            -- Grow down: icon 1 at top of stack, icons stack downward
            startY = (totalHeight / 2) - iconHeight / 2
        end
        startY = snapPx(startY, px)
    else
        -- Horizontal: centered both ways
        startX = -totalWidth / 2 + iconWidth / 2
        startX = snapPx(startX, px)
        startY = 0
    end

    -- Tolerance-based check: skip repositioning if all icons are already in correct positions
    -- Prevents jitter from floating-point drift (allows 2px tolerance)
    local needsReposition = false
    for i, icon in ipairs(icons) do
        if isVertical then
            local expectedY
            if growthDirection == "UP" then
                expectedY = snapPx(startY + (i - 1) * (iconHeight + padding), px)
            else -- DOWN
                expectedY = snapPx(startY - (i - 1) * (iconHeight + padding), px)
            end
            local point, _, _, xOfs, yOfs = icon:GetPoint(1)
            if not point or point ~= "CENTER" or abs((yOfs or 0) - expectedY) > 2 then
                needsReposition = true
                break
            end
        else
            local expectedX = snapPx(startX + (i - 1) * (iconWidth + padding), px)
            if not PositionMatchesTolerance(icon, expectedX, 2) then
                needsReposition = true
                break
            end
        end
    end

    if needsReposition then
        -- TWO-PASS LAYOUT: Clear all points first, then position - prevents mixed state flicker
        -- PASS 1: Clear all points first
        for _, icon in ipairs(icons) do
            icon:ClearAllPoints()
        end

        -- PASS 2: Apply style and position each icon
        for i, icon in ipairs(icons) do
            ApplyIconStyle(icon, settings)
            if isVertical then
                local y
                if growthDirection == "UP" then
                    y = startY + (i - 1) * (iconHeight + padding)
                else -- DOWN
                    y = startY - (i - 1) * (iconHeight + padding)
                end
                icon:SetPoint("CENTER", viewer, "CENTER", 0, snapPx(y, px))
            else
                local x = startX + (i - 1) * (iconWidth + padding)
                icon:SetPoint("CENTER", viewer, "CENTER", snapPx(x, px), snapPx(startY, px))
            end
        end
    else
        -- Positions are correct, just apply styling (skip SetPoint calls)
        for _, icon in ipairs(icons) do
            ApplyIconStyle(icon, settings)
        end
    end

    -- Owned containers need explicit sizing (Blizzard viewers auto-size from children).
    viewer:SetSize(totalWidth, totalHeight)

    -- Write calculated dimensions to viewer state so the proxy sizeResolver
    -- (CDMSizeResolver) reads our formula dimensions instead of falling back
    -- to Blizzard's auto-sized frame dimensions.
    if _G.QUI_SetCDMViewerBounds then
        _G.QUI_SetCDMViewerBounds(viewer, totalWidth, totalHeight)
    end

    -- Suppress Blizzard's dirty flag so its Layout() doesn't override our
    -- icon positioning on the next frame. Our SetPoint/SetSize calls above
    -- mark the viewer dirty; clearing it prevents the built-in OnUpdate from
    -- re-running Blizzard's default layout and stomping our grid.
    if viewer.MarkClean then
        viewer:MarkClean()
    end

    isIconLayoutRunning = false
end

---------------------------------------------------------------------------
-- BAR ALIGNMENT MANAGER
---------------------------------------------------------------------------

LayoutBuffBars = function()
    local viewer = GetBuffBarViewer()
    if not viewer then return end
    -- Tracked bars intentionally use addon-owned StatusBars. Blizzard's
    -- BuffBarCooldownViewer remains a data source only; the suppressor may
    -- park the viewer shell offscreen out of combat, but the re-anchor runtime
    -- never decorates or relocates its live bar child frames.
    if isBarLayoutRunning then return end

    isBarLayoutRunning = true
    local settings = GetTrackedBarSettings()
    if not IsCooldownViewerReady() then
        QueueTrackedBarLayoutWhenReady()
        isBarLayoutRunning = false
        return
    end
    if not settings.enabled then
        if ns.CDMBlizzardBuffBarSuppressor then
            ns.CDMBlizzardBuffBarSuppressor:Apply(settings)
        end
        NotifyTrackedBarRuntimeChanged()
        isBarLayoutRunning = false
        return
    end

    ApplyTrackedBarAnchor(settings)

    local resolvedBarWidth = settings.barWidth or 215
    local anchorTo = settings.anchorTo or "disabled"
    local placement = settings.anchorPlacement or "center"
    local canAutoWidth = settings.autoWidth and (anchorTo ~= "screen")
    if canAutoWidth then
        local anchorFrame
        local widthAnchorType = anchorTo
        if placement == "onTopResourceBars" then
            anchorFrame = GetTopVisibleResourceBarFrame()
            widthAnchorType = nil
        else
            anchorFrame = ResolveTrackedBarAnchorFrame(anchorTo)
        end
        if not anchorFrame and placement == "onTopResourceBars" then
            anchorFrame = ResolveTrackedBarAnchorFrame(anchorTo)
            widthAnchorType = anchorTo
        end
        if anchorFrame and anchorFrame:IsShown() then
            local anchorWidth = GetTrackedBarAnchorWidth(widthAnchorType, anchorFrame)
            if anchorWidth then
                local adjust = settings.autoWidthOffset or 0
                resolvedBarWidth = math.max(20, QUICore:PixelRound(anchorWidth + adjust, viewer))
            end
        end
    end

    local CDMBars = ns.CDMBars
    if CDMBars then
        local runtimeEntries = GetTrackedBarRuntimeEntries()
        CDMBars:Refresh(viewer, settings, resolvedBarWidth, "trackedBar", runtimeEntries)
    end

    if ns.CDMBlizzardBuffBarSuppressor then
        ns.CDMBlizzardBuffBarSuppressor:Apply(settings)
    end

    NotifyTrackedBarRuntimeChanged()
    isBarLayoutRunning = false
end

-- CHANGE DETECTION (called from OnUpdate hooks on viewers)
-- Icons: Hash-based detection for count/settings changes
---------------------------------------------------------------------------

-- Last-seen icon count + settings, compared field-by-field so the poll
-- doesn't allocate a hash string per tick. count = -1 is the invalidation
-- sentinel: it can never match a real count, forcing the next check to
-- see a change.
local lastIconState = { count = -1 }

local ICON_STATE_FIELDS = {
    { "iconSize", 42 },
    { "padding", 0 },
    { "aspectRatioCrop", 1.0 },
    { "borderSize", 2 },
    { "growthDirection", "CENTERED_HORIZONTAL" },
    { "anchorTo", "disabled" },
    { "anchorPlacement", "center" },
    { "anchorSpacing", 0 },
    { "anchorSourcePoint", "CENTER" },
    { "anchorTargetPoint", "CENTER" },
    { "anchorOffsetX", 0 },
    { "anchorOffsetY", 0 },
}

local function InvalidateIconState()
    lastIconState.count = -1
end

-- Returns true (and records the new state) when the icon count or any
-- tracked setting changed since the last call. Zero allocations.
local function UpdateIconState(count, settings)
    local changed = lastIconState.count ~= count
    lastIconState.count = count
    for i = 1, #ICON_STATE_FIELDS do
        local field = ICON_STATE_FIELDS[i]
        local key = field[1]
        local value = settings[key]
        if value == nil then value = field[2] end
        if lastIconState[key] ~= value then
            lastIconState[key] = value
            changed = true
        end
    end
    return changed
end

local function CheckIconChanges()
    local viewer = GetBuffIconViewer()
    if not viewer then return end
    if isIconLayoutRunning then return end
    if IsLayoutSuppressed() then return end
    -- Skip during Edit Mode — Blizzard controls icon layout/padding.
    if Helpers.IsEditModeActive() then return end

    -- Count visible icons
    local visibleCount = 0
    local inCombat = InCombatLockdown()
    local pool = ns.CDMIconFactory and ns.CDMIconFactory:GetIconPool("buff")
    if pool then
        for _, icon in ipairs(pool) do
            if inCombat then
                if ReadBoolean(icon:IsShown(), false) and ReadNumber(icon:GetAlpha(), 1) > 0 then
                    visibleCount = visibleCount + 1
                end
            else
                if icon:IsShown() and icon:GetAlpha() > 0 then visibleCount = visibleCount + 1 end
            end
        end
    end

    -- Anchor stays per-check: it is self-caching and doubles as the re-pin /
    -- retry loop for protected anchor targets (see ApplyBuffIconAnchor).
    local settings = GetBuffSettings()
    ApplyBuffIconAnchor(settings)

    -- Only layout if the count or a tracked setting changed
    if not UpdateIconState(visibleCount, settings) then
        return
    end

    LayoutBuffIcons()
end

-- OnUpdate handlers for buff icon/bar viewers (module-level to avoid
-- per-hook closure allocation).  Elapsed accumulators live at module scope
-- instead of being captured upvalues inside anonymous closures.
---------------------------------------------------------------------------
local buffIconOnUpdateElapsed = 0
local buffIconScanElapsed = 0

local function BuffIconViewer_OnUpdate(self, elapsed)
    buffIconOnUpdateElapsed = buffIconOnUpdateElapsed + elapsed
    buffIconScanElapsed = buffIconScanElapsed + elapsed
    if buffIconOnUpdateElapsed > 0.1 then  -- 10 FPS polling (was 20 FPS)
        buffIconOnUpdateElapsed = 0
        -- Suppress Blizzard's dirty flag at this cadence. Previously ran
        -- every frame; moving inside the throttle reduces calls from
        -- 60+/sec to ~10/sec with no visible layout glitches.
        if self.MarkClean then self:MarkClean() end
    end
    -- The pool scan + change detection is a fallback — UNIT_AURA events
    -- drive icon changes immediately via the coalesce frame — so it runs
    -- at a relaxed cadence. It also re-pins protected anchor targets, for
    -- which 0.25s remains visually immediate.
    if buffIconScanElapsed > 0.25 then
        buffIconScanElapsed = 0
        if self:IsShown() then
            CheckIconChanges()
        end
    end
end

-- FORCE POPULATE: Briefly trigger Edit Mode behavior to load all spells
-- This ensures the buff icons know what spells to display on first load
---------------------------------------------------------------------------

local forcePopulateDone = false

local function ForcePopulateBuffIcons()
    if forcePopulateDone then return end
    forcePopulateDone = true
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------

local initialized = false

local function Initialize()
    if initialized then return end
    initialized = true

    -- ADDON_LOADED safe window: protected calls are allowed inside this
    -- synchronous handler body even though InCombatLockdown() returns true
    -- during a combat /reload. Set both the module-local flag and the
    -- shared namespace flag so the central anchoring system cooperates.
    inInitSafeWindow = true
    ns._inInitSafeWindow = true

    -- CRITICAL: Set layout direction IMMEDIATELY at login, before combat can start
    -- This prevents Blizzard's Layout() from using wrong axis if first buff appears during combat
    -- TAINT SAFETY: Store in local table instead of writing to Blizzard viewer
    local barViewer = GetBuffBarViewer()
    if barViewer then
        local settings = GetTrackedBarSettings()
        local isVertical = (settings.orientation == "vertical")
        local growFromBottom = (settings.growUp ~= false)

        viewerBuffState[barViewer] = viewerBuffState[barViewer] or {}
        local vbs = viewerBuffState[barViewer]
        vbs.isHorizontal = not isVertical
        if isVertical then
            vbs.goingRight = growFromBottom
            vbs.goingUp = false
        else
            vbs.goingRight = true
            vbs.goingUp = growFromBottom
        end
    end

    -- Force populate buff icons first (teaches the viewer what spells to show)
    ForcePopulateBuffIcons()

    -- TAINT SAFETY: OnUpdate hooks use module-level elapsed tracking instead of
    -- writing properties to Blizzard CDM viewer frames, to avoid tainting the
    -- frame table. Handlers are module-level named functions so no closure is
    -- allocated per HookScript call.
    -- OnUpdate polling at 0.05s (20 FPS) - works alongside UNIT_AURA event detection
    local iconViewer = GetBuffIconViewer()
    local iconVbs = iconViewer and (viewerBuffState[iconViewer] or {})
    if iconViewer then viewerBuffState[iconViewer] = iconVbs end
    if iconViewer and not iconVbs.onUpdateHooked then
        iconVbs.onUpdateHooked = true
        iconViewer:HookScript("OnUpdate", BuffIconViewer_OnUpdate)
    end

    ---------------------------------------------------------------------------
    -- EVENT-BASED UPDATES: UNIT_AURA hook for immediate buff change detection
    -- (Replaces polling as primary detection - polling becomes fallback only)
    ---------------------------------------------------------------------------

    -- TAINT SAFETY: Use local variables instead of writing to Blizzard CDM viewer frames.
    local lastAuraIconCount = 0  -- Track visible icon count for change detection
    -- INSTALL UNCONDITIONALLY. ADDON_LOADED handlers fire in registration (TOC)
    -- order: this module registers BEFORE cdm_containers, so the provider engine
    -- is not initialized yet and GetBuffIconViewer() returns nil here on EVERY
    -- boot. Gating this install on the init-time viewer silently skipped the
    -- whole repair net for the session -- the only aura-change trigger the
    -- re-anchor engine has when Blizzard's items are cold-boot stale (their
    -- OnActiveStateChanged never fires). The coalesce handler and the
    -- subscriber both re-fetch the viewer per-event, so nothing below depends
    -- on it existing now.
    do
        -- Frame-show coalescing: Show() is a no-op if already shown,
        -- so rapid UNIT_AURA events within the same render frame are
        -- automatically batched into a single OnUpdate flush.
        local iconAuraCoalesce = CreateFrame("Frame")
        iconAuraCoalesce:Hide()
        iconAuraCoalesce:SetScript("OnUpdate", function(self)
            self:Hide()
            local iv2 = GetBuffIconViewer()
            if not iv2 or not iv2:IsShown() then return end
            if isIconLayoutRunning then return end
            if IsLayoutSuppressed() then return end

            -- RE-ANCHOR REPAIR NET: under the re-anchor engine the owned-icon
            -- pool is empty (matched buff entries are direct-anchored native
            -- Blizzard frames) and LayoutBuffIcons early-returns, so both legacy
            -- paths below are blind -- one lost OnActiveStateChanged left the
            -- buff surface stuck until unrelated churn. Route the coalesced
            -- player-aura change into the hooks' throttled re-claim instead
            -- (MarkDirty -> 0.05s Flush -> RefreshBuiltin("buff")).
            if ns._cdmBoot and ns._cdmReanchorHooks then
                ns._cdmReanchorHooks:MarkDirty("buff")
                return
            end

            -- COMBAT STABILITY: During combat, only force hash
            -- reset when icon count actually changed (buff gained
            -- or lost). This prevents relayout from UNIT_AURA spam
            -- when only aura properties (stacks, duration) changed
            -- but icon positions don't need to move.
            if InCombatLockdown() then
                local currentCount = 0
                local pool = ns.CDMIconFactory and ns.CDMIconFactory:GetIconPool("buff")
                if pool then
                    for _, icon in ipairs(pool) do
                        if ReadBoolean(icon:IsShown(), false) and ReadNumber(icon:GetAlpha(), 1) > 0 then
                            currentCount = currentCount + 1
                        end
                    end
                end
                if currentCount == lastAuraIconCount then
                    return  -- Count unchanged — skip relayout
                end
                lastAuraIconCount = currentCount
            end

            InvalidateIconState()
            CheckIconChanges()
        end)

        -- Subscribe to centralized aura dispatcher (player only)
        if ns.AuraEvents then
            ns.AuraEvents:Subscribe("player", function(unit, updateInfo)
                local iv = GetBuffIconViewer()
                if iv and iv:IsShown() then
                    iconAuraCoalesce:Show()
                end
            end)
        end
    end

    -- Hook Blizzard's BuffBarCooldownViewer Layout only after the data provider
    -- is ready. First-login native-frame hooks before COOLDOWN_VIEWER_DATA_LOADED
    -- can taint Blizzard's secret aura tables.
    InstallBarViewerLayoutHook()
    -- Also rebuild bars on UNIT_AURA (tracked buffs can appear/disappear)
    local barAuraCoalesce = CreateFrame("Frame")
    barAuraCoalesce:Hide()
    barAuraCoalesce:SetScript("OnUpdate", function(self)
        self:Hide()
        if isBarLayoutRunning then return end
        LayoutBuffBars()
    end)
    -- Subscribe to centralized aura dispatcher for bar layout (player only)
    if ns.AuraEvents then
        ns.AuraEvents:Subscribe("player", function(unit, updateInfo)
            local bv = _G["BuffBarCooldownViewer"]
            if bv and bv:IsShown() then
                barAuraCoalesce:Show()
            end
        end)
    end

    -- Initial layouts — run synchronously inside the ADDON_LOADED safe window.
    -- Deferring via C_Timer.After pushes this past the safe window boundary;
    -- on a combat /reload ApplyBuffIconAnchor / ApplyTrackedBarAnchor would
    -- then bail on InCombatLockdown() and the viewer would stay un-positioned.
    LayoutBuffIcons()
    LayoutBuffBars()

    -- Close the safe window — subsequent C_Timer callbacks and event handlers
    -- run outside the ADDON_LOADED handler and must respect combat lockdown.
    inInitSafeWindow = false
    ns._inInitSafeWindow = false
end

---------------------------------------------------------------------------
-- EVENT HANDLING
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
        Initialize()
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin, isReloadingUi = ...
        if isInitialLogin or isReloadingUi then
            -- PEW fires inside the safe window on combat /reload — protected
            -- calls are allowed even though InCombatLockdown() returns true.
            -- Run the initial layout synchronously here so the viewer is
            -- positioned before the safe window closes.
            inInitSafeWindow = true
            ns._inInitSafeWindow = true
            ForcePopulateBuffIcons()
            do
                local viewer = GetBuffIconViewer()
                if viewer and viewerBuffState[viewer] then
                    viewerBuffState[viewer].anchorCache = nil
                end
            end
            LayoutBuffIcons()
            LayoutBuffBars()
            inInitSafeWindow = false
            ns._inInitSafeWindow = false

            -- Deferred second pass: Blizzard viewer children may populate
            -- after PEW (first login or cinematic). These run outside the
            -- safe window and respect combat lockdown; they're recovery,
            -- not the primary path.
            C_Timer.After(1.5, function()
                ForcePopulateBuffIcons()
                local viewer = GetBuffIconViewer()
                if viewer and viewerBuffState[viewer] then
                    viewerBuffState[viewer].anchorCache = nil
                end
                LayoutBuffIcons()
                LayoutBuffBars()
            end)
            C_Timer.After(3.5, function()
                if InCombatLockdown() then return end
                local viewer = GetBuffIconViewer()
                if viewer and viewerBuffState[viewer] then
                    viewerBuffState[viewer].anchorCache = nil
                end
                LayoutBuffIcons()
            end)
        end
    end
end)

local function SetupDebugInstrumentation()
    ns.QUI_PerfRegistry = ns.QUI_PerfRegistry or {}
    ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "CDMBuffLayout", frame = eventFrame }
end
if ns.DebugRegister then -- gate contract: core/debug_gate.lua
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation() -- standalone test harness: no gate, run eagerly
end

---------------------------------------------------------------------------
-- OWNED ENGINE API
---------------------------------------------------------------------------
function CDMBuffLayout.OnContainerReady()
    -- Container was just created; re-initialize if we haven't yet
    if not initialized then
        Initialize()
    else
        -- Already initialized but hooks may be missing — set them up now
        local iconViewer = GetBuffIconViewer()
        if iconViewer then
            local iconVbs = viewerBuffState[iconViewer] or {}
            viewerBuffState[iconViewer] = iconVbs
            if not iconVbs.onUpdateHooked then
                iconVbs.onUpdateHooked = true
                iconViewer:HookScript("OnUpdate", BuffIconViewer_OnUpdate)
            end
            if not iconVbs.onShowHooked then
                iconVbs.onShowHooked = true
                iconViewer:HookScript("OnShow", function(self)
                    C_Timer.After(0, function()
                        if InCombatLockdown() then return end
                        if IsLayoutSuppressed() then return end
                        if isIconLayoutRunning then return end
                        LayoutBuffIcons()
                    end)
                end)
            end
            -- Invalidate anchor cache — the container was just created and
            -- any prior ApplyBuffIconAnchor may have failed (viewer didn't
            -- exist yet) or positioned a stale frame.
            iconVbs.anchorCache = nil

            -- Force initial layout on the new container
            ForcePopulateBuffIcons()
            C_Timer.After(0.3, LayoutBuffIcons)
        end
    end
end

function CDMBuffLayout.OnLayoutReady()
    -- Icons were (re)built in the owned container; position + style them
    InvalidateIconState()
    LayoutBuffIcons()
end

-- Also try to initialize immediately if viewers exist
C_Timer.After(0, function()
    if GetBuffIconViewer() or GetBuffBarViewer() then
        Initialize()
    end
end)

---------------------------------------------------------------------------
-- EDIT MODE CALLBACKS: Re-apply QUI icon size / padding on exit
---------------------------------------------------------------------------

do
    local core = GetCore()
    if core and core.RegisterEditModeExit then
        core:RegisterEditModeExit(function()
            -- Reset icon state so the next CheckIconChanges() triggers a full re-layout
            InvalidateIconState()

            -- Invalidate the anchor cache so ApplyBuffIconAnchor re-applies
            -- the saved anchor settings.  Edit Mode may have moved the
            -- container via SyncContainerToBlizzard or drag.
            local viewer = GetBuffIconViewer()
            if viewer and viewerBuffState[viewer] then
                viewerBuffState[viewer].anchorCache = nil
            end

            -- Deferred: Blizzard may still be tearing down Edit Mode on this frame
            C_Timer.After(0.1, function()
                if InCombatLockdown() then return end
                LayoutBuffIcons()
                LayoutBuffBars()
            end)
        end)
    end
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

CDMBuffLayout.LayoutIcons = LayoutBuffIcons
CDMBuffLayout.LayoutBars = LayoutBuffBars
CDMBuffLayout.Initialize = Initialize
CDMBuffLayout.GetTrackedBarRuntimeEntries = GetTrackedBarRuntimeEntries

-- Force refresh function (can be called from GUI)
function CDMBuffLayout.Refresh()
    -- Reset states to force recalculation
    InvalidateIconState()  -- Force change detection to fire for icons

    -- Update layout direction when settings change (e.g., orientation toggle)
    -- Must be done outside combat to take effect
    -- TAINT SAFETY: Store in local table instead of writing to Blizzard viewer
    local barViewer = GetBuffBarViewer()
    if barViewer then
        local settings = GetTrackedBarSettings()
        local isVertical = (settings.orientation == "vertical")
        local growFromBottom = (settings.growUp ~= false)

        viewerBuffState[barViewer] = viewerBuffState[barViewer] or {}
        local vbs = viewerBuffState[barViewer]
        vbs.isHorizontal = not isVertical
        if isVertical then
            vbs.goingRight = growFromBottom
            vbs.goingUp = false
        else
            vbs.goingRight = true
            vbs.goingUp = growFromBottom
        end
    end

    LayoutBuffIcons()
    LayoutBuffBars()
end

-- Global refresh function for GUI
_G.QUI_RefreshCDMBuffLayout = CDMBuffLayout.Refresh

if ns.Registry then
    ns.Registry:Register("cdmBuffLayout", {
        refresh = _G.QUI_RefreshCDMBuffLayout,
        priority = 20,
        group = "cooldowns",
        importCategories = { "cdm" },
    })
end
