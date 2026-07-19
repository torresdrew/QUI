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
local _version = 0
local _built = false
local _orderedSpellMap = nil
local _orderedSpellMapVersion = -1

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
        E.HiddenSpell,
        E.HiddenAura,
    }
    return CATEGORIES_FOR_INDEX
end

function CDMIndex.Rebuild()
    wipe(_spellIndex)
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
                            if primaryBase then
                                local entry = {
                                    cooldownID     = cdID,
                                    category       = cat,
                                    primarySpellID = primaryBase,
                                    aliases        = {},
                                }
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
local _refreshLayoutHooked = false
local function InstallRefreshLayoutHook()
    if _refreshLayoutHooked then return end
    if not (CooldownViewerSettings and CooldownViewerSettings.RefreshLayout) then return end
    local ok = pcall(hooksecurefunc, CooldownViewerSettings, "RefreshLayout", function()
        Notify("refresh_layout")
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
-- TEMPORARY DIAGNOSTIC — Brewmaster Empty Barrel proc probe.
-- Ships in the beta so an affected player can diagnose without running
-- macros: every relevant line is printed to chat with a [QUI EB] prefix
-- for a screenshot. Remove once the Empty Barrel art regression is closed.
--
-- What it answers (the one unverified assumption left after three fix
-- rounds): does the game expose the Empty Barrel override to addons at
-- proc time — via COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED and/or the
-- CooldownViewerCooldown info fields — and does QUI's mirror capture it?
-- Brewmaster-gated (spec 268); zero output on other specs.
---------------------------------------------------------------------------
do
    local KEG_SMASH = 121253
    local PROBE_CATEGORY_NAMES = {
        [0] = "essential", [1] = "utility", [2] = "buff", [3] = "trackedBar",
    }

    local function FmtID(v)
        -- Probe BEFORE any truth-test/comparison: secret values throw on both.
        if issecretvalue and issecretvalue(v) then return "secret" end
        if v == nil then return "nil" end
        return tostring(v)
    end

    local function ProbePrint(...)
        print("|cff30d1ff[QUI EB]|r", ...)
    end

    local function IsBrewmaster()
        if not (GetSpecialization and GetSpecializationInfo) then return false end
        local idx = GetSpecialization()
        if not idx then return false end
        local specID = GetSpecializationInfo(idx)
        return specID == 268
    end

    -- Delta scan across EVERY cooldown-viewer entry (all four categories):
    -- signature = spellID/override/overrideTooltip, plus — for the cooldown
    -- categories — the Blizzard child frame's LIVE icon texture (ground
    -- truth: does Blizzard's own child swap art on a proc even when the
    -- info API stays silent?). Round-1 probe only watched entries whose
    -- spellID==121253 and saw nothing move, so round 2 watches everything
    -- and prints only what CHANGES between scans.
    local _baseline = {}
    local _baselineBuilt = false

    local function EntrySig(cat, cdID, info)
        local sig = FmtID(info.spellID) .. "/" .. FmtID(info.overrideSpellID)
            .. "/" .. FmtID(info.overrideTooltipSpellID)
        if cat <= 1 and ns.CDMBlizzMirror
            and ns.CDMBlizzMirror.GetCooldownMethodTestPayload then
            local payload = ns.CDMBlizzMirror.GetCooldownMethodTestPayload(
                cdID, PROBE_CATEGORY_NAMES[cat])
            if payload then
                sig = sig .. "/tex=" .. FmtID(payload.iconTexture)
            end
        end
        return sig
    end

    local function ProbeScan(reason)
        if not (C_CooldownViewer
            and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
            return
        end
        local seen = {}
        for cat = 0, 3 do
            local set = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
            if type(set) == "table" then
                for i = 1, #set do
                    local cdID = set[i]
                    if not (issecretvalue and issecretvalue(cdID)) then
                        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                        if info then
                            local key = PROBE_CATEGORY_NAMES[cat] .. ":" .. FmtID(cdID)
                            local sig = EntrySig(cat, cdID, info)
                            seen[key] = true
                            local prev = _baseline[key]
                            if prev ~= sig then
                                _baseline[key] = sig
                                if _baselineBuilt then
                                    ProbePrint(("%s CHANGE %s now [%s] was [%s]"):format(
                                        reason, key, sig, prev or "absent"))
                                else
                                    local sid = info.spellID
                                    if not (issecretvalue and issecretvalue(sid))
                                        and sid == KEG_SMASH then
                                        ProbePrint(("baseline %s [%s]"):format(key, sig))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if _baselineBuilt then
            local removed
            for key in pairs(_baseline) do
                if not seen[key] then
                    removed = removed or {}
                    removed[#removed + 1] = key
                end
            end
            if removed then
                for i = 1, #removed do
                    local key = removed[i]
                    ProbePrint(("%s REMOVED %s was [%s]"):format(
                        reason, key, _baseline[key]))
                    _baseline[key] = nil
                end
            end
        else
            _baselineBuilt = true
        end
    end

    local function ScanSoon(reason, delay)
        if C_Timer and C_Timer.After then
            C_Timer.After(delay, function()
                ProbeScan(reason)
            end)
        else
            ProbeScan(reason)
        end
    end

    local _probeFrame = CreateFrame("Frame")
    _probeFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    _probeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    _probeFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    _probeFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
    _probeFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
    if _probeFrame.RegisterUnitEvent then
        _probeFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    else
        _probeFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end
    local _announced = false
    _probeFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
        if not IsBrewmaster() then return end
        if event == "PLAYER_ENTERING_WORLD" then
            if not _announced then
                _announced = true
                ProbePrint("probe v2 active — test several Empty Barrel procs, screenshot ALL [QUI EB] lines")
            end
            ProbeScan("login")
            return
        end
        if event == "PLAYER_REGEN_DISABLED" then
            -- Refresh the baseline entering combat so proc deltas diff
            -- against the immediate pre-pull state.
            ProbeScan("combat-start")
            return
        end
        if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
            -- Payload: baseSpellID, overrideSpellID (nil = override removed).
            ProbePrint("override event base=" .. FmtID(arg1) .. " override=" .. FmtID(arg2))
            ScanSoon("override-event", 0.1)
            return
        end
        if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW"
            or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
            -- The action-bar proc-glow edge. Fires for procs the cooldown
            -- info API may never report; the spellID names the proc spell.
            ProbePrint(event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW"
                and ("overlay SHOW spellID=" .. FmtID(arg1))
                or ("overlay HIDE spellID=" .. FmtID(arg1)))
            ScanSoon("overlay", 0.1)
            return
        end
        -- UNIT_SPELLCAST_SUCCEEDED player: arg3 = spellID. The proc lands
        -- with/just after a Keg Smash cast — scan twice to catch late flips.
        local castSid = arg3
        if issecretvalue and issecretvalue(castSid) then return end
        if castSid == KEG_SMASH then
            ScanSoon("post-cast", 0.25)
            ScanSoon("post-cast+1s", 1.0)
        end
    end)
end

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
-- Returned map: baseID -> { cooldownID, category }. Built fresh on each
-- call — callers can rebuild after a "refresh_layout" notification.
---------------------------------------------------------------------------
function CDMIndex.GetOrderedSpellMap()
    if _orderedSpellMap and _orderedSpellMapVersion == _version then
        return _orderedSpellMap
    end

    local map = {}
    _orderedSpellMap = map
    _orderedSpellMapVersion = _version

    if not (CooldownViewerSettings and CooldownViewerSettings.GetDataProvider) then
        return map
    end
    local api = GetCooldownViewerAPI()
    if not (api and api.GetCooldownViewerCooldownInfo) then
        return map
    end
    local provider = CooldownViewerSettings:GetDataProvider()
    if not (provider and provider.GetOrderedCooldownIDsForCategory) then
        return map
    end
    if not (Enum and Enum.CooldownViewerCategory) then return map end

    local visibleCats = {
        Enum.CooldownViewerCategory.TrackedBuff,
        Enum.CooldownViewerCategory.TrackedBar,
        Enum.CooldownViewerCategory.Essential,
        Enum.CooldownViewerCategory.Utility,
    }
    for _, cat in ipairs(visibleCats) do
        if cat ~= nil then
            local ids = provider.GetOrderedCooldownIDsForCategory(provider, cat, true)
            if ids then
                for _, cdID in ipairs(ids) do
                    local info = api.GetCooldownViewerCooldownInfo(cdID)
                    if info then
                        local entry = { cooldownID = cdID, category = cat }
                        CDMIndex.ForEachCooldownInfoID(info, function(id)
                            local b = CDMIndex.ToBaseSpellID(id)
                            if b and not map[b] then
                                map[b] = entry
                            end
                        end)
                    end
                end
            end
        end
    end
    return map
end

-- Convenience: return the ordered entry for a single spellID, or nil.
function CDMIndex.GetOrdered(spellID)
    local base = CDMIndex.ToBaseSpellID(spellID)
    if not base then return nil end
    return CDMIndex.GetOrderedSpellMap()[base]
end

-- Cheap "is this cooldown actually being rendered to the user right
-- now?" check used by overlay/binding decisions that should not act on
-- hidden cooldowns.
function CDMIndex.IsRendered(spellID)
    return CDMIndex.GetOrdered(spellID) ~= nil
end
