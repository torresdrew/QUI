-- tests/damage_meter_source_window_taint_test.lua
-- Run: lua tests/damage_meter_source_window_taint_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function assertContains(text, needle, reason)
    assert(text:find(needle, 1, true), reason)
end

local function assertAbsent(text, needle, reason)
    assert(not text:find(needle, 1, true), reason)
end

local source = readFile("modules/skinning/gameplay/damage_meter.lua")

assertContains(
    source,
    "local sourceWindowFocus = Helpers.CreateStateTable()",
    "Damage meter source-window focus state must live outside Blizzard frames")

assertAbsent(
    source,
    "_qui_focusedSource",
    "Source-window focus must not be cached on Blizzard frame keys")

assertContains(
    source,
    'hooksecurefunc(target, "SetSource"',
    "SetSource must synchronously capture non-secret source identity")

assertContains(
    source,
    'hooksecurefunc(target, "ClearSource"',
    "ClearSource must clear side-table source identity")

assertAbsent(
    source,
    "C_DamageMeter.GetCombatSessionSourceFromType",
    "Addon code must not call combat-session-source APIs with secret source IDs")

assertAbsent(
    source,
    "C_DamageMeter.GetCombatSessionSourceFromID",
    "Addon code must not call combat-session-source APIs with secret source IDs")

assertAbsent(
    source,
    "SecureCallFunctionResult",
    "securecallfunction must not be used to wrap combat-session-source APIs")

assertAbsent(
    source,
    "GetCombatSessionSource =",
    "Source-window GetCombatSessionSource must not be replaced by addon code")

assertContains(
    source,
    "local function CanOpenSourceWindow(source)",
    "Source-window opening must be guarded before Blizzard refreshes the popup")

assertContains(
    source,
    "if not CanOpenSourceWindow(source) then",
    "ShowSourceWindow must bail before secret source IDs reach Blizzard's popup refresh")

assertContains(
    source,
    "if InCombatLockdown() and sourceWindow and sourceWindow:IsShown() then",
    "Open source windows must be closed before combat refreshes can hit restricted detail APIs")

assertContains(
    source,
    "local function SecretSafeBuildDataProvider(self, combatSession)",
    "Session windows must avoid Blizzard's secret totalAmount comparison")

assertContains(
    source,
    "target.BuildDataProvider = SecretSafeBuildDataProvider",
    "Session-window instances must receive the secret-safe BuildDataProvider override")

local secretSafeBody = source:match("local function SecretSafeIsShowingSource%b()%s*(.-)%s*end%s*%-%-%-%-%-%-%-%-%-%-%-")
assert(secretSafeBody, "SecretSafeIsShowingSource body should be present")
assertAbsent(
    secretSafeBody,
    "sourceGUID",
    "SecretSafeIsShowingSource must not read or compare secret GUID fields")
assertAbsent(
    secretSafeBody,
    "sourceCreatureID",
    "SecretSafeIsShowingSource must not read or compare possibly secret creature IDs")

local buildDataProviderBody = source:match("local function SecretSafeBuildDataProvider%b()%s*(.-)%s*end%s*local function SecretSafeSetSessionDuration")
assert(buildDataProviderBody, "SecretSafeBuildDataProvider body should be present")
assertAbsent(
    buildDataProviderBody,
    "combatSource.totalAmount",
    "SecretSafeBuildDataProvider must not read secret totalAmount fields")
assertAbsent(
    buildDataProviderBody,
    "GetTotalAmount",
    "SecretSafeBuildDataProvider must not compare against source-window totalAmount")

print("OK: damage_meter_source_window_taint_test")
