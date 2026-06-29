-- tests/unit/cdm_reanchor_runtime_refresh_test.lua
-- Run: lua tests/unit/cdm_reanchor_runtime_refresh_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_runtime.lua", "cdm_reanchor_runtime.lua")("QUI", ns)
local R = assert(ns.CDMReanchorRuntime)

local fMatch, fDrop, fSecret = { id = 1 }, { id = 9 }, { id = 0 }
local ownedIcon = { o = 1 }
local container, viewer, settings = { c = 1 }, { v = 1 }, { s = 1 }

local overlays, sinks, owned, shells = {}, {}, {}, {}
local shellM = { s = 1 }
local bridge = {
    InstallAnchorGuard = function() end,
    Overlay = function(_, f, anchor) overlays[#overlays+1] = { live = f, shell = anchor } end,
    Sink = function(_, f) sinks[#sinks+1] = f end,
}
-- wiring stub: BuildFrameMap returns (map, items) with all three frames as items;
-- MatchCuratedToFrames matches eMatched->fMatch, claims fMatch.
local eMatched, eFrameless = { name = "m", _assignedRow = 1 }, { name = "f", _assignedRow = 2 }
local wiring = {
    GetViewerForKey = function() return viewer end,
    BuildFrameMap = function() return { [1] = fMatch }, { fMatch, fDrop, fSecret } end,
    MatchCuratedToFrames = function() return { { entry = eMatched, frame = fMatch } }, { eFrameless }, { [fMatch] = true } end,
}

local sizedWith
local shellLifecycle = {}
local runtime = R.New({
    bridge = bridge, wiring = wiring,
    getContainer = function() return container end,
    getSettings = function() return settings end,
    getCurated = function() return { eMatched, eFrameless } end,
    getAdditional = function() return {} end,
    mintOwned = function() return ownedIcon end,
    mintShell = function() return shellM end,
    positionOwned = function(icon) owned[#owned+1] = icon end,
    positionShell = function(shell) shells[#shells+1] = shell end,
    decorate = function() end,
    buildLayout = function(s, icons, opts)
        -- echo wrappers as placements in order
        local p = {}
        for i = 1, #icons do p[i] = { icon = icons[i], x = i, y = -i } end
        return { placements = p, metrics = { iconWidth = 40, totalHeight = 40 } }
    end,
    applySize = function(c, m) sizedWith = { c = c, m = m } end,
    beginShellPass = function(c) shellLifecycle[#shellLifecycle + 1] = { "begin", c } end,
    endShellPass = function(c) shellLifecycle[#shellLifecycle + 1] = { "end", c } end,
    resetShells = function() error("runtime should use shell pass reuse, not resetShells") end,
})

local count = runtime:RefreshContainer("essential")

assert(count == 2, "matched + frameless = 2 entries")
assert(#overlays == 1 and overlays[1].live == fMatch and overlays[1].shell == shellM,
    "the matched live frame is two-point-overlaid onto its shell")
assert(#shells == 1 and shells[1] == shellM, "the matched shell is positioned in the container")
assert(#owned == 1 and owned[1] == ownedIcon, "the frameless entry positioned as an owned icon")
-- sink: every enumerated item not claimed -> fDrop and fSecret (NOT fMatch)
assert(#sinks == 2, "two unmatched items sunk")
local sset = {}; for _, f in ipairs(sinks) do sset[f] = true end
assert(sset[fDrop] and sset[fSecret] and not sset[fMatch], "unmatched (incl secret) sunk, matched not sunk")
assert(sizedWith and sizedWith.c == container and sizedWith.m.iconWidth == 40, "container sized from plan.metrics")
assert(#shellLifecycle == 2 and shellLifecycle[1][1] == "begin" and shellLifecycle[1][2] == container
    and shellLifecycle[2][1] == "end" and shellLifecycle[2][2] == container,
    "refresh wraps shell acquisition in a generation pass without hiding the pool up front")

-- Per-frame feature registry: only the re-anchored frame is recorded, mapped to
-- its curated entry. Owned synthetic icons (frameless) are NOT in this registry
-- (they're real QUI-container children, reachable via GetChildren).
local reFrames = runtime:GetReanchoredFrames("essential")
assert(type(reFrames) == "table" and #reFrames == 1 and reFrames[1] == fMatch,
    "registry lists exactly the re-anchored frame")
assert(runtime:GetEntryForFrame(fMatch) == eMatched, "frame resolves to its curated entry")
assert(runtime:GetEntryForFrame(ownedIcon) == nil, "owned icon is not in the re-anchor registry")
assert(runtime:GetEntryForFrame(nil) == nil, "nil frame -> nil entry (no error)")
-- Registry is rebuilt per refresh (not appended): a second pass yields one entry.
runtime:RefreshContainer("essential")
assert(#runtime:GetReanchoredFrames("essential") == 1, "registry rebuilt, not accumulated")

-- If a previously re-anchored live frame stops matching, its feature mapping is
-- cleared. Otherwise keybind / glow logic can still treat a sunk Blizzard frame
-- as owned by the old curated entry.
wiring.MatchCuratedToFrames = function()
    return {}, { eMatched }, {}
end
runtime:RefreshContainer("essential")
assert(#runtime:GetReanchoredFrames("essential") == 0, "registry clears when no live frames match")
assert(runtime:GetEntryForFrame(fMatch) == nil, "old live frame mapping cleared when claim is lost")

-- bail cases (all three: missing viewer / container / settings)
assert(R.New({ bridge = bridge, wiring = { GetViewerForKey = function() return nil end } }):RefreshContainer("x") == 0, "no viewer -> 0")
assert(R.New({ bridge = bridge, wiring = { GetViewerForKey = function() return viewer end },
    getContainer = function() return nil end, getSettings = function() return settings end }):RefreshContainer("x") == 0, "no container -> 0")
assert(R.New({ bridge = bridge, wiring = { GetViewerForKey = function() return viewer end },
    getContainer = function() return container end, getSettings = function() return nil end }):RefreshContainer("x") == 0, "no settings -> 0")

-- Cooldown containers are presentation buckets in QUI, not a forced 1:1 mirror
-- of Blizzard's Essential vs Utility buckets. A QUI Essential entry must be able
-- to claim a live Blizzard frame from Utility when the user placed it there in
-- Blizzard CDM.
do
    local essentialViewer, utilityViewer = { v = "essential" }, { v = "utility" }
    local utilityFrame = { id = "utility-frame" }
    local crossEntry = { name = "cross", source = "blizzardCDM" }
    local crossOverlays, crossSinks, receivedViewers = {}, {}, nil
    local crossBridge = {
        InstallAnchorGuard = function() end,
        Overlay = function(_, f, anchor) crossOverlays[#crossOverlays + 1] = { live = f, shell = anchor } end,
        Sink = function(_, f) crossSinks[#crossSinks + 1] = f end,
    }
    local crossWiring = {
        GetViewerForKey = function() return essentialViewer end,
        GetViewersForKey = function() return { essentialViewer, utilityViewer } end,
        BuildFrameMap = function() return {}, {} end,
        BuildFrameMapForViewers = function(_, viewers)
            receivedViewers = viewers
            return { [77] = utilityFrame }, { utilityFrame }
        end,
        MatchCuratedToFrames = function(_, curated, frameMap)
            local frame = frameMap[77]
            if frame then
                return { { entry = curated[1], frame = frame } }, {}, { [frame] = true }
            end
            return {}, { curated[1] }, {}
        end,
    }
    local crossRuntime = R.New({
        bridge = crossBridge,
        wiring = crossWiring,
        getContainer = function() return container end,
        getSettings = function() return settings end,
        getCurated = function() return { crossEntry } end,
        getAdditional = function() return {} end,
        mintShell = function() return shellM end,
        buildLayout = function(_, icons)
            local p = {}
            for i = 1, #icons do p[i] = { icon = icons[i], x = i, y = i } end
            return { placements = p, metrics = {} }
        end,
        positionShell = function() end,
        decorate = function() end,
    })

    crossRuntime:RefreshContainer("essential")
    assert(receivedViewers and receivedViewers[1] == essentialViewer and receivedViewers[2] == utilityViewer,
        "essential refresh must enumerate both cooldown viewers")
    assert(#crossOverlays == 1 and crossOverlays[1].live == utilityFrame,
        "QUI Essential must claim the live Blizzard Utility frame")
    assert(#crossSinks == 0, "claimed cross-viewer frame must not be sunk")
end

-- Once a frame is claimed by one QUI cooldown container, a refresh of the sibling
-- container must not sink that same Blizzard frame.
do
    local sharedFrame = { id = "shared" }
    local sharedEntry = { name = "shared", source = "blizzardCDM" }
    local sharedSinks = {}
    local sharedBridge = {
        InstallAnchorGuard = function() end,
        Overlay = function() end,
        Sink = function(_, f) sharedSinks[#sharedSinks + 1] = f end,
    }
    local sharedWiring = {
        GetViewerForKey = function() return viewer end,
        GetViewersForKey = function() return { viewer } end,
        BuildFrameMapForViewers = function() return { [42] = sharedFrame }, { sharedFrame } end,
        MatchCuratedToFrames = function(_, curated, frameMap, key)
            if key == "essential" then
                return { { entry = curated[1], frame = frameMap[42] } }, {}, { [frameMap[42]] = true }
            end
            return {}, {}, {}
        end,
    }
    local sharedRuntime = R.New({
        bridge = sharedBridge,
        wiring = sharedWiring,
        getContainer = function() return container end,
        getSettings = function() return settings end,
        getCurated = function(key)
            if key == "essential" then return { sharedEntry } end
            return {}
        end,
        getAdditional = function() return {} end,
        mintShell = function() return shellM end,
        buildLayout = function(_, icons)
            local p = {}
            for i = 1, #icons do p[i] = { icon = icons[i], x = i, y = i } end
            return { placements = p, metrics = {} }
        end,
        positionShell = function() end,
        decorate = function() end,
    })

    sharedRuntime:RefreshContainer("essential")
    sharedRuntime:RefreshContainer("utility")
    assert(#sharedSinks == 0,
        "sibling refresh must not sink a Blizzard frame already claimed by another QUI container")
end

print("OK: cdm_reanchor_runtime_refresh_test")
