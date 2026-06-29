-- tests/unit/cdm_reanchor_hooks_test.lua
-- Run: lua tests/unit/cdm_reanchor_hooks_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_hooks.lua", "cdm_reanchor_hooks.lua")("QUI", ns)
local H = assert(ns.CDMReanchorHooks, "CDMReanchorHooks should be exported")
assert(type(H.New) == "function", "New is a function")

-- scheduler that records the callback so the test drives the flush
local pending
local refreshed = {}
local hooks = H.New({
    refresh = function(key) refreshed[#refreshed+1] = key end,
    keys = { "essential", "utility" },
    schedule = function(fn) pending = fn end,
})

-- MarkDirty coalesces: many marks -> one scheduled flush
hooks:MarkDirty("essential")
hooks:MarkDirty("essential")
hooks:MarkDirty("utility")
assert(#refreshed == 0, "nothing refreshes until the scheduled flush fires")
assert(type(pending) == "function", "a flush was scheduled once")

pending()  -- fire the scheduled flush
assert(#refreshed == 2, "each dirty container refreshed once")
local seen = {}
for _, k in ipairs(refreshed) do seen[k] = (seen[k] or 0) + 1 end
assert(seen.essential == 1 and seen.utility == 1, "essential + utility each refreshed once")

-- after flush, a new mark schedules again
pending = nil
hooks:MarkDirty("essential")
assert(type(pending) == "function", "re-arms scheduling after a flush")

-- MarkAllDirty marks every managed key
refreshed = {}
hooks:MarkAllDirty()
pending()
assert(#refreshed == 2, "MarkAllDirty requeues every managed container")

-- InstallViewerHooks: hooks Blizzard relayout/acquire/viewer visibility plus
-- per-frame CDM state changes. Re-running after nil viewers is the retry path
-- used when Blizzard_CooldownViewer loads after QUI.
local hookInstalls = {}
local function fakeHook(owner, method, fn) hookInstalls[#hookInstalls+1] = { owner = owner, method = method, fn = fn } end
local scripts = {}
local function makeFrame()
    return {
        OnActiveStateChanged = function() end,
        OnCooldownIDSet = function() end,
    }
end
local existingFrame, acquiredFrame = makeFrame(), makeFrame()
local pool = {
    Acquire = function() end,
    EnumerateActive = function()
        local yielded = false
        return function()
            if yielded then return nil end
            yielded = true
            return existingFrame
        end
    end,
}
local viewers = {
    essential = {
        RefreshLayout = function() end,
        OnAcquireItemFrame = function() end,
        itemFramePool = pool,
        HookScript = function(self, scriptName, fn) scripts[scriptName] = fn end,
    },
    utility = { RefreshLayout = function() end },
}
local h2refresh = {}
local h2 = H.New({
    refresh = function(k) h2refresh[#h2refresh+1] = k end,
    keys = { "essential", "utility" },
    hooksecurefunc = fakeHook,
    schedule = function(fn) fn() end,  -- immediate flush
})
h2:InstallViewerHooks(function() return nil end)
assert(#hookInstalls == 0, "nil viewers do not permanently block later hook install")
h2:InstallViewerHooks(function(k) return viewers[k] end)
assert(#hookInstalls >= 6, "viewer acquire/refresh and frame state hooks installed")
assert(hookInstalls[1].method == "RefreshLayout", "hooks RefreshLayout")
-- idempotent: re-install does not double-hook
local installedCount = #hookInstalls
h2:InstallViewerHooks(function(k) return viewers[k] end)
assert(#hookInstalls == installedCount, "InstallViewerHooks is idempotent per viewer/frame")
-- firing a hooked RefreshLayout drives one refresh (immediate scheduler here)
hookInstalls[1].fn()
assert(#h2refresh == 1, "firing the RefreshLayout hook drives one re-claim")

local acquireHook, activeHook, idHook
for _, h in ipairs(hookInstalls) do
    if h.owner == viewers.essential and h.method == "OnAcquireItemFrame" then acquireHook = h.fn end
    if h.owner == existingFrame and h.method == "OnActiveStateChanged" then activeHook = h.fn end
    if h.owner == existingFrame and h.method == "OnCooldownIDSet" then idHook = h.fn end
end
assert(type(acquireHook) == "function", "hooks viewer OnAcquireItemFrame")
assert(type(activeHook) == "function", "hooks existing frame OnActiveStateChanged")
assert(type(idHook) == "function", "hooks existing frame OnCooldownIDSet")
assert(type(scripts.OnShow) == "function" and type(scripts.OnHide) == "function", "hooks viewer show/hide")

local before = #h2refresh
acquireHook(viewers.essential, acquiredFrame)
assert(#h2refresh == before + 1, "acquired frame queues a re-claim")
local acquiredIDHook
for _, h in ipairs(hookInstalls) do
    if h.owner == acquiredFrame and h.method == "OnCooldownIDSet" then acquiredIDHook = h.fn end
end
assert(type(acquiredIDHook) == "function", "acquired frame gets cooldown-id hook")

before = #h2refresh
activeHook(existingFrame)
idHook(existingFrame)
scripts.OnShow(viewers.essential)
scripts.OnHide(viewers.essential)
assert(#h2refresh == before + 4, "frame and viewer state changes each queue re-claim")

-- CDMIndex broker events also dirty all managed viewers.
local sub
h2:InstallIndexSubscription({
    Subscribe = function(name, fn, priority)
        sub = { name = name, fn = fn, priority = priority }
    end,
})
assert(sub and sub.name == "reanchor" and type(sub.fn) == "function", "subscribes to CDMIndex")
before = #h2refresh
sub.fn("data_loaded")
assert(#h2refresh == before + 2, "CDMIndex events dirty all managed containers")

print("OK: cdm_reanchor_hooks_test")
