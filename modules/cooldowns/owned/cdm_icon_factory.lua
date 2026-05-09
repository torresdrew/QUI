-- cdm_icon_factory.lua
-- Icon pool lifecycle and the UpdateIconCooldown driver for the QUI CDM
-- owned engine. Frame writes happen here (and in cdm_icons.lua's view layer);
-- this file is allowed to call frame:Set*. It depends on cdm_resolvers.lua
-- for pure resolution and tick-cache reads.

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local Resolvers = ns.CDMResolvers

-- Forward reference to ns.CDMIcons. Bound by _FinalizeImports() at the
-- end of cdm_icons.lua's load. Cannot be `local CDMIcons = ns.CDMIcons`
-- here because cdm_icon_factory.lua loads before cdm_icons.lua per owned.xml.
local CDMIcons

local CDMIconFactory = {}
ns.CDMIconFactory = CDMIconFactory

---------------------------------------------------------------------------
-- LOCAL UPVALUE ALIASES
---------------------------------------------------------------------------
local GetGeneralFont        = Helpers.GetGeneralFont
local GetGeneralFontOutline = Helpers.GetGeneralFontOutline
local GetEntryTexture       = Resolvers.GetEntryTexture
local GetSpellTexture       = Resolvers.GetSpellTexture
-- Tick-cache reads used by UpdateIconCooldown driver
local QueryCharges        = Resolvers.QueryCharges
local QueryCooldown       = Resolvers.QueryCooldown
local QueryOverrideSpell  = Resolvers.QueryOverrideSpell
local QueryDisplayCount   = Resolvers.QueryDisplayCount
-- Pure resolvers used by UpdateIconCooldown driver
local ResolveAuraStateForIcon    = Resolvers.ResolveAuraStateForIcon
local HasRealCooldownState       = Resolvers.HasRealCooldownState
local ResolveMacro               = Resolvers.ResolveMacro
local IsAuraEntry                = Resolvers.IsAuraEntry
-- Helpers from cdm_icons.lua (local functions or namespace exposures there;
-- factory uses bare names via these upvalues so call sites stay clean).
-- All bound late by _FinalizeImports() at the end of cdm_icons.lua's load
-- because ns.CDMIcons is still nil at this point in the load order.
local GetBestSpellCooldown
local GetItemCooldown
local GetSlotCooldown
local IsTotemSlotEntry
local ApplyAuraStateToIcon
local ApplyResolvedCooldown
local ReapplySwipeStyle
local UpdateIconProfessionQuality
local ChargeDebug
local HookTextHasDisplay

local InCombatLockdown = InCombatLockdown
local CreateFrame      = CreateFrame
local type             = type
local pcall            = pcall

---------------------------------------------------------------------------
-- CONSTANTS (mirrors cdm_icons.lua; both refer to the same design values)
---------------------------------------------------------------------------
local DEFAULT_ICON_SIZE      = 39
local MAX_RECYCLE_POOL_SIZE  = 20
local GCD_MAX_DURATION       = 1.75

local function IsMouseoverRevealContext(context)
    local core = ns.Addon
    local profile = core and core.db and core.db.profile
    local visibility
    if context == "customTrackers" then
        visibility = profile and profile.customTrackersVisibility
    else
        visibility = profile and profile.cdmVisibility
    end
    return visibility and not visibility.showAlways and visibility.showOnMouseover
end

---------------------------------------------------------------------------
-- POOL STATE
---------------------------------------------------------------------------
local iconPools = {
    essential = {},
    utility   = {},
    buff      = {},
}
-- Pools for custom containers are created dynamically via EnsurePool().
local recyclePool = {}
do local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "CDM_iconRecyclePool", tbl = recyclePool }
    -- iconPools is a multi-key map of arrays; count across every sub-pool
    -- (incl. dynamically created Composer pools) so retention growth surfaces.
    mp[#mp + 1] = { name = "CDM_iconPools", fn = function()
        local count, deep = 0, 0
        for _, pool in pairs(iconPools) do
            count = count + 1
            if type(pool) == "table" then
                for _ in pairs(pool) do deep = deep + 1 end
            end
        end
        return count, deep
    end }
end
local iconCounter = 0

-- Expose pool tables so cdm_icons.lua can alias them as upvalues
-- (same table object — not a copy).
CDMIconFactory._iconPools   = iconPools
CDMIconFactory._recyclePool = recyclePool

---------------------------------------------------------------------------
-- ICON CREATION
-- Frame structure: Frame parent with .Icon, .Cooldown, .Border,
-- .DurationText, .StackText children.
---------------------------------------------------------------------------
local function CreateIcon(parent, spellEntry)
    iconCounter = iconCounter + 1
    local frameName = "QUICDMIcon" .. iconCounter

    local icon = CreateFrame("Frame", frameName, parent)
    local size = DEFAULT_ICON_SIZE
    icon:SetSize(size, size)

    -- .Icon texture (ARTWORK layer)
    icon.Icon = icon:CreateTexture(nil, "ARTWORK")
    icon.Icon:SetAllPoints(icon)

    -- .Cooldown frame (CooldownFrameTemplate for swipe/countdown)
    icon.Cooldown = CreateFrame("Cooldown", frameName .. "Cooldown", icon, "CooldownFrameTemplate")
    icon.Cooldown:SetAllPoints(icon)
    icon.Cooldown:SetDrawSwipe(true)
    icon.Cooldown:SetHideCountdownNumbers(false)
    icon.Cooldown:SetSwipeTexture("Interface\\Buttons\\WHITE8X8")
    icon.Cooldown:SetSwipeColor(0, 0, 0, 0.8)
    icon.Cooldown:SetDrawBling(true)
    icon.Cooldown:EnableMouse(false)

    -- .TextOverlay (sits above the CooldownFrame so text is never behind the swipe)
    icon.TextOverlay = CreateFrame("Frame", nil, icon)
    icon.TextOverlay:SetAllPoints(icon)
    icon.TextOverlay:SetFrameLevel(icon.Cooldown:GetFrameLevel() + 2)
    icon.TextOverlay:EnableMouse(false)

    -- .Border texture (BACKGROUND, sublayer -8, pre-created)
    icon.Border = icon:CreateTexture(nil, "BACKGROUND", nil, -8)
    icon.Border:Hide()

    -- .DurationText (OVERLAY, sublayer 7 — parented to TextOverlay, above swipe)
    icon.DurationText = icon.TextOverlay:CreateFontString(nil, "OVERLAY", nil, 7)
    icon.DurationText:SetPoint("CENTER")

    -- .StackText (OVERLAY, sublayer 7 — parented to TextOverlay, above swipe)
    icon.StackText = icon.TextOverlay:CreateFontString(nil, "OVERLAY", nil, 7)
    icon.StackText:SetPoint("BOTTOMRIGHT")

    -- Set a default font so SetText() never fires before ConfigureIcon styles them
    local defaultFont = GetGeneralFont()
    local defaultOutline = GetGeneralFontOutline()
    icon.DurationText:SetFont(defaultFont, 10, defaultOutline)
    icon.StackText:SetFont(defaultFont, 10, defaultOutline)

    -- Metadata
    icon._spellEntry = spellEntry
    icon._isQUICDMIcon = true
    if ns.HookFrameForMouseover then
        ns.HookFrameForMouseover(icon)
    end

    -- Set texture
    if spellEntry then
        local texID
        if spellEntry.type then
            texID = GetEntryTexture(spellEntry)
        else
            texID = GetSpellTexture(spellEntry.overrideSpellID or spellEntry.spellID)
        end
        -- Aura entries: dynamic buff icon (e.g., Roll the Bones → Broadside)
        -- arrives via the per-tick UpdateIconCooldown path, which reads the
        -- live aura's icon from r.auraData.icon. Initial icon is the
        -- composer-resolved entry texture.
        if texID then
            icon.Icon:SetTexture(texID)
            -- Only lock texture for cooldown entries — aura icons rely on
            -- the tick update + Blizzard texture hook for dynamic changes.
            if not spellEntry.isAura then
                icon._desiredTexture = texID
            end
        end
        CDMIcons.UpdateIconProfessionQuality(icon)
    end

    -- Tooltip support
    icon:EnableMouse(true)
    icon:SetScript("OnEnter", function(self)
        if GameTooltip.IsForbidden and GameTooltip:IsForbidden() then return end
        local tooltipProvider = ns.TooltipProvider
        local tooltipContext = self._quiTooltipContext
            or self.__quiTooltipContext
            or (self.__customTrackerIcon and "customTrackers")
            or "cdm"
        if tooltipProvider then
            if tooltipProvider.IsOwnerFadedOut
               and tooltipProvider:IsOwnerFadedOut(self)
               and not IsMouseoverRevealContext(tooltipContext) then
                pcall(GameTooltip.Hide, GameTooltip)
                return
            end
            if tooltipProvider.ShouldShowTooltip and not tooltipProvider:ShouldShowTooltip(tooltipContext) then
                pcall(GameTooltip.Hide, GameTooltip)
                return
            end
        end
        local entry = self._spellEntry
        if not entry then return end
        local tooltipSettings = QUICore and QUICore.db and QUICore.db.profile and QUICore.db.profile.tooltip
        if (not tooltipProvider) and tooltipSettings and tooltipSettings.hideInCombat and InCombatLockdown() then return end
        if tooltipSettings and tooltipSettings.anchorToCursor then
            local anchorTooltip = ns.QUI_AnchorTooltipToCursor
            if anchorTooltip then
                anchorTooltip(GameTooltip, self, tooltipSettings)
            else
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            end
        else
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        end
        -- Prefer the resolver's active aura identity. Avoid ad-hoc live aura
        -- lookups here; tooltip hover should not bypass the same filtering
        -- rules that drive the icon face and swipe.
        local sid = self._activeAuraSpellID
        if not sid then
            sid = self._runtimeSpellID
        end
        if not sid then
            sid = ns.CDMSpellData:ResolveDisplaySpellID(entry)
        end
        if sid then
            if entry.type == "trinket" or entry.type == "slot" then
                local itemID = entry.itemID or GetInventoryItemID("player", entry.id)
                if itemID then
                    pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
                end
            elseif entry.type == "item" then
                pcall(GameTooltip.SetItemByID, GameTooltip, entry.id)
            else
                pcall(GameTooltip.SetSpellByID, GameTooltip, sid)
            end
        end
        -- Append a source-spec line for entries migrated from a legacy
        -- spec-specific bar so the user can see at a glance where the
        -- entry came from (e.g. "Source: Discipline Priest"). Resolver
        -- writes _sourceSpecID at migration time.
        local srcSpecID = entry._sourceSpecID
        if type(srcSpecID) == "number" and GetSpecializationInfoByID then
            local _, specName, _, _, _, classToken = GetSpecializationInfoByID(srcSpecID)
            if specName then
                local label = classToken and ("%s %s"):format(specName, classToken) or specName
                pcall(GameTooltip.AddLine, GameTooltip, ("Source: %s"):format(label), 0.75, 0.85, 1, true)
            end
        end
        pcall(GameTooltip.Show, GameTooltip)
    end)
    icon:SetScript("OnLeave", function()
        pcall(GameTooltip.Hide, GameTooltip)
    end)

    icon:Hide()
    return icon
end

---------------------------------------------------------------------------
-- ICON POOL LIFECYCLE
---------------------------------------------------------------------------
function CDMIconFactory:AcquireIcon(parent, spellEntry)
    local icon = table.remove(recyclePool)
    if icon then
        CDMIcons.CancelCooldownExpiryRefresh(icon)
        icon:SetParent(parent)
        icon:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
        icon._spellEntry = spellEntry
        icon._isQUICDMIcon = true
        icon._lastStart = nil
        icon._lastDuration = nil
        icon._isOnGCD = nil
        icon._isOnGCDTrustedAt = nil
        icon._showingGCDSwipe = nil
        icon._showingRealCooldownSwipe = nil
        icon._wasShowingGCDSwipe = nil
        icon._lastAuraDurObj = nil
        icon._lastAuraSourceID = nil
        icon._hasCooldownActive = nil
        icon._hasRealCooldownActive = nil
        icon._resolvedCooldownMode = nil
        icon._isTotemInstance = nil
        icon._totemSlot = spellEntry and spellEntry._totemSlot or nil
        icon._totemIconCache = nil
        icon._pendingTotemSlotRefresh = nil
        icon._customBarActive = nil
        icon._customBarActiveType = nil
        icon._customBarActiveStart = nil
        icon._customBarActiveDuration = nil
        CDMIcons.StopCustomBarActiveGlow(icon)
        CDMIcons.ChargeDebug(spellEntry and spellEntry.name, "ACQUIRE", "reused", "viewerType=", spellEntry and spellEntry.viewerType)

        -- Update texture
        local texID
        if spellEntry.type then
            texID = GetEntryTexture(spellEntry)
        else
            texID = GetSpellTexture(spellEntry.overrideSpellID or spellEntry.spellID)
        end
        if icon.Icon then
            if texID then
                icon.Icon:SetTexture(texID)
                -- Only lock texture for cooldown entries — aura icons rely on
                -- the Blizzard texture hook for the correct aura icon.
                icon._desiredTexture = (not spellEntry.isAura) and texID or nil
            else
                -- Clear stale texture from previous owner to prevent
                -- recycled icons showing the wrong spell/item icon.
                icon.Icon:SetTexture(nil)
                icon._desiredTexture = nil
            end
            icon.Icon:SetDesaturated(false)
        end
        CDMIcons.UpdateIconProfessionQuality(icon)

        if icon.Cooldown then
            icon.Cooldown:Clear()
        end
        icon.StackText:SetText("")
        icon.StackText:Hide()
        -- Update click-to-cast secure attributes for recycled icons
        if spellEntry.viewerType ~= "buff" then
            CDMIcons.UpdateIconSecureAttributes(icon, spellEntry, spellEntry.viewerType)
        end
        icon:Hide()
        -- Bind to a Blizzard CDM child if this entry has one. On a recycled
        -- icon this also clears any stale binding from the previous owner.
        -- Routed through CDMIconFactory.* (table lookup) because the helper
        -- is defined later in this file and the local upvalue isn't visible
        -- here at parse time.
        CDMIconFactory.TryBindIconToBlizz(icon, spellEntry)
        -- Notify rotation helper that an icon was assigned a spell
        if ns._onIconAssigned then pcall(ns._onIconAssigned, icon) end
        return icon
    end
    local newIcon = CreateIcon(parent, spellEntry)
    CDMIcons.ChargeDebug(spellEntry and spellEntry.name, "ACQUIRE", "new", "viewerType=", spellEntry and spellEntry.viewerType)
    -- Update click-to-cast secure attributes for new icons
    if spellEntry.viewerType ~= "buff" then
        CDMIcons.UpdateIconSecureAttributes(newIcon, spellEntry, spellEntry.viewerType)
    end
    -- Bind to a Blizzard CDM child if this entry has one.
    CDMIconFactory.TryBindIconToBlizz(newIcon, spellEntry)
    -- Notify rotation helper that an icon was assigned a spell
    if ns._onIconAssigned then pcall(ns._onIconAssigned, newIcon) end
    return newIcon
end

function CDMIconFactory:ReleaseIcon(icon)
    if not icon then return end
    if _G.QUI_CDM_CHARGE_DEBUG then
        CDMIcons.ChargeDebug(icon._spellEntry and icon._spellEntry.name, "RELEASE",
            "viewerType=", icon._spellEntry and icon._spellEntry.viewerType,
            "shown=", icon.IsShown and icon:IsShown())
    end
    -- Drop any Blizzard child reparent and restore native widget visibility
    -- before the rest of release-state cleanup runs. Table-routed because
    -- the helper is defined later in this file.
    CDMIconFactory.ClearIconBlizzBacking(icon)
    CDMIcons.CancelCooldownExpiryRefresh(icon)
    -- Disconnect hooks before clearing _spellEntry
    CDMIcons.UnmirrorBlizzCooldown(icon)
    if ns._OwnedGlows and ns._OwnedGlows.ClearPandemicState then
        ns._OwnedGlows.ClearPandemicState(icon)
    end
    -- The keybind FontString and rotation-helper overlay are parented to the
    -- icon and travel with it through the shared recycle pool. Clear them so
    -- a recycled icon doesn't bring a previous viewer's keybind text into a
    -- container whose Show Keybinds is off (or which never paints keybinds).
    if _G.QUI_ClearKeybindIconState then
        _G.QUI_ClearKeybindIconState(icon)
    end
    icon:Hide()
    icon:ClearAllPoints()
    icon._spellEntry = nil
    icon._rangeTinted = nil
    icon._usabilityTinted = nil
    icon._cdDesaturated = nil
    icon._spellOverrideDesaturate = nil
    icon._desaturateIgnoreAura = nil
    icon._lastStart = nil
    icon._lastDuration = nil
    icon._isOnGCD = nil
    icon._isOnGCDTrustedAt = nil
    icon._showingGCDSwipe = nil
    icon._showingRealCooldownSwipe = nil
    icon._wasShowingGCDSwipe = nil
    icon._lastAuraDurObj = nil
    icon._lastAuraSourceID = nil
    icon._activeAuraSpellID = nil
    icon._auraIsHarmful = nil
    icon._lastTexture = nil
    icon._hasCooldownActive = nil
    icon._hasRealCooldownActive = nil
    icon._resolvedCooldownMode = nil
    icon._isTotemInstance = nil
    icon._totemSlot = nil
    icon._totemIconCache = nil
    icon._pendingTotemSlotRefresh = nil
    icon._lastLayoutFilterHidden = nil
    icon._customBarActive = nil
    icon._customBarActiveType = nil
    icon._customBarActiveStart = nil
    icon._customBarActiveDuration = nil
    icon._rowConfig = nil
    icon._quiTooltipContext = nil
    icon.__quiTooltipContext = nil
    icon.__customTrackerIcon = nil
    CDMIcons.StopCustomBarActiveGlow(icon)
    -- Reset grey-out child alpha (set by greyOutInactive/greyOutInactiveBuffs)
    icon._greyType = nil
    if icon._greyedOut then
        icon._greyedOut = nil
        if icon.Icon then icon.Icon:SetAlpha(1) end
        if icon.Cooldown then icon.Cooldown:SetAlpha(1) end
        if icon.Border then icon.Border:SetAlpha(1) end
        if icon.DurationText then icon.DurationText:SetAlpha(1) end
        if icon.StackText then icon.StackText:SetAlpha(1) end
    end
    if icon.Icon then
        icon.Icon:SetVertexColor(1, 1, 1, 1)
        icon.Icon:SetDesaturated(false)
    end
    if icon.Cooldown then
        icon.Cooldown:Clear()
    end
    icon.StackText:SetText("")
    icon.StackText:Hide()
    icon.Border:Hide()
    CDMIcons.ClearIconProfessionQuality(icon)

    -- Clear click-to-cast secure button
    if icon.clickButton then
        if not InCombatLockdown() then
            CDMIcons.ClearClickButtonAttributes(icon.clickButton)
            icon.clickButton:Hide()
        end
    end
    icon._pendingSecureUpdate = nil

    if #recyclePool < MAX_RECYCLE_POOL_SIZE then
        icon:SetParent(UIParent)
        recyclePool[#recyclePool + 1] = icon
    end
end


-- BLIZZ MIRROR

-- Keep CooldownFrame ready-flash ("bling") hidden when icon is effectively invisible.
-- This prevents GCD-ready glow from leaking through when row/container alpha is 0.
local function SyncCooldownBling(icon)
    if not icon or not icon.Cooldown or not icon.Cooldown.SetDrawBling then return end
    local effectiveAlpha = (icon.GetEffectiveAlpha and icon:GetEffectiveAlpha()) or icon:GetAlpha() or 1
    local shouldDrawBling = (effectiveAlpha > 0.001) and icon:IsShown()
    if icon._drawBlingEnabled ~= shouldDrawBling then
        icon._drawBlingEnabled = shouldDrawBling
        icon.Cooldown:SetDrawBling(shouldDrawBling)
    end
end

CDMIconFactory.SyncCooldownBling = SyncCooldownBling


---------------------------------------------------------------------------
-- BLIZZARD CHILD HOSTING
--
-- For entries that map to a Blizzard CDM cooldownID, the icon hosts the
-- viewer's child frame directly: Blizzard's own swipe / charge / aura-stack
-- widgets render inside our QUI icon and Blizzard remains the sole writer
-- of secret-safe state (DurationObjects flow through C-side sinks the
-- viewer mixin already drives). UpdateIconCooldown short-circuits when
-- _isBlizzBacked is set.
---------------------------------------------------------------------------
local function HideNativeIconWidgets(icon)
    if icon.Icon then pcall(icon.Icon.Hide, icon.Icon) end
    if icon.Cooldown then
        -- Hide() alone is not sufficient: CooldownFrame's swipe state can be
        -- redrawn by SetCooldown calls or by other QUI paths that bypass
        -- our short-circuits. Neutralize every rendering primitive so even
        -- if the frame becomes visible again, nothing paints over the
        -- reparented Blizzard child below.
        pcall(icon.Cooldown.Clear,                  icon.Cooldown)
        pcall(icon.Cooldown.SetDrawSwipe,           icon.Cooldown, false)
        pcall(icon.Cooldown.SetDrawEdge,            icon.Cooldown, false)
        pcall(icon.Cooldown.SetDrawBling,           icon.Cooldown, false)
        pcall(icon.Cooldown.SetSwipeColor,          icon.Cooldown, 0, 0, 0, 0)
        pcall(icon.Cooldown.SetHideCountdownNumbers, icon.Cooldown, true)
        pcall(icon.Cooldown.Hide,                   icon.Cooldown)
    end
    if icon.DurationText then pcall(icon.DurationText.Hide, icon.DurationText) end
    if icon.StackText    then pcall(icon.StackText.Hide,    icon.StackText)    end
    -- icon.Border intentionally NOT hidden: QUI's border styling stays
    -- in effect for Blizzard-backed icons too. The shape mismatch (square
    -- Border behind a circular masked Icon) is fixed in
    -- ApplyCircularMaskToBorder, called from SetIconBlizzBacking.
    if icon.TextOverlay  then pcall(icon.TextOverlay.Hide,  icon.TextOverlay)  end
end

local function ShowNativeIconWidgets(icon)
    if icon.Icon then pcall(icon.Icon.Show, icon.Icon) end
    if icon.Cooldown then
        -- Restore the QUI native Cooldown's rendering primitives to their
        -- factory defaults (mirrors CreateIcon's setup). The swipe color is
        -- intentionally black at 0.8 alpha — that's the QUI swipe style.
        pcall(icon.Cooldown.SetDrawSwipe,           icon.Cooldown, true)
        pcall(icon.Cooldown.SetDrawBling,           icon.Cooldown, true)
        pcall(icon.Cooldown.SetSwipeTexture,        icon.Cooldown, "Interface\\Buttons\\WHITE8X8")
        pcall(icon.Cooldown.SetSwipeColor,          icon.Cooldown, 0, 0, 0, 0.8)
        pcall(icon.Cooldown.SetHideCountdownNumbers, icon.Cooldown, false)
        pcall(icon.Cooldown.Show,                   icon.Cooldown)
    end
    -- DurationText / StackText / Border are content-driven (only Show'd when
    -- they have text/atlas). Don't force Show — let the per-tick driver
    -- restore visibility based on actual state.
    if icon.TextOverlay  then pcall(icon.TextOverlay.Show,  icon.TextOverlay)  end
end

local function SetBlizzAuraFallbackActive(icon, enabled)
    if not icon then return false end
    enabled = enabled == true
    -- Field is stored as true/nil (not true/false), so a direct == against
    -- a normalized boolean misfires as "changed" every tick when enabled is
    -- false and the field is nil (nil ~= false in Lua). Normalize first.
    local prior = icon._blizzAuraFallbackActive == true
    if prior == enabled then
        return false
    end
    icon._blizzAuraFallbackActive = enabled or nil

    if enabled then
        if icon.Icon then
            pcall(icon.Icon.Show, icon.Icon)
        end
        if icon.Cooldown then
            pcall(icon.Cooldown.SetAlpha, icon.Cooldown, 1)
            pcall(icon.Cooldown.SetDrawSwipe, icon.Cooldown, true)
            pcall(icon.Cooldown.SetSwipeTexture, icon.Cooldown, "Interface\\Buttons\\WHITE8X8")
            pcall(icon.Cooldown.SetSwipeColor, icon.Cooldown, 0, 0, 0, 0.8)
            pcall(icon.Cooldown.SetDrawBling, icon.Cooldown, false)
            pcall(icon.Cooldown.SetHideCountdownNumbers, icon.Cooldown, false)
            pcall(icon.Cooldown.Show, icon.Cooldown)
        end
        if icon._blizzCooldownFrame then
            pcall(icon._blizzCooldownFrame.SetAlpha, icon._blizzCooldownFrame, 0)
            pcall(icon._blizzCooldownFrame.SetDrawSwipe, icon._blizzCooldownFrame, false)
            pcall(icon._blizzCooldownFrame.SetDrawEdge, icon._blizzCooldownFrame, false)
            pcall(icon._blizzCooldownFrame.SetSwipeColor, icon._blizzCooldownFrame, 0, 0, 0, 0)
        end
        if icon._blizzDurationText then
            pcall(icon._blizzDurationText.Hide, icon._blizzDurationText)
        end
        if icon._blizzApplications then
            pcall(icon._blizzApplications.Hide, icon._blizzApplications)
        end
        if icon._blizzApplicationsText then
            pcall(icon._blizzApplicationsText.Hide, icon._blizzApplicationsText)
        end
    else
        icon._showingRealCooldownSwipe = nil
        icon._nativeAuraNoDurationCleared = nil
        if icon.Cooldown then
            pcall(icon.Cooldown.Clear, icon.Cooldown)
        end
        HideNativeIconWidgets(icon)
        if icon._blizzCooldownFrame then
            pcall(icon._blizzCooldownFrame.SetAlpha, icon._blizzCooldownFrame, 1)
            pcall(icon._blizzCooldownFrame.Show, icon._blizzCooldownFrame)
        end
        if icon._blizzDurationText and icon._rowConfig
           and icon._rowConfig.hideDurationText ~= true then
            pcall(icon._blizzDurationText.Show, icon._blizzDurationText)
        end
        if icon._blizzApplications then
            pcall(icon._blizzApplications.Show, icon._blizzApplications)
        end
    end

    return true
end

local function SetIconBlizzBacking(icon, cooldownID)
    if not (icon and cooldownID) then return end
    icon._blizzAuraFallbackActive = nil
    icon._isBlizzBacked = cooldownID
    HideNativeIconWidgets(icon)
    local mirror = ns.CDMBlizzMirror
    if mirror and mirror.RegisterHostSlot then
        mirror.RegisterHostSlot(icon, cooldownID)
    end
end

local function ClearIconBlizzBacking(icon)
    if not icon or not icon._isBlizzBacked then return end
    icon._blizzAuraFallbackActive = nil
    icon._isBlizzBacked = nil
    local mirror = ns.CDMBlizzMirror
    if mirror and mirror.UnregisterHostSlot then
        mirror.UnregisterHostSlot(icon)
    end
    ShowNativeIconWidgets(icon)
end

CDMIconFactory.SetIconBlizzBacking   = SetIconBlizzBacking
CDMIconFactory.ClearIconBlizzBacking = ClearIconBlizzBacking

local function GetBlizzDebugFilter()
    return _G.QUI_CDM_BLIZZ_DEBUG or _G.QUI_CDM_ICON_DEBUG
end

local function DebugValueMatches(filter, value)
    if not value then return false end
    local needle = tostring(filter):lower()
    if needle == "" then return false end
    return tostring(value):lower():find(needle, 1, true) ~= nil
end

local function ShouldDebugBlizzEntry(entry, lookupIDs)
    local filter = GetBlizzDebugFilter()
    if not filter then return false end
    if filter == true then return true end
    if DebugValueMatches(filter, entry and entry.name) then return true end
    if DebugValueMatches(filter, entry and entry.id) then return true end
    if DebugValueMatches(filter, entry and entry.spellID) then return true end
    if DebugValueMatches(filter, entry and entry.overrideSpellID) then return true end
    if type(lookupIDs) == "table" then
        for _, id in ipairs(lookupIDs) do
            if DebugValueMatches(filter, id) then return true end
        end
    end
    return false
end

local function FormatIDList(ids)
    if type(ids) ~= "table" or #ids == 0 then return "nil" end
    local out = {}
    for i, id in ipairs(ids) do
        out[i] = tostring(id)
    end
    return table.concat(out, ",")
end

local function FormatMirrorState(state)
    if not state then return "nil" end
    return "cdID=" .. tostring(state.cooldownID)
        .. " cat=" .. tostring(state.viewerCategory)
        .. " active=" .. tostring(state.isActive == true)
        .. " spell=" .. tostring(state.spellID)
        .. " ov=" .. tostring(state.overrideSpellID)
        .. " tooltip=" .. tostring(state.overrideTooltipSpellID)
        .. " links=" .. FormatIDList(state.linkedSpellIDs)
end

local function DebugBlizzEntry(enabled, entry, label, ...)
    if not enabled then return end
    print("|cff34D399[CDM-BlizzBind]|r",
        tostring(label),
        entry and (entry.name or "?") or "?",
        "viewer=", entry and tostring(entry.viewerType) or "nil",
        "kind=", entry and tostring(entry.kind) or "nil",
        "entryID=", entry and tostring(entry.id) or "nil",
        "spellID=", entry and tostring(entry.spellID) or "nil",
        "override=", entry and tostring(entry.overrideSpellID) or "nil",
        ...)
end

SLASH_QUI_CDMBLIZZDEBUG1 = "/cdmblizzdebug"
SlashCmdList["QUI_CDMBLIZZDEBUG"] = function(msg)
    local filter = msg and strtrim(msg) or ""
    local lower = filter:lower()
    if filter == "" then
        _G.QUI_CDM_BLIZZ_DEBUG = not _G.QUI_CDM_BLIZZ_DEBUG
        print("|cff34D399[CDM-BlizzBind]|r", _G.QUI_CDM_BLIZZ_DEBUG and "ON (all bindings)" or "OFF")
        return
    end
    if lower == "off" or lower == "0" or lower == "false" then
        _G.QUI_CDM_BLIZZ_DEBUG = nil
        print("|cff34D399[CDM-BlizzBind]|r OFF")
        return
    end
    if lower == "all" then
        _G.QUI_CDM_BLIZZ_DEBUG = true
    else
        _G.QUI_CDM_BLIZZ_DEBUG = filter
    end
    print("|cff34D399[CDM-BlizzBind]|r ON - filter:", tostring(_G.QUI_CDM_BLIZZ_DEBUG))
end

-- Resolve (entry, viewerType) -> cooldownID via the mirror's per-category
-- maps. Returns nil if the entry doesn't map to a Blizzard child.
local function ResolveBlizzCooldownIDForEntry(entry)
    local mirror = ns.CDMBlizzMirror
    if not mirror or not mirror.GetCooldownIDForViewer then return nil end
    if not entry then return nil end
    -- Item / macro / trinket / slot / totem entries don't have a Blizzard
    -- child (those categories live in QUI's custom-bar renderer only).
    local etype = entry.type
    if etype and etype ~= "spell" and etype ~= "aura" then return nil end
    local sid = entry.overrideSpellID or entry.spellID or entry.id
    if type(sid) ~= "number" or sid <= 0 then return nil end
    local viewerCat = entry.viewerType
    local cdID
    local strictAuraBinding = entry.kind == "aura"
        or entry.isAura == true
        or viewerCat == "buff"
        or viewerCat == "trackedBar"

    local function buildLookupIDs()
        local ids, seen = {}, {}
        local function add(id)
            if type(id) ~= "number" or id <= 0 or seen[id] then return end
            seen[id] = true
            ids[#ids + 1] = id
        end
        add(entry.overrideSpellID)
        add(entry.spellID)
        add(entry.id)
        add(sid)
        if not strictAuraBinding and type(entry.linkedSpellIDs) == "table" then
            for _, linkedID in ipairs(entry.linkedSpellIDs) do
                add(linkedID)
            end
        end
        return ids
    end

    local lookupIDs = buildLookupIDs()
    local debugBlizz = ShouldDebugBlizzEntry(entry, lookupIDs)
    DebugBlizzEntry(debugBlizz, entry, "begin",
        "strictAura=", tostring(strictAuraBinding),
        "lookupIDs=", FormatIDList(lookupIDs))

    local function lookupInViewer(cat)
        local ids = lookupIDs
        if strictAuraBinding and (cat == "buff" or cat == "trackedBar") then
            if not mirror.GetDirectCooldownIDForViewer then return nil end
            for _, id in ipairs(ids) do
                local found = mirror.GetDirectCooldownIDForViewer(id, cat)
                if found then
                    local state = mirror.GetStateByCooldownID and mirror.GetStateByCooldownID(found)
                    DebugBlizzEntry(debugBlizz, entry, "lookup-direct",
                        "cat=", cat, "id=", tostring(id), FormatMirrorState(state))
                    return found
                end
            end
            DebugBlizzEntry(debugBlizz, entry, "lookup-direct-miss",
                "cat=", cat, "ids=", FormatIDList(ids))
            return nil
        end

        for _, id in ipairs(ids) do
            local found = mirror.GetCooldownIDForViewer(id, cat)
            if found then
                local state = mirror.GetStateByCooldownID and mirror.GetStateByCooldownID(found)
                DebugBlizzEntry(debugBlizz, entry, "lookup-loose",
                    "cat=", cat, "id=", tostring(id), FormatMirrorState(state))
                return found
            end
        end
        DebugBlizzEntry(debugBlizz, entry, "lookup-loose-miss",
            "cat=", cat, "ids=", FormatIDList(ids))
        return nil
    end
    if viewerCat == "essential" then
        cdID = lookupInViewer("essential") or lookupInViewer("utility")
    elseif viewerCat == "utility" then
        cdID = lookupInViewer("utility") or lookupInViewer("essential")
    elseif viewerCat == "buff" then
        cdID = lookupInViewer("buff") or lookupInViewer("trackedBar")
    elseif viewerCat == "trackedBar" then
        cdID = lookupInViewer("trackedBar") or lookupInViewer("buff")
    else
        -- Custom bar (or unknown viewer): probe categories. Cooldown-kind
        -- entries probe essential/utility; aura-kind probe buff/trackedBar.
        local kind = entry.kind
        if kind == "aura" then
            cdID = lookupInViewer("buff") or lookupInViewer("trackedBar")
        else
            cdID = lookupInViewer("essential") or lookupInViewer("utility")
        end
    end
    if not cdID then return nil end

    if mirror.GetStateByCooldownID then
        local state = mirror.GetStateByCooldownID(cdID)
        local actualCat = state and state.viewerCategory
        local expected
        if viewerCat == "essential" or viewerCat == "utility" then
            expected = actualCat == "essential" or actualCat == "utility"
        elseif viewerCat == "buff" or viewerCat == "trackedBar" then
            expected = actualCat == "buff" or actualCat == "trackedBar"
        elseif strictAuraBinding then
            expected = actualCat == "buff" or actualCat == "trackedBar"
        else
            expected = actualCat == "essential" or actualCat == "utility"
        end
        if not expected then
            DebugBlizzEntry(debugBlizz, entry, "reject-category", FormatMirrorState(state))
            return nil
        end
    end

    -- Only bind if a live child currently exists for this cooldownID;
    -- otherwise fall back to native rendering for this acquire (the icon
    -- can rebind on the next refresh once Blizzard creates the child).
    if mirror.HasChildForCooldownID and not mirror.HasChildForCooldownID(cdID) then
        DebugBlizzEntry(debugBlizz, entry, "reject-no-child", "cdID=", tostring(cdID))
        return nil
    end
    local state = mirror.GetStateByCooldownID and mirror.GetStateByCooldownID(cdID)
    DebugBlizzEntry(debugBlizz, entry, "resolved", FormatMirrorState(state))
    return cdID
end

local function TryBindIconToBlizz(icon, spellEntry)
    local cdID = ResolveBlizzCooldownIDForEntry(spellEntry)
    if not cdID then
        -- Recycled icon may carry a stale Blizzard binding; clear it so
        -- native rendering takes over.
        ClearIconBlizzBacking(icon)
        return false
    end
    -- Same binding as before — no-op
    if icon._isBlizzBacked == cdID then return true end
    -- Different binding — clear and rebind
    if icon._isBlizzBacked then ClearIconBlizzBacking(icon) end
    SetIconBlizzBacking(icon, cdID)
    return true
end

CDMIconFactory.TryBindIconToBlizz = TryBindIconToBlizz


-- DRIVER

local function SyncBlizzBackedIconState(icon)
    local entry = icon and icon._spellEntry
    local cooldownID = icon and icon._isBlizzBacked
    if not (entry and cooldownID) then return false end

    local runtimeSid = entry.spellID or entry.overrideSpellID or entry.id
    if runtimeSid and not IsAuraEntry(entry) and C_Spell.GetOverrideSpell then
        local ovId = QueryOverrideSpell(runtimeSid)
        if ovId then runtimeSid = ovId end
    end
    icon._runtimeSpellID = runtimeSid
    local debugBlizz = ShouldDebugBlizzEntry(entry, {
        runtimeSid,
        entry.spellID,
        entry.overrideSpellID,
        entry.id,
    })

    local mirror = ns.CDMBlizzMirror
    local m = mirror and mirror.GetStateByCooldownID and mirror.GetStateByCooldownID(cooldownID)
    if not m then
        DebugBlizzEntry(debugBlizz, entry, "state-sync-missing", "cdID=", tostring(cooldownID))
        return false
    end

    local isAuraBacked = IsAuraEntry(entry)
        or m.viewerCategory == "buff"
        or m.viewerCategory == "trackedBar"
    if not isAuraBacked then
        DebugBlizzEntry(debugBlizz, entry, "state-sync-skip-cooldown", FormatMirrorState(m))
        return false
    end

    local r
    if ResolveAuraStateForIcon and runtimeSid then
        r = ResolveAuraStateForIcon(icon, entry, runtimeSid)
    end

    -- Mirror is authoritative for Blizz-backed icons. `m` is the mirror
    -- state for the EXACT cdID this icon is bound to (icon._isBlizzBacked).
    -- The resolver's `r.isActive` can come from a different cdID's aura
    -- (spellID→cdID maps have collisions: e.g. VP and Dread Plague both
    -- carry info.spellID=77575, so Outbreak's spellID resolves to whichever
    -- cdID was written last in the per-category map). Trusting `r` for
    -- this icon's display would let an unrelated aura's state — including
    -- its durObj — leak onto this icon. Use the mirror only.
    local mirrorActive = m.isActive == true
    local auraUnit = (m.selfAura == false) and "target" or "player"

    -- Taint diagnostic: log the m.* fields we're about to compare against
    -- so we can see whether they're secret in the user's environment.
    -- m.selfAura should be a clean bool/nil after CleanBool; if it shows
    -- as <SECRET> here, the sanitization missed it (probably need a
    -- broader strip or the C_CurveUtil decode is failing).
    local mirrorMod = ns.CDMBlizzMirror
    if mirrorMod and mirrorMod.TaintLog then
        mirrorMod.TaintLog("Sync.in",
            "cdID", cooldownID,
            "runtimeSid", runtimeSid,
            "m.isActive", m.isActive,
            "m.selfAura", m.selfAura,
            "m.hasAura", m.hasAura,
            "m.spellID", m.spellID,
            "m.overrideTooltipSpellID", m.overrideTooltipSpellID,
            "m.durObj", m.durObj,
            "m.viewerCategory", m.viewerCategory,
            "auraUnit", auraUnit,
            "mirrorActive", mirrorActive)
    end

    -- Two-stage durObj resolution.
    --
    -- Stage 1: trust m.durObj. The mirror's durObj came either from
    -- Blizzard's SetCooldownFromDurationObject hook (so it matches what's
    -- driving the reparented child Cooldown swipe) or from
    -- VerifyStateFreshness (C_UnitAuras.GetAuraDuration on the stamped
    -- instID — same value Blizzard's mixin would resolve to).
    --
    -- Stage 2: spellID-based fallback. Some Blizzard CDM entries have
    -- bugs where the child's Cooldown frame never receives a durObj push
    -- (Reaping is a known case — the buff is on the unit but the swipe
    -- stays empty). When stage 1 yields nothing, probe the catalog spell
    -- IDs through C_UnitAuras.GetUnitAuraBySpellID. Finding a non-nil
    -- aura means it IS on the unit → icon is active even if GetAuraDuration
    -- subsequently returns nil (durationless / permanent auras like
    -- stances and forms). When we DO get a durObj from the fallback we
    -- push it onto icon.Cooldown ourselves since Blizzard's mixin isn't.
    -- If both stages report no aura at all, the icon is inactive — no
    -- further fallback.
    local durObj = m.durObj
    local durObjSource = durObj and "mirror" or nil
    local fallbackFoundAura = false   -- aura is on unit per GetUnitAuraBySpellID
    local fallbackInstID

    if not mirrorActive
        and not durObj
        and C_UnitAuras
        and C_UnitAuras.GetUnitAuraBySpellID then
        local filter = (auraUnit == "target") and "HARMFUL" or "HELPFUL"
        local seen = {}
        -- Probe a candidate spellID through GetUnitAuraBySpellID.
        -- Return-true means "stop probing further candidates"; only the
        -- first hit matters because we just need to know whether the
        -- aura is on the unit and which instID to ask GetAuraDuration
        -- about. A non-nil aura means the icon IS active (durationless
        -- auras like stances/forms/permanent buffs return non-nil aura
        -- but nil duration — the icon should still show).
        local function probe(sid)
            if fallbackFoundAura then return true end
            if type(sid) ~= "number" or sid <= 0 or seen[sid] then return end
            seen[sid] = true
            local okA, ad = pcall(C_UnitAuras.GetUnitAuraBySpellID, auraUnit, sid, filter)
            local mirrorMod = ns.CDMBlizzMirror
            if mirrorMod and mirrorMod.TaintLog then
                mirrorMod.TaintLog("Sync.probe",
                    "cdID", cooldownID, "sid", sid,
                    "auraUnit", auraUnit, "filter", filter,
                    "okA", okA, "ad", ad)
            end
            if not okA or not ad then return end
            fallbackFoundAura = true
            local okI, instID = pcall(function() return ad.auraInstanceID end)
            if okI and instID and C_UnitAuras.GetAuraDuration then
                local okD, dur = pcall(C_UnitAuras.GetAuraDuration, auraUnit, instID)
                if mirrorMod and mirrorMod.TaintLog then
                    mirrorMod.TaintLog("Sync.probe.dur",
                        "cdID", cooldownID, "instID", instID,
                        "okD", okD, "dur", dur)
                end
                if okD and dur then
                    durObj = dur
                    durObjSource = "spellID-fallback"
                    fallbackInstID = instID
                end
            end
            return true
        end
        if not probe(m.overrideTooltipSpellID) then
            if not probe(m.overrideSpellID) then
                if not probe(m.spellID) then
                    if type(m.linkedSpellIDs) == "table" then
                        for _, lid in ipairs(m.linkedSpellIDs) do
                            if probe(lid) then break end
                        end
                    end
                    if not fallbackFoundAura then
                        probe(runtimeSid)
                    end
                end
            end
        end
    end

    -- Activeness is "is the aura on the unit", NOT "do we have a swipe
    -- duration". A durationless aura (form, stance, permanent buff) is
    -- active without a durObj — the icon should display, just without
    -- a countdown swipe.
    local active = mirrorActive or fallbackFoundAura or (durObj and true or false)
    local priorActive = icon._auraActive == true
    local priorEpoch = icon._lastBlizzSwipeEpoch
    icon._auraActive = active
    icon._auraUnit = auraUnit
    icon._totemSlot = entry._totemSlot or nil
    icon._isTotemInstance = nil

    if ns.CDMBlizzMirror and ns.CDMBlizzMirror.TaintLog then
        ns.CDMBlizzMirror.TaintLog("Sync.out",
            "cdID", cooldownID,
            "active", active,
            "mirrorActive", mirrorActive,
            "fallbackFoundAura", fallbackFoundAura,
            "durObjSource", durObjSource,
            "durObj", durObj,
            "fallbackInstID", fallbackInstID)
    end

    if active then
        icon._lastAuraDurObj = durObj
        icon._lastAuraSourceID = (durObjSource or "mirror")
            .. ":" .. tostring(cooldownID)
            .. ":" .. tostring(m.mirrorEpoch or 0)
        icon._activeAuraSpellID = m.overrideTooltipSpellID or runtimeSid
        -- Aura type for pandemic glow gating. The mirror path doesn't
        -- carry auraData; use auraUnit as a proxy — same convention as
        -- the spellID-fallback's HARMFUL/HELPFUL filter selection above
        -- (target → harmful, player/non-target → helpful).
        icon._auraIsHarmful = (auraUnit == "target") and true or false
    else
        icon._lastAuraDurObj = nil
        icon._lastAuraSourceID = nil
        icon._activeAuraSpellID = nil
        icon._auraIsHarmful = nil
    end

    -- The reparented child Cooldown subframe is owned by Blizzard's
    -- CooldownViewer mixin when it's actually pushing — for "Stage 1"
    -- mirror durObjs we must NOT touch icon.Cooldown (writes would race
    -- the mixin and cause cross-aura duration mix-ups).
    --
    -- For Stage 2 fallback, Blizzard's mixin isn't pushing, so the
    -- reparented Cooldown frame is empty. Forward our recovered durObj
    -- via SetCooldownFromDurationObject so the swipe renders. Per the
    -- 12.0.5 restriction, only SetCooldownFromDurationObject (NOT
    -- SetCooldown / SetCooldownFromExpirationTime / etc.) accepts secret
    -- values from tainted code, which durObj may be in combat.
    -- fallbackUsesNativeOverlay only when we have a durObj to push.
    -- A durationless active aura (fallbackFoundAura=true, durObj=nil) is
    -- still active but renders without a swipe — never push, never clear
    -- (Blizzard's mixin will manage icon.Cooldown's empty state).
    local fallbackUsesNativeOverlay = durObjSource == "spellID-fallback"
    local fallbackChanged = SetBlizzAuraFallbackActive(icon, fallbackUsesNativeOverlay)
    local nativeAuraApplied = false
    if fallbackUsesNativeOverlay and icon.Cooldown
        and icon.Cooldown.SetCooldownFromDurationObject then
        local okPush = pcall(icon.Cooldown.SetCooldownFromDurationObject,
            icon.Cooldown, durObj)
        nativeAuraApplied = okPush
    elseif fallbackChanged then
        -- Transitioned out of QUI-driven swipe (fallback active → inactive).
        -- Clear our previously-pushed durObj so it doesn't persist when
        -- the aura's gone or when Stage 1 / Blizzard's mixin takes over.
        if icon.Cooldown and icon.Cooldown.Clear then
            pcall(icon.Cooldown.Clear, icon.Cooldown)
        end
        if CDMIcons and CDMIcons.ClearIconStackText then
            CDMIcons.ClearIconStackText(icon)
        end
    end

    local epoch = m.mirrorEpoch or 0
    icon._lastBlizzSwipeEpoch = epoch
    if (priorActive ~= active or fallbackChanged)
       and entry.viewerType == "buff"
       and CDMIcons
       and CDMIcons.RequestBuffIconLayoutRefresh then
        CDMIcons.RequestBuffIconLayoutRefresh()
    end
    if priorActive ~= active or priorEpoch ~= epoch or fallbackChanged or nativeAuraApplied then
        DebugBlizzEntry(debugBlizz, entry, "state-sync",
            FormatMirrorState(m),
            "runtimeSid=", tostring(runtimeSid),
            "durObjSource=", tostring(durObjSource),
            "fallbackInstID=", tostring(fallbackInstID),
            "source=", tostring(icon._lastAuraSourceID),
            "nativeFallback=", tostring(fallbackUsesNativeOverlay),
            "nativeApplied=", tostring(nativeAuraApplied))
    end
    return priorActive ~= active or priorEpoch ~= epoch or fallbackChanged or nativeAuraApplied
end

local function UpdateIconCooldown(icon)
    if not icon or not icon._spellEntry then return end
    -- Blizzard-backed icons render via the reparented viewer child; the
    -- viewer's mixin owns swipe/stacks/charges via secret-safe C-side sinks.
    -- Keep QUI's host-side state in sync so visibility/layout code does not
    -- hide the host while the reparented Blizzard child is rendering.
    if icon._isBlizzBacked then
        local refreshSwipe = SyncBlizzBackedIconState(icon)
        if refreshSwipe then
            local swipe = ns._OwnedSwipe
            if swipe and swipe.ApplyToIcon then
                pcall(swipe.ApplyToIcon, icon)
            end
        end
        return
    end
    local entry = icon._spellEntry

    -- Runtime override: resolve from the BASE spell each tick so dynamic
    -- transforms (Glacial Spike ↔ Frostbolt, Mind Blast → Void Blast)
    -- are always current.  Shared across all paths in this function.
    local _runtimeSid = entry.spellID or entry.overrideSpellID or entry.id
    if _runtimeSid and not IsAuraEntry(entry) and C_Spell.GetOverrideSpell then
        local ovId = QueryOverrideSpell(_runtimeSid)
        if ovId then _runtimeSid = ovId end
    end
    -- Stash live override on icon so tooltip/display can pass it
    -- directly to C-side functions (handles secret values natively).
    icon._runtimeSpellID = _runtimeSid

        -- Aura-driven update: delegates to shared CDMSpellData:ResolveAuraState().
        -- Icons apply result to swipe/stacks display on CooldownFrame.
        do
            if IsAuraEntry(entry) then
                local auraSpellID = _runtimeSid
                if not auraSpellID then
                    return
                end

                local r = ResolveAuraStateForIcon(icon, entry, auraSpellID)
                if not r then
                    return
                end
                    local isTotemSlot = IsTotemSlotEntry(entry)
                    icon._totemSlot = entry._totemSlot or nil

                    if r.isActive then
                        ApplyAuraStateToIcon(icon, entry, auraSpellID, r)

                        -- Stacks: forward r.stacks directly to C-side where
                        -- possible. Blizzard aura APIs can return secret or
                        -- otherwise non-finite values in combat, so keep stack
                        -- formatting behind pcall and collapse invalid counts
                        -- to empty text.
                        if r.isTotemInstance then
                            CDMIcons.ClearIconStackText(icon)
                        else
                            CDMIcons.ApplyAuraStackText(icon, r.stacks, entry.hasCharges, InCombatLockdown(), r.stackSource)
                        end

                        -- Keep texture showing the active aura buff.
                        -- Totem instances use slot payloads from GetTotemInfo:
                        -- active state comes from GetTotemDuration(slot),
                        -- display icon comes from the same slot.
                        if icon.Icon then
                            local mirrored = false
                            if r.isTotemInstance then
                                if r.totemIcon then
                                    icon._totemIconCache = r.totemIcon
                                end
                                local totemTex = r.totemIcon or icon._totemIconCache
                                if totemTex then
                                    icon._desiredTexture = nil
                                    pcall(icon.Icon.SetTexture, icon.Icon, totemTex)
                                    icon._lastTexture = totemTex
                                    mirrored = true
                                end
                            end
                            -- Drive icon from r.auraData.icon (live aura icon
                            -- for buff-cycle spells like Roll the Bones), then
                            -- fall back to the base aura spell texture.
                            if not mirrored and not r.isTotemInstance then
                                local texID
                                if r.auraData then
                                    local okI, aIcon = pcall(function() return r.auraData.icon end)
                                    if okI and aIcon and aIcon ~= 0 then texID = aIcon end
                                end
                                if not texID then
                                    texID = GetSpellTexture(r.resolvedAuraSpellID or auraSpellID)
                                end
                                if texID and texID ~= icon._lastTexture then
                                    icon.Icon:SetTexture(texID)
                                    icon._lastTexture = texID
                                end
                            end
                        end

                        ApplyResolvedCooldown(icon)
                        ReapplySwipeStyle(icon.Cooldown, icon)
                        return  -- Aura path complete
                    else
                        local wasAuraActive = icon._auraActive
                        ApplyAuraStateToIcon(icon, entry, auraSpellID, r)

                        if icon.Icon then
                            local baseTex = GetEntryTexture(entry) or GetSpellTexture(auraSpellID)
                            icon._desiredTexture = nil
                            if baseTex and baseTex ~= icon._lastTexture then
                                pcall(icon.Icon.SetTexture, icon.Icon, baseTex)
                                icon._lastTexture = baseTex
                            end
                        end

                        CDMIcons.ClearIconStackText(icon)
                        -- Aura→CD transition: re-resolve so the resolver picks
                        -- up the underlying spell CD now that _auraActive is
                        -- cleared. One-shot on transition; no per-tick cost.
                        if wasAuraActive then
                            ApplyResolvedCooldown(icon)
                        end
                        return  -- Aura path complete
                    end
            end
        end

        -- Custom entry: use addon-created CD with our cooldown resolution
        local startTime, duration, durObj, apiIsActive, blizzRealCooldownActive
        if entry.type == "macro" then
            local resolvedID, resolvedType, fallbackTex = ResolveMacro(entry)
            if resolvedID then
                if resolvedType == "item" then
                    startTime, duration, durObj = GetItemCooldown(resolvedID)
                else
                    startTime, duration, durObj, apiIsActive, blizzRealCooldownActive = GetBestSpellCooldown(resolvedID)
                end
            end
            -- Update icon texture from already-resolved macro result
            -- (eliminates a redundant second ResolveMacro call via GetEntryTexture)
            local newTex
            if resolvedID then
                if resolvedType == "item" then
                    local _, _, _, _, tex = C_Item.GetItemInfoInstant(resolvedID)
                    newTex = tex
                else
                    newTex = GetSpellTexture(resolvedID)
                end
            else
                newTex = fallbackTex
            end
            if newTex and icon.Icon and newTex ~= icon._lastTexture then
                icon.Icon:SetTexture(newTex)
                icon._lastTexture = newTex
                UpdateIconProfessionQuality(icon)
            end
        elseif entry.type == "trinket" or entry.type == "slot" then
            -- Trinket/slot entries store equipment slot (13/14), resolve to item ID
            local slotID = entry.id
            local itemID = GetInventoryItemID("player", slotID)
            if itemID then
                startTime, duration, durObj = GetSlotCooldown(slotID)
                -- Update texture in case trinket was swapped
                if icon.Icon then
                    local ok, tex = pcall(C_Item.GetItemIconByID, itemID)
                    if ok and tex and tex ~= icon._lastTexture then
                        icon.Icon:SetTexture(tex)
                        icon._lastTexture = tex
                        UpdateIconProfessionQuality(icon)
                    end
                end
            end
            -- Hide stack text for trinkets
            CDMIcons.HideIconStackText(icon, "slot-clear")
        elseif entry.type == "item" then
            startTime, duration, durObj = GetItemCooldown(entry.id)
            -- Show item count/charges as stack text using legacy custom tracker semantics.
            if C_Item and C_Item.GetItemCount then
                local containerDB = CDMIcons.GetTrackerSettings(entry.viewerType)
                local includeUses = containerDB and containerDB.showItemCharges == true
                local ok, count = pcall(C_Item.GetItemCount, entry.id, false, includeUses, true)
                if ok and count then
                    local stackColor = icon._rowConfig and icon._rowConfig.stackTextColor or {1, 1, 1, 1}
                    do
                        local numericCount = count or 0
                        if numericCount > 1 then
                            if icon.StackText.SetTextColor then
                                icon.StackText:SetTextColor(stackColor[1], stackColor[2], stackColor[3], stackColor[4] or 1)
                            end
                            CDMIcons.ShowIconStackText(icon, tostring(numericCount), containerDB, "item-count")
                        elseif numericCount == 1 then
                            CDMIcons.HideIconStackText(icon, "item-count-one")
                        else
                            if icon.StackText.SetTextColor then
                                icon.StackText:SetTextColor((stackColor[1] or 1) * 0.5, (stackColor[2] or 1) * 0.5, (stackColor[3] or 1) * 0.5, stackColor[4] or 1)
                            end
                            CDMIcons.ShowIconStackText(icon, "0", containerDB, "item-count-zero")
                        end
                    end
                else
                    CDMIcons.ShowIconStackText(icon, "0", containerDB, "item-count-fallback")
                end
            end
        else
            -- Unified non-item path: aura detection via the resolver, then
            -- cooldown/recharge resolution via C_Spell-backed APIs. No
            -- Blizzard CDM viewer child reads.
            local _chargedAuraActive = false
            local _chargedTotemTexture = nil
            local useBuffSwipe = CDMIcons.ShouldUseBuffSwipeForIcon(icon, entry)
            if useBuffSwipe then
                local _cBaseID = _runtimeSid

                local r = ResolveAuraStateForIcon(icon, entry, _cBaseID)
                if r and r.isActive then
                    ApplyAuraStateToIcon(icon, entry, _cBaseID, r)
                    if IsTotemSlotEntry(entry) then
                        icon._isTotemInstance = true
                        if r.totemIcon then
                            icon._totemIconCache = r.totemIcon
                        end
                        _chargedTotemTexture = r.totemIcon or icon._totemIconCache
                        icon.StackText:SetText("")
                        icon.StackText:Hide()
                    else
                        icon._isTotemInstance = nil
                    end
                    -- Only block the normal cooldown path when we have
                    -- a DurationObject to display. If ResolveAuraState
                    -- reports active but has no durObj (spurious match),
                    -- fall through to GetBestSpellCooldown so the
                    -- recharge swipe still renders.
                    if icon.Cooldown and r.durObj then
                        _chargedAuraActive = true
                        -- Resolver owns icon.Cooldown writes; only restyle here.
                        ReapplySwipeStyle(icon.Cooldown, icon)
                    end
                    -- Non-charged aura entries (e.g. Mana Tea added via the
                    -- cooldown CDM picker / a custom container) write stacks
                    -- here from r.stacks. ApplyAuraStackText has explicit
                    -- IsSecretValue handling and routes through the same
                    -- C-side pcall pattern as the kind="aura" branch.
                    -- Charged entries skip this so the cooldownChargesCount
                    -- forwarding path can drive the StackText for them.
                    if not entry.hasCharges and not IsTotemSlotEntry(entry) then
                        CDMIcons.ApplyAuraStackText(icon, r.stacks, false, InCombatLockdown(), r.stackSource)
                    end
                elseif r then
                    local wasAuraActive = icon._auraActive
                    ApplyAuraStateToIcon(icon, entry, _cBaseID, r)
                    if wasAuraActive then
                        if icon.Cooldown then ReapplySwipeStyle(icon.Cooldown, icon) end
                        -- Aura→CD transition: re-resolve so the underlying
                        -- spell CD takes hold via the resolver.
                        ApplyResolvedCooldown(icon)
                    end
                end
            elseif icon._auraActive then
                -- Buff/debuff swipe was just disabled: clear aura state
                -- so the resolver resumes producing cooldown data.
                CDMIcons.ClearAuraStateForIcon(icon, entry)
                if icon.Cooldown then ReapplySwipeStyle(icon.Cooldown, icon) end
                -- Aura→CD transition: re-resolve so the underlying spell
                -- CD takes hold via the resolver.
                ApplyResolvedCooldown(icon)
            end

            if not _chargedAuraActive then
                -- Custom entry / charged recharge: full API resolution.
                startTime, duration, durObj, apiIsActive, blizzRealCooldownActive = GetBestSpellCooldown(_runtimeSid)
                if not durObj
                   and not (CDMIcons.IsSafeNumeric(startTime) and CDMIcons.IsSafeNumeric(duration) and duration > GCD_MAX_DURATION)
                then
                    local aliasID = CDMIcons.GetRecentCastAliasForEntry(entry)
                    if aliasID and aliasID ~= _runtimeSid then
                        local aStart, aDuration, aDurObj, aActive, aRealActive = GetBestSpellCooldown(aliasID)
                        if aDurObj or (CDMIcons.IsSafeNumeric(aStart) and CDMIcons.IsSafeNumeric(aDuration) and aDuration > GCD_MAX_DURATION) then
                            if CDMIcons.DebugIconEvent then
                                CDMIcons.DebugIconEvent(icon, "alias",
                                    "from=", tostring(_runtimeSid),
                                    "to=", tostring(aliasID),
                                    "aStart=", tostring(aStart),
                                    "aDuration=", tostring(aDuration),
                                    "aDurObj=", aDurObj and "yes" or "no",
                                    "aActive=", tostring(aActive))
                            end
                            _runtimeSid = aliasID
                            icon._runtimeSpellID = aliasID
                            startTime, duration, durObj, apiIsActive, blizzRealCooldownActive = aStart, aDuration, aDurObj, aActive, aRealActive
                        end
                    end
                end
            else
                -- Aura active: resolver owns _hasCooldownActive via
                -- C_Spell.GetSpellCooldown(sid).isActive in
                -- ApplyResolvedCooldown.
            end

            -- isOnGCD was captured synchronously in SPELL_UPDATE_COOLDOWN;
            -- this query is for active/duration data only.
            local _tickCi = QueryCooldown(_runtimeSid)
            if CDMIcons.DebugIconEvent then
                CDMIcons.DebugIconEvent(icon, "resolve",
                    "sid=", tostring(_runtimeSid),
                    "start=", tostring(startTime),
                    "duration=", tostring(duration),
                    "durObj=", durObj and "yes" or "no",
                    "apiActive=", tostring(apiIsActive),
                    "isOnGCD=", tostring(icon._isOnGCD),
                    "hasCharges=", tostring(entry.hasCharges),
                    "kind=", tostring(entry.kind),
                    "type=", tostring(entry.type))
            end
            -- Texture: mirror runtime override each tick. Keeps
            -- _desiredTexture set so per-tick texture writes never
            -- regress to a stale value, while updating for talent swaps.
            -- Aura entries leave _desiredTexture nil so the active aura's
            -- icon (set on the active branch above) wins.
            if icon.Icon and _chargedAuraActive and _chargedTotemTexture then
                icon._desiredTexture = nil
                pcall(icon.Icon.SetTexture, icon.Icon, _chargedTotemTexture)
                icon._lastTexture = _chargedTotemTexture
            elseif icon.Icon and not entry.isAura then
                local texID = GetSpellTexture(_runtimeSid)
                if texID then
                    if icon._desiredTexture ~= texID then
                        icon._desiredTexture = texID
                        pcall(icon.Icon.SetTexture, icon.Icon, texID)
                    end
                end
            elseif icon.Icon then
                icon._desiredTexture = nil
            end
        end

        -- _lastStart / _lastDuration: always update from API when readable.
        -- These are used by the desaturation check and visibility logic below.
        local hasSafeStart = CDMIcons.IsSafeNumeric(startTime)
        local hasSafeDuration = CDMIcons.IsSafeNumeric(duration)
        if hasSafeDuration then
            icon._lastDuration = duration
        end
        if hasSafeStart then
            icon._lastStart = startTime
        end
        if hasSafeDuration and duration == 0 then
            icon._lastStart = 0
            icon._lastDuration = 0
        end
        -- When API returns no data (fully charged / off CD), clear stale
        -- values so desaturation doesn't persist from a previous recharge.
        if not startTime and not duration then
            icon._lastStart = 0
            icon._lastDuration = 0
        end

        if icon.Cooldown then
            -- Decide what to draw from the actual rendered state first:
            -- aura swipe wins, then real cooldown/recharge, then GCD.
            -- isOnGCD is only used when this batch came from
            -- SPELL_UPDATE_COOLDOWN; outside that event it can be stale.
            local auraSwipeActive = icon._auraActive or entry.viewerType == "buff"
            local realCooldownActive = HasRealCooldownState(icon, entry, duration, apiIsActive, blizzRealCooldownActive, durObj, _runtimeSid)
            -- GCD is simple: isOnGCD says the current active display is the
            -- global cooldown. isActive is the non-secret "render cooldown UI"
            -- bit. Aura and real cooldown owners win; the resolver owns the
            -- actual cooldown-frame binding.
            local trustIsOnGCD = CDMIcons._trustIsOnGCDForBatch == true
            local gcdStateTrusted = trustIsOnGCD
                and icon._isOnGCDTrustedAt == CDMIcons._trustedGCDStamp
            local iconIsOnGCD = gcdStateTrusted and icon._isOnGCD == true
            local hasLongDisplayDuration = CDMIcons.IsSafeNumeric(duration) and duration > GCD_MAX_DURATION
            local activeDisplayActive = apiIsActive == true
                and not auraSwipeActive
                and ((gcdStateTrusted and iconIsOnGCD ~= true)
                    or realCooldownActive
                    or durObj ~= nil
                    or hasLongDisplayDuration)
            local activeDurationOwned = auraSwipeActive
                or activeDisplayActive
                or realCooldownActive
                or durObj ~= nil
            local gcdOnlyActive = iconIsOnGCD == true
                and apiIsActive == true
                and not activeDurationOwned
            -- _hasRealCooldownActive is owned by the resolver
            -- (C_Spell.GetSpellCooldown(sid).isActive in ApplyResolvedCooldown).
            if CDMIcons.DebugIconEvent then
                CDMIcons.DebugIconEvent(icon, "classify",
                    "real=", tostring(realCooldownActive),
                    "gcdOnly=", tostring(gcdOnlyActive),
                    "gcdTrusted=", tostring(trustIsOnGCD),
                    "gcdSnapshot=", tostring(gcdStateTrusted),
                    "durationOwned=", tostring(activeDurationOwned),
                    "blizzReal=", tostring(blizzRealCooldownActive),
                    "durObj=", durObj and "yes" or "no",
                    "baseLong=", tostring(CDMIcons.SpellHasBaseCooldownLongerThanGCD(_runtimeSid)))
            end
            -- Per-tick chain does NOT touch cooldown flags or icon.Cooldown.
            -- ApplyResolvedCooldown (event-driven via UNIT_SPELLCAST_SUCCEEDED,
            -- owned UNIT_AURA refresh, SPELL_UPDATE_COOLDOWN, SPELL_UPDATE_USABLE) is the
            -- sole writer of _hasCooldownActive / _hasRealCooldownActive /
            -- _showingRealCooldownSwipe / _showingGCDSwipe and the sole binder
            -- of icon.Cooldown via SetCooldownFromDurationObject.

            -- Reapply swipe styling when GCD or cooldown-active state
            -- transitions so SetDrawSwipe/SetDrawEdge and colors update.
            -- GCD transition: e.g., GCD → cooldown mode re-hides the swipe
            -- when radial darkening is off.
            -- isActive transition: ensures edge/color switches correctly
            -- when a cooldown starts (ready → active) or ends (active → ready)
            -- without waiting for a later resolver event.
            local prevGCD = icon._wasShowingGCDSwipe or false
            local curGCD = icon._showingGCDSwipe or false
            local prevActive = icon._wasApiActive
            local curActive = apiIsActive
            if prevGCD ~= curGCD or prevActive ~= curActive then
                icon._wasShowingGCDSwipe = curGCD
                icon._wasApiActive = curActive
                ReapplySwipeStyle(icon.Cooldown, icon)
            end

            -- Real cooldown state drives desaturation/visibility. Raw
            -- apiIsActive may also mean GCD or resource recovery.
            if apiIsActive ~= nil then
                -- When a real cooldown starts, clear usability tint so the
                -- desaturation gate opens.  Reset _lastVisualState so the
                -- range poll can reapply usability tint after the CD ends.
                local cooldownActiveForState = realCooldownActive and true or false
                if cooldownActiveForState and icon._usabilityTinted then
                    icon.Icon:SetVertexColor(1, 1, 1, 1)
                    icon._usabilityTinted = nil
                    icon._lastVisualState = nil
                end
                -- _hasCooldownActive is owned by the resolver
                -- (C_Spell.GetSpellCooldown(sid).isActive in
                -- ApplyResolvedCooldown).
            end
        end

    do
        local containerDB = CDMIcons.GetTrackerSettings(entry.viewerType)
        if CDMIcons.IsCustomBarContainer(containerDB) then
            CDMIcons.ApplyCustomBarActiveState(icon, entry, containerDB)
        else
            icon._customBarActive = nil
            CDMIcons.StopCustomBarActiveGlow(icon)
        end
    end

    -- Stack/charge text: API-driven on each tick.
    -- Cache chargeInfo for this icon — reused by desaturation check below
    -- (was called 3x per cooldown icon per tick, now 1x)
    local _cachedChargeInfo = nil
    local _cachedChargeOk = false

    -- Populate _cachedChargeInfo unconditionally (needed for desaturation
    -- check below), independent of whether hooks are driving stack text.
    do
        local spellID = _runtimeSid
        if spellID then
            local chargeInfo = QueryCharges(spellID)
            _cachedChargeOk = chargeInfo ~= nil
            _cachedChargeInfo = chargeInfo
        end
    end

    -- Forward charge count from C_Spell directly. The Blizzard CDM hook
    -- path that previously drove stack text was retired alongside the
    -- viewer-child mirror, so all stack text now comes from this API path.
    --
    -- Gate: GetSpellCharges on the base spell returns maxCharges > 1.
    -- maxCharges is non-secret (12.0.5+) and updates dynamically when
    -- the spell gains charges (e.g., Mind Blast base ID reports max=2
    -- when Void Blast is active). Single-charge spells (max=1) excluded.
    local _chargeCountForwarded = false
    if C_Spell.GetSpellCharges then
        local baseSid = entry.spellID or entry.id
        local ci = baseSid and QueryCharges(baseSid)
        local ciMax = ci and ci.maxCharges
        -- When the base spell transforms (e.g., Holy Bulwark → Sacred Weapon),
        -- GetSpellCharges on the base ID may return nil/<=1 even though the
        -- spell is still multi-charge.  Try the override spell ID as fallback.
        if (not ciMax or ciMax <= 1)
            and entry.overrideSpellID and entry.overrideSpellID ~= baseSid then
            local oci = QueryCharges(entry.overrideSpellID)
            local ociMax = oci and oci.maxCharges
            if ociMax and ociMax > 1 then
                ci = oci
                ciMax = ociMax
                ChargeDebug(entry.name, "FWD override fallback: overrideSpellID=", entry.overrideSpellID,
                    "maxCharges=", ociMax, "currentCharges=", oci.currentCharges)
            end
        end
        if ciMax and ciMax > 1 then
            -- Source the live charge count directly from C_Spell so we don't
            -- depend on any Blizzard CDM viewer child carrying the field.
            -- ci.currentCharges is the same value Blizzard's own viewer reads
            -- when populating cooldownChargesCount for charge spells.
            local ccc = ci.currentCharges
            local _dbgCccSource = ccc ~= nil and "api" or nil
            ChargeDebug(entry.name, "FWD path: baseSid=", baseSid,
                "maxCharges=", ciMax, "currentCharges=", ci.currentCharges,
                "ccc=", ccc, "cccSource=", _dbgCccSource or "nil",
                "hasCharges=", entry.hasCharges,
                "overrideSpellID=", entry.overrideSpellID)
            CDMIcons.DebugNativeChargeText(icon, "fwd-before-stacktext")
            if ccc ~= nil then
                CDMIcons.ShowIconStackText(icon, ccc, CDMIcons.GetTrackerSettings(entry.viewerType), "fwd-charge-count")
                _chargeCountForwarded = true
            end
        end
    end

    -- Charged entries where the FWD path couldn't find charges fall through
    -- to the API path below for the owned StackText value.

    if _chargeCountForwarded then
        ChargeDebug(entry.name, "SKIP API path: chargeCountForwarded=", _chargeCountForwarded)
    end
    if not _chargeCountForwarded then
        if entry.type == "item" then
            -- Item stack text was already set above in the cooldown section;
            -- nothing to do here — just prevent the else clause from clearing it.
        elseif entry.type == "spell" then
            -- Custom spell entry: check charges/stacks via API.
            -- Values may be secret in combat — pass directly to C-side functions
            -- (TruncateWhenZero, SetText) without reading in Lua.
            local spellID = _runtimeSid
            local stackVal  -- raw value (may be secret), forwarded to C-side
            local stackSource

            -- Only show charge count when maxCharges is readable and > 1
            -- (multi-charge spell).
            -- Resource overlay counts (Soul Fragments etc.) use
            -- GetSpellDisplayCount in the non-charge branch below.
            local cachedMaxCharges = _cachedChargeInfo and _cachedChargeInfo.maxCharges
            local isMultiCharge = cachedMaxCharges and cachedMaxCharges > 1

            if isMultiCharge then
                -- GetSpellDisplayCount is the canonical charge display API.
                if spellID and C_Spell.GetSpellDisplayCount then
                    stackVal = QueryDisplayCount(spellID)
                    if CDMIcons.ValueIsPresent(stackVal) then
                        stackSource = "spell-display-count"
                    end
                end
                ChargeDebug(entry.name, "API path: spellID=", spellID,
                    "maxCharges=", _cachedChargeInfo.maxCharges,
                    "currentCharges=", _cachedChargeInfo.currentCharges,
                    "displayCount=", stackVal, "isMultiCharge=", isMultiCharge)
            else
                -- Prefer stacking aura applications before generic display
                -- counts so buff-backed spell entries show their real stacks.
                stackVal, stackSource = CDMIcons.GetAuraApplicationsForSpell(spellID, entry, icon)

                -- Non-charge resource overlays (Soul Fragments, etc.) fall
                -- back to SpellDisplayCount. This mirrors action-button count
                -- text without trusting the CooldownViewer child's native
                -- cooldownChargesCount, which can carry unrelated counts for
                -- ordinary cooldown spells.
                local displayCount
                if CDMIcons.ValueIsMissing(stackVal) and spellID and C_Spell.GetSpellDisplayCount then
                    displayCount = QueryDisplayCount(spellID)
                    stackVal = displayCount
                    if CDMIcons.ValueIsPresent(displayCount) then
                        stackSource = "spell-display-count"
                        local displayOk, displayText = pcall(C_StringUtil.TruncateWhenZero, displayCount)
                        if displayOk and not HookTextHasDisplay(displayText) then
                            stackVal = nil
                            stackSource = nil
                        end
                    end
                end
                ChargeDebug(entry.name, "API non-charge stack: spellID=", spellID,
                    "displayCount=", tostring(displayCount),
                    "stackSource=", stackSource or "nil",
                    "stackVal=", tostring(stackVal))
            end


            -- Forward to C-side for display. Multi-charge spells always
            -- show their count (including "0" when depleted). Non-charge
            -- stacks use TruncateWhenZero to hide zero (resource overlays,
            -- non-charge spells that return 0 from GetSpellDisplayCount).
            if CDMIcons.ValueIsPresent(stackVal) then
                if isMultiCharge then
                    -- Always show charge count — "0" is meaningful
                    CDMIcons.ShowIconStackText(icon, stackVal, CDMIcons.GetTrackerSettings(entry.viewerType), "api-charge-count")
                else
                    local truncOk, truncText = pcall(C_StringUtil.TruncateWhenZero, stackVal)
                    local displayText = truncOk and truncText or stackVal
                    local hasText = HookTextHasDisplay(displayText)
                    if hasText then
                        CDMIcons.ShowIconStackText(icon, displayText, CDMIcons.GetTrackerSettings(entry.viewerType), stackSource or "api-aura-stack")
                    else
                        CDMIcons.HideIconStackText(icon, "api-aura-stack-empty")
                    end
                end
            elseif not InCombatLockdown() and not (entry and entry.hasCharges) then
                -- Don't hide charged-ability stack text on a transient API
                -- nil. UNIT_AURA on the target (from other players' buffs/
                -- debuffs) and PLAYER_SOFT_ENEMY_CHANGED both schedule full
                -- CDM updates; during those Blizzard's charge data and
                -- QueryDisplayCount can momentarily return nil even
                -- when the spell still has charges. Hiding here and
                -- re-showing on the next tick produced the visible "stacks
                -- flicker show/hide" symptom on every target aura change.
                -- The FWD path or the next tick's API read will restore the
                -- correct value; preserve the previous text in the gap.
                CDMIcons.HideIconStackText(icon, "api-stack-nil")
            end
        else
            -- Harvested entries and other types: API-read aura applications
            -- per-icon so each container renders the count independently.
            local stackVal = CDMIcons.GetAuraApplicationsForSpell(_runtimeSid, entry, icon)
            if CDMIcons.ValueIsPresent(stackVal) then
                local truncOk, truncText = pcall(C_StringUtil.TruncateWhenZero, stackVal)
                local displayText = truncOk and truncText or stackVal
                local hasText = HookTextHasDisplay(displayText)
                if hasText then
                    CDMIcons.ShowIconStackText(icon, displayText, CDMIcons.GetTrackerSettings(entry.viewerType), "harvested-aura-stack")
                else
                    CDMIcons.HideIconStackText(icon, "harvested-aura-stack-empty")
                end
            elseif not InCombatLockdown() then
                CDMIcons.HideIconStackText(icon, "harvested-stack-nil")
            end
        end
    end

    -- Desaturation for cooldown entries based on resolver-owned cooldown state.
    local desatSettings = CDMIcons._hoistedNcdm and (CDMIcons._hoistedNcdm[entry.viewerType]
        or (CDMIcons._hoistedNcdm.containers and CDMIcons._hoistedNcdm.containers[entry.viewerType]))
    CDMIcons.ApplyCooldownDesaturation(icon, entry, desatSettings or CDMIcons.ResolveTrackerSettingsNow(entry.viewerType), icon._resolvedCooldownMode)

    -- Self-heal usability tint: icon rebuilds (BuildIcons via ScanAll)
    -- wipe _usabilityTinted.  Restore from _lastVisualState which
    -- persists on the recycled table when the same spell is re-acquired.
    if icon._lastVisualState == "unusable"
       and not icon._usabilityTinted
       and not CDMIcons.CooldownHasVisualPriority(icon, entry, CDMIcons.GetTrackerSettings(entry.viewerType), CDMIcons._batchTime) then
        icon.Icon:SetVertexColor(0.4, 0.4, 0.4, 1)
        icon._usabilityTinted = true
    end
end

CDMIconFactory.UpdateIconCooldown = UpdateIconCooldown

---------------------------------------------------------------------------
-- DEFERRED IMPORT BINDING
-- Called from the tail of cdm_icons.lua once ns.CDMIcons is fully populated
-- (including all `CDMIcons.X = X` exposure lines). Reassigns the file-level
-- upvalues; every function defined in this file closes over those upvalues,
-- so they all see the late-bound values.
---------------------------------------------------------------------------
function CDMIconFactory._FinalizeImports(icons)
    CDMIcons                    = icons
    GetBestSpellCooldown        = icons.GetBestSpellCooldown
    GetItemCooldown             = icons.GetItemCooldown
    GetSlotCooldown             = icons.GetSlotCooldown
    IsTotemSlotEntry            = icons.IsTotemSlotEntry
    ApplyAuraStateToIcon        = icons.ApplyAuraStateToIcon
    ApplyResolvedCooldown       = icons.ApplyResolvedCooldown
    ReapplySwipeStyle           = icons.ReapplySwipeStyle
    UpdateIconProfessionQuality = icons.UpdateIconProfessionQuality
    ChargeDebug                 = icons.ChargeDebug
    HookTextHasDisplay          = icons.HookTextHasDisplay
end
