-- tests/unit/locale_lod_overlay_test.lua
-- Run: lua tests/unit/locale_lod_overlay_test.lua
--
-- Non-enUS UI-string translations (~4.9 MB) live INSIDE the per-locale
-- QUI_OptionsSearch_<loc> LoadOnDemand sub-addons (combined overlay +
-- settings search index — ONE folder per locale, per Drew: no parallel
-- QUI_Locale_* folder set). Contract:
--   * enUS stays root (base table + the beta enUS regen bot writes
--     core/locale/enUS.lua); the plain QUI_OptionsSearch addon stays a
--     lazy English-index-only addon.
--   * load_overlay.lua sits BETWEEN enUS.lua and locale.lua because
--     locale.lua captures ns.LocaleData.active as an UPVALUE — an overlay
--     loaded any later is invisible.
--   * The combined addons carry NO RequiredDeps: a QUI_Options dep would
--     drag the ~2.9 MB options engine into the login path. The byte-equal
--     namespace bootstrap hard-errors if the core is absent, and routes the
--     chunk's ns.LocaleData / the index's ns.QUI_SearchCache into the core
--     namespace, where GUI:EnsureSearchCacheLoaded consumes the parked
--     index on first search.

local LOCALES = { "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local toc = readFile("QUI.toc")

-- root keeps enUS + the applier, gains the overlay stub in between
local enusPos = assert(toc:find("core\\locale\\enUS.lua", 1, true), "enUS base must stay root-loaded")
local stubPos = assert(toc:find("core\\locale\\load_overlay.lua", 1, true), "overlay stub missing from root TOC")
local applierPos = assert(toc:find("core\\locale\\locale.lua", 1, true), "locale applier missing from root TOC")
assert(enusPos < stubPos and stubPos < applierPos,
    "load order must be enUS base -> overlay stub -> locale.lua (upvalue capture)")

local bootstrapTemplate = readFile("core/templates/subaddon_bootstrap.lua")

for _, loc in ipairs(LOCALES) do
    assert(not toc:find("core\\locale\\" .. loc .. ".lua", 1, true),
        loc .. " must not compile in the root TOC")

    local folder = "QUI_OptionsSearch_" .. loc
    local subToc = readFile(folder .. "/" .. folder .. ".toc")
    assert(subToc:find("## LoadOnDemand: 1", 1, true), folder .. " must be LoadOnDemand")
    assert(not subToc:find("## RequiredDeps", 1, true) and not subToc:find("## Dependencies", 1, true),
        folder .. " must carry no hard deps (a QUI_Options dep drags the options engine into login)")
    assert(subToc:find("## Group: QUI", 1, true), folder .. " must stay grouped with QUI (packaging)")

    assert(readFile(folder .. "/bootstrap.lua") == bootstrapTemplate,
        folder .. "/bootstrap.lua must stay byte-equal to core/templates/subaddon_bootstrap.lua")

    local chunk = readFile(folder .. "/" .. loc .. ".lua")
    assert(chunk:find('if want ~= "' .. loc .. '" then return end', 1, true),
        folder .. " chunk must keep its locale gate (double-safety if loaded manually)")
end

-- no parallel locale-only folder set may reappear
local p = io.popen('ls -d QUI_Locale_* 2>/dev/null')
local stray = p:read("*l")
p:close()
assert(stray == nil, "parallel QUI_Locale_* folders are forbidden (combined addons own the strings): " .. tostring(stray))

-- the stub must load the combined overlay synchronously and tolerate a missing addon
local stub = readFile("core/locale/load_overlay.lua")
assert(stub:find('"QUI_OptionsSearch_" .. want', 1, true), "stub must load the active locale's combined sub-addon")
assert(stub:find("pcall(loader", 1, true), "missing/disabled overlay must not break login")

-- the framework must consume a login-parked index instead of relying on LoadAddOn
local framework = readFile("QUI_Options/framework.lua")
assert(framework:find("if ns.QUI_SearchCache then", 1, true),
    "EnsureSearchCacheLoaded must apply the ns-parked index from login-loaded combined addons")

print("PASS locale_lod_overlay_test")
