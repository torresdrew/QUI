--[[
    QUI Nameplates — settings schema (GroupFrames pattern: schema/model/surface).

    Three schema-backed tabs rendered through the shared Settings.Renderer:
      Display  — enable, health bar/text, name, castbar, absorbs, raid marker,
                 aura icon rows, hitbox + stacking spacing
      Colors   — reaction set, cast colors, threat, target/focus, highlight,
                 out-of-combat darkening, execute range
      Behavior — friendly plate modes, aura filtering, spell lists (important +
                 per-channel allow/block), nameplate CVars

    Every widget change calls ns.QUI_RefreshNameplates() — the driver bumps the
    appearance generation, reapplies CVars, and restyles live plates.
]]

local ADDON_NAME, ns = ...
local QUI = QUI

local Settings = ns.Settings
local Renderer = Settings and Settings.Renderer
local Schema = Settings and Settings.Schema
if not Renderer or type(Renderer.RenderFeature) ~= "function"
    or not Schema or type(Schema.Feature) ~= "function" then
    return
end

local Helpers = ns.Helpers

local NameplatesSchema = ns.QUI_NameplatesSettingsSchema or {}
ns.QUI_NameplatesSettingsSchema = NameplatesSchema

local HEADER_GAP = 26
local SECTION_BOTTOM_PAD = 10
local DESCRIPTION_TEXT_COLOR = { 0.5, 0.5, 0.5, 1 }

local HEALTH_TEXT_STYLE_OPTIONS = {
    { value = "percent", text = ns.L["Percentage"] },
    { value = "absolute", text = ns.L["Absolute"] },
    { value = "both", text = ns.L["Both"] },
    { value = "none", text = ns.L["None"] },
}
local RAID_MARKER_POSITION_OPTIONS = {
    { value = "TOPRIGHT", text = ns.L["Top Right"] },
    { value = "TOP", text = ns.L["Top"] },
    { value = "LEFT", text = ns.L["Left"] },
    { value = "RIGHT", text = ns.L["Right"] },
}
local AURA_GROWTH_OPTIONS = {
    { value = "LEFT", text = ns.L["Left"] },
    { value = "RIGHT", text = ns.L["Right"] },
    { value = "CENTER", text = ns.L["Center"] },
}
local FRIENDLY_MODE_OPTIONS = {
    { value = "nameonly", text = ns.L["Name Only"] },
    { value = "bars", text = ns.L["Health Bars"] },
    { value = "off", text = ns.L["Off (Blizzard Plates)"] },
}

local ANCHOR_POINT_OPTIONS = {
    { value = "TOPLEFT", text = ns.L["Top Left"] },
    { value = "TOP", text = ns.L["Top"] },
    { value = "TOPRIGHT", text = ns.L["Top Right"] },
    { value = "LEFT", text = ns.L["Left"] },
    { value = "CENTER", text = ns.L["Center"] },
    { value = "RIGHT", text = ns.L["Right"] },
    { value = "BOTTOMLEFT", text = ns.L["Bottom Left"] },
    { value = "BOTTOM", text = ns.L["Bottom"] },
    { value = "BOTTOMRIGHT", text = ns.L["Bottom Right"] },
}

local JUSTIFY_OPTIONS = {
    { value = "LEFT", text = ns.L["Left"] },
    { value = "CENTER", text = ns.L["Center"] },
    { value = "RIGHT", text = ns.L["Right"] },
}

-- Search routing: mirrors the tile's constants (QUI_Options/tiles/nameplates.lua).
-- tabIndex 21 is a fresh static route id — the legacy tab bar never had a
-- Nameplates page, so no historical index exists to reuse.
local TAB_SEARCH_CONTEXTS = {
    display = { subTabIndex = 1, subTabName = "Display" },
    auras = { subTabIndex = 2, subTabName = "Auras" },
    castbars = { subTabIndex = 3, subTabName = "Castbars" },
    colors = { subTabIndex = 4, subTabName = "Colors" },
    behavior = { subTabIndex = 5, subTabName = "Behavior" },
}
local NAMEPLATES_SEARCH_TAB_INDEX = 21
local NAMEPLATES_SEARCH_TILE_ID = "nameplates"
local NAMEPLATES_SEARCH_FEATURE_ID = "nameplatesPage"
local NAMEPLATES_SEARCH_SUB_PAGE_INDEX = 1

local function GetGUI()
    return QUI and QUI.GUI or nil
end

local function GetOptionsAPI()
    return ns.QUI_Options
end

local function ResolveNameplatesDB()
    local profile = Helpers and Helpers.GetProfile and Helpers.GetProfile()
    local npdb = profile and profile.nameplates
    if type(npdb) ~= "table" then
        return nil
    end
    return npdb
end

local function SetSearchContext(searchContext)
    local gui = GetGUI()
    if gui and type(gui.SetSearchContext) == "function" and type(searchContext) == "table" then
        gui:SetSearchContext(searchContext)
    end
end

local function CreateSearchContext(tabKey)
    local context = TAB_SEARCH_CONTEXTS[tabKey] or TAB_SEARCH_CONTEXTS.display
    return {
        tabIndex = NAMEPLATES_SEARCH_TAB_INDEX,
        tabName = "Nameplates",
        subTabIndex = context.subTabIndex,
        subTabName = context.subTabName,
        tileId = NAMEPLATES_SEARCH_TILE_ID,
        subPageIndex = NAMEPLATES_SEARCH_SUB_PAGE_INDEX,
        featureId = NAMEPLATES_SEARCH_FEATURE_ID,
        category = "frames",
        surfaceTabKey = tabKey,
    }
end

local function EnsureSubTable(parent, key)
    if type(parent) ~= "table" then
        return nil
    end
    if type(parent[key]) ~= "table" then
        parent[key] = {}
    end
    return parent[key]
end

local function PrepareSectionHost(sectionHost, ctx)
    if not sectionHost then
        return
    end

    local pad = ctx and ctx.surface and ctx.surface.padding or 0
    local width = ctx and ctx.width or 760
    if type(width) ~= "number" or width <= 0 then
        width = 760
    end
    width = math.max(320, width - (pad * 2))
    if sectionHost.SetWidth then
        sectionHost:SetWidth(width)
    end
end

local function CreateSectionBuilder(sectionHost, ctx, searchContext)
    local optionsAPI = GetOptionsAPI()
    if not optionsAPI then
        return nil
    end

    PrepareSectionHost(sectionHost, ctx)
    SetSearchContext(searchContext)

    local y = 0
    local builder = {}

    function builder.Header(text)
        if type(text) ~= "string" or text == "" then
            return
        end

        local header = optionsAPI.CreateAccentDotLabel(sectionHost, text, y)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, y)
        header:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, y)
        y = y - HEADER_GAP
    end

    function builder.Description(text)
        if type(text) ~= "string" or text == "" then
            return
        end

        local description = sectionHost:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        description:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, y)
        description:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, y)
        description:SetJustifyH("LEFT")
        description:SetText(text)
        description:SetTextColor(
            DESCRIPTION_TEXT_COLOR[1],
            DESCRIPTION_TEXT_COLOR[2],
            DESCRIPTION_TEXT_COLOR[3],
            DESCRIPTION_TEXT_COLOR[4]
        )
        local height = 14
        if description.GetStringHeight then
            height = math.max(14, math.ceil(description:GetStringHeight() or 14))
        end
        y = y - height - 4
    end

    function builder.Card()
        local card = optionsAPI.CreateSettingsCardGroup(sectionHost, y)
        card.frame:ClearAllPoints()
        card.frame:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, y)
        card.frame:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, y)
        return card
    end

    function builder.CloseCard(card)
        card.Finalize()
        y = y - card.frame:GetHeight()
    end

    function builder.Spacer(amount)
        y = y - (amount or 10)
    end

    function builder.Height(extra)
        return math.abs(y) + (extra or SECTION_BOTTOM_PAD)
    end

    return builder
end

local function RefreshNameplates()
    if ns.QUI_RefreshNameplates then
        ns.QUI_RefreshNameplates()
    end
    if ns.QUI_RefreshNameplatePreview then
        ns.QUI_RefreshNameplatePreview()
    end
end

-- Deferred in-place section re-render (spell-list add/remove changes section
-- heights; RerenderFeature re-runs all sections + LayoutSections to reflow).
local function ScheduleSectionReflow(ctx)
    if type(ctx) ~= "table" or type(ctx.RerenderFeature) ~= "function" then
        return
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            ctx:RerenderFeature()
        end)
    else
        ctx:RerenderFeature()
    end
end

local function GetSpellNameById(spellId)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellId)
        if ok and name and name ~= "" then
            return name
        end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellId)
        if ok and name and name ~= "" then
            return name
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- SPELL-LIST EDITOR — compact, self-contained (numeric spell-ID input + Add,
-- one row per entry with a Remove button). Stores [spellID] = true maps.
-- Deliberately does NOT depend on GroupFrames' editor exports.
---------------------------------------------------------------------------
local function AddSpellListEditor(sectionHost, builder, ctx, listTable)
    local gui = GetGUI()
    local UIKit = ns.UIKit
    if not gui or type(listTable) ~= "table" then
        return
    end

    local function OnListChanged()
        RefreshNameplates()
        ScheduleSectionReflow(ctx)
    end

    -- Manual spell-ID input row.
    local inputRow = CreateFrame("Frame", nil, sectionHost)
    inputRow:SetHeight(24)
    inputRow:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, -builder.Height(0))
    inputRow:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, -builder.Height(0))

    local inputBox = CreateFrame("EditBox", nil, inputRow)
    inputBox:SetSize(90, 20)
    inputBox:SetPoint("LEFT", inputRow, "LEFT", 0, 0)
    inputBox:SetAutoFocus(false)
    inputBox:SetNumeric(true)
    inputBox:SetMaxLetters(10)
    inputBox:SetFontObject("GameFontNormalSmall")
    inputBox:SetTextInsets(4, 4, 0, 0)
    if UIKit and UIKit.CreateBackground and UIKit.CreateBorderLines and UIKit.UpdateBorderLines then
        UIKit.CreateBackground(inputBox, 0.06, 0.06, 0.08, 1)
        UIKit.CreateBorderLines(inputBox)
        UIKit.UpdateBorderLines(inputBox, 1, 1, 1, 1, 0.25, false)
    end
    inputBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local inputLabel = inputRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    inputLabel:SetPoint("LEFT", inputBox, "RIGHT", 6, 0)
    inputLabel:SetText(ns.L["Spell ID"])
    inputLabel:SetTextColor(0.5, 0.5, 0.5)

    local function CommitManual()
        local spellId = tonumber(inputBox:GetText())
        if spellId and spellId > 0 then
            listTable[spellId] = true
            inputBox:SetText("")
            inputBox:ClearFocus()
            OnListChanged()
        end
    end

    local addButton = gui:CreateButton(inputRow, ns.L["Add"], 60, 20, CommitManual)
    addButton:SetPoint("LEFT", inputLabel, "RIGHT", 8, 0)
    inputBox:SetScript("OnEnterPressed", CommitManual)

    builder.Spacer(28)

    -- One row per entry, sorted by spell ID.
    local ids = {}
    for id in pairs(listTable) do
        if type(id) == "number" then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local row = CreateFrame("Frame", nil, sectionHost)
        row:SetHeight(22)
        row:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, -builder.Height(0))
        row:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, -builder.Height(0))

        local removeButton = gui:CreateButton(row, ns.L["Remove"], 70, 18, function()
            listTable[id] = nil
            OnListChanged()
        end)
        removeButton:SetPoint("RIGHT", row, "RIGHT", 0, 0)

        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
        nameText:SetPoint("RIGHT", removeButton, "LEFT", -8, 0)
        nameText:SetJustifyH("LEFT")
        local name = GetSpellNameById(id)
        if name then
            nameText:SetText(string.format("%s (%d)", name, id))
        else
            nameText:SetText(tostring(id))
        end
        nameText:SetTextColor(0.8, 0.8, 0.8)

        builder.Spacer(24)
    end

    if #ids == 0 then
        builder.Description(ns.L["No spells added yet."])
    end
end

---------------------------------------------------------------------------
-- DISPLAY TAB SECTIONS
---------------------------------------------------------------------------
local function RenderEnableSection(sectionHost, ctx)
    local gui = GetGUI()
    local npdb = ResolveNameplatesDB()
    if not gui or not npdb then
        return nil
    end

    PrepareSectionHost(sectionHost, ctx)
    SetSearchContext(CreateSearchContext("display"))

    local enableCheck = gui:CreateFormCheckbox(
        sectionHost,
        ns.L["Enable QUI Nameplates (Req. Reload)"],
        "enabled",
        npdb,
        function()
            RefreshNameplates()
            gui:ShowConfirmation({
                title = ns.L["Reload UI?"],
                message = ns.L["Nameplates load at login: changing the enabled state requires a UI reload to install or remove the nameplate hooks."],
                acceptText = ns.L["Reload"],
                cancelText = ns.L["Later"],
                onAccept = function()
                    QUI:SafeReload()
                end,
            })
        end,
        { description = ns.L["Replace Blizzard's nameplates with QUI's custom nameplates. Requires a UI reload to take full effect."] }
    )
    enableCheck:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, -4)
    enableCheck:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, -4)

    return 64
end

-- Shared position controls for a text element: anchor point on the text,
-- attach point on the health bar, justification, and pixel offsets. Appends
-- three rows to `card`; each row is registered in `gatedRows` for the
-- enable-dimming pass.
local function AddTextPositionRows(gui, optionsAPI, card, tbl, refresh, gatedRows)
    local pointDropdown = gui:CreateFormDropdown(card.frame, nil, ANCHOR_POINT_OPTIONS, "point", tbl, refresh, {
        description = ns.L["Which point of the text is pinned."],
    })
    local relPointDropdown = gui:CreateFormDropdown(card.frame, nil, ANCHOR_POINT_OPTIONS, "relativePoint", tbl, refresh, {
        description = ns.L["Which point of the health bar the text pins to."],
    })
    local pointRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Anchor"], pointDropdown)
    local relPointRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Attach To"], relPointDropdown)
    card.AddRow(pointRow, relPointRow)

    local offsetXSlider = gui:CreateFormSlider(card.frame, nil, -100, 100, 1, "offsetX", tbl, refresh, { deferOnDrag = true }, {
        description = ns.L["Horizontal offset from the anchor, in pixels."],
    })
    local offsetYSlider = gui:CreateFormSlider(card.frame, nil, -100, 100, 1, "offsetY", tbl, refresh, { deferOnDrag = true }, {
        description = ns.L["Vertical offset from the anchor, in pixels."],
    })
    local offsetXRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Offset X"], offsetXSlider)
    local offsetYRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Offset Y"], offsetYSlider)
    card.AddRow(offsetXRow, offsetYRow)

    local justifyDropdown = gui:CreateFormDropdown(card.frame, nil, JUSTIFY_OPTIONS, "justify", tbl, refresh, {
        description = ns.L["Horizontal alignment of the text."],
    })
    local justifyRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Justify"], justifyDropdown)
    card.AddRow(justifyRow)

    if gatedRows then
        gatedRows[#gatedRows + 1] = pointRow
        gatedRows[#gatedRows + 1] = relPointRow
        gatedRows[#gatedRows + 1] = offsetXRow
        gatedRows[#gatedRows + 1] = offsetYRow
        gatedRows[#gatedRows + 1] = justifyRow
    end
end

local function RenderHealthSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local health = EnsureSubTable(npdb, "health")
    local healthText = EnsureSubTable(npdb, "healthText")
    if not health or not healthText then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("display"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Health Bar"])
    builder.Description(ns.L["Bar dimensions and styling. The hitbox below scales relative to these dimensions."])

    local barCard = builder.Card()
    local widthSlider = gui:CreateFormSlider(barCard.frame, nil, 60, 300, 1, "width", health, refresh, { deferOnDrag = true }, {
        description = ns.L["Health bar width in pixels."],
    })
    local heightSlider = gui:CreateFormSlider(barCard.frame, nil, 4, 40, 1, "height", health, refresh, { deferOnDrag = true }, {
        description = ns.L["Health bar height in pixels."],
    })
    barCard.AddRow(
        optionsAPI.BuildSettingRow(barCard.frame, ns.L["Width"], widthSlider),
        optionsAPI.BuildSettingRow(barCard.frame, ns.L["Height"], heightSlider)
    )

    local textureDropdown = gui:CreateFormDropdown(barCard.frame, nil, optionsAPI.GetTextureList(), "texture", health, refresh, {
        description = ns.L["Statusbar texture used for the health bar and cast bar."],
    })
    local borderSlider = gui:CreateFormSlider(barCard.frame, nil, 0, 4, 1, "borderSize", health, refresh, { deferOnDrag = true }, {
        description = ns.L["Pixel thickness of the plate border. 0 hides it."],
    })
    barCard.AddRow(
        optionsAPI.BuildSettingRow(barCard.frame, ns.L["Texture"], textureDropdown),
        optionsAPI.BuildSettingRow(barCard.frame, ns.L["Border Size"], borderSlider)
    )

    local bgColorPicker = gui:CreateFormColorPicker(barCard.frame, nil, "bgColor", health, refresh, { noAlpha = true }, {
        description = ns.L["Background color behind the health fill."],
    })
    local bgAlphaSlider = gui:CreateFormSlider(barCard.frame, nil, 0, 1, 0.05, "bgAlpha", health, refresh, { deferOnDrag = true }, {
        description = ns.L["Opacity of the health bar background."],
    })
    barCard.AddRow(
        optionsAPI.BuildSettingRow(barCard.frame, ns.L["Background Color"], bgColorPicker),
        optionsAPI.BuildSettingRow(barCard.frame, ns.L["Background Opacity"], bgAlphaSlider)
    )
    builder.CloseCard(barCard)

    builder.Spacer(14)
    builder.Header(ns.L["Health Text"])
    local textCard = builder.Card()
    local textRows = {}
    local function UpdateTextRows()
        local alpha = healthText.enabled ~= false and 1.0 or 0.4
        for _, row in ipairs(textRows) do
            row:SetAlpha(alpha)
        end
    end

    local textToggle = gui:CreateFormCheckbox(textCard.frame, nil, "enabled", healthText, function()
        refresh()
        UpdateTextRows()
    end, {
        description = ns.L["Show a health value on the bar."],
    })
    local styleDropdown = gui:CreateFormDropdown(textCard.frame, nil, HEALTH_TEXT_STYLE_OPTIONS, "style", healthText, refresh, {
        description = ns.L["Percentage, absolute value, or both."],
    })
    local styleRow = optionsAPI.BuildSettingRow(textCard.frame, ns.L["Style"], styleDropdown)
    textRows[#textRows + 1] = styleRow
    textCard.AddRow(
        optionsAPI.BuildSettingRow(textCard.frame, ns.L["Show Health Text"], textToggle),
        styleRow
    )

    local textSizeSlider = gui:CreateFormSlider(textCard.frame, nil, 6, 24, 1, "size", healthText, refresh, { deferOnDrag = true }, {
        description = ns.L["Font size of the health text."],
    })
    local textSizeRow = optionsAPI.BuildSettingRow(textCard.frame, ns.L["Font Size"], textSizeSlider)
    textRows[#textRows + 1] = textSizeRow
    local hidePercentCheckbox = gui:CreateFormCheckbox(textCard.frame, nil, "hidePercentSymbol", healthText, refresh, {
        description = ns.L["Drop the % symbol from percentage health text."],
    })
    local hidePercentRow = optionsAPI.BuildSettingRow(textCard.frame, ns.L["Hide Percent Symbol"], hidePercentCheckbox)
    textRows[#textRows + 1] = hidePercentRow
    textCard.AddRow(textSizeRow, hidePercentRow)
    AddTextPositionRows(gui, optionsAPI, textCard, healthText, refresh, textRows)
    UpdateTextRows()
    builder.CloseCard(textCard)

    return builder.Height()
end

local function RenderNameSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local name = EnsureSubTable(npdb, "name")
    if not name then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("display"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Name"])
    local card = builder.Card()
    local nameRows = {}
    local function UpdateNameRows()
        local alpha = name.enabled ~= false and 1.0 or 0.4
        for _, row in ipairs(nameRows) do
            row:SetAlpha(alpha)
        end
    end

    local nameToggle = gui:CreateFormCheckbox(card.frame, nil, "enabled", name, function()
        refresh()
        UpdateNameRows()
    end, {
        description = ns.L["Show the unit name above the health bar."],
    })
    local nameSizeSlider = gui:CreateFormSlider(card.frame, nil, 6, 24, 1, "size", name, refresh, { deferOnDrag = true }, {
        description = ns.L["Font size of the name text."],
    })
    local nameSizeRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Font Size"], nameSizeSlider)
    nameRows[#nameRows + 1] = nameSizeRow
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Show Name"], nameToggle),
        nameSizeRow
    )

    local classColorCheckbox = gui:CreateFormCheckbox(card.frame, nil, "classColorPlayers", name, refresh, {
        description = ns.L["Color enemy player names by class."],
    })
    local classColorRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Class Color Players"], classColorCheckbox)
    nameRows[#nameRows + 1] = classColorRow
    card.AddRow(classColorRow)
    AddTextPositionRows(gui, optionsAPI, card, name, refresh, nameRows)
    UpdateNameRows()
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderCastbarSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local castbar = EnsureSubTable(npdb, "castbar")
    if not castbar then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("castbars"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Cast Bar"])
    builder.Description(ns.L["Cast bar below the health bar. Cast state colors live on the Colors tab."])
    local card = builder.Card()
    local castRows = {}
    local function UpdateCastRows()
        local alpha = castbar.enabled ~= false and 1.0 or 0.4
        for _, row in ipairs(castRows) do
            row:SetAlpha(alpha)
        end
    end
    local function AddGatedRow(label, widget)
        local row = optionsAPI.BuildSettingRow(card.frame, label, widget)
        castRows[#castRows + 1] = row
        return row
    end

    local enableToggle = gui:CreateFormCheckbox(card.frame, nil, "enabled", castbar, function()
        refresh()
        UpdateCastRows()
    end, {
        description = ns.L["Show a cast bar on enemy nameplates."],
    })
    local heightSlider = gui:CreateFormSlider(card.frame, nil, 4, 40, 1, "height", castbar, refresh, { deferOnDrag = true }, {
        description = ns.L["Cast bar height in pixels."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Show Cast Bar"], enableToggle),
        AddGatedRow(ns.L["Height"], heightSlider)
    )

    local gapSlider = gui:CreateFormSlider(card.frame, nil, -10, 20, 1, "gap", castbar, refresh, { deferOnDrag = true }, {
        description = ns.L["Vertical gap between the cast bar and the health bar."],
    })
    local iconToggle = gui:CreateFormCheckbox(card.frame, nil, "showIcon", castbar, refresh, {
        description = ns.L["Show the spell icon beside the cast bar."],
    })
    card.AddRow(
        AddGatedRow(ns.L["Gap"], gapSlider),
        AddGatedRow(ns.L["Show Icon"], iconToggle)
    )

    local timerToggle = gui:CreateFormCheckbox(card.frame, nil, "showTimer", castbar, refresh, {
        description = ns.L["Show the remaining cast time."],
    })
    local spellNameToggle = gui:CreateFormCheckbox(card.frame, nil, "showSpellName", castbar, refresh, {
        description = ns.L["Show the name of the spell being cast."],
    })
    card.AddRow(
        AddGatedRow(ns.L["Show Timer"], timerToggle),
        AddGatedRow(ns.L["Show Spell Name"], spellNameToggle)
    )

    local nameSizeSlider = gui:CreateFormSlider(card.frame, nil, 6, 24, 1, "nameSize", castbar, refresh, { deferOnDrag = true }, {
        description = ns.L["Font size of the spell name text."],
    })
    local timerSizeSlider = gui:CreateFormSlider(card.frame, nil, 6, 24, 1, "timerSize", castbar, refresh, { deferOnDrag = true }, {
        description = ns.L["Font size of the cast timer text."],
    })
    card.AddRow(
        AddGatedRow(ns.L["Spell Name Size"], nameSizeSlider),
        AddGatedRow(ns.L["Timer Size"], timerSizeSlider)
    )

    local holdSlider = gui:CreateFormSlider(card.frame, nil, 0, 3, 0.1, "interruptedHoldTime", castbar, refresh, { deferOnDrag = true }, {
        description = ns.L["Seconds the interrupted state stays visible before the cast bar hides."],
    })
    card.AddRow(AddGatedRow(ns.L["Interrupted Hold Time"], holdSlider))

    local kickTickToggle = gui:CreateFormCheckbox(card.frame, nil, "kickTick", castbar, refresh, {
        description = ns.L["Mark where your interrupt comes off cooldown on the cast timeline. The marker converges on the cast edge as your kick becomes ready."],
    })
    local liftToggle = gui:CreateFormCheckbox(card.frame, nil, "liftOverlay", castbar, refresh, {
        description = ns.L["Render cast bars above neighboring nameplates so stacked plates never cover an active cast."],
    })
    card.AddRow(
        AddGatedRow(ns.L["Interrupt Ready Tick"], kickTickToggle),
        AddGatedRow(ns.L["Lift Above Other Plates"], liftToggle)
    )
    UpdateCastRows()
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderExtrasSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local absorbs = EnsureSubTable(npdb, "absorbs")
    local raidMarker = EnsureSubTable(npdb, "raidMarker")
    if not absorbs or not raidMarker then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("display"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Absorbs"])
    local absorbCard = builder.Card()
    local absorbRows = {}
    local function UpdateAbsorbRows()
        local alpha = absorbs.enabled ~= false and 1.0 or 0.4
        for _, row in ipairs(absorbRows) do
            row:SetAlpha(alpha)
        end
    end

    local absorbToggle = gui:CreateFormCheckbox(absorbCard.frame, nil, "enabled", absorbs, function()
        refresh()
        UpdateAbsorbRows()
    end, {
        description = ns.L["Show an absorb shield overlay on the health bar."],
    })
    local absorbColorPicker = gui:CreateFormColorPicker(absorbCard.frame, nil, "color", absorbs, refresh, { noAlpha = true }, {
        description = ns.L["Tint of the absorb overlay."],
    })
    local absorbColorRow = optionsAPI.BuildSettingRow(absorbCard.frame, ns.L["Absorb Color"], absorbColorPicker)
    absorbRows[#absorbRows + 1] = absorbColorRow
    absorbCard.AddRow(
        optionsAPI.BuildSettingRow(absorbCard.frame, ns.L["Show Absorbs"], absorbToggle),
        absorbColorRow
    )

    local absorbOpacitySlider = gui:CreateFormSlider(absorbCard.frame, nil, 0, 1, 0.05, "opacity", absorbs, refresh, { deferOnDrag = true }, {
        description = ns.L["Opacity of the absorb overlay."],
    })
    local absorbOpacityRow = optionsAPI.BuildSettingRow(absorbCard.frame, ns.L["Absorb Opacity"], absorbOpacitySlider)
    absorbRows[#absorbRows + 1] = absorbOpacityRow
    absorbCard.AddRow(absorbOpacityRow)
    UpdateAbsorbRows()
    builder.CloseCard(absorbCard)

    builder.Spacer(14)
    builder.Header(ns.L["Raid Marker"])
    local markerCard = builder.Card()
    local markerRows = {}
    local function UpdateMarkerRows()
        local alpha = raidMarker.enabled ~= false and 1.0 or 0.4
        for _, row in ipairs(markerRows) do
            row:SetAlpha(alpha)
        end
    end

    local markerToggle = gui:CreateFormCheckbox(markerCard.frame, nil, "enabled", raidMarker, function()
        refresh()
        UpdateMarkerRows()
    end, {
        description = ns.L["Show the unit's raid target marker on the plate."],
    })
    local markerSizeSlider = gui:CreateFormSlider(markerCard.frame, nil, 8, 48, 1, "size", raidMarker, refresh, { deferOnDrag = true }, {
        description = ns.L["Raid marker icon size in pixels."],
    })
    local markerSizeRow = optionsAPI.BuildSettingRow(markerCard.frame, ns.L["Size"], markerSizeSlider)
    markerRows[#markerRows + 1] = markerSizeRow
    markerCard.AddRow(
        optionsAPI.BuildSettingRow(markerCard.frame, ns.L["Show Raid Marker"], markerToggle),
        markerSizeRow
    )

    local markerPositionDropdown = gui:CreateFormDropdown(markerCard.frame, nil, RAID_MARKER_POSITION_OPTIONS, "position", raidMarker, refresh, {
        description = ns.L["Where the raid marker sits relative to the health bar."],
    })
    local markerPositionRow = optionsAPI.BuildSettingRow(markerCard.frame, ns.L["Position"], markerPositionDropdown)
    markerRows[#markerRows + 1] = markerPositionRow
    markerCard.AddRow(markerPositionRow)
    UpdateMarkerRows()
    builder.CloseCard(markerCard)

    return builder.Height()
end

local AURA_CHANNELS = {
    { key = "debuffs", label = ns.L["Debuffs"] },
    { key = "buffs", label = ns.L["Buffs"] },
    { key = "cc", label = ns.L["Crowd Control"] },
}

local function RenderAuraRowsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local auras = EnsureSubTable(npdb, "auras")
    if not auras then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("auras"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Auras"])
    builder.Description(ns.L["Aura icon rows above the nameplate. Filtering and spell lists live on the Behavior tab."])

    local masterCard = builder.Card()
    local masterToggle = gui:CreateFormCheckbox(masterCard.frame, nil, "enabled", auras, refresh, {
        description = ns.L["Master switch for all nameplate aura rows."],
    })
    masterCard.AddRow(optionsAPI.BuildSettingRow(masterCard.frame, ns.L["Show Auras"], masterToggle))
    builder.CloseCard(masterCard)

    for _, channelDef in ipairs(AURA_CHANNELS) do
        local channel = EnsureSubTable(auras, channelDef.key)
        if channel then
            builder.Spacer(14)
            builder.Header(channelDef.label)
            local card = builder.Card()
            local channelRows = {}
            local function UpdateChannelRows()
                local alpha = channel.enabled ~= false and 1.0 or 0.4
                for _, row in ipairs(channelRows) do
                    row:SetAlpha(alpha)
                end
            end
            local function AddGatedRow(label, widget)
                local row = optionsAPI.BuildSettingRow(card.frame, label, widget)
                channelRows[#channelRows + 1] = row
                return row
            end

            local enableToggle = gui:CreateFormCheckbox(card.frame, nil, "enabled", channel, function()
                refresh()
                UpdateChannelRows()
            end, {
                description = string.format(ns.L["Show the %1$s row."], string.lower(channelDef.label)),
            })
            local sizeSlider = gui:CreateFormSlider(card.frame, nil, 12, 48, 1, "size", channel, refresh, { deferOnDrag = true }, {
                description = ns.L["Icon size in pixels."],
            })
            card.AddRow(
                optionsAPI.BuildSettingRow(card.frame, ns.L["Enable"], enableToggle),
                AddGatedRow(ns.L["Icon Size"], sizeSlider)
            )

            local limitSlider = gui:CreateFormSlider(card.frame, nil, 1, 10, 1, "limit", channel, refresh, { deferOnDrag = true }, {
                description = ns.L["Maximum number of icons shown on this row."],
            })
            local growthDropdown = gui:CreateFormDropdown(card.frame, nil, AURA_GROWTH_OPTIONS, "growth", channel, refresh, {
                description = ns.L["Direction the row grows as icons are added."],
            })
            card.AddRow(
                AddGatedRow(ns.L["Max Icons"], limitSlider),
                AddGatedRow(ns.L["Growth"], growthDropdown)
            )

            local spacingSlider = gui:CreateFormSlider(card.frame, nil, 0, 10, 1, "spacing", channel, refresh, { deferOnDrag = true }, {
                description = ns.L["Gap between icons in pixels."],
            })
            local textSizeSlider = gui:CreateFormSlider(card.frame, nil, 6, 20, 1, "textSize", channel, refresh, { deferOnDrag = true }, {
                description = ns.L["Font size of stack and duration text on the icons."],
            })
            card.AddRow(
                AddGatedRow(ns.L["Spacing"], spacingSlider),
                AddGatedRow(ns.L["Text Size"], textSizeSlider)
            )

            -- Row anchoring: row point → health bar point + pixel offsets.
            local pointDropdown = gui:CreateFormDropdown(card.frame, nil, ANCHOR_POINT_OPTIONS, "point", channel, refresh, {
                description = ns.L["Which point of the aura row is pinned."],
            })
            local relPointDropdown = gui:CreateFormDropdown(card.frame, nil, ANCHOR_POINT_OPTIONS, "relativePoint", channel, refresh, {
                description = ns.L["Which point of the health bar the row pins to."],
            })
            card.AddRow(
                AddGatedRow(ns.L["Anchor"], pointDropdown),
                AddGatedRow(ns.L["Attach To"], relPointDropdown)
            )

            local offsetXSlider = gui:CreateFormSlider(card.frame, nil, -100, 100, 1, "offsetX", channel, refresh, { deferOnDrag = true }, {
                description = ns.L["Horizontal offset from the anchor, in pixels."],
            })
            local offsetYSlider = gui:CreateFormSlider(card.frame, nil, -100, 100, 1, "offsetY", channel, refresh, { deferOnDrag = true }, {
                description = ns.L["Vertical offset from the anchor, in pixels."],
            })
            card.AddRow(
                AddGatedRow(ns.L["Offset X"], offsetXSlider),
                AddGatedRow(ns.L["Offset Y"], offsetYSlider)
            )
            UpdateChannelRows()
            builder.CloseCard(card)
        end
    end

    return builder.Height()
end

local function RenderHitboxSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local cvars = EnsureSubTable(npdb, "cvars")
    if not cvars then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("display"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Hitbox & Stacking"])
    builder.Description(ns.L["The clickable plate area, derived from the health bar size. One global size applies to all plates."])
    local card = builder.Card()

    local scaleXSlider = gui:CreateFormSlider(card.frame, nil, 50, 200, 5, "hitboxScaleX", cvars, refresh, { deferOnDrag = true }, {
        description = ns.L["Hitbox width as a percentage of the health bar width."],
    })
    local scaleYSlider = gui:CreateFormSlider(card.frame, nil, 50, 200, 5, "hitboxScaleY", cvars, refresh, { deferOnDrag = true }, {
        description = ns.L["Hitbox height as a percentage of the health bar height."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Hitbox Width Scale"], scaleXSlider),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Hitbox Height Scale"], scaleYSlider)
    )

    local visualizerToggle = gui:CreateFormCheckbox(card.frame, nil, "hitboxVisualizer", cvars, refresh, {
        description = ns.L["Draw the hitbox outline on every plate while tuning the scales."],
    })
    local stackingSpacingSlider = gui:CreateFormSlider(card.frame, nil, 0.5, 2, 0.05, "stackingSpacing", cvars, refresh, { deferOnDrag = true }, {
        description = ns.L["Multiplier on the vertical space plates keep when stacking."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Hitbox Visualizer"], visualizerToggle),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Stacking Spacing"], stackingSpacingSlider)
    )
    builder.CloseCard(card)

    return builder.Height()
end

---------------------------------------------------------------------------
-- COLORS TAB SECTIONS
---------------------------------------------------------------------------
local function RenderReactionColorsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local colors = EnsureSubTable(npdb, "colors")
    if not colors then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("colors"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Reaction Colors"])
    local card = builder.Card()

    local hostilePicker = gui:CreateFormColorPicker(card.frame, nil, "hostile", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for hostile units."],
    })
    local neutralPicker = gui:CreateFormColorPicker(card.frame, nil, "neutral", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for neutral units."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Hostile"], hostilePicker),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Neutral"], neutralPicker)
    )

    local friendlyPicker = gui:CreateFormColorPicker(card.frame, nil, "friendly", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for friendly units (bars mode)."],
    })
    local tappedPicker = gui:CreateFormColorPicker(card.frame, nil, "tapped", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for tapped units (another player's kill credit)."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Friendly"], friendlyPicker),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Tapped"], tappedPicker)
    )

    local questRows = {}
    local function UpdateQuestRows()
        local alpha = colors.questEnabled ~= false and 1.0 or 0.4
        for _, row in ipairs(questRows) do
            row:SetAlpha(alpha)
        end
    end
    local questToggle = gui:CreateFormCheckbox(card.frame, nil, "questEnabled", colors, function()
        refresh()
        UpdateQuestRows()
    end, {
        description = ns.L["Recolor plates of units that count for one of your active quests."],
    })
    local questPicker = gui:CreateFormColorPicker(card.frame, nil, "quest", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for quest units."],
    })
    local questColorRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Quest Color"], questPicker)
    questRows[#questRows + 1] = questColorRow
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Quest Units"], questToggle),
        questColorRow
    )

    local classColorToggle = gui:CreateFormCheckbox(card.frame, nil, "classColorEnemyPlayers", colors, refresh, {
        description = ns.L["Color enemy players' health bars by class instead of the hostile color."],
    })
    card.AddRow(optionsAPI.BuildSettingRow(card.frame, ns.L["Class Color Enemy Players"], classColorToggle))
    UpdateQuestRows()
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderCastColorsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local colors = EnsureSubTable(npdb, "colors")
    if not colors then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("colors"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Cast Colors"])
    local card = builder.Card()

    local interruptiblePicker = gui:CreateFormColorPicker(card.frame, nil, "castInterruptible", colors, refresh, { noAlpha = true }, {
        description = ns.L["Cast bar color while the cast can be interrupted."],
    })
    local uninterruptiblePicker = gui:CreateFormColorPicker(card.frame, nil, "castUninterruptible", colors, refresh, { noAlpha = true }, {
        description = ns.L["Cast bar color for uninterruptible casts."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Interruptible"], interruptiblePicker),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Uninterruptible"], uninterruptiblePicker)
    )

    local interruptedPicker = gui:CreateFormColorPicker(card.frame, nil, "castInterrupted", colors, refresh, { noAlpha = true }, {
        description = ns.L["Cast bar color after a successful interrupt."],
    })
    card.AddRow(optionsAPI.BuildSettingRow(card.frame, ns.L["Interrupted"], interruptedPicker))
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderThreatColorsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local colors = EnsureSubTable(npdb, "colors")
    if not colors then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("colors"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Threat"])
    builder.Description(ns.L["Role-aware threat coloring. Active in dungeons and raids; overrides reaction colors there."])
    local card = builder.Card()
    local threatRows = {}
    local function UpdateThreatRows()
        local alpha = colors.threatEnabled ~= false and 1.0 or 0.4
        for _, row in ipairs(threatRows) do
            row:SetAlpha(alpha)
        end
    end
    local function AddGatedRow(label, widget)
        local row = optionsAPI.BuildSettingRow(card.frame, label, widget)
        threatRows[#threatRows + 1] = row
        return row
    end

    local threatToggle = gui:CreateFormCheckbox(card.frame, nil, "threatEnabled", colors, function()
        refresh()
        UpdateThreatRows()
    end, {
        description = ns.L["Color enemy health bars by your threat standing, adjusted for your role."],
    })
    local tankHasAggroPicker = gui:CreateFormColorPicker(card.frame, nil, "tankHasAggro", colors, refresh, { noAlpha = true }, {
        description = ns.L["Tank: you hold aggro."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Threat Colors"], threatToggle),
        AddGatedRow(ns.L["Tank: Has Aggro"], tankHasAggroPicker)
    )

    local tankNoAggroPicker = gui:CreateFormColorPicker(card.frame, nil, "tankNoAggro", colors, refresh, { noAlpha = true }, {
        description = ns.L["Tank: you lost aggro."],
    })
    local offTankPicker = gui:CreateFormColorPicker(card.frame, nil, "offTankAggro", colors, refresh, { noAlpha = true }, {
        description = ns.L["Tank: another tank holds aggro."],
    })
    card.AddRow(
        AddGatedRow(ns.L["Tank: Lost Aggro"], tankNoAggroPicker),
        AddGatedRow(ns.L["Off-Tank Has Aggro"], offTankPicker)
    )

    local dpsHasAggroPicker = gui:CreateFormColorPicker(card.frame, nil, "dpsHasAggro", colors, refresh, { noAlpha = true }, {
        description = ns.L["DPS/Healer: you pulled aggro."],
    })
    local dpsNearAggroPicker = gui:CreateFormColorPicker(card.frame, nil, "dpsNearAggro", colors, refresh, { noAlpha = true }, {
        description = ns.L["DPS/Healer: your threat is getting close."],
    })
    card.AddRow(
        AddGatedRow(ns.L["DPS: Has Aggro"], dpsHasAggroPicker),
        AddGatedRow(ns.L["DPS: Near Aggro"], dpsNearAggroPicker)
    )
    UpdateThreatRows()
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderTargetFocusSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local colors = EnsureSubTable(npdb, "colors")
    local highlight = EnsureSubTable(npdb, "highlight")
    if not colors or not highlight then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("colors"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Target & Focus"])
    local overrideCard = builder.Card()

    local targetColorRow, focusColorRow
    local function UpdateOverrideRows()
        if targetColorRow then
            targetColorRow:SetAlpha(colors.targetEnabled == true and 1.0 or 0.4)
        end
        if focusColorRow then
            focusColorRow:SetAlpha(colors.focusEnabled ~= false and 1.0 or 0.4)
        end
    end

    local targetToggle = gui:CreateFormCheckbox(overrideCard.frame, nil, "targetEnabled", colors, function()
        refresh()
        UpdateOverrideRows()
    end, {
        description = ns.L["Recolor your current target's health bar."],
    })
    local targetPicker = gui:CreateFormColorPicker(overrideCard.frame, nil, "target", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for your current target."],
    })
    targetColorRow = optionsAPI.BuildSettingRow(overrideCard.frame, ns.L["Target Color"], targetPicker)
    overrideCard.AddRow(
        optionsAPI.BuildSettingRow(overrideCard.frame, ns.L["Color Target"], targetToggle),
        targetColorRow
    )

    local focusToggle = gui:CreateFormCheckbox(overrideCard.frame, nil, "focusEnabled", colors, function()
        refresh()
        UpdateOverrideRows()
    end, {
        description = ns.L["Recolor your focus unit's health bar."],
    })
    local focusPicker = gui:CreateFormColorPicker(overrideCard.frame, nil, "focus", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color for your focus unit."],
    })
    focusColorRow = optionsAPI.BuildSettingRow(overrideCard.frame, ns.L["Focus Color"], focusPicker)
    overrideCard.AddRow(
        optionsAPI.BuildSettingRow(overrideCard.frame, ns.L["Color Focus"], focusToggle),
        focusColorRow
    )
    UpdateOverrideRows()
    builder.CloseCard(overrideCard)

    builder.Spacer(14)
    builder.Header(ns.L["Highlight"])
    local highlightCard = builder.Card()
    local glowRows = {}
    local mouseoverRow
    local function UpdateHighlightRows()
        local glowAlpha = highlight.targetGlow ~= false and 1.0 or 0.4
        for _, row in ipairs(glowRows) do
            row:SetAlpha(glowAlpha)
        end
        if mouseoverRow then
            mouseoverRow:SetAlpha(highlight.mouseover ~= false and 1.0 or 0.4)
        end
    end

    local glowToggle = gui:CreateFormCheckbox(highlightCard.frame, nil, "targetGlow", highlight, function()
        refresh()
        UpdateHighlightRows()
    end, {
        description = ns.L["Glow border around your current target's plate."],
    })
    local glowColorPicker = gui:CreateFormColorPicker(highlightCard.frame, nil, "targetGlowColor", highlight, refresh, { noAlpha = true }, {
        description = ns.L["Color of the target glow."],
    })
    local glowColorRow = optionsAPI.BuildSettingRow(highlightCard.frame, ns.L["Glow Color"], glowColorPicker)
    glowRows[#glowRows + 1] = glowColorRow
    highlightCard.AddRow(
        optionsAPI.BuildSettingRow(highlightCard.frame, ns.L["Target Glow"], glowToggle),
        glowColorRow
    )

    local glowAlphaSlider = gui:CreateFormSlider(highlightCard.frame, nil, 0, 1, 0.05, "targetGlowAlpha", highlight, refresh, { deferOnDrag = true }, {
        description = ns.L["Opacity of the target glow."],
    })
    local glowAlphaRow = optionsAPI.BuildSettingRow(highlightCard.frame, ns.L["Glow Opacity"], glowAlphaSlider)
    glowRows[#glowRows + 1] = glowAlphaRow
    local mouseoverToggle = gui:CreateFormCheckbox(highlightCard.frame, nil, "mouseover", highlight, function()
        refresh()
        UpdateHighlightRows()
    end, {
        description = ns.L["Brighten the plate under your mouse cursor."],
    })
    highlightCard.AddRow(
        glowAlphaRow,
        optionsAPI.BuildSettingRow(highlightCard.frame, ns.L["Mouseover Highlight"], mouseoverToggle)
    )

    local mouseoverAlphaSlider = gui:CreateFormSlider(highlightCard.frame, nil, 0, 1, 0.05, "mouseoverAlpha", highlight, refresh, { deferOnDrag = true }, {
        description = ns.L["Strength of the mouseover highlight."],
    })
    mouseoverRow = optionsAPI.BuildSettingRow(highlightCard.frame, ns.L["Mouseover Intensity"], mouseoverAlphaSlider)
    highlightCard.AddRow(mouseoverRow)
    UpdateHighlightRows()
    builder.CloseCard(highlightCard)

    return builder.Height()
end

local function RenderCombatStateSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local colors = EnsureSubTable(npdb, "colors")
    if not colors then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("colors"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Out of Combat"])
    local oocCard = builder.Card()
    local oocFactorRow
    local function UpdateOocRows()
        if oocFactorRow then
            oocFactorRow:SetAlpha(colors.oocDarken ~= false and 1.0 or 0.4)
        end
    end

    local oocToggle = gui:CreateFormCheckbox(oocCard.frame, nil, "oocDarken", colors, function()
        refresh()
        UpdateOocRows()
    end, {
        description = ns.L["Darken hostile plates while the unit is out of combat."],
    })
    local oocFactorSlider = gui:CreateFormSlider(oocCard.frame, nil, 0.3, 1, 0.05, "oocDarkenFactor", colors, refresh, { deferOnDrag = true }, {
        description = ns.L["Multiplier applied to the bar color out of combat. Lower is darker."],
    })
    oocFactorRow = optionsAPI.BuildSettingRow(oocCard.frame, ns.L["Darken Factor"], oocFactorSlider)
    oocCard.AddRow(
        optionsAPI.BuildSettingRow(oocCard.frame, ns.L["Darken Out of Combat"], oocToggle),
        oocFactorRow
    )
    UpdateOocRows()
    builder.CloseCard(oocCard)

    builder.Spacer(14)
    builder.Header(ns.L["Execute Range"])
    local executeCard = builder.Card()
    local executeRows = {}
    local function UpdateExecuteRows()
        local alpha = colors.executeEnabled == true and 1.0 or 0.4
        for _, row in ipairs(executeRows) do
            row:SetAlpha(alpha)
        end
    end

    local executeToggle = gui:CreateFormCheckbox(executeCard.frame, nil, "executeEnabled", colors, function()
        refresh()
        UpdateExecuteRows()
    end, {
        description = ns.L["Recolor the health bar when the unit drops below the execute threshold."],
    })
    local executePicker = gui:CreateFormColorPicker(executeCard.frame, nil, "execute", colors, refresh, { noAlpha = true }, {
        description = ns.L["Health bar color inside execute range."],
    })
    local executeColorRow = optionsAPI.BuildSettingRow(executeCard.frame, ns.L["Execute Color"], executePicker)
    executeRows[#executeRows + 1] = executeColorRow
    executeCard.AddRow(
        optionsAPI.BuildSettingRow(executeCard.frame, ns.L["Execute Coloring"], executeToggle),
        executeColorRow
    )

    local thresholdSlider = gui:CreateFormSlider(executeCard.frame, nil, 5, 50, 1, "executeThreshold", colors, refresh, { deferOnDrag = true }, {
        description = ns.L["Health percentage below which the execute color applies."],
    })
    local thresholdRow = optionsAPI.BuildSettingRow(executeCard.frame, ns.L["Execute Threshold"], thresholdSlider)
    executeRows[#executeRows + 1] = thresholdRow
    executeCard.AddRow(thresholdRow)
    UpdateExecuteRows()
    builder.CloseCard(executeCard)

    return builder.Height()
end

---------------------------------------------------------------------------
-- BEHAVIOR TAB SECTIONS
---------------------------------------------------------------------------
local function RenderFriendlySection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local friendly = EnsureSubTable(npdb, "friendly")
    if not friendly then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("behavior"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Friendly Nameplates"])
    builder.Description(ns.L["In dungeons and raids, Blizzard protects friendly nameplates — bars mode falls back to name-only there."])
    local card = builder.Card()

    local modeDropdown = gui:CreateFormDropdown(card.frame, nil, FRIENDLY_MODE_OPTIONS, "mode", friendly, refresh, {
        description = ns.L["Name Only shows just names; Health Bars uses compact QUI bars; Off leaves friendly plates to Blizzard."],
    })
    local nameSizeSlider = gui:CreateFormSlider(card.frame, nil, 6, 24, 1, "nameSize", friendly, refresh, { deferOnDrag = true }, {
        description = ns.L["Font size of friendly names in name-only mode."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Mode"], modeDropdown),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Name Size"], nameSizeSlider)
    )

    local classColorToggle = gui:CreateFormCheckbox(card.frame, nil, "classColorNames", friendly, refresh, {
        description = ns.L["Color friendly player names by class."],
    })
    local barWidthSlider = gui:CreateFormSlider(card.frame, nil, 60, 300, 1, "barWidth", friendly, refresh, { deferOnDrag = true }, {
        description = ns.L["Friendly health bar width (bars mode)."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Class Color Names"], classColorToggle),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Bar Width"], barWidthSlider)
    )

    local barHeightSlider = gui:CreateFormSlider(card.frame, nil, 4, 30, 1, "barHeight", friendly, refresh, { deferOnDrag = true }, {
        description = ns.L["Friendly health bar height (bars mode)."],
    })
    local showWorldToggle = gui:CreateFormCheckbox(card.frame, nil, "showInWorld", friendly, refresh, {
        description = ns.L["Show friendly nameplates in the open world."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Bar Height"], barHeightSlider),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Show In World"], showWorldToggle)
    )

    local showInstancesToggle = gui:CreateFormCheckbox(card.frame, nil, "showInInstances", friendly, refresh, {
        description = ns.L["Show friendly nameplates in dungeons and raids (name-only; Blizzard protects the plates there)."],
    })
    card.AddRow(optionsAPI.BuildSettingRow(card.frame, ns.L["Show In Instances"], showInstancesToggle))
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderAuraBehaviorSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local auras = EnsureSubTable(npdb, "auras")
    if not auras then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("auras"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Aura Filtering"])
    builder.Description(ns.L["What the aura rows show. Row layout lives on the Display tab."])
    local card = builder.Card()

    local mineOnlyToggle = gui:CreateFormCheckbox(card.frame, nil, "mineOnly", auras, refresh, {
        description = ns.L["Only show debuffs you applied."],
    })
    local pandemicToggle = gui:CreateFormCheckbox(card.frame, nil, "pandemicGlow", auras, refresh, {
        description = ns.L["Glow important auras when they enter the pandemic refresh window."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Only My Auras"], mineOnlyToggle),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Pandemic Glow"], pandemicToggle)
    )

    local dispelToggle = gui:CreateFormCheckbox(card.frame, nil, "dispelBorders", auras, refresh, {
        description = ns.L["Color aura icon borders by dispel type."],
    })
    local importantScaleSlider = gui:CreateFormSlider(card.frame, nil, 1, 2, 0.05, "importantScale", auras, refresh, { deferOnDrag = true }, {
        description = ns.L["Size multiplier for auras on the important list."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Dispel Borders"], dispelToggle),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Important Aura Scale"], importantScaleSlider)
    )

    local worldToggle = gui:CreateFormCheckbox(card.frame, nil, "enableWorld", auras, refresh, {
        description = ns.L["Show aura rows in the open world."],
    })
    local dungeonToggle = gui:CreateFormCheckbox(card.frame, nil, "enableDungeon", auras, refresh, {
        description = ns.L["Show aura rows in dungeons."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Auras In World"], worldToggle),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Auras In Dungeons"], dungeonToggle)
    )

    local raidToggle = gui:CreateFormCheckbox(card.frame, nil, "enableRaid", auras, refresh, {
        description = ns.L["Show aura rows in raids."],
    })
    card.AddRow(optionsAPI.BuildSettingRow(card.frame, ns.L["Auras In Raids"], raidToggle))
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderSpellListsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local auras = EnsureSubTable(npdb, "auras")
    if not auras then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("auras"))
    if not builder then
        return nil
    end

    builder.Header(ns.L["Important Auras"])
    builder.Description(ns.L["Important auras render larger (see Important Aura Scale) and can pandemic-glow."])
    if type(auras.importantList) ~= "table" then
        auras.importantList = {}
    end
    AddSpellListEditor(sectionHost, builder, ctx, auras.importantList)

    for _, channelDef in ipairs(AURA_CHANNELS) do
        local channel = EnsureSubTable(auras, channelDef.key)
        if channel then
            if type(channel.allowList) ~= "table" then
                channel.allowList = {}
            end
            if type(channel.blockList) ~= "table" then
                channel.blockList = {}
            end

            builder.Spacer(14)
            builder.Header(string.format(ns.L["%1$s — Allow List"], channelDef.label))
            builder.Description(ns.L["When this list has entries, ONLY these spells show on the row."])
            AddSpellListEditor(sectionHost, builder, ctx, channel.allowList)

            builder.Spacer(14)
            builder.Header(string.format(ns.L["%1$s — Block List"], channelDef.label))
            builder.Description(ns.L["These spells are always hidden from the row."])
            AddSpellListEditor(sectionHost, builder, ctx, channel.blockList)
        end
    end

    return builder.Height()
end

local function RenderCVarsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local cvars = EnsureSubTable(npdb, "cvars")
    if not cvars then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("behavior"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Nameplate CVars"])
    builder.Description(ns.L["Client-level nameplate variables. QUI owns these while nameplates are enabled; combat changes apply after combat ends."])
    local card = builder.Card()

    local distanceSlider = gui:CreateFormSlider(card.frame, nil, 10, 60, 1, "maxDistance", cvars, refresh, { deferOnDrag = true }, {
        description = ns.L["Maximum distance (yards) at which nameplates are visible."],
    })
    local stackEnemyToggle = gui:CreateFormCheckbox(card.frame, nil, "stackingEnemy", cvars, refresh, {
        description = ns.L["Stack enemy plates instead of letting them overlap."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Max Distance"], distanceSlider),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Stack Enemy Plates"], stackEnemyToggle)
    )

    local stackFriendlyToggle = gui:CreateFormCheckbox(card.frame, nil, "stackingFriendly", cvars, refresh, {
        description = ns.L["Stack friendly plates instead of letting them overlap."],
    })
    card.AddRow(optionsAPI.BuildSettingRow(card.frame, ns.L["Stack Friendly Plates"], stackFriendlyToggle))
    builder.CloseCard(card)

    return builder.Height()
end

local function RenderSpecPresetsSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    -- Nil when the runtime module isn't loaded (e.g. the offline search-cache
    -- generator): the auto-switch toggle still renders/indexes; only the
    -- per-spec Save/Apply/Clear rows need the module.
    local Presets = ns.QUI_Nameplates and ns.QUI_Nameplates.Presets

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("behavior"))
    if not builder then
        return nil
    end

    builder.Header(ns.L["Spec & Role Presets"])
    builder.Description(ns.L["Save the current nameplate settings as a preset. Spec presets live in this profile; role presets are account-wide — every character shares them. With auto-switch on, changing spec (or logging in) applies the matching preset; a spec preset wins over a role preset."])
    local card = builder.Card()

    local autoToggle = gui:CreateFormCheckbox(card.frame, nil, "specAutoSwitch", npdb, RefreshNameplates, {
        description = ns.L["Automatically apply the saved spec preset when you change specialization."],
    })
    -- Role auto-switch lives account-wide (db.global); bind a dummy when the
    -- runtime module isn't loaded (offline search-cache capture).
    local roleStore = (Presets and Presets.GetRoleStore and Presets.GetRoleStore()) or { autoSwitch = false }
    local roleAutoToggle = gui:CreateFormCheckbox(card.frame, nil, "autoSwitch", roleStore, RefreshNameplates, {
        description = ns.L["Account-wide: any character switching to a tank, healer, or damage spec applies that role's preset."],
    })
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Auto-switch on spec change"], autoToggle),
        optionsAPI.BuildSettingRow(card.frame, ns.L["Auto-switch by role (account-wide)"], roleAutoToggle)
    )
    builder.CloseCard(card)
    builder.Spacer(8)

    if not Presets then
        return builder.Height()
    end

    -- Shared Save / Apply / Clear row.
    local function AddPresetRow(labelText, saved, onSave, onApply, onClear)
        local row = CreateFrame("Frame", nil, sectionHost)
        row:SetHeight(26)
        row:SetPoint("TOPLEFT", sectionHost, "TOPLEFT", 0, -builder.Height(0))
        row:SetPoint("TOPRIGHT", sectionHost, "TOPRIGHT", 0, -builder.Height(0))
        builder.Spacer(30)

        local label = gui:CreateLabel(row, labelText .. (saved and (" |cFF34D399" .. ns.L["(saved)"] .. "|r") or ""), 12)
        label:SetPoint("LEFT", row, "LEFT", 4, 0)

        local saveBtn = gui:CreateButton(row, ns.L["Save"], 70, 20, function()
            onSave()
            ScheduleSectionReflow(ctx)
        end)
        saveBtn:SetPoint("LEFT", row, "LEFT", 200, 0)

        local applyBtn = gui:CreateButton(row, ns.L["Apply"], 70, 20, function()
            if onApply() then
                ScheduleSectionReflow(ctx)
            end
        end)
        applyBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)

        local clearBtn = gui:CreateButton(row, ns.L["Clear"], 70, 20, function()
            onClear()
            ScheduleSectionReflow(ctx)
        end)
        clearBtn:SetPoint("LEFT", applyBtn, "RIGHT", 8, 0)

        if not saved then
            if applyBtn.Disable then applyBtn:Disable() end
            if clearBtn.Disable then clearBtn:Disable() end
        end
    end

    -- One row per specialization of this character.
    local numSpecs = 0
    if GetNumSpecializations then
        local ok, n = pcall(GetNumSpecializations)
        if ok and type(n) == "number" then numSpecs = n end
    end
    for specIndex = 1, numSpecs do
        local specName = ns.L["Spec"] .. " " .. specIndex
        if GetSpecializationInfo then
            local ok, _, name = pcall(GetSpecializationInfo, specIndex)
            if ok and type(name) == "string" and name ~= "" then
                specName = name
            end
        end
        AddPresetRow(specName, Presets.HasPreset(specIndex),
            function() Presets.SaveForSpec(specIndex) end,
            function() return Presets.ApplyForSpec(specIndex) end,
            function() Presets.ClearForSpec(specIndex) end)
    end

    -- One row per role (account-wide storage).
    builder.Spacer(6)
    local ROLE_ROWS = {
        { role = "TANK", label = ns.L["Tank (all characters)"] },
        { role = "HEALER", label = ns.L["Healer (all characters)"] },
        { role = "DAMAGER", label = ns.L["Damage (all characters)"] },
    }
    for _, def in ipairs(ROLE_ROWS) do
        local role = def.role
        AddPresetRow(def.label, Presets.HasRolePreset(role),
            function() Presets.SaveForRole(role) end,
            function() return Presets.ApplyForRole(role) end,
            function() Presets.ClearForRole(role) end)
    end

    return builder.Height()
end

local function RenderAuraDurationSection(sectionHost, ctx)
    local gui = GetGUI()
    local optionsAPI = GetOptionsAPI()
    local npdb = ResolveNameplatesDB()
    if not gui or not optionsAPI or not npdb then
        return nil
    end

    local auras = EnsureSubTable(npdb, "auras")
    if not auras then
        return nil
    end
    local duration = EnsureSubTable(auras, "duration")
    if not duration then
        return nil
    end

    local builder = CreateSectionBuilder(sectionHost, ctx, CreateSearchContext("auras"))
    if not builder then
        return nil
    end

    local refresh = RefreshNameplates

    builder.Header(ns.L["Duration Text"])
    builder.Description(ns.L["The countdown numbers on aura icons. The timer itself is engine-driven — these settings only style it."])
    local card = builder.Card()
    local durationRows = {}
    local function UpdateDurationRows()
        local alpha = duration.enabled ~= false and 1.0 or 0.4
        for _, row in ipairs(durationRows) do
            row:SetAlpha(alpha)
        end
    end

    local enableToggle = gui:CreateFormCheckbox(card.frame, nil, "enabled", duration, function()
        refresh()
        UpdateDurationRows()
    end, {
        description = ns.L["Show remaining duration on aura icons."],
    })
    local sizeSlider = gui:CreateFormSlider(card.frame, nil, 6, 24, 1, "size", duration, refresh, { deferOnDrag = true }, {
        description = ns.L["Font size of the duration text."],
    })
    local sizeRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Font Size"], sizeSlider)
    durationRows[#durationRows + 1] = sizeRow
    card.AddRow(
        optionsAPI.BuildSettingRow(card.frame, ns.L["Show Duration"], enableToggle),
        sizeRow
    )

    local pointDropdown = gui:CreateFormDropdown(card.frame, nil, ANCHOR_POINT_OPTIONS, "point", duration, refresh, {
        description = ns.L["Where the duration text sits on the icon."],
    })
    local pointRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Anchor"], pointDropdown)
    durationRows[#durationRows + 1] = pointRow
    local decimalsToggle = gui:CreateFormCheckbox(card.frame, nil, "decimals", duration, refresh, {
        description = ns.L["Show tenths of a second below 3 seconds."],
    })
    local decimalsRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Decimals Under 3s"], decimalsToggle)
    durationRows[#durationRows + 1] = decimalsRow
    card.AddRow(pointRow, decimalsRow)

    local offsetXSlider = gui:CreateFormSlider(card.frame, nil, -30, 30, 1, "offsetX", duration, refresh, { deferOnDrag = true }, {
        description = ns.L["Horizontal offset of the duration text, in pixels."],
    })
    local offsetYSlider = gui:CreateFormSlider(card.frame, nil, -30, 30, 1, "offsetY", duration, refresh, { deferOnDrag = true }, {
        description = ns.L["Vertical offset of the duration text, in pixels."],
    })
    local offsetXRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Offset X"], offsetXSlider)
    local offsetYRow = optionsAPI.BuildSettingRow(card.frame, ns.L["Offset Y"], offsetYSlider)
    durationRows[#durationRows + 1] = offsetXRow
    durationRows[#durationRows + 1] = offsetYRow
    card.AddRow(offsetXRow, offsetYRow)
    UpdateDurationRows()
    builder.CloseCard(card)

    return builder.Height()
end

---------------------------------------------------------------------------
-- FEATURES + EXPORTED TAB RENDERERS
---------------------------------------------------------------------------
local function CreateMultiSectionTabFeature(id, sectionDefs)
    local sectionIds = {}
    local sections = {}
    for i, def in ipairs(sectionDefs) do
        sectionIds[i] = def.id
        sections[i] = Schema.Section({
            id = def.id,
            kind = "custom",
            minHeight = def.minHeight,
            render = def.render,
        })
    end
    return Schema.Feature({
        id = id,
        surfaces = {
            nameplateTab = {
                sections = sectionIds,
                padding = 10,
                sectionGap = 14,
                topPadding = 10,
                bottomPadding = 40,
            },
        },
        sections = sections,
    })
end

local DISPLAY_TAB_FEATURE = CreateMultiSectionTabFeature("nameplatesDisplayTab", {
    { id = "enable", minHeight = 64, render = RenderEnableSection },
    { id = "health", minHeight = 260, render = RenderHealthSection },
    { id = "name", minHeight = 180, render = RenderNameSection },
    { id = "extras", minHeight = 180, render = RenderExtrasSection },
    { id = "hitbox", minHeight = 130, render = RenderHitboxSection },
})

local AURAS_TAB_FEATURE = CreateMultiSectionTabFeature("nameplatesAurasTab", {
    { id = "auraRows", minHeight = 260, render = RenderAuraRowsSection },
    { id = "auraDuration", minHeight = 180, render = RenderAuraDurationSection },
    { id = "auraBehavior", minHeight = 160, render = RenderAuraBehaviorSection },
    { id = "spellLists", minHeight = 300, render = RenderSpellListsSection },
})

local CASTBARS_TAB_FEATURE = CreateMultiSectionTabFeature("nameplatesCastbarsTab", {
    { id = "castbar", minHeight = 220, render = RenderCastbarSection },
})

local COLORS_TAB_FEATURE = CreateMultiSectionTabFeature("nameplatesColorsTab", {
    { id = "reaction", minHeight = 200, render = RenderReactionColorsSection },
    { id = "cast", minHeight = 120, render = RenderCastColorsSection },
    { id = "threat", minHeight = 160, render = RenderThreatColorsSection },
    { id = "targetFocus", minHeight = 220, render = RenderTargetFocusSection },
    { id = "combatState", minHeight = 180, render = RenderCombatStateSection },
})

local BEHAVIOR_TAB_FEATURE = CreateMultiSectionTabFeature("nameplatesBehaviorTab", {
    { id = "friendly", minHeight = 200, render = RenderFriendlySection },
    { id = "specPresets", minHeight = 160, render = RenderSpecPresetsSection },
    { id = "cvarsSection", minHeight = 130, render = RenderCVarsSection },
})

local function RenderFeatureTab(feature, host)
    if not host then
        return false
    end

    local npdb = ResolveNameplatesDB()
    if not npdb then
        return false
    end

    local width = host.GetWidth and host:GetWidth() or 0
    if type(width) ~= "number" or width <= 0 then
        width = 760
    end

    return Renderer:RenderFeature(feature, host, {
        surface = "nameplateTab",
        width = width,
    })
end

function NameplatesSchema.RenderDisplayTab(host)
    return RenderFeatureTab(DISPLAY_TAB_FEATURE, host)
end

function NameplatesSchema.RenderAurasTab(host)
    return RenderFeatureTab(AURAS_TAB_FEATURE, host)
end

function NameplatesSchema.RenderCastbarsTab(host)
    return RenderFeatureTab(CASTBARS_TAB_FEATURE, host)
end

function NameplatesSchema.RenderColorsTab(host)
    return RenderFeatureTab(COLORS_TAB_FEATURE, host)
end

function NameplatesSchema.RenderBehaviorTab(host)
    return RenderFeatureTab(BEHAVIOR_TAB_FEATURE, host)
end
