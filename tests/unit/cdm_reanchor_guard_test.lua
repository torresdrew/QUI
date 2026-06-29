-- tests/unit/cdm_reanchor_guard_test.lua
-- Run: lua tests/unit/cdm_reanchor_guard_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor.lua", "cdm_reanchor.lua")("QUI", ns)
local CDMReanchor = assert(ns.CDMReanchor)

-- hooksecurefunc stub: wraps owner[method] so the hook runs AFTER the original.
local function hooksecurefunc(owner, method, hook)
    local original = owner[method] or function() end
    owner[method] = function(self, ...)
        original(self, ...)
        hook(self, ...)
    end
end

-- A frame whose SetPoint records calls and is hookable.
local container = {}
local setCalls = {}
local frame = {}
frame.ClearAllPoints = function() end
frame.SetPoint = function(self, point, rel, relPoint, x, y)
    setCalls[#setCalls+1] = { point = point, rel = rel, x = x, y = y }
end

-- raw methods delegate to the (hooked) frame methods so the guard's own re-anchor
-- goes through the same SetPoint path, exercising the recursion guard.
local raw = {
    ClearAllPoints = function(f) f:ClearAllPoints() end,
    SetPoint = function(f, p, rel, rp, x, y) f:SetPoint(p, rel, rp, x, y) end,
    SetAlpha = function() end,
}
local bridge = CDMReanchor.New({ raw = raw, securecall = function(fn, ...) return fn(...) end, hooksecurefunc = hooksecurefunc })

-- container stands in for the QUI chrome-shell anchor icon.
bridge:InstallAnchorGuard(frame)
bridge:Overlay(frame, container)
-- Overlay stamps a two-point stretch: TOPLEFT->TL + BOTTOMRIGHT->BR, both onto the anchor.
local afterOverlay = #setCalls
assert(afterOverlay >= 2, "overlay stamps two corner anchors")

-- Blizzard re-points the frame to a foreign relative frame:
local blizzGrid = {}
frame:SetPoint("CENTER", blizzGrid, "CENTER", 0, 0)

-- The guard must have re-forced our two-point overlay (TOPLEFT + BOTTOMRIGHT onto the anchor).
local n = #setCalls
local c1, c2 = setCalls[n - 1], setCalls[n]
assert(c1.rel == container and c2.rel == container,
    "guard re-forces our two-point anchor after a foreign re-point")
local pts = { [c1.point] = true, [c2.point] = true }
assert(pts.TOPLEFT and pts.BOTTOMRIGHT, "guard restores both corner anchors")
assert(c1.x == 0 and c1.y == 0 and c2.x == 0 and c2.y == 0, "two-point overlay uses zero offsets")

-- Our own re-anchor (rel == anchor) must NOT recurse infinitely.
local before = #setCalls
frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
assert(#setCalls - before <= 2, "guard ignores our own anchor calls (no runaway recursion)")

-- Installing twice does not double-hook: one corrective pass = exactly two SetPoint.
local n1 = #setCalls
bridge:InstallAnchorGuard(frame)
frame:SetPoint("LEFT", blizzGrid, "LEFT", 0, 0)
local corrections = 0
for i = n1 + 1, #setCalls do if setCalls[i].rel == container then corrections = corrections + 1 end end
assert(corrections == 2, "guard installs at most once per frame (single two-point correction)")

print("OK: cdm_reanchor_guard_test")
