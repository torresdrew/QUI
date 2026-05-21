-- tests/unit/cdm_icon_update_scheduler_test.lua
-- Run: lua tests/unit/cdm_icon_update_scheduler_test.lua

local frames = {}

function CreateFrame()
    local frame = {
        scripts = {},
        SetScript = function(self, scriptName, handler)
            self.scripts[scriptName] = handler
        end,
    }
    frames[#frames + 1] = frame
    return frame
end

local now = 100
function GetTime() return now end

local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("modules/cdm/cdm_icon_renderer.lua", "cdm_icon_update_scheduler.lua")("QUI", ns)
local module = assert(ns.CDMIconUpdateScheduler, "icon update scheduler module should be exported")

local enabled = true
local inCombat = true
local inRaid = false
local trustCalls = {}
local updateAllCalls = 0
local updateCooldownCalls = 0
local barUpdates = 0

local controller = module.Create({
    isRuntimeEnabled = function() return enabled end,
    getTime = function() return now end,
    isInCombat = function() return inCombat end,
    isInRaid = function() return inRaid end,
    setTrustIsOnGCDForBatch = function(value)
        trustCalls[#trustCalls + 1] = value
    end,
    updateAllCooldowns = function()
        updateAllCalls = updateAllCalls + 1
    end,
    updateCooldownOnly = function()
        updateCooldownCalls = updateCooldownCalls + 1
    end,
    getBars = function()
        return {
            UpdateOwnedBars = function()
                barUpdates = barUpdates + 1
            end,
        }
    end,
})

assert(controller:GetDelay(true, "cooldown") == 0,
    "fast cooldown updates should run on the next frame")
assert(controller:GetDelay(true, "full") == 0.05,
    "fast full updates should be capped to the idle interval")
assert(controller:GetDelay(false, "cooldown") == 0.20,
    "non-raid combat updates should use the combat interval")
inRaid = true
assert(controller:GetDelay(false, "cooldown") == 0.30,
    "raid combat updates should use the raid interval")
inCombat = false
inRaid = false
assert(controller:GetDelay(false, "cooldown") == 0.05,
    "out-of-combat updates should use the idle interval")

inCombat = true
controller:SetBarsDirty(true)
controller:Schedule(false, "cooldown", false)
local frame = frames[#frames]
assert(frame.scripts.OnUpdate, "fallback scheduling should arm an OnUpdate frame")
frame.scripts.OnUpdate(frame, 0.10)
assert(updateCooldownCalls == 0, "slow combat update should wait for its delay")

controller:Schedule(true, "full", true)
assert(controller:GetStats().updatePending == true, "merged update should remain pending")
frame.scripts.OnUpdate(frame, 0)
assert(updateAllCalls == 1, "merged full update should run the full refresh callback")
assert(updateCooldownCalls == 0, "merged full update should not run cooldown-only callback")
assert(trustCalls[1] == true and trustCalls[2] == false,
    "merged trust flag should wrap the refresh batch")
assert(barUpdates == 1, "dirty bars should drain after the icon update")
assert(controller:IsBarsDirty() == false, "dirty bar flag should clear after draining")
assert(controller:GetStats().lastUpdateTime == now, "scheduler should stamp the last update time")

controller:Schedule(true, "cooldown", false)
frame.scripts.OnUpdate(frame, 0)
assert(updateCooldownCalls == 1, "fast cooldown update should run cooldown-only callback")

controller:Schedule(false, "cooldown", true)
enabled = false
controller:Schedule(true, "full", true)
assert(controller:GetStats().updatePending == false,
    "disabled runtime should cancel pending fallback updates")
assert(frame.scripts.OnUpdate == nil, "disabled runtime should clear fallback OnUpdate")
enabled = true

local schedulerConfig
local scheduleCalls = {}
local cancelCalls = 0
local externalPending = true
local externalAllCalls = 0
local externalTrustCalls = {}
local externalController = module.Create({
    isRuntimeEnabled = function() return true end,
    getScheduler = function()
        return {
            SetRuntimeUpdateHandler = function(config)
                schedulerConfig = config
            end,
            ScheduleRuntimeUpdate = function(fast, mode, trustIsOnGCD)
                scheduleCalls[#scheduleCalls + 1] = {
                    fast = fast,
                    mode = mode,
                    trustIsOnGCD = trustIsOnGCD,
                }
            end,
            CancelRuntimeUpdate = function()
                cancelCalls = cancelCalls + 1
                externalPending = false
            end,
            IsRuntimeUpdatePending = function()
                return externalPending
            end,
        }
    end,
    setTrustIsOnGCDForBatch = function(value)
        externalTrustCalls[#externalTrustCalls + 1] = value
    end,
    updateAllCooldowns = function()
        externalAllCalls = externalAllCalls + 1
    end,
})

assert(type(schedulerConfig) == "table",
    "controller should register a runtime handler with CDMScheduler")
externalController:Schedule(true, "full", true)
assert(scheduleCalls[1].fast == true and scheduleCalls[1].mode == "full",
    "controller should delegate scheduling to CDMScheduler when available")
assert(scheduleCalls[1].trustIsOnGCD == true,
    "controller should forward trust flag to CDMScheduler")
assert(externalController:GetStats().updatePending == true,
    "controller stats should read CDMScheduler pending state when available")

schedulerConfig.run("full", true)
assert(externalAllCalls == 1,
    "registered scheduler run callback should execute the full icon refresh")
assert(externalTrustCalls[1] == true and externalTrustCalls[2] == false,
    "registered scheduler run callback should wrap trust state")

externalController:Cancel()
assert(cancelCalls == 1, "controller cancel should cancel CDMScheduler state")
assert(externalController:GetStats().updatePending == false,
    "controller stats should report cancelled CDMScheduler state")

print("OK: cdm_icon_update_scheduler_test")
