--[[
    QUI Cast Engine (ns.CastEngine)

    Shared secret-safe cast timing primitives, extracted from
    QUI_UnitFrames/unitframes/castbar.lua so nameplates (and any future
    castbar surface) reuse the same battle-tested paths.

    Midnight (12.0) rules encoded here:
    * UnitCastingInfo/UnitChannelInfo timing values can be SECRET for
      non-player units in combat. Secrets pass type checks but fail
      arithmetic — detection uses IsSecretValue plus a pcall arithmetic
      probe.
    * When timing is secret, animation must be engine-driven:
      StatusBar:SetTimerDuration(durationObj, 0, direction) and the C side
      animates the fill; Lua never computes progress.
    * Remaining-time text reads DurationObject:GetRemainingDuration() under
      pcall and passes the (possibly secret) result straight into
      SetFormattedText("%.1f", …) — a C-side sink that accepts secrets.
      Never "%d": integer coercion on a secret silently no-ops the call.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local IsSecretValue = Helpers.IsSecretValue

local type = type
local pcall = pcall
local ipairs = ipairs

local CastEngine = {}
ns.CastEngine = CastEngine

-- Nil-returning secret-safe tonumber (deliberately NOT Helpers.SafeToNumber,
-- which returns fallback-or-0 — callers here branch on nil).
local function SafeToNumber(v)
    -- Probe FIRST — `v == nil` on a secret is itself a compare OF the secret
    -- and throws; IsSecretValue(nil) is simply false.
    if IsSecretValue(v) then
        return nil -- @secret-policy: reject-secret-value — callers branch on nil
    end
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local ok, n = pcall(tonumber, v)
    if ok and type(n) == "number" then return n end
    return nil
end

---------------------------------------------------------------------------
-- CAST INFO
---------------------------------------------------------------------------
-- Query UnitCastingInfo/UnitChannelInfo plus the Midnight DurationObject.
-- Returns: spellName, text, texture, startTimeMS, endTimeMS,
--          notInterruptible, unitSpellID, isChanneled, channelStages,
--          durationObj, hasSecretTiming
function CastEngine.GetCastInfo(unit)
    local spellName, text, texture, startTimeMS, endTimeMS, _, _, notInterruptible, unitSpellID = UnitCastingInfo(unit)
    local isChanneled = false
    local channelStages = 0
    local channelSpellID = nil

    -- 12.1: the cast NAME is secret-capable (SecretWhenUnitSpellCastRestricted).
    -- A secret name means a cast IS in progress with restricted identity — it
    -- must never degrade to "not casting". Probe FIRST; `not <secret>` throws.
    if IsSecretValue(spellName) then
        -- Secret casting name: a cast is live; skip the channel fallback.
    elseif not spellName then
        spellName, text, texture, startTimeMS, endTimeMS, _, notInterruptible, channelSpellID, _, channelStages = UnitChannelInfo(unit)
        if IsSecretValue(spellName) then
            isChanneled = true -- @secret-policy: opaque-value-present — a secret channel name means a channel is in progress
        elseif spellName then
            isChanneled = true
            if IsSecretValue(channelSpellID) or IsSecretValue(unitSpellID) then
                -- Unreadable ids: keep unitSpellID exactly as returned.
            elseif channelSpellID and not unitSpellID then
                unitSpellID = channelSpellID
            end
        end
    end
    -- casting is a PLAIN boolean; a secret name counts as casting.
    local casting = false
    if IsSecretValue(spellName) then
        casting = true -- @secret-policy: opaque-value-present — a secret cast name means a cast is in progress
    elseif spellName ~= nil then
        casting = true
    end

    -- Duration object for engine-driven animation (Midnight 12.0+); primary
    -- path for non-player units whose timing values may be secret.
    local durationObj = nil
    if casting then
        local getDurationFn = isChanneled and UnitChannelDuration or UnitCastingDuration
        if type(getDurationFn) == "function" then
            local ok, dur = pcall(getDurationFn, unit)
            if ok then durationObj = dur end
        end
    end

    -- Secret-timing detection: IsSecretValue probes lead (truth-testing a
    -- secret start/end throws), then a pcall arithmetic probe for secrets
    -- that slip the probe (they pass type checks but fail arithmetic).
    local hasSecretTiming = false
    if casting then
        if IsSecretValue(startTimeMS) or IsSecretValue(endTimeMS) then
            hasSecretTiming = true
        elseif startTimeMS and endTimeMS then
            local ok = pcall(function() return startTimeMS + 0 end) -- @secret-safe: deliberate arithmetic probe under pcall; both operands probed non-secret above
            if not ok then hasSecretTiming = true end
        end
    end

    -- Return everything — callers check hasSecretTiming and fall back to
    -- durationObj-driven animation instead of throwing usable info away.
    return spellName, text, texture, startTimeMS, endTimeMS, notInterruptible, unitSpellID, isChanneled, channelStages, durationObj, hasSecretTiming
end

---------------------------------------------------------------------------
-- DURATION OBJECT HELPERS
---------------------------------------------------------------------------
-- Best-effort plain-number total duration from a DurationObject. Returns nil
-- when every getter is missing, errors, or yields a secret.
function CastEngine.GetDurationSeconds(durationObj)
    if not durationObj then return nil end

    local getters = {
        "GetTotalDuration",
        "GetDuration",
        "GetMaxDuration",
        "GetRemainingDuration",
        "GetRemaining",
    }

    for _, methodName in ipairs(getters) do
        local getter = durationObj[methodName]
        if getter then
            local ok, value = pcall(getter, durationObj)
            if ok then
                value = SafeToNumber(value)
                if value and value > 0 then
                    return value
                end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- TIMING MODE RESOLUTION (non-player units)
---------------------------------------------------------------------------
-- The decision ladder for non-player casts: prefer engine-driven animation
-- when timing is secret, fall back to plain start/end times, and finally try
-- engine-driven when timing is simply unavailable.
-- Returns: canShowCast, useTimerDriven, startTime, endTime (seconds)
function CastEngine.ResolveNonPlayerTiming(spellName, startTimeMS, endTimeMS, durationObj, statusBar, hasSecretTiming)
    if not spellName then
        return false, false, nil, nil
    end

    local supportsTimerDriven = durationObj and statusBar and statusBar.SetTimerDuration

    if hasSecretTiming and supportsTimerDriven then
        return true, true, nil, nil
    end

    if startTimeMS and endTimeMS then
        local success, startTime, endTime = pcall(function()
            return startTimeMS / 1000, endTimeMS / 1000
        end)
        if success then
            return true, false, startTime, endTime
        end
    end

    if supportsTimerDriven then
        -- Timing not explicitly secret but also not accessible — engine-driven.
        return true, true, nil, nil
    end

    return false, false, nil, nil
end

---------------------------------------------------------------------------
-- ENGINE-DRIVEN ANIMATION
---------------------------------------------------------------------------
-- Hand the bar to the C-side animator. direction: 0 = fill (casts and
-- empowered), 1 = drain (channels). Returns true when the engine accepted
-- the duration object.
function CastEngine.ApplyTimerDriven(statusBar, durationObj, direction)
    if not (statusBar and statusBar.SetTimerDuration and durationObj) then
        return false
    end
    local ok = ns.SafeCallMethod("sink-forward", statusBar, "SetTimerDuration", durationObj, 0, direction or 0)
    if not ok then
        -- Fallback: older signature without the direction parameter
        ok = ns.SafeCallMethod("sink-forward", statusBar, "SetTimerDuration", durationObj)
    end
    return ok
end

---------------------------------------------------------------------------
-- TIMER-DRIVEN TIME TEXT
---------------------------------------------------------------------------
-- Remaining-duration text for engine-animated bars. `bar` carries .timeText
-- (FontString) and .durationObj; the getter method lookup is memoized on the
-- bar because OnUpdate runs ~60 Hz against the same DurationObject and the
-- `or` chain is wasted metatable work per frame. The remaining value may be
-- secret — it flows straight into SetFormattedText("%.1f", …).
function CastEngine.UpdateTimerText(bar)
    if bar.timeText and bar.durationObj then
        local obj = bar.durationObj
        if bar._durationGetterObj ~= obj then
            bar._durationGetter = obj.GetRemainingDuration or obj.GetRemaining
            bar._durationGetterObj = obj
        end
        local getter = bar._durationGetter
        if getter then
            local ok, rem = pcall(getter, obj)
            if ok and rem ~= nil then
                bar.timeText:SetFormattedText("%.1f", rem)
            end
        end
    end
end
