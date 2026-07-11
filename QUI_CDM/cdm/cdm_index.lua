local _, ns = ...

---------------------------------------------------------------------------
-- CDM Index — single source of truth for CDM spell-ID alias walking,
-- base-ID normalization, cross-event invalidation, and the
-- RefreshLayout silent-mutation gap.
--
-- Loads early in cdm.xml so every other CDM file can depend on it.
--
-- API:
--   ns.CDMIndex.ForEachCooldownInfoID(info, callback)
--     Walks overrideTooltipSpellID, overrideSpellID, spellID, then every
--     linkedSpellIDs[i]. Single canonical alias walk; every consumer
--     uses this so no field can be silently missed.
--
--   ns.CDMIndex.IsUsableID(id) -> bool
--     Returns false for nil, non-number, <= 0, or secret-tagged IDs.
--     Used as a key-validity gate at index-build time only — never on
--     a per-tick combat path.
--
--   ns.CDMIndex.ToBaseSpellID(id) -> baseID or nil
--     source-facade base spell lookup with raw-id fallback. Returns
--     nil if the input is not usable.
--
--   ns.CDMIndex.Get(spellID) -> entry or nil
--     entry = { cooldownID, category, primarySpellID, aliases = {} }.
--     Every aliased spellID for one cooldown returns the SAME entry
--     table (identity equality), so callers can compare entries with ==.
--
--   ns.CDMIndex.Version() -> number
--     Monotonic counter; increments on every wipe so consumers can
--     detect staleness.
--
--   ns.CDMIndex.Subscribe(name, callback, priority)
--   ns.CDMIndex.Unsubscribe(name)
--     Single broker for COOLDOWN_VIEWER_TABLE_HOTFIXED,
--     COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED, COOLDOWN_VIEWER_DATA_LOADED,
--     and CooldownViewerSettings:RefreshLayout (no public event).
--     Subscribers fire in ascending priority order on each invalidation.
---------------------------------------------------------------------------

local CDMIndex = {}
ns.CDMIndex = CDMIndex

local ipairs = ipairs
local pairs = pairs
local type = type
local wipe = wipe

-- issecretvalue is global on 12.0+. Stub when running outside WoW (the
-- profile test harness loads no CDM code, so this is defensive only).
local issecretvalue = issecretvalue or function() return false end

local function GetCooldownViewerAPI()
    return _G.C_CooldownViewer
end

local function GetSources()
    return ns.CDMSources
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function CDMIndex.IsUsableID(id)
    if id == nil or type(id) ~= "number" then return false end
    if issecretvalue(id) then return false end
    return id > 0
end

function CDMIndex.ToBaseSpellID(id)
    if not CDMIndex.IsUsableID(id) then return nil end
    local Sources = GetSources()
    local base = Sources and Sources.QueryBaseSpell and Sources.QueryBaseSpell(id)
    if not CDMIndex.IsUsableID(base) then return id end
    return base
end

-- Centralized alias walk. Order matters for some callers (icon factory
-- probes overrideTooltipSpellID first as the "preferred display" ID);
-- preserve override -> tooltip -> spell -> linked.
function CDMIndex.ForEachCooldownInfoID(info, callback)
    if not info then return end
    callback(info.overrideTooltipSpellID)
    callback(info.overrideSpellID)
    callback(info.spellID)
    if info.linkedSpellIDs then
        for _, id in ipairs(info.linkedSpellIDs) do
            callback(id)
        end
    end
end

local function SelectPrimaryCooldownInfoID(info)
    if not info then return nil end
    if CDMIndex.IsUsableID(info.overrideTooltipSpellID) then
        return info.overrideTooltipSpellID
    end
    if CDMIndex.IsUsableID(info.overrideSpellID) then
        return info.overrideSpellID
    end
    if CDMIndex.IsUsableID(info.spellID) then
        return info.spellID
    end
    return nil
end

---------------------------------------------------------------------------
-- Index — populated lazily and on broker invalidation
---------------------------------------------------------------------------

local _spellIndex = {}      -- baseID -> entry (entry shared across aliases)
local _equipSlotIndex = {}  -- equipSlot luaIndex -> entry (item-only cooldowns)
local _categoryIndex = {}   -- spellCategoryID -> entry (consumable cooldowns)
local _version = 0
local _built = false
local _orderedSpellMap = nil
local _orderedEquipSlotMap = nil
local _orderedCategoryMap = nil
local _orderedSpellMapByCategory = nil
local _orderedEquipSlotMapByCategory = nil
local _orderedCategoryMapByCategory = nil
local _orderedMapsVersion = -1

function CDMIndex.Version() return _version end

local CATEGORIES_FOR_INDEX = nil  -- populated lazily once Enum is available

local function GetIndexCategories()
    if CATEGORIES_FOR_INDEX then return CATEGORIES_FOR_INDEX end
    if not (Enum and Enum.CooldownViewerCategory) then return nil end
    local E = Enum.CooldownViewerCategory
    -- Tracked first so they claim canonical entries before Essential/Utility
    -- duplicates: the same spell can appear in Essential as a cooldown and
    -- in TrackedBuff as its buff. The buff entry is the one consumers
    -- usually want when they ask "what does this aura belong to".
    CATEGORIES_FOR_INDEX = {
        E.TrackedBuff,
        E.TrackedBar,
        E.Essential,
        E.Utility,
        -- Equipped-item / spec-agnostic categories (12.x). nil on older clients;
        -- the `if cat ~= nil` filter in Rebuild() drops any that are absent.
        E.SpecAgnosticTracked,
        E.SpecAgnosticEssential,
        E.EquipSlotTracked,
        E.EquipSlotEssential,
        E.HiddenSpell,
        E.HiddenAura,
    }
    return CATEGORIES_FOR_INDEX
end

function CDMIndex.Rebuild()
    wipe(_spellIndex)
    wipe(_equipSlotIndex)
    wipe(_categoryIndex)
    _built = true
    _version = _version + 1

    local api = GetCooldownViewerAPI()
    if not (api
            and api.GetCooldownViewerCategorySet
            and api.GetCooldownViewerCooldownInfo) then
        return
    end

    local cats = GetIndexCategories()
    if not cats then return end

    local seenCooldown = {}
    for _, cat in ipairs(cats) do
        if cat ~= nil then
            local ids = api.GetCooldownViewerCategorySet(cat, true)
            if ids then
                for _, cdID in ipairs(ids) do
                    if not seenCooldown[cdID] then
                        seenCooldown[cdID] = true
                        local info = api.GetCooldownViewerCooldownInfo(cdID)
                        if info then
                            local primarySid = SelectPrimaryCooldownInfoID(info)
                            local primaryBase = CDMIndex.ToBaseSpellID(primarySid)
                            local equipSlot = info.equipSlot
                            local spellCategoryID = info.spellCategoryID
                            local hasEquipSlot = type(equipSlot) == "number"
                                and not issecretvalue(equipSlot)
                            local hasCategory = type(spellCategoryID) == "number"
                                and not issecretvalue(spellCategoryID)
                            if primaryBase or hasEquipSlot or hasCategory then
                                local entry = {
                                    cooldownID     = cdID,
                                    category       = cat,
                                    primarySpellID = primaryBase,  -- nil for pure item cooldowns
                                    aliases        = {},
                                }
                                if primaryBase then
                                    local seenAlias = {}
                                    CDMIndex.ForEachCooldownInfoID(info, function(id)
                                        local b = CDMIndex.ToBaseSpellID(id)
                                        if b and not seenAlias[b] then
                                            seenAlias[b] = true
                                            entry.aliases[#entry.aliases + 1] = b
                                            if not _spellIndex[b] then
                                                _spellIndex[b] = entry
                                            end
                                        end
                                    end)
                                end
                                if hasEquipSlot and _equipSlotIndex[equipSlot] == nil then
                                    _equipSlotIndex[equipSlot] = entry
                                end
                                if hasCategory and _categoryIndex[spellCategoryID] == nil then
                                    _categoryIndex[spellCategoryID] = entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function CDMIndex.Get(spellID)
    if not _built then CDMIndex.Rebuild() end
    local base = CDMIndex.ToBaseSpellID(spellID)
    if not base then return nil end
    return _spellIndex[base]
end

function CDMIndex.GetByEquipSlot(equipSlot)
    if not _built then CDMIndex.Rebuild() end
    if type(equipSlot) ~= "number" or issecretvalue(equipSlot) then return nil end
    return _equipSlotIndex[equipSlot]
end

function CDMIndex.GetByCategory(spellCategoryID)
    if not _built then CDMIndex.Rebuild() end
    if type(spellCategoryID) ~= "number" or issecretvalue(spellCategoryID) then return nil end
    return _categoryIndex[spellCategoryID]
end

---------------------------------------------------------------------------
-- Broker — subscribers fire in ascending priority on every invalidation
---------------------------------------------------------------------------

-- Subscribers: { name = string, cb = function, priority = number }
-- Sorted on every insert; sweep on every notify.
local _subs = {}

local function SortSubs()
    table.sort(_subs, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.name < b.name
    end)
end

function CDMIndex.Subscribe(name, callback, priority)
    if type(name) ~= "string" or type(callback) ~= "function" then return end
    -- Replace if same name already subscribed (idempotent during reload-paths).
    for i = 1, #_subs do
        if _subs[i].name == name then
            _subs[i].cb = callback
            _subs[i].priority = priority or 100
            SortSubs()
            return
        end
    end
    _subs[#_subs + 1] = { name = name, cb = callback, priority = priority or 100 }
    SortSubs()
end

function CDMIndex.Unsubscribe(name)
    for i = #_subs, 1, -1 do
        if _subs[i].name == name then
            table.remove(_subs, i)
            return
        end
    end
end

-- Reason is a short string ("hotfix", "override", "data_loaded",
-- "refresh_layout", "manual"). Subscribers may inspect it.
local function Notify(reason, ...)
    -- Wipe BEFORE notifying so subscribers' first lookup repopulates
    -- with a coherent index. _built=false forces lazy rebuild on next Get.
    _built = false
    _version = _version + 1
    for i = 1, #_subs do
        local s = _subs[i]
        local ok, err = pcall(s.cb, reason, ...)
        if not ok and ns.QUICore and ns.QUICore.DebugPrint then
            ns.QUICore.DebugPrint("CDMIndex broker subscriber '" .. s.name
                .. "' raised: " .. tostring(err))
        end
    end
end

CDMIndex.Notify = Notify

---------------------------------------------------------------------------
-- Event sources — fan out to the broker
---------------------------------------------------------------------------

local _eventFrame = CreateFrame("Frame")
_eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
_eventFrame:RegisterEvent("COOLDOWN_VIEWER_TABLE_HOTFIXED")
_eventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
_eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "COOLDOWN_VIEWER_DATA_LOADED" then
        Notify("data_loaded")
    elseif event == "COOLDOWN_VIEWER_TABLE_HOTFIXED" then
        Notify("hotfix")
    elseif event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
        -- arg1, arg2 = baseSpellID, overrideSpellID
        Notify("override", arg1, arg2)
    end
end)

---------------------------------------------------------------------------
-- RefreshLayout silent-mutation hook
---------------------------------------------------------------------------
-- CDM's settings UI fires no public event for category drag-drop, and
-- programmatic SetCooldownToCategory calls are similarly silent. Both
-- routes go through CooldownViewerSettings:RefreshLayout. Hooking it
-- closes the gap so the broker invalidates on those mutations the same
-- as it does for hotfix / override events.
-- securecall the hook body: RefreshLayout fires mid settings-mutation (drag-drop /
-- SetCooldownToCategory), inside the same SettingsLayoutManager cascade that calls the
-- protected SetHiddenGroupBuffs. A bare post-hook leaks this addon's taint into
-- Blizzard's continuation -> secret-value throw + ADDON_ACTION_BLOCKED. Isolate it.
local _securecall = securecallfunction or function(fn, ...) return fn(...) end
local function _OnSettingsRefreshLayout() Notify("refresh_layout") end

local _refreshLayoutHooked = false
local function InstallRefreshLayoutHook()
    if _refreshLayoutHooked then return end
    if not (CooldownViewerSettings and CooldownViewerSettings.RefreshLayout) then return end
    local ok = pcall(hooksecurefunc, CooldownViewerSettings, "RefreshLayout", function(...)
        _securecall(_OnSettingsRefreshLayout, ...)
    end)
    if ok then _refreshLayoutHooked = true end
end

InstallRefreshLayoutHook()
local _hookFrame = CreateFrame("Frame")
_hookFrame:RegisterEvent("PLAYER_LOGIN")
_hookFrame:SetScript("OnEvent", function(self)
    InstallRefreshLayoutHook()
    if _refreshLayoutHooked then
        self:UnregisterAllEvents()
    end
end)

---------------------------------------------------------------------------
-- Ordered map — what CDM is currently RENDERING (per the user's ordering
-- and visibility), as distinct from CDMIndex.Get above which answers
-- "what does CDM KNOW about" (incl. HiddenSpell / HiddenAura entries
-- the user has hidden).
--
-- Use ordered for icon-binding and overlay decisions ("is this cooldown
-- visible to the user right now?"). Use the index for spell-metadata
-- and override resolution ("does this cooldown exist at all?").
--
-- Returned spell map: baseID -> { cooldownID, category }. Item maps key by
-- equipSlot / spellCategoryID. Built fresh after each broker invalidation.
---------------------------------------------------------------------------
local function BuildOrderedMaps()
    if _orderedSpellMap and _orderedMapsVersion == _version then
        return
    end

    -- Cold-boot taint gate: consume Blizzard's settings data provider only
    -- AFTER one of its own secure consumers has built the lazy displayData
    -- cache. Every provider getter routes through CheckBuildDisplayData; if
    -- QUI is the first caller after COOLDOWN_VIEWER_DATA_LOADED (the viewers
    -- are still hidden on a cold login, so none of them is listening), QUI
    -- execution builds the shared cooldownInfo/order tables -- QUI-tainted --
    -- and the viewer's later secure RefreshData/GetCooldownIDs read poisons
    -- the whole item mint: aura reads go secret, the DisallowTaintedAccess
    -- aura map rejects registration, and every buff item is born inactive
    -- until /reload (a SHOWN viewer rebuilds the cache securely first, which
    -- is why /reload always healed). Read the memo fields RAW -- never via
    -- the getters, which build -- and bail WITHOUT latching the version so
    -- the next call retries once a shown viewer has built the cache.
    if CooldownViewerSettings and CooldownViewerSettings.GetDataProvider then
        local provider = CooldownViewerSettings:GetDataProvider()
        if provider and (provider.displayDataDirty or provider.displayData == nil) then
            if not _orderedSpellMap then
                _orderedSpellMap, _orderedEquipSlotMap, _orderedCategoryMap = {}, {}, {}
                _orderedSpellMapByCategory, _orderedEquipSlotMapByCategory, _orderedCategoryMapByCategory =
                    {}, {}, {}
            end
            return
        end
    end

    local spellMap, equipSlotMap, categoryMap = {}, {}, {}
    local spellMapByCategory, equipSlotMapByCategory, categoryMapByCategory = {}, {}, {}
    _orderedSpellMap = spellMap
    _orderedEquipSlotMap = equipSlotMap
    _orderedCategoryMap = categoryMap
    _orderedSpellMapByCategory = spellMapByCategory
    _orderedEquipSlotMapByCategory = equipSlotMapByCategory
    _orderedCategoryMapByCategory = categoryMapByCategory
    _orderedMapsVersion = _version

    if not (CooldownViewerSettings and CooldownViewerSettings.GetDataProvider) then
        return
    end
    local api = GetCooldownViewerAPI()
    if not (api and api.GetCooldownViewerCooldownInfo) then
        return
    end
    local provider = CooldownViewerSettings:GetDataProvider()
    if not (provider and provider.GetOrderedCooldownIDsForCategory) then
        return
    end
    if not (Enum and Enum.CooldownViewerCategory) then return end

    local visibleCats = {
        Enum.CooldownViewerCategory.TrackedBuff,
        Enum.CooldownViewerCategory.TrackedBar,
        Enum.CooldownViewerCategory.Essential,
        Enum.CooldownViewerCategory.Utility,
    }
    for _, cat in ipairs(visibleCats) do
        if cat ~= nil then
            local catSpellMap = {}
            local catEquipSlotMap = {}
            local catCategoryMap = {}
            spellMapByCategory[cat] = catSpellMap
            equipSlotMapByCategory[cat] = catEquipSlotMap
            categoryMapByCategory[cat] = catCategoryMap
            local ids = provider.GetOrderedCooldownIDsForCategory(provider, cat, true)
            if ids then
                for _, cdID in ipairs(ids) do
                    local info = api.GetCooldownViewerCooldownInfo(cdID)
                    if info then
                        local entry = { cooldownID = cdID, category = cat }
                        local equipSlot = info.equipSlot
                        if type(equipSlot) == "number"
                            and not issecretvalue(equipSlot)
                            and not equipSlotMap[equipSlot] then
                            equipSlotMap[equipSlot] = entry
                        end
                        if type(equipSlot) == "number"
                            and not issecretvalue(equipSlot)
                            and not catEquipSlotMap[equipSlot] then
                            catEquipSlotMap[equipSlot] = entry
                        end
                        local spellCategoryID = info.spellCategoryID
                        if type(spellCategoryID) == "number"
                            and not issecretvalue(spellCategoryID)
                            and not categoryMap[spellCategoryID] then
                            categoryMap[spellCategoryID] = entry
                        end
                        if type(spellCategoryID) == "number"
                            and not issecretvalue(spellCategoryID)
                            and not catCategoryMap[spellCategoryID] then
                            catCategoryMap[spellCategoryID] = entry
                        end
                        CDMIndex.ForEachCooldownInfoID(info, function(id)
                            local b = CDMIndex.ToBaseSpellID(id)
                            if b and not spellMap[b] then
                                spellMap[b] = entry
                            end
                            if b and not catSpellMap[b] then
                                catSpellMap[b] = entry
                            end
                        end)
                    end
                end
            end
        end
    end
end

function CDMIndex.GetOrderedSpellMap()
    BuildOrderedMaps()
    return _orderedSpellMap
end

-- Convenience: return the ordered entry for a single spellID, or nil.
function CDMIndex.GetOrdered(spellID)
    local base = CDMIndex.ToBaseSpellID(spellID)
    if not base then return nil end
    return CDMIndex.GetOrderedSpellMap()[base]
end

local function GetCategoryForContainerKey(containerKey)
    if not (Enum and Enum.CooldownViewerCategory) then return nil end
    local E = Enum.CooldownViewerCategory
    if containerKey == "essential" then return E.Essential end
    if containerKey == "utility" then return E.Utility end
    if containerKey == "buff" then return E.TrackedBuff end
    if containerKey == "trackedBar" then return E.TrackedBar end
    return nil
end

function CDMIndex.GetOrderedForContainer(containerKey, spellID)
    local cat = GetCategoryForContainerKey(containerKey)
    if cat == nil then return nil end
    local base = CDMIndex.ToBaseSpellID(spellID)
    if not base then return nil end
    BuildOrderedMaps()
    local byCategory = _orderedSpellMapByCategory and _orderedSpellMapByCategory[cat]
    return byCategory and byCategory[base] or nil
end

-- Cheap "is this cooldown actually being rendered to the user right
-- now?" check used by overlay/binding decisions that should not act on
-- hidden cooldowns.
function CDMIndex.IsRendered(spellID)
    return CDMIndex.GetOrdered(spellID) ~= nil
end

function CDMIndex.GetOrderedByEquipSlot(equipSlot)
    if type(equipSlot) ~= "number" or issecretvalue(equipSlot) then return nil end
    BuildOrderedMaps()
    return _orderedEquipSlotMap[equipSlot]
end

function CDMIndex.GetOrderedByCategory(spellCategoryID)
    if type(spellCategoryID) ~= "number" or issecretvalue(spellCategoryID) then return nil end
    BuildOrderedMaps()
    return _orderedCategoryMap[spellCategoryID]
end

function CDMIndex.GetOrderedByEquipSlotForContainer(containerKey, equipSlot)
    if type(equipSlot) ~= "number" or issecretvalue(equipSlot) then return nil end
    local cat = GetCategoryForContainerKey(containerKey)
    if cat == nil then return nil end
    BuildOrderedMaps()
    local byCategory = _orderedEquipSlotMapByCategory and _orderedEquipSlotMapByCategory[cat]
    return byCategory and byCategory[equipSlot] or nil
end

function CDMIndex.GetOrderedByCategoryForContainer(containerKey, spellCategoryID)
    if type(spellCategoryID) ~= "number" or issecretvalue(spellCategoryID) then return nil end
    local cat = GetCategoryForContainerKey(containerKey)
    if cat == nil then return nil end
    BuildOrderedMaps()
    local byCategory = _orderedCategoryMapByCategory and _orderedCategoryMapByCategory[cat]
    return byCategory and byCategory[spellCategoryID] or nil
end
