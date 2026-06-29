-- QUI_CDM/cdm/cdm_reanchor_hooks.lua
-- Re-pool keep-up for the re-anchor engine. Blizzard re-pools CooldownViewer item
-- frames on talent/cooldown/aura churn; this drives a throttled re-claim
-- (RefreshBuiltin) per affected container so re-anchored frames don't go stale.
-- DI'd (hooksecurefunc / refresh / scheduler injected); the dirty-set + coalesce
-- logic is unit-tested. Inert until wired by BootstrapReanchorRuntime.
local _, ns = ...

local CDMReanchorHooks = {}
ns.CDMReanchorHooks = CDMReanchorHooks

local InstanceMT = { __index = CDMReanchorHooks }

function CDMReanchorHooks.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _refresh = deps.refresh,
        _keys = deps.keys or { "essential", "utility", "buff" },
        _dirty = {},
        _scheduled = false,
        _hooked = setmetatable({}, { __mode = "k" }),
        _hookedPools = setmetatable({}, { __mode = "k" }),
        _hookedFrames = setmetatable({}, { __mode = "k" }),
        _indexSubscribed = false,
    }
    return setmetatable(self, InstanceMT)
end

function CDMReanchorHooks:MarkDirty(key)
    self._dirty[key] = true
    self:_Schedule()
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

function CDMReanchorHooks:_InstallFrameHooks(frame, key)
    if not frame or self._hookedFrames[frame] then return end
    local hooksec = self._deps.hooksecurefunc or hooksecurefunc
    if not hooksec then return end

    local installed = false
    local hooks = self
    if frame.OnActiveStateChanged then
        hooksec(frame, "OnActiveStateChanged", function()
            hooks:MarkDirty(key)
        end)
        installed = true
    end
    if frame.OnCooldownIDSet then
        hooksec(frame, "OnCooldownIDSet", function()
            hooks:MarkDirty(key)
        end)
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
            hooksec(viewer, "RefreshLayout", function() hooks:MarkDirty(key) end)
            if viewer.OnAcquireItemFrame then
                hooksec(viewer, "OnAcquireItemFrame", function(_, itemFrame)
                    hooks:_InstallFrameHooks(itemFrame, key)
                    hooks:MarkDirty(key)
                end)
            end
            if viewer.HookScript then
                viewer:HookScript("OnShow", function() hooks:MarkDirty(key) end)
                viewer:HookScript("OnHide", function() hooks:MarkDirty(key) end)
            end
        end

        if viewer then
            local pool = viewer.itemFramePool
            if pool and pool.Acquire and not self._hookedPools[pool] then
                self._hookedPools[pool] = true
                local hooks = self
                hooksec(pool, "Acquire", function(p)
                    EnumerateViewerFrames(viewer, function(frame)
                        hooks:_InstallFrameHooks(frame, key)
                    end)
                    hooks:MarkDirty(key)
                end)
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
