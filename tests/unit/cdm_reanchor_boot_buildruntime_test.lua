-- tests/unit/cdm_reanchor_boot_buildruntime_test.lua
-- Run: lua tests/unit/cdm_reanchor_boot_buildruntime_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
-- load the real bridge + wiring + runtime + boot into one ns
loadChunk("QUI_CDM/cdm/cdm_reanchor.lua", "cdm_reanchor.lua")("QUI", ns)
loadChunk("QUI_CDM/cdm/cdm_reanchor_wiring.lua", "cdm_reanchor_wiring.lua")("QUI", ns)
loadChunk("QUI_CDM/cdm/cdm_reanchor_runtime.lua", "cdm_reanchor_runtime.lua")("QUI", ns)
loadChunk("QUI_CDM/cdm/cdm_reanchor_boot.lua", "cdm_reanchor_boot.lua")("QUI", ns)
local B = assert(ns.CDMReanchorBoot)
assert(type(B.BuildRuntime) == "function", "BuildRuntime is a function")

-- recorder raw methods so the real bridge's Claim/Sink are observable
local setpoints, alphas = {}, {}
local raw = {
    ClearAllPoints = function() end,
    SetPoint = function(f, p, rel, rp, x, y) setpoints[#setpoints+1] = { f = f, rel = rel, x = x, y = y } end,
    SetAlpha = function(f, a) alphas[#alphas+1] = { f = f, a = a } end,
}

-- a live viewer with two item frames: cd 11 (curated) and cd 99 (not curated)
local fMatch, fDrop = { GetCooldownID = function() return 11 end }, { GetCooldownID = function() return 99 end }
local viewer = { GetItemFrames = function() return { fMatch, fDrop } end }
local container = { SetSize = function() end }

-- curated: one entry resolving (via index) to cooldownID 11
local curatedEntry = { spellID = 500, _assignedRow = 1 }
local ownedAdds = {}
local shell = { SetSize = function() end }   -- the QUI chrome shell for the matched slot
local shellPositioned = false
local clickOverlayCall
local shellLifecycle = {}

local env = {
    CDMReanchor = ns.CDMReanchor,
    CDMReanchorWiring = ns.CDMReanchorWiring,
    CDMReanchorRuntime = ns.CDMReanchorRuntime,
    uiParent = { uiparent = true },
    index = {
        IsUsableID = function(id) return type(id) == "number" and id > 0 end,
        Get = function(id) if id == 500 then return { cooldownID = 11 } end end,
    },
    getContainer = function() return container end,
    getCurated = function() return { curatedEntry } end,
    getSettings = function() return { row1 = { iconCount = 4, iconSize = 40 } } end,
    -- buildLayout stub: echo the wrappers as placements (1 entry here)
    buildLayout = function(settings, icons, opts)
        local p = {}
        for i = 1, #icons do p[i] = { icon = icons[i], x = i, y = -i } end
        return { placements = p, metrics = { iconWidth = 40, totalHeight = 40 } }
    end,
    pixelRound = function(v) return v end,
    acquireIcon = function(c, e) local o = { owned = e }; ownedAdds[#ownedAdds+1] = o; return o end,
    resolveAdditional = function() return {} end,
    -- chrome-shell deps: matched curated entries mint a shell, get positioned in the
    -- container, and the live Blizzard frame is two-point-overlaid onto the shell.
    mintShell = function() return shell end,
    positionShell = function() shellPositioned = true end,
    updateClickOverlay = function(shellArg, entryArg, viewerTypeArg)
        clickOverlayCall = { shell = shellArg, entry = entryArg, viewerType = viewerTypeArg }
    end,
    beginShellPass = function(c) shellLifecycle[#shellLifecycle + 1] = { "begin", c } end,
    endShellPass = function(c) shellLifecycle[#shellLifecycle + 1] = { "end", c } end,
    resetShells = function() error("BuildRuntime should pass begin/end shell hooks") end,
    -- inject recorder raw into the bridge via a wrapper: BuildRuntime uses CDMReanchor.New;
    -- we override by passing our own bridge through a shim below instead.
}

-- Shim CDMReanchor so the bridge uses our recorder raw + direct securecall
env.CDMReanchor = {
    New = function(opts)
        opts = opts or {}
        opts.raw = raw
        opts.securecall = function(fn, ...) return fn(...) end
        opts.hooksecurefunc = function() end
        return ns.CDMReanchor.New(opts)
    end,
}

-- need GetViewerForKey to return our viewer: inject via wiring shim
env.CDMReanchorWiring = {
    New = function(opts)
        local w = ns.CDMReanchorWiring.New(opts)
        w.GetViewerForKey = function() return viewer end
        return w
    end,
}

local facade = B.BuildRuntime(env)
assert(type(facade) == "table" and facade.bridge and facade.wiring and facade.runtime, "facade has bridge/wiring/runtime")
assert(type(facade.RefreshBuiltin) == "function", "facade:RefreshBuiltin exists")

local count = facade:RefreshBuiltin("essential")
assert(count == 1, "one curated entry assembled (matched)")
-- the matched frame (cd 11) is two-point-overlaid onto its shell; the other (cd 99) sunk (alpha 0)
local overlaidMatch, sunkDrop = false, false
for _, s in ipairs(setpoints) do if s.f == fMatch and s.rel == shell then overlaidMatch = true end end
for _, a in ipairs(alphas) do if a.f == fDrop and a.a == 0 then sunkDrop = true end end
assert(shellPositioned, "matched slot minted + positioned a QUI chrome shell")
assert(clickOverlayCall and clickOverlayCall.shell == shell and clickOverlayCall.entry == curatedEntry
    and clickOverlayCall.viewerType == "essential",
    "matched shell receives secure click overlay setup through boot deps")
assert(#shellLifecycle == 2 and shellLifecycle[1][1] == "begin" and shellLifecycle[1][2] == container
    and shellLifecycle[2][1] == "end" and shellLifecycle[2][2] == container,
    "boot wires shell generation lifecycle through to runtime")
assert(overlaidMatch, "curated-matched Blizzard frame two-point-overlaid onto its shell")
assert(sunkDrop, "non-curated Blizzard frame sunk (alpha 0)")

print("OK: cdm_reanchor_boot_buildruntime_test")
