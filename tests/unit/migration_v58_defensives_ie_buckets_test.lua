-- tests/unit/migration_v58_defensives_ie_buckets_test.lua
-- Run: lua5.1 tests/unit/migration_v58_defensives_ie_buckets_test.lua
--
-- Migrations.ExtendDefensivesToInstanceEncounterBuckets (v58): v54's
-- ExtendDefensivesToSpecBuckets backfilled the shipped "defensives" strip
-- into pre-existing NUMERIC spec-override buckets only, deliberately
-- excluding the string "i"..mapID / "e"..encounterID context buckets
-- (E.InstanceBucketKey / E.EncounterBucketKey, tried by
-- core/aura_context.lua ahead of specID) — those REPLACE "*" at render time
-- exactly like a numeric spec bucket, so a pre-existing one silently lost
-- the "defensives" strip. This migration closes that gap, mirroring v57's
-- SeedHealerHoTElements fan-out shape (IsHoTOverrideBucketKey) but scoped to
-- the i/e subset only:
--   - a pre-existing "i"/"e" bucket lacking a defensives-equivalent element
--     gets a CloneValue copy of "*"'s defensives element appended, mirroring
--     its enabled state
--   - numeric spec buckets and "*" itself are NEVER touched by this step
--     (v54 already covers numeric buckets; "*" is the fan-out's source)
--   - a hand-built classify-equivalent strip (fixed id="defensives" OR a
--     classify strip carrying both bigDefensive+externalDefensive) blocks
--     injection — BYTE-IDENTICAL presence check to
--     Migrations.ExtendDefensivesToSpecBuckets' inline check (v54 never
--     extracted a helper, so this replicates it exactly)
--   - a non-matching string key is left completely alone
--   - running twice never doubles the element

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

local function findDefensives(bucket)
    for _, e in ipairs(bucket or {}) do
        if type(e) == "table" and e.id == "defensives" then return e end
    end
end

-- Real array-length count via ipairs (not #bucket, not a truthiness check) --
-- used as the "state evidence" that a bucket the empty-skip guard touches is
-- genuinely empty, matching the production code's own #bucket>0 count.
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

-- Mirrors the shape LANDED v57's SeedHealerHoTElements actually stamps
-- (core/migrations.lua Migrations.SeedHealerHoTElements): fixed id
-- "healerHoTs", mode "tracked", onlyMine=true, _quiHoTSeed=true. Used to
-- hand-build a bucket that already looks like an EARLIER real v57 pass left
-- it (a profile stamped 57 from a prior session), rather than re-deriving it
-- from the live E.NewTrackedElement/E.HealerHoTSpellIDs path every time.
local function hotSeedElement(enabled)
    return {
        id = "healerHoTs", mode = "tracked", displayType = "icon",
        onlyMine = true, name = "Healer HoTs", _quiHoTSeed = true,
        spells = { 41635, 774 }, enabled = enabled == true,
    }
end

local function starDefensives(enabled)
    return {
        id = "defensives", mode = "filterStrip", auraType = "HELPFUL",
        enabled = enabled == true, filterMode = "classify",
        classifications = { bigDefensive = true, externalDefensive = true },
        anchor = "BOTTOMRIGHT", growDirection = "LEFT", spacing = 0,
        offsetX = 0, offsetY = 4, iconSize = 15, maxIcons = 3,
    }
end

----------------------------------------------------------------------------
-- 1) Pre-existing "i"/"e" buckets — one with curated content, one empty —
--    each get exactly one defensives clone; numeric + "*" untouched by this
--    step. Starting the profile already at 57 (rather than below it) means
--    only the v58 gate fires below (`stored < 54/56/57` are all false at
--    57), isolating this migration's own behavior from v54/v56/v57's.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]      = { starDefensives(true) },
                [105]      = { { id = "curatedSpec", mode = "filterStrip", auraType = "HELPFUL" } },
                ["i2810"]  = { { id = "curatedInstance", mode = "tracked", spells = { 123 } } },
                ["e999"]   = {},
                ["custom"] = { { id = "curatedCustom", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("stamped to current (58)", profile._schemaVersion == 58, tostring(profile._schemaVersion))

    local elements = profile.quiGroupFrames.party.auras.elements

    -- Instance bucket "i2810": curated content survives, exactly one
    -- defensives clone fanned in alongside it.
    check("'i2810': curated content untouched",
        elements["i2810"][1] and elements["i2810"][1].id == "curatedInstance")
    check("'i2810': exactly one defensives clone", countDefensives(elements["i2810"]) == 1,
        tostring(countDefensives(elements["i2810"])))
    local instDef = findDefensives(elements["i2810"])
    check("'i2810': got a defensives element", instDef ~= nil)
    if instDef then
        check("'i2810': enabled mirrors '*' (true)", instDef.enabled == true, tostring(instDef.enabled))
        check("'i2810': is a copy, not an alias of '*'s element", instDef ~= elements["*"][1])
    end

    -- Encounter bucket "e999" (empty): FLIPPED 2026-07-22 -- this pair used
    -- to pin the OLD (wrong) behavior, exactly one defensives clone landing
    -- in an empty override bucket. An empty override bucket is created ONLY
    -- by E.EnableSpecOverride and represents the user's own deliberate
    -- "render nothing in this context" (the override cascade REPLACES "*",
    -- it never merges) -- v58 must never inject anything into it.
    check("'e999' (empty): NO defensives clone lands (was: exactly one -- OLD wrong behavior)",
        countDefensives(elements["e999"]) == 0, tostring(countDefensives(elements["e999"])))
    check("'e999': bucket stays completely empty (0 array entries via ipairs, was: 1 -- OLD wrong behavior)",
        arrayCount(elements["e999"]) == 0, tostring(arrayCount(elements["e999"])))

    -- ADVERSARIAL: prove the two checks above actually discriminate -- hand-append
    -- a defensives clone to the (now-empty) bucket and confirm both flip to
    -- failing-shape values, then remove it and confirm they flip back
    -- byte-identical to the empty state RunOnProfile actually left.
    local scratchDefensives = starDefensives(true)
    elements["e999"][1] = scratchDefensives
    check("adversarial: manually appending a defensives clone makes countDefensives see it",
        countDefensives(elements["e999"]) == 1)
    check("adversarial: manually appending also makes arrayCount see it",
        arrayCount(elements["e999"]) == 1)
    elements["e999"][1] = nil
    check("adversarial: removing the scratch clone restores the empty state (byte-identical to post-run)",
        countDefensives(elements["e999"]) == 0 and arrayCount(elements["e999"]) == 0)

    -- Numeric spec bucket [105]: NEVER touched by v58 -- IsInstanceOrEncounterBucketKey
    -- excludes numeric key shapes outright (that's v54's territory, not v58's).
    check("spec bucket [105]: curated content untouched",
        elements[105][1] and elements[105][1].id == "curatedSpec")
    check("spec bucket [105]: NO defensives clone from v58 (numeric key shape excluded by design)",
        countDefensives(elements[105]) == 0, tostring(countDefensives(elements[105])))

    -- "*" itself: still exactly one, untouched (source, never a target).
    check("'*' still has exactly one defensives element", countDefensives(elements["*"]) == 1,
        tostring(countDefensives(elements["*"])))

    -- Non-matching string key: NEVER touched by the fan-out.
    check("non-matching string bucket 'custom': untouched (still exactly its curated element)",
        #elements["custom"] == 1 and elements["custom"][1].id == "curatedCustom",
        tostring(#elements["custom"]))
    check("non-matching string bucket 'custom': no defensives element landed",
        countDefensives(elements["custom"]) == 0)

    -- ADVERSARIAL: flip the injected clone's id off "defensives" and confirm
    -- countDefensives actually stops counting it (proves the assertions
    -- above discriminate on the id itself, not merely on bucket length),
    -- then restore byte-identical and confirm it counts again.
    instDef.id = "notDefensives"
    check("adversarial: renaming the clone's id makes it invisible to countDefensives",
        countDefensives(elements["i2810"]) == 0)
    instDef.id = "defensives"
    check("adversarial: restoring the id (byte-identical) makes it visible again",
        countDefensives(elements["i2810"]) == 1 and findDefensives(elements["i2810"]) == instDef)
end

----------------------------------------------------------------------------
-- 2) Disabled "*" defensives mirrors as disabled on the clone (v54 behavior
--    carried through unchanged — the clone is a full CloneValue deep copy).
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starDefensives(false) },
                ["i4242"] = { { id = "curated", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local clone = findDefensives(profile.quiGroupFrames.party.auras.elements["i4242"])
    check("clone injected", clone ~= nil)
    if clone then
        check("enabled mirrors '*' (false)", clone.enabled == false, tostring(clone.enabled))
        check("clone is a copy, not an alias", clone ~= profile.quiGroupFrames.party.auras.elements["*"][1])

        -- ADVERSARIAL: mutate the clone's enabled flag independently and
        -- prove "*"'s source element is unaffected (true deep copy, not a
        -- shared reference) -- then restore byte-identical.
        clone.enabled = true
        check("adversarial: mutating the clone does not affect '*'s source element",
            profile.quiGroupFrames.party.auras.elements["*"][1].enabled == false)
        clone.enabled = false
        check("adversarial: restoring the clone's enabled flag (byte-identical)",
            clone.enabled == false and profile.quiGroupFrames.party.auras.elements["*"][1].enabled == false)
    end
end

----------------------------------------------------------------------------
-- 3) Hand-built classify-equivalent strip blocks injection (no duplicate) —
--    exact mirror of v54's fixed-id-OR-classify-equivalence presence check,
--    now exercised on an i/e bucket instead of a numeric one.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]    = { starDefensives(true) },
                ["e777"] = { {
                    id = 42, mode = "filterStrip", auraType = "HELPFUL", filterMode = "classify",
                    classifications = { bigDefensive = true, externalDefensive = true },
                } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements["e777"]
    check("no duplicate next to hand-built equivalent (fixed-id scan)",
        countDefensives(bucket) == 0, tostring(countDefensives(bucket)))
    check("bucket length unchanged (nothing appended)", #bucket == 1, tostring(#bucket))
    check("hand-built element still classify-equivalent (proves the check actually found it, "
        .. "not a coincidence of an unrelated skip)",
        bucket[1].filterMode == "classify" and bucket[1].classifications.bigDefensive
        and bucket[1].classifications.externalDefensive)
end

----------------------------------------------------------------------------
-- 4) Profiles already carrying a fixed-id "defensives" element in the i/e
--    bucket are untouched (no double, own fields survive byte-identical).
----------------------------------------------------------------------------
do
    local ownDefensives = {
        id = "defensives", mode = "filterStrip", auraType = "HELPFUL",
        enabled = true, filterMode = "off", iconSize = 99, -- diverged from the shipped literal
    }
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starDefensives(true) },
                ["i1000"] = { ownDefensives },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements["i1000"]
    check("pre-existing defensives: no double", #bucket == 1, tostring(#bucket))
    check("pre-existing defensives: own diverged fields survive byte-identical",
        bucket[1] == ownDefensives and bucket[1].iconSize == 99 and bucket[1].filterMode == "off")
end

----------------------------------------------------------------------------
-- 5) Idempotent: running twice never doubles the element in the same i/e
--    bucket.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starDefensives(true) },
                ["e2020"] = { { id = "curated", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local firstCount = #profile.quiGroupFrames.party.auras.elements["e2020"]
    check("first pass: exactly one defensives element appended", firstCount == 2, tostring(firstCount))
    profile._schemaVersion = 57  -- force a second pass through the v58 gate
    M.RunOnProfile(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements["e2020"]
    check("idempotent: bucket length unchanged", #bucket == firstCount, tostring(#bucket))

    -- ADVERSARIAL: prove the idempotency check above is counting the
    -- "defensives" id specifically, not just array length (which could
    -- coincidentally stay stable if a doubling bug also dropped something
    -- else).
    check("adversarial: exactly one 'defensives' element after two passes, not a coincidence",
        countDefensives(bucket) == 1, tostring(countDefensives(bucket)))
end

----------------------------------------------------------------------------
-- 6) "*" missing entirely (elementsSeeded true but no "*" key at all) — base
--    stays nil, so the fan-out is skipped for this surface entirely,
--    exactly like v54's `if base then` guard. A pre-existing i/e bucket is
--    left completely untouched.
----------------------------------------------------------------------------
do
    local instBucket = { { id = "curated", mode = "filterStrip", auraType = "HELPFUL" } }
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["i5050"] = instBucket,
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("no '*' bucket: i/e bucket left untouched",
        #instBucket == 1 and instBucket[1].id == "curated", tostring(#instBucket))
    check("no '*' bucket: still no '*' key materialized",
        profile.quiGroupFrames.party.auras.elements["*"] == nil)

    -- ADVERSARIAL: prove the skip above is because base was genuinely nil
    -- (not because the fan-out never runs for this bucket at all) by adding
    -- a "*" table (with a defensives element) afterward, simulating a later
    -- latch, and re-running — the fan-out should now fire.
    profile.quiGroupFrames.party.auras.elements["*"] = { starDefensives(true) }
    profile._schemaVersion = 57
    M.RunOnProfile(profile)
    check("adversarial: adding a '*' bucket (with defensives) and re-running now fans out",
        countDefensives(instBucket) == 1, tostring(countDefensives(instBucket)))
    check("adversarial: curated content in the i/e bucket still intact after the fan-out",
        instBucket[1].id == "curated")
end

----------------------------------------------------------------------------
-- 7) "*" present but lacking a "defensives" element (e.g. only debuffs/buffs
--    strips) — base stays nil, fan-out skipped, exactly like v54.
----------------------------------------------------------------------------
do
    local instBucket = {}
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" } },
                ["e6060"] = instBucket,
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("'*' without defensives: i/e bucket gets nothing from v58", #instBucket == 0,
        tostring(#instBucket))
end

----------------------------------------------------------------------------
-- 8) Unlatched store (no elementsSeeded) is left alone.
----------------------------------------------------------------------------
do
    local instBucket = {}
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elements = {
                ["*"]     = { starDefensives(true) },
                ["i7070"] = instBucket,
            } } },  -- elementsSeeded absent
        },
    }
    M.RunOnProfile(profile)
    check("unlatched store: nothing injected", #instBucket == 0, tostring(#instBucket))
end

----------------------------------------------------------------------------
-- 9) Raid surface (not just party) gets the same treatment: a NON-empty
--    instance bucket lacking "defensives" still gets the fan-out clone
--    (unchanged behavior -- the empty-skip guard only ever affects buckets
--    with zero elements), while a genuinely EMPTY instance bucket on the
--    SAME surface stays empty (suppress-intent, same as party's "e999").
--    FLIPPED 2026-07-22: "i8080" used to start empty and pin the OLD (wrong)
--    behavior of getting a clone; it now starts with curated content
--    instead so this section still proves raid-surface fan-out coverage,
--    and "i9090" (added) covers the empty case on raid specifically.
----------------------------------------------------------------------------
do
    local raidBucket = { { id = "curatedRaid", mode = "filterStrip", auraType = "HELPFUL" } }
    local emptyRaidBucket = {}
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            raid = { auras = { elementsSeeded = true, elements = {
                ["*"]      = { starDefensives(true) },
                ["i8080"]  = raidBucket,
                ["i9090"]  = emptyRaidBucket,
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("raid surface: non-empty instance bucket still gets exactly one defensives clone",
        countDefensives(raidBucket) == 1, tostring(countDefensives(raidBucket)))
    check("raid surface: curated content in that bucket survives",
        raidBucket[1] and raidBucket[1].id == "curatedRaid")
    check("raid surface: EMPTY instance bucket 'i9090' stays empty (suppress-intent, not old behavior)",
        arrayCount(emptyRaidBucket) == 0, tostring(arrayCount(emptyRaidBucket)))

    -- ADVERSARIAL: prove the empty-bucket check discriminates by manually
    -- appending then removing a clone, mirroring the "e999" adversarial
    -- proof above.
    emptyRaidBucket[1] = starDefensives(true)
    check("adversarial: manually appending to 'i9090' is visible to countDefensives",
        countDefensives(emptyRaidBucket) == 1)
    emptyRaidBucket[1] = nil
    check("adversarial: removing the scratch clone restores 'i9090' byte-identical to empty",
        arrayCount(emptyRaidBucket) == 0)
end

----------------------------------------------------------------------------
-- 11) Migrations.RepairSoleHoTOverrideBuckets + net suppress-intent across
--     the full v57+v58 chain in ONE RunOnProfile pass, starting from stored
--     = 56 (before v57 has ever touched this profile): v57's fan-out
--     injects a real healerHoTs clone into the empty numeric/i/e override
--     buckets below, then the v58-gate repair immediately strips it back
--     out (before v58's own defensives fan-out ever sees the bucket) --
--     netting to the ORIGINAL empty state, i.e. the suppress-intent a user
--     configured is preserved end to end. A non-empty sibling bucket in the
--     same profile is the contrast: it DOES keep the v57 fan-out (repair's
--     `#bucket == 1` guard does not match a 2-element bucket), proving the
--     empty result isn't just "the fan-out never ran on this profile".
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starDefensives(true) },
                [301]     = {},   -- empty numeric override
                ["i3030"] = {},   -- empty instance override
                ["e4040"] = {},   -- empty encounter override
                [302]     = { { id = "curatedSpec2", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("chain from 56: stamped to current (58)", profile._schemaVersion == 58,
        tostring(profile._schemaVersion))

    local elements = profile.quiGroupFrames.party.auras.elements

    check("chain from 56: empty numeric bucket [301] ends EMPTY (net suppress-intent)",
        arrayCount(elements[301]) == 0, tostring(arrayCount(elements[301])))
    check("chain from 56: empty instance bucket 'i3030' ends EMPTY (net suppress-intent)",
        arrayCount(elements["i3030"]) == 0, tostring(arrayCount(elements["i3030"])))
    check("chain from 56: empty encounter bucket 'e4040' ends EMPTY (net suppress-intent)",
        arrayCount(elements["e4040"]) == 0, tostring(arrayCount(elements["e4040"])))
    check("chain from 56: none of the three carry a lingering healerHoTs element",
        findHoTSeed(elements[301]) == nil and findHoTSeed(elements["i3030"]) == nil
        and findHoTSeed(elements["e4040"]) == nil)
    check("chain from 56: none of the three carry a lingering defensives element either",
        countDefensives(elements[301]) == 0 and countDefensives(elements["i3030"]) == 0
        and countDefensives(elements["e4040"]) == 0)

    -- Contrast: non-empty sibling [302] keeps its curated content AND gets
    -- the normal v57 fan-out (repair does not touch a 2-element bucket).
    check("chain from 56: non-empty sibling [302] keeps curated content",
        elements[302][1] and elements[302][1].id == "curatedSpec2")
    check("chain from 56: non-empty sibling [302] DOES get the v57 healerHoTs fan-out",
        findHoTSeed(elements[302]) ~= nil)
    check("chain from 56: non-empty sibling [302] ends with exactly 2 elements (curated + healerHoTs)",
        arrayCount(elements[302]) == 2, tostring(arrayCount(elements[302])))

    -- ADVERSARIAL: prove the "ends EMPTY" result is the repair genuinely
    -- undoing v57's injection (not v57 simply never firing on this profile
    -- at all) -- "*" itself is the fan-out's SOURCE, never a repair target,
    -- so it must carry a real healerHoTs element after the same run.
    check("adversarial: '*' itself carries a real healerHoTs element post-run (v57 genuinely ran)",
        findHoTSeed(elements["*"]) ~= nil)
    check("adversarial: '*' also still carries its defensives element (v51/v54 lineage untouched)",
        countDefensives(elements["*"]) == 1)

    -- ADVERSARIAL: manually re-seed [301] with a sole healerHoTs clone
    -- AFTER the fact and confirm the discrimination helpers actually see it
    -- (proving the EMPTY assertions above discriminate on content, not on
    -- some accident like the table reference changing), then restore
    -- byte-identical to the empty state RunOnProfile actually left.
    local scratchHoT = hotSeedElement(true)
    elements[301][1] = scratchHoT
    check("adversarial: manually re-seeding [301] is visible to findHoTSeed/arrayCount",
        findHoTSeed(elements[301]) == scratchHoT and arrayCount(elements[301]) == 1)
    elements[301][1] = nil
    check("adversarial: removing the scratch seed restores [301] byte-identical to empty",
        arrayCount(elements[301]) == 0 and findHoTSeed(elements[301]) == nil)
end

----------------------------------------------------------------------------
-- 12) Profiles already stamped 57 from an EARLIER real session (the sole
--     _quiHoTSeed element is already sitting in the bucket exactly as
--     LANDED v57 would have left it) get repaired when crossing 58 --
--     numeric AND both string-context (i/e) shapes, on both party and raid.
--     "*" itself is excluded (IsHoTOverrideBucketKey returns false for it),
--     so it is left completely alone even though it also only carries the
--     seed element.
----------------------------------------------------------------------------
do
    local starSoleHoT = hotSeedElement(true)
    local numericSole = hotSeedElement(true)
    local instSole = hotSeedElement(false)
    local encSole = hotSeedElement(true)
    local raidNumericSole = hotSeedElement(true)
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starSoleHoT },
                [401]     = { numericSole },
                ["i4141"] = { instSole },
                ["e4242"] = { encSole },
            } } },
            raid = { auras = { elementsSeeded = true, elements = {
                ["*"]  = { hotSeedElement(true) },
                [402]  = { raidNumericSole },
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("already-57: stamped to current (58)", profile._schemaVersion == 58,
        tostring(profile._schemaVersion))

    local pe = profile.quiGroupFrames.party.auras.elements
    local re = profile.quiGroupFrames.raid.auras.elements

    check("already-57: sole-HoT numeric bucket [401] repaired to EMPTY",
        arrayCount(pe[401]) == 0, tostring(arrayCount(pe[401])))
    check("already-57: sole-HoT instance bucket 'i4141' repaired to EMPTY",
        arrayCount(pe["i4141"]) == 0, tostring(arrayCount(pe["i4141"])))
    check("already-57: sole-HoT encounter bucket 'e4242' repaired to EMPTY",
        arrayCount(pe["e4242"]) == 0, tostring(arrayCount(pe["e4242"])))
    check("already-57: sole-HoT numeric bucket on RAID [402] repaired to EMPTY too",
        arrayCount(re[402]) == 0, tostring(arrayCount(re[402])))

    -- "*" is never a repair target (IsHoTOverrideBucketKey excludes it) --
    -- both party and raid "*" buckets keep their sole seed element intact.
    check("already-57: party '*' (never a repair target) keeps its sole seed element",
        arrayCount(pe["*"]) == 1 and pe["*"][1] == starSoleHoT)
    check("already-57: raid '*' (never a repair target) keeps its sole seed element",
        arrayCount(re["*"]) == 1)

    -- ADVERSARIAL: confirm the removed element instances are actually gone
    -- (not just shadowed) by identity, and restore each bucket's
    -- byte-identical empty state after probing.
    check("adversarial: the removed instance-bucket element is not aliased anywhere else",
        instSole ~= pe["*"][1] and instSole ~= starSoleHoT)
    pe["i4141"][1] = instSole
    check("adversarial: manually restoring the same element object makes the bucket non-empty again",
        arrayCount(pe["i4141"]) == 1 and pe["i4141"][1] == instSole)
    pe["i4141"][1] = nil
    check("adversarial: removing it again restores byte-identical empty state",
        arrayCount(pe["i4141"]) == 0)
end

----------------------------------------------------------------------------
-- 13) healerHoTs ALONGSIDE curated content (numeric AND i/e) is NEVER
--     removed by the repair -- the `#bucket == 1` guard only ever matches a
--     bucket whose SOLE content is the seed element. The i/e case also
--     proves the repair-then-fan-out ORDER within the same v58 gate:
--     because the repair does not empty this bucket, v58's own defensives
--     fan-out still runs on it normally afterward and adds "defensives"
--     alongside the untouched curated + healerHoTs content (unchanged
--     fan-out behavior for a non-empty, defensives-lacking bucket).
----------------------------------------------------------------------------
do
    local curatedNumeric = { id = "curatedAlongside1", mode = "filterStrip", auraType = "HELPFUL" }
    local numericHoT = hotSeedElement(true)
    local curatedIE = { id = "curatedAlongside2", mode = "tracked", spells = { 999 } }
    local ieHoT = hotSeedElement(false)
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starDefensives(true) },
                [501]     = { curatedNumeric, numericHoT },
                ["i5151"] = { curatedIE, ieHoT },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local elements = profile.quiGroupFrames.party.auras.elements

    check("alongside-curated: numeric bucket [501] keeps BOTH elements (not stripped)",
        arrayCount(elements[501]) == 2, tostring(arrayCount(elements[501])))
    check("alongside-curated: numeric bucket [501] curated element survives untouched",
        elements[501][1] == curatedNumeric)
    check("alongside-curated: numeric bucket [501] healerHoTs element survives untouched",
        findHoTSeed(elements[501]) == numericHoT)

    check("alongside-curated: i/e bucket 'i5151' curated element survives untouched",
        elements["i5151"][1] == curatedIE)
    check("alongside-curated: i/e bucket 'i5151' healerHoTs element survives untouched",
        findHoTSeed(elements["i5151"]) == ieHoT)
    check("alongside-curated: i/e bucket 'i5151' ALSO gets the v58 defensives fan-out "
        .. "(non-empty + lacking defensives = unchanged fan-out behavior)",
        countDefensives(elements["i5151"]) == 1, tostring(countDefensives(elements["i5151"])))
    check("alongside-curated: i/e bucket 'i5151' ends with exactly 3 elements "
        .. "(curated + healerHoTs + defensives)",
        arrayCount(elements["i5151"]) == 3, tostring(arrayCount(elements["i5151"])))

    -- ADVERSARIAL: prove the "kept" result is because the guard's
    -- #bucket==1 check genuinely failed (2+ elements), not because the
    -- repair skipped this bucket for some unrelated reason -- shrink the
    -- numeric bucket down to JUST the seed element (mirroring section 12's
    -- shape) and re-run on a freshly re-lowered stamp; THIS TIME it must be
    -- stripped, proving the repair logic is live and content-sensitive.
    table.remove(elements[501], 1)
    check("adversarial setup: numeric bucket [501] now sole-seed", arrayCount(elements[501]) == 1
        and findHoTSeed(elements[501]) == numericHoT)
    profile._schemaVersion = 57
    M.RunOnProfile(profile)
    check("adversarial: now-sole-seed bucket [501] IS stripped to empty on this pass",
        arrayCount(elements[501]) == 0, tostring(arrayCount(elements[501])))
end

----------------------------------------------------------------------------
-- 14) Idempotent: running the full pipeline twice never re-strips content
--     that survived the first pass, and never re-injects/double-removes on
--     an already-repaired empty bucket.
----------------------------------------------------------------------------
do
    local curated = { id = "curatedIdempotent", mode = "filterStrip", auraType = "HELPFUL" }
    local hotEl = hotSeedElement(true)
    local profile = {
        _schemaVersion = 57,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]     = { starDefensives(true) },
                [601]     = { hotSeedElement(true) },       -- sole seed -> repaired to empty
                ["e6161"] = { curated, hotEl },              -- alongside curated -> kept, then defensives added
            } } },
        },
    }
    M.RunOnProfile(profile)
    local elements = profile.quiGroupFrames.party.auras.elements
    local firstEmptyCount = arrayCount(elements[601])
    local firstKeptCount = arrayCount(elements["e6161"])
    check("idempotent setup: [601] repaired to empty on first pass", firstEmptyCount == 0,
        tostring(firstEmptyCount))
    check("idempotent setup: 'e6161' ends at 3 elements on first pass (curated+HoT+defensives)",
        firstKeptCount == 3, tostring(firstKeptCount))

    profile._schemaVersion = 57  -- force a second pass through the v58 gate
    M.RunOnProfile(profile)
    check("idempotent: [601] stays empty on second pass (no re-injection, no error on empty bucket)",
        arrayCount(elements[601]) == 0, tostring(arrayCount(elements[601])))
    check("idempotent: 'e6161' element count unchanged on second pass",
        arrayCount(elements["e6161"]) == firstKeptCount, tostring(arrayCount(elements["e6161"])))
    check("idempotent: 'e6161' curated/HoT/defensives all still exactly one each",
        elements["e6161"][1] == curated and findHoTSeed(elements["e6161"]) == hotEl
        and countDefensives(elements["e6161"]) == 1)

    -- ADVERSARIAL: a third pass, forced again, must still be a no-op --
    -- guards against an off-by-one that only shows up on pass 3+.
    profile._schemaVersion = 57
    M.RunOnProfile(profile)
    check("adversarial: third pass still leaves [601] empty", arrayCount(elements[601]) == 0)
    check("adversarial: third pass still leaves 'e6161' at exactly 3 elements",
        arrayCount(elements["e6161"]) == 3, tostring(arrayCount(elements["e6161"])))
end

----------------------------------------------------------------------------
-- 15) SOURCE-GUARD PIN: v54's ExtendDefensivesToSpecBuckets and v58's
--     ExtendDefensivesToInstanceEncounterBuckets each carry their own INLINE
--     copy of the classify-equivalence presence check (neither ever
--     extracted it to a shared helper — see both functions' doc comments in
--     core/migrations.lua, which point at each other and at this test).
--     This reads the live source, locates each function body by its unique
--     `function Migrations.<Name>(profile)` anchor, slices out just the
--     `local present = false` … `for _, e in ipairs(bucket) do … end` loop
--     from each, normalizes per-line leading/trailing whitespace (the two
--     copies sit at different nesting depth in their respective functions,
--     so raw indentation may legitimately differ even when the check itself
--     is identical), and asserts the two normalized loop bodies are
--     TEXTUALLY EQUAL. A future edit to either copy that isn't mirrored in
--     the other fails this pin, not just "behaves differently at runtime"
--     (which the rest of this file already covers via curated/hand-built
--     classify-equivalent fixtures) -- this is the drift guard, not a
--     behavior test.
----------------------------------------------------------------------------
do
    local function readFile(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local content = f:read("*a")
        f:close()
        return content
    end

    local function countPlain(s, needle)
        local n, start = 0, 1
        while true do
            local i = s:find(needle, start, true)
            if not i then break end
            n = n + 1
            start = i + #needle
        end
        return n
    end

    -- Slice the function body from its anchor to the closing "end" that
    -- ends the FUNCTION (not one of its nested for/if blocks). Every nested
    -- block in both functions is indented, so its closing "end" is preceded
    -- by spaces, never immediately by "\n"; the function's own closing "end"
    -- is the first one flush at column 0, i.e. the first literal "\nend\n".
    local function extractFunctionBody(source, anchor)
        local occurrences = countPlain(source, anchor)
        if occurrences ~= 1 then return nil, ("anchor not unique (%d occurrences): %s"):format(occurrences, anchor) end
        local s = source:find(anchor, 1, true)
        local bodyStart = s + #anchor
        local endPos = source:find("\nend\n", bodyStart, true)
        if not endPos then return nil, "closing end not found for anchor: " .. anchor end
        return source:sub(bodyStart, endPos)
    end

    local function extractPresenceLoop(functionBody)
        local startPat = "local present = false"
        local occurrences = countPlain(functionBody, startPat)
        if occurrences ~= 1 then return nil, ("presence-loop start not unique (%d)"):format(occurrences) end
        local s = functionBody:find(startPat, 1, true)
        local endMarker = "if not present then"
        local e = functionBody:find(endMarker, s, true)
        if not e then return nil, "presence loop end marker ('if not present then') not found" end
        return functionBody:sub(s, e - 1)
    end

    local function normalizeLines(text)
        local out = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do
            out[#out + 1] = line:match("^%s*(.-)%s*$")
        end
        while out[#out] == "" do out[#out] = nil end
        return table.concat(out, "\n")
    end

    local source = readFile("core/migrations.lua")
    check("pin: core/migrations.lua readable from repo-root-relative path", source ~= nil)

    if source then
        local anchor54 = "function Migrations.ExtendDefensivesToSpecBuckets(profile)"
        local anchor58 = "function Migrations.ExtendDefensivesToInstanceEncounterBuckets(profile)"

        check("pin: v54 anchor occurs exactly once in source (unique)", countPlain(source, anchor54) == 1,
            tostring(countPlain(source, anchor54)))
        check("pin: v58 anchor occurs exactly once in source (unique)", countPlain(source, anchor58) == 1,
            tostring(countPlain(source, anchor58)))

        local body54, err54 = extractFunctionBody(source, anchor54)
        local body58, err58 = extractFunctionBody(source, anchor58)
        check("pin: v54 function body extracted", body54 ~= nil, err54)
        check("pin: v58 function body extracted", body58 ~= nil, err58)

        if body54 and body58 then
            local loop54, lerr54 = extractPresenceLoop(body54)
            local loop58, lerr58 = extractPresenceLoop(body58)
            check("pin: v54 presence loop extracted", loop54 ~= nil, lerr54)
            check("pin: v58 presence loop extracted", loop58 ~= nil, lerr58)

            if loop54 and loop58 then
                -- Sanity: prove the extraction actually captured the
                -- meaningful check content, not an accidental empty/partial
                -- slice that would make the equality assertion below
                -- vacuously true.
                check("pin: v54 extracted loop contains the classify markers",
                    loop54:find("bigDefensive", 1, true) ~= nil
                    and loop54:find("externalDefensive", 1, true) ~= nil
                    and loop54:find('e.id == "defensives"', 1, true) ~= nil)
                check("pin: v58 extracted loop contains the classify markers",
                    loop58:find("bigDefensive", 1, true) ~= nil
                    and loop58:find("externalDefensive", 1, true) ~= nil
                    and loop58:find('e.id == "defensives"', 1, true) ~= nil)

                local n54 = normalizeLines(loop54)
                local n58 = normalizeLines(loop58)
                check("PIN: v54/v58 presence-check inline loops are textually identical (normalized)",
                    n54 == n58, "\n--- v54 ---\n" .. n54 .. "\n--- v58 ---\n" .. n58)

                -- ADVERSARIAL: prove the pin above actually discriminates —
                -- mutate a SCRATCH copy of the v58 loop text (never touches
                -- the real file) and confirm the same comparison now
                -- disagrees, so a genuine future drift between the two
                -- copies would be caught, not silently accepted.
                local mutated = normalizeLines(loop58:gsub("bigDefensive", "bigDefensiveDRIFTED", 1))
                check("adversarial: mutating a scratch copy of v58's loop makes the pin comparison disagree",
                    mutated ~= n54, "mutation did not change the comparison outcome")
                check("adversarial: the unmutated normalized text still matches (mutation was scoped to the copy)",
                    n58 == normalizeLines(loop58))
            end
        end
    end
end

if failures > 0 then os.exit(1) end
print("migration_v58_defensives_ie_buckets_test: all checks passed")
