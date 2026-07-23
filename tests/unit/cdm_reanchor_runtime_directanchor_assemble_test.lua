-- tests/unit/cdm_reanchor_runtime_directanchor_assemble_test.lua
-- Run: lua tests/unit/cdm_reanchor_runtime_directanchor_assemble_test.lua
-- Big-bang native model: matched Essential/Utility/BuffIcon entries all use
-- the live Blizzard frame as the icon. trackedBar is intentionally excluded:
-- it renders through owned CDMBars frames and must never direct-anchor live
-- Blizzard BuffBar frames.
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_runtime.lua", "cdm_reanchor_runtime.lua")("QUI", ns)
local R = assert(ns.CDMReanchorRuntime)

local fMatch = { f = "blizz" }
local eMatched = { name = "matched", _assignedRow = 1 }
local wiring = {
    MatchCuratedToFrames = function()
        return { { entry = eMatched, frame = fMatch } }, {}, { [fMatch] = true }
    end,
}

local function newRuntime(shellCalls)
    return R.New({
        bridge = {}, wiring = wiring,
        getCurated = function() return { eMatched } end,
        getAdditional = function() return {} end,
        mintOwned = function() return nil end,
        mintShell = function(entry) shellCalls[#shellCalls + 1] = entry; return { s = "shell" } end,
    })
end

for _, key in ipairs({ "buff", "essential", "utility" }) do
    local shellCalls = {}
    local entries = newRuntime(shellCalls):AssembleEntries(key, {})
    assert(#entries == 1, key .. " matched entry assembled")
    local w = entries[1]
    assert(w.directAnchor == true, key .. " match is a direct-anchor wrapper")
    assert(w.reanchored == true, key .. " direct-anchor wrapper is still reanchored")
    assert(w.frame == fMatch and w.liveFrame == fMatch,
        key .. " direct-anchor frame == liveFrame == the live Blizzard frame")
    assert(w.src == eMatched and w._assignedRow == 1,
        key .. " src + row carried from source entry")
    assert(#shellCalls == 0, key .. " match does NOT mint a per-slot shell")
end

-- Blizzard-CDM BuffIcon entries are native-only. When Blizzard has not produced
-- a live child frame yet, QUI renders nothing and waits for the native repair /
-- reanchor path instead of synthesizing an owned replacement icon.
do
    local nativeBuffEntry = {
        name = "Configured Buff",
        source = "blizzardCDM",
        _assignedRow = 3,
    }
    local ownedIcon = { f = "owned-buff-icon" }
    local minted = {}
    local runtime = R.New({
        bridge = {},
        wiring = {
            MatchCuratedToFrames = function()
                return {}, { nativeBuffEntry }, {}
            end,
        },
        getCurated = function() return { nativeBuffEntry } end,
        getAdditional = function() return {} end,
        mintOwned = function(entry, key)
            minted[#minted + 1] = { entry = entry, key = key }
            return ownedIcon
        end,
        mintShell = function() error("frameless buff fallback must not mint a shell") end,
    })

    local entries = runtime:AssembleEntries("buff", {})
    assert(#entries == 0, "buff frameless Blizzard-CDM entry does not mint an owned fallback")
    assert(#minted == 0, "buff frameless Blizzard-CDM miss must not call mintOwned")

    entries = runtime:AssembleEntries("essential", {})
    assert(#entries == 0, "essential frameless Blizzard-CDM entry still does not mint fallback")
    assert(#minted == 0, "essential frameless miss must not mint an owned fallback")
end

-- Active-only BuffIcon must not treat a missing native frame as active. Cold login
-- can classify configured buff entries as frameless before Blizzard creates live
-- BuffIcon children; those unknown entries stay hidden unless QUI layout mode
-- explicitly needs a placeholder surface.
do
    local nativeBuffEntry = {
        name = "Configured Inactive Buff",
        source = "blizzardCDM",
    }
    local minted = 0
    local function makeRuntime(editing)
        return R.New({
            bridge = {},
            wiring = {
                MatchCuratedToFrames = function()
                    return {}, { nativeBuffEntry }, {}
                end,
            },
            getCurated = function() return { nativeBuffEntry } end,
            getAdditional = function() return {} end,
            mintOwned = function()
                minted = minted + 1
                return { f = "owned-buff-icon" }
            end,
            isEditMode = function() return editing == true end,
        })
    end

    local entries = makeRuntime(false):AssembleEntries("buff", {}, { iconDisplayMode = "active" })
    assert(#entries == 0, "active-only buff frameless native entry must stay hidden without a live active frame")
    assert(minted == 0, "active-only buff frameless native entry must not mint an owned fallback")

    entries = makeRuntime(true):AssembleEntries("buff", {}, { iconDisplayMode = "active" })
    assert(#entries == 1, "edit mode still shows active-only buff frameless entries for full layout bounds")
    assert(minted == 1, "edit-mode active-only buff frameless entry mints once")
end

-- trackedBar: no re-anchor assembly. The owned CDMBars path renders the surface;
-- this guard prevents accidental live BuffBar anchoring/decorating.
do
    local shellCalls = {}
    local entries = newRuntime(shellCalls):AssembleEntries("trackedBar", {})
    assert(#entries == 0, "trackedBar is not assembled by the re-anchor runtime")
    assert(#shellCalls == 0, "trackedBar match does NOT mint a per-slot shell")
end

print("OK: cdm_reanchor_runtime_directanchor_assemble_test")
