---------------------------------------------------------------------------
-- QUI Profile Migrations
-- Shared normalization pipeline for legacy SavedVariables and profile imports.
--
-- This is the single entry point for ALL profile-level migrations.
-- Call Migrations.Run(db) from any context that activates a profile:
--   - Addon startup (init.lua OnEnable via BackwardsCompat)
--   - Module startup (main.lua QUICore:OnInitialize)
--   - Profile switch (main.lua QUICore:OnProfileChanged)
--   - Profile import (profile_io.lua via BackwardsCompat)
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local Migrations = ns.Migrations or {}
ns.Migrations = Migrations
-- Also expose on the QUI global so init.lua (which has no `ns` scope) can
-- reach the snapshot/restore helpers for the `/qui migration` slash command.
if _G.QUI then _G.QUI.Migrations = Migrations end

-- Module-level upvalues set by Migrations.Run before iterating profiles and
-- cleared on exit. Declared here (file scope) so migration functions defined
-- anywhere in the file can reference them without forward-declaration issues.
local _currentGlobalDB     = nil  -- db.global; for cross-profile reads (v32+)

---------------------------------------------------------------------------
-- Schema version history
---------------------------------------------------------------------------
-- v0–v46 = pre-5.0 history. All step-by-step migrations through v47 were
--       REMOVED in 5.0. v47 is the migration floor (MIN_SUPPORTED_SCHEMA):
--       the last 4.x stable release and 5.0 alpha4 both shipped schema 47, so
--       any profile at or above 47 upgrades incrementally, while a profile
--       stored below 47 is backed up, wiped, and flagged for a starter-profile
--       reseed (see profile._needsStarterReseed) rather than upgraded. Fresh
--       profiles (stored==0) are NOT floored — they take the normal fresh-init
--       path.
--
-- v48 = RestoreBuffDebuffSplit — the single surviving migration. Player buffs
--       and debuffs use two independent CustomAuraContainers and two mover
--       targets; this seeds the debuff grid keys (from their buff equivalents)
--       and frameAnchoring.debuffFrame (below buffFrame) for any profile that
--       does not already carry them.
--
-- When adding a new migration: bump CURRENT_SCHEMA_VERSION, add a single
-- linear gate in RunOnProfile, and document the version above.
---------------------------------------------------------------------------
local CURRENT_SCHEMA_VERSION = 48

-- The oldest schema we still carry forward. The last 4.x stable release and
-- 5.0 alpha4 both shipped schema 47, and every step-by-step migration through
-- v47 was removed in 5.0. A profile stored below this floor is too old to
-- upgrade step-by-step; RunOnProfile backs it up, wipes it, and flags it for a
-- starter-profile reseed at login (see profile._needsStarterReseed). Fresh
-- profiles (stored==0) are NOT floored — they take the normal fresh-init path.
local MIN_SUPPORTED_SCHEMA = 47

-- Exposed so the profile-import path can reject below-floor (schema < 47)
-- exports before they reach RunOnProfile (where they would otherwise trip the
-- floor and wipe the active profile they import into).
Migrations.MIN_SUPPORTED_SCHEMA = MIN_SUPPORTED_SCHEMA

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------

local function CloneValue(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, nestedValue in pairs(value) do
        copy[key] = CloneValue(nestedValue)
    end
    return copy
end


local SPEC_ID_CLASS_TOKEN = {
    [62] = "MAGE", [63] = "MAGE", [64] = "MAGE",
    [65] = "PALADIN", [66] = "PALADIN", [70] = "PALADIN",
    [71] = "WARRIOR", [72] = "WARRIOR", [73] = "WARRIOR",
    [102] = "DRUID", [103] = "DRUID", [104] = "DRUID", [105] = "DRUID",
    [250] = "DEATHKNIGHT", [251] = "DEATHKNIGHT", [252] = "DEATHKNIGHT",
    [253] = "HUNTER", [254] = "HUNTER", [255] = "HUNTER",
    [256] = "PRIEST", [257] = "PRIEST", [258] = "PRIEST",
    [259] = "ROGUE", [260] = "ROGUE", [261] = "ROGUE",
    [262] = "SHAMAN", [263] = "SHAMAN", [264] = "SHAMAN",
    [265] = "WARLOCK", [266] = "WARLOCK", [267] = "WARLOCK",
    [268] = "MONK", [269] = "MONK", [270] = "MONK",
    [577] = "DEMONHUNTER", [581] = "DEMONHUNTER",
    [1467] = "EVOKER", [1468] = "EVOKER", [1473] = "EVOKER",
}

local function ParseSpecKey(value)
    if type(value) == "number" then
        return value, nil
    end
    if type(value) ~= "string" then
        return nil, nil
    end

    local classToken, specText = value:match("^([A-Z]+)%-(%d+)$")
    if specText then
        return tonumber(specText), classToken
    end
    local numeric = tonumber(value)
    if numeric then
        return numeric, nil
    end
    return nil, nil
end

local function GetClassTokenForSpecID(specID)
    if type(specID) ~= "number" then return nil end
    if GetSpecializationInfoByID then
        local result = { pcall(GetSpecializationInfoByID, specID) }
        local classToken = result[7]
        if result[1] and type(classToken) == "string" and classToken ~= "" then
            return classToken
        end
    end
    return SPEC_ID_CLASS_TOKEN[specID]
end

local function GetCanonicalSpecKey(value)
    local specID, classToken = ParseSpecKey(value)
    if not specID then
        return value, nil
    end
    classToken = classToken or GetClassTokenForSpecID(specID)
    if classToken then
        return classToken .. "-" .. tostring(specID), specID
    end
    return tostring(specID), specID
end

local function GetLiveSpecID()
    if not GetSpecialization or not GetSpecializationInfo then return nil end
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    return type(specID) == "number" and specID or nil
end

local function GetProfileSourceSpecID(profile)
    local fromProfile = profile and profile.ncdm and profile.ncdm._lastSpecID
    if type(fromProfile) == "number" and fromProfile > 0 then
        return fromProfile
    end
    return GetLiveSpecID()
end

local function RecordSpecKeyAlias(container, fromKey, toKey)
    if type(container) ~= "table" or fromKey == nil or toKey == nil or fromKey == toKey then return end
    if type(container._legacySpecKeyAliases) ~= "table" then
        container._legacySpecKeyAliases = {}
    end
    container._legacySpecKeyAliases[tostring(fromKey)] = tostring(toKey)
end

local function StampLegacySpecEntry(entry, sourceSpecID, sourceSpecKey, opts)
    if type(entry) ~= "table" then return entry end
    if type(sourceSpecID) == "number" and sourceSpecID > 0 and entry._sourceSpecID == nil then
        entry._sourceSpecID = sourceSpecID
    end
    if sourceSpecKey ~= nil and entry._legacySourceSpecKey == nil then
        entry._legacySourceSpecKey = tostring(sourceSpecKey)
    end
    if opts and opts.legacySpellbookSlot
       and entry.type == "spell"
       and type(entry.id) == "number"
       and entry._legacySpellbookSlot == nil
    then
        entry._legacySpellbookSlot = entry.id
    end
    return entry
end

local function EntriesEquivalent(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.type == b.type
       and a.id == b.id
       and a.macroName == b.macroName
       and a.customName == b.customName
end

local function DeduplicateEntryList(entries)
    if type(entries) ~= "table" then return false end
    local seen = {}
    local kept = {}
    local changed = false
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            local key = tostring(entry.type or "") .. "\031"
                .. tostring(entry.id or "") .. "\031"
                .. tostring(entry.macroName or "") .. "\031"
                .. tostring(entry.customName or "")
            if not seen[key] then
                seen[key] = true
                kept[#kept + 1] = entry
            else
                changed = true
            end
        else
            kept[#kept + 1] = entry
        end
    end
    if changed then
        for i = 1, math.max(#entries, #kept) do
            entries[i] = kept[i]
        end
    end
    return changed
end

local function MergeSpecEntryLists(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return false end
    local changed = false
    for _, entry in ipairs(src) do
        local exists = false
        for _, existing in ipairs(dst) do
            if EntriesEquivalent(existing, entry) then
                exists = true
                break
            end
        end
        if not exists then
            dst[#dst + 1] = entry
            changed = true
        end
    end
    if DeduplicateEntryList(dst) then
        changed = true
    end
    return changed
end

-- Forward declaration: defined further down (depends on _currentGlobalDB
-- and other v32-era helpers), but called from Migrations.RepairCustomTrackerSpecStorage
-- which is defined earlier in source order.
local PromoteLegacyContainerEntriesToPerSpec



---------------------------------------------------------------------------
-- 1. Data format migrations (restructure raw data first)
---------------------------------------------------------------------------



















---------------------------------------------------------------------------
-- 2. Legacy profile detection & normalization
---------------------------------------------------------------------------


local function IsPlaceholderAnchorEntry(entry)
    if type(entry) ~= "table" then
        return false
    end

    local parent = entry.parent
    local point = entry.point
    local relative = entry.relative
    local offsetX = tonumber(entry.offsetX) or 0
    local offsetY = tonumber(entry.offsetY) or 0
    local widthAdjust = tonumber(entry.widthAdjust) or 0
    local heightAdjust = tonumber(entry.heightAdjust) or 0

    if parent ~= nil and parent ~= "screen" then
        return false
    end
    if point ~= nil and point ~= "CENTER" then
        return false
    end
    if relative ~= nil and relative ~= "CENTER" then
        return false
    end
    if offsetX ~= 0 or offsetY ~= 0 or widthAdjust ~= 0 or heightAdjust ~= 0 then
        return false
    end
    if entry.hideWithParent or entry.keepInPlace or entry.autoWidth or entry.autoHeight then
        return false
    end

    -- Ignore housekeeping-only entries such as hudMinWidth.
    --
    -- `enabled` is whitelisted because 3.0 era profiles still carry the
    -- legacy enabled flag on ghost entries — without this, an `enabled=false`
    -- ghost survives pruning, falls through the cleanup loop, and ends up
    -- masking the AceDB default with a useless zero-offset CENTER anchor.
    -- The flag itself is meaningless once the migration normalizes things.
    for key, value in pairs(entry) do
        if key ~= "parent"
            and key ~= "point"
            and key ~= "relative"
            and key ~= "offsetX"
            and key ~= "offsetY"
            and key ~= "sizeStable"
            and key ~= "sizeStableAnchoring"
            and key ~= "hideWithParent"
            and key ~= "keepInPlace"
            and key ~= "autoWidth"
            and key ~= "autoHeight"
            and key ~= "widthAdjust"
            and key ~= "heightAdjust"
            and key ~= "enabled"
            and value ~= nil
        then
            return false
        end
    end

    return true
end

-- Buffered debug log: chat isn't available during OnInitialize/OnEnable when
-- migrations run, so we collect lines into a global table that can be dumped
-- via /qui miglog after login. The buffer is created lazily on first write.
--
-- Logging is unconditional during the v3.1.5 anchor-migration debug push.
-- Strip the MigLog calls and this helper after the bug is fixed.
local function MigLog(fmt, ...)
    if not _G.QUI_MIGRATION_LOG then _G.QUI_MIGRATION_LOG = {} end
    local line
    if select("#", ...) > 0 then
        local ok, msg = pcall(string.format, fmt, ...)
        line = ok and msg or fmt
    else
        line = fmt
    end
    _G.QUI_MIGRATION_LOG[#_G.QUI_MIGRATION_LOG + 1] = line
end






---------------------------------------------------------------------------
-- 3. Feature migrations
---------------------------------------------------------------------------

local function ResetCastbarPreviewModes(profile)
    if not profile or not profile.quiUnitFrames then
        return
    end

    for _, unitKey in ipairs({ "player", "target", "focus", "pet", "targettarget" }) do
        local unitDB = profile.quiUnitFrames[unitKey]
        if unitDB and unitDB.castbar then
            unitDB.castbar.previewMode = false
        end
    end

    for i = 1, 8 do
        local bossDB = profile.quiUnitFrames["boss" .. i]
        if bossDB and bossDB.castbar then
            bossDB.castbar.previewMode = false
        end
    end
end


-- v48: restore the two-container player buff/debuff model (the single
-- surviving migration). Defined as a Migrations.* method (not a local
-- function) so it adds no new upvalue to RunOnProfile.
function Migrations.RestoreBuffDebuffSplit(profile)
    local bb = profile and profile.buffBorders
    if type(bb) == "table" then
        if bb.debuffIconSize == nil then
            bb.debuffIconSize = bb.buffIconSize or 35
        end
        if bb.debuffIconsPerRow == nil then
            bb.debuffIconsPerRow = bb.buffIconsPerRow or 10
        end
        if bb.debuffIconSpacing == nil then
            bb.debuffIconSpacing = bb.buffIconSpacing or 0
        end
        if bb.debuffGrowLeft == nil then
            if bb.buffGrowLeft ~= nil then
                bb.debuffGrowLeft = bb.buffGrowLeft
            else
                bb.debuffGrowLeft = true
            end
        end
        if bb.debuffGrowUp == nil then
            bb.debuffGrowUp = bb.buffGrowUp or false
        end
        if bb.debuffInvertSwipeDarkening == nil then
            bb.debuffInvertSwipeDarkening = bb.buffInvertSwipeDarkening or false
        end
        if bb.debuffRowSpacing == nil then
            bb.debuffRowSpacing = bb.buffRowSpacing or 0
        end
    end

    if type(profile) ~= "table" then return end
    if type(profile.frameAnchoring) ~= "table" then
        profile.frameAnchoring = {}
    end
    local fa = profile.frameAnchoring
    if fa.debuffFrame == nil then
        fa.debuffFrame = {
            point = "TOPRIGHT",
            parent = "buffFrame",
            relative = "BOTTOMRIGHT",
            offsetX = 0,
            offsetY = -5,
            sizeStable = true,
            autoWidth = false,
            autoHeight = false,
            hideWithParent = false,
            keepInPlace = true,
            widthAdjust = 0,
            heightAdjust = 0,
            growAnchor = "TOPRIGHT",
        }
    end
end

---------------------------------------------------------------------------
-- Custom-tracker → CDM custom-bar helpers
--
-- Build/repair the unified ncdm.containers["customBar_<id>"] entries that
-- mirror legacy db.customTrackers bars. These are NOT migration-gated; they
-- are retained because the profile-import normalization path in
-- core/profile_io.lua calls Migrations.SyncCustomTrackerBarsToCDM and
-- Migrations.RemoveLegacyCustomBarContainers, which reach
-- EnsureCustomTrackerBarContainer / PortLegacySpecTrackerEntries /
-- RepairCustomTrackerSpecStorage and the spec-key helpers above.
---------------------------------------------------------------------------
local CUSTOM_TRACKER_ANCHOR_PREFIX = "customTracker:"
local CDM_CUSTOM_ANCHOR_PREFIX = "cdmCustom_"

local function GetCustomBarContainerKey(legacyId)
    return "customBar_" .. tostring(legacyId)
end

local function GetCustomBarAnchorKey(containerKey)
    return CDM_CUSTOM_ANCHOR_PREFIX .. tostring(containerKey)
end

local function FindCustomBarContainerByLegacyId(containers, legacyId)
    if type(containers) ~= "table" then return nil, nil end
    local destKey = GetCustomBarContainerKey(legacyId)
    if type(containers[destKey]) == "table" then
        return destKey, containers[destKey]
    end
    for key, container in pairs(containers) do
        if type(container) == "table" and container._legacyId == legacyId then
            return key, container
        end
    end
    return nil, nil
end

local function BuildCustomBarRowFromLegacy(bar)
    return {
        iconCount        = bar.maxIcons or 8,
        iconSize         = bar.iconSize or 28,
        borderSize       = bar.borderSize or 2,
        borderColorTable = CloneValue(bar.borderColor or bar.borderColorTable or {0, 0, 0, 1}),
        aspectRatioCrop  = bar.aspectRatioCrop or 1.0,
        zoom             = bar.zoom or 0,
        padding          = bar.spacing or 4,
        xOffset          = 0,
        yOffset          = 0,
        hideDurationText = bar.hideDurationText == true,
        durationFont     = bar.durationFont,
        durationSize     = bar.durationSize or bar.durationTextSize or 13,
        durationOffsetX  = bar.durationOffsetX or 0,
        durationOffsetY  = bar.durationOffsetY or 0,
        durationTextColor = CloneValue(bar.durationColor or bar.durationTextColor or {1, 1, 1, 1}),
        durationAnchor   = bar.durationAnchor or "CENTER",
        stackFont        = bar.stackFont,
        stackSize        = bar.stackSize or bar.stackTextSize or 9,
        stackOffsetX     = bar.stackOffsetX or 3,
        stackOffsetY     = bar.stackOffsetY or -1,
        stackTextColor   = CloneValue(bar.stackColor or bar.stackTextColor or {1, 1, 1, 1}),
        stackAnchor      = bar.stackAnchor or "BOTTOMRIGHT",
        hideStackText    = bar.hideStackText == true,
        opacity          = 1.0,
    }
end

local LEGACY_CUSTOM_TRACKER_COMPAT_FIELDS = {
    "enabled",
    "locked",
    "hideGCD",
    "hideNonUsable",
    "showOnlyOnCooldown",
    "showOnlyWhenActive",
    "showOnlyWhenOffCooldown",
    "showOnlyInCombat",
    "dynamicLayout",
    "clickableIcons",
    "showItemCharges",
    "showRechargeSwipe",
    "noDesaturateWithCharges",
    "showProfessionQuality",
    "showActiveState",
    "activeGlowEnabled",
    "activeGlowType",
    "activeGlowColor",
    "activeGlowLines",
    "activeGlowFrequency",
    "activeGlowThickness",
    "activeGlowScale",
}

local function NormalizeCustomBarVisibilityFlags(container)
    if type(container) ~= "table" then return end

    local mode = "always"
    if container.showOnlyOnCooldown then
        mode = "onCooldown"
        container.showOnlyWhenActive = false
        container.showOnlyWhenOffCooldown = false
    elseif container.showOnlyWhenActive then
        mode = "active"
        container.showOnlyWhenOffCooldown = false
    elseif container.showOnlyWhenOffCooldown then
        mode = "offCooldown"
    end

    container.visibilityMode = mode

    if mode ~= "onCooldown" then
        container.noDesaturateWithCharges = false
    end
end

local function StampCustomBarCompatibilityDefaults(container)
    if type(container) ~= "table" then return end

    container.tooltipContext = container.tooltipContext or "customTrackers"
    container.keybindContext = container.keybindContext or "customTrackers"

    if container.hideGCD == nil then container.hideGCD = true end
    if container.showItemCharges == nil then container.showItemCharges = true end
    if container.showProfessionQuality == nil then container.showProfessionQuality = true end
    if container.showActiveState == nil then container.showActiveState = true end
    if container.activeGlowEnabled == nil then container.activeGlowEnabled = true end
    if container.activeGlowType == nil then container.activeGlowType = "Pixel Glow" end
    if container.activeGlowColor == nil then container.activeGlowColor = {1, 0.85, 0.3, 1} end
    if container.activeGlowLines == nil then container.activeGlowLines = 8 end
    if container.activeGlowFrequency == nil then container.activeGlowFrequency = 0.25 end
    if container.activeGlowThickness == nil then container.activeGlowThickness = 2 end
    if container.activeGlowScale == nil then container.activeGlowScale = 1.0 end

    -- Legacy custom trackers defaulted to fixed slots. A nil value in old
    -- profiles means "static", while generic CDM containers treat nil as
    -- "dynamic"; stamp the legacy default explicitly for migrated bars.
    if container.dynamicLayout == nil then
        container.dynamicLayout = false
    end
    if container.dynamicLayout and container.clickableIcons then
        container.clickableIcons = false
    end

    if type(container.row1) == "table" then
        local row = container.row1
        if row.hideStackText == nil then row.hideStackText = container.hideStackText == true end
        if row.durationFont == nil then row.durationFont = container.durationFont end
        if row.stackFont == nil then row.stackFont = container.stackFont end
    end

    NormalizeCustomBarVisibilityFlags(container)
end

local function CopyLegacyCustomTrackerAnchor(profile, legacyId, containerKey)
    local fa = profile and profile.frameAnchoring
    if type(fa) ~= "table" then return end

    local oldKey = CUSTOM_TRACKER_ANCHOR_PREFIX .. tostring(legacyId)
    local newKey = GetCustomBarAnchorKey(containerKey)

    if type(fa[oldKey]) == "table" and type(fa[newKey]) ~= "table" then
        fa[newKey] = CloneValue(fa[oldKey])
    end

    -- Anything anchored to the old dynamic target should now point at the
    -- unified CDM container resolver.
    for _, entry in pairs(fa) do
        if type(entry) == "table" and entry.parent == oldKey then
            entry.parent = newKey
        end
    end
end

local function PortLegacySpecTrackerEntries(globalDB, legacyId, containerKey, container)
    if type(globalDB) ~= "table" then return end
    if type(globalDB.specTrackerSpells) ~= "table" then return end
    local src = globalDB.specTrackerSpells[legacyId]
    if type(src) ~= "table" then return end

    if type(globalDB.ncdm) ~= "table" then globalDB.ncdm = {} end
    if type(globalDB.ncdm.specTrackerSpells) ~= "table" then
        globalDB.ncdm.specTrackerSpells = {}
    end

    local dstRoot = globalDB.ncdm.specTrackerSpells
    if type(dstRoot[containerKey]) ~= "table" then
        dstRoot[containerKey] = {}
    end

    local dst = dstRoot[containerKey]
    local anyPorted = false
    for specKey, specList in pairs(src) do
        local canonicalKey, specID = GetCanonicalSpecKey(specKey)
        canonicalKey = canonicalKey or specKey
        if type(specList) == "table" then
            local copy = {}
            for i, entry in ipairs(specList) do
                copy[i] = StampLegacySpecEntry(CloneValue(entry), specID, specKey)
            end
            if type(dst[canonicalKey]) == "table" then
                if MergeSpecEntryLists(dst[canonicalKey], copy) then
                    anyPorted = true
                end
            else
                dst[canonicalKey] = copy
                anyPorted = true
            end
            RecordSpecKeyAlias(container, specKey, canonicalKey)
        end
    end

    if anyPorted and type(container) == "table" then
        container.specSpecific = true
    end
end

local IsUncustomizedDefaultTrackerBar

function Migrations.EnsureCustomTrackerBarContainer(profile, bar, globalDB)
    if type(profile) ~= "table" or type(bar) ~= "table" then return nil end
    if type(profile.ncdm) ~= "table" then profile.ncdm = {} end
    if type(profile.ncdm.containers) ~= "table" then profile.ncdm.containers = {} end

    local legacyId = bar.id
    if legacyId == nil or legacyId == "" then return nil end
    local sourceLegacyId = bar._importedLegacyId or legacyId

    local containers = profile.ncdm.containers
    local containerKey, container = FindCustomBarContainerByLegacyId(containers, legacyId)
    if not containerKey then
        containerKey = GetCustomBarContainerKey(legacyId)
    end

    if type(container) ~= "table" then
        container = CloneValue(bar)
        containers[containerKey] = container
    end

    container.builtIn = false
    container.containerType = "customBar"
    container.shape = "icon"
    container.name = bar.name or container.name or "Custom Bar"
    container.id = bar.id
    container._migratedFromCustomTrackers = true
    container._legacyId = legacyId
    container._importedLegacyId = nil

    for _, field in ipairs(LEGACY_CUSTOM_TRACKER_COMPAT_FIELDS) do
        if bar[field] ~= nil then
            container[field] = CloneValue(bar[field])
        end
    end

    container.pos = {
        ox = bar.offsetX or 0,
        oy = bar.offsetY or 0,
    }
    container.anchorTo = "disabled"

    container.row1 = BuildCustomBarRowFromLegacy(bar)
    container.row2 = { iconCount = 0 }
    container.row3 = { iconCount = 0 }

    local gd = bar.growDirection or container.growDirection
    container.growDirection = gd or "RIGHT"
    container.layoutDirection = (gd == "UP" or gd == "DOWN") and "VERTICAL" or "HORIZONTAL"

    if type(container.entries) ~= "table" and type(bar.entries) == "table" then
        container.entries = CloneValue(bar.entries)
    end
    if bar.specSpecificSpells == true then
        container.specSpecific = true
    end

    CopyLegacyCustomTrackerAnchor(profile, legacyId, containerKey)
    PortLegacySpecTrackerEntries(globalDB or _currentGlobalDB, sourceLegacyId, containerKey, container)
    StampCustomBarCompatibilityDefaults(container)

    return containerKey, container
end

function Migrations.SyncCustomTrackerBarsToCDM(profile, globalDB)
    local bars = profile and profile.customTrackers and profile.customTrackers.bars
    if type(bars) ~= "table" then return false end

    local any = false
    for _, bar in ipairs(bars) do
        if type(bar) == "table" and not IsUncustomizedDefaultTrackerBar(bar) then
            local key = Migrations.EnsureCustomTrackerBarContainer(profile, bar, globalDB)
            if key then any = true end
        end
    end
    if any and type(Migrations.RepairCustomTrackerSpecStorage) == "function" then
        Migrations.RepairCustomTrackerSpecStorage(profile, globalDB)
    end
    return any
end

function Migrations.RemoveLegacyCustomBarContainers(profile, globalDB)
    local containers = profile and profile.ncdm and profile.ncdm.containers
    if type(containers) ~= "table" then return end

    for key, container in pairs(containers) do
        if type(key) == "string" and type(container) == "table"
           and container.containerType == "customBar"
           and container._migratedFromCustomTrackers
        then
            containers[key] = nil
            if type(globalDB) == "table"
               and type(globalDB.ncdm) == "table"
               and type(globalDB.ncdm.specTrackerSpells) == "table"
            then
                globalDB.ncdm.specTrackerSpells[key] = nil
            end
            local fa = profile.frameAnchoring
            if type(fa) == "table" then
                fa[GetCustomBarAnchorKey(key)] = nil
            end
        end
    end
end

function IsUncustomizedDefaultTrackerBar(bar)
    if type(bar) ~= "table" then return false end
    if bar.id ~= "default_tracker_1" then return false end
    if bar.enabled ~= nil and bar.enabled ~= false then return false end
    if bar.name ~= nil and bar.name ~= "Trinket & Pot" then return false end
    if bar.offsetX ~= nil and bar.offsetX ~= -406 then return false end
    if bar.offsetY ~= nil and bar.offsetY ~= -152 then return false end
    if bar.iconSize ~= nil and bar.iconSize ~= 28 then return false end
    if bar.spacing ~= nil and bar.spacing ~= 4 then return false end

    local entries = bar.entries
    if type(entries) == "table" then
        if #entries ~= 1 then return false end
        local entry = entries[1]
        if type(entry) ~= "table" or entry.type ~= "item" or entry.id ~= 224022 then
            return false
        end
    end

    return true
end


function Migrations.RepairCustomTrackerSpecStorage(profile, globalDB)
    if type(profile) ~= "table" then return false end
    local containers = profile.ncdm and profile.ncdm.containers
    if type(containers) ~= "table" then return false end
    globalDB = globalDB or _currentGlobalDB
    if type(globalDB) ~= "table" then return false end
    if type(globalDB.ncdm) ~= "table" then globalDB.ncdm = {} end
    if type(globalDB.ncdm.specTrackerSpells) ~= "table" then
        globalDB.ncdm.specTrackerSpells = {}
    end

    local root = globalDB.ncdm.specTrackerSpells
    local changed = false

    for containerKey, container in pairs(containers) do
        if type(containerKey) == "string"
           and containerKey:find("^customBar_")
           and type(container) == "table"
        then
            local byContainer = root[containerKey]
            if type(byContainer) == "table" then
                local keys = {}
                for specKey in pairs(byContainer) do
                    keys[#keys + 1] = specKey
                end

                for _, specKey in ipairs(keys) do
                    local list = byContainer[specKey]
                    if type(list) == "table" then
                        local canonicalKey, specID = GetCanonicalSpecKey(specKey)
                        canonicalKey = canonicalKey or specKey
                        if not specID and type(container._sourceSpecID) == "number" then
                            specID = container._sourceSpecID
                        end

                        for _, entry in ipairs(list) do
                            StampLegacySpecEntry(entry, specID, specKey)
                        end
                        if DeduplicateEntryList(list) then
                            changed = true
                        end

                        if canonicalKey ~= specKey then
                            if type(byContainer[canonicalKey]) == "table" then
                                if MergeSpecEntryLists(byContainer[canonicalKey], list) then
                                    changed = true
                                end
                            else
                                byContainer[canonicalKey] = list
                                changed = true
                            end
                            byContainer[specKey] = nil
                            RecordSpecKeyAlias(container, specKey, canonicalKey)
                            changed = true
                        end
                    end
                end
            end

            -- Defensive late pass: if any container.entries leaked back
            -- into a spec-specific bar between v32(d) and here, promote
            -- it through the same path. PromoteLegacyContainerEntriesToPerSpec
            -- handles _sourceSpecID stamping internally; the wipe stays
            -- unconditional for the no-source-spec corner case.
            if container.specSpecific == true
               and type(container.entries) == "table"
               and #container.entries > 0
            then
                PromoteLegacyContainerEntriesToPerSpec(profile, containerKey, container, globalDB)
                container.entries = {}
                changed = true
            end
        end
    end

    return changed
end


----------------------------------------------------------------------------
-- Promote legacy container.entries on a spec-specific customBar into the
-- canonical per-spec storage location at
-- db.global.ncdm.specTrackerSpells[containerKey][canonicalSpec].
--
-- Used by RepairCustomTrackerSpecStorage just before it clears
-- container.entries.
-- Each promoted entry is cloned and stamped with _sourceSpecID,
-- _legacySourceSpecKey, and _legacySpellbookSlot so the composer's
-- "Source: <Spec>" tooltip and "Legacy data" hint can attach to it. Real
-- spell IDs and pre-V2 drag-handler garbage both go through unconditionally
-- — the runtime icon factory renders the standard ? fallback for IDs that
-- C_Spell.GetSpellInfo can't resolve, IsPlayerSpell drives the "Not usable
-- on your current class" hint for known-but-cross-class entries, and the
-- _legacySpellbookSlot stamp drives the "Legacy data — may need review"
-- hint. The user gets visibility into what was imported instead of a
-- silently empty bar.
--
-- Returns true if anything was promoted, false otherwise. Caller still
-- wipes container.entries unconditionally so a no-source-spec-hint bar
-- ends up empty (matches prior wipe semantics in that corner case).
----------------------------------------------------------------------------
PromoteLegacyContainerEntriesToPerSpec = function(profile, containerKey, container, globalDB)
    if type(container) ~= "table" then return false end
    if container.specSpecific ~= true then return false end
    if type(container.entries) ~= "table" or #container.entries == 0 then return false end

    local sourceSpecID = container._sourceSpecID
    if type(sourceSpecID) ~= "number" or sourceSpecID <= 0 then
        sourceSpecID = GetProfileSourceSpecID(profile)
    end
    if type(sourceSpecID) ~= "number" or sourceSpecID <= 0 then
        return false
    end
    if container._sourceSpecID == nil then
        container._sourceSpecID = sourceSpecID
    end

    globalDB = globalDB or _currentGlobalDB
    if type(globalDB) ~= "table" then return false end
    if type(globalDB.ncdm) ~= "table" then globalDB.ncdm = {} end
    if type(globalDB.ncdm.specTrackerSpells) ~= "table" then
        globalDB.ncdm.specTrackerSpells = {}
    end
    local root = globalDB.ncdm.specTrackerSpells
    if type(root[containerKey]) ~= "table" then
        root[containerKey] = {}
    end
    local byContainer = root[containerKey]

    local canonicalKey = GetCanonicalSpecKey(sourceSpecID) or tostring(sourceSpecID)
    if type(byContainer[canonicalKey]) ~= "table" then
        byContainer[canonicalKey] = {}
    end

    local promoted = {}
    for _, entry in ipairs(container.entries) do
        if type(entry) == "table" then
            local clone = CloneValue(entry)
            StampLegacySpecEntry(clone, sourceSpecID, tostring(sourceSpecID),
                { legacySpellbookSlot = true })
            promoted[#promoted + 1] = clone
        end
    end
    MergeSpecEntryLists(byContainer[canonicalKey], promoted)
    DeduplicateEntryList(byContainer[canonicalKey])
    return true
end


---------------------------------------------------------------------------
-- Late migration: import action bar / micro menu / bag bar positions from
-- Blizzard Edit Mode for users whose QUI profile predates frame anchoring
-- for these bars. Runs at PLAYER_LOGIN (not at addon-init time) because it
-- depends on EditModeManagerFrame being populated and the live bar frames
-- being laid out, neither of which is guaranteed during ADDON_LOADED.
--
-- Per-bar gating:
--   1. Bar already has a real (non-placeholder) frameAnchoring entry → PROTECTED.
--      Users who positioned the bar in QUI's Layout Mode keep their position.
--   2. Live frame readable → IMPORTED. Read absolute screen coords from
--      the live frame (lets WoW resolve any anchor chain like
--      MainActionBar → MultiBar5 → ...) and write a UIParent-relative
--      anchor into profile.frameAnchoring[<key>].
--   3. Live frame missing/nil-coords → SKIPPED. Bar gets no entry from
--      this migration; sentinel still stamps so we don't retry forever.
--      Affects e.g. stance bar on a stanceless character — harmless
--      because that bar is never visible for them anyway.
--
-- Note: we deliberately do NOT skip `isInDefaultPosition` entries. Even
-- bars at Blizzard's default need to be captured as explicit QUI data,
-- otherwise the migration leaves a gap exactly where legacy users with
-- no QUI overrides need it filled — they currently get the EditMode
-- position via actionbars.lua's RestoreContainerPosition fallback, but
-- that fallback depends on the live Blizzard frame being readable at
-- apply time. Importing makes the position permanent and editable.
--
-- Sentinel: profile._abPositionsImportedFromEditMode. Stamped after the
-- first successful EditMode read regardless of how many bars actually
-- imported — this is a one-shot best-effort migration, not a "keep
-- trying until everything succeeds" loop.
--
-- Only operates on the active profile (db.profile), not all stored
-- profiles, because EditMode layouts are per-character and other profiles
-- belong to alts with potentially different EditMode setups.
---------------------------------------------------------------------------

-- (system, systemIndex) → { fa = frameAnchoring key, frame = global frame name }
-- Indexed by [system][systemIndex] for ActionBar (which has multiple
-- instances), and [system]["*"] for MicroMenu/Bags (single instance, no
-- systemIndex). Built lazily so the Enum reference doesn't blow up if
-- this file is loaded in a context without Blizzard's enums.
local EM_TO_QUI = nil
local function GetEditModeLookup()
    if EM_TO_QUI then return EM_TO_QUI end
    if type(Enum) ~= "table" or type(Enum.EditModeSystem) ~= "table" then
        return nil
    end
    local AB    = Enum.EditModeSystem.ActionBar
    local MICRO = Enum.EditModeSystem.MicroMenu
    local BAGS  = Enum.EditModeSystem.Bags
    if AB == nil or MICRO == nil or BAGS == nil then
        return nil
    end
    EM_TO_QUI = {
        [AB] = {
            [1]  = { fa = "bar1",      frame = "MainActionBar" },
            [2]  = { fa = "bar2",      frame = "MultiBarBottomLeft" },
            [3]  = { fa = "bar3",      frame = "MultiBarBottomRight" },
            [4]  = { fa = "bar4",      frame = "MultiBarRight" },
            [5]  = { fa = "bar5",      frame = "MultiBarLeft" },
            [6]  = { fa = "bar6",      frame = "MultiBar5" },
            [7]  = { fa = "bar7",      frame = "MultiBar6" },
            [8]  = { fa = "bar8",      frame = "MultiBar7" },
            [11] = { fa = "stanceBar", frame = "StanceBar" },
            [12] = { fa = "petBar",    frame = "PetActionBar" },
            -- 13 = PossessActionBar — intentionally omitted, QUI doesn't manage it
        },
        [MICRO] = { ["*"] = { fa = "microMenu", frame = "MicroMenuContainer" } },
        [BAGS]  = { ["*"] = { fa = "bagBar",    frame = "BagsBar" } },
    }
    return EM_TO_QUI
end

local function LookupEditModeSystem(sys)
    local lookup = GetEditModeLookup()
    if not lookup then return nil end
    local typeTable = lookup[sys.system]
    if not typeTable then return nil end
    return typeTable[sys.systemIndex] or typeTable["*"]
end

local function MigrateActionBarPositionsFromEditMode(profile)
    if type(profile) ~= "table" then return end
    if profile._abPositionsImportedFromEditMode then
        MigLog("EditMode AB import: sentinel set, skipping")
        return
    end

    -- Scope gate: this migration is intended for fresh installs and
    -- pre-3.0 legacy upgraders. RunOnProfile flags eligible profiles
    -- (those whose pre-migration `_schemaVersion` was < 19, i.e. before
    -- MigrateAnchoringV1) by setting `_needsLateAbImport`. Profiles
    -- without that flag have already been through the modern anchoring
    -- pipeline and have explicit QUI positions for any bars they care
    -- about, so we just stamp the sentinel and return.
    if not profile._needsLateAbImport then
        MigLog("EditMode AB import: profile not flagged for late import, stamping sentinel and skipping")
        profile._abPositionsImportedFromEditMode = true
        return
    end

    if not (EditModeManagerFrame and EditModeManagerFrame.GetActiveLayoutInfo) then
        MigLog("EditMode AB import: EditModeManagerFrame not ready, will retry")
        return
    end

    local layout = EditModeManagerFrame:GetActiveLayoutInfo()
    if type(layout) ~= "table" or type(layout.systems) ~= "table" then
        MigLog("EditMode AB import: no active layout, will retry")
        return
    end

    profile.frameAnchoring = profile.frameAnchoring or {}
    local fa = profile.frameAnchoring

    local imported, protected, skipped = 0, 0, 0

    for _, sys in ipairs(layout.systems) do
        local mapping = LookupEditModeSystem(sys)
        if mapping then
            local key = mapping.fa
            local existing = fa[key]
            local userHasPosition = (existing ~= nil) and (not IsPlaceholderAnchorEntry(existing))

            if userHasPosition then
                protected = protected + 1
                MigLog("  %s: PROTECTED (user has QUI position)", key)
            else
                local frame = _G[mapping.frame]
                local L = frame and frame.GetLeft and frame:GetLeft()
                local B = frame and frame.GetBottom and frame:GetBottom()
                if type(L) == "number" and type(B) == "number" then
                    fa[key] = {
                        parent   = "screen",
                        point    = "BOTTOMLEFT",
                        relative = "BOTTOMLEFT",
                        offsetX  = L,
                        offsetY  = B,
                    }
                    imported = imported + 1
                    MigLog("  %s: IMPORTED at %.1f, %.1f (from %s, %s)",
                        key, L, B, mapping.frame,
                        sys.isInDefaultPosition and "default" or "moved")
                else
                    skipped = skipped + 1
                    MigLog("  %s: SKIPPED (frame %s not laid out)", key, mapping.frame)
                end
            end
        end
    end

    -- One-shot best-effort: stamp the sentinel after a successful
    -- EditMode read regardless of how many bars actually imported.
    -- Bars that couldn't be read (e.g. stance bar on a stanceless
    -- character) won't get retried — they're invisible for that
    -- character anyway and don't need a frameAnchoring entry.
    profile._abPositionsImportedFromEditMode = true
    profile._needsLateAbImport = nil

    MigLog("EditMode AB import done: imported=%d protected=%d skipped=%d",
        imported, protected, skipped)
end

---------------------------------------------------------------------------
-- Late entry point: migrations that depend on Blizzard runtime state
---------------------------------------------------------------------------
-- Called from QUICore PLAYER_LOGIN (after EditModeManagerFrame is loaded
-- and live frames are laid out, but before the action bar module applies
-- frameAnchoring on PLAYER_ENTERING_WORLD).
--
-- Unlike Migrations.Run, this only operates on the active profile —
-- the data sources (live frames, EditMode layout) are per-character and
-- don't apply to alts' stored profiles.
function Migrations.RunLate(db)
    if not db then return false end
    local profile = db.profile
    if type(profile) ~= "table" then return false end
    MigrateActionBarPositionsFromEditMode(profile)
    return true
end

---------------------------------------------------------------------------
-- Entry point: Run all profile migrations
---------------------------------------------------------------------------
--
-- Note: SeedDefaultFrameAnchoring and DEFAULT_FRAME_ANCHORING used to live
-- here. They wrote a parallel copy of default frameAnchoring entries into
-- every profile on login, bloating SVs with data AceDB already provides
-- via its defaults metatable. Removed. All frameAnchoring defaults now
-- live in core/defaults.lua as the single source of truth. AceDB serves
-- them on read, strips them on save, and no migration write is needed.
--
-- For legacy 2.55 absolute-offset profiles, MigrateAnchoring v1's
-- LEGACY255_DISCARD_ABSOLUTE handling still nils the broken entries;
-- AceDB defaults then fill in the replacements via metatable.

---------------------------------------------------------------------------
-- Snapshot / restore
---------------------------------------------------------------------------
-- Before the migration pipeline mutates a profile, we save a deep copy of
-- the profile under `_migrationBackup`. If a migration corrupts data, the
-- user can run `/qui migration restore [N]` to roll back to the latest
-- pre-migration state. Only the newest snapshot is retained; older builds
-- kept several full profile copies, which made SavedVariables expensive to
-- parse during login/reload.
--
-- The backup excludes `_migrationBackup` itself to prevent recursive growth,
-- and excludes legacy per-profile shipped-default snapshots because those are
-- now represented once in global storage.

local BACKUP_KEY = "_migrationBackup"
local MAX_BACKUP_SLOTS = 1
local BACKUP_EXCLUDED_KEYS = {
    [BACKUP_KEY] = true,
    _shippedDefaults = true,
}

local function DeepCloneExcluding(value, excludedKeys)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do
        if not excludedKeys[k] then
            copy[k] = DeepCloneExcluding(v, excludedKeys)
        end
    end
    return copy
end

-- Returns the backup container in slotted form, lazily upgrading the
-- legacy single-slot shape ({fromVersion, toVersion, savedAt, snapshot})
-- to the new {slots = {...}} shape. Returns nil if no backup exists.
local function GetBackupContainer(profile)
    local b = profile[BACKUP_KEY]
    if type(b) ~= "table" then return nil end
    if type(b.slots) == "table" then
        return b
    end
    -- Legacy single-slot shape — migrate in place.
    if type(b.snapshot) == "table" then
        local upgraded = { slots = { {
            fromVersion = b.fromVersion,
            toVersion   = b.toVersion,
            savedAt     = b.savedAt,
            snapshot    = b.snapshot,
        } } }
        profile[BACKUP_KEY] = upgraded
        return upgraded
    end
    return nil
end

local function CreateBackup(profile, fromVersion)
    local container = GetBackupContainer(profile) or { slots = {} }
    local newEntry = {
        fromVersion = fromVersion or 0,
        toVersion   = CURRENT_SCHEMA_VERSION,
        savedAt     = (time and time()) or 0,
        snapshot    = DeepCloneExcluding(profile, BACKUP_EXCLUDED_KEYS),
    }
    -- Push to front, trim tail to MAX_BACKUP_SLOTS.
    table.insert(container.slots, 1, newEntry)
    while #container.slots > MAX_BACKUP_SLOTS do
        table.remove(container.slots)
    end
    profile[BACKUP_KEY] = container
end

-- Restore the active profile from a migration backup slot. `slotIndex`
-- is 1-based and defaults to 1 (most recent). Wipes all current profile
-- keys (except the backup container itself) and copies the snapshot in.
-- Returns (ok, messageOrBackupInfo).
function Migrations.Restore(profile, slotIndex)
    if type(profile) ~= "table" then
        return false, "no profile"
    end
    local container = GetBackupContainer(profile)
    if not container or #container.slots == 0 then
        return false, "no migration backup available for this profile"
    end
    slotIndex = tonumber(slotIndex) or 1
    if slotIndex < 1 or slotIndex > #container.slots then
        return false, ("invalid slot %d (have %d backup(s))"):format(slotIndex, #container.slots)
    end
    local entry = container.slots[slotIndex]
    if type(entry) ~= "table" or type(entry.snapshot) ~= "table" then
        return false, ("backup slot %d is empty or corrupt"):format(slotIndex)
    end

    for k in pairs(profile) do
        if k ~= BACKUP_KEY then
            profile[k] = nil
        end
    end
    for k, v in pairs(entry.snapshot) do
        profile[k] = DeepCloneExcluding(v, BACKUP_EXCLUDED_KEYS)
    end
    -- After restore, the profile is back at its pre-migration version. The
    -- backup container is preserved so the user can restore other slots.
    return true, entry
end

local function PruneBackupContainer(profile)
    local existing = profile[BACKUP_KEY]
    local container = GetBackupContainer(profile)
    if not container or type(container.slots) ~= "table" then
        if existing ~= nil then
            profile[BACKUP_KEY] = nil
            return true
        end
        return false
    end

    local changed = existing ~= profile[BACKUP_KEY]
    local prunedSlots = {}
    for _, entry in ipairs(container.slots) do
        local snapshot = entry and entry.snapshot
        if type(snapshot) == "table" then
            for excludedKey in pairs(BACKUP_EXCLUDED_KEYS) do
                if snapshot[excludedKey] ~= nil then
                    snapshot[excludedKey] = nil
                    changed = true
                end
            end
            if #prunedSlots < MAX_BACKUP_SLOTS then
                prunedSlots[#prunedSlots + 1] = entry
            else
                changed = true
            end
        else
            changed = true
        end
    end

    if #prunedSlots == 0 then
        changed = changed or profile[BACKUP_KEY] ~= nil
        profile[BACKUP_KEY] = nil
    else
        changed = changed or #container.slots ~= #prunedSlots
        container.slots = prunedSlots
        profile[BACKUP_KEY] = container
    end

    return changed
end

-- Returns the full backup container ({slots = {...}}) for inspection.
-- Lazily upgrades legacy single-slot shape on read.
function Migrations.GetBackupInfo(profile)
    if type(profile) ~= "table" then return nil end
    PruneBackupContainer(profile)
    return GetBackupContainer(profile)
end

Migrations.MAX_BACKUP_SLOTS = MAX_BACKUP_SLOTS


-- Clear every key on a profile table in place, preserving only the migration
-- backup container so a floored profile can still be rolled back. Used by the
-- schema-47 floor in RunOnProfile before flagging a starter-profile reseed.
local function WipeProfileData(profile)
    for k in pairs(profile) do
        if k ~= BACKUP_KEY then
            profile[k] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Entry point: Run all profile migrations
---------------------------------------------------------------------------
--
-- Run the full migration pipeline against a single raw profile table.
-- Accepts either db.profile (AceDB proxy) or a raw db.sv.profiles[name]
-- entry. Operates only on explicit user data — never relies on AceDB
-- default-merging, so it's safe to call against raw tables that have
-- never been touched by AceDB.
--
-- Each migration is gated by a linear schema version. A profile's
-- `_schemaVersion` records the last version it was migrated through;
-- on upgrade, gates v(stored+1)..v(CURRENT) run in order. Each migration
-- function retains an internal data-shape guard so that running it twice
-- (e.g. on a profile already at CURRENT that re-enters the pipeline from
-- a profile import) is a no-op.
--
-- Historical note: prior to the rewrite, CURRENT_SCHEMA_VERSION was a
-- constant `1` that never matched the actual number of migrations added
-- over time. Profiles from the 3.0 – 3.1.4 era all have `_schemaVersion=1`
-- stamped regardless of which migrations had actually run; they are
-- treated as v1 here and all post-v1 gates re-run against them, relying
-- on each migration's internal shape guards to no-op on already-migrated
-- data.
function Migrations.RunOnProfile(profile)
    if type(profile) ~= "table" then return false end

    local cleanupChanged = PruneBackupContainer(profile)

    local stored = tonumber(profile._schemaVersion) or 0

    -- === Migration floor (schema 47) ===
    -- A profile stored below MIN_SUPPORTED_SCHEMA (47) is too old to upgrade
    -- step-by-step: every incremental migration through v47 was removed in 5.0,
    -- leaving the floor as the lowest schema we still carry forward. Rather than
    -- leave it half-migrated, snapshot it, wipe it, and flag it for a Starter
    -- Profile reseed at login — the reseed lives in QUI_Options (where the
    -- preset string + import engine load) and prompts a reload. Fresh profiles
    -- (stored==0) are explicitly NOT floored: they take the normal fresh-init
    -- path through the single gate below.
    if stored > 0 and stored < MIN_SUPPORTED_SCHEMA then
        MigLog("RunOnProfile: stored=%d below floor %d — backup + reseed",
            stored, MIN_SUPPORTED_SCHEMA)
        CreateBackup(profile, stored)
        WipeProfileData(profile)
        profile._needsStarterReseed = true
        profile._schemaVersion = CURRENT_SCHEMA_VERSION
        return true
    end

    -- Flag fresh profiles for the late EditMode action bar import. v19
    -- (the removed MigrateAnchoringV1) was the first migration to write
    -- frameAnchoring data; a fresh profile (stored==0) has none yet, so the
    -- late EditMode import should run for it. The flag is read at PLAYER_LOGIN
    -- by Migrations.RunLate after EditModeManagerFrame loads. Profiles at v31+
    -- already carry anchoring data and never get the flag, so RunLate stamps
    -- their sentinel and skips the import loop.
    if stored == 0 and not profile._abPositionsImportedFromEditMode then
        profile._needsLateAbImport = true
    end

    do
        local faCount = 0
        if type(profile.frameAnchoring) == "table" then
            for _ in pairs(profile.frameAnchoring) do faCount = faCount + 1 end
        end
        MigLog("=== RunOnProfile: stored=%d current=%d faEntries=%d ===",
            stored, CURRENT_SCHEMA_VERSION, faCount)
        if type(profile.frameAnchoring) == "table" and profile.frameAnchoring.debuffFrame then
            local d = profile.frameAnchoring.debuffFrame
            MigLog("  pre-mig debuffFrame: parent=%s point=%s ofs=%s/%s enabled=%s",
                tostring(d.parent), tostring(d.point), tostring(d.offsetX), tostring(d.offsetY), tostring(d.enabled))
        else
            MigLog("  pre-mig debuffFrame: NIL (no raw entry)")
        end
    end

    -- ResetCastbarPreviewModes is a runtime sanity reset, NOT a migration —
    -- it clears the transient previewMode flag on every load so a preview
    -- left enabled in a prior session never persists. Always runs.
    ResetCastbarPreviewModes(profile)

    if stored >= CURRENT_SCHEMA_VERSION then
        MigLog("RunOnProfile: stored >= current, NOTHING TO DO")
        return cleanupChanged
    end

    -- Skip the backup for empty/fresh profiles — there's nothing worth
    -- rolling back to. A profile is "fresh" if it has no keys other than
    -- internal version stamps.
    local hasUserData = false
    for k in pairs(profile) do
        if k ~= "_schemaVersion" and k ~= "_defaultsVersion" and k ~= BACKUP_KEY then
            hasUserData = true
            break
        end
    end

    -- Snapshot BEFORE any gate runs, so a failed/corrupt migration can
    -- always be rolled back to the pre-pipeline state.
    if hasUserData then
        CreateBackup(profile, stored)
    end

    -- === All step-by-step migrations through v47 removed in 5.0 ===
    -- Those incremental steps were deleted; profiles older than
    -- MIN_SUPPORTED_SCHEMA (47) are floored at the top of this function (backed
    -- up, wiped, and flagged for a starter-profile reseed), so they never reach
    -- the gate below. Any profile that does reach here is at the v47 floor or
    -- newer and needs at most the single surviving v48 migration.

    -- v48: restore the two-container player buff/debuff model. This is the only
    -- surviving migration: every profile at or above the v47 floor needs at most
    -- this one step. Older profiles are floored (backed up + reseeded) at the top
    -- of this function and never reach here. See
    -- docs/superpowers/specs/2026-06-26-migration-floor-47-collapse-design.md.
    if stored < 48 then Migrations.RestoreBuffDebuffSplit(profile) end

    profile._schemaVersion = CURRENT_SCHEMA_VERSION
    return true
end

-- Run migrations across every stored profile in the database. Previously
-- this function only touched db.profile (the active profile of the logged-
-- in character), leaving all other profiles frozen in their pre-migration
-- state until the user happened to log in on the matching character. Now
-- it iterates db.sv.profiles and migrates each one.
--
-- For stub db objects (e.g. profile import path) without db.sv.profiles,
-- falls back to migrating db.profile alone.
function Migrations.Run(db)
    if not db then return false end

    -- Expose db.global to migrations that need cross-profile / global
    -- reads (e.g. v32's legacy spec-tracker port). Cleared on exit so
    -- individual RunOnProfile calls from other entry points (profile
    -- import, profile switch) get nil and handle its absence gracefully.
    _currentGlobalDB = db.global

    local sv = db.sv

    local profiles = sv and sv.profiles
    if type(profiles) == "table" then
        local any = false
        for _, profile in pairs(profiles) do
            if Migrations.RunOnProfile(profile) then
                any = true
            end
        end

        local pins = ns.Settings and ns.Settings.Pins
        if pins and type(pins.IsAutoApplySuppressed) == "function"
            and not pins:IsAutoApplySuppressed() then
            if type(pins.PrepareActiveProfileForApply) == "function" then
                pins:PrepareActiveProfileForApply(db)
            end
            if type(pins.ApplyAllForDB) == "function" then
                pins:ApplyAllForDB(db)
            end
        end

        _currentGlobalDB     = nil
        return any
    end

    local result = Migrations.RunOnProfile(db.profile)

    local pins = ns.Settings and ns.Settings.Pins
    if pins and type(pins.IsAutoApplySuppressed) == "function"
        and not pins:IsAutoApplySuppressed() then
        if type(pins.PrepareActiveProfileForApply) == "function" then
            pins:PrepareActiveProfileForApply(db)
        end
        if type(pins.ApplyAllForDB) == "function" then
            pins:ApplyAllForDB(db)
        end
    end

    _currentGlobalDB     = nil
    return result
end
