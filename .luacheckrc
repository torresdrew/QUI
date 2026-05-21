-- luacheck configuration for QUI
--
-- Run:  luacheck <files>
-- Or:   luacheck QUI_Debug/ core/ modules/ init.lua
--
-- This config silences false-positive "undefined variable" warnings for the
-- WoW client API surface used by this addon. The full WoW API is enormous;
-- this list only covers what's currently referenced. Add globals here as
-- new ones surface in warnings — keep the list minimal so real undefined-
-- variable bugs (like use-before-define of locals) still show up.

std = "lua51"
max_line_length = false   -- WoW addons commonly run wider than 120 cols

-- Suppress noise from common WoW idioms:
--   212/self   — frames pass `self` to OnEvent/OnUpdate scripts; often unused
--   212/event  — OnEvent handlers receive event but often only inspect args
--   212/_.*    — leading-underscore args are by convention intentionally unused
ignore = {
    "212/self",
    "212/event",
    "212/_.*",
}

-- Project-defined globals (written to from any file in the addon).
globals = {
    "QUI",
    "QUI_DB",
    "QuaziiUI_DB",
    "QUI_MemAudit",
    "QUI_RefreshActionTracker",
    "QUI_ToggleActionTrackerPreview",
    "QUI_IsActionTrackerPreviewMode",
    "QUI_HasFrameAnchor",
    "QUI_ApplyFrameAnchor",
    "QUI_DiagnoseEditMode",
    "QUI_PerfRegistry",
    "QUI_PerfExperiments",
    "QUI_CompartmentClick",
    "QUI_CompartmentOnEnter",
    "QUI_CompartmentOnLeave",
    "SLASH_QUISCAN1",
    "SLASH_QUISCAN2",
    "SLASH_QUIKB1",
    "SLASH_QUI_CDM1",
    "SlashCmdList",
    "BINDING_NAME_QUI_TOGGLE_OPTIONS",
}

-- WoW client globals — read-only from addon code.
read_globals = {
    -- Frame creation / UI primitives
    "CreateFrame", "EnumerateFrames", "UIParent", "WorldFrame", "GameTooltip",
    "QuickKeybindFrame", "ShowUIPanel", "UIFrameFadeOut", "Settings",
    "CooldownViewerSettings", "EventRegistry", "AssistedCombatManager",
    "STANDARD_TEXT_FONT",

    -- Time, combat, addon lifecycle
    "GetTime", "InCombatLockdown", "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
    "IsAddOnLoaded", "LoadAddOn", "date",

    -- Units, bindings
    "UnitExists", "UnitCanAttack", "GetBindingKey",

    -- Spells, actions, macros
    "GetSpellInfo", "GetActionInfo", "GetMacroSpell", "FindBaseSpellByID",

    -- C_* namespace tables (whitelisted whole — methods accessed via dot/colon)
    "C_ActionBar", "C_AddOnProfiler", "C_AddOns", "C_AssistedCombat",
    "C_PartyInfo", "C_Spell", "C_Timer", "C_UnitAuras", "C_TooltipInfo",
    "C_NamePlate", "C_ItemCallbacks",

    -- WoW Lua extensions (Lua 5.1 base + Blizzard additions)
    "wipe", "strsplit", "strjoin", "strtrim", "strconcat", "format",
    "tContains", "tInvert", "tDeleteItem", "Mixin", "CreateFromMixins",
    "hooksecurefunc", "issecure", "issecurevariable",
    "tostringall", "issecretvalue", "Clamp",

    -- Blizzard internals
    "hash_SlashCmdList",

    -- Third-party libs
    "LibStub",
}
