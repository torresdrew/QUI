-- Consolidated CDM source (canonical; the one-shot consolidation tool is retired — edit directly).
-- CDM Aura -- consolidated catalog + runtime aura helpers.
-- Each `do -- Inlined from X ... end` block is a self-contained chunk that
-- tests load individually via load_cdm_consolidated_chunk.lua.

do
-- Inlined from cdm_aura_catalog.lua
local _, ns = ...

---------------------------------------------------------------------------
-- CDM Aura Catalog
--
-- Pure helpers for catalog-provided aura links. CDMSpellData owns entry
-- assembly; this module owns ability->aura display remaps and linked aura
-- ID attachment rules derived from the Blizzard catalog maps.
---------------------------------------------------------------------------

local CDMAuraCatalog = {}
ns.CDMAuraCatalog = CDMAuraCatalog

local ipairs = ipairs
local select = select
local type = type

local issecretvalue = issecretvalue or function() return false end

local function IsUsableID(id)
    if type(id) ~= "number" then return false end
    if issecretvalue(id) then return false end -- @secret-policy: reject-secret-ids
    return id > 0
end

function CDMAuraCatalog.ResolveEntryAuraDisplay(entryID, abilityToAuraSpellID)
    if not IsUsableID(entryID) then
        return entryID, false
    end

    local mappedID = abilityToAuraSpellID and abilityToAuraSpellID[entryID]
    if IsUsableID(mappedID) then
        return mappedID, true
    end

    return entryID, false
end

function CDMAuraCatalog.AttachLinkedAuraIDs(resolved, auraIDsForSpell, getAuraIDsForSpell, ...)
    if not resolved then return end

    local out, seen
    local function appendForSpellID(spellID)
        if not IsUsableID(spellID) then return end

        local ids
        if type(getAuraIDsForSpell) == "function" then
            ids = getAuraIDsForSpell(spellID)
        elseif auraIDsForSpell then
            ids = auraIDsForSpell[spellID]
        end
        if type(ids) ~= "table" then return end

        if not out then
            out = {}
            seen = {}
        end
        for _, auraID in ipairs(ids) do
            if IsUsableID(auraID) and not seen[auraID] then
                seen[auraID] = true
                out[#out + 1] = auraID
            end
        end
    end

    for i = 1, select("#", ...) do
        appendForSpellID(select(i, ...))
    end

    if out and #out > 0 then
        resolved.linkedSpellIDs = out
    end
end
end

do
-- Inlined from cdm_aura_runtime.lua
local _, ns = ...

---------------------------------------------------------------------------
-- CDM Aura Runtime
--
-- Runtime aura-state interface. CDMSpellData currently provides the adapter
-- implementation because it owns the UNIT_AURA capture indexes and scratch
-- helpers; callers consume this module instead of treating SpellData as a
-- parallel runtime truth source.
---------------------------------------------------------------------------

local CDMAuraRuntime = {}
ns.CDMAuraRuntime = CDMAuraRuntime

local resolveState
local getApplications
local getCapturedAura
local resolveAbilityAuraSpellID

function CDMAuraRuntime.SetResolver(callback)
    resolveState = callback
end

function CDMAuraRuntime.ResolveState(params)
    if resolveState then
        return resolveState(params)
    end
    return nil
end

function CDMAuraRuntime.SetApplicationsGetter(callback)
    getApplications = callback
end

function CDMAuraRuntime.GetApplications(unit, auraInstanceID)
    if getApplications then
        return getApplications(unit, auraInstanceID)
    end
    return nil
end

function CDMAuraRuntime.SetCapturedAuraGetter(callback)
    getCapturedAura = callback
end

function CDMAuraRuntime.GetCapturedAuraForLookup(...)
    if getCapturedAura then
        return getCapturedAura(...)
    end
    return nil
end

function CDMAuraRuntime.SetAbilityAuraSpellIDResolver(callback)
    resolveAbilityAuraSpellID = callback
end

function CDMAuraRuntime.ResolveAbilityAuraSpellID(spellID)
    if resolveAbilityAuraSpellID then
        return resolveAbilityAuraSpellID(spellID)
    end
    return spellID, false
end

function CDMAuraRuntime.HasAbilityAuraMapping(spellID)
    local _, remapped = CDMAuraRuntime.ResolveAbilityAuraSpellID(spellID)
    return remapped == true
end
end
