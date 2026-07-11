-- tests/unit/groupframes_mrb_cdm_merge_test.lua
-- MRB:RebuildRaidBuffs merges Blizzard CDM Group Buff items into MRB.RaidBuffs
-- (built-in 6 + CDM shown, deduped by spellID, hidden excluded), idempotently.
-- Run: lua tests/unit/groupframes_mrb_cdm_merge_test.lua

_G.issecretvalue = function() return false end
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end
_G.C_Timer = { After = function() end }
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end end

local ns = {}
assert(loadfile("QUI_GroupFrames/groupframes/groupframes_missing_raid_buffs.lua"))("QUI", ns)
local MRB = assert(ns.QUI_GroupFrameMissingRaidBuffs, "MRB not exported")
assert(type(MRB.RebuildRaidBuffs) == "function", "RebuildRaidBuffs must exist")

-- CDM stubs set AFTER load (RebuildRaidBuffs reads _G at call time).
_G.C_CooldownViewer = {
    GetGroupBuffItems = function()
        return {
            { spellID = 100,  name = "Test Buff A" },
            { spellID = 1459, name = "Arcane Intellect (dup)" }, -- already a built-in id
            { spellID = 200,  name = "Hidden Buff B" },          -- hidden
        }
    end,
}
_G.C_UnitAuras = { GetHiddenGroupBuffs = function() return { 200 } end }

MRB:RebuildRaidBuffs()

local byKey = {}
for _, e in ipairs(MRB.RaidBuffs) do byKey[e.key] = e end

assert(byKey.intellect, "built-in intellect retained")
assert(byKey.bronze, "built-in bronze retained")
assert(byKey["cdm:100"], "CDM spellID 100 merged")
assert(byKey["cdm:100"].label == "Test Buff A", "CDM label carried")
assert(byKey["cdm:100"].ids[1] == 100 and #byKey["cdm:100"].ids == 1, "CDM ids = {spellID}")
assert(byKey["cdm:100"].providerClass == nil, "CDM providerClass nil")
assert(byKey["cdm:100"].iconSpellID == 100, "CDM iconSpellID = spellID")
assert(byKey["cdm:100"].source == "cdm", "CDM entry tagged source=cdm")
assert(byKey["cdm:1459"] == nil, "1459 deduped (already in built-in intellect ids)")
assert(byKey["cdm:200"] == nil, "200 excluded (hidden)")

-- Idempotent + guard: APIs absent -> CDM entries dropped, built-in retained.
_G.C_CooldownViewer = nil
MRB:RebuildRaidBuffs()
local byKey2 = {}
for _, e in ipairs(MRB.RaidBuffs) do byKey2[e.key] = e end
assert(byKey2["cdm:100"] == nil, "guard/idempotent: CDM entries removed when API absent")
assert(byKey2.intellect, "built-in retained after guard rebuild")

print("OK groupframes_mrb_cdm_merge_test")
