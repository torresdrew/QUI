local ADDON_NAME, ns = ...
local function CJKFont(fs, p, s, f)
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(fs, p, s, f)
    else
        fs:SetFont(p, s, f)
    end
end

-- Shared aura element editor: renders the element list for a single spec bucket
-- of auras.elements (the unified core/aura_elements.lua model). Each element is
-- a filterStrip (Buffs/Debuffs), a tracked element (icon/square/bar/tint), or a
-- missing-raid-buff watcher. The surface's capabilities table (opts.capabilities)
-- gates which element types / display types / controls are offered so unit
-- frames, buff borders and group frames can share ONE editor.
--
-- Moved from QUI_GroupFrames/groupframes/settings/group_frames_auras_editor.lua
-- and generalized. The model import is now ns.AuraElements (the shared core
-- model) — never the group-frames model shim.

local E = ns.AuraElements
local SpellList = ns.QUI_AuraSpellList
local SkinBase = ns.SkinBase
local MissingRaidBuffs = ns.QUI_GroupFrameMissingRaidBuffs

local AurasEditor = ns.QUI_AuraElementsEditor or {}
ns.QUI_AuraElementsEditor = AurasEditor

local FORM_ROW = 32
local PAD = 10
local COL_GAP = 12
local ROW_HEIGHT = 30
local ROW_STEP = 32
local SUGGEST_CELL_SIZE = 36
local SUGGEST_ICON_SIZE = 28
local SUGGEST_CELL_GAP = 2
local SUGGEST_CELL_STRIDE = SUGGEST_CELL_SIZE + SUGGEST_CELL_GAP
local FALLBACK_ICON = 134400

local NINE_POINT_OPTIONS = {
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

local AURA_GROW_OPTIONS = {
    { value = "LEFT", text = ns.L["Left"] },
    { value = "RIGHT", text = ns.L["Right"] },
    { value = "CENTER", text = ns.L["Center"] },
    { value = "UP", text = ns.L["Up"] },
    { value = "DOWN", text = ns.L["Down"] },
}

-- Filter mode. "off" rides the bare polarity; "flags" AND-composes raw
-- AuraFilters tokens onto one filter string; "classify" (the canonical value —
-- core E.CompileFilters keys on it; legacy "classification" is migrated to it)
-- fans out one filter per ticked classification.
local FILTER_MODE_OPTIONS = {
    { value = "off", text = ns.L["Off (Show All)"] },
    { value = "flags", text = ns.L["Filter Flags"] },
    { value = "classify", text = ns.L["Classification"] },
}

local AURA_TYPE_OPTIONS = {
    { value = "HELPFUL", text = ns.L["Buffs (Helpful)"] },
    { value = "HARMFUL", text = ns.L["Debuffs (Harmful)"] },
}

local TRACKED_DISPLAY_OPTIONS_ALL = {
    { value = "icon", text = ns.L["Icon"] },
    { value = "square", text = ns.L["Colored Square"] },
    { value = "bar", text = ns.L["Bar"] },
    { value = "healthTint", text = ns.L["Health Bar Tint"] },
}

-- Container sort rules → AuraContainerSortMethod (see core/aura_glue.lua).
local SORT_OPTIONS = {
    { value = "INDEX", text = ns.L["Default Order"] },
    { value = "EXPIRY", text = ns.L["Expiration"] },
    { value = "EXPIRY_ONLY", text = ns.L["Expiration Only"] },
    { value = "NAME", text = ns.L["Name"] },
    { value = "NAME_ONLY", text = ns.L["Name Only"] },
    { value = "BIG_DEFENSIVE", text = ns.L["Big Defensives First"] },
}

local HEALTH_TINT_ANIMATION_OPTIONS = {
    { value = "fill", text = ns.L["Soft Fill"] },
    { value = "fade", text = ns.L["Soft Fade"] },
    { value = "fillFade", text = ns.L["Fill + Fade"] },
    { value = "pulse", text = ns.L["Subtle Pulse"] },
    { value = "instant", text = ns.L["Instant"] },
}

local SWIPE_STYLE_OPTIONS = {
    { value = "radial", text = ns.L["Radial"] },
    { value = "horizontal", text = ns.L["Horizontal"] },
    { value = "vertical", text = ns.L["Vertical"] },
}

local MISSING_RAID_BUFF_OPTIONS = {
    { key = "intellect", label = ns.L["Arcane Intellect (Mage)"] },
    { key = "stamina", label = ns.L["Power Word: Fortitude (Priest)"] },
    { key = "attackPower", label = ns.L["Battle Shout (Warrior)"] },
    { key = "versatility", label = ns.L["Mark of the Wild (Druid)"] },
    { key = "skyfury", label = ns.L["Skyfury (Shaman)"] },
    { key = "bronze", label = ns.L["Blessing of the Bronze (Evoker)"] },
}

-- Buff/debuff classification options, keyed by aura type.
local HELPFUL_CLASSIFICATIONS = {
    { key = "raid", label = ns.L["Raid"] },
    { key = "raidInCombat", label = ns.L["Raid (In Combat)"] },
    { key = "cancelable", label = ns.L["Cancelable"] },
    { key = "notCancelable", label = ns.L["Not Cancelable"] },
    { key = "bigDefensive", label = ns.L["Big Defensive"] },
    { key = "externalDefensive", label = ns.L["External Defensive"] },
}

local HARMFUL_CLASSIFICATIONS = {
    { key = "raid", label = ns.L["Raid"] },
    -- No raidInCombat: RAID_IN_COMBAT is a HELPFUL-only aura filter.
    { key = "crowdControl", label = ns.L["Crowd Control"] },
}

-- Raw AuraFilters tokens offered in "flags" mode, per aura type. HELPFUL-only
-- tokens are never offered on HARMFUL (a "HARMFUL|RAID_IN_COMBAT"-class combo
-- hard-errors in C_UnitAuras; the model also drops them defensively).
local HELPFUL_FLAG_TOKENS = {
    { token = "PLAYER", label = ns.L["Player"] },
    { token = "RAID", label = ns.L["Raid"] },
    { token = "CANCELABLE", label = ns.L["Cancelable"] },
    { token = "NOT_CANCELABLE", label = ns.L["Not Cancelable"] },
    { token = "BIG_DEFENSIVE", label = ns.L["Big Defensive"] },
    { token = "EXTERNAL_DEFENSIVE", label = ns.L["External Defensive"] },
}

local HARMFUL_FLAG_TOKENS = {
    { token = "PLAYER", label = ns.L["Player"] },
    { token = "RAID", label = ns.L["Raid"] },
    { token = "INCLUDE_NAME_PLATE_ONLY", label = ns.L["Nameplate Auras Only"] },
    { token = "RAID_PLAYER_DISPELLABLE", label = ns.L["Dispellable by Me"] },
    { token = "CROWD_CONTROL", label = ns.L["Crowd Control"] },
}

-- Full GF capability set. Used as the default when opts.capabilities is nil so
-- the GF mount (and anything mid-migration) keeps working. defaultBucketFn and
-- suggestions resolve lazily from the GF defaults module (always loaded by the
-- time RenderAuras runs), so this file carries no load-order dependency on it.
local function DefaultCapabilities()
    local AuraDefaults = ns.QUI_GroupFramesAuraDefaults
    return {
        elementTypes        = { filterStrip = true, tracked = true, missingRaidBuff = true },
        trackedDisplayTypes = { icon = true, square = true, bar = true, healthTint = true },
        cancelEligible      = false,
        maxStripElements    = 4,
        allowSpecOverride   = true,
        defaultBucketFn     = AuraDefaults and AuraDefaults.DefaultStripBucket or nil,
        suggestions         = AuraDefaults and AuraDefaults.GetSuggestionSpells or nil,
    }
end

local function ResolveCapabilities(opts)
    local caps = type(opts) == "table" and opts.capabilities
    if type(caps) ~= "table" then
        return DefaultCapabilities()
    end
    caps.elementTypes = caps.elementTypes or {}
    caps.trackedDisplayTypes = caps.trackedDisplayTypes or {}
    return caps
end

local function BuildTrackedDisplayOptions(trackedDisplayTypes)
    local out = {}
    for _, opt in ipairs(TRACKED_DISPLAY_OPTIONS_ALL) do
        if not trackedDisplayTypes or trackedDisplayTypes[opt.value] then
            out[#out + 1] = opt
        end
    end
    if #out == 0 then out[1] = TRACKED_DISPLAY_OPTIONS_ALL[1] end
    return out
end

local function DefaultTrackedDisplay(caps)
    local t = caps and caps.trackedDisplayTypes
    if type(t) ~= "table" then return "icon" end
    for _, v in ipairs({ "icon", "square", "bar", "healthTint" }) do
        if t[v] then return v end
    end
    return "icon"
end

local function GetGUI()
    return QUI and QUI.GUI or nil
end

-- Shared options API (BuildSettingRow lives here). ns is the suite-wide
-- namespace, so this resolves the same object the schema's GetOptionsAPI uses.
local function GetOptionsAPI()
    return ns.QUI_Options
end

local function GetSpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and name and name ~= "" then
            return name
        end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellID)
        if ok and name and name ~= "" then
            return name
        end
    end
    return nil
end

local function GetSpellTexture(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and texture then
            return texture
        end
    end
    return FALLBACK_ICON
end

-- Apply the QUI settings font + standard text colors to the spell-ID input
-- pieces. Any of box/label/addText may be nil.
local function StyleSpellInputText(GUI, C, box, label, addText)
    local fp = (GUI and GUI.FONT_PATH) or [[Interface\AddOns\QUI\assets\Quazii.ttf]]
    local tc = (C and C.text) or { 1, 1, 1, 1 }
    local mc = (C and C.textMuted) or { 1, 1, 1, 0.45 }
    if box then
        CJKFont(box, fp, 12, "")
        box:SetTextColor(tc[1], tc[2], tc[3], 1)
    end
    if label then
        CJKFont(label, fp, 11, "")
        label:SetTextColor(mc[1], mc[2], mc[3], mc[4] or 0.45)
    end
    if addText then
        CJKFont(addText, fp, 11, "")
        addText:SetTextColor(tc[1], tc[2], tc[3], 1)
    end
end

-- Pretty label/icon for an element. filterStrip => "Buffs"/"Debuffs"; tracked =>
-- the first spell's name (with a "+N" suffix when several spells share a strip).
local function GetElementLabel(element)
    if element.mode == "filterStrip" then
        if element.auraType == "HARMFUL" then
            return ns.L["Debuffs"], nil
        end
        return ns.L["Buffs"], nil
    elseif element.mode == "missingRaidBuff" then
        local icon = 134400
        local buffs = MissingRaidBuffs and MissingRaidBuffs.RaidBuffs
        if buffs and buffs[1] then
            local spellID = buffs[1].iconSpellID or (buffs[1].ids and buffs[1].ids[1])
            if spellID and C_Spell and C_Spell.GetSpellTexture then
                local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
                if ok and texture then icon = texture end
            end
        end
        return ns.L["Missing Raid Buff"], icon
    end

    local spells = element.spells or {}
    local first = spells[1]
    if not first then
        return ns.L["Tracked (empty)"], FALLBACK_ICON
    end
    local name = GetSpellName(first) or (ns.L["Spell"] .. " " .. tostring(first))
    if #spells > 1 then
        name = name .. " +" .. tostring(#spells - 1)
    end
    return name, GetSpellTexture(first)
end

-- Spell suggestions for the tracked picker, routed through the surface's
-- capabilities.suggestions provider (nil => no suggestions). Suggestions exclude
-- spells already tracked in this bucket.
local function GetSuggestionSpells(caps, bucket)
    if caps and type(caps.suggestions) == "function" then
        local existing = {}
        for _, element in ipairs(bucket or {}) do
            if element.mode == "tracked" then
                for _, sid in ipairs(element.spells or {}) do
                    existing[#existing + 1] = { spellID = sid }
                end
            end
        end
        return caps.suggestions(existing)
    end
    return {}
end

---------------------------------------------------------------------------
-- PER-ELEMENT CONFIG WIDGETS
-- Each builder appends form widgets into ctx.detailArea via AddDetailWidget and
-- returns nothing; the caller tracks the running Y. Kept at file scope so the
-- big RenderAuras closure stays under the Lua 5.1 60-upvalue cap.
---------------------------------------------------------------------------

local function AddPlacementWidgets(ctx, element, includeStrip)
    local GUI = ctx.GUI
    local row = ctx.AddFormRow
    local onChange = ctx.onChange

    if includeStrip then
        row(ns.L["Max Icons"], GUI:CreateFormSlider(ctx.detailArea, nil, 0, 10, 1, "maxIcons", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Hard cap on how many icons this element displays at once. 0 shows all matches."],
        }))
    end
    row(ns.L["Icon Size"], GUI:CreateFormSlider(ctx.detailArea, nil, 4, 40, 1, "iconSize", element, onChange, { deferOnDrag = true }, {
        description = ns.L["Pixel size of each icon."],
    }))
    row(ns.L["Anchor"], GUI:CreateFormDropdown(ctx.detailArea, nil, NINE_POINT_OPTIONS, "anchor", element, onChange, {
        description = ns.L["Where on the frame this element is anchored. X/Y Offset below nudges it from this anchor point."],
    }))
    if includeStrip then
        row(ns.L["Grow Direction"], GUI:CreateFormDropdown(ctx.detailArea, nil, AURA_GROW_OPTIONS, "growDirection", element, onChange, {
            description = ns.L["Direction additional icons are added in after the first."],
        }))
        row(ns.L["Spacing"], GUI:CreateFormSlider(ctx.detailArea, nil, 0, 8, 1, "spacing", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Pixel gap between adjacent icons."],
        }))
        row(ns.L["Icons Per Row"], GUI:CreateFormSlider(ctx.detailArea, nil, 0, 10, 1, "iconsPerRow", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Wrap icons onto a new row after this many. 0 keeps them on a single row. Extra rows stack away from the anchored frame edge."],
        }))
    end
    row(ns.L["X Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -100, 100, 1, "offsetX", element, onChange, { deferOnDrag = true }, {
        description = ns.L["Horizontal pixel offset from the anchor."],
    }))
    row(ns.L["Y Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -100, 100, 1, "offsetY", element, onChange, { deferOnDrag = true }, {
        description = ns.L["Vertical pixel offset from the anchor."],
    }))
end

local function AddSwipeWidgets(ctx, element)
    local GUI = ctx.GUI
    local row = ctx.AddFormRow
    local onChange = ctx.onChange

    row(ns.L["Hide Duration Swipe"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "hideSwipe", element, onChange, {
        description = ns.L["Hide the cooldown swipe animation drawn over icons."],
    }))
    row(ns.L["Reverse Swipe"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "reverseSwipe", element, onChange, {
        description = ns.L["Reverse the swipe direction so the shaded portion grows instead of shrinks as time passes."],
    }))
    row(ns.L["Swipe Style"], GUI:CreateFormDropdown(ctx.detailArea, nil, SWIPE_STYLE_OPTIONS, "swipeStyle", element, onChange, {
        description = ns.L["Radial or linear (horizontal/vertical) cooldown animation over aura icons."],
    }))
end

-- Shared text-region widget block for the duration{} / stack{} sub-tables. key
-- is "duration" or "stack"; the widgets write element[key].{show,fontSize,
-- anchor,offsetX,offsetY,color}. label is the region's display name.
local function AddTextRegionWidgets(ctx, element, key, label)
    local GUI = ctx.GUI
    local C = ctx.C
    local row = ctx.AddFormRow
    local add = ctx.AddDetailWidget
    local onChange = ctx.onChange

    if type(element[key]) ~= "table" then element[key] = {} end
    local region = element[key]

    local header = GUI:CreateLabel(ctx.detailArea, "|cFFAAAAAA" .. label .. "|r", 11, C.textMuted)
    header:SetJustifyH("LEFT")
    add(header, 18, true)

    row(ns.L["Show"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "show", region, onChange, {
        description = string.format(ns.L["Show the %s on each icon."], label),
    }))
    row(ns.L["Font Size"], GUI:CreateFormSlider(ctx.detailArea, nil, 6, 24, 1, "fontSize", region, onChange, { deferOnDrag = true }, {
        description = string.format(ns.L["Font size used for the %s."], label),
    }))
    row(ns.L["Text Anchor"], GUI:CreateFormDropdown(ctx.detailArea, nil, NINE_POINT_OPTIONS, "anchor", region, onChange, {
        description = ns.L["Where on the icon this text sits."],
    }))
    row(ns.L["X Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -30, 30, 1, "offsetX", region, onChange, { deferOnDrag = true }, {
        description = ns.L["Horizontal pixel offset from the text anchor."],
    }))
    row(ns.L["Y Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -30, 30, 1, "offsetY", region, onChange, { deferOnDrag = true }, {
        description = ns.L["Vertical pixel offset from the text anchor."],
    }))
    row(ns.L["Text Color"], GUI:CreateFormColorPicker(ctx.detailArea, nil, "color", region, onChange, nil, {
        description = string.format(ns.L["Color of the %s."], label),
    }))
end

local function AddFilterStripConfig(ctx, element)
    local GUI = ctx.GUI
    local row = ctx.AddFormRow
    local onChange = ctx.onChange
    local rebuild = ctx.rebuild
    local caps = ctx.caps

    row(ns.L["Aura Type"], GUI:CreateFormDropdown(ctx.detailArea, nil, AURA_TYPE_OPTIONS, "auraType", element, function()
        ctx.NotifyChanged()
        rebuild()
    end, {
        description = ns.L["Whether this strip shows helpful buffs or harmful debuffs."],
    }))

    AddPlacementWidgets(ctx, element, true)
    AddSwipeWidgets(ctx, element)
    AddTextRegionWidgets(ctx, element, "duration", ns.L["Duration Text"])
    AddTextRegionWidgets(ctx, element, "stack", ns.L["Stack Text"])

    row(ns.L["Sort Order"], GUI:CreateFormDropdown(ctx.detailArea, nil, SORT_OPTIONS, "sortRule", element, onChange, {
        description = ns.L["Order icons in this strip are displayed in."],
    }))
    row(ns.L["Reverse Sort"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "sortReverse", element, onChange, {
        description = ns.L["Reverse the sort order of icons in this strip."],
    }))

    -- Right-click-cancel is only honored on cancel-eligible (player-unit) hosts
    -- for HELPFUL strips, so only offer the toggle there.
    if caps.cancelEligible and element.auraType == "HELPFUL" then
        row(ns.L["Right-Click to Cancel"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "rightClickCancel", element, onChange, {
            description = ns.L["Allow right-clicking an icon in this strip to cancel the aura."],
        }))
    end

    row(ns.L["Filter Mode"], GUI:CreateFormDropdown(ctx.detailArea, nil, FILTER_MODE_OPTIONS, "filterMode", element, function()
        ctx.NotifyChanged()
        rebuild()
    end, {
        description = ns.L["Off shows everything; Flags composes the raw aura filter tokens ticked below; Classification shows only the categories ticked below."],
        keywords = { "filter", "include", "flags" },
    }))
    row(ns.L["Only My Auras"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "onlyMine", element, onChange, {
        description = ns.L["Only show auras you applied."],
        keywords = { "Only Mine", "mine only" },
    }))
    row(ns.L["Hide Permanent"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "hidePermanent", element, onChange, {
        description = ns.L["Hide auras with no remaining duration."],
    }))
    row(ns.L["Deduplicate Defensives"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "dedupeDefensives", element, onChange, {
        description = ns.L["Hide icons already shown by another tracked element."],
    }))

    local filterMode = element.filterMode or "off"
    if filterMode == "classify" then
        if type(element.classifications) ~= "table" then
            element.classifications = {}
        end
        local list = element.auraType == "HARMFUL" and HARMFUL_CLASSIFICATIONS or HELPFUL_CLASSIFICATIONS
        for _, entry in ipairs(list) do
            row(entry.label, GUI:CreateFormCheckbox(ctx.detailArea, nil, entry.key, element.classifications, onChange, {
                description = ns.L["Include auras Blizzard flags as "] .. entry.label .. ".",
            }))
        end
    elseif filterMode == "flags" then
        if type(element.filterFlags) ~= "table" then
            element.filterFlags = {}
        end
        local tokens = element.auraType == "HARMFUL" and HARMFUL_FLAG_TOKENS or HELPFUL_FLAG_TOKENS
        for _, entry in ipairs(tokens) do
            row(entry.label, GUI:CreateFormCheckbox(ctx.detailArea, nil, entry.token, element.filterFlags, onChange, {
                description = string.format(ns.L["Require the %s aura filter flag."], entry.label),
            }))
        end
    end
end

-- Spell-list editor for a tracked element's spells (an ARRAY). Reuses the shared
-- spell-list widget over a map view synced back to the array on every change,
-- plus a manual Spell ID input.
local function AddTrackedSpellListEditor(ctx, element)
    local GUI = ctx.GUI
    local C = ctx.C
    local add = ctx.AddDetailWidget
    local onChange = ctx.onChange

    if type(element.spells) ~= "table" then element.spells = {} end

    local header = GUI:CreateLabel(ctx.detailArea,
        "|cFFAAAAAA" .. ns.L["Tracked Spells (click a suggestion or enter a Spell ID):"] .. "|r", 11, C.textMuted)
    header:SetJustifyH("LEFT")
    add(header, 18, true)

    if not (SpellList and SpellList.CreateListFrame) then
        return
    end

    -- Manual Spell ID add row.
    local manualRow = CreateFrame("Frame", nil, ctx.detailArea)
    manualRow:SetHeight(24)

    local inputBox = CreateFrame("EditBox", nil, manualRow, "BackdropTemplate")
    inputBox:SetSize(80, 20)
    inputBox:SetPoint("LEFT", 0, 0)
    SkinBase.ApplyPixelBackdrop(inputBox, 1, true, false, { 0.25, 0.25, 0.25, 1 }, { 0.06, 0.06, 0.08, 1 })
    inputBox:SetFontObject("GameFontNormalSmall")
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(10)
    inputBox:SetTextInsets(4, 4, 0, 0)
    inputBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local inputLabel = manualRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    inputLabel:SetPoint("LEFT", inputBox, "RIGHT", 4, 0)
    inputLabel:SetText(ns.L["Spell ID"])
    inputLabel:SetTextColor(0.5, 0.5, 0.5)

    local addManualButton = CreateFrame("Button", nil, manualRow, "BackdropTemplate")
    addManualButton:SetSize(40, 20)
    addManualButton:SetPoint("LEFT", inputLabel, "RIGHT", 8, 0)
    SkinBase.ApplyPixelBackdrop(addManualButton, 1, true, false, { 0.3, 0.3, 0.3, 1 }, { 0.15, 0.15, 0.15, 1 })
    local addManualText = addManualButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addManualText:SetPoint("CENTER")
    addManualText:SetText(ns.L["Add"])
    StyleSpellInputText(GUI, C, inputBox, inputLabel, addManualText)

    local function CommitManual()
        local spellID = tonumber(inputBox:GetText())
        if spellID and spellID > 0 then
            local exists = false
            for _, sid in ipairs(element.spells) do
                if sid == spellID then exists = true break end
            end
            if not exists then
                element.spells[#element.spells + 1] = spellID
            end
            inputBox:SetText("")
            inputBox:ClearFocus()
            onChange()
            ctx.rebuild()
        end
    end
    addManualButton:SetScript("OnClick", CommitManual)
    inputBox:SetScript("OnEnterPressed", CommitManual)
    add(manualRow, 26, true)

    -- Preset toggle rows + "Other" remove rows over a map view of element.spells.
    local mapView = {}
    for _, sid in ipairs(element.spells) do mapView[sid] = true end
    local presets = (SpellList.GetDefaultPresets and SpellList.GetDefaultPresets()) or {}
    local listFrame = SpellList.CreateListFrame(ctx.detailArea, mapView, presets, function()
        local arr = element.spells
        for i = #arr, 1, -1 do arr[i] = nil end
        for sid in pairs(mapView) do arr[#arr + 1] = sid end
        table.sort(arr)
        onChange()
    end, function()
        ctx.rebuild()
    end)
    add(listFrame, math.max(1, listFrame:GetHeight() or 1), true)
end

-- Tracked element config. displayType picks the LIVE display: icon strip,
-- colored square, duration bar, or health-bar tint. The available displayTypes
-- are gated by capabilities.trackedDisplayTypes (a surface without a health-bar
-- would omit healthTint, etc.).
local function AddTrackedConfig(ctx, element)
    local GUI = ctx.GUI
    local row = ctx.AddFormRow
    local onChange = ctx.onChange
    local rebuild = ctx.rebuild
    local caps = ctx.caps

    local displayOptions = BuildTrackedDisplayOptions(caps.trackedDisplayTypes)
    row(ns.L["Display Type"], GUI:CreateFormDropdown(ctx.detailArea, nil, displayOptions, "displayType", element, function()
        ctx.NotifyChanged()
        rebuild()
    end, {
        description = ns.L["How this tracked aura displays: an icon strip, a colored square, a duration bar, or a health-bar tint."],
    }))
    row(ns.L["Aura Type"], GUI:CreateFormDropdown(ctx.detailArea, nil, AURA_TYPE_OPTIONS, "auraType", element, onChange, {
        description = ns.L["Whether this tracked aura is a helpful buff or a harmful debuff."],
    }))
    row(ns.L["Only My Cast"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "onlyMine", element, onChange, {
        description = ns.L["Only track this aura when you applied it."],
        keywords = { "Only Mine", "mine only" },
    }))

    local displayType = element.displayType or "icon"
    if displayType == "healthTint" then
        if type(element.color) ~= "table" then element.color = { 0.2, 0.8, 0.2, 1 } end
        if type(element.healthTint) ~= "table" then element.healthTint = {} end
        row(ns.L["Tint Color"], GUI:CreateFormColorPicker(ctx.detailArea, nil, "color", element, onChange, nil, {
            description = ns.L["Color tint applied across the health bar while the aura is active."],
        }))
        row(ns.L["Tint Animation"], GUI:CreateFormDropdown(ctx.detailArea, nil, HEALTH_TINT_ANIMATION_OPTIONS, "animation", element.healthTint, onChange, {
            description = ns.L["How the health-bar tint appears when the aura is detected."],
        }))
    elseif displayType == "square" then
        if type(element.color) ~= "table" then element.color = { 0.2, 0.8, 0.2, 1 } end
        row(ns.L["Square Size"], GUI:CreateFormSlider(ctx.detailArea, nil, 4, 40, 1, "iconSize", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Pixel size of the colored square."],
        }))
        row(ns.L["Anchor"], GUI:CreateFormDropdown(ctx.detailArea, nil, NINE_POINT_OPTIONS, "anchor", element, onChange, {
            description = ns.L["Where on the frame the square is anchored."],
        }))
        row(ns.L["X Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -100, 100, 1, "offsetX", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Horizontal pixel offset from the anchor."],
        }))
        row(ns.L["Y Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -100, 100, 1, "offsetY", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Vertical pixel offset from the anchor."],
        }))
        row(ns.L["Square Color"], GUI:CreateFormColorPicker(ctx.detailArea, nil, "color", element, onChange, nil, {
            description = ns.L["Fill color of the colored square."],
        }))
    elseif displayType == "bar" then
        if type(element.color) ~= "table" then element.color = { 0.2, 0.8, 0.2, 1 } end
        if type(element.bar) ~= "table" then element.bar = { thickness = 12, length = 48 } end
        row(ns.L["Anchor"], GUI:CreateFormDropdown(ctx.detailArea, nil, NINE_POINT_OPTIONS, "anchor", element, onChange, {
            description = ns.L["Where on the frame the bar is anchored."],
        }))
        row(ns.L["X Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -100, 100, 1, "offsetX", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Horizontal pixel offset from the anchor."],
        }))
        row(ns.L["Y Offset"], GUI:CreateFormSlider(ctx.detailArea, nil, -100, 100, 1, "offsetY", element, onChange, { deferOnDrag = true }, {
            description = ns.L["Vertical pixel offset from the anchor."],
        }))
        row(ns.L["Bar Color"], GUI:CreateFormColorPicker(ctx.detailArea, nil, "color", element, onChange, nil, {
            description = ns.L["Fill color of the bar while the aura is active."],
        }))
        row(ns.L["Thickness"], GUI:CreateFormSlider(ctx.detailArea, nil, 1, 40, 1, "thickness", element.bar, onChange, { deferOnDrag = true }, {
            description = ns.L["Pixel thickness of the bar."],
        }))
        row(ns.L["Length"], GUI:CreateFormSlider(ctx.detailArea, nil, 4, 200, 1, "length", element.bar, onChange, { deferOnDrag = true }, {
            description = ns.L["Pixel length of the bar."],
        }))
    else
        -- icon
        AddPlacementWidgets(ctx, element, true)
        AddSwipeWidgets(ctx, element)
        AddTextRegionWidgets(ctx, element, "duration", ns.L["Duration Text"])
        AddTextRegionWidgets(ctx, element, "stack", ns.L["Stack Text"])
    end

    AddTrackedSpellListEditor(ctx, element)
end

local function AddMissingRaidBuffConfig(ctx, element)
    local GUI = ctx.GUI
    local row = ctx.AddFormRow
    local onChange = ctx.onChange
    local rebuild = ctx.rebuild

    row(ns.L["Auto-Detect My Buff"], GUI:CreateFormCheckbox(ctx.detailArea, nil, "classDetection", element, function()
        ctx.NotifyChanged()
        rebuild()
    end, {
        description = ns.L["Only show the raid buff provided by your current class. Turn this off to choose buffs manually."],
    }), true)

    if element.classDetection == false then
        if type(element.buffChecks) ~= "table" then
            element.buffChecks = {}
        end
        for _, entry in ipairs(MISSING_RAID_BUFF_OPTIONS) do
            row(entry.label, GUI:CreateFormCheckbox(ctx.detailArea, nil, entry.key, element.buffChecks, onChange, {
                description = ns.L["Show this icon when the unit is missing this raid buff."],
            }))
        end
        -- CDM "Group Buff" entries merged into MRB.RaidBuffs (source=="cdm") aren't
        -- in the built-in MISSING_RAID_BUFF_OPTIONS list; surface them so they can be
        -- toggled in manual mode too.
        local merged = MissingRaidBuffs and MissingRaidBuffs.RaidBuffs
        if type(merged) == "table" then
            for _, entry in ipairs(merged) do
                if entry.source == "cdm" then
                    row(entry.label or entry.key, GUI:CreateFormCheckbox(ctx.detailArea, nil, entry.key, element.buffChecks, onChange, {
                        description = ns.L["Show this icon when the unit is missing this raid buff."],
                    }))
                end
            end
        end
    end

    AddPlacementWidgets(ctx, element, true)
end

---------------------------------------------------------------------------
-- ROW POOL
---------------------------------------------------------------------------
local function ReleaseRows(activeRows, pool)
    for _, row in ipairs(activeRows) do
        row:Hide()
        row:ClearAllPoints()
        if row.enable then row.enable:SetScript("OnClick", nil) end
        if row.delete then row.delete:SetScript("OnClick", nil) end
        row:SetScript("OnClick", nil)
        table.insert(pool, row)
    end
    wipe(activeRows)
end

---------------------------------------------------------------------------
-- DETAIL (per-element config) rendering. Builds widgets for the selected
-- element below the list.
---------------------------------------------------------------------------
-- Detail widgets lay out in the QUI two-column standard: consecutive form
-- widgets pair left/right, advancing the running Y by the taller of the two.
-- A widget added with span=true (headers, the manual-add row, the spell-list
-- frame) flushes any half-filled row and takes the full width on its own.
local function RenderDetail(ctx, element)
    ctx.ClearDetailWidgets()
    if not element then
        ctx.detailArea:SetHeight(1)
        return 0
    end

    local detailArea = ctx.detailArea
    ctx.detailY = -2
    ctx._pendingWidget = nil
    ctx._pendingHeight = 0
    -- Parity counter for the alternating row tint. Span rows (headers, the
    -- spell-list frame) are visually distinct and do not stripe or count, so
    -- the zebra rhythm stays continuous across the form rows around them.
    local rowParity = 0

    -- Emit one detail row: a frame stacked at the running Y holding either a
    -- left/right form pair (with center divider) or a single full-width / lone
    -- widget. Mirrors CreateSettingsCardGroup's row styling (3% white tint on
    -- odd rows, 5% white center divider) so the auras editor matches the
    -- standard two-column settings look.
    local function EmitRow(left, leftH, right, rightH, span)
        local rowH = span and leftH or (right and math.max(leftH, rightH) or leftH)
        local rowFrame = CreateFrame("Frame", nil, detailArea)
        ctx.RegisterDetailWidget(rowFrame)
        rowFrame:ClearAllPoints()
        rowFrame:SetPoint("TOPLEFT", detailArea, "TOPLEFT", 0, ctx.detailY)
        rowFrame:SetPoint("TOPRIGHT", detailArea, "TOPRIGHT", 0, ctx.detailY)
        rowFrame:SetHeight(rowH)

        if not span then
            if (rowParity % 2) == 1 then
                local bg = rowFrame:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints(rowFrame)
                bg:SetColorTexture(1, 1, 1, 0.02)
            end
            rowParity = rowParity + 1
        end

        left:SetParent(rowFrame)
        left:ClearAllPoints()
        if span then
            left:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", PAD, 0)
            left:SetPoint("TOPRIGHT", rowFrame, "TOPRIGHT", -PAD, 0)
        elseif right then
            left:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", PAD, 0)
            left:SetPoint("TOPRIGHT", rowFrame, "TOP", -(COL_GAP / 2), 0)
            right:SetParent(rowFrame)
            right:ClearAllPoints()
            right:SetPoint("TOPLEFT", rowFrame, "TOP", COL_GAP / 2, 0)
            right:SetPoint("TOPRIGHT", rowFrame, "TOPRIGHT", -PAD, 0)

            local cdiv = rowFrame:CreateTexture(nil, "ARTWORK")
            cdiv:SetPoint("TOP", rowFrame, "TOP", 0, -6)
            cdiv:SetPoint("BOTTOM", rowFrame, "BOTTOM", 0, 6)
            cdiv:SetWidth(1)
            cdiv:SetColorTexture(1, 1, 1, 0.05)
        else
            left:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", PAD, 0)
            left:SetPoint("TOPRIGHT", rowFrame, "TOP", -(COL_GAP / 2), 0)
        end

        ctx.detailY = ctx.detailY - rowH
    end

    local function FlushPending()
        if ctx._pendingWidget then
            EmitRow(ctx._pendingWidget, ctx._pendingHeight, nil, nil, false)
            ctx._pendingWidget = nil
            ctx._pendingHeight = 0
        end
    end

    ctx.AddDetailWidget = function(widget, height, span)
        if span then
            FlushPending()
            EmitRow(widget, height, nil, nil, true)
            return
        end
        if ctx._pendingWidget then
            EmitRow(ctx._pendingWidget, ctx._pendingHeight, widget, height, false)
            ctx._pendingWidget = nil
            ctx._pendingHeight = 0
        else
            ctx._pendingWidget = widget
            ctx._pendingHeight = height
        end
    end

    -- Wrap a bare (label=nil) form widget in the standard BuildSettingRow cell
    -- so it renders on a single compact line (label left, control right) at the
    -- uniform FORM_ROW height, instead of the tall label-on-top layout. Pass
    -- span=true for a full-width row.
    local optionsAPI = GetOptionsAPI()
    ctx.AddFormRow = function(label, widget, span)
        local cell = (optionsAPI and optionsAPI.BuildSettingRow)
            and optionsAPI.BuildSettingRow(detailArea, label, widget)
            or widget
        ctx.AddDetailWidget(cell, FORM_ROW, span)
    end

    ctx.AddFormRow(ns.L["Element Enabled"], ctx.GUI:CreateFormCheckbox(ctx.detailArea, nil, "enabled", element, function()
        ctx.NotifyChanged()
        ctx.rebuild()
    end, {
        description = ns.L["Toggle this element. When off, it does not display."],
    }), true)

    if element.mode == "filterStrip" then
        AddFilterStripConfig(ctx, element)
    elseif element.mode == "missingRaidBuff" then
        AddMissingRaidBuffConfig(ctx, element)
    else
        AddTrackedConfig(ctx, element)
    end

    FlushPending()

    local used = math.abs(ctx.detailY) + 8
    ctx.detailArea:SetHeight(used)
    return used
end

---------------------------------------------------------------------------
-- LIST + ADD + PICKER rendering
---------------------------------------------------------------------------
local function RebuildList(ctx)
    local bucket = ctx.bucket
    ctx.ReleaseRows()
    ctx.ReleaseSuggestRows()
    ctx.ClearDetailWidgets()

    -- nil selectedIndex means "all collapsed" -- a valid state the expand/minus
    -- toggle relies on, so DON'T coerce nil to 1 here (that made the minus button
    -- never collapse). Only clamp a real index that ran past the list end.
    if #bucket == 0 then
        ctx.selectedIndex = nil
    elseif ctx.selectedIndex and ctx.selectedIndex > #bucket then
        ctx.selectedIndex = #bucket
    end

    local C = ctx.C
    local accent = C.accent or { 0.204, 0.827, 0.6, 1 }
    local listY = 0

    -- Element rows.
    for index, element in ipairs(bucket) do
        local row = ctx.AcquireRow()
        row:SetParent(ctx.listArea)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ctx.listArea, "TOPLEFT", 0, listY)
        row:SetPoint("TOPRIGHT", ctx.listArea, "TOPRIGHT", 0, listY)
        row:Show()

        local label, icon = GetElementLabel(element)
        row.icon:SetTexture(icon or FALLBACK_ICON)
        row.icon:Show()
        local nameColor = element.enabled ~= false and "|cFFFFFFFF" or "|cFF808080"
        row.name:SetText(nameColor .. label .. "|r")

        if element.mode == "filterStrip" then
            row.badge:SetText("|cFF56D1FF" .. ns.L["STRIP"] .. "|r")
        elseif element.mode == "missingRaidBuff" then
            row.badge:SetText("|cFFFFD166" .. ns.L["RAID BUFF"] .. "|r")
        else
            row.badge:SetText("|cFFC8A2FF" .. ns.L["TRACKED"] .. "|r")
        end

        row.enable:SetToggleState(element.enabled ~= false)
        row.enable:SetScript("OnClick", function()
            element.enabled = (element.enabled == false)
            ctx.NotifyChanged()
            ctx.rebuild()
        end)

        local expanded = index == ctx.selectedIndex
        if ns.UIKit and ns.UIKit.SetChevronCaretExpanded and row.chevron then
            ns.UIKit.SetChevronCaretExpanded(row.chevron, expanded)
        end

        -- Alternating zebra (like the standard settings toggle rows); the
        -- expanded row gets a faint accent tint instead.
        if expanded then
            row.bg:SetColorTexture(accent[1], accent[2], accent[3], 0.10)
        elseif (index % 2) == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.02)
        else
            row.bg:SetColorTexture(1, 1, 1, 0)
        end

        -- Whole row toggles expand (collapse if already open, else open this one).
        row:SetScript("OnClick", function()
            if ctx.selectedIndex == index then
                ctx.selectedIndex = nil
            else
                ctx.selectedIndex = index
            end
            ctx.rebuild()
        end)
        row.delete:SetScript("OnClick", function()
            table.remove(bucket, index)
            if ctx.selectedIndex == index then
                ctx.selectedIndex = nil
            end
            ctx.NotifyChanged()
            ctx.rebuild()
        end)

        ctx.activeRows[#ctx.activeRows + 1] = row
        listY = listY - ROW_STEP

        -- Inline config directly under the selected row.
        if expanded then
            listY = listY - 2
            ctx.detailArea:ClearAllPoints()
            ctx.detailArea:SetParent(ctx.listArea)
            ctx.detailArea:SetPoint("TOPLEFT", ctx.listArea, "TOPLEFT", PAD, listY)
            ctx.detailArea:SetPoint("TOPRIGHT", ctx.listArea, "TOPRIGHT", 0, listY)
            ctx.detailArea:Show()
            local used = RenderDetail(ctx, element)
            listY = listY - used - 4
        end
    end

    if #bucket == 0 then
        ctx.emptyLabel:ClearAllPoints()
        ctx.emptyLabel:SetPoint("TOPLEFT", ctx.listArea, "TOPLEFT", 0, listY)
        ctx.emptyLabel:Show()
        listY = listY - 22
    else
        ctx.emptyLabel:Hide()
    end

    if ctx.selectedIndex == nil then
        ctx.detailArea:Hide()
    end

    -- Add controls (only when the surface offers addable element types).
    if ctx.hasAddButtons then
        ctx.UpdateAddStripState()
        listY = listY - 8
        ctx.addRow:ClearAllPoints()
        ctx.addRow:SetPoint("TOPLEFT", ctx.listArea, "TOPLEFT", 0, listY)
        ctx.addRow:SetPoint("TOPRIGHT", ctx.listArea, "TOPRIGHT", 0, listY)
        ctx.addRow:Show()
        listY = listY - 30
    else
        ctx.addRow:Hide()
    end

    -- Tracked-aura picker (suggestion grid + manual spellID) — tracked surfaces
    -- only.
    if ctx.trackedEnabled then
        listY = listY - 4
        ctx.pickerHeader:ClearAllPoints()
        ctx.pickerHeader:SetPoint("TOPLEFT", ctx.listArea, "TOPLEFT", 0, listY)
        ctx.pickerHeader:Show()
        listY = listY - 16

        ctx.inputRow:ClearAllPoints()
        ctx.inputRow:SetPoint("TOPLEFT", ctx.listArea, "TOPLEFT", 0, listY)
        ctx.inputRow:SetPoint("TOPRIGHT", ctx.listArea, "TOPRIGHT", 0, listY)
        ctx.inputRow:Show()
        listY = listY - 28

        local suggestions = GetSuggestionSpells(ctx.caps, bucket)
        if #suggestions > 0 then
            -- Prefer the explicit width threaded from the host section; it is stable
            -- across the synchronous render and the in-place rebuild. Fall back to
            -- the live width, then a fixed default, only when none was supplied.
            local contentWidth = ctx.contentWidth or ctx.listArea:GetWidth()
            if type(contentWidth) ~= "number" or contentWidth < SUGGEST_CELL_STRIDE then
                contentWidth = 480
            end
            local cols = math.max(1, math.floor(contentWidth / SUGGEST_CELL_STRIDE))
            local rowsUsed = math.ceil(#suggestions / cols)
            for sIndex, spell in ipairs(suggestions) do
                local cell = ctx.AcquireSuggestCell()
                local col = (sIndex - 1) % cols
                local rIdx = math.floor((sIndex - 1) / cols)
                cell:SetParent(ctx.listArea)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", col * SUGGEST_CELL_STRIDE, listY - (rIdx * SUGGEST_CELL_STRIDE))
                cell._spell = spell
                cell.icon:SetTexture(spell.icon or GetSpellTexture(spell.id))
                cell:Show()
                cell:SetScript("OnClick", function()
                    ctx.AddTracked(spell.id)
                end)
                ctx.activeSuggestRows[#ctx.activeSuggestRows + 1] = cell
            end
            listY = listY - (rowsUsed * SUGGEST_CELL_STRIDE) - 4
        end
    else
        ctx.pickerHeader:Hide()
        ctx.inputRow:Hide()
    end

    local contentHeight = math.max(1, math.abs(listY))
    ctx.listArea:SetHeight(contentHeight)
    local hostHeight = contentHeight + 8
    ctx.host:SetHeight(hostHeight)

    -- Report selection + height so the host can persist the open row and
    -- re-anchor the sections below this editor. Both are no-ops when the host
    -- did not supply hooks (e.g. the headless search-cache harvest).
    if ctx.onSelectionChanged then
        ctx.onSelectionChanged(ctx.selectedIndex)
    end
    if ctx.onLayoutChanged then
        ctx.onLayoutChanged(hostHeight)
    end
end

-- opts is optional. opts.forceSelectedIndex seeds the initially-expanded element
-- (used by the headless options-search harvest so per-element config labels get
-- rendered and captured). In-game callers omit opts and the list opens collapsed.
-- opts.capabilities gates which element types / display types / controls the
-- surface offers (see DefaultCapabilities for the shape; nil => full GF set).
function AurasEditor.RenderAuras(host, auras, bucketKey, onChange, opts)
    local GUI = GetGUI()
    if not host or not GUI or type(auras) ~= "table" or not E then
        return 1
    end

    local caps = ResolveCapabilities(opts)

    if type(auras.elements) ~= "table" then
        auras.elements = {}
    end
    -- Seed the surface's shipped defaults once, threading its default bucket fn
    -- (never the one-arg legacy form — core E.EnsureSeeded seeds an EMPTY bucket
    -- and latches when handed no fn). Idempotent: the runtime host normally seeds
    -- first, so this short-circuits on auras.elementsSeeded.
    if E.EnsureSeeded then
        E.EnsureSeeded(auras, caps.defaultBucketFn)
    end

    bucketKey = bucketKey or "*"
    -- Surfaces without spec overrides only ever edit the shared "*" bucket; never
    -- honor a stray spec bucketKey there (their host cannot create one).
    if not caps.allowSpecOverride then
        bucketKey = "*"
    end
    -- Only the shared "*" bucket is auto-created. Spec buckets must NOT be
    -- created merely by viewing/editing — their presence is the override flag
    -- (see AuraElements.EnableSpecOverride), so the schema only calls RenderAuras
    -- for a spec once override is on (bucket already exists).
    if bucketKey == "*" and type(auras.elements["*"]) ~= "table" then
        auras.elements["*"] = {}
    end

    local C = GUI.Colors or {}
    local accent = C.accent or { 0.204, 0.827, 0.6, 1 }

    local listArea = CreateFrame("Frame", nil, host)
    listArea:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    listArea:SetPoint("RIGHT", host, "RIGHT", 0, 0)
    listArea:SetHeight(1)

    local emptyLabel = GUI:CreateLabel(listArea, ns.L["No aura elements in this bucket yet. Add one below."], 11, C.textMuted)
    emptyLabel:SetJustifyH("LEFT")
    emptyLabel:Hide()

    local detailArea = CreateFrame("Frame", nil, listArea)
    detailArea:SetHeight(1)
    detailArea:Hide()

    local pickerHeader = listArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pickerHeader:SetJustifyH("LEFT")
    pickerHeader:SetText("|cFFAAAAAA" .. ns.L["Add Tracked Aura (click a suggestion or enter a Spell ID):"] .. "|r")

    -- Add buttons row (Filter strip / Missing raid buff), gated by the surface's
    -- element types. Anchored left-to-right in the order created.
    local addRow = CreateFrame("Frame", nil, listArea)
    addRow:SetHeight(26)
    local elementTypes = caps.elementTypes or {}
    local addStripButton, addMissingBuffButton
    if elementTypes.filterStrip then
        addStripButton = GUI:CreateButton(addRow, ns.L["Add Filter Strip"], 130, 22)
        addStripButton:ClearAllPoints()
        addStripButton:SetPoint("LEFT", addRow, "LEFT", 0, 0)
    end
    if elementTypes.missingRaidBuff then
        addMissingBuffButton = GUI:CreateButton(addRow, ns.L["Add Missing Raid Buff"], 170, 22)
        addMissingBuffButton:ClearAllPoints()
        if addStripButton then
            addMissingBuffButton:SetPoint("LEFT", addStripButton, "RIGHT", 8, 0)
        else
            addMissingBuffButton:SetPoint("LEFT", addRow, "LEFT", 0, 0)
        end
    end

    -- Manual spellID input row (tracked picker).
    local inputRow = CreateFrame("Frame", nil, listArea)
    inputRow:SetHeight(24)

    local inputBox = CreateFrame("EditBox", nil, inputRow, "BackdropTemplate")
    inputBox:SetSize(80, 20)
    inputBox:SetPoint("LEFT", 0, 0)
    SkinBase.ApplyPixelBackdrop(inputBox, 1, true, false, { 0.25, 0.25, 0.25, 1 }, { 0.06, 0.06, 0.08, 1 })
    inputBox:SetFontObject("GameFontNormalSmall")
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(10)
    inputBox:SetTextInsets(4, 4, 0, 0)
    inputBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local inputLabel = inputRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    inputLabel:SetPoint("LEFT", inputBox, "RIGHT", 4, 0)
    inputLabel:SetText(ns.L["Spell ID"])
    inputLabel:SetTextColor(0.5, 0.5, 0.5)

    local addManualButton = CreateFrame("Button", nil, inputRow, "BackdropTemplate")
    addManualButton:SetSize(40, 20)
    addManualButton:SetPoint("LEFT", inputLabel, "RIGHT", 8, 0)
    SkinBase.ApplyPixelBackdrop(addManualButton, 1, true, false, { 0.3, 0.3, 0.3, 1 }, { 0.15, 0.15, 0.15, 1 })
    local addManualText = addManualButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addManualText:SetPoint("CENTER")
    addManualText:SetText(ns.L["Add"])
    StyleSpellInputText(GUI, C, inputBox, inputLabel, addManualText)

    local rowPool = {}
    local activeRows = {}
    local suggestPool = {}
    local activeSuggestRows = {}
    local detailWidgets = {}

    local ctx = {
        GUI = GUI,
        C = C,
        host = host,
        auras = auras,
        caps = caps,
        bucket = auras.elements[bucketKey],
        onChangeRaw = onChange,
        listArea = listArea,
        emptyLabel = emptyLabel,
        detailArea = detailArea,
        pickerHeader = pickerHeader,
        addRow = addRow,
        addStripButton = addStripButton,
        inputRow = inputRow,
        activeRows = activeRows,
        activeSuggestRows = activeSuggestRows,
        selectedIndex = nil,
        hasAddButtons = (addStripButton ~= nil) or (addMissingBuffButton ~= nil),
        trackedEnabled = elementTypes.tracked and true or false,
        -- Explicit content width from the host section (see group_frames_schema
        -- RenderAurasSection). Used for the suggestion-grid column math so the
        -- list height is identical on the synchronous tab render and on the
        -- in-place add/remove rebuild, regardless of when anchors settle.
        contentWidth = (type(opts) == "table" and type(opts.contentWidth) == "number" and opts.contentWidth > 0)
            and opts.contentWidth or nil,
        -- Host hooks (optional): onSelectionChanged(index) persists which row is
        -- expanded so a host-driven reflow can restore it; onLayoutChanged(height)
        -- lets the host re-anchor the sections below when this editor resizes.
        onSelectionChanged = (type(opts) == "table" and type(opts.onSelectionChanged) == "function")
            and opts.onSelectionChanged or nil,
        onLayoutChanged = (type(opts) == "table" and type(opts.onLayoutChanged) == "function")
            and opts.onLayoutChanged or nil,
    }

    local function NotifyChanged()
        if type(onChange) == "function" then
            onChange()
        end
    end
    ctx.NotifyChanged = NotifyChanged
    -- onChange used by widgets that mutate the model in place (no list rebuild).
    ctx.onChange = function()
        NotifyChanged()
    end

    -- Re-entrancy guard: a child widget that lays itself out synchronously inside
    -- a RebuildList pass (the spell-list frame's CreateListFrame fires its
    -- onLayoutChanged) could fire a callback that calls rebuild again, re-entering
    -- RebuildList -> RenderDetail -> ... -> rebuild without end. The outer pass
    -- already reads each widget's final height as it returns, so any rebuild
    -- requested mid-pass is redundant -- drop it.
    local rebuilding = false
    local rebuild
    rebuild = function()
        if rebuilding then
            return
        end
        rebuilding = true
        local ok, err = pcall(RebuildList, ctx)
        rebuilding = false
        if not ok then
            error(err, 0)
        end
    end
    ctx.rebuild = rebuild

    ctx.ClearDetailWidgets = function()
        for _, widget in ipairs(detailWidgets) do
            widget:Hide()
        end
        wipe(detailWidgets)
    end
    ctx.RegisterDetailWidget = function(widget)
        detailWidgets[#detailWidgets + 1] = widget
        return widget
    end

    -- Update the "Add Filter Strip" button's enabled state against the surface's
    -- maxStripElements cap (counts ENABLED filter strips). At cap the button
    -- dims and clicks are swallowed with a tooltip.
    ctx.UpdateAddStripState = function()
        local b = ctx.addStripButton
        if not b then return end
        local cap = ctx.caps.maxStripElements
        if not cap then
            b._atCap = false
            b:SetAlpha(1)
            return
        end
        local n = 0
        for _, e in ipairs(ctx.bucket) do
            if e.mode == "filterStrip" and e.enabled ~= false then
                n = n + 1
            end
        end
        local atCap = n >= cap
        b._atCap = atCap
        b:SetAlpha(atCap and 0.4 or 1)
    end

    ctx.AcquireRow = function()
        local row = table.remove(rowPool)
        if row then
            row:Show()
            return row
        end

        -- Whole-row Button toggles expand; child buttons (enable, delete) consume
        -- their own clicks. The chevron is a Frame, so clicking it falls through
        -- to the row toggle.
        row = CreateFrame("Button", nil, listArea)
        row:SetHeight(ROW_HEIGHT)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)
        row.bg:SetColorTexture(1, 1, 1, 0)

        local UIKit = ns.UIKit
        if UIKit and UIKit.CreateChevronCaret then
            row.chevron = UIKit.CreateChevronCaret(row, {
                point = "LEFT", relativeTo = row, relativePoint = "LEFT",
                xPixels = 8, sizePixels = 8, collapsedDirection = "right",
                expanded = false,
                r = (C.text and C.text[1]) or 1,
                g = (C.text and C.text[2]) or 1,
                b = (C.text and C.text[3]) or 1,
                a = 0.85,
            })
        end

        row.enable = SpellList and SpellList.CreateMiniToggle and SpellList.CreateMiniToggle(row) or nil
        if not row.enable then
            -- Fallback simple button toggle.
            row.enable = CreateFrame("Button", nil, row)
            row.enable:SetSize(26, 14)
            row.enable.SetToggleState = function() end
        end
        row.enable:SetPoint("LEFT", row, "LEFT", 22, 0)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", row.enable, "RIGHT", 6, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        CJKFont(row.name, (GUI.FONT_PATH) or [[Interface\AddOns\QUI\assets\Quazii.ttf]], 12, "")
        row.name:SetJustifyH("LEFT")

        -- Standard QUI ghost button (matches Alts row delete), not a raw red x.
        row.delete = GUI:CreateButton(row, ns.L["Delete"], 56, 18)
        row.delete:SetPoint("RIGHT", row, "RIGHT", -6, 0)

        row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.badge:SetJustifyH("RIGHT")
        row.badge:SetPoint("RIGHT", row.delete, "LEFT", -8, 0)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.badge, "LEFT", -6, 0)

        return row
    end
    ctx.ReleaseRows = function()
        ReleaseRows(activeRows, rowPool)
    end

    ctx.AcquireSuggestCell = function()
        local cell = table.remove(suggestPool)
        if cell then
            cell:Show()
            return cell
        end

        cell = CreateFrame("Button", nil, listArea, "BackdropTemplate")
        cell:SetSize(SUGGEST_CELL_SIZE, SUGGEST_CELL_SIZE)
        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        SkinBase.ApplyPixelBackdrop(cell, 1, true, false, { 0.2, 0.2, 0.2, 0.5 }, { 0, 0, 0, 0 })

        cell.icon = cell:CreateTexture(nil, "ARTWORK")
        cell.icon:SetSize(SUGGEST_ICON_SIZE, SUGGEST_ICON_SIZE)
        cell.icon:SetPoint("CENTER")
        cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        cell.highlight = cell:CreateTexture(nil, "HIGHLIGHT")
        cell.highlight:SetAllPoints()
        cell.highlight:SetColorTexture(accent[1], accent[2], accent[3], 0.15)

        cell:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(accent[1], accent[2], accent[3], 0.8)
            if GameTooltip and self._spell then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetFrameStrata("TOOLTIP")
                GameTooltip:AddLine(self._spell.name or GetSpellName(self._spell.id) or (ns.L["Spell"] .. " " .. tostring(self._spell.id)), 1, 1, 1)
                GameTooltip:AddLine(ns.L["ID: "] .. tostring(self._spell.id), 0.5, 0.5, 0.5)
                if self._spell.source then
                    GameTooltip:AddLine(self._spell.source, 0.45, 0.65, 0.95)
                end
                GameTooltip:AddLine(ns.L["Click to add"], 0.5, 0.5, 0.5)
                GameTooltip:Show()
            end
        end)
        cell:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.5)
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)

        return cell
    end
    ctx.ReleaseSuggestRows = function()
        for _, cell in ipairs(activeSuggestRows) do
            cell:Hide()
            cell:ClearAllPoints()
            cell:SetScript("OnClick", nil)
            cell._spell = nil
            table.insert(suggestPool, cell)
        end
        wipe(activeSuggestRows)
    end

    -- New tracked elements default to the surface's preferred display type.
    ctx.AddTracked = function(spellID)
        spellID = tonumber(spellID) or spellID
        local element = E.NewTrackedElement(spellID and { spellID } or {}, DefaultTrackedDisplay(ctx.caps))
        ctx.bucket[#ctx.bucket + 1] = element
        ctx.selectedIndex = #ctx.bucket
        NotifyChanged()
        rebuild()
    end

    ctx.AddFilterStrip = function()
        -- Default new strips to debuffs only if a buff strip already exists,
        -- otherwise buffs; the auraType dropdown lets the user flip it.
        local hasBuff = false
        for _, element in ipairs(ctx.bucket) do
            if element.mode == "filterStrip" and element.auraType == "HELPFUL" then
                hasBuff = true
            end
        end
        local element = E.NewFilterStripElement(hasBuff and "HARMFUL" or "HELPFUL")
        ctx.bucket[#ctx.bucket + 1] = element
        ctx.selectedIndex = #ctx.bucket
        NotifyChanged()
        rebuild()
    end

    ctx.AddMissingRaidBuff = function()
        if not E.NewMissingRaidBuffElement then return end
        local element = E.NewMissingRaidBuffElement()
        ctx.bucket[#ctx.bucket + 1] = element
        ctx.selectedIndex = #ctx.bucket
        NotifyChanged()
        rebuild()
    end

    if addStripButton then
        addStripButton:SetScript("OnClick", function(self)
            if self._atCap then return end
            ctx.AddFilterStrip()
        end)
        addStripButton:HookScript("OnEnter", function(self)
            if self._atCap and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetFrameStrata("TOOLTIP")
                GameTooltip:AddLine(ns.L["Maximum filter strips reached for these frames."], 1, 0.82, 0)
                GameTooltip:Show()
            end
        end)
        addStripButton:HookScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
    end
    if addMissingBuffButton then
        addMissingBuffButton:SetScript("OnClick", function()
            ctx.AddMissingRaidBuff()
        end)
    end
    addManualButton:SetScript("OnClick", function()
        local spellID = tonumber(inputBox:GetText())
        if spellID and spellID > 0 then
            inputBox:SetText("")
            inputBox:ClearFocus()
            ctx.AddTracked(spellID)
        end
    end)
    inputBox:SetScript("OnEnterPressed", function()
        local click = addManualButton:GetScript("OnClick")
        if click then
            click(addManualButton)
        end
    end)

    -- Harvest-only: open with a specific element expanded so its per-element
    -- config widgets render (and their labels get captured). Clamped by RebuildList.
    if opts and type(opts.forceSelectedIndex) == "number" then
        ctx.selectedIndex = opts.forceSelectedIndex
    end

    rebuild()
    return host:GetHeight()
end

return AurasEditor
