local function fail(msg)
    print("FAIL: aura_skin_duration_options_test - " .. msg)
    os.exit(1)
end
local function noop() end

local curvePoints = {}
C_CurveUtil = {
    CreateColorCurve = function()
        local c = { _points = {} }
        c.SetType = function() end
        c.AddPoint = function(self, x, color)
            self._points[#self._points + 1] = { x = x, color = color }
            curvePoints[#curvePoints + 1] = { x = x, color = color }
        end
        return c
    end,
    CreateCurve = function()
        local c = {}
        c.SetType = noop
        c.AddPoint = noop
        return c
    end,
}
C_StringUtil = {
    CreateNumericRuleFormatter = function(a, b, n) return { fmt = { a, b, n } } end,
}
Enum = Enum or {}
Enum.LuaCurveType = { Step = 1 }
Enum.DurationTextBindingProperty = { RemainingPercent = 1 }
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end

local ns = { Addon = {} }
assert(loadfile("core/aura_skin.lua"))("QUI", ns)
local AuraSkin = ns.Addon.AuraSkin or (_G.QUI and _G.QUI.AuraSkin)
if not AuraSkin then fail("AuraSkin must be exported") end
if type(AuraSkin.BuildDurationTextOptions) ~= "function" then
    fail("AuraSkin.BuildDurationTextOptions must be exported")
end
if type(AuraSkin.ResolveDurationTextOptions) ~= "function" then
    fail("AuraSkin.ResolveDurationTextOptions must be exported")
end

local plain = AuraSkin.BuildDurationTextOptions({ duration = {} })
if plain.textFormatter ~= nil then fail("no decimals means no textFormatter") end
if plain.textColor ~= nil then fail("no pandemicColor means no textColor") end

local dec = AuraSkin.BuildDurationTextOptions({ duration = { decimals = true } })
if dec.textFormatter == nil then fail("decimals must produce a textFormatter") end

local baseColor = { 0, 0, 1, 1 }
local pandemicColor = { 1, 0, 0 }
local pan = AuraSkin.BuildDurationTextOptions({
    duration = { color = baseColor, pandemicColor = pandemicColor },
})
if type(pan.textColor) ~= "table" then fail("pandemicColor must produce textColor") end
if pan.textColor.property ~= Enum.DurationTextBindingProperty.RemainingPercent then
    fail("textColor must bind to RemainingPercent")
end
if pan.textColor.curve == nil then fail("textColor must carry a curve") end

local pointAtZero, pointAtThreshold
for _, p in ipairs(pan.textColor.curve._points) do
    if p.x == 0.0 then pointAtZero = p end
    if p.x == 0.3 then pointAtThreshold = p end
end
if not pointAtZero then fail("pandemic curve must have a point at 0.0") end
if not pointAtThreshold then fail("pandemic curve must have a point at 0.3") end
if pointAtZero.color.r ~= pandemicColor[1] or pointAtZero.color.g ~= pandemicColor[2]
    or pointAtZero.color.b ~= pandemicColor[3] then
    fail("point at 0.0 must carry the pandemic colour")
end
if pointAtThreshold.color.r ~= baseColor[1] or pointAtThreshold.color.g ~= baseColor[2]
    or pointAtThreshold.color.b ~= baseColor[3] then
    fail("point at 0.3 must carry the base colour")
end

local trackedButton = {}
local applied = AuraSkin.ResolveDurationTextOptions(trackedButton, {
    duration = { color = baseColor, pandemicColor = pandemicColor },
})
if type(applied.textColor) ~= "table" then fail("applying pandemicColor must produce textColor") end
if not trackedButton._quiPandemicCurved then fail("applying pandemicColor must set the tracking flag") end

local cleared = AuraSkin.ResolveDurationTextOptions(trackedButton, {
    duration = { color = baseColor },
})
if type(cleared.textColor) ~= "table" then
    fail("removing pandemicColor after it was applied must still emit textColor to clear the stale curve")
end
local clearedPoint = cleared.textColor.curve._points[1]
if not clearedPoint or clearedPoint.color.r ~= baseColor[1] or clearedPoint.color.g ~= baseColor[2]
    or clearedPoint.color.b ~= baseColor[3] then
    fail("clearing curve must carry the base colour")
end
if trackedButton._quiPandemicCurved then fail("clearing must reset the tracking flag") end

local untouchedButton = {}
local untouched = AuraSkin.ResolveDurationTextOptions(untouchedButton, {
    duration = { color = baseColor },
})
if untouched.textColor ~= nil then
    fail("a button that never had a pandemic curve must not get one on plain profiles")
end

print("PASS: aura_skin_duration_options_test")
