-- tests/unit/cdm_reanchor_editlock_test.lua
-- Run: lua tests/unit/cdm_reanchor_editlock_test.lua
-- Contract for CDMReanchorEditLock: locks the managed Blizzard CooldownViewer
-- systems out of Blizzard Edit Mode -- force non-movable (re-asserted on edit
-- enter / select) and close the settings dialog when it attaches to one of ours.
-- Additive hooks only; the dialog is resolved lazily.

local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_editlock.lua", "cdm_reanchor_editlock.lua")("QUI", ns)
local EL = assert(ns.CDMReanchorEditLock, "CDMReanchorEditLock exported")

-- Mock hooksecurefunc: record post-hooks; fire() runs original then post-hooks.
local hooks = {}
local function mockHooksec(obj, method, fn)
    hooks[obj] = hooks[obj] or {}
    hooks[obj][method] = hooks[obj][method] or {}
    table.insert(hooks[obj][method], fn)
end
local function fire(obj, method, ...)
    if obj[method] then obj[method](obj, ...) end
    local list = hooks[obj] and hooks[obj][method]
    if list then for _, fn in ipairs(list) do fn(obj, ...) end end
end

local function MakeSelection()
    local s = { alpha = 1 }
    function s:SetAlpha(a) self.alpha = a end
    function s:Show() self.shown = true end   -- ShowHighlighted/ShowSelected analog
    return s
end

local function MakeViewer()
    local v = { movable = true, Selection = MakeSelection() }
    function v:SetMovable(m) self.movable = m end
    function v:SelectSystem() end
    function v:OnEditModeEnter() end
    function v:HighlightSystem() end
    return v
end

local function MakeDialog()
    local d = { hidden = false, attached = nil }
    function d:AttachToSystemFrame(sf) self.attached = sf end
    function d:Hide() self.hidden = true end
    return d
end

-- ===== Core: lock a viewer + hook a present dialog
do
    local viewer = MakeViewer()
    local dialog = MakeDialog()
    local notifies = 0
    local lock = EL.New({
        hooksecurefunc = mockHooksec,
        keys = { "essential" },
        getDialog = function() return dialog end,
        notify = function() notifies = notifies + 1 end,
    })
    lock:Install(function() return viewer end)

    assert(lock:IsManaged(viewer), "viewer marked managed")
    assert(viewer.movable == false, "viewer forced non-movable at install")

    -- Mover/selection forced invisible at install.
    assert(viewer.Selection.alpha == 0, "Selection alpha forced to 0 (mover invisible)")

    -- Blizzard re-shows the mover on highlight (ShowHighlighted -> Show + may bump
    -- alpha); the SetAlpha re-assert hook keeps it 0. fire() runs the original
    -- SetAlpha(1) then the recorded post-hook, modelling hooksecurefunc.
    fire(viewer.Selection, "SetAlpha", 1)
    assert(viewer.Selection.alpha == 0, "SetAlpha(1) on Selection is re-asserted to 0")
    fire(viewer, "HighlightSystem")
    assert(viewer.Selection.alpha == 0, "HighlightSystem keeps the mover invisible")
    fire(viewer, "OnEditModeEnter")
    assert(viewer.Selection.alpha == 0, "OnEditModeEnter keeps the mover invisible")

    -- Blizzard re-enables movability on edit enter -> our hook re-asserts false.
    viewer.movable = true
    fire(viewer, "OnEditModeEnter")
    assert(viewer.movable == false, "OnEditModeEnter re-asserts non-movable")

    -- Selecting the system re-asserts non-movable AND closes the dialog.
    viewer.movable = true
    fire(viewer, "SelectSystem")
    assert(viewer.movable == false, "SelectSystem re-asserts non-movable")
    assert(dialog.hidden == true, "SelectSystem closes the settings dialog")

    -- Dialog attaching to a MANAGED viewer -> Hide + notify once.
    dialog.hidden = false
    fire(dialog, "AttachToSystemFrame", viewer)
    assert(dialog.hidden == true, "dialog attached to managed viewer is hidden")
    assert(notifies == 1, "notify fired once")

    -- Attaching again -> hidden again, but notify is one-shot.
    dialog.hidden = false
    fire(dialog, "AttachToSystemFrame", viewer)
    assert(dialog.hidden == true, "dialog re-hidden on second attach")
    assert(notifies == 1, "notify is one-shot")

    -- Dialog attaching to an UNMANAGED frame -> left alone.
    dialog.hidden = false
    fire(dialog, "AttachToSystemFrame", { foreign = true })
    assert(dialog.hidden == false, "unmanaged system frame: dialog NOT hidden")

    -- Idempotent: re-locking the same viewer is a no-op.
    assert(lock:LockViewer(viewer) == false, "LockViewer idempotent")
end

-- ===== Lazy dialog: global absent at install, resolved on first select
do
    local viewer = MakeViewer()
    local dialog = MakeDialog()
    local available = false
    local lock = EL.New({
        hooksecurefunc = mockHooksec,
        keys = { "essential" },
        getDialog = function() return available and dialog or nil end,
    })
    lock:Install(function() return viewer end)
    -- Dialog not present yet -> nothing hooked, SelectSystem can't close it.
    viewer.movable = true
    fire(viewer, "SelectSystem")
    assert(viewer.movable == false, "non-movable still re-asserted without a dialog")
    assert(dialog.hidden == false, "no dialog yet -> nothing to close")

    -- Edit Mode loads the dialog; next select resolves + closes it.
    available = true
    fire(viewer, "SelectSystem")
    assert(dialog.hidden == true, "lazily resolved dialog is closed on later select")
end

-- ===== Nil-safety
do
    local lock = EL.New({ hooksecurefunc = mockHooksec, keys = {} })
    lock:Install(nil)                 -- no getViewer, no dialog
    assert(lock:IsManaged(nil) == false, "nil is never managed")
    assert(lock:LockViewer(nil) == false, "LockViewer(nil) is a safe no-op")
end

print("OK: cdm_reanchor_editlock_test")
