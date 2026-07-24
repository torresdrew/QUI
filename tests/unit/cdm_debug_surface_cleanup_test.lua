-- tests/unit/cdm_debug_surface_cleanup_test.lua
-- Run: lua tests/unit/cdm_debug_surface_cleanup_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function assertAbsent(path, needle, reason)
    local text = readFile(path)
    assert(not text:find(needle, 1, true), reason .. " in " .. path)
end

local function assertFileAbsent(path, reason)
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        error(reason .. " still exists: " .. path, 2)
    end
end

assertAbsent("QUI_CDM/QUI_CDM.toc", "QUI_CDMTaintLog", "taint sentinel SavedVariable must be removed")
assertAbsent("QUI_CDM/QUI_CDM.toc", "cdm_taint_sentinel.lua", "taint sentinel must not load")
assertFileAbsent("QUI_CDM/cdm/cdm_taint_sentinel.lua", "taint sentinel file")

for _, path in ipairs({
    "QUI_CDM/cdm/cdm_containers.lua",
    "QUI_CDM/cdm/cdm_blizzard_buffbar_suppression.lua",
    "QUI_CDM/cdm/cdm_editmode_policy.lua",
}) do
    assertAbsent(path, "CDMBootSkip", "boot-bisect helper must be removed")
    assertAbsent(path, "/quitaint", "ungated taint slash references must be removed")
end

assertAbsent("init.lua", "cdm_cache", "/qui cdm_cache must be removed from the main slash dispatcher")
assertAbsent("QUI_Debug/cdm_debug.lua", 'SlashCommandOpen("cdm_cache ', "/cdmdebug cache must not delegate to /qui cdm_cache")
assertAbsent("QUI_Debug/cdm_debug.lua", "/run QUI_CDM", "debug docs must not advertise direct /run CDM flags")
assertAbsent("docs/getting-started/slash-commands.md", "/qui cdm_cache", "ungated cache command docs must be removed")
assertAbsent("docs/getting-started/slash-commands.md", "/cdmdebug mirror", "stale mirror docs must be removed")
assertAbsent("QUI_Options/tiles/help_content.lua", "cdm_cache", "ungated cache help tiles must be removed")
assertAbsent("core/locale/enUS.lua", "cdm_cache", "removed cache command locale strings must not remain")
assertAbsent("tools/i18n/state.json", "cdm_cache", "removed cache command i18n state must not remain")
assertAbsent("tools/i18n/state.json", "CDM Cache Status", "removed cache status i18n state must not remain")
assertAbsent("tools/i18n/state.json", "CDM Cache Reset", "removed cache reset i18n state must not remain")
assertAbsent("QUI_OptionsSearch/search_cache.lua", "CDM Cache Status", "removed cache status search entry must not remain")
assertAbsent("QUI_OptionsSearch/search_cache.lua", "CDM Cache Reset", "removed cache reset search entry must not remain")
assertAbsent(".luacheckrc", "SLASH_QUITAINT1", "removed taint slash global must not be whitelisted")
assertAbsent(".luacheckrc", "QUI_CDMTaintLog", "removed taint SavedVariable must not be whitelisted")

assertAbsent("QUI_CDM/cdm/cdm_spelldata.lua", "QUI_CDM_CHARGE_DEBUG", "direct /run charge debug print path must be removed")
assertAbsent("QUI_CDM/cdm/cdm_spelldata.lua", "QUI_CDM_TOTEM_DEBUG", "direct /run totem debug print path must be removed")
assertAbsent("QUI_CDM/cdm/cdm_icon_renderer.lua", "/run QUI_CDM", "normal CDM files must not document direct /run debug flags")

print("OK: cdm_debug_surface_cleanup_test")
