-- tests/unit/cdm_reanchor_sink_test.lua
-- Run: lua tests/unit/cdm_reanchor_sink_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor.lua", "cdm_reanchor.lua")("QUI", ns)
local CDMReanchor = assert(ns.CDMReanchor)

local calls = {}
local raw = {
    ClearAllPoints = function(f) calls[#calls+1] = { op = "clear", f = f } end,
    SetPoint = function(f, p, rel, rp, x, y)
        calls[#calls+1] = { op = "set", f = f, rel = rel, x = x, y = y }
    end,
    SetAlpha = function(f, a) calls[#calls+1] = { op = "alpha", f = f, a = a } end,
}
local sink = {}
local hideCalled = false
local frame = { Hide = function() hideCalled = true end }

local bridge = CDMReanchor.New({ raw = raw, securecall = function(fn, ...) return fn(...) end, sinkAnchor = sink })
bridge:Overlay(frame, {})
bridge:Sink(frame)

assert(bridge:IsClaimed(frame) == false, "sunk frame is not claimed")
assert(hideCalled == false, "Sink must NEVER call Hide() (pool-rebuild loops)")
local sawAlpha0, sawOffscreen = false, false
for _, c in ipairs(calls) do
    if c.op == "alpha" and c.a == 0 then sawAlpha0 = true end
    if c.op == "set" and c.rel == sink then sawOffscreen = true end
end
assert(sawAlpha0, "Sink sets alpha 0")
assert(sawOffscreen, "Sink re-anchors to the offscreen sink anchor")
local keyCount = 0
for _ in pairs(frame) do keyCount = keyCount + 1 end
assert(keyCount == 1, "Sink must NOT add keys onto the Blizzard frame (only pre-seeded Hide remains)")

print("OK: cdm_reanchor_sink_test")
