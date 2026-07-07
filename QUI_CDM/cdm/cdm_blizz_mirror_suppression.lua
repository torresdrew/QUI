local _, ns = ...

---------------------------------------------------------------------------
-- BLIZZARD VIEWER SUPPRESSION (satellite of cdm_blizz_mirror.lua)
--
-- The mirror requires Blizzard's CDM to be running (children populate, durObj
-- feed fires) — but when QUI's CDM is the active engine the user shouldn't
-- see Blizzard's UI competing with QUI's. We suppress visuals via alpha=0
-- + mouse off + a SetAlpha hook + a periodic alpha enforcer that catches
-- Blizzard's internal restoration paths during cooldown activations.
--
-- Suppression is gated on QUI_IsCDMMasterEnabled. When the user disables
-- QUI's CDM, Unsuppress is called and Blizzard's UI returns.
--
-- All operations are taint-safe: SetAlpha is C-side, EnableMouse is
-- C-side, hooksecurefunc is the recommended observation primitive.
--
-- Split out of cdm_blizz_mirror.lua (which sits at Lua's 200-local
-- main-chunk ceiling). Public surface is unchanged: CDMBlizzMirror.Suppress,
-- .Unsuppress, and .SyncSuppressionToMaster. All call sites run at event
-- time, after this file has loaded.
---------------------------------------------------------------------------

local CDMBlizzMirror = ns.CDMBlizzMirror
if not CDMBlizzMirror then return end  -- REQUIRED nil guard

-- catNum (0-3) → Blizzard viewer global name; exported by the parent.
local CATEGORY_GLOBALS = CDMBlizzMirror._CATEGORY_GLOBALS

local function IsCDMMasterEnabled()
    local checker = _G.QUI_IsCDMMasterEnabled
    return type(checker) ~= "function" or checker()
end

local _viewersSuppressed = false
local _viewerAlphaHooked   = {}    -- [viewerName] = true
local _selectionAlphaHooked = {}   -- [viewerName] = true (.Selection overlay)
local _alphaEnforcer = CreateFrame("Frame")
local _alphaEnforcerElapsed = 0

local UnsuppressViewers  -- forward decl

local function HookViewerAlpha(viewer, viewerName)
    if _viewerAlphaHooked[viewerName] then return end
    _viewerAlphaHooked[viewerName] = true
    hooksecurefunc(viewer, "SetAlpha", function(self, alpha)
        if _viewersSuppressed and alpha and alpha > 0 then
            -- Defer to next frame so we don't fight inside Blizzard's
            -- own protected execution chain (cutscene exit, etc.).
            C_Timer.After(0, function()
                if _viewersSuppressed and IsCDMMasterEnabled() and self:GetAlpha() > 0 then
                    self:SetAlpha(0)
                end
            end)
        end
    end)
end

-- viewer.Selection is the Edit Mode selection overlay. It uses
-- IgnoreParentAlpha so the parent viewer's alpha=0 doesn't hide it.
-- During Blizzard Edit Mode it becomes visible (teal border + handles)
-- to let users move/resize the viewer — defeating our suppression for
-- the duration of the edit session. Hook Show/SetAlpha to fight it.
local function HookSelectionAlpha(viewer, viewerName)
    if _selectionAlphaHooked[viewerName] then return end
    if not viewer.Selection then return end
    _selectionAlphaHooked[viewerName] = true
    local sel = viewer.Selection
    hooksecurefunc(sel, "Show", function(self)
        if _viewersSuppressed and IsCDMMasterEnabled() then
            C_Timer.After(0, function()
                if _viewersSuppressed and IsCDMMasterEnabled() then
                    self:SetAlpha(0)
                end
            end)
        end
    end)
    hooksecurefunc(sel, "SetAlpha", function(self, alpha)
        if _viewersSuppressed and alpha and alpha > 0 then
            C_Timer.After(0, function()
                if _viewersSuppressed and IsCDMMasterEnabled() and self:GetAlpha() > 0 then
                    self:SetAlpha(0)
                end
            end)
        end
    end)
end

-- do-block scopes the cache and vararg helper to the functions that need
-- them; they become upvalues instead of chunk locals.
local SetViewerChildrenMouse
do
    -- Last child count seen per viewer; weak keys so dropped viewers don't leak.
    local childCount = setmetatable({}, { __mode = "k" })

    -- Receives viewer:GetChildren() as varargs so GetChildren is invoked
    -- once per pass instead of once per child.
    local function applyChildren(enabled, ...)
        for i = 1, select('#', ...) do
            local child = (select(i, ...))
            if child then
                if child.EnableMouse then child.EnableMouse(child, enabled) end
                if child.SetMouseClickEnabled then child.SetMouseClickEnabled(child, enabled) end
                if child.SetMouseMotionEnabled then child.SetMouseMotionEnabled(child, enabled) end
            end
        end
    end

    SetViewerChildrenMouse = function(viewer, enabled)
        if not viewer or not viewer.GetChildren then return end
        if enabled then
            -- Clear the cache so a later re-suppress runs a full pass.
            childCount[viewer] = nil
            applyChildren(true, viewer:GetChildren())
            return
        end
        -- Skip the pass entirely while the child count is stable; one C call
        -- instead of a full child sweep per enforcer tick.
        local n = viewer.GetNumChildren and viewer:GetNumChildren() or nil
        if n and childCount[viewer] == n then return end
        childCount[viewer] = n
        applyChildren(false, viewer:GetChildren())
    end
end

local function AlphaEnforcerOnUpdate(self, dt)
    _alphaEnforcerElapsed = _alphaEnforcerElapsed + dt
    if _alphaEnforcerElapsed < 0.1 then return end
    _alphaEnforcerElapsed = 0

    if not IsCDMMasterEnabled() then
        self:SetScript("OnUpdate", nil)
        if UnsuppressViewers then UnsuppressViewers() end
        return
    end

    for catNum = 0, 3 do
        local viewer = _G[CATEGORY_GLOBALS[catNum]]
        if viewer then
            if viewer.GetAlpha and viewer:GetAlpha() > 0 then
                viewer.SetAlpha(viewer, 0)
            end
            if viewer.Selection and viewer.Selection.GetAlpha
               and viewer.Selection:GetAlpha() > 0 then
                viewer.Selection.SetAlpha(viewer.Selection, 0)
            end
            -- Blizzard creates children dynamically when cooldowns fire;
            -- catch any new ones that escaped our initial pass.
            SetViewerChildrenMouse(viewer, false)
        end
    end
end

-- Memaudit instrumentation: dynamic OnUpdate, same pattern as CDM_RuntimeTick.
local _AlphaEnforcerOnUpdateImpl = AlphaEnforcerOnUpdate
AlphaEnforcerOnUpdate = function(...)
    local measure = CDMBlizzMirror._measureFn
    if measure then return measure("CDM_AlphaEnforcer", _AlphaEnforcerOnUpdateImpl, ...) end
    return _AlphaEnforcerOnUpdateImpl(...)
end

_alphaEnforcer:SetScript("OnUpdate", nil)

local function SuppressViewers()
    if _viewersSuppressed then return end
    if not IsCDMMasterEnabled() then return end

    for catNum = 0, 3 do
        local viewerName = CATEGORY_GLOBALS[catNum]
        local viewer = _G[viewerName]
        if viewer then
            viewer.SetAlpha(viewer, 0)
            if viewer.EnableMouse then viewer.EnableMouse(viewer, false) end
            if viewer.SetMouseClickEnabled then viewer.SetMouseClickEnabled(viewer, false) end
            if viewer.SetMouseMotionEnabled then viewer.SetMouseMotionEnabled(viewer, false) end
            SetViewerChildrenMouse(viewer, false)
            HookViewerAlpha(viewer, viewerName)
            -- .Selection is the Edit Mode overlay (IgnoreParentAlpha-flagged,
            -- so parent alpha=0 doesn't hide it). Hide + hook independently.
            if viewer.Selection then
                viewer.Selection.SetAlpha(viewer.Selection, 0)
                HookSelectionAlpha(viewer, viewerName)
            end
        end
    end
    _viewersSuppressed = true
    _alphaEnforcerElapsed = 0
    _alphaEnforcer:SetScript("OnUpdate", AlphaEnforcerOnUpdate)
end

UnsuppressViewers = function()
    if not _viewersSuppressed then return end
    _viewersSuppressed = false
    _alphaEnforcer:SetScript("OnUpdate", nil)

    for catNum = 0, 3 do
        local viewer = _G[CATEGORY_GLOBALS[catNum]]
        if viewer then
            viewer.SetAlpha(viewer, 1)
            if viewer.EnableMouse then viewer.EnableMouse(viewer, true) end
            if viewer.SetMouseClickEnabled then viewer.SetMouseClickEnabled(viewer, true) end
            if viewer.SetMouseMotionEnabled then viewer.SetMouseMotionEnabled(viewer, true) end
            -- Selection alpha is normally 0 outside Edit Mode; restoring to 1
            -- here lets Blizzard's Edit Mode show it again. Blizzard sets it
            -- back to 0 when leaving Edit Mode through their own paths.
            if viewer.Selection then
                viewer.Selection.SetAlpha(viewer.Selection, 1)
            end

            -- Restore mouse on existing children too so tooltips work.
            SetViewerChildrenMouse(viewer, true)
        end
    end
end

function CDMBlizzMirror.Suppress() SuppressViewers() end
function CDMBlizzMirror.Unsuppress() UnsuppressViewers() end

function CDMBlizzMirror.SyncSuppressionToMaster()
    if IsCDMMasterEnabled() then
        SuppressViewers()
    else
        UnsuppressViewers()
    end
end
