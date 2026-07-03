-- QUI_CDM/cdm/cdm_reanchor_hooks.lua
-- Re-pool keep-up for the re-anchor engine. Blizzard re-pools CooldownViewer item
-- frames on talent/cooldown/aura churn; this drives a throttled re-claim
-- (RefreshBuiltin) per affected container so re-anchored frames don't go stale.
-- DI'd (hooksecurefunc / refresh / scheduler injected); the dirty-set + coalesce
-- logic is unit-tested. Inert until wired by BootstrapReanchorRuntime.
local _, ns = ...

local CDMReanchorHooks = {}
ns.CDMReanchorHooks = CDMReanchorHooks

-- Every body below post-hooks a SECRET-TRACKED Blizzard CDM frame/viewer/pool method
-- (OnCooldownIDSet fires mid-RefreshData, OnActiveStateChanged mid-OnEvent, RefreshLayout
-- / pool Acquire mid-relayout). A bare hook body leaks this addon's taint into Blizzard's
-- own continuation, which then throws on the item's secret cooldown/aura values
-- (RefreshIconColor / CacheCooldownValues / RefreshAuraInstance) and gets the settings
-- NotifyListeners cascade ADDON_ACTION_BLOCKED on SetHiddenGroupBuffs. securecall isolates
-- the body's taint from the Blizzard chain -- required for EVERY hook on a CDM frame. The
-- registered closure must do NOTHING but securecall(work, ...) so the taint is captured
-- secure before any addon read; see the re-anchor reference addons' SecureHook pattern.
local _securecall = securecallfunction or function(fn, ...) return fn(...) end

local MIXIN_GLOBAL_BY_KEY = {
    buff = "CooldownViewerBuffIconItemMixin",
    trackedBar = "CooldownViewerBuffBarItemMixin",
}

local function GetDefaultMixinForKey(key)
    local globalName = MIXIN_GLOBAL_BY_KEY[key]
    return globalName and _G[globalName] or nil
end

local InstanceMT = { __index = CDMReanchorHooks }

-- Shared active-state settle scheduler. MULTIPLE hook instances (the
-- essential/utility/buff instance and the trackedBar instance) schedule their
-- flush through one of these, and both viewers process the same UNIT_AURA
-- dispatch -- so overlapping schedules within the settle window are routine.
-- Every pending callback must run on settle: a single-slot implementation drops
-- the earlier instance's flush, and because MarkActiveStateDirty resets its
-- _activeScheduled latch only inside that very callback, the losing instance
-- goes permanently deaf to OnActiveStateChanged for the rest of the session.
function CDMReanchorHooks.CreateActiveStateScheduler(createFrame)
    createFrame = createFrame or CreateFrame
    local driver
    local pending = {}
    local ticks = 0
    return function(fn)
        pending[#pending + 1] = fn
        ticks = 0
        if not driver then
            driver = createFrame("Frame")
            driver:Hide()
            driver:SetScript("OnUpdate", function(self)
                ticks = ticks + 1
                if ticks < 2 then return end
                self:Hide()
                local fns = pending
                pending = {}
                for i = 1, #fns do
                    fns[i]()
                end
            end)
        end
        driver:Show()
    end
end

function CDMReanchorHooks.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _refresh = deps.refresh,
        _keys = deps.keys or { "essential", "utility", "buff" },
        _dirty = {},
        _scheduled = false,
        _activeScheduled = false,
        _hooked = setmetatable({}, { __mode = "k" }),
        _hookedPools = setmetatable({}, { __mode = "k" }),
        _hookedFrames = setmetatable({}, { __mode = "k" }),
        _hookedMixins = setmetatable({}, { __mode = "k" }),
        _indexSubscribed = false,
        -- Optional reference-style acquire blanking. Callers opt in per key and
        -- may gate it until the first successful reanchor pass so cold-login
        -- aura frames are not hidden before QUI has adopted them.
        _blank = deps.blank,
        _isInitWindow = deps.isInitWindow,
        _isInitialReanchorDone = deps.isInitialReanchorDone,
        _getMixinForKey = deps.getMixinForKey,
        _blankKeys = deps.blankKeys or {},
        _immediateRefreshLayoutKeys = deps.immediateRefreshLayoutKeys or deps.immediateKeys or {},
        _immediateAcquireKeys = deps.immediateAcquireKeys or {},
    }
    return setmetatable(self, InstanceMT)
end

-- Optional legacy blank hook. Disabled unless the caller explicitly supplies
-- blankKeys; default BuffIcon lifecycle should only re-claim/release frames.
function CDMReanchorHooks:MaybeBlankOnAcquire(key, frame)
    if not (self._blank and frame) then return end
    if not self._blankKeys[key] then return end
    if self._isInitWindow and self._isInitWindow(key, frame) then return end
    if self._isInitialReanchorDone and self._isInitialReanchorDone(key, frame) ~= true then return end
    self._blank(frame, key)
end

function CDMReanchorHooks:MarkDirty(key)
    self._dirty[key] = true
    self:_Schedule()
end

function CDMReanchorHooks:MarkImmediate(key)
    self._dirty[key] = nil
    if self._refresh then self._refresh(key) end
end

function CDMReanchorHooks:MarkAcquire(key)
    if self._immediateAcquireKeys[key] then
        self:MarkImmediate(key)
    else
        self:MarkDirty(key)
    end
end

function CDMReanchorHooks:MarkActiveStateDirty(key)
    local reapply = self._deps.reapplyPositions
    if reapply then reapply(key) end

    self._dirty[key] = true
    if self._activeScheduled then return end
    self._activeScheduled = true
    local schedule = self._deps.scheduleActiveState or self._deps.schedule
    if schedule then
        local hooks = self
        schedule(function()
            hooks._activeScheduled = false
            hooks:Flush()
        end)
    else
        -- no scheduler injected (tests): flush is driven manually
        self._activeScheduled = false
    end
end

function CDMReanchorHooks:MarkAllDirty()
    for i = 1, #self._keys do
        self._dirty[self._keys[i]] = true
    end
    self:_Schedule()
end

-- Coalesce: ask the injected scheduler to call Flush once; ignore until it fires.
function CDMReanchorHooks:_Schedule()
    if self._scheduled then return end
    self._scheduled = true
    local schedule = self._deps.schedule
    if schedule then
        local hooks = self
        schedule(function() hooks:Flush() end)
    else
        -- no scheduler injected (tests): flush is driven manually
        self._scheduled = false
    end
end

function CDMReanchorHooks:Flush()
    self._scheduled = false
    local dirty = self._dirty
    for key in pairs(dirty) do
        dirty[key] = nil
        if self._refresh then self._refresh(key) end
    end
end

function CDMReanchorHooks:GetMixinForKey(key)
    if self._getMixinForKey then
        return self._getMixinForKey(key)
    end
    return GetDefaultMixinForKey(key)
end

local function EnumerateViewerFrames(viewer, callback)
    if not (viewer and callback) then return end
    if viewer.GetItemFrames then
        local frames = viewer:GetItemFrames()
        if type(frames) == "table" then
            for i = 1, #frames do
                callback(frames[i])
            end
        end
    end
    local pool = viewer.itemFramePool
    if pool and pool.EnumerateActive then
        for frame in pool:EnumerateActive() do
            callback(frame)
        end
    end
end

function CDMReanchorHooks:InstallGlobalMixinHooks()
    local hooksec = self._deps.hooksecurefunc or hooksecurefunc
    if not hooksec then return false end

    local installed = false
    for i = 1, #self._keys do
        local key = self._keys[i]
        local mixin = self:GetMixinForKey(key)
        if mixin and not self._hookedMixins[mixin] and mixin.OnCooldownIDSet then
            self._hookedMixins[mixin] = true
            local hooks = self
            local function markCooldownIDSet()
                hooks:MarkDirty(key)
            end
            hooksec(mixin, "OnCooldownIDSet", function(...) _securecall(markCooldownIDSet, ...) end)
            installed = true
        end
    end
    return installed
end

function CDMReanchorHooks:_InstallFrameHooks(frame, key)
    if not frame or self._hookedFrames[frame] then return end
    local hooksec = self._deps.hooksecurefunc or hooksecurefunc
    if not hooksec then return end

    local installed = false
    local hooks = self
    local function markDirty() hooks:MarkDirty(key) end
    local function markActiveStateDirty() hooks:MarkActiveStateDirty(key) end
    if frame.OnActiveStateChanged then
        hooksec(frame, "OnActiveStateChanged", function(...) _securecall(markActiveStateDirty, ...) end)
        installed = true
    end
    if frame.OnCooldownIDSet then
        hooksec(frame, "OnCooldownIDSet", function(...) _securecall(markDirty, ...) end)
        installed = true
    end
    -- Native-show restore. Blizzard's incremental UNIT_AURA path can
    -- SetShown(true) a previously sunk (alpha-0) item without any
    -- Acquire/RefreshLayout/OnCooldownIDSet; the alpha-0 park is only reopened
    -- by a successful re-claim pass, so a native show must re-drive one or the
    -- re-shown frame stays invisible. Rides the settled active-state scheduler
    -- (Blizzard is still mutating the item mid-show).
    if frame.HookScript then
        frame:HookScript("OnShow", function(...) _securecall(markActiveStateDirty, ...) end)
        installed = true
    end
    if installed then
        self._hookedFrames[frame] = true
    end
end

-- Install a RefreshLayout hook on each managed viewer (idempotent per viewer) so
-- a Blizzard relayout marks that container dirty.
function CDMReanchorHooks:InstallViewerHooks(getViewer)
    local hooksec = self._deps.hooksecurefunc or hooksecurefunc
    if not (hooksec and getViewer) then return end
    for i = 1, #self._keys do
        local key = self._keys[i]
        local viewer = getViewer(key)
        if viewer and not self._hooked[viewer] and viewer.RefreshLayout then
            self._hooked[viewer] = true
            local hooks = self
            local function markDirty() hooks:MarkDirty(key) end
            local function markRefreshLayout()
                if hooks._immediateRefreshLayoutKeys[key] then
                    hooks:MarkImmediate(key)
                else
                    hooks:MarkDirty(key)
                end
            end
            hooksec(viewer, "RefreshLayout", function(...) _securecall(markRefreshLayout, ...) end)
            if viewer.OnAcquireItemFrame then
                local function onAcquire(_, itemFrame)
                    hooks:_InstallFrameHooks(itemFrame, key)
                    -- G11: reference-style acquire keep-up. Latency-sensitive
                    -- keys can bypass the generic ~50ms dirty flush and re-claim
                    -- immediately; optional blanking remains caller-controlled.
                    hooks:MaybeBlankOnAcquire(key, itemFrame)
                    hooks:MarkAcquire(key)
                end
                hooksec(viewer, "OnAcquireItemFrame", function(...) _securecall(onAcquire, ...) end)
            end
            if viewer.HookScript then
                viewer:HookScript("OnShow", function(...) _securecall(markDirty, ...) end)
                viewer:HookScript("OnHide", function(...) _securecall(markDirty, ...) end)
            end
        end

        if viewer then
            local pool = viewer.itemFramePool
            if pool and pool.Acquire and not self._hookedPools[pool] then
                self._hookedPools[pool] = true
                local hooks = self
                local function onPoolAcquire()
                    EnumerateViewerFrames(viewer, function(frame)
                        hooks:_InstallFrameHooks(frame, key)
                    end)
                    hooks:MarkAcquire(key)
                end
                hooksec(pool, "Acquire", function(...) _securecall(onPoolAcquire, ...) end)
            end
            EnumerateViewerFrames(viewer, function(frame)
                self:_InstallFrameHooks(frame, key)
            end)
        end
    end
end

function CDMReanchorHooks:InstallIndexSubscription(index)
    if self._indexSubscribed then return end
    if not (index and index.Subscribe) then return end
    local hooks = self
    index.Subscribe("reanchor", function()
        hooks:MarkAllDirty()
    end, 50)
    self._indexSubscribed = true
end

-- Catalog / layout / spec events -> requeue every managed container.
function CDMReanchorHooks:OnEvent()
    self:MarkAllDirty()
end

---------------------------------------------------------------------------
-- Proc-glow + native-alert suppression for re-anchored Blizzard CDM frames
--
-- G6: Blizzard's native gold proc flipbook (frame.SpellActivationAlert, a child
--     Frame re-created + re-shown on every proc) renders unstyled over QUI chrome
--     on a re-anchored builtin. The one-time decorate-hide no-ops (the alert is
--     lazily re-shown), so it MUST be re-hidden in the ShowAlert hook.
-- G8: re-anchored Blizzard frames are NOT owned IconFactory icons, so QUI's
--     event-driven glow system never enumerates them -> they get NO QUI glow. Paint
--     the configured glow on a QUI-OWNED overlay CHILD of the live frame (never on
--     the live frame's secret state).
--
-- Both ride one securecall-wrapped hook on ActionButtonSpellAlertManager
-- ShowAlert/HideAlert (the Blizzard manager that drives the native alert and is
-- fired for CDM item frames). hooksecurefunc on a Blizzard manager that runs a
-- secret CDM continuation requires the ENTIRE body run under securecall, else this
-- addon's taint leaks into Blizzard's chain (see cdm-reanchor-hook-bodies-need-
-- securecall). Inside the body the only writes on the LIVE frame are SetAlpha/Hide
-- on its SpellActivationAlert region (taint-safe, mirrors the re-anchor reference);
-- the glow runs entirely on the QUI-owned overlay child. The frame->entry lookup is
-- a plain non-secret table read.
--
-- DI'd for unit testing: getEntryForFrame (boot:GetEntryForFrame), ensureOverlay
-- (own-child factory), resolveGlow (cdm_effects glow config), startGlow/stopGlow
-- (cdm_effects LCG applier on the overlay), hooksecurefunc + securecall.
local CDMReanchorProcGlow = {}
ns.CDMReanchorProcGlow = CDMReanchorProcGlow

local ProcGlowMT = { __index = CDMReanchorProcGlow }

function CDMReanchorProcGlow.New(deps)
    deps = deps or {}
    local self = {
        _getEntryForFrame = deps.getEntryForFrame,
        _ensureOverlay    = deps.ensureOverlay,
        _resolveGlow      = deps.resolveGlow,
        _startGlow        = deps.startGlow,
        _stopGlow         = deps.stopGlow,
        _hooksecurefunc   = deps.hooksecurefunc or hooksecurefunc,
        _securecall       = deps.securecall or _securecall,
        _installed        = false,
    }
    return setmetatable(self, ProcGlowMT)
end

-- The securecall'd ShowAlert work body. frame is the Blizzard CDM item frame.
function CDMReanchorProcGlow:_OnShowAlert(frame)
    if not frame then return end
    local entry = self._getEntryForFrame and self._getEntryForFrame(frame) or nil
    if entry == nil then return end  -- not a managed re-anchored CDM frame: no-op
    -- G6: suppress Blizzard's native proc flipbook on the live frame. SetAlpha/Hide
    -- on the SpellActivationAlert region are the only live-frame writes here.
    local alert = frame.SpellActivationAlert
    if alert then
        if alert.SetAlpha then alert:SetAlpha(0) end
        if alert.Hide then alert:Hide() end
    end
    -- G8: paint QUI's configured glow on a QUI-OWNED overlay child of the live frame.
    if not (self._ensureOverlay and self._resolveGlow and self._startGlow) then return end
    local viewerSettings = self._resolveGlow(entry)
    if not viewerSettings then return end   -- viewer/per-spell glow disabled
    local overlay = self._ensureOverlay(frame)
    if overlay then self._startGlow(overlay, viewerSettings) end
end

-- The securecall'd HideAlert work body. Stop the QUI glow on the own overlay.
function CDMReanchorProcGlow:_OnHideAlert(frame)
    if not frame then return end
    local entry = self._getEntryForFrame and self._getEntryForFrame(frame) or nil
    if entry == nil then return end
    if not (self._ensureOverlay and self._stopGlow) then return end
    local overlay = self._ensureOverlay(frame)
    if overlay then self._stopGlow(overlay) end
end

-- Install the ShowAlert/HideAlert hooks on the manager (idempotent; once globally).
-- Each registered closure does NOTHING but securecall the work body so the taint is
-- captured secure before any addon read.
function CDMReanchorProcGlow:Install(manager)
    if self._installed then return false end
    local hooksec = self._hooksecurefunc
    if not (manager and hooksec) then return false end
    if not (manager.ShowAlert and manager.HideAlert) then return false end
    self._installed = true
    local me = self
    local function onShow(_, frame) me:_OnShowAlert(frame) end
    local function onHide(_, frame) me:_OnHideAlert(frame) end
    hooksec(manager, "ShowAlert", function(...) me._securecall(onShow, ...) end)
    hooksec(manager, "HideAlert", function(...) me._securecall(onHide, ...) end)
    return true
end
