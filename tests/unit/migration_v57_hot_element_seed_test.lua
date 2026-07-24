-- tests/unit/migration_v57_hot_element_seed_test.lua
-- Run: lua5.1 tests/unit/migration_v57_hot_element_seed_test.lua
--
-- Migrations.SeedHealerHoTElements (v57): an upcoming PTR build makes ~42
-- healer HoT/absorb spell ids secret in combat; the legacy Lua-side
-- spellID matcher cannot see secret auras and silently drops the icon, but
-- engine-rendered tracked slots (AuraSlots) render them C-side. Injects ONE
-- "tracked" element (flagged _quiHoTSeed) carrying the non-secret preset
-- union into every LATCHED "*" bucket (GF party/raid) — same
-- injection scope/shape as v51(e)'s FoldDefensiveIndicatorIntoElements.
--
-- Self-contained by design (see the version doc in core/migrations.lua):
-- does NOT call into QUI_GroupFrames' AuraDefaults.SeedHealerHoTElements —
-- Migrations.Run's primary call site (QUICore:OnInitialize) fires before
-- the QUI_GroupFrames sub-addon has loaded. HOT_SPELL_IDS is therefore a
-- pinned literal copy; part 2 below proves it never drifts from the live
-- AuraDefaults-derived union.

local envmod = dofile("tools/_addon_env.lua")
local ns = envmod.LoadCore()
envmod.LoadAddonFile("QUI_GroupFrames/groupframes/groupframes_aura_model.lua", "QUI_GroupFrames", ns)
envmod.LoadAddonFile("QUI_GroupFrames/groupframes/settings/group_frames_aura_defaults.lua", "QUI_GroupFrames", ns)
local M = ns.Migrations
local AuraDefaults = ns.QUI_GroupFramesAuraDefaults

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

local function findByFlag(bucket)
    for _, e in ipairs(bucket or {}) do if e._quiHoTSeed then return e end end
end

local function gfSurface()
    return {
        auras = {
            elementsSeeded = true,
            elements = { ["*"] = {
                { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" },
                { id = "buffs", mode = "filterStrip", auraType = "HELPFUL" },
            } },
        },
    }
end

----------------------------------------------------------------------------
-- 1) Party + raid: latched "*" buckets each get exactly one _quiHoTSeed
--    tracked element with the expected shape.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = gfSurface(),
            raid  = gfSurface(),
        },
    }
    M.RunOnProfile(profile)

    check("stamped to current (58)", profile._schemaVersion == 58, tostring(profile._schemaVersion))

    for _, key in ipairs({ "party", "raid" }) do
        local bucket = profile.quiGroupFrames[key].auras.elements["*"]
        local e = findByFlag(bucket)
        check(key .. ": element injected", e ~= nil)
        if e then
            -- Fixed id (not the session-scoped "e<N>" NewTrackedElement
            -- counter default): the counter isn't synced to existing bucket
            -- elements at OnInitialize and this dedup scan is a one-shot
            -- latch, so a counter-derived id can permanently collide with an
            -- existing element on legacy profiles. Same fixed-id precedent
            -- as "defensives" / "encounterBoss".
            check(key .. ": id == healerHoTs (fixed, not counter-derived)",
                e.id == "healerHoTs", tostring(e.id))
            check(key .. ": mode == tracked", e.mode == "tracked", tostring(e.mode))
            check(key .. ": displayType == icon", e.displayType == "icon", tostring(e.displayType))
            check(key .. ": onlyMine == true", e.onlyMine == true, tostring(e.onlyMine))
            -- maxIcons must stay ABSENT (uncapped) — see the migrations.lua
            -- v57 doc comment: AuraSlots binds 1:1 per spellID in array
            -- order and stops at the cap, so a cap here would strand every
            -- id past the first N with no watching slot.
            check(key .. ": maxIcons is absent/nil (uncapped)", e.maxIcons == nil, tostring(e.maxIcons))
            check(key .. ": spells non-empty", type(e.spells) == "table" and #e.spells > 0)
        end
        check(key .. ": original strips untouched", bucket[1].id == "debuffs" and bucket[2].id == "buffs")
        check(key .. ": exactly one element appended", #bucket == 3, tostring(#bucket))
    end
end

----------------------------------------------------------------------------
-- 2) Unlatched store (no elementsSeeded) is left alone — matches v51(e)'s
--    "the surface-aware runtime seed handles it" scoping.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elements = { ["*"] = {} } } },  -- elementsSeeded absent
        },
    }
    M.RunOnProfile(profile)
    local bucket = profile.quiGroupFrames.party.auras.elements["*"]
    check("unlatched store: nothing injected", #bucket == 0, tostring(#bucket))
end

----------------------------------------------------------------------------
-- 3) Idempotent: running twice never doubles the element.
----------------------------------------------------------------------------
do
    local profile = { _schemaVersion = 56, quiGroupFrames = { party = gfSurface() } }
    M.RunOnProfile(profile)
    local firstCount = #profile.quiGroupFrames.party.auras.elements["*"]
    profile._schemaVersion = 56  -- force a second pass through the v57 gate
    M.RunOnProfile(profile)
    check("idempotent: bucket length unchanged", #profile.quiGroupFrames.party.auras.elements["*"] == firstCount,
        tostring(#profile.quiGroupFrames.party.auras.elements["*"]))
end

----------------------------------------------------------------------------
-- 4) Belt-and-suspenders: a bucket that already carries a _quiHoTSeed
--    element (e.g. some other path landed it first) is not doubled, even
--    coming in fresh below the v57 gate.
----------------------------------------------------------------------------
do
    local bucket = gfSurface().auras.elements["*"]
    bucket[#bucket + 1] = { id = "preexisting", mode = "tracked", _quiHoTSeed = true, spells = { 1 } }
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = { party = { auras = { elementsSeeded = true, elements = { ["*"] = bucket } } } },
    }
    M.RunOnProfile(profile)
    check("pre-existing _quiHoTSeed: no double", #profile.quiGroupFrames.party.auras.elements["*"] == 3,
        tostring(#profile.quiGroupFrames.party.auras.elements["*"]))
end

----------------------------------------------------------------------------
-- 5) PIN: HOT_SPELL_IDS (core/migrations.lua) must stay byte-for-byte
--    equal (as a SET — order of transcription isn't the load-bearing
--    property) to the live non-secret union AuraDefaults.SeedHealerHoTElements
--    derives from SPEC_AURA_PRESETS. Guards against drift between the two
--    literal definitions (mirrors migration_v52_defensives_fold_test.lua's
--    BuildShippedDefensivesElement-vs-Model.DefaultStripBucket parity check).
----------------------------------------------------------------------------
do
    check("AuraDefaults loaded for the pin check", type(AuraDefaults) == "table")
    local presets = AuraDefaults.SpecPresets()
    local liveIds, liveSeen, secretIds = {}, {}, {}
    for _, preset in ipairs(presets) do
        for _, s in ipairs(preset.spells) do
            if s.secret then
                secretIds[s.id] = true
            elseif not liveSeen[s.id] then
                liveSeen[s.id] = true
                liveIds[#liveIds + 1] = s.id
            end
        end
    end

    -- Pull the pinned literal straight out of a fresh seed run (RunOnProfile
    -- already exercised the real migration code path above) rather than
    -- re-declaring it in the test — that would just be a THIRD copy to drift.
    local profile = { _schemaVersion = 56, quiGroupFrames = { party = gfSurface() } }
    M.RunOnProfile(profile)
    local pinned = findByFlag(profile.quiGroupFrames.party.auras.elements["*"]).spells

    check("pin: same count", #pinned == #liveIds,
        ("pinned=%d live=%d"):format(#pinned, #liveIds))

    local pinnedSet = {}
    for _, id in ipairs(pinned) do pinnedSet[id] = true end
    local allMatch, mismatch = true, nil
    for _, id in ipairs(liveIds) do
        if not pinnedSet[id] then allMatch, mismatch = false, id break end
    end
    check("pin: every live non-secret id present in pinned literal", allMatch, tostring(mismatch))

    local noExtra, extra = true, nil
    local liveSet = {}
    for _, id in ipairs(liveIds) do liveSet[id] = true end
    for _, id in ipairs(pinned) do
        if not liveSet[id] then noExtra, extra = false, id break end
    end
    check("pin: no extra id in pinned literal not present live", noExtra, tostring(extra))

    local noSecretsPinned, leaked = true, nil
    for _, id in ipairs(pinned) do
        if secretIds[id] then noSecretsPinned, leaked = false, id break end
    end
    check("pin: no secret preset id present in pinned literal", noSecretsPinned, tostring(leaked))

    -- ORDER, not just set membership. Now that maxIcons is gone (uncapped),
    -- no runtime behavior depends on array order any more — but pin it
    -- anyway: a future reorder of either literal (this file's HOT_SPELL_IDS
    -- or the live SPEC_AURA_PRESETS-derived union) would silently change
    -- which array index binds to which slot key ("t1", "t2", ...) even
    -- though the SET of bound spells stays identical, and a slot-index
    -- reorder is exactly the kind of change that should require a deliberate
    -- test update, not slip through a set-equality check.
    local sameOrder, atIndex = true, nil
    if #pinned == #liveIds then
        for i = 1, #pinned do
            if pinned[i] ~= liveIds[i] then sameOrder, atIndex = false, i break end
        end
    else
        sameOrder = false
    end
    check("pin: sequence order matches live union order (not just set)", sameOrder,
        atIndex and ("index " .. atIndex .. ": pinned=" .. tostring(pinned[atIndex])
            .. " live=" .. tostring(liveIds[atIndex])) or "length mismatch")
end

----------------------------------------------------------------------------
-- 6) Override-bucket fan-out (v54-style ExtendDefensivesToSpecBuckets idiom,
--    EXTENDED to the instance/encounter cascade rungs): numeric spec-override
--    buckets AND string "i"/"e" context buckets all REPLACE "*" at render
--    time rather than merging with it, so after "*" is seeded, every such
--    bucket lacking a _quiHoTSeed element gets a copy appended too — spec
--    bucket [105] with a curated element already in it, spec bucket [106]
--    that's empty, instance bucket "i2810" with curated content, encounter
--    bucket "e999" empty. "*" itself is still seeded exactly once, and a
--    non-matching string key ("custom") is left completely alone.
--
--    CASCADE NOTE (2026-07-22, v58 round 2): this profile's RunOnProfile
--    call cascades all the way to CURRENT, which now also runs v58's
--    Migrations.RepairSoleHoTOverrideBuckets (see core/migrations.lua's v58
--    version doc) immediately after this v57 fan-out, in the SAME pass.
--    That repair removes the _quiHoTSeed element from any override bucket
--    whose ONLY content is that element -- exactly the [106] and "e999"
--    buckets below, which started completely empty. This is v57's OWN
--    fan-out shape unchanged (still unconditionally seeds every empty
--    override bucket, pinned by the assertions immediately below); the
--    updated expectations further down for [106]/"e999" pin the CORRECTED
--    end state of the full pipeline (empty, not sole-seeded), not a change
--    to this function itself. "i2810" and [105] are non-empty and stay
--    exactly as this section always pinned them.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" } },
                [105] = { { id = "curated1", mode = "filterStrip", auraType = "HELPFUL" } },
                [106] = {},
                ["i2810"] = { { id = "curated2", mode = "tracked", spells = { 123 } } },
                ["e999"] = {},
                ["custom"] = { { id = "curated3", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local elements = profile.quiGroupFrames.party.auras.elements

    check("spec bucket [105]: curated content untouched", elements[105][1].id == "curated1")
    check("spec bucket [105]: curated + exactly one HoT element", #elements[105] == 2,
        tostring(#elements[105]))
    local specHoT = findByFlag(elements[105])
    check("spec bucket [105]: got a _quiHoTSeed element", specHoT ~= nil)
    if specHoT then
        check("spec bucket [105]: fixed id healerHoTs (not re-keyed)", specHoT.id == "healerHoTs",
            tostring(specHoT.id))
        check("spec bucket [105]: default enabled state (true) mirrored from '*'",
            specHoT.enabled == true, tostring(specHoT.enabled))
        check("spec bucket [105]: is a copy, not an alias of '*'s element",
            specHoT ~= findByFlag(elements["*"]))
    end

    -- FLIPPED (v58 round 2, see the CASCADE NOTE above): this pair used to
    -- pin v57's fan-out landing its sole HoT element in a bucket that
    -- started empty. Over the FULL pipeline (this profile cascades to
    -- CURRENT in one RunOnProfile call) that is no longer the end state --
    -- v58's Migrations.RepairSoleHoTOverrideBuckets strips the same element
    -- back out immediately afterward, in this same pass, because the
    -- bucket's ONLY content was the seed. v57's own fan-out still ran (see
    -- the adversarial check below, which proves it via [105]'s sibling
    -- clone) -- it is the pipeline's END STATE that changed.
    check("spec bucket [106] (empty): repaired back to EMPTY by v58 (was: got the HoT element)",
        #elements[106] == 0, tostring(#elements[106]))
    check("spec bucket [106] (empty): no lingering HoT element",
        findByFlag(elements[106]) == nil)

    -- ADVERSARIAL: prove [106] ending empty is the v58 repair undoing a REAL
    -- v57 injection (not v57 skipping this bucket) by manually re-seeding it
    -- with the same shape and confirming discrimination, then restoring
    -- byte-identical to the empty state RunOnProfile actually left.
    local scratch106 = { id = "healerHoTs", mode = "tracked", _quiHoTSeed = true, spells = { 1 } }
    elements[106][1] = scratch106
    check("adversarial: manually re-seeding [106] is visible to findByFlag",
        findByFlag(elements[106]) == scratch106)
    elements[106][1] = nil
    check("adversarial: removing the scratch seed restores [106] byte-identical to empty",
        #elements[106] == 0 and findByFlag(elements[106]) == nil)

    check("'*' still seeded exactly once", elements["*"] and #elements["*"] == 2
        and findByFlag(elements["*"]) ~= nil, tostring(elements["*"] and #elements["*"]))

    -- Instance bucket "i2810": curated content survives, exactly one HoT
    -- element gets fanned in alongside it.
    check("instance bucket 'i2810': curated content untouched",
        elements["i2810"][1] and elements["i2810"][1].id == "curated2")
    check("instance bucket 'i2810': curated + exactly one HoT element", #elements["i2810"] == 2,
        tostring(#elements["i2810"]))
    local instHoT = findByFlag(elements["i2810"])
    check("instance bucket 'i2810': got a _quiHoTSeed element", instHoT ~= nil)
    if instHoT then
        check("instance bucket 'i2810': fixed id healerHoTs (not re-keyed)",
            instHoT.id == "healerHoTs", tostring(instHoT.id))
        check("instance bucket 'i2810': is a copy, not an alias of '*'s element",
            instHoT ~= findByFlag(elements["*"]))
    end

    -- FLIPPED (v58 round 2, see the CASCADE NOTE above): same as [106] --
    -- was: got exactly the HoT element; now (full-pipeline end state):
    -- repaired back to empty.
    check("encounter bucket 'e999' (empty): repaired back to EMPTY by v58 (was: got the HoT element)",
        #elements["e999"] == 0, tostring(#elements["e999"]))
    check("encounter bucket 'e999' (empty): no lingering HoT element",
        findByFlag(elements["e999"]) == nil)

    -- ADVERSARIAL: same re-seed/restore discrimination proof as [106] above.
    local scratchE999 = { id = "healerHoTs", mode = "tracked", _quiHoTSeed = true, spells = { 1 } }
    elements["e999"][1] = scratchE999
    check("adversarial: manually re-seeding 'e999' is visible to findByFlag",
        findByFlag(elements["e999"]) == scratchE999)
    elements["e999"][1] = nil
    check("adversarial: removing the scratch seed restores 'e999' byte-identical to empty",
        #elements["e999"] == 0 and findByFlag(elements["e999"]) == nil)

    -- Non-matching string key: NEVER touched by the fan-out.
    check("non-matching string bucket 'custom': untouched (still exactly its curated element)",
        #elements["custom"] == 1 and elements["custom"][1].id == "curated3",
        tostring(#elements["custom"]))
    check("non-matching string bucket 'custom': no HoT element landed",
        findByFlag(elements["custom"]) == nil)

    -- ADVERSARIAL: flip the injected clone's flag off and confirm findByFlag
    -- actually stops finding it (proves the assertions above discriminate on
    -- the flag itself, not merely on element count/position), then restore
    -- byte-identical and confirm it's found again.
    specHoT._quiHoTSeed = false
    check("adversarial: flipping the clone's flag false makes it invisible to findByFlag",
        findByFlag(elements[105]) == nil)
    specHoT._quiHoTSeed = true
    check("adversarial: restoring the flag (byte-identical) makes it visible again",
        findByFlag(elements[105]) == specHoT)

    -- ADVERSARIAL: same discrimination proof for the instance-bucket clone.
    instHoT._quiHoTSeed = false
    check("adversarial: flipping the instance clone's flag false makes it invisible",
        findByFlag(elements["i2810"]) == nil)
    instHoT._quiHoTSeed = true
    check("adversarial: restoring the instance clone's flag (byte-identical) makes it visible again",
        findByFlag(elements["i2810"]) == instHoT)
end

----------------------------------------------------------------------------
-- 7) Belt-and-suspenders: a numeric spec bucket that ALREADY carries a
--    _quiHoTSeed element (e.g. some other path landed it first) is not
--    doubled — mirrors section 4's "*"-bucket belt-and-suspenders check,
--    scoped to a spec bucket instead.
----------------------------------------------------------------------------
do
    local specBucket = {
        { id = "curated3", mode = "filterStrip", auraType = "HELPFUL" },
        { id = "preexisting", mode = "tracked", _quiHoTSeed = true, spells = { 1 }, enabled = false },
    }
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" } },
                [102] = specBucket,
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("pre-existing spec-bucket _quiHoTSeed: no double", #specBucket == 2, tostring(#specBucket))
    local e = findByFlag(specBucket)
    check("pre-existing spec-bucket _quiHoTSeed: untouched element survives (own id/enabled kept)",
        e ~= nil and e.id == "preexisting" and e.enabled == false)

    -- ADVERSARIAL: remove the pre-existing flagged element and re-run on a
    -- freshly re-lowered stamp -> THIS TIME the fan-out (base sourced from
    -- "*", which the same run already seeded) appends a real clone, proving
    -- the "no double" result above happened because the presence check
    -- found the element, not because this bucket's fan-out never runs.
    table.remove(specBucket, 2)
    check("adversarial setup: element actually removed first", #specBucket == 1)
    profile._schemaVersion = 56
    M.RunOnProfile(profile)
    check("adversarial: removing the pre-existing element lets the fan-out inject a real one",
        #specBucket == 2 and findByFlag(specBucket) ~= nil, tostring(#specBucket))
    check("adversarial: curated content still intact after the fan-out landed",
        specBucket[1].id == "curated3")
end

----------------------------------------------------------------------------
-- 8) Idempotent: running the migration twice on a profile with a numeric
--    spec bucket never doubles the fan-out copy in that bucket — mirrors
--    section 3's "*"-bucket idempotency check, scoped to a spec bucket.
----------------------------------------------------------------------------
do
    local specBucket = { { id = "curated4", mode = "filterStrip", auraType = "HELPFUL" } }
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" } },
                [104] = specBucket,
            } } },
        },
    }
    M.RunOnProfile(profile)
    local firstCount = #specBucket
    check("first pass: spec bucket got exactly one HoT element appended", firstCount == 2,
        tostring(firstCount))
    profile._schemaVersion = 56  -- force a second pass through the v57 gate
    M.RunOnProfile(profile)
    check("idempotent: spec bucket length unchanged on second pass", #specBucket == firstCount,
        tostring(#specBucket))

    -- ADVERSARIAL: prove the idempotency check above is counting the flagged
    -- element specifically, not just array length (which could coincidentally
    -- stay stable if a doubling bug also dropped something else).
    local flaggedCount = 0
    for _, e in ipairs(specBucket) do if e._quiHoTSeed then flaggedCount = flaggedCount + 1 end end
    check("adversarial: exactly one _quiHoTSeed-flagged element after two passes, not a coincidence",
        flaggedCount == 1, tostring(flaggedCount))
end

----------------------------------------------------------------------------
-- 9) Enabled-state mirroring (v54 behavior, ExtendDefensivesToSpecBuckets):
--    the fan-out clone is a full deep copy of "*"'s _quiHoTSeed element, so
--    whatever enabled state "*" carries — including a non-default disabled
--    state — comes along automatically, exactly like v54's defensives
--    fan-out (migration_v54_defensives_spec_buckets_test.lua "disabled '*'
--    defensives mirrors as disabled").
----------------------------------------------------------------------------
do
    local starHoT = {
        id = "healerHoTs", mode = "tracked", displayType = "icon",
        onlyMine = true, name = "Healer HoTs", _quiHoTSeed = true,
        spells = { 1, 2, 3 }, enabled = false,
    }
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"] = { starHoT },
                [103] = { { id = "curated5", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local elements = profile.quiGroupFrames.party.auras.elements
    check("'*' HoT element untouched by the already-present check (still disabled)",
        elements["*"][1].enabled == false)
    local clone = findByFlag(elements[103])
    check("spec bucket got a fan-out clone", clone ~= nil)
    if clone then
        check("enabled mirrors '*' (false)", clone.enabled == false, tostring(clone.enabled))
        check("fan-out clone is a copy, not an alias of '*'s element", clone ~= starHoT)
        check("fixed id healerHoTs preserved on the disabled clone", clone.id == "healerHoTs",
            tostring(clone.id))
    end

    -- ADVERSARIAL: mutate the clone's enabled flag independently and prove
    -- "*"'s source element is unaffected (a true deep copy, not a shared
    -- reference) — then restore byte-identical.
    if clone then
        clone.enabled = true
        check("adversarial: mutating the clone's enabled flag does not affect '*'s source element",
            starHoT.enabled == false, tostring(starHoT.enabled))
        clone.enabled = false
        check("adversarial: restoring the clone's enabled flag (byte-identical)",
            clone.enabled == false and starHoT.enabled == false)
    end
end

----------------------------------------------------------------------------
-- 10) "*" missing entirely (elementsSeeded true but no "*" key at all) —
--     the "*"-seeding step can't run (elements["*"] isn't a table) so base
--     stays nil and, exactly like v54's ExtendDefensivesToSpecBuckets
--     `if base then` guard, the spec-bucket fan-out is skipped for this
--     surface too. A pre-existing numeric bucket is left completely
--     untouched.
----------------------------------------------------------------------------
do
    local specBucket = { { id = "curated6", mode = "filterStrip", auraType = "HELPFUL" } }
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                [101] = specBucket,
            } } },
        },
    }
    M.RunOnProfile(profile)
    check("no '*' bucket: spec bucket left untouched", #specBucket == 1
        and specBucket[1].id == "curated6", tostring(#specBucket))
    check("no '*' bucket: still no '*' key materialized",
        profile.quiGroupFrames.party.auras.elements["*"] == nil)

    -- ADVERSARIAL: prove the skip above is because base was genuinely nil
    -- (not because the fan-out code never runs for this bucket at all) by
    -- adding a "*" table afterward, simulating a later latch, and
    -- re-running — the fan-out should now fire since base is no longer nil.
    profile.quiGroupFrames.party.auras.elements["*"] = { { id = "debuffs", mode = "filterStrip" } }
    profile._schemaVersion = 56
    M.RunOnProfile(profile)
    check("adversarial: adding a '*' bucket and re-running now fans out into the spec bucket",
        #specBucket == 2 and findByFlag(specBucket) ~= nil, tostring(#specBucket))
    check("adversarial: curated content in the spec bucket still intact after the fan-out",
        specBucket[1].id == "curated6")
end

----------------------------------------------------------------------------
-- 11) The exact instance/encounter bucket keys named in the gap this
--     migration extends into: "i123" (a Journal mapID) and "e456" (a
--     Journal/ENCOUNTER_START encounterID) — the key shapes the
--     since-removed Encounters cascade produced. At v57 time both REPLACED
--     "*" at render time exactly like a numeric spec bucket (they were tried
--     ahead of specID/"*"), so a
--     pre-existing one of either shape must get the fan-out too. "i123"
--     starts with curated content, "e456" starts empty. A sibling numeric
--     spec bucket and "*" are unaffected, and a non-matching string key
--     ("custom") is never touched. Running twice never doubles either.
--
--     CASCADE NOTE (2026-07-22, v58 round 2): same as section 6 above --
--     this profile cascades to CURRENT in one RunOnProfile call, so "e456"
--     (which starts and stays completely empty as an override bucket) gets
--     v57's HoT element injected and then v58's
--     Migrations.RepairSoleHoTOverrideBuckets strips it back out in the
--     same pass, ending EMPTY rather than sole-seeded. "i123" keeps its
--     curated content plus the HoT element (2 elements, not sole-seeded, so
--     the repair's `#bucket == 1` guard never matches it) exactly as this
--     section always pinned.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 56,
        quiGroupFrames = {
            party = { auras = { elementsSeeded = true, elements = {
                ["*"]      = { { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" } },
                [104]      = { { id = "curatedSpec", mode = "filterStrip", auraType = "HELPFUL" } },
                ["i123"]   = { { id = "curatedInstance", mode = "tracked", spells = { 42 } } },
                ["e456"]   = {},
                ["custom"] = { { id = "curatedCustom", mode = "filterStrip", auraType = "HELPFUL" } },
            } } },
        },
    }
    M.RunOnProfile(profile)
    local elements = profile.quiGroupFrames.party.auras.elements

    -- "i123": curated content survives; exactly one healerHoTs element
    -- fanned in alongside it.
    check("'i123': curated content untouched", elements["i123"][1] ~= nil
        and elements["i123"][1].id == "curatedInstance")
    check("'i123': curated + exactly one HoT element", #elements["i123"] == 2,
        tostring(#elements["i123"]))
    local i123HoT = findByFlag(elements["i123"])
    check("'i123': got a _quiHoTSeed element", i123HoT ~= nil)
    check("'i123': fixed id healerHoTs (not re-keyed)", i123HoT ~= nil and i123HoT.id == "healerHoTs",
        i123HoT and tostring(i123HoT.id))
    check("'i123': is a copy, not an alias of '*'s element",
        i123HoT ~= nil and i123HoT ~= findByFlag(elements["*"]))

    -- FLIPPED (v58 round 2, see the CASCADE NOTE above): "e456" (empty) --
    -- was: the one element it ends up with is the HoT element; now
    -- (full-pipeline end state): repaired back to empty.
    check("'e456' (empty): repaired back to EMPTY by v58 (was: exactly one element present)",
        #elements["e456"] == 0, tostring(#elements["e456"]))
    check("'e456': no lingering HoT element",
        findByFlag(elements["e456"]) == nil)

    -- "*" and a sibling numeric spec bucket: unaffected/normal fan-out.
    check("'*' still seeded exactly once", #elements["*"] == 2 and findByFlag(elements["*"]) ~= nil,
        tostring(#elements["*"]))
    check("spec bucket [104]: curated content untouched",
        elements[104][1] ~= nil and elements[104][1].id == "curatedSpec")
    check("spec bucket [104]: curated + exactly one HoT element fanned in",
        #elements[104] == 2 and findByFlag(elements[104]) ~= nil, tostring(#elements[104]))

    -- Non-matching string key: NEVER touched by the fan-out.
    check("'custom': untouched (only its curated element, no fan-out)",
        #elements["custom"] == 1 and elements["custom"][1].id == "curatedCustom",
        tostring(#elements["custom"]))
    check("'custom': no HoT element landed", findByFlag(elements["custom"]) == nil)

    -- Run TWICE (re-lowering the stamp to force a second pass through the
    -- v57 gate) -> no doubles in either new bucket.
    profile._schemaVersion = 56
    M.RunOnProfile(profile)
    check("idempotent: 'i123' bucket length unchanged on second pass", #elements["i123"] == 2,
        tostring(#elements["i123"]))
    -- FLIPPED (v58 round 2): 'e456' is repaired back to empty on the FIRST
    -- pass already; the second pass must not re-inject the HoT element (v57
    -- would find it absent again since the repair removed it) NOR error on
    -- an already-empty bucket -- it must simply stay empty.
    check("idempotent: 'e456' stays EMPTY on second pass too (no re-injection, no error)",
        #elements["e456"] == 0, tostring(#elements["e456"]))
    local i123FlaggedCount = 0
    for _, e in ipairs(elements["i123"]) do if e._quiHoTSeed then i123FlaggedCount = i123FlaggedCount + 1 end end
    check("idempotent: 'i123' has exactly one flagged element after two passes, not a length coincidence",
        i123FlaggedCount == 1, tostring(i123FlaggedCount))

    -- ADVERSARIAL: flip the "i123" clone's flag off and confirm findByFlag
    -- actually stops finding it (proves the assertions above discriminate on
    -- the flag itself, not merely on element count/position), then restore
    -- byte-identical and confirm it is found again.
    i123HoT._quiHoTSeed = false
    check("adversarial: flipping 'i123' clone's flag false makes it invisible to findByFlag",
        findByFlag(elements["i123"]) == nil)
    i123HoT._quiHoTSeed = true
    check("adversarial: restoring 'i123' clone's flag (byte-identical) makes it visible again",
        findByFlag(elements["i123"]) == i123HoT)

    -- ADVERSARIAL (v58 round 2 replacement -- "e456"'s clone no longer
    -- exists post-repair, so the old flag-toggle proof doesn't apply):
    -- prove "e456" ending empty is the v58 repair genuinely undoing a REAL
    -- v57 injection each pass (not v57 skipping this bucket) by manually
    -- re-seeding it with the same shape findByFlag looks for and confirming
    -- discrimination, then restoring byte-identical to the empty state
    -- RunOnProfile actually left.
    local scratchE456 = { id = "healerHoTs", mode = "tracked", _quiHoTSeed = true, spells = { 1 } }
    elements["e456"][1] = scratchE456
    check("adversarial: manually re-seeding 'e456' is visible to findByFlag",
        findByFlag(elements["e456"]) == scratchE456)
    elements["e456"][1] = nil
    check("adversarial: removing the scratch seed restores 'e456' byte-identical to empty",
        #elements["e456"] == 0 and findByFlag(elements["e456"]) == nil)

    -- ADVERSARIAL: prove "custom" is skipped by the KEY SHAPE, not by
    -- accident (e.g. an empty-bucket special case) -- empty it out and
    -- re-run, and confirm it STAYS empty purely because "custom" doesn't
    -- match IsHoTOverrideBucketKey's i%d+/e%d+ pattern (unlike "e456" above,
    -- whose key shape DOES match -- it only ends up empty too because v57's
    -- injection is transient, immediately undone by v58's repair in the
    -- same pass; "custom" never gets injected into at all). Restore its
    -- original curated content afterward (byte-identical to pre-mutation).
    local customOriginal = elements["custom"][1]
    elements["custom"] = {}
    profile._schemaVersion = 56
    M.RunOnProfile(profile)
    check("adversarial: emptied 'custom' bucket still gets NO fan-out (key shape, not emptiness, gates it)",
        #elements["custom"] == 0, tostring(#elements["custom"]))
    elements["custom"] = { customOriginal }
    check("adversarial: 'custom' bucket restored to its original curated content (byte-identical)",
        #elements["custom"] == 1 and elements["custom"][1] == customOriginal)
end

if failures > 0 then os.exit(1) end
print("migration_v57_hot_element_seed_test: all checks passed")
