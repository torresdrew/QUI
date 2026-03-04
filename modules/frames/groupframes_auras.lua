--[[
    QUI Group Frames - Aura System
    Compact aura display for group frames with priority filtering,
    table pooling, shared aura timer, and duration color coding.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local LSM = LibStub("LibSharedMedia-3.0")
local QUICore = ns.Addon
local IsSecretValue = Helpers.IsSecretValue
local SafeValue = Helpers.SafeValue
local SafeToNumber = Helpers.SafeToNumber
local GetDB = Helpers.CreateDBGetter("quiGroupFrames")

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_GFA = {}
ns.QUI_GroupFrameAuras = QUI_GFA

-- Weak-keyed state for aura icons (taint safety)
local auraIconState = setmetatable({}, { __mode = "k" })

---------------------------------------------------------------------------
-- TABLE POOLING: Reusable aura data tables for GC reduction
---------------------------------------------------------------------------
local auraTablePool = {}
local POOL_SIZE = 60

local function AcquireAuraTable()
    local tbl = table.remove(auraTablePool)
    if tbl then
        wipe(tbl)
        return tbl
    end
    return {}
end

local function ReleaseAuraTable(tbl)
    if #auraTablePool < POOL_SIZE then
        wipe(tbl)
        table.insert(auraTablePool, tbl)
    end
end

-- Pre-allocate pool
for i = 1, POOL_SIZE do
    auraTablePool[i] = {}
end

---------------------------------------------------------------------------
-- SHARED AURA TIMER: Single animation drives all icon duration updates
---------------------------------------------------------------------------
local timerIcons = {} -- Icons registered for duration updates
local sharedTimerFrame = CreateFrame("Frame")
local TIMER_INTERVAL = 0.1 -- Update duration text every 100ms

local function FormatDuration(remaining)
    if remaining <= 0 then return "" end
    if remaining < 10 then
        return format("%.1f", remaining)
    elseif remaining < 60 then
        return format("%d", math.floor(remaining))
    elseif remaining < 3600 then
        return format("%dm", math.floor(remaining / 60))
    else
        return format("%dh", math.floor(remaining / 3600))
    end
end

local function GetDurationColor(remaining, duration)
    if duration <= 0 or remaining <= 0 then
        return 1, 0, 0 -- Red for expired
    end
    local pct = remaining / duration
    if pct > 0.5 then
        return 0.2, 1, 0.2 -- Green
    elseif pct > 0.25 then
        return 1, 1, 0 -- Yellow
    else
        return 1, 0.2, 0.2 -- Red
    end
end

local timerElapsed = 0
sharedTimerFrame:SetScript("OnUpdate", function(self, dt)
    timerElapsed = timerElapsed + dt
    if timerElapsed < TIMER_INTERVAL then return end
    timerElapsed = 0

    local now = GetTime()
    local db = GetDB()
    local showDurationColor = db and db.auras and db.auras.showDurationColor ~= false

    for icon, state in pairs(timerIcons) do
        if icon:IsShown() and state.expirationTime then
            local expTime = SafeToNumber(state.expirationTime, 0)
            local dur = SafeToNumber(state.duration, 0)
            local remaining = expTime - now

            if remaining > 0 then
                if icon.durationText then
                    icon.durationText:SetText(FormatDuration(remaining))
                    if showDurationColor then
                        local r, g, b = GetDurationColor(remaining, dur)
                        icon.durationText:SetTextColor(r, g, b, 1)
                    else
                        icon.durationText:SetTextColor(1, 1, 1, 1)
                    end
                end
            else
                -- Expired
                if icon.durationText then icon.durationText:SetText("") end
                timerIcons[icon] = nil
            end
        else
            timerIcons[icon] = nil
        end
    end
end)

local function RegisterIconTimer(icon, state)
    timerIcons[icon] = state
end

local function UnregisterIconTimer(icon)
    timerIcons[icon] = nil
end

---------------------------------------------------------------------------
-- SLOT OFFSET: Calculate icon position for configurable grow direction
---------------------------------------------------------------------------
local function CalculateSlotOffset(index, iconSize, spacing, direction)
    local step = (index - 1) * (iconSize + spacing)
    if direction == "RIGHT" then
        return step, 0
    elseif direction == "LEFT" then
        return -step, 0
    elseif direction == "UP" then
        return 0, step
    elseif direction == "DOWN" then
        return 0, -step
    end
    return step, 0 -- fallback to RIGHT
end

---------------------------------------------------------------------------
-- AURA ICON: Create/get icon for a frame
---------------------------------------------------------------------------
local function GetFontPath()
    local general = GetDB()
    general = general and general.general
    local fontName = general and general.font or "Quazii"
    return LSM:Fetch("font", fontName) or "Fonts\\FRIZQT__.TTF"
end

local function CreateAuraIcon(parent, size)
    size = size or 16
    local icon = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    icon:SetSize(size, size)

    -- Render above healthBar (+0), healPrediction (+1), absorb (+2)
    local baseLevel = parent.healthBar and parent.healthBar:GetFrameLevel() or parent:GetFrameLevel()
    icon:SetFrameLevel(baseLevel + 5)

    -- Icon texture
    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.icon = tex

    -- Border
    local px = QUICore.GetPixelSize and QUICore:GetPixelSize(icon) or 1
    icon:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = px,
    })
    icon:SetBackdropBorderColor(0, 0, 0, 1)

    -- Cooldown swipe
    local cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    cooldown:SetHideCountdownNumbers(true)
    icon.cooldown = cooldown

    -- Stack count text
    local stackText = icon:CreateFontString(nil, "OVERLAY")
    local fontPath = GetFontPath()
    stackText:SetFont(fontPath, 10, "OUTLINE")
    stackText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    stackText:SetJustifyH("RIGHT")
    icon.stackText = stackText

    -- Duration text
    local durationText = icon:CreateFontString(nil, "OVERLAY")
    durationText:SetFont(fontPath, 9, "OUTLINE")
    durationText:SetPoint("TOP", icon, "BOTTOM", 0, -1)
    durationText:SetJustifyH("CENTER")
    icon.durationText = durationText

    -- Expiring pulse animation
    local pulseGroup = icon:CreateAnimationGroup()
    local pulseAlpha = pulseGroup:CreateAnimation("Alpha")
    pulseAlpha:SetFromAlpha(1)
    pulseAlpha:SetToAlpha(0.3)
    pulseAlpha:SetDuration(0.4)
    pulseGroup:SetLooping("BOUNCE")
    icon.pulseGroup = pulseGroup

    icon:Hide()
    return icon
end

local function UpdateAuraIcon(icon, auraData, unit)
    if not icon or not auraData then
        if icon then icon:Hide() end
        return
    end

    local state = auraIconState[icon]
    if not state then
        state = {}
        auraIconState[icon] = state
    end

    -- Store data in side-table (NOT on frame — taint safety)
    state.unit = unit
    state.auraInstanceID = auraData.auraInstanceID
    state.expirationTime = auraData.expirationTime
    state.duration = auraData.duration
    state.applications = auraData.applications

    -- Icon texture
    if not IsSecretValue(auraData.icon) and auraData.icon and icon.icon then
        icon.icon:SetTexture(auraData.icon)  -- C-side, handles secret values
    end

    -- Stack count
    local stacks = SafeToNumber(auraData.applications, 0)
    if stacks > 1 and icon.stackText then
        icon.stackText:SetText(stacks)
    elseif icon.stackText then
        icon.stackText:SetText("")
    end

    -- Cooldown swipe (use C-side methods which handle secret values natively)
    if icon.cooldown then
        local dur = auraData.duration
        local expTime = auraData.expirationTime
        local auraID = auraData.auraInstanceID
        local hasValues = not IsSecretValue(dur) and dur and not IsSecretValue(expTime) and expTime
        local hasSecretValues = not hasValues and (IsSecretValue(dur) or IsSecretValue(expTime))

        if hasValues or hasSecretValues then
            -- Path 1: DurationObject (WoW 12.0+, fully secret-safe)
            if icon.cooldown.SetCooldownFromDurationObject and not IsSecretValue(auraID) and auraID and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                local ok, durationObj = pcall(C_UnitAuras.GetAuraDuration, unit, auraID)
                if ok and durationObj then
                    pcall(icon.cooldown.SetCooldownFromDurationObject, icon.cooldown, durationObj, true)
                elseif icon.cooldown.SetCooldownFromExpirationTime then
                    pcall(icon.cooldown.SetCooldownFromExpirationTime, icon.cooldown, expTime, dur)
                elseif hasValues then
                    pcall(function() icon.cooldown:SetCooldown(expTime - dur, dur) end)
                end
            elseif icon.cooldown.SetCooldownFromExpirationTime then
                -- Path 2: SetCooldownFromExpirationTime (C-side, secret-safe)
                pcall(icon.cooldown.SetCooldownFromExpirationTime, icon.cooldown, expTime, dur)
            elseif hasValues then
                -- Path 3: Legacy fallback (Lua arithmetic, only safe with non-secret values)
                pcall(function() icon.cooldown:SetCooldown(expTime - dur, dur) end)
            end
        else
            icon.cooldown:Clear()
        end
    end

    -- Duration text + timer registration
    local safeDur = SafeToNumber(auraData.duration, 0)
    if safeDur > 0 then
        RegisterIconTimer(icon, state)
    else
        UnregisterIconTimer(icon)
        if icon.durationText then icon.durationText:SetText("") end
    end

    -- Expiring pulse
    local db = GetDB()
    local showPulse = db and db.auras and db.auras.showExpiringPulse ~= false
    if showPulse and safeDur > 0 then
        local safeExp = SafeToNumber(auraData.expirationTime, 0)
        local remaining = safeExp - GetTime()
        if remaining > 0 and remaining < 5 then
            if icon.pulseGroup and not icon.pulseGroup:IsPlaying() then
                icon.pulseGroup:Play()
            end
        else
            if icon.pulseGroup and icon.pulseGroup:IsPlaying() then
                icon.pulseGroup:Stop()
            end
        end
    else
        if icon.pulseGroup and icon.pulseGroup:IsPlaying() then
            icon.pulseGroup:Stop()
        end
    end

    -- Dispellable debuff border color
    if not IsSecretValue(auraData.dispelName) and auraData.dispelName then
        local dispelType = SafeValue(auraData.dispelName, nil)
        local DISPEL_COLORS = {
            Magic   = { 0.2, 0.6, 1.0, 1 },
            Curse   = { 0.6, 0.0, 1.0, 1 },
            Disease = { 0.6, 0.4, 0.0, 1 },
            Poison  = { 0.0, 0.6, 0.0, 1 },
            Bleed   = { 0.8, 0.0, 0.0, 1 },
        }
        if dispelType and DISPEL_COLORS[dispelType] then
            local c = DISPEL_COLORS[dispelType]
            icon:SetBackdropBorderColor(c[1], c[2], c[3], c[4])
        else
            icon:SetBackdropBorderColor(0.8, 0, 0, 1) -- Default debuff red
        end
    else
        icon:SetBackdropBorderColor(0, 0, 0, 1) -- Default black border
    end

    icon:Show()
end

---------------------------------------------------------------------------
-- AURA PRIORITY: Sort auras by importance
---------------------------------------------------------------------------
local PRIORITY_DISPELLABLE = 3
local PRIORITY_BOSS = 2
local PRIORITY_NORMAL = 1

local function GetAuraPriority(auraData)
    if not auraData then return 0 end
    local isDispellable = SafeValue(auraData.dispelName, nil)
    local isBoss = SafeValue(auraData.isBossAura, false)

    if isDispellable then return PRIORITY_DISPELLABLE end
    if isBoss then return PRIORITY_BOSS end
    return PRIORITY_NORMAL
end

---------------------------------------------------------------------------
-- UPDATE: Auras for a single frame
---------------------------------------------------------------------------
local sortedAuras = {} -- Reusable sort table

local function UpdateFrameAuras(frame)
    if not frame or not frame.unit then return end

    local db = GetDB()
    if not db or not db.auras then return end
    local auraSettings = db.auras

    local unit = frame.unit
    if not UnitExists(unit) then
        -- Hide all icons
        if frame.debuffIcons then
            for _, icon in ipairs(frame.debuffIcons) do
                icon:Hide()
                UnregisterIconTimer(icon)
            end
        end
        if frame.buffIcons then
            for _, icon in ipairs(frame.buffIcons) do
                icon:Hide()
                UnregisterIconTimer(icon)
            end
        end
        return
    end

    -- Process debuffs
    if auraSettings.showDebuffs then
        local maxDebuffs = auraSettings.maxDebuffs or 3
        local iconSize = auraSettings.debuffIconSize or 16

        -- Ensure icon pool exists
        if not frame.debuffIcons then
            frame.debuffIcons = {}
        end

        -- Collect harmful auras using C-side filtering (secret-safe)
        wipe(sortedAuras)
        if C_UnitAuras.GetUnitAuras then
            local ok, harmfulAuras = pcall(C_UnitAuras.GetUnitAuras, unit, "HARMFUL", 80)
            if ok and harmfulAuras then
                for _, auraData in ipairs(harmfulAuras) do
                    local entry = AcquireAuraTable()
                    entry.auraData = auraData
                    entry.priority = GetAuraPriority(auraData)
                    table.insert(sortedAuras, entry)
                end
            end
        else
            -- Pre-12.0 fallback: slot iteration
            local slot = 1
            while true do
                local ok, auraData = pcall(C_UnitAuras.GetAuraDataBySlot, unit, slot)
                if not ok or not auraData then break end
                if SafeValue(auraData.isHarmful, false) then
                    local entry = AcquireAuraTable()
                    entry.auraData = auraData
                    entry.priority = GetAuraPriority(auraData)
                    table.insert(sortedAuras, entry)
                end
                slot = slot + 1
                if slot > 80 then break end
            end
        end

        -- Sort by priority (higher first)
        table.sort(sortedAuras, function(a, b)
            return a.priority > b.priority
        end)

        -- Display up to maxDebuffs
        local dAnchor = auraSettings.debuffAnchor or "BOTTOMRIGHT"
        local dGrow = auraSettings.debuffGrowDirection or "LEFT"
        local dSpacing = auraSettings.debuffSpacing or 2
        local dOffX = auraSettings.debuffOffsetX or -2
        local dOffY = auraSettings.debuffOffsetY or -18
        for i = 1, maxDebuffs do
            local entry = sortedAuras[i]
            if not frame.debuffIcons[i] then
                frame.debuffIcons[i] = CreateAuraIcon(frame, iconSize)
            end
            -- Reposition every update (settings may change)
            local offX, offY = CalculateSlotOffset(i, iconSize, dSpacing, dGrow)
            frame.debuffIcons[i]:ClearAllPoints()
            frame.debuffIcons[i]:SetPoint(dAnchor, frame, dAnchor, dOffX + offX, dOffY + offY)
            frame.debuffIcons[i]:SetSize(iconSize, iconSize)
            if entry then
                UpdateAuraIcon(frame.debuffIcons[i], entry.auraData, unit)
            else
                frame.debuffIcons[i]:Hide()
                UnregisterIconTimer(frame.debuffIcons[i])
            end
        end

        -- Hide excess icons
        for i = maxDebuffs + 1, #frame.debuffIcons do
            frame.debuffIcons[i]:Hide()
            UnregisterIconTimer(frame.debuffIcons[i])
        end

        -- Release pooled tables
        for _, entry in ipairs(sortedAuras) do
            ReleaseAuraTable(entry)
        end
    elseif frame.debuffIcons then
        for _, icon in ipairs(frame.debuffIcons) do
            icon:Hide()
            UnregisterIconTimer(icon)
        end
    end

    -- Process buffs (if enabled)
    if auraSettings.showBuffs and (auraSettings.maxBuffs or 0) > 0 then
        local maxBuffs = auraSettings.maxBuffs
        local iconSize = auraSettings.buffIconSize or 14

        if not frame.buffIcons then
            frame.buffIcons = {}
        end

        wipe(sortedAuras)
        if C_UnitAuras.GetUnitAuras then
            local ok, helpfulAuras = pcall(C_UnitAuras.GetUnitAuras, unit, "HELPFUL", 80)
            if ok and helpfulAuras then
                for _, auraData in ipairs(helpfulAuras) do
                    local entry = AcquireAuraTable()
                    entry.auraData = auraData
                    entry.priority = 1
                    table.insert(sortedAuras, entry)
                end
            end
        else
            -- Pre-12.0 fallback: slot iteration
            local slot = 1
            while true do
                local ok, auraData = pcall(C_UnitAuras.GetAuraDataBySlot, unit, slot)
                if not ok or not auraData then break end
                if SafeValue(auraData.isHelpful, false) then
                    local entry = AcquireAuraTable()
                    entry.auraData = auraData
                    entry.priority = 1
                    table.insert(sortedAuras, entry)
                end
                slot = slot + 1
                if slot > 80 then break end
            end
        end

        local bAnchor = auraSettings.buffAnchor or "TOPLEFT"
        local bGrow = auraSettings.buffGrowDirection or "RIGHT"
        local bSpacing = auraSettings.buffSpacing or 2
        local bOffX = auraSettings.buffOffsetX or 2
        local bOffY = auraSettings.buffOffsetY or 16
        for i = 1, maxBuffs do
            local entry = sortedAuras[i]
            if not frame.buffIcons[i] then
                frame.buffIcons[i] = CreateAuraIcon(frame, iconSize)
            end
            -- Reposition every update (settings may change)
            local offX, offY = CalculateSlotOffset(i, iconSize, bSpacing, bGrow)
            frame.buffIcons[i]:ClearAllPoints()
            frame.buffIcons[i]:SetPoint(bAnchor, frame, bAnchor, bOffX + offX, bOffY + offY)
            frame.buffIcons[i]:SetSize(iconSize, iconSize)
            if entry then
                UpdateAuraIcon(frame.buffIcons[i], entry.auraData, unit)
            else
                frame.buffIcons[i]:Hide()
                UnregisterIconTimer(frame.buffIcons[i])
            end
        end

        for i = maxBuffs + 1, #frame.buffIcons do
            frame.buffIcons[i]:Hide()
            UnregisterIconTimer(frame.buffIcons[i])
        end

        for _, entry in ipairs(sortedAuras) do
            ReleaseAuraTable(entry)
        end
    elseif frame.buffIcons then
        for _, icon in ipairs(frame.buffIcons) do
            icon:Hide()
            UnregisterIconTimer(icon)
        end
    end
end

---------------------------------------------------------------------------
-- EVENT HOOKUP: Listen to UNIT_AURA via the group frame event system
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_AURA")

eventFrame:SetScript("OnEvent", function(self, event, unit)
    if event ~= "UNIT_AURA" then return end
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.initialized then return end

    local frame = GF.unitFrameMap[unit]
    if frame then
        UpdateFrameAuras(frame)
    end
end)

---------------------------------------------------------------------------
-- PUBLIC: Refresh all frames
---------------------------------------------------------------------------
function QUI_GFA:RefreshAll()
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.initialized then return end

    for _, frame in pairs(GF.unitFrameMap) do
        if frame and frame:IsShown() then
            UpdateFrameAuras(frame)
        end
    end
end

function QUI_GFA:RefreshFrame(frame)
    UpdateFrameAuras(frame)
end
