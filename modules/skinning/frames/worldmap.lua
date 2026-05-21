---------------------------------------------------------------------------
-- WORLD MAP FRAME SKINNING
--
-- WorldMapFrame's chrome is split into two parts per
-- Blizzard_WorldMap/Blizzard_WorldMap.xml:28-:
--   - WorldMapFrame itself inherits MapCanvasFrameTemplate (just the scroll
--     container + canvas — no decorative chrome).
--   - WorldMapFrame.BorderFrame inherits PortraitFrameTemplateMinimizable,
--     which is what carries NineSlice / Bg / TopTileStreaks / PortraitContainer
--     / TitleContainer / CloseButton / MaximizeMinimizeFrame.
--
-- So skinning WorldMapFrame == skinning its BorderFrame, plus killing the
-- BlackoutFrame dim overlay and the InsetBorderTop separator.
---------------------------------------------------------------------------

local addonName, ns = ...
local SkinBase = ns.SkinBase
local GetCore = ns.Helpers.GetCore

local function IsSettingEnabled(key)
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    return settings and settings[key]
end

-- Build (or fetch) the LOW-strata fill frame that paints the QUI bg color
-- behind the map canvas. WorldMapFrame's title bar / chrome area sits
-- outside .ScrollContainer's bounds (Blizzard_WorldMap.xml:12-18), so a
-- fullscreen fill at LOW strata is invisible where the (opaque) map
-- covers it and visible only in the surrounding chrome — giving an
-- opaque QUI title bar without obscuring the map.
local function EnsureMapFill(frame)
    local fill = SkinBase.GetFrameData(frame, "mapFill")
    if fill then return fill end

    fill = CreateFrame("Frame", nil, frame)
    fill:SetAllPoints()
    fill:SetFrameStrata("LOW") -- behind ScrollContainer (MEDIUM)
    fill:EnableMouse(false)

    local tex = fill:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\Buttons\\WHITE8x8")
    fill.tex = tex

    SkinBase.SetFrameData(frame, "mapFill", fill)
    return fill
end

local function ApplyMapFillColor(frame)
    local fill = SkinBase.GetFrameData(frame, "mapFill")
    if not fill or not fill.tex then return end
    local _, _, _, _, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()
    fill.tex:SetVertexColor(bgr, bgg, bgb, bga or 1)
end

local function SkinWorldMap()
    if not IsSettingEnabled("skinWorldMap") then return end
    local frame = _G.WorldMapFrame
    if not frame or SkinBase.IsSkinned(frame) then return end

    -- BorderFrame carries the PortraitFrameTemplateMinimizable chrome.
    -- The shared helper handles chrome strip + backdrop + close button.
    -- Because BorderFrame is frameStrata="HIGH" and sits ABOVE the map
    -- canvas (.ScrollContainer at MEDIUM, child of WorldMapFrame —
    -- Blizzard_WorldMap.xml:12-43), we keep its backdrop's BORDER opaque
    -- (the outline must be in front of the map) but zero the FILL alpha
    -- (it would otherwise cover the map). The QUI fill is restored by a
    -- separate LOW-strata frame below.
    if frame.BorderFrame then
        SkinBase.SkinButtonFrameTemplate(frame.BorderFrame)
        local bd = SkinBase.GetBackdrop(frame.BorderFrame)
        if bd then
            local _, _, _, _, bgr, bgg, bgb = SkinBase.GetSkinColors()
            bd:SetBackdropColor(bgr, bgg, bgb, 0)
        end
        if frame.BorderFrame.Underlay then frame.BorderFrame.Underlay:Hide() end
        if frame.BorderFrame.InsetBorderTop then frame.BorderFrame.InsetBorderTop:Hide() end
    end

    EnsureMapFill(frame)
    ApplyMapFillColor(frame)

    SkinBase.MarkSkinned(frame)
end

local function RefreshWorldMap()
    local frame = _G.WorldMapFrame
    if not frame then return end
    if frame.BorderFrame then
        local bd = SkinBase.GetBackdrop(frame.BorderFrame)
        if bd then
            local sr, sg, sb, sa, bgr, bgg, bgb = SkinBase.GetSkinColors()
            -- Keep border opaque; fill stays alpha=0 so the map shows through.
            -- The opaque fill lives on the separate LOW-strata frame below.
            bd:SetBackdropColor(bgr, bgg, bgb, 0)
            bd:SetBackdropBorderColor(sr, sg, sb, sa)
        end
    end
    ApplyMapFillColor(frame)
end

_G.QUI_RefreshWorldMapColors = RefreshWorldMap
if ns.Registry then
    ns.Registry:Register("skinWorldMap", {
        refresh = RefreshWorldMap,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

SkinBase.OnAddOnLoaded("Blizzard_WorldMap", SkinWorldMap, 0.1)
