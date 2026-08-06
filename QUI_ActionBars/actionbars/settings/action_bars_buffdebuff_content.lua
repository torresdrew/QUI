local ADDON_NAME, ns = ...
local QUI = QUI
local GUI = QUI.GUI
local Opts = ns.QUI_Options
-- This tab's only settings surface is the Auras hub's "Buff/Debuff Frames"
-- sub-page (tabIndex 21, subTabIndex 4, auras tile subPages[4] -- see
-- QUI_Options/tiles/auras.lua and core/settings/content/auras_actionbar_page.lua).
-- The Action Bars tile's own Buff/Debuff sub-page was removed, and its
-- array slot 2 now holds "Per-Bar", so the search context below must name the
-- hub: routing it at action_bars/2 sent every harvested entry to Per-Bar.
local BUFF_DEBUFF_SEARCH_TILE_ID = "auras"
local ACTION_BARS_BUFF_DEBUFF_FEATURE_ID = "actionBarsBuffDebuff"
local BUFF_DEBUFF_SUB_PAGE_INDEX = 4

local function RefreshBuffBorders()
    if Opts and Opts.RefreshBuffBorders then
        Opts.RefreshBuffBorders()
        return
    end

    if _G.QUI_RefreshBuffBorders then
        _G.QUI_RefreshBuffBorders()
    end
end

local function GetBuffBordersSettings()
    local db = Opts and Opts.GetDB and Opts.GetDB()
    if not db then
        return nil
    end

    db.buffBorders = db.buffBorders or {}
    return db.buffBorders
end

local function BuildSharedSection(tabContent, headerAt, sectionAt, closeSection, settings)
    headerAt(ns.L["Shared"])
    local card = sectionAt()

    local showStacks = GUI:CreateFormToggle(card.frame, nil, "showStacks", settings, RefreshBuffBorders,
        { description = ns.L["Show stack counts on aura icons when the buff or debuff has multiple stacks."] })
    local hideSwipe = GUI:CreateFormToggle(card.frame, nil, "hideSwipe", settings, RefreshBuffBorders,
        { description = ns.L["Hide the cooldown swipe animation that fills the icon as time expires."] })
    card.AddRow(
        Opts.BuildSettingRow(card.frame, ns.L["Show Stack Counts"], showStacks),
        Opts.BuildSettingRow(card.frame, ns.L["Hide Duration Swipe"], hideSwipe)
    )

    local externalSkin = GUI:CreateFormToggle(card.frame, nil, "externalSkinning", settings, RefreshBuffBorders,
        { description = "When an external button-skinning addon is installed, let it skin buff/debuff icons instead of QUI's own border." })
    card.AddRow(
        Opts.BuildSettingRow(card.frame, "External Skinning", externalSkin)
    )

    local skinOptions = {}
    if ns.IconSkin and ns.IconSkin.GetSkinList then
        for _, name in ipairs(ns.IconSkin.GetSkinList()) do
            skinOptions[#skinOptions + 1] = { value = name, text = name }
        end
    end
    if #skinOptions == 0 then skinOptions = { { value = "Default", text = "Default" } } end
    local iconSkin = GUI:CreateFormDropdown(card.frame, nil, skinOptions, "iconSkin", settings, RefreshBuffBorders, nil,
        { description = "In-house skin preset (gloss + backdrop) for buff/debuff icons. Default keeps QUI's original look." })
    card.AddRow(
        Opts.BuildSettingRow(card.frame, "Button Skin", iconSkin)
    )

    local borderSize = GUI:CreateFormSlider(card.frame, nil, 1, 6, 1, "borderSize", settings, RefreshBuffBorders, nil,
        { description = ns.L["Thickness of the border drawn around buff and debuff icons."] })
    local fontSize = GUI:CreateFormSlider(card.frame, nil, 8, 24, 1, "fontSize", settings, RefreshBuffBorders, nil,
        { description = ns.L["Font size used for both stack text and countdown text."] })
    card.AddRow(
        Opts.BuildSettingRow(card.frame, ns.L["Border Size"], borderSize),
        Opts.BuildSettingRow(card.frame, ns.L["Font Size"], fontSize)
    )

    local fadeOutAlpha = GUI:CreateFormSlider(card.frame, nil, 0, 1, 0.05, "fadeOutAlpha", settings, RefreshBuffBorders, nil,
        { description = ns.L["Opacity used when a faded buff or debuff frame is not being hovered."] })
    card.AddRow(Opts.BuildSettingRow(card.frame, ns.L["Fade Out Opacity"], fadeOutAlpha))

    closeSection(card)
end

-- Returns the header frame + its build-time y offset and the card frame +
-- its build-time y offset, so a caller that needs to re-anchor this section
-- later (see the reflow wiring in BuildBuffDebuffTab) has stable originals
-- to recompute absolute offsets from.
local function BuildAuraSection(tabContent, headerAt, sectionAt, closeSection, settings, spec)
    local header, headerY = headerAt(spec.title)

    local general, cardY = sectionAt()
    local enabled = GUI:CreateFormToggle(general.frame, nil, spec.enabledKey, settings, RefreshBuffBorders,
        { description = spec.enableDescription })
    local showBorders = GUI:CreateFormToggle(general.frame, nil, spec.showBordersKey, settings, RefreshBuffBorders,
        { description = spec.borderDescription })
    general.AddRow(
        Opts.BuildSettingRow(general.frame, ns.L["Enabled"], enabled),
        Opts.BuildSettingRow(general.frame, ns.L["Show Borders"], showBorders)
    )

    local hideFrame = GUI:CreateFormToggle(general.frame, nil, spec.hideFrameKey, settings, RefreshBuffBorders,
        { description = spec.hideDescription })
    local fadeFrame = GUI:CreateFormToggle(general.frame, nil, spec.fadeKey, settings, RefreshBuffBorders,
        { description = spec.fadeDescription })
    general.AddRow(
        Opts.BuildSettingRow(general.frame, ns.L["Hide Frame"], hideFrame),
        Opts.BuildSettingRow(general.frame, ns.L["Fade On Mouseover"], fadeFrame)
    )
    closeSection(general)

    return header, headerY, general.frame, cardY
end

-- Mount the shared aura element editor (Task 8/9) for one BB zone. BB is
-- strips-only (no tracked icons/squares/bars) and has NO spec-bucket
-- dimension, so this always edits the "*" bucket. storeKey is "buffAuras" or
-- "debuffAuras" (settings.<storeKey>, create-on-demand — AceDB never persists
-- an array default, so the store must exist before the first mount). Right-
-- click cancel is engine-owned and buff-only (cancelEligible gated by caller).
-- BB is single-strip per zone; fixedAuraType pins the strip's polarity to the zone.
--
-- Unlike the card-based sections above, the embedded editor owns its own
-- dynamic height (rows can be added/removed live), so it is anchored as a
-- bare frame directly under tabContent rather than through
-- sectionAt()/closeSection(): CreateSettingsCardGroup's Finalize() sizes a
-- card purely from AddRow bookkeeping, which this content never calls, and
-- would stomp the editor's real height back to 0. Takes/returns the y cursor
-- like headerAt/sectionAt do internally, since this isn't a closure over it.
-- Returns (nextY, editorHost, mountedHeight, SetOnLayoutChanged).
-- mountedHeight is the height captured from this synchronous mount -- the
-- caller's baseline for computing a delta on later resizes. SetOnLayoutChanged
-- lets the caller wire the real reflow handler once it exists (see below);
-- until then the editor's own initial rebuild fires onLayoutChanged straight
-- into a no-op upvalue, since nothing below this section has been built yet.
local function BuildAuraEditorSection(tabContent, PAD, SECTION_GAP, y, settings, storeKey, defaultBucketFn, cancelEligible, fixedAuraType)
    local AurasEditor = ns.QUI_AuraElementsEditor
    if not AurasEditor or type(AurasEditor.RenderAuras) ~= "function" then
        return y
    end

    settings[storeKey] = settings[storeKey] or {}
    local auras = settings[storeKey]

    local editorHost = CreateFrame("Frame", nil, tabContent)
    editorHost:SetPoint("TOPLEFT", tabContent, "TOPLEFT", PAD, y)
    editorHost:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", -PAD, y)
    editorHost:SetHeight(1)

    ---@type fun(...): ... -- replaced below by the caller-supplied handler
    local onLayoutChangedHandler = function() end
    local height = AurasEditor.RenderAuras(editorHost, auras, "*", RefreshBuffBorders, {
        capabilities = {
            elementTypes      = { filterStrip = true },
            singleStrip       = true,
            fixedAuraType     = fixedAuraType,
            cancelEligible    = cancelEligible,
            allowSpecOverride = false,
            roleGate          = false,
            defaultBucketFn   = defaultBucketFn,
            -- Buff borders always track the PLAYER's own buffs/debuffs —
            -- always assistable (Wave 4 Task 2c polarity hint).
            unitPolarity      = "friendly",
        },
        onLayoutChanged = function(newHeight)
            onLayoutChangedHandler(newHeight)
        end,
    })
    height = (type(height) == "number" and height > 0) and height
        or (editorHost.GetHeight and editorHost:GetHeight())
        or 1
    height = math.max(1, height)
    editorHost:SetHeight(height)

    local function SetOnLayoutChanged(fn)
        onLayoutChangedHandler = fn
    end

    return y - height - SECTION_GAP, editorHost, height, SetOnLayoutChanged
end

local function BuildBuffDebuffTab(tabContent)
    local settings = GetBuffBordersSettings()
    if not settings then
        local label = tabContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", 15, -15)
        label:SetPoint("RIGHT", tabContent, "RIGHT", -15, 0)
        label:SetJustifyH("LEFT")
        label:SetText(ns.L["Buff and debuff settings are unavailable right now."])
        tabContent:SetHeight(80)
        return
    end

    local PAD = Opts.PADDING
    local HEADER_GAP = 26
    local SECTION_GAP = 14
    local y = -10

    local buffDebuffContext = {
        tabIndex = 21,
        tabName = ns.L["Auras"],
        subTabIndex = 4,
        subTabName = ns.L["Buff/Debuff Frames"],
        tileId = BUFF_DEBUFF_SEARCH_TILE_ID,
        subPageIndex = BUFF_DEBUFF_SUB_PAGE_INDEX,
        featureId = ACTION_BARS_BUFF_DEBUFF_FEATURE_ID,
        category = "frames",
    }
    local SearchRoute = ns.Settings and ns.Settings.SearchRoute
    if SearchRoute and type(SearchRoute.Apply) == "function" then
        SearchRoute.Apply(buffDebuffContext)
    end
    GUI:SetSearchContext(buffDebuffContext)

    -- Both return the frame they built PLUS the y offset it was built at (the
    -- caller may need that original offset later to recompute an absolute
    -- re-anchor when a section above resizes -- see the reflow wiring below).
    local function headerAt(text)
        local originY = y
        local header = Opts.CreateAccentDotLabel(tabContent, text, y)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", tabContent, "TOPLEFT", PAD, y)
        header:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", -PAD, y)
        y = y - HEADER_GAP
        return header, originY
    end

    local function sectionAt()
        local originY = y
        local card = Opts.CreateSettingsCardGroup(tabContent, y)
        card.frame:ClearAllPoints()
        card.frame:SetPoint("TOPLEFT", tabContent, "TOPLEFT", PAD, y)
        card.frame:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", -PAD, y)
        return card, originY
    end

    local function closeSection(card)
        card.Finalize()
        y = y - card.frame:GetHeight() - SECTION_GAP
    end

    BuildSharedSection(tabContent, headerAt, sectionAt, closeSection, settings)

    BuildAuraSection(tabContent, headerAt, sectionAt, closeSection, settings, {
        title = ns.L["Buffs"],
        enabledKey = "enableBuffs",
        showBordersKey = "showBuffBorders",
        hideFrameKey = "hideBuffFrame",
        fadeKey = "fadeBuffFrame",
        enableDescription = ns.L["Show the custom buff frame managed by QUI."],
        borderDescription = ns.L["Draw borders around buff icons."],
        hideDescription = ns.L["Hide the buff frame entirely, even when hovering its anchor area."],
        fadeDescription = ns.L["Fade the buff frame out until you hover it."],
    })
    local BB = ns.QUI_BuffBorders
    -- The buff editor's own host never needs re-anchoring (nothing above it
    -- resizes), so its host reference is intentionally unused (_).
    local _buffEditorHost, buffOriginalHeight, buffSetOnLayoutChanged
    y, _buffEditorHost, buffOriginalHeight, buffSetOnLayoutChanged = BuildAuraEditorSection(
        tabContent, PAD, SECTION_GAP, y, settings, "buffAuras", BB and BB.DefaultBuffBucket, true, "HELPFUL")

    local debuffHeader, debuffHeaderY, debuffCardFrame, debuffCardY = BuildAuraSection(
        tabContent, headerAt, sectionAt, closeSection, settings, {
        title = ns.L["Debuffs"],
        enabledKey = "enableDebuffs",
        showBordersKey = "showDebuffBorders",
        hideFrameKey = "hideDebuffFrame",
        fadeKey = "fadeDebuffFrame",
        enableDescription = ns.L["Show the custom debuff frame managed by QUI."],
        borderDescription = ns.L["Draw borders around debuff icons."],
        hideDescription = ns.L["Hide the debuff frame entirely, even when hovering its anchor area."],
        fadeDescription = ns.L["Fade the debuff frame out until you hover it."],
    })

    local debuffEditorY = y
    -- The engine can only cancel HELPFUL (buff) auras — cancelEligible = false
    -- here (AuraGlue.ElementGroups also gates this defensively).
    local debuffEditorHost, debuffOriginalHeight, debuffSetOnLayoutChanged
    y, debuffEditorHost, debuffOriginalHeight, debuffSetOnLayoutChanged = BuildAuraEditorSection(
        tabContent, PAD, SECTION_GAP, y, settings, "debuffAuras", BB and BB.DefaultDebuffBucket, false, "HARMFUL")

    local baseTabHeight = math.abs(y) + 40
    tabContent:SetHeight(baseTabHeight)

    -- Wire the reflow now that everything below the buff editor exists. The
    -- embedded aura editor resizes itself in place (Filter Mode flips, Dispel
    -- Type Filter include/exclude, whitelist/blacklist edits) and reports the
    -- new height via onLayoutChanged; without this, frames below a resized
    -- editor keep stale anchors (overlap on grow, gap on shrink) and
    -- tabContent goes stale too. Deltas are always computed against each
    -- editor's ORIGINAL mount height (never the previous fire), so repeated
    -- resizes never drift.
    if buffSetOnLayoutChanged or debuffSetOnLayoutChanged then
        local buffDelta, debuffDelta = 0, 0

        local function ApplyReflow()
            local shift = buffDelta
            if debuffHeader then
                debuffHeader:ClearAllPoints()
                debuffHeader:SetPoint("TOPLEFT", tabContent, "TOPLEFT", PAD, debuffHeaderY - shift)
                debuffHeader:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", -PAD, debuffHeaderY - shift)
            end
            if debuffCardFrame then
                debuffCardFrame:ClearAllPoints()
                debuffCardFrame:SetPoint("TOPLEFT", tabContent, "TOPLEFT", PAD, debuffCardY - shift)
                debuffCardFrame:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", -PAD, debuffCardY - shift)
            end
            if debuffEditorHost then
                debuffEditorHost:ClearAllPoints()
                debuffEditorHost:SetPoint("TOPLEFT", tabContent, "TOPLEFT", PAD, debuffEditorY - shift)
                debuffEditorHost:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", -PAD, debuffEditorY - shift)
            end
            tabContent:SetHeight(baseTabHeight + buffDelta + debuffDelta)
        end

        if buffSetOnLayoutChanged then
            buffSetOnLayoutChanged(function(height)
                if type(height) ~= "number" or not buffOriginalHeight then return end
                buffDelta = height - buffOriginalHeight
                ApplyReflow()
            end)
        end

        if debuffSetOnLayoutChanged then
            debuffSetOnLayoutChanged(function(height)
                if type(height) ~= "number" or not debuffOriginalHeight then return end
                debuffDelta = height - debuffOriginalHeight
                ApplyReflow()
            end)
        end
    end
end

ns.QUI_BuffDebuffOptions = {
    BuildBuffDebuffTab = BuildBuffDebuffTab,
}
