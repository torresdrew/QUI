--[[
    QUI Anchoring Options Module
    Reusable UI components for anchoring and snapping options
    Provides anchor dropdown, snap buttons, and offset controls
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local QUI_Anchoring_Options = {}
ns.QUI_Anchoring_Options = QUI_Anchoring_Options

-- Helper to get GUI (lazy load to avoid initialization order issues)
local function GetGUI()
    local QUI = _G.QUI
    if QUI and QUI.GUI then
        return QUI.GUI
    end
    return nil
end

-- Helper to get Colors (lazy load)
local function GetColors()
    local GUI = GetGUI()
    if GUI and GUI.Colors then
        return GUI.Colors
    end
    -- Fallback colors if GUI not available
    return {
        text = {1, 1, 1},
        border = {0.3, 0.3, 0.3},
        accent = {0.2, 0.6, 1}
    }
end

local GetCore = Helpers.GetCore

---------------------------------------------------------------------------
-- ANCHORING DATABASE DEFAULTS & HELPERS (shared infrastructure)
---------------------------------------------------------------------------
local ANCHORING_DEFAULTS = {
    parent         = "screen",
    point          = "CENTER",
    relative       = "CENTER",
    offsetX        = 0,
    offsetY        = 0,
    sizeStable     = true,
    autoWidth      = false,
    widthAdjust    = 0,
    autoHeight     = false,
    heightAdjust   = 0,
    hideWithParent = false,
    keepInPlace    = true,
}

local HUD_MIN_WIDTH_DEFAULT = (Helpers and Helpers.HUD_MIN_WIDTH_DEFAULT) or 200

function QUI_Anchoring_Options:GetAnchoringDB()
    local core = GetCore()
    local db = core and core.db and core.db.profile
    if not db then return nil end
    if type(db.frameAnchoring) ~= "table" then
        db.frameAnchoring = {}
    end

    -- Migrate and normalize legacy scalar keys to object style:
    -- frameAnchoring.hudMinWidth = { enabled = bool, width = number }
    local hudMinWidth
    if Helpers and Helpers.MigrateHUDMinWidthSettings then
        hudMinWidth = Helpers.MigrateHUDMinWidthSettings(db.frameAnchoring)
    end
    if not hudMinWidth then
        local enabled, width = false, HUD_MIN_WIDTH_DEFAULT
        if Helpers and Helpers.ParseHUDMinWidth then
            enabled, width = Helpers.ParseHUDMinWidth(db.frameAnchoring)
        end
        hudMinWidth = {
            enabled = enabled == true,
            width = width or HUD_MIN_WIDTH_DEFAULT,
        }
        db.frameAnchoring.hudMinWidth = hudMinWidth
        db.frameAnchoring.hudMinWidthEnabled = nil
    end

    return db.frameAnchoring
end

-- Returns a table bound to frameAnchoring[key] that widgets can read from
-- and write to. If the underlying entry does not yet exist, the returned
-- table is a lazy proxy: reads fall through to ANCHORING_DEFAULTS, and the
-- first write materializes the real entry in frameAnchoring (with defaults
-- backfilled) before applying the write.
--
-- This prevents the "opening a settings panel resurrects the entry" bug.
-- Previously this function unconditionally created anchoringDB[key] on
-- read, which caused ApplyAllFrameAnchors to pick up default screen/CENTER
-- entries for frames that should not have a frameAnchoring entry at all
-- (notably CDM containers owned by ncdm.pos).
function QUI_Anchoring_Options:GetFrameDB(key)
    local anchoringDB = self:GetAnchoringDB()
    if not anchoringDB then return nil end

    -- Existing entry: backfill missing default fields in-place and return it.
    local existing = anchoringDB[key]
    if existing then
        for k, v in pairs(ANCHORING_DEFAULTS) do
            if existing[k] == nil then
                existing[k] = v
            end
        end
        return existing
    end

    -- No entry: return a proxy that only materializes on a meaningful write.
    --
    -- "Meaningful" = the new value differs from ANCHORING_DEFAULTS. Widgets
    -- commonly fire OnChange handlers that write back the *current* value
    -- (e.g. dropdowns re-selecting the same option). Without this guard, any
    -- such write would materialize a full default-valued entry into the raw
    -- SV, which ApplyFrameAnchor would then pick up and SetPoint the live
    -- frame to the default position — causing CDM containers to teleport to
    -- screen center the moment a settings panel opens.
    --
    -- A real edit (user actually changes a dropdown/slider) will always
    -- produce a value different from the default, so the materialization
    -- still fires for legitimate interaction.
    local proxy = {}
    setmetatable(proxy, {
        __index = function(_, k)
            local real = anchoringDB[key]
            if real and real[k] ~= nil then
                return real[k]
            end
            return ANCHORING_DEFAULTS[k]
        end,
        __newindex = function(_, k, v)
            local real = anchoringDB[key]
            if not real then
                -- Skip no-op writes that would just restamp defaults.
                if v == ANCHORING_DEFAULTS[k] then
                    return
                end
                real = {}
                anchoringDB[key] = real
                -- Backfill defaults so the newly-materialized entry has the
                -- full metadata shape the anchoring system expects.
                for dk, dv in pairs(ANCHORING_DEFAULTS) do
                    real[dk] = dv
                end
            end
            real[k] = v
        end,
    })
    return proxy
end

local FORM_ROW = 32

function QUI_Anchoring_Options:BuildAnchoringSection(tabContent, frameKey, options, y)
    options = options or {}
    local PAD = 15  -- matches Shared.PADDING
    local GUI = GetGUI()
    if not GUI then return y, nil end

    local ninePointOptions = self:GetNinePointAnchorOptions()
    local frameDB = self:GetFrameDB(frameKey)
    if not frameDB then return y, nil end

    -- Default range based on screen size so sliders can reach all positions
    local screenW = math.ceil((UIParent and UIParent:GetWidth() or 1920) / 2)
    local screenH = math.ceil((UIParent and UIParent:GetHeight() or 1080) / 2)
    local defaultRange = math.max(screenW, screenH)
    local sliderMin = options.sliderRange and options.sliderRange[1] or -defaultRange
    local sliderMax = options.sliderRange and options.sliderRange[2] or defaultRange

    local widgetRefs = {}

    local function OnChange()
        if _G.QUI_ApplyFrameAnchor then
            _G.QUI_ApplyFrameAnchor(frameKey)
        end
        -- Bidirectional sync: if layout mode is open, mark changes and
        -- reposition the mover handle to follow the frame's new position.
        -- We clear any stale pending position first so SyncHandle reads
        -- the frame's actual position rather than an outdated offset.
        local inLayoutMode = _G.QUI_IsLayoutModeActive and _G.QUI_IsLayoutModeActive()
        if inLayoutMode then
            if _G.QUI_LayoutModeMarkChanged then
                _G.QUI_LayoutModeMarkChanged()
            end
            if _G.QUI_LayoutModeClearPending then
                _G.QUI_LayoutModeClearPending(frameKey)
            end
        end
        if _G.QUI_LayoutModeSyncHandle then
            _G.QUI_LayoutModeSyncHandle(frameKey)
        end

        -- Re-apply and sync the full anchored-DESCENDANT chain (children,
        -- grandchildren, ...), breadth-first so each parent is repositioned
        -- before its own children read it. A one-level pass left
        -- grandchildren at stale anchors (e.g. debuffFrame → buffFrame →
        -- minimap: moving the minimap reapplied buffFrame but debuffFrame
        -- kept its stale absolute anchor from a prior drag).
        -- Use ForceReapply to clear stale anchors (e.g. from drag
        -- operations that set children to CENTER/UIParent) and guarantee
        -- each child re-anchors to its configured parent frame. The
        -- visited set guards against parent cycles in the DB.
        local anchoringDB = GetCore()
        anchoringDB = anchoringDB and anchoringDB.db and anchoringDB.db.profile and anchoringDB.db.profile.frameAnchoring
        if anchoringDB then
            local visited = { [frameKey] = true }
            local queue = { frameKey }
            while #queue > 0 do
                local parentKey = table.remove(queue, 1)
                for childKey, childSettings in pairs(anchoringDB) do
                    if not visited[childKey] and type(childSettings) == "table"
                        and childSettings.parent == parentKey then
                        visited[childKey] = true
                        queue[#queue + 1] = childKey
                        if inLayoutMode and _G.QUI_LayoutModeClearPending then
                            _G.QUI_LayoutModeClearPending(childKey)
                        end
                        if _G.QUI_ForceReapplyFrameAnchor then
                            _G.QUI_ForceReapplyFrameAnchor(childKey)
                        elseif _G.QUI_ApplyFrameAnchor then
                            _G.QUI_ApplyFrameAnchor(childKey)
                        end
                        if _G.QUI_LayoutModeSyncHandle then
                            _G.QUI_LayoutModeSyncHandle(childKey)
                        end
                    end
                end
            end
        end
    end

    -- Section header
    if not options.noHeader then
        local headerName = options.name or frameKey
        ns.QUI_Options.CreateAccentDotLabel(tabContent, headerName .. " " .. ns.L["Anchoring"], y); y = y - 30
    end

    -- Anchor To dropdown (uses anchor target registry)
    -- When the anchor target changes, reset X/Y offsets to 0 so stale offsets
    -- from the previous target don't confuse the user.
    local function OnAnchorTargetChange(val)
        frameDB.offsetX = 0
        frameDB.offsetY = 0
        if widgetRefs.sliderX and widgetRefs.sliderX.SetValue then
            widgetRefs.sliderX:SetValue(0, true)
        end
        if widgetRefs.sliderY and widgetRefs.sliderY.SetValue then
            widgetRefs.sliderY:SetValue(0, true)
        end
        OnChange()
    end
    local anchorDropdown = self:CreateAnchorDropdown(
        tabContent, ns.L["Anchor To"], frameDB, "parent",
        PAD + 10, y, nil, OnAnchorTargetChange,
        nil, nil, frameKey  -- excludeSelf
    )
    if anchorDropdown then
        anchorDropdown:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.anchorDropdown = anchorDropdown
        y = y - FORM_ROW
    end

    -- From Point dropdown (source anchor)
    local fromPoint = GUI:CreateFormDropdown(tabContent, ns.L["From Point"], ninePointOptions, "point", frameDB, OnChange,
        { description = ns.L["Which corner or edge of this frame attaches to the anchor. Together with To Point, this defines how the two frames align."] })
    fromPoint:SetPoint("TOPLEFT", PAD + 10, y)
    fromPoint:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    widgetRefs.fromPoint = fromPoint
    y = y - FORM_ROW

    -- To Point dropdown (target anchor)
    local toPoint = GUI:CreateFormDropdown(tabContent, ns.L["To Point"], ninePointOptions, "relative", frameDB, OnChange,
        { description = ns.L["Which corner or edge of the anchor target this frame attaches to. Together with From Point, this defines how the two frames align."] })
    toPoint:SetPoint("TOPLEFT", PAD + 10, y)
    toPoint:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    widgetRefs.toPoint = toPoint
    y = y - FORM_ROW

    -- Offset X slider
    local sliderX = GUI:CreateFormSlider(tabContent, ns.L["Offset X"], sliderMin, sliderMax, 1, "offsetX", frameDB, OnChange, nil,
        { description = ns.L["Horizontal pixel offset from the anchor point. Positive values move the frame right, negative values move it left."] })
    sliderX:SetPoint("TOPLEFT", PAD + 10, y)
    sliderX:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    widgetRefs.sliderX = sliderX
    y = y - FORM_ROW

    -- Offset Y slider
    local sliderY = GUI:CreateFormSlider(tabContent, ns.L["Offset Y"], sliderMin, sliderMax, 1, "offsetY", frameDB, OnChange, nil,
        { description = ns.L["Vertical pixel offset from the anchor point. Positive values move the frame up, negative values move it down."] })
    sliderY:SetPoint("TOPLEFT", PAD + 10, y)
    sliderY:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
    widgetRefs.sliderY = sliderY
    y = y - FORM_ROW

    -- Auto-width toggle (match anchor target width)
    if options.autoWidth then
        local autoWidthToggle = GUI:CreateFormToggle(tabContent, ns.L["Auto-Width (Match Anchor Target)"], "autoWidth", frameDB, OnChange,
            { description = ns.L["Automatically resize this frame to match the width of its anchor target so the two stay visually aligned. Use Width Adjustment below for fine pixel tweaks."] })
        autoWidthToggle:SetPoint("TOPLEFT", PAD + 10, y)
        autoWidthToggle:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.autoWidth = autoWidthToggle
        y = y - FORM_ROW

        local widthAdjust = GUI:CreateFormSlider(tabContent, ns.L["Width Adjustment"], -20, 20, 1, "widthAdjust", frameDB, OnChange, nil,
            { description = ns.L["Pixel tweak added to the auto-matched width. Useful for overshooting or undershooting the anchor target to account for borders or padding."] })
        widthAdjust:SetPoint("TOPLEFT", PAD + 10, y)
        widthAdjust:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.widthAdjust = widthAdjust
        y = y - FORM_ROW
    end

    -- Auto-height toggle
    if options.autoHeight then
        local autoHeightToggle = GUI:CreateFormToggle(tabContent, ns.L["Auto-Height (Match CDM Row 1 Icon)"], "autoHeight", frameDB, OnChange,
            { description = ns.L["Automatically resize this frame to match the height of the Cooldown Manager's first icon row, so the frame scales with CDM icon size changes."] })
        autoHeightToggle:SetPoint("TOPLEFT", PAD + 10, y)
        autoHeightToggle:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.autoHeight = autoHeightToggle
        y = y - FORM_ROW

        local heightAdjust = GUI:CreateFormSlider(tabContent, ns.L["Height Adjustment"], -20, 20, 1, "heightAdjust", frameDB, OnChange, nil,
            { description = ns.L["Pixel tweak added to the auto-matched height. Useful for overshooting or undershooting the match to account for borders or visual padding."] })
        heightAdjust:SetPoint("TOPLEFT", PAD + 10, y)
        heightAdjust:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.heightAdjust = heightAdjust
        y = y - FORM_ROW
    end

    -- Hide With Anchor toggle
    if options.hideWithParent ~= false then
        local hideToggle = GUI:CreateFormToggle(tabContent, ns.L["Hide With Anchor"], "hideWithParent", frameDB, OnChange,
            { description = ns.L["Hide this frame whenever its anchor target is hidden, so dependent frames disappear together with the thing they follow."] })
        hideToggle:SetPoint("TOPLEFT", PAD + 10, y)
        hideToggle:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.hideWithParent = hideToggle
        y = y - FORM_ROW
    end

    -- Keep In Place toggle
    if options.hideWithParent ~= false then
        local keepToggle = GUI:CreateFormToggle(tabContent, ns.L["Keep In Place When Hidden"], "keepInPlace", frameDB, OnChange,
            { description = ns.L["When the anchor target is hidden but this frame stays visible, keep it at its last screen position instead of snapping toward the hidden anchor."] })
        keepToggle:SetPoint("TOPLEFT", PAD + 10, y)
        keepToggle:SetPoint("RIGHT", tabContent, "RIGHT", -PAD, 0)
        widgetRefs.keepInPlace = keepToggle
        y = y - FORM_ROW
    end

    y = y - 2  -- Small spacing after section

    -- Live-update: listen for anchor changes from layout mode
    local listenerRegistered = false
    local function RegisterLiveUpdates()
        if listenerRegistered then return end
        listenerRegistered = true
        local QUI = _G.QUI
        if QUI and QUI.RegisterMessage then
            QUI:RegisterMessage("QUI_FRAME_ANCHOR_CHANGED", function(_, changedKey, data)
                if changedKey ~= frameKey then return end
                -- Re-read DB values and update widgets
                local db = self:GetFrameDB(frameKey)
                if not db then return end
                if widgetRefs.sliderX and widgetRefs.sliderX.SetValue then
                    widgetRefs.sliderX:SetValue(db.offsetX or 0, true)
                end
                if widgetRefs.sliderY and widgetRefs.sliderY.SetValue then
                    widgetRefs.sliderY:SetValue(db.offsetY or 0, true)
                end
                if widgetRefs.anchorDropdown and widgetRefs.anchorDropdown.SetValue then
                    widgetRefs.anchorDropdown:SetValue(db.parent or "screen", true)
                end
                if widgetRefs.fromPoint and widgetRefs.fromPoint.SetValue then
                    widgetRefs.fromPoint:SetValue(db.point or "CENTER", true)
                end
                if widgetRefs.toPoint and widgetRefs.toPoint.SetValue then
                    widgetRefs.toPoint:SetValue(db.relative or "CENTER", true)
                end
            end)
        end
    end

    local function UnregisterLiveUpdates()
        if not listenerRegistered then return end
        listenerRegistered = false
        local QUI = _G.QUI
        if QUI and QUI.UnregisterMessage then
            pcall(QUI.UnregisterMessage, QUI, "QUI_FRAME_ANCHOR_CHANGED")
        end
    end

    -- Register immediately and unregister on hide
    RegisterLiveUpdates()
    tabContent:HookScript("OnHide", function()
        UnregisterLiveUpdates()
    end)
    tabContent:HookScript("OnShow", function()
        RegisterLiveUpdates()
    end)

    return y, widgetRefs
end

---------------------------------------------------------------------------
-- CREATE ANCHOR DROPDOWN
-- Parameters:
--   parent: Parent frame
--   label: Label text
--   settingsDB: Settings database table
--   anchorKey: Key name in settingsDB for anchor value (e.g., "anchor", "anchorTo")
--   x, y: Position
--   width: Width (optional, defaults to full width minus padding)
--   onChange: Callback function when value changes
--   includeList: Optional list of anchor values to include
--   excludeList: Optional list of anchor values to exclude
-- Returns: dropdown widget
---------------------------------------------------------------------------
function QUI_Anchoring_Options:CreateAnchorDropdown(parent, label, settingsDB, anchorKey, x, y, width, onChange, includeList, excludeList, excludeSelf)
    if not ns.QUI_Anchoring or not ns.QUI_Anchoring.GetAnchorTargetList then
        return nil
    end

    local GUI = GetGUI()
    if not GUI then
        return nil
    end

    -- Get anchor options list (support dynamic options via function)
    local function GetAnchorOptions()
        return ns.QUI_Anchoring:GetAnchorTargetList(includeList, excludeList, excludeSelf)
    end
    local anchorOptions = GetAnchorOptions()

    -- Create dropdown using GUI helper (pass optionsFunction for dynamic updates)
    local dropdown = GUI:CreateFormDropdown(parent, label, anchorOptions, anchorKey, settingsDB, onChange,
        { description = ns.L["Which frame this one anchors to. Pick a QUI frame, a Blizzard frame, or the screen; use From Point and To Point below to choose how the two frames align."] },
        { searchable = true, collapsible = true })
    -- Anchor targets may not be registered yet when options build; preserve the saved
    -- value in the display text instead of clearing it.
    dropdown.preserveUnknownValue = true

    if x and y then
        dropdown:SetPoint("TOPLEFT", x, y)
    end

    if width then
        dropdown:SetPoint("RIGHT", parent, "RIGHT", -(x or 0), 0)
    end

    return dropdown
end

function QUI_Anchoring_Options:GetNinePointAnchorOptions()
    return {
        {value = "TOPLEFT", text = ns.L["Top Left"]},
        {value = "TOP", text = ns.L["Top Center"]},
        {value = "TOPRIGHT", text = ns.L["Top Right"]},
        {value = "LEFT", text = ns.L["Center Left"]},
        {value = "CENTER", text = ns.L["Center"]},
        {value = "RIGHT", text = ns.L["Center Right"]},
        {value = "BOTTOMLEFT", text = ns.L["Bottom Left"]},
        {value = "BOTTOM", text = ns.L["Bottom Center"]},
        {value = "BOTTOMRIGHT", text = ns.L["Bottom Right"]},
    }
end
