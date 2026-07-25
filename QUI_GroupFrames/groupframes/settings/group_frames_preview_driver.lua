--[[
    QUI Group Frames - Settings Preview Driver

    Renders the docked group-frame settings preview: a mock unit-frame roster
    that reflects every group setting live and animates via one OnUpdate ticker.
    Aura elements follow the live ownership split: health tint, border and
    missing raid buffs use ns.QUI_GroupFrameAuraRender with fabricated matches;
    engine-owned filter strips and tracked icon/square/bar containers use
    ns.AuraPreview placeholders laid out with the live pin math.

    Public surface (also published as the 3 _G.QUI_*GroupFramePreview seams):
        ns.QUI_GroupFramesPreview.Build(host)
        ns.QUI_GroupFramesPreview.Refresh(contextMode)
        ns.QUI_GroupFramesPreview.Teardown()

    Invariants: registers no game events; never touches real party/raid frames;
    no WoW API call at file scope (loads under a bare test ns).
]]
local _, ns = ...
local function CJKFont(fs, p, s, f)
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(fs, p, s, f)
    else
        fs:SetFont(p, s, f)
    end
end

local Driver = ns.QUI_GroupFramesPreview or {}
ns.QUI_GroupFramesPreview = Driver

---------------------------------------------------------------------------
-- FAKE DATA POOLS (preview only — not gameplay data)
---------------------------------------------------------------------------
local PREVIEW_BUFF_ICONS   = { 136034, 135940, 136081, 135932, 136063 }
local FAKE_DURATIONS = { 8, 15, 30, 45, 60 }
local DISPEL_CYCLE   = { "Magic", "Curse", "Disease", "Poison" }

local _fakeInstance = 0
local function NextInstanceID()
    _fakeInstance = _fakeInstance + 1
    return _fakeInstance
end

-- Real spell icon when the client is present; nil under a bare test ns.
local function ResolveSpellIcon(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and tex then return tex end
    end
    return nil
end

-- now is injected so the builders are pure/testable (callers pass GetTime()).
local function MakeFakeAura(icon, index, harmful, now, spellId)
    local duration = FAKE_DURATIONS[((index - 1) % #FAKE_DURATIONS) + 1]
    local phase = ((index - 1) % 5) / 5          -- 0,.2,.4,.6,.8 — staggered fill
    local remaining = duration * (1 - phase)
    return {
        auraInstanceID = NextInstanceID(),
        icon           = icon,
        spellId        = spellId or (3000 + index),
        name           = harmful and "Preview Debuff" or "Preview Buff",
        duration       = duration,
        expirationTime = now + remaining,
        dispelName     = harmful and DISPEL_CYCLE[((index - 1) % #DISPEL_CYCLE) + 1] or nil,
        isBossAura     = false,
        isHelpful      = not harmful,
        isHarmful      = harmful,
    }
end

---------------------------------------------------------------------------
-- PURE PREVIEW HELPERS (no WoW API — math/table logic, unit-tested directly)
---------------------------------------------------------------------------

-- Raid preview frame-count tiers (multiples of 5, matching the step-5 sliders so
-- a slider value always renders 1:1; odd stored values snap to the nearest tier).
local RAID_COUNT_TIERS = { 5, 10, 15, 20, 25, 30, 35, 40 }

-- Snap an arbitrary raid count to the nearest tier. nil -> 25 (default).
-- Clamps to [5,40]; ties round UP to the larger tier.
function Driver._SnapRaidCount(n)
    n = tonumber(n)
    if not n then return 25 end
    if n <= RAID_COUNT_TIERS[1] then return RAID_COUNT_TIERS[1] end
    local last = RAID_COUNT_TIERS[#RAID_COUNT_TIERS]
    if n >= last then return last end
    local best, bestDist = RAID_COUNT_TIERS[1], math.huge
    for _, tier in ipairs(RAID_COUNT_TIERS) do
        local dist = math.abs(tier - n)
        -- Tiers are ascending, so on an exact tie (dist == bestDist) the later,
        -- larger tier wins -> ties round up.
        if dist < bestDist or (dist == bestDist and tier > best) then
            best, bestDist = tier, dist
        end
    end
    return best
end

-- Preview focus-filter keys. Each maps to an element group gated in the preview
-- ON TOP OF the normal config gates. Default all-on.
local FILTER_KEYS = {
    "threat", "dispel", "auras", "indicators", "targetedSpells",
    "targetHighlight", "pets", "range",
}

-- Normalize an arbitrary filter table to exactly FILTER_KEYS, defaulting any
-- missing key to true and dropping unknown keys.
function Driver._NormalizeFilter(tbl)
    tbl = tbl or {}
    local out = {}
    for _, k in ipairs(FILTER_KEYS) do
        out[k] = (tbl[k] ~= false)
    end
    return out
end

-- True unless the filter explicitly disables this key.
function Driver._FilterAllows(filter, key)
    if not filter then return true end
    return filter[key] ~= false
end

local INDICATOR_TOGGLE_KEYS = {
    "showRoleIcon", "showReadyCheck", "showResurrection", "showSummonPending",
    "showLeaderIcon", "showTargetMarker", "showPhaseIcon",
}

-- Whether the underlying config feature(s) behind a focus chip are enabled.
-- Surface uses this to grey chips the user can't usefully preview.
function Driver._ChipEnabledInConfig(vdb, chipKey)
    vdb = vdb or {}
    local ind = vdb.indicators or {}
    local healer = vdb.healer or {}
    if chipKey == "threat" then
        return ind.showThreatBorder ~= false
    elseif chipKey == "dispel" then
        local d = healer.dispelOverlay
        local glow = healer.cleanseGlow
        return ((d ~= nil) and (d.enabled ~= false))
            or ((glow ~= nil) and (glow.enabled == true))
    elseif chipKey == "auras" then
        local a = vdb.auras
        return (a ~= nil) and (a.enabled ~= false)
    elseif chipKey == "indicators" then
        for _, k in ipairs(INDICATOR_TOGGLE_KEYS) do
            if ind[k] then return true end
        end
        return false
    elseif chipKey == "targetedSpells" then
        return (vdb.targetedSpells ~= nil) and (vdb.targetedSpells.enabled ~= false)
    elseif chipKey == "targetHighlight" then
        return (healer.targetHighlight ~= nil) and (healer.targetHighlight.enabled == true)
    elseif chipKey == "pets" then
        return (vdb.pets ~= nil) and (vdb.pets.enabled == true)
    elseif chipKey == "range" then
        return (vdb.range ~= nil) and (vdb.range.enabled == true)
    end
    return false
end

-- One contract for both the full refresh and the aura-only refresh: the Aura
-- focus chip supplies the configured aura table when ON and nil when OFF. nil
-- drives RenderFrameAuras' complete release/hide path.
function Driver._AuraSettingsForFilter(vdb, filter)
    if filter and filter.auras == false then return nil end
    return vdb and vdb.auras or nil
end

function Driver._AuraHostLevel(baseLevel)
    local chrome = ns.QUI_GroupFrameChrome
    local levels = chrome and chrome.LEVELS
    return (tonumber(baseLevel) or 0) + ((levels and levels.AURA_HOST) or 11)
end

function Driver._BuildMissingRaidBuffMatches(element, now)
    local out = {}
    local MRB = ns.QUI_GroupFrameMissingRaidBuffs
    local buffs = MRB and MRB.RaidBuffs
    local maxIcons = tonumber(element and element.maxIcons) or 1
    if maxIcons <= 0 then maxIcons = buffs and #buffs or 1 end
    if buffs and #buffs > 0 then
        for i = 1, math.min(maxIcons, #buffs) do
            local buff = buffs[i]
            local spellID = buff.iconSpellID or (buff.ids and buff.ids[1])
            local icon = ResolveSpellIcon(spellID) or PREVIEW_BUFF_ICONS[((i - 1) % #PREVIEW_BUFF_ICONS) + 1]
            out[i] = MakeFakeAura(icon, i, false, now, spellID)
        end
    else
        out[1] = MakeFakeAura(PREVIEW_BUFF_ICONS[1], 1, false, now)
    end
    return out
end

---------------------------------------------------------------------------
-- GRID MATH — replicate the secure-header anchor layout (offsets from the
-- roster root's TOP-LEFT; +x right, +y up; y negative = downward).
---------------------------------------------------------------------------
local function ResolveGrow(layout)
    local g = layout and layout.growDirection
    if g == "UP" or g == "DOWN" or g == "LEFT" or g == "RIGHT" then return g end
    if layout and layout.orientation == "HORIZONTAL" then return "RIGHT" end
    return "DOWN"
end

function Driver._ComputeGridPositions(contextMode, count, layout, w, h)
    layout = layout or {}
    local grow = ResolveGrow(layout)
    local horizontal = (grow == "LEFT" or grow == "RIGHT")
    -- Default matches the live header math (groupframes.lua CalculateHeaderSize
    -- uses `layout.spacing or 2`); previewing an unset spacing as 0 drew the
    -- tiles flush when the real frames have a 2px gap.
    local spacing = tonumber(layout.spacing) or 2
    local isRaid = (contextMode == "raid")

    local perGroup, colSpacing, groupGrow
    if isRaid then
        if (layout.groupBy or "GROUP") == "NONE" then
            perGroup = tonumber(layout.unitsPerFlat) or 5
            colSpacing = spacing
        else
            perGroup = 5
            colSpacing = tonumber(layout.groupSpacing) or 10
        end
        groupGrow = layout.groupGrowDirection or "RIGHT"
    else
        perGroup = 5            -- party: single group, count <= 5
        colSpacing = spacing
        groupGrow = "RIGHT"
    end
    if perGroup < 1 then perGroup = 1 end

    local positions = {}
    for i = 1, count do
        local gi = math.floor((i - 1) / perGroup)   -- group index (0-based)
        local si = (i - 1) % perGroup               -- slot index within group
        local slotStep  = si * ((horizontal and w or h) + spacing)
        local groupStep = gi * ((horizontal and h or w) + colSpacing)
        local x, y = 0, 0
        if horizontal then
            x = (grow == "RIGHT") and slotStep or -slotStep
            y = -groupStep                                  -- columnAnchorPoint TOP
        else
            y = (grow == "UP") and slotStep or -slotStep
            x = (groupGrow == "LEFT") and -groupStep or groupStep
        end
        positions[i] = { x = x, y = y, w = w, h = h }
    end
    return positions
end

---------------------------------------------------------------------------
-- ROSTER — deterministic fake members for the mock grid.
---------------------------------------------------------------------------
local FAKE_CLASSES = { "WARRIOR","PALADIN","PRIEST","DRUID","SHAMAN","MAGE",
    "ROGUE","HUNTER","WARLOCK","DEATHKNIGHT","MONK","DEMONHUNTER","EVOKER" }
local FAKE_NAMES = { "Tankthor","Healena","Pwnadin","Natureza","Shamwow","Frostina",
    "Stabsworth","Bowmaster","Felcaster","Lichking","Mistpaw","Demonbane","Scalewing",
    "Ironwall","Lightbeam","Shadowmend","Wildgrowth","Totemist","Arcanist","Backstab",
    "Marksman","Doomcall","Runeblade","Zenmaster","Havocwing","Breathfire","Shieldwall",
    "Holylight","Mindblast","Starfall","Lavaflow","Pyrolust","Ambusher","Snipeshot",
    "Soulburn","Froststorm","Tigerpaw","Vengewing","Glimmora","Bulwark" }
local FAKE_ROLES_PARTY = { "TANK","HEALER","DAMAGER","DAMAGER","DAMAGER" }
local HP_PATTERN = { 100,85,65,45,92,78,30,95,88,55, 72,100,80,60,90,75,40,98,82,68,
    100,100,70,50,95,85,35,100,77,62, 88,42,100,73,56,91,100,83,47,100 }

local function RoleForIndex(contextMode, i)
    if contextMode == "raid" then
        if i <= 2 then return "TANK" elseif i <= 6 then return "HEALER" else return "DAMAGER" end
    end
    return FAKE_ROLES_PARTY[((i - 1) % #FAKE_ROLES_PARTY) + 1]
end

function Driver._BuildRoster(contextMode, count)
    local out = {}
    for i = 1, count do
        out[i] = {
            name      = FAKE_NAMES[((i - 1) % #FAKE_NAMES) + 1],
            class     = FAKE_CLASSES[((i - 1) % #FAKE_CLASSES) + 1],
            role      = RoleForIndex(contextMode, i),
            healthPct = HP_PATTERN[((i - 1) % #HP_PATTERN) + 1],
            level     = 80 - ((i - 1) % 6),
            group     = math.ceil(i / 5),
            isSelf    = i == 1,
            sourceIndex = i,
        }
    end
    return out
end

local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }

-- Apply the roster settings that are visually meaningful in a synthetic
-- preview: party player/DPS filters, group/role/class grouping, name/role sort
-- and the explicit self-first pin.
function Driver._PrepareRoster(contextMode, count, layout, gfdb)
    layout = layout or {}
    gfdb = gfdb or {}
    local source = Driver._BuildRoster(contextMode, count)
    local out = {}
    for _, member in ipairs(source) do
        local keep = true
        if contextMode == "party" then
            if layout.showPlayer == false and member.isSelf then keep = false end
            if layout.hideDPS == true and member.role == "DAMAGER" then keep = false end
        end
        if keep then out[#out + 1] = member end
    end

    local groupBy = contextMode == "raid" and (layout.groupBy or "GROUP") or "NONE"
    local byName = layout.sortMethod == "NAME"
    local byRole = layout.sortByRole == true or groupBy == "ROLE"
    table.sort(out, function(a, b)
        if groupBy == "GROUP" and a.group ~= b.group then return a.group < b.group end
        if groupBy == "CLASS" and a.class ~= b.class then return a.class < b.class end
        if byRole and a.role ~= b.role then
            return (ROLE_ORDER[a.role] or 9) < (ROLE_ORDER[b.role] or 9)
        end
        if byName and a.name ~= b.name then return a.name < b.name end
        return a.sourceIndex < b.sourceIndex
    end)

    local selfFirst
    if contextMode == "raid" then
        selfFirst = gfdb.raidSelfFirst
    else
        selfFirst = gfdb.partySelfFirst
    end
    if selfFirst then
        for i = 2, #out do
            if out[i].isSelf then
                local member = table.remove(out, i)
                table.insert(out, 1, member)
                break
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- DRIVER STATE + MOCK FRAME FACTORY
---------------------------------------------------------------------------
local MAX_AURA_PREVIEW_FRAMES = 5

local state = {
    host       = nil,   -- panel.contentHost from the surface
    root       = nil,   -- roster root frame (the measured previewCell)
    frames     = {},    -- all mock unit frames
    auraFrames = {},    -- subset that renders aura elements
    ticker     = nil,
    contextMode = "party",
    onBuilt    = nil,   -- observer fn from the surface
    clock      = 0,
}
Driver._state = state   -- exposed for later tasks in this file

local function EnsureRoot()
    if state.root and state.root:GetParent() == state.host then return state.root end
    if state.root then state.root:Hide(); state.root:SetParent(nil) end
    state.root = CreateFrame("Frame", nil, state.host)
    state.root:SetPoint("TOPLEFT", state.host, "TOPLEFT", 0, 0)
    state.root:SetSize(1, 1)
    return state.root
end
Driver._EnsureRoot = EnsureRoot

-- Build ONE mock unit frame with the regions the preview styles + the members
-- the aura renderer reads (previewUnit/healthBar/._healthPct/._isVerticalFill/._bottomPad).
local function CreateMockFrame(parent, fakeUnitToken)
    local f = CreateFrame("Button", nil, parent, "BackdropTemplate")
    f.previewUnit = fakeUnitToken           -- routed through QUI_GF.GetFrameUnit
    f._bottomPad = 0
    -- Dirty-check table Chrome.ResizeHealthForPower keeps its geometry in (the
    -- runtime uses the frame's own state entry for exactly the same purpose).
    f._chromeState = {}

    -- The health bar, power bar, overlay bars, text frame, name/level/health
    -- text, corner indicator textures, threat / target-highlight / dispel /
    -- cleanse overlays and the portrait are ALL built by
    -- ns.QUI_GroupFrameChrome.Apply -- the same builder DecorateGroupFrame
    -- runs on live frames -- so preview layering IS runtime layering and there
    -- is nothing to re-derive here.

    -- Placeholder host for the elements the ENGINE draws live (filter strips,
    -- tracked icon/square/bar): parked at the shared live aura-host level so
    -- placeholders sit exactly where the real containers do.
    f._auraHost = CreateFrame("Frame", nil, f)
    f._auraHost:SetAllPoints(f)
    f._auraHost:SetFrameLevel(Driver._AuraHostLevel(f:GetFrameLevel()))
    return f
end
Driver._CreateMockFrame = CreateMockFrame

---------------------------------------------------------------------------
-- SETTINGS STYLING
---------------------------------------------------------------------------
-- Dispel-type seed mirrors the settings UI's 4-color palette (no Bleed) so the
-- preview border colors match what the dispel-overlay tab pickers default to.
local DISPEL_SEED_FALLBACK = {
    Magic   = { 0.2, 0.6, 1.0 },
    Curse   = { 0.6, 0.0, 1.0 },
    Disease = { 0.6, 0.4, 0.0 },
    Poison  = { 0.0, 0.6, 0.0 },
}

-- Role atlases mirror the live builder (ns.QUI_GroupFrameRoleAtlas / ROLE_ATLAS).
local ROLE_ATLAS_FALLBACK = {
    TANK    = "roleicon-tiny-tank",
    HEALER  = "roleicon-tiny-healer",
    DAMAGER = "roleicon-tiny-dps",
}
local ROLE_TOGGLE_KEY = {
    TANK    = "showRoleTank",
    HEALER  = "showRoleHealer",
    DAMAGER = "showRoleDPS",
}

local function GetGFDB()
    local H = ns.Helpers
    local prof = H and H.GetProfile and H.GetProfile()
    return prof and prof.quiGroupFrames or nil
end
Driver._GetGFDB = GetGFDB

local function GetContextDB(gfdb, contextMode)
    if not gfdb then return nil end
    return (contextMode == "raid" and gfdb.raid) or gfdb.party or gfdb
end
Driver._GetContextDB = GetContextDB

-- (statusbar texture resolution now comes from the shared chrome module --
-- Chrome.ApplyStatusBarTexture -- so the preview cannot pick a different one.)

local function FontPath(general)
    local sm = ns.LSM
    local name = (general and general.font) or "Quazii"
    return (sm and sm.Fetch and sm:Fetch("font", name)) or "Fonts\\FRIZQT__.TTF"
end

local function ClassColor(class)
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r, c.g, c.b
    end
    return 0.6, 0.6, 0.6
end

-- The shared frame chrome (core/group_frame_chrome.lua) ships in the core addon,
-- so it is always loaded before this file. Resolve it lazily anyway: the
-- headless driver tests load this file against a bare ns.
local function GetChrome() return ns.QUI_GroupFrameChrome end

-- Fallback colors and the role/dispel palettes come from the modules that OWN
-- them (chrome, groupframes.lua, icon layout) so the preview cannot drift from
-- the live defaults the way its private copies did.
local function DefaultColor(key)
    local C = GetChrome()
    local t = C and C.DEFAULT_COLORS
    return (t and t[key]) or { 1, 1, 1, 1 }
end

local function RoleAtlas()
    return ns.QUI_GroupFrameRoleAtlas or ROLE_ATLAS_FALLBACK
end

local function DispelPalette()
    local IL = ns.QUI_GroupFrameIconLayout
    return (IL and IL.DISPEL_DEFAULT_COLORS) or DISPEL_SEED_FALLBACK
end

-- Add bottomPad to a Y offset whenever the anchor is a BOTTOM* point (mirrors the
-- live builder's BottomPadY so preview-only overlays clear the power bar).
local function BottomPadY(anchor, offY, bottomPad)
    if anchor and anchor:find("BOTTOM") then return (offY or 0) + (bottomPad or 0) end
    return offY or 0
end

---------------------------------------------------------------------------
-- SETTINGS STYLING
--
-- Everything structural -- backdrop, health bar, the three overlay bars, power
-- bar, text frame, name/level/health/status text, corner indicator textures,
-- threat / target-highlight / dispel / cleanse overlays, portrait -- is built
-- and positioned by ns.QUI_GroupFrameChrome.Apply, the SAME builder
-- DecorateGroupFrame runs on live frames. What is left here is only what a
-- preview legitimately owns: fabricated values (health percentages, sample
-- colors, mock names), the demo gating for transient states, and preview-only
-- extras (targeted-spell markers, pets, range fade).
---------------------------------------------------------------------------

-- Role filter for the power bar: the live path is UpdatePower ->
-- ShouldShowPowerForUnit -> Chrome.ResizeHealthForPower.
local function PowerVisibleFor(member, power)
    if power.showPowerBar == false then return false end
    local onlyHealers, onlyTanks = power.powerBarOnlyHealers, power.powerBarOnlyTanks
    if onlyHealers or onlyTanks then
        return (onlyHealers and member.role == "HEALER")
            or (onlyTanks and member.role == "TANK") or false
    end
    return true
end

-- Health + power VALUES and colors (geometry/texture/orientation are Chrome's).
local function ApplyBarValues(f, member, general, power, showPower)
    local hb = f.healthBar
    if hb then
        f._baseHealthPct = member.healthPct
        f._healthPct = member.healthPct
        hb:SetMinMaxValues(0, 100)
        hb:SetValue(member.healthPct)
        local r, g, b = 0.2, 0.8, 0.2
        if general.useClassColor then
            r, g, b = ClassColor(member.class)
        elseif general.darkMode and general.darkModeHealthColor then
            local c = general.darkModeHealthColor; r, g, b = c[1] or r, c[2] or g, c[3] or b
        end
        hb:SetStatusBarColor(r, g, b, 1)
    end

    local pb = f.powerBar
    if not pb then return end
    if not showPower then pb:Hide(); return end
    pb:SetMinMaxValues(0, 100)
    pb:SetValue(80)
    -- Default mana-blue stands in for the live power-type color; when the user
    -- opts OUT of power-type coloring, honor the configured custom color.
    local r, g, b = 0.2, 0.4, 0.8
    if not power.powerBarUsePowerColor and power.powerBarColor then
        local c = power.powerBarColor; r, g, b = c[1] or r, c[2] or g, c[3] or b
    end
    pb:SetStatusBarColor(r, g, b, 1)
    pb:Show()
end

-- Overlay bar VALUES: Chrome already styled absorb / heal-absorb / heal-pred
-- (draw order, texture, fill origin, detached geometry, spark, outline), so
-- the preview only fills them with a representative amount and color.
local OVERLAY_SAMPLE = {
    { key = "healPredictionBar", cfg = "healPrediction", value = 20, alpha = 0.5, r = 0.2, g = 1,   b = 0.2 },
    { key = "absorbBar",         cfg = "absorbs",        value = 25, alpha = 0.3, r = 1,   g = 1,   b = 1   },
    { key = "healAbsorbBar",     cfg = "healAbsorbs",    value = 15, alpha = 0.6, r = 0.5, g = 0.1, b = 0.1 },
}

local function ApplyHealthOverlays(f, member, vdb)
    for _, spec in ipairs(OVERLAY_SAMPLE) do
        local bar = f[spec.key]
        local settings = vdb[spec.cfg]
        if bar then
            if not settings or settings.enabled == false then
                bar:Hide()
            else
                bar:SetMinMaxValues(0, 100)
                bar:SetValue(spec.value)
                local r, g, b = spec.r, spec.g, spec.b
                if settings.useClassColor then
                    r, g, b = ClassColor(member.class)
                elseif settings.color then
                    local c = settings.color; r, g, b = c[1] or r, c[2] or g, c[3] or b
                end
                bar:SetStatusBarColor(r, g, b, tonumber(settings.opacity) or spec.alpha)
                bar:Show()
            end
        end
    end
end

-- Name / level text CONTENT (Chrome owns font, anchors and justification).
local function ApplyTextContent(f, member, nameCfg)
    local nt = f.nameText
    if nt then
        if nameCfg.showName == false then
            nt:Hide()
        else
            local label = member.name
            local maxLen = tonumber(nameCfg.maxNameLength) or 0
            if maxLen > 0 then label = label:sub(1, maxLen) end
            nt:SetText(label)
            if nameCfg.nameTextUseClassColor then
                nt:SetTextColor(ClassColor(member.class))
            elseif nameCfg.nameTextColor then
                local c = nameCfg.nameTextColor; nt:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1)
            else
                nt:SetTextColor(1, 1, 1)
            end
            nt:Show()
        end
    end

    local lt = f.levelText
    if not lt then return end
    if nameCfg.showLevel ~= true then
        lt:Hide()
        return
    end
    lt:SetText(tostring(member.level or 80))
    if nameCfg.levelTextColor then
        local c = nameCfg.levelTextColor; lt:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1)
    else
        lt:SetTextColor(1, 1, 1)
    end
    lt:Show()
end

-- Build the configured health-text string from a percent + a fake max HP.
local function FormatHealthText(style, pct, hideSymbol)
    local FAKE_MAX = 100000
    local hp = math.floor(FAKE_MAX * (pct / 100) + 0.5)
    if style == "absolute" then
        local abbr = AbbreviateNumbers or AbbreviateLargeNumbers
        return abbr and abbr(hp) or tostring(hp)
    elseif style == "both" then
        local abbr = AbbreviateNumbers or AbbreviateLargeNumbers
        local hpStr = abbr and abbr(hp) or tostring(hp)
        return hpStr .. (hideSymbol and (" | %d"):format(pct) or (" | %d%%"):format(pct))
    elseif style == "deficit" then
        local miss = FAKE_MAX - hp
        local abbr = AbbreviateNumbers or AbbreviateLargeNumbers
        if miss <= 0 then return "" end
        return "-" .. (abbr and abbr(miss) or tostring(miss))
    end
    return hideSymbol and ("%d"):format(pct) or ("%d%%"):format(pct)
end

-- Health text CONTENT + the ticker hook (Chrome owns font/anchor/justify).
local function ApplyHealthText(f, health)
    local ht = f.healthText
    if not ht then return end
    if health.showHealthText == false then
        ht:Hide()
        f._UpdateHealthText = nil
        return
    end
    local tc = health.healthTextColor
    if tc then ht:SetTextColor(tc[1] or 1, tc[2] or 1, tc[3] or 1, tc[4] or 1)
    else ht:SetTextColor(1, 1, 1, 1) end
    local style = health.healthDisplayStyle or "percent"
    local hideSymbol = health.hideHealthPercentSymbol
    ht:SetText(FormatHealthText(style, f._healthPct or 100, hideSymbol))
    ht:Show()
    f._UpdateHealthText = function(pct)
        ht:SetText(FormatHealthText(style, pct or 0, hideSymbol))
    end
end

-- Role icon: Chrome sized and positioned frame.roleIcon; the preview picks the
-- atlas for the mock member's role and honors the per-role toggles.
local function ApplyRoleIcon(f, member, ind, allowed)
    local icon = f.roleIcon
    if not icon then return end
    local atlasMap = RoleAtlas()
    local toggleKey = ROLE_TOGGLE_KEY[member.role]
    local show = allowed ~= false and ind.showRoleIcon and atlasMap[member.role]
        and (not toggleKey or ind[toggleKey] ~= false)
    if not show then icon:Hide(); return end
    icon:SetAtlas(atlasMap[member.role])
    icon:SetAlpha(1)
    icon:Show()
end

-- No demo slots (spotlight tiles, or a roster past the demo table): every
-- transient indicator stays hidden on that tile.
local EMPTY_DEMO = {}

-- indicators: readyCheck / resurrection / summon / leader / targetMarker / phase.
-- Every one of these is TRANSIENT at runtime (a ready check in progress, a
-- pending res/summon, the marked unit, the leader, a phased unit) -- drawing
-- them all on every tile stacked three CENTER-anchored icons on top of each
-- other on all five frames, which is nothing the runtime ever renders. Each
-- demos on one representative tile (INDICATOR_DEMO, assigned by
-- AssignSampleFlags); pairs that share a tile use non-overlapping anchors.
--
-- Size/anchor/offset all come from Chrome (it created and placed these exact
-- textures); the preview only decides visibility and supplies the sample art.
local INDICATOR_ART = {
    { key = "readyCheckIcon", show = "showReadyCheck",     demo = "readyCheck",
      texture = "Interface\\RAIDFRAME\\ReadyCheck-Ready" },
    { key = "resIcon",        show = "showResurrection",   demo = "resurrection" },
    { key = "summonIcon",     show = "showSummonPending",  demo = "summon" },
    { key = "leaderIcon",     show = "showLeaderIcon",     demo = "leader",
      atlas = "groupfinder-icon-leader" },
    { key = "targetMarker",   show = "showTargetMarker",   demo = "targetMarker",
      texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", raidIcon = 8 },
    { key = "phaseIcon",      show = "showPhaseIcon",      demo = "phase" },
}

local function ApplyIndicators(f, ind, allowed, demo)
    demo = demo or EMPTY_DEMO
    for _, spec in ipairs(INDICATOR_ART) do
        local tex = f[spec.key]
        if tex then
            if allowed == false or not demo[spec.demo] or not ind[spec.show] then
                tex:Hide()
            else
                -- res/summon/phase already carry their live texture from Chrome.
                if spec.atlas then tex:SetAtlas(spec.atlas)
                elseif spec.texture then tex:SetTexture(spec.texture) end
                if spec.raidIcon and SetRaidTargetIconTexture then
                    SetRaidTargetIconTexture(tex, spec.raidIcon)  -- 8 = skull sample
                end
                tex:Show()
            end
        end
    end
end

-- threat (indicators.showThreatBorder/threatColor) on Chrome's threatBorder,
-- colored the way UpdateThreat colors it at runtime.
local function ApplyThreat(f, ind, isSample)
    local tb = f.threatBorder
    if not tb then return end
    if ind.showThreatBorder == false or not isSample then tb:Hide(); return end
    local c = ind.threatColor or DefaultColor("threat")
    local C = GetChrome()
    if not C then tb:Hide(); return end
    C.SetBackdropOverlayColor(tb, c[1], c[2], c[3], c[4] or 0.8)
    tb:Show()
end

-- target highlight (healer.targetHighlight) on Chrome's targetHighlight,
-- colored the way UpdateTargetHighlight colors it at runtime.
local function ApplyTargetHighlight(f, healer, isTarget)
    local th = f.targetHighlight
    if not th then return end
    local cfg = healer and healer.targetHighlight
    if not cfg or cfg.enabled == false or not isTarget then th:Hide(); return end
    local c = cfg.color or DefaultColor("targetHighlight")
    local C = GetChrome()
    if not C then th:Hide(); return end
    C.SetBackdropOverlayColor(th, c[1], c[2], c[3], c[4] or 0.6)
    th:Show()
end

-- dispel overlay (healer.dispelOverlay) on Chrome's dispelOverlay, tinted
-- through the shared Chrome.SetDispelBorderColor the runtime uses.
local function ApplyDispelOverlay(f, healer, dispelType)
    local ov = f.dispelOverlay
    if not ov then return end
    local cfg = healer and healer.dispelOverlay
    if not cfg or cfg.enabled == false or not dispelType then ov:Hide(); return end
    local C = GetChrome()
    if not C then ov:Hide(); return end
    local seed = DispelPalette()
    local colors = cfg.colors or seed
    local c = colors[dispelType] or seed[dispelType] or DefaultColor("dispelFallback")
    C.SetDispelBorderColor(ov, c[1], c[2], c[3], tonumber(cfg.opacity) or 1)
    ov:Show()
end

-- cleanse-ready glow shares the dispellable sample with the border but has its
-- own enable/color settings and can run with the border disabled.
local function ApplyCleanseGlow(f, healer, hasDispellable)
    local glow = f.cleanseGlow
    if not glow then return end
    local cfg = healer and healer.cleanseGlow
    if not cfg or cfg.enabled ~= true or not hasDispellable then
        glow:Hide()
        return
    end
    local c = cfg.color or { 0.1, 1.0, 0.1, 1 }
    if glow.tex then
        glow.tex:SetVertexColor(c[1] or 0.1, c[2] or 1, c[3] or 0.1, c[4] or 1)
    end
    glow:Show()
end

-- Portrait: Chrome built and anchored the bordered frame; the preview fills it
-- with a flat swatch (there is no unit to portrait).
local function ApplyPortraitTint(f)
    local tex = f.portraitTexture
    if tex then tex:SetColorTexture(0.15, 0.15, 0.2, 1) end
end

-- targetedSpells (enabled/maxIcons/iconSize/reverseSwipe/growDirection/spacing/
--   position/offsetX/Y) — representative enemy-cast markers on sampled frames.
local TARGETED_SPELL_SAMPLES = { 135807, 136197, 136201, 135826, 135818 }
local function ApplyTargetedSpells(f, targeted, sampleCount, allowed)
    f._targetedSpellIcons = f._targetedSpellIcons or {}
    if allowed == false or not targeted or targeted.enabled == false or not sampleCount then
        for _, ic in ipairs(f._targetedSpellIcons) do ic:Hide() end
        return
    end

    local count = math.min(tonumber(targeted.maxIcons) or 3, tonumber(sampleCount) or 1)
    if count < 1 then
        for _, ic in ipairs(f._targetedSpellIcons) do ic:Hide() end
        return
    end

    local iconSize = tonumber(targeted.iconSize) or 24
    local spacing = tonumber(targeted.spacing) or 2
    local growDir = targeted.growDirection or "CENTER"
    local position = targeted.position or "CENTER"
    local offX = tonumber(targeted.offsetX) or 0
    local offY = BottomPadY(position, tonumber(targeted.offsetY) or 0, f._bottomPad)
    local reverseSwipe = targeted.reverseSwipe ~= false
    local step = iconSize + spacing
    local centerOffset = (growDir == "CENTER") and -((count - 1) * step) / 2 or 0

    for i = 1, math.max(count, #f._targetedSpellIcons) do
        local ic = f._targetedSpellIcons[i]
        if i <= count then
            if not ic then
                ic = CreateFrame("Frame", nil, f, "BackdropTemplate")
                ic._icon = ic:CreateTexture(nil, "ARTWORK")
                ic._icon:SetAllPoints()
                ic._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                ic._cd = CreateFrame("Cooldown", nil, ic, "CooldownFrameTemplate")
                ic._cd:SetAllPoints()
                f._targetedSpellIcons[i] = ic
            end

            local C = GetChrome()
            local levels = C and C.LEVELS
            ic:SetFrameLevel(f:GetFrameLevel() + ((levels and levels.TARGETED) or 13))
            ic:SetSize(iconSize, iconSize)
            ic._icon:SetTexture(TARGETED_SPELL_SAMPLES[((i - 1) % #TARGETED_SPELL_SAMPLES) + 1])

            if ic._cd then
                if ic._cd.SetReverse then ic._cd:SetReverse(reverseSwipe) end
                if ic._cd.SetDrawSwipe then ic._cd:SetDrawSwipe(true) end
                if ic._cd.SetSwipeColor then ic._cd:SetSwipeColor(0, 0, 0, 0.6) end
                if ic._cd.SetHideCountdownNumbers then ic._cd:SetHideCountdownNumbers(true) end
                if ic._cd.SetCooldown then ic._cd:SetCooldown(GetTime and GetTime() or 0, 4 + i * 2) end
                ic._cd:Show()
            end

            local sx, sy = centerOffset, 0
            if growDir == "LEFT" then
                sx = -(i - 1) * step
            elseif growDir == "UP" then
                sx, sy = 0, (i - 1) * step
            elseif growDir == "DOWN" then
                sx, sy = 0, -(i - 1) * step
            else
                sx = sx + (i - 1) * step
            end
            ic:ClearAllPoints()
            ic:SetPoint(position, f, position, offX + sx, offY + sy)
            ic:Show()
        elseif ic then
            ic:Hide()
        end
    end
end

-- range fade (range.enabled/outOfRangeAlpha) — apply reduced alpha to demo frames.
local function ApplyRangeFade(f, range, outOfRange)
    if range and range.enabled and outOfRange then
        f:SetAlpha(tonumber(range.outOfRangeAlpha) or 0.4)
    else
        f:SetAlpha(1)
    end
end

-- pets (pets.enabled/width/height/anchorTo) — one attached mock pet frame.
local function ApplyPets(f, pets, hasPet)
    if not pets or not pets.enabled or not hasPet then
        if f._petFrame then f._petFrame:Hide() end
        return
    end
    f._petFrame = f._petFrame or CreateFrame("Frame", nil, f, "BackdropTemplate")
    local pet = f._petFrame
    pet:SetSize(tonumber(pets.width) or 80, tonumber(pets.height) or 16)
    pet:ClearAllPoints()
    local anchorTo = pets.anchorTo or "BOTTOM"
    if anchorTo == "RIGHT" then
        pet:SetPoint("TOPLEFT", f, "TOPRIGHT", 2, 0)
    elseif anchorTo == "LEFT" then
        pet:SetPoint("TOPRIGHT", f, "TOPLEFT", -2, 0)
    else
        pet:SetPoint("TOP", f, "BOTTOM", 0, -2)
    end
    ns.SkinBase.ApplyPixelBackdrop(pet, 1, true, false, { 0, 0, 0, 1 }, { 0.15, 0.3, 0.15, 0.9 })
    pet._bar = pet._bar or pet:CreateTexture(nil, "ARTWORK")
    pet._bar:ClearAllPoints()
    pet._bar:SetPoint("TOPLEFT", 1, -1)
    pet._bar:SetPoint("BOTTOMRIGHT", -1, 1)
    pet._bar:SetColorTexture(0.2, 0.7, 0.2, 1)
    pet:Show()
end

-- Party target companion: mirrors groupframes_party_targets.lua's dimensions,
-- four-way anchor, gap and name visibility. It is ordinary frame chrome, not a
-- transient highlight, so the Highlights focus chip never suppresses it.
local function ApplyCompanionAnchor(frame, memberFrame, cfg)
    local gap = tonumber(cfg and cfg.anchorGap) or 2
    local side = (cfg and cfg.anchorTo) or "BOTTOM"
    frame:ClearAllPoints()
    if side == "TOP" then
        frame:SetPoint("BOTTOM", memberFrame, "TOP", 0, gap)
    elseif side == "RIGHT" then
        frame:SetPoint("LEFT", memberFrame, "RIGHT", gap, 0)
    elseif side == "LEFT" then
        frame:SetPoint("RIGHT", memberFrame, "LEFT", -gap, 0)
    else
        frame:SetPoint("TOP", memberFrame, "BOTTOM", 0, -gap)
    end
end
Driver._ApplyCompanionAnchor = ApplyCompanionAnchor

local function ApplyPartyTarget(f, member, cfg, general, contextMode)
    if contextMode ~= "party" or not cfg or cfg.enabled ~= true then
        if f._partyTargetPreview then f._partyTargetPreview:Hide() end
        return
    end

    local target = f._partyTargetPreview
    if not target then
        target = CreateFrame("Frame", nil, f, "BackdropTemplate")
        local C = GetChrome()
        if C then
            C.EnsureBackdrop(target, C.GetCachedBackdrop(
                "Interface\\Buttons\\WHITE8x8",
                "Interface\\Buttons\\WHITE8x8",
                1
            ))
        end
        target:SetBackdropBorderColor(0, 0, 0, 1)

        local hb = CreateFrame("StatusBar", nil, target)
        hb:SetPoint("TOPLEFT", target, "TOPLEFT", 1, -1)
        hb:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -1, 1)
        hb:SetMinMaxValues(0, 100)
        hb:EnableMouse(false)
        target.healthBar = hb

        local name = hb:CreateFontString(nil, "OVERLAY")
        name:SetPoint("LEFT", hb, "LEFT", 3, 0)
        name:SetPoint("RIGHT", hb, "RIGHT", -3, 0)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        target.nameText = name
        f._partyTargetPreview = target
    end

    local C = GetChrome()
    if C then
        C.SetBackdropFillColor(target, 0, 0, 0, 1)
        C.ApplyStatusBarTexture(target.healthBar, nil, general)
    end
    target:SetSize(tonumber(cfg.width) or 120, tonumber(cfg.height) or 22)
    ApplyCompanionAnchor(target, f, cfg)
    target.healthBar:SetValue(68)
    target.healthBar:SetStatusBarColor(0.65, 0.2, 0.2, 1)
    CJKFont(target.nameText, FontPath(general), tonumber(general and general.fontSize) or 11,
        (general and general.fontOutline) or "OUTLINE")
    target.nameText:SetText((member and member.name or "Member") .. " Target")
    if cfg.showName == false then target.nameText:Hide() else target.nameText:Show() end
    target:Show()
end

-- Orchestrator: style a mock tile from EVERY group-frame setting.
-- Step 1 hands the tile to the LIVE builder (ns.QUI_GroupFrameChrome.Apply);
-- steps 2+ add only what a preview owns -- fabricated values, demo gating and
-- the preview-only extras. `member._sampleTarget/._sampleThreat/._sampleDispel/
-- ._samplePet/._sampleOOR/._sampleIndicators` are representative flags set by
-- the roster builder so a single tile demos each single-unit feature.
local function ApplyFrameSettings(f, member, vdb, gfdb, contextMode)
    local general = vdb.general or {}
    local health  = vdb.health or {}
    local power   = vdb.power or {}
    local F = Driver._state.filter or Driver._NormalizeFilter(nil)

    local Chrome = GetChrome()
    if not Chrome or not Chrome.Apply then return end

    -- 1. The shared builder: skeleton + every settings-driven geometry, font,
    --    texture and frame level. Identical call the live frames get, including
    --    the state table it reseeds -- tiles are POOLED, so without that reseed
    --    the second refresh would leave a role-filtered tile with the power-bar
    --    gap this pass just rewrote from the global setting.
    f._chromeState = f._chromeState or {}
    Chrome.Apply(f, vdb, f._chromeState)

    -- 2. Per-unit power visibility (role filters) -- live does this from
    --    UpdatePower; it re-anchors the health bar and rewrites f._bottomPad.
    local showPower = PowerVisibleFor(member, power)
    Chrome.ResizeHealthForPower(f, vdb, showPower, f._chromeState)
    f._isVerticalFill = (health.healthFillDirection == "VERTICAL")

    -- 3. Fabricated values + content.
    ApplyBarValues(f, member, general, power, showPower)
    ApplyHealthOverlays(f, member, vdb)
    -- Name, level and health text are baseline frame chrome, not highlights:
    -- focus chips may hide demo effects but must never erase ordinary text.
    ApplyTextContent(f, member, vdb.name or {})
    ApplyHealthText(f, health)
    ApplyPortraitTint(f)
    ApplyRoleIcon(f, member, vdb.indicators or {}, F.indicators ~= false)
    ApplyIndicators(f, vdb.indicators or {}, F.indicators ~= false, member._sampleIndicators)
    ApplyThreat(f, vdb.indicators or {}, member._sampleThreat == true and F.threat ~= false)
    ApplyTargetHighlight(f, vdb.healer,
        member._sampleTarget == true and F.targetHighlight ~= false)
    local sampleDispel = (F.dispel ~= false) and member._sampleDispel or nil
    ApplyDispelOverlay(f, vdb.healer, sampleDispel)
    ApplyCleanseGlow(f, vdb.healer, sampleDispel ~= nil)

    -- 4. Preview-only extras (no live counterpart on the frame itself).
    ApplyTargetedSpells(f, vdb.targetedSpells, member._sampleTargetedSpells,
        F.targetedSpells ~= false)
    ApplyPets(f, vdb.pets, member._samplePet == true and F.pets ~= false)
    ApplyPartyTarget(f, member, vdb.targetFrames, general, contextMode)
    ApplyRangeFade(f, vdb.range, member._sampleOOR == true and F.range ~= false)
end
Driver._ApplyFrameSettings = ApplyFrameSettings

---------------------------------------------------------------------------
-- ASSEMBLY: aura render, lifecycle, ticker, spotlight, seams
---------------------------------------------------------------------------
local state = Driver._state
local AURA_PREVIEW_LIMIT = 5

-- AURA ELEMENTS: renderer-owned modes use fabricated matches; engine-owned
-- containers use placeholders because they require real unit auras. ----------
local function GetPreviewSpecID()
    local idx = GetSpecialization and GetSpecialization()
    if idx and GetSpecializationInfo then return (GetSpecializationInfo(idx)) end
    return nil
end

-- healthTint tracked previews as a health-bar tint (not an icon slot), so it
-- rides the real renderer and needs a fake match keyed by a tracked spell for
-- RenderHealthTint to find an "active" aura. The icon field is irrelevant for a
-- tint, so a helpful placeholder is fine.
local function BuildHealthTintMatches(element, now)
    local out = {}
    local spells = element.spells
    if type(spells) == "table" then
        for i, sid in ipairs(spells) do
            local icon = ResolveSpellIcon(sid)
                or PREVIEW_BUFF_ICONS[((i - 1) % #PREVIEW_BUFF_ICONS) + 1]
            out[sid] = MakeFakeAura(icon, i, false, now, sid)
        end
    end
    return out
end

-- Placeholder pin that mirrors the LIVE unit-frame path (RenderIcon,
-- groupframes_aura_render.lua) instead of the generic default:
--   * icon corner = IconLayout.GetIconAnchorForGrow(anchor, grow). The generic
--     derivation takes its horizontal side from the grow direction alone, so a
--     column-growing strip on a RIGHT-side anchor pinned the wrong corner.
--   * BOTTOM-anchored strips add frame._bottomPad so they clear the power bar.
local function MakeAuraPin(f)
    return function(element)
        local G = ns.AuraGlue
        if not (G and G.ElementProfile) then return nil end
        local p = G.ElementProfile(element)
        local anchor = element.anchor or "TOPLEFT"
        local offY = tonumber(element.offsetY) or 0
        if anchor:find("BOTTOM") then offY = offY + (f._bottomPad or 0) end
        local IL = ns.QUI_GroupFrameIconLayout
        local corner = IL and IL.GetIconAnchorForGrow
            and IL.GetIconAnchorForGrow(anchor, p.grow) or nil
        return p, anchor, tonumber(element.offsetX) or 0, offY, corner
    end
end
Driver._MakeAuraPin = MakeAuraPin

-- Real spell art for tracked placeholders: the element names its spells, so a
-- preview has no excuse for question marks. Filter strips stay generic -- their
-- content is whatever the engine's filter matches at runtime, which is exactly
-- what the placeholder's "worst-case footprint" is standing in for.
local function MakePlaceholderIcon(element, index)
    if element.mode ~= "tracked" then return nil end
    local spells = element.spells
    local sid = type(spells) == "table" and spells[index] or nil
    return sid and ResolveSpellIcon(sid) or nil
end
Driver._MakePlaceholderIcon = MakePlaceholderIcon

-- WHICH ELEMENTS THE RENDERER DRAWS is not the preview's call: it asks the live
-- module (QUI_GFA.EngineRendersElement). At runtime only missingRaidBuff and the
-- healthTint/border feeders go through ns.QUI_GroupFrameAuraRender; filter strips
-- and tracked icon/square/bar are drawn by a secure CustomAuraContainer that the
-- ENGINE fills from real unit auras. A preview cannot feed that container fake
-- data, so those elements get placeholders (ns.AuraPreview) laid out with the
-- live layout math -- and dispatching them through the renderer instead would
-- resurrect the pre-cutover path the live release reconciliation tears down.
local function RenderFrameAuras(f, auras, now)
    local Render  = ns.QUI_GroupFrameAuraRender
    local Model   = ns.QUI_GroupFramesAuraModel
    local Preview = ns.AuraPreview
    local GFA     = ns.QUI_GroupFrameAuras
    if not Render or not Model or not Model.ActiveElementsForSpec then return end
    if auras and Model.EnsureSeeded then Model.EnsureSeeded(auras, state.contextMode) end
    -- Placeholders live on the dedicated host at the shared live container
    -- level, never on `f` itself -- see CreateMockFrame.
    local auraHost = f._auraHost or f

    if not auras or auras.enabled == false then
        if Render.ReleaseAll then Render:ReleaseAll(f) end
        if Preview then Preview.Hide(auraHost) end
        f._previewAuraWork = nil
        f._previewAuraIDs = nil
        return
    end

    -- Preview the bucket the EDITOR is on (per-context), not the player's live
    -- spec -- otherwise editing "All Specs" while your current spec has its own
    -- bucket shows the wrong auras. nil (no editor push yet) falls back to live
    -- spec so the preview is sensible before the auras tab is ever opened.
    local bucketKey = state.previewBucket and state.previewBucket[state.contextMode]
    if bucketKey == nil then bucketKey = GetPreviewSpecID() end
    -- ActiveElementsForSpec drops `enabled == false` elements, so a disabled
    -- element is absent here: the renderer release pass below reclaims its
    -- widgets and AuraPreview hides its surplus placeholders.
    local elements = Model.ActiveElementsForSpec(auras, bucketKey)

    local previewElements = {}
    local work, current = {}, {}
    for _, element in ipairs(elements) do
        local engineDrawn = GFA and GFA.EngineRendersElement
            and GFA.EngineRendersElement(element) or false
        if engineDrawn then
            local matches
            if element.mode == "missingRaidBuff" then
                matches = Driver._BuildMissingRaidBuffMatches(element, now)
            else
                -- healthTint / border: frame-level feeders keyed by spellID.
                matches = BuildHealthTintMatches(element, now)
            end
            work[#work + 1] = { element = element, matches = matches }
            if element.id then current[element.id] = true end
            Render:Dispatch(f, element, matches)
        else
            previewElements[#previewElements + 1] = element
        end
    end
    if Preview then
        Preview.Show(auraHost, previewElements, {
            resolve = MakeAuraPin(f),
            icon = MakePlaceholderIcon,
        })
    end

    -- Release any renderer-owned element from last pass that is gone now
    -- (disabled, deleted, moved bucket, or flipped to a container display type).
    local prev = f._previewAuraIDs
    if prev then
        for id in pairs(prev) do
            if not current[id] then Render:Release(f, id) end
        end
    end
    f._previewAuraWork = work
    f._previewAuraIDs = current
end
Driver._RenderFrameAuras = RenderFrameAuras

-- FRAME DIMENSIONS (mirror groupframes.lua GetFrameDimensions) --------------
local function GetMockDimensions(vdb, contextMode, count)
    local Chrome = GetChrome()
    if not Chrome or not Chrome.FrameDimensions then return 200, 40 end
    return Chrome.FrameDimensions(vdb, Chrome.DimensionMode(count, contextMode))
end

-- Teardown helper: hide every pooled frame (frames are POOLED, never destroyed,
-- so a refresh reuses them rather than orphaning the old set).
local function ReleaseFrames()
    local Render = ns.QUI_GroupFrameAuraRender
    for _, f in ipairs(state.framePool or {}) do
        if Render and Render.ReleaseAll then Render:ReleaseAll(f) end
        f:Hide()
    end
    state.frames = {}
    state.auraFrames = {}
end

-- Pick representative frames to demo single-frame features (threat/target/
-- dispel/pet/out-of-range). Match the value each Apply* function checks for.
--
-- INDICATOR_DEMO does the same for the six transient corner indicators: one
-- tile each so the preview shows what the runtime shows (a ready check on one
-- unit, a pending res on another) instead of three CENTER icons stacked on
-- every tile. Tiles that share a slot use anchors that cannot collide (leader
-- TOP + target marker TOPRIGHT).
local INDICATOR_DEMO = {
    [1] = { leader = true, targetMarker = true },
    [2] = { phase = true },
    [3] = { readyCheck = true },
    [4] = { resurrection = true },
    [5] = { summon = true },
}
Driver._INDICATOR_DEMO = INDICATOR_DEMO

-- Put an attached Pet sample on the roster's OUTER edge whenever its anchor
-- points along the party growth axis. A BOTTOM pet on the first tile of a
-- DOWN-growing party otherwise lands directly on top of tile 2 and looks like
-- an unexplained full-frame overlay.
function Driver._EdgeSampleIndex(count, grow, anchorTo)
    if not count or count < 1 then return nil end
    grow = grow or "DOWN"
    anchorTo = anchorTo or "BOTTOM"
    if (grow == "DOWN" and anchorTo == "BOTTOM")
        or (grow == "UP" and anchorTo == "TOP")
        or (grow == "RIGHT" and anchorTo == "RIGHT")
        or (grow == "LEFT" and anchorTo == "LEFT")
    then
        return count
    end
    return 1
end

local function AssignSampleFlags(roster, count, vdb, layout)
    if count >= 1 then roster[1]._sampleTarget = true end
    local petCfg = vdb and vdb.pets
    local petIndex = Driver._EdgeSampleIndex(
        count,
        ResolveGrow(layout),
        petCfg and petCfg.anchorTo
    )
    if petIndex then roster[petIndex]._samplePet = true end
    if count >= 2 then roster[2]._sampleThreat = true end
    if count >= 3 then roster[3]._sampleDispel = "Magic" end
    if count >= 4 then roster[4]._sampleOOR = true end
    if count >= 2 then roster[2]._sampleTargetedSpells = 1 end
    if count >= 4 then roster[4]._sampleTargetedSpells = 2 end
    for i = 1, math.min(count, #INDICATOR_DEMO) do
        roster[i]._sampleIndicators = INDICATOR_DEMO[i]
    end
end
Driver._AssignSampleFlags = AssignSampleFlags

-- ANIMATION TICKER ---------------------------------------------------------
local function OscillateHealth(base, phase, clock)
    local v = base + math.sin((clock + phase) * 0.6) * 18
    if v < 1 then v = 1 elseif v > 100 then v = 100 end
    return v
end

local function LoopMatchSet(matches, now)
    for _, data in pairs(matches) do
        if type(data) == "table" and data.expirationTime and data.duration then
            if data.expirationTime - now <= 0 then
                data.expirationTime = now + data.duration
            end
        end
    end
end

local function AdvanceAuras(now)
    local Render = ns.QUI_GroupFrameAuraRender
    if not Render then return end
    for _, f in ipairs(state.auraFrames) do
        local work = f._previewAuraWork
        if work then
            for _, w in ipairs(work) do
                LoopMatchSet(w.matches, now)
                Render:Dispatch(f, w.element, w.matches)
            end
        end
    end
end

function Driver._EnsureTicker()
    if state.ticker then
        -- The options window (and our host) is rebuilt on theme change; re-parent
        -- so the OnUpdate keeps firing instead of riding a torn-down host.
        if state.host and state.ticker:GetParent() ~= state.host then
            state.ticker:SetParent(state.host)
        end
        state.ticker:Show()
        return state.ticker
    end
    state.ticker = CreateFrame("Frame", nil, state.host)
    state.ticker._auraAccum = 0
    state.ticker:SetScript("OnUpdate", function(self, elapsed)
        local Render = ns.QUI_GroupFrameAuraRender
        state.clock = state.clock + elapsed
        local now = (GetTime and GetTime()) or state.clock
        for _, f in ipairs(state.frames) do
            local pct = OscillateHealth(f._baseHealthPct or 100, f._phase or 0, state.clock)
            f._healthPct = pct
            if f.healthBar then f.healthBar:SetValue(pct) end
            if Render and f._quiAuraRenderHealthTintColor and Render.SyncHealthBarTint then
                Render:SyncHealthBarTint(f, pct, true)
            end
            if f._UpdateHealthText then f._UpdateHealthText(pct) end
        end
        self._auraAccum = self._auraAccum + elapsed
        if self._auraAccum >= 0.1 then
            self._auraAccum = 0
            AdvanceAuras(now)
        end
    end)
    return state.ticker
end

-- SPOTLIGHT (raid only) — a separate mock cluster shown when enabled.
-- gridRight = horizontal extent of the main grid (root is sized 1x1, so we
-- must NOT read root:GetWidth()).
function Driver._SpotlightOffset(index, w, h, spacing, orientation, grow)
    local n = index - 1
    local horizontal = orientation == "HORIZONTAL" or grow == "LEFT" or grow == "RIGHT"
    if horizontal then
        local dx = n * (w + spacing)
        if grow == "LEFT" then dx = -dx end
        return dx, 0
    end
    local dy = n * (h + spacing)
    if grow ~= "UP" then dy = -dy end
    return 0, dy
end

function Driver._RenderSpotlight(root, vdb, gfdb, now, gridRight)
    state.spotlightPool = state.spotlightPool or {}
    state.spotlightFrames = {}

    local sp = vdb.spotlight
    if not sp or sp.enabled ~= true then
        local Render = ns.QUI_GroupFrameAuraRender
        for _, f in ipairs(state.spotlightPool) do
            if Render and Render.ReleaseAll then Render:ReleaseAll(f) end
            f:Hide()
        end
        return
    end

    local w = tonumber(sp.frameWidth) or 180
    local h = tonumber(sp.frameHeight) or 36
    local spacing = tonumber(sp.spacing) or 2
    local grow = sp.growDirection or "DOWN"
    local orientation = sp.orientation
        or ((grow == "LEFT" or grow == "RIGHT") and "HORIZONTAL" or "VERTICAL")
    local sample
    if (sp.filterMode or "ROLE") == "NAME" then
        sample = {}
        for name in tostring(sp.nameList or ""):gmatch("[^,]+") do
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" then
                sample[#sample + 1] = {
                    role = "DAMAGER", class = "MAGE", name = name, healthPct = 90,
                }
            end
            if #sample >= 4 then break end
        end
        if #sample == 0 then
            sample[1] = { role = "DAMAGER", class = "MAGE", name = "Pinned1", healthPct = 90 }
        end
    else
        sample = {}
        if sp.filterTank ~= false then
            sample[#sample+1] = { role = "TANK", class = "WARRIOR", name = "Ironwall", healthPct = 88 }
        end
        if sp.filterHealer then
            sample[#sample+1] = { role = "HEALER", class = "PRIEST", name = "Healena", healthPct = 76 }
        end
        if sp.filterDamager then
            sample[#sample+1] = { role = "DAMAGER", class = "MAGE", name = "Frostina", healthPct = 68 }
        end
        if #sample == 0 then
            sample[1] = { role = "TANK", class = "PALADIN", name = "Lightbeam", healthPct = 82 }
        end
    end

    local startX = (tonumber(gridRight) or 200) + 30
    for i, m in ipairs(sample) do
        local f = state.spotlightPool[i]
        if not f then
            f = Driver._CreateMockFrame(root, "quiPreviewSpot" .. i)
            state.spotlightPool[i] = f
        elseif f:GetParent() ~= root then
            f:SetParent(root)
        end
        f._phase = i * 0.9
        f:SetSize(w, h)
        local ox, oy = Driver._SpotlightOffset(i, w, h, spacing, orientation, grow)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", root, "TOPLEFT", startX + ox, oy - 4)
        f:Show()
        Driver._ApplyFrameSettings(f, m, vdb, gfdb, "raid")
        RenderFrameAuras(f, Driver._AuraSettingsForFilter(vdb, state.filter), now)
        state.auraFrames[#state.auraFrames + 1] = f
        state.spotlightFrames[i] = f
    end
    local Render = ns.QUI_GroupFrameAuraRender
    for i = #sample + 1, #state.spotlightPool do
        local f = state.spotlightPool[i]
        if Render and Render.ReleaseAll then Render:ReleaseAll(f) end
        f:Hide()
    end
end

-- One "Group N" label per raid subgroup block in the preview, anchored to the
-- block's first frame (block origin). Mirrors the live per-group header. Gated to
-- raid + groupBy==GROUP + showGroupNumber; pooled/hidden otherwise. Labels live on
-- a high-level overlay host so they sit above the member frames (a fontstring on
-- root would be buried under the child frames -- same lesson as the _textFrame fix).
function Driver._RenderGroupLabels(vdb, layout, count)
    state.groupLabelPool = state.groupLabelPool or {}
    local pool = state.groupLabelPool
    local s = vdb and vdb.groupNumber
    local isRaid = (state.contextMode == "raid")
    local grouped = ((layout and layout.groupBy) or "GROUP") == "GROUP"
    local show = isRaid and grouped and s and s.showGroupNumber == true

    if not show then
        for i = 1, #pool do if pool[i] then pool[i]:Hide() end end
        return
    end

    local host = state.groupLabelHost
    if not host then
        host = CreateFrame("Frame", nil, state.root)
        host:SetAllPoints(state.root)
        state.groupLabelHost = host
    end
    host:SetFrameLevel((state.root:GetFrameLevel() or 0) + 100)
    host:Show()

    local perGroup = 5
    local font = FontPath(vdb.general or {})
    local size = tonumber(s.groupNumberFontSize) or 12
    local offX = tonumber(s.groupNumberOffsetX) or 0
    local offY = tonumber(s.groupNumberOffsetY) or 0
    local c = s.groupNumberTextColor or { 1, 1, 1, 1 }

    -- Place the label OUTSIDE the block on the chosen side (TOP anchor => label's
    -- BOTTOM pinned to the block's TOP, so it sits above the group, not inside the
    -- first unit). Mirrors the live UpdateRaidGroupLabel mapping. CENTER stays inside.
    local anchor = s.groupNumberAnchor or "TOPRIGHT"
    local selfPoint, blockPoint = anchor, anchor
    if anchor == "CENTER" then
        selfPoint, blockPoint = "CENTER", "CENTER"
    elseif anchor:find("TOP") then
        selfPoint = (anchor:gsub("TOP", "BOTTOM"))
    elseif anchor:find("BOTTOM") then
        selfPoint = (anchor:gsub("BOTTOM", "TOP"))
    elseif anchor == "LEFT" then
        selfPoint = "RIGHT"
    elseif anchor == "RIGHT" then
        selfPoint = "LEFT"
    end

    local groups = math.ceil(count / perGroup)
    for gi = 1, groups do
        local originFrame = state.frames[(gi - 1) * perGroup + 1]
        local lbl = pool[gi]
        if originFrame then
            if not lbl then
                lbl = host:CreateFontString(nil, "OVERLAY")
                pool[gi] = lbl
            end
            CJKFont(lbl, font, size, "OUTLINE")
            lbl:SetText(((ns.L and ns.L["Group"]) or "Group") .. " " .. gi)
            lbl:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
            lbl:SetWordWrap(false)
            lbl:ClearAllPoints()
            lbl:SetPoint(selfPoint, originFrame, blockPoint, offX, offY)
            lbl:Show()
        elseif lbl then
            lbl:Hide()
        end
    end
    for gi = groups + 1, #pool do
        if pool[gi] then pool[gi]:Hide() end
    end
end

-- LIFECYCLE ----------------------------------------------------------------
function Driver.Refresh(contextMode)
    if not state.host then return end
    state.contextMode = (contextMode == "raid") and "raid" or "party"
    state.filter = Driver._NormalizeFilter(state.filter)
    local gfdb = Driver._GetGFDB()
    local vdb = Driver._GetContextDB(gfdb, state.contextMode)
    if not vdb then return end

    local count = 5
    if state.contextMode == "raid" then
        local tm = (gfdb and gfdb.testMode) or {}
        count = Driver._SnapRaidCount(tm.raidCount)
    end

    local root = Driver._EnsureRoot()
    -- Mock frames are POOLED, not recreated each refresh. Refresh fires on every
    -- settings onChange (every slider tick); creating fresh frames would orphan
    -- the old ones (WoW frames can't be destroyed) and leak. Reuse pool[1..count]
    -- and hide the surplus.
    state.framePool = state.framePool or {}
    state.frames = {}
    state.auraFrames = {}

    local layout = vdb.layout or {}
    local roster = Driver._PrepareRoster(state.contextMode, count, layout, gfdb)
    count = #roster
    AssignSampleFlags(roster, count, vdb, layout)
    local w, h = GetMockDimensions(vdb, state.contextMode, count)
    local positions = Driver._ComputeGridPositions(state.contextMode, count, layout, w, h)

    local pad = 4
    local minX, maxX, maxY = math.huge, -math.huge, -math.huge
    for i = 1, count do
        local px, py = positions[i].x, positions[i].y
        if px < minX then minX = px end
        if px > maxX then maxX = px end
        if py > maxY then maxY = py end
    end
    if minX == math.huge then minX = 0 end
    if maxX == -math.huge then maxX = 0 end
    if maxY == -math.huge then maxY = 0 end

    local Render = ns.QUI_GroupFrameAuraRender
    local now = (GetTime and GetTime()) or 0
    for i = 1, count do
        local f = state.framePool[i]
        if not f then
            f = Driver._CreateMockFrame(root, "quiPreview" .. i)
            state.framePool[i] = f
        elseif f:GetParent() ~= root then
            f:SetParent(root)
        end
        f._phase = (i - 1) * 0.7
        f:SetSize(w, h)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", root, "TOPLEFT",
            (positions[i].x - minX) + pad, (positions[i].y - maxY) - pad)
        f:Show()
        Driver._ApplyFrameSettings(f, roster[i], vdb, gfdb, state.contextMode)
        state.frames[i] = f
        if i <= AURA_PREVIEW_LIMIT then
            state.auraFrames[#state.auraFrames + 1] = f
            RenderFrameAuras(f, Driver._AuraSettingsForFilter(vdb, state.filter), now)
        end
    end

    Driver._RenderGroupLabels(vdb, layout, count)

    -- Hide pooled frames beyond the current count (e.g. raid 25 -> party 5).
    for i = count + 1, #state.framePool do
        local f = state.framePool[i]
        if f then
            if Render and Render.ReleaseAll then Render:ReleaseAll(f) end
            f:Hide()
        end
    end

    -- Always call _RenderSpotlight: on party (or raid with spotlight disabled)
    -- it self-guards and clears any stale spotlight frames left from a prior
    -- raid refresh, so a raid->party switch doesn't leave them on screen.
    local gridRight = (maxX - minX) + w + pad
    Driver._RenderSpotlight(root, vdb, gfdb, now, gridRight)

    root:SetSize(1, 1)   -- the surface measures the descendant union, not root size
    if state.onBuilt then
        state.onBuilt(nil, { previewCell = root })
    end
end

-- Lightweight refresh used by the aura editor: re-dispatch ONLY the aura
-- preview tiles, skipping the full per-tile restyle in Refresh (up to 40 tiles
-- × ~15 Apply* subsystems). The aura editor only mutates aura element config --
-- never tile geometry/health/etc -- so the heavy restyle is wasted work on
-- every keystroke/slider tick. Falls back to a full Refresh when the preview
-- has not been built yet (no aura tiles to reuse).
function Driver.RefreshAuras()
    if not state.host then return end
    if not state.auraFrames or #state.auraFrames == 0 then
        Driver.Refresh(state.contextMode)
        return
    end
    local gfdb = Driver._GetGFDB()
    local vdb = Driver._GetContextDB(gfdb, state.contextMode)
    if not vdb then return end
    local now = (GetTime and GetTime()) or 0
    local auras = Driver._AuraSettingsForFilter(vdb, state.filter)
    for _, f in ipairs(state.auraFrames) do
        RenderFrameAuras(f, auras, now)
    end
end

function Driver.Build(host)
    state.host = host
    Driver._EnsureRoot()
    Driver._EnsureTicker()
    Driver.Refresh(state.contextMode)
end

function Driver.Teardown()
    ReleaseFrames()
    if state.spotlightPool then
        for _, f in ipairs(state.spotlightPool) do f:Hide(); f:SetParent(nil) end
        state.spotlightPool = {}
    end
    state.spotlightFrames = {}
    if state.root then state.root:Hide() end
    if state.ticker then state.ticker:Hide() end
end

-- GLOBAL SEAMS — the options surface calls these (replaces the old composer
-- definitions). Guarded callers tolerate nil before this LOD file loads.
_G.QUI_BuildGroupFramePreview = function(host, contextMode)
    Driver.Build(host)
    Driver.Refresh(contextMode)
end
-- Refresh coalescer: a single discrete settings change can fan out into several
-- onChange pings within one frame (editor rebuild + per-widget callbacks +
-- section reflow). Collapse them into one rebuild on the next frame. A queued
-- full refresh supersedes an aura-only one.
local function FlushPreviewRefresh()
    state._refreshScheduled = false
    local kind = state._pendingRefresh
    state._pendingRefresh = nil
    local cm = state._pendingContext
    state._pendingContext = nil
    if kind == "full" then
        Driver.Refresh(cm or state.contextMode)
    elseif kind == "auras" then
        Driver.RefreshAuras()
    end
end

local function ScheduleRefresh(kind, contextMode)
    if contextMode then state._pendingContext = contextMode end
    if kind == "full" or state._pendingRefresh == "full" then
        state._pendingRefresh = "full"
    else
        state._pendingRefresh = "auras"
    end
    if state._refreshScheduled then return end
    state._refreshScheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, FlushPreviewRefresh)
    else
        FlushPreviewRefresh()
    end
end

-- aurasOnly=true requests the lightweight aura-tile-only rebuild (see
-- Driver.RefreshAuras); omitted/false does the full per-tile restyle. Kept a
-- single seam (no new _G global) for the assignment ratchet.
-- bucketKey (optional): the spec bucket the auras editor currently has selected
-- ("*" = All Specs, or a specID). Set synchronously here so the coalesced flush
-- reads the latest; omitted/nil leaves the prior binding untouched.
_G.QUI_RefreshGroupFramePreview = function(contextMode, aurasOnly, bucketKey)
    if bucketKey ~= nil then
        local cm = (contextMode == "raid") and "raid" or "party"
        state.previewBucket = state.previewBucket or {}
        state.previewBucket[cm] = bucketKey
    end
    ScheduleRefresh(aurasOnly and "auras" or "full", contextMode or state.contextMode)
end
_G.QUI_SetGroupFramePreviewObserver = function(fn)
    state.onBuilt = fn
end
_G.QUI_SetGroupFramePreviewFilter = function(tbl)
    state.filter = Driver._NormalizeFilter(tbl)
    Driver.Refresh(state.contextMode)
end
_G.QUI_GetGroupFramePreviewFilter = function()
    return Driver._NormalizeFilter(state.filter)
end

return Driver
