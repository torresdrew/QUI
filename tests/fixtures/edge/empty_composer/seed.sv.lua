-- Empty-composer profile: all built-in CDM containers present with
-- ownedSpells = {} (post-seed-equivalent shape).
--
-- The live Blizzard seed path (ns.CDMComposer.SeedFromBlizzard) requires
-- C_CooldownViewer.* and runs in-game on first profile load. The headless
-- harness can't drive that; instead this fixture pins the round-trip of
-- the *empty-but-valid* shape that the seed produces (or that a user with
-- no CDM spells would observe).
--
-- Verifies: migrations + AceDB defaults round-trip cleanly without
-- crashing or stamping unexpected fields onto an otherwise-empty profile.
QUI_DB = {
    profileKeys = {
        ["TestChar - TestRealm"] = "Default",
    },
    profiles = {
        Default = {
            ncdm = {
                essential  = { ownedSpells = {}, containerType = "cooldown" },
                utility    = { ownedSpells = {}, containerType = "cooldown" },
                buff       = { ownedSpells = {}, containerType = "aura"     },
                trackedBar = { ownedSpells = {}, containerType = "auraBar"  },
                containers = {
                    essential  = { ownedSpells = {}, containerType = "cooldown", builtIn = true, name = "Essential" },
                    utility    = { ownedSpells = {}, containerType = "cooldown", builtIn = true, name = "Utility"   },
                    buff       = { ownedSpells = {}, containerType = "aura",     builtIn = true, name = "Buff"      },
                    trackedBar = { ownedSpells = {}, containerType = "auraBar",  builtIn = true, name = "BuffBar"   },
                },
            },
        },
    },
}
QUIDB = {}
