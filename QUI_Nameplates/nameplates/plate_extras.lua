--[[
    QUI Nameplates — extras: zone/role context, threat state, quest cache,
    target/focus highlight, raid markers, mouseover highlight, execute
    overlay, hitbox visualizer.

    Perf contract highlights:
    * target/focus changes are O(1): the previous plate is cached, the new
      one resolves via GetNamePlateForUnit — never a registry scan.
    * mouseover runs a 0.1s ticker ONLY while a plate is hovered.
    * execute range never compares health: the threshold is encoded in a
      step curve and UnitHealthPercent's (possibly secret) result drives the
      overlay through SetAlpha, a secret-accepting C-side sink.
    * the zone/role context refreshes on PEW/zone/spec/role events — never
      per plate.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local UIKit = ns.UIKit
local QUICore = ns.Addon

local type = type
local pcall = pcall
local wipe = wipe
local CreateFrame = CreateFrame
local UnitThreatSituation = UnitThreatSituation
local IsInInstance = IsInInstance
local UnitIsUnit = UnitIsUnit
local GetRaidTargetIndex = GetRaidTargetIndex
local UnitHealthPercent = UnitHealthPercent

local NPExtras = {}
NP.Extras = NPExtras

local RAID_MARKER_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

---------------------------------------------------------------------------
-- ZONE / ROLE CONTEXT (cached; consumed by the color resolver)
---------------------------------------------------------------------------
local context = {
    role = "DAMAGER",       -- player's assigned role
    inInstance = false,     -- party/raid/scenario instance
    instanceKind = "world", -- world | dungeon | raid (per-context aura enables)
}
NPExtras.context = context

function NPExtras.GetContext()
    return context
end

local function RefreshContext()
    local ok, inInstance, instanceType = pcall(IsInInstance)
    inInstance = ok and NP.Plain(inInstance, "boolean") or false
    instanceType = ok and NP.Plain(instanceType, "string") or nil
    if inInstance then
        if instanceType == "raid" then
            context.inInstance = true
            context.instanceKind = "raid"
        elseif instanceType == "party" or instanceType == "scenario" then
            context.inInstance = true
            context.instanceKind = "dungeon"
        else
            context.inInstance = false
            context.instanceKind = "world"
        end
    else
        context.inInstance = false
        context.instanceKind = "world"
    end

    local role
    if UnitGroupRolesAssigned then
        local okRole, r = pcall(UnitGroupRolesAssigned, "player")
        r = okRole and NP.Plain(r, "string") or nil
        if r and r ~= "NONE" then role = r end
    end
    if not role and GetSpecialization and GetSpecializationRole then
        local okSpec, spec = pcall(GetSpecialization)
        spec = okSpec and NP.Plain(spec, "number") or nil
        if spec then
            local okR, r = pcall(GetSpecializationRole, spec)
            role = okR and NP.Plain(r, "string") or nil
        end
    end
    context.role = role or "DAMAGER"
end
NPExtras.RefreshContext = RefreshContext

---------------------------------------------------------------------------
-- THREAT (per plate, event-driven from the driver)
---------------------------------------------------------------------------
-- Maps UnitThreatSituation to the resolver's plain enum. Secret/unavailable
-- readings leave npThreat nil (resolver skips the threat branch).
function NPExtras.UpdateThreat(plate)
    local unit = plate.unit
    if not unit then return end
    local ok, situation = pcall(UnitThreatSituation, "player", unit)
    situation = ok and NP.Plain(situation, "number") or nil
    if not situation then
        plate.npThreat = nil
        return
    end
    if situation >= 2 then
        plate.npThreat = "high"      -- tanking (securely or not)
    elseif situation == 1 then
        plate.npThreat = "near"      -- higher threat than tank / overnuking
    else
        plate.npThreat = "low"
    end
end

---------------------------------------------------------------------------
-- QUEST DETECTION (tooltip line scan; cached per token)
---------------------------------------------------------------------------
-- C_TooltipInfo.GetUnit line text is a tainted-secret hazard in combat: ALL
-- leftText reads stay inside pcall. Results are cached per unit token and
-- the cache is invalidated (debounced) on QUEST_LOG_UPDATE.
local questCache = {}   -- [unitToken] = true | false
local questCacheDirty = false

local function ScanQuestLines(unit)
    if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then return false end
    local okData, data = pcall(C_TooltipInfo.GetUnit, unit)
    if not okData or type(data) ~= "table" or type(data.lines) ~= "table" then
        return false
    end
    local playerName = UnitName and UnitName("player") or nil
    for i = 1, #data.lines do
        local line = data.lines[i]
        if type(line) == "table" then
            -- line.type: 8 = QuestObjective, 17 = QuestTitle (Enum.TooltipDataLineType)
            local lineType = NP.Plain(line.type, "number")
            if lineType == 8 or lineType == 17 then
                return true
            end
            -- Fallback heuristic for objective lines without a typed marker:
            -- "<n>/<m>" or "<n>%" progress patterns.
            local okText, isQuest = pcall(function()
                local text = line.leftText
                if type(text) ~= "string" then return false end
                if playerName and text == playerName then return false end
                return text:find("%d+/%d+") ~= nil or text:find("%d+%%") ~= nil
            end)
            if okText and isQuest == true then
                return true
            end
        end
    end
    return false
end

function NPExtras.IsQuestUnit(unit)
    if not unit then return false end
    local cached = questCache[unit]
    if cached ~= nil then return cached end
    local isQuest = ScanQuestLines(unit) == true
    questCache[unit] = isQuest
    return isQuest
end

function NPExtras.InvalidateQuestCache(unit)
    if unit then
        questCache[unit] = nil
    else
        wipe(questCache)
    end
end

---------------------------------------------------------------------------
-- EXECUTE OVERLAY (threshold encoded in a step curve — no comparison)
---------------------------------------------------------------------------
local executeCurve, executeCurveThreshold

local function GetExecuteCurve(thresholdPct)
    if executeCurve and executeCurveThreshold == thresholdPct then
        return executeCurve
    end
    if not (C_CurveUtil and C_CurveUtil.CreateCurve and Enum and Enum.LuaCurveType) then
        return nil
    end
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, 1)                       -- below threshold → overlay on
    curve:AddPoint((thresholdPct or 35) / 100, 0) -- at/above → off
    executeCurve, executeCurveThreshold = curve, thresholdPct
    return curve
end

function NPExtras.UpdateExecute(plate)
    local overlay = plate.npExecuteOverlay
    if not overlay then return end
    local unit = plate.unit
    local settings = NP.GetSettings()
    local colors = settings.colors or {}
    if not unit or colors.executeEnabled ~= true or type(UnitHealthPercent) ~= "function" then
        overlay:SetAlpha(0)
        return
    end
    local curve = GetExecuteCurve(colors.executeThreshold or 35)
    if not curve then
        overlay:SetAlpha(0)
        return
    end
    -- The (possibly secret) curve result flows straight into SetAlpha.
    local ok, alpha = pcall(UnitHealthPercent, unit, nil, curve)
    if ok and alpha ~= nil then
        pcall(overlay.SetAlpha, overlay, alpha)
    else
        overlay:SetAlpha(0)
    end
end

---------------------------------------------------------------------------
-- PER-PLATE WIDGETS (built once per pooled frame)
---------------------------------------------------------------------------
function NPExtras.BuildPlate(plate)
    -- Raid marker
    local marker = plate:CreateTexture(nil, "OVERLAY", nil, 5)
    marker:SetTexture(RAID_MARKER_TEXTURE)
    marker:Hide()
    plate.npRaidMarker = marker

    -- Target glow: additive wash behind the health bar (EUI's signature
    -- treatment translated into QUI primitives).
    local glow = plate:CreateTexture(nil, "BACKGROUND", nil, -7)
    glow:SetTexture("Interface\\Buttons\\WHITE8x8")
    glow:SetBlendMode("ADD")
    glow:Hide()
    plate.npTargetGlow = glow

    -- Mouseover highlight: white wash over the health bar.
    local hover = plate.healthBar:CreateTexture(nil, "ARTWORK", nil, 3)
    hover:SetAllPoints(plate.healthBar)
    hover:SetColorTexture(1, 1, 1, 1)
    hover:SetAlpha(0)
    plate.npHoverHighlight = hover

    -- Execute overlay: colored wash whose alpha is curve-driven.
    local execute = plate.healthBar:CreateTexture(nil, "ARTWORK", nil, 2)
    execute:SetAllPoints(plate.healthBar)
    execute:SetAlpha(0)
    plate.npExecuteOverlay = execute

    -- Hitbox visualizer (dev/UX toggle): translucent overlay over the
    -- Blizzard base's full extent; anchored at SetUnit time.
    local hitbox = plate:CreateTexture(nil, "BACKGROUND", nil, -8)
    hitbox:SetColorTexture(0, 0.8, 1, 0.25)
    hitbox:Hide()
    plate.npHitboxVis = hitbox
end

function NPExtras.ApplyAppearance(plate, settings)
    local highlight = settings.highlight or {}
    local markerS = settings.raidMarker or {}
    local colors = settings.colors or {}

    local size = markerS.size or 24
    QUICore:SetPixelPerfectSize(plate.npRaidMarker, size, size)
    plate.npRaidMarker:ClearAllPoints()
    local pos = markerS.position or "TOPRIGHT"
    if pos == "TOP" then
        plate.npRaidMarker:SetPoint("BOTTOM", plate.nameText, "TOP", 0, QUICore:Pixels(2, plate))
    elseif pos == "LEFT" then
        plate.npRaidMarker:SetPoint("RIGHT", plate.healthBar, "LEFT", -QUICore:Pixels(4, plate), 0)
    elseif pos == "RIGHT" then
        plate.npRaidMarker:SetPoint("LEFT", plate.healthBar, "RIGHT", QUICore:Pixels(4, plate), 0)
    else -- TOPRIGHT
        plate.npRaidMarker:SetPoint("BOTTOMLEFT", plate.healthBar, "TOPRIGHT", QUICore:Pixels(2, plate), QUICore:Pixels(2, plate))
    end
    plate.npRaidMarkerEnabled = markerS.enabled ~= false

    local gc = highlight.targetGlowColor or { 0.412, 0.667, 1.0 }
    plate.npTargetGlow:SetVertexColor(gc[1], gc[2], gc[3], highlight.targetGlowAlpha or 1)
    plate.npTargetGlow:ClearAllPoints()
    plate.npTargetGlow:SetPoint("TOPLEFT", plate.healthBar, "TOPLEFT", -QUICore:Pixels(6, plate), QUICore:Pixels(6, plate))
    plate.npTargetGlow:SetPoint("BOTTOMRIGHT", plate.healthBar, "BOTTOMRIGHT", QUICore:Pixels(6, plate), -QUICore:Pixels(6, plate))
    plate.npTargetGlowEnabled = highlight.targetGlow ~= false

    plate.npHoverAlpha = highlight.mouseoverAlpha or 0.3
    plate.npHoverEnabled = highlight.mouseover ~= false

    local ec = colors.execute or { 1, 0.1, 0.1 }
    plate.npExecuteOverlay:SetColorTexture(ec[1], ec[2], ec[3], 0.55)
end

---------------------------------------------------------------------------
-- RAID MARKERS
---------------------------------------------------------------------------
function NPExtras.UpdateRaidMarker(plate)
    local marker = plate.npRaidMarker
    if not marker then return end
    local unit = plate.unit
    if not unit or not plate.npRaidMarkerEnabled then
        marker:Hide()
        return
    end
    local ok, index = pcall(GetRaidTargetIndex, unit)
    index = ok and NP.Plain(index, "number") or nil
    if index and index >= 1 and index <= 8 then
        if SetRaidTargetIconTexture then
            pcall(SetRaidTargetIconTexture, marker, index)
        end
        marker:Show()
    else
        marker:Hide()
    end
end

---------------------------------------------------------------------------
-- TARGET / FOCUS (O(1): cached old plate + direct lookup of the new one)
---------------------------------------------------------------------------
local currentTargetPlate, currentFocusPlate

local function RefreshPlateColor(plate)
    NP.Health.UpdateColor(plate, NP.GetSettings(), context)
end

local function ApplyTargetVisual(plate)
    if plate.npIsTarget == true and plate.npTargetGlowEnabled then
        plate.npTargetGlow:Show()
    else
        plate.npTargetGlow:Hide()
    end
end

local function ResolvePlateFor(token)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, base = pcall(C_NamePlate.GetNamePlateForUnit, token)
    if not ok or not base then return nil end
    return NP.platesByBase[base]
end

local function OnTargetChanged()
    local old = currentTargetPlate
    currentTargetPlate = nil
    if old and old.unit then
        old.npIsTarget = false
        ApplyTargetVisual(old)
        RefreshPlateColor(old)
    end
    local plate = ResolvePlateFor("target")
    if plate and plate.unit then
        plate.npIsTarget = true
        currentTargetPlate = plate
        ApplyTargetVisual(plate)
        RefreshPlateColor(plate)
    end
end

local function OnFocusChanged()
    local old = currentFocusPlate
    currentFocusPlate = nil
    if old and old.unit then
        old.npIsFocus = false
        RefreshPlateColor(old)
    end
    local plate = ResolvePlateFor("focus")
    if plate and plate.unit then
        plate.npIsFocus = true
        currentFocusPlate = plate
        RefreshPlateColor(plate)
    end
end

---------------------------------------------------------------------------
-- MOUSEOVER (0.1s ticker only while hovering a plate)
---------------------------------------------------------------------------
local hoverPlate, hoverTicker

local function StopHover()
    if hoverPlate then
        hoverPlate.npHoverHighlight:SetAlpha(0)
        hoverPlate = nil
    end
    if hoverTicker then
        hoverTicker:Cancel()
        hoverTicker = nil
    end
end

local function HoverTick()
    local plate = hoverPlate
    if not plate or not plate.unit then
        StopHover()
        return
    end
    local ok, stillHovered = pcall(UnitIsUnit, "mouseover", plate.unit)
    if not (ok and NP.Plain(stillHovered, "boolean") == true) then
        StopHover()
    end
end

local function OnMouseoverChanged()
    local plate = ResolvePlateFor("mouseover")
    if plate == hoverPlate then return end
    StopHover()
    if not plate or not plate.npHoverEnabled or not plate.unit then return end
    hoverPlate = plate
    plate.npHoverHighlight:SetAlpha(plate.npHoverAlpha or 0.3)
    if C_Timer and C_Timer.NewTicker then
        hoverTicker = C_Timer.NewTicker(0.1, HoverTick)
    end
end

---------------------------------------------------------------------------
-- PLATE LIFECYCLE HOOKS (called by the driver)
---------------------------------------------------------------------------
-- Deferred phase of SetUnit: marker + target/focus caches + visualizer.
function NPExtras.OnPlateShown(plate)
    NPExtras.UpdateRaidMarker(plate)
    if plate.npIsTarget == true then
        currentTargetPlate = plate
    end
    if plate.npIsFocus == true then
        currentFocusPlate = plate
    end
    ApplyTargetVisual(plate)
    NPExtras.UpdateExecute(plate)

    local settings = NP.GetSettings()
    if settings.cvars and settings.cvars.hitboxVisualizer == true and plate.npBase then
        plate.npHitboxVis:ClearAllPoints()
        plate.npHitboxVis:SetAllPoints(plate.npBase)
        plate.npHitboxVis:Show()
    else
        plate.npHitboxVis:Hide()
    end
end

-- Recycle hygiene (driver ClearUnit).
function NPExtras.ClearPlate(plate)
    if currentTargetPlate == plate then currentTargetPlate = nil end
    if currentFocusPlate == plate then currentFocusPlate = nil end
    if hoverPlate == plate then StopHover() end
    if plate.npRaidMarker then plate.npRaidMarker:Hide() end
    if plate.npTargetGlow then plate.npTargetGlow:Hide() end
    if plate.npHoverHighlight then plate.npHoverHighlight:SetAlpha(0) end
    if plate.npExecuteOverlay then plate.npExecuteOverlay:SetAlpha(0) end
    if plate.npHitboxVis then plate.npHitboxVis:Hide() end
end

---------------------------------------------------------------------------
-- EVENTS
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
eventFrame:RegisterEvent("RAID_TARGET_UPDATE")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_TARGET_CHANGED" then
        if NP.IsEnabled() then OnTargetChanged() end
        return
    end
    if event == "UPDATE_MOUSEOVER_UNIT" then
        if NP.IsEnabled() then OnMouseoverChanged() end
        return
    end
    if event == "PLAYER_FOCUS_CHANGED" then
        if NP.IsEnabled() then OnFocusChanged() end
        return
    end
    if event == "RAID_TARGET_UPDATE" then
        if NP.IsEnabled() then
            for _, plate in pairs(NP.plates) do
                NPExtras.UpdateRaidMarker(plate)
            end
        end
        return
    end
    if event == "QUEST_LOG_UPDATE" then
        -- Debounced invalidation: wipe once per frame at most.
        if not questCacheDirty then
            questCacheDirty = true
            C_Timer.After(0, function()
                questCacheDirty = false
                wipe(questCache)
            end)
        end
        return
    end
    RefreshContext()
end)
