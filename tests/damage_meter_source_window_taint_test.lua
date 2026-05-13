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

print("OK: damage_meter_source_window_taint_test")
