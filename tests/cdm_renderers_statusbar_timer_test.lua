-- tests/cdm_renderers_statusbar_timer_test.lua
-- Run: lua tests/cdm_renderers_statusbar_timer_test.lua

local ns = {}

assert(loadfile("modules/cdm/cdm_renderers.lua"))("QUI", ns)

local renderers = assert(ns.CDMRenderers, "CDMRenderers table was not exported")

local durObj = { token = "duration-object" }
local minMaxCalls = 0
local timerSelf
local timerDurObj
local timerInterpolation
local timerDirection

local statusBar = {
    SetMinMaxValues = function()
        minMaxCalls = minMaxCalls + 1
    end,
    SetTimerDuration = function(self, duration, interpolation, direction)
        timerSelf = self
        timerDurObj = duration
        timerInterpolation = interpolation
        timerDirection = direction
    end,
}

local ok = renderers.SetStatusBarTimerDuration(statusBar, durObj)

assert(ok == true,
    "duration-object status-bar timer binding should report success")
assert(timerSelf == statusBar,
    "status-bar timer binding should call SetTimerDuration as a method")
assert(timerDurObj == durObj,
    "status-bar timer binding should forward the DurationObject")
assert(timerInterpolation == 0,
    "status-bar timer binding should use Immediate interpolation")
assert(timerDirection == 1,
    "status-bar timer binding should use RemainingTime direction so aura bars drain")
assert(minMaxCalls == 0,
    "status-bar timer binding should not force a 0..1 range before SetTimerDuration")

print("OK: cdm_renderers_statusbar_timer_test")
