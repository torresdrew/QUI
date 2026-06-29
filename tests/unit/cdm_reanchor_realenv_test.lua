-- tests/unit/cdm_reanchor_realenv_test.lua
-- Run: lua tests/unit/cdm_reanchor_realenv_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_reanchor_realenv.lua", "cdm_reanchor_realenv.lua")("QUI", ns)
local RE = assert(ns.CDMReanchorRealEnv, "CDMReanchorRealEnv should be exported")
assert(type(RE.BuildEnv) == "function", "BuildEnv is a function")

local placed, clickOverlayCall
local env = RE.BuildEnv({
    CDMContainers = { GetContainer = function(k) return "C:" .. k end },
    CDMSpellData = { BuildSpellListFromOwned = function(_, k) return { "S:" .. k } end },
    CDMIndex = "IDX",
    CDMLayout = { BuildIconLayout = "BL" },
    CDMIcons = {
        OnContainerIconPlaced = function(i, rc) placed = { i, rc } end,
        UpdateSecureClickOverlay = function(shell, entry, viewerType)
            clickOverlayCall = { shell = shell, entry = entry, viewerType = viewerType }
        end,
    },
    CDMIconFactory = { AcquireIcon = function(_, c, e) return { c, e } end },
    core = { PixelRound = function(_, v) return v + 1 end },
    uiParent = "UIP",
    getSettings = "GS",
    resolveAdditional = "RA",
    onMetrics = "OM",
})

assert(env.getContainer("essential") == "C:essential", "getContainer -> CDMContainers.GetContainer")
assert(env.getCurated("buff")[1] == "S:buff", "getCurated -> SpellData:BuildSpellListFromOwned")
assert(env.index == "IDX", "index wired")
assert(env.buildLayout == "BL", "buildLayout -> CDMLayout.BuildIconLayout")
assert(env.uiParent == "UIP", "uiParent wired")
assert(env.getSettings == "GS" and env.resolveAdditional == "RA" and env.onMetrics == "OM", "ctx internals passed through")
assert(env.pixelRound(5) == 6, "pixelRound -> core:PixelRound")
local ai = env.acquireIcon("CC", "EE")
assert(ai[1] == "CC" and ai[2] == "EE", "acquireIcon bound closure -> Factory:AcquireIcon(c,e)")
env.onIconPlaced("ic", "rc")
assert(placed[1] == "ic" and placed[2] == "rc", "onIconPlaced -> CDMIcons.OnContainerIconPlaced(icon,rowConfig)")
env.updateClickOverlay("shell", "entry", "essential")
assert(clickOverlayCall.shell == "shell" and clickOverlayCall.entry == "entry"
    and clickOverlayCall.viewerType == "essential",
    "updateClickOverlay -> CDMIcons.UpdateSecureClickOverlay(shell,entry,viewerType)")

do
    local oldCreateFrame = _G.CreateFrame
    local inCombat = false
    local createdFrames = {}
    local function makeRegion()
        return {
            ClearAllPoints = function(self) self.clearCount = (self.clearCount or 0) + 1 end,
            SetPoint = function(self) self.pointCount = (self.pointCount or 0) + 1 end,
            SetColorTexture = function(self) self.colorCount = (self.colorCount or 0) + 1 end,
            Show = function(self) self.shown = true; self.showCount = (self.showCount or 0) + 1 end,
            Hide = function(self) self.shown = false; self.hideCount = (self.hideCount or 0) + 1 end,
        }
    end
    _G.CreateFrame = function(_frameType, _name, parent)
        local frame = {
            parent = parent,
            shown = false,
            scripts = {},
            CreateTexture = function() return makeRegion() end,
            ClearAllPoints = function(self) self.clearCount = (self.clearCount or 0) + 1 end,
            SetPoint = function(self) self.pointCount = (self.pointCount or 0) + 1 end,
            SetSize = function(self, w, h) self.size = { w, h } end,
            Show = function(self) self.shown = true; self.showCount = (self.showCount or 0) + 1 end,
            Hide = function(self) self.shown = false; self.hideCount = (self.hideCount or 0) + 1 end,
            IsShown = function(self) return self.shown end,
            EnableMouse = function(self, enabled) self.mouseEnabled = enabled end,
            SetMouseClickEnabled = function(self, enabled) self.mouseClickEnabled = enabled end,
            SetMouseMotionEnabled = function(self, enabled) self.mouseMotionEnabled = enabled end,
            SetScript = function(self, name, fn) self.scripts[name] = fn end,
            GetScript = function(self, name) return self.scripts[name] end,
            SetAllPoints = function(self, relativeTo) self.allPoints = relativeTo end,
            SetFrameStrata = function(self, strata) self.strata = strata end,
            GetFrameStrata = function() return "MEDIUM" end,
            SetFrameLevel = function(self, level) self.level = level end,
            GetFrameLevel = function() return 10 end,
        }
        createdFrames[#createdFrames + 1] = frame
        return frame
    end

    local container = { CreateTexture = function() end }
    local shellEnv = RE.BuildEnv({
        CDMContainers = { GetContainer = function() return container end },
        isInCombat = function() return inCombat end,
    })

    shellEnv.beginShellPass(container)
    local first = shellEnv.mintShell({ spellID = 1 }, "essential")
    local second = shellEnv.mintShell({ spellID = 2 }, "essential")
    shellEnv.endShellPass(container)
    assert(first and second and first ~= second, "initial shell pass mints two shells")
    assert((first.hideCount or 0) == 0 and (second.hideCount or 0) == 0,
        "active shells are not hidden at the end of their generation")

    inCombat = true
    shellEnv.beginShellPass(container)
    local reused = shellEnv.mintShell({ spellID = 3 }, "essential")
    local clearCountBeforeCombatPosition = reused.clearCount or 0
    local positionedInCombat = shellEnv.positionShell(reused, container, 1, 2, 40, 40, { borderSize = 0 })
    shellEnv.endShellPass(container)
    assert(reused == first, "next generation reuses the first shell by slot")
    assert(positionedInCombat == false and (reused.clearCount or 0) == clearCountBeforeCombatPosition,
        "combat shell pass reuses existing shells without protected layout writes")
    assert((second.hideCount or 0) == 0,
        "stale surplus shell cleanup is deferred while combat is active")

    inCombat = false
    shellEnv.beginShellPass(container)
    local reusedAgain = shellEnv.mintShell({ spellID = 4 }, "essential")
    shellEnv.endShellPass(container)
    assert(reusedAgain == first, "out-of-combat generation keeps reusing the active shell")
    assert((second.hideCount or 0) == 1,
        "stale surplus shell is hidden once cleanup runs out of combat")

    _G.CreateFrame = oldCreateFrame
end

-- resilient defaults: missing modules -> safe nils, resolveAdditional default empty
local env2 = RE.BuildEnv({})
assert(env2.getContainer("x") == nil, "no container module -> nil")
assert(type(env2.resolveAdditional) == "function" and #env2.resolveAdditional("x") == 0, "default resolveAdditional -> empty")
assert(env2.pixelRound(7) == 7, "no core -> identity pixelRound")

print("OK: cdm_reanchor_realenv_test")
