-- tests/unit/migration_floor_collapse_test.lua
-- Run: lua5.1 tests/unit/migration_floor_collapse_test.lua
-- Verifies the 47-floor + linear-gate collapse:
--   - stored < 47 → floored (wiped, _needsStarterReseed, stamped CURRENT=49)
--   - stored == 47 → NOT floored; gates run RestoreBuffDebuffSplit + PrunePrivateAuras, stamped 49
--   - stored == 49 → no-op (already current)
local ns = dofile("tools/_addon_env.lua").LoadCore()
local M = ns.Migrations

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

-- 1) Below-floor profile is wiped + flagged for starter reseed.
do
    local profile = { _schemaVersion = 46, buffBorders = { buffIconSize = 99 }, someModule = { foo = true } }
    M.RunOnProfile(profile)
    check("below-floor (46) wiped: user data gone", profile.someModule == nil, tostring(profile.someModule))
    check("below-floor (46) flagged _needsStarterReseed", profile._needsStarterReseed == true, tostring(profile._needsStarterReseed))
    check("below-floor (46) stamped to CURRENT (49)", profile._schemaVersion == 49, tostring(profile._schemaVersion))
end

-- 2) At-floor profile (47) is NOT floored; gates run RestoreBuffDebuffSplit + PrunePrivateAuras.
do
    local profile = { _schemaVersion = 47, buffBorders = { buffIconSize = 35 }, frameAnchoring = { buffFrame = { parent = "minimap" } } }
    M.RunOnProfile(profile)
    check("at-floor (47) NOT wiped: buffIconSize survives", profile.buffBorders and profile.buffBorders.buffIconSize == 35, tostring(profile.buffBorders and profile.buffBorders.buffIconSize))
    check("at-floor (47) NOT flagged for reseed", profile._needsStarterReseed == nil, tostring(profile._needsStarterReseed))
    check("at-floor (47) debuffFrame restored", profile.frameAnchoring.debuffFrame ~= nil, "debuffFrame nil")
    check("at-floor (47) stamped to 49", profile._schemaVersion == 49, tostring(profile._schemaVersion))
end

-- 2b) v49 PrunePrivateAuras: seeded privateAuras subtables are stripped from
-- every tree the removed defaults carried them in; sibling keys survive.
do
    local profile = {
        _schemaVersion = 48,
        quiUnitFrames = {
            player = { privateAuras = { enabled = true, iconSize = 24 }, portrait = { enabled = true } },
            target = { privateAuras = { enabled = false } },
            focus  = { privateAuras = { maxPerFrame = 3 } },
        },
        quiGroupFrames = {
            party = { privateAuras = { enabled = true }, frames = { width = 90 } },
            raid  = { privateAuras = { growDirection = "RIGHT" } },
        },
    }
    M.RunOnProfile(profile)
    check("v49 prunes quiUnitFrames.player.privateAuras", profile.quiUnitFrames.player.privateAuras == nil,
        tostring(profile.quiUnitFrames.player.privateAuras))
    check("v49 prunes quiUnitFrames.target.privateAuras", profile.quiUnitFrames.target.privateAuras == nil,
        tostring(profile.quiUnitFrames.target.privateAuras))
    check("v49 prunes quiUnitFrames.focus.privateAuras", profile.quiUnitFrames.focus.privateAuras == nil,
        tostring(profile.quiUnitFrames.focus.privateAuras))
    check("v49 prunes quiGroupFrames.party.privateAuras", profile.quiGroupFrames.party.privateAuras == nil,
        tostring(profile.quiGroupFrames.party.privateAuras))
    check("v49 prunes quiGroupFrames.raid.privateAuras", profile.quiGroupFrames.raid.privateAuras == nil,
        tostring(profile.quiGroupFrames.raid.privateAuras))
    check("v49 prune preserves sibling unit settings", profile.quiUnitFrames.player.portrait
        and profile.quiUnitFrames.player.portrait.enabled == true, "portrait clobbered")
    check("v49 prune preserves sibling group settings", profile.quiGroupFrames.party.frames
        and profile.quiGroupFrames.party.frames.width == 90, "frames clobbered")
    check("v49 prune stamps to 49", profile._schemaVersion == 49, tostring(profile._schemaVersion))
end

-- 3) Already-current profile (49) is a no-op.
do
    local profile = { _schemaVersion = 49, buffBorders = { buffIconSize = 35, debuffIconSize = 12 } }
    M.RunOnProfile(profile)
    check("current (49) untouched: custom debuffIconSize preserved", profile.buffBorders.debuffIconSize == 12, tostring(profile.buffBorders.debuffIconSize))
    check("current (49) stays at 49", profile._schemaVersion == 49, tostring(profile._schemaVersion))
end

print("migration_floor_collapse_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
