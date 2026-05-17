local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CDM Icon Mirror Index
--
-- Private controller used by CDMIcons to target mirror-backed icon refreshes.
-- It owns the weak icon index, pending mirror refresh queue, and mirror
-- refresh stats; CDMIcons keeps the public lifecycle methods.
---------------------------------------------------------------------------

local CDMIconMirrorIndex = {}
ns.CDMIconMirrorIndex = CDMIconMirrorIndex

local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local wipe = wipe or function(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local function CountPendingKeys(pendingByCategory)
    local count = 0
    for _, byCooldownID in pairs(pendingByCategory or {}) do
        for _ in pairs(byCooldownID) do
            count = count + 1
        end
    end
    return count
end

function CDMIconMirrorIndex.Create(callbacks)
    callbacks = callbacks or {}

    local controller = {
        byCategory = {},
        pendingByCategory = {},
        refreshPending = false,
        stats = {
            targeted = 0,
            fallback = 0,
            maxBatch = 0,
        },
    }

    local function getIconSet(category, cooldownID, create)
        if not (category and cooldownID) then return nil end
        local byCategory = controller.byCategory[category]
        if not byCategory then
            if not create then return nil end
            byCategory = {}
            controller.byCategory[category] = byCategory
        end

        local iconSet = byCategory[cooldownID]
        if not iconSet then
            if not create then return nil end
            iconSet = setmetatable({}, { __mode = "k" })
            byCategory[cooldownID] = iconSet
        end
        return iconSet
    end

    function controller:RemoveIcon(icon)
        if not icon then return end
        local category = icon._blizzMirrorIndexCategory
        local cooldownID = icon._blizzMirrorIndexCooldownID
        if category and cooldownID then
            local iconSet = getIconSet(category, cooldownID, false)
            if iconSet then
                iconSet[icon] = nil
            end
        end
        icon._blizzMirrorIndexCategory = nil
        icon._blizzMirrorIndexCooldownID = nil
    end

    function controller:Rebuild(iconPools)
        wipe(controller.byCategory)
        for _, pool in pairs(iconPools or {}) do
            for _, icon in ipairs(pool) do
                if icon and icon._blizzMirrorCooldownID and icon._blizzMirrorCategory then
                    local iconSet = getIconSet(
                        icon._blizzMirrorCategory,
                        icon._blizzMirrorCooldownID,
                        true)
                    iconSet[icon] = true
                    icon._blizzMirrorIndexCategory = icon._blizzMirrorCategory
                    icon._blizzMirrorIndexCooldownID = icon._blizzMirrorCooldownID
                end
            end
        end
    end

    function controller:BindIcon(icon, cooldownID, category)
        if not icon then return end
        controller:RemoveIcon(icon)
        if cooldownID and category then
            local iconSet = getIconSet(category, cooldownID, true)
            iconSet[icon] = true
            icon._blizzMirrorIndexCategory = category
            icon._blizzMirrorIndexCooldownID = cooldownID
        end
        if callbacks.onBound then
            callbacks.onBound(icon, cooldownID, category)
        end
    end

    function controller:UnbindIcon(icon)
        controller:RemoveIcon(icon)
        if callbacks.onUnbound then
            callbacks.onUnbound(icon)
        end
    end

    function controller:Count()
        local mirrorIndexKeys = 0
        local mirrorIndexIcons = 0
        for _, byCooldownID in pairs(controller.byCategory) do
            for _, iconSet in pairs(byCooldownID) do
                mirrorIndexKeys = mirrorIndexKeys + 1
                for icon in pairs(iconSet) do
                    if icon then
                        mirrorIndexIcons = mirrorIndexIcons + 1
                    end
                end
            end
        end
        return mirrorIndexKeys, mirrorIndexIcons
    end

    function controller:PendingKeyCount()
        return CountPendingKeys(controller.pendingByCategory)
    end

    function controller:GetStats()
        return controller.stats
    end

    local function drainRefreshQueue()
        controller.refreshPending = false
        local pendingByCategory = controller.pendingByCategory
        controller.pendingByCategory = {}

        local batchKeys = CountPendingKeys(pendingByCategory)
        if batchKeys == 0 then return end

        local stats = controller.stats
        if batchKeys > stats.maxBatch then
            stats.maxBatch = batchKeys
        end
        stats.targeted = stats.targeted + batchKeys

        local editMode, ncdm, ncdmContainers, inCombat
        if callbacks.prepareBatch then
            editMode, ncdm, ncdmContainers, inCombat = callbacks.prepareBatch()
        end

        local refreshed = 0
        if callbacks.setStackTextWrites then
            callbacks.setStackTextWrites(true)
        end
        if callbacks.beginBatch then
            callbacks.beginBatch()
        end

        for category, byCooldownID in pairs(pendingByCategory) do
            for cooldownID in pairs(byCooldownID) do
                local iconSet = getIconSet(category, cooldownID, false)
                if iconSet then
                    for icon in pairs(iconSet) do
                        if icon
                            and icon._blizzMirrorCooldownID == cooldownID
                            and icon._blizzMirrorCategory == category
                            and callbacks.refreshIcon
                            and callbacks.refreshIcon(icon, editMode, ncdm, ncdmContainers, inCombat) then
                            refreshed = refreshed + 1
                        end
                    end
                end
            end
        end

        if callbacks.setStackTextWrites then
            callbacks.setStackTextWrites(false)
        end
        if callbacks.endBatch then
            callbacks.endBatch()
        end

        if refreshed > 0 and callbacks.drainLayoutDirty then
            callbacks.drainLayoutDirty()
        end
    end

    function controller:RequestRefresh(cooldownID, category)
        if callbacks.isRuntimeEnabled and not callbacks.isRuntimeEnabled() then return end

        if not (cooldownID and category) then
            controller.stats.fallback = controller.stats.fallback + 1
            if callbacks.requestFullRefresh then
                callbacks.requestFullRefresh()
            end
            return
        end

        local byCooldownID = controller.pendingByCategory[category]
        if not byCooldownID then
            byCooldownID = {}
            controller.pendingByCategory[category] = byCooldownID
        end
        byCooldownID[cooldownID] = true

        if controller.refreshPending then return end
        if not (C_Timer and C_Timer.After) then
            drainRefreshQueue()
            return
        end

        controller.refreshPending = true
        C_Timer.After(0, drainRefreshQueue)
    end

    function controller:IsRefreshPending()
        return controller.refreshPending == true
    end

    return controller
end
