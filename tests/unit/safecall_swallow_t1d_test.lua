-- tests/unit/safecall_swallow_t1d_test.lua
-- Source-text contract pins for Task 1d: 10 swallow-pcall sites converted to
-- ns.SafeCall (policy-classified) or existence-guarded loud direct calls,
-- across QUI_ResourceBars/resourcebars/resourcebars.lua,
-- QUI_DamageMeter/damage_meter/damage_meter.lua, QUI_CDM/cdm/cdm_containers.lua
-- and QUI_CDM/cdm/cdm_sources.lua. Pins the converted shape present, the old
-- bare-pcall shape absent (exact strings), and that existence guards at
-- sites 2-4/7/8 survived the swap.
-- Run: lua5.1 tests/unit/safecall_swallow_t1d_test.lua
local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a"); f:close()
    return (d:gsub("\r\n", "\n"))
end

local fails = 0
local function check(name, ok)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name) end
end

local function countOf(src, pattern)
    return select(2, src:gsub(pattern:gsub("%W", "%%%1"), ""))
end

---------------------------------------------------------------------------
-- File 1: QUI_ResourceBars/resourcebars/resourcebars.lua
---------------------------------------------------------------------------
local rb = readAll("QUI_ResourceBars/resourcebars/resourcebars.lua")

-- Site 1: power-bar text-styling block, best-effort-style, closure kept as-is.
check("site1: converted to ns.SafeCall(\"best-effort-style\", function() ...)",
    rb:find('ns.SafeCall("best-effort-style", function()', 1, true) ~= nil)
check("site1: old pcall-guarded comment gone",
    rb:find("(pcall-guarded so errors here cannot prevent the bar from showing)", 1, true) == nil)
check("site1: new SafeCall-guarded comment present",
    rb:find("(SafeCall-guarded so errors here cannot prevent the bar from showing)", 1, true) ~= nil)

-- Sites 2-4: bulkhead, existence checks preserved verbatim.
check("site2: ns.SafeCall(\"bulkhead\", _G.QUI_UpdateAnchoredUnitFrames)",
    rb:find('ns.SafeCall("bulkhead", _G.QUI_UpdateAnchoredUnitFrames)', 1, true) ~= nil)
check("site2: old bare pcall(_G.QUI_UpdateAnchoredUnitFrames) gone",
    rb:find("pcall(_G.QUI_UpdateAnchoredUnitFrames)", 1, true) == nil)
check("site2: existence guard preserved",
    rb:find("if _G.QUI_UpdateAnchoredUnitFrames then", 1, true) ~= nil)

check("site3: ns.SafeCall(\"bulkhead\", _G.QUI_UpdateAnchoredFrames)",
    rb:find('ns.SafeCall("bulkhead", _G.QUI_UpdateAnchoredFrames)', 1, true) ~= nil)
check("site3: old bare pcall(_G.QUI_UpdateAnchoredFrames) gone",
    rb:find("pcall(_G.QUI_UpdateAnchoredFrames)", 1, true) == nil)
check("site3: existence guard preserved",
    rb:find("if _G.QUI_UpdateAnchoredFrames then", 1, true) ~= nil)

check("site4: ns.SafeCall(\"bulkhead\", _G.QUI_RefreshCDMBuffLayout)",
    rb:find('ns.SafeCall("bulkhead", _G.QUI_RefreshCDMBuffLayout)', 1, true) ~= nil)
check("site4: old bare pcall(_G.QUI_RefreshCDMBuffLayout) gone",
    rb:find("pcall(_G.QUI_RefreshCDMBuffLayout)", 1, true) == nil)
check("site4: existence guard preserved",
    rb:find("if _G.QUI_RefreshCDMBuffLayout then", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File 2: QUI_DamageMeter/damage_meter/damage_meter.lua
---------------------------------------------------------------------------
local dm = readAll("QUI_DamageMeter/damage_meter/damage_meter.lua")

-- Sites 5-6: drag-stop + resize window.Refresh, best-effort-style, both occurrences.
check("sites5-6: old bare pcall(window.Refresh, window) fully gone",
    dm:find("pcall(window.Refresh, window)", 1, true) == nil)
check("sites5-6: ns.SafeCallMethod(\"best-effort-style\", window, \"Refresh\") appears twice",
    countOf(dm, 'ns.SafeCallMethodIfPresent("best-effort-style", window, "Refresh")') == 2)
check("site5: guard collapsed into the protected lookup (IfPresent)",
    dm:find('ns.SafeCallMethodIfPresent("best-effort-style", window, "Refresh")', 1, true) ~= nil)
check("site6: both Refresh sites use the protected-lookup IfPresent form (x2)",
    select(2, dm:gsub('ns%.SafeCallMethodIfPresent%("best%-effort%-style", window, "Refresh"%)', "")) == 2)

-- Sites 7-8: window-destroy registry unwind, loud existence-guarded direct calls.
check("site7: old pcall(ns.QUI_LayoutMode.UnregisterElement...) gone",
    dm:find("pcall(ns.QUI_LayoutMode.UnregisterElement", 1, true) == nil)
check("site7: direct loud call ns.QUI_LayoutMode.UnregisterElement(ns.QUI_LayoutMode, key)",
    dm:find("ns.QUI_LayoutMode.UnregisterElement(ns.QUI_LayoutMode, key)", 1, true) ~= nil)
check("site7: existence guard preserved",
    dm:find("if ns.QUI_LayoutMode and ns.QUI_LayoutMode.UnregisterElement then", 1, true) ~= nil)

check("site8: old pcall(_G.QUI_UnregisterFrameResolver, key) gone",
    dm:find("pcall(_G.QUI_UnregisterFrameResolver, key)", 1, true) == nil)
check("site8: direct loud call _G.QUI_UnregisterFrameResolver(key)",
    dm:find("_G.QUI_UnregisterFrameResolver(key)", 1, true) ~= nil)
check("site8: existence guard preserved",
    dm:find("if _G.QUI_UnregisterFrameResolver then", 1, true) ~= nil)

check("sites7-8: loud-vs-report decision documented (key is our own string, never secret-tainted)",
    dm:find("never\n    -- secret-tainted", 1, true) ~= nil
    or dm:find("never secret-tainted", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File 3: QUI_CDM/cdm/cdm_containers.lua
---------------------------------------------------------------------------
local cc = readAll("QUI_CDM/cdm/cdm_containers.lua")

check("site9: ns.SafeCall(\"bulkhead\", _loadoutChangeCallbacks[i])",
    cc:find('ns.SafeCall("bulkhead", _loadoutChangeCallbacks[i])', 1, true) ~= nil)
check("site9: old bare pcall(_loadoutChangeCallbacks[i]) gone",
    cc:find("pcall(_loadoutChangeCallbacks[i])", 1, true) == nil)
check("site9: loop structure unchanged (still iterates _loadoutChangeCallbacks by index)",
    cc:find("for i = 1, #_loadoutChangeCallbacks do", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File 4: QUI_CDM/cdm/cdm_sources.lua
---------------------------------------------------------------------------
local cs = readAll("QUI_CDM/cdm/cdm_sources.lua")

check('site10: ns.SafeCall("report", scanner.RegisterItemUseSpell, itemID, spellID)',
    cs:find('ns.SafeCall("report", scanner.RegisterItemUseSpell, itemID, spellID)', 1, true) ~= nil)
check("site10: old bare pcall(scanner.RegisterItemUseSpell, itemID, spellID) gone",
    cs:find("pcall(scanner.RegisterItemUseSpell, itemID, spellID)", 1, true) == nil)
check("site10: sanitize evidence documented (QueryInventoryItemID plain-slot lookup)",
    cs:find("QueryInventoryItemID(\"player\",", 1, true) ~= nil)
check("site10: sanitize evidence cites the reject-secret-ids guard it relies on",
    cs:find("@secret-policy: reject-secret-ids", 1, true) ~= nil
    and cs:find("QueryBestOwnedItemVariant", 1, true) ~= nil)
check("site10: sanitize evidence cites the API doc checked for spellID secrecy",
    cs:find("ItemDocumentation.lua", 1, true) ~= nil)

if fails > 0 then error(fails .. " failure(s) in safecall_swallow_t1d_test") end
print("OK: safecall_swallow_t1d_test (all checks passed)")
