-- tests/unit/safecall_migration_t45d_test.lua
-- Task 45d: modules/layout remainder + core remainder bare-pcall ->
-- ns.SafeCall migration. Source-text contract pins: per-file occurrence
-- counts + spot pins for notable policy classes (drag-loop zero-closure
-- best-effort-style, defer-ooc recovery-queue sites, the two T1d-precedent
-- bulkhead cross-module-seam sites + their error-reraise removal, and the
-- exhaustive utils.lua converted-line inventory — utils.lua is the
-- taint/secret firewall, DEFAULT SKIP there, so its 8 conversions are
-- pinned individually rather than just by count). Run:
-- lua5.1 tests/unit/safecall_migration_t45d_test.lua

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
-- Per-file occurrence-count pins: SafeCall( call count (bulkhead + all
-- other policies, pre-existing + new) + remaining bare pcall( count
-- (includes any xpcall( on the file, since "pcall(" is a substring of
-- "xpcall(" — matches the t45a/t45c precedent's counting convention).
---------------------------------------------------------------------------
local FILES = {
    { path = "modules/layout/layoutmode.lua",       safeCall = 76, bareCall = 4 },
    { path = "modules/layout/anchoring.lua",         safeCall = 36, bareCall = 8 },
    { path = "modules/layout/layoutmode_ui.lua",     safeCall = 3,  bareCall = 4 },
    { path = "modules/layout/layoutmode_utils.lua",  safeCall = 2,  bareCall = 2 },
    -- utils.lua 34 -> 36: FrameVisibleSecure grew lookup probes (guard-
    -- position member lookups moved inside pcall — SEPARATE ProbeIsShown/
    -- ProbeGetAlpha so the hidden short-circuit never depends on the alpha
    -- getter; still deliberate secret-guards, not swallows).
    { path = "core/utils.lua",                       safeCall = 8,  bareCall = 36 },
    { path = "core/main.lua",                        safeCall = 15, bareCall = 6 },
    { path = "core/uikit.lua",                       safeCall = 11, bareCall = 9 },
    { path = "core/backdrop_deferred.lua",           safeCall = 5,  bareCall = 0 },
    { path = "core/aura_glue.lua",                   safeCall = 2,  bareCall = 3 },
    { path = "core/font_system.lua",                 safeCall = 4,  bareCall = 0 },
    { path = "core/profile_io.lua",                  safeCall = 4,  bareCall = 1 },
    { path = "core/migrations.lua",                  safeCall = 1,  bareCall = 1 },
    { path = "core/settings/pins.lua",                safeCall = 4,  bareCall = 1 },
    { path = "core/scaling.lua",                     safeCall = 1,  bareCall = 2 },
    { path = "init.lua",                             safeCall = 4,  bareCall = 0 },
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
-- Drag-loop zero-closure spot pins: layoutmode.lua's OnUpdate drag handler
-- (~:2222-2264, 8 sites, PER-FRAME HOT) must be function-ref+args only —
-- no "function(" wrapping the converted call itself.
---------------------------------------------------------------------------
local layoutmode = src("modules/layout/layoutmode.lua")
local dragShapes = {
    'ns.SafeCallMethod("best-effort-style", targetFrame, "ClearAllPoints")\n                            ns.SafeCallMethod("best-effort-style", targetFrame, "SetPoint", "CENTER", frame, "CENTER", -cdx, -cdy)',
    'ns.SafeCallMethod("best-effort-style", targetFrame, "ClearAllPoints")\n                            local frameOx, frameOy = postSnapOx, postSnapOy',
    'ns.SafeCallMethod("best-effort-style", targetFrame, "ClearAllPoints")\n                                ns.SafeCallMethod("best-effort-style", targetFrame, "SetPoint", "CENTER", data.handle, "CENTER", -cdx, -cdy)',
}
for i, shape in ipairs(dragShapes) do
    check("pin: drag-loop OnUpdate site group " .. i .. " converted function-ref+args (zero new closures)",
        layoutmode:find(shape, 1, true) ~= nil)
end
-- None of the 8 drag-loop conversions introduced a "function(" wrapper.
local dragRegionStart = assert(layoutmode:find('handle:SetScript("OnDragStart"', 1, true))
local dragRegionEnd = assert(layoutmode:find('handle:SetScript("OnDragStop"', 1, true))
local dragRegion = layoutmode:sub(dragRegionStart, dragRegionEnd)
check("pin: drag-loop OnUpdate region has exactly 8 SafeCall( best-effort-style mutator sites",
    countOccurrences(dragRegion, 'ns%.SafeCallMethod%("best%-effort%-style", target[Ff]rame,') == 8)
check("pin: drag-loop OnUpdate region introduces zero new function( closures around SafeCall",
    dragRegion:find('SafeCall%("best%-effort%-style", function') == nil)

---------------------------------------------------------------------------
-- T1d cross-module-seam bulkhead precedent: layoutmode.lua:1214/:3207
-- (both T3-skipped pcall(_G.QUI_ApplyFrameAnchor,...) sites) converted per
-- brief instruction; :3207's manual `if not ok then error(err) end`
-- re-raise removed (ns.SafeCall's bulkhead policy already probes+reports).
---------------------------------------------------------------------------
check("pin: layoutmode.lua :1214 _G.QUI_ApplyFrameAnchor -> bulkhead",
    layoutmode:find('ns.SafeCall("bulkhead", _G.QUI_ApplyFrameAnchor, key)', 1, true) ~= nil)
check("pin: layoutmode.lua :3207 _G.QUI_ApplyFrameAnchor(bonusRollFrame) -> bulkhead",
    layoutmode:find('ns.SafeCall("bulkhead", _G.QUI_ApplyFrameAnchor, "bonusRollFrame")', 1, true) ~= nil)
check("pin: layoutmode.lua :3207 error(err) re-raise removed",
    layoutmode:find("if not ok then error(err) end", 1, true) == nil)
check("pin: layoutmode.lua exactly 17 ns.SafeCall(\"bulkhead\" occurrences (15 pre-45d + 2 T1d-precedent)",
    countOccurrences(layoutmode, 'ns%.SafeCall%("bulkhead"') == 17)

---------------------------------------------------------------------------
-- layoutmode_utils.lua's companion _G.QUI_ToggleLayoutMode bulkhead site.
-- Its sibling REPORTED dispatcher (:642, pcall(fn) + geterrorhandler) stays
-- bare — already-correct, matches THE SKIP RULE's REPORTED-dispatcher class.
---------------------------------------------------------------------------
local layoutmodeUtils = src("modules/layout/layoutmode_utils.lua")
check('pin: layoutmode_utils.lua QUI_ToggleLayoutMode -> ns.SafeCall("bulkhead", ...)',
    layoutmodeUtils:find('ns.SafeCall("bulkhead", _G.QUI_ToggleLayoutMode)', 1, true) ~= nil)
check("pin: layoutmode_utils.lua :642 REPORTED geterrorhandler dispatcher stays bare (SKIP)",
    layoutmodeUtils:find("local ok, err = pcall(fn)", 1, true) ~= nil
    and layoutmodeUtils:find("if not ok and geterrorhandler then geterrorhandler()(err) end", 1, true) ~= nil)

---------------------------------------------------------------------------
-- SetGradient x4 compat-fallback sites stay bare pcall (brief explicit):
-- layoutmode_settings.lua:42/:244 (untouched by this task — zero edits to
-- that file), layoutmode_ui.lua:53/:1613.
---------------------------------------------------------------------------
local layoutmodeUi = src("modules/layout/layoutmode_ui.lua")
check("pin: layoutmode_ui.lua SetGradient compat pcall(function() still bare x2",
    countOccurrences(layoutmodeUi, "pcall%(function%(%)\n%s*glow:SetGradient") == 2)
local layoutmodeSettings = src("modules/layout/layoutmode_settings.lua")
check("pin: layoutmode_settings.lua untouched by 45d (SetGradient x2 stay bare); " ..
    "count is 8 post-followup (T1a unwrapped the OnMouseWheel SafeGetVerticalScroll " ..
    "SetVerticalScroll pcall to a direct self:SetVerticalScroll call)",
    countOccurrences(layoutmodeSettings, "pcall%(") == 8)

---------------------------------------------------------------------------
-- anchoring.lua: manual error-forward removal precedent (RunAnchoredFrames-
-- PostHooks' print(tostring(err)) and the per-callback pcall(op,...)/
-- pcall(entry.op,...) loops -> bulkhead, matching the character.lua:2592
-- "manual error-forward removed" precedent from 45c).
---------------------------------------------------------------------------
local anchoring = src("modules/layout/anchoring.lua")
check("pin: anchoring.lua RunAnchoredFramesPostHooks -> bulkhead, manual print removed",
    anchoring:find('ns.SafeCall("bulkhead", hook.fn, ...)', 1, true) ~= nil
    and anchoring:find('anchored%-frames hook error') == nil)
check("pin: anchoring.lua drainPendingCombatConsumerOps per-op loop -> bulkhead",
    anchoring:find('ns.SafeCall("bulkhead", op, originKey)', 1, true) ~= nil)
check("pin: anchoring.lua replayConsumerOps per-op loop -> bulkhead",
    anchoring:find('ns.SafeCall("bulkhead", entry.op, entry.key)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- anchoring.lua: THE SKIP RULE spot checks — secret-defense arithmetic
-- (:1728-1732 GetAlpha-then-compare), the GetWidth secret-adjacent probes,
-- the GetSize probe-reads, and the :3238-region error()-re-raise (REPORTED)
-- all stay bare.
---------------------------------------------------------------------------
-- GetAlpha probe stays a bare pcall (SKIP: silent unknown-alpha fallback, not
-- a classified failure) but the lookup moved INSIDE the pcall — pre-indexing
-- frame.GetAlpha re-performed the throwing lookup the pcall exists for
-- (round-18b guard-position class; InstallVisibilityHook hardening).
check("pin: anchoring.lua GetAlpha probe stays bare, lookup inside the pcall (SKIP)",
    anchoring:find("local okAlpha, curAlpha = pcall(InvokeGetAlpha, frame)", 1, true) ~= nil
    and anchoring:find("pcall(frame.GetAlpha", 1, true) == nil)
check("pin: anchoring.lua GetWidth secret-adjacent probes stay bare x2 (SKIP)",
    countOccurrences(anchoring, "pcall%(function%(%) return [%w]+:GetWidth%(%) end%)") == 2)
check("pin: anchoring.lua GetSize probe-reads stay bare x2 (SKIP)",
    countOccurrences(anchoring, "pcall%([%w%.]+%.GetSize, [%w%.]+%)") == 2)
check("pin: anchoring.lua :3238-region error()-re-raise (REPORTED) stays bare",
    anchoring:find("local replayOK, replayStatus = pcall(", 1, true) ~= nil
    and anchoring:find("error(replayStatus, 0)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- defer-ooc spot pins: recovery-queue-consuming sites across the wave.
---------------------------------------------------------------------------
local backdropDeferred = src("core/backdrop_deferred.lua")
check("pin: backdrop_deferred.lua all 5 sites -> defer-ooc, recovery flow byte-identical",
    countOccurrences(backdropDeferred, 'ns%.SafeCall%("defer%-ooc"') + countOccurrences(backdropDeferred, 'ns%.SafeCallMethod%("defer%-ooc"') == 5)

local utilsSrc = src("core/utils.lua")
check("pin: utils.lua SetFrameBackdropColor -> defer-ooc (consumed by init.lua RecoverQUIBackdrops)",
    utilsSrc:find('local ok = ns.SafeCallMethod("defer-ooc", frame, "SetBackdropColor", r, g, b, a)', 1, true) ~= nil)
check("pin: utils.lua SetFrameBackdropBorderColor -> defer-ooc",
    utilsSrc:find('local ok = ns.SafeCallMethod("defer-ooc", frame, "SetBackdropBorderColor", r, g, b, a)', 1, true) ~= nil)

local initSrc = src("init.lua")
check("pin: init.lua RecoverQUIBackdrops (regen-queue consumer) -> defer-ooc x2",
    initSrc:find('ns.SafeCallMethod("defer-ooc", f, "SetBackdropColor", f._quiBgR, f._quiBgG, f._quiBgB, f._quiBgA or 1)', 1, true) ~= nil
    and initSrc:find('ns.SafeCallMethod("defer-ooc", f, "SetBackdropBorderColor", f._quiBorderR, f._quiBorderG, f._quiBorderB, f._quiBorderA or 1)', 1, true) ~= nil)
check("pin: init.lua memaudit-tool one-shot recovery (NOT the regen queue) stays best-effort-style",
    initSrc:find('ns.SafeCallMethod("best-effort-style", f, "SetBackdropColor", f._quiBgR, f._quiBgG, f._quiBgB, f._quiBgA or 1)', 1, true) ~= nil)

local mainSrc = src("core/main.lua")
check("pin: main.lua :391/:407 UIParent:SetScale combat-deferral -> defer-ooc x2",
    countOccurrences(mainSrc, 'ns%.SafeCallMethod%("defer%-ooc", UIParent, "SetScale",') == 2)
check("pin: main.lua :125-129 ApplyAnchors/RefreshUnitFrames/RefreshGroupFrames post-scale trio -> bulkhead",
    mainSrc:find('ns.SafeCall("bulkhead", ApplyAnchors, true)', 1, true) ~= nil
    and mainSrc:find('ns.SafeCall("bulkhead", RefreshUnitFrames)', 1, true) ~= nil
    and mainSrc:find('ns.SafeCall("bulkhead", RefreshGroupFrames)', 1, true) ~= nil)
check("pin: main.lua :463 TeardownFrameTree -> bulkhead",
    mainSrc:find('ns.SafeCallMethod("bulkhead", QUI.GUI, "TeardownFrameTree", QUI.GUI.MainFrame, { includeRoot = true })', 1, true) ~= nil)
check("pin: main.lua RefreshAll manual print(tostring(err)) removed -> bulkhead",
    mainSrc:find('ns.SafeCallMethod("bulkhead", self, "RefreshAll")', 1, true) ~= nil
    and mainSrc:find("RefreshAll error:") == nil)

local uikitSrc = src("core/uikit.lua")
check("pin: uikit.lua proxy resize/reanchor combatPending sites -> defer-ooc x3",
    countOccurrences(uikitSrc, 'ns%.SafeCallMethod%("defer%-ooc", self,') == 3)

local scalingSrc = src("core/scaling.lua")
check("pin: scaling.lua ApplyUIScale UIParent:SetScale -> defer-ooc, closure removed",
    scalingSrc:find('local success = ns.SafeCallMethod("defer-ooc", UIParent, "SetScale", scaleToApply)', 1, true) ~= nil)
check("pin: scaling.lua GetPixelSize secret-scale probes stay bare x2 (SKIP)",
    countOccurrences(scalingSrc, "pcall%([%w%.]+%.GetEffectiveScale, [%w%.]+%)") == 2)

---------------------------------------------------------------------------
-- core/utils.lua exhaustive converted-line inventory: the taint/secret
-- firewall file is DEFAULT SKIP, and every conversion here was individually
-- taint-checked. Pin the EXACT 8-site list (best-effort-style x6,
-- defer-ooc x2) so any future edit to this file must consciously touch
-- this test.
---------------------------------------------------------------------------
local utilsConverted = {
    { shape = 'ns.SafeCallMethod("best-effort-style", frame, "Hide")', note = "FlushCombatHideQueue" },
    { shape = 'ns.SafeCallMethod("best-effort-style", self, "Hide")', note = "DeferredHideOnShow" },
    { shape = 'return ns.SafeCallMethod("best-effort-style", frame, "Show")', note = "Helpers.SafeShow" },
    { shape = 'return ns.SafeCallMethod("best-effort-style", frame, "Hide")', note = "Helpers.SafeHide" },
    { shape = 'ns.SafeCallMethodIfPresent("best-effort-style", cooldownFrame, "SetDrawSwipe",', note = "ApplyCooldownSwipeStyle SetDrawSwipe" },
    { shape = 'ns.SafeCallMethodIfPresent("best-effort-style", cooldownFrame, "SetReverse", element and element.reverseSwipe == true)', note = "ApplyCooldownSwipeStyle SetReverse" },
    { shape = 'local ok = ns.SafeCallMethod("defer-ooc", frame, "SetBackdropColor", r, g, b, a)', note = "SetFrameBackdropColor" },
    { shape = 'local ok = ns.SafeCallMethod("defer-ooc", frame, "SetBackdropBorderColor", r, g, b, a)', note = "SetFrameBackdropBorderColor" },
}
check("pin: utils.lua converted-line inventory has exactly 8 entries (the brief's ≤8 ceiling, hit exactly)",
    #utilsConverted == 8)
for _, entry in ipairs(utilsConverted) do
    check("pin: utils.lua converted site — " .. entry.note,
        utilsSrc:find(entry.shape, 1, true) ~= nil)
end

-- Spot-check a representative sample of the 34 SKIPPED utils.lua sites —
-- the polarity-critical guards and statement-split probe idiom that make
-- this file the taint/secret firewall — to prove the DEFAULT SKIP held.
local utilsSkipped = {
    "local ok, protected = pcall(frame.IsProtected, frame)",       -- FrameIsProtected, fail-open
    "local ok, answer = pcall(frame.IsProtected, frame)",          -- FrameMutationRestricted, fail-closed
    "local okShownProbe, isShownM = pcall(ProbeIsShown, frame)",   -- FrameVisibleSecure lookup probe (statement-split)
    "local okAlphaProbe, getAlphaM = pcall(ProbeGetAlpha, frame)", -- FrameVisibleSecure alpha probe (after shown short-circuit)
    "local applied = pcall(cooldownFrame.SetCooldownFromDurationObject, cooldownFrame, durationObj, reverse)", -- result USED (branch), not "unused" per brief's cooldown-helper caveat
}
for _, shape in ipairs(utilsSkipped) do
    check("pin: utils.lua SKIPPED probe/guard survives untouched — " .. shape,
        utilsSrc:find(shape, 1, true) ~= nil)
end

---------------------------------------------------------------------------
-- core/aura_glue.lua: the 132/146/154 GetUnitAuras filter-validity probe
-- (sophisticated deliberate, re-probe baseline discriminator) stays bare;
-- the SEPARATE Configure->Restyle fallback (chain-next) and regen-replay
-- loop (bulkhead, manual tostring(err) forward removed) convert.
---------------------------------------------------------------------------
local auraGlueSrc = src("core/aura_glue.lua")
check("pin: aura_glue.lua GetUnitAuras filter-validity probe stays bare x3 (SKIP, sophisticated deliberate)",
    countOccurrences(auraGlueSrc, "pcall%(C_UnitAuras%.GetUnitAuras, unit,") == 3)
check('pin: aura_glue.lua RunConfigPass Configure->Restyle fallback -> chain-next',
    auraGlueSrc:find('local ok = ns.SafeCall("chain-next", AuraSkin.Configure, container, profile, groups)', 1, true) ~= nil)
check("pin: aura_glue.lua FlushPending per-owner replay -> bulkhead, manual tostring(err) forward removed",
    auraGlueSrc:find('ns.SafeCall("bulkhead", fn, owner)', 1, true) ~= nil
    and auraGlueSrc:find("regen replay error:") == nil)

---------------------------------------------------------------------------
-- core/migrations.lua: :409 string.format -> report (nil-fallback kept);
-- :183 GetSpecializationInfoByID result-table capture (value feeds
-- classToken decision) stays bare.
---------------------------------------------------------------------------
local migrationsSrc = src("core/migrations.lua")
check('pin: migrations.lua MigLog string.format -> SafeCall("report", ...), nil-fallback kept',
    migrationsSrc:find('local ok, msg = ns.SafeCall("report", string.format, fmt, ...)', 1, true) ~= nil
    and migrationsSrc:find("line = ok and msg or fmt", 1, true) ~= nil)
check("pin: migrations.lua GetSpecializationInfoByID result-table capture stays bare (SKIP, value feeds decision)",
    migrationsSrc:find("local result = { pcall(GetSpecializationInfoByID, specID) }", 1, true) ~= nil)

---------------------------------------------------------------------------
-- core/settings/pins.lua: WithAutoApplySuppressed's deliberate finally-
-- pattern error(resultA) re-raise (push/pop suppression around an
-- arbitrary callback) stays bare — converting would silently swallow the
-- callback's error instead of propagating it after cleanup runs.
---------------------------------------------------------------------------
local pinsSrc = src("core/settings/pins.lua")
check("pin: pins.lua WithAutoApplySuppressed finally-reraise stays bare (SKIP, deliberate error passthrough)",
    pinsSrc:find("local ok, resultA, resultB, resultC = pcall(callback)", 1, true) ~= nil
    and pinsSrc:find("if not ok then\n        error(resultA)\n    end", 1, true) ~= nil)

if fails > 0 then
    error(fails .. " failure(s) in safecall_migration_t45d_test", 0)
end
print("OK: safecall_migration_t45d_test (" .. #FILES .. " files pinned, all spot checks passed)")
