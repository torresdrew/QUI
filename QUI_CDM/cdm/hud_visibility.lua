local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local QUICore = ns.Addon

local UpdateCDMVisibility
local UpdateCustomTrackersVisibility
local UpdateUnitframesVisibility
local HookCustomTrackerFrameForMouseover

local _damagedAlphaCurve

local function GetDamagedAlphaCurve()
    if _damagedAlphaCurve then return _damagedAlphaCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateCurve
       or not Enum or not Enum.LuaCurveType then
        return nil
    end
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, 1)
    curve:AddPoint(1.0, 0)
    _damagedAlphaCurve = curve
    return curve
end

local function ReadNumber(value, fallback)
    if issecretvalue and issecretvalue(value) then return fallback end
    local valueType = type(value)
    if valueType == "number" then return value end
    if valueType == "string" then return tonumber(value) or fallback end
    return fallback
end

local function IsPlayerInGroup()
    return IsInGroup() or IsInRaid()
end

local HOUSING_INSTANCE_TYPES = {
    ["neighborhood"] = true,
    ["interior"] = true,
}

local function IsPlayerInInstance()
    local _, instanceType = GetInstanceInfo()
    if instanceType == "none" or instanceType == nil then
        return false
    end
    if HOUSING_INSTANCE_TYPES[instanceType] then
        return false
    end
    return true
end

local _cdmFramesCache = {}
local _cdmFramesDirty = true

local function InvalidateCDMFrameCache()
    _cdmFramesDirty = true
end

local function IsCustomCDMBarFrame(frame)
    if not frame then return false end
    local key = frame._quiCdmKey
    if not key and frame._spellEntry then
        key = frame._spellEntry.viewerType
    end
    if type(key) ~= "string" then return false end

    local profile = QUICore and QUICore.db and QUICore.db.profile
    local container = profile
        and profile.ncdm
        and profile.ncdm.containers
        and profile.ncdm.containers[key]
    return type(container) == "table" and container.containerType == "customBar"
end

local function GetCDMFrames()
    if not _cdmFramesDirty then
        return _cdmFramesCache
    end

    wipe(_cdmFramesCache)

    if ns.CDMProvider and ns.CDMProvider.GetViewerFrames then
        local frames = ns.CDMProvider:GetViewerFrames()
        if frames then
            for i = 1, #frames do
                if not IsCustomCDMBarFrame(frames[i]) then
                    _cdmFramesCache[#_cdmFramesCache + 1] = frames[i]
                end
            end
        end
    end

    _cdmFramesDirty = false
    return _cdmFramesCache
end

local function GetCustomTrackerFrames()
    local frames = {}
    if ns.CDMProvider and ns.CDMProvider.GetViewerFrames then
        local allFrames = ns.CDMProvider:GetViewerFrames()
        if allFrames then
            for i = 1, #allFrames do
                local frame = allFrames[i]
                if IsCustomCDMBarFrame(frame) then
                    frames[#frames + 1] = frame
                end
            end
        end
    end
    return frames
end

local function GetCDMVisibilitySettings()
    if QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.cdmVisibility then
        return QUICore.db.profile.cdmVisibility
    end
    return nil
end

local function IsCDMMasterEnabled()
    local profile = QUICore and QUICore.db and QUICore.db.profile
    local ncdm = profile and profile.ncdm
    return not ncdm or ncdm.enabled ~= false
end

local _viewerAlphaProxy = CreateFrame and CreateFrame("Frame") or nil
local _rawViewerSetAlpha = _viewerAlphaProxy and _viewerAlphaProxy.SetAlpha or nil
local _securecall = securecallfunction or function(fn, ...) return fn(...) end
local REANCHOR_VIEWER_KEYS = { "essential", "utility", "buff", "trackedBar" }

local function ApplyReanchorViewerAlpha(alpha)
    if not _rawViewerSetAlpha then return end
    local boot = ns._cdmBoot
    local wiring = boot and boot.wiring
    if not (wiring and wiring.GetViewerForKey) then return end
    if not IsCDMMasterEnabled() then alpha = 1 end
    for i = 1, #REANCHOR_VIEWER_KEYS do
        local viewer = wiring:GetViewerForKey(REANCHOR_VIEWER_KEYS[i])
        if viewer and (not viewer.IsForbidden or not viewer:IsForbidden()) then
            _securecall(_rawViewerSetAlpha, viewer, alpha)
        end
    end
end

local CDMVisibility = {
    currentlyHidden = false,
    isFading = false,
    fadeStart = 0,
    fadeStartAlpha = 1,
    fadeTargetAlpha = 1,
    fadeTargets = nil,
    fadeFrame = nil,
    mouseOver = false,
    mouseoverDetector = nil,
    hoverCount = 0,
    leaveTimer = nil,
}

local function ShouldHideForLocationRules(vis, includeVehicle)
    local ignoreHideRules = vis.dontHideInDungeonsRaids and Helpers.IsPlayerInDungeonOrRaid and Helpers.IsPlayerInDungeonOrRaid()
    if ignoreHideRules then return false end
    if vis.hideWhenMounted and not vis.showWhenMounted and Helpers.IsPlayerMounted() then return true end
    if vis.hideWhenFlying and Helpers.IsPlayerFlying() then return true end
    if vis.hideWhenSkyriding and Helpers.IsPlayerSkyriding() then return true end
    if includeVehicle and vis.hideWhenInVehicle and Helpers.IsPlayerInVehicle and Helpers.IsPlayerInVehicle() then return true end
    return false
end

local function ShouldCDMBeVisible()
    if not IsCDMMasterEnabled() then return false end

    local vis = GetCDMVisibilitySettings()
    if not vis then return true end

    if vis.showAlways then
        if ShouldHideForLocationRules(vis, true) then return false end
        return true
    end

    if vis.showWhenTargetExists and UnitExists("target") then return true end
    if vis.showInCombat and UnitAffectingCombat("player") then return true end
    if vis.showInGroup and IsPlayerInGroup() then return true end
    if vis.showInInstance and IsPlayerInInstance() then return true end
    if vis.showOnMouseover and CDMVisibility.mouseOver then return true end
    if vis.showWhenMounted and Helpers.IsPlayerMounted() then return true end

    if ShouldHideForLocationRules(vis, true) then return false end

    return false
end

local function OnCDMFadeUpdate(self)
    local targetAlpha = ReadNumber(CDMVisibility.fadeTargetAlpha, 1)
    local vis = GetCDMVisibilitySettings()
    local duration = (vis and vis.fadeDuration) or 0.2
    if duration <= 0 then duration = 0.01 end

    local now = GetTime()
    local elapsedTime = now - CDMVisibility.fadeStart
    local progress = math.min(elapsedTime / duration, 1)

    local startAlpha = ReadNumber(CDMVisibility.fadeStartAlpha, targetAlpha)
    local alpha = startAlpha + (targetAlpha - startAlpha) * progress

    local frames = CDMVisibility.fadeTargets or GetCDMFrames()
    for i = #frames, 1, -1 do
        local frame = frames[i]
        local ok = false
        if frame then
            ok = ns.SafeCallMethodIfPresent("best-effort-style", frame, "SetAlpha", alpha)
        end
        if not ok then
            table.remove(frames, i)
        end
    end
    ApplyReanchorViewerAlpha(alpha)

    if progress >= 1 then
        CDMVisibility.isFading = false
        CDMVisibility.currentlyHidden = (targetAlpha < 1)
        CDMVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
    end
end

local function StartCDMFade(targetAlpha)
    local frames = GetCDMFrames()
    if #frames == 0 then return end

    local rawAlpha = frames[1]:GetAlpha()
    local currentAlpha = ReadNumber(rawAlpha, targetAlpha)

    if math.abs(currentAlpha - targetAlpha) < 0.01 then
        CDMVisibility.currentlyHidden = (targetAlpha < 1)
        CDMVisibility.fadeStartAlpha = targetAlpha
        CDMVisibility.fadeTargetAlpha = targetAlpha
        ApplyReanchorViewerAlpha(targetAlpha)
        return
    end

    CDMVisibility.isFading = true
    CDMVisibility.fadeStart = GetTime()
    CDMVisibility.fadeStartAlpha = currentAlpha
    CDMVisibility.fadeTargetAlpha = targetAlpha
    CDMVisibility.fadeTargets = {}
    for i = 1, #frames do
        CDMVisibility.fadeTargets[i] = frames[i]
    end

    if not CDMVisibility.fadeFrame then
        CDMVisibility.fadeFrame = CreateFrame("Frame")
    end
    CDMVisibility.fadeFrame:SetScript("OnUpdate", OnCDMFadeUpdate)
end

local function SnapCDMFadeToTarget()
    local target = ReadNumber(CDMVisibility.fadeTargetAlpha, 1)
    local frames = CDMVisibility.fadeTargets or GetCDMFrames()
    for i = #frames, 1, -1 do
        local frame = frames[i]
        if frame then
            ns.SafeCallMethodIfPresent("best-effort-style", frame, "SetAlpha", target)
        end
    end
    ApplyReanchorViewerAlpha(target)
    CDMVisibility.isFading = false
    CDMVisibility.currentlyHidden = (target < 1)
    CDMVisibility.fadeTargets = nil
    if CDMVisibility.fadeFrame then
        CDMVisibility.fadeFrame:SetScript("OnUpdate", nil)
    end
end

UpdateCDMVisibility = function()
    if not IsCDMMasterEnabled() then
        StartCDMFade(0)
        return
    end

    if Helpers.IsEditModeActive() or Helpers.IsLayoutModeActive() then
        StartCDMFade(1)
        return
    end

    local shouldShow = ShouldCDMBeVisible()
    local vis = GetCDMVisibilitySettings()

    local hpCurve = ((not shouldShow) and vis and vis.showWhenHealthBelow100
        and UnitHealthPercent) and GetDamagedAlphaCurve() or nil
    if hpCurve then
        local damagedAlpha = UnitHealthPercent("player", true, hpCurve)
        if CDMVisibility.fadeFrame then
            CDMVisibility.fadeFrame:SetScript("OnUpdate", nil)
        end
        CDMVisibility.isFading = false
        CDMVisibility.fadeTargets = nil
        local frames = GetCDMFrames()
        for i = #frames, 1, -1 do
            local frame = frames[i]
            if frame then
                ns.SafeCallMethodIfPresent("sink-forward", frame, "SetAlpha", damagedAlpha)
            end
        end
        ApplyReanchorViewerAlpha(damagedAlpha)
        if QUICore then
            if QUICore.UpdatePowerBar then QUICore:UpdatePowerBar() end
            if QUICore.UpdateSecondaryPowerBar then QUICore:UpdateSecondaryPowerBar() end
        end
        return
    end

    if shouldShow then
        StartCDMFade(1)
    else
        StartCDMFade(vis and vis.fadeOutAlpha or 0)
    end

    if QUICore then
        if QUICore.UpdatePowerBar then
            QUICore:UpdatePowerBar()
        end
        if QUICore.UpdateSecondaryPowerBar then
            QUICore:UpdateSecondaryPowerBar()
        end
    end
end

local _mouseoverHooked = Helpers.CreateStateTable()

local function IsAddonOwnedCDMMouseoverFrame(frame)
    return frame
        and (frame._isQUICDMIcon or frame._quiCdmKey or frame._quiCDMMouseoverTarget)
end

local function HookFrameForMouseover(frame)
    if not IsAddonOwnedCDMMouseoverFrame(frame) or _mouseoverHooked[frame] then return end
    if IsCustomCDMBarFrame(frame) then
        if HookCustomTrackerFrameForMouseover then
            HookCustomTrackerFrameForMouseover(frame)
        end
        return
    end

    _mouseoverHooked[frame] = true

    frame:HookScript("OnEnter", function()
        local vis = GetCDMVisibilitySettings()
        if not vis or vis.showAlways or not vis.showOnMouseover then return end

        if CDMVisibility.leaveTimer then
            CDMVisibility.leaveTimer:Cancel()
            CDMVisibility.leaveTimer = nil
        end

        CDMVisibility.hoverCount = CDMVisibility.hoverCount + 1
        if CDMVisibility.hoverCount == 1 then
            CDMVisibility.mouseOver = true
            UpdateCDMVisibility()
        end
    end)

    frame:HookScript("OnLeave", function()
        local vis = GetCDMVisibilitySettings()
        if not vis or vis.showAlways or not vis.showOnMouseover then return end

        CDMVisibility.hoverCount = math.max(0, CDMVisibility.hoverCount - 1)

        if CDMVisibility.hoverCount == 0 then
            if CDMVisibility.leaveTimer then
                CDMVisibility.leaveTimer:Cancel()
            end

            CDMVisibility.leaveTimer = C_Timer.NewTimer(0.5, function()
                CDMVisibility.leaveTimer = nil
                if CDMVisibility.hoverCount == 0 then
                    CDMVisibility.mouseOver = false
                    UpdateCDMVisibility()
                end
            end)
        end
    end)
end

local function SetupCDMMouseoverDetector()
    local vis = GetCDMVisibilitySettings()

    if CDMVisibility.mouseoverDetector then
        CDMVisibility.mouseoverDetector:SetScript("OnUpdate", nil)
        CDMVisibility.mouseoverDetector:Hide()
        CDMVisibility.mouseoverDetector = nil
    end

    if CDMVisibility.leaveTimer then
        CDMVisibility.leaveTimer:Cancel()
        CDMVisibility.leaveTimer = nil
    end

    CDMVisibility.mouseOver = false
    CDMVisibility.hoverCount = 0

    if not vis or vis.showAlways or not vis.showOnMouseover then
        return
    end

    local cdmFrames = GetCDMFrames()
    for _, frame in ipairs(cdmFrames) do
        HookFrameForMouseover(frame)
    end

    local viewers
    if ns.CDMProvider and ns.CDMProvider.GetViewerFrames then
        viewers = ns.CDMProvider:GetViewerFrames()
    else
        viewers = {}
    end

    for _, viewer in ipairs(viewers) do
        if viewer and viewer.GetNumChildren then
            local numChildren = viewer:GetNumChildren()
            for i = 1, numChildren do
                local child = select(i, viewer:GetChildren())
                if child and IsAddonOwnedCDMMouseoverFrame(child) then
                    HookFrameForMouseover(child)
                end
            end
        end
    end

    local detector = CreateFrame("Frame", nil, UIParent)
    detector:EnableMouse(false)
    CDMVisibility.mouseoverDetector = detector
end

local CustomTrackersVisibility = {
    currentlyHidden = false,
    isFading = false,
    fadeStart = 0,
    fadeStartAlpha = 1,
    fadeTargetAlpha = 1,
    fadeTargets = nil,
    fadeFrame = nil,
    mouseOver = false,
    mouseoverDetector = nil,
    hoverCount = 0,
    leaveTimer = nil,
}

local function GetCustomTrackersVisibilitySettings()
    if QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.customTrackersVisibility then
        return QUICore.db.profile.customTrackersVisibility
    end
    return nil
end

local function ShouldCustomTrackersBeVisible()
    if not IsCDMMasterEnabled() then return false end

    local vis = GetCustomTrackersVisibilitySettings()
    if not vis then return true end

    if vis.showAlways then
        if ShouldHideForLocationRules(vis, true) then return false end
        return true
    end

    if vis.showWhenTargetExists and UnitExists("target") then return true end
    if vis.showInCombat and UnitAffectingCombat("player") then return true end
    if vis.showInGroup and IsPlayerInGroup() then return true end
    if vis.showInInstance and IsPlayerInInstance() then return true end
    if vis.showOnMouseover and CustomTrackersVisibility.mouseOver then return true end
    if vis.showWhenMounted and Helpers.IsPlayerMounted() then return true end

    if ShouldHideForLocationRules(vis, true) then return false end

    return false
end

local function OnCustomTrackersFadeUpdate(self)
    local targetAlpha = ReadNumber(CustomTrackersVisibility.fadeTargetAlpha, 1)
    local vis = GetCustomTrackersVisibilitySettings()
    local duration = (vis and vis.fadeDuration) or 0.2
    if duration <= 0 then duration = 0.01 end

    local now = GetTime()
    local elapsedTime = now - CustomTrackersVisibility.fadeStart
    local progress = math.min(elapsedTime / duration, 1)
    local startAlpha = ReadNumber(CustomTrackersVisibility.fadeStartAlpha, targetAlpha)
    local alpha = startAlpha + (targetAlpha - startAlpha) * progress

    local frames = CustomTrackersVisibility.fadeTargets or GetCustomTrackerFrames()
    for i = #frames, 1, -1 do
        local frame = frames[i]
        local ok = false
        if frame then
            ok = ns.SafeCallMethodIfPresent("best-effort-style", frame, "SetAlpha", alpha)
        end
        if not ok then
            table.remove(frames, i)
        end
    end

    if progress >= 1 then
        CustomTrackersVisibility.isFading = false
        CustomTrackersVisibility.currentlyHidden = (targetAlpha < 1)
        CustomTrackersVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
    end
end

local function StartCustomTrackersFade(targetAlpha)
    local frames = GetCustomTrackerFrames()
    if #frames == 0 then return end

    local rawAlpha = frames[1]:GetAlpha()
    local currentAlpha = ReadNumber(rawAlpha, targetAlpha)
    if math.abs(currentAlpha - targetAlpha) < 0.01 then
        CustomTrackersVisibility.currentlyHidden = (targetAlpha < 1)
        CustomTrackersVisibility.fadeStartAlpha = targetAlpha
        CustomTrackersVisibility.fadeTargetAlpha = targetAlpha
        return
    end

    CustomTrackersVisibility.isFading = true
    CustomTrackersVisibility.fadeStart = GetTime()
    CustomTrackersVisibility.fadeStartAlpha = currentAlpha
    CustomTrackersVisibility.fadeTargetAlpha = targetAlpha
    CustomTrackersVisibility.fadeTargets = {}
    for i = 1, #frames do
        CustomTrackersVisibility.fadeTargets[i] = frames[i]
    end

    if not CustomTrackersVisibility.fadeFrame then
        CustomTrackersVisibility.fadeFrame = CreateFrame("Frame")
    end
    CustomTrackersVisibility.fadeFrame:SetScript("OnUpdate", OnCustomTrackersFadeUpdate)
end

UpdateCustomTrackersVisibility = function()
    if not IsCDMMasterEnabled() then
        StartCustomTrackersFade(0)
        return
    end

    if Helpers.IsEditModeActive() or Helpers.IsLayoutModeActive() then
        StartCustomTrackersFade(1)
        return
    end

    local shouldShow = ShouldCustomTrackersBeVisible()
    local vis = GetCustomTrackersVisibilitySettings()
    if shouldShow then
        StartCustomTrackersFade(1)
    else
        StartCustomTrackersFade(vis and vis.fadeOutAlpha or 0)
    end
end

HookCustomTrackerFrameForMouseover = function(frame)
    if not IsAddonOwnedCDMMouseoverFrame(frame) or _mouseoverHooked[frame] then return end
    if not IsCustomCDMBarFrame(frame) then return end

    _mouseoverHooked[frame] = true

    frame:HookScript("OnEnter", function()
        local vis = GetCustomTrackersVisibilitySettings()
        if not vis or vis.showAlways or not vis.showOnMouseover then return end

        if CustomTrackersVisibility.leaveTimer then
            CustomTrackersVisibility.leaveTimer:Cancel()
            CustomTrackersVisibility.leaveTimer = nil
        end

        CustomTrackersVisibility.hoverCount = CustomTrackersVisibility.hoverCount + 1
        if CustomTrackersVisibility.hoverCount == 1 then
            CustomTrackersVisibility.mouseOver = true
            UpdateCustomTrackersVisibility()
        end
    end)

    frame:HookScript("OnLeave", function()
        local vis = GetCustomTrackersVisibilitySettings()
        if not vis or vis.showAlways or not vis.showOnMouseover then return end

        CustomTrackersVisibility.hoverCount = math.max(0, CustomTrackersVisibility.hoverCount - 1)
        if CustomTrackersVisibility.hoverCount == 0 then
            if CustomTrackersVisibility.leaveTimer then
                CustomTrackersVisibility.leaveTimer:Cancel()
            end

            CustomTrackersVisibility.leaveTimer = C_Timer.NewTimer(0.5, function()
                CustomTrackersVisibility.leaveTimer = nil
                if CustomTrackersVisibility.hoverCount == 0 then
                    CustomTrackersVisibility.mouseOver = false
                    UpdateCustomTrackersVisibility()
                end
            end)
        end
    end)
end

local function SetupCustomTrackersMouseoverDetector()
    local vis = GetCustomTrackersVisibilitySettings()

    if CustomTrackersVisibility.mouseoverDetector then
        CustomTrackersVisibility.mouseoverDetector:SetScript("OnUpdate", nil)
        CustomTrackersVisibility.mouseoverDetector:Hide()
        CustomTrackersVisibility.mouseoverDetector = nil
    end

    if CustomTrackersVisibility.leaveTimer then
        CustomTrackersVisibility.leaveTimer:Cancel()
        CustomTrackersVisibility.leaveTimer = nil
    end

    CustomTrackersVisibility.mouseOver = false
    CustomTrackersVisibility.hoverCount = 0

    if not vis or vis.showAlways or not vis.showOnMouseover then
        return
    end

    local frames = GetCustomTrackerFrames()
    for _, frame in ipairs(frames) do
        HookCustomTrackerFrameForMouseover(frame)
        if frame and frame.GetNumChildren then
            local numChildren = frame:GetNumChildren()
            for i = 1, numChildren do
                local child = select(i, frame:GetChildren())
                if child and IsAddonOwnedCDMMouseoverFrame(child) then
                    HookCustomTrackerFrameForMouseover(child)
                end
            end
        end
    end

    local detector = CreateFrame("Frame", nil, UIParent)
    detector:EnableMouse(false)
    CustomTrackersVisibility.mouseoverDetector = detector
end

local UnitframesVisibility = {
    currentlyHidden = false,
    isFading = false,
    fadeStart = 0,
    fadeStartAlpha = 1,
    fadeTargetAlpha = 1,
    fadeTargets = nil,
    fadeFrame = nil,
    mouseOver = false,
    mouseoverDetector = nil,
    leaveTimer = nil,
}

local function IsUnitframesCombatLocked()
    if InCombatLockdown and InCombatLockdown() then return true end
    return UnitAffectingCombat and UnitAffectingCombat("player")
end

local function GetUnitframesVisibilitySettings()
    if QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.unitframesVisibility then
        return QUICore.db.profile.unitframesVisibility
    end
    return nil
end

local function GetUnitframeFrames()
    local frames = {}

    if _G.QUI_UnitFrames then
        for unitKey, frame in pairs(_G.QUI_UnitFrames) do
            if frame then
                table.insert(frames, frame)
            end
        end
    end

    local vis = GetUnitframesVisibilitySettings()
    if not (vis and vis.alwaysShowCastbars) then
        if _G.QUI_Castbars then
            for unitKey, castbar in pairs(_G.QUI_Castbars) do
                if castbar then
                    table.insert(frames, castbar)
                end
            end
        end
    end

    return frames
end

local function GetPlayerUnitframes()
    local frames = {}
    if _G.QUI_UnitFrames and _G.QUI_UnitFrames.player then
        table.insert(frames, _G.QUI_UnitFrames.player)
    end
    local vis = GetUnitframesVisibilitySettings()
    if not (vis and vis.alwaysShowCastbars) then
        if _G.QUI_Castbars and _G.QUI_Castbars.player then
            table.insert(frames, _G.QUI_Castbars.player)
        end
    end
    return frames
end

local function GetUnitframeFramesExcludingPlayer()
    local frames = {}
    if _G.QUI_UnitFrames then
        for unitKey, frame in pairs(_G.QUI_UnitFrames) do
            if frame and unitKey ~= "player" then
                table.insert(frames, frame)
            end
        end
    end
    local vis = GetUnitframesVisibilitySettings()
    if not (vis and vis.alwaysShowCastbars) then
        if _G.QUI_Castbars then
            for unitKey, castbar in pairs(_G.QUI_Castbars) do
                if castbar and unitKey ~= "player" then
                    table.insert(frames, castbar)
                end
            end
        end
    end
    return frames
end

local function ApplyUnitframeVisibilityAlpha(frame, alpha)
    if not frame then return end

    if frame._quiCastbar then
        if frame._quiDesiredVisible then return end
        if frame._quiUseAlphaVisibility then
            frame:SetAlpha(0)
            return
        end
    end

    frame:SetAlpha(alpha)
end

local function ShouldUnitframesBeVisible()
    local vis = GetUnitframesVisibilitySettings()
    if not vis then return true end

    if IsUnitframesCombatLocked() then
        return true
    end

    if vis.showAlways then
        if ShouldHideForLocationRules(vis, false) then return false end
        return true
    end

    if vis.showWhenTargetExists and UnitExists("target") then return true end
    if vis.showInCombat and UnitAffectingCombat("player") then return true end
    if vis.showInGroup and IsPlayerInGroup() then return true end
    if vis.showInInstance and IsPlayerInInstance() then return true end
    if vis.showOnMouseover and UnitframesVisibility.mouseOver then return true end
    if vis.showWhenMounted and Helpers.IsPlayerMounted() then return true end

    if ShouldHideForLocationRules(vis, false) then return false end

    return false
end

local function OnUnitframesFadeUpdate(self)
    local targetAlpha = ReadNumber(UnitframesVisibility.fadeTargetAlpha, 1)
    if targetAlpha < 1 and IsUnitframesCombatLocked() then
        local frames = UnitframesVisibility.fadeTargets or GetUnitframeFrames()
        for _, frame in ipairs(frames) do
            ApplyUnitframeVisibilityAlpha(frame, 1)
        end
        UnitframesVisibility.isFading = false
        UnitframesVisibility.currentlyHidden = false
        UnitframesVisibility.fadeTargetAlpha = 1
        UnitframesVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
        return
    end

    local vis = GetUnitframesVisibilitySettings()
    local duration = (vis and vis.fadeDuration) or 0.2
    if duration <= 0 then duration = 0.01 end

    local now = GetTime()
    local elapsedTime = now - UnitframesVisibility.fadeStart
    local progress = math.min(elapsedTime / duration, 1)

    local startAlpha = ReadNumber(UnitframesVisibility.fadeStartAlpha, targetAlpha)
    local alpha = startAlpha + (targetAlpha - startAlpha) * progress

    local frames = UnitframesVisibility.fadeTargets or GetUnitframeFrames()
    for _, frame in ipairs(frames) do
        ApplyUnitframeVisibilityAlpha(frame, alpha)
    end

    if progress >= 1 then
        UnitframesVisibility.isFading = false
        UnitframesVisibility.currentlyHidden = (targetAlpha < 1)
        UnitframesVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
    end
end

local function StartUnitframesFade(targetAlpha, framesOverride)
    local frames = framesOverride or GetUnitframeFrames()
    if #frames == 0 then return end

    local forceInstant = IsUnitframesCombatLocked()
    if targetAlpha < 1 and forceInstant then
        targetAlpha = 1
    end

    local rawAlpha = frames[1]:GetAlpha()
    local currentAlpha = ReadNumber(rawAlpha, targetAlpha)

    if forceInstant or math.abs(currentAlpha - targetAlpha) < 0.01 then
        for _, frame in ipairs(frames) do
            ApplyUnitframeVisibilityAlpha(frame, targetAlpha)
        end
        if UnitframesVisibility.fadeFrame then
            UnitframesVisibility.fadeFrame:SetScript("OnUpdate", nil)
        end
        UnitframesVisibility.isFading = false
        UnitframesVisibility.currentlyHidden = (targetAlpha < 1)
        UnitframesVisibility.fadeStartAlpha = targetAlpha
        UnitframesVisibility.fadeTargetAlpha = targetAlpha
        UnitframesVisibility.fadeTargets = nil
        return
    end

    UnitframesVisibility.isFading = true
    UnitframesVisibility.fadeStart = GetTime()
    UnitframesVisibility.fadeStartAlpha = currentAlpha
    UnitframesVisibility.fadeTargetAlpha = targetAlpha
    UnitframesVisibility.fadeTargets = frames

    if not UnitframesVisibility.fadeFrame then
        UnitframesVisibility.fadeFrame = CreateFrame("Frame")
    end
    UnitframesVisibility.fadeFrame:SetScript("OnUpdate", OnUnitframesFadeUpdate)
end

UpdateUnitframesVisibility = function()
    if (_G.QUI_IsUnitFrameEditModeActive and _G.QUI_IsUnitFrameEditModeActive())
        or Helpers.IsLayoutModeActive() then
        StartUnitframesFade(1)
        return
    end

    local vis = GetUnitframesVisibilitySettings()
    local shouldShow = ShouldUnitframesBeVisible()

    local hpCurve = ((not shouldShow) and vis and vis.showWhenHealthBelow100
        and UnitHealthPercent) and GetDamagedAlphaCurve() or nil
    if hpCurve then
        local damagedAlpha = UnitHealthPercent("player", true, hpCurve)
        for _, frame in ipairs(GetPlayerUnitframes()) do
            ApplyUnitframeVisibilityAlpha(frame, damagedAlpha)
        end

        local fadeAlpha = vis and vis.fadeOutAlpha or 0
        local nonPlayerFrames = GetUnitframeFramesExcludingPlayer()
        if #nonPlayerFrames > 0 then
            StartUnitframesFade(fadeAlpha, nonPlayerFrames)
        else
            if UnitframesVisibility.fadeFrame then
                UnitframesVisibility.fadeFrame:SetScript("OnUpdate", nil)
            end
            UnitframesVisibility.isFading = false
            UnitframesVisibility.fadeTargets = nil
        end
        return
    end

    if _G.QUI_Castbars then
        local targetAlpha = 1

        if vis and vis.alwaysShowCastbars then
            targetAlpha = 1
        else
            targetAlpha = shouldShow and 1 or (vis and vis.fadeOutAlpha or 0)
        end

        for unitKey, castbar in pairs(_G.QUI_Castbars) do
            if castbar then
                ApplyUnitframeVisibilityAlpha(castbar, targetAlpha)
            end
        end
    end

    if shouldShow then
        StartUnitframesFade(1)
    else
        StartUnitframesFade(vis and vis.fadeOutAlpha or 0)
    end
end

local function SetupUnitframesMouseoverDetector()
    local vis = GetUnitframesVisibilitySettings()

    if UnitframesVisibility.mouseoverDetector then
        UnitframesVisibility.mouseoverDetector:SetScript("OnUpdate", nil)
        UnitframesVisibility.mouseoverDetector:Hide()
        UnitframesVisibility.mouseoverDetector = nil
    end

    if UnitframesVisibility.leaveTimer then
        UnitframesVisibility.leaveTimer:Cancel()
        UnitframesVisibility.leaveTimer = nil
    end
    UnitframesVisibility.mouseOver = false

    if not vis or vis.showAlways or not vis.showOnMouseover then
        return
    end

    local ufFrames = GetUnitframeFrames()
    local hoverCount = 0

    for _, frame in ipairs(ufFrames) do
        if frame and not _mouseoverHooked[frame] then
            _mouseoverHooked[frame] = true

            frame:HookScript("OnEnter", function()
                if UnitframesVisibility.leaveTimer then
                    UnitframesVisibility.leaveTimer:Cancel()
                    UnitframesVisibility.leaveTimer = nil
                end
                hoverCount = hoverCount + 1
                if hoverCount == 1 then
                    UnitframesVisibility.mouseOver = true
                    UpdateUnitframesVisibility()
                end
            end)

            frame:HookScript("OnLeave", function()
                hoverCount = math.max(0, hoverCount - 1)
                if hoverCount == 0 then
                    if UnitframesVisibility.leaveTimer then
                        UnitframesVisibility.leaveTimer:Cancel()
                    end
                    UnitframesVisibility.leaveTimer = C_Timer.NewTimer(0.5, function()
                        UnitframesVisibility.leaveTimer = nil
                        if hoverCount == 0 then
                            UnitframesVisibility.mouseOver = false
                            UpdateUnitframesVisibility()
                        end
                    end)
                end
            end)
        end
    end

    local detector = CreateFrame("Frame", nil, UIParent)
    detector:EnableMouse(false)
    UnitframesVisibility.mouseoverDetector = detector
end

local ActionBarsVisibility = {
    currentlyHidden = false,
    isFading = false,
    fadeStart = 0,
    fadeStartAlpha = 1,
    fadeTargetAlpha = 1,
    fadeTargets = nil,
    fadeFrame = nil,
    mouseOver = false,
    mouseoverDetector = nil,
    leaveTimer = nil,
}

local function GetActionBarsVisibilitySettings()
    if QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.actionBarsVisibility then
        return QUICore.db.profile.actionBarsVisibility
    end
    return nil
end

local function GetActionBarFrames()
    local frames = {}
    if ns.ActionBarsOwned and ns.ActionBarsOwned.containers then
        for barKey, container in pairs(ns.ActionBarsOwned.containers) do
            if container then
                frames[#frames + 1] = { barKey = barKey, container = container }
            end
        end
    end
    return frames
end

local function ShouldActionBarsBeVisible()
    local vis = GetActionBarsVisibilitySettings()
    if not vis then return true end

    if vis.showAlways then
        if ShouldHideForLocationRules(vis, true) then return false end
        return true
    end

    if vis.showWhenTargetExists and UnitExists("target") then return true end
    if vis.showInCombat and UnitAffectingCombat("player") then return true end
    if vis.showInGroup and IsPlayerInGroup() then return true end
    if vis.showInInstance and IsPlayerInInstance() then return true end
    if vis.showOnMouseover and ActionBarsVisibility.mouseOver then return true end
    if vis.showWhenMounted and Helpers.IsPlayerMounted() then return true end

    if ShouldHideForLocationRules(vis, true) then return false end

    return false
end

ns.ShouldHideActionBarsForVisibility = function()
    if Helpers.IsEditModeActive() or Helpers.IsLayoutModeActive() then
        return false
    end
    return not ShouldActionBarsBeVisible()
end

local function ApplyBarAlpha(setBarAlpha, barKey, container, alpha)
    if setBarAlpha then
        ns.SafeCall("best-effort-style", setBarAlpha, barKey, alpha)
    elseif container then
        ns.SafeCallMethodIfPresent("best-effort-style", container, "SetAlpha", alpha)
    end
end

local function OnActionBarsFadeUpdate(self)
    local targetAlpha = ReadNumber(ActionBarsVisibility.fadeTargetAlpha, 1)
    local vis = GetActionBarsVisibilitySettings()
    local duration = (vis and vis.fadeDuration) or 0.2
    if duration <= 0 then duration = 0.01 end

    local now = GetTime()
    local elapsedTime = now - ActionBarsVisibility.fadeStart
    local progress = math.min(elapsedTime / duration, 1)

    local startAlpha = ReadNumber(ActionBarsVisibility.fadeStartAlpha, targetAlpha)
    local alpha = startAlpha + (targetAlpha - startAlpha) * progress

    local setBarAlpha = ns.ActionBarsOwned and ns.ActionBarsOwned.SetBarAlpha
    local frames = ActionBarsVisibility.fadeTargets
    if frames then
        for _, entry in ipairs(frames) do
            ApplyBarAlpha(setBarAlpha, entry.barKey, entry.container, alpha)
        end
    else
        local containers = ns.ActionBarsOwned and ns.ActionBarsOwned.containers
        if containers then
            for barKey, container in pairs(containers) do
                ApplyBarAlpha(setBarAlpha, barKey, container, alpha)
            end
        end
    end

    if progress >= 1 then
        ActionBarsVisibility.isFading = false
        ActionBarsVisibility.currentlyHidden = (targetAlpha < 1)
        ActionBarsVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
    end
end

local function StartActionBarsFade(targetAlpha)
    local frames = GetActionBarFrames()
    if #frames == 0 then return end

    local rawAlpha = frames[1].container:GetAlpha()
    local currentAlpha = ReadNumber(rawAlpha, targetAlpha)

    if math.abs(currentAlpha - targetAlpha) < 0.01 then
        ActionBarsVisibility.currentlyHidden = (targetAlpha < 1)
        ActionBarsVisibility.fadeStartAlpha = targetAlpha
        ActionBarsVisibility.fadeTargetAlpha = targetAlpha
        return
    end

    ActionBarsVisibility.isFading = true
    ActionBarsVisibility.fadeStart = GetTime()
    ActionBarsVisibility.fadeStartAlpha = currentAlpha
    ActionBarsVisibility.fadeTargetAlpha = targetAlpha
    ActionBarsVisibility.fadeTargets = frames

    if not ActionBarsVisibility.fadeFrame then
        ActionBarsVisibility.fadeFrame = CreateFrame("Frame")
    end
    ActionBarsVisibility.fadeFrame:SetScript("OnUpdate", OnActionBarsFadeUpdate)
end

local function StopActionBarsFade()
    ActionBarsVisibility.isFading = false
    ActionBarsVisibility.fadeTargets = nil
    if ActionBarsVisibility.fadeFrame then
        ActionBarsVisibility.fadeFrame:SetScript("OnUpdate", nil)
    end
end

local function IsActionBarMouseoverFadeEnabled()
    if not (QUICore and QUICore.db and QUICore.db.profile) then return false end

    local actionBars = QUICore.db.profile.actionBars
    if type(actionBars) ~= "table" then return false end

    local fade = actionBars.fade
    local globalFadeEnabled = type(fade) == "table" and fade.enabled == true
    local bars = actionBars.bars
    local containers = ns.ActionBarsOwned and ns.ActionBarsOwned.containers

    if type(containers) == "table" and next(containers) ~= nil then
        for barKey in pairs(containers) do
            local barSettings = type(bars) == "table" and bars[barKey]
            local fadeEnabled = type(barSettings) == "table" and barSettings.fadeEnabled
            if fadeEnabled == nil then
                fadeEnabled = globalFadeEnabled
            end
            if fadeEnabled then
                return true
            end
        end
        return false
    end

    return globalFadeEnabled
end

local function UpdateActionBarsVisibility()
    if Helpers.IsEditModeActive() or Helpers.IsLayoutModeActive() then
        StartActionBarsFade(1)
        return
    end

    local shouldShow = ShouldActionBarsBeVisible()
    local vis = GetActionBarsVisibilitySettings()

    if shouldShow then
        if IsActionBarMouseoverFadeEnabled() then
            StopActionBarsFade()
            ActionBarsVisibility.currentlyHidden = false
            if type(_G.QUI_RefreshActionBarFade) == "function" then
                _G.QUI_RefreshActionBarFade()
            end
        else
            StartActionBarsFade(1)
        end
    else
        StartActionBarsFade(vis and vis.fadeOutAlpha or 0)
    end
end

local function SetupActionBarsMouseoverDetector()
    local vis = GetActionBarsVisibilitySettings()

    if ActionBarsVisibility.mouseoverDetector then
        ActionBarsVisibility.mouseoverDetector:SetScript("OnUpdate", nil)
        ActionBarsVisibility.mouseoverDetector:Hide()
        ActionBarsVisibility.mouseoverDetector = nil
    end

    if ActionBarsVisibility.leaveTimer then
        ActionBarsVisibility.leaveTimer:Cancel()
        ActionBarsVisibility.leaveTimer = nil
    end
    ActionBarsVisibility.mouseOver = false

    if not vis or vis.showAlways or not vis.showOnMouseover then
        return
    end

    local abFrames = GetActionBarFrames()
    local hoverCount = 0

    for _, entry in ipairs(abFrames) do
        local frame = entry.container
        if frame and not _mouseoverHooked[frame] then
            _mouseoverHooked[frame] = true

            frame:HookScript("OnEnter", function()
                if ActionBarsVisibility.leaveTimer then
                    ActionBarsVisibility.leaveTimer:Cancel()
                    ActionBarsVisibility.leaveTimer = nil
                end
                hoverCount = hoverCount + 1
                if hoverCount == 1 then
                    ActionBarsVisibility.mouseOver = true
                    UpdateActionBarsVisibility()
                end
            end)

            frame:HookScript("OnLeave", function()
                hoverCount = math.max(0, hoverCount - 1)
                if hoverCount == 0 then
                    if ActionBarsVisibility.leaveTimer then
                        ActionBarsVisibility.leaveTimer:Cancel()
                    end
                    ActionBarsVisibility.leaveTimer = C_Timer.NewTimer(0.3, function()
                        ActionBarsVisibility.leaveTimer = nil
                        if hoverCount == 0 then
                            ActionBarsVisibility.mouseOver = false
                            UpdateActionBarsVisibility()
                        end
                    end)
                end
            end)
        end
    end

    local detector = CreateFrame("Frame", nil, UIParent)
    detector:EnableMouse(false)
    local pollInterval = 0
    detector:SetScript("OnUpdate", function(self, elapsed)
        pollInterval = pollInterval + elapsed
        if pollInterval < 0.1 then return end
        pollInterval = 0

        if ActionBarsVisibility.mouseOver then return end
        if not ActionBarsVisibility.currentlyHidden
            and not (ActionBarsVisibility.isFading and ActionBarsVisibility.fadeTargetAlpha < 1) then
            return
        end

        local containers = ns.ActionBarsOwned and ns.ActionBarsOwned.containers
        if not containers then return end
        for _, container in pairs(containers) do
            local alpha = container and container.GetAlpha and ReadNumber(container:GetAlpha(), 1) or 1
            if container and alpha < 0.99 and container:IsMouseOver() then
                if ActionBarsVisibility.leaveTimer then
                    ActionBarsVisibility.leaveTimer:Cancel()
                    ActionBarsVisibility.leaveTimer = nil
                end
                hoverCount = 1
                ActionBarsVisibility.mouseOver = true
                UpdateActionBarsVisibility()
                return
            end
        end
    end)
    ActionBarsVisibility.mouseoverDetector = detector
end

local ChatVisibility = {
    currentlyHidden = false,
    isFading = false,
    fadeStart = 0,
    fadeStartAlpha = 1,
    fadeTargetAlpha = 1,
    fadeTargets = nil,
    fadeFrame = nil,
    mouseOver = false,
    mouseoverDetector = nil,
    leaveTimer = nil,
}

local function GetChatVisibilitySettings()
    if QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.chatVisibility then
        return QUICore.db.profile.chatVisibility
    end
    return nil
end

local function GetChatFrames()
    local frames = {}
    for i = 1, NUM_CHAT_WINDOWS do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame and chatFrame:IsShown() then
            frames[#frames + 1] = chatFrame
        end
    end
    if _G.GeneralDockManager then
        frames[#frames + 1] = _G.GeneralDockManager
    end
    return frames
end

local function ShouldChatBeVisible()
    local vis = GetChatVisibilitySettings()
    if not vis then return true end

    if vis.showAlways then
        if ShouldHideForLocationRules(vis, true) then return false end
        return true
    end

    if vis.showWhenTargetExists and UnitExists("target") then return true end
    if vis.showInCombat and UnitAffectingCombat("player") then return true end
    if vis.showInGroup and IsPlayerInGroup() then return true end
    if vis.showInInstance and IsPlayerInInstance() then return true end
    if vis.showOnMouseover and ChatVisibility.mouseOver then return true end
    if vis.showWhenMounted and Helpers.IsPlayerMounted() then return true end

    if ShouldHideForLocationRules(vis, true) then return false end

    return false
end

local function OnChatFadeUpdate(self)
    local Suppress = ns.QUI and ns.QUI.Chat and ns.QUI.Chat.BlizzardSuppress
    if Suppress and Suppress.IsActive and Suppress.IsActive() then
        ChatVisibility.isFading = false
        ChatVisibility.currentlyHidden = (ReadNumber(ChatVisibility.fadeTargetAlpha, 1) < 1)
        ChatVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
        return
    end
    local targetAlpha = ReadNumber(ChatVisibility.fadeTargetAlpha, 1)
    local vis = GetChatVisibilitySettings()
    local duration = (vis and vis.fadeDuration) or 0.2
    if duration <= 0 then duration = 0.01 end

    local now = GetTime()
    local elapsedTime = now - ChatVisibility.fadeStart
    local progress = math.min(elapsedTime / duration, 1)

    local startAlpha = ReadNumber(ChatVisibility.fadeStartAlpha, targetAlpha)
    local alpha = startAlpha + (targetAlpha - startAlpha) * progress

    local frames = ChatVisibility.fadeTargets or GetChatFrames()
    for _, frame in ipairs(frames) do
        ns.SafeCallMethodIfPresent("best-effort-style", frame, "SetAlpha", alpha)
    end

    if progress >= 1 then
        ChatVisibility.isFading = false
        ChatVisibility.currentlyHidden = (targetAlpha < 1)
        ChatVisibility.fadeTargets = nil
        self:SetScript("OnUpdate", nil)
    end
end

local function StartChatFade(targetAlpha)
    local Suppress = ns.QUI and ns.QUI.Chat and ns.QUI.Chat.BlizzardSuppress
    if Suppress and Suppress.IsActive and Suppress.IsActive() then return end

    local frames = GetChatFrames()
    if #frames == 0 then return end

    local rawAlpha = frames[1]:GetAlpha()
    local currentAlpha = ReadNumber(rawAlpha, targetAlpha)

    if math.abs(currentAlpha - targetAlpha) < 0.01 then
        ChatVisibility.currentlyHidden = (targetAlpha < 1)
        ChatVisibility.fadeStartAlpha = targetAlpha
        ChatVisibility.fadeTargetAlpha = targetAlpha
        return
    end

    ChatVisibility.isFading = true
    ChatVisibility.fadeStart = GetTime()
    ChatVisibility.fadeStartAlpha = currentAlpha
    ChatVisibility.fadeTargetAlpha = targetAlpha
    ChatVisibility.fadeTargets = frames

    if not ChatVisibility.fadeFrame then
        ChatVisibility.fadeFrame = CreateFrame("Frame")
    end
    ChatVisibility.fadeFrame:SetScript("OnUpdate", OnChatFadeUpdate)
end

local function UpdateChatVisibility()
    if Helpers.IsEditModeActive() or Helpers.IsLayoutModeActive() then
        StartChatFade(1)
        return
    end

    local shouldShow = ShouldChatBeVisible()
    local vis = GetChatVisibilitySettings()

    if shouldShow then
        StartChatFade(1)
    else
        StartChatFade(vis and vis.fadeOutAlpha or 0)
    end
end

local function SetupChatMouseoverDetector()
    local vis = GetChatVisibilitySettings()

    if ChatVisibility.mouseoverDetector then
        ChatVisibility.mouseoverDetector:SetScript("OnUpdate", nil)
        ChatVisibility.mouseoverDetector:Hide()
        ChatVisibility.mouseoverDetector = nil
    end

    if ChatVisibility.leaveTimer then
        ChatVisibility.leaveTimer:Cancel()
        ChatVisibility.leaveTimer = nil
    end
    ChatVisibility.mouseOver = false

    if not vis or vis.showAlways or not vis.showOnMouseover then
        return
    end

    local chatFrames = GetChatFrames()
    local hoverCount = 0

    for _, frame in ipairs(chatFrames) do
        if frame and not _mouseoverHooked[frame] then
            _mouseoverHooked[frame] = true

            frame:HookScript("OnEnter", function()
                if ChatVisibility.leaveTimer then
                    ChatVisibility.leaveTimer:Cancel()
                    ChatVisibility.leaveTimer = nil
                end
                hoverCount = hoverCount + 1
                if hoverCount == 1 then
                    ChatVisibility.mouseOver = true
                    UpdateChatVisibility()
                end
            end)

            frame:HookScript("OnLeave", function()
                hoverCount = math.max(0, hoverCount - 1)
                if hoverCount == 0 then
                    if ChatVisibility.leaveTimer then
                        ChatVisibility.leaveTimer:Cancel()
                    end
                    ChatVisibility.leaveTimer = C_Timer.NewTimer(0.5, function()
                        ChatVisibility.leaveTimer = nil
                        if hoverCount == 0 then
                            ChatVisibility.mouseOver = false
                            UpdateChatVisibility()
                        end
                    end)
                end
            end)
        end
    end

    local detector = CreateFrame("Frame", nil, UIParent)
    detector:EnableMouse(false)
    ChatVisibility.mouseoverDetector = detector
end

local visibilityEventFrame = CreateFrame("Frame")
visibilityEventFrame:RegisterEvent("ADDON_LOADED")
visibilityEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
visibilityEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
visibilityEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
visibilityEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
visibilityEventFrame:RegisterEvent("GROUP_JOINED")
visibilityEventFrame:RegisterEvent("GROUP_LEFT")
visibilityEventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
visibilityEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
visibilityEventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
visibilityEventFrame:RegisterEvent("PLAYER_STARTED_MOVING")
visibilityEventFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
visibilityEventFrame:RegisterEvent("PLAYER_IMPULSE_APPLIED")
visibilityEventFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
visibilityEventFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
visibilityEventFrame:RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR")
visibilityEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
visibilityEventFrame:RegisterEvent("PLAYER_FLAGS_CHANGED")
visibilityEventFrame:RegisterEvent("PLAYER_IS_GLIDING_CHANGED")
visibilityEventFrame:RegisterUnitEvent("UNIT_HEALTH", "player")
visibilityEventFrame:RegisterUnitEvent("UNIT_MAXHEALTH", "player")

local _pendingSetupTimer = nil

local visCoalesceFrame = CreateFrame("Frame")
visCoalesceFrame:Hide()
visCoalesceFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    UpdateCDMVisibility()
    UpdateCustomTrackersVisibility()
    UpdateUnitframesVisibility()
    UpdateActionBarsVisibility()
    UpdateChatVisibility()
end)

visibilityEventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_FLAGS_CHANGED" then
        local unit = ...
        if unit ~= "player" then return end
    end
    if event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        local unit = ...
        if unit ~= "player" then return end
    end

    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        if UpdateUnitframesVisibility then UpdateUnitframesVisibility() end
    end

    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
    end

    if event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        if _pendingSetupTimer then
            _pendingSetupTimer:Cancel()
        end
        _pendingSetupTimer = C_Timer.NewTimer(2.0, function()
            _pendingSetupTimer = nil
            SetupCDMMouseoverDetector()
                SetupCustomTrackersMouseoverDetector()
            SetupUnitframesMouseoverDetector()
            SetupActionBarsMouseoverDetector()
            SetupChatMouseoverDetector()
            UpdateCDMVisibility()
            UpdateCustomTrackersVisibility()
        end)
    end

    if (event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA")
        and (UnitframesVisibility.currentlyHidden
            or CustomTrackersVisibility.currentlyHidden
            or ActionBarsVisibility.currentlyHidden
            or ChatVisibility.currentlyHidden) then
        UpdateCDMVisibility()
        return
    end

    visCoalesceFrame:Show()
end)

_G.QUI_RefreshCDMVisibility = function()
    _cdmFramesDirty = true
    UpdateCDMVisibility()
end
ns.RefreshCDMVisibilityInstant = function()
    _cdmFramesDirty = true
    UpdateCDMVisibility()
    SnapCDMFadeToTarget()
end
_G.QUI_RefreshCustomTrackersVisibility = UpdateCustomTrackersVisibility
_G.QUI_RefreshUnitframesVisibility = UpdateUnitframesVisibility
_G.QUI_RefreshCDMMouseover = SetupCDMMouseoverDetector
_G.QUI_RefreshCustomTrackersMouseover = SetupCustomTrackersMouseoverDetector
_G.QUI_RefreshUnitframesMouseover = SetupUnitframesMouseoverDetector
_G.QUI_ShouldCDMBeVisible = ShouldCDMBeVisible
_G.QUI_ShouldCustomTrackersBeVisible = ShouldCustomTrackersBeVisible
_G.QUI_ShouldUnitframesBeVisible = ShouldUnitframesBeVisible
_G.QUI_RefreshActionBarsVisibility = UpdateActionBarsVisibility
_G.QUI_RefreshActionBarsMouseover = SetupActionBarsMouseoverDetector
_G.QUI_RefreshChatVisibility = UpdateChatVisibility
_G.QUI_RefreshChatMouseover = SetupChatMouseoverDetector

if ns.Registry then
    ns.Registry:Register("cdmVisibility", {
        refresh = _G.QUI_RefreshCDMVisibility,
        priority = 10,
        group = "cooldowns",
        importCategories = { "cdm" },
    })
    ns.Registry:Register("customTrackersVisibility", {
        refresh = _G.QUI_RefreshCustomTrackersVisibility,
        priority = 10,
        group = "cooldowns",
        importCategories = { "customTrackers" },
    })
end

ns.HookFrameForMouseover = function(frame)
    HookFrameForMouseover(frame)
    if HookCustomTrackerFrameForMouseover then
        HookCustomTrackerFrameForMouseover(frame)
    end
end
ns.InvalidateCDMFrameCache = InvalidateCDMFrameCache
ns.GetCDMFrameCacheStats = function()
    return {
        dirty = _cdmFramesDirty and true or false,
        size  = #_cdmFramesCache,
    }
end

local function RefreshAllVisibility()
    UpdateCDMVisibility()
    UpdateCustomTrackersVisibility()
    UpdateUnitframesVisibility()
    UpdateActionBarsVisibility()
    UpdateChatVisibility()
end

C_Timer.After(2, function()
    local core = ns.Helpers and ns.Helpers.GetCore and ns.Helpers.GetCore()
    if not core then return end
    if core.RegisterLayoutModeEnter then
        core:RegisterLayoutModeEnter(RefreshAllVisibility)
    end
    if core.RegisterLayoutModeExit then
        core:RegisterLayoutModeExit(RefreshAllVisibility)
    end
end)
