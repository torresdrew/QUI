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
--     selfBootstrap — true on a lod entry whose eager tier loads via the
--                  [Bootstrap] TOC directive at startup; the core's automatic
--                  LOD passes (eager + staggered) MUST skip it (a LoadAddOn
--                  there would also pull the lazy remainder, defeating the
--                  lazy tier). The lazy remainder loads via
--                  AddonLoader:LoadLazyBlock on its trigger; a live bundle
--                  enable from the Module Addons row still loads via
--                  SetModuleAddonEnabled (LoadNow, deliberate user action).
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
--   HOST-BACKED ENTRY — a module that ships inside another folder's addon (its
--   host) rather than as its own sibling folder. Has NO `folder` field, so the
--   loader and folder/TOC-checking consumers skip it (see the `entry.folder`
--   guards in core/addon_loader.lua and core/settings/content/module_addons_content.lua).
--   Only minimap/infobar/alts have individual per-module flag rows (they gate
--   cleanly at init).  skinning/datatexts/qol ride the QUI_UI bundle and have
--   no individual toggle.
--   Fields:
--     hostAddon  — folder name of the sibling addon that physically ships this module
--     module     — the module's top-level subdir inside the host (e.g. "minimap")
--     flag       — profile-DB path of the module's enable flag.
---------------------------------------------------------------------------
local MANIFEST = {
    -- login class: secure frames / taint-load-bearing hooks; order here is
    -- documentation only (the client loads by dependency + folder name).
    { folder = "QUI_ActionBars",   class = "login",                                                  sources = { "modules/actionbars" } },
    { folder = "QUI_CDM",          class = "login",                                                  sources = { "modules/cdm" } },
    { folder = "QUI_Chat",         class = "login", legacyFlag = { "chat", "enabled" },              sources = { "modules/chat" } },
    { folder = "QUI_GroupFrames",  class = "login", legacyFlag = { "quiGroupFrames", "enabled" },    sources = { "modules/groupframes" } },
    { folder = "QUI_ResourceBars", class = "login",                                                  sources = { "modules/resourcebars" } },
    { folder = "QUI_UnitFrames",   class = "login",                                                  sources = { "modules/unitframes" } },
    -- lod class: loaded post-login in THIS order (cosmetics first).
    --
    -- QUI_UI is the merged cosmetic + utility bundle: the former QUI_Skinning,
    -- QUI_Datatexts, QUI_Minimap, QUI_InfoBar, QUI_QoL and QUI_Alts sub-addons
    -- now ship as module subdirs inside one LOD folder. Intra-bundle file load
    -- order (datatexts before minimap so the 3-slot panel finds the registry;
    -- minimap eager-skinned before first render; infobar after its datatext
    -- registry) is governed by QUI_UI/QUI_UI.toc, not by this manifest.
    { folder = "QUI_UI", class = "lod", selfBootstrap = true, sources = {} },
    -- Host-backed entries: the three per-module flag rows that gate cleanly.
    -- skinning/datatexts/qol ride the QUI_UI bundle and have no individual row.
    { hostAddon = "QUI_UI", module = "minimap",   flag = { "minimap",   "enabled" } },
    { hostAddon = "QUI_UI", module = "infobar",   flag = { "infobar",   "enabled" } },
    { hostAddon = "QUI_UI", module = "alts",      flag = { "alts",      "enabled" } },
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
