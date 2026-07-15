-- tests/unit/encounter_catalog_test.lua
-- Run: lua5.1 tests/unit/encounter_catalog_test.lua
--
-- Pure flag-mapping test for ns.QUI_EncounterCatalog.AbilityRoleTags.
-- Blizzard EJ_GetSectionIconFlags returns an array of role-flag ints
-- (0=tank, 1=dps, 2=healer, per flagsByRole); AbilityRoleTags maps that
-- array into a {tank=?, dps=?, healer=?} set. The rest of the module
-- (BossAbilities/InstanceBosses/SeasonDungeons) walks live EJ/C_ChallengeMode
-- state and is not unit-tested here.

-- Stub the icon-flag enum BEFORE loading the module: encounter_catalog builds
-- its debuff-flag set from Enum.JournalEncounterIconFlags at load time, so it
-- must exist first for the BossAbilities filter test below to exercise filtering
-- (without it the filter fails open). Values mirror the real bitmask enum.
_G.Enum = _G.Enum or {}
_G.Enum.JournalEncounterIconFlags = {
    Tank = 1, Dps = 2, Healer = 4, Heroic = 8, Deadly = 16, Important = 32,
    Interruptible = 64, Magic = 128, Curse = 256, Poison = 512, Disease = 1024,
    Enrage = 2048, Mythic = 4096, Bleed = 8192,
}

local ns = dofile("tools/_addon_env.lua").LoadCore()
local EC = ns.QUI_EncounterCatalog

local failures = 0
local function check(n, ok, d)
    if ok then print("  ok  " .. n)
    else failures = failures + 1; print("FAIL  " .. n .. " " .. (d or "")) end
end

check("EncounterCatalog loaded", type(EC) == "table")
check("AbilityRoleTags is function", type(EC.AbilityRoleTags) == "function")

do
    local tags = EC.AbilityRoleTags({0})
    check("{0} -> tank", tags.tank == true)
    check("{0} -> no dps", tags.dps == nil)
    check("{0} -> no healer", tags.healer == nil)
end

do
    local tags = EC.AbilityRoleTags({1})
    check("{1} -> dps", tags.dps == true)
    check("{1} -> no tank", tags.tank == nil)
    check("{1} -> no healer", tags.healer == nil)
end

do
    local tags = EC.AbilityRoleTags({2})
    check("{2} -> healer", tags.healer == true)
    check("{2} -> no tank", tags.tank == nil)
    check("{2} -> no dps", tags.dps == nil)
end

do
    local tags = EC.AbilityRoleTags({0, 2})
    check("{0,2} -> tank", tags.tank == true)
    check("{0,2} -> healer", tags.healer == true)
    check("{0,2} -> no dps", tags.dps == nil)
end

do
    local tags = EC.AbilityRoleTags({})
    check("{} -> empty", next(tags) == nil)
end

do
    local tags = EC.AbilityRoleTags(nil)
    check("nil -> empty", type(tags) == "table" and next(tags) == nil)
end

do -- ExpansionRaids: stub EJ_* globals, assert mapping (mapID = 11th return)
    local savedTier, savedCur, savedIdx = EJ_SelectTier, EJ_GetCurrentTier, EJ_GetInstanceByIndex
    _G.EJ_GetCurrentTier = function() return 5 end
    _G.EJ_SelectTier = function(_) end
    local fake = {
        [1] = { id = 1001, name = "Manaforge Omega", mapID = 2810 },
        [2] = { id = 1002, name = "Nerub-ar Palace", mapID = 2657 },
        [3] = { id = 1003, name = "No Map Raid",     mapID = nil  }, -- dropped
    }
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        local f = isRaid and fake[index]
        if not f then return nil end
        return f.id, f.name, nil, nil, nil, nil, nil, nil, nil, nil, f.mapID
    end

    local raids = EC.ExpansionRaids()
    check("ExpansionRaids is function", type(EC.ExpansionRaids) == "function")
    check("ExpansionRaids drops mapless (2 of 3)", #raids == 2, tostring(#raids))
    check("raid1 name", raids[1].name == "Manaforge Omega")
    check("raid1 mapID", raids[1].mapID == 2810)
    check("raid1 journalInstanceID", raids[1].journalInstanceID == 1001)
    check("raid2 mapID", raids[2].mapID == 2657)

    _G.EJ_SelectTier, _G.EJ_GetCurrentTier, _G.EJ_GetInstanceByIndex = savedTier, savedCur, savedIdx
end

do -- ExpansionRaids picks the EXPANSION tier, not the "Current Season" pseudo-tier
    local sv = { EJ_SelectTier, EJ_GetCurrentTier, EJ_GetInstanceByIndex, EJ_GetNumTiers, GetEJTierDataTableID, GetExpansionLevel }
    local selectedTier
    _G.GetExpansionLevel = function() return 11 end          -- current expansion enum
    _G.GetEJTierDataTableID = function(x) return x + 1 end    -- 11 -> tier 12 (the expansion)
    _G.EJ_GetNumTiers = function() return 13 end             -- a trailing "Current Season" tier exists
    _G.EJ_GetCurrentTier = function() return 13 end          -- season tier -- must NOT be used
    _G.EJ_SelectTier = function(t) selectedTier = t end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if not isRaid or selectedTier ~= 12 then return nil end -- only the expansion tier lists raids
        local fake = { [1] = { 1, "Voidspire", 4001 }, [2] = { 2, "Dreamrift", 4002 }, [3] = { 3, "March of Ages", 4003 } }
        local f = fake[index]; if not f then return nil end
        return f[1], f[2], nil, nil, nil, nil, nil, nil, nil, nil, f[3]
    end

    local raids = EC.ExpansionRaids()
    check("selects expansion tier, not season", selectedTier == 12, tostring(selectedTier))
    check("lists all expansion raids (3)", #raids == 3, tostring(#raids))
    check("expansion raid name", raids[1].name == "Voidspire")

    _G.EJ_SelectTier, _G.EJ_GetCurrentTier, _G.EJ_GetInstanceByIndex, _G.EJ_GetNumTiers, _G.GetEJTierDataTableID, _G.GetExpansionLevel = sv[1], sv[2], sv[3], sv[4], sv[5], sv[6]
end

do -- BossAbilities: debuff-only filter + dedup by spellID + skip filteredByDifficulty
    local svEnc, svCEJ = EJ_GetEncounterInfo, C_EncounterJournal
    local M = _G.Enum.JournalEncounterIconFlags
    -- GetSectionIconFlags returns 0-based INDICES (index = bit position of the
    -- enum flag value), not the bitmask itself -- mirror that here.
    local function flagIdx(v) local i, x = 0, 1; while x < v do x = x * 2; i = i + 1 end; return i end
    local sections = {
        [1] = { spellID = 0,   title = "root",       firstChildSectionID = 2 },
        [2] = { spellID = 100, title = "Smashed",    abilityIcon = 1, siblingSectionID = 3, flags = { flagIdx(M.Tank) } },          -- role-flagged tank debuff -> included
        [3] = { spellID = 200, title = "Cast",       abilityIcon = 2, siblingSectionID = 4, flags = { flagIdx(M.Interruptible) } }, -- interrupt-only -> excluded
        [4] = { spellID = 100, title = "Smashed",    abilityIcon = 1, siblingSectionID = 5, flags = { flagIdx(M.Tank) } },          -- duplicate of 100 -> deduped
        [5] = { spellID = 300, title = "OtherDiff",  abilityIcon = 3, siblingSectionID = 6, flags = { flagIdx(M.Magic) }, filteredByDifficulty = true }, -- skipped
        [6] = { spellID = 400, title = "Hex",        abilityIcon = 4, siblingSectionID = 7, flags = { flagIdx(M.Curse) } },
        [7] = { spellID = 500, title = "Trash",      abilityIcon = 5, siblingSectionID = 8, flags = {} },                            -- no flag -> excluded
        [8] = { spellID = 600, title = "Burn",       abilityIcon = 6, flags = { flagIdx(M.Dps) } },                                  -- DPS-check role flag -> excluded
    }
    _G.EJ_GetEncounterInfo = function() return nil, nil, nil, 1 end
    _G.C_EncounterJournal = {
        GetSectionInfo = function(id) return sections[id] end,
        GetSectionIconFlags = function(id) return sections[id] and sections[id].flags end,
    }

    local abilities = EC.BossAbilities(1234)
    local ids = {}
    for _, a in ipairs(abilities) do ids[a.spellID] = (ids[a.spellID] or 0) + 1 end
    check("BossAbilities: tracked debuffs only, deduped (2)", #abilities == 2, tostring(#abilities))
    check("includes role-flagged tank debuff 100 (once)", ids[100] == 1)
    check("includes Curse debuff 400", ids[400] == 1)
    check("excludes interrupt-only ability 200", ids[200] == nil)
    check("excludes flagless ability 500", ids[500] == nil)
    check("excludes DPS-flagged ability 600", ids[600] == nil)
    check("skips filteredByDifficulty 300", ids[300] == nil)

    _G.EJ_GetEncounterInfo, _G.C_EncounterJournal = svEnc, svCEJ
end

do -- data-mined aura set is the PRIMARY signal: a flagless known-aura is included
    local saved = ns.QUI_EncounterAuraSpells
    ns.QUI_EncounterAuraSpells = { [900] = true }
    local svEnc, svCEJ = EJ_GetEncounterInfo, C_EncounterJournal
    local sections = {
        [1] = { spellID = 0,   title = "root", firstChildSectionID = 2 },
        [2] = { spellID = 900, title = "Curse", abilityIcon = 1, siblingSectionID = 3, flags = {} }, -- no flag, but in aura set -> included
        [3] = { spellID = 901, title = "Slam",  abilityIcon = 2, flags = {} },                       -- no flag, not in set -> excluded
    }
    _G.EJ_GetEncounterInfo = function() return nil, nil, nil, 1 end
    _G.C_EncounterJournal = {
        GetSectionInfo = function(id) return sections[id] end,
        GetSectionIconFlags = function(id) return sections[id] and sections[id].flags end,
    }
    local ab = EC.BossAbilities(1)
    local ids = {}
    for _, a in ipairs(ab) do ids[a.spellID] = true end
    check("aura-set includes flagless known aura 900", ids[900] == true)
    check("flagless non-aura 901 excluded", ids[901] == nil)
    _G.EJ_GetEncounterInfo, _G.C_EncounterJournal = svEnc, svCEJ
    ns.QUI_EncounterAuraSpells = saved
end

do -- VETO: data-mined boss buffs and live-client friendly-only spells never show
    local savedAura, savedBuff = ns.QUI_EncounterAuraSpells, ns.QUI_EncounterBuffSpells
    local svEnc, svCEJ, svSpell = EJ_GetEncounterInfo, C_EncounterJournal, C_Spell
    local M = _G.Enum.JournalEncounterIconFlags
    local function flagIdx(v) local i, x = 0, 1; while x < v do x = x * 2; i = i + 1 end; return i end
    ns.QUI_EncounterAuraSpells = { [910] = true, [912] = true } -- 910 harmful debuff, 912 self-buff
    ns.QUI_EncounterBuffSpells = { [911] = true }               -- data-mined boss/ally buff
    local sections = {
        [1] = { spellID = 0,   title = "root",   firstChildSectionID = 2 },
        [2] = { spellID = 910, title = "Debuff", abilityIcon = 1, siblingSectionID = 3, flags = { flagIdx(M.Magic) } }, -- aura set + harmful -> shown
        [3] = { spellID = 911, title = "Buff",   abilityIcon = 2, siblingSectionID = 4, flags = { flagIdx(M.Tank) } },  -- Tank-flagged BUT in buff set -> vetoed
        [4] = { spellID = 912, title = "Glory",  abilityIcon = 3, flags = { flagIdx(M.Magic) } },                       -- aura set + Magic BUT helpful-only -> vetoed
    }
    _G.EJ_GetEncounterInfo = function() return nil, nil, nil, 1 end
    _G.C_EncounterJournal = {
        GetSectionInfo = function(id) return sections[id] end,
        GetSectionIconFlags = function(id) return sections[id] and sections[id].flags end,
    }
    -- Live client: only 912 is friendly-castable-and-not-hostile (a self-buff).
    _G.C_Spell = {
        IsSpellHelpful = function(id) return id == 912 end,
        IsSpellHarmful = function(id) return id ~= 912 end,
    }
    local ab = EC.BossAbilities(1)
    local ids = {}
    for _, a in ipairs(ab) do ids[a.spellID] = true end
    check("harmful debuff in aura set shown (910)", ids[910] == true)
    check("data-mined buff vetoed despite Tank flag (911)", ids[911] == nil)
    check("friendly-only self-buff vetoed despite aura set (912)", ids[912] == nil)
    _G.EJ_GetEncounterInfo, _G.C_EncounterJournal, _G.C_Spell = svEnc, svCEJ, svSpell
    ns.QUI_EncounterAuraSpells, ns.QUI_EncounterBuffSpells = savedAura, savedBuff
end

print("encounter_catalog_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
