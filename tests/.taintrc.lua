-- tests/.taintrc.lua
-- Combat-taint analyzer config. See
-- docs/superpowers/specs/2026-05-04-taint-analyzer-design.md.
return {
    strict_paths = {
        -- Directories ratcheted into CI enforcement. Findings under these
        -- prefixes are classified strict (CI-blocking) instead of advisory.
        -- Add only after auditing — promoted findings must be either fixed
        -- or annotated with `-- @secret-safe: <reason>` to keep CI green.
        "QUI_CDM/cdm/",
        "QUI_Chat/chat/",
        "QUI_GroupFrames/groupframes/",
        "QUI_ActionBars/actionbars/",
        "QUI_DamageMeter/damage_meter/",
    },
    aspect_paths = {
        -- Directories where aspect-returning widget getters (api-index
        -- secretReturnsForAspect: GetText, GetAlpha, IsShown, …) taint their
        -- results. Opt-in per directory: aspect secrets only materialize on
        -- objects whose aspect was secretized (CDM/aura surfaces), so
        -- repo-wide coverage would flood the tiers.
        -- STATUS (2026-07 round-6): still empty — a diagnostic enable of
        -- "QUI_CDM/cdm/" produced 218 strict findings, overwhelmingly aspect
        -- getters on QUI-created chrome frames whose aspects are never
        -- secretized. Blanket enablement needs receiver PROVENANCE (taint
        -- only getters on Blizzard-owned viewer icons/children), which the
        -- analyzer does not model yet — see the 12.1 review follow-up before
        -- adding a path here.
    },
    strict_unwrap_paths = {
        -- Safe* unwrap helpers are stricter in CDM: cooldown-secret values
        -- must stay opaque unless they are passed to approved C-side sinks.
        "QUI_CDM/cdm/",
    },
    ignore_paths = {
        "libs/",
        "tests/",
        "importstrings/",
        "meta/",  -- LuaLS editor-only ---@meta stubs; never loaded in-game
    },
    precondition_only_paths = {
        -- Vendored libraries stay out of the taint tiers (third-party code,
        -- ignore_paths above) but DO get the raw guarded-call scan: the
        -- 2026-07 external review found unguarded RequiresUnitAuraAccess
        -- walks in LibOpenRaid that the libs/ blanket ignore hid.
        "libs/",
    },
    strict_precondition_paths = {
        -- LibOpenRaid's guarded-call sites are all fixed or @secret-safe
        -- annotated (2026-07); promote its precondition findings to strict
        -- so a future lib bump that regresses fails CI instead of hiding
        -- at review tier.
        "libs/LibOpenRaid/",
    },
    event_payload_params = {
        -- UNIT_AURA (SecretWhenAurasRestricted in the api-index): the
        -- OnEvent signature is (self, event, unit, updateInfo). BOTH payload
        -- args can be secret — 12.1 PTR 68569 made the unit token itself
        -- secret under restriction (see
        -- tests/unit/aura_events_secret_boundary_test.lua R1/R2: the
        -- payload unit arg is never trusted, only the registered token). A
        -- handler is detected by its `event == "UNIT_AURA"` comparison (see
        -- analyzer secretEventParamHits for the documented gaps).
        UNIT_AURA = { 3, 4 },
        -- UNIT_AURA_BLOCKED: (self, event, unitTarget, auraInstanceID) —
        -- ONLY auraInstanceID carries SecretValue in the 68675 payload docs
        -- (tests/api-docs/blizzard/UnitAuraDocumentation.lua). The event has
        -- no SecretWhenAurasRestricted flag, so unitTarget is NOT secret here
        -- (unlike UNIT_AURA's whole-payload restriction) — marking it tainted
        -- produced false positives on plain unit-token use.
        UNIT_AURA_BLOCKED = { 4 },
    },
    coverage = {
        secretWhenCooldownsRestricted = true,
        isSecretReturn = true,
        secretArguments_restricted = true,
    },
    extra_safe_sinks = {},
    extra_restriction_gates = {
        -- Module-local wrappers around C_Secrets.ShouldAurasBeSecret. The
        -- analyzer is non-interprocedural, so wrapper CALLS must be
        -- registered by name (round-4 alias resolution surfaced the hoisted
        -- C_UnitAuras refs these wrappers gate).
        "AurasAreSecret",           -- groupframes_auras / groupframes_missing_raid_buffs
        "AreAurasSecret",           -- cdm_sources local re-import
        "CDMSources.AreAurasSecret",
    },
    extra_unwraps = {
        -- QUI imports Helpers.Safe* as bare locals at file scope and calls
        -- them by short name. Register the short forms so the analyzer
        -- recognizes those call sites as unwraps (review-tier findings).
        "SafeValue",
        "SafeToNumber",
        "SafeToString",
        "SafeCompare",
    },
    clean_fields = {
        -- Field names that are always non-secret per Blizzard's API contract.
        -- When the analyzer sees `tainted_local.<field>` for any of these,
        -- it treats the read as clean instead of propagating taint.
        "isOnGCD",  -- SpellCooldownInfo.isOnGCD is always a clean boolean
    },
}
