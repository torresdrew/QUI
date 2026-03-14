---------------------------------------------------------------------------
-- QUI Layout Mode — Settings Panel
-- Context-aware settings panel that appears when a mover is selected
-- in Layout Mode. Modules register providers for their frame keys.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local QUI_LayoutMode_Settings = {}
ns.QUI_LayoutMode_Settings = QUI_LayoutMode_Settings

-- Accent color (#34D399)
local ACCENT_R, ACCENT_G, ACCENT_B = 0.204, 0.827, 0.600

-- Panel constants
local PANEL_WIDTH = 420
local PANEL_HEIGHT = 650
local PANEL_STRATA = "FULLSCREEN_DIALOG"
local PANEL_LEVEL = 200
local TITLE_HEIGHT = 32
local CONTENT_PADDING = 12
local BORDER_SIZE = 1

-- Scroll speed
local SCROLL_STEP = 60

-- State
QUI_LayoutMode_Settings._providers = {}  -- { [key] = { build, refresh } }
QUI_LayoutMode_Settings._currentKey = nil
QUI_LayoutMode_Settings._panel = nil
QUI_LayoutMode_Settings._built = false

---------------------------------------------------------------------------
-- PROVIDER REGISTRY
---------------------------------------------------------------------------

--- Register a settings provider for a frame key (or array of keys).
--- @param key string|table Single key or array of keys
--- @param provider table { build = function(content, key, width) → height, refresh = function() }
function QUI_LayoutMode_Settings:RegisterProvider(key, provider)
    if type(key) == "table" then
        for _, k in ipairs(key) do
            self._providers[k] = provider
        end
    else
        self._providers[key] = provider
    end
end

--- Check if a provider exists for a key.
function QUI_LayoutMode_Settings:HasProvider(key)
    return self._providers[key] ~= nil
end

---------------------------------------------------------------------------
-- PANEL CREATION
---------------------------------------------------------------------------

local function CreateBorderLine(parent, p1, r1, p2, r2, isHoriz, r, g, b, a)
    local line = parent:CreateTexture(nil, "BORDER")
    line:SetColorTexture(r or ACCENT_R, g or ACCENT_G, b or ACCENT_B, a or 0.6)
    line:ClearAllPoints()
    line:SetPoint(p1, parent, r1, 0, 0)
    line:SetPoint(p2, parent, r2, 0, 0)
    if isHoriz then
        line:SetHeight(BORDER_SIZE)
    else
        line:SetWidth(BORDER_SIZE)
    end
    return line
end

local function SafeGetVerticalScrollRange(scrollFrame)
    local ok, maxScroll = pcall(scrollFrame.GetVerticalScrollRange, scrollFrame)
    if not ok then return 0 end
    local ok2, safeMax = pcall(function() return math.max(0, maxScroll or 0) end)
    return ok2 and safeMax or 0
end

local function SafeGetVerticalScroll(scrollFrame)
    local ok, currentScroll = pcall(scrollFrame.GetVerticalScroll, scrollFrame)
    if not ok then return 0 end
    local ok2, safeCurrent = pcall(function() return currentScroll + 0 end)
    return ok2 and safeCurrent or 0
end

local function CreatePanel()
    local panel = CreateFrame("Frame", "QUI_LayoutMode_SettingsPanel", UIParent)
    panel:SetFrameStrata(PANEL_STRATA)
    panel:SetFrameLevel(PANEL_LEVEL)
    panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:Hide()

    -- Background
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.067, 0.094, 0.153, 0.97)

    -- Border
    CreateBorderLine(panel, "TOPLEFT", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", true)
    CreateBorderLine(panel, "BOTTOMLEFT", "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT", true)
    CreateBorderLine(panel, "TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", false)
    CreateBorderLine(panel, "TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT", false)

    -- Title bar background
    local titleBg = panel:CreateTexture(nil, "ARTWORK")
    titleBg:SetPoint("TOPLEFT", BORDER_SIZE, -BORDER_SIZE)
    titleBg:SetPoint("TOPRIGHT", -BORDER_SIZE, -BORDER_SIZE)
    titleBg:SetHeight(TITLE_HEIGHT)
    titleBg:SetColorTexture(0.04, 0.06, 0.1, 1)

    -- Title bar bottom line
    local titleLine = panel:CreateTexture(nil, "ARTWORK", nil, 1)
    titleLine:SetPoint("TOPLEFT", titleBg, "BOTTOMLEFT")
    titleLine:SetPoint("TOPRIGHT", titleBg, "BOTTOMRIGHT")
    titleLine:SetHeight(BORDER_SIZE)
    titleLine:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.4)

    -- Title text
    local titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", titleBg, "LEFT", 12, 0)
    titleText:SetPoint("RIGHT", titleBg, "RIGHT", -32, 0)
    titleText:SetJustifyH("LEFT")
    titleText:SetTextColor(1, 1, 1, 1)
    titleText:SetText("Settings")
    panel._titleText = titleText

    -- Close button
    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", titleBg, "RIGHT", -6, 0)

    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeTxt:SetPoint("CENTER")
    closeTxt:SetText("X")
    closeTxt:SetTextColor(0.6, 0.65, 0.7, 1)

    closeBtn:SetScript("OnEnter", function()
        closeTxt:SetTextColor(1, 0.3, 0.3, 1)
    end)
    closeBtn:SetScript("OnLeave", function()
        closeTxt:SetTextColor(0.6, 0.65, 0.7, 1)
    end)
    closeBtn:SetScript("OnClick", function()
        QUI_LayoutMode_Settings:Hide()
    end)

    -- Drag handle (title bar)
    local dragHandle = CreateFrame("Frame", nil, panel)
    dragHandle:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    dragHandle:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, 0)
    dragHandle:SetHeight(TITLE_HEIGHT)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function()
        panel:StartMoving()
    end)
    dragHandle:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
    end)

    -- Scroll frame for content
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", CONTENT_PADDING, -(TITLE_HEIGHT + CONTENT_PADDING))
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -(CONTENT_PADDING + 22), CONTENT_PADDING)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(PANEL_WIDTH - (CONTENT_PADDING * 2) - 22)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    -- Style scrollbar
    local scrollBar = scrollFrame.ScrollBar
    if scrollBar then
        scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 4, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 4, 16)
        local thumb = scrollBar:GetThumbTexture()
        if thumb then
            thumb:SetColorTexture(0.35, 0.45, 0.5, 0.8)
        end
        local scrollUp = scrollBar.ScrollUpButton or scrollBar.Back
        local scrollDown = scrollBar.ScrollDownButton or scrollBar.Forward
        if scrollUp then scrollUp:Hide(); scrollUp:SetAlpha(0) end
        if scrollDown then scrollDown:Hide(); scrollDown:SetAlpha(0) end

        -- Auto-hide scrollbar when not needed
        scrollBar:HookScript("OnShow", function(self)
            C_Timer.After(0.066, function()
                local maxScroll = SafeGetVerticalScrollRange(scrollFrame)
                if maxScroll <= 1 then
                    self:Hide()
                end
            end)
        end)
    end

    -- Mouse wheel scrolling
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local currentScroll = SafeGetVerticalScroll(self)
        local maxScroll = SafeGetVerticalScrollRange(self)
        local okNew, newScroll = pcall(function()
            return math.max(0, math.min(currentScroll - (delta * SCROLL_STEP), maxScroll))
        end)
        if okNew then
            pcall(self.SetVerticalScroll, self, newScroll)
        end
    end)

    panel._scrollFrame = scrollFrame
    panel._content = content

    -- Placeholder message (shown when no provider exists)
    local placeholder = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    placeholder:SetPoint("TOP", content, "TOP", 0, -40)
    placeholder:SetTextColor(0.6, 0.65, 0.7, 1)
    placeholder:SetText("No settings available for this frame.")
    placeholder:SetJustifyH("CENTER")
    placeholder:Hide()
    panel._placeholder = placeholder

    return panel
end

---------------------------------------------------------------------------
-- POSITIONING (near the selected mover)
---------------------------------------------------------------------------

local function PositionNearMover(panel, moverFrame)
    if not moverFrame then return end

    local moverCX, moverCY = moverFrame:GetCenter()
    if not moverCX or not moverCY then return end

    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    local panelW, panelH = panel:GetSize()

    -- Determine which side has more space
    local spaceRight = screenW - moverFrame:GetRight()
    local spaceLeft = moverFrame:GetLeft()
    local spaceAbove = screenH - moverFrame:GetTop()
    local spaceBelow = moverFrame:GetBottom()

    local x, y

    -- Prefer horizontal placement (left/right of mover)
    local margin = 12
    if spaceRight >= panelW + margin then
        x = moverFrame:GetRight() + margin
    elseif spaceLeft >= panelW + margin then
        x = moverFrame:GetLeft() - panelW - margin
    else
        -- Center horizontally if neither side has space
        x = math.max(4, math.min(moverCX - panelW / 2, screenW - panelW - 4))
    end

    -- Vertical: try to align top with mover top, clamp to screen
    y = math.min(moverFrame:GetTop(), screenH - 4)
    y = math.max(y, panelH + 4)

    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
end

---------------------------------------------------------------------------
-- CONTENT MANAGEMENT
---------------------------------------------------------------------------

local function ClearContent(panel)
    local content = panel._content
    -- Hide and release children
    for _, child in pairs({content:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    -- Hide font strings (except placeholder)
    for _, region in pairs({content:GetRegions()}) do
        if region ~= panel._placeholder then
            region:Hide()
        end
    end
    panel._placeholder:Hide()
    content:SetHeight(1)
    pcall(panel._scrollFrame.SetVerticalScroll, panel._scrollFrame, 0)
end

local function BuildContent(panel, key)
    ClearContent(panel)

    local provider = QUI_LayoutMode_Settings._providers[key]
    if not provider or not provider.build then
        panel._placeholder:Show()
        panel._content:SetHeight(80)
        return
    end

    local content = panel._content
    local contentWidth = content:GetWidth()
    local ok, totalHeight = pcall(provider.build, content, key, contentWidth)

    if ok and totalHeight and totalHeight > 0 then
        content:SetHeight(totalHeight)
    else
        -- Fallback: measure children
        local maxBottom = 0
        for _, child in pairs({content:GetChildren()}) do
            if child:IsShown() then
                local bottom = -(child:GetBottom() and (content:GetTop() - child:GetBottom()) or 0)
                if bottom > maxBottom then maxBottom = bottom end
            end
        end
        content:SetHeight(math.max(maxBottom + 20, 80))
    end
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

function QUI_LayoutMode_Settings:Show(key)
    if not key then
        self:Hide()
        return
    end

    if not self._panel then
        self._panel = CreatePanel()
    end

    local panel = self._panel
    local um = ns.QUI_LayoutMode
    local def = um and um._elements and um._elements[key]
    local label = def and def.label or key

    panel._titleText:SetText("|cff34D399" .. label .. "|r Settings")

    -- New key: rebuild content, only reposition if panel isn't already open
    if self._currentKey ~= key then
        local wasShown = panel:IsShown()
        self._currentKey = key
        BuildContent(panel, key)

        -- Position near mover only on first open (not when switching between movers)
        if not wasShown then
            local mover = um and um._handles and um._handles[key]
            if mover and not panel._userDragged then
                PositionNearMover(panel, mover)
            end
        end
    end

    panel:Show()
end

function QUI_LayoutMode_Settings:Hide()
    if self._panel then
        self._panel:Hide()
    end
end

function QUI_LayoutMode_Settings:Reset()
    self:Hide()
    self._currentKey = nil
end

function QUI_LayoutMode_Settings:IsShown()
    return self._panel and self._panel:IsShown()
end

function QUI_LayoutMode_Settings:GetCurrentKey()
    return self._currentKey
end

--- Force rebuild of current content (e.g., after DB change).
function QUI_LayoutMode_Settings:Refresh()
    if not self._currentKey or not self._panel or not self._panel:IsShown() then return end
    local provider = self._providers[self._currentKey]
    if provider and provider.refresh then
        pcall(provider.refresh)
    end
end

--- Reset state when Layout Mode closes.
function QUI_LayoutMode_Settings:Reset()
    self:Hide()
    self._currentKey = nil
    if self._panel then
        self._panel._userDragged = nil
    end
end
