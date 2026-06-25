---------------------------------------------------------------------------
-- QUI Unit Frames - Aura System
-- Buff/debuff icon creation, updating, preview mode, and tracking.
-- Extracted from modules/unitframes/unitframes.lua for maintainability.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local QUICore = ns.Addon

local function CJKFont(fs, p, s, f)
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(fs, p, s, f)
    else
        fs:SetFont(p, s, f)
    end
end

-- Upvalue caching for hot-path performance
local ipairs = ipairs
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer
local pairs = pairs
local rawget = rawget
local type = type
local UnitExists = UnitExists

-- QUI_UF is created in unitframes.lua and exported to ns.QUI_UnitFrames.
-- This file loads after unitframes.lua, so the reference is available.
local QUI_UF = ns.QUI_UnitFrames
if not QUI_UF then return end

-- Internal helpers exposed by unitframes.lua
local GetFontPath = QUI_UF._GetFontPath
local GetFontOutline = QUI_UF._GetFontOutline
local GetUnitSettings = QUI_UF._GetUnitSettings
local UpdateFrame = QUI_UF._UpdateFrame
---------------------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------------------

-- Preview aura data for buff/debuff preview mode (4 icons with varied stacks)
local PREVIEW_AURAS = {
    buffs = {
        {icon = "Interface\\Icons\\spell_nature_regenerate", stacks = 0, duration = 10},
        {icon = "Interface\\Icons\\spell_holy_powerwordshield", stacks = 0, duration = 10},
        {icon = "Interface\\Icons\\spell_nature_lightningshield", stacks = 3, duration = 10},
        {icon = "Interface\\Icons\\ability_warrior_battleshout", stacks = 5, duration = 10},
    },
    debuffs = {
        {icon = "Interface\\Icons\\spell_shadow_shadowwordpain", stacks = 0, duration = 10},
        {icon = "Interface\\Icons\\spell_shadow_mindblast", stacks = 0, duration = 10},
        {icon = "Interface\\Icons\\spell_nature_slow", stacks = 2, duration = 10},
        {icon = "Interface\\Icons\\spell_shadow_shadesofdarkness", stacks = 5, duration = 10},
    }
}

-- Maps DB toggle keys to Blizzard classification filter strings.
local BUFF_CLASSIFICATION_MAP = {
    helpful           = { "HELPFUL|RAID", "HELPFUL|RAID_IN_COMBAT" },
    cancelable        = "HELPFUL|CANCELABLE",
    notCancelable     = "HELPFUL|NOT_CANCELABLE",
    bigDefensive      = "HELPFUL|BIG_DEFENSIVE",
    externalDefensive = "HELPFUL|EXTERNAL_DEFENSIVE",
}

local DEBUFF_CLASSIFICATION_MAP = {
    -- RAID_IN_COMBAT is a HELPFUL-only AuraFilters token (Blizzard doc: "Combine
    -- with Player & Helpful"); "HARMFUL|RAID_IN_COMBAT" is an invalid combo and
    -- C_UnitAuras.GetUnitAuras hard-errors on it. The harmful key emits RAID only.
    harmful     = { "HARMFUL|RAID" },
    dispellable = "HARMFUL|RAID_PLAYER_DISPELLABLE",
    crowdControl = "HARMFUL|CROWD_CONTROL",
}

-- Boss engage is a global event; one shared listener avoids five frames
-- reprocessing every transient boss-slot pulse.
local bossEngageFrame

-- Map a user anchor corner to the icon/frame attach points (flip vertical only
-- for outside positioning) plus the 1px border-compensation X offset.
local AURA_ANCHOR_FRAMEPOINT = {
    TOPLEFT     = { "BOTTOMLEFT",  "TOPLEFT",     1 },
    TOPRIGHT    = { "BOTTOMRIGHT", "TOPRIGHT",   -1 },
    BOTTOMLEFT  = { "TOPLEFT",     "BOTTOMLEFT",  1 },
    BOTTOMRIGHT = { "TOPRIGHT",    "BOTTOMRIGHT", -1 },
}

local function MapAuraAnchorToFramePoint(anchor)
    local map = AURA_ANCHOR_FRAMEPOINT[anchor]
    if not map then return nil, nil, nil end
    return map[1], map[2], map[3]
end

local function IsClassificationEnabled(classifications, key)
    if key == "helpful" then
        local value = rawget(classifications, "helpful")
        if value ~= nil then return value end
        -- Legacy migration: previous Player/Target buff filters stored the
        -- two raid-frame filters as separate raid/raidInCombat toggles.
        return classifications.raid or classifications.raidInCombat
    end

    if key == "harmful" then
        local value = rawget(classifications, "harmful")
        if value ~= nil then return value end
        -- Legacy migration: previous Player/Target debuff filters stored the
        -- two raid-frame filters as separate raid/raidInCombat toggles.
        return classifications.raid or classifications.raidInCombat
    end

    return classifications[key]
end

local function BuildClassificationFilters(classifications, classificationMap)
    if not classifications or not classificationMap then return nil end

    local filters
    for key, filterSpec in pairs(classificationMap) do
        if IsClassificationEnabled(classifications, key) then
            filters = filters or {}
            if type(filterSpec) == "table" then
                for _, filterString in ipairs(filterSpec) do
                    filters[#filters + 1] = filterString
                end
            else
                filters[#filters + 1] = filterSpec
            end
        end
    end

    return filters
end

-- NOTE: per-icon filtering (the legacy IsAuraFilteredOutByInstanceID /
-- AuraPassesAnyFilter helpers) was removed when the LIVE display path moved to
-- the secure CustomAuraContainer.  The container applies the SAME inclusion
-- test, C_UnitAuras.IsAuraFilteredOutByInstanceID, internally for every
-- registered filter string (see Blizzard_CustomAuraContainer:AddAura) — so the
-- filter behaviour is identical, just driven C-side on secret-safe data.

---------------------------------------------------------------------------
-- AURA UPDATE
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- FILTER STRING BUILDER
---------------------------------------------------------------------------
-- Concatenates a Blizzard aura filter string from the structured filter DB.
-- base       : "HELPFUL" or "HARMFUL" — required anchor flag.
-- filterDB   : { modifiers = {FLAG = bool, …}, exclusive = string|nil } or nil
-- Returns base unchanged if filterDB is missing or empty.
local function BuildFilterString(base, filterDB)
    if not filterDB then return base end
    local parts = { base }
    if filterDB.modifiers then
        for flag, enabled in pairs(filterDB.modifiers) do
            if enabled then parts[#parts + 1] = flag end
        end
    end
    if filterDB.exclusive then
        parts[#parts + 1] = filterDB.exclusive
    end
    return table.concat(parts, "|")
end

---------------------------------------------------------------------------
-- LIVE DISPLAY PATH — secure CustomAuraContainer
---------------------------------------------------------------------------
-- The live buff/debuff display is rendered by Blizzard's secure
-- CustomAuraContainer (one container per zone), themed by QUI.AuraSkin.  The
-- container self-drives UNIT_AURA and handles secret aura data internally — no
-- QUI Lua ever reads a secret aura field on the live path.
--
-- LAYOUT-MODE PREVIEW keeps its own custom-icon renderer (the inline icon code
-- in ShowAuraPreviewForFrame): a secure, self-driving container cannot be fed
-- fake auras, so during preview the live container for that zone is disabled
-- and the preview icons render alone; the container is restored on exit.
-- The preview surface is self-contained and builds its icons inline.
---------------------------------------------------------------------------

local AuraSkin = (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)

-- Combat-deferral queue.  The container is a forbidden object: create / pool /
-- anchor / filter changes are restricted in combat, so any such work attempted
-- during InCombatLockdown() is queued and replayed on PLAYER_REGEN_ENABLED.
local pendingCombatWork = {}        -- [frame] = true  (re-apply config OOC)
local combatDeferFrame

local function FlushPendingCombatWork()
    for frame in pairs(pendingCombatWork) do
        pendingCombatWork[frame] = nil
        if frame and QUI_UF.ApplyContainerConfig then
            QUI_UF.ApplyContainerConfig(frame)
        end
    end
end

local function EnsureCombatDeferFrame()
    if combatDeferFrame then return end
    combatDeferFrame = CreateFrame("Frame")
    combatDeferFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatDeferFrame:SetScript("OnEvent", FlushPendingCombatWork)
end

local function QueueCombatWork(frame)
    EnsureCombatDeferFrame()
    pendingCombatWork[frame] = true
end

-- Resolve the Blizzard filter strings for a zone from the unit's aura settings.
-- Mirrors the legacy live-path filter logic: classification mode emits the
-- per-classification filter strings, otherwise the structured/base filter.
local function ResolveZoneFilters(auraSettings, unitKey, isDebuff)
    local base = isDebuff and "HARMFUL" or "HELPFUL"
    local usePlayerTargetAuraFilters = (unitKey == "player" or unitKey == "target")

    if isDebuff then
        if usePlayerTargetAuraFilters and auraSettings.debuffFilterMode == "classification" then
            local f = BuildClassificationFilters(auraSettings.debuffClassifications, DEBUFF_CLASSIFICATION_MAP)
            if f and #f > 0 then return f end
        end
        return { BuildFilterString(base, auraSettings.debuffFilter) }
    end

    if usePlayerTargetAuraFilters and auraSettings.buffFilterMode == "classification" then
        local f = BuildClassificationFilters(auraSettings.buffClassifications, BUFF_CLASSIFICATION_MAP)
        if f and #f > 0 then return f end
    end
    return { BuildFilterString(base, auraSettings.buffFilter) }
end

-- Anchor a container OOC with fixed points relative to its unit frame.  The
-- container is forbidden, so SetPoint/SetSize are NEVER called in combat.
local function AnchorContainer(container, frame, anchor)
    container:ClearAllPoints()
    container:SetPoint(anchor or "TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
end

-- Create (OOC) the two zone containers for a unit frame and theme/pool them via
-- AuraSkin.  Idempotent — re-attaches/re-themes if maxIcons grew.
local function EnsureContainers(frame, auraSettings)
    -- Re-resolve defensively in case core/aura_skin.lua loaded after this file's
    -- top-level chunk captured the (then-nil) upvalue.
    AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    if not AuraSkin or not CreateFrame then return false end

    -- Full grid profiles built from the per-zone aura settings.  Key names match
    -- exactly what the layout-mode preview path reads (ShowAuraPreviewForFrame),
    -- so live container layout == preview layout.  (debuff iconSize is the shared
    -- `iconSize`; buff iconSize is `buffIconSize` — mirrors the schema sliders.)
    local debuffProfile = {
        maxIcons    = auraSettings.debuffMaxIcons or 16,
        iconSize    = auraSettings.iconSize or 22,
        spacing     = auraSettings.debuffSpacing or auraSettings.iconSpacing or 2,
        grow        = auraSettings.debuffGrow or "RIGHT",
        maxPerRow   = auraSettings.debuffMaxPerRow or 0,
        offsetX     = auraSettings.debuffOffsetX or 0,
        offsetY     = auraSettings.debuffOffsetY or 2,
        anchor      = auraSettings.debuffAnchor or "TOPLEFT",
        borderSize  = auraSettings.debuffBorderSize or auraSettings.borderSize or 1,
        fontSize    = auraSettings.debuffFontSize or auraSettings.fontSize or 11,
        hideSwipe   = auraSettings.debuffHideSwipe ~= nil and auraSettings.debuffHideSwipe or (auraSettings.hideSwipe or false),
        reverseSwipe = auraSettings.debuffReverseSwipe ~= nil and auraSettings.debuffReverseSwipe or (auraSettings.reverseSwipe or false),
    }
    local buffProfile = {
        maxIcons    = auraSettings.buffMaxIcons or 16,
        iconSize    = auraSettings.buffIconSize or 22,
        spacing     = auraSettings.buffSpacing or auraSettings.iconSpacing or 2,
        grow        = auraSettings.buffGrow or "RIGHT",
        maxPerRow   = auraSettings.buffMaxPerRow or 0,
        offsetX     = auraSettings.buffOffsetX or 0,
        offsetY     = auraSettings.buffOffsetY or -2,
        anchor      = auraSettings.buffAnchor or "BOTTOMLEFT",
        borderSize  = auraSettings.buffBorderSize or auraSettings.borderSize or 1,
        fontSize    = auraSettings.buffFontSize or auraSettings.fontSize or 11,
        hideSwipe   = auraSettings.buffHideSwipe ~= nil and auraSettings.buffHideSwipe or (auraSettings.hideSwipe or false),
        reverseSwipe = auraSettings.buffReverseSwipe ~= nil and auraSettings.buffReverseSwipe or (auraSettings.reverseSwipe or false),
    }

    if not frame.debuffContainer then
        frame.debuffContainer = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
    end
    if not frame.buffContainer then
        frame.buffContainer = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
    end

    AuraSkin.Attach(frame.debuffContainer, debuffProfile)
    AuraSkin.Attach(frame.buffContainer, buffProfile)

    AnchorContainer(frame.debuffContainer, frame, auraSettings.debuffAnchor)
    AnchorContainer(frame.buffContainer, frame, auraSettings.buffAnchor)
    return true
end

-- The container's AddAuraFilter eagerly runs C_UnitAuras.GetUnitAuras(unit,
-- filterString); some AuraFilters tokens are only valid in a specific polarity
-- combo and the C API hard-errors on a bad one (and AddAuraFilter inserts the
-- filter BEFORE that throwing call, so a pcall around it would leave a poisoned
-- filter that re-throws on every later UNIT_AURA). Pre-validate the string with
-- our own (addon-allowed) GetUnitAuras and only hand accepted strings over.
local function FilterStringUsable(unit, filterString)
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuras) then return true end
    return (pcall(C_UnitAuras.GetUnitAuras, unit, filterString))
end

-- Add a zone's filter strings to its container, dropping any the C API rejects,
-- and guaranteeing at least the base polarity so a zone never silently shows
-- nothing when every classification filter is dropped.
local function AddZoneFilters(container, unit, filters, base, maxIcons)
    local added = 0
    for _, filterString in ipairs(filters) do
        if FilterStringUsable(unit, filterString) then
            container:AddAuraFilter(filterString, { maxFrameCount = maxIcons })
            added = added + 1
        end
    end
    if added == 0 then
        container:AddAuraFilter(base, { maxFrameCount = maxIcons })
    end
end

-- Apply enable/disable + filter + unit config to the live containers.  This is
-- the heart of the live path: filters and SetEnabled change, the container
-- self-drives the rest.  Runs OOC only (callers defer via QueueCombatWork).
local function ApplyContainerConfig(frame)
    if not frame or not frame.unit then return end
    local unitKey = frame.unitKey or frame.unit
    local settings = GetUnitSettings(unitKey)
    local auraSettings = settings and settings.auras or {}

    if not EnsureContainers(frame, auraSettings) then return end

    local showBuffs = auraSettings.showBuffs == true
    local showDebuffs = auraSettings.showDebuffs == true

    -- Preview mode owns the display for a zone while active: keep the live
    -- container disabled so the fake preview icons render alone.  Boss frames
    -- preview as a GROUP — ShowAuraPreview("boss", ...) sets the "boss_*" key for
    -- all five — so map boss1..boss5 to "boss" here, or the live container would
    -- re-enable on top of the preview.
    local previewKey = unitKey
    if type(unitKey) == "string" and unitKey:match("^boss%d+$") then previewKey = "boss" end
    local buffPreviewActive = QUI_UF.auraPreviewMode[previewKey .. "_buff"]
    local debuffPreviewActive = QUI_UF.auraPreviewMode[previewKey .. "_debuff"]

    -- Per-zone icon cap: maxFrameCount caps how many auras the container shows
    -- (it never assigns past the Nth registered button).  Match each zone's
    -- maxIcons so the cap == the number of pooled buttons.
    local debuffMaxIcons = auraSettings.debuffMaxIcons or 16
    local buffMaxIcons = auraSettings.buffMaxIcons or 16

    -- Debuff zone.  SetUnit BEFORE the filters so the container's eager
    -- GetUnitAuras (inside AddAuraFilter) has a valid unit.
    local dc = frame.debuffContainer
    dc:SetUnit(frame.unit)
    dc:ClearAuraFilters()
    if showDebuffs and not debuffPreviewActive then
        AddZoneFilters(dc, frame.unit, ResolveZoneFilters(auraSettings, unitKey, true), "HARMFUL", debuffMaxIcons)
        dc:SetEnabled(true)
        dc:Show()
    else
        dc:SetEnabled(false)
        dc:Hide()
    end

    -- Buff zone
    local bc = frame.buffContainer
    bc:SetUnit(frame.unit)
    bc:ClearAuraFilters()
    if showBuffs and not buffPreviewActive then
        AddZoneFilters(bc, frame.unit, ResolveZoneFilters(auraSettings, unitKey, false), "HELPFUL", buffMaxIcons)
        bc:SetEnabled(true)
        bc:Show()
    else
        bc:SetEnabled(false)
        bc:Hide()
    end
end
QUI_UF.ApplyContainerConfig = ApplyContainerConfig

-- Public entry (callers in unitframes.lua depend on the name).  The live
-- container self-drives UNIT_AURA, so this is no longer a per-frame render
-- loop; it (re)applies enable/disable + filter config, deferring to OOC if the
-- forbidden container can't be touched right now.
local function UpdateAuras(frame)
    if not frame or not frame.unit then return end
    if InCombatLockdown() then
        QueueCombatWork(frame)
        return
    end
    ApplyContainerConfig(frame)
end

-- Suppress / restore the live containers around layout-mode preview.  Disabling
-- + hiding lets the fake preview icons own the zone; restore re-applies live
-- config (deferred if in combat).
local function SuppressContainerForPreview(frame, isDebuff)
    if not frame then return end
    local container = isDebuff and frame.debuffContainer or frame.buffContainer
    if not container then return end
    if InCombatLockdown() then
        QueueCombatWork(frame)
        return
    end
    container:SetEnabled(false)
    container:Hide()
end

-- (The legacy live-render body — the manual per-index aura polling loop and its
--  SafeSetCooldown / DisplayStackCount closures — was removed when the live
--  display moved to the secure CustomAuraContainer above, which reads aura data
--  C-side and never hands a secret value to QUI Lua.)
-- Expose for unitframes.lua callers
QUI_UF.UpdateAuras = UpdateAuras

local function RefreshBossFrameForEngage(frame)
    if not frame or not frame.unit then return end

    if UnitExists(frame.unit) then
        UpdateFrame(frame)
    end
    UpdateAuras(frame)
end

local function EnsureBossEngageFrame()
    if bossEngageFrame then return end

    bossEngageFrame = CreateFrame("Frame")
    bossEngageFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    bossEngageFrame:SetScript("OnEvent", function()
        local frames = QUI_UF.frames
        if not frames then return end

        for i = 1, 5 do
            RefreshBossFrameForEngage(frames["boss" .. i])
        end
    end)
end

---------------------------------------------------------------------------
-- AURA TRACKING SETUP
---------------------------------------------------------------------------

local function SetupAuraTracking(frame)
    if not frame then return end

    local unit = frame.unit

    -- Live aura display is now a secure CustomAuraContainer per zone — it
    -- self-drives UNIT_AURA internally (see AuraContainerPrivateMixin), so QUI
    -- no longer registers UNIT_AURA on the unit frame for aura rendering.  We
    -- still listen for token-change events so the container re-points at the
    -- new underlying unit when the token's subject changes (target/focus swap,
    -- pet summon, ToT change) — the container's token string is unchanged in
    -- those cases, so we force a re-parse via ApplyContainerConfig (which
    -- clears + re-adds the filters → Blizzard UpdateAllAuras).
    if unit == "target" then
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    elseif unit == "focus" then
        frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
    elseif unit == "pet" then
        frame:RegisterEvent("UNIT_PET")
    elseif unit == "targettarget" then
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")  -- ToT changes when target changes
        frame:RegisterEvent("UNIT_TARGET")            -- ToT changes when target's target changes
    elseif unit:match("^boss%d+$") then
        EnsureBossEngageFrame()
    end
    -- player: token never changes; container handles UNIT_AURA on its own.

    -- Hook into existing OnEvent or create new one
    local oldOnEvent = frame:GetScript("OnEvent")
    frame:SetScript("OnEvent", function(self, event, arg1, ...)
        if oldOnEvent then
            oldOnEvent(self, event, arg1, ...)
        end

        if event == "PLAYER_TARGET_CHANGED" then
            if self.unit == "target" or self.unit == "targettarget" then
                UpdateAuras(self)
            end
        elseif event == "PLAYER_FOCUS_CHANGED" and self.unit == "focus" then
            UpdateAuras(self)
        elseif event == "UNIT_PET" and self.unit == "pet" then
            UpdateAuras(self)
        elseif event == "UNIT_TARGET" and self.unit == "targettarget" then
            UpdateAuras(self)
        end
    end)

    -- Create + configure the containers once at load.  EnsureContainers /
    -- anchoring touch a forbidden object, so do it OOC; UpdateAuras defers to
    -- PLAYER_REGEN_ENABLED if we somehow land here in combat.
    UpdateAuras(frame)

    -- Re-apply shortly after load to catch the case where the unit frame's
    -- final size/anchor settle a frame later (mirrors the legacy double-tap).
    C_Timer.After(0.2, function()
        UpdateAuras(frame)
    end)
end

-- Expose for unitframes.lua callers
QUI_UF.SetupAuraTracking = SetupAuraTracking

---------------------------------------------------------------------------
-- AURA PREVIEW MODE
---------------------------------------------------------------------------

function QUI_UF:ShowAuraPreview(unitKey, auraType)
    -- Handle boss frames specially - show aura preview on all 5
    if unitKey == "boss" then
        local previewKey = "boss_" .. auraType
        self.auraPreviewMode[previewKey] = true
        -- Only show if boss frame preview is active
        for i = 1, 5 do
            local bossKey = "boss" .. i
            local frame = self.frames[bossKey]
            if frame and self.previewMode[bossKey] then
                self:ShowAuraPreviewForFrame(frame, "boss", auraType)
            end
        end
        return
    end

    local frame = self.frames[unitKey]
    if not frame then return end

    local previewKey = unitKey .. "_" .. auraType
    self.auraPreviewMode[previewKey] = true

    self:ShowAuraPreviewForFrame(frame, unitKey, auraType)
end

function QUI_UF:ShowAuraPreviewForFrame(frame, unitKey, auraType)
    if not frame then return end

    -- Get settings
    local settings = GetUnitSettings(unitKey)
    local auraSettings = settings and settings.auras or {}

    -- Determine which preview data and settings to use
    local previewData = (auraType == "buff") and PREVIEW_AURAS.buffs or PREVIEW_AURAS.debuffs
    local isDebuff = (auraType == "debuff")

    -- Get size and positioning settings
    local iconSize, anchor, grow, offsetX, offsetY, spacing, maxIcons
    if isDebuff then
        iconSize = auraSettings.iconSize or 22
        anchor = auraSettings.debuffAnchor or "TOPLEFT"
        grow = auraSettings.debuffGrow or "RIGHT"
        offsetX = auraSettings.debuffOffsetX or 0
        offsetY = auraSettings.debuffOffsetY or 2
        spacing = auraSettings.debuffSpacing or 2
        maxIcons = auraSettings.debuffMaxIcons or 16
    else
        iconSize = auraSettings.buffIconSize or 22
        anchor = auraSettings.buffAnchor or "BOTTOMLEFT"
        grow = auraSettings.buffGrow or "RIGHT"
        offsetX = auraSettings.buffOffsetX or 0
        offsetY = auraSettings.buffOffsetY or -2
        spacing = auraSettings.buffSpacing or 2
        maxIcons = auraSettings.buffMaxIcons or 16
    end

    -- Initialize preview icon container if needed
    local containerKey = isDebuff and "previewDebuffIcons" or "previewBuffIcons"
    frame[containerKey] = frame[containerKey] or {}
    local container = frame[containerKey]

    -- Disable the live secure container for this zone so the fake preview icons
    -- own the display.  (A self-driving secure container cannot be fed fake
    -- auras — preview keeps the custom-icon renderer; restored on preview exit.)
    SuppressContainerForPreview(frame, isDebuff)

    -- Hide any legacy real-icon table that may exist (dead on the live path now,
    -- but cleared defensively).
    local realContainer = isDebuff and frame.debuffIcons or frame.buffIcons
    if realContainer then
        for _, icon in ipairs(realContainer) do
            icon:Hide()
        end
    end

    -- Hide any existing preview icons first (in case maxIcons was reduced)
    for _, icon in ipairs(container) do
        icon:SetScript("OnUpdate", nil)
        icon:Hide()
    end

    -- Track start time for looping cooldown animation
    local previewStartTime = GetTime()
    local previewDuration = 10
    local previewDataCount = #previewData

    -- Create/show preview icons based on maxIcons setting
    for i = 1, maxIcons do
        -- Cycle through mock data using modulo
        local dataIndex = ((i - 1) % previewDataCount) + 1
        local auraData = previewData[dataIndex]
        local icon = container[i]
        if not icon then
            -- Create new preview icon (simplified, no tooltip interaction needed)
            icon = CreateFrame("Frame", nil, frame)
            icon:SetFrameLevel(frame:GetFrameLevel() + 10)

            -- Border
            local border = icon:CreateTexture(nil, "BACKGROUND", nil, -8)
            border:SetColorTexture(0, 0, 0, 1)
            local prevIconPx = QUICore:GetPixelSize(icon)
            border:SetPoint("TOPLEFT", icon, "TOPLEFT", -prevIconPx, prevIconPx)
            border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", prevIconPx, -prevIconPx)
            icon.border = border

            -- Icon texture
            local tex = icon:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("TOPLEFT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", 0, 0)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            icon.icon = tex

            -- Cooldown swipe
            local cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
            cd:SetAllPoints(icon)
            cd:SetDrawEdge(false)
            cd:SetReverse(true)
            cd:SetSwipeTexture("Interface\\Buttons\\WHITE8X8")
            cd:SetSwipeColor(0, 0, 0, 0.8)
            cd.noOCC = true
            cd.noCooldownCount = true
            icon.cooldown = cd

            -- Stack count — parented above the cooldown swipe
            local stackOverlay = CreateFrame("Frame", nil, icon)
            stackOverlay:SetAllPoints(icon)
            stackOverlay:SetFrameLevel(cd:GetFrameLevel() + 1)
            local count = stackOverlay:CreateFontString(nil, "OVERLAY")
            count:SetTextColor(1, 1, 1, 1)
            icon.count = count

            container[i] = icon
        end

        -- Configure icon size
        icon:SetSize(iconSize, iconSize)

        -- Apply settings (font, stack position, etc.)
        local fontPath = GetFontPath()
        local fontOutline = GetFontOutline()
        local prefix = isDebuff and "debuff" or "buff"

        local showStack = auraSettings[prefix .. "ShowStack"]
        if showStack == nil then showStack = auraSettings.showStack end
        if showStack == nil then showStack = true end

        local stackSize = auraSettings[prefix .. "StackSize"] or auraSettings.stackSize or 10
        local stackAnchor = auraSettings[prefix .. "StackAnchor"] or auraSettings.stackAnchor or "BOTTOMRIGHT"
        local stackOffsetX = auraSettings[prefix .. "StackOffsetX"] or auraSettings.stackOffsetX or -1
        local stackOffsetY = auraSettings[prefix .. "StackOffsetY"] or auraSettings.stackOffsetY or 1
        local stackColor = auraSettings[prefix .. "StackColor"] or auraSettings.stackColor or {1, 1, 1, 1}

        CJKFont(icon.count, fontPath, stackSize, fontOutline)
        icon.count:ClearAllPoints()
        icon.count:SetPoint(stackAnchor, icon, stackAnchor, stackOffsetX, stackOffsetY)
        icon.count:SetTextColor(stackColor[1] or 1, stackColor[2] or 1, stackColor[3] or 1, stackColor[4] or 1)

        -- Hide Duration Swipe setting
        local hideSwipe = auraSettings[prefix .. "HideSwipe"]
        if hideSwipe == nil then hideSwipe = false end
        icon.cooldown:SetDrawSwipe(not hideSwipe)

        -- Set texture
        icon.icon:SetTexture(auraData.icon)

        -- Set border color (red for debuffs, black for buffs)
        if isDebuff then
            icon.border:SetColorTexture(0.8, 0.2, 0.2, 1)
        else
            icon.border:SetColorTexture(0, 0, 0, 1)
        end

        -- Set stack count
        if showStack and auraData.stacks and auraData.stacks > 1 then
            icon.count:SetText(auraData.stacks)
            icon.count:Show()
        else
            icon.count:Hide()
        end

        -- Calculate position
        local idx = i - 1
        local xPos, yPos = offsetX, offsetY
        if grow == "RIGHT" then
            xPos = xPos + idx * (iconSize + spacing)
        elseif grow == "LEFT" then
            xPos = xPos - idx * (iconSize + spacing)
        elseif grow == "UP" then
            yPos = yPos + idx * (iconSize + spacing)
        elseif grow == "DOWN" then
            yPos = yPos - idx * (iconSize + spacing)
        end

        -- Map user anchor to frame anchor points (flip vertical only for outside positioning)
        -- Border compensation: icons have 1px border extending beyond frame
        local iconPoint, framePoint, borderOffsetX = MapAuraAnchorToFramePoint(anchor)

        icon:ClearAllPoints()
        icon:SetPoint(iconPoint, frame, framePoint, xPos + (borderOffsetX or 0), yPos)

        -- Setup looping cooldown animation
        icon.cooldown:SetCooldown(previewStartTime, previewDuration)
        icon.cooldown:Show()

        -- Store start time for OnUpdate loop
        icon._previewStartTime = previewStartTime
        icon._previewDuration = previewDuration

        icon:SetScript("OnUpdate", function(self, elapsed)
            local now = GetTime()
            local elapsedTime = now - self._previewStartTime
            if elapsedTime >= self._previewDuration then
                self._previewStartTime = now
                self.cooldown:SetCooldown(now, self._previewDuration)
            end
        end)

        icon:Show()
    end
end

function QUI_UF:HideAuraPreview(unitKey, auraType)
    -- Handle boss frames specially - hide aura preview on all 5
    if unitKey == "boss" then
        local previewKey = "boss_" .. auraType
        self.auraPreviewMode[previewKey] = false
        for i = 1, 5 do
            local bossKey = "boss" .. i
            local frame = self.frames[bossKey]
            if frame then
                self:HideAuraPreviewForFrame(frame, bossKey, auraType)
            end
        end
        return
    end

    local frame = self.frames[unitKey]
    if not frame then return end

    local previewKey = unitKey .. "_" .. auraType
    self.auraPreviewMode[previewKey] = false

    self:HideAuraPreviewForFrame(frame, unitKey, auraType)
end

function QUI_UF:HideAuraPreviewForFrame(frame, unitKey, auraType)
    if not frame then return end

    local isDebuff = (auraType == "debuff")
    local containerKey = isDebuff and "previewDebuffIcons" or "previewBuffIcons"
    local container = frame[containerKey]

    -- Hide and cleanup preview icons
    if container then
        for _, icon in ipairs(container) do
            icon:SetScript("OnUpdate", nil)
            icon:Hide()
        end
    end

    -- Refresh real auras
    UpdateAuras(frame)
end
