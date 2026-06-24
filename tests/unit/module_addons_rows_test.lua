-- tests/unit/module_addons_rows_test.lua
-- Verifies the Module Addons row registrations after C8r:
--   - A QUI_UI folder row (bundle toggle) is registered.
--   - moduleFlag_minimap, moduleFlag_infobar, moduleFlag_alts host rows exist.
--   - Toggling a host row writes the profile flag and does NOT call
--     EnableAddOn/DisableAddOn.
--   - NO rows for skinning, datatexts, or qol (they ride the bundle).
-- Run: lua5.1 tests/unit/module_addons_rows_test.lua

local failures = 0
local function check(name, ok, detail)
    if ok then
        print(("  ok  %s"):format(name))
    else
        failures = failures + 1
        print(("FAIL  %s  %s"):format(name, detail or ""))
    end
end

-- Stub Registry + Schema to capture registered features.
local features = {}
local Registry = {
    GetFeature      = function(_, id) return features[id] end,
    RegisterFeature = function(_, spec) features[spec.id] = spec; return spec end,
}
local Schema = { Feature = function(def) return def end }

local ns = { Settings = { Registry = Registry, Schema = Schema } }
;(dofile("tests/helpers/locale.lua"))(ns)

-- Live profile with all three host flags set to true (default-on or opt-in).
local profile = {
    minimap = { enabled = true  },
    infobar = { enabled = false },  -- opt-in default
    alts    = { enabled = false },  -- opt-in default
}
local enableAddonCalls = {}
local disableAddonCalls = {}
_G.QUI = {
    db  = { profile = profile },
    GUI = { ShowConfirmation = function(_, opts) end },
    SafeReload = function() end,
}
_G.C_AddOns = {
    DoesAddOnExist     = function() return true end,
    IsAddOnLoaded      = function() return false end,
    GetAddOnEnableState = function() return 2 end,
    EnableAddOn        = function(n) enableAddonCalls[#enableAddonCalls+1] = n end,
    DisableAddOn       = function(n) disableAddonCalls[#disableAddonCalls+1] = n end,
    SaveAddOns         = function() end,
    LoadAddOn          = function() return true end,
}
ns.QUI_Modules = { NotifyChanged = function() end }

-- Real manifest.
assert(loadfile("core/addon_manifest.lua"))("QUI", ns)

-- Mocked loader (only used for folder rows; host rows bypass it).
ns.AddonLoader = {
    IsModuleAddonEnabled = function() return true end,
    SetModuleAddonEnabled = function(folder, on)
        if on then
            _G.C_AddOns.EnableAddOn(folder)
            _G.C_AddOns.LoadAddOn(folder)
            return "loaded"
        else
            _G.C_AddOns.DisableAddOn(folder)
            return "reload"
        end
    end,
}

assert(loadfile("core/settings/content/module_addons_content.lua"))("QUI", ns)

-- ── 1. QUI_UI bundle folder row ───────────────────────────────────────────────

local bundleRow = features["moduleAddon_QUI_UI"]
check("QUI_UI bundle row registered",
    bundleRow ~= nil,
    "expected moduleAddon_QUI_UI to be registered")
check("QUI_UI bundle row has moduleEntry",
    bundleRow and bundleRow.moduleEntry ~= nil)
check("QUI_UI bundle row label is non-empty",
    bundleRow and bundleRow.moduleEntry
        and type(bundleRow.moduleEntry.label) == "string"
        and #bundleRow.moduleEntry.label > 0,
    "label must be a non-empty string")

-- ── 2. Host module rows (minimap/infobar/alts) ────────────────────────────────

for _, mod in ipairs({ "minimap", "infobar", "alts" }) do
    local row = features["moduleFlag_" .. mod]
    check("moduleFlag_" .. mod .. " registered", row ~= nil,
        "expected moduleFlag_" .. mod .. " to be registered")
    check("moduleFlag_" .. mod .. " has moduleEntry",
        row and row.moduleEntry ~= nil)
end

-- ── 3. Host row flag read / write ─────────────────────────────────────────────

local minimapRow = features["moduleFlag_minimap"]
check("minimap host row: isEnabled reads profile.minimap.enabled",
    minimapRow and minimapRow.moduleEntry and minimapRow.moduleEntry.isEnabled() == true,
    "isEnabled should return true when profile.minimap.enabled == true")

-- Disable: must write the flag false; must NOT call DisableAddOn.
local addOnCallsBefore = #disableAddonCalls
if minimapRow and minimapRow.moduleEntry then
    minimapRow.moduleEntry.setEnabled(false)
end
check("minimap host row: setEnabled(false) writes profile.minimap.enabled=false",
    profile.minimap.enabled == false,
    "profile.minimap.enabled must be false after setEnabled(false)")
check("minimap host row: setEnabled(false) does NOT call DisableAddOn",
    #disableAddonCalls == addOnCallsBefore,
    ("DisableAddOn was called %d extra time(s) — host rows must not touch addon enable state"):format(
        #disableAddonCalls - addOnCallsBefore))
check("minimap host row: setEnabled(false) does NOT call EnableAddOn",
    #enableAddonCalls == 0,
    "EnableAddOn must not be called")

-- Re-enable: must write the flag true; isEnabled reflects the change.
if minimapRow and minimapRow.moduleEntry then
    minimapRow.moduleEntry.setEnabled(true)
end
check("minimap host row: setEnabled(true) writes profile.minimap.enabled=true",
    profile.minimap.enabled == true,
    "profile.minimap.enabled must be true after setEnabled(true)")
check("minimap host row: isEnabled() true after re-enable",
    minimapRow and minimapRow.moduleEntry and minimapRow.moduleEntry.isEnabled() == true)
check("minimap host row: setEnabled(true) does NOT call EnableAddOn",
    #enableAddonCalls == 0,
    "EnableAddOn must not be called for host rows")

-- ── 4. No rows for skinning/datatexts/qol ────────────────────────────────────

for _, mod in ipairs({ "skinning", "datatexts", "qol" }) do
    check("no row for " .. mod .. " (rides QUI_UI bundle)",
        features["moduleFlag_" .. mod] == nil and features["moduleAddon_QUI_" .. mod] == nil,
        "no feature row must exist for " .. mod)
end
-- Also no legacy QUI_Skinning/QUI_Datatexts/QUI_QoL folder rows.
check("no moduleAddon_QUI_Skinning row",  features["moduleAddon_QUI_Skinning"]  == nil)
check("no moduleAddon_QUI_Datatexts row", features["moduleAddon_QUI_Datatexts"] == nil)
check("no moduleAddon_QUI_QoL row",       features["moduleAddon_QUI_QoL"]       == nil)
check("no moduleAddon_QUI_Minimap row (host now)",  features["moduleAddon_QUI_Minimap"]  == nil)
check("no moduleAddon_QUI_InfoBar row (host now)",  features["moduleAddon_QUI_InfoBar"]  == nil)
check("no moduleAddon_QUI_Alts row (host now)",     features["moduleAddon_QUI_Alts"]     == nil)

-- ── 5. Result ─────────────────────────────────────────────────────────────────

if failures > 0 then
    io.stderr:write(("FAIL  module_addons_rows_test: %d assertion(s) failed\n"):format(failures))
    os.exit(1)
end
print("PASS: module_addons_rows_test")
