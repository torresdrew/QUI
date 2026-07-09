-- tests/unit/aura_elements_model_test.lua
-- Run: lua5.1 tests/unit/aura_elements_model_test.lua
-- REAL unit tests (core/aura_elements.lua is pure Lua — no frame APIs).
local ns = dofile("tools/_addon_env.lua").LoadCore()
local E = ns.AuraElements

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

-- Constructors -----------------------------------------------------------
do
    local e = E.NewFilterStripElement("HARMFUL")
    check("strip: mode/auraType", e.mode == "filterStrip" and e.auraType == "HARMFUL")
    check("strip: HARMFUL default classifications lack raidInCombat (HELPFUL-only token)",
        e.classifications.raid == true and e.classifications.raidInCombat == nil)
    check("strip: new sort fields", e.sortRule == "INDEX" and e.sortReverse == false)
    check("strip: rightClickCancel defaults true", e.rightClickCancel == true)
    check("strip: duration sub-table", type(e.duration) == "table" and e.duration.show == true
        and e.duration.fontSize == 9 and e.duration.anchor == "CENTER")
    check("strip: stack sub-table", type(e.stack) == "table" and e.stack.show == true
        and e.stack.anchor == "BOTTOMRIGHT")
    local t = E.NewTrackedElement({ 12345 }, "bar")
    check("tracked: auraType field present (slots need polarity)", t.auraType == "HELPFUL")
    check("tracked: displayType honored", t.displayType == "bar")
    check("tracked: bar dims seeded", t.bar and t.bar.thickness == 12 and t.bar.length == 48)
    local m = E.NewMissingRaidBuffElement()
    check("mrb: mode", m.mode == "missingRaidBuff")
end

-- Validate ---------------------------------------------------------------
do
    check("validate: strip needs polarity", E.Validate({ mode = "filterStrip", auraType = "HELPFUL" }) == true)
    check("validate: strip rejects bad polarity", E.Validate({ mode = "filterStrip", auraType = "ALL" }) == false)
    check("validate: tracked needs spells", E.Validate({ mode = "tracked", displayType = "icon", spells = {} }) == false)
    check("validate: tracked ok", E.Validate({ mode = "tracked", displayType = "square", spells = { 1 } }) == true)
    check("validate: unknown mode rejected", E.Validate({ mode = "wat" }) == false)
    check("validate: non-table rejected", E.Validate(nil) == false)
end

-- CompileFilters ---------------------------------------------------------
do
    local e = E.NewFilterStripElement("HELPFUL")
    e.filterMode = "classify"
    e.classifications = { raid = true, raidInCombat = true, cancelable = true }
    local fs = E.CompileFilters(e)
    table.sort(fs)
    check("compile: helpful classifications", table.concat(fs, ",") ==
        "HELPFUL|CANCELABLE,HELPFUL|RAID,HELPFUL|RAID_IN_COMBAT", table.concat(fs, ","))

    local d = E.NewFilterStripElement("HARMFUL")
    d.filterMode = "classify"
    d.classifications = { raid = true, dispellable = true, crowdControl = true }
    local dfs = E.CompileFilters(d)
    table.sort(dfs)
    check("compile: harmful never emits RAID_IN_COMBAT (C API hard-errors on that combo)",
        table.concat(dfs, ",") == "HARMFUL|CROWD_CONTROL,HARMFUL|RAID,HARMFUL|RAID_PLAYER_DISPELLABLE",
        table.concat(dfs, ","))

    local off = E.NewFilterStripElement("HELPFUL")
    off.filterMode = "off"
    check("compile: off mode → empty (caller uses base polarity)", #E.CompileFilters(off) == 0)

    -- "flags" = the legacy buffborders/UF AND-composition: enabled raw tokens
    -- joined onto ONE string, sorted for determinism.
    local flags = E.NewFilterStripElement("HELPFUL")
    flags.filterMode = "flags"
    flags.filterFlags = { PLAYER = true, CANCELABLE = true, RAID = false }
    local ffs = E.CompileFilters(flags)
    check("compile: flags mode AND-composes one string",
        #ffs == 1 and ffs[1] == "HELPFUL|CANCELABLE|PLAYER", tostring(ffs[1]))
    flags.filterFlags = {}
    check("compile: flags mode with nothing enabled → empty (bare polarity fallback)",
        #E.CompileFilters(flags) == 0)

    -- Out-of-set tokens are DROPPED, never emitted: the container's
    -- AddAuraGroup asserts AuraUtil.IsValidFilterString, and the C-side
    -- GetUnitAuras probe doesn't reject unknown components (live PTR error
    -- "Unknown aura filter component: 'modifiers'" from a corrupted store).
    flags.filterFlags = { PLAYER = true, modifiers = true }
    local dropped = E.CompileFilters(flags)
    check("compile: flags mode drops out-of-set tokens",
        #dropped == 1 and dropped[1] == "HELPFUL|PLAYER", tostring(dropped[1]))
    flags.filterFlags = { modifiers = true, exclusive = true }
    check("compile: flags mode with ONLY out-of-set tokens → empty (bare polarity fallback)",
        #E.CompileFilters(flags) == 0)

    -- Legacy UF fallback: helpful/harmful master toggles stored as raid/raidInCombat.
    local legacy = E.NewFilterStripElement("HELPFUL")
    legacy.filterMode = "classify"
    legacy.classifications = { helpful = true }
    local lfs = E.CompileFilters(legacy)
    table.sort(lfs)
    check("compile: 'helpful' master key expands to RAID + RAID_IN_COMBAT",
        table.concat(lfs, ",") == "HELPFUL|RAID,HELPFUL|RAID_IN_COMBAT", table.concat(lfs, ","))

    -- Split keys stay INDEPENDENT of the master alias: {raid=true} alone must
    -- NOT promote to RAID_IN_COMBAT (the merged map carries split keys, so no
    -- master fallback read — regression from the Task 2 review).
    local split = E.NewFilterStripElement("HELPFUL")
    split.filterMode = "classify"
    split.classifications = { raid = true }
    local sfs = E.CompileFilters(split)
    check("compile: {raid=true} alone emits ONLY HELPFUL|RAID",
        #sfs == 1 and sfs[1] == "HELPFUL|RAID", table.concat(sfs, ","))
end

-- CompileCandidateFilters --------------------------------------------------
do
    local e = E.NewFilterStripElement("HELPFUL")
    check("candidates: default nil (no restrictions)", E.CompileCandidateFilters(e) == nil)

    e.onlyMine = true
    local cf = E.CompileCandidateFilters(e)
    check("candidates: onlyMine → isFromPlayerOrPlayerPet", cf and cf.isFromPlayerOrPlayerPet == true)

    e.hidePermanent = true
    cf = E.CompileCandidateFilters(e)
    check("candidates: hidePermanent → maxDuration cap", cf and cf.maxDuration == 999999)

    e.filterMode = "whitelist"
    e.whitelist = { [17] = true, [42] = true }
    cf = E.CompileCandidateFilters(e)
    check("candidates: whitelist → includeSpellIDs map", cf and cf.includeSpellIDs
        and cf.includeSpellIDs[17] == true and cf.includeSpellIDs[42] == true)

    local b = E.NewFilterStripElement("HARMFUL")
    b.blacklist = { [99] = true }
    cf = E.CompileCandidateFilters(b)
    check("candidates: blacklist → excludeSpellIDs map", cf and cf.excludeSpellIDs and cf.excludeSpellIDs[99] == true)

    -- filterMode "off" must NOT emit includeSpellIDs even if a stale whitelist table exists.
    local off = E.NewFilterStripElement("HELPFUL")
    off.filterMode = "off"
    off.whitelist = { [5] = true }
    cf = E.CompileCandidateFilters(off)
    check("candidates: off mode ignores whitelist", cf == nil or cf.includeSpellIDs == nil)
end

-- NormalizeElement (legacy flat duration fields → duration{}) --------------
do
    local legacy = {
        id = "debuffs", mode = "filterStrip", auraType = "HARMFUL", enabled = true,
        showDurationText = true, durationFontSize = 9, durationAnchor = "BOTTOM",
        durationOffsetX = 0, durationOffsetY = -6, durationColor = { 1, 1, 1, 1 },
        durationUseTimeColor = true, showDurationColor = true, showExpiringPulse = true,
    }
    E.NormalizeElement(legacy)
    check("normalize: duration{} built from flat fields", legacy.duration
        and legacy.duration.show == true and legacy.duration.fontSize == 9
        and legacy.duration.anchor == "BOTTOM" and legacy.duration.offsetY == -6)
    check("normalize: flat duration fields pruned", legacy.showDurationText == nil
        and legacy.durationFontSize == nil and legacy.durationAnchor == nil
        and legacy.durationUseTimeColor == nil and legacy.showExpiringPulse == nil)
    check("normalize: stack{} seeded when absent", legacy.stack and legacy.stack.anchor == "BOTTOMRIGHT")
    check("normalize: idempotent", (function()
        E.NormalizeElement(legacy)
        return legacy.duration.fontSize == 9
    end)())
end

-- EnsureSeeded / buckets ---------------------------------------------------
do
    local function defaultBucket()
        return { { id = "seeded", mode = "filterStrip", auraType = "HARMFUL", enabled = true } }
    end
    local auras = {}
    E.EnsureSeeded(auras, defaultBucket)
    check("seed: '*' bucket created once", auras.elements and auras.elements["*"]
        and auras.elements["*"][1].id == "seeded")
    check("seed: flag set", auras.elementsSeeded == true)
    auras.elements["*"] = {}
    E.EnsureSeeded(auras, defaultBucket)
    check("seed: emptied bucket stays empty (flag, not presence)", #auras.elements["*"] == 0)

    local flat = { elementsSeeded = true, elements = { ["*"] = {
        { mode = "filterStrip", auraType = "HELPFUL", enabled = true },   -- no id
        { id = "dup", mode = "filterStrip", auraType = "HELPFUL" },
        { id = "dup", mode = "filterStrip", auraType = "HARMFUL" },
    } } }
    E.EnsureSeeded(flat, defaultBucket)
    local seen = {}
    local allUnique = true
    for _, e in ipairs(flat.elements["*"]) do
        if not e.id or seen[e.id] then allUnique = false end
        seen[e.id or ""] = true
    end
    check("seed: id backfill + dedupe", allUnique)
end

-- ActiveElementsForSpec ----------------------------------------------------
do
    local auras = { elements = {
        ["*"] = { { id = "a", enabled = true }, { id = "b", enabled = false } },
        [268] = { { id = "c", enabled = true } },
    } }
    local base = E.ActiveElementsForSpec(auras, nil)
    check("active: '*' bucket, disabled filtered", #base == 1 and base[1].id == "a")
    local spec = E.ActiveElementsForSpec(auras, 268)
    check("active: spec bucket OVERRIDES (never union)", #spec == 1 and spec[1].id == "c")
    local scratch = {}
    E.ActiveElementsForSpec(auras, nil, scratch)
    check("active: reusable out-array", #scratch == 1 and scratch[1].id == "a")
end

-- Spec-override engine (load-bearing for GF; deep-copy contract) ------------
do
    local auras = { elements = { ["*"] = {
        { id = "a", mode = "filterStrip", auraType = "HELPFUL", enabled = true,
          classifications = { raid = true }, whitelist = { [7] = true } },
    } } }
    E.EnableSpecOverride(auras, 268)
    check("override: bucket created", type(auras.elements[268]) == "table" and #auras.elements[268] == 1)
    check("override: HasSpecOverride true", E.HasSpecOverride(auras.elements, 268) == true)
    check("override: '*' key never overrides", E.HasSpecOverride(auras.elements, "*") == false)
    local src, copy = auras.elements["*"][1], auras.elements[268][1]
    check("override: fresh element id", copy.id ~= src.id)
    check("override: DEEP copy — no table aliasing",
        copy.classifications ~= src.classifications and copy.whitelist ~= src.whitelist)
    copy.classifications.raid = false
    check("override: mutating the copy leaves '*' intact", src.classifications.raid == true)
    E.EnableSpecOverride(auras, 268)
    check("override: enable is idempotent (no clobber)", auras.elements[268][1] == copy)
    E.DisableSpecOverride(auras, 268)
    check("override: disable deletes the bucket (inherits '*')", auras.elements[268] == nil)
    E.DisableSpecOverride(auras, "*")
    check("override: disable('*') is a guarded no-op", auras.elements["*"] ~= nil)
end

-- EffectiveOnlyMine: per-spell override beats the element default, including
-- an explicit false (the `~= nil` check, not truthiness, is the contract).
do
    local e = { onlyMine = true, onlyMineSpells = { [10] = false, [20] = true } }
    check("onlyMine: explicit per-spell FALSE overrides element true", E.EffectiveOnlyMine(e, 10) == false)
    check("onlyMine: per-spell true honored", E.EffectiveOnlyMine(e, 20) == true)
    check("onlyMine: unlisted spell falls back to element", E.EffectiveOnlyMine(e, 30) == true)
    check("onlyMine: no override table falls back", E.EffectiveOnlyMine({ onlyMine = false }, 10) == false)
end

-- Flags mode polarity guard: HELPFUL-only tokens never reach a HARMFUL string
-- (HARMFUL|RAID_IN_COMBAT hard-errors in C_UnitAuras.GetUnitAuras).
do
    local d = E.NewFilterStripElement("HARMFUL")
    d.filterMode = "flags"
    d.filterFlags = { PLAYER = true, RAID_IN_COMBAT = true }
    local fs = E.CompileFilters(d)
    check("flags: HARMFUL drops HELPFUL-only tokens", #fs == 1 and fs[1] == "HARMFUL|PLAYER", tostring(fs[1]))
    d.filterFlags = { RAID_IN_COMBAT = true }
    check("flags: HARMFUL with only invalid tokens → empty (bare polarity fallback)",
        #E.CompileFilters(d) == 0)
    local b = E.NewFilterStripElement("HELPFUL")
    b.filterMode = "flags"
    b.filterFlags = { RAID_IN_COMBAT = true }
    check("flags: HELPFUL keeps RAID_IN_COMBAT", E.CompileFilters(b)[1] == "HELPFUL|RAID_IN_COMBAT")
end

-- NormalizeElement edge branches --------------------------------------------
do
    local hidden = { mode = "filterStrip", auraType = "HELPFUL", showDurationText = false }
    E.NormalizeElement(hidden)
    check("normalize: showDurationText=false → duration.show false", hidden.duration.show == false)
    -- Legacy GF editor spelling: without this heal, a classified strip
    -- compiles {} → bare polarity → shows EVERYTHING (silent regression).
    local legacyMode = { mode = "filterStrip", auraType = "HARMFUL",
                         filterMode = "classification", classifications = { raid = true } }
    E.NormalizeElement(legacyMode)
    check("normalize: legacy 'classification' → canonical 'classify'", legacyMode.filterMode == "classify")
    check("normalize: healed strip still compiles its classifications",
        E.CompileFilters(legacyMode)[1] == "HARMFUL|RAID")
    local tracked = { mode = "tracked", displayType = "icon", spells = { 1 } }
    E.NormalizeElement(tracked)
    check("normalize: tracked gains auraType default", tracked.auraType == "HELPFUL")
end

-- EnsureSeeded advances idCounter past persisted eN ids (fresh ids never collide)
do
    local auras = { elementsSeeded = true, elements = { ["*"] = {
        { id = "e9000", mode = "filterStrip", auraType = "HELPFUL" },
    } } }
    E.EnsureSeeded(auras, nil)
    local fresh = E.NewFilterStripElement("HELPFUL")
    check("seed: idCounter advanced past persisted eN ids",
        tonumber(fresh.id:match("^e(%d+)$")) > 9000, tostring(fresh.id))
end

print("aura_elements_model_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
