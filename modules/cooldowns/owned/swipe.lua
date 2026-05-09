-- cooldownswipe.lua
-- Granular cooldown swipe control for addon-owned CDM icons.
-- Simplified: operates directly on QUI's owned icon frames.
-- No hooks, no pulse tickers, no deferred operations needed.

local _, ns = ...
local Helpers = ns.Helpers

-- Default settings
local DEFAULTS = {
    showBuffSwipe = true,
    showBuffIconSwipe = true,
    showGCDSwipe = true,
    showCooldownSwipe = true,
    -- Overlay color: shown when spell/buff is ACTIVE (aura duration)
    overlayColorMode = "default",  -- "default" | "class" | "accent" | "custom"
    overlayColor = {1, 1, 1, 1},
    -- Swipe color: shown when spell is ON COOLDOWN (radial darkening)
    swipeColorMode = "default",
    swipeColor = {1, 1, 1, 1},
}

-- Get settings from AceDB via shared helper
local function GetSettings()
    return Helpers.GetModuleSettings("cooldownSwipe", DEFAULTS)
end

---------------------------------------------------------------------------
-- COLOR RESOLUTION
---------------------------------------------------------------------------
local function GetClassColor()
    local _, class = UnitClass("player")
    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if classColor then
        return classColor.r, classColor.g, classColor.b, 0.8
    end
    return 1, 1, 1, 0.8
end

-- Resolve r,g,b,a for a given mode + stored color table; nil = leave default.
local function ResolveColor(mode, colorTable)
    if mode == "class" then
        return GetClassColor()
    elseif mode == "accent" then
        local QUI = _G.QUI
        if QUI and QUI.GetSkinColor then
            local r, g, b = QUI:GetSkinColor()
            return r, g, b, 0.8
        end
        return 0.376, 0.647, 0.980, 0.8  -- fallback sky blue
    elseif mode == "custom" then
        local c = colorTable or {}
        return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
    end
    return nil  -- "default": don't override
end

-- CDM default swipe color (dark overlay for cooldowns)
local CDM_DEFAULT_R, CDM_DEFAULT_G, CDM_DEFAULT_B, CDM_DEFAULT_A = 0, 0, 0, 0.8
-- Blizzard default buff/aura overlay color (yellow)
local BLIZZ_BUFF_R, BLIZZ_BUFF_G, BLIZZ_BUFF_B, BLIZZ_BUFF_A = 0.93, 0.77, 0.0, 0.45
local FULL_FRAME_SWIPE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local function SettingEnabled(value, fallback)
    if value == nil then
        return fallback == true
    end
    return value == true
end

---------------------------------------------------------------------------
-- APPLY SWIPE TO A SINGLE ICON
-- Classification prefers the icon's active rendered swipe state:
-- aura wins, then explicit GCD render flag, then cooldown.
---------------------------------------------------------------------------
local function ApplySwipeToIcon(icon, settings)
    if not icon or not icon.Cooldown or not icon._spellEntry then return end
    settings = settings or GetSettings()

    local entry = icon._spellEntry
    local isBuffIcon = (entry.viewerType == "buff")
    -- Aura-kind classification is independent of container shape: an aura
    -- entry on a custom cooldown container or essential/utility (kind="aura")
    -- still gets aura-mode swipe styling. Falls back to viewerType when
    -- CDMSpellData is unavailable during early bootstrap.
    local isAuraEntry
    local CDMSpellData = ns.CDMSpellData
    if CDMSpellData and CDMSpellData.IsAuraEntry then
        isAuraEntry = CDMSpellData.IsAuraEntry(entry, entry.viewerType)
    else
        isAuraEntry = (entry.kind == "aura")
            or isBuffIcon
            or entry.viewerType == "trackedBar"
    end

    -- Classify: aura, gcd, or cooldown.
    -- Buff viewer children are always auras. Aura-kind entries always
    -- visualize as aura mode. icon._auraActive is the event-driven flag
    -- maintained by the dispatcher. For all other entries (cooldown-kind,
    -- non-buff), delegate runtime aura-active detection to the shared
    -- helper used by the resolver (CDMIcons.ResolveIconDurationObject) so
    -- visual mode and source-DurationObject selection cannot diverge.
    local mode
    if isAuraEntry or icon._auraActive then
        mode = "aura"
    elseif not isBuffIcon then
        local CDMIcons = ns.CDMIcons
        if CDMIcons and CDMIcons.IsAuraCurrentlyActive then
            local active = CDMIcons.IsAuraCurrentlyActive(entry)
            if active then mode = "aura" end
        end
        -- Buff-pool cross-reference (preserved here, not in the helper —
        -- it depends on the current state of OTHER icons, which is a
        -- visual concern, not a per-entry property).
        if not mode then
            local sid = entry.overrideSpellID or entry.spellID
            if sid and CDMIcons then
                local buffPool = CDMIcons:GetIconPool("buff")
                if buffPool then
                    for _, buffIcon in ipairs(buffPool) do
                        local be = buffIcon._spellEntry
                        if be and (be.overrideSpellID == sid or be.spellID == sid)
                           and buffIcon:IsShown() then
                            mode = "aura"
                            break
                        end
                    end
                end
            end
        end
    end
    if not mode then
        if icon._showingGCDSwipe then
            mode = "gcd"
        else
            mode = "cooldown"
        end
    end

    -- Swipe visibility
    local showSwipe
    if mode == "aura" then
        if isBuffIcon then
            showSwipe = SettingEnabled(settings.showBuffIconSwipe, true)
        else
            showSwipe = SettingEnabled(settings.showBuffSwipe, true)
        end
    elseif mode == "gcd" then
        showSwipe = SettingEnabled(settings.showGCDSwipe, true)
    else
        showSwipe = SettingEnabled(settings.showCooldownSwipe, true)
    end

    -- Apply swipe styling to BOTH our native icon.Cooldown AND the
    -- reparented Blizzard child.Cooldown (if Blizzard-backed). Writing to
    -- both keeps QUI styling consistent regardless of which Cooldown
    -- frame is currently driving the visible swipe.
    local showEdge = showSwipe and (mode == "aura" or (mode == "cooldown" and settings.showRechargeEdge))

    local function applyToCooldown(cd)
        if not cd then return end
        -- Stash intended state on the frame so the mirror's swipe-defense
        -- hook (HookSwipeStyleDefense in cdm_blizz_mirror.lua) can revert
        -- Blizzard's mixin if it tries to re-apply template defaults.
        cd._quiIntendedDrawSwipe = showSwipe and true or false
        cd._quiIntendedDrawEdge  = showEdge and true or false
        cd._quiIntendedSwipeTexture = FULL_FRAME_SWIPE_TEXTURE
        pcall(cd.SetSwipeTexture, cd, FULL_FRAME_SWIPE_TEXTURE)
        pcall(cd.SetDrawSwipe, cd, showSwipe and true or false)
        pcall(cd.SetDrawEdge,  cd, showEdge and true or false)

        -- Apply color and texture based on mode.
        -- When swipe is disabled, force alpha-0 color as a failsafe —
        -- SetCooldownFromDurationObject + SetReverse (aura path) can
        -- internally re-enable drawSwipe on the C-side animation system,
        -- so a transparent color ensures the swipe is invisible regardless.
        local cR, cG, cB, cA
        if not showSwipe then
            cR, cG, cB, cA = 0, 0, 0, 0
        elseif mode == "aura" then
            local oR, oG, oB, oA = ResolveColor(settings.overlayColorMode or "default", settings.overlayColor)
            if not oR then oR, oG, oB, oA = BLIZZ_BUFF_R, BLIZZ_BUFF_G, BLIZZ_BUFF_B, BLIZZ_BUFF_A end
            cR, cG, cB, cA = oR, oG, oB, oA
        else
            local sR, sG, sB, sA = ResolveColor(settings.swipeColorMode or "default", settings.swipeColor)
            if not sR then sR, sG, sB, sA = CDM_DEFAULT_R, CDM_DEFAULT_G, CDM_DEFAULT_B, CDM_DEFAULT_A end
            cR, cG, cB, cA = sR, sG, sB, sA
        end
        cd._quiIntendedSwipeColor = { cR, cG, cB, cA or 1 }
        pcall(cd.SetSwipeColor, cd, cR, cG, cB, cA)
    end

    applyToCooldown(icon.Cooldown)
    applyToCooldown(icon._blizzCooldownFrame)
end

---------------------------------------------------------------------------
-- APPLY SWIPE TO A BLIZZARD BUFF VIEWER CHILD
-- These children have .Icon and .Cooldown but no ._spellEntry.
-- Buff viewer children are always auras, so classification is fixed.
---------------------------------------------------------------------------
local function ApplySwipeToBuffChild(icon, settings)
    if not icon or not icon.Cooldown then return end
    settings = settings or GetSettings()

    -- Buff viewer children are always auras in the buff viewer
    local showSwipe = SettingEnabled(settings.showBuffIconSwipe, true)

    icon.Cooldown:SetDrawSwipe(showSwipe)
    icon.Cooldown:SetDrawEdge(showSwipe)

    if not showSwipe then
        icon.Cooldown:SetSwipeColor(0, 0, 0, 0)
    else
        -- Use overlay color (aura mode) — default to Blizzard yellow
        local oR, oG, oB, oA = ResolveColor(settings.overlayColorMode or "default", settings.overlayColor)
        if not oR then oR, oG, oB, oA = BLIZZ_BUFF_R, BLIZZ_BUFF_G, BLIZZ_BUFF_B, BLIZZ_BUFF_A end

        icon.Cooldown:SetSwipeTexture("Interface\\Buttons\\WHITE8X8")
        icon.Cooldown:SetSwipeColor(oR, oG, oB, oA)
    end
end

---------------------------------------------------------------------------
-- REFRESH ALL ICONS
---------------------------------------------------------------------------
local function RefreshAllSwipes()
    local CDMIcons = ns.CDMIcons
    if not CDMIcons then return end

    local settings = GetSettings()

    if CDMIcons.UpdateAllCooldowns then
        CDMIcons:UpdateAllCooldowns()
    end

    -- Addon-owned icons (essential, utility, buff)
    for _, viewerType in ipairs({"essential", "utility", "buff"}) do
        local pool = CDMIcons:GetIconPool(viewerType)
        for _, icon in ipairs(pool) do
            ApplySwipeToIcon(icon, settings)
        end
    end
end

-- EXPORTS
---------------------------------------------------------------------------
ns._OwnedSwipe = {
    Apply = RefreshAllSwipes,
    ApplyToIcon = ApplySwipeToIcon,
    ApplyToBuffChild = ApplySwipeToBuffChild,
    GetSettings = GetSettings,
}
