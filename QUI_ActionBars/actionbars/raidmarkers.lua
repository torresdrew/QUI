--[[
    QUI Raid Markers Bar / Leader Toolbar — Owned Engine
    Row 1: secure buttons that place raid target markers (skull / cross / etc.)
    on the current target via the blessed type="raidtarget" action.
    Row 2: secure buttons that place world markers (flares) on the ground via
    the blessed type="worldmarker" action (left-click places / re-places,
    right-click clears — mirroring Blizzard's own raid manager UX), plus a
    clear-all-flares button.
    Row 3: a leader action strip — ready check, role poll, pull countdown.
    These are plain (insecure) buttons: DoReadyCheck / InitiateRolePoll /
    DoCountdown are callable from normal code.

    Rows 2 and 3 are leader-gated by default: they appear only while the
    player is group leader (or raid assist), driven by a coalesced
    GROUP_ROSTER_UPDATE / PARTY_LEADER_CHANGED watcher (GRU fires in bursts).

    Combat-safety contract is cloned from totems.lua: secure attributes are set
    OUT OF COMBAT only (deferred via pendingReconcile), button/container geometry
    is never changed in combat (LayoutButtons / StyleButton / PositionContainer all
    bail or skip SetSize in combat), and visibility is alpha-only (the container
    parents secure children so its Show/Hide and EnableMouse are protected).
    The strip buttons are not secure, but they live in the same container and
    follow the same alpha-only visibility rules for uniformity.

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

-- 8 raid target markers (1 = star, … 8 = skull).
local MAX_MARKERS = 8
local BASE_CROP = 0.08

-- World markers project the same 8 symbols onto the ground, but display slot d
-- places world marker WORLD_MARKER_ORDER[d] — the mapping Blizzard's own
-- CompactRaidFrameManager uses (its buttons show symbol d via the
-- "GM-raidMarker"..d atlas and place WORLD_RAID_MARKER_ORDER[d]).
local MAX_WORLD_MARKERS = 8
local WORLD_MARKER_ORDER = { 8, 4, 1, 7, 2, 3, 6, 5 }

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
local L = ns.L

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
-- LEADERSHIP STATE (drives visibility of the world-marker and strip rows)
---------------------------------------------------------------------------
local isLeaderish = false

local function ComputeLeaderish()
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    end
    if IsInGroup() then
        return UnitIsGroupLeader("player") == true
    end
    return false
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

local function SetWorldMarkerAction(btn, displayIndex)
    if not btn or not displayIndex then return end
    local marker = WORLD_MARKER_ORDER[displayIndex]
    if InCombatLockdown() then
        if btn._secureWorldMarker ~= marker then
            pendingReconcile = true
        end
        return
    end
    if btn._secureWorldMarker == marker then return end
    -- type="worldmarker": left-click places / re-places the flare
    -- (action1 "set"), right-click clears it (action2 "clear") — the same
    -- UX as Blizzard's raid manager, which never uses "toggle" for flares.
    btn:SetAttribute("type", "worldmarker")
    btn:SetAttribute("type1", "worldmarker")
    btn:SetAttribute("*type1", "worldmarker")
    btn:SetAttribute("type2", "worldmarker")
    btn:SetAttribute("marker", marker)
    btn:SetAttribute("action1", "set")
    btn:SetAttribute("action2", "clear")
    btn._secureWorldMarker = marker
end

local function SetWorldClearAction(btn)
    if not btn then return end
    if InCombatLockdown() then
        if not btn._secureWorldClear then
            pendingReconcile = true
        end
        return
    end
    if btn._secureWorldClear then return end
    -- "clear" with NO marker attribute → ClearRaidMarker(nil) clears ALL
    -- world markers (SECURE_ACTIONS.worldmarker passes the nil through;
    -- same behavior as Blizzard's /cwm with no argument).
    btn:SetAttribute("type", "worldmarker")
    btn:SetAttribute("type1", "worldmarker")
    btn:SetAttribute("*type1", "worldmarker")
    btn:SetAttribute("action", "clear")
    btn._secureWorldClear = true
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
RaidMarkersBar.worldRow = {}   -- 8 flare buttons + the clear-all button
RaidMarkersBar.stripRow = {}   -- ready check / role poll / pull countdown
RaidMarkersBar.enabled = false

local function AttachTooltip(btn, title, body)
    btn:SetScript("OnEnter", function(self)
        if not self.active then return end
        local tt = _G.GameTooltip
        if not tt then return end
        tt:SetOwner(self, "ANCHOR_RIGHT")
        tt:SetText(title, 1, 1, 1)
        if body then
            tt:AddLine(body, nil, nil, nil, true)
        end
        tt:Show()
    end)
    btn:SetScript("OnLeave", function()
        local tt = _G.GameTooltip
        if tt then tt:Hide() end
    end)
end

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

-- World-marker (flare) row: same symbol icons as row 1; the secure marker
-- attribute carries the WORLD_MARKER_ORDER mapping so the projected flare
-- matches the symbol on the button.
for i = 1, MAX_WORLD_MARKERS do
    local btn = CreateFrame("Button", "QUI_RaidMarkersBarWorldButton" .. i, container, "SecureActionButtonTemplate")
    btn:SetSize(36, 36)
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    btn.active = false
    btn:RegisterForClicks("AnyDown", "AnyUp")
    SetWorldMarkerAction(btn, i)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.icon:SetTexture(MarkerTexture(i))

    btn.border = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.border:SetColorTexture(0, 0, 0, 1)

    btn.worldMarker = WORLD_MARKER_ORDER[i]
    AttachTooltip(btn, L["World Marker"],
        L["Left-click: place or move this flare on the ground. Right-click: clear it."])
    RaidMarkersBar.worldRow[i] = btn
end

do
    local btn = CreateFrame("Button", "QUI_RaidMarkersBarWorldClearButton", container, "SecureActionButtonTemplate")
    btn:SetSize(36, 36)
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    btn.active = false
    btn:RegisterForClicks("AnyDown", "AnyUp")
    SetWorldClearAction(btn)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.icon:SetAtlas("GM-raidMarker-remove")
    btn.iconIsAtlas = true  -- StyleButton must not apply zoom texcoords

    btn.border = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.border:SetColorTexture(0, 0, 0, 1)

    AttachTooltip(btn, L["Clear World Markers"], L["Remove all placed flares."])
    RaidMarkersBar.worldRow[MAX_WORLD_MARKERS + 1] = btn
end

-- Leader action strip: plain (insecure) buttons — DoReadyCheck /
-- InitiateRolePoll / DoCountdown are callable from normal code. Permission
-- failures print a hint instead of silently no-opping.
local function PrintHint(msg)
    print("|cFF30D1FFQUI:|r " .. msg)
end

local STRIP_DEFS = {
    {
        name = "ReadyCheck",
        atlas = "GM-icon-readyCheck",
        title = L["Ready Check"],
        body = L["Start a ready check. Requires group lead or raid assist."],
        onClick = function()
            if not ComputeLeaderish() then
                PrintHint(L["Ready checks require group lead or raid assist."])
                return
            end
            if C_PartyInfo and C_PartyInfo.DoReadyCheck then
                C_PartyInfo.DoReadyCheck()
            end
        end,
    },
    {
        name = "RolePoll",
        atlas = "GM-icon-roles",
        title = L["Role Poll"],
        body = L["Ask everyone to confirm their role. Requires group lead."],
        onClick = function()
            if not UnitIsGroupLeader("player") then
                PrintHint(L["Role polls require group lead."])
                return
            end
            if InitiateRolePoll then
                InitiateRolePoll()
            end
        end,
    },
    {
        name = "Pull",
        atlas = "GM-icon-countdown",
        title = L["Pull Countdown"],
        body = L["Left-click: start the pull countdown. Right-click: cancel it."],
        onClick = function(_, mouseButton)
            if not (C_PartyInfo and C_PartyInfo.DoCountdown) then
                PrintHint(L["Pull countdown is not available on this client."])
                return
            end
            if mouseButton == "RightButton" then
                C_PartyInfo.DoCountdown(0)
                return
            end
            local db = GetDB()
            local secs = db and db.leaderStrip and db.leaderStrip.pullSeconds or 10
            local ok = C_PartyInfo.DoCountdown(secs)
            if not ok then
                PrintHint(L["Could not start pull countdown (need to be in a group and have permission)."])
            end
        end,
    },
}

for i, def in ipairs(STRIP_DEFS) do
    local btn = CreateFrame("Button", "QUI_RaidMarkersBarStrip" .. def.name, container)
    btn:SetSize(36, 36)
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    btn.active = false
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", def.onClick)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.icon:SetAtlas(def.atlas)
    btn.iconIsAtlas = true

    btn.border = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.border:SetColorTexture(0, 0, 0, 1)

    AttachTooltip(btn, def.title, def.body)
    RaidMarkersBar.stripRow[i] = btn
end

HideAllButtons = function()
    for i = 1, MAX_MARKERS do
        SafeHideButton(RaidMarkersBar.buttons[i])
    end
    for i = 1, #RaidMarkersBar.worldRow do
        SafeHideButton(RaidMarkersBar.worldRow[i])
    end
    for i = 1, #RaidMarkersBar.stripRow do
        SafeHideButton(RaidMarkersBar.stripRow[i])
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

    -- Atlas icons (clear-all, strip buttons) carry their own texcoords;
    -- applying the zoom crop would corrupt them.
    if not btn.iconIsAtlas then
        local zoom = db.zoom or 0
        local left = BASE_CROP + zoom
        local right = 1 - BASE_CROP - zoom
        btn.icon:SetTexCoord(left, right, left, right)
    end

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
-- ROW VISIBILITY PREDICATES
-- Preview mode (layout positioning) shows every enabled row regardless of
-- leadership; live mode applies the autoShowForLeader gate.
---------------------------------------------------------------------------
local function LeaderRowGate(db)
    if RaidMarkersBar.previewing then return true end
    if db.autoShowForLeader == false then return true end
    return isLeaderish
end

local function IsWorldRowActive(db)
    if not db then return false end
    local cfg = db.worldMarkers
    if cfg and cfg.enabled == false then return false end
    return LeaderRowGate(db)
end

local function IsStripRowActive(db)
    if not db then return false end
    local cfg = db.leaderStrip
    if cfg and cfg.enabled == false then return false end
    return LeaderRowGate(db)
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

    -- Active rows, in fixed order: target markers, world markers, strip.
    -- Rows run along the grow direction; additional rows stack on the cross
    -- axis (below for horizontal growth, to the right for vertical).
    local rows = { RaidMarkersBar.buttons }
    if IsWorldRowActive(db) then
        rows[#rows + 1] = RaidMarkersBar.worldRow
    end
    if IsStripRowActive(db) then
        rows[#rows + 1] = RaidMarkersBar.stripRow
    end

    local maxCount = 0
    for r = 1, #rows do
        local buttons = rows[r]
        if #buttons > maxCount then maxCount = #buttons end
        for i = 1, #buttons do
            local btn = buttons[i]
            btn:SetSize(iconSize, iconSize)
            btn:ClearAllPoints()
            local main = (i - 1) * (iconSize + spacing)
            local cross = (r - 1) * (iconSize + spacing)
            if growDir == "RIGHT" then
                btn:SetPoint("TOPLEFT", container, "TOPLEFT", main, -cross)
            elseif growDir == "LEFT" then
                btn:SetPoint("TOPRIGHT", container, "TOPRIGHT", -main, -cross)
            elseif growDir == "DOWN" then
                btn:SetPoint("TOPLEFT", container, "TOPLEFT", cross, -main)
            elseif growDir == "UP" then
                btn:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", cross, main)
            end
        end
    end

    -- Inactive rows are alpha-hidden but must not occupy stale points inside
    -- the new container rect; park them on the container origin.
    if not IsWorldRowActive(db) then
        for i = 1, #RaidMarkersBar.worldRow do
            RaidMarkersBar.worldRow[i]:ClearAllPoints()
            RaidMarkersBar.worldRow[i]:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        end
    end
    if not IsStripRowActive(db) then
        for i = 1, #RaidMarkersBar.stripRow do
            RaidMarkersBar.stripRow[i]:ClearAllPoints()
            RaidMarkersBar.stripRow[i]:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        end
    end

    -- Container sized to the full bar extent so the anchor engine sees a stable rect.
    local mainExtent = maxCount * iconSize + (maxCount - 1) * spacing
    local crossExtent = #rows * iconSize + (#rows - 1) * spacing
    if growDir == "RIGHT" or growDir == "LEFT" then
        container:SetSize(mainExtent, crossExtent)
    else
        container:SetSize(crossExtent, mainExtent)
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

-- Applies contents + visibility for the world-marker and strip rows (both
-- live and preview paths). Attribute writers are cached/idempotent and
-- combat-deferred internally.
local function ApplyLeaderRows(db)
    local worldActive = IsWorldRowActive(db)
    for i = 1, MAX_WORLD_MARKERS do
        local btn = RaidMarkersBar.worldRow[i]
        SetWorldMarkerAction(btn, i)
        StyleButton(btn)
        if worldActive then SafeShowButton(btn) else SafeHideButton(btn) end
    end
    local clearBtn = RaidMarkersBar.worldRow[MAX_WORLD_MARKERS + 1]
    SetWorldClearAction(clearBtn)
    StyleButton(clearBtn)
    if worldActive then SafeShowButton(clearBtn) else SafeHideButton(clearBtn) end

    local stripActive = IsStripRowActive(db)
    for i = 1, #RaidMarkersBar.stripRow do
        local btn = RaidMarkersBar.stripRow[i]
        StyleButton(btn)
        if stripActive then SafeShowButton(btn) else SafeHideButton(btn) end
    end
end

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

    ApplyLeaderRows(db)

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
    -- Preview shows every enabled row regardless of leadership (the
    -- IsWorldRowActive/IsStripRowActive gates return true while previewing)
    -- so users can position the full bar.
    ApplyLeaderRows(db)
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
-- LEADERSHIP WATCHER
-- GROUP_ROSTER_UPDATE fires in bursts of 5-20 during roster churn, so the
-- recompute is coalesced through a hidden frame's OnUpdate (one pass per
-- render frame at most; same pattern as hud_visibility.lua).
---------------------------------------------------------------------------
local leaderCoalesce = CreateFrame("Frame")
leaderCoalesce:Hide()
leaderCoalesce:SetScript("OnUpdate", function(self)
    self:Hide()
    local newState = ComputeLeaderish()
    if newState == isLeaderish then return end
    isLeaderish = newState
    if RaidMarkersBar.previewing then return end
    if not RaidMarkersBar.enabled then return end
    -- Re-applies row visibility (alpha-only in combat) and relayouts
    -- (combat-deferred inside LayoutButtons via pendingReconcile).
    ShowMarkers()
end)

local leaderWatch = CreateFrame("Frame")
leaderWatch:RegisterEvent("GROUP_ROSTER_UPDATE")
leaderWatch:RegisterEvent("PARTY_LEADER_CHANGED")
leaderWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
leaderWatch:SetScript("OnEvent", function()
    leaderCoalesce:Show()
end)

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
