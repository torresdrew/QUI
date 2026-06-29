-- tests/unit/cdm_reanchor_runtime_position_test.lua
-- Run: lua tests/unit/cdm_reanchor_runtime_position_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_runtime.lua", "cdm_reanchor_runtime.lua")("QUI", ns)
local R = assert(ns.CDMReanchorRuntime)

local guards, overlays, owned, decorated, shells, clickOverlays = {}, {}, {}, {}, {}, {}
local bridge = {
    InstallAnchorGuard = function(_, f) guards[#guards+1] = f end,
    Overlay = function(_, f, anchor) overlays[#overlays+1] = { f = f, anchor = anchor } end,
}
local container = {}
local shellM, blizzFrame, ownedIcon = { s = 1 }, { b = 1 }, { o = 1 }
local rowCfg = { row = 2, size = 40 }     -- rowConfig forwarded to owned placement
local rowCfgR = { row = 1, size = 40 }    -- rowConfig forwarded to shell + decorate
-- matched wrapper: frame is the chrome SHELL; liveFrame is the Blizzard frame.
local entryReanchor = { spellID = 123, viewerType = "essential" }
local wReanchor = { src = entryReanchor, frame = shellM, liveFrame = blizzFrame, reanchored = true }
local wOwned    = { frame = ownedIcon, reanchored = false }
local plan = {
    placements = {
        { icon = wReanchor, x = 5, y = -5, rowConfig = rowCfgR },
        { icon = wOwned,    x = 9, y = -9, rowConfig = rowCfg },
        { icon = { reanchored = false }, x = 0, y = 0 },  -- no frame -> skipped
    },
}

local runtime = R.New({
    bridge = bridge,
    pixelRound = function(v) return v + 100 end,   -- prove pixelRound is applied
    positionShell = function(shell, c, x, y, w, h, rowConfig)
        shells[#shells+1] = { shell = shell, c = c, x = x, y = y, w = w, h = h, rowConfig = rowConfig }
    end,
    positionOwned = function(icon, c, p, rp, x, y, rowConfig) owned[#owned+1] = { icon = icon, c = c, p = p, rp = rp, x = x, y = y, rowConfig = rowConfig } end,
    decorate = function(live, shell, rowConfig) decorated[#decorated+1] = { live = live, shell = shell, rowConfig = rowConfig } end,
    updateClickOverlay = function(shell, entry, viewerType)
        clickOverlays[#clickOverlays+1] = { shell = shell, entry = entry, viewerType = viewerType }
    end,
})

local n = runtime:PositionEntries(container, plan, "essential")
assert(n == 2, "two wrappers with frames positioned, frameless wrapper skipped")

-- re-anchored: the SHELL is positioned in the container at CENTER with pixel-rounded
-- coords + size from rowConfig.size (aspect 1 -> square).
assert(#shells == 1 and shells[1].shell == shellM and shells[1].c == container, "shell positioned in the container")
assert(shells[1].x == 105 and shells[1].y == 95, "pixelRound applied to shell coords")
assert(shells[1].w == 40 and shells[1].h == 40, "shell sized from rowConfig.size")
assert(shells[1].rowConfig == rowCfgR, "shell styled with its rowConfig (border)")

-- the live Blizzard frame is guarded + two-point-overlaid onto its shell, then decorated.
assert(#guards == 1 and guards[1] == blizzFrame, "guard installed for the live Blizzard frame")
assert(#overlays == 1 and overlays[1].f == blizzFrame and overlays[1].anchor == shellM,
    "live frame two-point-overlaid onto its shell (not the container)")
assert(#decorated == 1 and decorated[1].live == blizzFrame and decorated[1].shell == shellM
    and decorated[1].rowConfig == rowCfgR,
    "decorate called once for the live frame, with its shell + rowConfig")
assert(#clickOverlays == 1 and clickOverlays[1].shell == shellM and clickOverlays[1].entry == entryReanchor
    and clickOverlays[1].viewerType == "essential",
    "reanchored shell gets a secure click overlay for the matched entry")

-- owned: positioned via positionOwned, never guarded/overlaid/decorated
assert(#owned == 1 and owned[1].icon == ownedIcon and owned[1].c == container, "owned icon positioned via positionOwned")
assert(owned[1].p == "CENTER" and owned[1].rp == "CENTER" and owned[1].x == 109 and owned[1].y == 91, "owned coords pixel-rounded at CENTER")
assert(owned[1].rowConfig == rowCfg, "placement.rowConfig forwarded to positionOwned (for ConfigureIcon)")

do
    local skippedLiveWrites = 0
    local skippedRuntime = R.New({
        bridge = {
            InstallAnchorGuard = function() skippedLiveWrites = skippedLiveWrites + 1 end,
            Overlay = function() skippedLiveWrites = skippedLiveWrites + 1 end,
        },
        positionShell = function() return false end,
        decorate = function() skippedLiveWrites = skippedLiveWrites + 1 end,
        updateClickOverlay = function() skippedLiveWrites = skippedLiveWrites + 1 end,
    })
    local skipped = skippedRuntime:PositionEntries(container, {
        placements = {
            { icon = wReanchor, x = 0, y = 0, rowConfig = rowCfgR },
        },
    }, "essential")
    assert(skipped == 0 and skippedLiveWrites == 0,
        "declined shell positioning skips live Blizzard overlay/decorate writes")
end

assert(runtime:PositionEntries(container, nil) == 0, "nil plan -> 0")
print("OK: cdm_reanchor_runtime_position_test")
