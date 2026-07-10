--[[
    QUI Nameplates — aura engine (debuff/buff/CC rows + filter model).

    Sources & filtering are SERVER-SIDE: filter strings classify on the C
    side ("HARMFUL|INCLUDE_NAME_PLATE_ONLY" etc.), membership tests go
    through C_UnitAuras.IsAuraFilteredOutByInstanceID. On top of that, QUI's
    own lists (per-channel allow/block, mine-only, important emphasis,
    per-context enables) resolve in Lua from clean spellIDs — spellId on
    added payloads is treated as possibly secret and gated with
    IsSecretValue before any table lookup.

    Ordering under secrets: expiration is secret so there is NO client sort.
    C_UnitAuras.GetUnitAuraInstanceIDs returns server-ordered IDs; rebuilds
    intersect that order with the locally filtered ID set.

    Delta processing rides the core dispatcher's "nameplate" tier
    (payload contract: updateInfo nil = full update; delta tables are POOLED
    and wiped after dispatch — everything kept is copied here). Pure
    duration/stack updates take an in-place fast path; rebuilds are
    per-channel and rate-limited to one per plate per frame; token recycling
    triggers a full rescan from the driver.

    Rendering, ZERO Lua timers: duration objects drive Cooldown widgets
    (SetCooldownFromDurationObject + C-side countdown formatter), the
    permanent-aura (0,0) strobe is masked via SetAlphaFromBoolean(IsZero),
    stacks come from GetAuraApplicationDisplayCount straight into SetText,
    dispel borders from GetAuraDispelTypeColor through a color curve, and
    pandemic glow alpha evaluates EvaluateRemainingPercent(stepCurve) on a
    shared refcounted 5 Hz ticker.

    12.1 forward path: RenderChannel is the separable "arrange N icon
    frames" step — Blizzard's AuraContainer replaces the delta path there,
    gated on a capability constant, without touching the filter model.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local Helpers = ns.Helpers
local UIKit = ns.UIKit
local QUICore = ns.Addon
local IsSecretValue = Helpers.IsSecretValue

local type = type
local pcall = pcall
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local CreateFrame = CreateFrame

local NPAuras = {}
NP.Auras = NPAuras

local CHANNELS = { "debuffs", "buffs", "cc" }

---------------------------------------------------------------------------
-- FILTER MODEL (pure functions — unit-tested offline)
---------------------------------------------------------------------------
-- Server-side filter string per channel. Deliberately NOT the Blizzard
-- debuffList piggyback: QUI owns its filter model end to end.
function NPAuras.ComposeFilter(channelKey, auraSettings)
    auraSettings = auraSettings or {}
    if channelKey == "debuffs" then
        local filter = "HARMFUL|INCLUDE_NAME_PLATE_ONLY"
        if auraSettings.mineOnly ~= false then
            filter = filter .. "|PLAYER"
        end
        return filter
    elseif channelKey == "buffs" then
        return "HELPFUL|INCLUDE_NAME_PLATE_ONLY"
    elseif channelKey == "cc" then
        return "HARMFUL|CROWD_CONTROL"
    end
    return nil
end

-- Local list resolution from a CLEAN spellID. Returns:
--   "block"     — hidden by block list
--   "allow"     — allow list exists and contains it
--   "excluded"  — allow list exists and does NOT contain it
--   "important" — on the important list (emphasized)
--   "default"   — no list opinion
function NPAuras.ResolveSpellLists(spellId, channelSettings, importantList)
    if type(spellId) ~= "number" then return "default" end
    if channelSettings then
        local block = channelSettings.blockList
        if block and block[spellId] then return "block" end
        local allow = channelSettings.allowList
        if allow and next(allow) ~= nil then
            if allow[spellId] then
                if importantList and importantList[spellId] then return "important" end
                return "allow"
            end
            return "excluded"
        end
    end
    if importantList and importantList[spellId] then return "important" end
    return "default"
end

-- Per-context enable (world/dungeon/raid), pure over the cached context.
function NPAuras.IsContextEnabled(auraSettings, instanceKind)
    auraSettings = auraSettings or {}
    if instanceKind == "raid" then
        return auraSettings.enableRaid ~= false
    elseif instanceKind == "dungeon" then
        return auraSettings.enableDungeon ~= false
    end
    return auraSettings.enableWorld ~= false
end

---------------------------------------------------------------------------
-- CURVES (created lazily, shared by all plates)
---------------------------------------------------------------------------
local pandemicCurve
local function GetPandemicCurve()
    if pandemicCurve then return pandemicCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateCurve and Enum and Enum.LuaCurveType) then
        return nil
    end
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, 1)    -- under 30% remaining → glow on
    curve:AddPoint(0.3, 0)    -- above → off
    pandemicCurve = curve
    return curve
end

local dispelCurve
local function GetDispelCurve()
    if dispelCurve then return dispelCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum and Enum.LuaCurveType
        and Enum.DispelType and CreateColor) then
        return nil
    end
    local colors = {
        Magic   = { 0.2, 0.6, 1.0 },
        Curse   = { 0.6, 0.0, 1.0 },
        Disease = { 0.6, 0.4, 0.0 },
        Poison  = { 0.0, 0.6, 0.0 },
    }
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0, CreateColor(0, 0, 0, 0))
    for name, c in pairs(colors) do
        local enumVal = Enum.DispelType[name]
        if type(enumVal) == "number" then
            curve:AddPoint(enumVal, CreateColor(c[1], c[2], c[3], 1))
        end
    end
    dispelCurve = curve
    return curve
end

-- Opt-in decimal formatter (tenths under 3s). Off by default: Blizzard's
-- stock countdown formatting is what most users expect, and the rule
-- formatter's precision covered small icons entirely.
local countdownFormatter
local function GetCountdownFormatter()
    if countdownFormatter ~= nil then return countdownFormatter or nil end
    if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
        local ok, fmt = pcall(C_StringUtil.CreateNumericRuleFormatter, "%.1f", "%.0f", 3)
        countdownFormatter = ok and fmt or false
    else
        countdownFormatter = false
    end
    return countdownFormatter or nil
end

---------------------------------------------------------------------------
-- COUNTDOWN TEXT STYLING
---------------------------------------------------------------------------
-- The Cooldown widget owns the countdown FontString (engine-driven — Lua
-- never computes remaining time); we fetch the region once and restyle it.
local function FindCooldownText(cd)
    if not cd.GetRegions then return nil end
    local ok, r1, r2, r3, r4 = pcall(cd.GetRegions, cd)
    if not ok then return nil end
    for _, region in ipairs({ r1, r2, r3, r4 }) do
        local okType, objType = pcall(function() return region:GetObjectType() end)
        if okType and objType == "FontString" then
            return region
        end
    end
    return nil
end

-- Apply the user's duration-text settings to one icon holder.
local function ApplyDurationStyle(holder, auraSettings)
    local durS = (auraSettings and auraSettings.duration) or {}
    local cd = holder.cd
    if not cd then return end

    local show = durS.enabled ~= false
    pcall(cd.SetHideCountdownNumbers, cd, not show)

    if cd.SetCountdownFormatter then
        if durS.decimals == true then
            local fmt = GetCountdownFormatter()
            if fmt then pcall(cd.SetCountdownFormatter, cd, fmt) end
        else
            pcall(cd.SetCountdownFormatter, cd, nil)
        end
    end

    local text = holder.cdText
    if not text then
        text = FindCooldownText(cd)
        holder.cdText = text
    end
    if text and show then
        QUICore:ApplyFont(text, nil, durS.size or 12, UIKit.ResolveFontPath(), "OUTLINE")
        text:ClearAllPoints()
        text:SetPoint(
            durS.point or "CENTER",
            holder.iconFrame,
            durS.point or "CENTER",
            durS.offsetX or 0,
            durS.offsetY or 0)
    end
end

---------------------------------------------------------------------------
-- PANDEMIC TICKER (shared, refcounted 5 Hz)
---------------------------------------------------------------------------
local pandemicIcons = {}   -- [iconFrame] = durationObj
local pandemicCount = 0
local pandemicTicker

local function PandemicTick()
    local curve = GetPandemicCurve()
    if not curve then return end
    for icon, durObj in pairs(pandemicIcons) do
        if icon:IsShown() and icon.npGlow then
            local ok, alpha = pcall(durObj.EvaluateRemainingPercent, durObj, curve)
            if ok and alpha ~= nil then
                pcall(icon.npGlow.SetAlpha, icon.npGlow, alpha)
            end
        end
    end
end

local function PandemicAdd(icon, durObj)
    if pandemicIcons[icon] == durObj then return end
    if pandemicIcons[icon] == nil then
        pandemicCount = pandemicCount + 1
    end
    pandemicIcons[icon] = durObj
    if not pandemicTicker and C_Timer and C_Timer.NewTicker then
        pandemicTicker = C_Timer.NewTicker(0.2, PandemicTick)
    end
end

local function PandemicRemove(icon)
    if pandemicIcons[icon] == nil then return end
    pandemicIcons[icon] = nil
    pandemicCount = pandemicCount - 1
    if icon.npGlow then icon.npGlow:SetAlpha(0) end
    if pandemicCount <= 0 then
        pandemicCount = 0
        if pandemicTicker then
            pandemicTicker:Cancel()
            pandemicTicker = nil
        end
    end
end

---------------------------------------------------------------------------
-- ICON POOL (per plate, per channel; built on UIKit.CreateIcon)
---------------------------------------------------------------------------
local function CreateAuraIcon(plate, row)
    local holder = CreateFrame("Frame", nil, row)
    local iconFrame = UIKit.CreateIcon(holder, 24, 1, 0, 0, 0, 1)
    holder.iconFrame = iconFrame

    local cd = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
    cd:SetAllPoints(iconFrame)
    cd:SetDrawEdge(false)
    holder.cd = cd
    -- Countdown visibility/font/position/precision are user settings —
    -- applied by ApplyDurationStyle (at creation and on appearance refresh).
    ApplyDurationStyle(holder, NP.GetSettings().auras)

    -- Stack text on a separate carrier ABOVE the cooldown so the
    -- permanent-aura alpha mask on cd never hides the stacks.
    local stackCarrier = CreateFrame("Frame", nil, iconFrame)
    stackCarrier:SetAllPoints(iconFrame)
    stackCarrier:SetFrameLevel(cd:GetFrameLevel() + 1)
    holder.stackText = UIKit.CreateText(stackCarrier, 11, nil, "OUTLINE", "OVERLAY")
    holder.stackText:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 1, -1)

    -- Pandemic glow ring (alpha driven by the 5 Hz curve ticker).
    local glow = iconFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    glow:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 2, -2)
    glow:SetColorTexture(1, 0.35, 0.1, 0.45)
    glow:SetAlpha(0)
    holder.npGlow = glow
    iconFrame.npGlow = glow

    holder:Hide()
    return holder
end

local function GetRow(plate, channelKey)
    local rows = plate.npAuraRows
    if not rows then
        rows = {}
        plate.npAuraRows = rows
    end
    local row = rows[channelKey]
    if not row then
        row = CreateFrame("Frame", nil, plate)
        row:SetSize(1, 1)
        row.icons = {}
        rows[channelKey] = row
    end
    return row
end

---------------------------------------------------------------------------
-- BUILD / APPEARANCE
---------------------------------------------------------------------------
local OnNameplateAura -- defined below (delta consumer)

local subscribed = false
local function EnsureSubscribed()
    -- Deferred until the first plate is built: Subscribe lazily creates the
    -- dispatcher's 40 nameplate frames, which a disabled suite must not pay.
    if subscribed or not ns.AuraEvents then return end
    subscribed = true
    ns.AuraEvents:Subscribe("nameplate", OnNameplateAura)
end

function NPAuras.Build(plate)
    EnsureSubscribed()
    plate.npAuraSets = { debuffs = {}, buffs = {}, cc = {} }   -- [instanceID] = spellId|true
    plate.npAuraImportant = { debuffs = {}, buffs = {}, cc = {} } -- [instanceID] = true
    plate.npAuraDirty = {}
    plate.npAuraIconByID = {}
    for _, channelKey in ipairs(CHANNELS) do
        GetRow(plate, channelKey)
    end
end

-- Fallback anchors reproducing the classic layout when a channel has no
-- explicit position: debuffs above the bar (clearing the name), buffs above
-- those, cc beside the bar.
local ROW_ANCHOR_DEFAULTS = {
    debuffs = { point = "BOTTOM", relativePoint = "TOP", offsetX = 0, offsetY = 20 },
    buffs   = { point = "BOTTOM", relativePoint = "TOP", offsetX = 0, offsetY = 50 },
    cc      = { point = "RIGHT", relativePoint = "LEFT", offsetX = -4, offsetY = 0 },
}

-- Every row anchors to the HEALTH BAR (the stable reference): the row's
-- `point` pins to the bar's `relativePoint` with pixel-snapped offsets.
local function AnchorRow(plate, row, channelKey, ch)
    local fallback = ROW_ANCHOR_DEFAULTS[channelKey]
    row:ClearAllPoints()
    row:SetPoint(
        ch.point or fallback.point,
        plate.healthBar,
        ch.relativePoint or fallback.relativePoint,
        QUICore:Pixels(ch.offsetX or fallback.offsetX, plate),
        QUICore:Pixels(ch.offsetY or fallback.offsetY, plate))
end

function NPAuras.ApplyAppearance(plate, settings)
    local auras = settings.auras or {}
    plate.npAurasEnabled = auras.enabled ~= false
    for _, channelKey in ipairs(CHANNELS) do
        local ch = auras[channelKey] or {}
        local row = GetRow(plate, channelKey)
        AnchorRow(plate, row, channelKey, ch)
        row.npSize = ch.size or 24
        row.npSpacing = ch.spacing or 2
        row.npLimit = ch.limit or 4
        row.npGrowth = ch.growth or "RIGHT"
        row.npTextSize = ch.textSize or 11
        row.npEnabled = ch.enabled ~= false
        local fontPath = UIKit.ResolveFontPath()
        for _, holder in ipairs(row.icons) do
            QUICore:ApplyFont(holder.stackText, nil, row.npTextSize, fontPath, "OUTLINE")
            ApplyDurationStyle(holder, auras)
        end
    end
end

---------------------------------------------------------------------------
-- CLASSIFICATION (added payloads → channels)
---------------------------------------------------------------------------
-- Membership test: IsAuraFilteredOutByInstanceID returns TRUE when the aura
-- is filtered out. Only a clean boolean false counts as membership; a
-- secret/unavailable verdict is treated as non-member (fail closed — the
-- next full rebuild reconciles).
local function IsMember(unit, instanceID, filter)
    if not (C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID) then return false end
    local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, instanceID, filter)
    -- Only a verifiably plain false is membership; a SECRET verdict fails
    -- closed (comparing it would error — NP.Plain, not type()).
    return ok and NP.Plain(filteredOut, "boolean") == false
end

-- Extract a CLEAN spellId from an aura payload/data table; nil when secret.
local function CleanSpellId(aura)
    if type(aura) ~= "table" then return nil end
    local spellId = aura.spellId
    if spellId == nil or IsSecretValue(spellId) then return nil end
    if type(spellId) == "number" then return spellId end
    return nil
end

local function ClassifyIntoChannels(plate, unit, instanceID, spellId, settings)
    local auras = settings.auras or {}
    local important = auras.importantList
    local touched = false
    for _, channelKey in ipairs(CHANNELS) do
        local ch = auras[channelKey] or {}
        if ch.enabled ~= false then
            local filter = NPAuras.ComposeFilter(channelKey, auras)
            if filter and IsMember(unit, instanceID, filter) then
                local verdict = NPAuras.ResolveSpellLists(spellId, ch, important)
                if verdict ~= "block" and verdict ~= "excluded" then
                    plate.npAuraSets[channelKey][instanceID] = spellId or true
                    plate.npAuraImportant[channelKey][instanceID] = (verdict == "important") or nil
                    plate.npAuraDirty[channelKey] = true
                    touched = true
                end
            end
        end
    end
    return touched
end

---------------------------------------------------------------------------
-- RENDERING (the separable "arrange N icon frames" step; 12.1 AuraContainer
-- replaces exactly this on capable clients)
---------------------------------------------------------------------------
local function HideIconsFrom(row, firstUnused)
    for i = firstUnused, #row.icons do
        local holder = row.icons[i]
        if holder.npInstanceID then
            PandemicRemove(holder.iconFrame)
        end
        holder.npInstanceID = nil
        holder:Hide()
    end
end

local function PaintIcon(plate, holder, unit, instanceID, isImportant, settings)
    local auras = settings.auras or {}
    holder.npInstanceID = instanceID

    -- Icon texture from our copied add-time info (SetTexture accepts secrets).
    local info = plate.npAuraIconInfo and plate.npAuraIconInfo[instanceID]
    if info ~= nil then
        pcall(holder.iconFrame.texture.SetTexture, holder.iconFrame.texture, info)
    else
        holder.iconFrame.texture:SetTexture(134400) -- question mark
    end

    -- Duration: engine-driven cooldown swipe + countdown text; the
    -- permanent-aura (0,0) strobe is masked by boolean-alpha on the cd.
    local cd = holder.cd
    if C_UnitAuras and C_UnitAuras.GetAuraDuration then
        local okDur, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, instanceID)
        if okDur and durObj ~= nil then
            if cd.SetCooldownFromDurationObject then
                pcall(cd.SetCooldownFromDurationObject, cd, durObj)
            end
            if cd.SetAlphaFromBoolean and durObj.IsZero then
                local okZero, zeroBool = pcall(durObj.IsZero, durObj)
                if okZero and zeroBool ~= nil then
                    pcall(cd.SetAlphaFromBoolean, cd, zeroBool, 0, 1)
                end
            end
            if auras.pandemicGlow ~= false and isImportant then
                PandemicAdd(holder.iconFrame, durObj)
            else
                PandemicRemove(holder.iconFrame)
            end
        else
            cd:Clear()
            PandemicRemove(holder.iconFrame)
        end
    end

    -- Stacks: display count straight into SetText (secret-safe sink).
    if C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
        local okStacks, stacks = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, instanceID, 2, 1000)
        if okStacks and stacks ~= nil then
            local okSet = pcall(holder.stackText.SetText, holder.stackText, stacks)
            if not okSet then holder.stackText:SetText("") end
        else
            holder.stackText:SetText("")
        end
    end

    -- Dispel-type border: the curve remaps the secret enum C-side; the
    -- returned color applies via SetVertexColor (the secret-safe border path).
    local borderPainted = false
    if auras.dispelBorders ~= false and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor then
        local curve = GetDispelCurve()
        if curve then
            local okColor, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, instanceID, curve)
            if okColor and color ~= nil and holder.iconFrame.border then
                local okApply = pcall(function()
                    local r, g, b, a = color:GetRGBA()
                    holder.iconFrame.border:SetVertexColor(r, g, b, a)
                end)
                borderPainted = okApply
            end
        end
    end
    if not borderPainted and holder.iconFrame.border then
        if isImportant then
            holder.iconFrame.border:SetVertexColor(1, 0.55, 0.1, 1)
        else
            holder.iconFrame.border:SetVertexColor(0, 0, 0, 1)
        end
    end

    holder:Show()
end

local function RenderChannel(plate, channelKey, settings)
    local unit = plate.unit
    local row = plate.npAuraRows and plate.npAuraRows[channelKey]
    if not unit or not row then return end
    local auras = settings.auras or {}
    local ch = auras[channelKey] or {}
    local set = plate.npAuraSets[channelKey]
    local importantSet = plate.npAuraImportant[channelKey]

    if not row.npEnabled or not plate.npAurasEnabled then
        HideIconsFrom(row, 1)
        return
    end

    -- Server order: expiration is secret, so ordering is the server's job.
    local ordered
    if C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs then
        local filter = NPAuras.ComposeFilter(channelKey, auras)
        local sortRule = Enum and Enum.UnitAuraSortRule and Enum.UnitAuraSortRule.ExpirationTime
        local sortDir = Enum and Enum.UnitAuraSortDirection and Enum.UnitAuraSortDirection.Ascending
        local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter, nil, sortRule, sortDir)
        if ok and type(ids) == "table" then
            ordered = ids
        end
    end

    local shown = 0
    local limit = row.npLimit or 4
    local size = row.npSize or 24
    local spacing = row.npSpacing or 2
    local growth = row.npGrowth or "RIGHT"
    local iconByID = plate.npAuraIconByID

    local function place(instanceID)
        if shown >= limit then return end
        shown = shown + 1
        local holder = row.icons[shown]
        if not holder then
            holder = CreateAuraIcon(plate, row)
            row.icons[shown] = holder
            QUICore:ApplyFont(holder.stackText, nil, row.npTextSize or 11, UIKit.ResolveFontPath(), "OUTLINE")
        end
        local isImportant = importantSet[instanceID] == true
        local scale = isImportant and (auras.importantScale or 1.3) or 1
        UIKit.UpdateIconLayout(holder.iconFrame, size * scale, 1)
        QUICore:SetPixelPerfectSize(holder, size * scale, size * scale)
        holder:ClearAllPoints()
        local offset = (shown - 1) * (size + spacing)
        if growth == "LEFT" then
            holder:SetPoint("RIGHT", row, "RIGHT", -QUICore:Pixels(offset, plate), 0)
        elseif growth == "CENTER" then
            holder:SetPoint("CENTER", row, "CENTER", QUICore:Pixels(offset, plate), 0)
        else
            holder:SetPoint("LEFT", row, "LEFT", QUICore:Pixels(offset, plate), 0)
        end
        PaintIcon(plate, holder, unit, instanceID, isImportant, settings)
        iconByID[instanceID] = holder
    end

    -- Drop stale fast-path handles for this channel before repaint.
    for instanceID, holder in pairs(iconByID) do
        if set[instanceID] == nil and holder.npChannel == channelKey then
            iconByID[instanceID] = nil
        end
    end

    if ordered then
        for i = 1, #ordered do
            local id = ordered[i]
            if set[id] ~= nil then
                place(id)
            end
        end
    else
        for id in pairs(set) do
            place(id)
        end
    end
    for i = 1, shown do
        row.icons[i].npChannel = channelKey
    end

    -- Row extent for growth anchoring (CENTER rows self-center).
    local extent = shown > 0 and (shown * size + (shown - 1) * spacing) or 1
    QUICore:SetPixelPerfectSize(row, extent, size)

    HideIconsFrom(row, shown + 1)
end

---------------------------------------------------------------------------
-- REBUILD SCHEDULING (one per plate per frame)
---------------------------------------------------------------------------
local flushPlates = {}
local flushFrame = CreateFrame("Frame")
flushFrame:Hide()
flushFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    local settings = NP.GetSettings()
    for plate in pairs(flushPlates) do
        flushPlates[plate] = nil
        if plate.unit then
            for _, channelKey in ipairs(CHANNELS) do
                if plate.npAuraDirty[channelKey] then
                    plate.npAuraDirty[channelKey] = nil
                    RenderChannel(plate, channelKey, settings)
                end
            end
        end
    end
end)

local function ScheduleFlush(plate)
    flushPlates[plate] = true
    flushFrame:Show()
end

---------------------------------------------------------------------------
-- FULL RESCAN (ADDED / token recycling / settings refresh)
---------------------------------------------------------------------------
function NPAuras.FullRescan(plate)
    local unit = plate.unit
    if not unit or not plate.npAuraSets then return end
    local settings = NP.GetSettings()
    local auras = settings.auras or {}

    for _, channelKey in ipairs(CHANNELS) do
        wipe(plate.npAuraSets[channelKey])
        wipe(plate.npAuraImportant[channelKey])
        plate.npAuraDirty[channelKey] = true
    end
    wipe(plate.npAuraIconByID)
    plate.npAuraIconInfo = plate.npAuraIconInfo or {}
    wipe(plate.npAuraIconInfo)

    if not plate.npAurasEnabled or auras.enabled == false then
        ScheduleFlush(plate)
        return
    end
    local context = NP.Extras.GetContext()
    if not NPAuras.IsContextEnabled(auras, context.instanceKind) then
        ScheduleFlush(plate)
        return
    end

    -- Seed sets from server-ordered ID lists per channel, then classify by
    -- local lists using aura data (clean spellIds only).
    for _, channelKey in ipairs(CHANNELS) do
        local ch = auras[channelKey] or {}
        if ch.enabled ~= false then
            local filter = NPAuras.ComposeFilter(channelKey, auras)
            if filter and C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs then
                local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter)
                if ok and type(ids) == "table" then
                    for i = 1, #ids do
                        local instanceID = ids[i]
                        local spellId, icon
                        if C_UnitAuras.GetAuraDataByAuraInstanceID then
                            local okData, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, instanceID)
                            if okData and type(data) == "table" then
                                spellId = CleanSpellId(data)
                                icon = data.icon
                            end
                        end
                        local verdict = NPAuras.ResolveSpellLists(spellId, ch, auras.importantList)
                        if verdict ~= "block" and verdict ~= "excluded" then
                            plate.npAuraSets[channelKey][instanceID] = spellId or true
                            plate.npAuraImportant[channelKey][instanceID] = (verdict == "important") or nil
                            if icon ~= nil then
                                plate.npAuraIconInfo[instanceID] = icon
                            end
                        end
                    end
                end
            end
        end
    end
    ScheduleFlush(plate)
end

---------------------------------------------------------------------------
-- DELTA CONSUMER (core dispatcher "nameplate" tier)
---------------------------------------------------------------------------
OnNameplateAura = function(unit, updateInfo)
    local plate = NP.plates[unit]
    if not plate or not plate.npAuraSets then return end
    if not plate.npAurasEnabled then return end

    -- Full update: rescan everything.
    if updateInfo == nil then
        NPAuras.FullRescan(plate)
        return
    end

    local settings = NP.GetSettings()
    local touched = false

    -- Added: classify each into channels (COPY what we keep — the payload
    -- tables are pooled and wiped after dispatch).
    local added = updateInfo.addedAuras
    if added then
        for i = 1, #added do
            local aura = added[i]
            if type(aura) == "table" and aura.auraInstanceID ~= nil then
                local instanceID = aura.auraInstanceID
                local spellId = CleanSpellId(aura)
                plate.npAuraIconInfo = plate.npAuraIconInfo or {}
                if aura.icon ~= nil then
                    plate.npAuraIconInfo[instanceID] = aura.icon
                end
                if ClassifyIntoChannels(plate, unit, instanceID, spellId, settings) then
                    touched = true
                end
            end
        end
    end

    -- Removed: drop from any channel set.
    local removed = updateInfo.removedAuraInstanceIDs
    if removed then
        for i = 1, #removed do
            local instanceID = removed[i]
            for _, channelKey in ipairs(CHANNELS) do
                if plate.npAuraSets[channelKey][instanceID] ~= nil then
                    plate.npAuraSets[channelKey][instanceID] = nil
                    plate.npAuraImportant[channelKey][instanceID] = nil
                    plate.npAuraDirty[channelKey] = true
                    touched = true
                end
            end
            if plate.npAuraIconInfo then
                plate.npAuraIconInfo[instanceID] = nil
            end
        end
    end

    -- Updated: in-place fast path — re-arm the cooldown + stacks on the
    -- already-shown icon without a channel rebuild.
    local updated = updateInfo.updatedAuraInstanceIDs
    if updated then
        for i = 1, #updated do
            local instanceID = updated[i]
            local holder = plate.npAuraIconByID[instanceID]
            if holder and holder.npInstanceID == instanceID and holder:IsShown() then
                local cd = holder.cd
                if C_UnitAuras and C_UnitAuras.GetAuraDuration then
                    local okDur, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, instanceID)
                    if okDur and durObj ~= nil and cd.SetCooldownFromDurationObject then
                        pcall(cd.SetCooldownFromDurationObject, cd, durObj)
                        if pandemicIcons[holder.iconFrame] then
                            PandemicAdd(holder.iconFrame, durObj)
                        end
                    end
                end
                if C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
                    local okStacks, stacks = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, instanceID, 2, 1000)
                    if okStacks and stacks ~= nil then
                        pcall(holder.stackText.SetText, holder.stackText, stacks)
                    end
                end
            end
        end
    end

    if touched then
        ScheduleFlush(plate)
    end
end

---------------------------------------------------------------------------
-- CLEAR (recycle hygiene, called from the driver's ClearUnit)
---------------------------------------------------------------------------
function NPAuras.Clear(plate)
    if not plate.npAuraSets then return end
    for _, channelKey in ipairs(CHANNELS) do
        wipe(plate.npAuraSets[channelKey])
        wipe(plate.npAuraImportant[channelKey])
        plate.npAuraDirty[channelKey] = nil
        local row = plate.npAuraRows and plate.npAuraRows[channelKey]
        if row then
            HideIconsFrom(row, 1)
        end
    end
    wipe(plate.npAuraIconByID)
    if plate.npAuraIconInfo then
        wipe(plate.npAuraIconInfo)
    end
    flushPlates[plate] = nil
end

-- Subscription happens lazily in Build (EnsureSubscribed) so a disabled
-- suite never creates the dispatcher's nameplate tier.
