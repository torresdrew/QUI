-- tests/unit/groupframes_throttle_trailing_flush_test.lua
-- Run: lua tests/unit/groupframes_throttle_trailing_flush_test.lua
--
-- The per-unit 100ms coalesce windows are leading-edge: the first event in a
-- window is applied, the rest return early. Left at that, the LAST event of a
-- burst is dropped forever — a player healed to full inside a window keeps the
-- stale bar until their health happens to change again, which out of combat can
-- be never. Every suppressed event must be replayed once its window closes.

local loadDispatch = dofile("tests/helpers/load_groupframes_dispatch.lua")

local now = 100
local frame = {}
local calls = { health = 0, power = 0, absorb = 0, healAbsorb = 0, healPrediction = 0 }

-- Captures the flush frame's OnUpdate so the test can step render frames.
local flushFrame
local function CreateFrame()
    local f = { shown = false, script = nil }
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetScript(_, fn) self.script = fn end
    flushFrame = f
    return f
end

local function counter(key)
    return function(seenFrame)
        assert(seenFrame == frame, key .. " should receive the mapped frame")
        calls[key] = calls[key] + 1
    end
end

local ctx = {
    ns = {},
    QUI_GF = {
        initialized = true,
        unitFrameMap = { raid1 = { frame } },
    },
    _state = {
        cachedModuleEnabled = true,
        healthThrottle = {},
        healAbsorbThrottle = {},
    },
    _range = { cache = {}, cacheTime = {} },
    powerThrottle = {},
    absorbThrottle = {},
    healPredThrottle = {},
    THROTTLE_INTERVAL = 0.1,
    CreateFrame = CreateFrame,
    GetTime = function() return now end,
    UnitExists = function() return true end,
    RebuildUnitFrameMap = function() error("unexpected map rebuild") end,
    UpdateHealth = counter("health"),
    UpdatePower = counter("power"),
    UpdateAbsorbs = counter("absorb"),
    UpdateHealAbsorb = counter("healAbsorb"),
    UpdateHealPrediction = counter("healPrediction"),
    type = type,
    pairs = pairs,
    wipe = function(t) for k in pairs(t) do t[k] = nil end end,
}

local OnEvent = loadDispatch(ctx)
assert(flushFrame, "throttle section should create a flush frame")
assert(flushFrame.script, "flush frame should have an OnUpdate script")

local function render()
    flushFrame.script(flushFrame)
end

---------------------------------------------------------------------------
-- An unsuppressed event applies immediately and arms nothing.
---------------------------------------------------------------------------
OnEvent(nil, "UNIT_HEALTH", "raid1")
assert(calls.health == 1, "first health event should apply immediately")
assert(not flushFrame.shown, "an applied event should not queue a flush")

---------------------------------------------------------------------------
-- A suppressed event is still suppressed now, but is not lost.
---------------------------------------------------------------------------
OnEvent(nil, "UNIT_HEALTH", "raid1")
assert(calls.health == 1, "duplicate health event inside 100ms should be throttled")
assert(flushFrame.shown, "a suppressed event should queue the trailing flush")

-- Still inside the window: the flush must wait, not fire early or give up.
render()
assert(calls.health == 1, "flush should not apply before the window closes")
assert(flushFrame.shown, "flush should stay armed while the window is open")

-- Window closes: the dropped sample is replayed.
now = 100.2
render()
assert(calls.health == 2, "suppressed health event should be replayed after the window")
assert(not flushFrame.shown, "flush frame should stop itself once the queue drains")

---------------------------------------------------------------------------
-- The replay re-arms the window, so it cannot hot-loop once per render frame.
---------------------------------------------------------------------------
OnEvent(nil, "UNIT_HEALTH", "raid1")
assert(calls.health == 2, "event inside the replayed window should be throttled")
now = 100.25
render()
assert(calls.health == 2, "replay should have re-armed the throttle window")

---------------------------------------------------------------------------
-- Channels stay independent through the queue: a pending health flush must not
-- drag along (or be starved by) the absorb overlays, which are separate bars.
---------------------------------------------------------------------------
now = 200
OnEvent(nil, "UNIT_ABSORB_AMOUNT_CHANGED", "raid1")
OnEvent(nil, "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "raid1")
OnEvent(nil, "UNIT_HEAL_PREDICTION", "raid1")
OnEvent(nil, "UNIT_POWER_UPDATE", "raid1")
assert(calls.absorb == 1 and calls.healAbsorb == 1
    and calls.healPrediction == 1 and calls.power == 1,
    "each channel's first event should apply — they must not suppress each other")

OnEvent(nil, "UNIT_ABSORB_AMOUNT_CHANGED", "raid1")
assert(calls.absorb == 1, "duplicate absorb inside the window should be throttled")
now = 200.2
render()
assert(calls.absorb == 2, "suppressed absorb should be replayed")
assert(calls.healAbsorb == 1 and calls.healPrediction == 1 and calls.power == 1,
    "channels with nothing pending should not be replayed")

---------------------------------------------------------------------------
-- Roster churn drops the queue: the unit token may now be a different player,
-- and the rebuild refreshes every frame anyway.
---------------------------------------------------------------------------
now = 300
OnEvent(nil, "UNIT_HEALTH", "raid1")
OnEvent(nil, "UNIT_HEALTH", "raid1")
local healthBeforeReset = calls.health
ctx._state.ResetThrottles()
now = 300.2
render()
assert(calls.health == healthBeforeReset, "reset should discard queued flushes")

---------------------------------------------------------------------------
-- A pending unit that left the group is dropped, not replayed against a stale
-- frame list — and the queue must not leak the entry either.
---------------------------------------------------------------------------
now = 400
OnEvent(nil, "UNIT_HEALTH", "raid1")
OnEvent(nil, "UNIT_HEALTH", "raid1")
local pending = ctx._state.throttleChannels.health.pending
assert(pending.raid1, "suppressed event should be queued under its unit")
ctx.QUI_GF.unitFrameMap.raid1 = nil
now = 400.2
render()
assert(not pending.raid1, "flush should drop queued units that left the group")
assert(not flushFrame.shown, "flush frame should stop after draining")

print("OK: groupframes_throttle_trailing_flush_test")
