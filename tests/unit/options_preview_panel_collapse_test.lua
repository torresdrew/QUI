-- tests/unit/options_preview_panel_collapse_test.lua
-- Run: lua tests/unit/options_preview_panel_collapse_test.lua
-- luacheck: globals CreateFrame UIParent GetCursorPosition hooksecurefunc

local function NewFrame()
    local f = {
        children = {}, scripts = {}, hooks = {}, points = {},
        shown = true, width = 0, height = 0, scale = 1,
        level = 500, movingCalls = 0,
    }
    function f:SetPoint(point, relTo, relPoint, x, y)
        self.points[#self.points + 1] =
            { point = point, relTo = relTo, relPoint = relPoint, x = x, y = y }
    end
    function f:GetPoint(i) local p = self.points[i or 1]
        if not p then return nil end
        return p.point, p.relTo, p.relPoint, p.x, p.y end
    function f:ClearAllPoints() self.points = {} end
    function f:SetAllPoints() end
    function f:SetSize(w, h) self.width, self.height = w, h end
    function f:SetWidth(w) self.width = w end
    function f:SetHeight(h) self.height = h end
    function f:GetWidth() return self.width end
    function f:GetHeight() return self.height end
    function f:SetScale(s) self.scale = s end
    function f:GetScale() return self.scale end
    function f:GetEffectiveScale() return self.scale end
    function f:GetLeft() return self.left end
    function f:GetRight() return self.right end
    function f:GetTop() return self.top end
    function f:Show() self.shown = true
        if self.hooks.OnShow then self.hooks.OnShow(self) end end
    function f:Hide() self.shown = false
        if self.hooks.OnHide then self.hooks.OnHide(self) end end
    function f:SetShown(v) if v then self:Show() else self:Hide() end end
    function f:IsShown() return self.shown end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:GetScript(k) return self.scripts[k] end
    function f:HookScript(k, fn) self.hooks[k] = fn end
    function f:EnableMouse() end
    function f:SetMovable(v) self.movable = v end
    function f:RegisterForDrag() end
    function f:RegisterForClicks() end
    function f:SetClampedToScreen() end
    function f:SetFrameStrata() end
    function f:SetFrameLevel(l) self.level = l end
    function f:GetFrameLevel() return self.level end
    function f:GetParent() return self.parent end
    function f:StartMoving() self.movingCalls = self.movingCalls + 1 end
    function f:StopMovingOrSizing() end
    function f:CreateTexture()
        local t = { SetAllPoints = function() end, SetTexture = function() end,
            SetVertexColor = function() end, SetColorTexture = function() end,
            SetGradient = function() end, SetPoint = function() end,
            Show = function(s) s.shown = true end, Hide = function(s) s.shown = false end }
        t.shown = true
        return t
    end
    return f
end

function CreateFrame(_, _, parent)
    local f = NewFrame()
    f.parent = parent
    if parent and parent.children then
        parent.children[#parent.children + 1] = f
    end
    return f
end

UIParent = NewFrame()
UIParent.left, UIParent.right = 0, 1600
function hooksecurefunc(tbl, name, fn)
    local orig = tbl[name]
    tbl[name] = function(...) orig(...) if fn then fn(...) end end
end
GetCursorPosition = function() return 0, 0 end

local ns = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
}
assert(loadfile("core/settings/full_surface.lua"))("QUI", ns)
local FullSurface = assert(ns.Settings and ns.Settings.FullSurface)

-- A window wide enough that the right dock always fits by default.
local function NewWindow()
    local win = NewFrame()
    win.left, win.right, win.top = 100, 700, 900
    win.width, win.height = 600, 850
    return win
end

local gui = {
    Colors = {},
    CreateLabel = function(_, parent, text)
        local fs = { text = text }
        function fs:SetJustifyH() end
        function fs:SetText(t) self.text = t end
        function fs:SetPoint() end
        fs.parent = parent
        return fs
    end,
}

local function BuildPanel(win, sessionState)
    gui.MainFrame = win
    return FullSurface.CreateDockedPreviewPanel({
        gui = gui, window = win, minWidth = 140,
        controlStripHeight = 0, sessionState = sessionState,
    })
end

local HEADER_H, PAD = 22, 8   -- builder defaults (opts.headerHeight / opts.pad)

local win = NewWindow()
local P = BuildPanel(win, {})
P.Show()

---------------------------------------------------------------------------
-- 1) Resize while expanded applies content dims + chrome
---------------------------------------------------------------------------
P.Resize(300, 400)
assert(P.frame.width == 300 + PAD * 2, "expanded width = content + pad")
assert(P.frame.height == 400 + HEADER_H + PAD * 2, "expanded height = content + chrome")

---------------------------------------------------------------------------
-- 2) Collapse: header-only height, content + strip hidden, width kept
---------------------------------------------------------------------------
P.collapseButton.scripts.OnClick(P.collapseButton)
assert(P.IsCollapsed() == true, "collapsed")
assert(P._contentWrapper.shown == false, "content wrapper hidden")
assert(P.frame.height == HEADER_H + PAD * 2, "header-only height")
assert(P.frame.width == 300 + PAD * 2, "width unchanged")

---------------------------------------------------------------------------
-- 3) Resize while collapsed is deferred, applied on expand
---------------------------------------------------------------------------
P.Resize(500, 600)
assert(P.frame.height == HEADER_H + PAD * 2, "resize deferred while collapsed")
P.collapseButton.scripts.OnClick(P.collapseButton)
assert(P.IsCollapsed() == false, "expanded again")
assert(P._contentWrapper.shown == true, "content wrapper shown")
assert(P.frame.width == 500 + PAD * 2, "deferred width applied on expand")
assert(P.frame.height == 600 + HEADER_H + PAD * 2, "deferred height applied on expand")

---------------------------------------------------------------------------
-- 4) Height cap: taller than window clamps to window height
---------------------------------------------------------------------------
P.Resize(300, 2000)
assert(P.frame.height == win.height, "height capped at window height")

---------------------------------------------------------------------------
-- 5) Collapsed state seeds from sessionState (theme-rebuild carry)
---------------------------------------------------------------------------
local carried = { collapsed = true }
local P2 = BuildPanel(NewWindow(), carried)
assert(P2.IsCollapsed() == true, "collapsed restored from session table")
assert(P2.frame.height == HEADER_H + PAD * 2, "restored panel builds collapsed")

print("options_preview_panel_collapse_test: OK")
