-- tests/unit/cdm_sources_secret_aura_gate_test.lua
-- Run: lua tests/unit/cdm_sources_secret_aura_gate_test.lua
--
-- 12.1: instance-ID aura getters (RequiresUnitAuraAccess) THROW while aura
-- data is globally secret (C_Secrets.ShouldAurasBeSecret() == true), even when
-- the auraInstanceID argument is a plain number cached before combat. The
-- Query* wrappers must bail to nil WITHOUT calling the C function while the
-- predicate is true, and pass through normally when it is false. Spell-based
-- getters (RequiresNonSecretAura — return secrets, never throw) must NOT be
-- gated.

local secretValues = {}
function issecretvalue(value) return secretValues[value] == true end

_G.wipe = function(tbl)
    for k in pairs(tbl) do tbl[k] = nil end
    return tbl
end

-- Simulated global aura secrecy. The instance getters below enforce the same
-- contract the live client does: called while secret -> hard Lua error.
local aurasSecret = false
C_Secrets = {
    ShouldAurasBeSecret = function() return aurasSecret end,
}

local calls = { duration = 0, data = 0, expiration = 0, filtered = 0, appCount = 0, bySpell = 0 }

local function instanceGetter(counterKey, result)
    return function(...)
        if aurasSecret then
            error(counterKey .. "(): Auras cannot be accessed when secret while tainted")
        end
        calls[counterKey] = calls[counterKey] + 1
        return result
    end
end

local durationToken = { token = "duration" }
local auraDataToken = { token = "aura-data" }

C_UnitAuras = {
    GetAuraDuration = instanceGetter("duration", durationToken),
    GetAuraDataByAuraInstanceID = instanceGetter("data", auraDataToken),
    DoesAuraHaveExpirationTime = instanceGetter("expiration", true),
    IsAuraFilteredOutByInstanceID = instanceGetter("filtered", false),
    GetAuraApplicationDisplayCount = instanceGetter("appCount", 3),
    GetUnitAuraBySpellID = function(_unit, _spellID, _filter)
        -- Spell getters never throw; they return (possibly secret) AuraData.
        calls.bySpell = calls.bySpell + 1
        return auraDataToken
    end,
}

local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_sources.lua", "cdm_sources.lua")("QUI", ns)
local S = ns.CDMSources

---------------------------------------------------------------------------
-- T1: AreAurasSecret mirrors the predicate.
---------------------------------------------------------------------------
assert(S.AreAurasSecret() == false, "T1: not secret out of combat")
aurasSecret = true
assert(S.AreAurasSecret() == true, "T1: secret while predicate true")
aurasSecret = false

---------------------------------------------------------------------------
-- T2: non-secret window — every wrapper passes through to the C function.
---------------------------------------------------------------------------
assert(S.QueryAuraDuration("player", 1685) == durationToken, "T2: duration passes through")
assert(S.QueryAuraDataByAuraInstanceID("player", 1685) == auraDataToken, "T2: data passes through")
assert(S.QueryAuraHasExpirationTime("player", 1685) == true, "T2: expiration passes through")
assert(S.QueryAuraFilteredOutByInstanceID("target", 1, "HARMFUL|PLAYER") == false, "T2: filter passes through")
assert(S.QueryAuraApplicationDisplayCount("player", 1731, 0, 99) == 3, "T2: app count passes through")
assert(calls.duration == 1 and calls.data == 1 and calls.expiration == 1
    and calls.filtered == 1 and calls.appCount == 1, "T2: each C function called exactly once")

---------------------------------------------------------------------------
-- T3: secret window — wrappers return nil and NEVER reach the C function
-- (the mock throws if reached; plain cached IDs must not be forwarded).
---------------------------------------------------------------------------
aurasSecret = true
assert(S.QueryAuraDuration("player", 1685) == nil, "T3: duration gated to nil")
assert(S.QueryAuraDataByAuraInstanceID("player", 1685) == nil, "T3: data gated to nil")
assert(S.QueryAuraHasExpirationTime("player", 1685) == nil, "T3: expiration gated to nil")
assert(S.QueryAuraFilteredOutByInstanceID("target", 1, "HARMFUL|PLAYER") == nil, "T3: filter gated to nil")
assert(S.QueryAuraApplicationDisplayCount("player", 1731, 0, 99) == nil, "T3: app count gated to nil")
assert(calls.duration == 1 and calls.data == 1 and calls.expiration == 1
    and calls.filtered == 1 and calls.appCount == 1, "T3: no additional C calls while secret")

---------------------------------------------------------------------------
-- T4: spell-based getter is NOT gated — safe API, must keep resolving the
-- whitelisted auras that carry CDM through combat.
---------------------------------------------------------------------------
assert(S.QueryUnitAuraBySpellID("player", 100) == auraDataToken, "T4: spell getter still resolves while secret")
assert(calls.bySpell >= 1, "T4: spell getter reached the C function")
aurasSecret = false

---------------------------------------------------------------------------
-- T5: secret auraInstanceID still rejected even when auras are NOT secret
-- (pre-existing HasOpaqueValue contract preserved).
---------------------------------------------------------------------------
local secretID = { token = "secret-instance-id" }
secretValues[secretID] = true
assert(S.QueryAuraDuration("player", secretID) == nil, "T5: secret ID rejected")
assert(calls.duration == 1, "T5: secret ID never forwarded to the C function")

---------------------------------------------------------------------------
-- T6: absent C_Secrets (test harness / older client) — fail open, no gate.
---------------------------------------------------------------------------
do
    local ns2 = {}
    local savedSecrets = C_Secrets
    C_Secrets = nil
    loadChunk("QUI_CDM/cdm/cdm_sources.lua", "cdm_sources.lua")("QUI", ns2)
    C_Secrets = savedSecrets
    assert(ns2.CDMSources.AreAurasSecret() == false, "T6: no C_Secrets -> never secret")
    assert(ns2.CDMSources.QueryAuraDuration("player", 1685) == durationToken,
        "T6: wrapper passes through without C_Secrets")
end

print("cdm_sources_secret_aura_gate_test: OK")
