local ADDON_NAME, ns = ...
local DR = {}
ns.QUI_DispelRoles = DR

-- Offensive+defensive dispel capability by class; spec-gated schools noted.
-- Base (any spec) schools + heal-spec-only additions.
local BASE = {
    PALADIN = { Poison = true, Disease = true, Magic_healSpecs = { [65] = true } }, -- Holy(65) magic
    -- Purify Disease (all specs) = Disease; Purify (Disc 256 / Holy 257) adds Magic.
    PRIEST  = { Disease = true, Magic_healSpecs = { [256]=true, [257]=true } },
    SHAMAN  = { Curse = true, Magic_healSpecs = { [264] = true } },              -- Resto(264) magic
    DRUID   = { Curse = true, Poison = true, Magic_healSpecs = { [105] = true } },-- Resto(105) magic
    MONK    = { Poison = true, Disease = true, Magic_healSpecs = { [270] = true } },
    -- Expunge (all specs) = Poison; Naturalize (Preservation 1468) adds Magic.
    -- Cauterizing Flame (Bleed/Poison/Curse/Disease) is a class TALENT, not a
    -- spec guarantee — this spec-keyed table can't express it, so it's omitted.
    EVOKER  = { Poison = true, Magic_healSpecs = { [1468] = true } },
    MAGE    = { Curse = true },
    HUNTER  = { }, WARRIOR = {}, ROGUE = {}, WARLOCK = {}, DEMONHUNTER = {}, DEATHKNIGHT = {},
}

function DR.SchoolsForClassSpec(classFile, specID)
    local out = {}
    local def = BASE[classFile]
    if not def then return out end
    for k, v in pairs(def) do
        if v == true then
            out[k] = true
        elseif type(v) == "table" then
            -- keyed like "Magic_healSpecs" -> school "Magic" if specID matches
            local school = k:match("^(%a+)_healSpecs$")
            if school and specID and v[specID] then out[school] = true end
        end
    end
    return out
end

function DR.PlayerDispelSchools()
    local _, classFile = UnitClass("player")
    local specID = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and (function() local i = C_SpecializationInfo.GetSpecialization(); return i and select(1, GetSpecializationInfo(i)) end)() or nil
    return DR.SchoolsForClassSpec(classFile, specID)
end

return DR
