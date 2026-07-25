-- tests/unit/migration_v51_filterflags_repair_test.lua
-- Run: lua5.1 tests/unit/migration_v51_filterflags_repair_test.lua
--
-- v51 = Migrations.RepairAuraFilterFlags. The shipped v50 UF seed misread the
-- NESTED legacy filter shape ({ modifiers = {TOKEN=bool}, exclusive =
-- "TOKEN"|nil }) by iterating the OUTER table, stamping the literal container
-- keys as filter tokens: filterFlags = { modifiers = true, exclusive = true }.
-- CompileFilters then emitted "HARMFUL|modifiers", which passes the C-side
-- GetUnitAuras probe but fails the container's AuraUtil.IsValidFilterString
-- assert inside AddAuraGroup (live PTR error: "Unknown aura filter component:
-- 'modifiers'"). The legacy source table was pruned after the seed, so v51
-- can only sanitize: strip out-of-set tokens, revert empty flags-mode
-- elements to bare polarity ("off").

local ns = dofile("tools/_addon_env.lua").LoadCore()
local M  = ns.Migrations
local E  = ns.AuraElements

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

local function stripElement(auraType, filterMode, filterFlags)
    local e = E.NewFilterStripElement(auraType)
    if filterMode then e.filterMode = filterMode end
    if filterFlags then e.filterFlags = filterFlags end
    return e
end

----------------------------------------------------------------------------
-- 1) Corrupted store (what the shipped v50 produced): literal container keys
--    as tokens. Repair strips them; the emptied element reverts to "off".
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 50,
        quiUnitFrames = {
            player = {
                auras = {
                    elementsSeeded = true,
                    elements = { ["*"] = {
                        stripElement("HARMFUL", "flags", { modifiers = true }),
                        stripElement("HELPFUL", "flags", { modifiers = true, exclusive = true }),
                    } },
                },
            },
        },
    }
    M.RunOnProfile(profile)

    local bucket = profile.quiUnitFrames.player.auras.elements["*"]
    local debuff, buff = bucket[1], bucket[2]
    check("corrupt debuff 'modifiers' token stripped", debuff.filterFlags.modifiers == nil, "still present")
    check("corrupt debuff reverts to off", debuff.filterMode == "off", tostring(debuff.filterMode))
    check("corrupt debuff compiles to empty (bare polarity)", #E.CompileFilters(debuff) == 0,
        table.concat(E.CompileFilters(debuff), " , "))
    check("corrupt buff 'exclusive' token stripped", buff.filterFlags.exclusive == nil, "still present")
    check("corrupt buff reverts to off", buff.filterMode == "off", tostring(buff.filterMode))
    check("stamped to current (59)", profile._schemaVersion == 59, tostring(profile._schemaVersion))
end

----------------------------------------------------------------------------
-- 2) Mixed flags: valid tokens survive, invalid ones are stripped, and the
--    element STAYS in flags mode.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 50,
        quiUnitFrames = {
            target = {
                auras = {
                    elementsSeeded = true,
                    elements = { ["*"] = {
                        stripElement("HARMFUL", "flags", { PLAYER = true, modifiers = true }),
                    } },
                },
            },
        },
    }
    M.RunOnProfile(profile)

    local e = profile.quiUnitFrames.target.auras.elements["*"][1]
    check("mixed: PLAYER survives", e.filterFlags.PLAYER == true, "PLAYER lost")
    check("mixed: 'modifiers' stripped", e.filterFlags.modifiers == nil, "still present")
    check("mixed: stays flags mode", e.filterMode == "flags", tostring(e.filterMode))
    local fs = E.CompileFilters(e)
    check("mixed: compiles to HARMFUL|PLAYER", #fs == 1 and fs[1] == "HARMFUL|PLAYER", tostring(fs[1]))
end

----------------------------------------------------------------------------
-- 3) Non-flags elements and other stores untouched; per-spec buckets walked.
----------------------------------------------------------------------------
do
    local classifyElem = stripElement("HELPFUL", "classify")
    classifyElem.classifications = { raid = true }
    local profile = {
        _schemaVersion = 50,
        quiUnitFrames = {
            focus = {
                auras = {
                    elementsSeeded = true,
                    elements = {
                        ["*"] = { classifyElem },
                        [250] = { stripElement("HARMFUL", "flags", { exclusive = true }) },
                    },
                },
            },
        },
        buffBorders = { buffAuras = { elementsSeeded = true, elements = { ["*"] = {} } } },
    }
    M.RunOnProfile(profile)

    local fa = profile.quiUnitFrames.focus.auras
    check("classify element untouched", fa.elements["*"][1].filterMode == "classify",
        tostring(fa.elements["*"][1].filterMode))
    check("classify classifications preserved", fa.elements["*"][1].classifications.raid == true, "raid lost")
    local spec = fa.elements[250][1]
    check("per-spec bucket repaired", spec.filterFlags.exclusive == nil and spec.filterMode == "off",
        tostring(spec.filterMode))
    check("stamped to current (59)", profile._schemaVersion == 59, tostring(profile._schemaVersion))
end

----------------------------------------------------------------------------
-- 4) Alpha stamp (51) re-enters the v58 squash: the repair is a
--    content-idempotent step (NOT stamp-guarded), so an out-of-set token
--    still carried at a mid-chain alpha stamp IS stripped on the way to 58
--    (out-of-set tokens are corruption that hard-errors the container's
--    IsValidFilterString — healing them is the point). At 58 the gate is
--    closed: a token hand-set after the squash is not re-stripped.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 51,
        quiUnitFrames = {
            player = {
                auras = {
                    elementsSeeded = true,
                    elements = { ["*"] = { stripElement("HARMFUL", "flags", { modifiers = true }) } },
                },
            },
        },
    }
    M.RunOnProfile(profile)
    local e = profile.quiUnitFrames.player.auras.elements["*"][1]
    check("alpha stamp 51: squash re-runs the repair, weird token stripped", e.filterFlags.modifiers == nil, "survived")
    check("alpha stamp 51: stamped to current (59)", profile._schemaVersion == 59, tostring(profile._schemaVersion))

    e.filterFlags.modifiers = true
    M.RunOnProfile(profile)
    check("at 58: gate closed, hand-set token not re-stripped", e.filterFlags.modifiers == true, "was stripped")
end

----------------------------------------------------------------------------
-- 5) NOT_CANCELABLE heal: the engine removed NOT_CANCELABLE (build 68569)
--    from AuraUtil.AuraFilters after v51 originally shipped, so a store
--    seeded while that build's VALID_FILTER_TOKENS still allowed it can
--    reach this repair carrying it. The repair runs BEFORE
--    EnsureSeeded/NormalizeElement ever get a chance to heal it themselves,
--    so it must rewrite (not blind-strip) to keep pre-repair user intent.
----------------------------------------------------------------------------
do
    local profile = {
        _schemaVersion = 50,
        quiUnitFrames = {
            player = {
                auras = {
                    elementsSeeded = true,
                    elements = { ["*"] = {
                        -- require-only legacy token -> heals to CANCELABLE exclude
                        stripElement("HELPFUL", "flags", { NOT_CANCELABLE = true }),
                        -- an existing CANCELABLE value is never clobbered
                        stripElement("HELPFUL", "flags", { NOT_CANCELABLE = true, CANCELABLE = true }),
                    } },
                },
            },
        },
    }
    M.RunOnProfile(profile)

    local bucket = profile.quiUnitFrames.player.auras.elements["*"]
    local healed, conflict = bucket[1], bucket[2]
    check("heal: NOT_CANCELABLE require rewrites to CANCELABLE exclude",
        healed.filterFlags.CANCELABLE == "exclude", tostring(healed.filterFlags.CANCELABLE))
    check("heal: NOT_CANCELABLE removed after rewrite", healed.filterFlags.NOT_CANCELABLE == nil)
    check("heal: healed element stays in flags mode", healed.filterMode == "flags",
        tostring(healed.filterMode))
    check("heal: existing CANCELABLE value not clobbered",
        conflict.filterFlags.CANCELABLE == true, tostring(conflict.filterFlags.CANCELABLE))
    check("heal: NOT_CANCELABLE removed even when CANCELABLE already set",
        conflict.filterFlags.NOT_CANCELABLE == nil)
    check("stamped to current (59)", profile._schemaVersion == 59, tostring(profile._schemaVersion))
end

print("migration_v51_filterflags_repair_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
