-- QUI_CDM/cdm/cdm_reanchor_editlock.lua
-- Locks the Blizzard CooldownViewer systems out of Blizzard Edit Mode. The four
-- viewers are QUI-managed (re-anchored + parked alpha-0 by CDMReanchorPark), so
-- they must not be selectable / movable / editable in Edit Mode -- otherwise the
-- native Cooldown Manager re-surfaces as an editable system on top of the QUI
-- containers. This suppresses that: force the viewers non-movable and close the
-- Blizzard settings dialog whenever it attaches to one of our viewers.
--
-- Taint posture: ADDITIVE hooks only (hooksecurefunc -- never replaces a secure
-- method) and only benign mutators (SetMovable / dialog:Hide). Viewers are
-- identity-matched against the managed set, so there is no dependency on the
-- EditModeSystem enum value. DI'd + idempotent for unit testing.
local _, ns = ...

local CDMReanchorEditLock = {}
ns.CDMReanchorEditLock = CDMReanchorEditLock

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
        hooksec(sel, "SetAlpha", function(s, a)
            if lock._selReasserting then return end
            if a ~= 0 then
                lock._selReasserting = true
                s:SetAlpha(0)
                lock._selReasserting = false
            end
        end)
    end
    self._selReasserting = true
    sel:SetAlpha(0)
    self._selReasserting = false
end

-- Make one viewer un-editable: force non-movable now, re-assert on every Edit-Mode
-- enter / system-select (Blizzard re-enables movability there), close the settings
-- dialog if selection routed it open, and keep the mover/selection invisible.
function CDMReanchorEditLock:LockViewer(viewer)
    if not viewer or self._hookedViewers[viewer] then return false end
    self._managed[viewer] = true
    self._hookedViewers[viewer] = true
    if viewer.SetMovable then viewer:SetMovable(false) end
    self:HideSelection(viewer)

    local hooksec = self._hooksecurefunc
    if not hooksec then return true end
    local lock = self
    if viewer.OnEditModeEnter then
        hooksec(viewer, "OnEditModeEnter", function(v)
            if v.SetMovable then v:SetMovable(false) end
            lock:HideSelection(v)
        end)
    end
    if viewer.SelectSystem then
        hooksec(viewer, "SelectSystem", function(v)
            if v.SetMovable then v:SetMovable(false) end
            lock:_CloseDialog()
            lock:HideSelection(v)
        end)
    end
    if viewer.HighlightSystem then
        hooksec(viewer, "HighlightSystem", function(v)
            lock:HideSelection(v)
        end)
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
    hooksec(dialog, "AttachToSystemFrame", function(dlg, systemFrame)
        if lock:IsManaged(systemFrame) then
            if dlg.Hide then dlg:Hide() end
            lock:_Notify()
        end
    end)
    return true
end

function CDMReanchorEditLock:Install(getViewer)
    local keys = self._deps.keys or { "essential", "utility", "buff", "trackedBar" }
    if getViewer then
        for i = 1, #keys do
            self:LockViewer(getViewer(keys[i]))
        end
    end
    -- Hook the settings dialog if it already exists; otherwise the first managed
    -- SelectSystem (Edit Mode active => dialog loaded) resolves + hooks it lazily.
    self:_ResolveDialog()
end
