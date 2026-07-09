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
function Model.DefaultStripBucket()
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
            filterMode = "off", filterFlags = {}, onlyMine = false, hidePermanent = false, dedupeDefensives = true,
            classifications = { raid = false, raidInCombat = false, cancelable = false, notCancelable = false, bigDefensive = false, externalDefensive = false },
            whitelist = {}, blacklist = {},
            sortRule = "INDEX", sortReverse = false, rightClickCancel = true,
        },
    }
end

-- Legacy-signature seed shim: the old GF model's EnsureSeeded(auras) seeded the
-- shipped default strips with NO argument; core E.EnsureSeeded seeds whatever
-- defaultBucketFn returns (nil -> EMPTY bucket + latched elementsSeeded flag).
-- The editor/preview/schema still call the one-arg form and can run BEFORE the
-- runtime ever seeds (options opened on a fresh profile), so thread the GF
-- default bucket for them here. Callers passing their own defaultBucketFn
-- (the runtime) pass through unchanged. Deleted with the settings cutover.
function Model.EnsureSeeded(auras, defaultBucketFn)
    return E.EnsureSeeded(auras, defaultBucketFn or Model.DefaultStripBucket)
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
