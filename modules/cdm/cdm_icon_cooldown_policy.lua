local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CDM Icon Cooldown Policy
--
-- Private controller used by CDMIcons. It owns icon-local GCD swipe flags,
-- trusted GCD capture, mirror state lookup, and mirror charge-cycle memory.
---------------------------------------------------------------------------

local CDMIconCooldownPolicy = {}
ns.CDMIconCooldownPolicy = CDMIconCooldownPolicy

local ipairs = ipairs
local pairs = pairs
local type = type

function CDMIconCooldownPolicy.Create(callbacks)
    callbacks = callbacks or {}

    local controller = {}
    local hasQueryCooldown = type(callbacks.queryCooldown) == "function"

    local function QueryOverrideSpell(spellID)
        return callbacks.queryOverrideSpell and callbacks.queryOverrideSpell(spellID) or nil
    end

    local function QueryCooldown(spellID)
        return callbacks.queryCooldown and callbacks.queryCooldown(spellID) or nil
    end

    local function GetIconCooldownIdentifier(icon)
        local entry = icon and icon._spellEntry
        if not entry then return nil end

        local base = entry.spellID or entry.id
        if base then
            local overrideID = QueryOverrideSpell(base)
            if overrideID then return overrideID end
        end
        return base
    end

    function controller:MarkGCDSwipe(icon)
        if not icon then return end
        icon._showingGCDSwipe = true
        icon._showingRealCooldownSwipe = nil
    end

    function controller:ClearGCDSwipe(icon)
        if not icon then return end
        icon._showingGCDSwipe = nil
    end

    function controller:GetIconMirrorState(icon)
        local mirror = callbacks.getMirror and callbacks.getMirror() or nil
        if not (icon and icon._blizzMirrorCooldownID and mirror and mirror.GetStateByCooldownID) then
            return nil
        end
        return mirror.GetStateByCooldownID(icon._blizzMirrorCooldownID, icon._blizzMirrorCategory)
    end

    function controller:MirrorStateIsActive(state)
        return state and state.isActive == true
    end

    function controller:ClearIconChargeMirrorCycle(icon)
        if not icon then return end
        icon._lastChargeMirrorCooldownID = nil
        icon._lastChargeMirrorCategory = nil
        icon._lastChargeRuntimeSpellID = nil
    end

    function controller:RememberIconChargeMirrorCycle(icon, runtimeSpellID)
        if not (icon and icon._blizzMirrorCooldownID) then return end
        icon._lastChargeMirrorCooldownID = icon._blizzMirrorCooldownID
        icon._lastChargeMirrorCategory = icon._blizzMirrorCategory
        icon._lastChargeRuntimeSpellID = runtimeSpellID
    end

    function controller:UpdateIconChargeMirrorCycle(icon, mode, runtimeSpellID)
        if not icon then return end
        if mode == "charge" then
            controller:RememberIconChargeMirrorCycle(icon, runtimeSpellID)
        elseif mode == "inactive"
            and not controller:MirrorStateIsActive(controller:GetIconMirrorState(icon)) then
            controller:ClearIconChargeMirrorCycle(icon)
        end
    end

    function controller:MirrorPayloadHasChargeState(mirrorPayload)
        local state = mirrorPayload and mirrorPayload.state
        if not state then return false end
        if state.resolvedMode == "charge"
            or state.durObjSource == "spell-charge"
            or state.resourceDurObj ~= nil
            or state.cooldownChargesShown == true
            or state.chargeCountFrameShown == true then
            return true
        end
        return state.stackTextSource == "ChargeCount" and state.stackTextShown ~= false
    end

    function controller:MirrorPayloadMatchesRecentChargeCycle(icon, mirrorPayload)
        local state = mirrorPayload and mirrorPayload.state
        if not (icon and state and state.isActive == true and icon._lastChargeMirrorCooldownID) then
            return false
        end
        local cooldownID = mirrorPayload.cooldownID or state.cooldownID or icon._blizzMirrorCooldownID
        if cooldownID ~= icon._lastChargeMirrorCooldownID then
            return false
        end
        local category = mirrorPayload.category or state.viewerCategory or icon._blizzMirrorCategory
        return icon._lastChargeMirrorCategory == nil or category == icon._lastChargeMirrorCategory
    end

    function controller:CaptureTrustedGCDStateForIcon(icon, spellState, stamp)
        if not icon or not icon._spellEntry then return false end

        local sid = GetIconCooldownIdentifier(icon)
        local sidType = type(sid)
        if sidType ~= "number" and sidType ~= "string" then
            sid = nil
        end
        local prev = icon._isOnGCD

        if not sid or not hasQueryCooldown then
            if prev ~= nil then
                icon._isOnGCD = nil
                icon._isOnGCDTrustedAt = nil
                return true
            end
            icon._isOnGCD = nil
            icon._isOnGCDTrustedAt = nil
            return false
        end

        local trusted = spellState and spellState[sid]
        if trusted == nil then
            local cdInfo = QueryCooldown(sid)
            local onGCD = cdInfo and cdInfo.isOnGCD
            if type(onGCD) == "boolean" then
                trusted = onGCD
            end
            if trusted ~= nil and spellState then
                spellState[sid] = trusted
            end
        end

        if type(trusted) == "boolean" then
            icon._isOnGCD = trusted
            icon._isOnGCDTrustedAt = stamp
            return prev ~= trusted
        end

        icon._isOnGCD = nil
        icon._isOnGCDTrustedAt = nil
        return prev ~= nil
    end

    function controller:CaptureTrustedGCDState(iconPools, spellState, stamp)
        if not hasQueryCooldown then
            return false
        end

        local anyChanged = false
        for _, pool in pairs(iconPools or {}) do
            for _, icon in ipairs(pool) do
                if controller:CaptureTrustedGCDStateForIcon(icon, spellState, stamp) then
                    anyChanged = true
                end
            end
        end
        return anyChanged
    end

    return controller
end
