-- customglows.lua
-- Custom glow effects for Essential and Utility CDM icons.
-- Simplified: applies LibCustomGlow directly to addon-owned icon frames.
-- No overlay frame indirection, no Blizzard glow suppression needed.

local _, ns = ...
local Helpers = ns.Helpers

local function IsCDMRuntimeEnabled()
    local checker = _G.QUI_IsCDMMasterEnabled
    return type(checker) ~= "function" or checker()
end

-- Pandemic step curve: lazily built, cached. The curve evaluates C-side and
-- yields a secret userdata (LuaCurveEvaluatedResult) that flows directly into
-- SetAlpha — never compared, arithmetic'd, or read into Lua. Mirrors the HP
-- alpha-curve pattern in hud_visibility.lua.
local _pandemicCurve

local function GetPandemicCurve()
    if _pandemicCurve then return _pandemicCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateCurve
       or not Enum or not Enum.LuaCurveType then
        return nil
    end
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    -- Negative-side anchor: if the cached _lastAuraDurObj outlives the
    -- aura it represents (icon-side state didn't observe the removal in
    -- time, or the resolver returned r.durObj=nil while r.isActive=true
    -- and ApplyAuraStateToIcon kept the stale cached durObj), then
    -- EvaluateRemainingPercent on that durObj produces a NEGATIVE value
    -- once GetTime() is past startTime+duration. Without this anchor the
    -- step curve falls back to the lowest defined point's value (1) for
    -- any x below 0, leaving the glow stuck on permanently.
    curve:AddPoint(-1.0, 0) -- expired / negative percent → hide
    curve:AddPoint(0.0, 1)  -- 0..<30% remaining → glow visible
    curve:AddPoint(0.3, 0)  -- 30%+ remaining → glow hidden
    _pandemicCurve = curve
    return curve
end

-- Get LibCustomGlow for custom glow styles
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)

-- Texture assets for overlay glow types
local FLASH_TEXTURE = [[Interface\AddOns\QUI\assets\iconskin\Flash]]
local HAMMER_TEXTURE = [[Interface\AddOns\QUI\assets\quazii_hammer]]

-- Get IsSpellOverlayed API: try C_ namespace (12.0+), fall back to deprecated global
local IsSpellOverlayed = (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed)
    or _G.IsSpellOverlayed

-- Event-based overlay tracking: ultimate fallback when neither query API exists,
-- and also used to check override spell IDs that the API might miss.
local overlayedSpells = {}  -- [spellID] = true
local overlayedSpellCounts = {}  -- [spellID] = refcount
local overlayedSourceMap = {}  -- [sourceSpellID] = { [candidateID] = true }

local function ForEachSpellCandidate(spellID, callback)
    if not spellID or not callback then return end
    spellID = spellID
    if not spellID then return end

    callback(spellID)

    if C_Spell and C_Spell.GetOverrideSpell then
        local ok, overrideID = pcall(C_Spell.GetOverrideSpell, spellID)
        overrideID = ok and overrideID or nil
        if ok and overrideID and overrideID ~= spellID then
            callback(overrideID)
        end
    end
end

local function GetPreferredSpellID(icon)
    if not icon or not icon._spellEntry then return nil end

    local entry = icon._spellEntry

    if icon._runtimeSpellID then
        return icon._runtimeSpellID
    end

    local CDMSpellData = ns.CDMSpellData
    if CDMSpellData and CDMSpellData.ResolveDisplaySpellID then
        local resolvedID = CDMSpellData:ResolveDisplaySpellID(entry)
        if resolvedID then
            return resolvedID
        end
    end

    return entry.overrideSpellID or entry.spellID or entry.id
end

local function ClearOverlaySource(sourceSpellID)
    local mapped = sourceSpellID and overlayedSourceMap[sourceSpellID]
    if not mapped then return end
    for candidateID in pairs(mapped) do
        local count = (overlayedSpellCounts[candidateID] or 0) - 1
        if count > 0 then
            overlayedSpellCounts[candidateID] = count
            overlayedSpells[candidateID] = true
        else
            overlayedSpellCounts[candidateID] = nil
            overlayedSpells[candidateID] = nil
        end
    end
    overlayedSourceMap[sourceSpellID] = nil
end

local function MarkOverlaySource(sourceSpellID)
    if not sourceSpellID then return end
    ClearOverlaySource(sourceSpellID)
    local mapped = {}
    ForEachSpellCandidate(sourceSpellID, function(candidateID)
        if candidateID then
            mapped[candidateID] = true
            overlayedSpellCounts[candidateID] = (overlayedSpellCounts[candidateID] or 0) + 1
            overlayedSpells[candidateID] = true
        end
    end)
    overlayedSourceMap[sourceSpellID] = mapped
end

local _iconRawSeen = {}
local _iconCandidateSeen = {}

local function ForEachIconSpellID(icon, callback)
    if not icon or not icon._spellEntry or not callback then return end

    local entry = icon._spellEntry
    local rawSeen = _iconRawSeen
    local candidateSeen = _iconCandidateSeen
    wipe(rawSeen)
    wipe(candidateSeen)

    local function VisitRaw(id)
        if not id or rawSeen[id] then return end
        rawSeen[id] = true
        ForEachSpellCandidate(id, function(candidateID)
            if candidateID and not candidateSeen[candidateID] then
                candidateSeen[candidateID] = true
                callback(candidateID)
            end
        end)
    end

    -- entry.* come from our spell registration and are always non-secret.
    VisitRaw(entry.spellID)
    VisitRaw(entry.overrideSpellID)
    VisitRaw(entry.id)

    -- Runtime override may be a secret value in combat; sanitize at the
    -- boundary. Combat misses here are covered by
    -- SPELL_ACTIVATION_OVERLAY_GLOW events, which deliver non-secret
    -- spellIDs directly to ScanGlowsForSpell.
    VisitRaw(icon._runtimeSpellID)

    local CDMSpellData = ns.CDMSpellData
    if CDMSpellData and CDMSpellData.ResolveDisplaySpellID then
        VisitRaw(CDMSpellData:ResolveDisplaySpellID(entry))
    end

    if entry.linkedSpellIDs then
        for _, linkedSpellID in ipairs(entry.linkedSpellIDs) do
            VisitRaw(linkedSpellID)
        end
    end

    wipe(rawSeen)
    wipe(candidateSeen)
end
-- Safe wrapper: C_Spell.IsSpellUsable can return secret values in Midnight.
local function SafeIsSpellUsable(spellID)
    if not spellID or not C_Spell or not C_Spell.IsSpellUsable then return true, false end
    local ok, usable, noMana = pcall(C_Spell.IsSpellUsable, spellID)
    if not ok then return true, false end
    return usable and true or false, noMana and true or false
end

-- Check if an icon's spell is fully castable: off cooldown, no active aura, has resources.
local function IsSpellCastable(icon)
    if not icon or not icon._spellEntry then return false end
    if icon._auraActive then return false end
    if icon._hasCooldownActive then return false end
    local spellID = icon._runtimeSpellID
        or icon._spellEntry.overrideSpellID
        or icon._spellEntry.spellID
    if not spellID then return false end
    return SafeIsSpellUsable(spellID)
end

local function GetSpellGlowOverride(icon)
    if not icon or not icon._spellEntry then return nil end

    local entry = icon._spellEntry
    local CDMSpellData = ns.CDMSpellData
    if not CDMSpellData or not entry.viewerType then return nil end

    local lookupID = entry.spellID or entry.id
    if not lookupID then return nil end

    return CDMSpellData:GetSpellOverride(entry.viewerType, lookupID)
end

local GetSettings = Helpers.CreateDBGetter("customGlow")

local function IsPandemicMirroringEnabled(icon)
    if not icon or not icon._spellEntry then return false end

    local settings = GetSettings()
    if not settings then return true end

    local viewerType = icon._spellEntry.viewerType
    if not viewerType then return false end

    -- Built-in viewers and custom containers all use the viewerType as
    -- the settings-key prefix.
    local debuffKey = viewerType .. "PandemicDebuffEnabled"
    local buffKey   = viewerType .. "PandemicBuffEnabled"
    local debuffOn = settings[debuffKey] ~= false
    local buffOn   = settings[buffKey]   ~= false

    -- Pick the relevant toggle from the cached aura type. When the type
    -- is unknown (aura first observed in combat without auraData), fall
    -- back to "show if either toggle is on" so combat-applied auras
    -- don't suddenly lose their pandemic glow.
    local isHarmful = icon._auraIsHarmful
    if isHarmful == true  then return debuffOn end
    if isHarmful == false then return buffOn   end
    return debuffOn or buffOn
end

-- Forward declarations.
local ClearPandemicState
local SyncGlowForIcon
local UpdatePandemicGlow

-- Track which icons currently have active glows
local activeGlowIcons = {}  -- [icon] = true

-- Reverse lookup: spellID → list of icons that track it.
-- Allows O(1) dispatch on SHOW/HIDE events instead of scanning all icons.
local spellIdToGlowIcons = {}  -- [spellID] = {icon, ...}
do local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "CDM_overlayedSpells", tbl = overlayedSpells }
    mp[#mp + 1] = { name = "CDM_glowSpellMap",    tbl = spellIdToGlowIcons }
    mp[#mp + 1] = { name = "CDM_activeGlows",     tbl = activeGlowIcons }
end

local function AddGlowMapID(spellID, icon)
    if not spellID then return end
    local list = spellIdToGlowIcons[spellID]
    if not list then
        list = {}
        spellIdToGlowIcons[spellID] = list
    end
    list[#list + 1] = icon
end

local function RebuildGlowSpellMap()
    wipe(spellIdToGlowIcons)
    local CDMIcons = ns.CDMIcons
    if not CDMIcons then return end
    if CDMIcons.ForEachIcon then
        CDMIcons:ForEachIcon(function(icon)
            if icon._spellEntry then
                local spellID = icon._spellEntry.spellID
                local overrideID = icon._spellEntry.overrideSpellID
                AddGlowMapID(spellID, icon)
                if overrideID and overrideID ~= spellID then
                    AddGlowMapID(overrideID, icon)
                end
            end
        end)
        return
    end
    for _, viewerType in ipairs({"essential", "utility"}) do
        local pool = CDMIcons:GetIconPool(viewerType)
        for _, icon in ipairs(pool) do
            if icon._spellEntry then
                local spellID = icon._spellEntry.spellID
                local overrideID = icon._spellEntry.overrideSpellID
                AddGlowMapID(spellID, icon)
                if overrideID and overrideID ~= spellID then
                    AddGlowMapID(overrideID, icon)
                end
            end
        end
    end
end

-- SETTINGS ACCESS
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- DETERMINE VIEWER TYPE FROM ICON
-- Uses icon._spellEntry.viewerType instead of checking parent frame.
---------------------------------------------------------------------------
local function GetViewerType(icon)
    if not icon or not icon._spellEntry then return nil end
    local vt = icon._spellEntry.viewerType
    if vt == "essential" then return "Essential"
    elseif vt == "utility" then return "Utility"
    elseif vt then return vt  -- custom container key
    end
    return nil
end

---------------------------------------------------------------------------
-- GET SETTINGS FOR VIEWER TYPE
---------------------------------------------------------------------------
local function GetViewerSettings(viewerType)
    local settings = GetSettings()
    if not settings then return nil end

    if viewerType == "Essential" then
        if not settings.essentialEnabled then return nil end
        return {
            enabled = true,
            glowType = settings.essentialGlowType or "Pixel Glow",
            color = settings.essentialColor or {0.95, 0.95, 0.32, 1},
            lines = settings.essentialLines or 14,
            frequency = settings.essentialFrequency or 0.25,
            thickness = settings.essentialThickness or 2,
            scale = settings.essentialScale or 1,
            xOffset = settings.essentialXOffset or 0,
            yOffset = settings.essentialYOffset or 0,
        }
    elseif viewerType == "Utility" then
        if not settings.utilityEnabled then return nil end
        return {
            enabled = true,
            glowType = settings.utilityGlowType or "Pixel Glow",
            color = settings.utilityColor or {0.95, 0.95, 0.32, 1},
            lines = settings.utilityLines or 14,
            frequency = settings.utilityFrequency or 0.25,
            thickness = settings.utilityThickness or 2,
            scale = settings.utilityScale or 1,
            xOffset = settings.utilityXOffset or 0,
            yOffset = settings.utilityYOffset or 0,
        }
    else
        -- Custom container: uses viewerType as prefix (e.g., "custom_1Enabled")
        local prefix = viewerType
        if not settings[prefix .. "Enabled"] then return nil end
        return {
            enabled = true,
            glowType = settings[prefix .. "GlowType"] or "Pixel Glow",
            color = settings[prefix .. "Color"] or {0.95, 0.95, 0.32, 1},
            lines = settings[prefix .. "Lines"] or 14,
            frequency = settings[prefix .. "Frequency"] or 0.25,
            thickness = settings[prefix .. "Thickness"] or 2,
            scale = settings[prefix .. "Scale"] or 1,
            xOffset = settings[prefix .. "XOffset"] or 0,
            yOffset = settings[prefix .. "YOffset"] or 0,
        }
    end

    return nil
end

---------------------------------------------------------------------------
-- GLOW APPLICATION (supports 3 glow types via LibCustomGlow)
-- Applied directly to owned icons — no overlay frame needed.
---------------------------------------------------------------------------

-- Ensure glow frame renders above the Cooldown swipe.
-- LibCustomGlow sets glow at icon:GetFrameLevel() + 8, but HUD layering
-- can push CooldownFrameTemplate above that. Reference the Cooldown frame
-- directly (same pattern as TextOverlay in cdm_icons.lua:659).
-- Layer order: Cooldown swipe (cdLevel) → Glow (+1) → Text (+1) → ClickButton (+2)
local function EnsureGlowAboveCooldown(icon, glowFrame)
    if not glowFrame or not icon or not icon.Cooldown then return end

    local cdLevel = icon.Cooldown:GetFrameLevel()
    local glowLevel = glowFrame:GetFrameLevel()
    if glowLevel <= cdLevel then
        glowLevel = cdLevel + 1
        glowFrame:SetFrameLevel(glowLevel)
    end

    -- Keep stack/proc text above glow and click button above text.
    local CDMIcons = ns.CDMIcons
    if CDMIcons and CDMIcons.EnsureTextOverlayLevel then
        CDMIcons:EnsureTextOverlayLevel(icon, glowLevel + 1)
    end
end

-- Shared helper: create or reuse a pulsing texture overlay on an icon.
-- key: unique frame key on icon (e.g. "_QUIFlashGlow")
-- texturePath: texture file path
local function StartTextureGlow(icon, key, texturePath, color)
    local frame = icon[key]
    if not frame then
        frame = CreateFrame("Frame", nil, icon)
        frame:SetAllPoints(icon)
        icon[key] = frame

        local tex = frame:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(texturePath)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetBlendMode("ADD")
        tex:SetAllPoints(frame)
        frame.texture = tex

        local ag = frame:CreateAnimationGroup()
        ag:SetLooping("REPEAT")

        local fadeIn = ag:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0.3)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(0.4)
        fadeIn:SetOrder(1)

        local fadeOut = ag:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(1)
        fadeOut:SetToAlpha(0.3)
        fadeOut:SetDuration(0.4)
        fadeOut:SetOrder(2)

        frame.animGroup = ag
    end

    local r, g, b, a = 1, 1, 1, 1
    if color then r, g, b, a = color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1 end
    frame.texture:SetVertexColor(r, g, b, a)
    frame:Show()
    frame.animGroup:Play()
    return frame
end

local function StopTextureGlow(icon, key)
    local frame = icon[key]
    if frame then
        frame.animGroup:Stop()
        frame:Hide()
    end
end

local StopGlow

local function ApplyLibCustomGlow(icon, viewerSettings)
    if not LCG or not icon then return false end

    local glowType = viewerSettings.glowType
    local color = viewerSettings.color
    local lines = viewerSettings.lines
    local frequency = viewerSettings.frequency
    local thickness = viewerSettings.thickness
    local scale = viewerSettings.scale or 1
    local xOffset = viewerSettings.xOffset or 0

    -- Stop any existing glow first
    StopGlow(icon)

    if glowType == "Pixel Glow" then
        LCG.PixelGlow_Start(icon, color, lines, frequency, nil, thickness, 0, 0, true, "_QUICustomGlow")
        local glowFrame = icon["_PixelGlow_QUICustomGlow"]
        if glowFrame then
            glowFrame:ClearAllPoints()
            glowFrame:SetPoint("TOPLEFT", icon, "TOPLEFT", -xOffset, xOffset)
            glowFrame:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", xOffset, -xOffset)
            EnsureGlowAboveCooldown(icon, glowFrame)
        end

    elseif glowType == "Autocast Shine" then
        LCG.AutoCastGlow_Start(icon, color, lines, frequency, scale, 0, 0, "_QUICustomGlow")
        local glowFrame = icon["_AutoCastGlow_QUICustomGlow"]
        if glowFrame then
            glowFrame:ClearAllPoints()
            glowFrame:SetPoint("TOPLEFT", icon, "TOPLEFT", -xOffset, xOffset)
            glowFrame:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", xOffset, -xOffset)
            EnsureGlowAboveCooldown(icon, glowFrame)
        end

    elseif glowType == "Button Glow" then
        LCG.ButtonGlow_Start(icon, color, frequency)
        EnsureGlowAboveCooldown(icon, icon["_ButtonGlow"])

    elseif glowType == "Flash" then
        local frame = StartTextureGlow(icon, "_QUIFlashGlow", FLASH_TEXTURE, color)
        EnsureGlowAboveCooldown(icon, frame)

    elseif glowType == "Hammer" then
        local frame = StartTextureGlow(icon, "_QUIHammerGlow", HAMMER_TEXTURE, color)
        EnsureGlowAboveCooldown(icon, frame)

    elseif glowType == "Proc Glow" then
        LCG.ProcGlow_Start(icon, {
            key = "_QUICustomGlow",
            color = color,
            startAnim = true,
            xOffset = xOffset,
            yOffset = viewerSettings.yOffset or 0,
        })
        local glowFrame = icon["_ProcGlow_QUICustomGlow"]
        if glowFrame then
            EnsureGlowAboveCooldown(icon, glowFrame)
        end
    end

    activeGlowIcons[icon] = true
    return true
end

---------------------------------------------------------------------------
-- START / STOP GLOW
---------------------------------------------------------------------------
-- Per-spell glow color override helper: returns a copy of viewerSettings
-- with the color replaced if a per-spell glowColor override exists.
local function ApplyGlowColorOverride(viewerSettings, spellOvr)
    if not spellOvr or not spellOvr.glowColor then return viewerSettings end
    -- Shallow copy so we don't mutate the cached settings table
    local copy = {}
    for k, v in pairs(viewerSettings) do copy[k] = v end
    copy.color = spellOvr.glowColor
    return copy
end

local function StartGlow(icon, spellOvr)
    if not icon then return end
    if activeGlowIcons[icon] then return end

    local viewerType = GetViewerType(icon)
    if not viewerType then return end

    local viewerSettings = GetViewerSettings(viewerType)
    if not viewerSettings then return end

    -- Apply per-spell glow color override
    viewerSettings = ApplyGlowColorOverride(viewerSettings, spellOvr)

    ApplyLibCustomGlow(icon, viewerSettings)
end

StopGlow = function(icon)
    if not icon then return end
    if LCG then
        pcall(LCG.PixelGlow_Stop, icon, "_QUICustomGlow")
        pcall(LCG.AutoCastGlow_Stop, icon, "_QUICustomGlow")
        pcall(LCG.ButtonGlow_Stop, icon)
        pcall(LCG.ProcGlow_Stop, icon, "_QUICustomGlow")
    end
    StopTextureGlow(icon, "_QUIFlashGlow")
    StopTextureGlow(icon, "_QUIHammerGlow")
    activeGlowIcons[icon] = nil
end

---------------------------------------------------------------------------
-- PANDEMIC GLOW: dedicated overlay frame whose alpha is driven by a
-- C_CurveUtil step curve evaluated against the icon's active aura
-- DurationObject. The curve evaluates C-side and the result is secret
-- userdata that flows directly into SetAlpha — no Lua-side compare or
-- arithmetic. Mirrors hud_visibility's UnitHealthPercent + curve pattern.
---------------------------------------------------------------------------
local PANDEMIC_TEXTURE = FLASH_TEXTURE  -- reuse the proc-glow flash sheet

local function EnsurePandemicGlowFrame(icon)
    if not icon then return nil end
    local frame = icon.PandemicGlow
    if frame then return frame end

    frame = CreateFrame("Frame", nil, icon)
    frame:SetAllPoints(icon)
    frame:SetAlpha(0)

    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(PANDEMIC_TEXTURE)
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetBlendMode("ADD")
    tex:SetAllPoints(frame)
    tex:SetVertexColor(1, 0.85, 0.2, 1)
    frame.texture = tex

    icon.PandemicGlow = frame
    EnsureGlowAboveCooldown(icon, frame)
    return frame
end

UpdatePandemicGlow = function(icon)
    if not icon or not icon._spellEntry then return end

    local frame = icon.PandemicGlow
    local enabled = IsPandemicMirroringEnabled(icon)
    if not enabled then
        if frame then frame:SetAlpha(0) end
        return
    end

    local spellOvr = GetSpellGlowOverride(icon)
    if spellOvr and spellOvr.glowEnabled == false then
        if frame then frame:SetAlpha(0) end
        return
    end

    if not icon._auraActive or not icon._lastAuraDurObj then
        if frame then frame:SetAlpha(0) end
        return
    end

    local curve = GetPandemicCurve()
    if not curve then
        if frame then frame:SetAlpha(0) end
        return
    end

    frame = frame or EnsurePandemicGlowFrame(icon)
    if not frame then return end

    local durObj = icon._lastAuraDurObj

    -- Gate against permanent / no-duration auras. For an aura with no
    -- duration, EvaluateRemainingPercent lands at the start of the step
    -- curve (alpha 1) and the glow shows permanently. DurationObject:IsZero
    -- is a stable per-aura property (not derived from elapsed/remaining),
    -- and EvaluateColorValueFromBoolean keeps the (potentially-secret) bool
    -- C-side — the result is a normal scalar safe for SetAlpha. Same pattern
    -- as cdm_bars.lua's permanent-aura overlay drive.
    --   IsZero=true  (permanent) → texture alpha 0 → glow hidden
    --   IsZero=false (timed)     → texture alpha 1 → curve drives frame alpha
    if frame.texture
       and durObj.IsZero
       and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
        local okZ, isZero = pcall(durObj.IsZero, durObj)
        if okZ then
            local okA, gate = pcall(C_CurveUtil.EvaluateColorValueFromBoolean,
                isZero, 0, 1)
            if okA then
                pcall(frame.texture.SetAlpha, frame.texture, gate)
            end
        end
    end

    -- Curve evaluates C-side; result is secret userdata; SetAlpha accepts it
    -- natively. Never read back into Lua.
    frame:SetAlpha(durObj:EvaluateRemainingPercent(curve))
end

ClearPandemicState = function(icon)
    if not icon then return end
    if icon.PandemicGlow then
        icon.PandemicGlow:SetAlpha(0)
    end
end

---------------------------------------------------------------------------
-- CHECK OVERLAY STATE: query API + event-based tracking
---------------------------------------------------------------------------
local function IsOverlayQueryActive(spellID)
    if not spellID or not IsSpellOverlayed then return false end
    local ok, result = pcall(IsSpellOverlayed, spellID)
    return ok and result and true or false
end

local function IsOverlayed(spellID)
    if not spellID then return false end
    -- Prefer the live query API whenever it exists. The event cache is a
    -- fallback for clients/API paths where the query function is unavailable;
    -- otherwise a missed HIDE event can leave a spell looking permanently procced.
    if IsSpellOverlayed then
        return IsOverlayQueryActive(spellID)
    end
    return overlayedSpells[spellID] or false
end

local function EvaluateGlowForIcon(icon)
    if not icon or not icon:IsShown() or not icon._spellEntry then
        return false, nil
    end

    local entry = icon._spellEntry
    local viewerType = entry.viewerType
    local baseID = entry.spellID
    local overrideID = entry.overrideSpellID

    local spellOvr = GetSpellGlowOverride(icon)

    local shouldGlow
    if spellOvr and spellOvr.glowEnabled == false then
        shouldGlow = false
    elseif spellOvr and spellOvr.glowEnabled == true then
        shouldGlow = true
    else
        ForEachIconSpellID(icon, function(spellID)
            if not shouldGlow and IsOverlayed(spellID) then
                shouldGlow = true
            end
        end)
    end

    if not shouldGlow and spellOvr and spellOvr.procOnUsable == true then
        shouldGlow = IsSpellCastable(icon)
    end

    return shouldGlow and true or false, spellOvr
end

SyncGlowForIcon = function(icon)
    local shouldGlow, spellOvr = EvaluateGlowForIcon(icon)

    if shouldGlow and not activeGlowIcons[icon] then
        StartGlow(icon, spellOvr)
    elseif not shouldGlow and activeGlowIcons[icon] then
        StopGlow(icon)
    end

    UpdatePandemicGlow(icon)
end

---------------------------------------------------------------------------
-- SCAN ALL ICONS AND SYNC GLOW STATE
---------------------------------------------------------------------------
local function ScanAllGlows()
    local CDMIcons = ns.CDMIcons
    if not CDMIcons then return end

    if CDMIcons.ForEachIcon then
        CDMIcons:ForEachIcon(function(icon)
            if not icon:IsShown() then -- skip hidden icons (glow re-applied on layout refresh)
                -- noop: skip
            elseif icon._spellEntry then
                SyncGlowForIcon(icon)
            end
        end)
        return
    end

    for _, viewerType in ipairs({"essential", "utility"}) do
        local pool = CDMIcons:GetIconPool(viewerType)
        for _, icon in ipairs(pool) do
            if not icon:IsShown() then
                -- noop: skip
            elseif icon._spellEntry then
                SyncGlowForIcon(icon)
            end
        end
    end
end

---------------------------------------------------------------------------
-- TARGETED GLOW UPDATE FOR A SINGLE SPELL ID
-- O(1) lookup via reverse map instead of scanning all icons.
---------------------------------------------------------------------------
local _scanGlowVisited = {}

local function ScanGlowsForSpell(spellID)
    if not spellID then ScanAllGlows(); return end

    local CDMIcons = ns.CDMIcons
    if not CDMIcons then return end

    -- Deduplicate icons across candidates. Reuse scratch table because
    -- overlay events can fire in bursts during combat.
    local visited = _scanGlowVisited
    wipe(visited)
    local matched = false
    ForEachSpellCandidate(spellID, function(id)
        local icons = spellIdToGlowIcons[id]
        if icons then
            matched = true
            for i = 1, #icons do
                local icon = icons[i]
                if not visited[icon] then
                    visited[icon] = true
                    if icon:IsShown() and icon._spellEntry then
                        SyncGlowForIcon(icon)
                    end
                end
            end
        end
    end)

    if not matched then
        -- Proc events are infrequent; if the fast reverse map misses because
        -- Blizzard reported a related spellID we do not currently index,
        -- rescan all visible icons immediately so short overlays are not lost.
        ScanAllGlows()
    end

    wipe(visited)
end

---------------------------------------------------------------------------
-- REFRESH ALL GLOWS (called when settings change)
---------------------------------------------------------------------------
local _refreshStopScratch = {}

local function StopAllTrackedGlows()
    local toStop = _refreshStopScratch
    wipe(toStop)
    for icon in pairs(activeGlowIcons) do
        toStop[#toStop + 1] = icon
    end
    for _, icon in ipairs(toStop) do
        StopGlow(icon)
        if icon.PandemicGlow then
            icon.PandemicGlow:SetAlpha(0)
        end
    end
    wipe(toStop)
    wipe(activeGlowIcons)
end

local function RefreshAllGlows()
    -- Stop all current glows
    StopAllTrackedGlows()

    if not IsCDMRuntimeEnabled() then
        return
    end

    -- Rebuild reverse lookup and re-scan with current settings
    RebuildGlowSpellMap()
    ScanAllGlows()
end

---------------------------------------------------------------------------
-- EVENT HANDLING
-- SPELL_ACTIVATION_OVERLAY_GLOW events drive proc glow updates.
-- Track overlay state in overlayedSpells table for API-free fallback.
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

-- Coalesced usability glow scan: a short delay lets CDM's update finish first
-- so icon._hasCooldownActive is current when we check IsSpellCastable.
local usabilityGlowFrame = CreateFrame("Frame")
local _usabilityGlowPending = false
local _usabilityGlowElapsed = 0
local USABILITY_GLOW_DELAY = 0.1

local function UsabilityGlowOnUpdate(self, elapsed)
    if not IsCDMRuntimeEnabled() then
        self:SetScript("OnUpdate", nil)
        _usabilityGlowPending = false
        return
    end

    _usabilityGlowElapsed = _usabilityGlowElapsed + elapsed
    if _usabilityGlowElapsed < USABILITY_GLOW_DELAY then return end
    self:SetScript("OnUpdate", nil)
    _usabilityGlowPending = false
    ScanAllGlows()
end

local function ScheduleUsabilityGlowScan()
    if not IsCDMRuntimeEnabled() then return end
    if _usabilityGlowPending then return end
    _usabilityGlowPending = true
    _usabilityGlowElapsed = 0
    usabilityGlowFrame:SetScript("OnUpdate", UsabilityGlowOnUpdate)
end

eventFrame:SetScript("OnEvent", function(_, event, spellID)
    if not IsCDMRuntimeEnabled() then
        StopAllTrackedGlows()
        usabilityGlowFrame:SetScript("OnUpdate", nil)
        _usabilityGlowPending = false
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_USABLE" then
        ScheduleUsabilityGlowScan()
        return
    end
    if event == "PLAYER_TARGET_CHANGED" then
        ScheduleUsabilityGlowScan()
        return
    end
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" and spellID then
        MarkOverlaySource(spellID)
        ScanGlowsForSpell(spellID)
        return
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" and spellID then
        ClearOverlaySource(spellID)
        ScanGlowsForSpell(spellID)
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        wipe(overlayedSpells)
        wipe(overlayedSpellCounts)
        wipe(overlayedSourceMap)
    end
    ScanAllGlows()
end)

ns.QUI_PerfRegistry = ns.QUI_PerfRegistry or {}
ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "CDM_Glows", frame = eventFrame }

-- Low-frequency fallback scan to catch edge cases (e.g. icon replaced
-- with an already-active proc, no SHOW event fires for it)
local glowFallbackTicker = C_Timer.NewTicker(5, function()
    if IsCDMRuntimeEnabled() then
        ScanAllGlows()
    end
end)

local function DisableRuntime()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
    usabilityGlowFrame:SetScript("OnUpdate", nil)
    _usabilityGlowPending = false
    if glowFallbackTicker and glowFallbackTicker.Cancel then
        glowFallbackTicker:Cancel()
        glowFallbackTicker = nil
    end
    StopAllTrackedGlows()
end

---------------------------------------------------------------------------
-- PANDEMIC AURA REFRESH
-- cdm_spelldata.lua owns UNIT_AURA and calls this after it captures the
-- batched payload. The icon's _lastAuraDurObj (cached by the resolver in
-- ApplyAuraStateToIcon) feeds the C-side curve evaluation; pandemic state
-- never enters Lua.
---------------------------------------------------------------------------
local function HandleUnitAuraChanged(_unit, _updateInfo)
    if not IsCDMRuntimeEnabled() then return end

    for _, icons in pairs(spellIdToGlowIcons) do
        for i = 1, #icons do
            local icon = icons[i]
            if icon and icon:IsShown() and icon._spellEntry then
                UpdatePandemicGlow(icon)
            end
        end
    end
end

---------------------------------------------------------------------------
-- EXPORTS
---------------------------------------------------------------------------
-- Store on ns for engine init to wire
ns._OwnedGlows = {
    StartGlow = StartGlow,
    StopGlow = StopGlow,
    RefreshAllGlows = RefreshAllGlows,
    RebuildGlowSpellMap = RebuildGlowSpellMap,
    GetViewerType = GetViewerType,
    activeGlowIcons = activeGlowIcons,
    ScheduleGlowScan = ScanAllGlows,
    IsSpellCastable = IsSpellCastable,
    UpdatePandemicGlow = UpdatePandemicGlow,
    ClearPandemicState = ClearPandemicState,
    HandleUnitAuraChanged = HandleUnitAuraChanged,
    DisableRuntime = DisableRuntime,
    GetGlowState = function(icon)
        return activeGlowIcons[icon] and { active = true } or nil
    end,
}

