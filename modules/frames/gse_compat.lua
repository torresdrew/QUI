--[[
    QUI GSE Action Bar Compatibility

    GSE identifies override-capable action buttons by global name prefix
    (ActionButton, MultiBarBottomLeftButton, BT4, ElvUI, Dominos, ...).
    QUI's native engine creates buttons named QUI_Bar<N>Button<i> /
    QUI_PetButton<i> / QUI_StanceButton<i>, none of which match GSE's
    prefix table, so GSE falls into its generic third-party branch and
    applies an OnEnter WrapScript that is restricted on ActionButtonTemplate
    in modern WoW — the override install errors and the button never fires
    the GSE sequence.

    This shim intercepts GSE.CreateActionBarOverride / RemoveActionBarOverride
    for QUI-owned buttons and installs the equivalent secure OnClick WrapScript
    ourselves (OnClick WrapScript IS allowed on ActionButtonTemplate; only
    OnEnter WrapScript is blocked — confirmed by GSE's own Events.lua:532
    comment).  OnEnter tooltip/type-correction is handled via a non-secure
    HookScript.  QUI-button overrides are persisted in our own AceDB table
    and re-applied on login / spec change, so GSE's LoadOverrides loop never
    touches them.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local GetCore = Helpers and Helpers.GetCore

local pairs = pairs
local type = type
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer

---------------------------------------------------------------------------
-- Button name classification
---------------------------------------------------------------------------

local function IsQUIButtonName(name)
    if type(name) ~= "string" then return false end
    if name:match("^QUI_Bar[1-8]Button%d+$") then return true end
    if name:match("^QUI_PetButton%d+$") then return true end
    if name:match("^QUI_StanceButton%d+$") then return true end
    return false
end

---------------------------------------------------------------------------
-- Secure handler + snippets
--
-- BAR_SWAP_OAC / BAR_SWAP_ONCLICK mirror GSE's equivalent snippets: they
-- flip between type="click" (fire GSE sequence) and type="action" (let a
-- vehicle/override/possession bar handle the slot).  Kept behaviourally
-- identical so vehicle transitions work the same on QUI buttons as on
-- native Blizzard bars.
---------------------------------------------------------------------------

local SHBT
local function GetSHBT()
    if not SHBT then
        SHBT = CreateFrame("Frame", "QUI_GSECompatSecureHandler", nil,
            "SecureHandlerBaseTemplate,SecureFrameTemplate")
    end
    return SHBT
end

local BAR_SWAP_OAC = [[
    if name ~= "action" and name ~= "pressandholdaction" then return end
    if not self:GetAttribute("gse-button") then return end
    local slot = self:GetID()
    local page = slot > 0 and self:GetEffectiveAttribute("actionpage") or nil
    local effectiveAction = (slot == 0 or not page) and self:GetEffectiveAttribute("action")
                            or (page and (slot + page * 12 - 12)) or nil
    if effectiveAction then
        local at = GetActionInfo(effectiveAction)
        if at == nil or at == "macro" then
            self:SetAttribute("type", "click")
        else
            self:SetAttribute("type", "action")
        end
    end
]]

local BAR_SWAP_ONCLICK = [[
    local gseButton = self:GetAttribute('gse-button')
    if gseButton then
        local slot = self:GetID()
        local page = slot > 0 and self:GetEffectiveAttribute("actionpage") or nil
        local effectiveAction = (slot == 0 or not page) and self:GetEffectiveAttribute("action")
                                or (page and (slot + page * 12 - 12)) or nil
        if effectiveAction then
            local at = GetActionInfo(effectiveAction)
            if at == nil or at == "macro" then
                self:SetAttribute('type', 'click')
            else
                self:SetAttribute('type', 'action')
            end
        end
    else
        self:SetAttribute('type', 'action')
    end
]]

---------------------------------------------------------------------------
-- Per-button install / uninstall
---------------------------------------------------------------------------

local wrappedButtons = {}   -- [buttonName] = true  (WrapScripts installed once)
local onEnterHooked = {}    -- [buttonName] = true  (HookScript installed once)

local function HookOnEnterOnce(btn, buttonName)
    if onEnterHooked[buttonName] then return end
    onEnterHooked[buttonName] = true
    btn:HookScript("OnEnter", function(self)
        if InCombatLockdown() then return end
        if self:GetAttribute("gse-button") then
            self:SetAttribute("type", "click")
        end
    end)
end

local function InstallOverrideOnButton(buttonName, sequenceName)
    if InCombatLockdown() then return false end
    local btn = _G[buttonName]
    if not btn then return false end
    if not _G[sequenceName] then
        -- GSE stores each sequence as a global SecureActionButton frame named
        -- after the sequence.  Missing global means the sequence hasn't been
        -- compiled yet — skip; GSE.ReloadOverrides will retry later.
        return false
    end

    local handler = GetSHBT()
    if not wrappedButtons[buttonName] then
        -- WrapScript on OnClick is allowed on ActionButtonTemplate; OnEnter is not.
        handler:WrapScript(btn, "OnClick", BAR_SWAP_ONCLICK)
        handler:WrapScript(btn, "OnAttributeChanged", BAR_SWAP_OAC)
        wrappedButtons[buttonName] = true
    end

    HookOnEnterOnce(btn, buttonName)

    btn:SetAttribute("gse-button", sequenceName)
    btn:SetAttribute("type", "click")
    btn:SetAttribute("clickbutton", _G[sequenceName])
    return true
end

local function RemoveOverrideFromButton(buttonName)
    if InCombatLockdown() then return false end
    local btn = _G[buttonName]
    if not btn then return false end
    -- WrapScripts are permanent once installed; clearing the gse-button
    -- attribute makes both snippets fall through to type="action", which
    -- is the correct restored behaviour for a QUI action button.
    btn:SetAttribute("gse-button", nil)
    btn:SetAttribute("clickbutton", nil)
    btn:SetAttribute("type", "action")
    return true
end

---------------------------------------------------------------------------
-- Persistence (QUI DB)
---------------------------------------------------------------------------

local function GetSpecID()
    if GSE and GSE.GetCurrentSpecID then return GSE.GetCurrentSpecID() end
    if PlayerUtil and PlayerUtil.GetCurrentSpecID then
        return PlayerUtil.GetCurrentSpecID() or 0
    end
    return 0
end

local function GetBindingsTable(create)
    local QUI = _G.QUI
    if not QUI or not QUI.db or not QUI.db.profile then return nil end
    local root = QUI.db.profile.gseCompat
    if not root then
        if not create then return nil end
        root = {}
        QUI.db.profile.gseCompat = root
    end
    if not root.bindings then
        if not create then return nil end
        root.bindings = {}
    end
    local spec = GetSpecID()
    local specTable = root.bindings[spec]
    if not specTable then
        if not create then return nil end
        specTable = {}
        root.bindings[spec] = specTable
    end
    return specTable
end

local function SaveBinding(buttonName, sequenceName)
    local t = GetBindingsTable(true)
    if not t then return end
    t[buttonName] = sequenceName
end

local function ClearBinding(buttonName)
    local t = GetBindingsTable(false)
    if not t then return end
    t[buttonName] = nil
end

---------------------------------------------------------------------------
-- Re-install pass (login, spec change, after bar rebuild)
---------------------------------------------------------------------------

local function ReapplyAll()
    if InCombatLockdown() then return end
    local t = GetBindingsTable(false)
    if not t then return end
    for buttonName, sequenceName in pairs(t) do
        if IsQUIButtonName(buttonName) then
            InstallOverrideOnButton(buttonName, sequenceName)
        end
    end
end

---------------------------------------------------------------------------
-- GSE API hooks
---------------------------------------------------------------------------

local hooksInstalled = false

local function InstallGSEHooks()
    if hooksInstalled then return end
    if not _G.GSE then return end
    hooksInstalled = true

    local origCreate = GSE.CreateActionBarOverride
    GSE.CreateActionBarOverride = function(buttonName, sequenceName)
        if IsQUIButtonName(buttonName) then
            if InCombatLockdown() then return end
            if InstallOverrideOnButton(buttonName, sequenceName) then
                SaveBinding(buttonName, sequenceName)
            end
            return
        end
        return origCreate(buttonName, sequenceName)
    end

    local origRemove = GSE.RemoveActionBarOverride
    GSE.RemoveActionBarOverride = function(buttonName)
        if IsQUIButtonName(buttonName) then
            if InCombatLockdown() then return end
            RemoveOverrideFromButton(buttonName)
            ClearBinding(buttonName)
            return
        end
        return origRemove(buttonName)
    end

    -- After GSE reloads overrides (e.g. spec change, sequence recompile) our
    -- QUI button clickbuttons may point at stale sequence frames.  Re-apply.
    if GSE.ReloadOverrides then
        hooksecurefunc(GSE, "ReloadOverrides", function()
            ReapplyAll()
        end)
    end
end

---------------------------------------------------------------------------
-- Right-click sequence picker popup
--
-- GSE hooks OnClick on known addon buttons to show a context menu for
-- assigning / changing / clearing sequence overrides.  QUI buttons are
-- not in that list, so we install the equivalent handler ourselves.
---------------------------------------------------------------------------

local rightClickHooked = {}  -- [buttonName] = true

local function HookRightClickOnce(btn, buttonName)
    if rightClickHooked[buttonName] then return end
    rightClickHooked[buttonName] = true
    btn:HookScript("OnClick", function(self, mousebutton, down)
        if not _G.GSE then return end
        if not _G.GSEOptions or not _G.GSEOptions.actionBarOverridePopup then return end
        if InCombatLockdown() then return end
        if not down then return end
        if mousebutton ~= "RightButton" then return end

        local existingSequence = self:GetAttribute("gse-button")

        if not existingSequence then
            local action = self.action or self:GetAttribute("action")
            if not action or action == 0 then return end
            if HasAction(action) then return end
        end

        local classIconText = ""
        local classInfo = C_CreatureInfo and C_CreatureInfo.GetClassInfo(GSE.GetCurrentClassID())
        if classInfo and classInfo.classFile then
            classIconText = "|A:classicon-" .. classInfo.classFile:lower() .. ":16:16|a "
        end

        local names = {}
        local function addSequences(classID)
            for k, seq in pairs(GSE.Library[classID] or {}) do
                local specID = seq and seq.MetaData and seq.MetaData.SpecID
                local disabled = seq and seq.MetaData and seq.MetaData.Disabled
                names[#names + 1] = { name = k, specID = specID, disabled = disabled }
            end
        end
        addSequences(GSE.GetCurrentClassID())
        addSequences(0)

        table.sort(names, function(a, b) return a.name < b.name end)

        local L = GSE.L or {}
        local bName = self:GetName()
        MenuUtil.CreateContextMenu(self, function(ownerRegion, rootDescription)
            if existingSequence then
                rootDescription:CreateTitle((L["GSE"] or "GSE") .. ": " .. existingSequence)
                rootDescription:CreateButton(L["Clear Override"] or "Clear Override", function()
                    GSE.RemoveActionBarOverride(bName)
                end)
                if #names > 0 then
                    rootDescription:CreateDivider()
                    rootDescription:CreateTitle(L["Change Sequence"] or "Change Sequence")
                end
            else
                rootDescription:CreateTitle(L["Assign GSE Sequence"] or "Assign GSE Sequence")
            end
            for _, entry in ipairs(names) do
                local iconText = classIconText
                local specID = entry.specID
                if specID and specID >= 15 and GetSpecializationInfoByID then
                    local _, _, _, specIconID = GetSpecializationInfoByID(specID)
                    if specIconID then
                        iconText = "|T" .. specIconID .. ":16:16|t "
                    end
                end
                local label = iconText .. entry.name
                if entry.disabled then
                    local element = rootDescription:CreateButton("|cFF808080" .. label .. "|r", function() end)
                    element:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, L["Sequence Disabled"] or "Sequence Disabled")
                    end)
                else
                    rootDescription:CreateButton(label, function()
                        GSE.CreateActionBarOverride(bName, entry.name)
                    end)
                end
            end
        end)
    end)
end

local function HookRightClickAllQUIButtons()
    if not _G.GSE then return end
    for bar = 1, 8 do
        for slot = 1, 12 do
            local name = "QUI_Bar" .. bar .. "Button" .. slot
            local btn = _G[name]
            if btn then
                HookRightClickOnce(btn, name)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Event wiring
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        InstallGSEHooks()
        -- Defer one frame so GSE has finished its own PLAYER_LOGIN setup
        -- (sequence globals, ReloadOverrides) before we install on top.
        C_Timer.After(0.1, function()
            InstallGSEHooks()
            ReapplyAll()
            HookRightClickAllQUIButtons()
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        InstallGSEHooks()
        C_Timer.After(0.1, function()
            ReapplyAll()
            HookRightClickAllQUIButtons()
        end)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        C_Timer.After(0.1, ReapplyAll)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- In case a spec change or reload landed in combat, retry OOC.
        ReapplyAll()
    end
end)

---------------------------------------------------------------------------
-- Public namespace (for debugging / manual re-apply)
---------------------------------------------------------------------------

ns.QUI_GSECompat = {
    IsQUIButtonName = IsQUIButtonName,
    Reapply = ReapplyAll,
    Install = InstallOverrideOnButton,
    Remove = RemoveOverrideFromButton,
}
