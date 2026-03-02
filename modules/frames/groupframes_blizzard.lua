--[[
    QUI Group Frames - Blizzard Frame Hider
    Hides default Blizzard party/raid frames when QUI group frames are enabled.
    Uses alpha=0 + EnableMouse(false) pattern for taint safety (never Hide() secure frames).
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local GetDB = Helpers.CreateDBGetter("quiGroupFrames")

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_GFB = {}
ns.QUI_GroupFrameBlizzard = QUI_GFB

-- Track what we've hidden so we can restore
local hiddenFrames = {}
local watcherFrame = nil
local hookedFrames = setmetatable({}, { __mode = "k" })

---------------------------------------------------------------------------
-- HELPERS: Safe hide (alpha=0, no mouse, off-screen)
---------------------------------------------------------------------------
local function SafeHideFrame(frame)
    if not frame then return end
    if InCombatLockdown() then return false end

    pcall(function()
        frame:SetAlpha(0)
        frame:EnableMouse(false)
    end)

    hiddenFrames[frame] = true
    return true
end

local function SafeHideFrameOffscreen(frame)
    if not frame then return end
    if InCombatLockdown() then return false end

    pcall(function()
        frame:SetAlpha(0)
        frame:EnableMouse(false)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10000, 10000)
    end)

    hiddenFrames[frame] = true
    return true
end

---------------------------------------------------------------------------
-- HELPERS: Restore frame
---------------------------------------------------------------------------
local function RestoreFrame(frame)
    if not frame then return end
    if InCombatLockdown() then return false end

    pcall(function()
        frame:SetAlpha(1)
        frame:EnableMouse(true)
    end)

    hiddenFrames[frame] = nil
    return true
end

---------------------------------------------------------------------------
-- HIDE: Blizzard party frames
---------------------------------------------------------------------------
local function HideBlizzardPartyFrames()
    if InCombatLockdown() then return end

    -- CompactPartyFrame (Retail party frames)
    if CompactPartyFrame then
        SafeHideFrame(CompactPartyFrame)
    end

    -- Legacy PartyMemberFrame1-4
    for i = 1, 4 do
        local pf = _G["PartyMemberFrame" .. i]
        if pf then
            SafeHideFrameOffscreen(pf)
            if pf.UnregisterAllEvents then
                pcall(pf.UnregisterAllEvents, pf)
            end
        end
    end
end

---------------------------------------------------------------------------
-- HIDE: Blizzard raid frames
---------------------------------------------------------------------------
local function HideBlizzardRaidFrames()
    if InCombatLockdown() then return end

    -- CompactRaidFrameContainer
    if CompactRaidFrameContainer then
        SafeHideFrame(CompactRaidFrameContainer)
    end

    -- CompactRaidFrameManager (the "raid" tab on left side)
    if CompactRaidFrameManager then
        SafeHideFrame(CompactRaidFrameManager)
    end
end

---------------------------------------------------------------------------
-- HIDE: All Blizzard group frames
---------------------------------------------------------------------------
function QUI_GFB:HideBlizzardFrames()
    local db = GetDB()
    if not db or not db.enabled then return end

    if InCombatLockdown() then
        -- Defer to combat end
        self.pendingHide = true
        return
    end

    HideBlizzardPartyFrames()
    HideBlizzardRaidFrames()

    -- Start watcher to re-hide frames if Blizzard restores them
    self:StartWatcher()
end

---------------------------------------------------------------------------
-- RESTORE: All Blizzard group frames
---------------------------------------------------------------------------
function QUI_GFB:RestoreBlizzardFrames()
    if InCombatLockdown() then
        self.pendingRestore = true
        return
    end

    -- Restore all hidden frames
    for frame in pairs(hiddenFrames) do
        RestoreFrame(frame)
    end
    wipe(hiddenFrames)

    -- Stop watcher
    self:StopWatcher()
end

---------------------------------------------------------------------------
-- WATCHER: Re-hide if Blizzard restores frames
---------------------------------------------------------------------------
function QUI_GFB:StartWatcher()
    if watcherFrame then return end

    watcherFrame = CreateFrame("Frame")
    local elapsed = 0
    watcherFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 1.0 then return end -- Check every second
        elapsed = 0

        -- Skip during edit mode
        if Helpers.IsEditModeActive and Helpers.IsEditModeActive() then return end
        if InCombatLockdown() then return end

        local db = GetDB()
        if not db or not db.enabled then return end

        -- Re-hide CompactPartyFrame if it became visible
        if CompactPartyFrame and CompactPartyFrame:GetAlpha() > 0 then
            C_Timer.After(0, function()
                if InCombatLockdown() then return end
                SafeHideFrame(CompactPartyFrame)
            end)
        end

        -- Re-hide CompactRaidFrameManager if it became visible
        if CompactRaidFrameManager and CompactRaidFrameManager:GetAlpha() > 0 then
            C_Timer.After(0, function()
                if InCombatLockdown() then return end
                SafeHideFrame(CompactRaidFrameManager)
            end)
        end

        -- Re-hide CompactRaidFrameContainer if it became visible
        if CompactRaidFrameContainer and CompactRaidFrameContainer:GetAlpha() > 0 then
            C_Timer.After(0, function()
                if InCombatLockdown() then return end
                SafeHideFrame(CompactRaidFrameContainer)
            end)
        end
    end)
end

function QUI_GFB:StopWatcher()
    if watcherFrame then
        watcherFrame:SetScript("OnUpdate", nil)
        watcherFrame:Hide()
        watcherFrame = nil
    end
end

---------------------------------------------------------------------------
-- COMBAT EVENTS: Deferred operations
---------------------------------------------------------------------------
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    if QUI_GFB.pendingHide then
        QUI_GFB.pendingHide = false
        QUI_GFB:HideBlizzardFrames()
    end
    if QUI_GFB.pendingRestore then
        QUI_GFB.pendingRestore = false
        QUI_GFB:RestoreBlizzardFrames()
    end
end)
