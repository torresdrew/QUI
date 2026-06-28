-- tests/unit/chat_tab_overflow_test.lua
-- Run: lua tests/unit/chat_tab_overflow_test.lua
-- Verifies tab-bar overflow handling: tabs that outgrow the bar render as a
-- scrollable visible slice with left/right edge controls, mouse-wheel scrolling,
-- edge accent cues for hidden unread tabs, public activation auto-scrolling a
-- hidden tab into view, resize reset, offset clamp, and unknown bar width
-- disabling overflow.

local function makeFrame(ftype)
    local f = { ftype = ftype, shown = true, points = {} }
    local function noop() end
    f.SetPoint = function(s, ...) s.points[#s.points + 1] = { ... } end
    f.ClearAllPoints = function(s) s.points = {} end
    f.SetSize = noop; f.SetHeight = noop
    f.SetWidth = function(s, w) s.width = w end
    f.GetWidth = function(s) return s.width end -- nil until set
    f.Show = function(s) s.shown = true end
    f.Hide = function(s) s.shown = false end
    f.IsShown = function(s) return s.shown end
    f.EnableMouse = noop
    f.EnableMouseWheel = function(s, enabled) s.mouseWheelEnabled = enabled end
    f.IsMouseWheelEnabled = function(s) return s.mouseWheelEnabled == true end
    f.RegisterForDrag = noop
    f.RegisterForClicks = noop
    f.SetAlpha = noop
    f.SetFrameLevel = noop
    f.GetFrameLevel = function() return 5 end
    f.GetParent = function(s) return s._parent end
    f.SetParent = function(s, p) s._parent = p end
    f.SetScript = function(s, k, v) s["_" .. k] = v end
    f.CreateFontString = function()
        local fs = { points = {},
            SetPoint = function(o, ...) o.points[#o.points + 1] = { ... } end,
            ClearAllPoints = function(o) o.points = {} end,
            SetText = function(o, t) o.text = t end,
            GetStringWidth = function() return 30 end,
            GetFont = function() return "font.ttf", 11, "" end,
            SetFont = noop, SetFontObject = noop,
            SetTextColor = function(o, r, g, b) o.color = { r, g, b } end,
            SetJustifyH = noop }
        return fs
    end
    f.CreateTexture = function()
        local tx = { SetPoint = noop, ClearAllPoints = noop,
            SetAllPoints = noop, SetTexture = noop,
            SetColorTexture = function(o, r, g, b, a) o.color = { r, g, b, a } end,
            SetHeight = noop, SetWidth = noop,
            SetShown = function(o, v) o.visible = v end,
            Hide = function(o) o.visible = false end }
        return tx
    end
    return f
end

local created = {}
function _G.CreateFrame(ftype, name, parent)
    local f = makeFrame(ftype)
    f.name = name
    f._parent = parent
    created[#created + 1] = f
    return f
end
_G.NUM_CHAT_WINDOWS = 10
function _G.GetChatWindowInfo() return "" end
_G.ChatFontNormal = {}
_G.ChatTypeInfo = { WHISPER = { r = 1, g = 0.5, b = 1 } }

local container = makeFrame("Frame")
local setActiveCalls = {}
local activeFilter
local storeCb

-- Four saved tabs (72 px each with the 30 px stub string width) + one
-- conversation appended by the synthesis fallback.
local stubCustomTabs = {
    { name = "Alpha", groups = { A = true } },
    { name = "Beta",  groups = { B = true } },
    { name = "Gamma", groups = { C = true } },
    { name = "Delta", groups = { D = true } },
}
local stubConvs = { { key = "Pal-Realm", name = "Pal", windowID = 1 } }

local function makeFilter(td)
    return function(entry) return td.groups and td.groups[entry.k] or false end
end

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        GetGeneralFont = function() return "font.ttf" end,
        GetGeneralFontOutline = function() return "" end,
    },
    QUI = { Chat = {
        _internals = {
            GetSettings = function() return { enabled = true } end,
            IsChatEnabled = function(s) return s and s.enabled ~= false end,
            GetAccent = function() return { 0.2, 0.8, 0.6, 1 } end,
            GetThemeColors = function() return {
                bg = { 0.05, 0.06, 0.07, 1 },
                bgDark = { 0.01, 0.02, 0.03, 1 },
                border = { 0.3, 0.3, 0.3, 0.4 },
                text = { 1, 1, 1, 1 },
                textDim = { 0.7, 0.7, 0.7, 1 },
            } end,
        },
        DisplayLayer = { GetContainer = function() return container end },
        MessageStore = { OnAppend = function(fn) storeCb = fn end },
        ConversationManager = {
            EachForWindow = function(windowID, fn)
                for i = 1, #stubConvs do
                    if stubConvs[i].windowID == windowID then fn(stubConvs[i]) end
                end
            end,
        },
        TabManager = {
            SetActiveTab = function(_, td)
                activeFilter = td and makeFilter(td) or nil
                setActiveCalls[#setActiveCalls + 1] = { td = td }
            end,
            SetActiveConversation = function() end,
            GetActiveFilter = function() return activeFilter end,
            GetWindowTabs = function() return stubCustomTabs end,
            GetWindowTab = function(_, i) return stubCustomTabs[i] end,
            BuildTabFilter = makeFilter,
            BuildConversationFilter = function(key)
                return function(entry) return entry.conv == key end
            end,
        },
    } },
}

assert(loadfile("QUI_Chat/chat/tab_ui.lua"))("QUI", ns)
local TabUI = ns.QUI.Chat.TabUI

TabUI.EnsureAttached()
local inst = TabUI._instances[1]
local bar = inst.bar
local function buttons() return inst.buttons end

local function visibleLabels()
    local out = {}
    for i = 1, #buttons() do
        local b = buttons()[i]
        if b:IsShown() then out[#out + 1] = b.label.text end
    end
    return table.concat(out, ",")
end

local function shown(label)
    for i = 1, #buttons() do
        local b = buttons()[i]
        if b.label.text == label then return b:IsShown() end
    end
    return false
end

local function click(btn)
    assert(btn and btn._OnClick, "button must have OnClick script")
    btn._OnClick(btn, "LeftButton")
end

local function wheel(delta)
    assert(bar._OnMouseWheel, "bar must have OnMouseWheel script")
    bar._OnMouseWheel(bar, delta)
end

-- (1) Unknown bar width (stub returns nil): overflow disabled, all 5 visible.
assert(#buttons() == 5, "4 saved tabs + 1 conversation expected, got " .. #buttons())
for i = 1, 5 do
    assert(buttons()[i]:IsShown(), "tab " .. i .. " should be visible with unknown bar width")
end
assert(inst.firstHidden == nil, "no overflow with unknown bar width")
assert(not (inst.scrollLeftBtn and inst.scrollLeftBtn:IsShown()), "left scroll control hidden with unknown bar width")
assert(not (inst.scrollRightBtn and inst.scrollRightBtn:IsShown()), "right scroll control hidden with unknown bar width")

-- (2) Narrow bar: the tab row shows a windowed slice with edge controls.
bar.width = 200
bar._OnSizeChanged(bar)
assert(inst.firstHidden == 3, "tabs after visible slice should be hidden, got " .. tostring(inst.firstHidden))
assert(inst.visibleFirst == 1 and inst.visibleLast == 2,
    "initial visible slice should be tabs 1-2, got "
        .. tostring(inst.visibleFirst) .. "-" .. tostring(inst.visibleLast))
assert(buttons()[1]:IsShown() and buttons()[2]:IsShown(), "tabs 1-2 stay visible")
assert(not buttons()[3]:IsShown() and not buttons()[4]:IsShown() and not buttons()[5]:IsShown(),
    "tabs 3-5 hide until scrolled into view")
assert(inst.scrollLeftBtn and inst.scrollLeftBtn:IsShown(), "left scroll control appears")
assert(inst.scrollRightBtn and inst.scrollRightBtn:IsShown(), "right scroll control appears")
assert(inst.scrollLeftBtn.points[1][4] == 0, "left control anchors at row start")
assert(inst.scrollRightBtn.points[1][1] == "BOTTOMRIGHT", "right control anchors at row end")
assert(bar:IsMouseWheelEnabled(), "tab bar enables mouse wheel")
assert(visibleLabels() == "Alpha,Beta", "initial visible labels got " .. visibleLabels())

-- (3) Hidden-unread cue: a message for hidden tab Delta accents the right edge.
storeCb({ k = "D" })
assert(inst.unread[-4] == 1, "hidden tab still counts unread")
local accent = { 0.2, 0.8, 0.6 }
local c = inst.scrollRightBtn.label.color
assert(c and c[1] == accent[1] and c[2] == accent[2] and c[3] == accent[3],
    "right scroll label should use accent while a hidden right tab has unread")

-- (4) Right control click scrolls later tabs into the visible slice.
click(inst.scrollRightBtn)
assert(inst.scrollOffset == 1, "right scroll advances offset to 1, got " .. tostring(inst.scrollOffset))
assert(inst.visibleFirst == 2 and inst.visibleLast == 3,
    "after right scroll visible slice should be tabs 2-3, got "
        .. tostring(inst.visibleFirst) .. "-" .. tostring(inst.visibleLast))
assert(visibleLabels() == "Beta,Gamma", "after right scroll labels got " .. visibleLabels())
assert(shown("Alpha") == false and shown("Delta") == false, "edge tabs hidden after first scroll")

-- (5) Mouse wheel scrolls both directions.
wheel(-1)
assert(inst.scrollOffset == 2, "wheel down advances offset to 2, got " .. tostring(inst.scrollOffset))
assert(visibleLabels() == "Gamma,Delta", "wheel down labels got " .. visibleLabels())
wheel(-1)
assert(inst.scrollOffset == 3, "wheel down reaches final tab window, got " .. tostring(inst.scrollOffset))
assert(visibleLabels() == "Delta,Pal", "tail window labels got " .. visibleLabels())
wheel(1)
assert(inst.scrollOffset == 2, "wheel up leaves the tail window, got " .. tostring(inst.scrollOffset))
assert(visibleLabels() == "Gamma,Delta", "wheel up from tail labels got " .. visibleLabels())
wheel(1)
assert(inst.scrollOffset == 1, "wheel up moves offset back to 1, got " .. tostring(inst.scrollOffset))
assert(visibleLabels() == "Beta,Gamma", "wheel up labels got " .. visibleLabels())

-- (6) Public activation auto-scrolls a hidden tab into view and clears unread.
assert(TabUI.ActivateFrameID(1, 4) == true, "hidden tab activates through public API")
assert(inst.activeID == -4, "Delta active after public activation")
assert(setActiveCalls[#setActiveCalls].td == stubCustomTabs[4], "activation applies the hidden tab data")
assert(inst.unread[-4] == nil, "activation clears unread")
assert(shown("Delta") == true, "active hidden tab scrolled into view")
assert(inst.visibleFirst <= 4 and inst.visibleLast >= 4,
    "visible slice must include active tab 4, got "
        .. tostring(inst.visibleFirst) .. "-" .. tostring(inst.visibleLast))
inst.scrollOffset = 0
TabUI.Rebuild()
assert(shown("Delta") == true, "rebuild keeps active hidden tab visible")
assert(inst.visibleFirst <= 4 and inst.visibleLast >= 4,
    "rebuild visible slice must include active tab 4, got "
        .. tostring(inst.visibleFirst) .. "-" .. tostring(inst.visibleLast))
assert(inst.scrollRightBtn.underline.visible ~= true,
    "right control should not represent hidden active state once active tab is visible")

-- (7) Widening the bar brings everything back and hides controls.
bar.width = 4000
bar._OnSizeChanged(bar)
assert(inst.firstHidden == nil, "wide bar has no overflow")
for i = 1, 5 do
    assert(buttons()[i]:IsShown(), "tab " .. i .. " visible again after resize")
end
assert(not inst.scrollLeftBtn:IsShown(), "left control hides when everything fits")
assert(not inst.scrollRightBtn:IsShown(), "right control hides when everything fits")
assert(inst.scrollOffset == 0, "wide layout resets scroll offset")

-- (8) Narrowing clamps an out-of-range offset and keeps a valid visible slice.
inst.scrollOffset = 99
bar.width = 200
bar._OnSizeChanged(bar)
assert(inst.scrollOffset < 99, "resize clamps out-of-range scroll offset")
assert(inst.visibleFirst and inst.visibleLast and inst.visibleFirst <= inst.visibleLast,
    "narrow layout keeps a valid visible slice")
assert(inst.firstHidden ~= nil, "overflow re-engages")

print("OK chat_tab_overflow_test")
