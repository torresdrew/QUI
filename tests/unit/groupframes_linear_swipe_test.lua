-- tests/unit/groupframes_linear_swipe_test.lua
-- Run: lua tests/unit/groupframes_linear_swipe_test.lua
-- Extracts ApplyLinearSwipe from groupframes_aura_render.lua (between the
-- QUI_TEST_EXTRACT sentinels) and verifies it drives the StatusBar from the
-- aura duration object for linear styles, and hides for radial / missing data.

local loadstring = loadstring or load

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a"); f:close()
    return d:gsub("\r\n", "\n")
end

local source = readAll("QUI_GroupFrames/groupframes/groupframes_aura_render.lua")
local s = assert(source:find("-- >>> QUI_TEST_EXTRACT ApplyLinearSwipe", 1, true), "begin sentinel")
local fnStart = assert(source:find("\n", s)) + 1
local nl = assert(source:find("\n%-%- <<< QUI_TEST_EXTRACT ApplyLinearSwipe", fnStart), "end sentinel")
local fnSource = source:sub(fnStart, nl - 1)

-- factory injects the C_UnitAuras stub as an upvalue
local factory = assert(loadstring(
    "return function(_CUA)\nlocal C_UnitAuras = _CUA\n" .. fnSource .. "\nreturn ApplyLinearSwipe\nend",
    "linearSwipe"))()

local function newBar()
    local b = { shown = false }
    function b:SetOrientation(o) self.orient = o end
    function b:SetTimerDuration(dur, interp, dir) self.timer = { dur, interp, dir } end
    function b:Show() self.shown = true end
    function b:Hide() self.shown = false end
    function b:SetFrameLevel(l) self.level = l end
    function b:GetParent() return { GetFrameLevel = function() return 0 end } end
    return b
end
local durSentinel = { __dur = true }
local CUA = { GetAuraDuration = function(unit, id) return durSentinel end }
local ApplyLinearSwipe = factory(CUA)

local aura = { auraInstanceID = 7 }

-- horizontal -> orientation + timer(sentinel, Immediate=0, RemainingTime=1) + shown, true
local b = newBar()
assert(ApplyLinearSwipe(b, "raid1", { swipeStyle = "horizontal" }, aura) == true, "horizontal applies")
assert(b.orient == "HORIZONTAL", "orientation horizontal")
assert(b.timer and b.timer[1] == durSentinel and b.timer[2] == 0 and b.timer[3] == 1, "timer args (sentinel, 0, 1)")
assert(b.shown == true, "shown")

-- vertical -> orientation VERTICAL
local bv = newBar()
ApplyLinearSwipe(bv, "raid1", { swipeStyle = "vertical" }, aura)
assert(bv.orient == "VERTICAL", "orientation vertical")

-- reverseSwipe -> direction 0 (ElapsedTime)
local br = newBar()
ApplyLinearSwipe(br, "raid1", { swipeStyle = "horizontal", reverseSwipe = true }, aura)
assert(br.timer[3] == 0, "reverse -> ElapsedTime(0)")

-- radial -> hidden, false
local b2 = newBar()
assert(ApplyLinearSwipe(b2, "raid1", { swipeStyle = "radial" }, aura) == false, "radial skipped")
assert(b2.shown == false, "radial hidden")

-- no instance id -> hidden, false
local b3 = newBar()
assert(ApplyLinearSwipe(b3, "raid1", { swipeStyle = "horizontal" }, { auraInstanceID = nil }) == false, "no instID skipped")

-- no GetAuraDuration API -> hidden, false
local ApplyLinearSwipeNoAPI = factory({})
local b4 = newBar()
assert(ApplyLinearSwipeNoAPI(b4, "raid1", { swipeStyle = "horizontal" }, aura) == false, "no API skipped")

print("PASS: groupframes_linear_swipe")
