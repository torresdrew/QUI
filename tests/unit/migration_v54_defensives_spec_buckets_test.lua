-- tests/unit/migration_v54_defensives_spec_buckets_test.lua
-- Run: lua5.1 tests/unit/migration_v54_defensives_spec_buckets_test.lua
-- v54: backfill the shipped defensives strip into spec-override buckets that
-- v51(e) skipped. Spec buckets REPLACE "*" (E.ActiveElementsForSpec), so a
-- pre-existing override bucket silently lost the indicator for that spec.
--   - numeric spec buckets lacking defensives get a CloneValue copy of the
--     "*" element (enabled state mirrors "*")
--   - string context buckets ("i"../"e"..) are never touched
--   - a hand-built classify-equivalent strip blocks injection (no duplicate)
--   - the stamp is the one-shot: deletions after v54 stick
local ns = dofile("tools/_addon_env.lua").LoadCore()
local M = ns.Migrations

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

local function countDefensives(bucket)
    local n = 0
    for _, e in ipairs(bucket or {}) do
        if type(e) == "table" and e.id == "defensives" then n = n + 1 end
    end
    return n
end

local function buildProfile(starEnabled)
    local defensives = {
        id = "defensives", mode = "filterStrip", auraType = "HELPFUL",
        enabled = starEnabled, filterMode = "classify",
        classifications = { bigDefensive = true, externalDefensive = true },
    }
    return {
        _schemaVersion = 51,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { defensives },
                [105] = { { id = 7, mode = "filterStrip", auraType = "HARMFUL", filterMode = "off" } },
                ["i2810"] = { { id = 9, mode = "tracked", spells = { 123 } } },
            } } },
        },
    }
end

do -- spec bucket backfilled, context bucket untouched, stamp moves
    local p = buildProfile(true)
    M.RunOnProfile(p)
    local elements = p.quiGroupFrames.party.auras.elements
    check("spec bucket got defensives", countDefensives(elements[105]) == 1, tostring(countDefensives(elements[105])))
    for _, e in ipairs(elements[105]) do
        if e.id == "defensives" then
            check("enabled mirrors '*' (true)", e.enabled == true, tostring(e.enabled))
            check("copy, not alias", e ~= elements["*"][1])
        end
    end
    -- v54 ITSELF never touches "i2810" (that's what this check proves — see
    -- ExtendDefensivesToSpecBuckets's numeric-only bucketKey filter); the
    -- original id=9 element and its position survive. This profile's
    -- RunOnProfile call cascades all the way to the CURRENT schema, though,
    -- so a LATER, independent step in the same chain — v57's
    -- SeedHealerHoTElements, which (unlike v54) fans a _quiHoTSeed element
    -- into string i/e context buckets too, see core/migrations.lua's v57 doc
    -- — legitimately appends a second element to this same bucket. That's
    -- expected and unrelated to v54; the assertion below still pins v54's
    -- own no-touch behavior (original element unmoved, no "defensives"
    -- landed) while accounting for the v57 addition.
    check("context bucket: v54 leaves the original element untouched (in place)",
        elements["i2810"][1] and elements["i2810"][1].id == 9)
    check("context bucket: v54 itself injects no 'defensives' element into it",
        countDefensives(elements["i2810"]) == 0)
    check("context bucket: only the v57 healerHoTs fan-out added anything (no other growth)",
        #elements["i2810"] == 2 and elements["i2810"][2]._quiHoTSeed == true,
        tostring(#elements["i2810"]))
    check("'*' still has exactly one", countDefensives(elements["*"]) == 1)
    check("stamped 57", p._schemaVersion == 57, tostring(p._schemaVersion))
end

do -- disabled "*" defensives mirrors as disabled
    local p = buildProfile(false)
    M.RunOnProfile(p)
    for _, e in ipairs(p.quiGroupFrames.party.auras.elements[105]) do
        if e.id == "defensives" then
            check("enabled mirrors '*' (false)", e.enabled == false, tostring(e.enabled))
        end
    end
end

do -- hand-built classify-equivalent blocks injection
    local p = buildProfile(true)
    table.insert(p.quiGroupFrames.party.auras.elements[105], {
        id = 42, mode = "filterStrip", auraType = "HELPFUL", filterMode = "classify",
        classifications = { bigDefensive = true, externalDefensive = true },
    })
    M.RunOnProfile(p)
    check("no duplicate next to hand-built equivalent",
        countDefensives(p.quiGroupFrames.party.auras.elements[105]) == 0,
        tostring(countDefensives(p.quiGroupFrames.party.auras.elements[105])))
end

do -- one-shot: post-v54 deletion sticks on the next run
    local p = buildProfile(true)
    M.RunOnProfile(p)
    local spec = p.quiGroupFrames.party.auras.elements[105]
    for i = #spec, 1, -1 do
        if spec[i].id == "defensives" then table.remove(spec, i) end
    end
    M.RunOnProfile(p)
    check("post-v54 deletion sticks", countDefensives(spec) == 0, tostring(countDefensives(spec)))
end

print("migration_v54_defensives_spec_buckets_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
