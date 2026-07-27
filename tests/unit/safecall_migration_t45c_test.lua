-- tests/unit/safecall_migration_t45c_test.lua
-- Task 45c: modules/skinning remainder + QUI_ActionBars remainder bare-pcall
-- -> ns.SafeCall migration. Source-text contract pins: per-file occurrence
-- counts + spot pins for the notable policy classes (SafeUpdate coarse
-- wraps, helpers.lua doc-checked "report" sites, totems.lua's first
-- production "defer-ooc" uses, sink-forward, bulkhead). Run:
-- lua5.1 tests/unit/safecall_migration_t45c_test.lua

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

---------------------------------------------------------------------------
-- Per-file occurrence-count pins: ns.SafeCall( call count + remaining bare
-- pcall( count. Counts, not enumeration, so unrelated same-class edits
-- don't silently break this test.
---------------------------------------------------------------------------
local FILES = {
    { path = "modules/skinning/character_pane/character.lua",       safeCall = 25, bareCall = 29 },
    { path = "modules/skinning/character_pane/inspect.lua",         safeCall = 7,  bareCall = 10 },
    -- 28 = 26 pre-PTR7 + 2 aura-tooltip bridge pushes (ApplyAuraTooltipStyle:
    -- SetTooltipBackdrop + ResetTooltipStyle, both engine-mediated).
    { path = "modules/skinning/system/tooltips.lua",                safeCall = 28, bareCall = 19 },
    { path = "modules/skinning/frames/character.lua",               safeCall = 7,  bareCall = 0 },
    { path = "modules/skinning/frames/achievement.lua",             safeCall = 2,  bareCall = 0 },
    { path = "modules/skinning/frames/craftingorders.lua",          safeCall = 2,  bareCall = 0 },
    { path = "modules/skinning/frames/journals.lua",                safeCall = 2,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_glow.lua",       safeCall = 15, bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_events.lua",     safeCall = 2,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/actionbars_skinning.lua",   safeCall = 5,  bareCall = 0 },
    { path = "QUI_ActionBars/actionbars/totems.lua",                safeCall = 14, bareCall = 4 },
    { path = "QUI_ActionBars/actionbars/actionbars_helpers.lua",    safeCall = 4,  bareCall = 1 },
    { path = "QUI_ActionBars/actionbars/actionbars_public.lua",     safeCall = 6,  bareCall = 0 },
}

local srcCache = {}
local function src(path)
    if not srcCache[path] then srcCache[path] = readAll(path) end
    return srcCache[path]
end

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
-- SafeUpdate coarse-wrap spot pins (glow.lua x3, events.lua x1) — the
-- audit's flagship coarse-wrap, per-frame HOT, zero new closures.
---------------------------------------------------------------------------
local glowSrc = src("QUI_ActionBars/actionbars/actionbars_glow.lua")
check("pin: glow.lua SafeUpdate coarse wrap occurs 3x (first-run active/newly-empty + fast-path)",
    countOccurrences(glowSrc, 'ns%.SafeCall%("best%-effort%-style", ActionBarsOwned%.SafeUpdate, btn%)') == 3)

local eventsSrc = src("QUI_ActionBars/actionbars/actionbars_events.lua")
check("pin: events.lua SafeUpdate coarse wrap present",
    eventsSrc:find('ns.SafeCall("best-effort-style", ActionBarsOwned.SafeUpdate, btn)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- helpers.lua doc-checked "report" sites (IsInInstance / GetInstanceInfo /
-- C_ChallengeMode.IsChallengeModeActive): tests/api-docs/blizzard/ carries
-- no SecretArguments/SecretWhenRestricted annotation for any of the three,
-- so a real failure must surface (a swallowed failure flips bar
-- visibility) rather than being classified as an expected error.
---------------------------------------------------------------------------
local helpersSrc = src("QUI_ActionBars/actionbars/actionbars_helpers.lua")
check('pin: helpers.lua IsInInstance -> SafeCall("report", ...)',
    helpersSrc:find('ns.SafeCall("report", IsInInstance)', 1, true) ~= nil)
check('pin: helpers.lua GetInstanceInfo -> SafeCall("report", ...)',
    helpersSrc:find('ns.SafeCall("report", GetInstanceInfo)', 1, true) ~= nil)
check('pin: helpers.lua C_ChallengeMode.IsChallengeModeActive -> SafeCall("report", ...)',
    helpersSrc:find('ns.SafeCall("report", C_ChallengeMode.IsChallengeModeActive)', 1, true) ~= nil)
-- SafeIsActionInRange (a Safe*-named helper, per THE SKIP RULE) keeps its
-- bare pcall — the one remaining bareCall pin above.
check("pin: helpers.lua SafeIsActionInRange's internal pcall(IsActionInRange stays bare (Safe*-helper SKIP)",
    helpersSrc:find("local ok, val = pcall(IsActionInRange, action)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- public.lua: AutoPushSpellWatcher.Start -> report; both
-- kb.UpdateAllRotationHelpers call sites -> bulkhead (explicit brief
-- instruction, lines 226 and 281 pre-edit).
---------------------------------------------------------------------------
local publicSrc = src("QUI_ActionBars/actionbars/actionbars_public.lua")
check('pin: public.lua AutoPushSpellWatcher.Start -> SafeCall("report", ...)',
    publicSrc:find('ns.SafeCallMethodIfPresent("report", _G.AutoPushSpellWatcher, "Start")', 1, true) ~= nil)
check("pin: public.lua kb.UpdateAllRotationHelpers bulkhead occurs 2x (OnSetActionSpell + UpdateAllAssistedHighlightFramesForSpell)",
    countOccurrences(publicSrc, 'ns%.SafeCall%("bulkhead", kb%.UpdateAllRotationHelpers') == 2)

---------------------------------------------------------------------------
-- totems.lua: first production "defer-ooc" uses. StealEvents/RestoreEvents
-- mutate the protected TotemFrame + its SecureActionButtonTemplate
-- totemButtons; both functions are bookended by
-- `if InCombatLockdown() then pendingReconcile = true; return end` gates
-- (so these mutations only ever run OOC) and pendingReconcile is consumed
-- on PLAYER_REGEN_ENABLED to re-run UpdateTotems() — an unexpected failure
-- here is recoverable via that existing OOC-recovery mechanism, hence
-- "defer-ooc" rather than plain "best-effort-style". Sites (post-edit
-- line numbers): 562 tf:UnregisterEvent, 577 tbtn:EnableMouse(false),
-- 586 tf:RegisterEvent, 593 tbtn:EnableMouse(true), 597 tf:Update.
---------------------------------------------------------------------------
local totemsSrc = src("QUI_ActionBars/actionbars/totems.lua")
check("pin: totems.lua defer-ooc occurs 5x (StealEvents x3 + RestoreEvents x2)",
    countOccurrences(totemsSrc, 'ns%.SafeCall%("defer%-ooc"') + countOccurrences(totemsSrc, 'ns%.SafeCallMethod%("defer%-ooc"')
    + countOccurrences(totemsSrc, 'ns%.SafeCallMethodIfPresent%("defer%-ooc"') == 5)
check("pin: totems.lua defer-ooc: tf.UnregisterEvent",
    totemsSrc:find('ns.SafeCallMethod("defer-ooc", tf, "UnregisterEvent", event)', 1, true) ~= nil)
check("pin: totems.lua defer-ooc: tf.RegisterEvent",
    totemsSrc:find('ns.SafeCallMethod("defer-ooc", tf, "RegisterEvent", event)', 1, true) ~= nil)
check("pin: totems.lua defer-ooc: tf.Update",
    totemsSrc:find('ns.SafeCallMethodIfPresent("defer-ooc", tf, "Update")', 1, true) ~= nil)
check("pin: totems.lua defer-ooc: tbtn.EnableMouse occurs 2x (false in StealEvents + true in RestoreEvents)",
    countOccurrences(totemsSrc, 'ns%.SafeCallMethod%("defer%-ooc", tbtn, "EnableMouse"') == 2)

-- totems.lua: sink-forward sites — possibly-secret combat duration/icon
-- data forwarded raw to a C-side setter (SetTexture/SetFormattedText),
-- never truth-tested.
check("pin: totems.lua sink-forward occurs 3x (icon SetTexture + 2x duration SetFormattedText)",
    countOccurrences(totemsSrc, 'ns%.SafeCall%("sink%-forward"') + countOccurrences(totemsSrc, 'ns%.SafeCallMethod%("sink%-forward"') == 3)

-- totems.lua: StyleButton swipe styling (explicit brief line :273) stays
-- best-effort-style, not defer-ooc — cosmetic Cooldown-frame setters, not
-- part of the pendingReconcile OOC-recovery system.
check("pin: totems.lua StyleButton swipe whole-pass wrap -> best-effort-style",
    totemsSrc:find('ns.SafeCall("best-effort-style", function()\n        cd:SetSwipeTexture', 1, true) ~= nil)

-- totems.lua: THE SKIP RULE spot pins — the four secret probe-read /
-- truth-test sites stay bare pcall.
check("pin: totems.lua @secret-safe isActive comparison stays bare pcall (SKIP)",
    totemsSrc:find("-- @secret-safe: comparisons run INSIDE pcall", 1, true) ~= nil)
check("pin: totems.lua GetTotemTimeLeft (combat isActive probe) stays bare pcall (SKIP)",
    totemsSrc:find("local tok, timeLeft = pcall(GetTotemTimeLeft, slot)", 1, true) ~= nil)
check("pin: totems.lua durObj:GetRemainingDuration stays bare pcall (SKIP)",
    totemsSrc:find("local rok, rem = pcall(durObj.GetRemainingDuration, durObj)", 1, true) ~= nil)
check("pin: totems.lua ticker GetTotemTimeLeft probe-before-truth-test stays bare pcall (SKIP)",
    totemsSrc:find("local ok, remaining = pcall(GetTotemTimeLeft, b.slot)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- character.lua: sink-forward (row.bar:SetValue with possibly-secret pct)
-- + the brief's explicit :2791 broad stat-tooltip wrap conversion keeping
-- the documented default-tooltip fallback.
---------------------------------------------------------------------------
local charSrc = src("modules/skinning/character_pane/character.lua")
check("pin: character.lua sink-forward row.bar.SetValue present",
    charSrc:find('ns.SafeCallMethod("sink-forward", row.bar, "SetValue", pct)', 1, true) ~= nil)
check("pin: character.lua :2791 stat-tooltip wrap -> best-effort-style, default-tooltip fallback comment retained",
    charSrc:find('ns.SafeCall("best-effort-style", function()\n                            local _, unitClass = UnitClass("player")', 1, true) ~= nil
        and charSrc:find("-- If pcall failed, keep the default tooltip2", 1, true) ~= nil)
check("pin: character.lua outer stats-panel whole-pass wrap converted, raw err print removed",
    charSrc:find('local success = ns.SafeCall("best-effort-style", function()', 1, true) ~= nil
        and charSrc:find('print("QUI: Error updating stats panel:", err)', 1, true) == nil)
-- SKIP-rule spot pin: the ARMOR-idiom secret-forward truth-test sites stay bare.
check("pin: character.lua UnitArmor ARMOR-idiom stays bare pcall (SKIP)",
    charSrc:find("local aOk, _, aEff = pcall(UnitArmor, unit)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- tooltips.lua: module-level `local SafeCall = ns.SafeCall` capture — several
-- functions shadow the module `ns` with `local ns = tooltip.NineSlice`, so
-- `ns.SafeCall` would resolve to the wrong table inside them.
---------------------------------------------------------------------------
local ttSrc = src("modules/skinning/system/tooltips.lua")
check("pin: tooltips.lua captures a module-level local SafeCall (ns-shadow safe)",
    ttSrc:find("local SafeCall = ns.SafeCall", 1, true) ~= nil)
check("pin: tooltips.lua HideNineSlice uses the captured local SafeCall, not ns.SafeCall",
    ttSrc:find("SafeCall(\"best-effort-style\", ns.Hide, ns)", 1, true) ~= nil)

if fails > 0 then error(fails .. " failure(s) in safecall_migration_t45c_test") end
print("OK: safecall_migration_t45c_test (all checks passed)")
