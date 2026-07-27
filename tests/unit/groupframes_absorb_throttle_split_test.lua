-- tests/unit/groupframes_absorb_throttle_split_test.lua
-- Run: lua tests/unit/groupframes_absorb_throttle_split_test.lua
--
-- UNIT_ABSORB_AMOUNT_CHANGED and UNIT_HEAL_ABSORB_AMOUNT_CHANGED are separate
-- visual overlays. Their throttles must not suppress each other for the same
-- unit inside the 100 ms coalesce window.

local loadDispatch = dofile("tests/helpers/load_groupframes_dispatch.lua")

local calls = {
    absorb = 0,
    healAbsorb = 0,
    healPrediction = 0,
}
local now = 100
local frame = {}

local ctx = {
    ns = {},
    QUI_GF = {
        initialized = true,
        unitFrameMap = {
            raid1 = { frame },
        },
    },
    _state = {
        cachedModuleEnabled = true,
        healthThrottle = {},
        healAbsorbThrottle = {},
    },
    _range = {
        cache = {},
        cacheTime = {},
    },
    powerThrottle = {},
    absorbThrottle = {},
    healPredThrottle = {},
    THROTTLE_INTERVAL = 0.1,
    -- The throttle section creates its trailing-flush frame at load time; this
    -- test only exercises the leading edge, so an inert stub is enough.
    CreateFrame = function()
        return {
            Show = function() end,
            Hide = function() end,
            SetScript = function() end,
        }
    end,
    GetTime = function() return now end,
    UnitExists = function() return true end,
    RebuildUnitFrameMap = function() error("unexpected map rebuild") end,
    UpdateHealth = function() error("unexpected health update") end,
    UpdatePower = function() error("unexpected power update") end,
    UpdateAbsorbs = function(seenFrame)
        assert(seenFrame == frame, "UpdateAbsorbs should receive mapped frame")
        calls.absorb = calls.absorb + 1
    end,
    UpdateHealAbsorb = function(seenFrame)
        assert(seenFrame == frame, "UpdateHealAbsorb should receive mapped frame")
        calls.healAbsorb = calls.healAbsorb + 1
    end,
    UpdateHealPrediction = function(seenFrame)
        assert(seenFrame == frame, "UpdateHealPrediction should receive mapped frame")
        calls.healPrediction = calls.healPrediction + 1
    end,
    type = type,
    pairs = pairs,
    wipe = function(t) for k in pairs(t) do t[k] = nil end end,
}

local OnEvent = loadDispatch(ctx)

OnEvent(nil, "UNIT_ABSORB_AMOUNT_CHANGED", "raid1")
OnEvent(nil, "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "raid1")
OnEvent(nil, "UNIT_ABSORB_AMOUNT_CHANGED", "raid1")

assert(calls.absorb == 1, "duplicate absorb event inside 100 ms should be throttled")
assert(calls.healAbsorb == 1,
    "heal-absorb event should not be suppressed by absorb event throttle")
assert(calls.healPrediction == 0, "heal prediction should not run for absorb events")

print("OK: groupframes_absorb_throttle_split_test")
