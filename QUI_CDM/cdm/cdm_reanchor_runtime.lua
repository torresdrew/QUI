-- QUI_CDM/cdm/cdm_reanchor_runtime.lua
-- Unified position+sink runtime for the re-anchor engine. Lays out a single
-- container holding a mix of re-anchored Blizzard frames (curated matches) and
-- owned synthetic icons (frameless curated + additional spells) in one
-- BuildIconLayout pass; sinks unmatched Blizzard frames. Composes the Phase 1
-- bridge + Phase 2a wiring. Inert until Phase 2b-2 wires it.
local _, ns = ...

local CDMReanchorRuntime = {}
ns.CDMReanchorRuntime = CDMReanchorRuntime

local InstanceMT = { __index = CDMReanchorRuntime }
local BLIZZARD_CDM_ENTRY_SOURCE = "blizzardCDM"

local function ShouldMintFramelessOwned(entry)
    if entry and entry.source == BLIZZARD_CDM_ENTRY_SOURCE then return false end
    return true
end

function CDMReanchorRuntime.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _bridge = deps.bridge,
        _wiring = deps.wiring,
        -- Registry of the re-anchored Blizzard frames per container + a frame->entry
        -- map, so per-frame features (keybinds, rotation glow) can cover the
        -- re-anchored frames too. These frames stay parented to the Blizzard viewer
        -- (not the QUI container), so feature code that walks container:GetChildren()
        -- misses them -- it enumerates this registry instead.
        _reanchoredByKey = {},
        _entryByFrame = setmetatable({}, { __mode = "k" }),
    }
    return setmetatable(self, InstanceMT)
end

-- List of re-anchored Blizzard frames for a container key (live; do not mutate).
function CDMReanchorRuntime:GetReanchoredFrames(containerKey)
    return self._reanchoredByKey[containerKey]
end

-- The curated entry a re-anchored frame was claimed for (carries spellID/id), or nil.
function CDMReanchorRuntime:GetEntryForFrame(frame)
    if frame == nil then return nil end
    return self._entryByFrame[frame]
end

function CDMReanchorRuntime:IsFrameClaimedByAnyContainer(frame)
    if frame == nil then return false end
    return self._entryByFrame[frame] ~= nil
end

function CDMReanchorRuntime:ClearContainerRegistry(containerKey)
    local previous = self._reanchoredByKey[containerKey]
    if previous then
        for i = 1, #previous do
            self._entryByFrame[previous[i]] = nil
        end
    end
    self._reanchoredByKey[containerKey] = {}
end

function CDMReanchorRuntime:AssembleEntries(containerKey, frameMap)
    local deps, wiring = self._deps, self._wiring
    local curated = (deps.getCurated and deps.getCurated(containerKey)) or {}
    local matched, frameless, claimedFrames = wiring:MatchCuratedToFrames(curated, frameMap, containerKey)
    matched = matched or {}
    frameless = frameless or {}
    claimedFrames = claimedFrames or {}

    local entries = {}
    local matchedByEntry, framelessByEntry = {}, {}
    for i = 1, #matched do
        local m = matched[i]
        if m and m.entry then
            matchedByEntry[m.entry] = m
        end
    end
    for i = 1, #frameless do
        local e = frameless[i]
        if e then
            framelessByEntry[e] = true
        end
    end

    -- Walk the original curated order from the composer. MatchCuratedToFrames
    -- classifies entries into native-frame matches vs frameless entries, but the
    -- final layout must not group those classes; reordering in the composer is
    -- saved as curated-list order.
    for i = 1, #curated do
        local e = curated[i]
        local m = matchedByEntry[e]
        if m then
            -- Curated match -> lightweight QUI chrome SHELL positioned in the
            -- container, with the live Blizzard frame two-point-stretched onto it.
            local shell = deps.mintShell and deps.mintShell(e, containerKey) or nil
            if shell then
                entries[#entries + 1] = {
                    src = e, frame = shell, liveFrame = m.frame, reanchored = true,
                    _assignedRow = e._assignedRow,
                }
            end
        elseif framelessByEntry[e] and ShouldMintFramelessOwned(e) then
            -- Curated frameless -> owned synthetic icon. Blizzard-CDM-backed
            -- entries only exist as re-anchored Blizzard frames; with no live
            -- frame, render nothing so a missed native claim is visible.
            local icon = deps.mintOwned and deps.mintOwned(e, containerKey) or nil
            if icon then
                entries[#entries + 1] = {
                    src = e, frame = icon, reanchored = false,
                    _assignedRow = e._assignedRow,
                }
            end
        end
    end

    -- Additional spells -> owned synthetic icon
    local additional = (deps.getAdditional and deps.getAdditional(containerKey)) or {}
    for i = 1, #additional do
        local e = additional[i]
        local icon = deps.mintOwned and deps.mintOwned(e, containerKey) or nil
        if icon then
            entries[#entries + 1] = {
                src = e, frame = icon, reanchored = false,
                _assignedRow = e._assignedRow,
            }
        end
    end

    return entries, claimedFrames
end

function CDMReanchorRuntime:PositionEntries(container, plan, containerKey)
    if not (plan and plan.placements) then return 0 end
    local deps, bridge = self._deps, self._bridge
    local n = 0
    for _, placement in ipairs(plan.placements) do
        local wrapper = placement.icon
        local frame = wrapper and wrapper.frame
        if frame then
            local x, y = placement.x, placement.y
            if deps.pixelRound then
                x = deps.pixelRound(x, container)
                y = deps.pixelRound(y, container)
            end
            if wrapper.reanchored then
                -- frame is the QUI chrome shell. Size it to the same slot the owned
                -- icons use (rowConfig.size, height = size/aspect) and position it
                -- single-point in the container (same scale chain as owned icons).
                local rc = placement.rowConfig
                local w, h
                local size = rc and rc.size
                if size then
                    local aspect = (rc and rc.aspectRatioCrop) or 1
                    if type(aspect) ~= "number" or aspect <= 0 then aspect = 1 end
                    w, h = size, size / aspect
                end
                local positioned = true
                if deps.positionShell then
                    positioned = deps.positionShell(frame, container, x, y, w, h, rc)
                end
                if positioned ~= false then
                    -- Two-point-stretch the live Blizzard frame onto the shell so its
                    -- on-screen rect matches the shell regardless of scale chains, then
                    -- chrome-decorate it (neutralize Blizzard chrome, QUI font; native
                    -- swipe/count kept, shell owns the border).
                    local live = wrapper.liveFrame
                    if live then
                        bridge:InstallAnchorGuard(live)
                        bridge:Overlay(live, frame)
                        if deps.decorate then deps.decorate(live, frame, rc) end
                    end
                    if deps.updateClickOverlay then
                        deps.updateClickOverlay(frame, wrapper.src, containerKey)
                    end
                    n = n + 1
                end
            elseif deps.positionOwned then
                -- owned synthetic icons need their per-row config forwarded so the
                -- placement hook (OnContainerIconPlaced -> ConfigureIcon) runs.
                deps.positionOwned(frame, container, "CENTER", "CENTER", x, y, placement.rowConfig)
                n = n + 1
            end
        end
    end
    return n
end

function CDMReanchorRuntime:RefreshContainer(containerKey)
    local deps, wiring, bridge = self._deps, self._wiring, self._bridge
    local viewers = wiring.GetViewersForKey and wiring:GetViewersForKey(containerKey) or nil
    if not viewers or #viewers == 0 then
        local viewer = wiring:GetViewerForKey(containerKey)
        if viewer then
            viewers = { viewer }
        end
    end
    local container = deps.getContainer and deps.getContainer(containerKey) or nil
    if not viewers or #viewers == 0 or not container then
        self:ClearContainerRegistry(containerKey)
        return 0
    end
    local settings = deps.getSettings and deps.getSettings(containerKey) or nil
    if not settings then
        self:ClearContainerRegistry(containerKey)
        return 0
    end

    -- Generation-mark this container's chrome shells before AssembleEntries
    -- reuses them. Older resetShells remains a fallback for isolated tests /
    -- callers that have not adopted the pass lifecycle yet.
    local shellPassActive = false
    if deps.beginShellPass then
        deps.beginShellPass(container)
        shellPassActive = true
    elseif deps.resetShells then
        deps.resetShells(container)
    end

    local frameMap, items
    if wiring.BuildFrameMapForViewers then
        frameMap, items = wiring:BuildFrameMapForViewers(viewers)
    else
        frameMap, items = wiring:BuildFrameMap(viewers[1])
    end
    local entries, claimedFrames = self:AssembleEntries(containerKey, frameMap)

    -- Rebuild the per-frame feature registry for this container: which live Blizzard
    -- frames are overlaid here, and the curated entry each was matched for. Keybind /
    -- rotation-glow code reads this to cover the overlaid Blizzard frames (the visible
    -- content), which stay under the viewer and aren't container:GetChildren() icons.
    self:ClearContainerRegistry(containerKey)
    local reanchored = {}
    for i = 1, #entries do
        local w = entries[i]
        if w.reanchored and w.liveFrame then
            reanchored[#reanchored + 1] = w.liveFrame
            self._entryByFrame[w.liveFrame] = w.src
        end
    end
    self._reanchoredByKey[containerKey] = reanchored

    local plan = deps.buildLayout and deps.buildLayout(settings, entries, {}) or nil
    self:PositionEntries(container, plan, containerKey)
    if shellPassActive and deps.endShellPass then
        deps.endShellPass(container)
    end

    if plan and plan.metrics and deps.applySize then
        deps.applySize(container, plan.metrics)
    end

    -- Sink every enumerated Blizzard frame the curation did not claim (never Hide).
    -- Iterate raw `items`, not the map, so secret-identity frames are sunk too.
    for i = 1, #items do
        local frame = items[i]
        if not claimedFrames[frame] and not self:IsFrameClaimedByAnyContainer(frame) then
            bridge:Sink(frame)
        end
    end

    return #entries
end
