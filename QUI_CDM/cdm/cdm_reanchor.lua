-- QUI_CDM/cdm/cdm_reanchor.lua
-- Re-anchor bridge core. Relocates Blizzard CooldownViewer item frames into QUI
-- containers via SetPoint (never SetParent). All per-frame state is external and
-- weak-keyed; nothing is written onto Blizzard frames.
local _, ns = ...

local CDMReanchor = {}
ns.CDMReanchor = CDMReanchor

-- Raw, unhooked primitives captured before any hook can taint them.
local _proxy = (CreateFrame and CreateFrame("Frame")) or {}
local RAW = {
    ClearAllPoints       = _proxy.ClearAllPoints or function() end,
    SetPoint             = _proxy.SetPoint or function() end,
    SetAlpha             = _proxy.SetAlpha or function() end,
    SetIgnoreParentAlpha = _proxy.SetIgnoreParentAlpha or function() end,
}

local _securecall = securecallfunction or function(callee, ...) return callee(...) end
local _issecretvalue = issecretvalue or function() return false end

local InstanceMT = { __index = CDMReanchor }

function CDMReanchor.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _raw = deps.raw or RAW,
        _securecall = deps.securecall or _securecall,
        _hooksecurefunc = deps.hooksecurefunc or hooksecurefunc,
        _sinkAnchor = deps.sinkAnchor or UIParent,
        _frameData = setmetatable({}, { __mode = "k" }),
        _infoCache = {},
    }
    return setmetatable(self, InstanceMT)
end

function CDMReanchor:GetData(frame)
    local fd = self._frameData[frame]
    if not fd then
        fd = {}
        self._frameData[frame] = fd
    end
    return fd
end

function CDMReanchor:IsClaimed(frame)
    local fd = self._frameData[frame]
    return (fd ~= nil and fd.claimedBy ~= nil) or false
end

-- Two-point overlay (RECT form): stretch a Blizzard CooldownViewer frame onto an
-- ARBITRARY relative frame at computed slot corners. Pinning BOTH opposite corners
-- (frame TOPLEFT->relativeTo tlRelPoint + frame BOTTOMRIGHT->relativeTo brRelPoint)
-- forces the Blizzard frame's on-screen rect to EXACTLY match the two anchor points,
-- independent of either frame's scale chain -- relativeTo is a real QUI-container-side
-- frame (authored in the container's coordinate space), the Blizzard frame stays
-- parented to its viewer (a different chain). No SetSize, no GetScale read, no
-- secret-state copy: the owner supplies border/bg/position, the Blizzard frame renders
    -- its OWN native swipe/count on top. The shell path (Overlay) is the zero-offset,
    -- TL/BR special case; buff direct-anchors to the container at slot corners.
function CDMReanchor:OverlayRect(frame, relativeTo, tlRelPoint, tlX, tlY, brRelPoint, brX, brY)
    local fd = self:GetData(frame)
    fd.claimedBy = relativeTo
    fd.overlayAnchor = relativeTo   -- keeps the guard's self-call/unclaimed logic working
    -- Full rect stamped BEFORE SetPoint so the guard re-asserts these exact corners.
    fd.overlayRect = {
        relativeTo = relativeTo,
        tlRelPoint = tlRelPoint, tlX = tlX, tlY = tlY,
        brRelPoint = brRelPoint, brX = brX, brY = brY,
    }
    fd.sunk = nil
    local raw, sc = self._raw, self._securecall
    sc(raw.SetAlpha, frame, 1)
    sc(raw.ClearAllPoints, frame)
    sc(raw.SetPoint, frame, "TOPLEFT", relativeTo, tlRelPoint, tlX, tlY)
    sc(raw.SetPoint, frame, "BOTTOMRIGHT", relativeTo, brRelPoint, brX, brY)
end

-- Legacy shell overlay: stretch a Blizzard frame onto an owned QUI anchor icon at
-- zero offset (TOPLEFT->TL + BOTTOMRIGHT->BR). Thin, byte-identical wrapper over the
-- RECT form -- essential/utility clickable icons still ride the per-slot shell.
function CDMReanchor:Overlay(frame, anchorIcon)
    return self:OverlayRect(frame, anchorIcon, "TOPLEFT", 0, 0, "BOTTOMRIGHT", 0, 0)
end

function CDMReanchor:Sink(frame)
    local fd = self:GetData(frame)
    fd.claimedBy = nil
    fd.overlayAnchor = nil
    fd.overlayRect = nil   -- clear the rect too, so a re-anchor consumer can't see a stale slot
    fd.sunk = true
    local raw, sc = self._raw, self._securecall
    -- G10: hide the unclaimed pool frame with alpha-0 ONLY (park retired). The anchor
    -- guard's unclaimed branch already alpha-0's a frame Blizzard re-anchors back into
    -- its viewer grid, and Blizzard's next Layout pass overwrites any point we set, so
    -- ClearAllPoints + an offscreen SetPoint were a redundant extra combat SetPoint +
    -- ClearAllPoints churn on a managed GridLayout child -- dropped. This matches the
    -- re-anchor reference's unclaimed-hide recipe (SetAlpha(0) + SetDrawSwipe(false)),
    -- replacing the old offscreen park.
    sc(raw.SetAlpha, frame, 0)
    -- SetDrawSwipe(false) hides the native swipe so a momentarily re-shown frame doesn't
    -- flash it before the alpha takes. SetDrawSwipe is AllowedWhenTainted (taint-safe);
    -- the body runs under securecall like every other write here. Guard GetCooldownFrame
    -- (mixin getter) then the plain Cooldown field.
    local cd = (frame.GetCooldownFrame and frame:GetCooldownFrame()) or frame.Cooldown
    if cd and cd.SetDrawSwipe then
        sc(cd.SetDrawSwipe, cd, false)
    end
end

function CDMReanchor:InstallAnchorGuard(frame)
    local fd = self:GetData(frame)
    if fd.guarded then return end
    fd.guarded = true
    local bridge = self
    -- Re-assert the two-point overlay after Blizzard's CooldownViewer Layout() pass
    -- re-anchors the frame to its item container. The hook fires inside Blizzard's
    -- secure execution frame for a secret-tracked CDM frame, so the WHOLE body runs
    -- under securecall (not just the writes) -- a bare body leaks this addon's taint
    -- into Blizzard's continuation, which then throws on the item's secret cooldown/
    -- aura values. The raw setters (already secure here) avoid re-triggering this hook.
    local function reassert(f, _point, relativeTo)
        local d = bridge._frameData[f]
        if not d or not d.overlayAnchor then
            -- Unclaimed: park is retired (Task 1), so a frame Blizzard re-anchors back
            -- into its viewer grid would otherwise show. Hide it in place; SetAlpha is
            -- taint-safe on the live frame (no strata/level/ignore-alpha state write).
            bridge._raw.SetAlpha(f, 0)
            return
        end
        local raw = bridge._raw
        local rect = d.overlayRect
        if rect then
            -- Both our re-pins target rect.relativeTo (the container/anchor); Blizzard's
            -- Layout re-anchors to its VIEWER (a different relativeTo), so a container-
            -- relative call is unambiguously our own two-point call -> ignore.
            if relativeTo == rect.relativeTo then return end
            raw.ClearAllPoints(f)
            raw.SetPoint(f, "TOPLEFT", rect.relativeTo, rect.tlRelPoint, rect.tlX, rect.tlY)
            raw.SetPoint(f, "BOTTOMRIGHT", rect.relativeTo, rect.brRelPoint, rect.brX, rect.brY)
            return
        end
        -- Legacy fall-back for any caller that stamped only overlayAnchor (no rect).
        if relativeTo == d.overlayAnchor then return end   -- our own two-point call; ignore
        raw.ClearAllPoints(f)
        raw.SetPoint(f, "TOPLEFT", d.overlayAnchor, "TOPLEFT", 0, 0)
        raw.SetPoint(f, "BOTTOMRIGHT", d.overlayAnchor, "BOTTOMRIGHT", 0, 0)
    end
    self._hooksecurefunc(frame, "SetPoint", function(...)
        _securecall(reassert, ...)
    end)
end

function CDMReanchor:ResolveIdentity(frame)
    if self._deps.resolveIdentity then
        return self._deps.resolveIdentity(frame)
    end
    local getID = frame.GetCooldownID
    local cooldownID
    if getID then
        local ok, id = pcall(getID, frame)
        if ok then cooldownID = id end
    else
        cooldownID = frame.cooldownID
    end
    -- Guard issecretvalue BEFORE any comparison; the type check below rejects nil.
    if _issecretvalue(cooldownID) then return nil end
    if type(cooldownID) ~= "number" then return nil end

    local info = self._infoCache[cooldownID]
    if info == nil then
        if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            local ok, resolved = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
            info = (ok and resolved) or false
        else
            info = false
        end
        self._infoCache[cooldownID] = info
    end
    if not info then return cooldownID, nil end
    return cooldownID, info.category
end

function CDMReanchor:GetFrameCooldownInfo(frame, cooldownID)
    if self._deps.getFrameCooldownInfo then
        return self._deps.getFrameCooldownInfo(frame, cooldownID)
    end
    if not frame then return nil end

    local getInfo = frame.GetCooldownInfo
    if getInfo then
        local ok, info = pcall(getInfo, frame)
        if ok and type(info) == "table" then
            return info
        end
    end

    if type(frame.cooldownInfo) == "table" then
        return frame.cooldownInfo
    end

    if type(cooldownID) ~= "number" or _issecretvalue(cooldownID) then
        cooldownID = self:ResolveIdentity(frame)
    end
    if type(cooldownID) ~= "number" or _issecretvalue(cooldownID) then
        return nil
    end

    local info = self._infoCache[cooldownID]
    if info == nil then
        if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            local ok, resolved = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
            info = (ok and resolved) or false
        else
            info = false
        end
        self._infoCache[cooldownID] = info
    end
    return type(info) == "table" and info or nil
end

function CDMReanchor:EnumerateItems(viewer)
    if self._deps.enumerate then
        return self._deps.enumerate(viewer)
    end
    local out = {}
    if not viewer then return out end
    if viewer.GetItemFrames then
        local frames = viewer:GetItemFrames()
        if frames then
            for i = 1, #frames do out[i] = frames[i] end
        end
        return out
    end
    local pool = viewer.itemFramePool
    if pool and pool.EnumerateActive then
        for f in pool:EnumerateActive() do
            out[#out + 1] = f
        end
    end
    return out
end
