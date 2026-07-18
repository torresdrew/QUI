local ADDON_NAME, ns = ...
local C = {}; ns.QUI_EncounterCatalog = C
local ROLE_BY_FLAG = { [0]="tank", [1]="dps", [2]="healer" }  -- Blizzard flagsByRole
function C.AbilityRoleTags(iconFlags)
    local out = {}
    if type(iconFlags) == "table" then
        for _, f in ipairs(iconFlags) do local r = ROLE_BY_FLAG[f]; if r then out[r] = true end end
    end
    return out
end

-- GetSectionIconFlags returns 0-based icon INDICES, not the Enum bitmask
-- (EncounterJournal_SetFlagIcon(texture, index) converts index->flag: Tank=0,
-- Dps=1, Healer=2, ... Magic=7, Curse=8, Poison=9, Disease=10, Bleed=13). We want
-- the INDICES for abilities worth tracking as a group-frame DEBUFF: the Tank and
-- Healer role flags (where tank stacks and heal-relevant debuffs live) plus the
-- dispel/curable schools (Magic/Curse/Poison/Disease/Bleed). Deliberately
-- EXCLUDED: Dps (DPS-check mechanics, not frame debuffs), Important/Deadly (big
-- hits, not necessarily auras), Interruptible (a cast to interrupt), Enrage (a
-- boss buff), Heroic/Mythic (difficulty markers), and abilities with no flag.
-- Resolved lazily (indices are stable) so the numbers are never hardcoded:
-- prefer Blizzard's own EncounterJournal_GetIconIndexFromFlag, else derive the
-- index as the bit position of the Enum flag value. Returns nil when it can't be
-- resolved (no Enum), which makes IsDebuffAbility fail OPEN (shows everything)
-- rather than hiding all abilities.
local debuffIndexSet -- nil until resolved / unresolvable
local function ResolveDebuffIndexSet()
    if debuffIndexSet ~= nil then return debuffIndexSet end
    local Flags = Enum and Enum.JournalEncounterIconFlags
    if not Flags then return nil end
    local meta = Enum.JournalEncounterIconFlagsMeta
    local minValue = (meta and meta.MinValue) or 1
    local set, any = {}, false
    for _, k in ipairs({ "Tank", "Healer", "Magic", "Curse", "Poison", "Disease", "Bleed" }) do
        local flagValue = Flags[k]
        if flagValue then
            local index
            if type(EncounterJournal_GetIconIndexFromFlag) == "function" then
                index = EncounterJournal_GetIconIndexFromFlag(flagValue)
            end
            if index == nil and minValue > 0 and flagValue >= minValue then
                -- Flag values are powers of two from minValue; index = bit position.
                local i, v = 0, minValue
                while v < flagValue do v = v * 2; i = i + 1 end
                if v == flagValue then index = i end
            end
            if index ~= nil then set[index] = true; any = true end
        end
    end
    if any then debuffIndexSet = set end
    return debuffIndexSet
end
local function IsDebuffAbility(iconFlags)
    local set = ResolveDebuffIndexSet()
    if not set then return true end          -- can't classify -> don't filter
    if type(iconFlags) ~= "table" then return false end
    for _, f in ipairs(iconFlags) do
        if set[f] then return true end
    end
    return false
end

-- Live-client VETO: a spell the client says can be cast on friendly targets but
-- NOT on hostiles is a buff (a boss self-buff like Imperator's Glory, or an ally
-- buff), never a player debuff -- so it must never appear in this player-debuff
-- browser, even when the Journal happens to flag it or the data set lists it.
-- C_Spell.IsSpellHelpful / IsSpellHarmful are Blizzard's OWN, always-current
-- classification (SpellDocumentation: helpful = "can be cast on the player or
-- other friendly targets", harmful = "can be cast on hostile targets"; both
-- SecretArguments = AllowedWhenTainted, so safe from the Options context). Reading
-- the live client means this catches boss buffs the offline data can't know about
-- -- content NEWER than the last data regen, which no baked spellID set can cover.
local function IsHelpfulOnly(spellID)
    local Spell = C_Spell
    if not (Spell and Spell.IsSpellHelpful and Spell.IsSpellHarmful) then return false end
    local okH, helpful = pcall(Spell.IsSpellHelpful, spellID)
    if not (okH and helpful) then return false end          -- not friendly-castable -> not a pure buff
    local okD, harmful = pcall(Spell.IsSpellHarmful, spellID)
    return okD and not harmful                              -- friendly-only (never hostile) -> buff
end

-- Walk a boss's Journal section tree, collecting only DEBUFF abilities. Skips
-- difficulty-variant sections (filteredByDifficulty -- the source of the same
-- ability appearing several times) and de-duplicates by spellID (an ability can
-- also be referenced under multiple phases/sections).
local function walk(sectionID, out, seen, depth)
    if not sectionID or depth > 60 then return end
    local info = C_EncounterJournal and C_EncounterJournal.GetSectionInfo and C_EncounterJournal.GetSectionInfo(sectionID)
    if not info then return end
    if info.spellID and info.spellID > 0 and not info.filteredByDifficulty and not seen[info.spellID] then
        local id = info.spellID
        local flags = C_EncounterJournal.GetSectionIconFlags and C_EncounterJournal.GetSectionIconFlags(sectionID)
        -- VETO FIRST: a data-mined boss/ally buff (QUI_EncounterBuffSpells -- aura
        -- that only ever lands on the caster or allies) or a spell the live client
        -- classes as friendly-only is not a player debuff. This wins over BOTH the
        -- aura set and the icon-flag heuristic so e.g. Imperator's Glory (a self-
        -- buff) never shows even when the Journal flags it.
        local buffSet = ns.QUI_EncounterBuffSpells
        local vetoed = (buffSet and buffSet[id]) or IsHelpfulOnly(id)
        -- PRIMARY signal: the data-mined set of encounter ability spellIDs that
        -- apply an aura TO PLAYERS (core/encounter_aura_data.lua, generated from the
        -- client's SpellEffect DB2 -- a debuff the boss puts on you, following the
        -- spell-trigger chain and filtered by hostile ImplicitTarget so boss self-
        -- buffs/ally buffs are excluded). The icon-flag heuristic is the FALLBACK
        -- for spellIDs absent from that set (content newer than the last data
        -- regen). "Smashed"/"Void Marked" (trigger-applied) land via the set.
        local auraSet = ns.QUI_EncounterAuraSpells
        if not vetoed and ((auraSet and auraSet[id]) or IsDebuffAbility(flags)) then
            seen[id] = true
            out[#out+1] = { spellID = id, name = info.title, icon = info.abilityIcon, tags = C.AbilityRoleTags(flags) }
        end
    end
    walk(info.firstChildSectionID, out, seen, depth+1)
    walk(info.siblingSectionID, out, seen, depth+1)
end
function C.BossAbilities(encounterID)
    local out = {}
    if not (EJ_GetEncounterInfo and encounterID) then return out end
    walk(select(4, EJ_GetEncounterInfo(encounterID)), out, {}, 0)
    return out
end
-- The full raid/dungeon instance + boss lists (EJ_GetInstanceByIndex /
-- EJ_GetEncounterInfoByIndex) are only populated once the load-on-demand
-- Adventure Guide addon has run; before that the C API returns just the
-- featured/current instance -- which is why an un-opened Journal shows only the
-- current raid. Load it once (idempotent, OOC-only from Options), mirroring the
-- loader-resolution in core/locale/load_overlay.lua.
local journalLoaded = false
local function EnsureJournalLoaded()
    if journalLoaded then return end
    journalLoaded = true
    local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if loader then pcall(loader, "Blizzard_EncounterJournal") end
end

-- The Encounter Journal has a "Current Season" pseudo-tier that
-- EJ_GetCurrentTier() returns -- it lists ONLY the new season's raid, not the
-- whole expansion (so the raid picker showed just one). Resolve the CURRENT
-- EXPANSION's tier instead, via Blizzard's own expansion->tier map
-- (GetEJTierDataTableID, a global exposed once the Adventure Guide addon loads).
-- Falls back to EJ_GetCurrentTier() when that map isn't present.
local function CurrentExpansionTier()
    EnsureJournalLoaded()
    local getLevel = GetExpansionLevel or GetServerExpansionLevel
    if type(GetEJTierDataTableID) == "function" and getLevel then
        local tier = GetEJTierDataTableID(getLevel())
        if tier then
            if not EJ_GetNumTiers or tier <= EJ_GetNumTiers() then
                return tier
            end
        end
    end
    return EJ_GetCurrentTier and EJ_GetCurrentTier() or nil
end

function C.InstanceBosses(journalInstanceID)
    local out = {}
    if not (EJ_SelectInstance and EJ_GetEncounterInfoByIndex and journalInstanceID) then return out end
    EnsureJournalLoaded()
    EJ_SelectInstance(journalInstanceID)
    local i = 1
    while true do
        local name, _, bossID = EJ_GetEncounterInfoByIndex(i, journalInstanceID)
        if not name then break end
        out[#out+1] = { encounterID = bossID, name = name }
        i = i + 1
    end
    return out
end
function C.SeasonDungeons()
    local out = {}
    if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then return out end
    for _, id in ipairs(C_ChallengeMode.GetMapTable() or {}) do
        local name, _, _, _, _, mapID = C_ChallengeMode.GetMapUIInfo(id)
        if name then out[#out+1] = { mapChallengeModeID = id, name = name, mapID = mapID } end
    end
    return out
end

-- Resolves a world mapID (the same "GameMap" ID space `E.InstanceBucketKey`
-- keys on, and what `C_ChallengeMode.GetMapUIInfo` returns as `mapID`) to its
-- Encounter Journal instance, when the Journal has an entry for it. Returns
-- nil for non-instance maps or when EJ data isn't available.
function C.JournalInstanceForMap(mapID)
    if type(mapID) ~= "number" then return nil end
    if not (C_EncounterJournal and C_EncounterJournal.GetInstanceForGameMap) then return nil end
    return C_EncounterJournal.GetInstanceForGameMap(mapID)
end

-- The raid/dungeon the player is presently standing in, resolved through the
-- Journal (nil when not in an instance, or the instance has no Journal
-- entry -- e.g. a scenario/delve). mapID here is the SAME space
-- `E.InstanceBucketKey` expects (sourced from `GetBestMapForUnit`, matching
-- `core/aura_context.lua`'s runtime tracker so a bucket keyed off this value
-- resolves at zone-in).
function C.CurrentInstance()
    if not (IsInInstance and IsInInstance()) then return nil end
    local mapID = GetBestMapForUnit and GetBestMapForUnit("player")
    if not mapID then return nil end
    local journalInstanceID = C.JournalInstanceForMap(mapID)
    if not journalInstanceID then return nil end
    local name = EJ_GetInstanceInfo and EJ_GetInstanceInfo(journalInstanceID)
    if not name or name == "" then return nil end
    return { journalInstanceID = journalInstanceID, name = name, mapID = mapID }
end

-- All raids of the CURRENT EXPANSION (the whole "Midnight"-style tier, not the
-- "Current Season" pseudo-tier -- see CurrentExpansionTier). Dungeons stay
-- season-scoped via SeasonDungeons; only raids span the full expansion.
-- EJ_GetInstanceByIndex(index, isRaid=true) returns 11 values; the 11th is the
-- instance's uiMap `mapID` (tests/framexml/.../Blizzard_EncounterJournal.lua:819)
-- -- the same uiMap space E.InstanceBucketKey and the runtime aura context
-- (GetBestMapForUnit) key on. Entries without a mapID are dropped, never guessed.
-- (Raids can span multiple floor uiMaps; if GetBestMapForUnit at runtime returns a
-- child map that differs from this instance mapID, the instance bucket won't match
-- -- an in-game verification item, out of scope for this catalog reader.)
function C.ExpansionRaids()
    local out = {}
    if not (EJ_SelectTier and EJ_GetInstanceByIndex) then return out end
    local tier = CurrentExpansionTier()
    if not tier then return out end
    EJ_SelectTier(tier)
    local i = 1
    while true do
        local instanceID, name, _, _, _, _, _, _, _, _, mapID = EJ_GetInstanceByIndex(i, true)
        if not instanceID then break end
        if name and mapID then
            out[#out + 1] = { journalInstanceID = instanceID, name = name, mapID = mapID }
        end
        i = i + 1
    end
    return out
end

return C
