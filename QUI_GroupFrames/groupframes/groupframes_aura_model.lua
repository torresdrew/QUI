-- QUI_GroupFrames/groupframes/groupframes_aura_model.lua
-- COMPATIBILITY SHIM — the element model moved to core/aura_elements.lua
-- (shared by all aura surfaces). This file only (a) delegates to it for the
-- editor/preview imports that still use the old name (deleted with them in
-- the settings/preview cutover tasks), and (b) keeps the GF-only tracked
-- match populator used by the preview fakes.
local ADDON_NAME, ns = ...
local E = ns.AuraElements
local Model = setmetatable({}, { __index = E })
ns.QUI_GroupFramesAuraModel = Model

-- The shipped default strips (NORMALIZED core schema). This lives HERE — an
-- always-loaded QUI_GroupFrames file — not in the Options-only defaults file:
-- the runtime seed path runs on any group-frame refresh, and E.EnsureSeeded
-- LATCHES elementsSeeded after seeding whatever the bucket fn returns. If the
-- bucket lived Options-side, a fresh profile on an Options-disabled install
-- would latch an EMPTY "*" bucket and permanently lose the shipped strips.
-- Single source of truth: seeded ONCE per profile context (never an AceDB
-- array default — copyDefaults re-fills deleted indices). Fixed string ids
-- ("debuffs"/"buffs") match the historical values. Fresh table each call.
function Model.DefaultStripBucket(frameType)
    return {
        {
            id = "debuffs", enabled = true, mode = "filterStrip", auraType = "HARMFUL",
            anchor = "BOTTOMRIGHT", growDirection = "LEFT", spacing = 2,
            offsetX = -2, offsetY = -18, iconSize = 16, maxIcons = 3,
            hideSwipe = false, reverseSwipe = false,
            swipeStyle = "radial",
            duration = { show = true, fontSize = 9, anchor = "BOTTOM", offsetX = 0, offsetY = -6, color = { 1, 1, 1, 1 } },
            stack = { show = true, fontSize = 9, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } },
            filterMode = "off", filterFlags = {},
            classifications = { raid = true, crowdControl = true },  -- HARMFUL: no raidInCombat (helpful-only filter)
            whitelist = {}, blacklist = {},
            sortRule = "INDEX", sortReverse = false, rightClickCancel = true,
        },
        {
            id = "buffs", enabled = false, mode = "filterStrip", auraType = "HELPFUL",
            anchor = "TOPLEFT", growDirection = "RIGHT", spacing = 2,
            offsetX = 2, offsetY = 16, iconSize = 14, maxIcons = 0,
            hideSwipe = false, reverseSwipe = false,
            swipeStyle = "radial",
            duration = { show = true, fontSize = 9, anchor = "BOTTOM", offsetX = 0, offsetY = -6, color = { 1, 1, 1, 1 } },
            stack = { show = true, fontSize = 9, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } },
            filterMode = "off", filterFlags = {}, onlyMine = false, hidePermanent = false,
            classifications = { raid = false, raidInCombat = false, cancelable = false, notCancelable = false, bigDefensive = false, externalDefensive = false },
            whitelist = {}, blacklist = {},
            sortRule = "INDEX", sortReverse = false, rightClickCancel = true,
        },
        {
            -- The retired healer.defensiveIndicator as a shipped element:
            -- classify-mode big/external defensives, engine-filtered. Party
            -- shipped ON, raid OFF (parity with the old indicator defaults);
            -- unknown surface seeds DISABLED (conservative — every GF caller
            -- threads its frameType). Green border = the indicator's identity.
            id = "defensives", enabled = (frameType == "party"), mode = "filterStrip", auraType = "HELPFUL",
            anchor = "BOTTOMRIGHT", growDirection = "LEFT", spacing = 0,
            offsetX = 0, offsetY = 4, iconSize = 15, maxIcons = 3,
            hideSwipe = false, reverseSwipe = true,
            swipeStyle = "radial",
            duration = { show = true, fontSize = 9, anchor = "BOTTOM", offsetX = 0, offsetY = -6, color = { 1, 1, 1, 1 } },
            stack = { show = true, fontSize = 9, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } },
            filterMode = "classify", filterFlags = {},
            classifications = { bigDefensive = true, externalDefensive = true },
            borderColor = { 0, 0.8, 0, 1 },
            whitelist = {}, blacklist = {},
            sortRule = "INDEX", sortReverse = false, rightClickCancel = false,
        },
        Model.HealerHoTElement(),
    }
end

-- Healer HoTs (v57): shipped as ONE always-present tracked element, same
-- delivery precedent as the "defensives" strip above (built inside
-- DefaultStripBucket, so it reaches every EnsureSeeded latch path — party/
-- raid runtime render, editmode, preview, the Options Auras section, the
-- setup wizard — the FIRST time a surface's buckets latch; elementsSeeded
-- then makes deletion permanent). Covers the healer HoT/absorb ids PTR
-- flips secret in combat: engine-rendered tracked slots (core/aura_slots.lua)
-- render secret auras C-side, but the legacy Lua-side spellID match cannot
-- see them and silently drops the icon. Built via the shared constructor
-- (not a raw literal like the filterStrips above) so every NewTrackedElement
-- default — duration/stack/bar/border shape — tracks that constructor
-- automatically; `spells` comes from the SINGLE canonical source
-- core/aura_elements.lua E.HealerHoTSpellIDs() (core/migrations.lua
-- Migrations.SeedHealerHoTElements reads the exact same source for the
-- legacy-latch migration path covering profiles whose buckets latched
-- BEFORE this version — the two can never drift apart). Fixed id (not the
-- session-scoped "e<N>" counter NewTrackedElement assigns by default) —
-- same fixed-id precedent as "defensives"/"encounterBoss": the seed-once
-- dedup scan (both here and in the migration) keys on a STABLE id. Left
-- deliberately UNCAPPED (no maxIcons): AuraSlots binds tracked slots 1:1 per
-- spellID in array order and stops at any cap, so a cap here would strand
-- every id past it with no watching slot — onlyMine=true is the real bound
-- (only the player's own current spec's ids ever have a live aura to
-- match, so every other spec's slots simply sit unbound, not truncated).
function Model.HealerHoTElement()
    local element = E.NewTrackedElement(E.HealerHoTSpellIDs(), "icon")
    element.id = "healerHoTs"
    element.onlyMine = true
    element.name = ns.L["Healer HoTs"]
    element._quiHoTSeed = true
    return element
end

-- Seed shim: second arg is either a defaultBucketFn (runtime callers pass
-- their own closure) or a frameType string ("party"/"raid") from the
-- editor/preview/schema paths — the bucket is surface-aware since the
-- defensives fold-in (party seeds the defensives strip enabled, raid
-- disabled). nil falls through to DefaultStripBucket(nil) = defensives
-- disabled (conservative).
function Model.EnsureSeeded(auras, defaultBucketFnOrFrameType)
    local a = defaultBucketFnOrFrameType
    if type(a) == "function" then
        return E.EnsureSeeded(auras, a)
    end
    return E.EnsureSeeded(auras, function() return Model.DefaultStripBucket(a) end)
end

-- `out` (optional): reusable { [spellID] = auraData } map for the preview
-- fakes (the LIVE tracked path is engine-driven via core/aura_slots.lua and
-- never reads aura data).
function Model.PopulateElementMatches(element, cache, out)
    local matches = out or {}
    if out then
        for k in pairs(matches) do matches[k] = nil end
    end
    if element.mode == "tracked" and cache then
        for _, sid in ipairs(element.spells or {}) do
            local data = (cache.buffsBySpellID and cache.buffsBySpellID[sid])
                      or (cache.debuffsBySpellID and cache.debuffsBySpellID[sid])
            if data then matches[sid] = data end
        end
    end
    return matches
end

return Model
