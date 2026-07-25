-- tests/unit/safecall_migration_t45e_test.lua
-- Task 45e: modules/qol remainder + modules/trackers remainder +
-- modules/combat remainder bare-pcall -> ns.SafeCall migration.
-- Source-text contract pins: per-file occurrence counts + spot pins for
-- notable policy classes (healer_mana sink-forwards, rotationassist
-- chain-next override-spell fallback, tooltip.lua zero-new-closures,
-- atonement_counter/focuscastalert chain-next fallback chains, preytracker
-- widget-suppression best-effort-style, tooltip.lua bulkhead per-callback
-- isolation for the ID-injection dispatch). Run:
-- lua5.1 tests/unit/safecall_migration_t45e_test.lua

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
-- matching the t45a-d precedent's counting convention).
-- tooltip_provider.lua, death_alert.lua, spellscanner.lua: 0 conversions
-- this wave (mouse-focus/probe-read files, "mostly SKIP" per brief) —
-- still pinned so a future wave's edits show up as a diff here.
---------------------------------------------------------------------------
local FILES = {
    { path = "modules/qol/healer_mana.lua",          safeCall = 2,  bareCall = 4 },
    { path = "modules/qol/lusttimer.lua",             safeCall = 2,  bareCall = 2 },
    { path = "modules/qol/death_alert.lua",           safeCall = 0,  bareCall = 4 },
    { path = "modules/qol/qol.lua",                   safeCall = 5,  bareCall = 2 },
    { path = "modules/qol/focuscastalert.lua",        safeCall = 5,  bareCall = 0 },
    { path = "modules/qol/skyriding.lua",             safeCall = 2,  bareCall = 0 },
    { path = "modules/qol/rangecheck.lua",            safeCall = 1,  bareCall = 0 },
    { path = "modules/qol/blizzard_mover.lua",        safeCall = 1,  bareCall = 4 },
    { path = "modules/qol/tooltip_provider.lua",      safeCall = 0,  bareCall = 8 },
    { path = "modules/qol/tooltip_inspect.lua",       safeCall = 1,  bareCall = 4 },
    { path = "modules/qol/tooltip.lua",               safeCall = 33, bareCall = 48 },
    { path = "modules/trackers/preytracker.lua",      safeCall = 22, bareCall = 8 },
    { path = "modules/trackers/atonement_counter.lua", safeCall = 4, bareCall = 7 },
    -- round-22: +1 bare pcall — ForEachPlayerHelpfulAura's per-index
    -- GetAuraDataByIndex guard (iterator termination contract, deliberate
    -- secret-guard, not an error-swallow).
    { path = "modules/trackers/spellscanner.lua",     safeCall = 0,  bareCall = 7 },
    { path = "modules/combat/rotationassist.lua",     safeCall = 2,  bareCall = 9 },
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
-- healer_mana.lua: UnitPowerMax/UnitPower probe-reads (feed a secret
-- presence check) stay bare; SetMinMaxValues/SetValue sink-forwards
-- convert (results discarded, secrets ride raw into the StatusBar).
---------------------------------------------------------------------------
local healerMana = src("modules/qol/healer_mana.lua")
check('pin: healer_mana.lua SetMinMaxValues -> ns.SafeCall("sink-forward", ...)',
    healerMana:find('ns.SafeCallMethod("sink-forward", row.bar, "SetMinMaxValues", 0, maxPower)', 1, true) ~= nil)
check('pin: healer_mana.lua SetValue -> ns.SafeCall("sink-forward", ...)',
    healerMana:find('ns.SafeCallMethod("sink-forward", row.bar, "SetValue", curPower)', 1, true) ~= nil)
check("pin: healer_mana.lua UnitPowerMax/UnitPower probe-reads stay bare pcall",
    healerMana:find("local okMax, maxPower = pcall(UnitPowerMax, unit, 0)", 1, true) ~= nil
    and healerMana:find("local okCur, curPower = pcall(UnitPower, unit, 0)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- rotationassist.lua: GetOverrideSpell fallback -> chain-next (keeps the
-- base-spell fallback when the override lookup fails); SetSize discarded
-- guard -> best-effort-style. The Usability/range secret-boolean block
-- (IsSpellUsable/SpellHasRange/IsSpellInRange) and the two compat-chain
-- keybind probes stay bare (brief-explicit "probe-reads SKIP; compat
-- chains SKIP").
---------------------------------------------------------------------------
local rotationassist = src("modules/combat/rotationassist.lua")
check('pin: rotationassist.lua :443 GetOverrideSpell -> ns.SafeCall("chain-next", ...)',
    rotationassist:find('ns.SafeCall("chain-next", C_Spell.GetOverrideSpell, spellID)', 1, true) ~= nil)
check('pin: rotationassist.lua :482 SetSize -> ns.SafeCall("best-effort-style", ...)',
    rotationassist:find('ns.SafeCallMethod("best-effort-style", iconFrame, "SetSize", size, size)', 1, true) ~= nil)
check("pin: rotationassist.lua IsSpellUsable/SpellHasRange/IsSpellInRange secret-boolean block stays bare",
    rotationassist:find("local usableOk, isUsable, notEnoughMana = pcall(C_Spell.IsSpellUsable, spellID)", 1, true) ~= nil
    and rotationassist:find('local rangeOk, hasRange = pcall(C_Spell.SpellHasRange, spellID)', 1, true) ~= nil)
check("pin: rotationassist.lua GetKeybindForSpell compat-chain probes stay bare",
    rotationassist:find("return FindBaseSpellByID and FindBaseSpellByID(spellID)", 1, true) ~= nil
    and rotationassist:find("return C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(spellID)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- atonement_counter.lua: spell-name/texture 2-step lookup chains (modern
-- C_Spell API, then legacy global, then literal default) -> chain-next.
-- Every UNIT_AURA scan site (secret probe-reads, explicit IsSecretValue
-- guards) stays bare per THE SKIP RULE.
---------------------------------------------------------------------------
local atonement = src("modules/trackers/atonement_counter.lua")
check('pin: atonement_counter.lua C_Spell.GetSpellName -> ns.SafeCall("chain-next", ...)',
    atonement:find('ns.SafeCall("chain-next", C_Spell.GetSpellName, ATONEMENT_SPELL_ID)', 1, true) ~= nil)
check('pin: atonement_counter.lua GetSpellInfo fallback -> ns.SafeCall("chain-next", ...)',
    atonement:find('ns.SafeCall("chain-next", GetSpellInfo, ATONEMENT_SPELL_ID)', 1, true) ~= nil)
check('pin: atonement_counter.lua C_Spell.GetSpellTexture -> ns.SafeCall("chain-next", ...)',
    atonement:find('ns.SafeCall("chain-next", C_Spell.GetSpellTexture, ATONEMENT_SPELL_ID)', 1, true) ~= nil)
check('pin: atonement_counter.lua GetSpellTexture fallback -> ns.SafeCall("chain-next", ...)',
    atonement:find('ns.SafeCall("chain-next", GetSpellTexture, ATONEMENT_SPELL_ID)', 1, true) ~= nil)
check("pin: atonement_counter.lua UnitHasPlayerAtonement aura-scan chain stays bare (secret probe-reads)",
    atonement:find("local ok, auraData = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, ATONEMENT_SPELL_ID)", 1, true) ~= nil
    and atonement:find("local ok, helpfulAuras = pcall(C_UnitAuras.GetUnitAuras, unit, PLAYER_HELPFUL_FILTER)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- focuscastalert.lua: IsSpellKnownForPlayer's 4-way API fallback chain
-- (IsSpellKnownOrOverridesKnown -> C_SpellBook.IsSpellKnown -> IsPlayerSpell
-- -> IsSpellKnown) -> chain-next; the SetFormattedText sink with its
-- secret-placeholder fallback branch -> sink-forward.
---------------------------------------------------------------------------
local focuscastalert = src("modules/qol/focuscastalert.lua")
check('pin: focuscastalert.lua IsSpellKnownOrOverridesKnown -> ns.SafeCall("chain-next", ...)',
    focuscastalert:find('ns.SafeCall("chain-next", IsSpellKnownOrOverridesKnown, spellID)', 1, true) ~= nil)
check('pin: focuscastalert.lua C_SpellBook.IsSpellKnown -> ns.SafeCall("chain-next", ...)',
    focuscastalert:find('ns.SafeCall("chain-next", C_SpellBook.IsSpellKnown, spellID)', 1, true) ~= nil)
check('pin: focuscastalert.lua SetFormattedText -> ns.SafeCall("sink-forward", ...) with fallback branch kept',
    focuscastalert:find('local ok = ns.SafeCallMethod("sink-forward", state.text, "SetFormattedText", fmt, unpack(args))', 1, true) ~= nil
    and focuscastalert:find("Fallback: show without secret placeholders", 1, true) ~= nil)

---------------------------------------------------------------------------
-- preytracker.lua: widget-suppression Hide/Show/Stop/Play mutator guards
-- (discarded results) -> best-effort-style. GetParent/GetAllWidgetsBySetID
-- probe-reads (value feeds a decision) stay bare.
---------------------------------------------------------------------------
local preytracker = src("modules/trackers/preytracker.lua")
check('pin: preytracker.lua target.Hide -> ns.SafeCall("best-effort-style", ...)',
    preytracker:find('ns.SafeCallMethod("best-effort-style", target, "Hide")', 1, true) ~= nil)
check('pin: preytracker.lua target.Show -> ns.SafeCall("best-effort-style", ...)',
    preytracker:find('ns.SafeCallMethodIfPresent("best-effort-style", target, "Show")', 1, true) ~= nil)
check('pin: preytracker.lua group.Stop/group.Play -> ns.SafeCall("best-effort-style", ...)',
    preytracker:find('ns.SafeCallMethodIfPresent("best-effort-style", group, "Stop")', 1, true) ~= nil
    and preytracker:find('ns.SafeCallMethodIfPresent("best-effort-style", group, "Play")', 1, true) ~= nil)
check("pin: preytracker.lua ApplySuppressionToWidgetParent GetParent probe-read stays bare",
    preytracker:find("local okP, parent = pcall(frameRef.GetParent, frameRef)", 1, true) ~= nil)
check("pin: preytracker.lua local Safe* helper (line ~159) body untouched (THE SKIP RULE " ..
    "Safe*-helper class); renamed SafeCall -> LocalSafeCall post-followup to stop shadowing " ..
    "the global ns.SafeCall name (all in-file call sites re-pointed alongside it)",
    preytracker:find("local function LocalSafeCall(func, ...)", 1, true) ~= nil
    and preytracker:find("local ok, result = pcall(func, ...)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- tooltip.lua: hottest file, zero new closures anywhere (brief-explicit).
-- Diff-based check: no "+function(" line was added by this wave's edits
-- would require git; instead pin that every converted sink/mutator site
-- is a direct function-ref+args substitution (no "SafeCall(...  function"
-- immediately after the policy string at any converted sink site), plus
-- the four ID-injection dispatch sites -> bulkhead (per-callback isolation,
-- self-contained processing functions), and the tooltipdebug REPORTED
-- site (:401, /tooltipdebug auratip) stays bare untouched.
---------------------------------------------------------------------------
local tooltip = src("modules/qol/tooltip.lua")
check('pin: tooltip.lua TryAddSpellIDFromTooltipData -> ns.SafeCall("bulkhead", ...)',
    tooltip:find('ns.SafeCall("bulkhead", TryAddSpellIDFromTooltipData, tooltip, data)', 1, true) ~= nil)
check('pin: tooltip.lua TryAddAuraSpellIDFromTooltipData -> ns.SafeCall("bulkhead", ...)',
    tooltip:find('ns.SafeCall("bulkhead", TryAddAuraSpellIDFromTooltipData, tooltip, data)', 1, true) ~= nil)
check('pin: tooltip.lua TryAddItemIDFromTooltipData -> ns.SafeCall("bulkhead", ...)',
    tooltip:find('ns.SafeCall("bulkhead", TryAddItemIDFromTooltipData, tooltip, data)', 1, true) ~= nil)
check('pin: tooltip.lua TryAddItemMaxStackSizeFromTooltipData -> ns.SafeCall("bulkhead", ...)',
    tooltip:find('ns.SafeCall("bulkhead", TryAddItemMaxStackSizeFromTooltipData, tooltip, data)', 1, true) ~= nil)
check("pin: tooltip.lua exactly 4 ns.SafeCall(\"bulkhead\" occurrences (ID-injection dispatch isolation)",
    countOccurrences(tooltip, 'ns%.SafeCall%("bulkhead"') == 4)
check("pin: tooltip.lua :401 /tooltipdebug auratip REPORTED site stays bare (brief-explicit)",
    tooltip:find("local ok, status = pcall(statusFn)", 1, true) ~= nil)
check("pin: tooltip.lua zero new function( closures introduced by any SafeCall( conversion site",
    (function()
        for pos in tooltip:gmatch('()ns%.SafeCall%("[%w%-]+",%s*function') do
            return false, pos
        end
        return true
    end)())
check("pin: tooltip.lua ResolveTooltipUnit/ShouldKeepTooltipVisible/IsTooltipOwnerHovered watcher-stack probe-reads stay bare",
    tooltip:find("local ok, _, unit = pcall(tooltip.GetUnit, tooltip)", 1, true) ~= nil
    and tooltip:find("local ok, isOver = pcall(owner.IsMouseOver, owner)", 1, true) ~= nil
    and tooltip:find("local okShown, shown = pcall(owner.IsShown, owner)", 1, true) ~= nil)
check("pin: tooltip.lua GameTooltip.SetAlpha sink sites (ResetTooltipHideFade + hide-fade OnUpdate) -> sink-forward",
    tooltip:find('ns.SafeCallMethod("sink-forward", GameTooltip, "SetAlpha", 1)', 1, true) ~= nil
    and tooltip:find('ns.SafeCallMethod("sink-forward", GameTooltip, "SetAlpha", nextAlpha)', 1, true) ~= nil)
check("pin: tooltip.lua GetAlpha secret-defense-arithmetic probe-read (StartTooltipHideFade) stays bare",
    tooltip:find("local okAlpha, currentAlpha = pcall(GameTooltip.GetAlpha, GameTooltip)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- qol.lua: HasMythicPlusActiveSignal's 3-way alternative-signal chain
-- (C_MythicPlus.IsMythicPlusActive / C_ChallengeMode.GetActiveChallengeMapID
-- / C_ChallengeMode.IsChallengeModeActive) -> chain-next (brief-explicit).
---------------------------------------------------------------------------
local qol = src("modules/qol/qol.lua")
check('pin: qol.lua C_MythicPlus.IsMythicPlusActive -> ns.SafeCall("chain-next", ...)',
    qol:find('ns.SafeCall("chain-next", C_MythicPlus.IsMythicPlusActive)', 1, true) ~= nil)
check('pin: qol.lua C_ChallengeMode.GetActiveChallengeMapID -> ns.SafeCall("chain-next", ...)',
    qol:find('ns.SafeCall("chain-next", C_ChallengeMode.GetActiveChallengeMapID)', 1, true) ~= nil)
check('pin: qol.lua C_ChallengeMode.IsChallengeModeActive -> ns.SafeCall("chain-next", ...)',
    qol:find('ns.SafeCall("chain-next", C_ChallengeMode.IsChallengeModeActive)', 1, true) ~= nil)
check("pin: qol.lua ShouldHideLootToast GetItemInfo/GetDetailedItemLevelInfo probe-reads stay bare",
    qol:find("pcall(C_Item.GetItemInfo, itemLink)", 1, true) ~= nil
    and qol:find("local okIlvl, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, itemLink)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- tooltip_provider.lua / death_alert.lua / spellscanner.lua: 0 conversions
-- this wave. Every site is a probe-read whose result feeds a decision
-- (frame-hierarchy walk, secret-aware aura scan, or a boolean fold
-- structurally identical to an established SKIP precedent) — spot-pin a
-- representative site per file so a regression here is visible.
---------------------------------------------------------------------------
local tooltipProvider = src("modules/qol/tooltip_provider.lua")
check("pin: tooltip_provider.lua IsFrameBlockingMouse IsVisible probe-read stays bare (0 conversions this wave)",
    tooltipProvider:find("local ok, visible = pcall(focus.IsVisible, focus)", 1, true) ~= nil)

local deathAlert = src("modules/qol/death_alert.lua")
check("pin: death_alert.lua UnitIsDeadOrGhost probe-read stays bare (0 conversions this wave)",
    deathAlert:find("local okDead, dead = pcall(UnitIsDeadOrGhost, unit)", 1, true) ~= nil)

local spellscanner = src("modules/trackers/spellscanner.lua")
check("pin: spellscanner.lua GetRawAuraInstanceID secret probe-read stays bare (0 conversions this wave)",
    spellscanner:find("local ok, instID = pcall(function() return auraData.auraInstanceID end)", 1, true) ~= nil)

if fails > 0 then
    error(fails .. " failure(s) in safecall_migration_t45e_test", 0)
end
print("OK: safecall_migration_t45e_test (" .. #FILES .. " files pinned, all spot checks passed)")
