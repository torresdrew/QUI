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
        end
        return nil
    end,
    QueryOverrideSpell = function(spellID)
        return spellID
    end,
}

_G.C_CooldownViewer = {
    GetCooldownViewerCategorySet = function(category, includeHidden)
        assert(category == 0, "unexpected category")
        assert(includeHidden == false, "includeHidden should be false for add-list catalog")
        return { 77 }
    end,
    GetCooldownViewerCooldownInfo = function(cooldownID)
        assert(cooldownID == 77, "unexpected cooldownID")
        return {
            spellID = 12345,
            overrideSpellID = nil,
            overrideTooltipSpellID = nil,
            isKnown = true,
        }
    end,
}

local catalog = assert(ns.CDMCatalog, "CDMCatalog table was not exported")
local available = catalog.GetAvailableSpellsForContainer("essential", "cooldown", {}, {})

assert(#available == 1, "late-bound C_CooldownViewer should populate add entries")
assert(available[1].spellID == 12345, "wrong spellID")
assert(available[1].name == "Late Bound Spell", "wrong spell name")
assert(available[1].icon == 98765, "wrong spell icon")

print("OK: cdm_catalog_test")
