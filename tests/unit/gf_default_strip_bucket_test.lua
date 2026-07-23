-- tests/unit/gf_default_strip_bucket_test.lua
-- Run: lua5.1 tests/unit/gf_default_strip_bucket_test.lua
--
-- The GF shipped strip bucket is surface-aware since the defensives fold-in:
-- party seeds the "defensives" strip enabled, raid seeds it disabled (parity
-- with the retired healer.defensiveIndicator defaults: party ON, raid OFF).
-- The strip is classify-mode bigDefensive+externalDefensive with a green
-- borderColor (the old indicator's visual identity).
--
-- v57: the bucket also always carries a 4th element, the "healerHoTs"
-- tracked element (Model.HealerHoTElement) -- same
-- surface-independent-always-present shape as debuffs/buffs, not
-- frameType-gated like defensives.

local envmod = dofile("tools/_addon_env.lua")
local ns = envmod.LoadCore()
envmod.LoadAddonFile("QUI_GroupFrames/groupframes/groupframes_aura_model.lua", "QUI_GroupFrames", ns)
local Model = ns.QUI_GroupFramesAuraModel

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

for _, frameType in ipairs({ "party", "raid" }) do
    local bucket = Model.DefaultStripBucket(frameType)
    check(frameType .. ": bucket has 4 elements", #bucket == 4, tostring(#bucket))
    check(frameType .. ": strip/element ids stable", bucket[1].id == "debuffs"
        and bucket[2].id == "buffs" and bucket[3].id == "defensives"
        and bucket[4].id == "healerHoTs",
        table.concat({ tostring(bucket[1].id), tostring(bucket[2].id), tostring(bucket[3].id),
            tostring(bucket[4].id) }, ","))
    local d = bucket[3]
    check(frameType .. ": defensives enabled parity",
        d.enabled == (frameType == "party"), tostring(d.enabled))
    check(frameType .. ": classify mode", d.mode == "filterStrip"
        and d.auraType == "HELPFUL" and d.filterMode == "classify", d.filterMode)
    check(frameType .. ": classifications", d.classifications
        and d.classifications.bigDefensive == true
        and d.classifications.externalDefensive == true, "wrong classifications")
    check(frameType .. ": green borderColor", type(d.borderColor) == "table"
        and d.borderColor[1] == 0 and d.borderColor[2] == 0.8
        and d.borderColor[3] == 0 and d.borderColor[4] == 1, "not green")
    check(frameType .. ": geometry matches retired indicator defaults",
        d.anchor == "BOTTOMRIGHT" and d.growDirection == "LEFT"
        and d.iconSize == 15 and d.maxIcons == 3 and d.spacing == 0
        and d.offsetX == 0 and d.offsetY == 4 and d.reverseSwipe == true,
        "geometry drift")
    check(frameType .. ": no rightClickCancel", d.rightClickCancel == false,
        tostring(d.rightClickCancel))
    for i = 1, 3 do
        check(frameType .. ": strip " .. i .. " has no dedupeDefensives",
            bucket[i].dedupeDefensives == nil, tostring(bucket[i].dedupeDefensives))
    end

    -- healerHoTs (v57): tracked, uncapped, onlyMine, surface-INDEPENDENT
    -- (present and identical shape on both party and raid, unlike
    -- defensives' frameType gate).
    local hot = bucket[4]
    check(frameType .. ": healerHoTs mode == tracked", hot.mode == "tracked", tostring(hot.mode))
    check(frameType .. ": healerHoTs displayType == icon", hot.displayType == "icon", tostring(hot.displayType))
    check(frameType .. ": healerHoTs onlyMine == true", hot.onlyMine == true, tostring(hot.onlyMine))
    check(frameType .. ": healerHoTs maxIcons absent (uncapped)", hot.maxIcons == nil, tostring(hot.maxIcons))
    check(frameType .. ": healerHoTs _quiHoTSeed flag set", hot._quiHoTSeed == true, tostring(hot._quiHoTSeed))
    check(frameType .. ": healerHoTs has 42 spells", type(hot.spells) == "table" and #hot.spells == 42,
        tostring(hot.spells and #hot.spells))
end

-- No-arg call must not error (legacy callers during rollout); defensives
-- defaults DISABLED when the surface is unknown (conservative). healerHoTs
-- is unaffected by frameType -- present either way.
local anon = Model.DefaultStripBucket()
check("nil frameType: defensives disabled", anon[3].enabled == false, tostring(anon[3].enabled))
check("nil frameType: healerHoTs still present", anon[4] and anon[4].id == "healerHoTs",
    tostring(anon[4] and anon[4].id))

-- Shim: string second arg seeds via the surface-aware bucket.
local auras = {}
Model.EnsureSeeded(auras, "party")
check("EnsureSeeded('party') seeds 4 elements", #auras.elements["*"] == 4,
    tostring(auras.elements and #auras.elements["*"]))
check("EnsureSeeded('party') defensives enabled",
    auras.elements["*"][3].enabled == true, "disabled")
check("EnsureSeeded('party') healerHoTs present",
    auras.elements["*"][4] and auras.elements["*"][4].id == "healerHoTs",
    tostring(auras.elements["*"][4] and auras.elements["*"][4].id))

if failures > 0 then os.exit(1) end
print("gf_default_strip_bucket_test: all checks passed")
