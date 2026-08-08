local ADDON_NAME, ns = ...
local env = ns.ActionBarsEnv
env.ADDON_NAME = ADDON_NAME
env.ns = ns
env.SetChunkEnv(1, env)

---@diagnostic disable: lowercase-global -- SetChunkEnv installs a setfenv

IsInEditMode = ns.Helpers.IsEditModeShown

function GetBarFadeState(barKey)
    if not ActionBarsOwned.fadeState[barKey] then
        ActionBarsOwned.fadeState[barKey] = {
            isFading = false,
            currentAlpha = 1,
            targetAlpha = 1,
            fadeStart = 0,
            fadeStartAlpha = 1,
            fadeDuration = 0.3,
            isMouseOver = false,
            delayTimer = nil,
            leaveCheckTimer = nil,
        }
    end
    return ActionBarsOwned.fadeState[barKey]
end

function SetBarAlpha(barKey, alpha)
    if alpha < 1 and ShouldSuspendMouseoverFade(barKey) then
        alpha = 1
    end

    local buttons = GetBarButtons(barKey)
    local settings = GetGlobalSettings()
    local hideEmptyEnabled = settings and settings.hideEmptySlots

    for _, button in ipairs(buttons) do
        local state = GetFrameState(button)
        if hideEmptyEnabled and state.hiddenEmpty then
            button:SetAlpha(ActionBarsOwned.dragPreviewActive and (ActionBarsOwned.DRAG_PREVIEW_ALPHA * alpha) or 0)
        else
            button:SetAlpha(alpha)
        end

        local hidden = alpha <= 0 or (hideEmptyEnabled and state.hiddenEmpty)
        if hidden then
            FadeHideTextures(state, button)
        elseif state.fadeHidden then
            FadeShowTextures(state, button)
        end
    end

    local barFrame = GetBarFrame(barKey)
    if barFrame then
        barFrame:SetAlpha(alpha)
    end

    if barKey == "bar1" then
        ApplyLeaveVehicleButtonVisibilityOverride(alpha < 1 and ShouldKeepLeaveVehicleVisible())
    end

    GetBarFadeState(barKey).currentAlpha = alpha
end

function StartBarFade(barKey, targetAlpha)
    if targetAlpha < 1 and IsInEditMode() then return end
    if targetAlpha < 1 and ShouldSuspendMouseoverFade(barKey) then return end

    local state = GetBarFadeState(barKey)
    local fadeSettings = GetFadeSettings()

    local duration = targetAlpha > state.currentAlpha
        and (fadeSettings and fadeSettings.fadeInDuration or 0.2)
        or (fadeSettings and fadeSettings.fadeOutDuration or 0.3)

    if math.abs(state.currentAlpha - targetAlpha) < 0.01 then
        state.isFading = false
        return
    end

    state.isFading = true
    state.targetAlpha = targetAlpha
    state.fadeStart = GetTime()
    state.fadeStartAlpha = state.currentAlpha
    state.fadeDuration = duration

    if not ActionBarsOwned.fadeFrame then
        ActionBarsOwned.fadeFrame = CreateFrame("Frame")
        ActionBarsOwned.fadeFrame:SetScript("OnUpdate", function(self, elapsed)
            local now = GetTime()
            local anyFading = false

            for bKey, bState in pairs(ActionBarsOwned.fadeState) do
                if bState.isFading then
                    anyFading = true
                    local elapsedTime = now - bState.fadeStart
                    local progress = math.min(elapsedTime / bState.fadeDuration, 1)

                    local easedProgress = progress * (2 - progress)

                    local alpha = bState.fadeStartAlpha +
                        (bState.targetAlpha - bState.fadeStartAlpha) * easedProgress

                    SetBarAlpha(bKey, alpha)

                    if progress >= 1 then
                        bState.isFading = false
                        SetBarAlpha(bKey, bState.targetAlpha)
                    end
                end
            end

            if not anyFading then
                self:SetScript("OnUpdate", nil)
                self:Hide()
            end
        end)
        ActionBarsOwned.fadeFrameUpdate = ActionBarsOwned.fadeFrame:GetScript("OnUpdate")
    end
    ActionBarsOwned.fadeFrame:SetScript("OnUpdate", ActionBarsOwned.fadeFrameUpdate)
    ActionBarsOwned.fadeFrame:Show()
end

function IsMouseOverBar(barKey)
    local barFrame = GetBarFrame(barKey)
    if barFrame and barFrame:IsMouseOver() then
        return true
    end

    local buttons = GetBarButtons(barKey)
    for _, button in ipairs(buttons) do
        if button:IsMouseOver() then
            return true
        end
    end

    return false
end

do

function IsMouseOverAnyLinkedBar()
    for _, barKey in ipairs(STANDARD_BAR_KEYS) do
        if IsMouseOverBar(barKey) then
            return true
        end
    end
    return false
end

function ShowLinkedBarDirect(barKey)
    local barSettings = GetBarSettings(barKey)
    local fadeSettings = GetFadeSettings()

    if not barSettings then return end
    if ShouldForceShowForSpellBook() then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForActionBarContext(barKey) then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldSuppressMouseoverHideForLevel() then
        SetBarAlpha(barKey, 1)
        return
    end
    if barSettings.alwaysShow then return end

    local fadeEnabled = barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if not fadeEnabled then return end

    local state = GetBarFadeState(barKey)

    CancelBarFadeTimers(state)

    StartBarFade(barKey, 1)
end

function FadeLinkedBarDirect(barKey)
    if IsInEditMode() then return end

    local barSettings = GetBarSettings(barKey)
    local fadeSettings = GetFadeSettings()

    if not barSettings then return end
    if ShouldForceShowForSpellBook() then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForActionBarContext(barKey) then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldSuppressMouseoverHideForLevel() then
        SetBarAlpha(barKey, 1)
        return
    end
    if barSettings.alwaysShow then return end

    local fadeEnabled = barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if not fadeEnabled then return end

    local state = GetBarFadeState(barKey)
    state.isMouseOver = false

    local fadeOutAlpha = barSettings.fadeOutAlpha
    if fadeOutAlpha == nil then
        fadeOutAlpha = fadeSettings and fadeSettings.fadeOutAlpha or 0
    end

    local delay = fadeSettings and fadeSettings.fadeOutDelay or 0.5

    if state.delayTimer then
        state.delayTimer:Cancel()
    end

    local function TryLinkedFade()
        if ShouldForceShowForSpellBook() then
            SetBarAlpha(barKey, 1)
            state.delayTimer = nil
            return
        end
        if ShouldForceShowForActionBarContext(barKey) then
            SetBarAlpha(barKey, 1)
            state.delayTimer = nil
            return
        end

        if IsSpellFlyoutActiveForBar(barKey) then
            SetBarAlpha(barKey, 1)
            state.delayTimer = C_Timer.NewTimer(SPELL_UI_FADE_RECHECK_DELAY, TryLinkedFade)
            return
        end

        state.delayTimer = nil

        if not IsMouseOverAnyLinkedBar() then
            StartBarFade(barKey, fadeOutAlpha)
        end
    end

    state.delayTimer = C_Timer.NewTimer(delay, TryLinkedFade)
end

function IsExtraButtonBarFadeActive(barSettings)
    return (barSettings and barSettings.enabled == true
        and barSettings.fadeEnabled == true) or false
end

function OnBarMouseEnter(barKey)
    local state = GetBarFadeState(barKey)
    local fadeSettings = GetFadeSettings()
    local barSettings = GetBarSettings(barKey)

    if ShouldSuppressMouseoverHideForLevel() then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForSpellBook() then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForActionBarContext(barKey) then
        SetBarAlpha(barKey, 1)
        return
    end

    if barSettings and barSettings.alwaysShow then return end

    local fadeEnabled = barSettings and barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if barKey == "extraActionButton" or barKey == "zoneAbility" then
        fadeEnabled = IsExtraButtonBarFadeActive(barSettings)
    end
    if not fadeEnabled then return end

    state.isMouseOver = true

    if fadeSettings and fadeSettings.linkBars1to8 and IsLinkedBar(barKey) then
        for _, linkedKey in ipairs(LINKED_OWNED_BAR_KEYS) do
            if linkedKey ~= barKey then
                ShowLinkedBarDirect(linkedKey)
            end
        end
    end

    CancelBarFadeTimers(state)

    StartBarFade(barKey, 1)
end

function OnBarMouseLeave(barKey)
    if IsInEditMode() then return end

    local state = GetBarFadeState(barKey)
    local fadeSettings = GetFadeSettings()
    local barSettings = GetBarSettings(barKey)

    if ShouldSuppressMouseoverHideForLevel() then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForSpellBook() then
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForActionBarContext(barKey) then
        SetBarAlpha(barKey, 1)
        return
    end
    if barSettings and barSettings.alwaysShow then return end

    local isMainBar = barKey and barKey:match("^bar%d$")
    if isMainBar and InCombatLockdown() and fadeSettings and fadeSettings.alwaysShowInCombat then
        return
    end

    local fadeEnabled = barSettings and barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end
    if barKey == "extraActionButton" or barKey == "zoneAbility" then
        fadeEnabled = IsExtraButtonBarFadeActive(barSettings)
    end
    if not fadeEnabled then return end

    if state.leaveCheckTimer then
        state.leaveCheckTimer:Cancel()
    end

    state.leaveCheckTimer = C_Timer.NewTimer(0.066, function()
        state.leaveCheckTimer = nil

        if IsMouseOverBar(barKey) then return end
        if fadeSettings and fadeSettings.linkBars1to8 and IsLinkedBar(barKey) then
            if IsMouseOverAnyLinkedBar() then
                return
            end
            for _, linkedKey in ipairs(LINKED_OWNED_BAR_KEYS) do
                FadeLinkedBarDirect(linkedKey)
            end
            return
        end

        state.isMouseOver = false

        local fadeOutAlpha = barSettings and barSettings.fadeOutAlpha
        if fadeOutAlpha == nil then
            fadeOutAlpha = fadeSettings and fadeSettings.fadeOutAlpha or 0
        end

        local delay = fadeSettings and fadeSettings.fadeOutDelay or 0.5

        if state.delayTimer then
            state.delayTimer:Cancel()
        end

        local function TryFadeOut()
            if state.isMouseOver then
                state.delayTimer = nil
                return
            end

            if ShouldForceShowForSpellBook() then
                SetBarAlpha(barKey, 1)
                state.delayTimer = nil
                return
            end
            if ShouldForceShowForActionBarContext(barKey) then
                SetBarAlpha(barKey, 1)
                state.delayTimer = nil
                return
            end

            if IsSpellFlyoutActiveForBar(barKey) then
                SetBarAlpha(barKey, 1)
                state.delayTimer = C_Timer.NewTimer(SPELL_UI_FADE_RECHECK_DELAY, TryFadeOut)
                return
            end

            local freshBarSettings = GetBarSettings(barKey)
            local freshFadeSettings = GetFadeSettings()
            local freshFadeOutAlpha = freshBarSettings and freshBarSettings.fadeOutAlpha
            if freshFadeOutAlpha == nil then
                freshFadeOutAlpha = freshFadeSettings and freshFadeSettings.fadeOutAlpha or 0
            end
            StartBarFade(barKey, freshFadeOutAlpha)
            state.delayTimer = nil
        end

        state.delayTimer = C_Timer.NewTimer(delay, TryFadeOut)
    end)
end

function HookFrameForMouseover(frame, barKey)
    if not frame then return end
    local state = GetFrameState(frame)
    if state.mouseoverHooked then return end
    state.mouseoverHooked = true

    frame:HookScript("OnEnter", function()
        OnBarMouseEnter(barKey)
    end)

    frame:HookScript("OnLeave", function()
        OnBarMouseLeave(barKey)
    end)
end

function SetupBarMouseover(barKey)
    if IsInEditMode() then
        SetBarAlpha(barKey, 1)
        return
    end

    local barSettings = GetBarSettings(barKey)
    local fadeSettings = GetFadeSettings()
    local db = GetDB()

    if not db then return end

    if barKey == "extraActionButton" or barKey == "zoneAbility" then
        if not IsExtraButtonBarFadeActive(barSettings) then
            local state = GetBarFadeState(barKey)
            state.isFading = false
            CancelBarFadeTimers(state)
            SetBarAlpha(barKey, 1)
            return
        end
    end

    local state = GetBarFadeState(barKey)

    if ShouldSuppressMouseoverHideForLevel() then
        state.isFading = false
        CancelBarFadeTimers(state)
        SetBarAlpha(barKey, 1)
        return
    end

    if ShouldForceShowForSpellBook() then
        state.isFading = false
        CancelBarFadeTimers(state)
        SetBarAlpha(barKey, 1)
        return
    end
    if ShouldForceShowForActionBarContext(barKey) then
        state.isFading = false
        CancelBarFadeTimers(state)
        SetBarAlpha(barKey, 1)
        return
    end

    if barSettings and barSettings.alwaysShow then
        SetBarAlpha(barKey, 1)
        return
    end

    local fadeEnabled = barSettings and barSettings.fadeEnabled
    if fadeEnabled == nil then
        fadeEnabled = fadeSettings and fadeSettings.enabled
    end

    if not fadeEnabled then
        SetBarAlpha(barKey, 1)
        return
    end

    local fadeOutAlpha = barSettings and barSettings.fadeOutAlpha
    if fadeOutAlpha == nil then
        fadeOutAlpha = fadeSettings and fadeSettings.fadeOutAlpha or 0
    end

    local barFrame = GetBarFrame(barKey)
    if barFrame then
        HookFrameForMouseover(barFrame, barKey)
    end

    local buttons = GetBarButtons(barKey)
    for _, button in ipairs(buttons) do
        HookFrameForMouseover(button, barKey)
    end

    state.targetAlpha = fadeOutAlpha

    state.isFading = false
    if state.delayTimer then
        state.delayTimer:Cancel()
        state.delayTimer = nil
    end
    if state.leaveCheckTimer then
        state.leaveCheckTimer:Cancel()
        state.leaveCheckTimer = nil
    end

    if not IsMouseOverBar(barKey) then
        SetBarAlpha(barKey, fadeOutAlpha)
    end
end

function RefreshBarsForSpellBookVisibility()
    if not ActionBarsOwned.initialized then return end

    local forceShow = ShouldForceShowForSpellBook()

    for barKey, _ in pairs(BAR_FRAMES) do
        if SKINNABLE_BAR_KEYS[barKey] then
            local state = GetOwnedBarFadeState(barKey)
            state.isFading = false
            CancelOwnedBarFadeTimers(state)
            if forceShow then
                SetOwnedBarAlpha(barKey, 1)
            else
                SetupOwnedBarMouseover(barKey)
            end
        else
            local state = GetBarFadeState(barKey)
            state.isFading = false
            CancelBarFadeTimers(state)
            if forceShow then
                SetBarAlpha(barKey, 1)
            else
                SetupBarMouseover(barKey)
            end
        end
    end
end

function HookSpellBookVisibilityFrame(frame)
    if not frame then return end

    local state = GetFrameState(frame)
    if state.spellBookVisibilityHooked then return end
    state.spellBookVisibilityHooked = true

    frame:HookScript("OnShow", function()
        C_Timer.After(0, RefreshBarsForSpellBookVisibility)
    end)
    frame:HookScript("OnHide", function()
        C_Timer.After(0, RefreshBarsForSpellBookVisibility)
    end)
end

function EnsureSpellBookVisibilityHooks()
    HookSpellBookVisibilityFrame(_G.SpellBookFrame)

    local playerSpellsFrame = _G.PlayerSpellsFrame
    HookSpellBookVisibilityFrame(playerSpellsFrame)
    if playerSpellsFrame and playerSpellsFrame.SpellBookFrame then
        HookSpellBookVisibilityFrame(playerSpellsFrame.SpellBookFrame)
    end
end

function ScheduleSpellBookVisibilityRefresh()
    if not ActionBarsOwned.initialized then return end

    local function Refresh()
        if not ActionBarsOwned.initialized then return end
        EnsureSpellBookVisibilityHooks()
        RefreshBarsForSpellBookVisibility()
    end

    Refresh()
    C_Timer.After(0, Refresh)
    C_Timer.After(SPELL_UI_FADE_RECHECK_DELAY, Refresh)
end

function HookSpellBookToggleFunction(functionName)
    local fn = _G[functionName]
    if type(fn) ~= "function" then return end

    local hooked = ActionBarsOwned.spellBookToggleHooks
    if not hooked then
        hooked = {}
        ActionBarsOwned.spellBookToggleHooks = hooked
    end
    if hooked[functionName] then return end

    hooked[functionName] = true
    hooksecurefunc(functionName, ScheduleSpellBookVisibilityRefresh)
end

SPELLBOOK_UI_ADDONS = {
    Blizzard_PlayerSpells = true,
    Blizzard_SpellBook = true,
}

function HandleSpellBookAddonLoaded(addonName)
    if not SPELLBOOK_UI_ADDONS[addonName] then return end

    C_Timer.After(0, function()
        if not ActionBarsOwned.initialized then return end
        ScheduleSpellBookVisibilityRefresh()
    end)
end

ActionBarsOwned.SetupBarMouseover = SetupBarMouseover
ActionBarsOwned.RefreshBarsForSpellBookVisibility = RefreshBarsForSpellBookVisibility
ActionBarsOwned.HookSpellBookVisibilityFrame = HookSpellBookVisibilityFrame
ActionBarsOwned.EnsureSpellBookVisibilityHooks = EnsureSpellBookVisibilityHooks
ActionBarsOwned.ScheduleSpellBookVisibilityRefresh = ScheduleSpellBookVisibilityRefresh
ActionBarsOwned.HookSpellBookToggleFunction = HookSpellBookToggleFunction
ActionBarsOwned.HandleSpellBookAddonLoaded = HandleSpellBookAddonLoaded

end

COMBAT_FADE_BARS = {
    bar1 = true, bar2 = true, bar3 = true, bar4 = true,
    bar5 = true, bar6 = true, bar7 = true, bar8 = true,
    pet = true, stance = true,
}

combatFadeFrame = CreateFrame("Frame")
combatFadeFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

combatFadeFrame:SetScript("OnEvent", function(self, event)
    local fadeSettings = GetFadeSettings()
    if not fadeSettings or not fadeSettings.enabled then return end
    if not fadeSettings.alwaysShowInCombat then return end
    if ShouldSuppressMouseoverHideForLevel() then return end

    for barKey, _ in pairs(COMBAT_FADE_BARS) do
        SetupOwnedBarMouseover(barKey)
    end
end)

function SkinBar(barKey)
    if not SKINNABLE_BAR_KEYS[barKey] then return end

    local db = GetDB()
    if not db then return end

    local barSettings = GetBarSettings(barKey)
    if not barSettings or not barSettings.enabled then return end

    local effectiveSettings = GetEffectiveSettings(barKey)
    if not effectiveSettings then return end

    local buttons = GetBarButtons(barKey)

    for _, button in ipairs(buttons) do
        SkinButton(button, effectiveSettings)
        UpdateButtonText(button, effectiveSettings)

        AddKeybindMethods(button, barKey)

        local state = GetFrameState(button)
        if not state.onEnterHooked then
            state.onEnterHooked = true
            button:HookScript("OnEnter", function(self)
                local LibKeyBound = LibStub("LibKeyBound-1.0", true)
                if LibKeyBound and LibKeyBound:IsShown() then
                    LibKeyBound:Set(self)
                end
            end)
        end

        if not state.flyoutSkinHooked then
            state.flyoutSkinHooked = true
            button:HookScript("OnClick", function()
                C_Timer.After(0, function()
                    if SkinSpellFlyoutButtons then
                        SkinSpellFlyoutButtons()
                    end
                end)
            end)
        end

        if not state.visibilityEffectsHooked then
            state.visibilityEffectsHooked = true
            button:HookScript("OnHide", function(self)
                local st = GetFrameState(self)
                FadeHideTextures(st, self)
            end)
            button:HookScript("OnShow", function(self)
                local st = GetFrameState(self)
                ActionBarsOwned.SuppressButtonProcVisuals(self)
                local key = GetBarKeyFromButton(self)
                local fadeState = key and ActionBarsOwned.fadeState and ActionBarsOwned.fadeState[key]
                local hideEmptyEnabled = GetGlobalSettings() and GetGlobalSettings().hideEmptySlots
                local shouldStayHidden = (fadeState and fadeState.currentAlpha and fadeState.currentAlpha <= 0)
                    or (hideEmptyEnabled and st.hiddenEmpty)

                if shouldStayHidden then
                    FadeHideTextures(st, self)
                else
                    FadeShowTextures(st, self)
                end
            end)
        end
    end
end
