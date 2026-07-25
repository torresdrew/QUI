local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- COLLECTION FANFARE AUTO-CLEAR ("auto-unwrap")
--
-- New mounts/pets/toys arrive "wrapped": the Collections journal shows a
-- present-box fanfare per item and the collections microbutton keeps an
-- "unopened items" alert up until each is clicked. This clears all pending
-- fanfares automatically and dismisses the alert.
--
-- APIs verified against tests/api-docs/blizzard/:
--   C_MountJournal: GetNumMountsNeedingFanfare / NeedsFanfare / ClearFanfare /
--     Get+SetCollectedFilterSetting / GetNumDisplayedMounts / GetDisplayedMountID.
--   C_ToyBoxInfo: NeedsFanfare / ClearFanfare (+ NEW_TOY_ADDED).
--   NEW_MOUNT_ADDED / NEW_PET_ADDED / NEW_TOY_ADDED events.
-- Legacy/undocumented, existence-guarded at every call site (mirrors how the
-- 12.x Blizzard_Collections code itself reaches them):
--   C_ToyBox.GetNumToys / GetToyFromIndex, ToyBox.fanfareToys (only when the
--   Blizzard_Collections addon is loaded), C_PetJournal fanfare trio (absent
--   from the 12.x generated docs — pet branch no-ops if the API is gone).
--   LE_MOUNT_JOURNAL_FILTER_COLLECTED/UNUSABLE (used by Blizzard_MountCollection).
--   MainMenuMicroButton_HideAlert / CollectionsMicroButton_SetAlertShown
--   (Blizzard_MicroMenu), COLLECTION_UNOPENED_PLURAL/SINGULAR global strings.
--
-- Mount clearing needs the journal filters temporarily forced to
-- collected-only (NeedsFanfare walks *displayed* mounts); previous filter
-- settings are saved and restored. All calls are insecure-safe (journal
-- APIs, no combat/secure interaction).
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local function Enabled()
    local s = GetSettings()
    return s and s.autoUnwrapCollections == true
end

local function StopCollectionAlert()
    local button = _G.CollectionsMicroButton
    if button and MainMenuMicroButton_HideAlert then
        MainMenuMicroButton_HideAlert(button)
    end
    if CollectionsMicroButton_SetAlertShown then
        CollectionsMicroButton_SetAlertShown(false)
    end
end

local function ClearMountFanfare()
    if not (C_MountJournal and C_MountJournal.GetNumMountsNeedingFanfare) then return false end
    if C_MountJournal.GetNumMountsNeedingFanfare() <= 0 then return false end
    if LE_MOUNT_JOURNAL_FILTER_COLLECTED == nil or LE_MOUNT_JOURNAL_FILTER_UNUSABLE == nil then return false end

    -- NeedsFanfare only walks displayed mounts: force collected-only filters,
    -- clear, then restore the user's filter settings.
    local saved = {}
    for i = LE_MOUNT_JOURNAL_FILTER_COLLECTED, LE_MOUNT_JOURNAL_FILTER_UNUSABLE do
        saved[i] = C_MountJournal.GetCollectedFilterSetting(i) and true or false
        C_MountJournal.SetCollectedFilterSetting(i, i == LE_MOUNT_JOURNAL_FILTER_COLLECTED)
    end

    for i = 1, C_MountJournal.GetNumDisplayedMounts() do
        local mountID = C_MountJournal.GetDisplayedMountID(i)
        if mountID and C_MountJournal.NeedsFanfare(mountID) then
            C_MountJournal.ClearFanfare(mountID)
        end
    end

    for i = LE_MOUNT_JOURNAL_FILTER_COLLECTED, LE_MOUNT_JOURNAL_FILTER_UNUSABLE do
        C_MountJournal.SetCollectedFilterSetting(i, saved[i])
    end
    return true
end

-- Pet fanfare APIs are absent from the 12.x generated docs; keep the branch
-- fully existence-guarded so it silently no-ops if the API is gone and starts
-- working again if it returns.
local function ClearPetFanfare()
    local PJ = C_PetJournal
    if not (PJ and PJ.GetNumPetsNeedingFanfare and PJ.GetOwnedPetIDs and PJ.PetNeedsFanfare and PJ.ClearFanfare) then
        return false
    end
    if (PJ.GetNumPetsNeedingFanfare() or 0) == 0 then return false end
    local cleared = false
    for _, petID in ipairs(PJ.GetOwnedPetIDs() or {}) do
        if petID and PJ.PetNeedsFanfare(petID) then
            PJ.ClearFanfare(petID)
            cleared = true
        end
    end
    return cleared
end

local function ClearToyFanfare()
    if not (C_ToyBoxInfo and C_ToyBoxInfo.NeedsFanfare and C_ToyBoxInfo.ClearFanfare) then return false end
    local cleared = false

    -- Fast path: the ToyBox frame tracks pending fanfares once
    -- Blizzard_Collections has loaded.
    local toyBoxFrame = _G.ToyBox
    if toyBoxFrame and type(toyBoxFrame.fanfareToys) == "table" then
        for toyID, needs in pairs(toyBoxFrame.fanfareToys) do
            if needs and toyID and C_ToyBoxInfo.NeedsFanfare(toyID) then
                C_ToyBoxInfo.ClearFanfare(toyID)
                cleared = true
            end
        end
        if cleared then return true end
    end

    -- Full scan fallback (legacy C_ToyBox namespace, existence-guarded).
    if C_ToyBox and C_ToyBox.GetNumToys and C_ToyBox.GetToyFromIndex then
        for i = 1, C_ToyBox.GetNumToys() do
            local toyID = C_ToyBox.GetToyFromIndex(i)
            if toyID and toyID > 0 and C_ToyBoxInfo.NeedsFanfare(toyID) then
                C_ToyBoxInfo.ClearFanfare(toyID)
                cleared = true
            end
        end
    end
    return cleared
end

local pending = false
local function ClearAllSoon()
    if not Enabled() or pending then return end
    pending = true
    -- Small delay: batches the burst of NEW_*_ADDED events after opening a
    -- wrapped drop, and defers out of the event's execution context.
    C_Timer.After(0.2, function()
        pending = false
        if not Enabled() then return end
        local any = ClearMountFanfare()
        any = ClearPetFanfare() or any
        any = ClearToyFanfare() or any
        if any then StopCollectionAlert() end
    end)
end

-- The microbutton alert fires with the "unopened items" text when wrapped
-- collectibles are pending; use it as a trigger and clear immediately.
hooksecurefunc("MainMenuMicroButton_ShowAlert", function(_, text)
    if text == COLLECTION_UNOPENED_PLURAL or text == COLLECTION_UNOPENED_SINGULAR then
        ClearAllSoon()
    end
end)

local frame = CreateFrame("Frame")
-- Literal RegisterEvent calls so tools/generate_event_allowlist.lua detects them.
frame:RegisterEvent("NEW_MOUNT_ADDED")
frame:RegisterEvent("NEW_PET_ADDED")
frame:RegisterEvent("NEW_TOY_ADDED")
frame:SetScript("OnEvent", function()
    ClearAllSoon()
end)

ns.RefreshCollectionFanfare = ClearAllSoon

if ns.WhenLoggedIn then
    ns.WhenLoggedIn(ClearAllSoon)
end
