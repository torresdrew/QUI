-- buffborders.lua
-- Player buff/debuff icon display on Blizzard's secure CustomAuraContainer
-- model (the SAME path the unit/group frames use via QUI.AuraSkin). QUI exposes
-- two named anchor frames (QUI_BuffIconContainer and QUI_DebuffIconContainer)
-- on UIParent; each owns its own forbidden AuraContainer
-- ("CustomAuraContainerTemplate") that QUI.AuraSkin pools CustomAuraButtons onto.
-- The container self-drives UNIT_AURA and renders aura DATA C-side (secret-safe).
-- CREATION of the forbidden container/buttons is combat-restricted (combat
-- creation crashes the 12.1 client) and stays deferred to PLAYER_REGEN_ENABLED;
-- MUTATION of pre-created objects (anchor/size/filters/enable) is combat-legal,
-- so config changes apply live in combat and the full pass still replays at
-- regen (secure cancel-header attributes + private-aura registration are
-- OOC-only).
--
-- Right-click cancel of own buffs is a separate secure hit layer:
-- CustomAuraButton has no OnClick path in 12.1, so QUI overlays a
-- SecureAuraHeaderTemplate using SecureAuraButtonTemplate. The secure header owns
-- UNIT_AURA/index updates and the secure cancelaura action; QUI never scripts the
-- forbidden CustomAuraButtons and never calls CancelUnitBuff directly.
--
-- TEMP WEAPON ENCHANTS are NOT auras (GetWeaponEnchantInfo, never in UNIT_AURA),
-- so the secure container cannot show them. They keep a SMALL SEPARATE insecure
-- display (QUI's own buttons) with right-click CancelItemTempEnchantment gated on
-- InCombatLockdown, anchored adjacent to the buff container.

local _, ns = ...
local Helpers = ns.Helpers

local function CJKFont(fs, p, s, f)
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(fs, p, s, f)
    else
        fs:SetFont(p, s, f)
    end
end

local GetCore = Helpers.GetCore
local GetGeneralFont = Helpers.GetGeneralFont
local GetGeneralFontOutline = Helpers.GetGeneralFontOutline
local IsSecretValue = Helpers.IsSecretValue
local SafeValue = Helpers.SafeValue

-- Aura theme (A1): border color + count/duration font objects.
local AuraTheme = ns.Addon and ns.Addon.AuraTheme or (QUI and QUI.AuraTheme)
-- Aura skin (shared secure container adapter — the SINGLE path that touches the
-- forbidden CustomAuraButton inbound API). Re-resolved in EnsureContainers in
-- case core/aura_skin.lua loaded after this file's top-level chunk.
local AuraSkin = (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)

-- Upvalue caching
local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local wipe = wipe
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local CancelItemTempEnchantment = CancelItemTempEnchantment
local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local GetInventoryItemTexture = GetInventoryItemTexture

-- Private aura API (WoW 10.1.0+)
local AddPrivateAuraAnchor = C_UnitAuras and C_UnitAuras.AddPrivateAuraAnchor
local RemovePrivateAuraAnchor = C_UnitAuras and C_UnitAuras.RemovePrivateAuraAnchor

-- 12.0.5+ requires `isContainer` on AddPrivateAuraAnchor args; non-container
-- anchors must pass `isContainer = false` or registration silently fails.
local CLIENT_VERSION = select(4, GetBuildInfo())
local IS_CONTAINER_SUPPORTED = CLIENT_VERSION and CLIENT_VERSION >= 120005

---------------------------------------------------------------------------
-- DEFAULTS
---------------------------------------------------------------------------
local DEFAULTS = {
    enableBuffs = true,
    enableDebuffs = true,
    showBuffBorders = true,
    showDebuffBorders = true,
    hideBuffFrame = false,
    hideDebuffFrame = false,
    fadeBuffFrame = false,
    fadeDebuffFrame = false,
    fadeOutAlpha = 0,
    externalSkinning = false,
    iconSkin = "Default",
    borderSize = 2,
    fontSize = 12,
    fontOutline = true,
    buffIconsPerRow = 0,
    buffIconSpacing = 0,
    buffIconSize = 0,
    buffGrowLeft = false,
    buffGrowUp = false,
    buffInvertSwipeDarkening = false,
    buffRowSpacing = 0,
    showStacks = true,
    hideSwipe = false,
    -- Text positioning (per-frame)
    buffStackTextAnchor = "BOTTOMRIGHT",
    buffStackTextOffsetX = -1,
    buffStackTextOffsetY = 1,
    buffDurationTextAnchor = "CENTER",
    buffDurationTextOffsetX = 0,
    buffDurationTextOffsetY = 0,
    debuffStackTextAnchor = "BOTTOMRIGHT",
    debuffStackTextOffsetX = -1,
    debuffStackTextOffsetY = 1,
    debuffDurationTextAnchor = "CENTER",
    debuffDurationTextOffsetX = 0,
    debuffDurationTextOffsetY = 0,
}

local function GetSettings()
    return Helpers.GetModuleSettings("buffBorders", DEFAULTS)
end

local function GetBorderSizePx(frame, settings)
    local borderSize = settings and settings.borderSize
    if type(borderSize) ~= "number" then
        borderSize = DEFAULTS.borderSize
    end
    if borderSize <= 0 then return 0 end

    local core = GetCore and GetCore()
    if core and core.Pixels then
        return core:Pixels(borderSize, frame)
    end
    if core and core.GetPixelSize then
        return borderSize * core:GetPixelSize(frame)
    end
    return borderSize
end

---------------------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------------------
local DEFAULT_ICON_SIZE = 30
local BASE_CROP = 0.08

-- Debuff type → border color (r, g, b) — used by the layout-mode preview grid +
-- private-aura slot edges (live container border color is owned by AuraTheme).
local DEBUFF_TYPE_COLORS = {
    Magic   = { 0.20, 0.60, 1.00 },
    Curse   = { 0.60, 0.00, 1.00 },
    Disease = { 0.60, 0.40, 0.00 },
    Poison  = { 0.00, 0.60, 0.00 },
    [""]    = { 0.50, 0.00, 0.00 },
}
local BORDER_COLOR_BUFF = { 0, 0, 0 }
local BORDER_COLOR_DEBUFF_DEFAULT = { 0.50, 0.00, 0.00 }

-- The fixed per-zone icon cap. Mirrors Blizzard's BUFF_MAX_DISPLAY /
-- DEBUFF_MAX_DISPLAY; the container's maxFrameCount caps how many of the pooled
-- AuraSkin buttons render, and AuraSkin pools exactly this many.
local BUFF_MAX_DISPLAY = 40
local DEBUFF_MAX_DISPLAY = 40

-- Temp-enchant strip is a small separate insecure display (synthetic, non-aura).
local TEMP_ENCHANT_MAX = 3

---------------------------------------------------------------------------
-- AURA FILTER CONFIG
--
-- Filter flags are exposed as user options and appended to the per-zone filter
-- string. The CustomAuraContainer applies the SAME inclusion test internally for
-- each registered filter string (C_UnitAuras.IsAuraFilteredOutByInstanceID — see
-- Blizzard_CustomAuraContainer:AddAura), so the filter behaviour is identical to
-- the old Lua GetUnitAuras read, just driven C-side on secret-safe data.
--
-- (The legacy sort config is gone: the container drives its own ordering via
--  AuraUtil.DefaultAuraCompare on the priority table — there is no per-frame sort
--  enum on the container path.)
---------------------------------------------------------------------------

-- DB key (per-frame) → AuraFilters flag appended to the filter string.
-- HELPFUL/HARMFUL is implicit on the per-zone base.
local BUFF_FILTER_FLAGS = {
    { dbKey = "buffFilterPlayer",        flag = "PLAYER" },
    { dbKey = "buffFilterRaid",          flag = "RAID" },
    { dbKey = "buffFilterCancelable",    flag = "CANCELABLE" },
    { dbKey = "buffFilterNotCancelable", flag = "NOT_CANCELABLE" },
    { dbKey = "buffFilterBigDefensive",  flag = "BIG_DEFENSIVE" },
}

local DEBUFF_FILTER_FLAGS = {
    { dbKey = "debuffFilterPlayer",                flag = "PLAYER" },
    { dbKey = "debuffFilterRaid",                  flag = "RAID" },
    { dbKey = "debuffFilterIncludeNameplateOnly",  flag = "INCLUDE_NAME_PLATE_ONLY" },
    { dbKey = "debuffFilterRaidPlayerDispellable", flag = "RAID_PLAYER_DISPELLABLE" },
    { dbKey = "debuffFilterCrowdControl",          flag = "CROWD_CONTROL" },
}

-- Build the AuraFilters string for a zone. "HELPFUL"/"HARMFUL" base + any enabled
-- modifier flags, PIPE-joined to match AuraUtil.CreateFilterString (string.join
-- "|") and the unit/group container paths. The container forwards this exact
-- string to the C-side aura read / IsAuraFilteredOutByInstanceID.
local function BuildAuraFilter(settings, isBuff)
    local s = isBuff and "HELPFUL" or "HARMFUL"
    if not settings then return s end
    local list = isBuff and BUFF_FILTER_FLAGS or DEBUFF_FILTER_FLAGS
    for i = 1, #list do
        local entry = list[i]
        if settings[entry.dbKey] then
            s = s .. "|" .. entry.flag
        end
    end
    return s
end

---------------------------------------------------------------------------
-- LAYOUT PROFILE (settings → AuraSkin/AuraTheme grid profile)
---------------------------------------------------------------------------
-- Map the per-zone buffBorders settings to the AuraSkin profile shape
-- (iconSize, spacing, grow, maxIcons, maxPerRow, offsetX/Y, anchor) that
-- QUI.AuraSkin.Attach + AuraTheme.Metrics consume. This is the SAME profile
-- contract the unit-frame container path builds (unitframe_auras.lua
-- EnsureContainers), so all three surfaces flow through one helper.
--
-- growLeft → horizontal grow LEFT/RIGHT (the player strip is row-major
-- horizontal); growUp picks the BOTTOM grow corner so the strip's origin sits at
-- the bottom. Row wrap follows the shared AuraSkin GridOffset (perpendicular to
-- grow). maxPerRow = iconsPerRow.
local function BuildZoneProfile(settings, isBuff)
    local prefix = isBuff and "buff" or "debuff"

    local iconSize = settings and settings[prefix .. "IconSize"] or 0
    if not iconSize or iconSize <= 0 then iconSize = DEFAULT_ICON_SIZE end

    local perRow = settings and settings[prefix .. "IconsPerRow"] or 0
    if not perRow or perRow <= 0 then perRow = 10 end

    local spacing = settings and settings[prefix .. "IconSpacing"] or 0
    if not spacing or spacing <= 0 then spacing = 2 end

    local growLeft = settings and settings[prefix .. "GrowLeft"]
    local growUp = settings and settings[prefix .. "GrowUp"]

    local grow = growLeft and "LEFT" or "RIGHT"
    local anchor
    if growUp then
        anchor = growLeft and "BOTTOMRIGHT" or "BOTTOMLEFT"
    else
        anchor = growLeft and "TOPRIGHT" or "TOPLEFT"
    end

    local maxIcons = isBuff and BUFF_MAX_DISPLAY or DEBUFF_MAX_DISPLAY

    return {
        maxIcons     = maxIcons,
        iconSize     = iconSize,
        spacing      = spacing,
        grow         = grow,
        maxPerRow    = perRow,
        offsetX      = 0,
        offsetY      = 0,
        anchor       = anchor,
        borderSize   = settings and settings.borderSize or DEFAULTS.borderSize,
        fontSize     = settings and settings.fontSize or DEFAULTS.fontSize,
        hideSwipe    = settings and settings.hideSwipe or false,
        reverseSwipe = false,
    }
end

-- Natural grid extent of a fully-populated row (mover handle covers the full
-- possible width/height — the container renders an unknown live count C-side).
local function GridExtent(profile)
    local cols = math.min(profile.maxPerRow > 0 and profile.maxPerRow or profile.maxIcons, profile.maxIcons)
    if cols < 1 then cols = 1 end
    local rows = math.ceil(profile.maxIcons / cols)
    local w = cols * profile.iconSize + math.max(0, cols - 1) * profile.spacing
    local h = rows * profile.iconSize + math.max(0, rows - 1) * profile.spacing
    return w, h
end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
-- Weapon enchant cached total duration per slot
local enchantCachedDuration = {}

-- Live temp-enchant count (strip slots actually occupied). Enchants are item
-- info (GetWeaponEnchantInfo) — Lua-visible, unlike the secret live aura count
-- — so the strip LEADS the buff row and the secure grid is anchored this many
-- cells further along the grow direction (see AnchorAuraContainer).
local liveEnchantCount = 0

-- The QUI named anchor frames (created in Init) are the published, movable
-- frames the anchoring system resolves by global name and positions. Each owns
-- its own forbidden AuraContainer (._auraContainer) for one aura type.
local buffContainer = nil       -- QUI_BuffIconContainer (named anchor frame)
local debuffContainer = nil     -- QUI_DebuffIconContainer (named anchor frame)
local buffCancelHeader = nil    -- SecureAuraHeaderTemplate overlay for buff right-click cancel
local tempEnchantFrame = nil    -- small separate insecure temp-enchant strip
local initialized = false

-- Blizzard frame banish state
local blizzBuffBanished = false
local blizzDebuffBanished = false
local blizzardBanishState = Helpers.CreateStateTable()
local blizzardBanishParent

local function GetBlizzardBanishState(frame)
    local state = blizzardBanishState[frame]
    if not state then
        state = {}
        blizzardBanishState[frame] = state
    end
    return state
end

-- Layout mode preview state
local previewActive = false

-- Private aura state (player debuffs hidden from addon APIs)
local PA_MAX_SLOTS = 3
local paSlots = {}
local paAnchorIDs = {}

-- debug counters; nil until QUI_Debug activates instrumentation
local buffBorderStats

---------------------------------------------------------------------------
-- COMBAT DEFERRAL
-- The AuraContainer is a forbidden object: create / pool / anchor / filter /
-- enable changes are restricted in combat, so any such work attempted during
-- InCombatLockdown() is queued and replayed on PLAYER_REGEN_ENABLED.
---------------------------------------------------------------------------
local pendingContainerWork = false

local function ApplyContainerConfig() end  -- forward declaration

-- Replays container work that was deferred because it was attempted in combat
-- (AuraContainer is a forbidden object). Run from the always-registered
-- PLAYER_REGEN_ENABLED handler below; the pendingContainerWork gate makes combat
-- end a no-op unless work was actually queued — no unconditional full rebuild.
local function FlushPendingContainerWork()
    if pendingContainerWork then
        pendingContainerWork = false
        ApplyContainerConfig()
    end
end

local function QueueContainerWork()
    pendingContainerWork = true
end

---------------------------------------------------------------------------
-- 4-EDGE BORDER (private-aura slots + layout-mode preview icons)
---------------------------------------------------------------------------
local function ApplyBorderColorAndSize(frame, r, g, b, borderSizePx)
    frame.BorderTop:SetColorTexture(r, g, b, 1)
    frame.BorderBottom:SetColorTexture(r, g, b, 1)
    frame.BorderLeft:SetColorTexture(r, g, b, 1)
    frame.BorderRight:SetColorTexture(r, g, b, 1)

    frame.BorderTop:SetHeight(borderSizePx)
    frame.BorderBottom:SetHeight(borderSizePx)
    frame.BorderLeft:SetWidth(borderSizePx)
    frame.BorderRight:SetWidth(borderSizePx)
end

-- Style a 4-edge preview/private-slot icon (color, size, swipe, fonts). Used by
-- the layout-mode preview grid + temp-enchant strip only; live auras style their
-- single-texture border through AuraSkin/AuraTheme.
local function StyleIcon(icon, settings, isBuff, debuffType)
    if not icon or not settings then return end

    local borderSizePx = GetBorderSizePx(icon, settings)

    local r, g, b
    if isBuff then
        r, g, b = BORDER_COLOR_BUFF[1], BORDER_COLOR_BUFF[2], BORDER_COLOR_BUFF[3]
    else
        local safeType = Helpers.SafeValue(debuffType, "")
        local colors = DEBUFF_TYPE_COLORS[safeType] or BORDER_COLOR_DEBUFF_DEFAULT
        r, g, b = colors[1], colors[2], colors[3]
    end

    ApplyBorderColorAndSize(icon, r, g, b, borderSizePx)

    local showBorders
    if isBuff then
        showBorders = settings.showBuffBorders ~= false
    else
        showBorders = settings.showDebuffBorders ~= false
    end
    icon.BorderTop:SetShown(showBorders)
    icon.BorderBottom:SetShown(showBorders)
    icon.BorderLeft:SetShown(showBorders)
    icon.BorderRight:SetShown(showBorders)

    if icon.Cooldown then
        local showSwipe = not settings.hideSwipe
        icon.Cooldown:SetDrawSwipe(showSwipe)
        icon.Cooldown:SetDrawEdge(showSwipe)
    end

    local font = GetGeneralFont()
    local outline = GetGeneralFontOutline()
    local fontSize = settings.fontSize or 12
    if icon.Stacks and icon.Stacks.SetFont then
        CJKFont(icon.Stacks, font, fontSize, outline)
    end

    local tp = isBuff and "buff" or "debuff"
    local stackAnchor = settings[tp .. "StackTextAnchor"] or "BOTTOMRIGHT"
    local stackOffX = settings[tp .. "StackTextOffsetX"]
    if stackOffX == nil then stackOffX = -1 end
    local stackOffY = settings[tp .. "StackTextOffsetY"]
    if stackOffY == nil then stackOffY = 1 end
    if icon.Stacks then
        icon.Stacks:ClearAllPoints()
        local stackParent = icon.TextOverlay or icon
        icon.Stacks:SetPoint(stackAnchor, stackParent, stackAnchor, stackOffX, stackOffY)
        if stackAnchor == "TOPLEFT" or stackAnchor == "LEFT" or stackAnchor == "BOTTOMLEFT" then
            icon.Stacks:SetJustifyH("LEFT")
        elseif stackAnchor == "TOPRIGHT" or stackAnchor == "RIGHT" or stackAnchor == "BOTTOMRIGHT" then
            icon.Stacks:SetJustifyH("RIGHT")
        else
            icon.Stacks:SetJustifyH("CENTER")
        end
    end
end

local function CreateBorderEdges(frame)
    frame.BorderTop = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    frame.BorderBottom = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    frame.BorderLeft = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    frame.BorderRight = frame:CreateTexture(nil, "OVERLAY", nil, 7)

    frame.BorderTop:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.BorderTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    frame.BorderBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    frame.BorderBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.BorderLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.BorderLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    frame.BorderRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    frame.BorderRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
end

---------------------------------------------------------------------------
-- WEAPON ENCHANTS (small SEPARATE insecure display)
-- Temp weapon enchants come from GetWeaponEnchantInfo — they are NOT auras and
-- never appear in UNIT_AURA, so the secure CustomAuraContainer cannot show them.
-- QUI renders them on its OWN insecure buttons (NOT container-managed), keeping
-- right-click CancelItemTempEnchantment (slot index 1/2/3 = main/off/ranged),
-- gated on InCombatLockdown (cancel is protected in combat for everyone).
---------------------------------------------------------------------------
local ENCHANT_SLOT_BY_INDEX = { 16, 17, 18 }

-- Read the live temp enchants → dense descriptor list (mirror BuffFrame.lua
-- UpdateTemporaryEnchantmentBuffs). Secret-guard the expiration timestamp.
local function ReadTempEnchants()
    local list = {}
    local r = { GetWeaponEnchantInfo() }
    for itemIndex = 1, TEMP_ENCHANT_MAX do
        local base = (itemIndex - 1) * 4
        local hasEnchant = r[base + 1]
        local enchantExpiration = r[base + 2]
        local enchantCharges = r[base + 3]
        if hasEnchant and enchantExpiration and not IsSecretValue(enchantExpiration) then
            local slot = ENCHANT_SLOT_BY_INDEX[itemIndex]
            local remainingSec = enchantExpiration / 1000
            local total = enchantCachedDuration[slot]
            if not total or remainingSec > total then
                total = remainingSec
                enchantCachedDuration[slot] = total
            end
            list[#list + 1] = {
                -- enchantSlot (16/17/18) feeds GetInventoryItemTexture +
                -- GameTooltip:SetInventoryItem; enchantCancelIndex (1/2/3) is what
                -- CancelItemTempEnchantment expects (BuffFrame.lua:903-913).
                enchantSlot = slot,
                enchantCancelIndex = itemIndex,
                icon = GetInventoryItemTexture("player", slot),
                applications = enchantCharges,
                enchantStart = GetTime() - (total - remainingSec),
                enchantTotal = total,
            }
        end
    end
    return list
end

-- One insecure temp-enchant button. Plain QUI Button (NOT a forbidden
-- AuraButton), so QUI scripts it freely. Right-click cancels via
-- CancelItemTempEnchantment (combat-gated). Tooltip via SetInventoryItem.
local function EnsureTempEnchantButton(parent, i)
    local b = parent.buttons[i]
    if b then return b end

    b = CreateFrame("Button", nil, parent, nil)
    b:RegisterForClicks("RightButtonUp")

    local bd = b:CreateTexture(nil, "BACKGROUND", nil, -8)
    bd:SetColorTexture(0, 0, 0, 1)
    bd:SetAllPoints(b)
    b._quiBackdrop = bd

    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(b)
    tex:SetTexCoord(BASE_CROP, 1 - BASE_CROP, BASE_CROP, 1 - BASE_CROP)
    b.Icon = tex

    CreateBorderEdges(b)

    b.Cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.Cooldown:SetAllPoints(b)

    b.Stacks = b:CreateFontString(nil, "OVERLAY")
    b.Stacks:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    -- Seed a font at creation: the empty-slot path (elseif b then) calls
    -- Stacks:SetText("") WITHOUT going through StyleIcon, which otherwise errors
    -- "FontString:SetText(): Font not set".  StyleIcon re-applies the real size
    -- when an enchant actually occupies the slot.
    CJKFont(b.Stacks, GetGeneralFont(), 12, GetGeneralFontOutline())

    b:SetScript("OnClick", function(self, button)
        if button ~= "RightButton" then return end
        -- Cancel is protected in combat for everyone, not just secure code.
        if InCombatLockdown() then return end
        if self.enchantCancelIndex then
            pcall(CancelItemTempEnchantment, self.enchantCancelIndex)
        end
    end)
    b:SetScript("OnEnter", function(self)
        if GameTooltip.IsForbidden and GameTooltip:IsForbidden() then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        if self.enchantSlot then
            pcall(GameTooltip.SetInventoryItem, GameTooltip, "player", self.enchantSlot)
        end
        pcall(GameTooltip.Show, GameTooltip)
    end)
    b:SetScript("OnLeave", function()
        pcall(GameTooltip.Hide, GameTooltip)
    end)

    parent.buttons[i] = b
    return b
end

-- Refresh + lay out the temp-enchant strip. Pure insecure work — runs in or out
-- of combat (these are QUI's own frames). The strip anchors to the buff anchor
-- frame's grow corner, flowing away from the buff grid.
local function UpdateTempEnchants()
    if not tempEnchantFrame or not buffContainer then return end
    local settings = GetSettings()
    if not settings then return end
    if previewActive then return end

    local show = settings.enableBuffs and not settings.hideBuffFrame
    if not show then
        liveEnchantCount = 0
        tempEnchantFrame:Hide()
        return
    end

    local list = ReadTempEnchants()
    local n = #list
    liveEnchantCount = n

    local profile = BuildZoneProfile(settings, true)
    local iconSize, spacing = profile.iconSize, profile.spacing
    local growLeft = settings.buffGrowLeft
    -- The strip LEADS the buff row (default-UI parity): enchants render at the
    -- grid origin corner; AnchorAuraContainer shifts the secure grid past them.
    local point = profile.anchor
    local xDir = growLeft and -1 or 1

    tempEnchantFrame:ClearAllPoints()
    tempEnchantFrame:SetPoint(point, buffContainer, point, 0, 0)

    for i = 1, TEMP_ENCHANT_MAX do
        local b = EnsureTempEnchantButton(tempEnchantFrame, i)
        local info = list[i]
        if info then
            b:SetSize(iconSize, iconSize)
            b:ClearAllPoints()
            b:SetPoint(point, tempEnchantFrame, point, xDir * (i - 1) * (iconSize + spacing), 0)
            b.enchantSlot = info.enchantSlot
            b.enchantCancelIndex = info.enchantCancelIndex
            pcall(b.Icon.SetTexture, b.Icon, info.icon)
            StyleIcon(b, settings, true)
            if b.Cooldown then
                if info.enchantStart and info.enchantTotal and info.enchantTotal > 0 then
                    pcall(b.Cooldown.SetCooldown, b.Cooldown, info.enchantStart, info.enchantTotal)
                else
                    pcall(b.Cooldown.Clear, b.Cooldown)
                end
            end
            if b.Stacks then
                local count = SafeValue(info.applications)
                b.Stacks:SetText((type(count) == "number" and count > 1) and count or "")
            end
            b:Show()
        elseif b then
            b.enchantSlot = nil
            b.enchantCancelIndex = nil
            pcall(b.Icon.SetTexture, b.Icon, nil)
            if b.Stacks then b.Stacks:SetText("") end
            if b.Cooldown then pcall(b.Cooldown.Clear, b.Cooldown) end
            b:Hide()
        end
    end

    if n > 0 then
        tempEnchantFrame:Show()
    else
        tempEnchantFrame:Hide()
    end
end

---------------------------------------------------------------------------
-- BANISH / RESTORE BLIZZARD FRAMES
---------------------------------------------------------------------------
local function SetDescendantMouse(frame, enable)
    for i = 1, frame:GetNumChildren() do
        local child = select(i, frame:GetChildren())
        if child then
            if child.EnableMouse then child:EnableMouse(enable) end
            SetDescendantMouse(child, enable)
        end
    end
end

local function EnsureBlizzardBanishParent()
    if not blizzardBanishParent then
        blizzardBanishParent = CreateFrame("Frame", "QUI_BuffBordersHiddenParent", UIParent)
        blizzardBanishParent:Hide()
    end
    return blizzardBanishParent
end

local function RemoveFromManagedContainer(frame)
    if not frame then return nil end
    local currentParent = frame.GetParent and frame:GetParent() or nil
    if currentParent and currentParent.RemoveManagedFrame then
        pcall(currentParent.RemoveManagedFrame, currentParent, frame)
    end
    frame.ignoreFramePositionManager = true
    return currentParent
end

local function BanishBlizzardFrame(frame)
    if not frame then return false end
    if InCombatLockdown() and not ns._inInitSafeWindow then return false end

    local state = GetBlizzardBanishState(frame)
    if not state.banished then
        state.originalParent = frame.GetParent and frame:GetParent() or UIParent
        state.originalAlpha = frame.GetAlpha and frame:GetAlpha() or 1
        state.originalMouse = frame.IsMouseEnabled and frame:IsMouseEnabled()
        state.originalIgnoreFramePositionManager = frame.ignoreFramePositionManager
    end

    RemoveFromManagedContainer(frame)

    local hiddenParent = EnsureBlizzardBanishParent()
    if frame.SetParent and frame:GetParent() ~= hiddenParent then
        pcall(frame.SetParent, frame, hiddenParent)
    end
    if frame.SetAlpha then pcall(frame.SetAlpha, frame, 0) end
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, false) end
    SetDescendantMouse(frame, false)

    state.banished = true
    return true
end

local function RestoreBlizzardFrame(frame)
    if not frame then return false end
    if InCombatLockdown() and not ns._inInitSafeWindow then return false end

    local state = blizzardBanishState[frame]
    if state and state.originalIgnoreFramePositionManager ~= nil then
        frame.ignoreFramePositionManager = state.originalIgnoreFramePositionManager
    else
        frame.ignoreFramePositionManager = nil
    end

    local parent = state and state.originalParent or UIParent
    if frame.SetParent and parent then
        pcall(frame.SetParent, frame, parent)
    end

    local alpha = (state and state.originalAlpha ~= nil) and state.originalAlpha or 1
    if frame.SetAlpha then pcall(frame.SetAlpha, frame, alpha) end

    local mouse = not (state and state.originalMouse == false)
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, mouse) end
    SetDescendantMouse(frame, mouse)

    if frame.Show then pcall(frame.Show, frame) end
    if state then state.banished = false end
    return true
end

---------------------------------------------------------------------------
-- PRIVATE AURAS (player debuffs hidden from addon APIs)
-- Unchanged in spirit: 3 slot frames parented to the debuff anchor frame, each
-- registered as a private-aura anchor via C_UnitAuras.AddPrivateAuraAnchor
-- (client-side rendering). The container path renders normal debuffs C-side;
-- private auras layer on top via their own anchors (same as before).
---------------------------------------------------------------------------
local function ClearPrivateAuraAnchors()
    if not RemovePrivateAuraAnchor then return end
    for i = 1, #paAnchorIDs do
        local id = paAnchorIDs[i]
        if id then pcall(RemovePrivateAuraAnchor, id) end
    end
    wipe(paAnchorIDs)
    for i = 1, PA_MAX_SLOTS do
        local slot = paSlots[i]
        if slot then
            for j = 1, slot:GetNumChildren() do
                local child = select(j, slot:GetChildren())
                if child then pcall(child.Hide, child) end
            end
        end
    end
end

local function EnsureSlotBorders(slot)
    if slot.BorderTop then return end
    CreateBorderEdges(slot)
end

local function IsForbiddenObject(object)
    if not object or not object.IsForbidden then return false end
    local ok, forbidden = pcall(object.IsForbidden, object)
    return ok and forbidden
end

local function IsObjectTypeSafe(object, objectType)
    if not object or not object.IsObjectType then return false end
    local ok, matches = pcall(object.IsObjectType, object, objectType)
    return ok and matches
end

local function SlotHasVisibleAura(slot)
    if not slot or not slot.GetNumChildren then return false end
    local numOk, numChildren = pcall(slot.GetNumChildren, slot)
    if not numOk or not numChildren or numChildren == 0 then return false end
    local childrenOk, children = pcall(function() return { slot:GetChildren() } end)
    if not childrenOk or not children then return false end
    for i = 1, numChildren do
        local child = children[i]
        if child and not IsForbiddenObject(child) and child.IsShown then
            local ok, shown = pcall(child.IsShown, child)
            if ok and shown then return true end
        end
    end
    return false
end

local function StyleSlotBorders(slot, settings)
    if not slot.BorderTop then return end
    local borderSizePx = GetBorderSizePx(slot, settings)
    local r, g, b = BORDER_COLOR_DEBUFF_DEFAULT[1], BORDER_COLOR_DEBUFF_DEFAULT[2], BORDER_COLOR_DEBUFF_DEFAULT[3]

    ApplyBorderColorAndSize(slot, r, g, b, borderSizePx)

    local showBorders = settings and settings.showDebuffBorders ~= false
    local visible = showBorders and SlotHasVisibleAura(slot)
    slot.BorderTop:SetShown(visible)
    slot.BorderBottom:SetShown(visible)
    slot.BorderLeft:SetShown(visible)
    slot.BorderRight:SetShown(visible)
end

local function StyleSlotTextRecursive(node, settings, depth)
    if not node or depth > 5 or IsForbiddenObject(node) then return end
    settings = settings or DEFAULTS

    local font = GetGeneralFont()
    local outline = GetGeneralFontOutline()
    local fontSize = settings.fontSize or 12

    local numRegions = 0
    local regions
    if node.GetNumRegions and node.GetRegions then
        local numOk, count = pcall(node.GetNumRegions, node)
        if numOk and type(count) == "number" and count > 0 then
            local regionsOk, regionList = pcall(function() return { node:GetRegions() } end)
            if regionsOk and regionList then
                numRegions = count
                regions = regionList
            end
        end
    end
    for i = 1, numRegions do
        local region = regions and regions[i]
        if region and not IsForbiddenObject(region) and IsObjectTypeSafe(region, "FontString") and region.SetFont then
            pcall(CJKFont, region, font, fontSize, outline)
            local text
            if region.GetText then
                local textOk, textValue = pcall(region.GetText, region)
                if textOk then
                    text = SafeValue(textValue, nil)
                end
            end
            if text then
                local anchor = settings.debuffDurationTextAnchor or "CENTER"
                local offX = settings.debuffDurationTextOffsetX or 0
                local offY = settings.debuffDurationTextOffsetY or 0
                local parent
                if region.GetParent then
                    local parentOk, parentValue = pcall(region.GetParent, region)
                    if parentOk then parent = parentValue end
                end
                pcall(region.ClearAllPoints, region)
                pcall(region.SetPoint, region, anchor, parent or node, anchor, offX, offY)
            end
        end
    end

    if IsObjectTypeSafe(node, "Cooldown") and node.GetCountdownFontString then
        local cdOk, cdText = pcall(node.GetCountdownFontString, node)
        if cdOk and cdText and not IsForbiddenObject(cdText) and cdText.SetFont then
            pcall(CJKFont, cdText, font, fontSize, outline)
            local anchor = settings.debuffDurationTextAnchor or "CENTER"
            local offX = settings.debuffDurationTextOffsetX or 0
            local offY = settings.debuffDurationTextOffsetY or 0
            pcall(cdText.ClearAllPoints, cdText)
            pcall(cdText.SetPoint, cdText, anchor, node, anchor, offX, offY)
        end
    end

    local numChildren = 0
    local children
    if node.GetNumChildren and node.GetChildren then
        local numOk, count = pcall(node.GetNumChildren, node)
        if numOk and type(count) == "number" and count > 0 then
            local childrenOk, childList = pcall(function() return { node:GetChildren() } end)
            if childrenOk and childList then
                numChildren = count
                children = childList
            end
        end
    end
    for i = 1, numChildren do
        local child = children and children[i]
        if child and not IsForbiddenObject(child) then
            StyleSlotTextRecursive(child, settings, depth + 1)
        end
    end
end

local function DeferStyleSlotText(slot, settings)
    C_Timer.After(0, function()
        if not slot:IsShown() then return end
        StyleSlotBorders(slot, settings)
        StyleSlotTextRecursive(slot, settings, 1)
    end)
end

local function SetupPrivateAuras()
    if not AddPrivateAuraAnchor or not debuffContainer then return end
    ClearPrivateAuraAnchors()

    local settings = GetSettings()
    local iconSize = DEFAULT_ICON_SIZE
    if settings then
        local s = settings.debuffIconSize or 0
        if s > 0 then iconSize = s end
    end

    local borderSizePx = GetBorderSizePx(debuffContainer, settings)

    for i = 1, PA_MAX_SLOTS do
        local slot = paSlots[i]
        if not slot then
            slot = CreateFrame("Frame", "QUI_PlayerPrivateAura" .. i, debuffContainer)
            slot:SetIgnoreParentAlpha(true)
            paSlots[i] = slot
        end
        slot:SetSize(iconSize, iconSize)
        slot:Show()

        EnsureSlotBorders(slot)
        StyleSlotBorders(slot, settings)

        local anchorArgs = {
            unitToken = "player",
            auraIndex = i,
            parent = slot,
            showCountdownFrame = true,
            showCountdownNumbers = true,
            iconInfo = {
                iconWidth = iconSize - borderSizePx * 2,
                iconHeight = iconSize - borderSizePx * 2,
                borderScale = -1000,
                iconAnchor = {
                    point = "CENTER",
                    relativeTo = slot,
                    relativePoint = "CENTER",
                    offsetX = 0,
                    offsetY = 0,
                },
            },
        }
        if IS_CONTAINER_SUPPORTED then anchorArgs.isContainer = false end
        local ok, anchorID = pcall(AddPrivateAuraAnchor, anchorArgs)
        paAnchorIDs[i] = ok and anchorID or nil
    end

    for _, slot in ipairs(paSlots) do
        DeferStyleSlotText(slot, settings)
    end
end

-- Position the 3 private-aura slots on a FIXED reserved strip below the debuff
-- grid's max extent. Private auras cannot join the engine pool and the live
-- debuff count is secret-safe / unknown to Lua, so the slots sit one row below
-- the debuff container's possible extent, on the same grow corner as that grid.
local function LayoutPrivateAuraSlots()
    if not AddPrivateAuraAnchor or #paSlots == 0 or not debuffContainer then return end

    local settings = GetSettings()
    if not settings or not settings.enableDebuffs or settings.hideDebuffFrame then
        for _, slot in ipairs(paSlots) do
            slot:Hide()
        end
        return
    end

    local profile = BuildZoneProfile(settings, false)
    local iconSize = profile.iconSize
    local spacing = profile.spacing
    local growLeft = settings.debuffGrowLeft
    local growUp = settings.debuffGrowUp
    local xDir = growLeft and -1 or 1
    local point = profile.anchor
    local _, gridH = GridExtent(profile)
    local stripYBase = growUp and (gridH + spacing) or -(gridH + spacing)

    for i = 1, #paSlots do
        local slot = paSlots[i]
        slot:SetSize(iconSize, iconSize)
        slot:ClearAllPoints()
        local x = xDir * (i - 1) * (iconSize + spacing)
        slot:SetPoint(point, debuffContainer, point, x, stripYBase)
        StyleSlotBorders(slot, settings)
        slot:Show()
    end
end

---------------------------------------------------------------------------
-- BLIZZARD FRAME MANAGEMENT
---------------------------------------------------------------------------
local function ManageBlizzardFrames()
    local settings = GetSettings()
    if not settings then return end

    if settings.enableBuffs then
        if BanishBlizzardFrame(BuffFrame) then
            blizzBuffBanished = true
        end
    else
        if blizzBuffBanished then
            if RestoreBlizzardFrame(BuffFrame) then
                blizzBuffBanished = false
            end
        end
    end

    if settings.enableDebuffs then
        if BanishBlizzardFrame(DebuffFrame) then
            blizzDebuffBanished = true
        end
    else
        if blizzDebuffBanished then
            if RestoreBlizzardFrame(DebuffFrame) then
                blizzDebuffBanished = false
            end
        end
    end
end

---------------------------------------------------------------------------
-- LIVE CONTAINER CONFIG (shared secure path)
-- Create (OOC) the per-zone AuraContainer on each named anchor frame, theme +
-- pool the buttons via QUI.AuraSkin (the SAME helper the unit/group frames use),
-- then apply filters + unit + enable. The container self-drives UNIT_AURA; QUI
-- never reads a secret aura field on this path.
---------------------------------------------------------------------------
local function AnchorAuraContainer(container, parent, profile)
    -- The grid lays out FROM the profile.anchor corner of the container, so pin
    -- the container's anchor corner to the parent anchor frame's matching corner.
    -- BUFF zone: the temp-enchant strip (Lua-knowable count) leads the row, so
    -- the secure grid starts liveEnchantCount cells along the grow direction —
    -- the one direction dynamic packing can work while the aura count is secret.
    -- The WHOLE container shifts (rows 2+ indent too): the secure cancel header
    -- can only lay a uniform grid, and a ragged first-row indent would misalign
    -- the cancel hit-layer with the display buttons.
    local xOff = 0
    if parent == buffContainer and liveEnchantCount > 0 then
        local xDir = (profile.grow == "LEFT") and -1 or 1
        xOff = xDir * liveEnchantCount * (profile.iconSize + profile.spacing)
    end
    container:ClearAllPoints()
    container:SetPoint(profile.anchor, parent, profile.anchor, xOff, 0)
end

local function EnsureZoneContainer(anchorFrame, profile)
    AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    if not AuraSkin or not CreateFrame then return nil end

    local container = anchorFrame._auraContainer
    if not container then
        container = CreateFrame("AuraContainer", nil, anchorFrame, "CustomAuraContainerTemplate")
        anchorFrame._auraContainer = container
    end
    AuraSkin.Attach(container, profile)
    AnchorAuraContainer(container, anchorFrame, profile)
    return container
end

-- Configure one zone's AuraContainer: buttons, anchor, unit, filters, enable.
-- allowCreate gates the OOC-only creation path (frame creation of the
-- forbidden container + AuraSkin button pooling, via EnsureZoneContainer).
-- With allowCreate false (in combat) only PRE-CREATED objects are mutated:
-- AuraSkin.Reflow re-flows the existing button pool (creation-free) and the
-- filter/unit/enable/anchor writes below are combat-legal on a live container.
local function ConfigureZoneAuraContainer(anchorFrame, profile, active, filter, maxCount, allowCreate)
    local container = anchorFrame._auraContainer
    if allowCreate then
        container = EnsureZoneContainer(anchorFrame, profile)
    elseif container then
        AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
        if AuraSkin and AuraSkin.Reflow then
            AuraSkin.Reflow(container, profile)
        end
        AnchorAuraContainer(container, anchorFrame, profile)
    end
    if not container then return nil end

    -- SetUnit BEFORE the filters so AddAuraFilter's eager C-side aura read has a unit.
    container:SetUnit("player")
    container:ClearAuraFilters()
    if active then
        container:AddAuraFilter(filter, { maxFrameCount = maxCount })
        container:SetEnabled(true)
        container:Show()
    else
        container:SetEnabled(false)
        container:Hide()
    end
    return container
end

local function EnsureBuffCancelHeader()
    if buffCancelHeader or not buffContainer then return buffCancelHeader end

    local ok, header = pcall(CreateFrame, "Frame", "QUI_BuffCancelHeader", buffContainer, "SecureAuraHeaderTemplate")
    if not ok or not header then return nil end
    buffCancelHeader = header
    return buffCancelHeader
end

local function StyleBuffCancelChild(child, iconSize)
    if not child then return end
    pcall(child.SetSize, child, iconSize, iconSize)
    pcall(child.SetAlpha, child, 0)
    -- Children are born mouse-DISABLED (initialConfigFunction snippet) so an
    -- unstyled child can never block tooltips or swallow clicks; only this
    -- insecure pass (OOC-only) arms the cancel hit layer.
    pcall(child.EnableMouse, child, true)
    if child.SetPropagateMouseMotion then
        pcall(child.SetPropagateMouseMotion, child, true)
    end
    if child.SetPassThroughButtons then
        pcall(child.SetPassThroughButtons, child, "LeftButton")
    end
    child._quiCancelStyled = true
end

local function RefreshBuffCancelChildren(header, iconSize, maxButtons)
    if not header or not header.GetAttribute then return end
    for i = 1, maxButtons do
        local child = header:GetAttribute("child" .. i)
        if child then
            StyleBuffCancelChild(child, iconSize)
        end
    end
end

-- LATE-CREATED CHILDREN: the secure header builds child buttons lazily as the
-- live buff count exceeds its all-time max (SecureGroupHeaders configureAuras).
-- That CAN happen mid-combat: SecureAuraHeader_Update runs in Blizzard's secure
-- UNIT_AURA/OnShow context, where protected-template CreateFrame + SetPoint are
-- legal in combat. The initialConfigFunction snippet CANNOT style new children
-- for tooltip pass-through: it runs on a restricted frame handle, and handles
-- expose no SetPropagateMouseMotion/SetPassThroughButtons — those `if self.X`
-- clauses are silently dead. Handles DO expose EnableMouse, so the snippet
-- births every child mouse-DISABLED: an unstyled child is transparent (tooltips
-- + clicks reach the forbidden CustomAuraButton underneath) instead of a
-- blocker. The header publishes each new child as a "childN" attribute
-- (setAttributesWithoutResponse → plain SetAttribute, so the OnAttributeChanged
-- SCRIPT still fires; only Blizzard's handler early-returns on _ignore) — an
-- insecure post-hook on that script sees every creation without registering
-- UNIT_AURA. Styling is deferred one frame (the attribute lands mid-layout).
-- All three setters are protected (SimpleScriptRegionAPIDocumentation:
-- IsProtectedFunction + HasRestrictions): in combat, queue and flush on
-- PLAYER_REGEN_ENABLED — until then the child stays mouse-off, costing only its
-- cancel hit area (moot in combat: the visibility driver below hides the whole
-- overlay).
local pendingChildStyle = false

local function StyleNewCancelChildren()
    if not buffCancelHeader then return end
    if InCombatLockdown() then
        pendingChildStyle = true
        return
    end
    local iconSize = buffCancelHeader._quiChildIconSize or DEFAULT_ICON_SIZE
    for i = 1, BUFF_MAX_DISPLAY do
        local child = buffCancelHeader:GetAttribute("child" .. i)
        if not child then break end
        if not child._quiCancelStyled then
            StyleBuffCancelChild(child, iconSize)
        end
    end
end

local childStyleScheduled = false
local function RunScheduledChildStyle()
    childStyleScheduled = false
    StyleNewCancelChildren()
end
local function ScheduleChildStyle()
    if childStyleScheduled then return end
    childStyleScheduled = true
    C_Timer.After(0, RunScheduledChildStyle)
end

-- Attribute names arrive lowercased; "child1".."child40" marks a new secure
-- child (the "frameref-childN" sibling set doesn't match the pattern).
local function OnCancelHeaderAttributeChanged(_, name)
    if type(name) == "string" and name:find("^child%d") then
        ScheduleChildStyle()
    end
end

-- COMBAT VISIBILITY: the overlay is hidden for the whole of combat by a SECURE
-- state driver. The display container assigns auras to its buttons in
-- AuraUtil.DefaultAuraCompare priority order (own-cast first, then
-- isPriorityAura, then canApplyAura, then auraInstanceID); SecureAuraHeader can
-- only sort INDEX/NAME/TIME (+separateOwn). Priority procs — a combat
-- phenomenon — reorder the display but not the header, and the divergence
-- cannot be reconciled insecurely in combat (aura data is secret), so a
-- combat-visible overlay right-clicks the WRONG aura. Hiding it makes every
-- buff hover/left-click work in combat (nothing sits over the forbidden
-- buttons) at the cost of in-combat right-click cancel. Hide/Show comes from
-- Blizzard's SecureStateDriverManager (secure), so the combat-end re-show runs
-- SecureAuraHeader_OnShow → a clean secure update (positions, indexes, any
-- missing children). The driver must be UNregistered whenever QUI manually
-- hides the header (disabled/preview) or the next state flip would re-show it.
local function SetCancelHeaderCombatDriver(header, enabled)
    if enabled then
        if not header._quiVisDriver then
            header._quiVisDriver = true
            RegisterStateDriver(header, "visibility", "[combat] hide; show")
        end
    elseif header._quiVisDriver then
        header._quiVisDriver = nil
        UnregisterStateDriver(header, "visibility")
    end
end

local function ConfigureBuffCancelHeader(settings, profile, buffMax, perRow, anyBuffs)
    local header = EnsureBuffCancelHeader()
    if not header then return end

    if not header._quiChildWatch then
        header._quiChildWatch = true
        header:HookScript("OnAttributeChanged", OnCancelHeaderAttributeChanged)
    end

    if not anyBuffs then
        SetCancelHeaderCombatDriver(header, false)
        pcall(header.Hide, header)
        return
    end

    local iconSize = profile.iconSize or DEFAULT_ICON_SIZE
    local spacing = profile.spacing or 2
    local step = iconSize + spacing
    local growLeft = settings and settings.buffGrowLeft
    local growUp = settings and settings.buffGrowUp
    local xOffset = growLeft and -step or step
    local wrapYOffset = growUp and step or -step
    local maxWraps = math.ceil(buffMax / perRow)
    local filter = BuildAuraFilter(settings, true)
    local initialConfig = string.format(
        'self:EnableMouse(false); self:SetWidth(%.3f); self:SetHeight(%.3f); self:SetAlpha(0); if self.SetPropagateMouseMotion then self:SetPropagateMouseMotion(true); end; if self.SetPassThroughButtons then self:SetPassThroughButtons("LeftButton"); end;',
        iconSize, iconSize)

    -- Same enchant lead-in offset as AnchorAuraContainer: the cancel hit-layer
    -- must track the shifted display grid or right-click cancels the wrong aura.
    local enchantXOff = 0
    if liveEnchantCount > 0 then
        enchantXOff = (growLeft and -1 or 1) * liveEnchantCount * step
    end
    header:ClearAllPoints()
    header:SetPoint(profile.anchor, buffContainer, profile.anchor, enchantXOff, 0)
    header:SetSize(1, 1)
    if header.SetFrameLevel and buffContainer.GetFrameLevel then
        pcall(header.SetFrameLevel, header, (buffContainer:GetFrameLevel() or 0) + 40)
    end

    header:SetAttribute("unit", "player")
    header:SetAttribute("filter", filter)
    header:SetAttribute("template", "SecureAuraButtonTemplate")
    header:SetAttribute("sortMethod", "INDEX")
    header:SetAttribute("sortDirection", "+")
    header:SetAttribute("separateOwn", 1)
    header:SetAttribute("maxAuraCount", buffMax)
    header:SetAttribute("point", profile.anchor)
    header:SetAttribute("xOffset", xOffset)
    header:SetAttribute("yOffset", 0)
    header:SetAttribute("wrapAfter", perRow)
    header:SetAttribute("wrapXOffset", 0)
    header:SetAttribute("wrapYOffset", wrapYOffset)
    header:SetAttribute("maxWraps", maxWraps)
    header:SetAttribute("initialConfigFunction", initialConfig)
    header._quiChildIconSize = iconSize
    SetCancelHeaderCombatDriver(header, true)
    header:Show()
    RefreshBuffCancelChildren(header, iconSize, buffMax)
end

-- Heart of the live path, shared by both passes. allowCreate=true is the full
-- OOC pass: may create the forbidden containers, pool buttons, rewrite the
-- secure cancel header's attributes, and re-register private-aura anchors.
-- allowCreate=false is the combat pass: only combat-legal mutation of
-- pre-created objects (anchor-frame sizing, container anchor/filters/enable,
-- alpha fades, the insecure temp-enchant strip, private-aura slot layout).
local function ApplyConfigPass(allowCreate)
    if not buffContainer or not debuffContainer then return end
    if previewActive then return end

    local settings = GetSettings()
    if not settings then return end

    -- Temp enchants FIRST: the strip's live count feeds the buff zone's anchor
    -- offset and natural width below.
    UpdateTempEnchants()

    local buffProfile = BuildZoneProfile(settings, true)
    local debuffProfile = BuildZoneProfile(settings, false)
    local buffMax = buffProfile.maxIcons
    local debuffMax = debuffProfile.maxIcons
    local buffPerRow = buffProfile.maxPerRow
    if buffPerRow < 1 then buffPerRow = 1 end

    local bw, bh = GridExtent(buffProfile)
    if liveEnchantCount > 0 then
        -- The enchant lead-in shifts the grid origin; the natural (mover /
        -- anchoring) extent must cover strip + shifted grid.
        bw = bw + liveEnchantCount * (buffProfile.iconSize + buffProfile.spacing)
    end
    buffContainer._naturalW, buffContainer._naturalH = bw, bh
    buffContainer:SetSize(bw, bh)

    local dw, dh = GridExtent(debuffProfile)
    debuffContainer._naturalW, debuffContainer._naturalH = dw, dh
    debuffContainer:SetSize(dw, dh)

    local anyBuffs   = settings.enableBuffs   and not settings.hideBuffFrame
    local anyDebuffs = settings.enableDebuffs and not settings.hideDebuffFrame

    if allowCreate then
        ConfigureZoneAuraContainer(buffContainer, buffProfile, anyBuffs,
            BuildAuraFilter(settings, true), buffMax, true)
        ConfigureZoneAuraContainer(debuffContainer, debuffProfile, anyDebuffs,
            BuildAuraFilter(settings, false), debuffMax, true)
        ConfigureBuffCancelHeader(settings, buffProfile, buffMax, buffPerRow, anyBuffs)
    else
        -- In-combat mutation of a pre-created container is 12.1-PTR-legal
        -- (anchor/size/filter/enable). pcall-guard the first live deployments:
        -- on any restriction error the queued full pass still reconciles at
        -- PLAYER_REGEN_ENABLED. The secure cancel header is NOT touched here
        -- (SetAttribute is combat-blocked; the header is combat-hidden anyway).
        pcall(ConfigureZoneAuraContainer, buffContainer, buffProfile, anyBuffs,
            BuildAuraFilter(settings, true), buffMax, false)
        pcall(ConfigureZoneAuraContainer, debuffContainer, debuffProfile, anyDebuffs,
            BuildAuraFilter(settings, false), debuffMax, false)
    end

    -- Fade support (SetAlpha is unprotected on the named anchor frames).
    if anyBuffs then
        buffContainer:SetAlpha(settings.fadeBuffFrame and (settings.fadeOutAlpha or 0) or 1)
    else
        buffContainer:SetAlpha(0)
    end
    if anyDebuffs then
        debuffContainer:SetAlpha(settings.fadeDebuffFrame and (settings.fadeOutAlpha or 0) or 1)
    else
        debuffContainer:SetAlpha(0)
    end

    if buffBorderStats then buffBorderStats.containerConfigs = buffBorderStats.containerConfigs + 1 end

    if allowCreate then
        SetupPrivateAuras()
    end
    LayoutPrivateAuraSlots()
end

-- Full OOC pass (re-assigned to the forward declaration above; also what
-- FlushPendingContainerWork replays at PLAYER_REGEN_ENABLED).
ApplyContainerConfig = function()
    ApplyConfigPass(true)
end

-- Combat-legal mutation pass on pre-created objects.
local function ApplyMutableConfig()
    ApplyConfigPass(false)
end

-- Public re-config. OOC: run the full pass. In combat: apply the combat-legal
-- mutation subset immediately (live feedback on pre-created containers) AND
-- queue the full pass — creation, secure cancel-header attributes, and
-- private-aura registration can only run at PLAYER_REGEN_ENABLED.
local function ApplyOrDefer()
    if previewActive then return end
    if InCombatLockdown() then
        ApplyMutableConfig()
        QueueContainerWork()
        return
    end
    ApplyContainerConfig()
end

-- Event entry point for enchant changes: refresh the strip, and when the live
-- count CHANGED the buff grid origin moved — re-run the config pass (in combat
-- that is the mutable pass now + the queued full pass at regen; the cancel
-- header is combat-hidden, so its shift waiting for regen is invisible).
local function RefreshTempEnchants()
    local before = liveEnchantCount
    UpdateTempEnchants()
    if liveEnchantCount ~= before then
        ApplyOrDefer()
    end
end

---------------------------------------------------------------------------
-- LAYOUT MODE PREVIEW
-- The secure container cannot be fed fake auras, so during preview each zone's
-- live container is disabled + hidden and the preview icons render alone on a
-- HIGH-strata overlay; the container is restored on exit.
---------------------------------------------------------------------------
local PREVIEW_BUFF_TEXTURES = {
    136012, 136085, 135932, 132333, 136247, 135987, 136048, 135964,
}
local PREVIEW_DEBUFF_TEXTURES = {
    135849, 135813, 132851, 136139, 136066, 135959,
}
local PREVIEW_DEBUFF_TYPES = { "Magic", "Curse", "Disease", "Poison", "Magic", "" }

local previewBuffIcons = {}
local previewDebuffIcons = {}
local previewBuffOverlay = nil
local previewDebuffOverlay = nil

local function GetPreviewCount(settings, prefix)
    local perRow = settings[prefix .. "IconsPerRow"] or 0
    if perRow <= 0 then perRow = 10 end
    return math.max(3, math.min(perRow + math.ceil(perRow / 2), 20))
end

local function CreatePreviewGrid(parent, textures, debuffTypes, settings, prefix, isBuff)
    local iconSize = settings[prefix .. "IconSize"] or 0
    if iconSize <= 0 then iconSize = DEFAULT_ICON_SIZE end
    local iconsPerRow = settings[prefix .. "IconsPerRow"] or 0
    if iconsPerRow <= 0 then iconsPerRow = 10 end
    local spacing = settings[prefix .. "IconSpacing"] or 0
    if spacing <= 0 then spacing = 2 end
    local rowSpacing = settings[prefix .. "RowSpacing"] or 0
    if rowSpacing <= 0 then rowSpacing = spacing end
    local growLeft = settings[prefix .. "GrowLeft"]
    local growUp = settings[prefix .. "GrowUp"]

    local anchor
    if growUp then
        anchor = growLeft and "BOTTOMRIGHT" or "BOTTOMLEFT"
    else
        anchor = growLeft and "TOPRIGHT" or "TOPLEFT"
    end

    local count = GetPreviewCount(settings, prefix)
    local icons = {}

    for i = 1, count do
        local icon = CreateFrame("Frame", nil, parent)
        icon:SetSize(iconSize, iconSize)

        local tex = icon:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexCoord(BASE_CROP, 1 - BASE_CROP, BASE_CROP, 1 - BASE_CROP)
        tex:SetTexture(textures[((i - 1) % #textures) + 1])
        icon.Icon = tex

        CreateBorderEdges(icon)

        icon.Stacks = icon:CreateFontString(nil, "OVERLAY")
        CJKFont(icon.Stacks, GetGeneralFont(), 10, GetGeneralFontOutline())
        icon.Stacks:SetPoint("BOTTOMRIGHT", -1, 1)
        icon.Stacks:SetText("")
        icon.Stacks:Hide()

        icon.Cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
        icon.Cooldown:SetAllPoints()
        icon.Cooldown:Clear()
        icon.TextOverlay = CreateFrame("Frame", nil, icon)
        icon.TextOverlay:SetAllPoints()

        local debuffType = debuffTypes and debuffTypes[((i - 1) % #debuffTypes) + 1]
        StyleIcon(icon, settings, isBuff, debuffType)

        local idx = i - 1
        local col = idx % iconsPerRow
        local row = math.floor(idx / iconsPerRow)
        local colStep = iconSize + spacing
        local rowStep = iconSize + rowSpacing
        local xOff = growLeft and -(col * colStep) or (col * colStep)
        local yOff = growUp and (row * rowStep) or -(row * rowStep)
        icon:SetPoint(anchor, parent, anchor, xOff, yOff)
        icon:Show()

        icons[#icons + 1] = icon
    end

    local numCols = math.min(count, iconsPerRow)
    local numRows = math.ceil(count / iconsPerRow)
    local totalW = numCols * iconSize + math.max(0, numCols - 1) * spacing
    local totalH = numRows * iconSize + math.max(0, numRows - 1) * rowSpacing
    parent:SetSize(totalW, totalH)
    parent._naturalW = totalW
    parent._naturalH = totalH

    return icons
end

local function ShowPreview()
    if previewActive then return end
    if not buffContainer or not debuffContainer then return end
    previewActive = true

    local settings = GetSettings()
    if not settings then
        previewActive = false
        return
    end

    -- Disable the live secure containers so the fake icons own the zone.
    if not InCombatLockdown() then
        if buffContainer._auraContainer then
            pcall(buffContainer._auraContainer.SetEnabled, buffContainer._auraContainer, false)
            pcall(buffContainer._auraContainer.Hide, buffContainer._auraContainer)
        end
        if debuffContainer._auraContainer then
            pcall(debuffContainer._auraContainer.SetEnabled, debuffContainer._auraContainer, false)
            pcall(debuffContainer._auraContainer.Hide, debuffContainer._auraContainer)
        end
        if buffCancelHeader then
            -- Drop the combat-visibility driver first: a registered driver
            -- re-Shows the header on the next state flip, defeating the manual
            -- Hide. HidePreview → ApplyOrDefer → ConfigureBuffCancelHeader
            -- re-registers it.
            SetCancelHeaderCombatDriver(buffCancelHeader, false)
            pcall(buffCancelHeader.Hide, buffCancelHeader)
        end
    end
    if tempEnchantFrame then tempEnchantFrame:Hide() end

    if not buffContainer:IsShown() then buffContainer:Show() end
    if not debuffContainer:IsShown() then debuffContainer:Show() end
    buffContainer:SetAlpha(1)
    debuffContainer:SetAlpha(1)

    if not previewBuffOverlay then
        previewBuffOverlay = CreateFrame("Frame", nil, buffContainer)
    end
    previewBuffOverlay:SetAllPoints(buffContainer)
    previewBuffOverlay:SetIgnoreParentAlpha(true)
    previewBuffOverlay:SetFrameStrata("HIGH")
    previewBuffOverlay:Show()

    previewBuffIcons = CreatePreviewGrid(previewBuffOverlay, PREVIEW_BUFF_TEXTURES, nil, settings, "buff", true)

    if not previewDebuffOverlay then
        previewDebuffOverlay = CreateFrame("Frame", nil, debuffContainer)
    end
    previewDebuffOverlay:SetAllPoints(debuffContainer)
    previewDebuffOverlay:SetIgnoreParentAlpha(true)
    previewDebuffOverlay:SetFrameStrata("HIGH")
    previewDebuffOverlay:Show()

    previewDebuffIcons = CreatePreviewGrid(previewDebuffOverlay, PREVIEW_DEBUFF_TEXTURES, PREVIEW_DEBUFF_TYPES, settings, "debuff", false)

    buffContainer._naturalW = previewBuffOverlay._naturalW
    buffContainer._naturalH = previewBuffOverlay._naturalH
    buffContainer:SetSize(previewBuffOverlay._naturalW, previewBuffOverlay._naturalH)
    debuffContainer._naturalW = previewDebuffOverlay._naturalW
    debuffContainer._naturalH = previewDebuffOverlay._naturalH
    debuffContainer:SetSize(previewDebuffOverlay._naturalW, previewDebuffOverlay._naturalH)

    if _G.QUI_LayoutModeSyncHandle then
        _G.QUI_LayoutModeSyncHandle("buffFrame")
        _G.QUI_LayoutModeSyncHandle("debuffFrame")
    end

    for _, slot in ipairs(paSlots) do slot:Hide() end
end

local function HidePreview()
    if not previewActive then return end
    previewActive = false

    for _, icon in ipairs(previewBuffIcons) do icon:Hide() end
    wipe(previewBuffIcons)
    for _, icon in ipairs(previewDebuffIcons) do icon:Hide() end
    wipe(previewDebuffIcons)

    if previewBuffOverlay then previewBuffOverlay:Hide() end
    if previewDebuffOverlay then previewDebuffOverlay:Hide() end

    ApplyOrDefer()
end

---------------------------------------------------------------------------
-- GROW ANCHOR (settings → frame anchoring corner)
---------------------------------------------------------------------------
local GROW_ANCHOR_FRAC_X = { TOPLEFT = 0, TOPRIGHT = 1, BOTTOMLEFT = 0, BOTTOMRIGHT = 1 }
local GROW_ANCHOR_FRAC_Y = { TOPLEFT = 1, TOPRIGHT = 1, BOTTOMLEFT = 0, BOTTOMRIGHT = 0 }

local function UpdateGrowAnchor(faKey)
    if not faKey then return end
    local profile = QUI and QUI.db and QUI.db.profile
    if not profile then return end
    local bbDB = profile.buffBorders
    if type(bbDB) ~= "table" then return end

    local growLeft, growUp
    if faKey == "buffFrame" then
        growLeft = bbDB.buffGrowLeft
        growUp   = bbDB.buffGrowUp
    elseif faKey == "debuffFrame" then
        growLeft = bbDB.debuffGrowLeft
        growUp   = bbDB.debuffGrowUp
    else
        return
    end

    local newCorner
    if growUp then
        newCorner = growLeft and "BOTTOMRIGHT" or "BOTTOMLEFT"
    else
        newCorner = growLeft and "TOPRIGHT" or "TOPLEFT"
    end

    if not profile.frameAnchoring then
        profile.frameAnchoring = {}
    end
    if not profile.frameAnchoring[faKey] then
        profile.frameAnchoring[faKey] = {}
    end
    local entry = profile.frameAnchoring[faKey]
    local oldCorner = entry.growAnchor

    if oldCorner == newCorner then return end

    local isNewCornerFormat = entry.point == oldCorner
        and entry.relative == oldCorner
        and GROW_ANCHOR_FRAC_X[oldCorner] ~= nil

    local isFreePosition = entry.parent == "disabled" or entry.parent == "screen"
    if isNewCornerFormat and oldCorner and isFreePosition then
        local pw = UIParent:GetWidth()
        local ph = UIParent:GetHeight()
        local dX = (GROW_ANCHOR_FRAC_X[oldCorner] - GROW_ANCHOR_FRAC_X[newCorner]) * pw
        local dY = (GROW_ANCHOR_FRAC_Y[oldCorner] - GROW_ANCHOR_FRAC_Y[newCorner]) * ph
        entry.offsetX = math.floor((entry.offsetX or 0) + dX + 0.5)
        entry.offsetY = math.floor((entry.offsetY or 0) + dY + 0.5)
        entry.point = newCorner
        entry.relative = newCorner
    end

    entry.growAnchor = newCorner

    if _G.QUI_ApplyFrameAnchor then
        _G.QUI_ApplyFrameAnchor(faKey)
    end
end

---------------------------------------------------------------------------
-- FULL REFRESH (called from settings / profile switch)
---------------------------------------------------------------------------
local Init  -- forward declaration

local function FullRefresh()
    if not buffContainer or not debuffContainer then return end

    ManageBlizzardFrames()

    UpdateGrowAnchor("buffFrame")
    UpdateGrowAnchor("debuffFrame")

    if previewActive then
        HidePreview()
        ShowPreview()
        return
    end

    wipe(enchantCachedDuration)

    ApplyOrDefer()

    -- Re-run frame anchoring now that natural sizes are settled.
    if not Helpers.IsLayoutModeActive() then
        if _G.QUI_ApplyFrameAnchor then
            _G.QUI_ApplyFrameAnchor("buffFrame")
            _G.QUI_ApplyFrameAnchor("debuffFrame")
            if _G.QUI_UpdateFramesAnchoredTo then
                _G.QUI_UpdateFramesAnchoredTo("buffFrame")
                _G.QUI_UpdateFramesAnchoredTo("debuffFrame")
            end
        end
    else
        if _G.QUI_LayoutModeSyncHandle then
            _G.QUI_LayoutModeSyncHandle("buffFrame")
            _G.QUI_LayoutModeSyncHandle("debuffFrame")
        end
    end
end

local function TryDeferredFullRefresh()
    if previewActive then return end
    if not initialized then
        Init()
        return
    end
    if not buffContainer or not debuffContainer then return end
    FullRefresh()
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------
local function BuildFrames()
    -- Plain insecure named anchor frames on UIParent. These are the published,
    -- movable frames that the anchoring system resolves by name and positions;
    -- SetSize/Show/SetPoint on them are unprotected. Each owns one forbidden
    -- AuraContainer (created in ApplyContainerConfig) parented to it.
    buffContainer = CreateFrame("Frame", "QUI_BuffIconContainer", UIParent)
    buffContainer:SetSize(1, 1)
    buffContainer:SetClampedToScreen(true)

    debuffContainer = CreateFrame("Frame", "QUI_DebuffIconContainer", UIParent)
    debuffContainer:SetSize(1, 1)
    debuffContainer:SetClampedToScreen(true)

    -- Small SEPARATE insecure temp-enchant strip (synthetic non-aura entries).
    tempEnchantFrame = CreateFrame("Frame", "QUI_TempEnchantStrip", buffContainer)
    tempEnchantFrame.buttons = {}
    tempEnchantFrame:SetSize(1, 1)
    tempEnchantFrame:Hide()
end

Init = function()
    if initialized then return true end
    initialized = true

    BuildFrames()

    local settings = GetSettings()

    UpdateGrowAnchor("buffFrame")
    UpdateGrowAnchor("debuffFrame")

    local applyAnchor = _G.QUI_ApplyFrameAnchor
    if applyAnchor then
        applyAnchor("buffFrame")
        applyAnchor("debuffFrame")
    end

    ManageBlizzardFrames()

    -- Create + configure the live containers (forbidden objects → OOC; defers to
    -- PLAYER_REGEN_ENABLED if Init somehow lands in combat).
    ApplyOrDefer()

    -- Temp-enchant events: inventory + enchant changes re-read GetWeaponEnchantInfo.
    buffContainer:RegisterEvent("WEAPON_ENCHANT_CHANGED")
    buffContainer:SetScript("OnEvent", function(self, event)
        if previewActive then return end
        if event == "WEAPON_ENCHANT_CHANGED" then
            wipe(enchantCachedDuration)
            RefreshTempEnchants()
        end
    end)

    -- Re-apply shortly after build so anchoring + first auras settle (mirrors the
    -- legacy double-tap).
    C_Timer.After(0.1, ApplyOrDefer)
    C_Timer.After(0.5, TryDeferredFullRefresh)
    C_Timer.After(2.0, TryDeferredFullRefresh)
    return true
end

---------------------------------------------------------------------------
-- EVENT HANDLING
---------------------------------------------------------------------------
-- The live container self-drives UNIT_AURA C-side, so QUI no longer polls auras
-- on UNIT_AURA. We only refresh the SEPARATE temp-enchant strip on inventory
-- changes (its data comes from GetWeaponEnchantInfo, not UNIT_AURA).
local enchantEventFrame = CreateFrame("Frame")
enchantEventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
enchantEventFrame:SetScript("OnEvent", function(self, event, unit)
    if unit == "player" then
        wipe(enchantCachedDuration)
        RefreshTempEnchants()
    end
end)

-- Combat-end handler: replay container work that was deferred during combat.
-- Gated by pendingContainerWork (set only when ApplyOrDefer hits an in-combat
-- forbidden-object restriction), so this is a no-op on a normal combat end and
-- no longer triggers a full secure-header rebuild every time combat ends.
local paRegenFrame = CreateFrame("Frame")
paRegenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
paRegenFrame:SetScript("OnEvent", function()
    FlushPendingContainerWork()
    if pendingChildStyle then
        pendingChildStyle = false
        ScheduleChildStyle()
    end
end)

-- Debug instrumentation.
local function SetupDebugInstrumentation()
    buffBorderStats = {
        containerConfigs = 0,
    }
    local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "BB_enchantCache", tbl = enchantCachedDuration }
    mp[#mp + 1] = { name = "BB_containerConfigs", counter = true, fn = function() return buffBorderStats.containerConfigs end }
    local reg = ns.QUI_PerfRegistry or {}; ns.QUI_PerfRegistry = reg
    reg[#reg + 1] = { name = "BuffBorders_CombatEnd",    frame = paRegenFrame }
    reg[#reg + 1] = { name = "BuffBorders_EnchantEvent", frame = enchantEventFrame }
end
if ns.DebugRegister then -- gate contract: core/debug_gate.lua
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation() -- standalone test harness: no gate, run eagerly
end

-- Primary initialization is called from core/main.lua during the ADDON_LOADED
-- safe window. Keep this retry for unusual load orders and combat-end recovery.
C_Timer.After(1, TryDeferredFullRefresh)

---------------------------------------------------------------------------
-- EXPORTS
---------------------------------------------------------------------------
local function RefreshBuffBorders()
    if not initialized and not Init() then return end
    FullRefresh()
end

QUI.BuffBorders = {
    Init = Init,
    Apply = RefreshBuffBorders,
    ShowPreview = ShowPreview,
    HidePreview = HidePreview,
}

-- Global function for config panel / layout mode to call
_G.QUI_RefreshBuffBorders = RefreshBuffBorders

-- Layout mode preview hooks
_G.QUI_BuffBordersShowPreview = ShowPreview
_G.QUI_BuffBordersHidePreview = HidePreview

if ns.Registry then
    ns.Registry:Register("buffBorders", {
        refresh = _G.QUI_RefreshBuffBorders,
        priority = 60,
        group = "ui",
        importCategories = { "cdm" },
    })
end
