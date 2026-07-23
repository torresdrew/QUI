local ADDON_NAME, ns = ...
local E = ns.AuraElements
local W = {}
ns.QUI_AuraWizard = W

local MATRIX = {
    TANK    = { groupParty = { buffs = {}, debuffs = { "dispellable" } }, player = { buffs = { "defensives" } }, target = { debuffs = { "boss" } } },
    HEALER  = { groupParty = { buffs = { "mine" }, debuffs = { "dispellable" } }, player = { buffs = { "defensives" } }, target = { debuffs = {} } },
    DAMAGER = { groupParty = { buffs = {}, debuffs = {} }, player = { buffs = { "mine" } }, target = { debuffs = { "mine" } } },
}
local function copyList(t) local o={} for i,v in ipairs(t or {}) do o[i]=v end return o end

-- Step 3 party intent menus (ordered). Keys are Phase-1 WhatToShow keys
-- (HELPFUL: mine/defensives/all; HARMFUL: dispellable/boss/crowdControl). The
-- MATRIX supplies which entries start checked; the menu is the full choice set.
W.PARTY_BUFF_INTENTS = {
    { key = "mine",       label = ns.L["My HoTs"] },
    { key = "defensives", label = ns.L["Big defensives on allies"] },
    { key = "all",        label = ns.L["All buffs"] },
}
W.PARTY_DEBUFF_INTENTS = {
    { key = "dispellable",  label = ns.L["Dispellable by me"] },
    { key = "boss",         label = ns.L["Boss debuffs"] },
    { key = "crowdControl", label = ns.L["Crowd control"] },
}

function W.RoleDefaults(role)
    local m = MATRIX[role] or MATRIX.DAMAGER
    return {
        groupParty = { buffs = copyList(m.groupParty.buffs), debuffs = copyList(m.groupParty.debuffs) },
        player = { buffs = copyList(m.player.buffs) },
        target = { debuffs = copyList(m.target.debuffs) },
    }
end
function W.SeedSurface(auras, auraType, intentKey)
    local e = E.NewFilterStripElement(auraType)
    E.ApplyWhatToShow(e, intentKey)
    return e
end
function W.PlayerRole()
    if not (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) then return "DAMAGER" end
    local idx = C_SpecializationInfo.GetSpecialization()
    if not idx then return "DAMAGER" end
    local role = select(5, GetSpecializationInfo(idx))  -- role token TANK/HEALER/DAMAGER
    if role == "TANK" or role == "HEALER" then return role end
    return "DAMAGER"
end

-- Current player's specID (first return of GetSpecializationInfo), mirroring
-- PlayerRole's C_SpecializationInfo access. nil outside the game / no spec
-- chosen yet — callers treat that as "no override possible", same as the
-- group-frames render path (GetPlayerSpecID in groupframes_auras.lua, which
-- is file-local there and not exported cross-addon, so this re-derives it
-- from the same Blizzard API rather than reaching into that file).
function W.PlayerSpecID()
    if not (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) then return nil end
    local idx = C_SpecializationInfo.GetSpecialization()
    if not idx then return nil end
    return (GetSpecializationInfo(idx))  -- first return = specId
end

-- The elements bucket key the runtime actually reads for `specID` on a
-- surface that supports per-spec override buckets (group-frames party).
-- Mirrors E.ActiveElementsForSpec's OVERRIDE (either/or) resolution: a
-- present spec bucket wins over "*", never a union. Surfaces that never
-- create spec buckets (unit frames) always resolve to "*" here too, since
-- E.HasSpecOverride is false whenever elements[specID] doesn't exist.
function W.ActiveBucketKey(elements, specID)
    if E.HasSpecOverride and E.HasSpecOverride(elements, specID) then
        return specID
    end
    return "*"
end

local function deepCopyElement(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = deepCopyElement(val) end
    return t
end

-- true iff `e` is (or has been configured as) the shipped "defensives"
-- strip: either the fixed shipped id, or any strip already classify-mode
-- scoped to exactly big/external defensives (hand-built equivalent). Buff
-- retargeting must never repurpose this strip — Finding 2.
local function isDefensivesStrip(e)
    if type(e) ~= "table" then return false end
    if e.id == "defensives" then return true end
    if e.filterMode == "classify" and type(e.classifications) == "table"
        and e.classifications.bigDefensive and e.classifications.externalDefensive then
        return true
    end
    return false
end

-- Next filterStrip element in `bucket` matching `auraType` that no intent
-- has claimed yet this pass; skips defensives-classified strips when
-- `skipDefensives` is true (buff search).
local function claimNextStrip(bucket, auraType, claimed, skipDefensives)
    for _, e in ipairs(bucket) do
        if type(e) == "table" and e.mode == "filterStrip" and e.auraType == auraType
            and not claimed[e]
            and not (skipDefensives and isDefensivesStrip(e)) then
            return e
        end
    end
    return nil
end

-- One polarity's intent pass for SeedBucketForRole. Each key claims its OWN
-- strip (in bucket order); `explicit` additionally disables every unclaimed
-- strip of the polarity afterwards (declarative selection semantics).
local function applyIntentKeys(bucket, auraType, keys, skipDefensives, explicit)
    keys = keys or {}
    local claimed = {}
    for _, key in ipairs(keys) do
        local strip
        if key == "defensives" then
            -- The shipped defensives strip is enabled IN PLACE, never cloned
            -- onto a second strip (the old retarget path produced a duplicate
            -- classify-defensives strip next to the shipped one).
            for _, e in ipairs(bucket) do
                if type(e) == "table" and e.mode == "filterStrip" and isDefensivesStrip(e) then
                    strip = e
                    break
                end
            end
        else
            strip = claimNextStrip(bucket, auraType, claimed, skipDefensives)
            if strip then E.ApplyWhatToShow(strip, key) end
        end
        if not strip then
            strip = W.SeedSurface(nil, auraType, key)
            bucket[#bucket + 1] = strip
        end
        claimed[strip] = true
        strip.enabled = true
    end
    if explicit then
        for _, e in ipairs(bucket) do
            if type(e) == "table" and e.mode == "filterStrip" and e.auraType == auraType
                and not claimed[e] then
                e.enabled = false
            end
        end
    end
end

-- Pure retarget-in-place seed helper (Finding 2). `bucket` is the live
-- elements array for a surface's ACTIVE bucket (whichever key
-- ActiveBucketKey resolved to) — mutated in place and returned, so callers
-- assign the result back into auras.elements[key] to also cover the
-- absent-key case. `buffKeys`/`debuffKeys` are "what to show" intent lists.
--
-- Semantics:
--  1. If the bucket is empty/absent, seed it from `defaultBucketFn` (deep
--     copied so callers never alias the shipped default's tables).
--  2. Each intent key claims its OWN strip of the matching polarity, in
--     bucket order (first key -> first strip, second key -> next unclaimed
--     strip, ...), retargeted via E.ApplyWhatToShow + enabled=true; a new
--     strip is appended once existing ones run out. Multiple checked
--     intents therefore never collapse onto one strip.
--  3. The "defensives" buff intent enables the shipped defensives strip in
--     place; generic buff intents never claim or retarget it.
--  4. `explicit` = the keys came from the party page's checkbox menus
--     (a full declarative selection): every strip of that polarity the pass
--     did NOT claim is disabled, so unchecked intents — including
--     uncheck-all — actually turn things off. Role-default callers omit it
--     and keep the old leave-untouched semantics.
--  5. Tracked and other non-strip elements are always left untouched.
function W.SeedBucketForRole(bucket, buffKeys, debuffKeys, defaultBucketFn, explicit)
    bucket = bucket or {}
    if #bucket == 0 and type(defaultBucketFn) == "function" then
        local seed = defaultBucketFn() or {}
        for i, e in ipairs(seed) do
            bucket[i] = deepCopyElement(e)
        end
    end

    applyIntentKeys(bucket, "HARMFUL", debuffKeys, false, explicit)
    applyIntentKeys(bucket, "HELPFUL", buffKeys, true, explicit)

    return bucket
end

-- Deep value-equality ignoring the volatile `id` field (fresh default
-- buckets mint new ids every call, so ids never match by construction).
local function elementEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if k ~= "id" and not elementEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if k ~= "id" and a[k] == nil then return false end
    end
    return true
end

-- Both sides are normalized (on deep copies — NormalizeElement mutates) so
-- a stored element that predates a model field doesn't diff against a
-- freshly-constructed default that carries it.
local function normalizedCopy(e)
    local c = deepCopyElement(e)
    if type(E.NormalizeElement) == "function" then E.NormalizeElement(c) end
    return c
end

function W.SurfaceIsCustomized(auras, defaultBucketFn, bucketKey)
    if type(auras) ~= "table" or not auras.elementsSeeded then return false end
    bucketKey = bucketKey or "*"
    local cur = (auras.elements and auras.elements[bucketKey]) or {}
    local def = (type(defaultBucketFn)=="function" and defaultBucketFn()) or {}
    if #cur ~= #def then return true end
    for i = 1, #cur do
        if not elementEqual(normalizedCopy(cur[i]), normalizedCopy(def[i])) then return true end
    end
    return false
end

-- Ordered live-step keys for the given role + surface selection.
-- partyAuras only when Party is a chosen surface; placeHoTs only for a healer
-- who is configuring Party (HoTs live on the party frame).
function W.WizardSteps(role, surfaces)
    surfaces = surfaces or {}
    local steps = { "role", "surfaces" }
    if surfaces.party then steps[#steps + 1] = "partyAuras" end
    if role == "HEALER" and surfaces.party then steps[#steps + 1] = "placeHoTs" end
    steps[#steps + 1] = "review"
    return steps
end

-- Focus mirrors Target: same debuff intents (focus = second target). No MATRIX
-- row -- reads the role's Target debuffs so MATRIX stays the single source.
function W.FocusDefaults(role)
    local m = MATRIX[role] or MATRIX.DAMAGER
    return { debuffs = copyList(m.target.debuffs) }
end

-- Commit one tracked element per staged HoT. `staged` is
-- { [spellID] = { corner = <anchor string>, displayType = <string> } }.
-- Deterministic spellID order. A staged spellID REPLACES its existing tracking
-- wherever it appears — the review step promises the wizard's selection wins,
-- so a re-run with a new corner/display must not be a silent no-op. A staged
-- id is removed from EVERY position of a multi-spell element (not just
-- spells[1]); the element keeps its remaining spells and is only removed when
-- none are left. Every other element in `bucket` is left untouched. Returns
-- the (mutated) bucket.
function W.CommitTrackedHoTs(bucket, staged)
    bucket = bucket or {}
    if type(staged) ~= "table" then return bucket end
    local ids = {}
    for spellID in pairs(staged) do ids[#ids + 1] = spellID end
    table.sort(ids)
    local stagedSet = {}
    for _, spellID in ipairs(ids) do stagedSet[spellID] = true end
    for i = #bucket, 1, -1 do
        local e = bucket[i]
        if type(e) == "table" and e.mode == "tracked" and type(e.spells) == "table" then
            local spells = e.spells
            for j = #spells, 1, -1 do
                if stagedSet[spells[j]] then table.remove(spells, j) end
            end
            if #spells == 0 then table.remove(bucket, i) end
        end
    end
    -- Per-corner occupied PIXEL INTERVALS in SIGNED offset space, seeded
    -- from tracked elements ALREADY in the bucket: the 2nd+ HoT on a corner
    -- is stepped away from the 1st instead of anchoring exactly on top of
    -- it -- overlapped indicators are indistinguishable at runtime. Mirrored
    -- by the wizard step-4 live preview.
    -- Occupancy facts (2026-07 review rounds 2-5):
    --   * EVERY tracked container element renders one indicator PER SPELL
    --     (core/aura_slots.lua Sync builds one slot per numeric spell,
    --     capped by maxIcons -- icon, square and bar displayTypes alike).
    --   * Intervals are REAL pixel extents, not ordinal slots.
    --   * Seeding from each element's actual offset reuses holes left by
    --     removed elements instead of stacking past them.
    local slotsX, slotsY = {}, {}
    local function markInterval(map, corner, lo, hi)
        local list = map[corner]
        if not list then list = {}; map[corner] = list end
        list[#list + 1] = { lo, hi }
    end
    -- Corner EXTENSION sign per axis: which way a cell's body extends from
    -- its anchor offset (SetPoint semantics): TOP corners extend downward
    -- (-Y), BOTTOM upward (+Y); LEFT corners extend rightward (+X), RIGHT
    -- leftward (-X). A cell anchored at o with size s occupies [o, o+s)
    -- when ext > 0 and [o-s, o) when ext < 0 -- REAL pixel extents, so
    -- cross-axis marks and claims interact correctly.
    local function extX(corner) return corner:find("RIGHT", 1, true) and -1 or 1 end
    local function extY(corner) return corner:find("TOP", 1, true) and -1 or 1 end
    local function cellExtent(o, s, ext)
        if ext > 0 then return o, o + s end
        return o - s, o
    end
    -- Occupied span of n cells anchored from `off`, marching in grow
    -- direction g (+1 RIGHT/UP, -1 LEFT/DOWN, 0 CENTER = symmetric), each
    -- extending toward ext.
    local function spanFor(off, s, n, g, ext)
        local aLo, aHi
        if g == 0 then
            aLo = off - ((n - 1) / 2) * s
            aHi = off + ((n - 1) / 2) * s
        elseif g > 0 then
            aLo, aHi = off, off + (n - 1) * s
        else
            aLo, aHi = off - (n - 1) * s, off
        end
        if ext > 0 then return aLo, aHi + s end
        return aLo - s, aHi
    end
    -- Directional first-fit over REAL extents: candidate anchors start at 0
    -- and bump past blockers toward `dir`. Terminates: the anchor is
    -- monotonic in dir and the list is finite.
    local function claimOffset(map, corner, size, dir, ext)
        local list = map[corner]
        if not list then list = {}; map[corner] = list end
        local off = 0
        local moved = true
        while moved do
            moved = false
            local lo, hi = cellExtent(off, size, ext)
            for _, iv in ipairs(list) do
                if iv[1] < hi and iv[2] > lo then
                    if dir >= 0 then
                        off = (ext > 0) and iv[2] or (iv[2] + size)
                    else
                        off = (ext > 0) and (iv[1] - size) or iv[1]
                    end
                    moved = true
                    lo, hi = cellExtent(off, size, ext)
                end
            end
        end
        local lo, hi = cellExtent(off, size, ext)
        list[#list + 1] = { lo, hi }
        return off
    end
    local function renderedSpellCount(e)
        local n = (type(e.spells) == "table") and #e.spells or 0
        if n < 1 then n = 1 end
        local cap = e.maxIcons
        if type(cap) == "number" and cap > 0 and cap < n then n = cap end
        return n
    end
    -- Wrap split: n rendered cells → (mainN, crossN). iconsPerRow caps the
    -- main-axis run; rows past the first stack on the CROSS axis toward the
    -- corner's extension sign (AuraSlots.AnchorSlot advances rowI exactly the
    -- way cellExtent extends), so the occupied shape is the full wrapped
    -- rectangle: widest-row cells on the main axis × row count on the cross
    -- axis. (Round-6: a single-cell cross mark let a new bar land on a
    -- retained element's second row, and a new icon on a vertical element's
    -- second column.)
    local function wrapCounts(e, n)
        local perRow = e.iconsPerRow
        if type(perRow) == "number" and perRow > 0 and perRow < n then
            return perRow, math.ceil(n / perRow)
        end
        return n, 1
    end
    -- Per-cell steps MUST mirror the runtime geometry (AuraGlue.ElementProfile
    -- feeding AuraSlots.AnchorSlot: step = size + spacing): icon/square size
    -- falls back to the PROFILE default 22 (not the NewTrackedElement seed
    -- 16), spacing to 2, bars to length 48 x thickness 12 (round-4: a 4px
    -- thickness guess overlapped real 12px bars).
    local function elemSteps(e)
        local isBar = e.displayType == "bar"
        local size = (type(e.iconSize) == "number" and e.iconSize > 0) and e.iconSize or 22
        local spacing = e.spacing or 2
        local w = isBar and ((e.bar and e.bar.length) or 48) or size
        local h = isBar and ((e.bar and e.bar.thickness) or 12) or size
        return w + spacing, h + spacing
    end
    -- Round-5: spans follow the element's OWN growDirection exactly as
    -- AnchorSlot lays cells out (RIGHT/UP positive, LEFT/DOWN negative,
    -- CENTER symmetric); bars with horizontal grow stack along X with
    -- length-sized cells, not Y. The previous |offset|+forward model
    -- overlapped every LEFT/UP/CENTER layout. Each element also marks its
    -- cross-axis extent — ALL wrapped rows/columns (wrapCounts above), not
    -- just the first — so an element stepping on the other axis of the same
    -- corner cannot land on any wrapped row.
    for _, e in ipairs(bucket) do
        -- "border" and "healthTint" wrap/tint the whole frame -- they
        -- neither occupy nor consume a corner slot.
        if type(e) == "table" and e.mode == "tracked"
            and e.displayType ~= "border" and e.displayType ~= "healthTint" then
            local corner = e.anchor or "TOPLEFT"
            local grow = e.growDirection or "RIGHT"
            local n = renderedSpellCount(e)
            local mainN, crossN = wrapCounts(e, n)
            local stepX, stepY = elemSteps(e)
            local offX, offY = e.offsetX or 0, e.offsetY or 0
            if grow == "UP" or grow == "DOWN" then
                local g = (grow == "UP") and 1 or -1
                markInterval(slotsY, corner, spanFor(offY, stepY, mainN, g, extY(corner)))
                markInterval(slotsX, corner, cellExtent(offX, stepX * crossN, extX(corner)))
            else
                local g = (grow == "LEFT") and -1 or (grow == "CENTER") and 0 or 1
                markInterval(slotsX, corner, spanFor(offX, stepX, mainN, g, extX(corner)))
                markInterval(slotsY, corner, cellExtent(offY, stepY * crossN, extY(corner)))
            end
        end
    end
    for _, spellID in ipairs(ids) do
        local cfg = staged[spellID] or {}
        local e = E.NewTrackedElement({ spellID }, cfg.displayType or "icon")
        e.anchor = cfg.corner or "TOPLEFT"
        local stepX, stepY = elemSteps(e)
        if e.displayType == "bar" then
            -- Wizard bars stack vertically per element: downward from TOP
            -- corners (negative Y), upward from BOTTOM ones.
            local dir = extY(e.anchor)
            local off = claimOffset(slotsY, e.anchor, stepY, dir, extY(e.anchor))
            if off ~= 0 then e.offsetY = off end
            markInterval(slotsX, e.anchor, cellExtent(e.offsetX or 0, stepX, extX(e.anchor)))
        elseif e.displayType ~= "border" then
            -- Icons/squares step sideways, inward from the corner (negative
            -- X from right corners).
            local dir = extX(e.anchor)
            local off = claimOffset(slotsX, e.anchor, stepX, dir, extX(e.anchor))
            if off ~= 0 then e.offsetX = off end
            markInterval(slotsY, e.anchor, cellExtent(e.offsetY or 0, stepY, extY(e.anchor)))
        end
        bucket[#bucket + 1] = e
    end
    return bucket
end

return W
