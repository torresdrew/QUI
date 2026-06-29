-- tests/unit/cdm_reanchor_park_test.lua
-- Run: lua tests/unit/cdm_reanchor_park_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_park.lua", "cdm_reanchor_park.lua")("QUI", ns)
local P = assert(ns.CDMReanchorPark, "CDMReanchorPark should be exported")
assert(type(P.New) == "function", "New is a function")

-- hooksecurefunc stub: wrap owner[method] so the hook runs after the original
local function hooksecurefunc(owner, method, hook)
    local original = owner[method] or function() end
    owner[method] = function(self, ...) original(self, ...); hook(self, ...) end
end

local alpha = 1
local viewer = {}
viewer.SetAlpha = function(_, a) alpha = a end

local park = P.New({ hooksecurefunc = hooksecurefunc, keys = { "essential" } })

assert(park:Park(viewer) == true, "Park returns true")
assert(park:IsParked(viewer) == true, "viewer marked parked")
assert(alpha == 0, "viewer alpha forced to 0")

-- Blizzard re-shows the viewer (alpha 1) -> the hook re-asserts 0
viewer:SetAlpha(1)
assert(alpha == 0, "SetAlpha hook re-asserts 0 when Blizzard re-shows")

-- our own re-assert (alpha 0) does not recurse infinitely
viewer:SetAlpha(0)
assert(alpha == 0, "no runaway recursion on our own SetAlpha(0)")

-- idempotent: second Park does not double-hook (alpha stays 0, no error)
assert(park:Park(viewer) == true, "second Park ok")

-- ParkAll over getViewer
local v2 = { SetAlpha = function(self, a) self.a = a end }
local park2 = P.New({ hooksecurefunc = hooksecurefunc, keys = { "x" } })
park2:ParkAll(function() return v2 end)
assert(v2.a == 0, "ParkAll parks the resolved viewer")

assert(park:Park(nil) == false, "nil viewer -> false")

print("OK: cdm_reanchor_park_test")
