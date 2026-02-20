---------------------------------------------------------------------------
-- QUI Skinning Base
-- Shared utilities for all skinning modules.
-- Loaded first via skinning.xml so all skinning files can reference ns.SkinBase.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

local SkinBase = {}
ns.SkinBase = SkinBase

-- TAINT SAFETY: Shared weak-keyed state table for storing custom properties
-- on Blizzard frames without tainting their frame tables. Any skinning module
-- that operates on registered Edit Mode system frames MUST use this instead
-- of writing properties directly on the frame (e.g., frame.quiBackdrop).
-- Usage: SkinBase.State(frame).quiBackdrop = ...
local _frameState = setmetatable({}, { __mode = "k" })
function SkinBase.State(f)
    if not _frameState[f] then _frameState[f] = {} end
    return _frameState[f]
end

---------------------------------------------------------------------------
-- GetPixelSize(frame, default)
-- Returns the pixel-perfect edge size for the given frame.
---------------------------------------------------------------------------
function SkinBase.GetPixelSize(frame, default)
    local core = Helpers.GetCore()
    if core and type(core.GetPixelSize) == "function" then
        local px = core:GetPixelSize(frame)
        if type(px) == "number" and px > 0 then
            return px
        end
    end
    return default or 1
end

---------------------------------------------------------------------------
-- GetSkinColors()
-- Returns accent + background colors: sr, sg, sb, sa, bgr, bgg, bgb, bga
---------------------------------------------------------------------------
function SkinBase.GetSkinColors()
    return Helpers.GetSkinColors()
end

---------------------------------------------------------------------------
-- CreateBackdrop(frame, sr, sg, sb, sa, bgr, bgg, bgb, bga)
-- Creates (or updates) a pixel-perfect QUI backdrop on the given frame.
-- Stores the backdrop as frame.quiBackdrop for backward compatibility,
-- AND in SkinBase.State(frame).quiBackdrop for taint-safe access.
---------------------------------------------------------------------------
function SkinBase.CreateBackdrop(frame, sr, sg, sb, sa, bgr, bgg, bgb, bga)
    local state = SkinBase.State(frame)
    if not state.quiBackdrop then
        state.quiBackdrop = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        state.quiBackdrop:SetAllPoints()
        state.quiBackdrop:SetFrameLevel(frame:GetFrameLevel())
        state.quiBackdrop:EnableMouse(false)
    end
    -- Backward compat: also store on the frame for callers that read frame.quiBackdrop.
    -- This writes a tainted key on the frame table, which is fine for non-Edit-Mode
    -- frames. Edit Mode system frames should use SkinBase.State(frame).quiBackdrop.
    frame.quiBackdrop = state.quiBackdrop

    local px = SkinBase.GetPixelSize(state.quiBackdrop, 1)
    state.quiBackdrop:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = px,
        insets = { left = px, right = px, top = px, bottom = px },
    })
    state.quiBackdrop:SetBackdropColor(bgr, bgg, bgb, bga)
    state.quiBackdrop:SetBackdropBorderColor(sr, sg, sb, sa)
end

---------------------------------------------------------------------------
-- StripTextures(frame)
-- Hides all Texture regions on a frame (alpha -> 0).
---------------------------------------------------------------------------
function SkinBase.StripTextures(frame)
    if not frame then return end
    for i = 1, frame:GetNumRegions() do
        local region = select(i, frame:GetRegions())
        if region and region:IsObjectType("Texture") then
            region:SetAlpha(0)
        end
    end
end
