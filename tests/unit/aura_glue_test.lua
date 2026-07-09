-- tests/unit/aura_glue_test.lua
-- Run: lua5.1 tests/unit/aura_glue_test.lua
_G.AuraContainerSortMethod = { Default = 0, BigDefensive = 1, UnitFrameDebuff = 2,
    ImportantOnly = 3, Expiration = 4, ExpirationOnly = 5, Name = 6, NameOnly = 7 }
_G.AuraContainerSortDirection = { Normal = 0, Reverse = 1 }
local ns = dofile("tools/_addon_env.lua").LoadCore()
local G = ns.AuraGlue
local E = ns.AuraElements

local failures = 0
local function check(name, ok, detail)
    if ok then print(("  ok  %s"):format(name))
    else failures = failures + 1; print(("FAIL  %s  %s"):format(name, detail or "")) end
end

-- ElementProfile -----------------------------------------------------------
do
    local e = E.NewFilterStripElement("HARMFUL")   -- anchor BOTTOMRIGHT, grow LEFT
    e.iconSize = 20; e.spacing = 3; e.maxIcons = 5; e.iconsPerRow = 4
    local p = G.ElementProfile(e)
    check("profile: layout fields map", p.iconSize == 20 and p.spacing == 3
        and p.maxIcons == 5 and p.maxPerRow == 4 and p.grow == "LEFT" and p.anchor == "BOTTOMRIGHT")
    check("profile: BOTTOM anchor wraps UP", p.wrap == "UP")
    check("profile: offsets folded", p.offsetX == e.offsetX and p.offsetY == e.offsetY)
    check("profile: duration/stack passed through", p.duration == e.duration and p.stack == e.stack)
    check("profile: swipe fields", p.hideSwipe == false and p.reverseSwipe == false)

    local top = E.NewFilterStripElement("HELPFUL") -- anchor TOPLEFT
    check("profile: TOP anchor wraps DOWN", G.ElementProfile(top).wrap == "DOWN")

    local zero = E.NewFilterStripElement("HELPFUL")
    zero.maxIcons = 0
    check("profile: maxIcons 0 (unlimited) → 40 cap for the engine", G.ElementProfile(zero).maxIcons == 40)

    local o = G.ElementProfile(top, { attachPoint = "BOTTOMLEFT", wrap = "UP", offsetX = 7 })
    check("profile: overrides win", o.attachPoint == "BOTTOMLEFT" and o.wrap == "UP" and o.offsetX == 7)
end

-- ElementGroups ------------------------------------------------------------
do
    local e = E.NewFilterStripElement("HELPFUL")
    e.filterMode = "classify"
    -- `helpful = false` explicitly disables the legacy flat-toggle fallback in
    -- E.CompileFilters' IsClassificationEnabled (aura_elements.lua): with it
    -- absent, an unset "helpful" key falls back to `raid or raidInCombat`,
    -- which would fold in HELPFUL|RAID_IN_COMBAT any time raid=true even
    -- though raidInCombat is off — surfacing a THIRD filter here. Setting it
    -- false isolates the two classifications this test actually exercises.
    e.classifications = { helpful = false, raid = true, cancelable = true }
    e.sortRule = "EXPIRY"; e.sortReverse = true
    local p = G.ElementProfile(e)
    local groups = G.ElementGroups("player", e, p, true)
    check("groups: one per compiled filter", #groups == 2)
    local filters = {}
    for _, g in ipairs(groups) do filters[g.filter] = g end
    check("groups: filters carried", filters["HELPFUL|RAID"] ~= nil and filters["HELPFUL|CANCELABLE"] ~= nil)
    check("groups: sort translated per element", groups[1].sortMethod == 4
        and groups[1].sortDirection == 1)
    check("groups: cancel on eligible HELPFUL", groups[1].cancelButtons == "RightButtonUp")
    check("groups: maxFrameCount from profile", groups[1].maxFrameCount == p.maxIcons)
    check("groups: keys are pipe-free + unique", groups[1].key ~= groups[2].key
        and not groups[1].key:find("|", 1, true))

    e.rightClickCancel = false
    check("groups: per-element cancel opt-out", G.ElementGroups("player", e, p, true)[1].cancelButtons == nil)

    local d = E.NewFilterStripElement("HARMFUL")
    local dp = G.ElementProfile(d)
    local dgroups = G.ElementGroups("player", d, dp, true)
    check("groups: off mode falls back to bare polarity", #dgroups == 1 and dgroups[1].filter == "HARMFUL")
    check("groups: no cancel on HARMFUL even when eligible", dgroups[1].cancelButtons == nil)

    local w = E.NewFilterStripElement("HELPFUL")
    w.filterMode = "whitelist"; w.whitelist = { [17] = true }
    local wgroups = G.ElementGroups("player", w, G.ElementProfile(w), false)
    check("groups: whitelist mode = bare polarity + includeSpellIDs candidates",
        wgroups[1].filter == "HELPFUL" and wgroups[1].candidateFilters
        and wgroups[1].candidateFilters.includeSpellIDs[17] == true)
    check("groups: ineligible host never cancels", wgroups[1].cancelButtons == nil)
end

-- SORT_TRANSLATIONS coverage -------------------------------------------------
do
    for rule, want in pairs({ INDEX = 0, DEFAULT = 0, EXPIRY = 4, EXPIRY_ONLY = 5,
                              NAME = 6, NAME_ONLY = 7, BIG_DEFENSIVE = 1 }) do
        local e = E.NewFilterStripElement("HELPFUL")
        e.sortRule = rule
        local g = G.ElementGroups("player", e, G.ElementProfile(e), false)
        check("sort: " .. rule, g[1].sortMethod == want, tostring(g[1].sortMethod))
    end
end

print("aura_glue_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
