-- tests/unit/search_cache_locale_consistency_test.lua
-- Run: lua tests/unit/search_cache_locale_consistency_test.lua
--
-- Guard: no locale search cache may contain any of the six retired moduleAddon
-- IDs that were replaced during the Module Addons consolidation.  If a future
-- registry change leaves locale caches stale, this test will catch it before
-- ship.

local RETIRED_IDS = {
    "moduleAddon_QUI_Skinning",
    "moduleAddon_QUI_Datatexts",
    "moduleAddon_QUI_Minimap",
    "moduleAddon_QUI_InfoBar",
    "moduleAddon_QUI_QoL",
    "moduleAddon_QUI_Alts",
}

local LOCALES = {
    "deDE", "esES", "esMX", "frFR", "itIT",
    "koKR", "ptBR", "ruRU", "zhCN", "zhTW",
}

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local failures = {}

for _, locale in ipairs(LOCALES) do
    local path = ("QUI_OptionsSearch_%s/search_cache.lua"):format(locale)
    local content = readAll(path)
    if not content then
        table.insert(failures, ("MISSING: %s"):format(path))
    else
        for _, id in ipairs(RETIRED_IDS) do
            if content:find(id, 1, true) then
                table.insert(failures,
                    ("%s: contains retired featureId %q — run bash tools/i18n/gen_all_caches.sh"):format(path, id))
            end
        end
    end
end

if #failures > 0 then
    for _, msg in ipairs(failures) do
        io.stderr:write("FAIL: " .. msg .. "\n")
    end
    os.exit(1)
end

print("ok: all " .. #LOCALES .. " locale search caches free of retired moduleAddon IDs")
