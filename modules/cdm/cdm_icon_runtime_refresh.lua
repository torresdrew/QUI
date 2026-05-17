local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CDM Icon Runtime Refresh
--
-- Private controller for CDMIcons event/runtime refresh dispatch. CDMIcons
-- owns renderer callbacks; this module owns the event branching shape.
---------------------------------------------------------------------------

local CDMIconRuntimeRefresh = {}
ns.CDMIconRuntimeRefresh = CDMIconRuntimeRefresh

function CDMIconRuntimeRefresh.Create(callbacks)
    callbacks = callbacks or {}

    local controller = {}

    function controller:HandleAuraRefresh(unit, updateInfo)
        if callbacks.isRuntimeEnabled and not callbacks.isRuntimeEnabled() then return end
        if callbacks.eventTracePrint then
            callbacks.eventTracePrint("aura-pre", "UNIT_AURA", unit, nil, nil,
                callbacks.eventTraceAuraInfo and callbacks.eventTraceAuraInfo(updateInfo))
        end

        if not updateInfo or updateInfo.isFullUpdate then
            if callbacks.setBarsDirty then callbacks.setBarsDirty(true) end
            if callbacks.scheduleFullUpdate then callbacks.scheduleFullUpdate() end
            if callbacks.applyAuraScope then callbacks.applyAuraScope() end
        else
            local refreshed = callbacks.applyAuraInstances
                and callbacks.applyAuraInstances(unit, updateInfo)
                or 0
            if refreshed > 0 then
                if callbacks.setBarsDirty then callbacks.setBarsDirty(true) end
                if callbacks.runDirtyBarUpdate then callbacks.runDirtyBarUpdate() end
            end
        end

        if callbacks.eventTracePrint then
            callbacks.eventTracePrint("aura-post", "UNIT_AURA", unit, nil, nil,
                callbacks.eventTraceAuraInfo and callbacks.eventTraceAuraInfo(updateInfo))
        end
    end

    function controller:Handle(event, arg1, arg2, arg3, frame)
        if event == "UNIT_AURA" then
            return controller:HandleAuraRefresh(arg1, arg2)
        end
        if callbacks.handleFrameEvent then
            return callbacks.handleFrameEvent(frame, event, arg1, arg2, arg3)
        end
    end

    return controller
end
