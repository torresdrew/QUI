--[[
    QUI Layout Mode Settings Providers
    Migrated from options panels to layout mode context panels.
    Covers: XP Tracker, Brez Counter, Combat Timer, Rotation Assist Icon,
            Focus Cast Alert, Pet Warning, Buff/Debuff Borders, Minimap,
            Extra Action Button, Zone Ability, Totem Bar
]]

local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- REGISTER ALL PROVIDERS
---------------------------------------------------------------------------
local function RegisterAllProviders()
    local settingsPanel = ns.QUI_LayoutMode_Settings
    if not settingsPanel then return end

    local GUI = QUI and QUI.GUI
    if not GUI then return end

    local U = ns.QUI_LayoutMode_Utils
    if not U then return end

    local P = U.PlaceRow
    local FORM_ROW = U.FORM_ROW

    local anchorOptions = {
        {value = "TOPLEFT", text = "Top Left"},
        {value = "TOP", text = "Top"},
        {value = "TOPRIGHT", text = "Top Right"},
        {value = "LEFT", text = "Left"},
        {value = "CENTER", text = "Center"},
        {value = "RIGHT", text = "Right"},
        {value = "BOTTOMLEFT", text = "Bottom Left"},
        {value = "BOTTOM", text = "Bottom"},
        {value = "BOTTOMRIGHT", text = "Bottom Right"},
    }

    ---------------------------------------------------------------------------
    -- XP TRACKER
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("xpTracker", { build = function(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.xpTracker then return 80 end
        local xp = db.xpTracker
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshXPTracker then _G.QUI_RefreshXPTracker() end end

        U.CreateCollapsible(content, "Size & Text", 9 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormSlider(body, "Bar Width", 200, 1000, 1, "width", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Height", 60, 200, 1, "height", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Bar Height", 8, 40, 1, "barHeight", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Header Font Size", 8, 22, 1, "headerFontSize", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Header Line Height", 12, 30, 1, "headerLineHeight", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Font Size", 8, 18, 1, "fontSize", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Line Height", 10, 24, 1, "lineHeight", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormDropdown(body, "Bar Texture", U.GetTextureList(), "barTexture", xp, Refresh), body, sy)
            P(GUI:CreateFormDropdown(body, "Details Grow Direction", {{value="auto",text="Auto"},{value="up",text="Up"},{value="down",text="Down"}}, "detailsGrowDirection", xp, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Colors", 4 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormColorPicker(body, "XP Bar Color", "barColor", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Rested XP Color", "restedColor", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Backdrop Color", "backdropColor", xp, Refresh), body, sy)
            P(GUI:CreateFormColorPicker(body, "Border Color", "borderColor", xp, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Display", 4 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Show Bar Text", "showBarText", xp, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Show Rested XP Overlay", "showRested", xp, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Hide Text Until Hover", "hideTextUntilHover", xp, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "xpTracker", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- COMBAT TIMER
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("combatTimer", { build = function(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.combatTimer then return 80 end
        local ct = db.combatTimer
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshCombatTimer then _G.QUI_RefreshCombatTimer() end end

        U.CreateCollapsible(content, "General", 4 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Only Show In Encounters", "onlyShowInEncounters", ct, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Width", 40, 200, 1, "width", ct, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Height", 20, 100, 1, "height", ct, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Font Size", 12, 32, 1, "fontSize", ct, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Text", 4 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Use Class Color", "useClassColorText", ct, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Text Color", "textColor", ct, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Use Custom Font", "useCustomFont", ct, Refresh), body, sy)
            local fonts = U.GetFontList(); if #fonts > 0 then P(GUI:CreateFormDropdown(body, "Font", fonts, "font", ct, Refresh), body, sy) end
        end, sections, relayout)

        U.BuildBackdropBorderSection(content, ct, sections, relayout, Refresh)

        U.BuildPositionCollapsible(content, "combatTimer", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- BREZ COUNTER
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("brezCounter", { build = function(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.brzCounter then return 80 end
        local bz = db.brzCounter
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshBrezCounter then _G.QUI_RefreshBrezCounter() end end

        U.CreateCollapsible(content, "General", 5 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Lock Frame", "locked", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Width", 30, 100, 1, "width", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Height", 30, 100, 1, "height", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Charges Font Size", 10, 28, 1, "fontSize", bz, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Timer Font Size", 8, 24, 1, "timerFontSize", bz, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Colors", 6 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormColorPicker(body, "Charges Available", "hasChargesColor", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "No Charges", "noChargesColor", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Class Color Timer Text", "useClassColorText", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Timer Text Color", "timerColor", bz, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Use Custom Font", "useCustomFont", bz, Refresh), body, sy)
            local fonts = U.GetFontList(); if #fonts > 0 then P(GUI:CreateFormDropdown(body, "Font", fonts, "font", bz, Refresh), body, sy) end
        end, sections, relayout)

        U.BuildBackdropBorderSection(content, bz, sections, relayout, Refresh)

        U.BuildPositionCollapsible(content, "brezCounter", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- ROTATION ASSIST ICON
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("rotationAssistIcon", { build = function(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.rotationAssistIcon then return 80 end
        local ra = db.rotationAssistIcon
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshRotationAssistIcon then _G.QUI_RefreshRotationAssistIcon() end end

        U.CreateCollapsible(content, "General", 6 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Lock Position", "isLocked", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Cooldown Swipe", "cooldownSwipeEnabled", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormDropdown(body, "Visibility", {{value="always",text="Always"},{value="combat",text="In Combat"},{value="hostile",text="Hostile Target"}}, "visibility", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormDropdown(body, "Frame Strata", {{value="LOW",text="Low"},{value="MEDIUM",text="Medium"},{value="HIGH",text="High"},{value="DIALOG",text="Dialog"}}, "frameStrata", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Icon Size", 16, 400, 1, "iconSize", ra, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Border Size", 0, 15, 1, "borderThickness", ra, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Border & Keybind", 7 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormColorPicker(body, "Border Color", "borderColor", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Show Keybind", "showKeybind", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Keybind Color", "keybindColor", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormDropdown(body, "Keybind Anchor", anchorOptions, "keybindAnchor", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Keybind Size", 6, 48, 1, "keybindSize", ra, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Keybind X Offset", -50, 50, 1, "keybindOffsetX", ra, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Keybind Y Offset", -50, 50, 1, "keybindOffsetY", ra, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "rotationAssistIcon", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- FOCUS CAST ALERT
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("focusCastAlert", { build = function(content, key, width)
        local db = U.GetProfileDB()
        local general = db and db.general
        if not general or not general.focusCastAlert then return 80 end
        local fca = general.focusCastAlert
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshFocusCastAlert then _G.QUI_RefreshFocusCastAlert() end end

        U.CreateCollapsible(content, "Text & Font", 6 * FORM_ROW + 8, function(body)
            local sy = -4
            local fonts = U.GetFontList(); table.insert(fonts, 1, {value = "", text = "(Global Font)"})
            sy = P(GUI:CreateFormDropdown(body, "Font", fonts, "font", fca, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Font Size", 8, 72, 1, "fontSize", fca, Refresh), body, sy)
            sy = P(GUI:CreateFormDropdown(body, "Font Outline", {{value="",text="None"},{value="OUTLINE",text="Outline"},{value="THICKOUTLINE",text="Thick Outline"}}, "fontOutline", fca, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Use Class Color", "useClassColor", fca, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Text Color", "textColor", fca, Refresh), body, sy)
            P(GUI:CreateFormDropdown(body, "Anchor To", {{value="screen",text="Screen"},{value="essential",text="CDM Essential"},{value="focus",text="Focus Frame"}}, "anchorTo", fca, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "focusCastAlert", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- PET WARNING
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("petWarning", { build = function(content, key, width)
        local db = U.GetProfileDB()
        local general = db and db.general
        if not general then return 80 end
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RepositionPetWarning then _G.QUI_RepositionPetWarning() end end

        U.CreateCollapsible(content, "Offsets", 2 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormSlider(body, "Horizontal Offset", -500, 500, 10, "petWarningOffsetX", general, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Vertical Offset", -500, 500, 10, "petWarningOffsetY", general, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "petWarning", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- BUFF / DEBUFF BORDERS (shared provider for both)
    ---------------------------------------------------------------------------
    local function BuildBuffDebuffSettings(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.buffBorders then return 80 end
        local bb = db.buffBorders
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshBuffBorders then _G.QUI_RefreshBuffBorders() end end

        U.CreateCollapsible(content, "Borders", 4 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Enable Buff Borders", "enableBuffs", bb, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Enable Debuff Borders", "enableDebuffs", bb, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Border Size", 1, 5, 0.5, "borderSize", bb, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Font Size", 6, 24, 1, "fontSize", bb, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Visibility", 2 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Hide Buff Frame", "hideBuffFrame", bb, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Hide Debuff Frame", "hideDebuffFrame", bb, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, key, nil, sections, relayout)
        relayout() return content:GetHeight()
    end

    settingsPanel:RegisterProvider({"buffFrame", "debuffFrame"}, { build = BuildBuffDebuffSettings })

    ---------------------------------------------------------------------------
    -- MINIMAP
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("minimap", { build = function(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.minimap then return 80 end
        local mm = db.minimap
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshMinimap then _G.QUI_RefreshMinimap() end end

        U.CreateCollapsible(content, "General", 5 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormSlider(body, "Map Dimensions", 120, 380, 1, "size", mm, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Scale", 0.5, 2.0, 0.01, "scale", mm, Refresh, { deferOnDrag = true }), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Middle-Click Menu", "middleClickMenuEnabled", mm, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Hide Blizzard Micro Menu", "hideMicroMenu", mm, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Hide Blizzard Bag Bar", "hideBagBar", mm, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Border", 4 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormSlider(body, "Border Size", 1, 16, 1, "borderSize", mm, Refresh), body, sy)
            sy = P(GUI:CreateFormColorPicker(body, "Border Color", "borderColor", mm, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Class Color Border", "useClassColorBorder", mm, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Accent Color Border", "useAccentColorBorder", mm, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "minimap", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- EXTRA ACTION BUTTON
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("extraActionButton", { build = function(content, key, width)
        local db = U.GetProfileDB()
        local bars = db and db.actionBars and db.actionBars.bars
        local eab = bars and bars.extraActionButton
        if not eab then return 80 end
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshExtraButtons then _G.QUI_RefreshExtraButtons() end end

        U.CreateCollapsible(content, "General", 3 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormSlider(body, "Scale", 0.5, 2.0, 0.05, "scale", eab, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Hide Artwork", "hideArtwork", eab, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Mouseover Fade", "fadeEnabled", eab, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "extraActionButton", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- ZONE ABILITY
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("zoneAbility", { build = function(content, key, width)
        local db = U.GetProfileDB()
        local bars = db and db.actionBars and db.actionBars.bars
        local za = bars and bars.zoneAbility
        if not za then return 80 end
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshExtraButtons then _G.QUI_RefreshExtraButtons() end end

        U.CreateCollapsible(content, "General", 3 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormSlider(body, "Scale", 0.5, 2.0, 0.05, "scale", za, Refresh), body, sy)
            sy = P(GUI:CreateFormCheckbox(body, "Hide Artwork", "hideArtwork", za, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Mouseover Fade", "fadeEnabled", za, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "zoneAbility", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- TOTEM BAR
    ---------------------------------------------------------------------------
    settingsPanel:RegisterProvider("totemBar", { build = function(content, key, width)
        local db = U.GetProfileDB()
        if not db or not db.totemBar then return 80 end
        local tb = db.totemBar
        local sections = {}
        local function relayout() U.StandardRelayout(content, sections) end
        local function Refresh() if _G.QUI_RefreshTotemBar then _G.QUI_RefreshTotemBar() end end

        U.CreateCollapsible(content, "Layout", 5 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormDropdown(body, "Grow Direction", {{value="RIGHT",text="Right"},{value="LEFT",text="Left"},{value="DOWN",text="Down"},{value="UP",text="Up"}}, "growDirection", tb, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Icon Size", 20, 80, 1, "iconSize", tb, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Spacing", 0, 20, 1, "spacing", tb, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Border Size", 0, 6, 1, "borderSize", tb, Refresh), body, sy)
            P(GUI:CreateFormSlider(body, "Icon Zoom", 0, 0.15, 0.01, "zoom", tb, Refresh), body, sy)
        end, sections, relayout)

        U.CreateCollapsible(content, "Duration & Cooldown", 3 * FORM_ROW + 8, function(body)
            local sy = -4
            sy = P(GUI:CreateFormCheckbox(body, "Hide Duration Text", "hideDurationText", tb, Refresh), body, sy)
            sy = P(GUI:CreateFormSlider(body, "Duration Text Size", 8, 24, 1, "durationSize", tb, Refresh), body, sy)
            P(GUI:CreateFormCheckbox(body, "Show Cooldown Swipe", "showSwipe", tb, Refresh), body, sy)
        end, sections, relayout)

        U.BuildPositionCollapsible(content, "totemBar", nil, sections, relayout)
        relayout() return content:GetHeight()
    end })

    ---------------------------------------------------------------------------
    -- POSITION-ONLY PROVIDERS
    ---------------------------------------------------------------------------
    for _, providerKey in ipairs({"rangeCheck", "actionTracker", "crosshair", "skyriding"}) do
        settingsPanel:RegisterProvider(providerKey, { build = function(content, key, width)
            local sections = {}
            local function relayout() U.StandardRelayout(content, sections) end
            U.BuildPositionCollapsible(content, providerKey, nil, sections, relayout)
            relayout() return content:GetHeight()
        end })
    end
end

C_Timer.After(3, RegisterAllProviders)
