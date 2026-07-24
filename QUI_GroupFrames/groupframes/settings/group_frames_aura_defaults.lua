local ADDON_NAME, ns = ...

local AuraDefaults = ns.QUI_GroupFramesAuraDefaults or {}
ns.QUI_GroupFramesAuraDefaults = AuraDefaults

-- The shipped default filter strips (debuffs + buffs) for the all-specs ("*")
-- bucket. Ported byte-for-byte from the old groupframes_aura_model.lua
-- The shipped default strip bucket DEFINITION lives in the always-loaded
-- model shim (groupframes_aura_model.lua) — the runtime seed path latches
-- elementsSeeded, so an Options-only definition would let an Options-disabled
-- install latch an EMPTY bucket and permanently lose the shipped strips.
-- This delegate keeps the settings-side name (editor capability wiring
-- passes AuraDefaults.DefaultStripBucket as defaultBucketFn).
function AuraDefaults.DefaultStripBucket(frameType)
    return ns.QUI_GroupFramesAuraModel.DefaultStripBucket(frameType)
end

local function SpellKey(spellID)
    local numeric = tonumber(spellID)
    if numeric then
        return "n:" .. tostring(numeric)
    end
    return "s:" .. tostring(spellID)
end

local function GetCDMAuraEntries()
    local composer = ns.CDMComposer
    if not composer or type(composer.GetAvailableSpellsForContainer) ~= "function" then
        return {}
    end
    return composer.GetAvailableSpellsForContainer("buff", "aura", {}, nil) or {}
end

local function IsKnownCDMSuggestion(entry)
    -- CDM exposes the full Blizzard catalog here; only known entries belong in
    -- this class/spec suggestion strip.
    return entry and entry.isKnown == true
end

local function BuildCDMPreset(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return nil
    end

    local spells = {}
    for _, entry in ipairs(entries) do
        local spellID = entry.spellID or entry.id
        if spellID and IsKnownCDMSuggestion(entry) then
            spells[#spells + 1] = {
                id = spellID,
                name = entry.name,
                icon = entry.icon,
                source = ns.L["Blizzard CDM"],
            }
        end
    end

    if #spells == 0 then
        return nil
    end

    return {
        name = "Blizzard Aura Suggestions",
        source = ns.L["Blizzard CDM"],
        spells = spells,
    }
end

local function DeduplicatePresets(presets)
    local deduped = {}
    local seen = {}
    for _, preset in ipairs(presets or {}) do
        local copy = {
            name = preset.name,
            specID = preset.specID,
            classFile = preset.classFile,
            source = preset.source,
            spells = {},
        }
        for _, spell in ipairs(preset.spells or {}) do
            local spellID = spell.id or spell.spellID
            if spellID then
                local key = SpellKey(spellID)
                if not seen[key] then
                    seen[key] = true
                    copy.spells[#copy.spells + 1] = spell
                end
            end
        end
        if #copy.spells > 0 then
            deduped[#deduped + 1] = copy
        end
    end
    return deduped
end

-- Suggestion presets for the tracked-auras editor and the setup wizard.
-- CDM catalog only since the healerHoTs-seed removal (2026-07-23, spec
-- docs/superpowers/specs/2026-07-23-healerhots-seed-removal-design.md):
-- the hand-curated SPEC_AURA_PRESETS table is gone — Blizzard's own
-- isKnown-filtered CDM catalog is the sole suggestion source, and users
-- build tracked elements themselves.
function AuraDefaults.GetDefaultPresets(options)
    options = options or {}
    local cdmEntries = options.cdmAuraEntries
    if cdmEntries == nil then
        cdmEntries = GetCDMAuraEntries()
    end

    local presets = {}
    local cdmPreset = BuildCDMPreset(cdmEntries)
    if cdmPreset then
        presets[#presets + 1] = cdmPreset
    end

    return DeduplicatePresets(presets)
end
