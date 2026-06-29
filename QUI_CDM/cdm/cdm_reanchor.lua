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
    ClearAllPoints = _proxy.ClearAllPoints or function() end,
    SetPoint       = _proxy.SetPoint or function() end,
    SetAlpha       = _proxy.SetAlpha or function() end,
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

-- Two-point overlay: stretch a Blizzard CooldownViewer frame onto an owned QUI
-- anchor icon. Pinning BOTH opposite corners (TOPLEFT->TL + BOTTOMRIGHT->BR, zero
-- offset) forces the Blizzard frame's on-screen rect to EXACTLY match the anchor
-- icon's rect, independent of either frame's scale chain -- the anchor is a real
-- QUI-container child (authored in the container's coordinate space), the Blizzard
-- frame stays parented to its viewer (a different chain). No SetSize, no GetScale
-- read, no secret-state copy: the owned icon supplies border/bg/position, the
-- Blizzard frame renders its OWN native swipe/count on top.
function CDMReanchor:Overlay(frame, anchorIcon)
    local fd = self:GetData(frame)
    fd.claimedBy = anchorIcon
    fd.overlayAnchor = anchorIcon   -- stamped BEFORE SetPoint so the guard re-asserts the same two points
    fd.sunk = nil
    local raw, sc = self._raw, self._securecall
    sc(raw.ClearAllPoints, frame)
    sc(raw.SetPoint, frame, "TOPLEFT", anchorIcon, "TOPLEFT", 0, 0)
    sc(raw.SetPoint, frame, "BOTTOMRIGHT", anchorIcon, "BOTTOMRIGHT", 0, 0)
end

function CDMReanchor:Sink(frame)
    local fd = self:GetData(frame)
    fd.claimedBy = nil
    fd.overlayAnchor = nil
    fd.sunk = true
    local raw, sc = self._raw, self._securecall
    sc(raw.SetAlpha, frame, 0)
    sc(raw.ClearAllPoints, frame)
    sc(raw.SetPoint, frame, "TOPLEFT", self._sinkAnchor, "TOPLEFT", -10000, 10000)
end

function CDMReanchor:InstallAnchorGuard(frame)
    local fd = self:GetData(frame)
    if fd.guarded then return end
    fd.guarded = true
    local bridge = self
    self._hooksecurefunc(frame, "SetPoint", function(f, _point, relativeTo)
        local d = bridge._frameData[f]
        if not d or not d.overlayAnchor then return end
        if relativeTo == d.overlayAnchor then return end   -- our own two-point call; ignore
        -- Blizzard's CooldownViewer Layout() pass re-anchored the frame to its item
        -- container; re-assert the two-point overlay onto our owned anchor icon.
        local raw, sc = bridge._raw, bridge._securecall
        sc(raw.ClearAllPoints, f)
        sc(raw.SetPoint, f, "TOPLEFT", d.overlayAnchor, "TOPLEFT", 0, 0)
        sc(raw.SetPoint, f, "BOTTOMRIGHT", d.overlayAnchor, "BOTTOMRIGHT", 0, 0)
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
