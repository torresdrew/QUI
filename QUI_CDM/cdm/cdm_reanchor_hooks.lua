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
    -- ticks = frames since the LAST enqueue (the 2-frame settle: Blizzard is
    -- still mutating the item mid-show). age = frames since this cycle armed:
    -- a combat-start burst re-enqueues every frame, and a settle counter alone
    -- never fires under that churn -- unclaimed frames sat visible at the
    -- native viewer position for the whole storm. The age deadline bounds the
    -- wait; under sustained churn the flush cadence becomes one per deadline.
    local ticks = 0
    local age = 0
    local armed = false
    return function(fn)
        pending[#pending + 1] = fn
        ticks = 0
        if not armed then
            armed = true
            age = 0
        end
        if not driver then
            driver = createFrame("Frame")
            driver:Hide()
            driver:SetScript("OnUpdate", function(self)
                ticks = ticks + 1
                age = age + 1
                if ticks < 2 and age < 8 then return end
                self:Hide()
                armed = false
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
        -- Blanking a frame the bridge still CLAIMS adds an alpha-0/alpha-1
        -- flicker per pool churn (its SetPoint guard re-pins it anyway).
        _isClaimed = deps.isClaimed,
        -- Early anchor-guard install (combat-start snap fix): frames Blizzard
        -- acquires mid-combat had no guard until first claimed, so they
        -- rendered at the native viewer's mid-screen position until the next
        -- re-claim pass. Opted-in keys get the guard at every acquire
        -- (post-initial-reanchor; the bridge dedupes installs per frame).
        _installGuard = deps.installGuard,
        _installGuardKeys = deps.installGuardKeys or {},
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
    if self._isClaimed and self._isClaimed(frame) then return end
    self._blank(frame, key)
end

-- Early anchor-guard install for opted-in keys. Retried on EVERY acquire (not
-- once per frame) so a frame first seen before the initial reanchor pass still
-- picks the guard up later; InstallAnchorGuard itself is idempotent per frame.
-- Gated on isInitialReanchorDone so cold-login frames are not alpha-0'd by the
-- guard's unclaimed branch before QUI's first pass has adopted them.
function CDMReanchorHooks:MaybeInstallAnchorGuard(key, frame)
    local install = self._installGuard
    if not (install and frame) then return end
    if not self._installGuardKeys[key] then return end
    if self._isInitialReanchorDone and self._isInitialReanchorDone(key, frame) ~= true then return end
    install(frame, key)
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
    if not frame then return end
    -- Before the once-per-frame gate: the guard install retries per acquire.
    self:MaybeInstallAnchorGuard(key, frame)
    if self._hookedFrames[frame] then return end
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

-- Viewer glue (combat-start snap fix, reference-addon recipe): pin the Blizzard
-- viewer's rect onto the QUI container (viewer TOPLEFT/BOTTOMRIGHT -> container
-- corners) and re-assert whenever anything else re-anchors the viewer. The
-- viewers sit at their native mid-screen Edit-Mode position at alpha-1, so any
-- item frame Blizzard lays out before QUI claims it renders mid-screen; with
-- the glue, Blizzard's own grid layout lands ON the QUI container instead --
-- the mid-screen landing spot stops existing. canWrite gates every write (the
-- viewer is an Edit-Mode-managed frame: anchor writes are combat-restricted);
-- a glue missed in combat is recovered via ReassertViewerGlue on
-- PLAYER_REGEN_ENABLED. Buff is NOT glued: cdm_buff_layout owns that viewer's
-- anchoring and the glue would fight it.
function CDMReanchorHooks:_GlueViewer(entry)
    local viewer = entry.viewer
    local getContainer = self._glueGetContainer
    local canWrite = self._glueCanWrite
    local container = getContainer and getContainer(entry.key) or nil
    if not (viewer and container) then return false end
    if canWrite and not canWrite() then return false end
    viewer:ClearAllPoints()
    viewer:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    viewer:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    return true
end

function CDMReanchorHooks:InstallViewerGlue(getViewer, getContainer, glueKeys, canWrite)
    local hooksec = self._deps.hooksecurefunc or hooksecurefunc
    if not (hooksec and getViewer and getContainer) then return end
    self._glueGetContainer = getContainer
    self._glueCanWrite = canWrite
    self._gluedViewers = self._gluedViewers or setmetatable({}, { __mode = "k" })
    self._glueEntries = self._glueEntries or {}
    glueKeys = glueKeys or {}
    for i = 1, #self._keys do
        local key = self._keys[i]
        local viewer = glueKeys[key] and getViewer(key) or nil
        if viewer and not self._gluedViewers[viewer] then
            self._gluedViewers[viewer] = true
            local entry = { viewer = viewer, key = key, applied = false }
            self._glueEntries[#self._glueEntries + 1] = entry
            local hooks = self
            -- Loop guard: QUI's own glue passes the container as relativeTo,
            -- so a container-relative SetPoint is our own call -> ignore.
            local function reglue(_, _point, relativeTo)
                local container = hooks._glueGetContainer
                    and hooks._glueGetContainer(entry.key) or nil
                if not container or relativeTo == container then return end
                entry.applied = hooks:_GlueViewer(entry)
            end
            hooksec(viewer, "SetPoint", function(...) _securecall(reglue, ...) end)
            entry.applied = self:_GlueViewer(entry)
        end
    end
    -- Retry entries whose initial glue missed (container not created yet at
    -- hook-install time, or a combat-locked /reload install) -- this method
    -- re-runs on the RefreshReanchorRuntimeHooks retry paths, so a peaceful
    -- login recovers here instead of waiting for the first combat end.
    for i = 1, #self._glueEntries do
        local entry = self._glueEntries[i]
        if not entry.applied then
            entry.applied = self:_GlueViewer(entry)
        end
    end
end

function CDMReanchorHooks:ReassertViewerGlue()
    local entries = self._glueEntries
    if not entries then return end
    for i = 1, #entries do
        entries[i].applied = self:_GlueViewer(entries[i])
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

---------------------------------------------------------------------------
-- Pandemic glow for re-anchored Blizzard CDM frames
--
-- Owned icons drive their pandemic glow from the resolver's cached aura
-- DurationObject (cdm_effects UpdatePandemicGlow); re-anchored live frames
-- never enter that path (no _spellEntry/_lastAuraDurObj, not in the glow
-- spell map). Their signal is Blizzard's OWN pandemic state machine:
-- CooldownViewerItemMixin:CheckPandemicTimeDisplay calls
-- ShowPandemicStateFrame/HidePandemicStateFrame on the item frame
-- (CooldownViewer.lua:620-644), computed from C_UnitAuras
-- GetRefreshExtendedDuration - GetAuraBaseDuration -- the TRUE per-spell
-- pandemic window, self-driven from the item's aura refresh (no user alert
-- config required; gated only on C_CooldownViewer.GetValidAlertTypes).
--
-- Post-hook both methods per claimed frame. ShowPandemicStateFrame re-fires
-- every item OnUpdate tick during pandemic, so the paint is latched per frame
-- (keyed by entry, so a re-pooled frame repaints for its new spell). Inside
-- the body the only live-frame write is SetAlpha(0)/Hide on its PandemicIcon
-- child (Blizzard's native pandemic FX -- suppressed on managed frames the
-- same way the proc bridge suppresses SpellActivationAlert; unmanaged frames
-- keep it). The QUI visual is painted on the QUI-OWNED overlay child only.
-- Every hook body runs under securecall -- required for EVERY hook on a CDM
-- frame (see the header comment at the top of this file).
--
-- DI'd for unit testing: getEntryForFrame, ensureOverlay (own-child factory),
-- isPandemicEnabled (cdm_effects settings gate), startPandemic/stopPandemic
-- (cdm_effects overlay painter), hooksecurefunc + securecall.
local CDMReanchorPandemic = {}
ns.CDMReanchorPandemic = CDMReanchorPandemic

local PandemicMT = { __index = CDMReanchorPandemic }

function CDMReanchorPandemic.New(deps)
    deps = deps or {}
    local self = {
        _getEntryForFrame  = deps.getEntryForFrame,
        _ensureOverlay     = deps.ensureOverlay,
        _isPandemicEnabled = deps.isPandemicEnabled,
        _startPandemic     = deps.startPandemic,
        _stopPandemic      = deps.stopPandemic,
        _hooksecurefunc    = deps.hooksecurefunc or hooksecurefunc,
        _securecall        = deps.securecall or _securecall,
        _hooked            = setmetatable({}, { __mode = "k" }),
        -- frame -> latch key of the entry whose pandemic glow is currently
        -- painted. Keyed by spellID/id (not entry table identity: curated
        -- lists can rebuild entry tables across claim passes for the SAME
        -- spell, and a table-identity latch would stop/repaint on every pass)
        -- so a frame re-pooled to a different spell drops the stale glow while
        -- a same-spell re-claim keeps it untouched.
        _active            = setmetatable({}, { __mode = "k" }),
    }
    return setmetatable(self, PandemicMT)
end

local function PandemicLatchKey(entry)
    if not entry then return nil end
    return entry.spellID or entry.id or entry
end

function CDMReanchorPandemic:_StopFor(frame)
    self._active[frame] = nil
    if not (self._ensureOverlay and self._stopPandemic) then return end
    local overlay = self._ensureOverlay(frame)
    if overlay then self._stopPandemic(overlay) end
end

-- The securecall'd ShowPandemicStateFrame work body.
function CDMReanchorPandemic:_OnShowPandemic(frame)
    if not frame then return end
    local entry = self._getEntryForFrame and self._getEntryForFrame(frame) or nil
    if entry == nil then return end  -- not a managed re-anchored CDM frame: no-op
    -- Suppress Blizzard's native pandemic FX on managed frames (QUI owns the
    -- visual, per settings -- owned icons never show the native FX either).
    -- Raw field read; SetAlpha/Hide on the child region are the only
    -- live-frame writes here, mirroring the proc bridge's alert suppression.
    local nativeIcon = frame.PandemicIcon
    if nativeIcon then
        if nativeIcon.SetAlpha then nativeIcon:SetAlpha(0) end
        if nativeIcon.Hide then nativeIcon:Hide() end
    end
    local enabled = self._isPandemicEnabled and self._isPandemicEnabled(entry)
    if not enabled then
        -- Settings toggled off mid-pandemic: clear a live latch.
        if self._active[frame] ~= nil then self:_StopFor(frame) end
        return
    end
    if self._active[frame] == PandemicLatchKey(entry) then return end  -- latched: re-fires per tick
    if not (self._ensureOverlay and self._startPandemic) then return end
    local overlay = self._ensureOverlay(frame)
    if overlay then
        self._startPandemic(overlay)
        self._active[frame] = PandemicLatchKey(entry)
    end
end

-- The securecall'd HidePandemicStateFrame work body. Always safe to clear --
-- no entry guard, so a frame whose registry entry was dropped mid-pandemic
-- still tears its glow down.
function CDMReanchorPandemic:_OnHidePandemic(frame)
    if not frame then return end
    if self._active[frame] == nil then return end
    self:_StopFor(frame)
end

-- Claim-time reconcile, called from the runtime claim pass alongside
-- auraPhase:Hook. A frame re-pooled to a different entry never fires
-- HidePandemicStateFrame for the OLD spell (pool release just Hide()s the
-- frame), so a stale latch would keep the old glow visible over the new
-- spell's icon until its next pandemic. Stop it here; the new spell's own
-- Show hook repaints if it is actually in pandemic. Same-spell re-claims
-- (rebuilt entry table, same spellID) keep the glow untouched.
function CDMReanchorPandemic:OnClaim(frame, entry)
    if not frame then return end
    local current = self._active[frame]
    if current ~= nil and current ~= PandemicLatchKey(entry) then
        self:_StopFor(frame)
    end
end

-- Install the per-frame post-hooks (idempotent per frame). The registered
-- closures do NOTHING but securecall the work bodies.
function CDMReanchorPandemic:Hook(frame)
    if not frame or self._hooked[frame] then return end
    local hooksec = self._hooksecurefunc
    if not hooksec then return end
    if not (frame.ShowPandemicStateFrame and frame.HidePandemicStateFrame) then return end
    self._hooked[frame] = true
    local me = self
    local function showWork(f) me:_OnShowPandemic(f) end
    local function hideWork(f) me:_OnHidePandemic(f) end
    hooksec(frame, "ShowPandemicStateFrame", function(...) me._securecall(showWork, ...) end)
    hooksec(frame, "HidePandemicStateFrame", function(...) me._securecall(hideWork, ...) end)
end
