-- tests/unit/damage_meter_current_duration_test.lua
-- Run: lua tests/unit/damage_meter_current_duration_test.lua
--
-- Standalone tests for ResolveCurrentViewDuration — the pure helper that
-- tracks the Current session's duration for the header timer and breakdown
-- aggregates.
--
-- The regressions it guards: the server rolls the Current session at
-- segment boundaries, so BOTH prior divisor strategies failed in game —
-- the regen-to-regen combat clock missed sessions it didn't cover, and a
-- post-combat GetSessionDurationSeconds read picked up the freshly rolled
-- (tiny) session, inflating displayed rates toward total-damage magnitude.
-- The pin model: live API reads in combat keep the pin warm; out of combat
-- the warm pin is served untouched (no combat-end API read exists to race
-- the roll); the pin resets at combat start. Row amountPerSecond is no
-- longer derived at all — the API's own total/rate pair is rendered as-is,
-- matching the stock meter.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a"); file:close()
    return data:gsub("\r\n", "\n")
end

local src = readAll("QUI_DamageMeter/damage_meter/damage_meter.lua")

local function extract(fnName)
    local start_pos = src:find("local function " .. fnName)
    assert(start_pos, "could not locate " .. fnName .. " block in damage_meter.lua")
    local end_pos = src:find("QUI_DamageMeter%." .. fnName, start_pos)
    assert(end_pos, "could not locate QUI_DamageMeter." .. fnName .. " assignment")
    local chunk = src:sub(start_pos, end_pos - 1):match("^(.-)\n%s*$")
    assert(chunk, "failed to extract " .. fnName .. " chunk")
    local loader = assert(loadstring(chunk .. "\nreturn " .. fnName))
    return loader()
end

local ResolveCurrentViewDuration = extract("ResolveCurrentViewDuration")

-- A stand-in secret value our fake isSecret recognises.
local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
local function isSecret(x) return x == SECRET end

-- Signature: ResolveCurrentViewDuration(inCombat, apiDuration, pinnedDuration,
--                                        combatElapsed, isSecret) -> duration, newPin

-- Case 1: in combat, live API duration wins and warms the pin.
do
    local d, pin = ResolveCurrentViewDuration(true, 42, 10, 58, isSecret)
    assert(d == 42 and pin == 42, "in combat: live API duration wins and warms the pin")
end

-- Case 2: in combat, API nil -> warm pin serves (session data retained).
do
    local d, pin = ResolveCurrentViewDuration(true, nil, 37, 58, isSecret)
    assert(d == 37 and pin == 37, "in combat with nil API duration serves the warm pin")
end

-- Case 3: in combat, no API, no pin -> legacy combat clock, pin untouched.
do
    local d, pin = ResolveCurrentViewDuration(true, nil, 0, 58, isSecret)
    assert(d == 58 and pin == 0, "in combat last resort is the combat clock; pin stays")
end

-- Case 4 (THE REGRESSION): out of combat, pin set -> pin wins over the live
-- API value, which may belong to a freshly rolled (tiny) session.
do
    local d, pin = ResolveCurrentViewDuration(false, 3, 240, 58, isSecret)
    assert(d == 240 and pin == 240, "idle: pinned duration wins over the rolled API value")
end

-- Case 5: out of combat, no pin (fresh login / reload) -> API fallback.
do
    local d, pin = ResolveCurrentViewDuration(false, 300, 0, 0, isSecret)
    assert(d == 300 and pin == 0, "idle without a pin falls back to the API duration")
end

-- Case 6: out of combat, no pin, API nil -> legacy combat clock.
do
    local d, pin = ResolveCurrentViewDuration(false, nil, 0, 58, isSecret)
    assert(d == 58 and pin == 0, "idle without pin or API falls back to the combat clock")
end

-- Case 7: nothing usable -> nil duration, pin passthrough.
do
    local d, pin = ResolveCurrentViewDuration(false, nil, 0, 0, isSecret)
    assert(d == nil and pin == 0, "no usable duration -> nil")
end

-- Case 8: secret values are never usable in either state.
do
    local d = ResolveCurrentViewDuration(true, SECRET, 37, 58, isSecret)
    assert(d == 37, "in combat: secret API duration is unusable -> pin")
    local d2 = ResolveCurrentViewDuration(false, SECRET, 0, 58, isSecret)
    assert(d2 == 58, "idle: secret API duration is unusable -> combat clock")
end

print("OK: damage_meter_current_duration_test")
