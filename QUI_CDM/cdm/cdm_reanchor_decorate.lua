-- QUI_CDM/cdm/cdm_reanchor_decorate.lua
-- Chrome-only decoration of re-anchored Blizzard CooldownViewer item frames:
-- alpha-0 Blizzard's own border/flash decorations (so QUI chrome shows) while
-- keeping the native Cooldown swipe / charge / count rendering. Idempotent per
-- frame (weak done-set); never writes keys onto the Blizzard frame -- the
-- "decorated" flag lives in this module's external weak table. DI'd: the actual
-- region-hide and QUI-chrome application are injected. Does NOT write alpha or
-- strata/level onto the frame (lift dep removed Task 1; viewers stay alpha-1).
local _, ns = ...

local CDMReanchorDecorate = {}
ns.CDMReanchorDecorate = CDMReanchorDecorate

-- Named Blizzard item-frame regions hidden on re-anchor (Cooldown is deliberately
-- NOT in this list -- its native swipe/count is kept). Names match the 12.x FrameXML
-- CooldownViewer item templates. The anonymous OVERLAY chrome (IconOverlay bevel,
-- OOR shadow) + the rounding mask are not addressable by parentKey and are handled
-- separately by CDMIcons.NeutralizeBlizzardItemChrome (the applyChrome dep).
-- SpellActivationAlert (G6): the native gold proc flipbook. This decorate-pass hide
-- is belt-and-suspenders only -- the alert is lazily re-created + re-shown on every
-- proc, so the load-bearing re-hide rides the ActionButtonSpellAlertManager ShowAlert
-- hook (CDMReanchorProcGlow). hideRegion also Hide()s it (not just SetAlpha).
local HIDDEN_REGIONS = {
    "DebuffBorder",
    "CooldownFlash",
    "SpellActivationAlert",
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
-- Viewers stay alpha-1 (park removed in Task 1); claimed icons inherit visibility
-- from the viewer. Unclaimed icon hiding is deferred to Task 2.
function CDMReanchorDecorate:Decorate(frame, rowConfig)
    local deps = self._deps
    if self._done[frame] then
        -- Re-apply pass. firstChrome=false only marks "not the first decorate of
        -- this frame" for the hideRegion pass above; applyChrome itself re-asserts
        -- ALL chrome (native Cooldown widget writes included) every pass, matching
        -- the re-anchor reference's per-collect-pass cadence. (An earlier theory
        -- blamed per-pass Cooldown-widget writes for the cold-login taint wedge;
        -- that was wrong -- the reference re-applies them per pass, taint-clean.)
        if deps.applyChrome then deps.applyChrome(frame, rowConfig, false) end
        return false
    end
    self._done[frame] = true
    if deps.hideRegion then
        for i = 1, #HIDDEN_REGIONS do
            deps.hideRegion(frame, HIDDEN_REGIONS[i])
        end
    end
    if deps.applyChrome then deps.applyChrome(frame, rowConfig, true) end
    return true
end

function CDMReanchorDecorate:IsDecorated(frame)
    return self._done[frame] == true
end
