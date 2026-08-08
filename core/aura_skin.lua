local ADDON_NAME, ns = ...
ns.Addon = ns.Addon or {}
local AuraTheme = ns.Addon.AuraTheme
local AuraSkin = {}
ns.Addon.AuraSkin = AuraSkin
ns.AuraSkin = AuraSkin
_G.QUI = _G.QUI or {}
_G.QUI.AuraSkin = AuraSkin

local function AurasAreSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

local _restrictedRestyle = {}
local _restrictedPollArmed = false
local function ScheduleRestrictedRestyle(container)
    _restrictedRestyle[container] = true
    if _restrictedPollArmed then return end
    local After = C_Timer and C_Timer.After
    if not After then return end
    _restrictedPollArmed = true
    local function tick()
        if AurasAreSecret() then
            After(0.5, tick)
            return
        end
        _restrictedPollArmed = false
        local run = _restrictedRestyle
        _restrictedRestyle = {}
        for c in pairs(run) do
            if c._quiProfile then
                AuraSkin.Restyle(c, c._quiProfile)
            end
        end
    end
    After(0.5, tick)
end

local AuraElements
local function ResolveAuraElements()
    AuraElements = AuraElements or ns.AuraElements
    return AuraElements
end

local function ResolveLayout(profile)
    profile = profile or {}
    local m = AuraTheme.Metrics(profile)
    return {
        maxIcons  = m.maxIcons,
        iconSize  = m.iconSize,
        spacing   = m.spacing,
        grow      = m.grow,
        maxPerRow = profile.maxPerRow or 0,
        offsetX   = profile.offsetX or 0,
        offsetY   = profile.offsetY or 0,
        anchor    = profile.anchor or "TOPLEFT",
        attachPoint = profile.attachPoint or profile.anchor or "TOPLEFT",
        wrap = profile.wrap,
    }
end

local function buildButtonArt(button)
    if button._quiWired then return end
    button._quiWired = true

    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(button)
    button._quiBorder = border

    local dispel = button:CreateTexture(nil, "BORDER")
    dispel:SetAllPoints(button)
    dispel:SetColorTexture(1, 1, 1, 1)
    if dispel.DisablePixelSnap then dispel:DisablePixelSnap() end
    button._quiDispel = dispel

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.Icon = icon
    if button.SetIcon then button:SetIcon(icon) end

    local backdrop = button:CreateTexture(nil, "BACKGROUND", nil, -8)
    backdrop:SetAllPoints(button)
    backdrop:SetColorTexture(0, 0, 0, 1)
    if backdrop.Hide then backdrop:Hide() end
    button._quiBackdrop = backdrop

    local gloss = button:CreateTexture(nil, "OVERLAY")
    if ns.IconSkin and gloss.SetTexture then gloss:SetTexture(ns.IconSkin.GlossTexture) end
    if gloss.SetBlendMode then gloss:SetBlendMode("ADD") end
    gloss:SetAllPoints(button)
    if gloss.Hide then gloss:Hide() end
    button._quiGloss = gloss

    local symbol = button:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
    symbol:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    button._quiSymbol = symbol
    if button.SetDispelTypeText then
        button:SetDispelTypeText(symbol, {
            showWhenHarmful = true,
            showWhenHelpful = false,
        })
    end

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(button)
    cd:SetHideCountdownNumbers(true)
    button._quiCooldown = cd
    if button.SetDurationCooldown then button:SetDurationCooldown(cd) end

    local fill = CreateFrame("StatusBar", nil, button)
    fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetAllPoints(button)
    fill:Hide()
    button._quiDurationBar = fill

    local durText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    durText:SetPoint("CENTER", button, "CENTER", 0, 0)
    button._quiDuration = durText
    if button.SetDurationText then button:SetDurationText(durText, {}) end

    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button._quiCount = count
    if button.SetApplicationCount then button:SetApplicationCount(count, {}) end
end

local function ApplyIconSkinOwnership(button, profile)
    local Bridge = ns.ExternalSkinBridge
    local surfaceKey = profile.externalSkinKey
    local external = profile.externalSkinning == true
        and surfaceKey ~= nil
        and Bridge and Bridge.IsAvailable and Bridge.IsAvailable()

    if external then
        if button._quiBridgedKey and button._quiBridgedKey ~= surfaceKey then
            Bridge.RemoveButton(button._quiBridgedKey, button)
            button._quiBridgedKey = nil
        end
        if button._quiBridgedKey ~= surfaceKey then
            local regions = button._quiRegions or {}
            button._quiRegions = regions
            regions.Icon = button.Icon
            regions.Cooldown = button._quiCooldown
            Bridge.AddButton(surfaceKey, button, regions)
            button._quiBridgedKey = surfaceKey
        end
        button._quiBridged = true
        if button._quiBorder and button._quiBorder.Hide then button._quiBorder:Hide() end
        if button._quiBackdrop and button._quiBackdrop.Hide then button._quiBackdrop:Hide() end
        if button._quiGloss and button._quiGloss.Hide then button._quiGloss:Hide() end
        return
    end

    if button._quiBridgedKey and Bridge then
        Bridge.RemoveButton(button._quiBridgedKey, button)
    end
    button._quiBridgedKey = nil
    button._quiBridged = nil

    if button._quiBorder and button._quiBorder.Show then button._quiBorder:Show() end
    local skinName = profile.iconSkin or "Default"
    if ns.IconSkin and skinName ~= "Default" then
        local regions = button._quiRegions or {}
        button._quiRegions = regions
        regions.Backdrop = button._quiBackdrop
        regions.Gloss = button._quiGloss
        ns.IconSkin.ApplySkin(button, regions, skinName)
    else
        if button._quiBackdrop and button._quiBackdrop.Hide then button._quiBackdrop:Hide() end
        if button._quiGloss and button._quiGloss.Hide then button._quiGloss:Hide() end
    end
end

local pandemicFormatter
local function DurationFormatter()
    if pandemicFormatter ~= nil then return pandemicFormatter or nil end
    if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
        local ok, fmt = pcall(C_StringUtil.CreateNumericRuleFormatter, "%.1f", "%.0f", 3)
        pandemicFormatter = ok and fmt or false
    else
        pandemicFormatter = false
    end
    return pandemicFormatter or nil
end

local function HasCurveSupport()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor
        and Enum and Enum.LuaCurveType
end

local function ResolveBaseColor(color)
    if type(color) == "table" then
        return color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1
    end
    return 1, 1, 1, 1
end

local function PandemicCurve(baseColor, pandemicColor)
    if not HasCurveSupport() then return nil end
    local br, bg, bb, ba = ResolveBaseColor(baseColor)
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, CreateColor(pandemicColor[1] or 1, pandemicColor[2] or 0,
        pandemicColor[3] or 0, pandemicColor[4] or 1))
    curve:AddPoint(0.3, CreateColor(br, bg, bb, ba))
    return curve
end

local function FlatColorCurve(baseColor)
    if not HasCurveSupport() then return nil end
    local br, bg, bb, ba = ResolveBaseColor(baseColor)
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, CreateColor(br, bg, bb, ba))
    return curve
end

local function DurationOptionsBase(profile)
    local durS = (profile and profile.duration) or {}
    local opts = {}
    if durS.decimals == true then
        opts.textFormatter = DurationFormatter()
    end
    return durS, opts
end

local function BindDurationTextColor(opts, curve)
    if curve and Enum and Enum.DurationTextBindingProperty then
        opts.textColor = {
            curve = curve,
            property = Enum.DurationTextBindingProperty.RemainingPercent,
        }
    end
    return opts
end

function AuraSkin.BuildDurationTextOptions(profile)
    local durS, opts = DurationOptionsBase(profile)
    if type(durS.pandemicColor) == "table" then
        BindDurationTextColor(opts, PandemicCurve(durS.color, durS.pandemicColor))
    end
    return opts
end

function AuraSkin.BuildDurationClearCurveOptions(profile)
    local durS, opts = DurationOptionsBase(profile)
    return BindDurationTextColor(opts, FlatColorCurve(durS.color))
end

function AuraSkin.ResolveDurationTextOptions(button, profile)
    local durS = (profile and profile.duration) or {}
    if type(durS.pandemicColor) == "table" then
        local opts = AuraSkin.BuildDurationTextOptions(profile)
        if button then
            button._quiPandemicCurved = (opts.textColor ~= nil) or nil
        end
        return opts
    end
    if button and button._quiPandemicCurved then
        button._quiPandemicCurved = nil
        return AuraSkin.BuildDurationClearCurveOptions(profile)
    end
    return AuraSkin.BuildDurationTextOptions(profile)
end

local Helpers = ns.Helpers
local function styleButton(button, profile)
    local size = profile.iconSize or 22
    if size <= 0 then size = 22 end
    button:SetSize(size, size)

    if button.SetTooltipAnchorPoint then
        if profile.tooltipAnchor then
            if not button._quiTipPrev and button.GetTooltipAnchorPoint then
                button._quiTipPrev = { button:GetTooltipAnchorPoint() }
            end
            local ok = pcall(button.SetTooltipAnchorPoint, button, profile.tooltipAnchor,
                profile.tooltipAnchorX or 0, profile.tooltipAnchorY or 0)
            if ok then button._quiTipAnchored = true end
        elseif button._quiTipAnchored then
            local prev = button._quiTipPrev
            pcall(button.SetTooltipAnchorPoint, button,
                (prev and prev[1]) or "ANCHOR_BOTTOMLEFT",
                (prev and prev[2]) or 0, (prev and prev[3]) or 0)
            button._quiTipAnchored = nil
        end
    end
    if button.SetHideTooltipInCombat then
        button:SetHideTooltipInCombat(profile.tooltipHideInCombat == true)
    end

    ApplyIconSkinOwnership(button, profile)

    local dispel = button._quiDispel
    if dispel and button.ClearDispelTypeTextures and button.AddDispelTypeTexture then
        local borderOpts = {
            style = 3,
            showWhenHarmful = true,
            showWhenHelpful = false,
        }
        if type(profile.dispelColors) == "table" then
            borderOpts.customDispelColorMap = profile.dispelColors
        elseif profile.dispelColorCurve then
            borderOpts.customDispelColorCurve = profile.dispelColorCurve
        end
        if type(profile.dispelAssets) == "table" then
            borderOpts.style = 4
            borderOpts.customDispelAssetMap = profile.dispelAssets
        end
        button:ClearDispelTypeTextures()
        if button._quiBridged or profile.showDispelBorder == false then
            if dispel.Hide then dispel:Hide() end
        else
            if dispel.Show then dispel:Show() end
            button:AddDispelTypeTexture(dispel, borderOpts)
        end
    end

    local border = button._quiBorder
    if border then
        local bc = profile.borderColor
        local r, g, b, a
        if type(bc) == "table" then
            r, g, b, a = bc[1] or 1, bc[2] or 1, bc[3] or 1, bc[4]
        else
            r, g, b, a = AuraTheme.BorderColor()
        end
        border:SetColorTexture(r, g, b, a or 1)
        if border.DisablePixelSnap then border:DisablePixelSnap() end
    end

    local fontPath = (Helpers and Helpers.GetGeneralFont and Helpers.GetGeneralFont())
    local fontFlags = (Helpers and Helpers.GetGeneralFontOutline and Helpers.GetGeneralFontOutline()) or "OUTLINE"
    local function styleText(fs, cfg, fallbackSize, defAnchor, defX, defY)
        if not fs then return end
        local size = (cfg and cfg.fontSize) or fallbackSize or 11
        if size <= 0 then size = 11 end
        if fontPath then fs:SetFont(fontPath, size, fontFlags) end
        fs:ClearAllPoints()
        fs:SetPoint((cfg and cfg.anchor) or defAnchor, button, (cfg and cfg.anchor) or defAnchor,
            (cfg and cfg.offsetX) or defX, (cfg and cfg.offsetY) or defY)
        local c = cfg and cfg.color
        if c then fs:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1) end
        fs:SetAlpha(cfg and cfg.show == false and 0 or 1)
    end
    styleText(button._quiDuration, profile.duration, profile.fontSize, "CENTER", 0, 0)
    if button.SetDurationText and button._quiDuration then
        ns.SafeCall("sink-forward", button.SetDurationText, button, button._quiDuration,
            AuraSkin.ResolveDurationTextOptions(button, profile))
    end
    styleText(button._quiCount, profile.stack, profile.fontSize, "BOTTOMRIGHT", -1, 1)
    if fontPath and button._quiSymbol then button._quiSymbol:SetFont(fontPath, (profile.fontSize and profile.fontSize > 0) and profile.fontSize or 11, fontFlags) end

    local cd = button._quiCooldown
    local wantsLinear = profile.swipeStyle == "horizontal" or profile.swipeStyle == "vertical"
    if wantsLinear and button.SetDurationBar then
        if cd and cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
        local fill = button._quiDurationBar
        if not fill and InCombatLockdown() then
            return
        end
        if not fill then
            fill = CreateFrame("StatusBar", nil, button)
            fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
            fill:SetAllPoints(button)
            button._quiDurationBar = fill
        end
        button:SetDurationBar(fill, {
            direction = (profile.reverseSwipe and Enum.StatusBarTimerDirection.ElapsedTime)
                or Enum.StatusBarTimerDirection.RemainingTime,
            interpolation = Enum.StatusBarInterpolation.Immediate,
        })
        fill:SetOrientation(profile.swipeStyle == "vertical" and "VERTICAL" or "HORIZONTAL")
        fill:Show()
    else
        if button._quiDurationBar then button._quiDurationBar:Hide() end
        if cd then
            cd:SetDrawSwipe(profile.hideSwipe ~= true)
            cd:SetReverse(profile.reverseSwipe == true)
            cd:SetHideCountdownNumbers(true)
        end
    end
end

local function FlowFor(L)
    local grow = L.grow == "CENTER" and "RIGHT" or L.grow
    local column = (grow == "UP" or grow == "DOWN")
    local left = (grow == "LEFT")
    local up
    if column then up = (grow == "UP") else up = (L.wrap == "UP") end
    local anchor = (up and "BOTTOM" or "TOP") .. (left and "RIGHT" or "LEFT")
    return anchor, left, up, column
end

function AuraSkin.LayoutAnchor(profile)
    local L = ResolveLayout(profile)
    if L.grow == "CENTER" then
        return "CENTER"
    end
    local anchor = FlowFor(L)
    return anchor
end

local function ApplyContainerLayout(container, L)
    local anchor, left, up, column = FlowFor(L)
    local FD = AnchorUtil.FlowDirection
    local AX = AnchorUtil.FlowLayoutAxis
    container:SetFlowLayoutAnchorPoint(anchor)
    container:SetFlowLayoutGrowthDirection(
        left and FD.Left or FD.Right,
        up and FD.Up or FD.Down)
    container:SetFlowLayoutPadding(0, 0, 0, 0)
    container:SetFlowLayoutAxis(column and AX.Vertical or AX.Horizontal)
    local lineSize
    if L.maxPerRow and L.maxPerRow > 0 then
        lineSize = L.maxPerRow * L.iconSize + (L.maxPerRow - 1) * L.spacing + 0.5
    end
    container:SetFlowLayoutMaximumLineSize(lineSize)
end

local function GroupLayout(L, g)
    local t = {
        elementSpacing = L.spacing,
        lineSpacing    = L.spacing,
        elementWidth   = L.iconSize,
        elementHeight  = L.iconSize,
    }
    if g and type(g._quiOrder) == "number" then
        t.layoutIndex = g._quiOrder
    end
    return t
end

local function MakeInitializer(container, _groupDesc)
    return function(button)
        buildButtonArt(button)
        styleButton(button, container._quiProfile or {})
        if button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(container._quiCancelButtons)
        end
        local reg = container._quiButtons
        if not reg then
            reg = {}
            container._quiButtons = reg
        end
        if not button._quiTracked then
            button._quiTracked = true
            reg[#reg + 1] = button
        end
    end
end

local function EachTrackedButton(container, fn)
    local seen
    if container.GetAuraGroupFrame and container.GetAuraGroupFrameCount then
        seen = {}
        local registered = container._quiGroups
        if registered then
            for key in pairs(registered) do
                local count = container:GetAuraGroupFrameCount(key)
                for i = 1, count or 0 do
                    local button = container:GetAuraGroupFrame(key, i)
                    if button then
                        seen[button] = true
                        fn(button)
                    end
                end
            end
        end
    end
    local reg = container._quiButtons
    if reg then
        for i = 1, #reg do
            local button = reg[i]
            if button and not (seen and seen[button]) then
                fn(button)
            end
        end
    end
end

function AuraSkin.Configure(container, profile, groups)
    local L = ResolveLayout(profile)
    container._quiProfile = profile
    local cancel
    for i = 1, #groups do
        local c = groups[i].cancelButtons
        if c then cancel = c end
    end
    container._quiCancelButtons = cancel
    local registered = container._quiGroups
    if not registered then
        registered = {}
        container._quiGroups = registered
    end
    local wanted = {}
    local E = ResolveAuraElements()
    local canMutateFilter = container.SetAuraGroupFilterString ~= nil
    for i = 1, #groups do
        local g = groups[i]
        g._quiOrder = i
        local gkey = g.key or ""
        assert(not gkey:find("|", 1, true),
            "AuraSkin group key must not contain '|'")
        local filter = (E and E.CanonicalizeFilterString) and E.CanonicalizeFilterString(g.filter) or g.filter
        local key = canMutateFilter and gkey or (gkey .. "|" .. filter)
        wanted[key] = true
        local maxCount   = g.maxFrameCount or L.maxIcons
        local sortMethod = g.sortMethod or AuraContainerSortMethod.Default
        local sortDir    = g.sortDirection or AuraContainerSortDirection.Normal
        if registered[key] or container:HasAuraGroup(key) then
            if canMutateFilter and registered[key] ~= filter then
                container:SetAuraGroupFilterString(key, filter)
            end
            container:SetAuraGroupMaxFrameCount(key, maxCount)
            container:SetAuraGroupSortMethod(key, sortMethod, sortDir)
            container:SetAuraGroupCandidateFilters(key, g.candidateFilters)
            container:SetAuraGroupLayout(key, GroupLayout(L, g))
            registered[key] = filter
        else
            container:AddAuraGroup(key, filter, {
                maxFrameCount    = maxCount,
                sortMethod       = sortMethod,
                sortDirection    = sortDir,
                candidateFilters = g.candidateFilters,
                initializeFrame  = MakeInitializer(container, g),
                layout           = GroupLayout(L, g),
            })
            registered[key] = filter
        end
    end
    for key in pairs(registered) do
        if not wanted[key] then
            container:SetAuraGroupMaxFrameCount(key, 0)
        end
    end
    ApplyContainerLayout(container, L)

    if AurasAreSecret() then
        ScheduleRestrictedRestyle(container)
        return
    end
    EachTrackedButton(container, function(button)
        styleButton(button, profile)
        if button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(container._quiCancelButtons)
        end
    end)
end

function AuraSkin.Restyle(container, profile)
    container._quiProfile = profile
    if AurasAreSecret() then
        ScheduleRestrictedRestyle(container)
        return
    end
    EachTrackedButton(container, function(button)
        styleButton(button, profile)
        if button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(container._quiCancelButtons)
        end
    end)
end

function AuraSkin.ConfigureEnchantments(container, profile)
    local slots = _G.AuraContainerItemEnchantmentSlot
    local placement = _G.CustomAuraContainerItemEnchantmentPlacement
    if not (slots and placement and container.AddItemEnchantment) then
        return false
    end
    container._quiProfile = profile
    local L = ResolveLayout(profile)
    container:SetItemEnchantmentLayout({
        placement      = placement.BeforeAuraGroups,
        elementSpacing = L.spacing,
        lineSpacing    = L.spacing,
        elementWidth   = L.iconSize,
        elementHeight  = L.iconSize,
    })
    if not AurasAreSecret() then
        local reg = container._quiButtons
        if reg then
            for i = 1, #reg do
                local b = reg[i]
                if b and b.SetCancelAuraButtons then
                    b:SetCancelAuraButtons(container._quiCancelButtons)
                end
            end
        end
    end
    if not container._quiEnchantsAdded then
        local init = MakeInitializer(container, {})
        for _, slot in ipairs({ slots.MainHand, slots.OffHand, slots.Ranged }) do
            container:AddItemEnchantment(slot, {
                initializeFrame = init,
                hidePermanent   = true,
            })
        end
        container._quiEnchantsAdded = true
    end
    return true
end

function AuraSkin.WireButton(button, profile)
    buildButtonArt(button)
    styleButton(button, profile or {})
end

function AuraSkin.WirePreviewButton(button, profile)
    if not button.SetDurationBar then
        button.SetDurationBar = function(self, bar, options)
            self._quiPreviewDurationBar = bar
            self._quiPreviewDurationOptions = options
        end
        button._quiPreviewDurationBarShim = true
    end
    buildButtonArt(button)
    styleButton(button, profile or {})
    button._tex = button.Icon
    if button._quiDispel and button._quiDispel.Hide then button._quiDispel:Hide() end
end

function AuraSkin.ReleasePreviewButton(button)
    local key = button and button._quiBridgedKey
    local Bridge = ns.ExternalSkinBridge
    if key and Bridge then Bridge.RemoveButton(key, button) end
    if button then
        button._quiBridgedKey = nil
        button._quiBridged = nil
    end
end
