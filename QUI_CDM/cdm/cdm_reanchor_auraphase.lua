-- QUI_CDM/cdm/cdm_reanchor_auraphase.lua
-- QUI owns the swipe COLOUR on re-anchored Blizzard CooldownViewer cooldown
-- frames via a SetSwipeColor post-hook -> reassertColor (non-secret), plus ONE
-- deliberate timing override: when showCooldownIconAuraPhase is OFF, the
-- SetCooldown post-hook re-binds the widget from the aura display to the
-- spell's real cooldown via an opaque duration object (see boot's
-- restyleAuraPhaseAsCooldown). QUI never reads secret cooldown state.
local _, ns = ...

local CDMReanchorAuraPhase = {}
ns.CDMReanchorAuraPhase = CDMReanchorAuraPhase

local InstanceMT = { __index = CDMReanchorAuraPhase }

function CDMReanchorAuraPhase.New(deps)
    deps = deps or {}
    return setmetatable({
        _deps = deps,
        _swipeHooked = setmetatable({}, { __mode = "k" }),
        _reentry = setmetatable({}, { __mode = "k" }),
        _edgeHooked = setmetatable({}, { __mode = "k" }),
        _edgeReentry = setmetatable({}, { __mode = "k" }),
        _timingHooked = setmetatable({}, { __mode = "k" }),
        _timingReentry = setmetatable({}, { __mode = "k" }),
        _desatHooked = setmetatable({}, { __mode = "k" }),
        _desatReentry = setmetatable({}, { __mode = "k" }),
        -- Container key per hooked frame. BuffIcon items never set the
        -- cooldownUseAuraDisplayTime FIELD (they refresh via their own
        -- RefreshCooldownInfo, not RefreshSpellCooldownInfo), so the reassert
        -- callbacks need the container key to classify them as aura displays.
        _keyByFrame = setmetatable({}, { __mode = "k" }),
    }, InstanceMT)
end

-- Re-assert the QUI swipe colour whenever Blizzard re-colours the cooldown
-- widget. Re-entry guard keeps deps.reassertColor's own SetSwipeColor from
-- recursing into this handler.
function CDMReanchorAuraPhase:OnSwipeColor(frame, cd)
    if not cd or self._reentry[cd] then return end
    self._reentry[cd] = true
    local deps = self._deps
    if deps.reassertColor then ns.SafeCall("bulkhead", deps.reassertColor, frame, cd, self._keyByFrame[frame]) end
    self._reentry[cd] = false
end

-- Re-assert AFTER Blizzard re-binds the widget timing. RefreshSpellCooldownInfo
-- orders SetSwipeColor (:1166) BEFORE SetUseAuraDisplayTime + CooldownFrame_Set ->
-- SetCooldown (:1168-1169), so a reassert fired only from the colour hook is
-- overwritten three lines later when the aura-phase-off restyle re-binds timing.
-- This SetCooldown post-hook is the LAST Lua-visible write in the refresh
-- sequence (only Pause/Resume follow, which never re-time), so the restyle in
-- deps.reassertColor sticks. Hooked args (start/duration) can be SECRET aura
-- times -- the handler ignores them entirely. Both guards are set so the
-- reassert's own SetSwipeColor can't bounce through the colour hook.
function CDMReanchorAuraPhase:OnCooldownSet(frame, cd)
    if not cd or self._timingReentry[cd] or self._reentry[cd] then return end
    self._timingReentry[cd] = true
    self._reentry[cd] = true
    local deps = self._deps
    if deps.reassertColor then ns.SafeCall("bulkhead", deps.reassertColor, frame, cd, self._keyByFrame[frame]) end
    self._reentry[cd] = false
    self._timingReentry[cd] = false
end

-- Re-assert icon saturation AFTER Blizzard writes it. RefreshData orders
-- RefreshSpellCooldownInfo (:1269, fires the SetCooldown hook) BEFORE
-- RefreshIconDesaturation (:1271 -> Icon:SetDesaturated(false) in aura phase),
-- so a desat write from the timing hook is stomped two calls later. This
-- SetDesaturated post-hook fires at the stomp itself; deps.reassertDesat then
-- re-drives the aura-phase-off saturation (duration-object curve, no secret
-- reads). Guarded so the reassert's own SetDesaturated fallback can't recurse.
function CDMReanchorAuraPhase:OnDesaturated(frame, tex)
    if not tex or self._desatReentry[tex] then return end
    self._desatReentry[tex] = true
    local deps = self._deps
    if deps.reassertDesat then ns.SafeCall("bulkhead", deps.reassertDesat, frame, tex, self._keyByFrame[frame]) end
    self._desatReentry[tex] = false
end

-- G13: re-assert the QUI recharge draw-edge state whenever Blizzard re-enables it.
-- Blizzard sets cooldownShowDrawEdge=true for charge spells and re-asserts it on
-- every refresh, so a one-shot disable in applyChrome is overwritten -- this hook
-- re-hides it (via deps.reassertEdge) every time. Re-entry guard keeps the
-- reassert's own SetDrawEdge(false), which re-fires this hook, from recursing.
function CDMReanchorAuraPhase:OnDrawEdge(frame, cd)
    if not cd or self._edgeReentry[cd] then return end
    self._edgeReentry[cd] = true
    local deps = self._deps
    if deps.reassertEdge then ns.SafeCall("bulkhead", deps.reassertEdge, frame, cd, self._keyByFrame[frame]) end
    self._edgeReentry[cd] = false
end

-- Install the additive per-frame SetSwipeColor hook. The callback only touches
-- cdFrame colour methods and runs under securecall (injected) so the item-level
-- write stays attributed to a secure context and never taints the native CDM
-- frame's secret continuation.
function CDMReanchorAuraPhase:Hook(frame, containerKey)
    if not frame then return end
    if containerKey ~= nil then self._keyByFrame[frame] = containerKey end
    local hooksec = self._deps.hooksecurefunc or hooksecurefunc
    local securecall = self._deps.securecall or function(fn, ...) return fn(...) end
    local this = self

    local cd = frame.GetCooldownFrame and frame:GetCooldownFrame()
    if cd and type(cd.SetSwipeColor) == "function" and not self._swipeHooked[cd] then
        self._swipeHooked[cd] = true
        local function colorWork() this:OnSwipeColor(frame, cd) end
        hooksec(cd, "SetSwipeColor", function()
            securecall(colorWork)
        end)
    end
    -- Timing post-hook: SetCooldown is the last timing write in Blizzard's refresh
    -- (CooldownFrame_Set at CooldownViewer.lua:1169, AFTER the SetSwipeColor at
    -- :1166), so the aura-phase-off re-bind must re-assert from here to survive
    -- the refresh. Same securecall posture as the colour hook.
    if cd and type(cd.SetCooldown) == "function" and not self._timingHooked[cd] then
        self._timingHooked[cd] = true
        local function timingWork() this:OnCooldownSet(frame, cd) end
        hooksec(cd, "SetCooldown", function()
            securecall(timingWork)
        end)
    end
    -- Desaturation post-hook on the icon TEXTURE (raw .Icon field read -- never a
    -- provider getter). SetDesaturated is AllowedWhenTainted, same class as
    -- SetSwipeColor; the reassert body runs under the same securecall posture.
    local tex = frame.Icon
    if tex and type(tex.SetDesaturated) == "function" and not self._desatHooked[tex] then
        self._desatHooked[tex] = true
        local function desatWork() this:OnDesaturated(frame, tex) end
        hooksec(tex, "SetDesaturated", function()
            securecall(desatWork)
        end)
    end
    -- G13: parallel SetDrawEdge hook. Blizzard re-asserts the bright leading recharge
    -- edge for charge spells every refresh; this re-hides it (when the owned-icon
    -- showRechargeEdge setting is off) so re-anchored multi-charge icons match owned
    -- ones. SetDrawEdge is AllowedWhenTainted (taint-safe, same class as SetSwipeColor);
    -- the body runs under securecall like the colour hook.
    if cd and type(cd.SetDrawEdge) == "function" and not self._edgeHooked[cd] then
        self._edgeHooked[cd] = true
        local function edgeWork() this:OnDrawEdge(frame, cd) end
        hooksec(cd, "SetDrawEdge", function()
            securecall(edgeWork)
        end)
    end
end

-- Proactive claim-time re-assert. The per-widget hooks above only fire on the
-- NEXT Blizzard write; a frame claimed after Blizzard's refresh already painted
-- (BuffIcon items recolour once per aura application, at apply -- BEFORE the
-- settled claim pass runs) keeps the native swipe colour until the next aura
-- refresh. Runs the same securecall'd colour/edge bodies as the hooks, so the
-- re-entry guards and taint posture are identical.
function CDMReanchorAuraPhase:Reassert(frame)
    if not frame then return end
    local securecall = self._deps.securecall or function(fn, ...) return fn(...) end
    local cd = frame.GetCooldownFrame and frame:GetCooldownFrame()
    if not cd then return end
    local this = self
    securecall(function()
        this:OnSwipeColor(frame, cd)
        this:OnDrawEdge(frame, cd)
    end)
end
