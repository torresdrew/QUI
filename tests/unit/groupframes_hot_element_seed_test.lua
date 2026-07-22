-- tests/unit/groupframes_hot_element_seed_test.lua
-- Run: lua tests/unit/groupframes_hot_element_seed_test.lua
--
-- Task 13 / v57 rework: healer-HoT tracked-element delivery. Engine-rendered
-- tracked slots (AuraSlots) render secret auras C-side; the legacy Lua-side
-- spellID match cannot. Production delivery is now the MODEL DEFAULT
-- (QUI_GroupFrames/groupframes/groupframes_aura_model.lua
-- Model.DefaultStripBucket / Model.HealerHoTElement, reached via
-- core/aura_elements.lua E.EnsureSeeded the FIRST time any surface's
-- buckets latch) plus core/migrations.lua Migrations.SeedHealerHoTElements
-- for profiles whose buckets latched BEFORE v57 -- see section 8 below.
-- AuraDefaults.SeedHealerHoTElements(bucket) (sections 1-7) is no longer
-- called by any production path; it survives ONLY as the tested
-- drift-anchor primitive that independently re-derives the non-secret
-- union from SPEC_AURA_PRESETS, which section 8's drift pin checks the
-- shared canonical source (core/aura_elements.lua E.HealerHoTSpellIDs())
-- against.

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a"); f:close()
    return (data:gsub("\r\n", "\n"))
end

local failures = 0
local function check(name, ok, detail)
    if ok then
        print(("  ok  %s"):format(name))
    else
        failures = failures + 1
        print(("FAIL  %s  %s"):format(name, detail or ""))
    end
end

----------------------------------------------------------------------------
-- 1) Source-guard floor (brief Step 1)
----------------------------------------------------------------------------
local src = readAll("QUI_GroupFrames/groupframes/settings/group_frames_aura_defaults.lua")
assert(src:find("function AuraDefaults.SpecPresets", 1, true),
    "presets must be exported via AuraDefaults.SpecPresets")
assert(src:find("function AuraDefaults.SeedHealerHoTElements", 1, true),
    "seed function required")
assert(src:find("_quiHoTSeed", 1, true), "seed-once flag required")
assert(src:find("NewTrackedElement", 1, true),
    "seed must build a tracked element (engine-rendered slots)")
print("OK groupframes_hot_element_seed_test (source guard)")

----------------------------------------------------------------------------
-- 2) Behavioral: load the real core element model + the real presets file,
--    call SeedHealerHoTElements against stub buckets.
----------------------------------------------------------------------------
local envmod = dofile("tools/_addon_env.lua")
local ns = envmod.LoadCore()
envmod.LoadAddonFile(
    "QUI_GroupFrames/groupframes/settings/group_frames_aura_defaults.lua",
    "QUI_GroupFrames", ns)
local AuraDefaults = ns.QUI_GroupFramesAuraDefaults

check("AuraDefaults loaded", type(AuraDefaults) == "table")
check("SpecPresets exported", type(AuraDefaults.SpecPresets) == "function")
check("SeedHealerHoTElements exported", type(AuraDefaults.SeedHealerHoTElements) == "function")

-- Independent ground truth: walk the REAL shipped presets (not a copy pasted
-- duplicate of the seed function's own loop) and compute the expected
-- non-secret ordered-union spell id set ourselves, so this test actually
-- proves the seed function's dedup/exclusion behavior rather than just
-- mirroring it.
local presets = AuraDefaults.SpecPresets()
check("presets non-empty", type(presets) == "table" and #presets > 0)

local expectedIds, expectedSeen, secretIds = {}, {}, {}
for _, preset in ipairs(presets) do
    for _, s in ipairs(preset.spells) do
        if s.secret then
            secretIds[s.id] = true
        elseif not expectedSeen[s.id] then
            expectedSeen[s.id] = true
            expectedIds[#expectedIds + 1] = s.id
        end
    end
end
-- A spell id used by one spec's non-secret entry and another spec's secret
-- entry (e.g. 10060 Power Infusion is secret on both presets that carry it)
-- must never appear in expectedIds — cross-check for safety.
for _, id in ipairs(expectedIds) do
    check(("expected id %d is not flagged secret anywhere"):format(id), not secretIds[id])
end

----------------------------------------------------------------------------
-- 3) First call: appends exactly one element with the right shape.
----------------------------------------------------------------------------
do
    local bucket = {}
    local ok = AuraDefaults.SeedHealerHoTElements(bucket)
    check("first call returns true", ok == true)
    check("bucket has exactly one element", #bucket == 1, tostring(#bucket))

    local e = bucket[1]
    check("element exists", type(e) == "table")
    if e then
        -- Fixed id (not the session-scoped "e<N>" NewTrackedElement counter
        -- default) — drift-pin parity with core/migrations.lua's
        -- Migrations.SeedHealerHoTElements, same fixed-id precedent as
        -- "defensives" / "encounterBoss".
        check("id == healerHoTs (fixed, not counter-derived)",
            e.id == "healerHoTs", tostring(e.id))
        check("mode == tracked", e.mode == "tracked", tostring(e.mode))
        check("displayType == icon", e.displayType == "icon", tostring(e.displayType))
        check("onlyMine == true", e.onlyMine == true, tostring(e.onlyMine))
        -- maxIcons must stay ABSENT (or <= 0): AuraSlots binds tracked slots
        -- 1:1 per spellID in array order and stops at the cap. A cap here
        -- would strand every id past the first N with no watching slot —
        -- 7 of 8 healer specs would silently get zero icons. onlyMine=true
        -- is the real bound, not a maxIcons cap.
        check("maxIcons is absent/nil (uncapped)", e.maxIcons == nil, tostring(e.maxIcons))
        check("_quiHoTSeed flag set", e._quiHoTSeed == true, tostring(e._quiHoTSeed))
        check("name set from ns.L", e.name ~= nil, "nil name")

        check("spells is a table", type(e.spells) == "table")
        check("spell count matches non-secret union", #e.spells == #expectedIds,
            ("got %d want %d"):format(type(e.spells) == "table" and #e.spells or -1, #expectedIds))

        local gotSet = {}
        for _, id in ipairs(e.spells) do gotSet[id] = true end
        local allPresent, missing = true, nil
        for _, id in ipairs(expectedIds) do
            if not gotSet[id] then allPresent, missing = false, id break end
        end
        check("every expected non-secret id present", allPresent, tostring(missing))

        local noSecrets, leaked = true, nil
        for _, id in ipairs(e.spells) do
            if secretIds[id] then noSecrets, leaked = false, id break end
        end
        check("no secret preset id leaked into spells", noSecrets, tostring(leaked))

        check("no duplicate ids in spells array", (function()
            local seen = {}
            for _, id in ipairs(e.spells) do
                if seen[id] then return false end
                seen[id] = true
            end
            return true
        end)())

        check("ordered union starts with first non-secret preset id",
            e.spells[1] == expectedIds[1], tostring(e.spells[1]))
    end
end

----------------------------------------------------------------------------
-- 4) Second call on the SAME bucket: no-op (seed-once).
----------------------------------------------------------------------------
do
    local bucket = {}
    AuraDefaults.SeedHealerHoTElements(bucket)
    local countAfterFirst = #bucket
    local ok = AuraDefaults.SeedHealerHoTElements(bucket)
    check("second call returns false", ok == false)
    check("bucket length unchanged after second call", #bucket == countAfterFirst,
        tostring(#bucket))
end

----------------------------------------------------------------------------
-- 5) A bucket that already carries a _quiHoTSeed element (regardless of
--    position) is left alone too.
----------------------------------------------------------------------------
do
    local bucket = {
        { id = "debuffs", mode = "filterStrip" },
        { id = "preexisting", mode = "tracked", _quiHoTSeed = true, spells = { 1 } },
        { id = "buffs", mode = "filterStrip" },
    }
    local ok = AuraDefaults.SeedHealerHoTElements(bucket)
    check("pre-seeded bucket: returns false", ok == false)
    check("pre-seeded bucket: length unchanged", #bucket == 3, tostring(#bucket))
end

----------------------------------------------------------------------------
-- 6) Defensive: non-table bucket.
----------------------------------------------------------------------------
do
    check("nil bucket returns false", AuraDefaults.SeedHealerHoTElements(nil) == false)
    check("non-table bucket returns false", AuraDefaults.SeedHealerHoTElements("nope") == false)
end

----------------------------------------------------------------------------
-- 7) Sync harness: drive the REAL core/aura_slots.lua S.Sync against the
--    seeded 42-spell element and prove every spec's ids get a real watching
--    slot, not just the first 4 (the maxIcons=4 bug this closes: AuraSlots
--    binds slots 1:1 per spellID in array order and stops at any cap, so a
--    capped element silently drops every id past the cap). Mirrors
--    tests/unit/aura_slots_never_secret_exemption_test.lua's MakeContainer/
--    MakeFrame stub + LiveAssistProbe pattern.
----------------------------------------------------------------------------
do
    _G.InCombatLockdown = function() return false end
    ns.Addon = ns.Addon or {}
    ns.Addon.AuraSkin = ns.Addon.AuraSkin or { WireButton = function() end }

    local S = assert(loadfile("core/aura_slots.lua"))("QUI", ns)

    local function MakeFrame()
        return {
            SetSize = function() end,
            ClearAllPoints = function() end,
            SetPoint = function() end,
            Icon = { SetAlpha = function() end },
        }
    end
    local function MakeContainer()
        local c = { _filterCalls = {}, _stringCalls = {}, _createdKeys = {}, _birthFilters = {} }
        c.SetAuraSlotFilterString = function(self, key, base) c._stringCalls[key] = base end
        c.SetAuraSlotCandidateFilters = function(self, key, filters) c._filterCalls[key] = filters end
        c.AddAuraSlot = function(self, key, base, opts)
            c._createdKeys[#c._createdKeys + 1] = key
            c._birthFilters[key] = opts and opts.candidateFilters
            local frame = MakeFrame()
            if opts and type(opts.initializeFrame) == "function" then
                opts.initializeFrame(frame)
            end
            return frame
        end
        return c
    end

    -- LiveAssistProbe = TRUE (fully trusted party unit): enforceable=true,
    -- so parkAll stays false and every slot gets a REAL per-spell filter —
    -- the quadrant where the maxIcons truncation bug would have hidden
    -- everything past index 4.
    _G.UnitIsConnected = function() return true end
    _G.UnitIsDeadOrGhost = function() return false end
    _G.UnitCanAssist = function() return true end
    _G.UnitIsVisible = function() return true end
    _G.UnitPhaseReason = function() return nil end

    local bucket = {}
    AuraDefaults.SeedHealerHoTElements(bucket)
    local element = bucket[1]
    check("harness: seeded element present", type(element) == "table")

    if element then
        local container = MakeContainer()
        container.GetUnit = function() return "party1" end

        local complete = S.Sync(container, element, true)
        check("harness: Sync completes (OOC, allowCreate)", complete == true)

        local pool = container._quiSlots
        local spellCount = #element.spells
        check("harness: pool has one slot per spell (uncapped)",
            pool ~= nil and #pool == spellCount,
            ("pool=%s spells=%d"):format(pool and tostring(#pool) or "nil", spellCount))
        check("harness: slot count == 42", spellCount == 42, tostring(spellCount))

        -- Slots past index 4 exist and are NOT parked — direct refutation of
        -- the maxIcons=4 truncation bug.
        for _, idx in ipairs({ 5, 8, 20, 42 }) do
            local slot = pool and pool[idx]
            check(("harness: slot %d exists"):format(idx), slot ~= nil)
            check(("harness: slot %d is not parked"):format(idx), slot and slot.parked == false,
                slot and tostring(slot.parked))
        end

        -- A spell from a NON-first spec (61295 Riptide, Restoration Shaman —
        -- Restoration Druid is first in SPEC_AURA_PRESETS) must get a REAL
        -- per-spell filter, found dynamically by its actual array position
        -- (not a hardcoded index, so this stays correct if preset ordering
        -- ever changes upstream).
        local riptideIndex
        for i, id in ipairs(element.spells) do
            if id == 61295 then riptideIndex = i break end
        end
        check("harness: 61295 (Riptide, Resto Shaman) is in the seeded spells",
            riptideIndex ~= nil)
        if riptideIndex then
            check("harness: 61295 is past index 4 (would have been truncated)",
                riptideIndex > 4, tostring(riptideIndex))
            local key = "t" .. riptideIndex
            local filter = container._birthFilters[key]
            check("harness: 61295's slot got a REAL per-spell filter (not parked)",
                filter ~= nil and filter.maxDuration == nil
                and filter.includeSpellIDs and filter.includeSpellIDs[61295] == true,
                filter and ("maxDuration=" .. tostring(filter.maxDuration)) or "nil filter")
        end
    end

    _G.UnitIsConnected = nil
    _G.UnitIsDeadOrGhost = nil
    _G.UnitCanAssist = nil
    _G.UnitIsVisible = nil
    _G.UnitPhaseReason = nil
end

----------------------------------------------------------------------------
-- 8) MODEL-DEFAULT delivery (v57 rework): the previous round's
--    RenderAurasSection latch-path call is GONE. Delivery is now
--    QUI_GroupFrames/groupframes/groupframes_aura_model.lua
--    Model.DefaultStripBucket appending Model.HealerHoTElement()
--    unconditionally, reached via core/aura_elements.lua E.EnsureSeeded on
--    ANY surface's first bucket latch (party/raid runtime render, editmode,
--    preview, the Options Auras section, the setup wizard -- not just
--    Options). This drives the REAL Model.EnsureSeeded and the REAL
--    Migrations.RunOnProfile (both already loaded by LoadCore() above /
--    the LoadAddonFile below) -- no reimplementation of either's logic.
----------------------------------------------------------------------------
do
    envmod.LoadAddonFile(
        "QUI_GroupFrames/groupframes/groupframes_aura_model.lua",
        "QUI_GroupFrames", ns)
    local Model = ns.QUI_GroupFramesAuraModel
    local Migrations = ns.Migrations
    local E = ns.AuraElements

    check("Model loaded", type(Model) == "table")
    check("Migrations loaded", type(Migrations) == "table")

    local function CountHoT(bucket)
        local n = 0
        for _, e in ipairs(bucket or {}) do
            if type(e) == "table" and e._quiHoTSeed then n = n + 1 end
        end
        return n
    end
    local function findHoT(bucket)
        for _, e in ipairs(bucket or {}) do
            if type(e) == "table" and e._quiHoTSeed then return e end
        end
    end

    ----------------------------------------------------------------------
    -- 8a) FRESH LATCH: an unlatched store, latched via the real
    -- Model.EnsureSeeded (the exact call every production caller makes --
    -- groupframes_auras.lua, groupframes_editmode.lua, the preview driver,
    -- group_frames_schema.lua's own EnsureSeeded call), gets exactly one
    -- _quiHoTSeed element with the full expected shape.
    ----------------------------------------------------------------------
    local auras = {}
    Model.EnsureSeeded(auras, "party")
    local bucket = auras.elements and auras.elements["*"]
    check("fresh latch: bucket exists", type(bucket) == "table", tostring(bucket))
    check("fresh latch: exactly one HoT element", bucket and CountHoT(bucket) == 1,
        tostring(bucket and CountHoT(bucket)))

    local e = bucket and findHoT(bucket)
    check("fresh latch: element found", e ~= nil)
    if e then
        check("fresh latch: id == healerHoTs", e.id == "healerHoTs", tostring(e.id))
        check("fresh latch: mode == tracked", e.mode == "tracked", tostring(e.mode))
        check("fresh latch: displayType == icon", e.displayType == "icon", tostring(e.displayType))
        check("fresh latch: onlyMine == true", e.onlyMine == true, tostring(e.onlyMine))
        check("fresh latch: maxIcons absent (uncapped)", e.maxIcons == nil, tostring(e.maxIcons))
        check("fresh latch: 42 spells", type(e.spells) == "table" and #e.spells == 42,
            tostring(e.spells and #e.spells))

        -- ADVERSARIAL: prove CountHoT actually discriminates on the flag
        -- rather than merely on element presence -- flip it false, recheck,
        -- restore byte-identical, recheck again.
        e._quiHoTSeed = false
        check("adversarial: CountHoT drops to 0 when the flag is flipped false",
            CountHoT(bucket) == 0, tostring(CountHoT(bucket)))
        e._quiHoTSeed = true
        check("adversarial: restoring the flag brings the count back to 1 (byte-identical restore)",
            CountHoT(bucket) == 1, tostring(CountHoT(bucket)))
    end

    ----------------------------------------------------------------------
    -- 8b) SEED-ONCE / DELETION PERSISTENCE: latch once, delete the
    -- element, re-run the SAME latch call -> auras.elementsSeeded
    -- short-circuits E.EnsureSeeded, nothing comes back. Then run the REAL
    -- Migrations.RunOnProfile against a profile already stamped >= 57
    -- (the version this element shipped in) -> still nothing, because the
    -- migration's own `stored < 57` gate skips the step entirely.
    ----------------------------------------------------------------------
    do
        local a2 = {}
        Model.EnsureSeeded(a2, "party")
        local b2 = a2.elements["*"]
        for i = #b2, 1, -1 do
            if b2[i]._quiHoTSeed then table.remove(b2, i) end
        end
        check("deletion: element actually removed", CountHoT(b2) == 0, tostring(CountHoT(b2)))

        Model.EnsureSeeded(a2, "party")  -- re-run the identical latch call
        check("seed-once: re-latching does NOT resurrect the deleted element",
            CountHoT(a2.elements["*"]) == 0, tostring(CountHoT(a2.elements["*"])))

        local profile = {
            _schemaVersion = 57,
            quiGroupFrames = { party = { auras = a2 } },
        }
        Migrations.RunOnProfile(profile)
        check("seed-once: Migrations.RunOnProfile (already stamped >= 57) does not resurrect it",
            CountHoT(profile.quiGroupFrames.party.auras.elements["*"]) == 0,
            tostring(CountHoT(profile.quiGroupFrames.party.auras.elements["*"])))

        -- ADVERSARIAL: confirm the surviving bucket still has its original
        -- (non-HoT) strips untouched -- the deletion above didn't collapse
        -- the WHOLE bucket, only the one flagged element.
        check("adversarial: original strips (debuffs/buffs/defensives) survive the deletion",
            #a2.elements["*"] == 3, tostring(#a2.elements["*"]))
    end

    ----------------------------------------------------------------------
    -- 8c) BOTH ORDERS, NO DOUBLE.
    ----------------------------------------------------------------------
    do
        -- latch-then-migration
        local a3 = {}
        Model.EnsureSeeded(a3, "raid")
        local profile = { _schemaVersion = 56, quiGroupFrames = { raid = { auras = a3 } } }
        Migrations.RunOnProfile(profile)
        check("latch-then-migration: exactly one HoT element",
            CountHoT(profile.quiGroupFrames.raid.auras.elements["*"]) == 1,
            tostring(CountHoT(profile.quiGroupFrames.raid.auras.elements["*"])))
    end
    do
        -- migration-then-latch: surface already latched (no HoT element
        -- yet, the migration's actual target shape), migration seeds it,
        -- then re-latching afterward must stay a no-op.
        local profile = {
            _schemaVersion = 56,
            quiGroupFrames = { raid = { auras = {
                elementsSeeded = true,
                elements = { ["*"] = {
                    { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" },
                    { id = "buffs", mode = "filterStrip", auraType = "HELPFUL" },
                } },
            } } },
        }
        Migrations.RunOnProfile(profile)
        check("migration-then-latch: migration seeded it first",
            CountHoT(profile.quiGroupFrames.raid.auras.elements["*"]) == 1,
            tostring(CountHoT(profile.quiGroupFrames.raid.auras.elements["*"])))
        Model.EnsureSeeded(profile.quiGroupFrames.raid.auras, "raid")
        check("migration-then-latch: re-latching after the migration stays exactly one",
            CountHoT(profile.quiGroupFrames.raid.auras.elements["*"]) == 1,
            tostring(CountHoT(profile.quiGroupFrames.raid.auras.elements["*"])))
    end

    ----------------------------------------------------------------------
    -- 8d) DRIFT PIN -- single-source proof. Model.HealerHoTElement() (the
    -- runtime default) and Migrations.SeedHealerHoTElements' injected
    -- element (the legacy-latch migration) both trace to the exact same
    -- core/aura_elements.lua E.HealerHoTSpellIDs() call -- prove VALUE
    -- identity (set AND order), not just "both happen to be 42 long". Then
    -- close the loop: pin that canonical source against the independent,
    -- human-maintained ground truth (AuraDefaults' SPEC_AURA_PRESETS-derived
    -- union) so an edit to the presets can never silently drift from what
    -- actually ships.
    ----------------------------------------------------------------------
    do
        check("drift pin: E.HealerHoTSpellIDs exported", type(E.HealerHoTSpellIDs) == "function")
        local modelSpells = Model.HealerHoTElement().spells

        local profile = {
            _schemaVersion = 56,
            quiGroupFrames = { party = {
                auras = { elementsSeeded = true, elements = { ["*"] = {
                    { id = "debuffs", mode = "filterStrip", auraType = "HARMFUL" },
                } } },
            } },
        }
        Migrations.RunOnProfile(profile)
        local migrationElement = findHoT(profile.quiGroupFrames.party.auras.elements["*"])
        check("drift pin: migration produced a HoT element", migrationElement ~= nil)
        local migrationSpells = migrationElement and migrationElement.spells or {}

        check("drift pin: model and migration spell counts match",
            #modelSpells == #migrationSpells,
            ("model=%d migration=%d"):format(#modelSpells, #migrationSpells))
        local sameOrder, atIndex = true, nil
        for i = 1, math.max(#modelSpells, #migrationSpells) do
            if modelSpells[i] ~= migrationSpells[i] then sameOrder, atIndex = false, i break end
        end
        check("drift pin: model and migration spells are order-identical (single source)",
            sameOrder, atIndex and ("index " .. atIndex) or nil)

        -- Canonical source vs. the independent AuraDefaults/preset ground truth.
        local canonical = E.HealerHoTSpellIDs()
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
        check("drift pin: canonical source count == live preset-derived count",
            #canonical == #liveIds, ("canonical=%d live=%d"):format(#canonical, #liveIds))
        local canonSameOrder, canonAt = true, nil
        for i = 1, math.max(#canonical, #liveIds) do
            if canonical[i] ~= liveIds[i] then canonSameOrder, canonAt = false, i break end
        end
        check("drift pin: canonical source order matches live preset-derived order",
            canonSameOrder, canonAt and ("index " .. canonAt) or nil)
        local noSecrets, leaked = true, nil
        for _, id in ipairs(canonical) do
            if secretIds[id] then noSecrets, leaked = false, id break end
        end
        check("drift pin: no secret preset id present in the canonical source", noSecrets, tostring(leaked))

        -- ADVERSARIAL: HealerHoTSpellIDs() must hand out a FRESH copy every
        -- call -- mutate one returned array and prove a second independent
        -- call is unaffected (the shared source table was never touched).
        canonical[1] = -999
        local secondCall = E.HealerHoTSpellIDs()
        check("adversarial: mutating a returned copy does not corrupt the canonical source",
            secondCall[1] ~= -999, tostring(secondCall[1]))
        check("adversarial: the second independent call still matches the live union at index 1",
            secondCall[1] == liveIds[1], ("got=%s want=%s"):format(tostring(secondCall[1]), tostring(liveIds[1])))
    end
end

if failures > 0 then
    error(("%d check(s) failed"):format(failures))
end
print("OK groupframes_hot_element_seed_test")
