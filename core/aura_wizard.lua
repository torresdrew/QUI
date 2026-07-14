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
-- Deterministic spellID order. A staged spellID REPLACES its existing tracked
-- element — the review step promises the wizard's selection wins, so a re-run
-- with a new corner/display must not be a silent no-op. Every other element
-- in `bucket` is left untouched. Returns the (mutated) bucket.
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
        if type(e) == "table" and e.mode == "tracked" and type(e.spells) == "table"
            and stagedSet[e.spells[1]] then
            table.remove(bucket, i)
        end
    end
    -- Per-corner slot counters, seeded from tracked elements ALREADY in the
    -- bucket: the 2nd+ HoT on a corner is stepped away from the 1st instead
    -- of anchoring exactly on top of it — overlapped indicators are
    -- indistinguishable at runtime. Icons/squares step sideways (X); bars
    -- step vertically (Y — they're wide, a sideways icon-width step would
    -- still overlap). Mirrored by the wizard step-4 live preview.
    local slotsX, slotsY = {}, {}
    for _, e in ipairs(bucket) do
        -- "border" wraps the whole frame — it neither occupies nor consumes
        -- a corner slot.
        if type(e) == "table" and e.mode == "tracked" and e.displayType ~= "border" then
            local c = e.anchor or "TOPLEFT"
            if e.displayType == "bar" then
                slotsY[c] = (slotsY[c] or 0) + 1
            else
                slotsX[c] = (slotsX[c] or 0) + 1
            end
        end
    end
    for _, spellID in ipairs(ids) do
        local cfg = staged[spellID] or {}
        local e = E.NewTrackedElement({ spellID }, cfg.displayType or "icon")
        e.anchor = cfg.corner or "TOPLEFT"
        if e.displayType == "bar" then
            local slot = slotsY[e.anchor] or 0
            slotsY[e.anchor] = slot + 1
            if slot > 0 then
                local step = (((e.bar and e.bar.thickness) or 4) + 2) * slot
                e.offsetY = (e.anchor == "TOPLEFT" or e.anchor == "TOPRIGHT") and -step or step
            end
        elseif e.displayType ~= "border" then
            local slot = slotsX[e.anchor] or 0
            slotsX[e.anchor] = slot + 1
            if slot > 0 then
                local step = ((e.iconSize or 16) + 2) * slot
                e.offsetX = (e.anchor == "TOPRIGHT" or e.anchor == "BOTTOMRIGHT") and -step or step
            end
        end
        bucket[#bucket + 1] = e
    end
    return bucket
end

return W
