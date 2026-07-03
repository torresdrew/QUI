-- QUI_CDM/cdm/cdm_reanchor_editlock.lua
-- Locks the Blizzard CooldownViewer systems out of Blizzard Edit Mode. The
-- native systems are QUI-managed or mirrored, so they must not be visible,
-- draggable, or configurable in Blizzard Edit Mode.
--
-- Taint posture: do not touch viewer/Selection state until Blizzard_EditMode's
-- settings dialog exists. Cold-login UNIT_AURA can run before that point, and
-- Blizzard's CooldownViewer aura lookup tables reject tainted access.
local _, ns = ...

local CDMReanchorEditLock = {}
ns.CDMReanchorEditLock = CDMReanchorEditLock

-- Every body here post-hooks a CDM viewer / its Edit-Mode selection / the settings
-- dialog -- the same SettingsLayoutManager machinery the SetHiddenGroupBuffs cascade
-- runs through. Bodies run under securecall so they can't leak this addon's taint into
-- Blizzard's continuation (required for EVERY hook on a CDM frame).
local _securecall = securecallfunction or function(fn, ...) return fn(...) end

local InstanceMT = { __index = CDMReanchorEditLock }

function CDMReanchorEditLock.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _hooksecurefunc = deps.hooksecurefunc or hooksecurefunc,
        _managed = setmetatable({}, { __mode = "k" }),        -- viewer -> true
        _hookedViewers = setmetatable({}, { __mode = "k" }),  -- viewer -> true
        _selHooked = setmetatable({}, { __mode = "k" }),      -- Selection frame -> true
        _dialog = nil,
        _dialogHooked = false,
        _notified = false,
        _waitingForEditMode = false,
        _waitingForCooldownViewerData = false,
        _cooldownViewerDataFrame = nil,
        _getViewer = nil,
    }
    return setmetatable(self, InstanceMT)
end

function CDMReanchorEditLock:IsManaged(frame)
    return frame ~= nil and self._managed[frame] == true
end

-- Resolve the Edit-Mode settings dialog (lazily -- the global may not exist until
-- Edit Mode first loads) and ensure it's hooked. Returns the dialog or nil.
function CDMReanchorEditLock:_ResolveDialog()
    if not self._dialog then
        local getDialog = self._deps.getDialog
        local dialog = getDialog and getDialog() or nil
        if dialog then self:HookDialog(dialog) end
    end
    return self._dialog
end

function CDMReanchorEditLock:_CloseDialog()
    local dialog = self:_ResolveDialog()
    if dialog and dialog.Hide then dialog:Hide() end
end

function CDMReanchorEditLock:_Notify()
    if self._notified then return end
    self._notified = true
    if self._deps.notify then self._deps.notify() end
end

function CDMReanchorEditLock:_QueueEditModeRetry()
    if self._waitingForEditMode then return end
    self._waitingForEditMode = true

    local continue = self._deps.continueOnAddOnLoaded
    local eventUtil = _G.EventUtil
    if not continue and eventUtil and eventUtil.ContinueOnAddOnLoaded then
        continue = function(addonName, fn)
            eventUtil.ContinueOnAddOnLoaded(addonName, fn)
        end
    end
    if not continue then return end

    local lock = self
    continue("Blizzard_EditMode", function()
        lock._waitingForEditMode = false
        lock:Install()
    end)
end

function CDMReanchorEditLock:_IsCooldownViewerReady()
    local ready = self._deps.isCooldownViewerReady
    if ready then
        return ready() == true
    end

    local catalog = ns.CDMCatalog
    if catalog and catalog.IsCooldownViewerReady then
        return catalog.IsCooldownViewerReady()
    end

    local api = _G.C_CooldownViewer
    if not api then return false end
    if not api.IsCooldownViewerAvailable then return true end
    local ok, isReady = pcall(api.IsCooldownViewerAvailable)
    return ok and isReady == true
end

function CDMReanchorEditLock:_QueueCooldownViewerDataRetry()
    if self._waitingForCooldownViewerData then return end
    self._waitingForCooldownViewerData = true

    local continue = self._deps.continueOnCooldownViewerDataLoaded
    if continue then
        local lock = self
        continue(function()
            lock._waitingForCooldownViewerData = false
            lock:Install()
        end)
        return
    end

    if not CreateFrame then return end
    local frame = self._cooldownViewerDataFrame
    if not frame then
        frame = CreateFrame("Frame")
        self._cooldownViewerDataFrame = frame
    end

    local lock = self
    frame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    frame:SetScript("OnEvent", function(f)
        f:UnregisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
        f:SetScript("OnEvent", nil)
        lock._waitingForCooldownViewerData = false
        lock:Install()
    end)
end

-- Make the Edit-Mode selection/mover of a managed viewer invisible. The mover
-- visual is the system's `.Selection` frame (border + label + drag handles),
-- shown via Selection:ShowHighlighted()/ShowSelected() -- both only call Show()
-- and never touch alpha. So forcing Selection alpha 0 and re-asserting it on any
-- SetAlpha hides the mover entirely while leaving the frame structurally intact.
-- Taint-safe: additive hook + unprotected SetAlpha; no keys written onto the frame.
function CDMReanchorEditLock:HideSelection(viewer)
    local sel = viewer and viewer.Selection
    if not sel or not sel.SetAlpha then return end
    local hooksec = self._hooksecurefunc
    if hooksec and not self._selHooked[sel] then
        self._selHooked[sel] = true
        local lock = self
        local function reassertSel(s, a)
            if lock._selReasserting then return end
            if a ~= 0 then
                lock._selReasserting = true
                s:SetAlpha(0)
                lock._selReasserting = false
            end
        end
        hooksec(sel, "SetAlpha", function(...) _securecall(reassertSel, ...) end)
    end
    self._selReasserting = true
    sel:SetAlpha(0)
    self._selReasserting = false
end

function CDMReanchorEditLock:DisableSelectionDrag(viewer)
    local sel = viewer and viewer.Selection
    if not (sel and sel.SetScript) then return end
    sel:SetScript("OnDragStart", nil)
    sel:SetScript("OnDragStop", nil)
end

function CDMReanchorEditLock:SuppressNativeTrackedBar(viewer, key)
    if key ~= "trackedBar" and viewer ~= _G.BuffBarCooldownViewer then return end

    local suppress = self._deps.suppressNativeTrackedBar
    if suppress then
        suppress(viewer, key)
        return
    end

    local suppressor = ns.CDMBlizzardBuffBarSuppressor
    if suppressor and suppressor.Suppress then
        suppressor:Suppress(viewer)
    end
end

-- Make one viewer un-editable: force non-movable now, re-assert on every Edit-Mode
-- enter / system-select (Blizzard re-enables movability there), close the settings
-- dialog if selection routed it open, and keep the mover/selection invisible.
function CDMReanchorEditLock:LockViewer(viewer, key)
    if not viewer or self._hookedViewers[viewer] then return false end
    self._managed[viewer] = true
    self._hookedViewers[viewer] = true
    if viewer.SetMovable then viewer:SetMovable(false) end
    self:DisableSelectionDrag(viewer)
    self:HideSelection(viewer)
    self:SuppressNativeTrackedBar(viewer, key)

    local hooksec = self._hooksecurefunc
    if not hooksec then return true end
    local lock = self
    if viewer.SelectSystem then
        local function onSelect(v)
            if v.SetMovable then v:SetMovable(false) end
            lock:_CloseDialog()
            lock:HideSelection(v)
            lock:SuppressNativeTrackedBar(v, key)
        end
        hooksec(viewer, "SelectSystem", function(...) _securecall(onSelect, ...) end)
    end
    if viewer.HighlightSystem then
        local function onHighlight(v)
            lock:HideSelection(v)
            lock:SuppressNativeTrackedBar(v, key)
        end
        hooksec(viewer, "HighlightSystem", function(...) _securecall(onHighlight, ...) end)
    end
    if viewer.ClearHighlight then
        local function onClear(v)
            lock:HideSelection(v)
            lock:SuppressNativeTrackedBar(v, key)
        end
        hooksec(viewer, "ClearHighlight", function(...) _securecall(onClear, ...) end)
    end
    return true
end

-- When Blizzard attaches its settings dialog to a managed viewer, close it (the
-- system is QUI-managed; there's nothing to edit here).
function CDMReanchorEditLock:HookDialog(dialog)
    if not dialog then return false end
    self._dialog = dialog
    if self._dialogHooked then return false end
    local hooksec = self._hooksecurefunc
    if not (hooksec and dialog.AttachToSystemFrame) then return false end
    self._dialogHooked = true
    local lock = self
    local function onAttach(dlg, systemFrame)
        if lock:IsManaged(systemFrame) then
            if dlg.Hide then dlg:Hide() end
            lock:_Notify()
        end
    end
    hooksec(dialog, "AttachToSystemFrame", function(...) _securecall(onAttach, ...) end)
    return true
end

function CDMReanchorEditLock:Install(getViewer)
    if getViewer then
        self._getViewer = getViewer
    end

    local dialog = self:_ResolveDialog()
    if not dialog then
        self:_QueueEditModeRetry()
        return false
    end
    if not self:_IsCooldownViewerReady() then
        self:_QueueCooldownViewerDataRetry()
        return false
    end

    local keys = self._deps.keys or { "essential", "utility", "buff", "trackedBar" }
    getViewer = self._getViewer
    if getViewer then
        for i = 1, #keys do
            local key = keys[i]
            self:LockViewer(getViewer(key), key)
        end
    end
    return true
end
