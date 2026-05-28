-- tests/unit/skinning_manual_pixel_backdrop_test.lua
-- Run: lua tests/unit/skinning_manual_pixel_backdrop_test.lua
-- luacheck: globals CreateFrame

local createdFrames = {}
local safeBackdropCalls = {}
local registeredRefresh

local function NewTexture()
    local texture = {
        points = {},
        visible = false,
    }

    function texture:ClearAllPoints()
        self.points = {}
    end

    function texture:SetPoint(...)
        self.points[#self.points + 1] = { ... }
    end

    function texture:SetHeight(height)
        self.height = height
    end

    function texture:SetWidth(width)
        self.width = width
    end

    function texture:SetTexture(file)
        self.file = file
    end

    function texture:SetColorTexture(r, g, b, a)
        self.colorTexture = { r, g, b, a }
    end

    function texture:SetVertexColor(r, g, b, a)
        self.color = { r, g, b, a }
    end

    function texture:Show()
        self.visible = true
    end

    function texture:Hide()
        self.visible = false
    end

    return texture
end

local function NewFrame(parent)
    local frame = {
        parent = parent,
        textures = {},
        points = {},
        shown = false,
        frameLevel = 4,
    }

    function frame:CreateTexture()
        local texture = NewTexture()
        self.textures[#self.textures + 1] = texture
        return texture
    end

    function frame:SetAllPoints()
        self.allPoints = true
    end

    function frame:SetFrameLevel(level)
        self.frameLevel = level
    end

    function frame:GetFrameLevel()
        return self.frameLevel
    end

    function frame:EnableMouse(enabled)
        self.mouseEnabled = enabled
    end

    function frame:ClearAllPoints()
        self.points = {}
    end

    function frame:SetPoint(...)
        self.points[#self.points + 1] = { ... }
    end

    function frame:Show()
        self.shown = true
    end

    createdFrames[#createdFrames + 1] = frame
    return frame
end

function CreateFrame(_, _, parent)
    return NewFrame(parent)
end

local ns = {
    Helpers = {
        CreateStateTable = function()
            return setmetatable({}, { __mode = "k" })
        end,
        GetCore = function()
            return {
                GetPixelSize = function()
                    return 0.5
                end,
                SafeSetBackdrop = function(frame, info, borderColor, bgColor)
                    safeBackdropCalls[#safeBackdropCalls + 1] = {
                        frame = frame,
                        info = info,
                        borderColor = borderColor,
                        bgColor = bgColor,
                    }
                    return true
                end,
            }
        end,
        SafeToNumber = function(value, default)
            return tonumber(value) or default
        end,
    },
    UIKit = {
        RegisterScaleRefresh = function(_, _, callback)
            registeredRefresh = callback
        end,
    },
}

assert(loadfile("modules/skinning/base.lua"))("QUI", ns)

local SkinBase = ns.SkinBase
local owner = NewFrame()

SkinBase.CreateBackdrop(owner, 0.6, 0.7, 0.8, 1, 0.1, 0.2, 0.3, 0.9)

local backdrop = SkinBase.GetBackdrop(owner)
assert(backdrop, "CreateBackdrop must create a cached backdrop frame")
assert(type(backdrop.SetBackdropColor) == "function",
    "plain pixel backdrop frames must expose SetBackdropColor for later refresh callers")
assert(type(backdrop.SetBackdropBorderColor) == "function",
    "plain pixel backdrop frames must expose SetBackdropBorderColor for later refresh callers")
assert(backdrop.textures[1].colorTexture[1] == 0.1 and backdrop.textures[1].colorTexture[4] == 0.9,
    "manual pixel backdrop background must use a solid color texture with the configured color")

backdrop:SetBackdropColor(0.2, 0.3, 0.4, 0.5)
backdrop:SetBackdropBorderColor(0.7, 0.8, 0.9, 1)

assert(backdrop._quiBgR == 0.2 and backdrop._quiBgA == 0.5,
    "manual SetBackdropColor must store the current background color")
assert(backdrop._quiBorderR == 0.7 and backdrop._quiBorderA == 1,
    "manual SetBackdropBorderColor must store the current border color")
assert(backdrop.textures[1].colorTexture[1] == 0.2 and backdrop.textures[1].colorTexture[4] == 0.5,
    "manual SetBackdropColor must recolor solid background textures directly")
assert(backdrop.textures[2].colorTexture[1] == 0.7 and backdrop.textures[2].colorTexture[4] == 1,
    "manual SetBackdropBorderColor must recolor solid border textures directly")

local native = NewFrame()
function native:SetBackdrop(info)
    self.backdropInfo = info
end
function native:SetBackdropColor(r, g, b, a)
    self.bgColor = { r, g, b, a }
end
function native:SetBackdropBorderColor(r, g, b, a)
    self.borderColor = { r, g, b, a }
end

SkinBase.ApplyPixelBackdrop(native, 1, true, true)
native._quiBgR, native._quiBgG, native._quiBgB, native._quiBgA = 0.11, 0.12, 0.13, 0.91
native._quiBorderR, native._quiBorderG, native._quiBorderB, native._quiBorderA = 0.61, 0.62, 0.63, 1
registeredRefresh(native)

local refreshed = safeBackdropCalls[#safeBackdropCalls]
assert(refreshed.bgColor and refreshed.bgColor[1] == 0.11 and refreshed.bgColor[4] == 0.91,
    "scale refresh must preserve stored native pixel backdrop background colors")
assert(refreshed.borderColor and refreshed.borderColor[1] == 0.61 and refreshed.borderColor[4] == 1,
    "scale refresh must preserve stored native pixel backdrop border colors")

print("OK: skinning_manual_pixel_backdrop_test")
