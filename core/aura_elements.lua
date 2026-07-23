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

-- "border" is a frame-level indicator like "healthTint": presence of any matched
-- tracked spell tints a colored outline around the unit frame (not a slot). It is
-- an engine feeder (see EngineRendersElement / relevance), not a container group.
local DISPLAY_TYPES = { icon = true, square = true, bar = true, healthTint = true, border = true }
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
-- 12.1.0.68675 dispel-filter semantics (Blizzard_FrameXMLUtil/AuraUtil.lua
-- AuraFilters): RAID on HARMFUL = "harmful auras the PLAYER can dispel";
-- RAID_PLAYER_DISPELLABLE = "auras SOMEONE in the player's raid can dispel
-- (including helpful enrages on enemies)". The "dispellable" intent is
-- labeled "Dispellable by me" in the editor, so it compiles to HARMFUL|RAID
-- — RAID_PLAYER_DISPELLABLE would show raid-wide dispels the player cannot
-- touch. (Pre-68675 both strings behaved close enough that the distinction
-- never surfaced; the 68675 corpus made it explicit.)
local DEBUFF_CLASSIFICATION_MAP = {
    harmful      = { "HARMFUL|RAID" },
    raid         = "HARMFUL|RAID",
    dispellable  = "HARMFUL|RAID",
    crowdControl = "HARMFUL|CROWD_CONTROL",
}

-- Wave 4 Task 2b — classification EXCLUSIVITY. Before this, "classify" mode's
-- OR fan-out built one group per ticked category with NO relationship between
-- them: an aura matching two ticked categories (e.g. a big-defensive that is
-- also cancelable) rendered in BOTH groups, each at the element's full
-- maxIcons — an honesty gap alongside 2a's cap relabel. The fix: give the
-- editor's checkbox lists (HELPFUL_CLASSIFICATIONS / HARMFUL_CLASSIFICATIONS,
-- QUI_Options/aura_elements_editor.lua) a FIXED priority order — reusing that
-- exact order, so "first ticked category (top of the list) wins the overlap"
-- matches what the user sees top-to-bottom — and append `!TOKEN` negations of
-- every HIGHER-priority ENABLED category to each lower one's compiled string.
-- Negating a category is De Morgan on its single-component clause: a
-- positive-token category ("RAID") negates to an exclusion ("!RAID"); an
-- already-negated category (notCancelable, "!CANCELABLE") negates to the
-- bare positive token ("CANCELABLE") — see NegateComponent below. Only the
-- HIGHER-priority category's own negation is threaded forward (never
-- backward), so a strictly-below category can never influence one above it.
--
-- Scope, deliberately narrow: restricted to the keys the editor actually
-- exposes (HELPFUL_CLASSIFICATIONS / HARMFUL_CLASSIFICATIONS). The legacy
-- master keys (`helpful`, `harmful`) and `dispellable` are NOT in these lists
-- — grepped repo-wide, none of the three is ever set outside this map or a
-- captured pre-merge profile shape the migration heals TO `helpful`/`harmful`
-- (core/compatibility.lua); no live editor control writes them. They keep
-- compiling through the UNCHANGED legacy path below (CompileFilters' second
-- loop), so old profiles carrying them never regress. Extending exclusivity
-- to them would also be unsound as a blanket rule: `helpful` fans out to TWO
-- strings (RAID and RAID_IN_COMBAT) — De Morgan on an OR of two clauses needs
-- BOTH negated components threaded together, which the single-component
-- accumulator below doesn't model, and no live data ever exercises it.
local BUFF_CLASSIFICATION_PRIORITY = {
    "raid", "raidInCombat", "cancelable", "notCancelable", "bigDefensive", "externalDefensive",
}
local DEBUFF_CLASSIFICATION_PRIORITY = {
    "raid", "crowdControl",
}

-- Pull the single non-polarity component out of a ranked classification's
-- map entry, e.g. "HELPFUL|BIG_DEFENSIVE" -> "BIG_DEFENSIVE",
-- "HELPFUL|!CANCELABLE" -> "!CANCELABLE". Every key referenced by the two
-- PRIORITY lists above maps to exactly one such single-component string (not
-- the two-string `helpful`/`harmful` shape) — verified by inspection of the
-- two maps just above. Returns nil on anything else (defensive; the ranked
-- loop below treats nil as "nothing to compile", never invents a token).
local function ClassificationComponent(entry)
    local fs = type(entry) == "string" and entry or nil
    if not fs then return nil end
    local comp = fs:match("^[A-Z_]+|(.+)$")
    return comp
end

-- De Morgan on a single-literal clause: the negation of "has TOKEN"
-- (required) is "lacks TOKEN" (excluded), and vice versa. Returns
-- (token, becomesRequired) — becomesRequired is true when the NEGATED clause
-- is a requirement (i.e. the source component was itself an exclusion).
local function NegateComponent(comp)
    if comp:sub(1, 1) == "!" then
        return comp:sub(2), true
    end
    return comp, false
end

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

-- Healer HoTs (v57) — canonical spell-id source. An upcoming PTR build makes
-- ~42 healer HoT/absorb ids secret in combat; engine-rendered tracked slots
-- (core/aura_slots.lua) render secret auras C-side, but the legacy Lua-side
-- spellID match (buffsBySpellID) cannot see them and silently drops the
-- icon. This is the SINGLE physical copy of the non-secret union: every
-- consumer that needs to CONSTRUCT the shipped "healerHoTs" tracked element
-- calls HealerHoTSpellIDs() below instead of declaring its own literal —
-- QUI_GroupFrames/groupframes/groupframes_aura_model.lua
-- Model.HealerHoTElement (the runtime latch-time default, called from
-- Model.DefaultStripBucket) and core/migrations.lua
-- Migrations.SeedHealerHoTElements (the legacy-latch v57 migration) both
-- read this exact list, so those two can never drift apart from each other.
-- Ground truth for WHAT belongs in this list remains the Options-side
-- QUI_GroupFrames/groupframes/settings/group_frames_aura_defaults.lua
-- SPEC_AURA_PRESETS table, which carries the per-spell `secret` annotation
-- this core file structurally cannot see (core loads before every
-- sub-addon, including QUI_GroupFrames — see the v57 doc comment in
-- core/migrations.lua). That file's AuraDefaults.SeedHealerHoTElements
-- independently re-derives the non-secret union from SPEC_AURA_PRESETS
-- purely so tests/unit/migration_v57_hot_element_seed_test.lua can pin this
-- list against it (set AND order) — an edit to the presets that isn't
-- mirrored here fails that test instead of silently drifting.
local HEALER_HOT_SPELL_IDS = {
    -- Restoration Druid
    774, 8936, 33763, 155777, 48438, 474754, 439530,
    -- Restoration Shaman
    61295, 383648, 974, 207400, 382024, 444490,
    -- Holy Paladin
    156910, 156322, 53563, 1244893, 200025,
    -- Discipline Priest
    17, 194384, 1253593, 41635,
    -- Holy Priest (41635 Prayer of Mending already counted above)
    139, 77489,
    -- Mistweaver Monk
    119611, 124682, 115175, 450769,
    -- Preservation Evoker
    364343, 366155, 367364, 355941, 376788, 363502, 373267,
    -- Augmentation Evoker
    410089, 413984, 360827, 410263, 410686, 395152, 369459,
}

-- Fresh copy every call. The returned array becomes an element's stored
-- `.spells` field once handed to NewTrackedElement, and the tracked-element
-- editor (QUI_Options/aura_elements_editor.lua) mutates that array IN PLACE
-- (add/remove spell rows) — handing the SAME table object to every caller
-- would let editing one profile's healerHoTs element corrupt this shared
-- canonical list for every other latch in the session (and every profile
-- switch afterward). Callers must never receive the raw table above.
function E.HealerHoTSpellIDs()
    local out = {}
    for i, id in ipairs(HEALER_HOT_SPELL_IDS) do out[i] = id end
    return out
end

function E.NewFilterStripElement(auraType)
    return {
        id = nextId(), enabled = true, mode = "filterStrip",
        auraType = auraType or "HELPFUL",
        applyToRoles = "all",
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
        onlyMine = false, hidePermanent = false,
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
        -- Per-frame role gate: "all" (every frame) | "tank" | "healer" | "dps" |
        -- "me" (player's frame only). Resolved out of combat on roster events, so a
        -- role-mismatched element is simply absent from the frame's active list.
        applyToRoles = "all",
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
        -- "border" displayType: outline thickness (px) drawn around the frame in
        -- element.color when a matched spell is present.
        border = { thickness = 2 },
    }
end

function E.NewMissingRaidBuffElement()
    local checks = {}
    for key, value in pairs(DEFAULT_MISSING_RAID_BUFF_CHECKS) do checks[key] = value end
    return {
        id = nextId(), enabled = true, mode = "missingRaidBuff",
        applyToRoles = "all",
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
        if type(e.dispelTypes) ~= "table" and e.dispelTypes ~= "mine" then e.dispelTypes = {} end
        if type(e.maxDurationSec) ~= "number" then e.maxDurationSec = 0 end
        -- Legacy GF editor spelling: "classification" → canonical "classify"
        -- (CompileFilters keys on "classify"; unmapped, a classified strip
        -- would silently fall to bare polarity = show-everything).
        if e.filterMode == "classification" then e.filterMode = "classify" end
    elseif e.mode == "tracked" then
        if e.auraType == nil then e.auraType = "HELPFUL" end
        if type(e.border) ~= "table" then e.border = { thickness = 2 } end
    end
    -- applyToRoles gate (all modes): absent legacy elements are unrestricted.
    if e.applyToRoles == nil then e.applyToRoles = "all" end
    return e
end

-- Role-gate check: does an element apply to a frame whose unit resolves to
-- `frameRole` ("TANK"/"HEALER"/"DAMAGER"/nil) and is-player `isSelf`? "all" and
-- a nil/unknown gate always pass (backward-compatible). Roles are stable within
-- an encounter, so this is only re-evaluated on roster/spec events (OOC).
local ROLE_GATE_TO_ASSIGNED = { tank = "TANK", healer = "HEALER", dps = "DAMAGER" }
function E.ElementAppliesToRole(element, frameRole, isSelf)
    local gate = element and element.applyToRoles
    if gate == nil or gate == "all" then return true end
    if gate == "me" then return isSelf == true end
    local want = ROLE_GATE_TO_ASSIGNED[gate]
    if not want then return true end  -- unknown token: fail open, never hide
    return frameRole == want
end

local WHAT_TO_SHOW_KEYS = {
    HELPFUL = { "all", "mine", "defensives", "purgeable", "whitelist" },
    HARMFUL = { "all", "dispellable", "crowdControl", "boss", "roleBoss", "whitelist" },
}

function E.WhatToShowKeys(auraType)
    return WHAT_TO_SHOW_KEYS[auraType] or WHAT_TO_SHOW_KEYS.HELPFUL
end

local function clearShowFields(e)
    e.filterMode = "off"
    e.filterFlags = {}
    e.classifications = defaultClassifications(e.auraType)
    e.onlyMine = false
    e.dispelFilterMode = "off"
    e.dispelTypes = {}
    e.gateStealable = nil
    e.gateBossAura = nil
    e.gatePriorityAura = nil
    e.gateRoleAura = nil
    e.gateBossOrRoleAura = nil
end

function E.ApplyWhatToShow(element, key)
    clearShowFields(element)
    if key == "mine" then
        element.onlyMine = true
    elseif key == "defensives" then
        element.filterMode = "classify"
        element.classifications = { bigDefensive = true, externalDefensive = true }
    elseif key == "purgeable" then
        element.gateStealable = true
    elseif key == "dispellable" then
        -- Engine-evaluated "player can dispel this" (HARMFUL|RAID — 68675
        -- semantics; RAID_PLAYER_DISPELLABLE means "anyone in the raid can
        -- dispel" and is the wrong filter for a personal cleanse view): the
        -- C side knows the player's ACTUAL dispel kit including talents, and
        -- tracks respecs live — strictly better than our class/spec school
        -- table (ns.QUI_DispelRoles), which stays only as the resolver for
        -- manual dispel-TYPE filters ("mine" sentinel) and the dispel-roles
        -- page.
        element.filterMode = "classify"
        element.classifications = { dispellable = true }
    elseif key == "crowdControl" then
        element.filterMode = "classify"
        element.classifications = { crowdControl = true }
    elseif key == "boss" then
        element.gateBossAura = true
    elseif key == "roleBoss" then
        element.gateBossOrRoleAura = true
    elseif key == "whitelist" then
        element.filterMode = "whitelist"
    end
    -- key == "all" (or unknown) leaves the cleared/default state
    return element
end

-- true iff every listed key is true in tbl AND no other key in tbl is true
local function onlyClassKeys(tbl, wanted)
    local want = {}
    for _, k in ipairs(wanted) do want[k] = true; if tbl[k] ~= true then return false end end
    for k, v in pairs(tbl) do
        if v == true and not want[k] then return false end
    end
    return true
end

function E.DeriveWhatToShow(element)
    local mode = element.filterMode or "off"
    if mode == "whitelist" then return "whitelist" end
    if mode == "flags" then return "custom" end
    if mode == "classify" then
        local c = element.classifications or {}
        if onlyClassKeys(c, { "bigDefensive", "externalDefensive" }) then return "defensives" end
        if onlyClassKeys(c, { "crowdControl" }) then return "crowdControl" end
        if onlyClassKeys(c, { "dispellable" }) then return "dispellable" end
        return "custom"
    end
    -- mode == "off": any of these fields make it non-default and unrecognised -> custom
    if next(element.filterFlags or {}) ~= nil then return "custom" end
    if element.dispelFilterMode == "exclude" then return "custom" end
    if element.gatePriorityAura == true or element.gateRoleAura == true then return "custom" end
    local mods = {}
    if element.onlyMine == true then mods[#mods + 1] = "mine" end
    if element.gateStealable == true then mods[#mods + 1] = "purgeable" end
    if element.gateBossAura == true then mods[#mods + 1] = "boss" end
    if element.gateBossOrRoleAura == true then mods[#mods + 1] = "roleBoss" end
    if element.dispelFilterMode == "include" then mods[#mods + 1] = "dispellable" end
    if #mods == 0 then return "all" end
    if #mods == 1 then return mods[1] end
    return "custom"
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
    -- 68675 additions: IMPORTANT (helpful auras shown on enemy nameplates
    -- even when non-stealable), DISPELLABLE (dispellable by ANY source,
    -- regardless of the player's raid).
    IMPORTANT = true, DISPELLABLE = true,
}
E.VALID_FILTER_TOKENS = VALID_FILTER_TOKENS

-- Tokens whose NEGATION the engine silently ignores (AuraUtil.lua:
-- "IncludeNameplateOnly and Maw filters are not negatable (negation will be
-- ignored if applied)"). !INCLUDE_NAME_PLATE_ONLY still VALIDATES but means
-- nothing — and since ABSENCE of these tokens already filters the category
-- out, an "exclude" tri-state compiles to simply omitting the token: same
-- matching behavior, no dead component in the string.
local NON_NEGATABLE_TOKENS = { INCLUDE_NAME_PLATE_ONLY = true, MAW = true }

-- Filter-string canonicalization (Wave 4 Task 4 — filter-group retention).
-- PTR4 aura groups are addon-unremovable and core/aura_skin.lua Configure
-- keys its registry entry on `gkey.."|"..filter` (see that file's header) —
-- every DISTINCT filter string therefore retains its own orphaned group
-- until reload. CanonicalizeFilterString is the ONE pure function that
-- normalizes a filter string to a stable, deterministic form so
-- semantically-equal strings collapse onto the same registry key, wired at
-- BOTH ends: AuraGlue.ElementGroups (the string's producer / "storage") and
-- AuraSkin.Configure's key derivation (the consumer choke point named
-- above) — see core/aura_glue.lua and core/aura_skin.lua.
--
-- Grammar (Blizzard_FrameXMLUtil/AuraUtil.lua:291-313 IsValidFilterString,
-- vendored tests/framexml/.../AuraUtil.lua): components are delimited by
-- ANY of "|" or space (string.split("| ", filterString)), each optionally
-- "!"-negated, each validated INDEPENDENTLY by exact-case membership in the
-- fixed AuraFilters enum (EnumUtil.IsValid → tContains, case-sensitive).
-- Position never affects validity — confirmed against the vendored source:
-- "RAID|HELPFUL|!CANCELABLE" validates identically to
-- "HELPFUL|RAID|!CANCELABLE". This is the SAME assumption CompileFilters
-- above already relies on (table.sort on its req/exc arrays) — sorting
-- within the two commutative scopes (required tokens, excluded tokens) is
-- therefore safe and mirrors that existing, shipped convention exactly
-- (polarity leads if present, then requires sorted, then !excludes sorted).
-- Dual-polarity edge: a string carrying BOTH polarities keeps the first-seen
-- polarity in the lead slot, so Canon("HELPFUL|HARMFUL") ~= Canon("HARMFUL|
-- HELPFUL"). Unreachable from any QUI producer (auraType is single-valued);
-- idempotence and validity still hold — documented, not defended.
-- Caveat (honest scope of that proof): IsValidFilterString proves SYNTAX
-- order-independence only; the C-side MATCHING behavior of a reordered
-- string is unverifiable headless. It is well-founded — CompileFilters has
-- shipped sorted output since the tri-state expansion, so every live group
-- already runs on engine-sorted strings — but strictly in-game-confirmed
-- only for the orderings CompileFilters itself emits.
--
-- Validity-preserving BY CONSTRUCTION, not by re-deriving IsValidFilterString
-- from scratch: canonicalization only reorders/dedupes/case-folds a string
-- that IsKnownFilterString already accepts as well-formed (every component
-- an exact-case AuraFilters token, no bare "!"); anything it does NOT
-- accept is returned UNCHANGED. So IsValidFilterString(canonical) ==
-- IsValidFilterString(raw) holds in both directions:
--   * raw well-formed -> canonical is a reordered/deduped set of the SAME
--     already-uppercase tokens -> still valid (component validity is
--     position- and duplicate-independent, proven above -> reordering/
--     dedup can't newly invalidate it).
--   * raw NOT well-formed (unknown token, bare "!") -> passthrough,
--     output == input -> validity trivially unchanged.
-- This is deliberately narrower than "case-fold anything typed": a
-- case-only-invalid raw string (e.g. "helpful|raid" — invalid because the
-- engine validator is exact-case) is left untouched rather than repaired,
-- because repairing it would flip invalid -> valid and break the invariant
-- above. In THIS codebase that narrowing costs nothing live: every
-- filter-affecting editor control is a checkbox/dropdown that writes
-- pre-validated uppercase tokens (QUI_Options/aura_elements_editor.lua
-- FILTER_MODE_OPTIONS/TRI_STATE_OPTIONS/classification checkboxes) — there
-- is no free-text filter-string input anywhere in the editor (verified: the
-- only EditBox reachable from a filterStrip element is the whitelist/
-- blacklist manual spell-ID field, which never touches a filter string).
local function IsKnownFilterString(filterString)
    if type(filterString) ~= "string" or filterString == "" then return false end
    local any = false
    -- Delimiter set is the engine's LITERAL pair — "|" and space ONLY
    -- (string.split("| ", filterString) in the vendored validator), NOT the
    -- %s class: the engine treats a tab/newline as part of a component, so
    -- e.g. "HELPFUL\tRAID" is ONE unknown component (invalid). A %s split
    -- here would accept it and re-emit it pipe-joined — flipping invalid
    -- raw -> valid canonical and breaking the validity-preservation
    -- invariant documented above.
    for component in filterString:gmatch("[^| ]+") do
        any = true
        local negated = component:sub(1, 1) == "!"
        local tok = negated and component:sub(2) or component
        if tok == "" then return false end -- bare "!" — invalid (matches the engine)
        if not VALID_FILTER_TOKENS[tok] then return false end
    end
    return any
end
E.IsKnownFilterString = IsKnownFilterString

function E.CanonicalizeFilterString(filterString)
    if not IsKnownFilterString(filterString) then
        return filterString
    end
    local reqSeen, excSeen = {}, {}
    local req, exc = {}, {}
    local polarity
    -- Same LITERAL "|"/space delimiter set as IsKnownFilterString above —
    -- the two loops must tokenize identically or the guard proves nothing
    -- about what this loop re-emits.
    for component in filterString:gmatch("[^| ]+") do
        local negated = component:sub(1, 1) == "!"
        -- Case normalization: a no-op on this guarded path today (every
        -- accepted token is already exact-case-valid, hence already
        -- uppercase), kept explicit so the contract holds even if a future
        -- token or caller relaxes that guarantee.
        local tok = (negated and component:sub(2) or component):upper()
        if negated then
            if not excSeen[tok] then excSeen[tok] = true; exc[#exc + 1] = tok end
        elseif (tok == "HELPFUL" or tok == "HARMFUL") and not polarity then
            polarity = tok
        elseif not reqSeen[tok] then
            reqSeen[tok] = true; req[#req + 1] = tok
        end
    end
    table.sort(req)
    table.sort(exc)
    local parts = {}
    if polarity then parts[#parts + 1] = polarity end
    for i = 1, #req do parts[#parts + 1] = req[i] end
    for i = 1, #exc do parts[#parts + 1] = "!" .. exc[i] end
    return table.concat(parts, "|")
end

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
                elseif v == "exclude" and not NON_NEGATABLE_TOKENS[tok] then
                    -- Non-negatable tokens (nameplate-only / Maw): the engine
                    -- ignores their "!" form, and absence already excludes
                    -- the category — omit instead of emitting a dead token.
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
    local harmful = (element.auraType == "HARMFUL")
    local map = harmful and DEBUFF_CLASSIFICATION_MAP or BUFF_CLASSIFICATION_MAP
    local priority = harmful and DEBUFF_CLASSIFICATION_PRIORITY or BUFF_CLASSIFICATION_PRIORITY
    local classifications = element.classifications or {}
    local seen = {}
    local handled = {}
    -- Ranked pass (2b): the priority-ordered, editor-exposed categories.
    -- requireAcc/excludeAcc accumulate the negation of every HIGHER-priority
    -- ENABLED category as the loop walks down the list, so each category's
    -- string carries the full set of exclusions needed to stay exclusive
    -- against everything ranked above it.
    local requireAcc, excludeAcc = {}, {}
    for _, key in ipairs(priority) do
        handled[key] = true
        local comp = ClassificationComponent(map[key])
        if comp and IsClassificationEnabled(classifications, key) then
            local reqSeen, excSeen = {}, {}
            local req, exc = {}, {}
            local ownNegated = comp:sub(1, 1) == "!"
            local ownTok = ownNegated and comp:sub(2) or comp
            if ownNegated then
                excSeen[ownTok] = true; exc[#exc + 1] = ownTok
            else
                reqSeen[ownTok] = true; req[#req + 1] = ownTok
            end
            for tok in pairs(requireAcc) do
                if not reqSeen[tok] then reqSeen[tok] = true; req[#req + 1] = tok end
            end
            for tok in pairs(excludeAcc) do
                if not excSeen[tok] then excSeen[tok] = true; exc[#exc + 1] = tok end
            end
            -- Unsatisfiability guard: a token landing in BOTH the require and
            -- exclude sets means two ENABLED higher-priority categories are
            -- literal complements (the only such pair in the maps today:
            -- cancelable = CANCELABLE, notCancelable = !CANCELABLE). Together
            -- they exhaust the domain — every aura matches exactly one of the
            -- two — so any aura this category could show is ALREADY claimed
            -- by one of those two higher groups. The merged string (e.g.
            -- "HELPFUL|BIG_DEFENSIVE|CANCELABLE|!CANCELABLE") is syntactically
            -- valid but can never match; emitting it would register a dead,
            -- unremovable engine group that silently renders zero icons.
            -- SKIPPING the group is therefore semantically exact, not lossy:
            -- no aura exists that matches this category yet neither
            -- complement. (The category still contributes its own negation
            -- below — moot in practice, since the accumulators only grow and
            -- every later category inherits the same contradictory pair and
            -- skips too, but kept unconditional so the contribution rule
            -- stays uniform.)
            local unsatisfiable = false
            for i = 1, #req do
                if excSeen[req[i]] then unsatisfiable = true; break end
            end
            if not unsatisfiable then
                table.sort(req)
                table.sort(exc)
                local parts = { element.auraType or "HELPFUL" }
                for i = 1, #req do parts[#parts + 1] = req[i] end
                for i = 1, #exc do parts[#parts + 1] = "!" .. exc[i] end
                local fs = table.concat(parts, "|")
                if not seen[fs] then seen[fs] = true; out[#out + 1] = fs end
            end

            -- Contribute THIS category's own negation forward, for every
            -- lower-priority category processed after it.
            local negTok, becomesRequired = NegateComponent(comp)
            if becomesRequired then
                requireAcc[negTok] = true
            else
                excludeAcc[negTok] = true
            end
        end
    end
    -- Legacy pass: any map key the ranked list above doesn't cover (the
    -- `helpful`/`harmful` master keys, `dispellable` — none reachable via the
    -- editor, see the priority-list comment above) compiles EXACTLY as before
    -- 2b: bare, unnegated, no participation in the exclusivity scheme either
    -- direction.
    for key, entry in pairs(map) do
        if not handled[key] and IsClassificationEnabled(classifications, key) then
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
    if dmode == "include" or dmode == "exclude" then
        local types = element.dispelTypes
        if types == "mine" then
            -- Sentinel from ApplyWhatToShow("dispellable"): resolve to the
            -- player's class/spec capability at compile time so respecs are
            -- picked up on the next refresh (aura_context re-fires the
            -- surface refresh on PLAYER_SPECIALIZATION_CHANGED). pcall: the
            -- headless harness has no UnitClass — that (or a missing module)
            -- falls back to the four base schools.
            local DR = ns and ns.QUI_DispelRoles
            local ok, mine = false, nil
            if DR and type(DR.PlayerDispelSchools) == "function" then
                ok, mine = pcall(DR.PlayerDispelSchools)
            end
            types = (ok and type(mine) == "table" and mine)
                or { Magic = true, Curse = true, Disease = true, Poison = true }
            if dmode == "include" and next(types) == nil then
                -- A class with no dispel (e.g. Warrior) must match NOTHING,
                -- not everything: an empty include set would emit no filter
                -- at all and broaden the strip to every debuff. No real
                -- dispelName ever matches this key (nil dispelName reads
                -- tbl[nil] -> nil -> filtered).
                types = { ["QUI-none"] = true }
            end
        end
        if type(types) == "table" then
            local set = {}
            for name, on in pairs(types) do
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
        local seen = {} -- every id in the store: fresh ids must collide with none
        for _, bucket in pairs(auras.elements) do
            if type(bucket) == "table" then
                for _, e in ipairs(bucket) do
                    local id = type(e) == "table" and e.id
                    if id ~= nil then
                        seen[id] = true
                        local n = type(id) == "string" and tonumber(id:match("^e(%d+)$"))
                        if n and n > idCounter then idCounter = n end
                    end
                end
            end
        end
        -- Uniqueness is PER BUCKET: only one bucket is ever active on a
        -- surface, so render reconciliation (frame state keyed on element.id)
        -- never sees two live elements sharing an id. Fixed-id elements
        -- (id = "defensives" / "encounterBoss") legitimately recur across
        -- spec buckets — a cross-bucket rewrite would orphan a cloned strip
        -- from its FindBossStrip-style lookup and spawn a duplicate on the
        -- next write to that bucket.
        for _, bucket in pairs(auras.elements) do
            if type(bucket) == "table" then
                local inBucket = {}
                for _, e in ipairs(bucket) do
                    if type(e) == "table" then
                        if e.id == nil or inBucket[e.id] then
                            local newId = nextId()
                            while seen[newId] do newId = nextId() end
                            e.id = newId
                            seen[newId] = true
                        end
                        inBucket[e.id] = true
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

-- Enforce the single-strip invariant for surfaces whose buckets are
-- polarity-scoped (buff borders: buffAuras/debuffAuras). Keeps the FIRST
-- filterStrip in the shared "*" bucket, removes later filterStrips, forces
-- the survivor's auraType (when given) and enabled=true — zone visibility on
-- those surfaces is the settings-level toggle, not the element flag.
-- Non-strip elements are left alone. Idempotent; mutates in place; returns
-- true iff anything changed. Runs on the BB runtime resolve path every load
-- (dev/hand-edited SVs may hold extra or cross-polarity strips from before
-- the single-strip collapse; EnsureSeeded's latch means it never re-seeds).
function E.NormalizeSingleStripBucket(store, auraType)
    if type(store) ~= "table" or type(store.elements) ~= "table" then
        return false
    end
    local bucket = store.elements["*"]
    if type(bucket) ~= "table" then
        return false
    end
    local firstIndex
    for i = 1, #bucket do
        local e = bucket[i]
        if type(e) == "table" and e.mode == "filterStrip" then
            firstIndex = i
            break
        end
    end
    if not firstIndex then
        return false
    end
    local changed = false
    for i = #bucket, firstIndex + 1, -1 do
        local e = bucket[i]
        if type(e) == "table" and e.mode == "filterStrip" then
            table.remove(bucket, i)
            changed = true
        end
    end
    local strip = bucket[firstIndex]
    if auraType and strip.auraType ~= auraType then
        strip.auraType = auraType
        changed = true
    end
    if strip.enabled ~= true then
        strip.enabled = true
        changed = true
    end
    return changed
end

-- OVERRIDE (either/or) semantics: a present spec bucket REPLACES "*" for that
-- spec, never a union. `out` (optional) is a reusable scratch array for the
-- zero-alloc render fan-out. `contextKeys` (optional) is an array of string
-- bucket keys tried in order BEFORE specID; the first present bucket wins
-- and specID/"*" are skipped entirely. Behavior is identical to the 2/3-arg
-- form when `contextKeys` is nil (or resolves to no match).
function E.ActiveElementsForSpec(auras, specID, out, contextKeys)
    if out then
        for i = #out, 1, -1 do out[i] = nil end
    else
        out = {}
    end
    local elements = auras and auras.elements
    if not elements then return out end
    local bucket
    if type(contextKeys) == "table" then
        for _, k in ipairs(contextKeys) do
            if k ~= nil and elements[k] ~= nil then bucket = elements[k]; break end
        end
    end
    if not bucket then
        if specID ~= nil and elements[specID] ~= nil then bucket = elements[specID]
        else bucket = elements["*"] end
    end
    if bucket then
        for _, e in ipairs(bucket) do
            if e.enabled ~= false then out[#out + 1] = e end
        end
    end
    return out
end

-- Largest element count across EVERY bucket in the store ("*", spec, instance,
-- encounter). Callers size a per-frame container pool to this so a bucket switch
-- that ADDS elements (e.g. an encounter's boss-ability indicators) never needs
-- forbidden container CREATION mid-combat -- the union is pre-created out of
-- combat and the switch is pure mutation on pull. Over-counts harmlessly:
-- health-tint / border elements draw no container, so a pool sized to the raw
-- max simply leaves a few slots disabled. Returns 0 for an empty/absent store.
function E.MaxBucketElementCount(auras)
    local elements = auras and auras.elements
    if type(elements) ~= "table" then return 0 end
    local max = 0
    for _, bucket in pairs(elements) do
        if type(bucket) == "table" and #bucket > max then max = #bucket end
    end
    return max
end

-- Builds the elements-table bucket key for an instance/context (e.g. a
-- Journal mapID), used as an optional cascade rung tried before specID via
-- `contextKeys`. Returns nil for anything that isn't a positive number so
-- callers can pass it straight through without a guard.
function E.InstanceBucketKey(mapID)
    if type(mapID) == "number" and mapID > 0 then
        return "i" .. mapID
    end
    return nil
end

-- Builds the elements-table bucket key for a specific encounter (Journal /
-- ENCOUNTER_START encounterID). Tried BEFORE the instance key in the cascade so
-- a boss delta overrides its instance's delta. Returns nil for non-positive ids.
function E.EncounterBucketKey(encounterID)
    if type(encounterID) == "number" and encounterID > 0 then
        return "e" .. encounterID
    end
    return nil
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
        -- Fixed semantic ids ("defensives"/"encounterBoss") must survive the
        -- clone: FindBossStrip-style lookups key on them PER BUCKET, and the
        -- normalize pass explicitly lets them recur across buckets (only one
        -- bucket is ever active). Re-keying one would orphan the cloned strip
        -- from its lookup and spawn a duplicate on the next write. Only
        -- generated "e<N>" ids are re-keyed.
        if type(c.id) ~= "string" or c.id:match("^e%d+$") then
            c.id = nextId()
        end
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
