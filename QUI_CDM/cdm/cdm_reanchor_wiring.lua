-- QUI_CDM/cdm/cdm_reanchor_wiring.lua
-- Curated-claim adapter for the re-anchor bridge. Matches a container's curated
-- ownedSpells entries to live Blizzard CooldownViewer item frames (by cooldownID,
-- via CDMIndex — mirror-independent) and re-anchors the matches into the QUI
-- container. Composes the Phase 1 bridge primitives. Inert until Phase 2b wires it.
local _, ns = ...

local CDMReanchorWiring = {}
ns.CDMReanchorWiring = CDMReanchorWiring

-- container taxonomy key -> Blizzard viewer global name
local VIEWER_GLOBAL_FOR_KEY = {
    essential  = "EssentialCooldownViewer",
    utility    = "UtilityCooldownViewer",
    buff       = "BuffIconCooldownViewer",
    trackedBar = "BuffBarCooldownViewer",
}

local InstanceMT = { __index = CDMReanchorWiring }
local _issecretvalue = issecretvalue or function() return false end

function CDMReanchorWiring.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _bridge = deps.bridge,
    }
    return setmetatable(self, InstanceMT)
end

function CDMReanchorWiring:GetViewerForKey(containerKey)
    if self._deps.getViewerForKey then
        return self._deps.getViewerForKey(containerKey)
    end
    local name = VIEWER_GLOBAL_FOR_KEY[containerKey]
    if not name then return nil end
    return _G[name]
end

function CDMReanchorWiring:GetViewersForKey(containerKey)
    if self._deps.getViewersForKey then
        return self._deps.getViewersForKey(containerKey) or {}
    end

    local out = {}
    if containerKey == "essential" or containerKey == "utility" then
        local primary = self:GetViewerForKey(containerKey)
        local siblingKey = (containerKey == "essential") and "utility" or "essential"
        local sibling = self:GetViewerForKey(siblingKey)
        if primary then out[#out + 1] = primary end
        if sibling and sibling ~= primary then out[#out + 1] = sibling end
        return out
    end

    local viewer = self:GetViewerForKey(containerKey)
    if viewer then out[#out + 1] = viewer end
    return out
end

local function appendID(list, id)
    if id ~= nil then
        list[#list + 1] = id
    end
end

local function isSafeNumber(value)
    return type(value) == "number" and not _issecretvalue(value)
end

local function toBaseSpellID(index, spellID)
    if not isSafeNumber(spellID) then return nil end
    if index and index.ToBaseSpellID then
        return index.ToBaseSpellID(spellID)
    end
    return spellID
end

local function claimByKey(map, key, frame)
    if key ~= nil and map[key] == nil then
        map[key] = frame
    end
end

local function forEachCooldownInfoID(index, info, callback)
    if type(info) ~= "table" then return end
    if index and index.ForEachCooldownInfoID then
        index.ForEachCooldownInfoID(info, callback)
        return
    end
    callback(info.overrideTooltipSpellID)
    callback(info.overrideSpellID)
    callback(info.spellID)
    if type(info.linkedSpellIDs) == "table" then
        for i = 1, #info.linkedSpellIDs do
            callback(info.linkedSpellIDs[i])
        end
    end
end

local function addFrameSpellAlias(frameMap, index, spellID, frame)
    local base = toBaseSpellID(index, spellID)
    if base then
        claimByKey(frameMap._bySpell, base, frame)
    end
end

local function addFrameInfoAliases(frameMap, index, frame, info)
    if type(info) ~= "table" then return end

    if isSafeNumber(info.equipSlot) then
        claimByKey(frameMap._byEquipSlot, info.equipSlot, frame)
    end
    if isSafeNumber(info.spellCategoryID) then
        claimByKey(frameMap._bySpellCategory, info.spellCategoryID, frame)
    end
    forEachCooldownInfoID(index, info, function(id)
        addFrameSpellAlias(frameMap, index, id, frame)
    end)
end

-- Returns BOTH the cooldownID->frame map AND the raw ordered item list. The raw
-- list is load-bearing for sinking: a frame whose GetCooldownID() reads as a secret
-- value in combat resolves to nil identity and is absent from the cooldownID map.
-- Frame-derived spell/slot/category aliases are also captured when available so a
-- real Blizzard frame is not dropped just because the provider cooldownID lookup is
-- stale or incomplete.
local function newFrameMap()
    local map, items = {}, {}
    map._bySpell = {}
    map._byEquipSlot = {}
    map._bySpellCategory = {}
    return map, items
end

function CDMReanchorWiring:AddViewerToFrameMap(map, items, viewer)
    if not viewer then return end
    local bridge = self._bridge
    local index = self._deps.index
    local viewerItems = bridge:EnumerateItems(viewer)
    for i = 1, #viewerItems do
        local frame = viewerItems[i]
        items[#items + 1] = frame
        local cooldownID = bridge:ResolveIdentity(frame)
        if cooldownID ~= nil then
            claimByKey(map, cooldownID, frame)
        end
        if bridge.GetFrameCooldownInfo then
            addFrameInfoAliases(map, index, frame, bridge:GetFrameCooldownInfo(frame, cooldownID))
        end
        if frame and frame.GetSpellID then
            local ok, spellID = pcall(frame.GetSpellID, frame)
            if ok then
                addFrameSpellAlias(map, index, spellID, frame)
            end
        end
    end
end

function CDMReanchorWiring:BuildFrameMap(viewer)
    local map, items = newFrameMap()
    self:AddViewerToFrameMap(map, items, viewer)
    return map, items
end

function CDMReanchorWiring:BuildFrameMapForViewers(viewers)
    local map, items = newFrameMap()
    if type(viewers) ~= "table" then return map, items end
    for i = 1, #viewers do
        self:AddViewerToFrameMap(map, items, viewers[i])
    end
    return map, items
end

function CDMReanchorWiring:ResolveEntryCooldownID(entry, containerKey)
    if self._deps.resolveEntryCooldownID then
        return self._deps.resolveEntryCooldownID(entry, containerKey)
    end
    local index = self._deps.index
    if not index then return nil end

    -- Item entries identify by equipSlot / spellCategoryID, NOT spellID. Resolve
    -- type-first and return early: a resolved trinket carries spellID == itemID
    -- (cdm_spelldata ResolveOwnedEntry), and entry.id == equipSlot could collide
    -- with a real spellID -- both would mis-resolve via the generic path below.
    local etype = entry.type
    if etype == "slot" or etype == "trinket" then
        local rec = index.GetOrderedByEquipSlotForContainer
            and index.GetOrderedByEquipSlotForContainer(containerKey, entry.id)
        if not rec and index.GetOrderedByEquipSlot then
            rec = index.GetOrderedByEquipSlot(entry.id)
        end
        if not rec and index.GetByEquipSlot then
            rec = index.GetByEquipSlot(entry.id)
        end
        return (rec and rec.cooldownID) or nil
    elseif etype == "consumable" then
        local rec = index.GetOrderedByCategoryForContainer
            and index.GetOrderedByCategoryForContainer(containerKey, entry.id)
        if not rec and index.GetOrderedByCategory then
            rec = index.GetOrderedByCategory(entry.id)
        end
        if not rec and index.GetByCategory then
            rec = index.GetByCategory(entry.id)
        end
        return (rec and rec.cooldownID) or nil
    end

    local ids = {}
    appendID(ids, entry.overrideSpellID)
    appendID(ids, entry.spellID)
    appendID(ids, entry.id)
    if type(entry.linkedSpellIDs) == "table" then
        for i = 1, #entry.linkedSpellIDs do
            appendID(ids, entry.linkedSpellIDs[i])
        end
    end

    for i = 1, #ids do
        local id = ids[i]
        if index.IsUsableID(id) then
            local rec = index.GetOrderedForContainer
                and index.GetOrderedForContainer(containerKey, id)
            if not rec and index.GetOrdered then
                rec = index.GetOrdered(id)
            end
            if not rec then
                rec = index.Get(id)
            end
            if rec and rec.cooldownID ~= nil then
                return rec.cooldownID
            end
        end
    end
    return nil
end

function CDMReanchorWiring:ResolveEntryFrame(entry, frameMap)
    if not entry or type(frameMap) ~= "table" then return nil end

    local etype = entry.type
    if etype == "slot" or etype == "trinket" then
        local bySlot = frameMap._byEquipSlot
        return bySlot and bySlot[entry.id] or nil
    elseif etype == "consumable" then
        local byCategory = frameMap._bySpellCategory
        return byCategory and byCategory[entry.id] or nil
    end

    local bySpell = frameMap._bySpell
    if not bySpell then return nil end

    local index = self._deps.index
    local ids = {}
    appendID(ids, entry.overrideSpellID)
    appendID(ids, entry.spellID)
    appendID(ids, entry.id)
    if type(entry.linkedSpellIDs) == "table" then
        for i = 1, #entry.linkedSpellIDs do
            appendID(ids, entry.linkedSpellIDs[i])
        end
    end

    for i = 1, #ids do
        local base = toBaseSpellID(index, ids[i])
        local frame = base and bySpell[base]
        if frame then
            return frame
        end
    end
    return nil
end

function CDMReanchorWiring:MatchCuratedToFrames(curated, frameMap, containerKey)
    local matched, frameless, claimedFrames = {}, {}, {}
    for i = 1, #curated do
        local entry = curated[i]
        local cooldownID = self:ResolveEntryCooldownID(entry, containerKey)
        local frame = (cooldownID ~= nil) and frameMap[cooldownID] or nil
        if not frame then
            frame = self:ResolveEntryFrame(entry, frameMap)
        end
        if frame and not claimedFrames[frame] then
            claimedFrames[frame] = true
            matched[#matched + 1] = { entry = entry, frame = frame }
        else
            frameless[#frameless + 1] = entry
        end
    end
    return matched, frameless, claimedFrames
end
