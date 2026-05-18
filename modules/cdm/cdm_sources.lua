local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CDM Sources
--
-- Thin adapters around Blizzard runtime APIs. These functions do not write
-- frames and do not decide visibility; they only return raw source data to
-- resolvers/stores.
---------------------------------------------------------------------------

local CDMSources = {}
ns.CDMSources = CDMSources

local C_Spell = C_Spell
local C_Item = C_Item
local C_UnitAuras = C_UnitAuras
local Shared = ns.CDMShared
local WoW_IsSecretValue = issecretvalue

local function HasOpaqueValue(value)
    if WoW_IsSecretValue and WoW_IsSecretValue(value) then
        return true
    end
    return value ~= nil
end

local function IsCooldownMirrorCategory(category)
    if Shared and Shared.IsCooldownMirrorCategory then
        return Shared.IsCooldownMirrorCategory(category)
    end
    return category == "essential" or category == "utility"
end

function CDMSources.QuerySpellCharges(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellCharges) then return nil, false end
    local ok, result = pcall(C_Spell.GetSpellCharges, spellID)
    if ok then return result, true end
    return nil, false
end

function CDMSources.QuerySpellCooldown(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    local ok, result = pcall(C_Spell.GetSpellCooldown, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellCooldownDuration(spellID, ignoreGCD)
    if not spellID or not (C_Spell and C_Spell.GetSpellCooldownDuration) then return nil end
    local ok, result = pcall(C_Spell.GetSpellCooldownDuration, spellID, ignoreGCD and true or false)
    if ok then return result end
    return nil
end

function CDMSources.QueryBaseSpell(spellID)
    if not spellID or not (C_Spell and C_Spell.GetBaseSpell) then return nil end
    local ok, result = pcall(C_Spell.GetBaseSpell, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellBaseCooldown(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellBaseCooldown) then return nil end
    local ok, result = pcall(C_Spell.GetSpellBaseCooldown, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellChargeDuration(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellChargeDuration) then return nil end
    local ok, result = pcall(C_Spell.GetSpellChargeDuration, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QueryOverrideSpell(spellID)
    if not spellID or not (C_Spell and C_Spell.GetOverrideSpell) then return nil end
    local ok, result = pcall(C_Spell.GetOverrideSpell, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellDisplayCount(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellDisplayCount) then return nil end
    local ok, result = pcall(C_Spell.GetSpellDisplayCount, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellCount(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellCastCount) then return nil end
    local ok, result = pcall(C_Spell.GetSpellCastCount, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellInfo(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellInfo) then return nil end
    local ok, result = pcall(C_Spell.GetSpellInfo, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellName(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellName) then return nil end
    local ok, result = pcall(C_Spell.GetSpellName, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellTexture(spellID)
    if not spellID or not (C_Spell and C_Spell.GetSpellTexture) then return nil end
    local ok, result = pcall(C_Spell.GetSpellTexture, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellUsable(spellID)
    if not spellID or not (C_Spell and C_Spell.IsSpellUsable) then return nil, nil end
    local ok, usable, noMana = pcall(C_Spell.IsSpellUsable, spellID)
    if ok then return usable, noMana end
    return nil, nil
end

function CDMSources.QuerySpellInRange(spellID, unit)
    if not spellID or not unit or not (C_Spell and C_Spell.IsSpellInRange) then return nil end
    local ok, result = pcall(C_Spell.IsSpellInRange, spellID, unit)
    if ok then return result end
    return nil
end

function CDMSources.QuerySpellHasRange(spellID)
    if not spellID or not (C_Spell and C_Spell.SpellHasRange) then return nil end
    local ok, result = pcall(C_Spell.SpellHasRange, spellID)
    if ok then return result end
    return nil
end

function CDMSources.EnableSpellRangeCheck(spellID, enable)
    if not spellID or not (C_Spell and C_Spell.EnableSpellRangeCheck) then return false end
    local ok = pcall(C_Spell.EnableSpellRangeCheck, spellID, enable == true)
    return ok == true
end

function CDMSources.QuerySpellHarmful(spellNameOrID)
    if not spellNameOrID then return nil end
    if C_Spell and C_Spell.IsSpellHarmful then
        local ok, result = pcall(C_Spell.IsSpellHarmful, spellNameOrID)
        if ok then return result end
    end
    if IsHarmfulSpell then
        local ok, result = pcall(IsHarmfulSpell, spellNameOrID)
        if ok then return result end
    end
    return nil
end

function CDMSources.QuerySpellHelpful(spellNameOrID)
    if not spellNameOrID then return nil end
    if C_Spell and C_Spell.IsSpellHelpful then
        local ok, result = pcall(C_Spell.IsSpellHelpful, spellNameOrID)
        if ok then return result end
    end
    if IsHelpfulSpell then
        local ok, result = pcall(IsHelpfulSpell, spellNameOrID)
        if ok then return result end
    end
    return nil
end

function CDMSources.QueryItemInfoInstant(itemID)
    if not itemID or not (C_Item and C_Item.GetItemInfoInstant) then return nil end
    local ok, a, b, c, d, e, f, g = pcall(C_Item.GetItemInfoInstant, itemID)
    if ok then return a, b, c, d, e, f, g end
    return nil
end

function CDMSources.QueryItemIconByID(itemID)
    if not itemID or not (C_Item and C_Item.GetItemIconByID) then return nil end
    local ok, result = pcall(C_Item.GetItemIconByID, itemID)
    if ok then return result end
    return nil
end

function CDMSources.QueryItemNameByID(itemID)
    if not itemID or not (C_Item and C_Item.GetItemNameByID) then return nil end
    local ok, result = pcall(C_Item.GetItemNameByID, itemID)
    if ok then return result end
    return nil
end

function CDMSources.QueryItemSpell(itemID)
    if not itemID or not (C_Item and C_Item.GetItemSpell) then return nil, nil end
    local ok, name, spellID = pcall(C_Item.GetItemSpell, itemID)
    if ok then return name, spellID end
    return nil, nil
end

function CDMSources.QueryItemQualityByID(itemID)
    if not itemID or not (C_Item and C_Item.GetItemQualityByID) then return nil end
    local ok, result = pcall(C_Item.GetItemQualityByID, itemID)
    if ok then return result end
    return nil
end

function CDMSources.QueryItemProfessionQualityInfo(itemInfo)
    if not itemInfo or not C_TradeSkillUI then return nil end
    if issecretvalue and issecretvalue(itemInfo) then return nil end
    if C_TradeSkillUI.GetItemReagentQualityInfo then
        local ok, info = pcall(C_TradeSkillUI.GetItemReagentQualityInfo, itemInfo)
        if ok and info then return info end
    end
    if C_TradeSkillUI.GetItemCraftedQualityInfo then
        local ok, info = pcall(C_TradeSkillUI.GetItemCraftedQualityInfo, itemInfo)
        if ok then return info end
    end
    return nil
end

function CDMSources.QueryFirstTriggeredSpellForItem(itemID, itemQuality)
    if not itemID or not (C_Item and C_Item.GetFirstTriggeredSpellForItem) then return nil end
    local ok, spellID
    if itemQuality ~= nil then
        ok, spellID = pcall(C_Item.GetFirstTriggeredSpellForItem, itemID, itemQuality)
    else
        ok, spellID = pcall(C_Item.GetFirstTriggeredSpellForItem, itemID)
    end
    if ok then return spellID end
    return nil
end

function CDMSources.QueryIsEquippedItem(itemID)
    if not itemID or not (C_Item and C_Item.IsEquippedItem) then return nil end
    local ok, result = pcall(C_Item.IsEquippedItem, itemID)
    if ok then return result end
    return nil
end

function CDMSources.QueryInventoryItemID(unit, slotID)
    if not unit or not slotID or not GetInventoryItemID then return nil end
    local ok, result = pcall(GetInventoryItemID, unit, slotID)
    if ok then return result end
    return nil
end

function CDMSources.QueryInventoryItemLink(unit, slotID)
    if not unit or not slotID or not GetInventoryItemLink then return nil end
    local ok, result = pcall(GetInventoryItemLink, unit, slotID)
    if ok then return result end
    return nil
end

function CDMSources.QueryInventoryItemTexture(unit, slotID)
    if not unit or not slotID or not GetInventoryItemTexture then return nil end
    local ok, result = pcall(GetInventoryItemTexture, unit, slotID)
    if ok then return result end
    return nil
end

function CDMSources.QueryItemCount(itemID, includeBank, includeUses, forceUpdate)
    if not itemID or not (C_Item and C_Item.GetItemCount) then return nil end
    local ok, result = pcall(C_Item.GetItemCount, itemID, includeBank, includeUses, forceUpdate)
    if ok then return result end
    return nil
end

function CDMSources.QueryBestOwnedItemVariant(itemID)
    if not itemID then return nil end
    if issecretvalue and issecretvalue(itemID) then return nil end

    local consumables = ns.ConsumableMacros
    local getVariantOrder = consumables and consumables.GetVariantOrderForItem
    local variants = getVariantOrder and getVariantOrder(itemID)
    if type(variants) ~= "table" or #variants == 0 then
        return itemID
    end

    for _, variantID in ipairs(variants) do
        if type(variantID) == "number" then
            local count = CDMSources.QueryItemCount(variantID, false, false)
            if issecretvalue and issecretvalue(count) then
                return itemID
            end
            if type(count) == "number" and count > 0 then
                return variantID
            end
        end
    end

    return itemID
end

function CDMSources.QueryItemCooldown(itemID)
    if not itemID or not (C_Item and C_Item.GetItemCooldown) then return nil end
    local ok, startTime, duration, enabled = pcall(C_Item.GetItemCooldown, itemID)
    if ok then return startTime, duration, enabled end
    return nil
end

local function QueryScannerActive(scanner, spellID, itemID)
    local active, expiration, duration, auraInstanceID, auraUnit
    if itemID and scanner.IsItemActive then
        local ok, a, e, d, instID, unit = pcall(scanner.IsItemActive, itemID)
        if ok then
            active, expiration, duration, auraInstanceID, auraUnit = a, e, d, instID, unit
        end
    end
    if active ~= true and spellID and scanner.IsSpellActive then
        local ok, a, e, d, instID, unit = pcall(scanner.IsSpellActive, spellID)
        if ok then
            active, expiration, duration, auraInstanceID, auraUnit = a, e, d, instID, unit
        end
    end
    return active == true, expiration, duration, auraInstanceID, auraUnit
end

local function CopyScannerAuraInfo(data, active, expiration, duration, source, sourceItemID, sourceSpellID,
                                   auraInstanceID, auraUnit)
    if not data and not active then return nil end
    return {
        active = active == true,
        expiration = expiration,
        duration = duration or (data and data.duration),
        auraInstanceID = auraInstanceID,
        auraUnit = auraUnit,
        useSpellID = data and data.useSpellID or sourceSpellID,
        buffSpellID = data and data.buffSpellID or nil,
        icon = data and data.icon or nil,
        name = data and data.name or nil,
        source = source,
        sourceItemID = sourceItemID,
        sourceSpellID = sourceSpellID,
    }
end

local function QueryScannedItemInfo(scanner, itemID)
    if not itemID or not scanner.GetScannedItemInfo then return nil end
    local ok, data = pcall(scanner.GetScannedItemInfo, itemID)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function QueryScannedSpellInfo(scanner, spellID)
    if not spellID or not scanner.GetScannedSpellInfo then return nil end
    local ok, data = pcall(scanner.GetScannedSpellInfo, spellID)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function RegisterScannerItemUseSpell(scanner, itemID, spellID)
    if not itemID or not spellID or not scanner.RegisterItemUseSpell then return end
    pcall(scanner.RegisterItemUseSpell, itemID, spellID)
end

function CDMSources.QueryScannedItemAuraInfo(itemID, itemSpellID)
    if not itemID and not itemSpellID then return nil end

    local root = _G and _G.QUI or QUI
    local scanner = root and root.SpellScanner
    if not scanner then return nil end

    local resolvedItemSpellID = itemSpellID
    if not resolvedItemSpellID and itemID and CDMSources.QueryItemSpell then
        local _, spellID = CDMSources.QueryItemSpell(itemID)
        resolvedItemSpellID = spellID
    end
    RegisterScannerItemUseSpell(scanner, itemID, resolvedItemSpellID)

    local data = QueryScannedItemInfo(scanner, itemID)
    local sourceItemID = itemID
    if not data and itemID then
        local consumables = ns.ConsumableMacros
        local getVariantOrder = consumables and consumables.GetVariantOrderForItem
        local variants = getVariantOrder and getVariantOrder(itemID)
        if type(variants) == "table" then
            for _, variantID in ipairs(variants) do
                if type(variantID) == "number" then
                    data = QueryScannedItemInfo(scanner, variantID)
                    if data then
                        sourceItemID = variantID
                        break
                    end
                end
            end
        end
    end
    if data then
        local useSpellID = data.useSpellID or resolvedItemSpellID
        local active, expiration, duration, auraInstanceID, auraUnit =
            QueryScannerActive(scanner, useSpellID, sourceItemID)
        return CopyScannerAuraInfo(data, active, expiration, duration, "item",
            sourceItemID, useSpellID, auraInstanceID, auraUnit)
    end

    data = QueryScannedSpellInfo(scanner, resolvedItemSpellID)
    if data then
        local active, expiration, duration, auraInstanceID, auraUnit =
            QueryScannerActive(scanner, resolvedItemSpellID, nil)
        return CopyScannerAuraInfo(data, active, expiration, duration, "spell",
            itemID, resolvedItemSpellID, auraInstanceID, auraUnit)
    end

    local active, expiration, duration, auraInstanceID, auraUnit =
        QueryScannerActive(scanner, resolvedItemSpellID, itemID)
    return CopyScannerAuraInfo(nil, active, expiration, duration, "active",
        itemID, resolvedItemSpellID, auraInstanceID, auraUnit)
end

function CDMSources.QueryAuraDuration(unit, auraInstanceID)
    if not unit or not HasOpaqueValue(auraInstanceID) or not (C_UnitAuras and C_UnitAuras.GetAuraDuration) then return nil end
    local ok, result = pcall(C_UnitAuras.GetAuraDuration, unit, auraInstanceID)
    if ok then return result end
    return nil
end

function CDMSources.QueryAuraDataByAuraInstanceID(unit, auraInstanceID)
    if not unit or not HasOpaqueValue(auraInstanceID) or not (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) then return nil end
    local ok, result = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
    if ok then return result end
    return nil
end

function CDMSources.QueryAuraHasExpirationTime(unit, auraInstanceID)
    if not unit or not HasOpaqueValue(auraInstanceID) or not (C_UnitAuras and C_UnitAuras.DoesAuraHaveExpirationTime) then return nil end
    local ok, result = pcall(C_UnitAuras.DoesAuraHaveExpirationTime, unit, auraInstanceID)
    if ok then return result end
    return nil
end

function CDMSources.QueryAuraFilteredOutByInstanceID(unit, auraInstanceID, filter)
    if not unit or not HasOpaqueValue(auraInstanceID) or not (C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID) then return nil end
    local ok, result = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, auraInstanceID, filter)
    if ok then return result end
    return nil
end

function CDMSources.QueryAuraApplicationDisplayCount(unit, auraInstanceID, minValue, maxValue)
    if not unit or not HasOpaqueValue(auraInstanceID) or not (C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount) then return nil end
    local ok, result = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, auraInstanceID, minValue, maxValue)
    if ok then return result end
    return nil
end

function CDMSources.QueryUnitAuraBySpellID(unit, spellID, filter)
    if not unit or not spellID or not (C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID) then return nil end
    local ok, result = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellID, filter)
    if ok then return result end
    return nil
end

function CDMSources.QueryPlayerAuraBySpellID(spellID)
    if not spellID or not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    local ok, result = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QueryAuraDataBySpellID(unit, spellID, filter)
    if not unit or not spellID or not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID) then return nil end
    local ok, result = pcall(C_UnitAuras.GetAuraDataBySpellID, unit, spellID, filter)
    if ok then return result end
    return nil
end

function CDMSources.QueryCooldownAuraBySpellID(spellID)
    if not spellID or not (C_UnitAuras and C_UnitAuras.GetCooldownAuraBySpellID) then return nil end
    local ok, result = pcall(C_UnitAuras.GetCooldownAuraBySpellID, spellID)
    if ok then return result end
    return nil
end

function CDMSources.QueryAuraDataBySpellName(unit, name, filter)
    if not unit or not name or not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return nil end
    local ok, result = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, name, filter)
    if ok then return result end
    return nil
end

function CDMSources.QueryUnitAuras(unit, filter, maxCount)
    if not unit or not (C_UnitAuras and C_UnitAuras.GetUnitAuras) then return nil end
    local ok, result = pcall(C_UnitAuras.GetUnitAuras, unit, filter, maxCount)
    if ok then return result end
    return nil
end

function CDMSources.QueryMirroredCooldownState(spellID, viewerType)
    local mirror = ns.CDMBlizzMirror
    if not mirror or not spellID then return nil end
    if IsCooldownMirrorCategory(viewerType)
       and mirror.GetMirroredStateForViewer then
        return mirror.GetMirroredStateForViewer(spellID, viewerType)
    end
    if mirror.FindCooldownState then
        return mirror.FindCooldownState(spellID)
    end
    return nil
end
