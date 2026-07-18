local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- VENDOR SELL RULES
--
-- Rule-based auto-sell at merchants beyond grey junk: sells EQUIPPABLE
-- armor/weapons at/below a chosen quality (and optionally below an item
-- level), plus an explicit force-sell list. Ships with PREVIEW MODE ON —
-- until it's turned off, the engine only prints what it WOULD sell.
--
-- HARD PROTECTIONS (always on, not configurable):
--   * equipment-set members (C_Container.GetContainerItemEquipmentSetInfo)
--   * gear still on an upgrade track below its max (C_Item.GetItemUpgradeInfo)
--   * unbound BoE/BoA items (tradeable value; ContainerItemInfo.isBound)
--   * anything on the never-sell list
--   * items vendors pay nothing for (hasNoValue)
--   * quality above the rule cap, non-equippables (crafting mats etc. are
--     never rule-sold; only the force-sell list can sell arbitrary items)
--   * at most 12 sales per merchant visit (fits the buyback window)
--
-- All APIs doc-verified earlier in this suite: GetContainerItemInfo
-- (MayReturnNothing; quality Nilable, isBound/hasNoValue/itemID/hyperlink
-- fields), UseContainerItem (2-arg sell form), GetItemInfoInstant (classID
-- 6th return; 2 = Weapon, 4 = Armor), GetItemUpgradeInfo (Nilable return),
-- GetDetailedItemLevelInfo (MayReturnNothing).
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local MAX_SALES_PER_VISIT = 12

-- <<< QUI_TEST_EXTRACT decide_sale
-- Pure rule core. facts = { quality, classID, ilvl, inSet, upgradable,
-- unboundTradable, hasNoValue, forced, protected }; cfg = { maxQuality,
-- maxIlvl }. Returns true when the item should be sold.
-- Protections always beat rules; the force-sell list beats the
-- equippable-only restriction but never the protections.
local function DecideSale(cfg, facts)
    -- hard protections
    if facts.hasNoValue then return false end
    if facts.protected then return false end
    if facts.inSet then return false end
    if facts.upgradable then return false end
    if facts.unboundTradable then return false end

    if facts.forced then return true end

    -- rules apply to equippable gear only (weapons/armor)
    if facts.classID ~= 2 and facts.classID ~= 4 then return false end
    if type(facts.quality) ~= "number" then return false end
    if facts.quality > (cfg.maxQuality or 0) then return false end
    local maxIlvl = cfg.maxIlvl or 0
    if maxIlvl > 0 then
        if type(facts.ilvl) ~= "number" then return false end
        if facts.ilvl >= maxIlvl then return false end
    end
    return true
end
-- <<< QUI_TEST_EXTRACT decide_sale

-- Parse an itemID list ("123, 456" / newline separated) into a set.
local function ParseIDList(text)
    local set = {}
    if type(text) == "string" then
        for id in text:gmatch("%d+") do
            set[tonumber(id)] = true
        end
    end
    return set
end

local function GatherFacts(info, bag, slot, forceSet, neverSet)
    local facts = {
        quality = info.quality,
        hasNoValue = info.hasNoValue and true or false,
        forced = (info.itemID and forceSet[info.itemID]) and true or false,
        protected = (info.itemID and neverSet[info.itemID]) and true or false,
        inSet = false,
        upgradable = false,
        unboundTradable = false,
        classID = nil,
        ilvl = nil,
    }

    if C_Container.GetContainerItemEquipmentSetInfo then
        facts.inSet = C_Container.GetContainerItemEquipmentSetInfo(bag, slot) and true or false
    end

    local link = info.hyperlink
    if link then
        local okI, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, link)
        if okI then facts.classID = classID end

        if C_Item.GetItemUpgradeInfo then
            local okU, u = pcall(C_Item.GetItemUpgradeInfo, link)
            if okU and u and u.currentLevel and u.maxLevel and u.currentLevel < u.maxLevel then
                facts.upgradable = true
            end
        end

        if C_Item.GetDetailedItemLevelInfo then
            local okL, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
            if okL and type(ilvl) == "number" then facts.ilvl = ilvl end
        end
    end

    -- Unbound gear that binds on equip / to account still has trade value.
    -- ContainerItemInfo.isBound == false + a binding bindType. Details come
    -- from GetItemInfo (12th/13th returns unused here; bindType is 14th) —
    -- use the container flag + tooltip-free heuristic: unbound equippables
    -- are protected outright (safest: worn gear is always bound).
    if info.isBound == false and (facts.classID == 2 or facts.classID == 4) then
        facts.unboundTradable = true
    end

    return facts
end

local function RunRules()
    local settings = GetSettings()
    local cfg = settings and settings.vendorRules
    if not cfg or not cfg.enabled then return end

    local forceSet = ParseIDList(cfg.forceSell)
    local neverSet = ParseIDList(cfg.neverSell)
    local preview = cfg.previewOnly ~= false -- default true until explicitly off
    local sold = 0

    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if sold >= MAX_SALES_PER_VISIT then break end
            local info = C_Container.GetContainerItemInfo(bag, slot) -- MayReturnNothing
            if info and not info.isLocked then
                local facts = GatherFacts(info, bag, slot, forceSet, neverSet)
                if DecideSale(cfg, facts) then
                    sold = sold + 1
                    if preview then
                        print("|cff60A5FAQUI Vendor Rules (preview):|r would sell "
                            .. (info.hyperlink or ("item " .. tostring(info.itemID))))
                    else
                        C_Container.UseContainerItem(bag, slot)
                    end
                end
            end
        end
        if sold >= MAX_SALES_PER_VISIT then break end
    end

    if sold > 0 then
        if preview then
            print(("|cff60A5FAQUI Vendor Rules:|r preview mode — %d item(s) matched. Disable preview in QoL > Merchant to sell for real."):format(sold))
        else
            print(("|cff60A5FAQUI Vendor Rules:|r sold %d item(s)%s."):format(sold,
                sold >= MAX_SALES_PER_VISIT and " (per-visit cap reached)" or ""))
        end
    end
end

local frame = CreateFrame("Frame")
-- Literal RegisterEvent call so tools/generate_event_allowlist.lua detects it.
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", function()
    -- Defer a frame: let auto-repair/junk-sell (qol.lua MERCHANT_SHOW) run
    -- first so the cap counts only rule sales.
    C_Timer.After(0, RunRules)
end)

ns.RunVendorRules = RunRules
