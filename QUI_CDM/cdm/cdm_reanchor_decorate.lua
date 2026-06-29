-- QUI_CDM/cdm/cdm_reanchor_decorate.lua
-- Chrome-only decoration of re-anchored Blizzard CooldownViewer item frames:
-- alpha-0 Blizzard's own border/flash decorations (so QUI chrome shows) while
-- keeping the native Cooldown swipe / charge / count rendering. Idempotent per
-- frame (weak done-set); never writes keys onto the Blizzard frame -- the
-- "decorated" flag lives in this module's external weak table. DI'd: the actual
-- region-hide and QUI-chrome application are injected. Inert until wired (2b+).
local _, ns = ...

local CDMReanchorDecorate = {}
ns.CDMReanchorDecorate = CDMReanchorDecorate

-- Named Blizzard item-frame regions hidden on re-anchor (Cooldown is deliberately
-- NOT in this list -- its native swipe/count is kept). Names match the 12.x FrameXML
-- CooldownViewer item templates. The anonymous OVERLAY chrome (IconOverlay bevel,
-- OOR shadow) + the rounding mask are not addressable by parentKey and are handled
-- separately by CDMIcons.NeutralizeBlizzardItemChrome (the applyChrome dep).
local HIDDEN_REGIONS = {
    "DebuffBorder",
    "CooldownFlash",
}
CDMReanchorDecorate.HIDDEN_REGIONS = HIDDEN_REGIONS

local InstanceMT = { __index = CDMReanchorDecorate }

function CDMReanchorDecorate.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _done = setmetatable({}, { __mode = "k" }),
    }
    return setmetatable(self, InstanceMT)
end

-- Decorate(frame, rowConfig) -> firstTime:boolean
-- First call: hide each Blizzard decoration region, then apply QUI chrome.
-- Subsequent calls: only re-apply QUI chrome (row settings can change without a
-- re-claim), the region hides are maintained by the host via hooks elsewhere.
function CDMReanchorDecorate:Decorate(frame, rowConfig)
    local deps = self._deps
    -- Every call: lift the frame above the parked viewer's alpha-0. Re-anchored
    -- frames stay CHILDREN of the Blizzard viewer (SetPoint, not SetParent), so
    -- they inherit its alpha; the mirror parks the viewer at alpha 0. lift sets
    -- IgnoreParentAlpha(true) + SetAlpha(1) so the child shows regardless, and a
    -- re-claim after a sink (which set own-alpha 0) restores visibility.
    if deps.lift then deps.lift(frame) end
    if self._done[frame] then
        if deps.applyChrome then deps.applyChrome(frame, rowConfig) end
        return false
    end
    self._done[frame] = true
    if deps.hideRegion then
        for i = 1, #HIDDEN_REGIONS do
            deps.hideRegion(frame, HIDDEN_REGIONS[i])
        end
    end
    if deps.applyChrome then deps.applyChrome(frame, rowConfig) end
    return true
end

function CDMReanchorDecorate:IsDecorated(frame)
    return self._done[frame] == true
end
