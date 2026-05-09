# empty_composer

Fresh profile with all built-in CDM containers present but `ownedSpells = {}`.
Verifies that migrations and AceDB defaults round-trip cleanly on an empty
composer state, without crashing or stamping unexpected fields.

The Blizzard seed path (`ns.CDMComposer.SeedFromBlizzard`) requires
`C_CooldownViewer.*` which is unavailable in the headless harness. The
seed runs in-game on first profile load; this fixture only validates the
round-trip of the *post-seed-or-pre-seed-equivalent* shape (i.e., empty
containers must round-trip without error).

If a future migration changes `ncdm` defaults or adds a new field,
re-snapshot via:

    lua tools/test_profiles.lua --update --only edge/empty_composer

and inspect the diff before committing.
