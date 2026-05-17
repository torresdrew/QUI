-- tests/cdm_catalog_test.lua
-- Headless verification of CDM catalog late-bound Blizzard API access.
-- Run: lua tests/cdm_catalog_test.lua

_G.issecretvalue = function()
    return false
end

_G.C_CooldownViewer = nil

local ns = {
}

local chunk = assert(loadfile("modules/cdm/cdm_catalog.lua"))
chunk("QUI", ns)

ns.CDMSources = {
    QuerySpellInfo = function(spellID)
        if spellID == 12345 then
            return { name = "Late Bound Spell", iconID = 98765 }
        elseif spellID == 67890 then
            return { name = "Unlearned CDM Spell", iconID = 87654 }
        elseif spellID == 13579 then
            return { name = "Untracked CDM Spell", iconID = 76543 }
        end
        return nil
    end,
    QueryOverrideSpell = function(spellID)
        return spellID
    end,
}

_G.C_CooldownViewer = {
    GetCooldownViewerCategorySet = function(category, allowUnlearned)
        assert(category == 0, "unexpected category")
        assert(allowUnlearned == true, "catalog should request unlearned CDM abilities")
        return { 77, 78, 79 }
    end,
    GetCooldownViewerCooldownInfo = function(cooldownID)
        if cooldownID == 77 then
            return {
                spellID = 12345,
                overrideSpellID = nil,
                overrideTooltipSpellID = nil,
                isKnown = true,
            }
        elseif cooldownID == 78 then
            return {
                spellID = 67890,
                overrideSpellID = nil,
                overrideTooltipSpellID = nil,
                isKnown = false,
            }
        elseif cooldownID == 79 then
            return {
                spellID = 13579,
                overrideSpellID = nil,
                overrideTooltipSpellID = nil,
                isKnown = true,
            }
        end
        error("unexpected cooldownID")
    end,
}

_G.CooldownViewerSettings = {
    GetDataProvider = function()
        return {
            GetOrderedCooldownIDsForCategory = function(_, category, allowUnlearned)
                assert(category == 0, "unexpected ordered category")
                assert(allowUnlearned == true, "seed should preserve tracked unlearned abilities")
                return { 77, 78 }
            end,
        }
    end,
}

local catalog = assert(ns.CDMCatalog, "CDMCatalog table was not exported")
local available = catalog.GetAvailableSpellsForContainer("essential", "cooldown", {}, {})

assert(#available == 3, "late-bound C_CooldownViewer should populate learned, unlearned, and untracked add entries")

local bySpellID = {}
for _, entry in ipairs(available) do
    bySpellID[entry.spellID] = entry
end

assert(bySpellID[12345], "learned spell missing")
assert(bySpellID[12345].name == "Late Bound Spell", "wrong learned spell name")
assert(bySpellID[12345].icon == 98765, "wrong learned spell icon")

assert(bySpellID[67890], "unlearned CDM spell missing")
assert(bySpellID[67890].name == "Unlearned CDM Spell", "wrong unlearned spell name")
assert(bySpellID[67890].icon == 87654, "wrong unlearned spell icon")
assert(bySpellID[67890].isKnown == false, "unlearned CDM spell should retain isKnown=false")

assert(bySpellID[13579], "untracked CDM spell missing from add catalog")
assert(bySpellID[13579].name == "Untracked CDM Spell", "wrong untracked spell name")
assert(bySpellID[13579].icon == 76543, "wrong untracked spell icon")

local seeded, seedReady = catalog.SeedFromBlizzard("essential")
assert(seedReady == true, "seed should report ready when the tracked provider returns a category list")
local seededSet = {}
for _, entry in ipairs(seeded) do
    seededSet[entry.id] = true
end
assert(seededSet[12345], "learned spell missing from initial snapshot seed")
assert(seededSet[67890], "unlearned CDM spell missing from initial snapshot seed")
assert(not seededSet[13579], "seed/reset should not import spells the user is not tracking in Blizzard CDM")

local cooldownMap = {}
local cooldownDirectMap = {}
catalog.MapCooldownInfoIDs(cooldownMap, cooldownDirectMap, {
    spellID = 20001,
    overrideSpellID = 20002,
    overrideTooltipSpellID = 20003,
    linkedSpellIDs = { 20004 },
}, 9001, "essential")
assert(cooldownMap[20002] == 9001, "cooldown category should map override/source IDs")
assert(cooldownMap[20001] == 9001, "cooldown category should retain source spell fallback")
assert(cooldownMap[20003] == nil, "cooldown category should not claim tooltip aura IDs")
assert(cooldownMap[20004] == nil, "cooldown category should not claim linked aura IDs")
assert(cooldownDirectMap[20002] == 9001, "cooldown direct map should use override/source IDs")
assert(cooldownDirectMap[20003] == nil, "cooldown direct map should not claim tooltip aura IDs")

local auraMap = { [30003] = 88, [30004] = 88 }
local auraDirectMap = { [30002] = 88, [30003] = 88, [30004] = 88 }
catalog.MapCooldownInfoIDs(auraMap, auraDirectMap, {
    spellID = 30001,
    overrideSpellID = 30002,
    overrideTooltipSpellID = 30003,
    linkedSpellIDs = { 30004 },
}, 9002, "buff")
assert(auraMap[30002] == 9002, "aura category should map source ability IDs")
assert(auraMap[30003] == 9002, "aura category should let tooltip aura ID win in the category map")
assert(auraMap[30004] == 88, "aura category linked aliases should not overwrite category-map owners")
assert(auraDirectMap[30003] == 9002, "aura direct map should let tooltip aura IDs win")
assert(auraDirectMap[30004] == 9002, "aura direct map should let linked aura IDs win")
assert(auraDirectMap[30002] == 88, "aura direct map should not overwrite source ability owners")

print("OK: cdm_catalog_test")
