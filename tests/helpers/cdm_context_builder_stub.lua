-- Shared test stub for CDMResolvers.BuildCooldownStateContext.
-- Keep this shape aligned with the production resolver-owned context contract.

local function NormalizeMirrorCategory(category)
    if category == "essential"
        or category == "utility"
        or category == "buff"
        or category == "trackedBar" then
        return category
    end
    return nil
end

return function(owner, entry, runtimeSpellID, options)
    local context = options and options.context
    local contextKey = options and options.contextKey or "_cooldownStateContext"
    if not context and owner then
        context = owner[contextKey]
        if not context then
            context = {}
            owner[contextKey] = context
        end
    end
    if not context then
        context = {}
    end

    context.owner = nil
    context.entry = nil
    context.runtimeSpellID = nil
    context.mirrorCooldownID = nil
    context.mirrorCategory = nil
    context.cachedMirrorState = nil
    context.cachedMirrorSourceID = nil
    context.containerKey = nil
    context.totemSlot = nil
    context.useBuffSwipe = nil
    context.skipAuraPhase = nil
    context.showGCDSwipe = nil
    context.lastChargeMirrorCooldownID = nil
    context.lastChargeMirrorCategory = nil
    context.lastChargeRuntimeSpellID = nil

    local policy = options and options.mirrorIdentityPolicy or "frame-or-entry"
    local cooldownID
    local category

    if policy ~= "entry" and policy ~= "entry-or-fallback" then
        cooldownID = options and options.mirrorCooldownID
        category = options and options.mirrorCategory
        if cooldownID == nil and owner then
            cooldownID = owner._blizzMirrorCooldownID
            category = owner._blizzMirrorCategory
        end
    end

    if cooldownID == nil and policy == "entry-or-fallback" and entry then
        cooldownID = entry.cooldownID
        category = NormalizeMirrorCategory(entry.blizzardMirrorCategory)
            or NormalizeMirrorCategory(entry.viewerCategory)
            or NormalizeMirrorCategory(entry.viewerType)
    end

    local containerKey = options and options.containerKey
    if containerKey == nil then
        containerKey = entry and entry.viewerType
    end
    if containerKey == nil and options then
        containerKey = options.fallbackContainerKey
    end

    context.owner = owner
    context.entry = entry
    context.runtimeSpellID = runtimeSpellID
    context.mirrorCooldownID = cooldownID
    context.mirrorCategory = category
    context.cachedMirrorState = options and options.cachedMirrorState
    context.cachedMirrorSourceID = options and options.cachedMirrorSourceID
    context.containerKey = containerKey
    context.totemSlot = (options and options.totemSlot)
        or (owner and owner._totemSlot)
    context.useBuffSwipe = options and options.useBuffSwipe
    context.skipAuraPhase = options and options.skipAuraPhase == true
    context.showGCDSwipe = options and options.showGCDSwipe == true
    context.lastChargeMirrorCooldownID = options and options.lastChargeMirrorCooldownID
    context.lastChargeMirrorCategory = options and options.lastChargeMirrorCategory
    context.lastChargeRuntimeSpellID = options and options.lastChargeRuntimeSpellID
    return context
end
