--[[
    QUI Nameplates — shared state and settings access.

    Loads first in the suite. Owns the module table (ns.QUI_Nameplates), the
    unit → plate registry, the appearance generation counter, and the
    settings getter. Satellites nil-guard on ns.QUI_Nameplates.

    THE SECRET-VALUE RULEBOOK (all suite files; strict taint tier enforces it)
    ------------------------------------------------------------------------
    Sinks that accept secrets: SetValue/SetMinMaxValues, SetText/
    SetFormattedText (C-side; %.0f/%.1f/%s ONLY, never %d — integer coercion
    on a secret silently no-ops the whole call), SetTexture, SetAlpha,
    SetAlphaFromBoolean, SetCooldownFromDurationObject, SetTimerDuration,
    SetCountdownFormatter, curve evaluation, C_StringUtil.*, AbbreviateNumbers.

    House idioms:
    * Health/absorb VALUES flow raw into StatusBars; zero-checks only behind
      Helpers.IsSecretValue gates + SafeToNumber.
    * Health PERCENT is never computed: UnitHealthPercent(unit, usePredicted,
      CurveConstants.ScaleTo100) under pcall (returns secret at full HP —
      never nil-compare), formatted with SetFormattedText("%.0f%%", ...).
    * Dirty-checks: `if IsSecretValue(v) or v ~= cache then ... if not
      IsSecretValue(v) then cache = v end` — secret ⇒ always write, never cache.
    * Existence checks on possibly-secret returns: type(x) == "nil" (type()
      is safe); NEVER truthiness, equality, or #.
    * Names: Helpers.TruncateUTF8 (secret-safe) straight into SetText;
      keep-last-good on transient !UnitExists.
    * Secret booleans route into SetAlphaFromBoolean /
      EvaluateColorValueFromBoolean chains; a user toggle (clean boolean)
      gates whether the secret is consumed at all.
    * End-of-cast/teardown decisions use UnitExists (plain false), never
      UnitCastingInfo truthiness ("stale secret channel info" hazard).

    Verified 12.0 environmental facts (each earned a scar in the references):
    * There is ONE C_NamePlate.SetNamePlateSize(w, h) — per-reaction variants
      are gone. It grows from CENTER (no Y-compensation).
    * SetStackingBoundsFrame reads RENDERED region bounds — the bounds frame
      needs an alpha-0 full-size texture or it contributes nothing.
    * SetFillStyle re-enables pixel snapping — re-disable after, or fill-edge
      ticks dance.
    * Blizzard UnitFrame suppression must be UNCONDITIONAL — first-frame
      UnitCanAttack lies.
    * C_NamePlateManager.SetNamePlateHitTestInsets is SecretArguments =
      NotAllowed — plain numbers only.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local NP = {}
ns.QUI_Nameplates = NP

-- unit token → plate frame (enemy pool)
NP.plates = {}

-- unit token → friendly bars-mode plate (separate thinner pool; friendly.lua)
NP.friendlyPlates = {}

-- Blizzard base frame → plate (weak keys; suppression bookkeeping)
NP.platesByBase = setmetatable({}, { __mode = "k" })

-- Appearance generation: static styling (fonts/anchors/sizes) is applied to
-- a pooled plate only when plate._appearanceGen ~= NP.appearanceGen.
-- Settings refreshes bump the generation; pooled respawns skip static work.
NP.appearanceGen = 1

function NP.BumpAppearanceGeneration()
    NP.appearanceGen = NP.appearanceGen + 1
end

---------------------------------------------------------------------------
-- PLAIN-VALUE GATE
---------------------------------------------------------------------------
-- type() CANNOT detect secrets: a secret boolean reports type "boolean" and
-- then errors on its first truthiness test, comparison, or use as a table
-- key. This gate returns the value only when it is BOTH verifiably
-- non-secret AND of the expected type; nil otherwise. Every branch on a
-- possibly-secret API return must route through it (or a C-side sink).
local IsSecretValue = Helpers.IsSecretValue
function NP.Plain(value, expectedType)
    if value == nil or IsSecretValue(value) then return nil end
    if type(value) == expectedType then return value end
    return nil
end

---------------------------------------------------------------------------
-- SETTINGS
---------------------------------------------------------------------------
-- Runtime keys are seeded from core/defaults.lua (profile tree "nameplates");
-- this local mirror only backfills profiles created before the suite shipped.
local DEFAULTS = {
    enabled = false,
}

function NP.GetSettings()
    return Helpers.GetModuleSettings("nameplates", DEFAULTS)
end

function NP.IsEnabled()
    local s = NP.GetSettings()
    return s and s.enabled == true
end

---------------------------------------------------------------------------
-- PUBLIC: cross-suite attachment host (consumed by QoL mplus_progress)
---------------------------------------------------------------------------
-- Returns the region other modules should anchor plate-attached text to,
-- or nil when the custom plates aren't managing this unit.
function NP:GetPlateAnchor(unit)
    if not unit then return nil end
    local plate = NP.plates[unit] or NP.friendlyPlates[unit]
    if plate and plate.healthBar and plate:IsShown() then
        return plate.healthBar
    end
    return nil
end
