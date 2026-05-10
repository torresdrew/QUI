-- tests/cdm_index_test.lua
-- Headless verification of CDM index late-bound Blizzard API access.
-- Run: lua tests/cdm_index_test.lua

_G.wipe = function(tbl)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
end

_G.issecretvalue = function()
    return false
end

_G.Enum = {
    CooldownViewerCategory = {
        TrackedBuff = 2,
        TrackedBar = 3,
        Essential = 0,
        Utility = 1,
        HiddenSpell = 4,
        HiddenAura = 5,
    },
}

_G.C_CooldownViewer = nil
_G.CreateFrame = function()
    return {
        RegisterEvent = function() end,
        SetScript = function() end,
    }
end
_G.EventRegistry = {
    RegisterCallback = function() end,
}

local ns = {}

local chunk = assert(loadfile("modules/cdm/cdm_index.lua"))
chunk("QUI", ns)

ns.CDMSources = {
    QueryBaseSpell = function(spellID)
        if spellID == 12346 then
            return 12345
        end
        return spellID
    end,
}

_G.C_CooldownViewer = {
    GetCooldownViewerCategorySet = function(category, includeHidden)
        assert(includeHidden == true, "index should request hidden entries")
        if category == 0 then
            return { 88 }
        end
        return {}
    end,
    GetCooldownViewerCooldownInfo = function(cooldownID)
        assert(cooldownID == 88, "unexpected cooldownID")
        return {
            spellID = 12345,
            overrideSpellID = 12346,
            overrideTooltipSpellID = nil,
            linkedSpellIDs = { 12347 },
        }
    end,
}

local index = assert(ns.CDMIndex, "CDMIndex table was not exported")
index.Rebuild()

local entry = index.Get(12346)
assert(entry, "late-bound C_CooldownViewer should populate index aliases")
assert(entry.cooldownID == 88, "wrong cooldownID")
assert(entry.primarySpellID == 12345, "late-bound CDMSources should normalize primary spellID")
assert(index.Get(12347) == entry, "linked aliases should share the same index entry")

print("OK: cdm_index_test")
