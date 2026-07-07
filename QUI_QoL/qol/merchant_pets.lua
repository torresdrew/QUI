local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- MERCHANT KNOWN-PET MARKS
--
-- Overlays a green check on merchant items that teach a battle pet you have
-- already collected, so vendor pet shopping doesn't need journal cross-checks.
--
-- Detection: C_Item.GetItemInfoInstant(link) (doc-verified: classID 6th /
-- subClassID 7th return) gates to pet items (classID 17 = Battlepet, or
-- 15/2 = Miscellaneous/CompanionPet — ItemConstantsDocumentation), then
-- C_PetJournal.GetPetInfoByItemID(itemID) -> speciesID (13th return) and
-- C_PetJournal.GetNumCollectedInfo(speciesID) > 0. Both C_PetJournal calls
-- are absent from the generated docs but used by 12.x Blizzard code
-- (DressUpFrames.lua / Blizzard_PetBattleUI.lua) — existence-guarded here.
--
-- Wiring: post-hook on MerchantFrame_UpdateMerchantInfo (page changes call
-- it too). Iterates MerchantItem{i}ItemButton up to the CURRENT
-- MERCHANT_ITEMS_PER_PAGE — the QUI merchant grid raises it, and its extra
-- buttons exist before the raise (merchant_grid.lua invariant), so this
-- covers the enlarged grid automatically. Collected-state cached per itemID;
-- wiped on pet-journal changes.
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local collectedCache = {} -- itemID -> bool (pet item -> already collected)
local overlays = {}       -- button -> Texture

local function IsPetCollected(itemID)
    local cached = collectedCache[itemID]
    if cached ~= nil then return cached end
    local PJ = C_PetJournal
    if not (PJ and PJ.GetPetInfoByItemID and PJ.GetNumCollectedInfo) then return false end
    local owned = false
    local okSpecies, speciesID = pcall(function()
        return (select(13, PJ.GetPetInfoByItemID(itemID)))
    end)
    if okSpecies and type(speciesID) == "number" and speciesID > 0 then
        local okCount, numCollected = pcall(PJ.GetNumCollectedInfo, speciesID)
        owned = okCount and (numCollected or 0) > 0
    end
    collectedCache[itemID] = owned
    return owned
end

local function EnsureOverlay(button)
    local tex = overlays[button]
    if not tex then
        tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetSize(16, 16)
        tex:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 2)
        tex:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        overlays[button] = tex
    end
    return tex
end

local function UpdateMerchant()
    local merchantFrame = _G.MerchantFrame
    if not merchantFrame or not merchantFrame:IsShown() then return end
    -- Only decorate the merchant tab; the buyback tab reuses the buttons.
    if merchantFrame.selectedTab and merchantFrame.selectedTab ~= 1 then return end

    local settings = GetSettings()
    local enabled = settings and settings.merchantKnownPetMark == true
    local perPage = _G.MERCHANT_ITEMS_PER_PAGE or 10
    local page = merchantFrame.page or 1
    local GetLink = _G.GetMerchantItemLink

    for i = 1, perPage do
        local button = _G["MerchantItem" .. i .. "ItemButton"]
        if button then
            local show = false
            if enabled and GetLink and button:IsShown() then
                local index = ((page - 1) * perPage) + i
                local link = GetLink(index)
                if link then
                    local okInfo, itemID, _, _, _, _, classID, subclassID =
                        pcall(C_Item.GetItemInfoInstant, link)
                    if okInfo and itemID
                        and (classID == 17 or (classID == 15 and subclassID == 2)) then
                        show = IsPetCollected(itemID)
                    end
                end
            end
            if show then
                EnsureOverlay(button):Show()
            elseif overlays[button] then
                overlays[button]:Hide()
            end
        end
    end
end

hooksecurefunc("MerchantFrame_UpdateMerchantInfo", UpdateMerchant)

local frame = CreateFrame("Frame")
-- Literal RegisterEvent calls so tools/generate_event_allowlist.lua detects them.
frame:RegisterEvent("PET_JOURNAL_LIST_UPDATE")
frame:RegisterEvent("NEW_PET_ADDED")
frame:SetScript("OnEvent", function()
    wipe(collectedCache)
    UpdateMerchant()
end)

ns.RefreshMerchantPetMarks = UpdateMerchant
