-- QUI_CDM/cdm/cdm_reanchor_boot.lua
-- Real-dep boot factory for the re-anchor engine. Wires the bridge + wiring +
-- runtime to the live WoW-side deps (container registry, curated spell list,
-- CDMIndex, BuildIconLayout, PixelRound, owned-icon factory, customEntries).
-- Inert until Phase 2b-3 constructs it and splices the LayoutContainer call.
local _, ns = ...

local CDMReanchorBoot = {}
ns.CDMReanchorBoot = CDMReanchorBoot

local _issecretvalue = issecretvalue or function() return false end

-- positionOwned: replicates LayoutContainer's owned-icon placement (cdm_containers.lua:2665-2677).
-- rowConfig is forwarded to onIconPlaced so the placement hook (OnContainerIconPlaced ->
-- ConfigureIcon) applies per-row sizing/config exactly as the legacy path did.
local function MakePositionOwned(env)
    return function(icon, container, point, relPoint, x, y, rowConfig)
        if icon.GetScale and icon:GetScale() ~= 1 then
            icon:SetScale(1)
        end
        icon:ClearAllPoints()
        icon:SetPoint(point, container, relPoint, x, y)
        icon:Show()
        if env.onIconPlaced then env.onIconPlaced(icon, rowConfig) end
    end
end

-- applySize: replicates the container sizing (cdm_containers.lua:2713-2716) + metrics stash.
-- The container parents secure click overlays (SecureActionButtonTemplate via
-- CDMIcons.UpdateSecureClickOverlay), so its SetSize is a PROTECTED call -- raw in combat it
-- throws ADDON_ACTION_BLOCKED. Gate on env.canMutate exactly like the sibling slot-host deps
-- (positionClickSlot / begin-endShellPass / resetShells all short-circuit on the same combat
-- predicate); the deferred resize is recovered by the PLAYER_REGEN_ENABLED RefreshAll,
-- which re-runs this pass out of combat. The pcall is a final guard so an unforeseen protected
-- edge cannot reach the error handler. The metrics stash (onMetrics) is plain Lua bookkeeping
-- (viewerState fields + ncdm._last* persistence, no protected calls) -- it always runs.
local function MakeApplySize(env)
    return function(container, metrics)
        local w = metrics.iconWidth or 0
        local h = metrics.totalHeight or 0
        -- Pass the container so the gate checks ITS restriction: buff/trackedBar
        -- containers have no secure click descendants and resize in combat; an
        -- essential/utility container parents secure click slots, so it stays
        -- anchoring-restricted and resize defers to PLAYER_REGEN_ENABLED.
        if w > 0 and h > 0 and ((not env.canMutate) or env.canMutate(container)) then
            ns.SafeCallMethod("best-effort-style", container, "SetSize", w, h)
        end
        if env.onMetrics then env.onMetrics(container, metrics) end
    end
end

-- mintOwned: resolve container by key, then env.acquireIcon (cdm_icon_factory.lua:326).
-- NOTE: env.acquireIcon must be a BOUND closure -- function(c,e) return Factory:AcquireIcon(c,e) end --
-- not the raw OOP method, since AcquireIcon needs `self == Factory`.
local function MakeMintOwned(env)
    return function(entry, containerKey)
        local container = env.getContainer and env.getContainer(containerKey) or nil
        if not container then return nil end
        -- containerKey rides along so realenv can register the icon in the
        -- Factory pool for that key -- the content-refresh loops
        -- (cdm_icon_runtime_refresh / cdm_effects) walk GetIconPool(key), so
        -- an unregistered owned icon renders as a static texture (no stack
        -- text, no expired-state repaint).
        return env.acquireIcon(container, entry, containerKey)
    end
end

-- getAdditional: resolve customEntries for a container (default empty)
local function MakeGetAdditional(env)
    return function(containerKey)
        if env.resolveAdditional then
            return env.resolveAdditional(containerKey) or {}
        end
        return {}
    end
end

-- exposed for unit tests
CDMReanchorBoot._MakePositionOwned = MakePositionOwned
CDMReanchorBoot._MakeApplySize = MakeApplySize
CDMReanchorBoot._MakeMintOwned = MakeMintOwned
CDMReanchorBoot._MakeGetAdditional = MakeGetAdditional

function CDMReanchorBoot.BuildRuntime(env)
    local bridge = env.CDMReanchor.New({ sinkAnchor = env.uiParent })
    local wiring = env.CDMReanchorWiring.New({ bridge = bridge, index = env.index })
    local runtime
    -- Swipe colour helpers: re-assert the QUI swipe colour on the re-anchored
    -- Blizzard cooldown widget via the SetSwipeColor hook (non-secret only).
    -- Colours come from the live cooldownSwipe settings via cdm_effects so
    -- re-anchored frames honour the same swipeColor the user set for owned icons.
    local function swipeSettings()
        return (ns._OwnedSwipe and ns._OwnedSwipe.GetSettings and ns._OwnedSwipe.GetSettings()) or {}
    end
    -- Hide Cooldown Effects: a container flagged in profile.cooldownEffects
    -- suppresses swipe + edge on its icons. Reanchored Blizzard builtins ride
    -- this via the existing re-assert bodies below (reassertColor / reassertEdge),
    -- driving SetDrawSwipe(false)+SetDrawEdge(false) additively; both setters are
    -- AllowedWhenTainted and the bodies already run under the aura-phase owner's
    -- securecall. Lazily reads ns._OwnedSwipe so load order doesn't matter.
    local function effectsHidden(containerKey)
        local swipe = ns._OwnedSwipe
        return swipe and swipe.IsContainerEffectsHidden
            and swipe.IsContainerEffectsHidden(containerKey) or false
    end
    local function modeColor(mode)
        if ns._CDM_ResolveModeColor then return ns._CDM_ResolveModeColor(swipeSettings(), mode) end
        if mode == "aura" then return 0.93, 0.77, 0.0, 0.45 end
        return 0, 0, 0, 0.8
    end
    -- Visibility for the current NON-aura swipe, honouring the SEPARATE GCD toggle.
    -- Blizzard sets isOnGCD only while the global cooldown is the SOLE active
    -- cooldown (a real spell cooldown clears it), so isOnGCD==true means a bare GCD
    -- flash -> gate on showGCDSwipe (default OFF), matching owned icons. isOnGCD can
    -- be secret in combat; fall back to the cooldown toggle so a real cooldown is
    -- never hidden.
    local function cooldownShown(frame)
        local s = swipeSettings()
        local g = frame and frame.isOnGCD
        if _issecretvalue(g) then return s.showCooldownSwipe ~= false end
        if g == true then return s.showGCDSwipe == true end
        return s.showCooldownSwipe ~= false
    end
    local function isAuraPhaseEnabled()
        local s = ns._OwnedSwipe and ns._OwnedSwipe.GetSettings and ns._OwnedSwipe.GetSettings()
        return not (s and s.showCooldownIconAuraPhase == false)
    end
    -- BuffIcon container keys. BuffIcon items are ALWAYS aura displays but never
    -- set the cooldownUseAuraDisplayTime FIELD (CooldownViewerBuffIconItemMixin
    -- refreshes via its own RefreshCooldownInfo, not RefreshSpellCooldownInfo,
    -- which is the only writer of that field) -- so the generic branch below
    -- would misclassify them as plain cooldown swipes. The aura-phase owner
    -- threads the container key through so these frames route to the owned
    -- buff-child rules (cdm_effects ApplySwipeToBuffChild): showBuffIconSwipe
    -- gate + aura colour, and NEVER the aura-phase-off timing restyle -- the
    -- buff IS the aura; there is no real cooldown display behind it to re-bind.
    local function isBuffIconFrameKey(key)
        return key == "buff" or key == "buffIcon"
    end
    -- Honour showCooldownIconAuraPhase=false on a re-anchored NATIVE frame: re-bind
    -- the widget to the spell's REAL cooldown via a duration object so the icon
    -- shows recharge instead of the buff. Blizzard's refresh orders SetSwipeColor
    -- BEFORE the timing write (CooldownViewer.lua:1166 vs :1169), so the re-bind
    -- only sticks when fired from the aura-phase owner's SetCooldown post-hook --
    -- the LAST timing write in the refresh sequence (the colour-hook pass still
    -- runs, its re-bind is simply overwritten and then redone from SetCooldown).
    -- Taint class matches the decorate pass: the duration object is an opaque
    -- handle (GetSpellCooldownDuration is AllowedWhenTainted, no secret reads) and
    -- every setter here takes non-secret args only. spellID comes from the curated
    -- entry, NOT frame:GetSpellID() -- that getter returns a SECRET in aura phase.
    -- Real-cooldown duration object for a claimed native frame: spell CD first
    -- (ignoreGCD -- bare-GCD flashes never replace the aura display), charge
    -- recharge fallback for partial-charge spells, matching Blizzard's own
    -- charges > spell-cooldown precedence outside the aura phase. spellID comes
    -- from the curated entry via the runtime registry -- frame:GetSpellID()
    -- returns a SECRET in aura phase. nil when the frame is unclaimed or the
    -- spell has no cooldown rolling behind the buff.
    local function queryRealCooldownDurObj(frame)
        local entry = runtime and runtime.GetEntryForFrame and runtime:GetEntryForFrame(frame)
        if not entry then return nil end
        -- Item-backed entries (trinket/slot/item/macro): entry.id is an ITEM or
        -- SLOT id, never a spellID -- feeding it to the spell queries below
        -- returned nil and the restyle cleared the widget (trinket read "ready"
        -- + bright with no swipe during its proc). Route through the resolvers'
        -- owned-icon item resolution instead (slot -> item -> use-spell).
        local entryType = entry.type
        if entryType == "item" or entryType == "trinket" or entryType == "slot"
            or entryType == "macro" then
            local R = ns.CDMResolvers
            if R and R.BuildEntryItemDurationObject then
                return R.BuildEntryItemDurationObject(entry)
            end
            return nil
        end
        local spellID
        if entryType == "consumable" then
            -- Categorized consumable (potion/healthstone): entry.id is a SPELL
            -- CATEGORY id. The index maps it back to the cooldown-set entry whose
            -- primarySpellID drives the shared category cooldown (nil for pure
            -- item cooldowns -> no re-bind, clear-to-ready like the no-CD case).
            local Index = ns.CDMIndex
            local indexEntry = Index and Index.GetByCategory and Index.GetByCategory(entry.id)
            spellID = indexEntry and indexEntry.primarySpellID
        else
            spellID = entry.overrideSpellID or entry.spellID or entry.id
        end
        if _issecretvalue(spellID) or type(spellID) ~= "number" then return nil end
        local Sources = ns.CDMSources
        if not Sources then return nil end
        local durObj
        if Sources.QuerySpellCooldownDuration then
            durObj = Sources.QuerySpellCooldownDuration(spellID, true)
        end
        if not durObj and Sources.QuerySpellChargeDuration then
            durObj = Sources.QuerySpellChargeDuration(spellID)
        end
        return durObj
    end
    local function restyleAuraPhaseAsCooldown(frame, cd)
        local durObj = queryRealCooldownDurObj(frame)
        if cd.SetUseAuraDisplayTime then cd:SetUseAuraDisplayTime(false) end
        if durObj and cd.SetCooldownFromDurationObject then
            local clearIfZero = true -- spell ready behind the buff -> clear to ready
            cd:SetCooldownFromDurationObject(durObj, clearIfZero)
            if swipeSettings().showCooldownSwipe ~= false then
                local r, g, b, a = modeColor("cooldown")
                cd:SetSwipeColor(r, g, b, a)
            else
                cd:SetSwipeColor(0, 0, 0, 0)
            end
        else
            -- No curated entry / no duration-object API: suppress the aura display
            -- outright rather than showing a phase the user disabled.
            if cd.Clear then cd:Clear() end
            cd:SetSwipeColor(0, 0, 0, 0)
        end
    end
    -- Re-assert for the SetSwipeColor hook: aura phase + setting on -> QUI aura
    -- colour over Blizzard's native aura timing; aura phase + setting off -> re-bind
    -- to the real cooldown (above); otherwise the cooldown colour, or alpha-0 when
    -- the cooldown swipe is disabled. Colour writes can't fight Blizzard's swipe
    -- geometry; the aura-off re-bind is the one deliberate timing write.
    local function reassertColor(frame, cd, containerKey)
        if not (cd and cd.SetSwipeColor) then return end
        -- Hide Cooldown Effects wins over every colour/timing branch: alpha-0 the
        -- swipe and drop draw swipe+edge so the reanchored builtin matches a hidden
        -- owned icon. Same direct-method posture as the rest of this body (already
        -- securecall-wrapped by the aura-phase owner's colorWork).
        if effectsHidden(containerKey) then
            cd:SetSwipeColor(0, 0, 0, 0)
            if cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
            if cd.SetDrawEdge then cd:SetDrawEdge(false) end
            return
        end
        if isBuffIconFrameKey(containerKey) then
            if swipeSettings().showBuffIconSwipe == false then
                cd:SetSwipeColor(0, 0, 0, 0)
            else
                local r, g, b, a = modeColor("aura")
                cd:SetSwipeColor(r, g, b, a)
            end
            return
        end
        if frame.cooldownUseAuraDisplayTime == true then
            if isAuraPhaseEnabled() then
                local r, g, b, a = modeColor("aura")
                cd:SetSwipeColor(r, g, b, a)
            else
                restyleAuraPhaseAsCooldown(frame, cd)
            end
        elseif cooldownShown(frame) then
            local r, g, b, a = modeColor("cooldown")
            cd:SetSwipeColor(r, g, b, a)
        else
            cd:SetSwipeColor(0, 0, 0, 0)
        end
    end
    -- Saturation re-assert for the SetDesaturated hook. Blizzard's aura phase
    -- forces the icon BRIGHT (cooldownDesaturated=false, re-written every
    -- RefreshData AFTER the timing refresh), so a restyled icon read as "ready"
    -- while its real cooldown rolled. When the aura-phase-off restyle owns the
    -- display, re-drive saturation the owned-icon way (cdm_icon_renderer
    -- ApplyCooldownDesaturation): bind the real-CD duration object through the
    -- shared step curve into SetDesaturation -- dark while the CD rolls, bright
    -- the instant it hits zero, sampled C-side with no secret reads. No real CD
    -- behind the buff -> leave Blizzard's bright write (matches clear-to-ready).
    -- Boolean SetDesaturated(true) fallback when CurveUtil is unavailable (its
    -- re-fire of the hook is re-entry guarded in the aura-phase owner).
    local function reassertDesat(frame, tex)
        if not tex then return end
        if frame.cooldownUseAuraDisplayTime ~= true or isAuraPhaseEnabled() then return end
        local durObj = queryRealCooldownDurObj(frame)
        if not durObj then return end
        local curve = ns._CDM_GetCooldownDesatCurve and ns._CDM_GetCooldownDesatCurve()
        if curve and durObj.EvaluateRemainingPercent and tex.SetDesaturation then
            tex:SetDesaturation(durObj:EvaluateRemainingPercent(curve))
        elseif tex.SetDesaturated then
            tex:SetDesaturated(true)
        end
    end
    -- G13: edge-only re-assert for the SetDrawEdge hook. Blizzard re-enables the bright
    -- leading recharge edge (cooldownShowDrawEdge=true) for charge spells on every
    -- refresh; when the owned-icon showRechargeEdge setting is off we re-hide it so
    -- re-anchored multi-charge icons match owned ones (cdm_effects.lua:1820 reads the
    -- same non-secret field). When the setting is ON we leave Blizzard's edge untouched.
    -- SetDrawEdge is AllowedWhenTainted (taint-safe); no secret read, no timing write.
    local function reassertEdge(_frame, cd, containerKey)
        if not (cd and cd.SetDrawEdge) then return end
        -- Hide Cooldown Effects: drop the recharge edge outright (the colour hook's
        -- companion re-assert already alpha-0'd + un-drew the swipe).
        if effectsHidden(containerKey) then
            cd:SetDrawEdge(false)
            return
        end
        local s = swipeSettings()
        if isBuffIconFrameKey(containerKey) then
            -- Owned buff-child rule: edge rides the buff swipe toggles
            -- (showBuffIconSwipe + showBuffEdge, both default ON), not the
            -- cooldown-icon showRechargeEdge setting.
            if s.showBuffIconSwipe == false or s.showBuffEdge == false then
                cd:SetDrawEdge(false)
            end
            return
        end
        if s.showRechargeEdge then return end   -- user wants the edge
        cd:SetDrawEdge(false)
    end
    local auraPhase = ns.CDMReanchorAuraPhase and ns.CDMReanchorAuraPhase.New({
        securecall = securecallfunction,
        isAuraPhaseEnabled = isAuraPhaseEnabled,
        reassertColor = reassertColor,
        reassertEdge = reassertEdge,
        reassertDesat = reassertDesat,
    })
    -- Pandemic bridge: Blizzard's own ShowPandemicStateFrame/HidePandemicStateFrame
    -- per-frame state machine drives QUI's pandemic flash on the shared own-child
    -- glow overlay (same overlay the proc bridge paints). Settings gate + painter
    -- live in cdm_effects (ns._OwnedGlows); all deps resolve lazily so load order
    -- and runtime construction order don't matter (`runtime` is assigned below --
    -- the closure captures the upvalue, same pattern as queryRealCooldownDurObj).
    local pandemic = ns.CDMReanchorPandemic and ns.CDMReanchorPandemic.New({
        securecall = securecallfunction,
        getEntryForFrame = function(frame)
            return runtime and runtime.GetEntryForFrame and runtime:GetEntryForFrame(frame) or nil
        end,
        ensureOverlay = function(frame)
            local ensure = ns._CDMEnsureReanchorGlowOverlay
            return ensure and ensure(frame) or nil
        end,
        isPandemicEnabled = function(entry)
            local OG = ns._OwnedGlows
            if OG and OG.IsPandemicEnabledForEntry then
                return OG.IsPandemicEnabledForEntry(entry)
            end
            return false
        end,
        startPandemic = function(overlay)
            local OG = ns._OwnedGlows
            if OG and OG.ApplyPandemicToOverlay then OG.ApplyPandemicToOverlay(overlay) end
        end,
        stopPandemic = function(overlay)
            local OG = ns._OwnedGlows
            if OG and OG.ClearPandemicFromOverlay then OG.ClearPandemicFromOverlay(overlay) end
        end,
    })
    runtime = env.CDMReanchorRuntime.New({
        bridge = bridge,
        wiring = wiring,
        placementPlanner = env.CDMPlacementPlanner or ns.CDMPlacementPlanner,
        auraPhase = auraPhase,
        pandemic = pandemic,
        -- Proc-glow bridge OnClaim reconcile. The instance is built lazily in
        -- cdm_containers (InstallReanchorProcGlowHooks, gated on the
        -- ActionButtonSpellAlertManager global existing), so resolve it per claim
        -- instead of capturing it here -- it may not exist when the runtime is
        -- constructed. A re-pooled frame never fires HideAlert for its old spell,
        -- so the claim pass must drop the stale proc glow (same as pandemic).
        getProcGlow = function()
            return ns._cdmReanchorProcGlow
        end,
        getContainer = env.getContainer,
        getCurated = env.getCurated,
        getSettings = env.getSettings,
        getAdditional = MakeGetAdditional(env),
        buildLayout = env.buildLayout,
        buildBuffLayout = env.buildBuffLayout,
        frameIsActive = env.frameIsActive,
        -- Aura ground truth for non-Blizzard/custom BuffIcon owned fallbacks.
        -- Blizzard-CDM buff entries are native-only in the reanchor runtime.
        entryAuraIsPresent = env.entryAuraIsPresent,
        inCombat = env.inCombat,
        -- Frame-independent protected-mutation gate (realenv canMutateProtectedShells):
        -- true OOC / init-safe window, false in combat. The runtime defers a whole
        -- refresh pass when this is false AND the container's owned icons carry a
        -- secure clickButton (else Factory recycle Hides a protected parent).
        canMutate = env.canMutate,
        isEditMode = env.isEditMode,
        pixelRound = env.pixelRound,
        mintOwned = MakeMintOwned(env),
        -- Ghost fix: each pass releases the previous pass's minted owned icons
        -- (Factory recycle) before re-minting, so frameless/additional icons
        -- can't pile up Show()n at stale slots.
        releaseOwned = env.releaseIcon,
        positionOwned = MakePositionOwned(env),
        acquireAuraMirror = env.acquireAuraMirror,
        positionAuraMirror = env.positionAuraMirror,
        beginAuraMirrorPass = env.beginAuraMirrorPass,
        endAuraMirrorPass = env.endAuraMirrorPass,
        applySize = MakeApplySize(env),
        decorate = env.decorate,
        mintShell = env.mintShell,
        positionShell = env.positionShell,
        positionClickSlot = env.positionClickSlot,
        -- Native direct-anchor tooltip overlay: all matched native frames use a
        -- QUI-owned hover child on the live frame; Essential/Utility click handling
        -- lives on separate container slot hosts.
        ensureLiveTooltip = env.ensureLiveTooltip,
        -- Teardown companion: tear down the direct-anchor overlay for sunk frames so
        -- alpha-0 frames no longer catch the mouse (phantom tooltip / dead-zone fix).
        hideLiveTooltip = env.hideLiveTooltip,
        updateClickOverlay = env.updateClickOverlay,
        beginShellPass = env.beginShellPass,
        endShellPass = env.endShellPass,
        resetShells = env.resetShells,
    })
    return {
        bridge = bridge,
        wiring = wiring,
        runtime = runtime,
        RefreshBuiltin = function(_, containerKey)
            return runtime:RefreshContainer(containerKey)
        end,
        -- Atomic global placement pass used by live built-in layout and hook
        -- churn. RefreshBuiltin remains as a narrow compatibility/test seam.
        RefreshBuiltins = function(_, containerKeys)
            return runtime:RefreshContainers(containerKeys)
        end,
        -- PLAYER_REGEN_ENABLED drain: re-run every container whose combat refresh
        -- was deferred by the protected-owned gate.
        DrainPendingCombatRefresh = function(_)
            return runtime:DrainPendingCombatRefresh()
        end,
        -- Per-frame feature registry accessors (keybinds / rotation glow over the
        -- re-anchored Blizzard frames, which aren't QUI-container children).
        GetReanchoredFrames = function(_, containerKey)
            return runtime:GetReanchoredFrames(containerKey)
        end,
        GetEntryForFrame = function(_, frame)
            return runtime:GetEntryForFrame(frame)
        end,
        GetPlacementsForFrame = function(_, frame)
            return runtime:GetPlacementsForFrame(frame)
        end,
    }
end
