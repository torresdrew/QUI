-- core/aura_elements.lua — unified aura element model shared by buffborders,
-- unit frames and group frames (one schema, one compiler, one seed/override
-- engine). Pure Lua: no frame APIs, fully unit-testable headless.
--
-- Storage shape is UNIFORM across all three surfaces: a spec-bucket store
--   auras.elements = { ["*"] = { element, ... }, [specID] = { ... } }
-- Only group frames ever create non-"*" buckets (per-spec overrides); unit
-- frames and buffborders always read/write the "*" bucket. Element lists are
-- NEVER declared in core/defaults.lua (AceDB copyDefaults re-fills deleted
-- array indices), they are seeded exactly once behind auras.elementsSeeded.
local ADDON_NAME, ns = ...
local E = ns.AuraElements or {}
ns.AuraElements = E
_G.QUI = _G.QUI or {}
_G.QUI.AuraElements = E

local idCounter = 0
local function nextId()
    idCounter = idCounter + 1
    return "e" .. tostring(idCounter)
end

local function deepCopyTable(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = deepCopyTable(val) end
    return t
end

local DISPLAY_TYPES = { icon = true, square = true, bar = true, healthTint = true }
local DEFAULT_MISSING_RAID_BUFF_CHECKS = {
    intellect = true, stamina = true, attackPower = true,
    versatility = true, skyfury = true, bronze = true,
}

-- Classification key → Blizzard filter-string fragment(s). Merged superset of
-- the GF and UF maps (they overlapped on every shared key). The `helpful` /
-- `harmful` master keys are the UF legacy spelling: they expand to the same
-- RAID (+ RAID_IN_COMBAT for HELPFUL) pair the split raid/raidInCombat keys
-- produce; a stored helpful=true keeps working via its own map entry.
-- RAID_IN_COMBAT is a HELPFUL-only AuraFilters token (Blizzard doc: "Combine
-- with Player & Helpful"); "HARMFUL|RAID_IN_COMBAT" is an invalid combo and
-- C_UnitAuras.GetUnitAuras hard-errors on it — the HARMFUL map must never
-- emit it.
local BUFF_CLASSIFICATION_MAP = {
    helpful           = { "HELPFUL|RAID", "HELPFUL|RAID_IN_COMBAT" },
    raid              = "HELPFUL|RAID",
    raidInCombat      = "HELPFUL|RAID_IN_COMBAT",
    cancelable        = "HELPFUL|CANCELABLE",
    -- NOT_CANCELABLE was removed from the engine's AuraFilters set (build
    -- 68569); the replacement is CANCELABLE excluded (`!CANCELABLE`).
    notCancelable     = "HELPFUL|!CANCELABLE",
    bigDefensive      = "HELPFUL|BIG_DEFENSIVE",
    externalDefensive = "HELPFUL|EXTERNAL_DEFENSIVE",
}
local DEBUFF_CLASSIFICATION_MAP = {
    harmful      = { "HARMFUL|RAID" },
    raid         = "HARMFUL|RAID",
    dispellable  = "HARMFUL|RAID_PLAYER_DISPELLABLE",
    crowdControl = "HARMFUL|CROWD_CONTROL",
}

-- NOTE: unlike the pre-merge UF map (which had ONLY the helpful/harmful
-- master keys and needed a raid/raidInCombat fallback read), the merged map
-- carries the split keys alongside the masters — so no fallback: a legacy
-- profile's split pair emits its strings via the split entries directly, and
-- a master-key fallback here would wrongly promote {raid=true} to
-- RAID_IN_COMBAT as well (the two toggles must stay independent).
local function IsClassificationEnabled(classifications, key)
    return classifications[key] == true
end

local function defaultClassifications(auraType)
    if auraType == "HARMFUL" then
        return { raid = true, crowdControl = true }
    end
    return { raid = false, raidInCombat = false, cancelable = false, notCancelable = false,
             bigDefensive = false, externalDefensive = false }
end

local function defaultDuration()
    return { show = true, fontSize = 9, anchor = "CENTER", offsetX = 0, offsetY = 0,
             color = { 1, 1, 1, 1 } }
end
local function defaultStack()
    return { show = true, fontSize = 9, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1,
             color = { 1, 1, 1, 1 } }
end

function E.NewFilterStripElement(auraType)
    return {
        id = nextId(), enabled = true, mode = "filterStrip",
        auraType = auraType or "HELPFUL",
        anchor = (auraType == "HARMFUL") and "BOTTOMRIGHT" or "TOPLEFT",
        offsetX = 0, offsetY = 0,
        growDirection = (auraType == "HARMFUL") and "LEFT" or "RIGHT",
        spacing = 2, iconSize = 14, maxIcons = 3, iconsPerRow = 0,
        hideSwipe = false, reverseSwipe = false,
        swipeStyle = "radial",
        duration = defaultDuration(),
        stack = defaultStack(),
        -- filterMode: "off" (bare polarity) | "flags" (AND-composed AuraFilters
        -- tokens on ONE string — the buffborders/UF legacy semantics) |
        -- "classify" (OR fan-out, one group per classification) | "whitelist".
        filterMode = "off", filterFlags = {},
        onlyMine = false, hidePermanent = false, dedupeDefensives = true,
        classifications = defaultClassifications(auraType),
        whitelist = {}, blacklist = {},
        dispelFilterMode = "off", dispelTypes = {},
        maxDurationSec = 0,
        -- Boolean gates (gateStealable, gateBossAura, gatePriorityAura,
        -- gateRoleAura, gateBossOrRoleAura) are intentionally NOT seeded:
        -- absent = off, the editor stamps them on first toggle.
        sortRule = "INDEX", sortReverse = false,
        -- Honored only on cancel-eligible hosts (player-unit) + HELPFUL strips;
        -- runtime maps it to SetCancelAuraButtons("RightButtonUp").
        rightClickCancel = true,
    }
end

function E.NewTrackedElement(spells, displayType)
    return {
        id = nextId(), enabled = true, mode = "tracked",
        -- Slots need a polarity for their filter string; the legacy model never
        -- stored one (it read both buff+debuff caches). Default HELPFUL, editor
        -- exposes a Buff/Debuff dropdown.
        auraType = "HELPFUL",
        spells = spells or {}, onlyMine = false, onlyMineSpells = {},
        displayType = displayType or "icon",
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        growDirection = "RIGHT", spacing = 2, iconSize = 16, iconsPerRow = 0,
        hideSwipe = false, reverseSwipe = false,
        swipeStyle = "radial",
        duration = { show = false, fontSize = 9, anchor = "CENTER", offsetX = 0, offsetY = 0,
                     color = { 1, 1, 1, 1 } },
        stack = defaultStack(),
        color = { 1, 1, 1 },
        -- Seed a visible bar config up front (a fresh tracked bar is otherwise
        -- near-invisible at renderer defaults).
        bar = { thickness = 12, length = 48 },
    }
end

function E.NewMissingRaidBuffElement()
    local checks = {}
    for key, value in pairs(DEFAULT_MISSING_RAID_BUFF_CHECKS) do checks[key] = value end
    return {
        id = nextId(), enabled = true, mode = "missingRaidBuff",
        classDetection = true, buffChecks = checks,
        anchor = "CENTER", offsetX = 0, offsetY = 0,
        growDirection = "RIGHT", spacing = 2, iconSize = 16, maxIcons = 1, iconsPerRow = 0,
        hideSwipe = true, reverseSwipe = false,
        swipeStyle = "radial",
        duration = { show = false, fontSize = 9, anchor = "CENTER", offsetX = 0, offsetY = 0,
                     color = { 1, 1, 1, 1 } },
        stack = defaultStack(),
    }
end

function E.Validate(e)
    if type(e) ~= "table" then return false end
    if e.mode == "filterStrip" then
        return e.auraType == "HELPFUL" or e.auraType == "HARMFUL"
    elseif e.mode == "tracked" then
        if not DISPLAY_TYPES[e.displayType] then return false end
        return type(e.spells) == "table" and #e.spells > 0
    elseif e.mode == "missingRaidBuff" then
        return true
    end
    return false
end

function E.EffectiveOnlyMine(e, spellID)
    if e.onlyMineSpells and e.onlyMineSpells[spellID] ~= nil then
        return e.onlyMineSpells[spellID]
    end
    return e.onlyMine == true
end

-- Heal a legacy element in place: fold the flat v46 duration/stack fields into
-- the duration{} / stack{} sub-tables and drop knobs that are dead post-PTR4
-- (durationUseTimeColor / showDurationColor / showExpiringPulse required Lua
-- reads of remaining time — secret in combat; the native countdown owns text
-- now). Idempotent; safe on already-normalized elements.
function E.NormalizeElement(e)
    if type(e) ~= "table" then return e end
    if type(e.duration) ~= "table" then
        e.duration = {
            show     = (e.showDurationText ~= false),
            fontSize = e.durationFontSize or 9,
            anchor   = e.durationAnchor or "CENTER",
            offsetX  = e.durationOffsetX or 0,
            offsetY  = e.durationOffsetY or 0,
            color    = e.durationColor or { 1, 1, 1, 1 },
        }
    end
    if type(e.stack) ~= "table" then
        e.stack = defaultStack()
    end
    e.showDurationText = nil
    e.durationFontSize = nil
    e.durationAnchor = nil
    e.durationOffsetX = nil
    e.durationOffsetY = nil
    e.durationColor = nil
    e.durationUseTimeColor = nil
    e.showDurationColor = nil
    e.showExpiringPulse = nil
    if e.mode == "filterStrip" then
        if e.sortRule == nil then e.sortRule = "INDEX" end
        if e.sortReverse == nil then e.sortReverse = false end
        if e.rightClickCancel == nil then e.rightClickCancel = true end
        if e.filterFlags == nil then e.filterFlags = {} end
        -- Tri-state flag values: true = require, "exclude" = negate. Coerce
        -- any other legacy truthy value to true and drop falsy entries, so
        -- the compiler and editor only ever see the two canonical values.
        for tok, v in pairs(e.filterFlags) do
            if v ~= true and v ~= "exclude" then
                e.filterFlags[tok] = v and true or nil
            end
        end
        -- Engine-removed token heal: NOT_CANCELABLE no longer validates (the
        -- engine dropped it; see VALID_FILTER_TOKENS above). A legacy
        -- REQUIRE heals onto the CANCELABLE token's exclude state, unless a
        -- CANCELABLE value is already stored (never clobber it). A legacy
        -- EXCLUDE or a conflicting existing CANCELABLE value just drops — no
        -- invented semantics. Kept OUTSIDE the pairs() loop above: adding a
        -- new key to a table mid-iteration is illegal in Lua 5.1.
        if e.filterFlags.NOT_CANCELABLE ~= nil then
            if e.filterFlags.NOT_CANCELABLE == true and e.filterFlags.CANCELABLE == nil then
                e.filterFlags.CANCELABLE = "exclude"
            end
            e.filterFlags.NOT_CANCELABLE = nil
        end
        if e.dispelFilterMode == nil then e.dispelFilterMode = "off" end
        if type(e.dispelTypes) ~= "table" then e.dispelTypes = {} end
        if type(e.maxDurationSec) ~= "number" then e.maxDurationSec = 0 end
        -- Legacy GF editor spelling: "classification" → canonical "classify"
        -- (CompileFilters keys on "classify"; unmapped, a classified strip
        -- would silently fall to bare polarity = show-everything).
        if e.filterMode == "classification" then e.filterMode = "classify" end
    elseif e.mode == "tracked" then
        if e.auraType == nil then e.auraType = "HELPFUL" end
    end
    return e
end

-- Compile a filterStrip element's filter config into Blizzard filter strings.
-- "classify" fans out one string per enabled classification (OR semantics —
-- one group each). "flags" AND-composes the tri-state filterFlags tokens onto
-- ONE string: `true` = require, `"exclude"` = negate (`!TOKEN`). Required
-- tokens are emitted first, then excluded tokens as `!TOKEN`
-- (`HELPFUL|PLAYER|!CANCELABLE` = helpful AND player AND NOT cancelable —
-- the legacy buffborders/UF filter semantics extended with negation); each
-- group is sorted independently for determinism. "off" and "whitelist"
-- return an EMPTY array — the caller (AuraGlue.ElementGroups) falls back to
-- the bare polarity, with per-spell restriction carried by candidateFilters
-- instead.
-- AuraFilters tokens that are only valid combined with HELPFUL; pairing them
-- with HARMFUL hard-errors in C_UnitAuras.GetUnitAuras (same crash class the
-- HARMFUL classification map avoids structurally). Flags mode takes raw user
-- tokens, so it needs the guard explicitly.
local HELPFUL_ONLY_TOKENS = { RAID_IN_COMBAT = true }

-- Engine-valid AuraFilters components (Blizzard_FrameXMLUtil/AuraUtil.lua
-- AuraUtil.AuraFilters). The container's AddAuraGroup asserts
-- IsValidFilterString on every group registration, and the C-side
-- GetUnitAuras probe in AuraGlue.FilterStringUsable does NOT catch unknown
-- components (the C parser tolerates them) — so an out-of-set token in
-- filterFlags hard-errors the secure config pass. CompileFilters drops
-- unknown tokens instead of emitting them. NOT_CANCELABLE was removed from
-- the engine set (build 68569); Blizzard_DeprecatedAuraFilters only aliases
-- the enum KEY `NotCancelable` to the VALUE "!CANCELABLE" — it does NOT make
-- the literal component NOT_CANCELABLE pass AuraUtil.IsValidFilterString
-- (component validation is by VALUE via EnumUtil.IsValid). The replacement
-- is CANCELABLE excluded (`!CANCELABLE`).
local VALID_FILTER_TOKENS = {
    HELPFUL = true, HARMFUL = true, RAID = true, INCLUDE_NAME_PLATE_ONLY = true,
    PLAYER = true, CANCELABLE = true, MAW = true,
    EXTERNAL_DEFENSIVE = true, CROWD_CONTROL = true, RAID_IN_COMBAT = true,
    RAID_PLAYER_DISPELLABLE = true, BIG_DEFENSIVE = true,
}
E.VALID_FILTER_TOKENS = VALID_FILTER_TOKENS

function E.CompileFilters(element)
    local out = {}
    if element.filterMode == "flags" then
        local flags = element.filterFlags or {}
        local harmful = (element.auraType == "HARMFUL")
        local req, exc = {}, {}
        for tok, v in pairs(flags) do
            -- VALID_FILTER_TOKENS: out-of-set tokens hard-error AddAuraGroup
            -- (the C probe tolerates them; only AuraUtil.IsValidFilterString
            -- rejects) — drop them here, in BOTH directions. The HELPFUL-only
            -- guard is also directionless: a negated helpful-only token
            -- paired with HARMFUL is the same invalid-combo crash class.
            if VALID_FILTER_TOKENS[tok] and not (harmful and HELPFUL_ONLY_TOKENS[tok]) then
                if v == true then
                    req[#req + 1] = tok
                elseif v == "exclude" then
                    exc[#exc + 1] = "!" .. tok
                end
            end
        end
        if #req > 0 or #exc > 0 then
            table.sort(req)
            table.sort(exc)
            local parts = { element.auraType or "HELPFUL" }
            for i = 1, #req do parts[#parts + 1] = req[i] end
            for i = 1, #exc do parts[#parts + 1] = exc[i] end
            out[1] = table.concat(parts, "|")
        end
        return out
    end
    if element.filterMode ~= "classify" then return out end
    local map = (element.auraType == "HARMFUL") and DEBUFF_CLASSIFICATION_MAP or BUFF_CLASSIFICATION_MAP
    local classifications = element.classifications or {}
    local seen = {}
    for key, entry in pairs(map) do
        if IsClassificationEnabled(classifications, key) then
            if type(entry) == "table" then
                for _, fs in ipairs(entry) do
                    if not seen[fs] then seen[fs] = true; out[#out + 1] = fs end
                end
            else
                if not seen[entry] then seen[entry] = true; out[#out + 1] = entry end
            end
        end
    end
    return out
end

-- Compile the element's per-spell / ownership restrictions into engine
-- candidateFilters (vendored 68569, Blizzard_AuraContainerUtil.lua:30
-- DoesAuraPassCandidateFilters). Returns nil when unrestricted.
-- ENGINE LIMITATION (Blizzard_AuraContainerUtil.lua:35): includeSpellIDs /
-- excludeSpellIDs are only evaluated when CanApplyIdentityCandidateFilters
-- passes — helpful auras on assistable units, harmful auras on non-assistable
-- units. A harmful whitelist on a friendly unit is engine-ignored; we pass it
-- through anyway (the gate is dynamic per unit at eval time).
function E.CompileCandidateFilters(element)
    local cf = nil
    local function ensure()
        if not cf then cf = {} end
        return cf
    end
    if element.onlyMine == true then
        ensure().isFromPlayerOrPlayerPet = true
    end
    -- Any non-nil maxDuration implicitly hides permanent auras
    -- (Blizzard_AuraContainerUtil.lua:93). A user-set cap wins; the large
    -- fallback keeps every real timed aura visible for hidePermanent-only.
    -- Engine filters on BASE duration, not remaining time.
    local maxDur = tonumber(element.maxDurationSec) or 0
    if maxDur > 0 then
        ensure().maxDuration = maxDur
    elseif element.hidePermanent == true then
        ensure().maxDuration = 999999
    end
    if element.filterMode == "whitelist" and type(element.whitelist) == "table" and next(element.whitelist) then
        local inc = {}
        for sid, on in pairs(element.whitelist) do
            if on then inc[sid] = true end
        end
        if next(inc) then ensure().includeSpellIDs = inc end
    end
    if type(element.blacklist) == "table" and next(element.blacklist) then
        local exc = {}
        for sid, on in pairs(element.blacklist) do
            if on then exc[sid] = true end
        end
        if next(exc) then ensure().excludeSpellIDs = exc end
    end
    -- Dispel-type filters are NOT identity-gated by the engine — they apply
    -- on every unit (Blizzard_AuraContainerUtil.lua:53-63).
    local dmode = element.dispelFilterMode
    if (dmode == "include" or dmode == "exclude") and type(element.dispelTypes) == "table" then
        local set = {}
        for name, on in pairs(element.dispelTypes) do
            if on then set[name] = true end
        end
        if next(set) then
            if dmode == "include" then
                ensure().includeDispelTypes = set
            else
                ensure().excludeDispelTypes = set
            end
        end
    end
    -- Boolean gates: the engine only accepts true or nil for these
    -- (ValidateCandidateFilters, Blizzard_CustomAuraContainer.lua:121-138);
    -- a false gate must therefore emit NOTHING, not false.
    if element.gateStealable == true then ensure().isStealable = true end
    if element.gateBossAura == true then ensure().isBossAura = true end
    if element.gatePriorityAura == true then ensure().isPriorityAura = true end
    if element.gateRoleAura == true then ensure().isRoleAura = true end
    if element.gateBossOrRoleAura == true then ensure().isBossOrRoleAura = true end
    return cf
end

-- ============================================================================
-- Spec-bucket store: seed-once, id-backfill, override semantics.
-- Ported from QUI_GroupFrames/groupframes/groupframes_aura_model.lua — the
-- semantics (and the reasons in these comments) are unchanged; the shipped
-- default bucket is now a CALLER-SUPPLIED function so each surface seeds its
-- own defaults.
-- ============================================================================

-- Seed the shared "*" bucket exactly ONCE per store. Guarded by
-- auras.elementsSeeded so deleting every element does NOT re-seed on reload —
-- the flag, not bucket presence, is the "already seeded" signal. Also heals
-- legacy stores: drops empty non-"*" buckets left by the old
-- auto-create-on-view (an empty spec bucket would wrongly suppress "*" to
-- nothing), backfills missing/duplicate element ids (render reconciliation
-- keys on element.id — nil throws, duplicates cross-release), and normalizes
-- every element (NormalizeElement).
function E.EnsureSeeded(auras, defaultBucketFn)
    if type(auras) ~= "table" then return end

    if not auras._specBucketsNormalized and type(auras.elements) == "table" then
        auras._specBucketsNormalized = true
        local drop = {}
        for key, bucket in pairs(auras.elements) do
            if key ~= "*" and type(bucket) == "table" and #bucket == 0 then
                drop[#drop + 1] = key
            end
        end
        for _, key in ipairs(drop) do
            auras.elements[key] = nil
        end
    end

    if not auras._elementIDsBackfilled and type(auras.elements) == "table" then
        auras._elementIDsBackfilled = true
        local used = {}
        for _, bucket in pairs(auras.elements) do
            if type(bucket) == "table" then
                for _, e in ipairs(bucket) do
                    local id = type(e) == "table" and e.id
                    if id ~= nil then
                        used[id] = (used[id] or 0) + 1
                        local n = type(id) == "string" and tonumber(id:match("^e(%d+)$"))
                        if n and n > idCounter then idCounter = n end
                    end
                end
            end
        end
        for _, bucket in pairs(auras.elements) do
            if type(bucket) == "table" then
                for _, e in ipairs(bucket) do
                    if type(e) == "table" then
                        local id = e.id
                        if id == nil or used[id] > 1 then
                            if id ~= nil then used[id] = used[id] - 1 end
                            local newId = nextId()
                            while used[newId] do newId = nextId() end
                            e.id = newId
                            used[newId] = 1
                        end
                    end
                end
            end
        end
    end

    -- Normalize every stored element (cheap field checks; idempotent).
    if type(auras.elements) == "table" then
        for _, bucket in pairs(auras.elements) do
            if type(bucket) == "table" then
                for _, e in ipairs(bucket) do E.NormalizeElement(e) end
            end
        end
    end

    if auras.elementsSeeded then return end
    auras.elementsSeeded = true
    auras.elements = auras.elements or {}
    if auras.elements["*"] == nil then
        local bucket = defaultBucketFn and defaultBucketFn() or {}
        for _, e in ipairs(bucket) do E.NormalizeElement(e) end
        auras.elements["*"] = bucket
    end
end

-- OVERRIDE (either/or) semantics: a present spec bucket REPLACES "*" for that
-- spec, never a union. `out` (optional) is a reusable scratch array for the
-- zero-alloc render fan-out.
function E.ActiveElementsForSpec(auras, specID, out)
    if out then
        for i = #out, 1, -1 do out[i] = nil end
    else
        out = {}
    end
    local elements = auras and auras.elements
    if not elements then return out end
    local bucket
    if specID ~= nil and elements[specID] ~= nil then
        bucket = elements[specID]
    else
        bucket = elements["*"]
    end
    if bucket then
        for _, e in ipairs(bucket) do
            if e.enabled ~= false then out[#out + 1] = e end
        end
    end
    return out
end

function E.HasSpecOverride(elements, bucketKey)
    return bucketKey ~= nil and bucketKey ~= "*"
        and type(elements) == "table" and elements[bucketKey] ~= nil
end

function E.EnableSpecOverride(auras, bucketKey)
    if type(auras) ~= "table" or bucketKey == nil or bucketKey == "*" then return end
    auras.elements = auras.elements or {}
    if auras.elements[bucketKey] ~= nil then return end
    local src = auras.elements["*"] or {}
    local copy = {}
    for _, e in ipairs(src) do
        local c = deepCopyTable(e)
        c.id = nextId()
        copy[#copy + 1] = c
    end
    auras.elements[bucketKey] = copy
end

function E.DisableSpecOverride(auras, bucketKey)
    if type(auras) ~= "table" or bucketKey == nil or bucketKey == "*" then return end
    if type(auras.elements) == "table" then
        auras.elements[bucketKey] = nil
    end
end

return E
