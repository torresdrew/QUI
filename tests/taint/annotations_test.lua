-- tests/taint/annotations_test.lua
local Annotations = dofile("tests/taint/annotations.lua")

local function assert_eq(a, e, msg)
    if a ~= e then error((msg or "") .. ": expected " .. tostring(e) ..
        ", got " .. tostring(a), 2) end
end

local source = [[
local x = 1
local y = x + 1  -- @secret-safe: trailing-style on line 2
-- @secret-safe: applies-to-line-4
local z = x + 2
local bad = x + 3  -- @secret-safe:
]]

local annots = Annotations.scan(source)
assert_eq(annots[2].reason, "trailing-style on line 2",
    "line 2 has trailing annotation")
assert_eq(annots[4].reason, "applies-to-line-4",
    "line 4 inherits annotation from preceding comment line 3")
assert_eq(annots[5].reason, nil, "line 5 has empty reason")
assert(annots[5].emptyReason, "line 5 emptyReason flagged")

print("annotations test passed")
