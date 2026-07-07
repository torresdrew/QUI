local _, ns = ...

---------------------------------------------------------------------------
-- Namespace export guard
--
-- Seventeen suites write their cross-module exports into the one shared
-- core namespace through each suite's bootstrap proxy. Two suites picking
-- the same key used to be silent last-writer-wins — the losing suite's
-- consumers got the winner's object with no signal anywhere.
--
-- Every suite-side ns write now flows through _TrackSuiteNsExport (called
-- by the bootstrap __newindex before the write lands). The guard records
-- the first-writing suite per key and flags any later write from a
-- DIFFERENT suite that would replace an existing value with a different
-- one. Collisions are appended to ns._NsExportCollisionLog and announced
-- in chat once per key.
--
-- What deliberately does NOT warn:
--   * rewrites by the owning suite (module refresh reassignments)
--   * value-identical writes (the `ns.X = ns.X or {}` lazy-init idiom)
--   * keys in SHARED_NS_KEYS — cross-suite mutable state by design
--   * keys first written by core (owner falls back to "QUI" core, and
--     core-side writes don't route through the proxy at all)
--
-- tests/unit/ns_export_ownership_test.lua is the static CI twin: it fails
-- when a new cross-suite key appears in source without joining the shared
-- list below AND there.
---------------------------------------------------------------------------

-- Keys that multiple suites intentionally write with differing values.
-- Keep in sync with tests/unit/ns_export_ownership_test.lua.
local SHARED_NS_KEYS = {
    CDMRuntimeEventTraceHook = true, -- debug suite rebinds the CDM trace hook
    QUI                      = true, -- convenience re-export of the addon object
    QUI_Options              = true, -- options table lazy-seeded by core gui_shell
    QUI_PerfRegistry         = true, -- shared perf-metric registry, lazy-init everywhere
    SkinBase                 = true, -- defined in core uikit, lazy-init by QUI_Skinning
    _inInitSafeWindow        = true, -- combat-reload safe-window flag, toggled by several suites
    _memprobes               = true, -- shared memaudit probe table
}

local exportOwners = {}  -- key -> first-writing suite name
local warnedKeys = {}    -- key -> true once announced

local collisionLog = {}
ns._NsExportCollisionLog = collisionLog

function ns._TrackSuiteNsExport(addonName, key, value)
    local existing = ns[key]
    if existing == nil then
        if exportOwners[key] == nil then
            exportOwners[key] = addonName
        end
        return
    end
    if existing == value then return end

    -- Existing key with no recorded suite owner was written by core.
    local owner = exportOwners[key] or "QUI"
    if owner == addonName or SHARED_NS_KEYS[key] then return end

    collisionLog[#collisionLog + 1] = {
        key = key,
        owner = owner,
        overwrittenBy = addonName,
    }
    if not warnedKeys[key] then
        warnedKeys[key] = true
        print(("|cFFFF6666QUI:|r namespace export '%s' from %s was overwritten by %s — cross-suite state may be broken. Please report this."):format(
            tostring(key), tostring(owner), tostring(addonName)))
    end
end
