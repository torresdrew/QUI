-- tests/unit/cdm_reanchor_runtime_assemble_test.lua
-- Run: lua tests/unit/cdm_reanchor_runtime_assemble_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_runtime.lua", "cdm_reanchor_runtime.lua")("QUI", ns)
local R = assert(ns.CDMReanchorRuntime)

-- stub wiring: MatchCuratedToFrames returns a fixed split
local fMatch = { f = "blizz" }
local eMatched  = { name = "matched",  _assignedRow = 1 }
local eFrameless= { name = "frameless",_assignedRow = 2 }
local eAdd      = { name = "additional",_assignedRow = 3 }
local wiring = {
    MatchCuratedToFrames = function(_, curated, frameMap)
        -- eMatched -> fMatch; eFrameless -> none
        return { { entry = eMatched, frame = fMatch } }, { eFrameless }, { [fMatch] = true }
    end,
}

local mintCalls, shellCalls = {}, {}
local ownedIconF, ownedIconA, shellM = { o = "F" }, { o = "A" }, { s = "M" }
local runtime = R.New({
    bridge = {}, wiring = wiring,
    getCurated = function() return { eMatched, eFrameless } end,
    getAdditional = function() return { eAdd } end,
    mintOwned = function(entry)
        mintCalls[#mintCalls+1] = entry
        if entry == eFrameless then return ownedIconF end
        if entry == eAdd then return ownedIconA end
        return nil
    end,
    mintShell = function(entry) shellCalls[#shellCalls+1] = entry; return shellM end,
})

local entries, claimed = runtime:AssembleEntries("essential", {})

assert(#entries == 3, "matched + frameless + additional assembled")
-- matched -> a QUI chrome shell (entries[].frame) carrying the live Blizzard frame
-- (entries[].liveFrame); never the bare Blizzard frame as the layout icon.
assert(entries[1].reanchored == true and entries[1].frame == shellM
    and entries[1].liveFrame == fMatch and entries[1].src == eMatched,
    "matched -> chrome shell + live blizz frame")
assert(entries[2].reanchored == false and entries[2].frame == ownedIconF and entries[2].src == eFrameless, "frameless is an owned icon")
assert(entries[3].reanchored == false and entries[3].frame == ownedIconA and entries[3].src == eAdd, "additional is an owned icon")
assert(entries[1]._assignedRow == 1 and entries[2]._assignedRow == 2 and entries[3]._assignedRow == 3, "row carried from source entry")
assert(claimed[fMatch] == true, "claimedFrames passed through from match")
assert(shellCalls[1] == eMatched and #shellCalls == 1, "mintShell called once, for the matched entry")
assert(mintCalls[1] == eFrameless and mintCalls[2] == eAdd, "mintOwned called for frameless then additional, not for matched")

-- Curated order is the composer order. A frameless/manual entry between two
-- native matches must stay in that saved slot instead of being pushed after
-- all matched Blizzard frames.
local eFirstNative = { name = "first-native", _assignedRow = 1 }
local eMiddleOwned = { name = "middle-owned", _assignedRow = 1 }
local eLastNative = { name = "last-native", _assignedRow = 1 }
local fFirst, fLast = { f = "first" }, { f = "last" }
local orderedWiring = {
    MatchCuratedToFrames = function()
        return {
            { entry = eFirstNative, frame = fFirst },
            { entry = eLastNative, frame = fLast },
        }, {
            eMiddleOwned,
        }, {
            [fFirst] = true,
            [fLast] = true,
        }
    end,
}
local orderedRuntime = R.New({
    bridge = {},
    wiring = orderedWiring,
    getCurated = function() return { eFirstNative, eMiddleOwned, eLastNative } end,
    getAdditional = function() return {} end,
    mintOwned = function(entry) return { owned = entry.name } end,
    mintShell = function(entry) return { shell = entry.name } end,
})
local orderedEntries = orderedRuntime:AssembleEntries("essential", {})
assert(#orderedEntries == 3, "ordered native/owned entries assembled")
assert(orderedEntries[1].src == eFirstNative
    and orderedEntries[2].src == eMiddleOwned
    and orderedEntries[3].src == eLastNative,
    "reanchor assembly must preserve composer order across native/owned boundaries")

-- mintOwned returning nil drops that owned entry; matched (shell) still present
local runtime2 = R.New({
    bridge = {}, wiring = wiring,
    getCurated = function() return { eMatched, eFrameless } end,
    getAdditional = function() return {} end,
    mintOwned = function() return nil end,
    mintShell = function() return shellM end,
})
local entries2 = runtime2:AssembleEntries("essential", {})
assert(#entries2 == 1 and entries2[1].src == eMatched and entries2[1].liveFrame == fMatch,
    "owned entry dropped when mintOwned returns nil; matched shell still present")

-- mintShell returning nil drops the matched entry (never re-anchor a bare frame)
local runtime3 = R.New({
    bridge = {}, wiring = wiring,
    getCurated = function() return { eMatched, eFrameless } end,
    getAdditional = function() return {} end,
    mintOwned = function() return ownedIconF end,
    mintShell = function() return nil end,
})
local entries3 = runtime3:AssembleEntries("essential", {})
assert(#entries3 == 1 and entries3[1].src == eFrameless,
    "matched dropped when mintShell returns nil; frameless owned still present")

print("OK: cdm_reanchor_runtime_assemble_test")
