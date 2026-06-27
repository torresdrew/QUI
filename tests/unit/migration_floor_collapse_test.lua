-- tests/unit/migration_floor_collapse_test.lua
-- Run: lua5.1 tests/unit/migration_floor_collapse_test.lua
-- Verifies the 47-floor + single-gate collapse:
--   - stored < 47 → floored (wiped, _needsStarterReseed, stamped CURRENT=48)
--   - stored == 47 → NOT floored; single gate runs RestoreBuffDebuffSplit, stamped 48
--   - stored == 48 → no-op (already current)
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
    check("below-floor (46) stamped to CURRENT (48)", profile._schemaVersion == 48, tostring(profile._schemaVersion))
end

-- 2) At-floor profile (47) is NOT floored; single gate runs RestoreBuffDebuffSplit.
do
    local profile = { _schemaVersion = 47, buffBorders = { buffIconSize = 35 }, frameAnchoring = { buffFrame = { parent = "minimap" } } }
    M.RunOnProfile(profile)
    check("at-floor (47) NOT wiped: buffIconSize survives", profile.buffBorders and profile.buffBorders.buffIconSize == 35, tostring(profile.buffBorders and profile.buffBorders.buffIconSize))
    check("at-floor (47) NOT flagged for reseed", profile._needsStarterReseed == nil, tostring(profile._needsStarterReseed))
    check("at-floor (47) debuffFrame restored", profile.frameAnchoring.debuffFrame ~= nil, "debuffFrame nil")
    check("at-floor (47) stamped to 48", profile._schemaVersion == 48, tostring(profile._schemaVersion))
end

-- 3) Already-current profile (48) is a no-op.
do
    local profile = { _schemaVersion = 48, buffBorders = { buffIconSize = 35, debuffIconSize = 12 } }
    M.RunOnProfile(profile)
    check("current (48) untouched: custom debuffIconSize preserved", profile.buffBorders.debuffIconSize == 12, tostring(profile.buffBorders.debuffIconSize))
    check("current (48) stays at 48", profile._schemaVersion == 48, tostring(profile._schemaVersion))
end

print("migration_floor_collapse_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
