-- QUI_CDM/cdm/cdm_reanchor_realenv.lua
-- Wires the re-anchor boot env to the live ns modules + WoW globals. The three
-- cdm_containers-internal deps (getSettings/resolveAdditional/onMetrics) are
-- injected via ctx at the Initialize call site. Used by the guarded construction
-- of ns._cdmBoot; the runtime stays inert until the LayoutContainer splice (2b-4).
local _, ns = ...

local CDMReanchorRealEnv = {}
ns.CDMReanchorRealEnv = CDMReanchorRealEnv

-- Item-frame-level mutations on a re-anchored Blizzard CDM frame (SetFrameStrata/
-- SetFrameLevel via the shell lift, SetIgnoreParentAlpha + native countdown SetFont
-- inside Decorate) taint the secret-tracked CooldownViewer item when run from
-- insecure code -- Blizzard's own per-item OnEvent refresh then throws on secret
-- cooldown/aura values (compare/arithmetic). Running the whole decorate pass under
-- securecall attributes the writes to a secure context, matching the re-anchor
-- reference addons (one securecalls the same strata/level ops; another avoids them
-- entirely). Child-widget restyle (swipe/icon crop) is taint-safe either way --
-- folded under the one boundary so there is a single, unambiguous chokepoint.
local _securecall = securecallfunction or function(fn, ...) return fn(...) end

local function _DecorateWork(decorator, live, shell, rowConfig)
    if shell and live.SetFrameStrata and shell.GetFrameStrata then
        live:SetFrameStrata(shell:GetFrameStrata())
        if live.SetFrameLevel and shell.GetFrameLevel then
            live:SetFrameLevel(shell:GetFrameLevel() + 1)
        end
    end
    return decorator:Decorate(live, rowConfig)
end

function CDMReanchorRealEnv.BuildEnv(ctx)
    ctx = ctx or {}
    local Containers = ctx.CDMContainers or ns.CDMContainers
    local SpellData  = ctx.CDMSpellData or ns.CDMSpellData
    local Layout     = ctx.CDMLayout or ns.CDMLayout
    local Icons      = ctx.CDMIcons or ns.CDMIcons
    local Factory    = ctx.CDMIconFactory or ns.CDMIconFactory
    local Core       = ctx.core or _G.QUI
    local DecorateMod = ctx.CDMReanchorDecorate or ns.CDMReanchorDecorate

    -- One decorator per runtime. The Blizzard frame is decorated CHROME-ONLY:
    -- neutralize its native chrome + apply the QUI font to its NATIVE count/countdown.
    -- It keeps rendering its own icon/swipe/count (cheap -- no per-tick API cooldown).
    -- The QUI border lives on the chrome SHELL beneath it (StyleShell), never on the
    -- Blizzard frame, so nothing is written onto Blizzard-owned objects.
    local Helpers = ns.Helpers
    local decorate
    if DecorateMod and DecorateMod.New then
        local decorator = DecorateMod.New({
            -- Lift the overlaid child above the parked viewer's alpha-0.
            lift = function(frame)
                if frame.SetIgnoreParentAlpha then frame:SetIgnoreParentAlpha(true) end
                if frame.SetAlpha then frame:SetAlpha(1) end
            end,
            hideRegion = function(frame, name)
                local region = frame[name]
                if region and region.SetAlpha then region:SetAlpha(0) end
            end,
            applyChrome = function(frame, rowConfig)
                -- Strip native Blizzard item chrome (IconOverlay bevel, OOR shadow,
                -- rounding mask) and crop the icon to QUI zoom. Runs every pass:
                -- Blizzard re-asserts the icon texcoord when it swaps the spell icon.
                if Icons and Icons.NeutralizeBlizzardItemChrome then
                    Icons.NeutralizeBlizzardItemChrome(frame, rowConfig)
                end
                if type(rowConfig) ~= "table" then return end
                local cd = frame.Cooldown
                -- Match the owned-icon swipe (cdm_icon_factory CreateIconBare) so matched
                -- (native Blizzard swipe) and additional (QUI swipe) icons render identically;
                -- kill the ready-flash bling (QUI uses its own glow systems).
                if cd then
                    if cd.SetSwipeTexture then cd:SetSwipeTexture("Interface\\Buttons\\WHITE8X8") end
                    if cd.SetSwipeColor then cd:SetSwipeColor(0, 0, 0, 0.8) end
                    if cd.SetDrawBling then cd:SetDrawBling(false) end
                end
                -- QUI font on the NATIVE cooldown countdown + count text.
                if Helpers and Helpers.ApplyFontWithFallback and Helpers.GetGeneralFont then
                    local font = Helpers.GetGeneralFont()
                    local outline = Helpers.GetGeneralFontOutline and Helpers.GetGeneralFontOutline()
                    if font then
                        if cd and cd.GetCountdownFontString then
                            local fs = cd:GetCountdownFontString()
                            if fs then Helpers.ApplyFontWithFallback(fs, font, rowConfig.durationSize or 14, outline) end
                        end
                        local count = (frame.ChargeCount and frame.ChargeCount.Current)
                            or (frame.Applications and frame.Applications.Applications)
                        if count then Helpers.ApplyFontWithFallback(count, font, rowConfig.stackSize or 14, outline) end
                    end
                end
            end,
        })
        decorate = function(live, shell, rowConfig)
            -- Render the Blizzard frame above its shell (viewer child, different parent
            -- chain -> strata/level set explicitly, not parent-derived) then chrome-
            -- decorate it. The whole pass runs under securecall so the item-level
            -- strata/level/IgnoreParentAlpha/font writes do not taint the secret-tracked
            -- CDM frame's native OnEvent refresh. See _DecorateWork.
            return _securecall(_DecorateWork, decorator, live, shell, rowConfig)
        end
    end

    -- Lightweight chrome shells: per-slot QUI border frames that anchor the
    -- two-point-stretched Blizzard frame inside the container's scale chain. NOT
    -- owned icons (never added to the factory iconPools -> never ticked -> zero
    -- per-frame CPU). Pooled per container; reused across refreshes, surplus hidden
    -- only after a generation pass proves it is stale.
    local shellPools = setmetatable({}, { __mode = "k" })
    local function getShellPool(container)
        local p = shellPools[container]
        if not p then p = { list = {}, used = 0, generation = 0 }; shellPools[container] = p end
        return p
    end

    local function isInCombatLockdown()
        if ctx.isInCombat then return ctx.isInCombat() end
        return (InCombatLockdown and InCombatLockdown()) or false
    end

    local function isInitSafeWindow()
        if ctx.isInitSafeWindow then return ctx.isInitSafeWindow() end
        return ns._inInitSafeWindow == true
    end

    local function canMutateProtectedShells()
        return (not isInCombatLockdown()) or isInitSafeWindow()
    end

    local function hideShell(shell)
        if not shell then return end
        local overlay = shell._quiCdmHoverOverlay
        if overlay and overlay.Hide and ((not overlay.IsShown) or overlay:IsShown()) then
            overlay:Hide()
        end
        if shell.Hide and ((not shell.IsShown) or shell:IsShown()) then
            shell:Hide()
        end
        shell._spellEntry = nil
        shell._quiTooltipContext = nil
        shell.__quiTooltipContext = nil
        shell.__customTrackerIcon = nil
    end

    local function beginShellPass(container)
        local p = getShellPool(container)
        p.generation = (p.generation or 0) + 1
        p.used = 0
        return p.generation
    end

    local function endShellPass(container)
        local p = shellPools[container]
        if not p then return true end
        if not canMutateProtectedShells() then
            p.cleanupPending = true
            return false
        end
        local generation = p.generation or 0
        for i = 1, #p.list do
            local shell = p.list[i]
            if shell and shell._quiCdmShellGeneration ~= generation then
                hideShell(shell)
            end
        end
        p.cleanupPending = nil
        return true
    end

    local function resetShells(container)
        local p = shellPools[container]
        if not p then return end
        if not canMutateProtectedShells() then
            p.cleanupPending = true
            return false
        end
        for i = 1, #p.list do
            local s = p.list[i]
            hideShell(s)
        end
        p.used = 0
        return true
    end
    local function getContainerFor(key)
        if Containers and Containers.GetContainer then return Containers.GetContainer(key) end
        return nil
    end

    local function getShellTooltipContext(_containerKey)
        return "cdm"
    end

    local function runShellTooltipScript(shell, scriptName)
        if not (shell and shell.GetScript) then return end
        local script = shell:GetScript(scriptName)
        if script then script(shell) end
    end

    local function ensureHoverOverlay(shell)
        if not (shell and shell.CreateTexture and CreateFrame) then return nil end
        local overlay = shell._quiCdmHoverOverlay
        if not overlay then
            overlay = CreateFrame("Frame", nil, shell)
            overlay._quiCdmHoverOverlay = true
            overlay:SetAllPoints(shell)
            overlay:EnableMouse(true)
            if overlay.SetMouseClickEnabled then
                overlay:SetMouseClickEnabled(false)
            end
            if overlay.SetMouseMotionEnabled then
                overlay:SetMouseMotionEnabled(true)
            end
            overlay:SetScript("OnEnter", function(self)
                runShellTooltipScript(self:GetParent(), "OnEnter")
            end)
            overlay:SetScript("OnLeave", function(self)
                runShellTooltipScript(self:GetParent(), "OnLeave")
            end)
            shell._quiCdmHoverOverlay = overlay
        end
        overlay:SetAllPoints(shell)
        overlay:Show()
        return overlay
    end

    local function raiseHoverOverlay(shell)
        local overlay = shell and shell._quiCdmHoverOverlay
        if not overlay then return end
        if overlay.SetFrameStrata and shell.GetFrameStrata then
            overlay:SetFrameStrata(shell:GetFrameStrata())
        end
        if overlay.SetFrameLevel and shell.GetFrameLevel then
            overlay:SetFrameLevel(shell:GetFrameLevel() + 4)
        end
    end

    local function ensureShellTooltip(shell)
        if not shell then return end
        if not shell._quiCdmTooltipWired then
            shell._quiCdmTooltipWired = true
            shell:EnableMouse(true)
            if shell.SetMouseClickEnabled then
                shell:SetMouseClickEnabled(false)
            end
            if shell.SetMouseMotionEnabled then
                shell:SetMouseMotionEnabled(true)
            end
            shell:SetScript("OnEnter", function(self)
                local Factory = ns.CDMIconFactory
                if Factory and Factory.ShowEntryTooltip then
                    Factory.ShowEntryTooltip(self, self._spellEntry, self._quiTooltipContext or "cdm")
                end
            end)
            shell:SetScript("OnLeave", function()
                local Factory = ns.CDMIconFactory
                if Factory and Factory.HideEntryTooltip then
                    Factory.HideEntryTooltip()
                elseif GameTooltip and GameTooltip.Hide then
                    GameTooltip.Hide(GameTooltip)
                end
            end)
        end
        ensureHoverOverlay(shell)
    end

    local function mintShell(_entry, containerKey)
        local container = getContainerFor(containerKey)
        if not (container and container.CreateTexture) then return nil end
        local p = getShellPool(container)
        local nextIndex = (p.used or 0) + 1
        local shell = p.list[nextIndex]
        if not shell then
            if not canMutateProtectedShells() then
                p.cleanupPending = true
                return nil
            end
            shell = CreateFrame("Frame", nil, container)
            shell._quiCdmShell = true
            shell.Border = shell:CreateTexture(nil, "BACKGROUND", nil, -8)
            p.list[nextIndex] = shell
        elseif shell.IsShown and not shell:IsShown() and not canMutateProtectedShells() then
            p.cleanupPending = true
            return nil
        end
        p.used = nextIndex
        shell._quiCdmShellGeneration = p.generation or 0
        local tooltipContext = getShellTooltipContext(containerKey)
        shell._spellEntry = _entry
        shell._quiTooltipContext = tooltipContext
        shell.__quiTooltipContext = tooltipContext
        shell.__customTrackerIcon = nil
        if canMutateProtectedShells() then
            ensureShellTooltip(shell)
        end
        if shell.Show and ((not shell.IsShown) or not shell:IsShown()) then
            shell:Show()
        end
        return shell
    end
    local function positionShell(shell, container, x, y, w, h, rowConfig)
        if not (shell and shell.ClearAllPoints) then return end
        if not canMutateProtectedShells() then
            return false
        end
        shell:ClearAllPoints()
        shell:SetPoint("CENTER", container, "CENTER", x, y)
        if w and h and shell.SetSize then shell:SetSize(w, h) end
        -- QUI border: SAME skin-border resolver as owned icons -> uniform chrome.
        local borderSize = (type(rowConfig) == "table" and rowConfig.borderSize) or 0
        local tex = shell.Border
        if borderSize > 0 and tex then
            local bs = (Core and Core.Pixels) and Core:Pixels(borderSize, shell) or borderSize
            local r, g, b, a = 0, 0, 0, 1
            if Helpers and Helpers.GetSkinBorderColor then
                r, g, b, a = Helpers.GetSkinBorderColor(rowConfig, "")
            end
            tex:SetColorTexture(r, g, b, a)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", shell, "TOPLEFT", -bs, bs)
            tex:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", bs, -bs)
            tex:Show()
        elseif tex then
            tex:Hide()
        end
        raiseHoverOverlay(shell)
        return true
    end
    local function updateClickOverlay(shell, entry, viewerType)
        if Icons and Icons.UpdateSecureClickOverlay then
            Icons.UpdateSecureClickOverlay(shell, entry, viewerType)
        end
    end

    return {
        CDMReanchor        = ns.CDMReanchor,
        CDMReanchorWiring  = ns.CDMReanchorWiring,
        CDMReanchorRuntime = ns.CDMReanchorRuntime,
        uiParent = ctx.uiParent or _G.UIParent,
        index = ctx.CDMIndex or ns.CDMIndex,
        getContainer = function(key)
            if Containers and Containers.GetContainer then return Containers.GetContainer(key) end
            return nil
        end,
        getCurated = function(key)
            if SpellData and SpellData.BuildSpellListFromOwned then
                return SpellData:BuildSpellListFromOwned(key)
            end
            return {}
        end,
        getSettings = ctx.getSettings,
        resolveAdditional = ctx.resolveAdditional or function() return {} end,
        onMetrics = ctx.onMetrics,
        buildLayout = Layout and Layout.BuildIconLayout or nil,
        pixelRound = function(v, c)
            if Core and Core.PixelRound then return Core:PixelRound(v, c) end
            return v
        end,
        acquireIcon = function(c, e)
            if Factory and Factory.AcquireIcon then return Factory:AcquireIcon(c, e) end
            return nil
        end,
        onIconPlaced = function(icon, rowConfig)
            if Icons and Icons.OnContainerIconPlaced then Icons.OnContainerIconPlaced(icon, rowConfig) end
        end,
        decorate = decorate,
        mintShell = mintShell,
        positionShell = positionShell,
        updateClickOverlay = updateClickOverlay,
        beginShellPass = beginShellPass,
        endShellPass = endShellPass,
        resetShells = resetShells,
    }
end
