--[[
    QUI Options V2 — Auras hub, Encounters sub-page.

    A browser (not an editor): pick a surface, pick an instance (the raid/dungeon
    the player is in, resolved through the Encounter Journal, plus expansion raids
    via ns.QUI_EncounterCatalog.ExpansionRaids and this season's Mythic+ pool via
    SeasonDungeons), pick a boss, and read that boss's Journal-documented
    abilities as a reference catalog. The one WRITE control is the per-surface
    boss-debuff gate strip.

    12.1 IDENTITY GATING is why there are no per-ability toggles: the engine
    skips exact spell-ID candidate filters (include/excludeSpellIDs) for
    HARMFUL auras on units the player CAN assist, and for HELPFUL auras on
    units the player CANNOT (Blizzard_AuraContainer/Blizzard_AuraContainerUtil
    .lua CanApplyIdentityCandidateFilters — deliberately, so encounter debuffs
    can't drive bespoke "Move now!" displays). Encounter abilities are auras
    the boss applies TO PLAYERS (the catalog is gated on the data-mined
    player-facing set, core/encounter_aura_data.lua), so:
      * on friendly frames (party/raid/player) — where those debuffs DO
        appear — exact-ID filters are skipped by the engine;
      * on hostile frames (target/focus/boss) the debuffs don't exist at all
        (they are on the players, never on the enemy).
    There is NO surface where a per-ability encounter pick can legally render,
    which is why this page's earlier per-ability "destinations" were removed.
    (UnitCanAssist is also evaluated LIVE by the engine — a friendly target
    or focus flips that frame into the skipped branch — so hostility can
    never be assumed per surface either.)

    What DOES work are the non-identity gates (isBossAura / isBossOrRoleAura),
    so each surface gets ONE dedicated boss-debuff strip with an
    all/role-relevant mode. It lives in the surface's spec-ACTIVE bucket, only
    shows while boss auras are up (so it appears on pull and self-hides after
    the fight), and its placement/sizing is edited in the element editor.
    (The per-encounter cascade in core/aura_context.lua still exists for the
    advanced case where a strip must behave DIFFERENTLY per boss -- a filter
    RESTRICTION, not an addition -- but this browser does not write those buckets.)
]]

local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local Settings = ns.Settings
local Registry = Settings and Settings.Registry
local Schema = Settings and Settings.Schema
if not Registry or type(Registry.RegisterFeature) ~= "function"
    or not Schema or type(Schema.Feature) ~= "function"
    or type(Schema.Section) ~= "function" then
    return
end

local E = ns.AuraElements
local EC = ns.QUI_EncounterCatalog
-- E (core aura model) is a hard dependency for the write path
-- (NewFilterStripElement for the boss-debuff gate strip); bail cleanly if
-- the core module somehow isn't loaded yet.
if not E then return end

local FALLBACK_ICON = 134400 -- INV_Misc_QuestionMark, matches aura_elements_editor.lua's fallback.

-- Ordered so the chip text reads Tank, DPS, Healer regardless of table
-- iteration order (tags is a set: {tank=true, dps=true, healer=true}).
local ROLE_TAG_ORDER = {
    { key = "tank",   label = "Tank" },
    { key = "dps",    label = "DPS" },
    { key = "healer", label = "Healer" },
}

local function RoleTagsText(tags)
    if type(tags) ~= "table" then return "" end
    local parts = {}
    for _, role in ipairs(ROLE_TAG_ORDER) do
        if tags[role.key] then
            parts[#parts + 1] = ns.L[role.label]
        end
    end
    return table.concat(parts, ", ")
end

-- Live-writes only: not exported from core/settings/util.lua (Util only has
-- ShallowCopy) -- same small local the wizard page uses.
local function ensure(t, k)
    t[k] = t[k] or {}
    return t[k]
end

-- Surfaces the boss-debuff gate strip can be configured on. Each resolves the
-- CustomAuraContainer aura store at db[root][unit].auras (group frames and
-- unit frames share the core/aura_elements bucket model). Only frames that
-- can actually CARRY an encounter debuff are listed — the abilities land on
-- players, never on the enemy, so target/focus/boss are deliberately absent
-- (see file header). Action-bar buff borders are player-cast-buff surfaces,
-- so they are intentionally absent too.
local function RefreshGF() if _G.QUI_RefreshGroupFrames then _G.QUI_RefreshGroupFrames() end end
local function RefreshUF() if _G.QUI_RefreshUnitFrames then _G.QUI_RefreshUnitFrames() end end
local SURFACES = {
    { value = "party",  text = ns.L["Party Frames"],  root = "quiGroupFrames", unit = "party",  refresh = RefreshGF },
    { value = "raid",   text = ns.L["Raid Frames"],   root = "quiGroupFrames", unit = "raid",   refresh = RefreshGF },
    { value = "player", text = ns.L["Player"],        root = "quiUnitFrames",  unit = "player", refresh = RefreshUF },
}
local SURFACE_BY_VALUE = {}
for _, s in ipairs(SURFACES) do SURFACE_BY_VALUE[s.value] = s end

-- Read-only store lookup (no creation) for rendering checkbox state.
local function SurfaceAurasRaw(surfaceValue)
    local db = _G.QUI and _G.QUI.db and _G.QUI.db.profile
    local s = SURFACE_BY_VALUE[surfaceValue]
    local root = db and s and db[s.root]
    local unitTbl = root and root[s.unit]
    return unitTbl and unitTbl.auras or nil
end

-- Ensure-and-return store (for writes). Options are always OOC.
local function SurfaceAurasEnsure(surfaceValue)
    local db = _G.QUI and _G.QUI.db and _G.QUI.db.profile
    local s = SURFACE_BY_VALUE[surfaceValue]
    if not (db and s) then return nil end
    return ensure(ensure(ensure(db, s.root), s.unit), "auras")
end

local function SurfaceRefresh(surfaceValue)
    local s = SURFACE_BY_VALUE[surfaceValue]
    if s and s.refresh then s.refresh() end
end

-- Build the instance picker's dropdown options + a value->record lookup.
-- Records carry { journalInstanceID, name, mapID }. The current instance (if
-- any) is listed first; season Mythic+ dungeons follow, skipping a dungeon
-- entry that's the exact same mapID as the current-instance entry so a
-- player standing in this season's dungeon doesn't see it twice.
local function BuildInstanceChoices()
    local options, lookup = {}, {}

    local current = EC and type(EC.CurrentInstance) == "function" and EC.CurrentInstance()
    if current then
        local value = "current"
        lookup[value] = current
        options[#options + 1] = { value = value, text = string.format(ns.L["Current: %s"], current.name) }
    end

    -- Raids: the WHOLE expansion (every raid in the current Encounter-Journal
    -- tier), grouped under a non-selectable "Raids" header.
    local raidOpts = {}
    local raids = (EC and type(EC.ExpansionRaids) == "function" and EC.ExpansionRaids()) or {}
    for _, raid in ipairs(raids) do
        if raid.mapID and not (current and current.mapID == raid.mapID) then
            local value = "raid:" .. tostring(raid.journalInstanceID)
            lookup[value] = { journalInstanceID = raid.journalInstanceID, name = raid.name, mapID = raid.mapID }
            raidOpts[#raidOpts + 1] = { value = value, text = raid.name }
        end
    end
    if #raidOpts > 0 then
        options[#options + 1] = { isHeader = true, text = ns.L["Raids"] }
        for _, opt in ipairs(raidOpts) do options[#options + 1] = opt end
    end

    -- Dungeons: this season's Mythic+ pool (keystone-scoped by design), grouped
    -- under a non-selectable "Dungeons" header.
    local dungeonOpts = {}
    local dungeons = (EC and type(EC.SeasonDungeons) == "function" and EC.SeasonDungeons()) or {}
    for _, dungeon in ipairs(dungeons) do
        if dungeon.mapID and not (current and current.mapID == dungeon.mapID) then
            local journalInstanceID = EC and type(EC.JournalInstanceForMap) == "function"
                and EC.JournalInstanceForMap(dungeon.mapID)
            local value = "dungeon:" .. tostring(dungeon.mapChallengeModeID or dungeon.mapID)
            lookup[value] = { journalInstanceID = journalInstanceID, name = dungeon.name, mapID = dungeon.mapID }
            dungeonOpts[#dungeonOpts + 1] = { value = value, text = dungeon.name }
        end
    end
    if #dungeonOpts > 0 then
        options[#options + 1] = { isHeader = true, text = ns.L["Dungeons"] }
        for _, opt in ipairs(dungeonOpts) do options[#options + 1] = opt end
    end

    return options, lookup
end

-- ========================== boss-debuff gate strip ==========================
-- One dedicated HARMFUL strip per surface, gated on the engine's non-identity
-- boss filters (see file header). Stable string id, mirroring the shipped
-- "defensives" strip precedent, so the editor list and this dropdown agree on
-- which strip is "the boss strip".
local BOSS_STRIP_ID = "encounterBoss"

-- Group-frame surfaces resolve per-spec override buckets; writing "*" while a
-- spec override is active would be invisible (spec buckets REPLACE "*").
-- Unit-frame surfaces never create spec buckets, so this resolves to "*" there.
local function ActiveBucketKeyFor(auras)
    local W = ns.QUI_AuraWizard
    if W and type(W.ActiveBucketKey) == "function" and type(W.PlayerSpecID) == "function" then
        return W.ActiveBucketKey(auras.elements, W.PlayerSpecID())
    end
    return "*"
end

local function FindBossStrip(bucket)
    if type(bucket) ~= "table" then return nil end
    for _, e in ipairs(bucket) do
        if type(e) == "table" and e.id == BOSS_STRIP_ID then return e end
    end
    return nil
end

-- "off" (absent/disabled) | "all" (isBossAura) | "role" (isBossOrRoleAura)
local function BossStripMode(surfaceValue)
    local auras = SurfaceAurasRaw(surfaceValue)
    if not (auras and auras.elements) then return "off" end
    local strip = FindBossStrip(auras.elements[ActiveBucketKeyFor(auras)])
    if not strip or strip.enabled == false then return "off" end
    if strip.gateBossOrRoleAura == true then return "role" end
    return "all"
end

local function SetBossStripMode(surfaceValue, mode)
    local auras = SurfaceAurasEnsure(surfaceValue)
    if not auras then return end
    auras.elements = auras.elements or {}
    local key = ActiveBucketKeyFor(auras)
    auras.elements[key] = auras.elements[key] or {}
    local bucket = auras.elements[key]
    local strip = FindBossStrip(bucket)
    if mode == "off" then
        -- Keep the configured strip (placement, sizing) — just disable it.
        if strip then strip.enabled = false end
    else
        if not strip then
            strip = E.NewFilterStripElement("HARMFUL")
            strip.id = BOSS_STRIP_ID
            bucket[#bucket + 1] = strip
        end
        strip.enabled = true
        -- Candidate filters AND together — both gates set would collapse
        -- "role" back to boss-only. Keep them exclusive.
        strip.gateBossAura = (mode == "all") and true or nil
        strip.gateBossOrRoleAura = (mode == "role") and true or nil
    end
    SurfaceRefresh(surfaceValue)
end

-- Renders the ability catalog for `encounterID` into `host` starting at `y`,
-- one row per Journal-documented ability: icon + name + role-tag chips. A
-- reference catalog only — identity gating forbids per-ability filters on
-- every surface (see file header); the boss-debuff gate strip covers display.
-- Returns new y.
local function BuildAbilityRows(host, y, encounterID)
    local C = GUI.Colors or {}
    local abilities = (EC and type(EC.BossAbilities) == "function" and EC.BossAbilities(encounterID)) or {}

    if #abilities == 0 then
        local empty = GUI:CreateLabel(host, ns.L["No tracked abilities found for this boss."], 12, C.textMuted)
        empty:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
        return y + 18
    end

    local ROW_HEIGHT = 30

    for _, ability in ipairs(abilities) do
        local spellID = ability.spellID
        local row = CreateFrame("Frame", nil, host)
        row:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", host, "RIGHT", 0, 0)
        row:SetHeight(ROW_HEIGHT)

        -- Hover the row to see the ability's own Journal spell tooltip. This is
        -- an out-of-combat Options list (not a live combat frame), so it needs
        -- no debounce/storm guard -- contrast the group-frame aura path.
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if not (GameTooltip and spellID) then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetFrameStrata("TOOLTIP")
            GameTooltip:SetSpellByID(spellID)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        icon:SetTexture(ability.icon or FALLBACK_ICON)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local trailing = row
        local tagsText = RoleTagsText(ability.tags)
        if tagsText ~= "" then
            local tagsLabel = GUI:CreateLabel(row, tagsText, 11, C.textMuted)
            tagsLabel:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            trailing = tagsLabel
        end

        local nameLabel = GUI:CreateLabel(row, ability.name or ("#" .. tostring(spellID)), 12, C.text)
        nameLabel:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        if trailing == row then
            nameLabel:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        else
            nameLabel:SetPoint("RIGHT", trailing, "LEFT", -8, 0)
        end
        nameLabel:SetJustifyH("LEFT")
        nameLabel:SetWordWrap(false)

        y = y + ROW_HEIGHT + 2
    end

    return y
end

local function BuildAurasEncountersContent(host, ctx, section)
    local C = GUI.Colors or {}
    local FullSurface = Settings and Settings.FullSurface

    local y = 0

    -- Surface picker: which surface's aura store the boss-ability toggles write
    -- to (group-frame party/raid or unit-frame target/focus/player/boss).
    if ctx.state.selectedSurfaceValue == nil or SURFACE_BY_VALUE[ctx.state.selectedSurfaceValue] == nil then
        ctx.state.selectedSurfaceValue = SURFACES[1].value
    end

    local noteText = ns.L["Boss abilities are debuffs on YOU and your group, and 12.1 hides their exact spell identities from addons, so per-ability picks aren't possible. Use the boss-debuff strip — it shows boss-applied debuffs (optionally only role-relevant ones), appears on pull and self-hides after the fight. The ability list below is a reference catalog."]
    local note = GUI:CreateLabel(host, noteText, 12, C.textMuted)
    note:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    note:SetWidth(math.max((ctx and ctx.width or 700) - 16, 200))
    note:SetWordWrap(true)
    y = y + (note:GetStringHeight() or 16) + 10
    local surfaceOptions = {}
    for _, s in ipairs(SURFACES) do surfaceOptions[#surfaceOptions + 1] = { value = s.value, text = s.text } end
    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            topOffset = y,
            label = ns.L["Surface"],
            stateKey = "_surface",
            selectedValue = ctx.state.selectedSurfaceValue,
            options = surfaceOptions,
            meta = { description = ns.L["Which frames the boss-debuff strip below is configured for."] },
            height = 30,
            onChanged = function(value)
                if ctx.state.selectedSurfaceValue ~= value then
                    ctx.state.selectedSurfaceValue = value
                    if ctx and type(ctx.RerenderSection) == "function" then
                        ctx:RerenderSection(section.id)
                    end
                end
            end,
        })
        local rowHeight = (built and built.row and built.row.GetHeight and built.row:GetHeight()) or 30
        y = y + rowHeight + 8
    end

    -- The one control that IS engine-legal here — the dedicated boss-debuff
    -- gate strip (see file header). Reads/writes the spec-ACTIVE bucket so a
    -- group-frame spec override doesn't swallow it. "Role-relevant" is the
    -- engine's isBossOrRoleAura: boss debuffs plus debuffs tagged for ANY
    -- role (AuraUtil.IsRoleAura) — it is not filtered to the player's
    -- current role, so the label must not claim "my role".
    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            topOffset = y,
            label = ns.L["Boss debuffs"],
            stateKey = "_bossGate",
            selectedValue = BossStripMode(ctx.state.selectedSurfaceValue),
            options = {
                { value = "off",  text = ns.L["Off"] },
                { value = "all",  text = ns.L["All boss debuffs"] },
                { value = "role", text = ns.L["Role-relevant boss debuffs"] },
            },
            meta = { description = ns.L["Shows debuffs Blizzard marks as boss debuffs — or boss plus role-tagged debuffs — in a dedicated strip on this surface. Configure its placement in the element editor."] },
            height = 30,
            onChanged = function(value)
                SetBossStripMode(ctx.state.selectedSurfaceValue, value)
            end,
        })
        local rowHeight = (built and built.row and built.row.GetHeight and built.row:GetHeight()) or 30
        y = y + rowHeight + 8
    end

    local instanceOptions, instanceLookup = BuildInstanceChoices()

    if #instanceOptions == 0 then
        local empty = GUI:CreateLabel(host, ns.L["No instances found."], 12, C.textMuted)
        empty:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
        y = y + 18
        host:SetHeight(y)
        if GUI and type(GUI.SetSearchContext) == "function" then
            GUI:SetSearchContext({
                tileId = "auras",
                subPageIndex = 6,
                featureId = "aurasEncountersPage",
                tabIndex = 21,
                subTabIndex = 6,
                tabName = ns.L["Auras"],
                subTabName = ns.L["Encounters"],
            })
        end
        return y
    end

    if ctx.state.selectedInstanceValue == nil or instanceLookup[ctx.state.selectedInstanceValue] == nil then
        -- First SELECTABLE option (skip group headers, which carry no value).
        ctx.state.selectedInstanceValue = nil
        for _, opt in ipairs(instanceOptions) do
            if opt.value ~= nil then
                ctx.state.selectedInstanceValue = opt.value
                break
            end
        end
    end

    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            topOffset = y,
            label = ns.L["Instance"],
            stateKey = "_instance",
            selectedValue = ctx.state.selectedInstanceValue,
            options = instanceOptions,
            meta = { description = ns.L["Pick the raid or Mythic+ dungeon to configure tracked abilities for."] },
            height = 30,
            onChanged = function(value)
                if ctx.state.selectedInstanceValue ~= value then
                    ctx.state.selectedInstanceValue = value
                    ctx.state.selectedBossValue = nil
                    if ctx and type(ctx.RerenderSection) == "function" then
                        ctx:RerenderSection(section.id)
                    end
                end
            end,
        })
        local rowHeight = (built and built.row and built.row.GetHeight and built.row:GetHeight()) or 30
        y = y + rowHeight + 8
    end

    local selectedInstance = instanceLookup[ctx.state.selectedInstanceValue]
    local bosses = (selectedInstance and selectedInstance.journalInstanceID
        and EC and type(EC.InstanceBosses) == "function")
        and EC.InstanceBosses(selectedInstance.journalInstanceID) or {}

    if #bosses == 0 then
        local empty = GUI:CreateLabel(host, ns.L["No bosses found for this instance."], 12, C.textMuted)
        empty:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
        y = y + 18
        host:SetHeight(y)
        if GUI and type(GUI.SetSearchContext) == "function" then
            GUI:SetSearchContext({
                tileId = "auras",
                subPageIndex = 6,
                featureId = "aurasEncountersPage",
                tabIndex = 21,
                subTabIndex = 6,
                tabName = ns.L["Auras"],
                subTabName = ns.L["Encounters"],
            })
        end
        return y
    end

    local bossOptions = {}
    local bossLookup = {}
    for _, boss in ipairs(bosses) do
        local value = tostring(boss.encounterID)
        bossLookup[value] = boss.encounterID
        bossOptions[#bossOptions + 1] = { value = value, text = boss.name }
    end

    if ctx.state.selectedBossValue == nil or bossLookup[ctx.state.selectedBossValue] == nil then
        ctx.state.selectedBossValue = bossOptions[1].value
    end

    if FullSurface and type(FullSurface.BuildContextDropdownRow) == "function" then
        local built = FullSurface.BuildContextDropdownRow(host, {
            gui = GUI,
            topOffset = y,
            label = ns.L["Boss"],
            stateKey = "_boss",
            selectedValue = ctx.state.selectedBossValue,
            options = bossOptions,
            meta = { description = ns.L["Pick a boss to see its Journal-documented abilities."] },
            height = 30,
            onChanged = function(value)
                if ctx.state.selectedBossValue ~= value then
                    ctx.state.selectedBossValue = value
                    if ctx and type(ctx.RerenderSection) == "function" then
                        ctx:RerenderSection(section.id)
                    end
                end
            end,
        })
        local rowHeight = (built and built.row and built.row.GetHeight and built.row:GetHeight()) or 30
        y = y + rowHeight + 12
    end

    local encounterID = bossLookup[ctx.state.selectedBossValue]
    if encounterID then
        y = BuildAbilityRows(host, y, encounterID)
    end

    host:SetHeight(y)

    if GUI and type(GUI.SetSearchContext) == "function" then
        GUI:SetSearchContext({
            tileId = "auras",
            subPageIndex = 6,
            featureId = "aurasEncountersPage",
            tabIndex = 21,
            subTabIndex = 6,
            tabName = ns.L["Auras"],
            subTabName = ns.L["Encounters"],
        })
    end

    return y
end

Registry:RegisterFeature(Schema.Feature({
    id = "aurasEncountersPage",
    category = "frames",
    nav = { tileId = "auras", subPageIndex = 6 },
    sections = {
        Schema.Section({
            id = "settings",
            kind = "page",
            minHeight = 80,
            build = BuildAurasEncountersContent,
        }),
    },
}))
