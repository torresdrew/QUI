-- tests/unit/migration_v56_boss_strip_repair_test.lua
-- Run: lua5.1 tests/unit/migration_v56_boss_strip_repair_test.lua
--
-- v56 (55 burned) = Migrations.RepairSpecBucketBossStrips: pre-fix
-- EnableSpecOverride re-keyed the fixed-id "encounterBoss" strip when
-- cloning "*" into an override bucket (dev-build exposure only). Repair,
-- matched by exact structural equality (ignoring id/enabled) against "*"'s
-- boss strip:
--   * bucket lacks the fixed id -> promote the equal orphan TO the fixed id
--   * bucket already has the fixed id -> remove equal orphans (duplicates)
--     regardless of enabled — the page-owned fixed strip is authoritative
--   * diverged orphans (user-edited) are untouched — user data
--   * gate flags alone must NOT match (editor exposes them on user strips)

local ns = dofile("tools/_addon_env.lua").LoadCore()
local M  = ns.Migrations

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

local function bossStrip(id, enabled)
    return {
        id = id, enabled = enabled ~= false, mode = "filterStrip", auraType = "HARMFUL",
        anchor = "TOPLEFT", growDirection = "RIGHT", spacing = 2,
        offsetX = 0, offsetY = 0, iconSize = 15, maxIcons = 4,
        gateBossAura = true,
        duration = { show = true, fontSize = 9, color = { 1, 1, 1, 1 } },
        whitelist = {}, blacklist = {},
    }
end

-- (1) orphan adoption: equal clone (different id + enabled) gets the fixed id
do
    local profile = { quiGroupFrames = { party = { auras = { elements = {
        ["*"] = { bossStrip("encounterBoss") },
        [268] = { bossStrip("e5", false) },
    } } } } }
    M.RepairSpecBucketBossStrips(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements[268]
    check("adopt: orphan re-identified", bucket[1].id == "encounterBoss", tostring(bucket[1].id))
    check("adopt: enabled state preserved", bucket[1].enabled == false)
    check("adopt: bucket size unchanged", #bucket == 1, tostring(#bucket))
    check("adopt: '*' untouched",
        profile.quiGroupFrames.party.auras.elements["*"][1].id == "encounterBoss")
end

-- (2) duplicate removal: fixed strip present (diverged mode) + equal orphan,
-- both enabled -> orphan removed
do
    local fixed = bossStrip("encounterBoss")
    fixed.gateBossAura = nil
    fixed.gateBossOrRoleAura = true -- user switched mode after the duplicate spawned
    local profile = { quiGroupFrames = { raid = { auras = { elements = {
        ["*"] = { bossStrip("encounterBoss") },
        [65] = { bossStrip("e9"), fixed },
    } } } } }
    M.RepairSpecBucketBossStrips(profile)
    local bucket = profile.quiGroupFrames.raid.auras.elements[65]
    check("dedup: orphan removed", #bucket == 1, tostring(#bucket))
    check("dedup: diverged fixed strip kept",
        bucket[1].id == "encounterBoss" and bucket[1].gateBossOrRoleAura == true)
end

-- (2b) enabled mismatch: enabled orphan beside DISABLED fixed strip is the
-- bug itself (page says Off, orphan keeps rendering, no UI can remove it) —
-- orphan removed, fixed strip's enabled is authoritative (the v55 first cut
-- kept both; that's why 55 is burned)
do
    local fixed = bossStrip("encounterBoss", false)
    local profile = { quiGroupFrames = { raid = { auras = { elements = {
        ["*"] = { bossStrip("encounterBoss") },
        [66] = { bossStrip("e9"), fixed },
    } } } } }
    M.RepairSpecBucketBossStrips(profile)
    local bucket = profile.quiGroupFrames.raid.auras.elements[66]
    check("enabled mismatch: orphan removed", #bucket == 1, tostring(#bucket))
    check("enabled mismatch: fixed strip kept disabled",
        bucket[1].id == "encounterBoss" and bucket[1].enabled == false)
end

-- (3) diverged orphan untouched (user edited the clone = user data)
do
    local diverged = bossStrip("e7")
    diverged.iconSize = 22
    local profile = { quiGroupFrames = { party = { auras = { elements = {
        ["*"] = { bossStrip("encounterBoss") },
        [102] = { diverged },
    } } } } }
    M.RepairSpecBucketBossStrips(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements[102]
    check("diverged: id untouched", bucket[1].id == "e7", tostring(bucket[1].id))
end

-- (4) gate flags alone must not match: a user strip sharing flags but not
-- structure survives, even when the bucket lacks the fixed id
do
    local userStrip = {
        id = "e12", enabled = true, mode = "filterStrip", auraType = "HARMFUL",
        anchor = "BOTTOMLEFT", iconSize = 20, gateBossAura = true,
        whitelist = {}, blacklist = {},
    }
    local profile = { quiGroupFrames = { party = { auras = { elements = {
        ["*"] = { bossStrip("encounterBoss") },
        [268] = { userStrip },
    } } } } }
    M.RepairSpecBucketBossStrips(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements[268]
    check("flags-only: user strip untouched", bucket[1].id == "e12", tostring(bucket[1].id))
end

-- (5) no "*" boss strip -> whole store untouched; absent stores tolerated
do
    local profile = { quiGroupFrames = { party = { auras = { elements = {
        ["*"] = { bossStrip("e1") }, -- no fixed-id strip at all
        [268] = { bossStrip("e2") },
    } } } }, quiUnitFrames = { player = {} }, buffBorders = {} }
    M.RepairSpecBucketBossStrips(profile)
    check("no base: spec bucket untouched",
        profile.quiGroupFrames.party.auras.elements[268][1].id == "e2")
end

-- (6) scope is GF party/raid NUMERIC buckets only (2026-07 round-3 review):
-- unit-frame stores and string context buckets ("e"/"i") are untouched —
-- nothing looks those up by id, and a data-rewriting migration stays minimal
do
    local profile = {
        quiGroupFrames = { party = { auras = { elements = {
            ["*"] = { bossStrip("encounterBoss") },
            ["e123"] = { bossStrip("e4") },
            ["i506"] = { bossStrip("e6") },
        } } } },
        quiUnitFrames = { player = { auras = { elements = {
            ["*"] = { bossStrip("encounterBoss") },
            [63] = { bossStrip("e5") },
        } } } },
    }
    M.RepairSpecBucketBossStrips(profile)
    check("string encounter bucket untouched",
        profile.quiGroupFrames.party.auras.elements["e123"][1].id == "e4")
    check("string instance bucket untouched",
        profile.quiGroupFrames.party.auras.elements["i506"][1].id == "e6")
    check("UF store untouched",
        profile.quiUnitFrames.player.auras.elements[63][1].id == "e5")
end

print("migration_v56_boss_strip_repair_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
