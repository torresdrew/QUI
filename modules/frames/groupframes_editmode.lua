--[[
    QUI Group Frames - Edit Mode & Test/Preview System
    Handles header dragging, nudge controls, fake preview frames,
    spotlight feature, and Blizzard Edit Mode integration.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local QUICore = ns.Addon
local GetDB = Helpers.CreateDBGetter("quiGroupFrames")

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_GFEM = {}
ns.QUI_GroupFrameEditMode = QUI_GFEM

local isEditMode = false
local isTestMode = false
local testFrames = {}
local editOverlays = {}
local spotlightHeader = nil

---------------------------------------------------------------------------
-- FAKE DATA: For test/preview mode
---------------------------------------------------------------------------
local FAKE_CLASSES = { "WARRIOR", "PALADIN", "PRIEST", "DRUID", "SHAMAN", "MAGE", "ROGUE", "HUNTER", "WARLOCK", "DEATHKNIGHT", "MONK", "DEMONHUNTER", "EVOKER" }
local FAKE_NAMES = { "Tankthor", "Healena", "Pwnadin", "Natureza", "Shamwow", "Frostina", "Stabsworth", "Bowmaster", "Felcaster", "Lichking", "Mistpaw", "Demonbane", "Scalewing",
    "Ironwall", "Lightbeam", "Shadowmend", "Wildgrowth", "Totemist", "Arcanist", "Backstab", "Marksman", "Doomcall", "Runeblade", "Zenmaster", "Havocwing", "Breathfire",
    "Shieldwall", "Holylight", "Mindblast", "Starfall", "Lavaflow", "Pyrolust", "Ambusher", "Snipeshot", "Soulburn", "Froststorm", "Tigerpaw", "Vengewing", "Glimmora",
    "Bulwark", "Divinity" }
local FAKE_ROLES = { "TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER" }
local FAKE_RAID_ROLES = { "TANK", "TANK", "HEALER", "HEALER", "HEALER", "HEALER",
    "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER",
    "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER",
    "DAMAGER", "DAMAGER", "DAMAGER" }

local function GetFakeHealthPct(index)
    -- Varied health levels for visual interest
    local patterns = { 100, 85, 65, 45, 92, 78, 30, 95, 88, 55,
                       72, 100, 80, 60, 90, 75, 40, 98, 82, 68,
                       0, 100, 70, 50, 95, 85, 35, 100, 77, 62,
                       88, 42, 100, 73, 56, 91, 100, 83, 47, 100 }
    return patterns[((index - 1) % #patterns) + 1]
end

---------------------------------------------------------------------------
-- TEST MODE: Create fake frames for solo testing
---------------------------------------------------------------------------
local function CreateTestFrame(parent, index, totalCount, classToken, name, role, healthPct)
    local db = GetDB()
    if not db then return nil end

    local GF = ns.QUI_GroupFrames
    if not GF then return nil end

    local mode
    if totalCount <= 5 then mode = "party"
    elseif totalCount <= 15 then mode = "small"
    elseif totalCount <= 25 then mode = "medium"
    else mode = "large"
    end

    local dims = db.dimensions
    local w, h
    if mode == "party" then w, h = dims.partyWidth or 200, dims.partyHeight or 40
    elseif mode == "small" then w, h = dims.smallRaidWidth or 180, dims.smallRaidHeight or 36
    elseif mode == "medium" then w, h = dims.mediumRaidWidth or 160, dims.mediumRaidHeight or 30
    else w, h = dims.largeRaidWidth or 140, dims.largeRaidHeight or 24
    end

    local frame = CreateFrame("Frame", "QUI_TestFrame" .. index, parent, "BackdropTemplate")
    frame:SetSize(w, h)

    -- Visuals matching DecorateGroupFrame
    local general = db.general
    local borderPx = general and general.borderSize or 1
    local borderSize = borderPx > 0 and (QUICore.Pixels and QUICore:Pixels(borderPx, frame) or borderPx) or 0
    local px = QUICore.GetPixelSize and QUICore:GetPixelSize(frame) or 1

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = borderSize > 0 and "Interface\\Buttons\\WHITE8x8" or nil,
        edgeSize = borderSize > 0 and borderSize or nil,
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    if borderSize > 0 then
        frame:SetBackdropBorderColor(0, 0, 0, 1)
    end

    -- Power bar
    local powerSettings = db.power
    local showPower = powerSettings and powerSettings.showPowerBar ~= false
    local powerHeight = showPower and (powerSettings.powerBarHeight or 4) or 0
    local separatorHeight = showPower and px or 0

    -- Health bar
    local LSM = LibStub("LibSharedMedia-3.0")
    local textureName = general and general.texture or "Quazii v5"
    local texturePath = LSM:Fetch("statusbar", textureName) or "Interface\\TargetingFrame\\UI-StatusBar"

    local healthBar = CreateFrame("StatusBar", nil, frame)
    healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", borderSize, -borderSize)
    healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -borderSize, borderSize + powerHeight + separatorHeight)
    healthBar:SetStatusBarTexture(texturePath)
    healthBar:SetMinMaxValues(0, 100)
    healthBar:SetValue(healthPct)

    -- Health bar background
    local healthBg = healthBar:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints()
    healthBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    healthBg:SetVertexColor(0.05, 0.05, 0.05, 0.9)

    -- Class color on health bar
    if general and general.darkMode then
        local c = general.darkModeHealthColor or { 0.15, 0.15, 0.15, 1 }
        healthBar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 1)
    elseif general and general.useClassColor ~= false then
        local cc = RAID_CLASS_COLORS[classToken]
        if cc then
            healthBar:SetStatusBarColor(cc.r, cc.g, cc.b, 1)
        else
            healthBar:SetStatusBarColor(0.2, 0.8, 0.2, 1)
        end
    else
        healthBar:SetStatusBarColor(0.2, 0.8, 0.2, 1)
    end

    -- Power bar
    if showPower then
        local powerBar = CreateFrame("StatusBar", nil, frame)
        powerBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", borderSize, borderSize)
        powerBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -borderSize, borderSize)
        powerBar:SetHeight(powerHeight)
        powerBar:SetStatusBarTexture(texturePath)
        powerBar:SetMinMaxValues(0, 100)
        powerBar:SetValue(100)
        powerBar:SetStatusBarColor(0, 0.5, 1, 1)

        local powerBg = powerBar:CreateTexture(nil, "BACKGROUND")
        powerBg:SetAllPoints()
        powerBg:SetTexture("Interface\\Buttons\\WHITE8x8")
        powerBg:SetVertexColor(0.05, 0.05, 0.05, 0.9)

        local sep = powerBar:CreateTexture(nil, "OVERLAY")
        sep:SetHeight(px)
        sep:SetPoint("BOTTOMLEFT", powerBar, "TOPLEFT", 0, 0)
        sep:SetPoint("BOTTOMRIGHT", powerBar, "TOPRIGHT", 0, 0)
        sep:SetTexture("Interface\\Buttons\\WHITE8x8")
        sep:SetVertexColor(0, 0, 0, 1)
    end

    -- Text frame
    local textFrame = CreateFrame("Frame", nil, frame)
    textFrame:SetAllPoints()
    textFrame:SetFrameLevel(healthBar:GetFrameLevel() + 3)

    local fontName = general and general.font or "Quazii"
    local fontPath = LSM:Fetch("font", fontName) or "Fonts\\FRIZQT__.TTF"
    local fontOutline = general and general.fontOutline or "OUTLINE"

    -- Name text
    local nameSettings = db.name
    local nameText = textFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(fontPath, nameSettings and nameSettings.nameFontSize or 12, fontOutline)
    nameText:SetPoint("LEFT", frame, "LEFT", nameSettings and nameSettings.nameOffsetX or 4, nameSettings and nameSettings.nameOffsetY or 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1, 1)

    local displayName = name
    local maxLen = nameSettings and nameSettings.maxNameLength or 10
    if maxLen > 0 and #displayName > maxLen then
        displayName = displayName:sub(1, maxLen)
    end
    nameText:SetText(displayName)

    -- Health text
    local healthSettings = db.health
    local healthText = textFrame:CreateFontString(nil, "OVERLAY")
    healthText:SetFont(fontPath, healthSettings and healthSettings.healthFontSize or 12, fontOutline)
    healthText:SetPoint("RIGHT", frame, "RIGHT", healthSettings and healthSettings.healthOffsetX or -4, healthSettings and healthSettings.healthOffsetY or 0)
    healthText:SetJustifyH("RIGHT")
    healthText:SetTextColor(1, 1, 1, 1)

    if healthPct == 0 then
        healthText:SetText("Dead")
        healthText:SetTextColor(0.5, 0.5, 0.5, 1)
        healthBar:SetStatusBarColor(0.5, 0.5, 0.5, 1)
    else
        healthText:SetText(healthPct .. "%")
    end

    -- Role icon
    local indSettings = db.indicators
    if indSettings and indSettings.showRoleIcon ~= false then
        local roleIcon = textFrame:CreateTexture(nil, "OVERLAY")
        roleIcon:SetSize(indSettings.roleIconSize or 12, indSettings.roleIconSize or 12)
        roleIcon:SetPoint(indSettings.roleIconAnchor or "TOPLEFT", frame, indSettings.roleIconAnchor or "TOPLEFT", 2, -2)
        local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
        local atlas = ROLE_ATLAS[role]
        if atlas then
            roleIcon:SetAtlas(atlas)
        else
            roleIcon:Hide()
        end
    end

    frame:Show()
    return frame
end

local function DestroyTestFrames()
    for _, frame in ipairs(testFrames) do
        frame:Hide()
        frame:SetParent(nil)
    end
    wipe(testFrames)
end

---------------------------------------------------------------------------
-- TEST MODE: Toggle
---------------------------------------------------------------------------
function QUI_GFEM:EnableTestMode(previewType)
    if isTestMode then self:DisableTestMode() end

    local db = GetDB()
    if not db then return end

    isTestMode = true

    local GF = ns.QUI_GroupFrames
    if GF then GF.testMode = true end

    -- Determine count
    local count
    if previewType == "raid" then
        count = db.testMode and db.testMode.raidCount or 25
    else
        count = db.testMode and db.testMode.partyCount or 5
    end

    -- Create container
    local container = CreateFrame("Frame", "QUI_TestContainer", UIParent)
    local position = db.position
    container:SetPoint("CENTER", UIParent, "CENTER", position and position.offsetX or -400, position and position.offsetY or 0)
    container:Show()
    table.insert(testFrames, container)

    -- Create test frames
    local layout = db.layout
    local spacing = layout and layout.spacing or 2
    local growDown = (layout and layout.growDirection or "DOWN") == "DOWN"
    local groupGrowRight = (layout and layout.groupGrowDirection or "RIGHT") == "RIGHT"
    local groupSpacing = layout and layout.groupSpacing or 10

    local framesPerGroup = 5
    local numGroups = math.ceil(count / framesPerGroup)

    for g = 1, numGroups do
        for i = 1, framesPerGroup do
            local index = (g - 1) * framesPerGroup + i
            if index > count then break end

            local classIdx = ((index - 1) % #FAKE_CLASSES) + 1
            local classToken = FAKE_CLASSES[classIdx]
            local name = FAKE_NAMES[((index - 1) % #FAKE_NAMES) + 1]
            local role
            if count <= 5 then
                role = FAKE_ROLES[((index - 1) % #FAKE_ROLES) + 1]
            else
                role = FAKE_RAID_ROLES[((index - 1) % #FAKE_RAID_ROLES) + 1]
            end
            local healthPct = GetFakeHealthPct(index)

            local testFrame = CreateTestFrame(container, index, count, classToken, name, role, healthPct)
            if testFrame then
                -- Position within container
                local mode
                if count <= 5 then mode = "party"
                elseif count <= 15 then mode = "small"
                elseif count <= 25 then mode = "medium"
                else mode = "large"
                end

                local dims = db.dimensions
                local w, h
                if mode == "party" then w, h = dims.partyWidth or 200, dims.partyHeight or 40
                elseif mode == "small" then w, h = dims.smallRaidWidth or 180, dims.smallRaidHeight or 36
                elseif mode == "medium" then w, h = dims.mediumRaidWidth or 160, dims.mediumRaidHeight or 30
                else w, h = dims.largeRaidWidth or 140, dims.largeRaidHeight or 24
                end

                local col = g - 1
                local row = i - 1

                local xOff = groupGrowRight and (col * (w + groupSpacing)) or -(col * (w + groupSpacing))
                local yOff = growDown and -(row * (h + spacing)) or (row * (h + spacing))

                testFrame:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, yOff)
                table.insert(testFrames, testFrame)
            end
        end
    end

    -- Set container size based on total extent
    local totalW = numGroups * ((db.dimensions.partyWidth or 200) + (layout and layout.groupSpacing or 10))
    local totalH = framesPerGroup * ((db.dimensions.partyHeight or 40) + spacing)
    container:SetSize(totalW, totalH)
end

function QUI_GFEM:DisableTestMode()
    DestroyTestFrames()
    isTestMode = false

    local GF = ns.QUI_GroupFrames
    if GF then GF.testMode = false end
end

function QUI_GFEM:IsTestMode()
    return isTestMode
end

function QUI_GFEM:ToggleTestMode(previewType)
    if isTestMode then
        self:DisableTestMode()
    else
        self:EnableTestMode(previewType or "party")
    end
end

---------------------------------------------------------------------------
-- EDIT MODE: Dragging + overlays
---------------------------------------------------------------------------
function QUI_GFEM:EnableEditMode()
    if isEditMode then return end
    isEditMode = true

    local GF = ns.QUI_GroupFrames
    if not GF then return end
    GF.editMode = true

    -- Make headers draggable
    for _, headerKey in ipairs({"party", "raid"}) do
        local header = GF.headers[headerKey]
        if header then
            -- Create or show edit overlay
            if not editOverlays[headerKey] then
                local overlay = CreateFrame("Frame", nil, header)
                overlay:SetAllPoints()
                overlay:SetFrameLevel(header:GetFrameLevel() + 20)

                -- Blue highlight border
                local px = QUICore.GetPixelSize and QUICore:GetPixelSize(overlay) or 1
                local border = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
                border:SetPoint("TOPLEFT", -px * 2, px * 2)
                border:SetPoint("BOTTOMRIGHT", px * 2, -px * 2)
                border:SetBackdrop({
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = px * 2,
                })
                border:SetBackdropBorderColor(0.2, 0.6, 1, 0.8) -- Blue
                overlay.border = border

                -- Position text
                local posText = overlay:CreateFontString(nil, "OVERLAY")
                local fontPath = LibStub("LibSharedMedia-3.0"):Fetch("font", "Quazii") or "Fonts\\FRIZQT__.TTF"
                posText:SetFont(fontPath, 10, "OUTLINE")
                posText:SetPoint("BOTTOM", overlay, "TOP", 0, 4)
                posText:SetTextColor(0.2, 0.6, 1, 1)
                overlay.posText = posText

                -- Make draggable
                overlay:EnableMouse(true)
                overlay:RegisterForDrag("LeftButton")
                overlay:SetScript("OnDragStart", function()
                    if InCombatLockdown() then return end
                    header:StartMoving()
                end)
                overlay:SetScript("OnDragStop", function()
                    header:StopMovingOrSizing()
                    -- Save position
                    local db = GetDB()
                    if db and db.position then
                        local _, _, _, x, y = header:GetPoint(1)
                        db.position.offsetX = x
                        db.position.offsetY = y
                    end
                    -- Update position text
                    self:UpdatePositionText(overlay, header)
                end)

                editOverlays[headerKey] = overlay
            end

            editOverlays[headerKey]:Show()
            self:UpdatePositionText(editOverlays[headerKey], header)
        end
    end

    -- If not in a group, enable test mode
    if not IsInGroup() and not IsInRaid() then
        self:EnableTestMode("party")
    end
end

function QUI_GFEM:DisableEditMode()
    if not isEditMode then return end
    isEditMode = false

    local GF = ns.QUI_GroupFrames
    if GF then GF.editMode = false end

    -- Hide overlays
    for _, overlay in pairs(editOverlays) do
        overlay:Hide()
    end

    -- Disable test mode if active
    if isTestMode then
        self:DisableTestMode()
    end
end

function QUI_GFEM:ToggleEditMode()
    if isEditMode then
        self:DisableEditMode()
    else
        self:EnableEditMode()
    end
end

function QUI_GFEM:IsEditMode()
    return isEditMode
end

function QUI_GFEM:UpdatePositionText(overlay, header)
    if not overlay or not overlay.posText or not header then return end
    local _, _, _, x, y = header:GetPoint(1)
    if x and y then
        overlay.posText:SetText(format("X: %.0f  Y: %.0f", x, y))
    end
end

---------------------------------------------------------------------------
-- NUDGE: Pixel-level positioning
---------------------------------------------------------------------------
function QUI_GFEM:NudgeHeader(headerKey, dx, dy)
    local GF = ns.QUI_GroupFrames
    if not GF then return end
    local header = GF.headers[headerKey]
    if not header then return end
    if InCombatLockdown() then return end

    local db = GetDB()
    if not db or not db.position then return end

    db.position.offsetX = (db.position.offsetX or 0) + dx
    db.position.offsetY = (db.position.offsetY or 0) + dy

    header:ClearAllPoints()
    header:SetPoint("CENTER", UIParent, "CENTER", db.position.offsetX, db.position.offsetY)

    if editOverlays[headerKey] then
        self:UpdatePositionText(editOverlays[headerKey], header)
    end
end

---------------------------------------------------------------------------
-- SPOTLIGHT: Pin specific members to a separate group
---------------------------------------------------------------------------
function QUI_GFEM:CreateSpotlightHeader()
    local db = GetDB()
    if not db or not db.spotlight or not db.spotlight.enabled then return end
    if InCombatLockdown() then return end

    if spotlightHeader then return spotlightHeader end

    local initConfigFunc = [[
        local header = self:GetParent()
        self:SetWidth(header:GetAttribute("_initialAttribute-unit-width") or 200)
        self:SetHeight(header:GetAttribute("_initialAttribute-unit-height") or 40)
        self:SetAttribute("*type1", "target")
        self:SetAttribute("*type2", "togglemenu")
        RegisterUnitWatch(self)
    ]]

    spotlightHeader = CreateFrame("Frame", "QUI_SpotlightHeader", UIParent, "SecureGroupHeaderTemplate")
    spotlightHeader:SetAttribute("template", "SecureUnitButtonTemplate, BackdropTemplate")
    spotlightHeader:SetAttribute("initialConfigFunction", initConfigFunc)
    spotlightHeader:SetAttribute("showRaid", true)
    spotlightHeader:SetAttribute("showParty", true)

    -- Filter by role
    local roles = db.spotlight.byRole
    if roles and #roles > 0 then
        spotlightHeader:SetAttribute("groupBy", "ASSIGNEDROLE")
        spotlightHeader:SetAttribute("groupingOrder", table.concat(roles, ","))
    end

    -- Dimensions
    local dims = db.dimensions
    local w = dims and dims.partyWidth or 200
    local h = dims and dims.partyHeight or 40
    if not db.spotlight.useMainFrameStyle then
        -- Could have separate dimensions, for now use main
    end
    spotlightHeader:SetAttribute("_initialAttribute-unit-width", w)
    spotlightHeader:SetAttribute("_initialAttribute-unit-height", h)

    -- Grow direction
    local spacing = db.spotlight.spacing or 2
    local grow = db.spotlight.growDirection or "DOWN"
    if grow == "DOWN" then
        spotlightHeader:SetAttribute("point", "TOP")
        spotlightHeader:SetAttribute("yOffset", -spacing)
    else
        spotlightHeader:SetAttribute("point", "BOTTOM")
        spotlightHeader:SetAttribute("yOffset", spacing)
    end

    -- Position
    local pos = db.spotlight.position
    spotlightHeader:SetPoint("CENTER", UIParent, "CENTER",
        pos and pos.offsetX or -400, pos and pos.offsetY or 200)
    spotlightHeader:SetMovable(true)
    spotlightHeader:SetClampedToScreen(true)

    -- Decorate children after a delay
    C_Timer.After(0.2, function()
        local GF = ns.QUI_GroupFrames
        if GF then
            local i = 1
            while true do
                local child = spotlightHeader:GetAttribute("child" .. i)
                if not child then break end
                -- Reuse the same decoration function
                if not child._quiDecorated then
                    -- We can't call DecorateGroupFrame directly since it's local,
                    -- but the child frames should already be decorated by the header system
                end
                i = i + 1
            end
        end
    end)

    spotlightHeader:Show()
    return spotlightHeader
end

function QUI_GFEM:DestroySpotlightHeader()
    if spotlightHeader then
        if not InCombatLockdown() then
            spotlightHeader:Hide()
        end
        spotlightHeader = nil
    end
end

---------------------------------------------------------------------------
-- SLASH COMMAND: /qui grouptest
---------------------------------------------------------------------------
-- Registered in init.lua via the existing slash command handler
-- This function is called from there
function QUI_GFEM:HandleSlashCommand(args)
    if args == "party" then
        self:ToggleTestMode("party")
    elseif args == "raid" then
        self:ToggleTestMode("raid")
    elseif args == "edit" then
        self:ToggleEditMode()
    else
        -- Default: toggle party test
        self:ToggleTestMode("party")
    end
end

---------------------------------------------------------------------------
-- BLIZZARD EDIT MODE INTEGRATION
---------------------------------------------------------------------------
local function OnEditModeEnter()
    -- Show our frames for positioning
    QUI_GFEM:EnableEditMode()
end

local function OnEditModeExit()
    QUI_GFEM:DisableEditMode()
end

-- Hook Blizzard Edit Mode via QUICore callback registry
QUICore:RegisterEditModeEnter(function()
    local db = GetDB()
    if not db or not db.enabled then return end
    OnEditModeEnter()
end)

QUICore:RegisterEditModeExit(function()
    local db = GetDB()
    if not db or not db.enabled then return end
    OnEditModeExit()
end)
