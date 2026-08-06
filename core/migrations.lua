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

local _currentGlobalDB     = nil

local CURRENT_SCHEMA_VERSION = 60

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
        local ok, msg = ns.SafeCall("report", string.format, fmt, ...)
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


-- v59 squash step (a): restore the two-container player buff/debuff model
-- before the flat settings are consumed by SeedAuraElements.
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

-- v59 squash step (b): the private-aura feature is gone (runtime consumers,
-- settings surfaces, and defaults all removed). Strip any stored privateAuras
-- subtable left behind by an older profile so it doesn't linger as dead
-- data. Mirrors the exact paths the removed defaults carried it under:
-- quiUnitFrames.player/target/focus and quiGroupFrames.party/raid.
function Migrations.PrunePrivateAuras(profile)
    if type(profile) ~= "table" then return end

    local uf = profile.quiUnitFrames
    if type(uf) == "table" then
        for _, unitKey in ipairs({ "player", "target", "focus" }) do
            local unit = uf[unitKey]
            if type(unit) == "table" then
                unit.privateAuras = nil
            end
        end
    end

    local gf = profile.quiGroupFrames
    if type(gf) == "table" then
        for _, contextMode in ipairs({ "party", "raid" }) do
            local contextDB = gf[contextMode]
            if type(contextDB) == "table" then
                contextDB.privateAuras = nil
            end
        end
    end
end

-- v59 squash step (c): aura-surface unification. The three aura surfaces
-- converge on ONE model
-- (core/aura_elements.lua): a spec-bucket store `auras.elements = { ["*"] = {
-- element, ... } }` guarded by `elementsSeeded`.
--   * buffborders: flat per-strip settings -> buffAuras / debuffAuras stores.
--   * unit frames: flat per-strip settings -> auras.elements store.
--   * group frames: elements already exist -> NormalizeElement in place.
-- Runs at ADDON_LOADED, strictly before any surface renders (renders are
-- post-PEW), so the stores are seeded first. SKIPS any store already carrying
-- elementsSeeded (idempotency + never clobbers a runtime-seeded fresh profile).
-- Nil-guarded throughout; prunes ONLY known migrated keys.
-- Returns false (without seeding) if the element model isn't loaded — the
-- caller must NOT stamp in that case or the flat keys would strand
-- unmigrated behind the version gate. Unreachable in practice (migration
-- fires at ADDON_LOADED after all TOC files; headless/import callers load
-- core first); belt-and-braces only.
function Migrations.SeedAuraElements(profile)
    local E = _G.QUI and _G.QUI.AuraElements
    if not E then return false end

    -- ---- buffborders ------------------------------------------------------
    local bb = profile.buffBorders
    if type(bb) == "table" then
        local FLAG_KEYS = {
            buff = { buffFilterPlayer = "PLAYER", buffFilterRaid = "RAID",
                     buffFilterCancelable = "CANCELABLE",
                     buffFilterBigDefensive = "BIG_DEFENSIVE" },
            debuff = { debuffFilterPlayer = "PLAYER", debuffFilterRaid = "RAID",
                       debuffFilterIncludeNameplateOnly = "INCLUDE_NAME_PLATE_ONLY",
                       -- Legacy checkbox meant "dispellable by me"; 68675
                       -- moved that semantic to RAID (RAID_PLAYER_DISPELLABLE
                       -- now means anyone-in-raid). Port to the token that
                       -- preserves the user's intent.
                       debuffFilterRaidPlayerDispellable = "RAID",
                       debuffFilterCrowdControl = "CROWD_CONTROL" },
        }
        local function seedZone(prefix, storeKey, auraType, enableKey, cancelable)
            if type(bb[storeKey]) == "table" and bb[storeKey].elementsSeeded then return end
            local e = E.NewFilterStripElement(auraType)
            e.id = prefix .. "s"
            -- Frame-level enable stays a settings-level read (the runtime gates
            -- the whole host on bb.enableBuffs/enableDebuffs), but the per-strip
            -- element inherits the same on/off state so a disabled host does not
            -- render a strip that would flip on the moment the host is enabled.
            e.enabled = (bb[enableKey] ~= false)
            -- ABSENT-key resolution: this migration reads RAW SavedVariables
            -- (Migrations.Run iterates db.sv.profiles) and AceDB never persists
            -- unchanged defaults — an absent key means HEAD rendered the
            -- defaults.lua value. Two DISTINCT iconSize resolutions:
            --   * ABSENT           -> 35 (defaults.lua buff/debuffIconSize)
            --   * PRESENT but <= 0 -> 30 (HEAD BuildZoneProfile's explicit
            --     DEFAULT_ICON_SIZE reset for the 0 = "use default" sentinel)
            -- perRow/spacing resolve identically on both paths (absent ->
            -- defaults 10/0; BuildZoneProfile resolved <= 0 -> 10/2 either way).
            local size = bb[prefix .. "IconSize"]
            if type(size) == "number" then
                e.iconSize = (size > 0) and size or 30
            else
                e.iconSize = 35
            end
            local perRow = bb[prefix .. "IconsPerRow"]
            e.iconsPerRow = (type(perRow) == "number" and perRow > 0) and perRow or 10
            local spacing = bb[prefix .. "IconSpacing"]
            e.spacing = (type(spacing) == "number" and spacing > 0) and spacing or 2
            -- HEAD's BuildZoneProfile capped every zone at the FIXED
            -- BUFF_MAX_DISPLAY / DEBUFF_MAX_DISPLAY (= 40), never a setting;
            -- the element-model default (3) would truncate the strip.
            e.maxIcons = 40
            -- Absent grow toggles resolve to the defaults.lua values
            -- (buff/debuffGrowLeft = true, GrowUp = false => grow LEFT from a
            -- TOPRIGHT origin). This corner also feeds UpdateGrowAnchor.
            local growLeft = bb[prefix .. "GrowLeft"]
            if growLeft == nil then growLeft = true end
            local growUp = bb[prefix .. "GrowUp"] == true
            e.growDirection = growLeft and "LEFT" or "RIGHT"
            if growUp then
                e.anchor = growLeft and "BOTTOMRIGHT" or "BOTTOMLEFT"
            else
                e.anchor = growLeft and "TOPRIGHT" or "TOPLEFT"
            end
            e.sortRule = bb[prefix .. "SortRule"] or "INDEX"
            e.sortReverse = bb[prefix .. "SortReverse"] == true
            local flags, any = {}, false
            for dbKey, token in pairs(FLAG_KEYS[prefix]) do
                if bb[dbKey] then flags[token] = true; any = true end
            end
            -- The engine removed NOT_CANCELABLE. Preserve the legacy checkbox
            -- as the canonical negated CANCELABLE value, without overriding an
            -- explicitly enabled CANCELABLE checkbox if both were stored.
            if prefix == "buff" and bb.buffFilterNotCancelable then
                if flags.CANCELABLE == nil then flags.CANCELABLE = "exclude" end
                any = true
            end
            if any then
                e.filterMode = "flags"
                e.filterFlags = flags
            end
            -- Absent fontSize rendered the defaults.lua value (12), not the
            -- element-model default (9).
            e.duration.fontSize = (type(bb.fontSize) == "number" and bb.fontSize > 0) and bb.fontSize or 12
            e.duration.anchor = bb[prefix .. "DurationTextAnchor"] or e.duration.anchor
            e.duration.offsetX = bb[prefix .. "DurationTextOffsetX"] or e.duration.offsetX
            e.duration.offsetY = bb[prefix .. "DurationTextOffsetY"] or e.duration.offsetY
            e.stack.fontSize = e.duration.fontSize
            e.stack.anchor = bb[prefix .. "StackTextAnchor"] or e.stack.anchor
            e.stack.offsetX = bb[prefix .. "StackTextOffsetX"] or e.stack.offsetX
            e.stack.offsetY = bb[prefix .. "StackTextOffsetY"] or e.stack.offsetY
            e.rightClickCancel = cancelable
            bb[storeKey] = { elementsSeeded = true, elements = { ["*"] = { e } } }
        end
        seedZone("buff", "buffAuras", "HELPFUL", "enableBuffs", true)
        seedZone("debuff", "debuffAuras", "HARMFUL", "enableDebuffs", false)
        -- Prune every migrated per-strip key. Frame-level keys SURVIVE:
        -- enableBuffs/enableDebuffs (per-frame master gate), hide*/fade*,
        -- showBuffBorders/showDebuffBorders, iconSkin, externalSkinning,
        -- borderSize, fontSize, fontOutline.
        local PRUNE_SUFFIXES = {
            "IconSize", "IconsPerRow", "IconSpacing", "GrowLeft", "GrowUp",
            "SortRule", "SortReverse", "RowSpacing", "InvertSwipeDarkening",
            "DurationTextAnchor", "DurationTextOffsetX", "DurationTextOffsetY",
            "StackTextAnchor", "StackTextOffsetX", "StackTextOffsetY",
        }
        for _, prefix in ipairs({ "buff", "debuff" }) do
            for _, suffix in ipairs(PRUNE_SUFFIXES) do
                bb[prefix .. suffix] = nil
            end
            for dbKey in pairs(FLAG_KEYS[prefix]) do
                bb[dbKey] = nil
            end
            if prefix == "buff" then bb.buffFilterNotCancelable = nil end
        end
    end

    -- ---- unit frames ------------------------------------------------------
    -- Effective HEAD render defaults PER UNIT. This migration reads RAW
    -- SavedVariables, and AceDB never persists unchanged defaults — an absent
    -- key means HEAD rendered that unit's defaults.lua value (per-unit auras
    -- blocks, deleted by the 5.0 defaults restructure), falling through to
    -- HEAD's code fallback for keys no block declared (buff/debuffMaxPerRow on
    -- non-player units -> 0, spacing on tt/pet/focus/boss -> 2). Values below
    -- transcribed from `git show HEAD:core/defaults.lua`: iconSize + maxIcons
    -- + offsetY are the only per-unit variations (HEAD's debuff size read the
    -- shared `iconSize` key; only focus declared non-zero offsets and 16 max).
    local UF_HEAD_DEFAULTS = {
        player       = { buff = { iconSize = 22, maxIcons = 4,  offsetY = 0 },  debuff = { iconSize = 22, maxIcons = 4,  offsetY = 0 } },
        target       = { buff = { iconSize = 18, maxIcons = 4,  offsetY = 0 },  debuff = { iconSize = 26, maxIcons = 4,  offsetY = 0 } },
        targettarget = { buff = { iconSize = 22, maxIcons = 4,  offsetY = 0 },  debuff = { iconSize = 22, maxIcons = 4,  offsetY = 0 } },
        pet          = { buff = { iconSize = 22, maxIcons = 4,  offsetY = 0 },  debuff = { iconSize = 22, maxIcons = 4,  offsetY = 0 } },
        focus        = { buff = { iconSize = 20, maxIcons = 16, offsetY = -2 }, debuff = { iconSize = 20, maxIcons = 16, offsetY = 2 } },
        boss         = { buff = { iconSize = 22, maxIcons = 4,  offsetY = 0 },  debuff = { iconSize = 22, maxIcons = 4,  offsetY = 0 } },
    }
    -- Units with no HEAD defaults block: HEAD's code fallbacks
    -- (BuildZoneProfiles: iconSize 22, maxIcons 16, offsetY -2 buff / 2 debuff).
    local UF_HEAD_FALLBACK = {
        buff = { iconSize = 22, maxIcons = 16, offsetY = -2 },
        debuff = { iconSize = 22, maxIcons = 16, offsetY = 2 },
    }
    local uf = profile.quiUnitFrames
    if type(uf) == "table" then
        for unitKey, unit in pairs(uf) do
            local a = type(unit) == "table" and unit.auras
            if type(a) == "table" and not a.elementsSeeded then
                local unitDefaults = UF_HEAD_DEFAULTS[unitKey] or UF_HEAD_FALLBACK
                local function seedElem(prefix, auraType, showKey)
                    local d = unitDefaults[prefix]
                    local e = E.NewFilterStripElement(auraType)
                    e.id = prefix .. "s"
                    e.enabled = (a[showKey] == true)
                    -- HEAD's UF BuildZoneProfiles used auraSettings.iconSize for
                    -- the DEBUFF size fallback (there is no debuffIconSize key in
                    -- the shipped defaults — only the shared `iconSize`).
                    local size = a[prefix .. "IconSize"] or ((prefix == "debuff") and a.iconSize)
                    e.iconSize = (type(size) == "number" and size > 0) and size or d.iconSize
                    e.anchor = a[prefix .. "Anchor"] or ((prefix == "buff") and "BOTTOMLEFT" or "TOPLEFT")
                    e.growDirection = a[prefix .. "Grow"] or "RIGHT"
                    local m = a[prefix .. "MaxIcons"]
                    e.maxIcons = (type(m) == "number" and m > 0) and m or d.maxIcons
                    e.iconsPerRow = a[prefix .. "MaxPerRow"] or 0
                    e.offsetX = a[prefix .. "OffsetX"] or 0
                    e.offsetY = a[prefix .. "OffsetY"] or d.offsetY
                    e.spacing = a[prefix .. "Spacing"] or a.iconSpacing or 2
                    if a[prefix .. "FilterMode"] == "classification" and type(a[prefix .. "Classifications"]) == "table" then
                        e.filterMode = "classify"
                        e.classifications = a[prefix .. "Classifications"]
                        -- Legacy-master heal: pre-merge UF maps had ONLY the
                        -- helpful/harmful master keys and derived them as
                        -- (raid or raidInCombat). The merged model reads keys
                        -- independently, so a legacy {raid=true} shape would
                        -- silently lose RAID_IN_COMBAT (helpful) or fall to
                        -- bare-polarity (harmful). Stamp the master to preserve
                        -- pre-migration visuals exactly.
                        local c = e.classifications
                        local master = (auraType == "HELPFUL") and "helpful" or "harmful"
                        if c[master] == nil and (c.raid or c.raidInCombat) then
                            c[master] = true
                        end
                    elseif type(a[prefix .. "Filter"]) == "table" then
                        -- Legacy UF filter store is NESTED (HEAD's BuildFilterString
                        -- read { modifiers = {TOKEN=bool}, exclusive = "TOKEN"|nil });
                        -- tolerate flat {TOKEN=true} variants too. Convert only
                        -- engine tokens; container names never become filter tokens.
                        local lf = a[prefix .. "Filter"]
                        local valid = E.VALID_FILTER_TOKENS or {}
                        local flags = {}
                        if type(lf.modifiers) == "table" then
                            for tok, on in pairs(lf.modifiers) do
                                if on == true and valid[tok] then flags[tok] = true end
                            end
                        end
                        if type(lf.exclusive) == "string" and valid[lf.exclusive] then
                            flags[lf.exclusive] = true
                        end
                        for tok, on in pairs(lf) do
                            if on == true and valid[tok] then flags[tok] = true end
                        end
                        -- Preserve the removed NOT_CANCELABLE token from every
                        -- legacy spelling as canonical !CANCELABLE. Process it
                        -- after valid tokens so CANCELABLE=true wins conflicts.
                        local legacyNotCancelable = type(lf.modifiers) == "table"
                            and lf.modifiers.NOT_CANCELABLE == true
                        legacyNotCancelable = legacyNotCancelable
                            or lf.exclusive == "NOT_CANCELABLE"
                            or lf.NOT_CANCELABLE == true
                        if legacyNotCancelable and flags.CANCELABLE == nil then
                            flags.CANCELABLE = "exclude"
                        end
                        if next(flags) then
                            e.filterMode = "flags"
                            e.filterFlags = flags
                        end
                    end
                    -- Absent duration/stack sub-tables resolve to the HEAD
                    -- defaults.lua declarations (player/target blocks:
                    -- buffDuration show/fs12, debuffDuration hidden/fs10, stack
                    -- fs10) — identical to the staged DefaultUnitAuraBucket, so
                    -- migrated and fresh-seeded stores render the same. The
                    -- element-model defaults (fs 9) never rendered on UF.
                    local dur = a[prefix .. "Duration"]
                    if type(dur) == "table" then
                        e.duration = { show = dur.show ~= false, fontSize = dur.fontSize or 10,
                                       anchor = dur.anchor or "CENTER", offsetX = dur.offsetX or 0,
                                       offsetY = dur.offsetY or 0, color = dur.color or { 1, 1, 1, 1 } }
                    else
                        e.duration = { show = (prefix == "buff"), fontSize = (prefix == "buff") and 12 or 10,
                                       anchor = "CENTER", offsetX = 0, offsetY = 0, color = { 1, 1, 1, 1 } }
                    end
                    local st = a[prefix .. "Stack"]
                    if type(st) == "table" then
                        e.stack = { show = st.show ~= false, fontSize = st.fontSize or 10,
                                    anchor = st.anchor or "BOTTOMRIGHT", offsetX = st.offsetX or -1,
                                    offsetY = st.offsetY or 1, color = st.color or { 1, 1, 1, 1 } }
                    else
                        e.stack = { show = true, fontSize = 10, anchor = "BOTTOMRIGHT",
                                    offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } }
                    end
                    -- "Hide Duration Swipe" was a real HEAD checkbox
                    -- (per-zone prefixed key, shared fallback) — map it or
                    -- the user's setting silently reverts (element default
                    -- false re-enables the swipe permanently). reverseSwipe:
                    -- same shared-fallback read on HEAD's live path.
                    e.hideSwipe = (a[prefix .. "HideSwipe"] == true) or (a.hideSwipe == true)
                    e.reverseSwipe = (a[prefix .. "ReverseSwipe"] == true) or (a.reverseSwipe == true)
                    e.rightClickCancel = (unitKey == "player") and (auraType == "HELPFUL")
                    return e
                end
                local debuff = seedElem("debuff", "HARMFUL", "showDebuffs")
                local buff = seedElem("buff", "HELPFUL", "showBuffs")
                a.elements = { ["*"] = { debuff, buff } }
                a.elementsSeeded = true
                -- Prune migrated flat keys; unknown/sibling keys survive.
                local PRUNE = {
                    "showBuffs", "showDebuffs", "iconSize", "iconSpacing",
                    "hideSwipe", "reverseSwipe",
                    "durationColor", "showDuration", "durationSize", "durationAnchor",
                    "durationOffsetX", "durationOffsetY",
                    "stackColor", "showStack", "stackSize", "stackAnchor",
                    "stackOffsetX", "stackOffsetY",
                }
                for _, k in ipairs(PRUNE) do a[k] = nil end
                for _, prefix in ipairs({ "buff", "debuff" }) do
                    -- Duration* scalars (buffDurationSize etc.) were PREVIEW-only
                    -- orphans at HEAD (never live-rendered): prune, don't map.
                    for _, suffix in ipairs({ "IconSize", "Anchor", "Grow", "MaxIcons", "MaxPerRow",
                        "OffsetX", "OffsetY", "Spacing", "FilterMode", "FilterOnlyMine", "Classifications",
                        "Filter", "Duration", "Stack", "ShowStack", "StackSize", "StackAnchor",
                        "StackOffsetX", "StackOffsetY", "StackColor", "BorderSize", "FontSize",
                        "HideSwipe", "ReverseSwipe", "ShowDuration", "DurationSize", "DurationAnchor",
                        "DurationOffsetX", "DurationOffsetY", "DurationColor" }) do
                        a[prefix .. suffix] = nil
                    end
                end
            end
        end
    end

    -- ---- group frames (normalize in place) --------------------------------
    -- GF stores are already element-shaped at HEAD; normalize each element to
    -- fold flat duration fields and stamp the new fields. No legacy-master heal
    -- here: GF's HEAD classification map used the SPLIT keys directly (raid /
    -- raidInCombat), so no master derivation to preserve.
    local gf = profile.quiGroupFrames
    if type(gf) == "table" then
        for _, groupKey in ipairs({ "party", "raid" }) do
            local a = type(gf[groupKey]) == "table" and gf[groupKey].auras
            if type(a) == "table" and type(a.elements) == "table" then
                for _, bucket in pairs(a.elements) do
                    if type(bucket) == "table" then
                        for _, e in ipairs(bucket) do E.NormalizeElement(e) end
                    end
                end
            end
        end
    end
end

-- v59 squash step (d): fold the legacy GF
-- defensive indicator into the unified element model.
-- The indicator (healer.defensiveIndicator, its own renderer/classifier in
-- groupframes.lua) is replaced by a shipped "defensives" filterStrip element
-- (classify: bigDefensive + externalDefensive, engine-filtered). A latched
-- "*" bucket receives the shipped strip and every existing non-empty override
-- bucket receives a clone; empty overrides remain empty because they express
-- deliberate suppression. An unlatched store gets the strip from the
-- surface-aware runtime seed (Model.DefaultStripBucket). `enabled`
-- carries over ONLY when the raw SV stored enabled == true: migrations see
-- RAW profiles (no AceDB defaults merged) and the AceDB default was false on
-- BOTH surfaces, so an absent table/key means the user's effective value was
-- false. Old geometry is discarded by design (fresh-seed decision, see
-- docs/superpowers/specs/2026-07-10-defensives-fold-into-aura-elements-design.md).
-- Also strips the dead dedupeDefensives key from EVERY element store (no
-- runtime consumer since the pipeline unification) and deletes the old
-- healer.defensiveIndicator table. Self-contained (no element-model
-- dependency): plain-table injection, so no seed/repair-style bail. This literal
-- must stay field-identical to Model.DefaultStripBucket's third strip
-- (enabled excepted) — pinned by migration_schema59_defensives_fold_test.lua.
local function BuildShippedDefensivesElement(enabled)
    return {
        id = "defensives", enabled = enabled == true, mode = "filterStrip", auraType = "HELPFUL",
        anchor = "BOTTOMRIGHT", growDirection = "LEFT", spacing = 0,
        offsetX = 0, offsetY = 4, iconSize = 15, maxIcons = 3,
        hideSwipe = false, reverseSwipe = true,
        swipeStyle = "radial",
        duration = { show = true, fontSize = 9, anchor = "BOTTOM", offsetX = 0, offsetY = -6, color = { 1, 1, 1, 1 } },
        stack = { show = true, fontSize = 9, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } },
        filterMode = "classify", filterFlags = {},
        classifications = { bigDefensive = true, externalDefensive = true },
        borderColor = { 0, 0.8, 0, 1 },
        whitelist = {}, blacklist = {},
        sortRule = "INDEX", sortReverse = false, rightClickCancel = false,
    }
end

local function IsDefensivesEquivalent(element)
    return type(element) == "table" and (element.id == "defensives"
        or (element.filterMode == "classify"
            and type(element.classifications) == "table"
            and element.classifications.bigDefensive
            and element.classifications.externalDefensive))
end

local function IsAuraOverrideBucketKey(bucketKey)
    return type(bucketKey) == "number"
end

local function StripDedupeFromStore(store)
    local elements = type(store) == "table" and type(store.elements) == "table" and store.elements
    if not elements then return end
    for _, bucket in pairs(elements) do
        if type(bucket) == "table" then
            for _, e in ipairs(bucket) do
                if type(e) == "table" then e.dedupeDefensives = nil end
            end
        end
    end
end

function Migrations.FoldDefensiveIndicatorIntoElements(profile)
    local gf = profile.quiGroupFrames
    if type(gf) == "table" then
        for _, key in ipairs({ "party", "raid" }) do
            local surface = gf[key]
            if type(surface) == "table" then
                local healer = surface.healer
                local di = type(healer) == "table" and healer.defensiveIndicator
                local oldEnabled = type(di) == "table" and di.enabled == true

                local a = surface.auras
                local elements = type(a) == "table" and type(a.elements) == "table" and a.elements
                if elements and a.elementsSeeded then
                    local base
                    local star = elements["*"]
                    if type(star) == "table" then
                        for _, e in ipairs(star) do
                            if type(e) == "table" and e.id == "defensives" then
                                base = e
                                break
                            end
                        end
                        if not base then
                            base = BuildShippedDefensivesElement(oldEnabled)
                            star[#star + 1] = base
                        end
                    end

                    -- Override buckets replace "*" at render time, so carry
                    -- the shipped strip into every existing non-empty bucket.
                    -- An existing empty bucket is deliberate suppress-intent;
                    -- never turn it into a defensives-only bucket.
                    if base then
                        for bucketKey, bucket in pairs(elements) do
                            if IsAuraOverrideBucketKey(bucketKey)
                                and type(bucket) == "table" and #bucket > 0 then
                                local present = false
                                for _, e in ipairs(bucket) do
                                    if IsDefensivesEquivalent(e) then
                                        present = true
                                        break
                                    end
                                end
                                if not present then
                                    bucket[#bucket + 1] = CloneValue(base)
                                end
                            end
                        end
                    end
                end

                StripDedupeFromStore(a)
                if type(healer) == "table" then healer.defensiveIndicator = nil end
            end
        end
    end

    local uf = profile.quiUnitFrames
    if type(uf) == "table" then
        for _, unit in pairs(uf) do
            if type(unit) == "table" then StripDedupeFromStore(unit.auras) end
        end
    end

    local bb = profile.buffBorders
    if type(bb) == "table" then
        StripDedupeFromStore(bb.buffAuras)
        StripDedupeFromStore(bb.debuffAuras)
    end
    return true
end

---------------------------------------------------------------------------
-- v59 squash step (e): purge CDM per-container satellite settings orphaned by
-- DeleteContainer (which historically never cleaned them). A satellite is
-- orphaned when its derived container key no longer exists in
-- profile.ncdm.containers. This is its own copy of the purge logic (NOT a
-- shared call into QUI_CDM/cdm/cdm_containers.lua's PurgeContainerSatellites
-- seam) — migrations run in contexts (profile import, addon startup before
-- LOD modules load) where the CDM sub-addon may not be loaded yet. Keep the
-- customGlow suffix list in lockstep with tools/gen_new_profile_seed.lua's
-- copy. (cdm_containers.lua's PurgeContainerSatellites needs no list — it
-- prefix-matches on a known containerKey.)
---------------------------------------------------------------------------
-- Ordered longest-suffix-first: several suffixes share a tail (every
-- Pandemic*Enabled variant ends in "Enabled"), so a shorter generic suffix
-- must never be tried before the longer specific one it is a tail of, or it
-- mis-derives the container prefix (e.g. stripping bare "Enabled" from
-- "<liveKey>PandemicBuffEnabled" yields "<liveKey>PandemicBuff", which is
-- not a live container key, wrongly orphaning a LIVE key). The match loop
-- below stops at the first suffix that matches the key's tail at all
-- (break unconditionally on match, not only on delete) so this ordering is
-- load-bearing, not cosmetic.
local CDM_GLOW_SUFFIXES = {
    "PandemicDebuffEnabled", "PandemicBuffEnabled", "PandemicEnabled",
    "Thickness", "Frequency", "GlowType", "XOffset", "YOffset", "Enabled",
    "Color", "Scale", "Lines",
}

function Migrations.PurgeOrphanContainerSatellites(profile)
    local ncdm = profile.ncdm
    local live = {}
    if ncdm and type(ncdm.containers) == "table" then
        for key in pairs(ncdm.containers) do live[key] = true end
    end

    local anchors = profile.frameAnchoring
    if type(anchors) == "table" then
        local toRemove = {}
        for k in pairs(anchors) do
            if type(k) == "string" then
                local key = k:match("^cdmCustom_(.+)$")
                if key and not live[key] then toRemove[#toRemove + 1] = k end
            end
        end
        for _, k in ipairs(toRemove) do anchors[k] = nil end
    end

    local effects = profile.cooldownEffects
    if type(effects) == "table" then
        local toRemove = {}
        for k in pairs(effects) do
            if type(k) == "string" then
                local key = k:match("^hide_(.+)$")
                if key and not live[key] then toRemove[#toRemove + 1] = k end
            end
        end
        for _, k in ipairs(toRemove) do effects[k] = nil end
    end

    local glow = profile.customGlow
    if type(glow) == "table" then
        local toRemove = {}
        for k in pairs(glow) do
            if type(k) == "string" then
                for _, suffix in ipairs(CDM_GLOW_SUFFIXES) do
                    local key = k:match("^(.+)" .. suffix .. "$")
                    if key then
                        -- First matching suffix wins and stops the search
                        -- (see the ordering note on CDM_GLOW_SUFFIXES above).
                        -- Only container-shaped prefixes; never touch the
                        -- essential/utility builtin glow keys.
                        if key ~= "essential" and key ~= "utility"
                            and (key:find("^custom_") or key:find("^customBar_"))
                            and not live[key] then
                            toRemove[#toRemove + 1] = k
                        end
                        break
                    end
                end
            end
        end
        for _, k in ipairs(toRemove) do glow[k] = nil end
    end

    return true
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

-- Upstream (DrewUI) rebrands legacy QUI profile keys/tokens onto its own
-- names here. QUI's keys ARE the legacy names, so both maps are empty and
-- ApplyRebrand is a structural no-op — kept so RunOnProfile/RunOnGlobal keep
-- the same shape as upstream and future key renames have a ready seam.
local REBRANDED_PROFILE_KEYS = {}

local REBRANDED_TOKENS = {}

local PINNED_KEY_PATTERN = "^%d+:%d+:"

function Migrations.ApplyRebrand(root)
    if type(root) ~= "table" then return end

    for oldKey, newKey in pairs(REBRANDED_PROFILE_KEYS) do
        local legacy = root[oldKey]
        if legacy ~= nil then
            if root[newKey] == nil then
                root[newKey] = legacy
            end
            root[oldKey] = nil
        end
    end

    local seen = {}
    local function walk(tbl)
        if seen[tbl] then return end
        seen[tbl] = true

        local renames
        for k, v in pairs(tbl) do
            local newValue = type(v) == "string" and REBRANDED_TOKENS[v] or nil
            if newValue then tbl[k] = newValue end

            if type(k) == "string" then
                local newKey = REBRANDED_TOKENS[k]
                if not newKey and k:find(PINNED_KEY_PATTERN) and k:find("QUI", 1, true) then
                    newKey = k:gsub("QUI(%A)", "QUI%1"):gsub("QUI$", "QUI")
                end
                if newKey and newKey ~= k then
                    renames = renames or {}
                    renames[#renames + 1] = { k, newKey }
                end
            end

            if type(v) == "table" then walk(v) end
        end

        if renames then
            for _, pair in ipairs(renames) do
                local oldKey, newKey = pair[1], pair[2]
                if tbl[newKey] == nil then tbl[newKey] = tbl[oldKey] end
                tbl[oldKey] = nil
            end
        end
    end
    walk(root)
end

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

    -- v59: the complete 5.0 migration. Schema 47 is the only stable source
    -- version, so the final transform lives behind one gate with no alpha-only
    -- seed/remove or repair chain. Burned intermediate stamps also enter this
    -- gate and are handled by the helpers' existing data-shape guards.
    if stored < CURRENT_SCHEMA_VERSION then
        Migrations.ApplyRebrand(profile)

        Migrations.RestoreBuffDebuffSplit(profile)

        -- (b) private-aura feature removed; strip stored privateAuras.
        Migrations.PrunePrivateAuras(profile)

        -- (c) convert the legacy aura surfaces directly to the final unified
        -- element shape. If the model is unavailable, leave the schema stamp
        -- untouched so the full squash retries on the next pass.
        if Migrations.SeedAuraElements(profile) == false then
            return true
        end

        -- (d) fold the legacy GF defensive indicator and fan the shipped
        -- element into all non-empty override buckets in one pass.
        Migrations.FoldDefensiveIndicatorIntoElements(profile)

        -- (e) purge CDM per-container satellite settings orphaned by deletion.
        Migrations.PurgeOrphanContainerSatellites(profile)
    end

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

    if type(db.global) == "table" then
        Migrations.ApplyRebrand(db.global)
    end

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
