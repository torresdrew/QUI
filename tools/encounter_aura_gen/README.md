# Encounter aura-spell data generator

Regenerates `core/encounter_aura_data.lua` — the set of Encounter-Journal boss
ability spellIDs that apply an aura (debuff/buff). Used by the Auras > Encounters
browser to filter each boss's ability list down to trackable auras (the
icon-flag heuristic in `core/encounter_catalog.lua` is the fallback for spellIDs
absent from this set — e.g. content newer than the last regen).

## Source
WoW client DB2 tables, fetched **online** from Blizzard's CDN via
`@rhyster/wow-casc-dbc` (no local WoW install needed; the journal DB2 is often
not downloaded in a local install):
- `JournalEncounterSection.db2` (FDID 1134413) → every encounter ability spellID
- `SpellEffect.db2` (FDID 1140088) → a spell "applies an aura" if any effect row
  has an APPLY_AURA / area-aura Effect (6/27/35/65/119/128/129/143/224)

## Regenerate (per patch)
```
cd tools/encounter_aura_gen
npm install            # once: pulls @rhyster/wow-casc-dbc
PRODUCT=wow node gen_encounter_aura_data.mjs ../../core/encounter_aura_data.lua
```
`PRODUCT=wow` = live retail; use `wowt` for PTR. Requires network to
`*.patch.battle.net` + `*.cdn.blizzard.com`.
