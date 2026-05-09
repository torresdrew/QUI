local ADDON_NAME, ns = ...

local mainNS = QUI and QUI._ns
if type(mainNS) ~= "table" then
    error("QUI_Options requires QUI to load first")
end

setmetatable(ns, {
    __index = mainNS,
    __newindex = function(_, key, value)
        mainNS[key] = value
    end,
})

QUI._optionsAddonName = ADDON_NAME
