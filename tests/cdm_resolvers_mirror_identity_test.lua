-- tests/cdm_resolvers_mirror_identity_test.lua
-- Run: lua tests/cdm_resolvers_mirror_identity_test.lua

function InCombatLockdown() return false end
function geterrorhandler() return function(err) error(err) end end
function CreateFrame()
    return {
        RegisterEvent = function() end,
        RegisterUnitEvent = function() end,
        SetScript = function() end,
    }
end

local states = {
    ["buff:9001"] = { cooldownID = 9001, viewerCategory = "buff" },
    ["trackedBar:9002"] = { cooldownID = 9002, viewerCategory = "trackedBar" },
    ["utility:8002"] = { cooldownID = 8002, viewerCategory = "utility" },
    ["essential:70759"] = {
        cooldownID = 70759,
        viewerCategory = "essential",
        spellID = 77575,
        overrideSpellID = 77575,
    },
    ["utility:28527"] = {
        cooldownID = 28527,
        viewerCategory = "utility",
        spellID = 48707,
        overrideSpellID = 48707,
    },
}

local bySpell = {
    buff = {
        [101] = 9001,
        [301] = 9001,
    },
    trackedBar = {
        [102] = 9002,
    },
    utility = {
        [202] = 8002,
        [48707] = 28527,
    },
    essential = {
        [77575] = 70759,
    },
}

local ns = {
    Helpers = {},
    CDMSources = {
        QueryOverrideSpell = function() return nil end,
    },
    CDMBlizzMirror = {
        GetDirectCooldownIDForViewer = function(spellID, viewerCategory)
            local cat = bySpell[viewerCategory]
            return cat and cat[spellID] or nil
        end,
        GetCooldownIDForViewer = function(spellID, viewerCategory)
            local cat = bySpell[viewerCategory]
            return cat and cat[spellID] or nil
        end,
        GetStateByCooldownID = function(cooldownID, viewerCategory)
            return states[tostring(viewerCategory) .. ":" .. tostring(cooldownID)]
        end,
        HasChildForCooldownID = function(cooldownID, viewerCategory)
            return states[tostring(viewerCategory) .. ":" .. tostring(cooldownID)] ~= nil
        end,
    },
}

assert(loadfile("modules/cdm/cdm_resolvers.lua"))("QUI", ns)

local resolvers = assert(ns.CDMResolvers, "CDMResolvers table was not exported")
local resolveIdentity = assert(resolvers.ResolveBlizzardMirrorIdentity,
    "shared mirror identity resolver was not exported")

local cdID, cat = resolveIdentity({
    type = "spell",
    id = 101,
    kind = "aura",
    viewerType = "customBar",
})

assert(cdID == 9001, "custom aura entry should resolve through the buff icon category")
assert(cat == "buff", "custom aura entry should keep the buff icon mirror category")

cdID, cat = resolveIdentity({
    type = "spell",
    id = 102,
    kind = "aura",
    viewerType = "customBar",
})

assert(cdID == 9002, "custom aura entry should fall back to the buff bar category")
assert(cat == "trackedBar", "custom aura entry should keep the buff bar mirror category")

cdID, cat = resolveIdentity({
    type = "spell",
    id = 202,
    kind = "cooldown",
    viewerType = "customBar",
})

assert(cdID == 8002, "custom cooldown entry should resolve through cooldown categories")
assert(cat == "utility", "custom cooldown entry should keep the cooldown mirror category")

cdID, cat = resolveIdentity({
    type = "aura",
    id = 101,
    viewerType = "customIcon",
})

assert(cdID == 9001, "entry type aura should resolve through aura categories")
assert(cat == "buff", "entry type aura should keep the aura mirror category")

cdID, cat = resolveIdentity({
    type = "cooldown",
    id = 202,
    viewerType = "customIcon",
})

assert(cdID == 8002, "entry type cooldown should resolve through cooldown categories")
assert(cat == "utility", "entry type cooldown should keep the cooldown mirror category")

cdID, cat = resolveIdentity({
    type = "spell",
    id = 999,
    kind = "aura",
    viewerType = "customBar",
    cooldownID = 9002,
})

assert(cdID == 9002, "explicit custom aura cooldownID should still be honored")
assert(cat == "trackedBar", "explicit custom aura cooldownID should resolve its aura category")

cdID, cat = resolveIdentity({
    type = "spell",
    id = 202,
    kind = "aura",
    viewerType = "customBar",
})

assert(cdID == nil, "aura entry must not bind to cooldown-category mirror IDs")
assert(cat == nil, "rejected aura entry should not return a mirror category")

cdID, cat = resolveIdentity({
    type = "spell",
    id = 77575,
    spellID = 77575,
    kind = "cooldown",
    viewerType = "essential",
    cooldownID = 28527,
    linkedSpellIDs = { 48707 },
})

assert(cdID == 70759, "mismatched explicit cooldownID should not bind Outbreak to AMS")
assert(cat == "essential", "mismatched explicit cooldownID should fall back to the entry's own category")

local payload = resolvers.ResolveMirrorRenderPayloadForEntry({
    type = "spell",
    id = 77575,
    spellID = 77575,
    kind = "cooldown",
    viewerType = "essential",
    linkedSpellIDs = { 48707 },
}, 28527, "utility", 77575)

assert(payload and payload.cooldownID == 70759,
    "stale icon mirror binding should be rejected during render payload resolution")
assert(payload and payload.category == "essential",
    "stale icon mirror binding should fall back to the entry's own render category")

print("OK: cdm_resolvers_mirror_identity_test")
