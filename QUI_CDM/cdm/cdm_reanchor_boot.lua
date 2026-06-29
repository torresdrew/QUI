-- QUI_CDM/cdm/cdm_reanchor_boot.lua
-- Real-dep boot factory for the re-anchor engine. Wires the bridge + wiring +
-- runtime to the live WoW-side deps (container registry, curated spell list,
-- CDMIndex, BuildIconLayout, PixelRound, owned-icon factory, customEntries).
-- Inert until Phase 2b-3 constructs it and splices the LayoutContainer call.
local _, ns = ...

local CDMReanchorBoot = {}
ns.CDMReanchorBoot = CDMReanchorBoot

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
-- throws ADDON_ACTION_BLOCKED. Gate on env.canMutate exactly like the sibling shell deps
-- (mintShell / positionShell / begin-endShellPass / resetShells all short-circuit on the same
-- combat predicate); the deferred resize is recovered by the PLAYER_REGEN_ENABLED RefreshAll,
-- which re-runs this pass out of combat. The pcall is a final guard so an unforeseen protected
-- edge cannot reach the error handler. The metrics stash (onMetrics) is plain Lua bookkeeping
-- (viewerState fields + ncdm._last* persistence, no protected calls) -- it always runs.
local function MakeApplySize(env)
    return function(container, metrics)
        local w = metrics.iconWidth or 0
        local h = metrics.totalHeight or 0
        if w > 0 and h > 0 and ((not env.canMutate) or env.canMutate()) then
            pcall(container.SetSize, container, w, h)
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
        return env.acquireIcon(container, entry)
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
    local runtime = env.CDMReanchorRuntime.New({
        bridge = bridge,
        wiring = wiring,
        getContainer = env.getContainer,
        getCurated = env.getCurated,
        getSettings = env.getSettings,
        getAdditional = MakeGetAdditional(env),
        buildLayout = env.buildLayout,
        pixelRound = env.pixelRound,
        mintOwned = MakeMintOwned(env),
        positionOwned = MakePositionOwned(env),
        applySize = MakeApplySize(env),
        decorate = env.decorate,
        mintShell = env.mintShell,
        positionShell = env.positionShell,
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
        -- Per-frame feature registry accessors (keybinds / rotation glow over the
        -- re-anchored Blizzard frames, which aren't QUI-container children).
        GetReanchoredFrames = function(_, containerKey)
            return runtime:GetReanchoredFrames(containerKey)
        end,
        GetEntryForFrame = function(_, frame)
            return runtime:GetEntryForFrame(frame)
        end,
    }
end
