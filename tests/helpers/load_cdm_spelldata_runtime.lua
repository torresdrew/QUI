return function(ns)
    ns = ns or {}

    local existingShared = ns.CDMShared or {}
    if not existingShared.GetBuiltinContainerEntryKind then
        local sharedNS = {
            Helpers = ns.Helpers,
            Addon = ns.Addon,
        }
        assert(loadfile("modules/cdm/cdm_shared.lua"))("QUI", sharedNS)
        for key, value in pairs(sharedNS.CDMShared or {}) do
            if existingShared[key] == nil then
                existingShared[key] = value
            end
        end
        ns.CDMShared = existingShared
    end

    if not ns.CDMAuraCatalog then
        assert(loadfile("modules/cdm/cdm_aura_catalog.lua"))("QUI", ns)
    end
    if not ns.CDMAuraRuntime then
        assert(loadfile("modules/cdm/cdm_aura_runtime.lua"))("QUI", ns)
    end

    return ns
end
