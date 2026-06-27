-- tests/unit/migration_v48_unify_buffdebuff_test.lua
-- Run: lua5.1 tests/unit/migration_v48_unify_buffdebuff_test.lua
-- Verifies the v48 migration restores the separate debuff grid keys +
-- debuffFrame anchor after unified model.
local ns = dofile("tools/_addon_env.lua").LoadCore()
local M = ns.Migrations

local profile = {
    _schemaVersion = 47,
    buffBorders = { buffIconSize = 35 },
    frameAnchoring = {
        buffFrame   = { parent = "minimap" },
        someChild   = { parent = "buffFrame" },
    },
}

M.RunOnProfile(profile)

assert(profile.buffBorders.buffIconSize == 35, "buffIconSize must survive")
assert(profile.buffBorders.debuffIconSize == 35, "missing debuffIconSize must be restored from buffIconSize")
assert(profile.buffBorders.debuffIconsPerRow == 10, "missing debuffIconsPerRow must be restored")
assert(profile.buffBorders.debuffIconSpacing == 0, "missing debuffIconSpacing must be restored")
assert(profile.buffBorders.debuffGrowLeft == true, "missing debuffGrowLeft must default to stock QUI orientation")
assert(profile.buffBorders.debuffGrowUp == false, "missing debuffGrowUp must default to stock QUI orientation")
assert(profile.frameAnchoring.debuffFrame ~= nil, "debuffFrame anchor must be restored")
assert(profile.frameAnchoring.debuffFrame.parent == "buffFrame", "debuffFrame should default below/relative to buffFrame")
assert(profile.frameAnchoring.someChild.parent == "buffFrame", "existing dependents must be preserved")
print("migration_v48_restore_buffdebuff_split_test: OK")
