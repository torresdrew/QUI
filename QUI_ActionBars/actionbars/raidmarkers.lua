--[[
    QUI Raid Markers Bar — Owned Engine
    A small bar of secure buttons that place raid target markers (skull / cross /
    etc.) on the current target. Uses SecureActionButtonTemplate with the blessed
    type="raidtarget" action so placement works in combat — the underlying
    SetRaidTarget is restricted and only fires through a secure click.

    Combat-safety contract is cloned from totems.lua: secure attributes are set
    OUT OF COMBAT only (deferred via pendingReconcile), button/container geometry
    is never changed in combat (LayoutButtons / StyleButton / PositionContainer all
    bail or skip SetSize in combat), and visibility is alpha-only (the container
    parents secure children so its Show/Hide and EnableMouse are protected).

    Unlike totems there is no per-slot active state: all configured marker buttons
    are shown whenever the bar is enabled. Placing markers requires raid lead /
    assist in a group; the secure click silently no-ops without it (a UX note, not
    a taint issue).
]]

local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- MODULE NAMESPACE
---------------------------------------------------------------------------
local RaidMarkersBar = {}
ns.QUI_RaidMarkersBar = RaidMarkersBar

local QUICore = ns.Addon
local Helpers = ns.Helpers

-- 8 raid target markers (1 = star, … 8 = skull). World markers (flares) are a
-- deliberate follow-up: their placement-mode behavior needs in-game confirmation.
local MAX_MARKERS = 8
local BASE_CROP = 0.08

-- Per-marker icon textures (individual files, indexed 1-8).
local function MarkerTexture(i)
    return "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i
end

-- Performance: cache frequently-called globals as locals
local CreateFrame = CreateFrame
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local math_floor = math.floor

---------------------------------------------------------------------------
-- COMBAT-SAFE SHOW / HIDE (alpha + mouse enable; never Show/Hide secure children)
---------------------------------------------------------------------------
local pendingReconcile = false
local HideAllButtons

local function SafeShowButton(btn)
    btn:SetAlpha(1)
    btn.active = true
    if InCombatLockdown() then
        pendingReconcile = true
        return
    end
    btn:EnableMouse(true)
end

local function SafeHideButton(btn)
    btn:SetAlpha(0)
    btn.active = false
    if InCombatLockdown() then
        pendingReconcile = true
        return
    end
    btn:EnableMouse(false)
end

---------------------------------------------------------------------------
-- DATABASE ACCESS
---------------------------------------------------------------------------
local GetDB = Helpers.CreateDBGetter("raidMarkersBar")

---------------------------------------------------------------------------
-- GROW DIRECTION HELPERS
---------------------------------------------------------------------------
local function GrowAnchor(growDir)
    if growDir == "RIGHT" then return "LEFT"
    elseif growDir == "LEFT" then return "RIGHT"
    elseif growDir == "DOWN" then return "TOP"
    elseif growDir == "UP" then return "BOTTOM"
    end
    return "LEFT"
end

local function GetAnchorPosition(frame, anchor)
    local x, y = frame:GetCenter()
    if anchor == "LEFT" then
        x = frame:GetLeft()
    elseif anchor == "RIGHT" then
        x = frame:GetRight()
    elseif anchor == "TOP" then
        y = frame:GetTop()
    elseif anchor == "BOTTOM" then
        y = frame:GetBottom()
    end
    return x, y
end

---------------------------------------------------------------------------
-- SECURE ATTRIBUTES (set OOC only; deferred in combat)
---------------------------------------------------------------------------
local function SetMarkerAction(btn, marker)
    if not btn or not marker then return end
    if InCombatLockdown() then
        if btn._secureMarker ~= marker then
            pendingReconcile = true
        end
        return
    end
    if btn._secureMarker == marker then return end
    -- type="raidtarget" + marker N + action "toggle" on the current target.
    btn:SetAttribute("type", "raidtarget")
    btn:SetAttribute("type1", "raidtarget")
    btn:SetAttribute("*type1", "raidtarget")
    btn:SetAttribute("marker", marker)
    btn:SetAttribute("action", "toggle")
    btn:SetAttribute("unit", "target")
    btn._secureMarker = marker
end

---------------------------------------------------------------------------
-- CONTAINER + BUTTON CREATION
---------------------------------------------------------------------------
local container = CreateFrame("Frame", "QUI_RaidMarkersBar", UIParent)
container:SetFrameStrata("MEDIUM")
container:SetSize(1, 1)
container:SetMovable(true)
container:EnableMouse(false)
container:RegisterForDrag("LeftButton")
container:SetClampedToScreen(true)
container:SetAlpha(0)
container.visible = false

-- Container parents SecureActionButtonTemplate children → EnableMouse is
-- protected in combat. Toggle deferred via pendingReconcile; alpha + visible
-- flag remain combat-safe.
local function ShowContainer()
    container:SetAlpha(1)
    container.visible = true
    if InCombatLockdown() then
        pendingReconcile = true
        return
    end
    container:EnableMouse(true)
end

local function HideContainer()
    container:SetAlpha(0)
    container.visible = false
    if InCombatLockdown() then
        pendingReconcile = true
        return
    end
    container:EnableMouse(false)
end

RaidMarkersBar.container = container
RaidMarkersBar.buttons = {}
RaidMarkersBar.enabled = false

for i = 1, MAX_MARKERS do
    local btn = CreateFrame("Button", "QUI_RaidMarkersBarButton" .. i, container, "SecureActionButtonTemplate")
    btn:SetSize(36, 36)
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    btn.active = false
    -- Register both directions so the secure click fires regardless of the
    -- ActionButtonUseKeyDown CVar (same reasoning as the totem bar).
    btn:RegisterForClicks("AnyDown", "AnyUp")
    SetMarkerAction(btn, i)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.icon:SetTexture(MarkerTexture(i))

    -- Border (behind icon)
    btn.border = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.border:SetColorTexture(0, 0, 0, 1)

    btn.marker = i
    RaidMarkersBar.buttons[i] = btn
end

HideAllButtons = function()
    for i = 1, MAX_MARKERS do
        SafeHideButton(RaidMarkersBar.buttons[i])
    end
end

---------------------------------------------------------------------------
-- STYLE A SINGLE BUTTON
---------------------------------------------------------------------------
local function StyleButton(btn)
    local db = GetDB()
    if not db or not btn then return end

    local size = db.iconSize or 36
    if not InCombatLockdown() then
        btn:SetSize(size, size)
    end

    local zoom = db.zoom or 0
    local left = BASE_CROP + zoom
    local right = 1 - BASE_CROP - zoom
    btn.icon:SetTexCoord(left, right, left, right)

    local bs = db.borderSize or 2
    if bs > 0 then
        local bpx = (QUICore and QUICore.Pixels) and QUICore:Pixels(bs, btn) or bs
        btn.border:Show()
        btn.border:ClearAllPoints()
        btn.border:SetPoint("TOPLEFT", -bpx, bpx)
        btn.border:SetPoint("BOTTOMRIGHT", bpx, -bpx)
    else
        btn.border:Hide()
    end
end

---------------------------------------------------------------------------
-- LAYOUT BUTTONS (no-op in combat — secure SetPoint is protected)
---------------------------------------------------------------------------
local function LayoutButtons()
    if InCombatLockdown() then
        pendingReconcile = true
        return
    end
    local db = GetDB()
    if not db then return end

    local growDir = db.growDirection or "RIGHT"
    local spacing = db.spacing or 4
    local iconSize = db.iconSize or 36

    for i = 1, MAX_MARKERS do
        local btn = RaidMarkersBar.buttons[i]
        btn:SetSize(iconSize, iconSize)
        btn:ClearAllPoints()
        local offset = (i - 1) * (iconSize + spacing)
        if growDir == "RIGHT" then
            btn:SetPoint("LEFT", container, "LEFT", offset, 0)
        elseif growDir == "LEFT" then
            btn:SetPoint("RIGHT", container, "RIGHT", -offset, 0)
        elseif growDir == "DOWN" then
            btn:SetPoint("TOP", container, "TOP", 0, -offset)
        elseif growDir == "UP" then
            btn:SetPoint("BOTTOM", container, "BOTTOM", 0, offset)
        end
    end

    -- Container sized to the full bar extent so the anchor engine sees a stable rect.
    if growDir == "RIGHT" or growDir == "LEFT" then
        container:SetSize(MAX_MARKERS * iconSize + (MAX_MARKERS - 1) * spacing, iconSize)
    else
        container:SetSize(iconSize, MAX_MARKERS * iconSize + (MAX_MARKERS - 1) * spacing)
    end

    local anchoring = ns.QUI_Anchoring
    if anchoring and anchoring.ApplyFrameAnchor and QUICore
       and QUICore.db and QUICore.db.profile and QUICore.db.profile.frameAnchoring then
        local settings = QUICore.db.profile.frameAnchoring.raidMarkersBar
        if settings then
            anchoring:ApplyFrameAnchor("raidMarkersBar", settings)
        end
    end
end

---------------------------------------------------------------------------
-- POSITIONING
---------------------------------------------------------------------------
local function PositionContainer()
    if InCombatLockdown() then return end
    if _G.QUI_HasFrameAnchor and _G.QUI_HasFrameAnchor("raidMarkersBar") then return end

    local db = GetDB()
    if not db then return end

    container:ClearAllPoints()
    local anchor = GrowAnchor(db.growDirection or "RIGHT")
    local offsetX = db.offsetX or 0
    local offsetY = db.offsetY or -200
    container:SetPoint(anchor, UIParent, "CENTER", offsetX, offsetY)
end

---------------------------------------------------------------------------
-- SHOW ALL CONFIGURED MARKER BUTTONS
---------------------------------------------------------------------------
local function ShowMarkers()
    if RaidMarkersBar.previewing then return end
    local db = GetDB()
    if not db or not db.enabled then return end

    for i = 1, MAX_MARKERS do
        local btn = RaidMarkersBar.buttons[i]
        SetMarkerAction(btn, i)
        StyleButton(btn)
        SafeShowButton(btn)
    end

    LayoutButtons()

    if not container.visible then
        ShowContainer()
    end
end

---------------------------------------------------------------------------
-- ENABLE / DISABLE
---------------------------------------------------------------------------
local function Enable()
    if RaidMarkersBar.enabled then return end
    RaidMarkersBar.enabled = true
    PositionContainer()
    if not container:IsShown() then container:Show() end
    ShowMarkers()
end

local function Disable()
    if not RaidMarkersBar.enabled then return end
    RaidMarkersBar.enabled = false
    HideAllButtons()
    HideContainer()
end

---------------------------------------------------------------------------
-- DRAG HANDLERS
---------------------------------------------------------------------------
container:SetScript("OnDragStart", function(self)
    local db = GetDB()
    if db and not db.locked then
        self:StartMoving()
    end
end)

container:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local db = GetDB()
    if not db then return end

    local anchor = GrowAnchor(db.growDirection or "RIGHT")
    local anchorX, anchorY = GetAnchorPosition(self, anchor)
    local screenX, screenY = UIParent:GetCenter()
    if anchorX and anchorY and screenX and screenY then
        if QUICore and QUICore.PixelRound then
            db.offsetX = QUICore:PixelRound(anchorX - screenX)
            db.offsetY = QUICore:PixelRound(anchorY - screenY)
        else
            db.offsetX = math_floor(anchorX - screenX + 0.5)
            db.offsetY = math_floor(anchorY - screenY + 0.5)
        end
    end
    PositionContainer()
end)

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------
function RaidMarkersBar:Refresh()
    local db = GetDB()
    if not db or not db.enabled then
        Disable()
        return
    end
    Enable()
    PositionContainer()
    ShowMarkers()
end

function RaidMarkersBar:Hide()
    Disable()
end

---------------------------------------------------------------------------
-- PREVIEW (shown on the container's own buttons)
---------------------------------------------------------------------------
RaidMarkersBar.previewing = false

local function ShowMockMarkers()
    local db = GetDB()
    if not db then return end
    for i = 1, MAX_MARKERS do
        local btn = RaidMarkersBar.buttons[i]
        StyleButton(btn)
        SafeShowButton(btn)
    end
    LayoutButtons()
end

local function ClearMockMarkers()
    HideAllButtons()
end

function RaidMarkersBar:ShowPreview()
    self.previewing = true
    PositionContainer()
    if not container:IsShown() then container:Show() end
    ShowContainer()
    ShowMockMarkers()
end

function RaidMarkersBar:HidePreview()
    if not self.previewing then return end
    self.previewing = false
    ClearMockMarkers()
    if self.enabled then
        ShowMarkers()
    else
        HideContainer()
    end
end

function RaidMarkersBar:IsPreviewShown()
    return self.previewing
end

---------------------------------------------------------------------------
-- GLOBAL CALLBACKS (for options / layout mode)
---------------------------------------------------------------------------
_G.QUI_RefreshRaidMarkersBar = function()
    RaidMarkersBar:Refresh()
    if RaidMarkersBar:IsPreviewShown() then
        ShowMockMarkers()
    end
end

_G.QUI_ShowRaidMarkersBarPreview = function()
    RaidMarkersBar:ShowPreview()
end

_G.QUI_HideRaidMarkersBarPreview = function()
    RaidMarkersBar:HidePreview()
end

if ns.Registry then
    ns.Registry:Register("raidMarkersBar", {
        refresh = _G.QUI_RefreshRaidMarkersBar,
        priority = 20,
        group = "frames",
        importCategories = { "actionBars" },
    })
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingReconcile then
            pendingReconcile = false
            if RaidMarkersBar.previewing then
                PositionContainer()
                ShowContainer()
                ShowMockMarkers()
            elseif RaidMarkersBar.enabled then
                PositionContainer()
                ShowMarkers()
            else
                HideAllButtons()
                HideContainer()
            end
        end
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        if QUICore then
            QUICore.RaidMarkersBar = RaidMarkersBar
        end
        C_Timer.After(0.6, function()
            RaidMarkersBar:Refresh()
        end)
    end
end)
