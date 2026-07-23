-- tests/unit/safecall_migration_t45f_test.lua
-- Task 45f (FINAL migration wave): QUI_CDM remainder (bar_renderer, sources,
-- catalog, buff_layout, reanchor cluster, hud_visibility, containers) +
-- QUI_ResourceBars/QUI_DamageMeter remainder + QUI_Debug/QUI_Options
-- remainder + misc modules (keybinds, minimap, integrations, uihider,
-- datatexts, dungeon, QUI_Bags, skinning notifications/gameplay) +
-- QUI_ActionBars leftovers (cooldowns/builder/actionbars.lua/flyout/
-- petstance/usability/extra_buttons/layout/per_bar_builders/buffborders/
-- gse_compat residual) bare-pcall -> ns.SafeCall migration.
-- Source-text contract pins: per-file occurrence counts + spot pins for
-- notable policy classes (bar_renderer HOT sink-forward duration binding,
-- hud_visibility sink-forward secret-alpha, compat-probe SKIPs, the
-- cdm_containers BuffState diagnostic-dump untouched, reanchor
-- securecall-adjacent bulkhead, damage_meter SecretWhenInCombat stays bare,
-- QUI_Logger/recorder.lua sanitize-mechanism untouched, aura_elements_editor
-- re-raise stays bare, ui_smoke report policy, keybinds zero-closure
-- per-button hot path, uihider doc-checked report sites, bag_window
-- defer-ooc retry-flag pair, buffborders QueueContainerWork defer-ooc pair,
-- gse_compat report-policy format guard, EditMode GetSettingValue reads
-- stay bare). Run:
-- lua5.1 tests/unit/safecall_migration_t45f_test.lua

local function readAll(path)
    local f = assert(io.open(path, "rb"), "failed to open " .. path)
    local d = f:read("*a"); f:close()
    return (d:gsub("\r\n", "\n"))
end

local fails = 0
local function check(name, ok)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name) end
end

local function countOccurrences(text, pattern)
    return select(2, text:gsub(pattern, ""))
end

local srcCache = {}
local function src(path)
    if not srcCache[path] then srcCache[path] = readAll(path) end
    return srcCache[path]
end

---------------------------------------------------------------------------
-- Per-file occurrence-count pins: SafeCall( call count (pre-existing +
-- new) + remaining bare pcall( count (includes xpcall( as a substring,
-- matching the t45a-e precedent's counting convention).
---------------------------------------------------------------------------
local FILES = {
    -- Scope A: QUI_CDM remainder
    { path = "QUI_CDM/cdm/cdm_bar_renderer.lua",          safeCall = 12, bareCall = 3 },
    { path = "QUI_CDM/cdm/cdm_sources.lua",                safeCall = 10, bareCall = 0 },
    { path = "QUI_CDM/cdm/cdm_catalog.lua",                safeCall = 3,  bareCall = 3 },
    { path = "QUI_CDM/cdm/cdm_buff_layout.lua",            safeCall = 3,  bareCall = 6 },
    { path = "QUI_CDM/cdm/cdm_reanchor.lua",               safeCall = 3,  bareCall = 1 },
    { path = "QUI_CDM/cdm/cdm_reanchor_auraphase.lua",     safeCall = 4,  bareCall = 0 },
    { path = "QUI_CDM/cdm/cdm_reanchor_boot.lua",          safeCall = 1,  bareCall = 0 },
    { path = "QUI_CDM/cdm/cdm_reanchor_realenv.lua",       safeCall = 4,  bareCall = 6 },
    { path = "QUI_CDM/cdm/hud_visibility.lua",             safeCall = 7,  bareCall = 0 },
    { path = "QUI_CDM/cdm/cdm_containers.lua",             safeCall = 5,  bareCall = 13 },
    -- Scope B: QUI_ResourceBars + QUI_DamageMeter remainder
    { path = "QUI_ResourceBars/resourcebars/resourcebars.lua",   safeCall = 4, bareCall = 8 },
    { path = "QUI_DamageMeter/damage_meter/damage_meter.lua",    safeCall = 3, bareCall = 7 },
    -- Scope C: QUI_Debug + QUI_Options remainder
    { path = "QUI_Debug/cdm_debug.lua",                    safeCall = 1,  bareCall = 17 },
    { path = "QUI_Debug/memaudit.lua",                     safeCall = 4,  bareCall = 13 },
    { path = "QUI_Debug/performance.lua",                  safeCall = 3,  bareCall = 5 },
    { path = "QUI_Debug/ui_smoke.lua",                     safeCall = 8,  bareCall = 5 },
    { path = "QUI_Debug/perftest.lua",                     safeCall = 2,  bareCall = 2 },
    { path = "QUI_Options/framework.lua",                  safeCall = 7,  bareCall = 3 },
    { path = "QUI_Options/shared.lua",                     safeCall = 4,  bareCall = 3 },
    { path = "QUI_Options/aura_spell_list.lua",            safeCall = 3,  bareCall = 3 },
    { path = "QUI_Options/aura_elements_editor.lua",       safeCall = 4,  bareCall = 1 },
    { path = "QUI_Logger/recorder.lua",                    safeCall = 0,  bareCall = 4 },
    -- Scope D: misc modules
    { path = "modules/utility/keybinds.lua",               safeCall = 2,  bareCall = 22 },
    { path = "modules/minimap/minimap.lua",                safeCall = 15, bareCall = 2 },
    { path = "modules/integrations/bigwigs.lua",           safeCall = 2,  bareCall = 3 },
    { path = "modules/integrations/dandersframes.lua",     safeCall = 4,  bareCall = 0 },
    { path = "modules/ui/uihider.lua",                     safeCall = 3,  bareCall = 0 },
    { path = "modules/datatexts/datatexts.lua",            safeCall = 5,  bareCall = 0 },
    { path = "modules/infobar/infobar.lua",                safeCall = 0,  bareCall = 3 },
    -- advisory sweep (2026-07-21): the UpdateButtonCooldown sink-forward
    -- SafeCall closure was DELETED — probe-first issecretvalue guards
    -- replaced it (startTime/duration proven plain before comparison;
    -- an unreadable field holds the last overlay state).
    { path = "modules/dungeon/party_keystones.lua",        safeCall = 0,  bareCall = 0 },
    { path = "modules/dungeon/keystone.lua",                safeCall = 0,  bareCall = 0 },
    { path = "QUI_Bags/bags/newitems.lua",                 safeCall = 1,  bareCall = 0 },
    { path = "QUI_Bags/bags/views/bag_window.lua",         safeCall = 2,  bareCall = 0 },
    { path = "QUI_Bags/bags/views/item_buttons.lua",       safeCall = 1,  bareCall = 0 },
    { path = "modules/alts/views/window.lua",              safeCall = 0,  bareCall = 1 },
    { path = "modules/skinning/notifications/alerts.lua",  safeCall = 1,  bareCall = 0 },
    { path = "modules/skinning/notifications/loot.lua",    safeCall = 2,  bareCall = 0 },
    -- round-22: the BUG-004 percentage pcall was DELETED — probe-first
    -- IsSecretValue guards replaced it (values proven plain before
    -- arithmetic; secret tick sink-passes raw and skips text).
    { path = "modules/skinning/gameplay/powerbaralt.lua",  safeCall = 0,  bareCall = 0 },
    -- Scope E: QUI_ActionBars leftovers
    { path = "QUI_ActionBars/actionbars/actionbars_cooldowns.lua",       safeCall = 1,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_builder.lua",         safeCall = 4,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars.lua",                 safeCall = 5,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_flyout.lua",          safeCall = 6,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_petstance.lua",       safeCall = 2,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_usability.lua",       safeCall = 1,  bareCall = 3 },
    { path = "QUI_ActionBars/actionbars/actionbars_extra_buttons.lua",   safeCall = 2,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_layout.lua",          safeCall = 1,  bareCall = 4 },
    { path = "QUI_ActionBars/actionbars/actionbars_per_bar_builders.lua", safeCall = 1, bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/buffborders.lua",                safeCall = 15, bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/gse_compat.lua",                 safeCall = 4,  bareCall = 0 },
}

for _, f in ipairs(FILES) do
    local text = src(f.path)
    local safeCallCount = countOccurrences(text, "SafeCall%(") + countOccurrences(text, "SafeCallMethod%(")
        + countOccurrences(text, "SafeCallMethodIfPresent%(")
    local bareCallCount = countOccurrences(text, "pcall%(")
    check(("pin: %s SafeCall( count == %d (saw %d)"):format(f.path, f.safeCall, safeCallCount),
        safeCallCount == f.safeCall)
    check(("pin: %s remaining bare pcall( count == %d (saw %d)"):format(f.path, f.bareCall, bareCallCount),
        bareCallCount == f.bareCall)
end

---------------------------------------------------------------------------
-- Scope A: cdm_bar_renderer.lua — HOT per-frame duration-binding update
-- (durObj forwarded raw to the C-side binding sink) -> sink-forward, zero
-- new closures (plain call-argument swap, no wrapper function introduced).
---------------------------------------------------------------------------
local barRenderer = src("QUI_CDM/cdm/cdm_bar_renderer.lua")
check('pin: cdm_bar_renderer.lua binding.SetDuration -> ns.SafeCall("sink-forward", ...)',
    barRenderer:find('ns.SafeCallMethod("sink-forward", binding, "SetDuration", durObj)', 1, true) ~= nil)
check('pin: cdm_bar_renderer.lua binding.SetEnabled (post-duration enable) -> ns.SafeCall("best-effort-style", ...)',
    barRenderer:find('ns.SafeCallMethodIfPresent("best-effort-style", binding, "SetEnabled", true)', 1, true) ~= nil)
check("pin: cdm_bar_renderer.lua zero new function( closures introduced by any SafeCall( conversion site",
    (function()
        for _ in barRenderer:gmatch('ns%.SafeCall%("[%w%-]+",%s*function') do return false end
        return true
    end)())

---------------------------------------------------------------------------
-- Scope A: hud_visibility.lua — HOT OnUpdate fade loops, zero new closures;
-- the secret curve-resolved alpha forward is the sanctioned sink-forward
-- path (never enters Lua arithmetic).
---------------------------------------------------------------------------
local hudVisibility = src("QUI_CDM/cdm/hud_visibility.lua")
check('pin: hud_visibility.lua damaged-alpha SetAlpha -> ns.SafeCall("sink-forward", ...)',
    hudVisibility:find('ns.SafeCallMethodIfPresent("sink-forward", frame, "SetAlpha", damagedAlpha)', 1, true) ~= nil)
check("pin: hud_visibility.lua zero new function( closures introduced by any SafeCall( conversion site",
    (function()
        for _ in hudVisibility:gmatch('ns%.SafeCall%("[%w%-]+",%s*function') do return false end
        return true
    end)())

---------------------------------------------------------------------------
-- Scope A: compat-probe SKIP class (IsCooldownViewerAvailable 3-line
-- probe idiom) stays bare pcall in every CDM file it appears in.
---------------------------------------------------------------------------
local cdmCatalog = src("QUI_CDM/cdm/cdm_catalog.lua")
check("pin: cdm_catalog.lua IsCooldownViewerAvailable compat probe stays bare pcall",
    cdmCatalog:find("local ok, isAvailable = pcall(api.IsCooldownViewerAvailable)", 1, true) ~= nil)

local cdmContainers = src("QUI_CDM/cdm/cdm_containers.lua")
check("pin: cdm_containers.lua IsCooldownViewerAvailable compat probe stays bare pcall",
    cdmContainers:find("local ok, ready = pcall(api.IsCooldownViewerAvailable)", 1, true) ~= nil)
check("pin: cdm_containers.lua _G.QUI_DebugCDM.BuffState diagnostic dumper stays fully untouched",
    cdmContainers:find("_G.QUI_DebugCDM.BuffState = function()", 1, true) ~= nil
    and cdmContainers:find('local ok, list = pcall(ns.CDMSpellData.BuildSpellListFromOwned, ns.CDMSpellData, "buff")', 1, true) ~= nil
    and cdmContainers:find("local okItems, items = pcall(viewer.GetItemFrames, viewer)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope A: cdm_reanchor_auraphase.lua — securecall-adjacent decorate
-- callbacks -> bulkhead (structure kept byte-identical, only the pcall ->
-- SafeCall swap changed).
---------------------------------------------------------------------------
local reanchorAuraphase = src("QUI_CDM/cdm/cdm_reanchor_auraphase.lua")
check("pin: cdm_reanchor_auraphase.lua exactly 4 ns.SafeCall(\"bulkhead\" decorate-callback sites",
    countOccurrences(reanchorAuraphase, 'ns%.SafeCall%("bulkhead"') == 4)

---------------------------------------------------------------------------
-- Scope B: resourcebars.lua — every site is a probe-read (power-percent /
-- charge secret data) that stays bare per THE SKIP RULE; 0 conversions.
---------------------------------------------------------------------------
local resourcebars = src("QUI_ResourceBars/resourcebars/resourcebars.lua")
check("pin: resourcebars.lua UnitPowerPercent probe-reads stay bare (0 conversions this wave)",
    resourcebars:find("ok, pct = pcall(UnitPowerPercent, unit, powerType, usePredicted, CurveConstants.ScaleTo100)", 1, true) ~= nil
    and resourcebars:find("ok, pct = pcall(UnitPowerPercent, unit, powerType, usePredicted)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope B: damage_meter.lua — SecretWhenInCombat combat-session fetch
-- probe-reads stay bare; the one non-secret GetAvailableCombatSessions
-- session-list read converts (no secret annotation, unlike its siblings).
---------------------------------------------------------------------------
local damageMeter = src("QUI_DamageMeter/damage_meter/damage_meter.lua")
check('pin: damage_meter.lua GetAvailableCombatSessions -> ns.SafeCall("best-effort-style", ...)',
    damageMeter:find("local ok, availableSessions = ns.SafeCall(\"best-effort-style\", C_DamageMeter.GetAvailableCombatSessions)", 1, true) ~= nil)
check("pin: damage_meter.lua GetCombatSessionFromID/FromType SecretWhenInCombat probe-reads stay bare",
    damageMeter:find("ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, sessionID, damageMeterType)", 1, true) ~= nil
    and damageMeter:find("ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, damageMeterType)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope C: QUI_Logger/recorder.lua — pcall IS the secret-sanitize
-- mechanism; ALL 4 sites stay bare, file fully untouched this wave.
---------------------------------------------------------------------------
local recorder = src("QUI_Logger/recorder.lua")
check("pin: recorder.lua SanitizeArg pcall-sanitize sites stay bare (all 4, file untouched)",
    recorder:find("local okKey, safeKey = pcall(ns.SanitizeArg, k, limits, depth + 1)", 1, true) ~= nil
    and recorder:find("local okValue, safeValue = pcall(ns.SanitizeArg, v, limits, depth + 1)", 1, true) ~= nil
    and recorder:find("local ok, copy = pcall(sanitizeTable, v, limits, depth)", 1, true) ~= nil
    and recorder:find("local ok, s = pcall(ns.SanitizeArg, (select(i, ...)), limits, 0)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope C: aura_elements_editor.lua :~1654 — deliberate re-raise (not a
-- swallow) stays bare, exactly as instructed.
---------------------------------------------------------------------------
local auraElementsEditor = src("QUI_Options/aura_elements_editor.lua")
check("pin: aura_elements_editor.lua RebuildList re-raise site stays bare pcall (REPORTED, untouched)",
    auraElementsEditor:find("local ok, err = pcall(RebuildList, ctx)", 1, true) ~= nil
    and auraElementsEditor:find("error(err, 0)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope C: ui_smoke.lua — smoke tester, loud-about-failures -> report
-- policy for its fallback sites.
---------------------------------------------------------------------------
local uiSmoke = src("QUI_Debug/ui_smoke.lua")
check('pin: ui_smoke.lua skin.GetFrameData -> ns.SafeCall("report", ...)',
    uiSmoke:find('local ok, value = ns.SafeCall("report", skin.GetFrameData, frame, key)', 1, true) ~= nil)
check('pin: ui_smoke.lua skin.IsSkinned -> ns.SafeCall("report", ...)',
    uiSmoke:find('local ok, value = ns.SafeCall("report", skin.IsSkinned, frame)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope C: QUI_Options/shared.lua — GetVerticalScroll(Range) getters
-- carry SecretReturnsForAspect; the outer probe-guard stays bare (extended
-- beyond the two literally-named lines to a third sibling site, same
-- documented reason).
---------------------------------------------------------------------------
local optionsShared = src("QUI_Options/shared.lua")
check("pin: shared.lua GetSafeVerticalScrollRange/GetSafeVerticalScroll probe-guards stay bare",
    optionsShared:find("local ok, maxScroll = pcall(scrollFrame.GetVerticalScrollRange, scrollFrame)", 1, true) ~= nil
    and optionsShared:find("local ok, currentScroll = pcall(scrollFrame.GetVerticalScroll, scrollFrame)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope C: QUI_Options/framework.lua — LoadAddOn genuine-throw sites ->
-- report (a real load failure must surface, not silently no-op).
---------------------------------------------------------------------------
local optionsFramework = src("QUI_Options/framework.lua")
check("pin: framework.lua LoadAddOn resolver present (report-policy conversion target)",
    optionsFramework:find("local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn", 1, true) ~= nil)
check('pin: framework.lua LoadAddOn call -> ns.SafeCall("report", ...)',
    optionsFramework:find('ns.SafeCall("report", loader', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope D: keybinds.lua — HOT per-button ProcessActionButton coarse wrap,
-- zero new closures (plain call-argument swap via the file's QUI.SafeCall
-- alias).
---------------------------------------------------------------------------
local keybinds = src("modules/utility/keybinds.lua")
check('pin: keybinds.lua ProcessActionButton per-button loop -> QUI.SafeCall("best-effort-style", ...)',
    keybinds:find("QUI.SafeCall(\"best-effort-style\", ProcessActionButton, button)", 1, true) ~= nil)
check("pin: keybinds.lua zero new function( closures introduced by any SafeCall( conversion site",
    (function()
        for _ in keybinds:gmatch('SafeCall%("[%w%-]+",%s*function') do return false end
        return true
    end)())

---------------------------------------------------------------------------
-- Scope D: uihider.lua — delve/scenario info APIs, doc-checked (no
-- Secret* annotation on any of the 3), a visibility-classification
-- failure here must surface -> report, default fallback kept.
---------------------------------------------------------------------------
local uihider = src("modules/ui/uihider.lua")
check('pin: uihider.lua HasActiveDelve -> ns.SafeCall("report", ...)',
    uihider:find('local ok, active = ns.SafeCall("report", delves.HasActiveDelve)', 1, true) ~= nil)
check('pin: uihider.lua GetTieredEntranceType -> ns.SafeCall("report", ...)',
    uihider:find('local ok, entranceType = ns.SafeCall("report", delves.GetTieredEntranceType)', 1, true) ~= nil)
check('pin: uihider.lua GetScenarioInfo -> ns.SafeCall("report", ...)',
    uihider:find('local ok, info = ns.SafeCall("report", C_ScenarioInfo.GetScenarioInfo)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope D: QUI_Bags/bags/views/bag_window.lua — SetPassThroughButtons x2,
-- guarded by the existing _quiPassThroughFailed retry flag -> defer-ooc.
---------------------------------------------------------------------------
local bagWindow = src("QUI_Bags/bags/views/bag_window.lua")
check('pin: bag_window.lua SetPassThroughButtons (both sites) -> ns.SafeCall("defer-ooc", ...)',
    bagWindow:find('ns.SafeCallMethod("defer-ooc", dep, "SetPassThroughButtons", "LeftButton")', 1, true) ~= nil
    and countOccurrences(bagWindow, 'ns%.SafeCallMethod%("defer%-ooc",%s*dep,%s*"SetPassThroughButtons"') == 2)
check("pin: bag_window.lua _quiPassThroughFailed retry-flag mechanism intact",
    bagWindow:find("dep._quiPassThroughFailed = true", 1, true) ~= nil
    and bagWindow:find("dep._quiPassThroughFailed and not InCombatLockdown()", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope D: modules/integrations/bigwigs.lua — compat probes stay bare;
-- proxy SetAllPoints anchor calls -> defer-ooc.
---------------------------------------------------------------------------
local bigwigs = src("modules/integrations/bigwigs.lua")
check("pin: bigwigs.lua GetPlugin/SendMessage compat probes stay bare pcall",
    bigwigs:find("local ok, plugin = pcall(BigWigs.GetPlugin, BigWigs, \"Bars\", true)", 1, true) ~= nil
    and bigwigs:find("local ok = pcall(BigWigsLoader.SendMessage, BigWigsLoader, \"BigWigs_ProfileUpdate\")", 1, true) ~= nil
    and bigwigs:find("local ok = pcall(bars.SendMessage, bars, \"BigWigs_ProfileUpdate\")", 1, true) ~= nil)
check('pin: bigwigs.lua proxy anchor calls -> ns.SafeCall("defer-ooc", ...)',
    countOccurrences(bigwigs, 'ns%.SafeCall%("defer%-ooc"') == 2)

---------------------------------------------------------------------------
-- Scope D: modules/skinning/gameplay/powerbaralt.lua — round-22 superseded
-- the BUG-004 pcall: UnitPower/UnitPowerMax are probed FIRST
-- (IsSecretValue), the secret tick sink-passes raw values, and the clean
-- branch does plain arithmetic — no pcall wrapper left. Probe-order itself
-- is pinned in secret_probe_order_source_guard_test.lua.
---------------------------------------------------------------------------
local powerbaralt = src("modules/skinning/gameplay/powerbaralt.lua")
check("pin: powerbaralt.lua probes power/maxPower before use (BUG-004 pcall superseded)",
    powerbaralt:find("Helpers.IsSecretValue(power) or Helpers.IsSecretValue(maxPower)", 1, true) ~= nil
    and powerbaralt:find("local calcOk, calcResult = pcall(function()", 1, true) == nil)

---------------------------------------------------------------------------
-- Scope E: buffborders.lua — the QueueContainerWork()-on-failure
-- ApplyMoverElements pair (strongest defer-ooc candidate per the 45c
-- reviewer) -> defer-ooc; surrounding QueueContainerWork/if-else structure
-- kept byte-identical.
---------------------------------------------------------------------------
local buffborders = src("QUI_ActionBars/actionbars/buffborders.lua")
check('pin: buffborders.lua ApplyMoverElements combat-path pair -> ns.SafeCall("defer-ooc", ...)',
    buffborders:find("ok1, inc1, fresh1 = ns.SafeCall(\"defer-ooc\", ApplyMoverElements, buffContainer,   buffActive,   true,  false)", 1, true) ~= nil
    and buffborders:find("ok2, inc2, fresh2 = ns.SafeCall(\"defer-ooc\", ApplyMoverElements, debuffContainer, debuffActive, false, false)", 1, true) ~= nil)
check("pin: buffborders.lua QueueContainerWork() reconcile call untouched",
    buffborders:find("if (not ok1) or (not ok2) or inc1 or inc2 then QueueContainerWork() end", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope E: gse_compat.lua residual — btn.Update discards -> best-effort-
-- style; the string.format guard (own-bug format/arg mismatch must
-- surface) -> report. No GSE identifiers added/renamed.
---------------------------------------------------------------------------
local gseCompat = src("QUI_ActionBars/actionbars/gse_compat.lua")
check('pin: gse_compat.lua btn.Update sites -> ns.SafeCall("best-effort-style", ...) (x2)',
    countOccurrences(gseCompat, 'ns%.SafeCallMethodIfPresent%("best%-effort%-style",%s*btn,%s*"Update"%)') == 2)
check('pin: gse_compat.lua string.format guard -> ns.SafeCall("report", ...)',
    gseCompat:find('local ok, msg = ns.SafeCall("report", string.format, fmt, ...)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Scope E: actionbars_layout.lua / actionbars_usability.lua — EditMode
-- GetSettingValue anchor-read getters feed real decisions, stay bare
-- (legit-skip class, matches 45c precedent in this same directory).
---------------------------------------------------------------------------
local actionbarsLayout = src("QUI_ActionBars/actionbars/actionbars_layout.lua")
check("pin: actionbars_layout.lua EditMode GetSettingValue reads stay bare (Orientation/NumRows/NumIcons)",
    actionbarsLayout:find("local okOrientation, orientation = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.Orientation)", 1, true) ~= nil
    and actionbarsLayout:find("local okRows, numRows = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.NumRows)", 1, true) ~= nil
    and actionbarsLayout:find("local okIcons, numIcons = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.NumIcons)", 1, true) ~= nil)

local actionbarsUsability = src("QUI_ActionBars/actionbars/actionbars_usability.lua")
check("pin: actionbars_usability.lua EditMode GetSettingValue reads stay bare (Orientation/NumRows)",
    actionbarsUsability:find("local okO, orientation = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.Orientation)", 1, true) ~= nil
    and actionbarsUsability:find("local okR, editNumRows = pcall(barFrame.GetSettingValue, barFrame, EditModeSettings.NumRows)", 1, true) ~= nil)

if fails > 0 then
    error(fails .. " failure(s) in safecall_migration_t45f_test", 0)
end
print("OK: safecall_migration_t45f_test (" .. #FILES .. " files pinned, all spot checks passed)")
