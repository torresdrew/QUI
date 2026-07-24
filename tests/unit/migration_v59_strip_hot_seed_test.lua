-- tests/unit/migration_v59_strip_hot_seed_test.lua
-- Run: lua5.1 tests/unit/migration_v59_strip_hot_seed_test.lua
--
-- v59: StripHealerHoTSeeds — the healerHoTs default seed is REMOVED as a
-- product decision (2026-07-23, spec
-- docs/superpowers/specs/2026-07-23-healerhots-seed-removal-design.md).
-- v59 sweeps every _quiHoTSeed-flagged element from EVERY bucket shape
-- ("*", numeric spec, "i".."/e".. context) on party+raid, UNCONDITIONALLY —
-- unlike the kept v58 step (j) repair, whose #bucket==1 sole-seed guard
-- preserves flagged elements sitting alongside curated content. Buckets
-- left empty stay in place. User-customized elements that still carry the
-- flag are removed too (owner-accepted loss).

local envmod = dofile("tools/_addon_env.lua")
local ns = envmod.LoadCore()
local M = ns.Migrations

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

local function arrayCount(bucket)
    local n = 0
    for _ in ipairs(bucket or {}) do n = n + 1 end
    return n
end

local function findHoTSeed(bucket)
    for _, e in ipairs(bucket or {}) do
        if type(e) == "table" and e._quiHoTSeed then return e end
    end
end

-- The shape the removed seed paths stamped (fixed id "healerHoTs",
-- _quiHoTSeed = true). Spell list intentionally tiny/customized in some
-- scenarios — the flag alone is the strip criterion.
local function hotSeedElement(spells, name)
    return {
        id = "healerHoTs", mode = "tracked", displayType = "icon",
        onlyMine = true, name = name or "Healer HoTs", _quiHoTSeed = true,
        spells = spells or { 41635, 774 }, enabled = true,
    }
end

local function curated(id)
    return { id = id, mode = "filterStrip", auraType = "HELPFUL" }
end

----------------------------------------------------------------------------
-- 1) Strips the flagged element from every bucket shape, party AND raid,
--    including "*" (unlike the kept (j) repair, which never targets "*"),
--    preserving unflagged neighbors and their order.
----------------------------------------------------------------------------
do
    local pStar1, pStar2 = curated("keepA"), curated("keepB")
    local profile = {
        _schemaVersion = 58,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { pStar1, hotSeedElement(), pStar2 },
                [105]     = { hotSeedElement() },
                ["i2810"] = { curated("keepC"), hotSeedElement() },
                ["e3131"] = { hotSeedElement() },
            } } },
            raid = { auras = { elementsSeeded = true, elements = {
                ["*"]  = { hotSeedElement() },
                [270]  = { hotSeedElement(), curated("keepD") },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local pe = profile.quiGroupFrames.party.auras.elements
    local re = profile.quiGroupFrames.raid.auras.elements

    check("stamped 59", profile._schemaVersion == 59, tostring(profile._schemaVersion))
    check("party '*': flagged element gone, neighbors keep order",
        arrayCount(pe["*"]) == 2 and pe["*"][1] == pStar1 and pe["*"][2] == pStar2,
        tostring(arrayCount(pe["*"])))
    check("party numeric [105]: sole flagged bucket swept to empty, bucket kept",
        type(pe[105]) == "table" and arrayCount(pe[105]) == 0, tostring(arrayCount(pe[105])))
    check("party 'i2810': flagged gone alongside curated (UNCONDITIONAL, unlike (j))",
        arrayCount(pe["i2810"]) == 1 and pe["i2810"][1].id == "keepC",
        tostring(arrayCount(pe["i2810"])))
    check("party 'e3131': swept to empty", arrayCount(pe["e3131"]) == 0)
    check("raid '*': swept to empty ('*' IS a v59 target)", arrayCount(re["*"]) == 0)
    check("raid numeric [270]: curated survives in place",
        arrayCount(re[270]) == 1 and re[270][1].id == "keepD")
    check("no _quiHoTSeed anywhere post-run",
        findHoTSeed(pe["*"]) == nil and findHoTSeed(pe[105]) == nil
        and findHoTSeed(pe["i2810"]) == nil and findHoTSeed(pe["e3131"]) == nil
        and findHoTSeed(re["*"]) == nil and findHoTSeed(re[270]) == nil)
end

----------------------------------------------------------------------------
-- 2) Multiple flagged clones in ONE bucket (reverse-iteration correctness)
--    and customized-but-flagged (edited spells/name) both removed.
----------------------------------------------------------------------------
do
    local keep = curated("keepE")
    local profile = {
        _schemaVersion = 58,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { hotSeedElement(), keep,
                          hotSeedElement({ 774 }, "My trimmed HoTs"),
                          hotSeedElement() },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local star = profile.quiGroupFrames.party.auras.elements["*"]
    check("three flagged clones removed in one pass, keeper survives",
        arrayCount(star) == 1 and star[1] == keep, tostring(arrayCount(star)))
    check("customized-but-flagged removed too (owner-accepted)",
        findHoTSeed(star) == nil)
end

----------------------------------------------------------------------------
-- 3) Idempotence + no-op shapes: second run changes nothing; missing
--    quiGroupFrames / auras / elements are safe; unflagged "healerHoTs"-ish
--    ids are NOT matched (flag is the sole criterion).
----------------------------------------------------------------------------
do
    local impostor = { id = "healerHoTs", mode = "tracked", spells = { 999 } } -- no flag
    local profile = {
        _schemaVersion = 58,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { impostor, hotSeedElement() },
            } } },
            raid = { auras = {} },  -- no elements table
        },
    }
    M.RunOnProfile(profile)
    local star = profile.quiGroupFrames.party.auras.elements["*"]
    check("unflagged same-id element survives (flag is sole criterion)",
        arrayCount(star) == 1 and star[1] == impostor)
    local before = arrayCount(star)
    profile._schemaVersion = 58
    M.RunOnProfile(profile)
    check("idempotent: re-run from re-lowered stamp changes nothing",
        arrayCount(star) == before and star[1] == impostor)

    check("bare-profile shapes are safe no-ops",
        M.StripHealerHoTSeeds({}) == true
        and M.StripHealerHoTSeeds({ quiGroupFrames = 7 }) == true
        and M.StripHealerHoTSeeds({ quiGroupFrames = { party = {} } }) == true)
end

----------------------------------------------------------------------------
-- 4) Full chain from 56: v58 squash no longer seeds (step (i) deleted), the
--    kept (j) repair and (k) fan-out behave, and v59 leaves zero flags. A
--    pre-existing sole-seed i/e bucket (dev-window shape) is emptied by (j)
--    BEFORE (k) can inject defensives into it (the reason (j) survives).
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { curated("star") },
                ["i5050"] = { hotSeedElement() }, -- dev-window sole-seed pollution
                ["e6060"] = {},                   -- user suppress-intent
            } } },
        },
    }
    M.RunOnProfile(profile)
    local pe = profile.quiGroupFrames.party.auras.elements
    check("chain 56: stamped 59", profile._schemaVersion == 59, tostring(profile._schemaVersion))
    check("chain 56: '*' unpolluted (no seed step anymore)",
        arrayCount(pe["*"]) == 1 and pe["*"][1].id == "star" and findHoTSeed(pe["*"]) == nil)
    check("chain 56: sole-seed 'i5050' emptied by kept (j) and NOT refilled by (k)",
        arrayCount(pe["i5050"]) == 0, tostring(arrayCount(pe["i5050"])))
    check("chain 56: empty 'e6060' suppress-intent preserved",
        arrayCount(pe["e6060"]) == 0)
end

if failures > 0 then os.exit(1) end
print("migration_v59_strip_hot_seed_test: all checks passed")
