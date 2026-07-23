--[[
    QUI Group Frames - Party Target Frames

    A small companion "target frame" for each PARTY member, showing that
    member's current target (name + health bar only). Each companion is a
    standalone SecureUnitButton bound to the compound unit token
    "partyNtarget", parented to and anchored beside the matching party group
    frame so it follows the group layout (no separate mover).

    Design notes:
      * PARTY ONLY. Raid would mean up to 40 extra secure frames + pollers.
      * Compound unit tokens ("party1target") are SECRET on addon-restricted
        maps. We never branch/compare a value derived from them in Lua:
          - health   -> SetValue(UnitHealthPercent(...))  (C-side forwards secrets)
          - name     -> SetText(TruncateUTF8(UnitName(...)))  (C-side forwards)
          - bar color-> class color only when issecretvalue() says it is safe to
                        read; otherwise a fixed fallback color. Never branch a secret.
      * Visibility is driven by RegisterUnitWatch on the secure button — it
        shows/hides natively (combat-safe) as the target exists or not.
      * The target unit's health does not raise reliable UNIT_HEALTH for a
        compound token, so a light ticker polls the (<=4) SHOWN frames; a
        UNIT_TARGET watch refreshes name/color the instant a member re-targets.
      * Repositioning a secure frame is combat-restricted. Parenting/anchoring
        is established out of combat and re-applied on roster change; if that
        lands mid-combat it defers to PLAYER_REGEN_ENABLED.
]]

local ADDON_NAME, ns = ...

local Helpers = ns.Helpers
local LSM = ns.LSM
local GetDB = Helpers.CreateDBGetter("quiGroupFrames")
local TruncateUTF8 = Helpers.TruncateUTF8
local ApplyFontWithFallback = Helpers.ApplyFontWithFallback

-- Hot/secret-path globals cached as locals
local CreateFrame = CreateFrame
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local RegisterUnitWatch = RegisterUnitWatch
local UnregisterUnitWatch = UnregisterUnitWatch
local UnitName = UnitName
local UnitClass = UnitClass
local UnitHealthPercent = UnitHealthPercent
local issecretvalue = _G.issecretvalue
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local CurveConstants = CurveConstants
local C_Timer = C_Timer

local MAX_PARTY = 4                 -- party1..party4 (player's own target = the unit-frame target)
local TICK_INTERVAL = 0.2           -- health drain poll for shown companions
local FALLBACK_COLOR = { 0.6, 0.6, 0.6 }  -- used when class is unreadable/secret

---------------------------------------------------------------------------
-- Subsystem table (published suite-wide via the bootstrap metatable proxy)
---------------------------------------------------------------------------
local PT = {
    frames = {},          -- index -> companion secure button
    pendingAnchor = false, -- a re-anchor was requested while restricted
    ticker = nil,
    eventFrame = nil,
    lastGF = nil,         -- cached QUI_GF handle for combat-end re-anchor
}
ns.QUI_GroupFramePartyTargets = PT

-- Forward declaration: defined with the event handlers near the bottom but
-- referenced by Configure/Teardown above them.
local SetTargetWatch

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local function GetConfig()
    local db = GetDB()
    -- Gate on the MODULE enable too: companions are unit-watched independently
    -- of the group headers, so a disabled module must still tear them down.
    if not db or not db.enabled then return nil end
    local party = db.party
    return party and party.targetFrames, party
end

local function ResolveFont(general)
    local fontName = general and general.font or "Quazii"
    return LSM:Fetch("font", fontName) or STANDARD_TEXT_FONT
end

local function ResolveTexture(general)
    local texName = general and general.texture or "Quazii v5"
    return LSM:Fetch("statusbar", texName)
end

---------------------------------------------------------------------------
-- Frame construction (OUT OF COMBAT ONLY — secure attrs/RegisterUnitWatch)
---------------------------------------------------------------------------
local function CreateCompanion(index)
    local frame = CreateFrame("Button", nil, UIParent,
        "SecureUnitButtonTemplate, BackdropTemplate")
    frame:Hide()

    -- Secure: bind the compound token and the click-to-target action.
    local unit = "party" .. index .. "target"
    frame.ptUnit = unit
    frame:SetAttribute("unit", unit)
    frame:SetAttribute("*type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")

    -- Backdrop (own cached table, 1px border) — no BorderRegistry entry needed.
    frame._quiBackdrop = {
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    }
    frame:SetBackdrop(frame._quiBackdrop)
    frame:SetBackdropColor(0, 0, 0, 1)
    frame:SetBackdropBorderColor(0, 0, 0, 1)

    -- Health bar
    local hb = CreateFrame("StatusBar", nil, frame)
    hb:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    hb:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    hb:SetMinMaxValues(0, 100)
    hb:SetValue(100)
    hb:EnableMouse(false)
    frame.healthBar = hb

    -- Name
    local name = hb:CreateFontString(nil, "OVERLAY")
    name:SetPoint("LEFT", hb, "LEFT", 3, 0)
    name:SetPoint("RIGHT", hb, "RIGHT", -3, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetTextColor(1, 1, 1, 1)
    frame.nameText = name

    return frame
end

-- Native, combat-safe show/hide based on UnitExists(unit). Idempotent so a
-- disable -> enable cycle re-arms the state driver. OOC only (secure manager).
local function EnsureWatched(frame)
    if not frame._ptWatched then
        RegisterUnitWatch(frame)
        frame._ptWatched = true
    end
end

---------------------------------------------------------------------------
-- Styling (size / texture / font) — SetSize on a secure frame is combat-
-- restricted, so callers must run this out of combat.
---------------------------------------------------------------------------
local function StyleCompanion(frame, cfg, general)
    local w = cfg.width or 120
    local h = cfg.height or 24
    frame:SetSize(w, h)

    local tex = ResolveTexture(general)
    if tex then frame.healthBar:SetStatusBarTexture(tex) end

    local fontPath = ResolveFont(general)
    local fontSize = (general and general.fontSize) or 11
    local outline = (general and general.fontOutline) or "OUTLINE"
    ApplyFontWithFallback(frame.nameText, fontPath, fontSize, outline)
    frame.nameText:SetShown(cfg.showName ~= false)
end

---------------------------------------------------------------------------
-- Per-frame render (SECRET-SAFE — never branch a compound-token value)
---------------------------------------------------------------------------
local function RenderCompanion(frame)
    local unit = frame.ptUnit
    if not unit then return end

    -- Health: forward the (possibly secret) curve result straight to SetValue.
    frame.healthBar:SetValue(UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))

    -- Name: UnitName -> TruncateUTF8 -> SetText forward secrets C-side. No
    -- `or ""` fallback: TruncateUTF8 may return a SECRET string (it formats a
    -- secret name through string.format), and `secret or ""` would branch on a
    -- secret. TruncateUTF8 already returns "" for a nil name, so SetText is safe.
    frame.nameText:SetText(TruncateUTF8(UnitName(unit), 12))

    -- Color: class color only when the class string is non-secret; else fixed.
    local r, g, b = FALLBACK_COLOR[1], FALLBACK_COLOR[2], FALLBACK_COLOR[3]
    local _, class = UnitClass(unit)
    -- Probe FIRST — `class and issecretvalue(class)` truth-tests the secret.
    -- @secret-policy: collapse-only — fixed fallback color
    local classIsSecret = issecretvalue and issecretvalue(class)
    if not classIsSecret and class then
        local cc = RAID_CLASS_COLORS[class]
        if cc then r, g, b = cc.r, cc.g, cc.b end
    end
    if r ~= frame._lr or g ~= frame._lg or b ~= frame._lb then
        frame._lr, frame._lg, frame._lb = r, g, b
        frame.healthBar:SetStatusBarColor(r, g, b, 1)
    end
end

---------------------------------------------------------------------------
-- Ticker: poll only the SHOWN companions (<=4) for health drain.
---------------------------------------------------------------------------
local function Tick()
    for i = 1, MAX_PARTY do
        local f = PT.frames[i]
        if f and f:IsShown() then
            RenderCompanion(f)
        end
    end
end

local function StartTicker()
    if not PT.ticker then
        PT.ticker = C_Timer.NewTicker(TICK_INTERVAL, Tick)
    end
end

local function StopTicker()
    if PT.ticker then
        PT.ticker:Cancel()
        PT.ticker = nil
    end
end

---------------------------------------------------------------------------
-- Anchoring: position each companion beside its party group frame. Resolves
-- the member frame by UNIT (QUI_GF.unitFrameMap), so it is correct even when
-- the party header sorts members by role.
--
-- TAINT: companions stay parented to UIParent and only SetPoint RELATIVE to
-- the member frame — a relative point makes the position follow the member
-- without re-parenting a tainted addon frame under a Blizzard secure-header
-- child (which could taint the header's secure execution). Scale is NOT
-- matched to the member here (GetEffectiveScale can return a secret); the
-- companion renders at its own configured pixel size.
---------------------------------------------------------------------------
local function ApplyAnchor(frame, memberFrame, cfg)
    local gap = cfg.anchorGap or 2
    local side = cfg.anchorTo or "BOTTOM"
    frame:ClearAllPoints()
    if side == "TOP" then
        frame:SetPoint("BOTTOM", memberFrame, "TOP", 0, gap)
    elseif side == "RIGHT" then
        frame:SetPoint("LEFT", memberFrame, "RIGHT", gap, 0)
    elseif side == "LEFT" then
        frame:SetPoint("RIGHT", memberFrame, "LEFT", -gap, 0)
    else -- BOTTOM (default)
        frame:SetPoint("TOP", memberFrame, "BOTTOM", 0, -gap)
    end
end

-- Re-anchor every companion to its current party frame. Combat-deferred:
-- repositioning a secure frame is blocked in combat, so we set a pending flag
-- and replay at PLAYER_REGEN_ENABLED.
function PT:Reanchor(QUI_GF)
    if QUI_GF then self.lastGF = QUI_GF end
    QUI_GF = QUI_GF or self.lastGF
    local cfg = GetConfig()
    if not cfg or not cfg.enabled or not QUI_GF then return end

    if InCombatLockdown() then
        self.pendingAnchor = true
        return
    end
    self.pendingAnchor = false

    local map = QUI_GF.unitFrameMap
    for i = 1, MAX_PARTY do
        local frame = self.frames[i]
        if frame then
            local list = map and map["party" .. i]
            local memberFrame = list and list[1]
            if memberFrame then
                ApplyAnchor(frame, memberFrame, cfg)
            else
                -- No party frame for this slot: clear the (possibly stale)
                -- anchor so it doesn't track a recycled member frame. The
                -- unit-watch keeps it hidden while partyNtarget doesn't exist.
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER")
            end
        end
    end
end

---------------------------------------------------------------------------
-- Configure: master entry. Creates/styles/anchors frames when enabled, or
-- tears the feature down when disabled. Secure ops require out-of-combat;
-- it is called from RefreshSettings, which is itself combat-deferred.
---------------------------------------------------------------------------
function PT:Configure(QUI_GF)
    if QUI_GF then self.lastGF = QUI_GF end
    local cfg, party = GetConfig()
    local general = party and party.general

    if not cfg or not cfg.enabled then
        self:Teardown()
        return
    end

    if InCombatLockdown() then
        -- Secure creation/sizing blocked; replay after combat.
        self.pendingAnchor = true
        return
    end

    for i = 1, MAX_PARTY do
        local frame = self.frames[i]
        if not frame then
            frame = CreateCompanion(i)
            self.frames[i] = frame
        end
        StyleCompanion(frame, cfg, general)
    end

    -- Anchor first, then arm the unit-watch, so a frame never flashes
    -- un-anchored the instant the state driver shows it.
    self:Reanchor(QUI_GF)
    for i = 1, MAX_PARTY do
        EnsureWatched(self.frames[i])
    end
    SetTargetWatch(true)
    StartTicker()
end

---------------------------------------------------------------------------
-- Teardown: hide companions + stop polling (does not destroy frames; secure
-- frames cannot be unregistered/destroyed mid-combat and are cheap to keep).
---------------------------------------------------------------------------
function PT:Teardown()
    StopTicker()
    SetTargetWatch(false)
    if InCombatLockdown() then
        -- Cannot touch the secure state driver in combat; finish the hide at
        -- the next PLAYER_REGEN_ENABLED (Configure -> Teardown OOC).
        self.pendingAnchor = true
        return
    end
    for i = 1, MAX_PARTY do
        local frame = self.frames[i]
        if frame then
            if frame._ptWatched then
                UnregisterUnitWatch(frame)
                frame._ptWatched = false
            end
            frame:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Events: own a small frame for combat-end replay + instant target-swap
-- refresh. Roster re-anchor is driven by groupframes.lua's GRU_DeferredWork
-- (it owns unitFrameMap), which calls PT:Reanchor after the rebuild.
---------------------------------------------------------------------------
local function OnEvent(_, event, arg1)
    if event == "PLAYER_REGEN_ENABLED" then
        if PT.pendingAnchor then
            PT.pendingAnchor = false
            -- Re-run a full configure: covers both a deferred enable and a
            -- deferred re-anchor that happened during combat.
            PT:Configure(PT.lastGF)
        end
    elseif event == "UNIT_TARGET" then
        -- arg1 is the unit whose target changed (e.g. "party2"). Refresh that
        -- member's companion immediately so the name/color don't lag the tick.
        if type(arg1) == "string" then
            local index = arg1:match("^party(%d)$")
            index = index and tonumber(index)
            local frame = index and PT.frames[index]
            if frame and frame:IsShown() then
                RenderCompanion(frame)
            end
        end
    end
end

local function EnsureEventFrame()
    if PT.eventFrame then return end
    local ef = CreateFrame("Frame")
    ef:SetScript("OnEvent", OnEvent)
    -- Always-on, cheap: combat-end replay of deferred secure work.
    ef:RegisterEvent("PLAYER_REGEN_ENABLED")
    PT.eventFrame = ef
end

-- UNIT_TARGET (party1..4) only matters while the feature is live, so it is
-- registered/unregistered with enable to avoid per-swap work when disabled.
-- The event frame is insecure, so this is not combat-restricted.
function SetTargetWatch(active)
    EnsureEventFrame()
    if active and not PT.targetWatch then
        PT.eventFrame:RegisterUnitEvent("UNIT_TARGET", "party1", "party2", "party3", "party4")
        PT.targetWatch = true
    elseif not active and PT.targetWatch then
        PT.eventFrame:UnregisterEvent("UNIT_TARGET")
        PT.targetWatch = false
    end
end

EnsureEventFrame()
