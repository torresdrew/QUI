---------------------------------------------------------------------------
-- QUI SafeCall — classified pcall guard.
-- Classify + count + report ONLY: policy actions (parking, queueing,
-- fallthrough) stay at call sites. Policies exist so failure counters
-- attribute to a named intent.
---------------------------------------------------------------------------
local _, ns = ...

local pcall = pcall
local tostring = tostring
local strfind = string.find
local print = print
-- C global, never replaced at runtime: load-time capture is safe.
local issecretvalue = issecretvalue or function() return false end
-- geterrorhandler is deliberately NOT captured at load: error grabbers
-- replace the handler at runtime, so resolve the current one per failure.

local POLICIES = {
    ["park-fail-closed"] = true,
    ["defer-ooc"] = true,
    ["defer-lift"] = true,
    ["chain-next"] = true,
    ["sink-forward"] = true,
    ["best-effort-style"] = true,
    ["bulkhead"] = true,
    ["compat"] = true,
    ["report"] = true, -- no expected classes; everything loud
}

-- Expected error classes (plain find, case-sensitive).
local EXPECTED = {
    "secret value",
    "Cannot use SecureHandlers API on forbidden frames",
    "Cannot use SecureHandlers API during combat",
    "forbidden object",
    "locked-down object", -- 12.1: "Attempt to access fully locked-down object"
    "attempted to store a secret",
    "combat lockdown",
    "ADDON_ACTION_BLOCKED",
}

local stats = { badpolicy = 0, seenOverflow = 0 }
local seen = {}
local seenCount = 0
local SEEN_CAP = 200
local observer

local function bump(policy, field)
    local t = stats[policy]
    if not t then
        t = { expected = 0, unexpected = 0, secretErr = 0 }
        stats[policy] = t
    end
    t[field] = t[field] + 1
end

local function currentHandler()
    local get = geterrorhandler
    local handler = get and get()
    return handler or print
end

-- Handler dispatch is PROTECTED: geterrorhandler resolves an INSTALLED
-- handler (error grabbers replace it at runtime), and a throwing handler
-- would otherwise escape SafeCall through the failure path itself — for
-- ordinary and secret errors alike. Resolution is pcall'd too (a secret
-- handler value throws on currentHandler's `or print` truth-test). A
-- handler failure is swallowed (containment outranks reporting, and there
-- is no safe reporter left to tell) but DELIVERY status is returned so the
-- dedup path can decline to mark an err it never managed to report.
local dispatching = false
local function reportToHandler(err)
    -- Active-dispatch sentinel: a handler whose own work fails back through
    -- SafeCall with a UNIQUE err each time defeats the string-keyed dedup
    -- (it only stops IDENTICAL re-raises) and would recurse handler-inside-
    -- handler until C-stack exhaustion. One dispatch may be live at a time;
    -- a nested report declines as NON-DELIVERY, so the caller rolls back
    -- its dedup mark and the err retries on its next independent occurrence.
    -- The latch is set BEFORE handler resolution: geterrorhandler is
    -- grabber-replaceable, so resolution itself can fail back through
    -- SafeCall and is the same reentry surface as the handler body.
    if dispatching then return false end
    dispatching = true
    local okH, handler = pcall(currentHandler)
    if not okH then
        dispatching = false
        return false
    end
    local delivered = (pcall(handler, err))
    dispatching = false
    return delivered
end

-- Observer dispatch is latched like the handler: the observer runs BEFORE
-- dedup, so one whose own work fails back through SafeCall with a UNIQUE
-- err each time would recurse observer-inside-observer until C-stack
-- exhaustion (dedup only stops IDENTICAL errs). One observer dispatch may
-- be live at a time; nested failures still count and report to the handler
-- — only their observer NOTIFICATION is dropped (containment outranks
-- reporting, and the observer is diagnostic-only).
local observing = false
local function notifyObserver(policy, err, wasExpected)
    if not observer or observing then return end
    observing = true
    pcall(observer, policy, err, wasExpected)
    observing = false
end

local function onFailure(policy, err)
    if not POLICIES[policy] then
        -- Unknown policy (call-site typo) must never crash a render path:
        -- count it and route as report (unexpected-only).
        stats.badpolicy = stats.badpolicy + 1
        policy = "report"
    end
    -- Probe FIRST: error messages can BE secret (Blizzard_ScriptErrorsFrame.lua:95-105).
    -- NEVER index a table with err, NEVER err:find, NEVER format it before this check.
    if issecretvalue(err) then
        bump(policy, "secretErr")
        reportToHandler(err) -- Blizzard's display handles secret messages; dedup skipped
        return
    end
    -- tostring is PROTECTED: a non-secret error OBJECT can carry a hostile
    -- __tostring that throws (the failure path itself would then escape the
    -- bulkhead) or that returns a secret string — re-probe before find/index.
    local okStr, str = pcall(tostring, err)
    if okStr and issecretvalue(str) then
        bump(policy, "secretErr")
        reportToHandler(str)
        return
    end
    if not okStr or type(str) ~= "string" then
        str = "SafeCall(" .. policy .. "): unprintable error object"
    end
    err = str
    if policy ~= "report" then
        for i = 1, #EXPECTED do
            if strfind(err, EXPECTED[i], 1, true) then
                bump(policy, "expected")
                notifyObserver(policy, err, true)
                return
            end
        end
    end
    bump(policy, "unexpected")
    notifyObserver(policy, err, false)
    local n = seen[err]
    if n then
        seen[err] = n + 1 -- already reported once; dedup
    elseif seenCount < SEEN_CAP then
        -- Marked BEFORE dispatch so a handler that re-raises this same err
        -- through SafeCall dedups instead of recursing — but a TRANSIENT
        -- handler failure must not permanently silence the err, so the mark
        -- is rolled back on non-delivery and the next occurrence retries.
        seen[err] = 1
        seenCount = seenCount + 1
        if not reportToHandler(err) then
            seen[err] = nil
            seenCount = seenCount - 1
        end
    else
        stats.seenOverflow = stats.seenOverflow + 1
        reportToHandler(err) -- untracked beyond cap: report unconditionally
    end
end

local function finish(policy, ok, ...)
    if ok then
        return true, ...
    end
    onFailure(policy, ...)
    return false
end

-- Single load-time trampoline: the method index happens INSIDE pcall because
-- obj[methodName] on a forbidden frame — or a secret-tainted obj — can throw.
local function invoke(obj, name, ...)
    return obj[name](obj, ...)
end

-- IfPresent probe: a call-site guard like `if obj.Method then` performs the
-- SAME throwing lookup the trampoline exists to protect, one line before it —
-- so the existence probe must live INSIDE a pcall too. Probe order: a secret
-- obj (or member) throws on `== nil`, so issecretvalue runs first; secret
-- means the Lua-only decision is rejected and the call skipped (fail-closed
-- skip, never a truth manufactured from secrecy). SKIP is a private sentinel
-- so a skip is never conflated with a successful call.
local SKIP = {}
local function probeMethod(obj, name)
    if issecretvalue(obj) or obj == nil then return SKIP end
    local m = obj[name]
    if issecretvalue(m) or m == nil then return SKIP end
    return m
end

function ns.SafeCall(policy, fn, ...)
    return finish(policy, pcall(fn, ...))
end

function ns.SafeCallMethod(policy, obj, methodName, ...)
    return finish(policy, pcall(invoke, obj, methodName, ...))
end

-- Guarded variant: replaces the `if obj and obj.Method then SafeCallMethod`
-- pair with the existence lookup itself protected. THREE-STATE return so a
-- skip is never reported as a successful call:
--   nil        — skipped (nil/secret obj, absent/secret method); falsy, so
--                every old guard-false code path behaves as before
--   false      — the lookup or the call threw (classified via the policy)
--   true, ...  — the method was actually called
function ns.SafeCallMethodIfPresent(policy, obj, methodName, ...)
    local okProbe, m = pcall(probeMethod, obj, methodName)
    if not okProbe then
        onFailure(policy, m)
        return false
    end
    if m == SKIP then return nil end
    return finish(policy, pcall(m, obj, ...))
end

-- Live counters reference; treat as read-only.
function ns.SafeCallStats()
    return stats
end

-- Single optional observer, fn(policy, errString, wasExpected); non-secret
-- errs only. nil clears.
function ns.SafeCallSetObserver(fn)
    observer = fn
end
