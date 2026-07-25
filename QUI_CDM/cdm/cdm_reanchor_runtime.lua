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

local function IsBuffIconKey(containerKey)
    return containerKey == "buff" or containerKey == "buffIcon"
end

local function IsBlizzardCDMEntry(entry)
    return entry and entry.source == BLIZZARD_CDM_ENTRY_SOURCE
end

local function ShouldMintFramelessOwned(entry, containerKey, displayMode, editing)
    if IsBuffIconKey(containerKey) then
        -- Blizzard-CDM buff entries are native-only in the live path. If
        -- Blizzard has not produced a BuffIconCooldownViewer child yet, render
        -- nothing and let the reanchor readiness/hooks repair the native claim.
        -- QUI layout mode may still ask for a placeholder surface for mover
        -- bounds; Blizzard Edit Mode does not set this flag.
        if IsBlizzardCDMEntry(entry) then return editing == true end

        -- Active-only non-Blizzard BuffIcon cannot treat "no native Blizzard
        -- child yet" as an active aura. Custom/additional entries keep the
        -- owned path used by the rest of the icon runtime.
        if displayMode == "active" and not editing then return false end
        return true
    end
    if IsBlizzardCDMEntry(entry) then return false end
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
        -- Per-container ledger of owned icons minted THIS pass (frameless curated
        -- + additional entries). mintOwned acquires a fresh Factory icon every
        -- pass; without releasing the previous pass's icons they stay Show()n at
        -- stale slots (ghost icons that never clear) and leak one frame per pass.
        _mintedOwnedByKey = {},
        -- Boundary instrumentation: last pass's per-container diag snapshot
        -- (counts at each assemble/refresh decision point) so in-game
        -- diagnostics can pin which link fails without a debug-mode reload.
        _lastDiagByKey = {},
        _diagSeqByKey = {},
    }
    return setmetatable(self, InstanceMT)
end

function CDMReanchorRuntime:_NextDiag(containerKey, diag)
    local seq = (self._diagSeqByKey[containerKey] or 0) + 1
    self._diagSeqByKey[containerKey] = seq
    diag.seq = seq
    if GetTime then diag.at = GetTime() end
    self._lastDiagByKey[containerKey] = diag
    return diag
end

-- Last pass's diag snapshot for a container (nil until a pass ran).
function CDMReanchorRuntime:GetLastDiag(containerKey)
    return self._lastDiagByKey[containerKey]
end

-- Release the PREVIOUS pass's minted owned icons for a container (Factory
-- recycle: Hide + ClearAllPoints + pool return), then reset the ledger. Runs at
-- the top of every assemble AND on the refresh early-return paths so stale
-- icons cannot survive a container/settings disappearance.
function CDMReanchorRuntime:ReleaseOwnedIcons(containerKey)
    local minted = self._mintedOwnedByKey[containerKey]
    if not minted then return end
    local release = self._deps.releaseOwned
    if not release then
        self._mintedOwnedByKey[containerKey] = nil
        return
    end
    -- Keep icons whose release was REFUSED (returned false: protected in combat).
    -- Clearing them without a successful Factory recycle strands a visible/
    -- clickable ghost; they are retried on the next pass / regen drain.
    local kept
    for i = 1, #minted do
        -- containerKey rides along so realenv can drop the icon from the
        -- Factory pool it was registered in at mint time.
        local ok = release(minted[i], containerKey)
        if ok == false then
            kept = kept or {}
            kept[#kept + 1] = minted[i]
        end
    end
    self._mintedOwnedByKey[containerKey] = kept
end

-- Combat protected-owned defer. In combat a QUI-owned icon that carries a secure
-- clickButton child is visibility-protected: Factory recycle (Hide/ClearAllPoints/
-- SetParent) raises ADDON_ACTION_BLOCKED. Defer the WHOLE pass for such a container
-- and recover on PLAYER_REGEN_ENABLED (DrainPendingCombatRefresh). Mirrors
-- ShouldDeferContainerLayoutInCombat, which only the legacy LayoutContainer path
-- consults. Inert without a canMutate dep (isolated tests, non-live callers).
function CDMReanchorRuntime:_ShouldDeferOwnedReleaseInCombat(containerKey)
    local canMutate = self._deps.canMutate
    -- OOC / init-safe window: canMutate() true -> never defer. No dep -> never defer.
    if not canMutate or canMutate() then return false end
    -- Combat: only the prior pass's owned icons are at risk (they are what
    -- ReleaseOwnedIcons would Hide). Native reanchored frames are not released here.
    local minted = self._mintedOwnedByKey[containerKey]
    if not minted then return false end
    for i = 1, #minted do
        local icon = minted[i]
        if icon and icon.clickButton ~= nil then return true end
    end
    return false
end

-- Re-run every container whose combat refresh was deferred. Called from the
-- PLAYER_REGEN_ENABLED handler via the boot table (DrainPendingCombatRefresh).
function CDMReanchorRuntime:DrainPendingCombatRefresh()
    local pending = self._pendingCombatRefresh
    if not pending then return end
    self._pendingCombatRefresh = nil
    for key in pairs(pending) do
        self:RefreshContainer(key)
    end
end

function CDMReanchorRuntime:_TrackMintedOwned(containerKey, icon)
    local minted = self._mintedOwnedByKey[containerKey]
    if not minted then
        minted = {}
        self._mintedOwnedByKey[containerKey] = minted
    end
    minted[#minted + 1] = icon
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

function CDMReanchorRuntime:AssembleEntries(containerKey, frameMap, settings)
    local deps, wiring = self._deps, self._wiring
    -- Swap the owned-icon ledger: release last pass's minted icons before this
    -- pass mints (Factory recycle hands the same frames back, so no churn).
    self:ReleaseOwnedIcons(containerKey)
    local curated = (deps.getCurated and deps.getCurated(containerKey)) or {}
    local matched, frameless, claimedFrames = wiring:MatchCuratedToFrames(curated, frameMap, containerKey)
    matched = matched or {}
    frameless = frameless or {}
    claimedFrames = claimedFrames or {}
    -- Tracked bars render through addon-owned CDMBars StatusBars. Blizzard's
    -- BuffBarCooldownViewer frames are data sources only; do not anchor,
    -- decorate, tooltip-wrap, or register them in the re-anchor frame registry.
    -- Keep claimedFrames intact so an accidental trackedBar refresh does not
    -- sink a matched data-source frame.
    if containerKey == "trackedBar" then
        return {}, claimedFrames
    end

    -- Active-mode filter. "active" shows only matched frames whose live Blizzard item
    -- reports active (CooldownViewerItemMixin:IsActive -- aura present / on cooldown);
    -- "combat" resolves to always in combat, active otherwise; "always" shows all.
    -- deps.frameIsActive issecretvalue-guards + fails open, so a combat-secret active
    -- state shows (never hides a possibly-active frame). Re-drives on the per-frame
    -- OnActiveStateChanged hook (cdm_reanchor_hooks) -> MarkDirty -> RefreshBuiltin.
    local displayMode = (settings and settings.iconDisplayMode) or "always"
    if displayMode == "combat" then
        displayMode = (deps.inCombat and deps.inCombat()) and "always" or "active"
    end
    -- Never filter while positioning in QUI/CDM layout mode: the mover needs
    -- the full configured surface, not just currently-active frames. Blizzard
    -- Edit Mode is deliberately excluded so CDM does not appear there.
    local editing = deps.isEditMode and deps.isEditMode()
    local filterInactive = (displayMode == "active") and (deps.frameIsActive ~= nil) and not editing

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
    -- Aura ground truth for QUI-OWNED buff entries only (custom/manual spells
    -- Blizzard does not track). Blizzard-CDM-backed entries are NATIVE-ONLY,
    -- matching the re-anchor reference model: render Blizzard's item frame when
    -- Blizzard activates it (OnActiveStateChanged re-drives the claim pass) and
    -- render NOTHING while it is inactive/stale -- never derive aura truth and
    -- mint a replacement icon for a Blizzard-tracked buff.
    local auraLive = IsBuffIconKey(containerKey) and filterInactive
        and deps.entryAuraIsPresent or nil
    local function ownedAuraFallback(e)
        if not auraLive then return false end
        if IsBlizzardCDMEntry(e) then return false end
        return auraLive(e) and true or false
    end

    -- Per-pass boundary counters (GetLastDiag): which branch each curated entry
    -- took, and where custom/owned fallback assembly drops (aura probe missing,
    -- aura not live, mintOwned nil). Plain bookkeeping -- no protected calls.
    local diag = self:_NextDiag(containerKey, {
        displayMode = displayMode,
        filterInactive = filterInactive and true or false,
        editing = editing and true or false,
        auraProbe = auraLive ~= nil,
        curated = #curated,
        matched = 0, frameless = 0, additional = 0,
        nativeClaimed = 0, staleNative = 0,
        fallbackLive = 0, minted = 0, mintFailed = 0,
    })

    for i = 1, #curated do
        local e = curated[i]
        local m = matchedByEntry[e]
        if m then
            diag.matched = diag.matched + 1
        elseif framelessByEntry[e] then
            diag.frameless = diag.frameless + 1
        end
        if m and filterInactive and not deps.frameIsActive(m.frame, containerKey, e) then
            -- active-only mode + this matched frame is not natively usable:
            -- unclaim it and render nothing (Blizzard owns the item lifecycle;
            -- it re-appears when OnActiveStateChanged re-drives the refresh).
            -- QUI-owned (non-Blizzard-CDM) entries may render an owned icon off
            -- QUI's own aura query.
            diag.staleNative = diag.staleNative + 1
            claimedFrames[m.frame] = nil
            if ownedAuraFallback(e) then
                diag.fallbackLive = diag.fallbackLive + 1
                local icon = deps.mintOwned and deps.mintOwned(e, containerKey) or nil
                if icon then
                    diag.minted = diag.minted + 1
                    self:_TrackMintedOwned(containerKey, icon)
                    entries[#entries + 1] = {
                        src = e, frame = icon, reanchored = false,
                        _assignedRow = e._assignedRow,
                    }
                else
                    diag.mintFailed = diag.mintFailed + 1
                end
            end
        elseif m then
            -- Big-bang native model: matched Blizzard CDM items ARE the visible icons.
            -- Essential/Utility no longer mint a visual shell; their secure click target
            -- is a separate QUI-owned slot overlay positioned beside this direct anchor.
            -- BuffIcon has no secure click target. trackedBar returned above because
            -- BuffBarCooldownViewer is data-source-only for owned StatusBars.
            diag.nativeClaimed = diag.nativeClaimed + 1
            entries[#entries + 1] = {
                src = e, frame = m.frame, liveFrame = m.frame,
                reanchored = true, directAnchor = true,
                _assignedRow = e._assignedRow,
            }
        elseif framelessByEntry[e] and ownedAuraFallback(e) then
            -- QUI-owned entry with no native frame but a LIVE aura: owned icon
            -- even in active mode (ShouldMintFramelessOwned deliberately
            -- suppresses speculative frameless mints there; a live aura is not
            -- speculative). Blizzard-CDM entries never reach here (native-only).
            diag.fallbackLive = diag.fallbackLive + 1
            local icon = deps.mintOwned and deps.mintOwned(e, containerKey) or nil
            if icon then
                diag.minted = diag.minted + 1
                self:_TrackMintedOwned(containerKey, icon)
                entries[#entries + 1] = {
                    src = e, frame = icon, reanchored = false,
                    _assignedRow = e._assignedRow,
                }
            else
                diag.mintFailed = diag.mintFailed + 1
            end
        elseif framelessByEntry[e] and ShouldMintFramelessOwned(e, containerKey, displayMode, editing) then
            -- Curated frameless -> owned synthetic icon. Blizzard-CDM-backed
            -- entries only exist as re-anchored Blizzard frames in the live
            -- path; with no live frame, render nothing so a missed native claim
            -- is visible. QUI layout mode can still request placeholders for
            -- mover bounds.
            local icon = deps.mintOwned and deps.mintOwned(e, containerKey) or nil
            if icon then
                diag.minted = diag.minted + 1
                self:_TrackMintedOwned(containerKey, icon)
                entries[#entries + 1] = {
                    src = e, frame = icon, reanchored = false,
                    _assignedRow = e._assignedRow,
                }
            else
                diag.mintFailed = diag.mintFailed + 1
            end
        end
    end

    -- Additional spells -> owned synthetic icon
    local additional = (deps.getAdditional and deps.getAdditional(containerKey)) or {}
    for i = 1, #additional do
        local e = additional[i]
        diag.additional = diag.additional + 1
        local icon = deps.mintOwned and deps.mintOwned(e, containerKey) or nil
        if icon then
            diag.minted = diag.minted + 1
            self:_TrackMintedOwned(containerKey, icon)
            entries[#entries + 1] = {
                src = e, frame = icon, reanchored = false,
                _assignedRow = e._assignedRow,
            }
        else
            diag.mintFailed = diag.mintFailed + 1
        end
    end

    diag.entriesOut = #entries
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
                -- Prefer an explicit w/h from the layout (bars: barWidth x barHeight,
                -- decoupled from the icon crop so the icon texcoord aspect stays square);
                -- otherwise derive from rowConfig.size + aspectRatioCrop like owned icons.
                local rc = placement.rowConfig
                local w, h = placement.w, placement.h
                if not (w and h) then
                    local size = rc and rc.size
                    if size then
                        local aspect = (rc and rc.aspectRatioCrop) or 1
                        if type(aspect) ~= "number" or aspect <= 0 then aspect = 1 end
                        w, h = size, size / aspect
                    end
                end
                -- Native matched entry: pin the live Blizzard frame's TL/BR straight
                -- to the container CENTER at the slot corners (two-point rect,
                -- scale-independent). x/y are the icon-CENTER offsets from container
                -- CENTER, so TL = center + (-w/2, +h/2), BR = center + (+w/2, -h/2).
                -- Secure click handling, when needed, is a separate QUI-owned slot
                -- overlay and is never the live frame's anchor target.
                local live = wrapper.liveFrame
                if live and w and h then
                    local tlX, tlY = x - w / 2, y + h / 2
                    local brX, brY = x + w / 2, y - h / 2
                    bridge:InstallAnchorGuard(live)
                    bridge:OverlayRect(live, container, "CENTER", tlX, tlY, "CENTER", brX, brY)
                    -- No shell to decorate against: pass a minimal stand-in carrying the
                    -- curated entry so decorate's _spellEntry consumers keep working
                    -- (the retired shell.Bg/BarIcon are gone; the icon path's shell.Border
                    -- access is nil-guarded, so the {_spellEntry=...} stand-in suffices).
                    if deps.decorate then
                        deps.decorate(live, { _spellEntry = wrapper.src }, rc, containerKey)
                    end
                    -- No shell hosts tooltip scripts anymore. A QUI-owned child
                    -- overlay on the live frame handles hover; the live Blizzard frame
                    -- itself is never SetScript/EnableMouse mutated.
                    if deps.ensureLiveTooltip then
                        deps.ensureLiveTooltip(live, wrapper.src)
                    end
                    if containerKey ~= "buff" and deps.positionClickSlot then
                        local clickSlot = deps.positionClickSlot(container, live, wrapper.src,
                            containerKey, x, y, w, h, rc)
                        if clickSlot and deps.updateClickOverlay then
                            deps.updateClickOverlay(clickSlot, wrapper.src, containerKey)
                        end
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
    -- Combat protected-owned defer (before ANY registry/ledger mutation): if this
    -- container's owned icons carry a secure clickButton and we cannot mutate
    -- protected frames right now, leave all state intact and queue a regen drain.
    if self:_ShouldDeferOwnedReleaseInCombat(containerKey) then
        self._pendingCombatRefresh = self._pendingCombatRefresh or {}
        self._pendingCombatRefresh[containerKey] = true
        self:_NextDiag(containerKey, { earlyReturn = "combat-protected-owned" })
        return #(self._mintedOwnedByKey[containerKey] or {})
    end

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
        self:_NextDiag(containerKey, { earlyReturn = "no-viewers-or-container" })
        self:ClearContainerRegistry(containerKey)
        self:ReleaseOwnedIcons(containerKey)
        return 0
    end
    local settings = deps.getSettings and deps.getSettings(containerKey) or nil
    if not settings then
        self:_NextDiag(containerKey, { earlyReturn = "no-settings" })
        self:ClearContainerRegistry(containerKey)
        self:ReleaseOwnedIcons(containerKey)
        return 0
    end

    -- Generation-mark this container's pooled slot hosts before positioning reuses
    -- them. Older resetShells remains a fallback for isolated tests/callers that have
    -- not adopted the pass lifecycle yet. BuffIcon normally leaves the pool empty;
    -- Essential/Utility populate it with non-visual secure click hosts.
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
    items = items or {}
    -- Disabled tracker: claim NOTHING for this key, but keep the pass alive so the
    -- native sink loop below alpha-0s every enumerated frame no other container
    -- claims. LayoutContainer gates on enabled==false for the QUI-container side;
    -- without this mirror gate the reanchor pass still assembled the disabled
    -- tracker's curated entries and pinned live Blizzard frames alpha-1 onto its
    -- hidden container (parked near screen center) — visible mid-screen icons on
    -- every churn pass until another container re-claimed them (Towelliee repro:
    -- utility disabled, its category spells curated into essential; wings press
    -- flashed the utility set at the disabled container's rect).
    local entries, claimedFrames
    if settings.enabled == false then
        self:_NextDiag(containerKey, { earlyReturn = "disabled" })
        entries, claimedFrames = {}, {}
    else
        entries, claimedFrames = self:AssembleEntries(containerKey, frameMap, settings)
    end

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
            if deps.auraPhase then
                deps.auraPhase:Hook(w.liveFrame, containerKey)
                -- Claim-time colour/edge assert: the hooks only fire on the NEXT
                -- Blizzard write, so a first-claimed frame (BuffIcon recolours
                -- once, at aura apply, before this settled pass) keeps the
                -- native swipe colour until the next refresh without this.
                if deps.auraPhase.Reassert then
                    deps.auraPhase:Reassert(w.liveFrame)
                end
            end
            -- Pandemic bridge: hook Blizzard's per-frame pandemic state machine
            -- (Show/HidePandemicStateFrame) + claim-time reconcile so a frame
            -- re-pooled to a different entry drops the old spell's glow (pool
            -- release never fires the Hide hook). trackedBar never reaches this
            -- loop (data-source-only early return in AssembleEntries).
            if deps.pandemic then
                deps.pandemic:Hook(w.liveFrame)
                if deps.pandemic.OnClaim then
                    deps.pandemic:OnClaim(w.liveFrame, w.src)
                end
            end
            -- Proc-glow bridge: same re-pool reconcile as pandemic. The glow is
            -- driven by the ActionButtonSpellAlertManager ShowAlert/HideAlert hook
            -- (CDMReanchorProcGlow), latched per frame; a frame re-pooled to a new
            -- entry never fires HideAlert for the old spell, so drop the stale
            -- latched glow here. Resolved lazily -- the instance is built only once
            -- the alert manager global exists.
            if deps.getProcGlow then
                local pg = deps.getProcGlow()
                if pg and pg.OnClaim then
                    pg:OnClaim(w.liveFrame, w.src)
                end
            end
        end
    end
    self._reanchoredByKey[containerKey] = reanchored

    local plan = deps.buildLayout and deps.buildLayout(settings, entries, {}) or nil
    -- Row-based layout (BuildIconLayout) returns nil when the container settings carry
    -- no row1/2/3 schema -- the buff surface uses a flat iconSize/growthDirection schema.
    -- Fall back to the single-line grid layout so buff entries still position + size.
    if not plan and deps.buildBuffLayout then
        plan = deps.buildBuffLayout(settings, entries, {}, containerKey)
    end
    local positioned = self:PositionEntries(container, plan, containerKey)
    local diag = self._lastDiagByKey[containerKey]
    if diag then
        diag.planNil = plan == nil
        diag.positioned = positioned
    end
    if shellPassActive and deps.endShellPass then
        deps.endShellPass(container)
    end

    if plan and plan.metrics and deps.applySize then
        deps.applySize(container, plan.metrics)
    end

    -- Sink every enumerated cooldown frame the curation did not claim (never Hide).
    -- Iterate raw `items`, not the map, so secret-identity frames are sunk too.
    -- Also tear down the direct-anchor tooltip overlay: bridge:Sink only SetAlpha(0)'s
    -- the live frame, but an alpha-0 frame still receives mouse events.  Call
    -- hideLiveTooltip so the overlay's mouse-catcher is hidden + disabled for sunk
    -- buff/bar slots.  Shell-path frames have no _liveTooltip entry -> harmless no-op.
    -- BuffIcon is different: its native frames are Blizzard aura lifecycle frames.
    -- Active-only mode can legitimately claim zero entries, so do not run the generic
    -- native sink path against fresh unclaimed BuffIcon children. If QUI claimed the
    -- frame on an earlier pass, release that stale bridge state or expired buffs can
    -- keep the old overlay rect/alpha and overlap the next active icon.
    local skipNativeSink = IsBuffIconKey(containerKey)
    for i = 1, #items do
        local frame = items[i]
        if not claimedFrames[frame] and not self:IsFrameClaimedByAnyContainer(frame) then
            local previouslyClaimed = bridge.IsClaimed and bridge:IsClaimed(frame)
            if not skipNativeSink or previouslyClaimed then
                bridge:Sink(frame)
            end
            if deps.hideLiveTooltip then deps.hideLiveTooltip(frame) end
        end
    end

    return #entries
end
