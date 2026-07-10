---------------------------------------------------------------------------
-- QUI suite manifest — single source of truth for the sub-addon split.
-- Consumed by core/addon_loader.lua (runtime), tools/split_suite_tocs.lua
-- (one-shot splitter) and tests/unit/suite_toc_consistency_test.lua (CI).
--
-- Entries come in two shapes:
--
--   FOLDER ENTRY — a shipped sibling addon folder. Fields:
--     folder     — sibling addon folder name
--     class      — "login" (loads with the loading screen) | "lod" (LoadOnDemand,
--                  loaded by the core post-login, in manifest order)
--     legacyFlag — profile-DB path of the module's dormant-guard flag, or nil.
--                  Present on entries (QUI_Chat, QUI_GroupFrames, QUI_Bags) that
--                  default to off for stock-chat / opt-in users.  Consumed by the
--                  Module Addons rows (AND-read for isEnabled, heal-on-enable) and
--                  honored by each module's own init.  NOT consumed by the loader —
--                  addon enable state alone gates LOD loading.
--     sources    — original modules/<dir> roots (repo-relative, forward slashes);
--                  inside the sub-addon each keeps its dir name (modules/cdm →
--                  QUI_CDM/cdm/...)
--
--   CORE-MODULE ENTRY — a module that ships inside the main QUI addon (no
--   separate folder, no host addon). Has NO `folder` field, so the loader and
--   folder/TOC-checking consumers skip it (see the `entry.folder` guards in
--   core/addon_loader.lua and core/settings/content/module_addons_content.lua).
--   Rendered as a profile-flag toggle row by module_addons_content.lua.
--   Fields:
--     coreModule — the module identifier (e.g. "minimap")
--     flag       — profile-DB path of the module's enable flag.
---------------------------------------------------------------------------
local MANIFEST = {
    -- login class: secure frames / taint-load-bearing hooks; order here is
    -- documentation only (the client loads by dependency + folder name).
    { folder = "QUI_ActionBars",   class = "login",                                                  sources = { "modules/actionbars" } },
    { folder = "QUI_CDM",          class = "login",                                                  sources = { "modules/cdm" } },
    { folder = "QUI_Chat",         class = "login", legacyFlag = { "chat", "enabled" },              sources = { "modules/chat" } },
    { folder = "QUI_GroupFrames",  class = "login", legacyFlag = { "quiGroupFrames", "enabled" },    sources = { "modules/groupframes" } },
    -- Opt-in, default-off (legacyFlag nameplates.enabled): full custom
    -- nameplates. Login class — plates must exist the moment a loading
    -- screen drops, and the Blizzard-art suppression hooks are
    -- taint-load-bearing (must be installed before the first plate spawns).
    { folder = "QUI_Nameplates",   class = "login", legacyFlag = { "nameplates", "enabled" },        sources = {} },
    { folder = "QUI_ResourceBars", class = "login",                                                  sources = { "modules/resourcebars" } },
    { folder = "QUI_UnitFrames",   class = "login",                                                  sources = { "modules/unitframes" } },
    -- lod class: loaded post-login in THIS order (cosmetics first).
    --
    -- coreModule entries: modules that now ship inside the main QUI addon and
    -- carry a profile-flag toggle (no folder → loader/TOC consumers skip them;
    -- no separate sub-addon). Rendered as profile-flag
    -- rows by core/settings/content/module_addons_content.lua. qol has no entry
    -- here — it stays always-on; its per-feature general.* flags toggle each
    -- QoL feature individually.
    { coreModule = "minimap",   flag = { "minimap",      "enabled" } },
    { coreModule = "infobar",   flag = { "infobar",      "enabled" } },
    { coreModule = "alts",      flag = { "alts",         "enabled" } },
    { coreModule = "datatexts", flag = { "quiDatatexts", "enabled" } },
    { coreModule = "skinning",  flag = { "skinning",     "enabled" } },
    { folder = "QUI_DamageMeter",  class = "lod",                                                    sources = { "modules/damage_meter" } },
    -- Opt-in, default-off (legacyFlag bags.enabled): ships enabled but stays
    -- dormant until the user turns it on via the Module Addons row. Loads via
    -- the eager LOD pass like its siblings; bags.lua self-gates on the flag.
    { folder = "QUI_Bags",         class = "lod", legacyFlag = { "bags", "enabled" },                sources = { "modules/bags" } },
}

local ADDON_NAME, ns = ...
if type(ns) == "table" then
    ns.AddonManifest = MANIFEST
end
return MANIFEST
