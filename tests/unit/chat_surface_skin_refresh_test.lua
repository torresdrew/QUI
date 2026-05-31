-- tests/unit/chat_surface_skin_refresh_test.lua
-- Run: lua tests/unit/chat_surface_skin_refresh_test.lua
--
-- Regression guard for "the chat frame glass/border doesn't follow a live
-- skin/accent color change until /reload" (sibling of the custom-button bug).
--
-- Root cause: the chat frame glass border always tracks the skin
-- (GetChatSurfaceColors -> Helpers.GetSkinBorderColor) and its bg tracks the skin
-- unless the user picked a custom glass color, but CreateGlassBackdrop is only
-- re-run by Skinning.SkinAll on the chat module's "chat"-group refresh. A
-- skin-color change fires Registry:RefreshAll("skinning"), which only refreshes
-- group == "skinning" modules, so the chat surface was skipped and kept its old
-- color.
--
-- The fix registers a chat-surface re-skin with the "skinning" group. This test
-- drives the real skinning.lua SkinAll path through the real registration and a
-- simulated skin-color change, asserting the glass border re-colors.

-- luacheck: globals CreateFrame C_Timer NUM_CHAT_WINDOWS ChatFrame1

local function approx(a, b) return a and math.abs(a - b) < 1e-4 end

local NOOP = function() end
local NewFrame
local M = {}
function M:GetFrameLevel() return self.frameLevel end
function M:GetName() return self._name end
function M:IsForbidden() return false end
function M:GetChildren() return (table.unpack or unpack)(self._children) end
function M:CreateTexture() return NewFrame() end
function M:SetVertexColor(r, g, b, a) self._texColor = { r, g, b, a } end
for _, name in ipairs({
    "SetFrameLevel", "SetFrameStrata", "SetSize", "SetWidth", "SetHeight", "Show", "Hide",
    "SetPoint", "SetAllPoints", "ClearAllPoints", "EnableMouse", "SetTexture", "SetAlpha",
    "RegisterEvent", "UnregisterEvent", "SetScript", "HookScript", "SetParent",
}) do
    M[name] = NOOP
end
local frameMeta = { __index = M }
NewFrame = function(name)
    return setmetatable({ _children = {}, _name = name, frameLevel = 2 }, frameMeta)
end

-- Mutable skin border the chat surface tracks: {r,g,b}.
local SKIN_BORDER = { 0.10, 0.20, 0.30 }

local settings = { enabled = true, glass = { enabled = true } }

local registrations = {}
local Registry = {
    Register = function(_, name, def) registrations[name] = def end,
    RefreshAll = function(_, group)
        for _, def in pairs(registrations) do
            if def.refresh and (not group or def.group == group) then def.refresh() end
        end
    end,
}

-- Chat internals (`I`) the skinning leaf reads through. GetChatSurfaceColors and
-- ApplySurfaceStyle live in chat.lua; here they are stubbed so the test drives
-- the REAL skinning.lua SkinAll/CreateGlassBackdrop wiring while observing the
-- color that gets applied.
local I = {
    skinnedFrames = {},
    chatBackdrops = setmetatable({}, { __mode = "k" }),
    GetSettings = function() return settings end,
    IsChatEnabled = function(s) return s and s.enabled end,
    IsTemporaryChatFrame = function() return true end,
    IsChatMessagingLockedDown = function() return false end,
    GetChatSurfaceColors = function()
        return { 0, 0, 0, 0.25 }, { SKIN_BORDER[1], SKIN_BORDER[2], SKIN_BORDER[3], 0.55 }
    end,
    ApplySurfaceStyle = function(frame, _, borderColor)
        frame._appliedBorderR, frame._appliedBorderG, frame._appliedBorderB = borderColor[1], borderColor[2], borderColor[3]
    end,
}

local ns = {
    Helpers = { IsSecretValue = function() return false end },
    UIKit = {},
    SkinBase = {},
    Registry = Registry,
    QUI = { Chat = { _internals = I } },
}

CreateFrame = function(_, name) return NewFrame(name) end
C_Timer = { After = function() end }
NUM_CHAT_WINDOWS = 1
ChatFrame1 = NewFrame("ChatFrame1")
-- hooksecurefunc intentionally left nil so the load-time hook installers no-op.

assert(loadfile("modules/chat/skinning.lua"))("QUI", ns)

-- The fix must register a chat-surface re-skin under the "skinning" group.
local reg = registrations["chatSurfaceSkin"]
assert(reg and reg.group == "skinning" and type(reg.refresh) == "function",
    "FIX: chat surface skinning must register a 'skinning'-group refresh")

-- Initial skin at the base border color.
reg.refresh()
local backdrop = I.chatBackdrops[ChatFrame1]
assert(backdrop, "skinning must create the chat glass backdrop")
assert(approx(backdrop._appliedBorderR, SKIN_BORDER[1]) and approx(backdrop._appliedBorderB, SKIN_BORDER[3]),
    "precondition: glass border starts at the base skin color")

-- Simulate the user changing the skin border color, then the skinning refresh.
SKIN_BORDER = { 0.70, 0.65, 0.20 }
ns.Registry:RefreshAll("skinning")

assert(approx(backdrop._appliedBorderR, SKIN_BORDER[1]) and approx(backdrop._appliedBorderG, SKIN_BORDER[2])
    and approx(backdrop._appliedBorderB, SKIN_BORDER[3]),
    "FIX: a skinning refresh must re-color the chat glass border to the new skin color")

print("OK: chat_surface_skin_refresh_test")
