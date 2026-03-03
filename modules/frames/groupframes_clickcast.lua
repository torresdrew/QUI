--[[
    QUI Group Frames - Click-Casting Framework
    Native click-casting that works independently of Clique.
    Features: modifier combos, smart resurrection, per-spec profiles,
    Clique coexistence, binding tooltip on frame hover.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local GetDB = Helpers.CreateDBGetter("quiGroupFrames")

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_GFCC = {}
ns.QUI_GroupFrameClickCast = QUI_GFCC

-- Track registered frames
local registeredFrames = setmetatable({}, { __mode = "k" })
local activeBindings = {} -- Resolved bindings for current spec
local isEnabled = false

---------------------------------------------------------------------------
-- MODIFIER HELPERS
---------------------------------------------------------------------------
local MODIFIER_MAP = {
    [""]      = function() return not IsShiftKeyDown() and not IsControlKeyDown() and not IsAltKeyDown() end,
    ["shift"] = function() return IsShiftKeyDown() and not IsControlKeyDown() and not IsAltKeyDown() end,
    ["ctrl"]  = function() return not IsShiftKeyDown() and IsControlKeyDown() and not IsAltKeyDown() end,
    ["alt"]   = function() return not IsShiftKeyDown() and not IsControlKeyDown() and IsAltKeyDown() end,
    ["shift-ctrl"]  = function() return IsShiftKeyDown() and IsControlKeyDown() and not IsAltKeyDown() end,
    ["shift-alt"]   = function() return IsShiftKeyDown() and not IsControlKeyDown() and IsAltKeyDown() end,
    ["ctrl-alt"]    = function() return not IsShiftKeyDown() and IsControlKeyDown() and IsAltKeyDown() end,
    ["shift-ctrl-alt"] = function() return IsShiftKeyDown() and IsControlKeyDown() and IsAltKeyDown() end,
}

local BUTTON_NAMES = {
    LeftButton = "Left Click",
    RightButton = "Right Click",
    MiddleButton = "Middle Click",
    Button4 = "Button 4",
    Button5 = "Button 5",
}

local MODIFIER_LABELS = {
    [""]      = "",
    ["shift"] = "Shift+",
    ["ctrl"]  = "Ctrl+",
    ["alt"]   = "Alt+",
    ["shift-ctrl"]  = "Shift+Ctrl+",
    ["shift-alt"]   = "Shift+Alt+",
    ["ctrl-alt"]    = "Ctrl+Alt+",
    ["shift-ctrl-alt"] = "Shift+Ctrl+Alt+",
}

---------------------------------------------------------------------------
-- RESURRECTION SPELLS: Per-class res spell IDs
---------------------------------------------------------------------------
local RES_SPELLS = {
    PRIEST      = 2006,   -- Resurrection
    PALADIN     = 7328,   -- Redemption
    SHAMAN      = 2008,   -- Ancestral Spirit
    DRUID       = 50769,  -- Revive
    MONK        = 115178, -- Resuscitate
    EVOKER      = 361227, -- Return
    WARLOCK     = 20707,  -- Soulstone
    DEATHKNIGHT = 61999,  -- Raise Ally
}

local function GetResurrectionSpellName()
    local _, classToken = UnitClass("player")
    local spellID = RES_SPELLS[classToken]
    if spellID then
        local name = C_Spell.GetSpellName(spellID)
        return name
    end
    return nil
end

---------------------------------------------------------------------------
-- BINDING RESOLUTION: Build active binding set for current spec
---------------------------------------------------------------------------
local function ResolveBindings()
    wipe(activeBindings)

    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return end

    local bindings = db.clickCast.bindings
    if not bindings then return end

    -- If per-spec, filter to current spec
    if db.clickCast.perSpec then
        local specID = GetSpecializationInfo(GetSpecialization() or 1)
        if specID then
            -- Look for spec-specific bindings
            local specBindings = db.clickCast.specBindings and db.clickCast.specBindings[specID]
            if specBindings then
                bindings = specBindings
            end
        end
    end

    for _, binding in ipairs(bindings) do
        if binding.button and binding.spell then
            table.insert(activeBindings, {
                button = binding.button,
                modifiers = binding.modifiers or "",
                spell = binding.spell,
                macro = binding.macro,
                actionType = binding.actionType, -- "spell", "macro", "target", "focus", "assist"
            })
        end
    end
end

---------------------------------------------------------------------------
-- FRAME SETUP: Apply click-cast attributes to a frame
---------------------------------------------------------------------------
local function SetupFrameClickCast(frame)
    if not frame or registeredFrames[frame] then return end
    if InCombatLockdown() then return end

    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return end

    -- Set secure attributes for each binding
    for _, binding in ipairs(activeBindings) do
        local prefix = ""
        local mods = binding.modifiers or ""
        if mods ~= "" then
            -- Convert "shift" to "shift-", "ctrl" to "ctrl-", etc.
            prefix = mods:gsub("%-$", "") .. "-"
            if not prefix:find("-$") then prefix = prefix .. "-" end
        end

        local attrType = prefix .. "type" .. (binding.button == "LeftButton" and "1" or
            binding.button == "RightButton" and "2" or
            binding.button == "MiddleButton" and "3" or
            binding.button == "Button4" and "4" or
            binding.button == "Button5" and "5" or "1")

        local actionType = binding.actionType or "spell"

        if actionType == "spell" then
            frame:SetAttribute(attrType, "spell")
            local spellAttr = prefix .. "spell-" .. (binding.button == "LeftButton" and "1" or
                binding.button == "RightButton" and "2" or
                binding.button == "MiddleButton" and "3" or
                binding.button == "Button4" and "4" or
                binding.button == "Button5" and "5" or "1")
            frame:SetAttribute(spellAttr, binding.spell)
        elseif actionType == "macro" then
            frame:SetAttribute(attrType, "macro")
            local macroAttr = prefix .. "macrotext-" .. (binding.button == "LeftButton" and "1" or
                binding.button == "RightButton" and "2" or
                binding.button == "MiddleButton" and "3" or "1")
            frame:SetAttribute(macroAttr, binding.macro)
        elseif actionType == "target" then
            frame:SetAttribute(attrType, "target")
        elseif actionType == "focus" then
            frame:SetAttribute(attrType, "focus")
        elseif actionType == "assist" then
            frame:SetAttribute(attrType, "assist")
        end
    end

    registeredFrames[frame] = true

    -- Smart resurrection: hook to swap spell when target is dead
    if db.clickCast.smartRes then
        local resSpell = GetResurrectionSpellName()
        if resSpell then
            frame:HookScript("OnEnter", function(self)
                if InCombatLockdown() then return end
                local unit = self:GetAttribute("unit")
                if unit and UnitIsDeadOrGhost(unit) and (UnitIsConnected(unit) or not UnitIsPlayer(unit)) then
                    -- Swap left click to res
                    self:SetAttribute("type1", "spell")
                    self:SetAttribute("spell1", resSpell)
                end
            end)
            frame:HookScript("OnLeave", function(self)
                if InCombatLockdown() then return end
                -- Restore normal binding
                local normalBinding = nil
                for _, b in ipairs(activeBindings) do
                    if b.button == "LeftButton" and (b.modifiers or "") == "" then
                        normalBinding = b
                        break
                    end
                end
                if normalBinding then
                    self:SetAttribute("type1", normalBinding.actionType or "spell")
                    if normalBinding.actionType == "spell" or not normalBinding.actionType then
                        self:SetAttribute("spell1", normalBinding.spell)
                    end
                else
                    -- Default: target
                    self:SetAttribute("type1", "target")
                end
            end)
        end
    end

    -- Tooltip showing available bindings
    if db.clickCast.showTooltip then
        frame:HookScript("OnEnter", function(self)
            if #activeBindings == 0 then return end

            -- Check if we should show tooltip (avoid conflict with unit tooltip)
            local existingOwner = GameTooltip:GetOwner()
            if existingOwner == self then
                -- Append to existing unit tooltip
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Click-Cast Bindings:", 0.2, 0.83, 0.6)
                for _, binding in ipairs(activeBindings) do
                    local modLabel = MODIFIER_LABELS[binding.modifiers or ""] or ""
                    local buttonLabel = BUTTON_NAMES[binding.button] or binding.button
                    local spellLabel = binding.spell or binding.actionType or "?"
                    GameTooltip:AddDoubleLine(
                        modLabel .. buttonLabel,
                        spellLabel,
                        0.8, 0.8, 0.8, 1, 1, 1
                    )
                end
                GameTooltip:Show()
            end
        end)
    end
end

---------------------------------------------------------------------------
-- CLEAR: Remove click-cast attributes from a frame
---------------------------------------------------------------------------
local function ClearFrameClickCast(frame)
    if not frame or not registeredFrames[frame] then return end
    if InCombatLockdown() then return end

    -- Restore default target/menu behavior
    frame:SetAttribute("*type1", "target")
    frame:SetAttribute("*type2", "togglemenu")

    registeredFrames[frame] = nil
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------
function QUI_GFCC:Initialize()
    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return end

    -- Check Clique coexistence
    if IsAddOnLoaded and IsAddOnLoaded("Clique") then
        -- Clique is loaded — disable QUI click-cast by default
        -- unless user explicitly enabled it
        if not db.clickCast.forceOverClique then
            return
        end
    end

    ResolveBindings()
    isEnabled = true
end

function QUI_GFCC:RegisterFrame(frame)
    if not isEnabled then return end
    SetupFrameClickCast(frame)
end

function QUI_GFCC:UnregisterFrame(frame)
    ClearFrameClickCast(frame)
end

function QUI_GFCC:RegisterAllFrames()
    if not isEnabled then return end
    local GF = ns.QUI_GroupFrames
    if not GF then return end

    for _, frame in pairs(GF.unitFrameMap) do
        SetupFrameClickCast(frame)
    end
end

function QUI_GFCC:RefreshBindings()
    if InCombatLockdown() then return end

    -- Clear all existing bindings
    for frame in pairs(registeredFrames) do
        ClearFrameClickCast(frame)
    end
    wipe(registeredFrames)

    -- Re-resolve and re-apply
    ResolveBindings()
    self:RegisterAllFrames()
end

function QUI_GFCC:IsEnabled()
    return isEnabled
end

function QUI_GFCC:GetActiveBindings()
    return activeBindings
end

---------------------------------------------------------------------------
-- EVENTS: Spec change and combat end
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event)
    if not isEnabled then return end

    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Re-resolve bindings for new spec
        C_Timer.After(0.5, function()
            if not InCombatLockdown() then
                QUI_GFCC:RefreshBindings()
            end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Apply any deferred binding changes
        if QUI_GFCC.pendingRefresh then
            QUI_GFCC.pendingRefresh = false
            QUI_GFCC:RefreshBindings()
        end
    end
end)
