---------------------------------------------------------------------------
-- QUI Global Preferences
-- Opt-in system for making individual settings account-wide.
-- Nothing is global by default — the user explicitly opts in per setting.
-- Global values are stored in db.global.preferences and apply across
-- all characters/profiles.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local GlobalPrefs = {}
ns.GlobalPrefs = GlobalPrefs

---------------------------------------------------------------------------
-- ELIGIBLE SETTINGS REGISTRY
-- Only settings listed here can be made global. Each entry has a category
-- (for the bulk-management UI) and a human-readable label.
---------------------------------------------------------------------------
GlobalPrefs.ELIGIBLE = {
    ---------------------------------------------------------------------------
    -- Theme & Display
    ---------------------------------------------------------------------------
    ["general.font"]                       = { category = "Theme & Display",    label = "Master Font" },
    ["general.fontOutline"]                = { category = "Theme & Display",    label = "Font Outline" },
    ["general.texture"]                    = { category = "Theme & Display",    label = "Master Texture" },
    ["general.uiScale"]                    = { category = "Theme & Display",    label = "UI Scale" },
    ["general.darkMode"]                   = { category = "Theme & Display",    label = "Dark Mode" },
    ["general.darkModeHealthColor"]        = { category = "Theme & Display",    label = "Dark Mode Health Color" },
    ["general.darkModeBgColor"]            = { category = "Theme & Display",    label = "Dark Mode Background" },
    ["general.darkModeOpacity"]            = { category = "Theme & Display",    label = "Dark Mode Opacity" },
    ["general.darkModeHealthOpacity"]      = { category = "Theme & Display",    label = "Dark Mode Health Opacity" },
    ["general.darkModeBgOpacity"]          = { category = "Theme & Display",    label = "Dark Mode BG Opacity" },
    ["general.defaultUseClassColor"]       = { category = "Theme & Display",    label = "Use Class Colors" },
    ["general.defaultHealthColor"]         = { category = "Theme & Display",    label = "Default Health Color" },
    ["general.defaultBgColor"]             = { category = "Theme & Display",    label = "Default BG Color" },
    ["general.defaultOpacity"]             = { category = "Theme & Display",    label = "Default Opacity" },
    ["general.defaultHealthOpacity"]       = { category = "Theme & Display",    label = "Default Health Opacity" },
    ["general.defaultBgOpacity"]           = { category = "Theme & Display",    label = "Default BG Opacity" },
    ["general.hostilityColorHostile"]      = { category = "Theme & Display",    label = "Hostile Color" },
    ["general.hostilityColorNeutral"]      = { category = "Theme & Display",    label = "Neutral Color" },
    ["general.hostilityColorFriendly"]     = { category = "Theme & Display",    label = "Friendly Color" },
    ["general.applyGlobalFontToBlizzard"]  = { category = "Theme & Display",    label = "Apply Font to Blizzard" },
    ["general.overrideSCTFont"]            = { category = "Theme & Display",    label = "Override SCT Font" },

    ---------------------------------------------------------------------------
    -- QoL Behavior
    ---------------------------------------------------------------------------
    ["general.sellJunk"]                   = { category = "QoL Behavior",       label = "Auto-Sell Junk" },
    ["general.autoRepair"]                 = { category = "QoL Behavior",       label = "Auto-Repair" },
    ["general.autoRoleAccept"]             = { category = "QoL Behavior",       label = "Auto-Accept Role" },
    ["general.autoAcceptInvites"]          = { category = "QoL Behavior",       label = "Auto-Accept Invites" },
    ["general.autoAcceptQuest"]            = { category = "QoL Behavior",       label = "Auto-Accept Quests" },
    ["general.autoTurnInQuest"]            = { category = "QoL Behavior",       label = "Auto-Turn In Quests" },
    ["general.questHoldShift"]             = { category = "QoL Behavior",       label = "Hold Shift for Quest" },
    ["general.fastAutoLoot"]               = { category = "QoL Behavior",       label = "Fast Auto-Loot" },
    ["general.autoSelectGossip"]           = { category = "QoL Behavior",       label = "Auto-Select Gossip" },
    ["general.autoCombatLog"]              = { category = "QoL Behavior",       label = "Auto Combat Log" },
    ["general.autoCombatLogRaid"]          = { category = "QoL Behavior",       label = "Auto Combat Log Raid" },
    ["general.autoDeleteConfirm"]          = { category = "QoL Behavior",       label = "Auto Delete Confirm" },
    ["general.autoInsertKey"]              = { category = "QoL Behavior",       label = "Auto-Insert Keystone" },
    ["general.petCombatWarning"]           = { category = "QoL Behavior",       label = "Pet Combat Warning" },
    ["general.auctionHouseExpansionFilter"] = { category = "QoL Behavior",      label = "AH Expansion Filter" },
    ["general.craftingOrderExpansionFilter"] = { category = "QoL Behavior",     label = "Crafting Order Filter" },

    ---------------------------------------------------------------------------
    -- Blizzard Skinning
    ---------------------------------------------------------------------------
    ["general.skinGameMenu"]               = { category = "Blizzard Skinning",  label = "Skin Game Menu" },
    ["general.skinKeystoneFrame"]          = { category = "Blizzard Skinning",  label = "Skin Keystone Frame" },
    ["general.skinObjectiveTracker"]       = { category = "Blizzard Skinning",  label = "Skin Objective Tracker" },
    ["general.skinAuctionHouse"]           = { category = "Blizzard Skinning",  label = "Skin Auction House" },
    ["general.skinCraftingOrders"]         = { category = "Blizzard Skinning",  label = "Skin Crafting Orders" },
    ["general.skinProfessions"]            = { category = "Blizzard Skinning",  label = "Skin Professions" },
    ["general.skinAlerts"]                 = { category = "Blizzard Skinning",  label = "Skin Alerts" },
    ["general.skinCharacterFrame"]         = { category = "Blizzard Skinning",  label = "Skin Character Frame" },
    ["general.skinInspectFrame"]           = { category = "Blizzard Skinning",  label = "Skin Inspect Frame" },
    ["general.skinPowerBarAlt"]            = { category = "Blizzard Skinning",  label = "Skin Power Bar Alt" },
    ["general.skinStatusTrackingBars"]     = { category = "Blizzard Skinning",  label = "Skin Status Bars" },
    ["general.skinOverrideActionBar"]      = { category = "Blizzard Skinning",  label = "Skin Override Bar" },
    ["general.skinInstanceFrames"]         = { category = "Blizzard Skinning",  label = "Skin Instance Frames" },
    ["general.skinBgColor"]                = { category = "Blizzard Skinning",  label = "Skin BG Color" },
    ["general.skinUseClassColor"]          = { category = "Blizzard Skinning",  label = "Skin Use Class Color" },
    ["general.objectiveTrackerClickThrough"] = { category = "Blizzard Skinning", label = "OT Click Through" },

    ---------------------------------------------------------------------------
    -- UI Behavior
    ---------------------------------------------------------------------------
    ["general.addQUIButton"]               = { category = "UI Behavior",        label = "Add QUI Button" },
    ["general.addEditModeButton"]          = { category = "UI Behavior",        label = "Add Edit Mode Button" },
    ["general.allowReloadInCombat"]        = { category = "UI Behavior",        label = "Allow Reload in Combat" },
    ["general.gameMenuDim"]                = { category = "UI Behavior",        label = "Dim Game Menu" },
    ["general.gameMenuFontSize"]           = { category = "UI Behavior",        label = "Game Menu Font Size" },

    ---------------------------------------------------------------------------
    -- Tooltip
    ---------------------------------------------------------------------------
    ["tooltip.enabled"]                    = { category = "Tooltip",            label = "Enable Tooltip" },
    ["tooltip.fontSize"]                   = { category = "Tooltip",            label = "Tooltip Font Size" },
    ["tooltip.bgColor"]                    = { category = "Tooltip",            label = "Tooltip BG Color" },
    ["tooltip.borderColor"]                = { category = "Tooltip",            label = "Tooltip Border Color" },
    ["tooltip.borderUseClassColor"]        = { category = "Tooltip",            label = "Border Use Class Color" },

    ---------------------------------------------------------------------------
    -- Chat
    ---------------------------------------------------------------------------
    ["chat.enabled"]                       = { category = "Chat",               label = "Enable Chat" },
    ["chat.glass.enabled"]                 = { category = "Chat",               label = "Glass Effect" },
    ["chat.glass.bgAlpha"]                 = { category = "Chat",               label = "Glass BG Alpha" },
    ["chat.fade.enabled"]                  = { category = "Chat",               label = "Chat Fade" },
    ["chat.fade.delay"]                    = { category = "Chat",               label = "Fade Delay" },
    ["chat.urls.enabled"]                  = { category = "Chat",               label = "URL Detection" },

    ---------------------------------------------------------------------------
    -- Action Bars (global appearance)
    ---------------------------------------------------------------------------
    ["actionBars.global.showKeybinds"]     = { category = "Action Bars",        label = "Show Keybinds" },
    ["actionBars.global.showMacroNames"]   = { category = "Action Bars",        label = "Show Macro Names" },
    ["actionBars.global.showCounts"]       = { category = "Action Bars",        label = "Show Stack Counts" },
    ["actionBars.global.showBorders"]      = { category = "Action Bars",        label = "Show Borders" },
    ["actionBars.global.showTooltips"]     = { category = "Action Bars",        label = "Show Tooltips" },
    ["actionBars.global.hideEmptySlots"]   = { category = "Action Bars",        label = "Hide Empty Slots" },
    ["actionBars.global.lockButtons"]      = { category = "Action Bars",        label = "Lock Buttons" },
    ["actionBars.global.rangeIndicator"]   = { category = "Action Bars",        label = "Range Indicator" },
    ["actionBars.global.usabilityIndicator"] = { category = "Action Bars",      label = "Usability Indicator" },
    ["actionBars.global.keybindFontSize"]  = { category = "Action Bars",        label = "Keybind Font Size" },
    ["actionBars.global.iconZoom"]         = { category = "Action Bars",        label = "Icon Zoom" },

    ---------------------------------------------------------------------------
    -- Popup Blocker
    ---------------------------------------------------------------------------
    ["general.popupBlocker.enabled"]       = { category = "Popup Blocker",      label = "Enable Popup Blocker" },

    ---------------------------------------------------------------------------
    -- Consumable Check
    ---------------------------------------------------------------------------
    ["general.consumableCheckEnabled"]     = { category = "Consumables",        label = "Enable Consumable Check" },

    ---------------------------------------------------------------------------
    -- Key Tracker
    ---------------------------------------------------------------------------
    ["general.keyTrackerEnabled"]          = { category = "Key Tracker",        label = "Enable Key Tracker" },
    ["general.mplusTeleportEnabled"]       = { category = "Key Tracker",        label = "M+ Teleport" },
}

---------------------------------------------------------------------------
-- INTERNAL HELPERS
---------------------------------------------------------------------------

-- Walk a dotted path on a table, returning (parentTable, finalKey)
local function WalkPath(tbl, dottedKey)
    local current = tbl
    local segments = {}
    for segment in dottedKey:gmatch("[^.]+") do
        segments[#segments + 1] = segment
    end
    for i = 1, #segments - 1 do
        current = current and current[segments[i]]
    end
    return current, segments[#segments]
end

local function GetDB()
    local core = Helpers and Helpers.GetCore and Helpers.GetCore()
    return core and core.db
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

--- Get the effective value for a setting. Returns (value, isGlobal).
--- If the setting is globally opted-in, returns the global value.
--- Otherwise falls back to the profile value.
function GlobalPrefs:Get(dottedKey)
    local db = GetDB()
    if not db then return nil, false end

    local prefs = db.global and db.global.preferences
    if prefs and prefs[dottedKey] ~= nil then
        return prefs[dottedKey], true
    end

    -- Fall back to profile
    local parent, key = WalkPath(db.profile, dottedKey)
    if parent then
        return parent[key], false
    end
    return nil, false
end

--- Set a value in the global preferences store.
function GlobalPrefs:Set(dottedKey, value)
    local db = GetDB()
    if not db or not db.global then return end
    db.global.preferences = db.global.preferences or {}
    db.global.preferences[dottedKey] = value
end

--- Remove a setting from global preferences (revert to per-profile).
function GlobalPrefs:Remove(dottedKey)
    local db = GetDB()
    if not db or not db.global or not db.global.preferences then return end
    db.global.preferences[dottedKey] = nil
end

--- Check if a setting is currently opted-in as global.
function GlobalPrefs:IsGlobal(dottedKey)
    local db = GetDB()
    return db and db.global and db.global.preferences and db.global.preferences[dottedKey] ~= nil
end

--- Promote multiple settings to global in bulk (copies current profile values).
function GlobalPrefs:MakeBulkGlobal(dottedKeys)
    local db = GetDB()
    if not db or not db.global then return end
    db.global.preferences = db.global.preferences or {}
    for _, dottedKey in ipairs(dottedKeys) do
        local parent, key = WalkPath(db.profile, dottedKey)
        if parent and parent[key] ~= nil then
            db.global.preferences[dottedKey] = parent[key]
        end
    end
end

--- Remove multiple settings from global preferences in bulk.
function GlobalPrefs:RemoveBulkGlobal(dottedKeys)
    local db = GetDB()
    if not db or not db.global or not db.global.preferences then return end
    for _, dottedKey in ipairs(dottedKeys) do
        db.global.preferences[dottedKey] = nil
    end
end

--- Iterator over all currently global preferences.
function GlobalPrefs:GetAllGlobal()
    local db = GetDB()
    local prefs = db and db.global and db.global.preferences
    if not prefs then return function() end end
    return pairs(prefs)
end

--- Returns (categoriesTable, orderedCategoryNames) for the bulk management UI.
--- Each category entry is a sorted list of { key, label, isGlobal }.
function GlobalPrefs:GetEligibleByCategory()
    local categories = {}
    local categoryOrder = {}
    for dottedKey, meta in pairs(self.ELIGIBLE) do
        local cat = meta.category
        if not categories[cat] then
            categories[cat] = {}
            categoryOrder[#categoryOrder + 1] = cat
        end
        categories[cat][#categories[cat] + 1] = {
            key = dottedKey,
            label = meta.label,
            isGlobal = self:IsGlobal(dottedKey),
        }
    end
    table.sort(categoryOrder)
    for _, cat in pairs(categories) do
        table.sort(cat, function(a, b) return a.label < b.label end)
    end
    return categories, categoryOrder
end
