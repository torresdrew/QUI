-- tests/unit/chat_frame_editmode_size_persistence_test.lua
-- Run: lua tests/unit/chat_frame_editmode_size_persistence_test.lua
--
-- QUI owns ChatFrame1 size via its own profile (db.profile.chat.frameSize) and
-- re-applies it on login. It must NOT write Blizzard's Edit Mode layout: preset
-- layouts (Modern/Classic) regenerate on load and silently drop the change, so
-- the size reverted on /reload. This test verifies the resize path resizes the
-- live frame, stores the size in the QUI profile, and leaves Edit Mode untouched
-- (the manager below is a spy: any call into it is a regression).

local registeredFeature
local capturedSizeConfig
local settingChanges = {}

function InCombatLockdown() return false end

Enum = {
    EditModeChatFrameDisplayOnlySetting = { Width = 101, Height = 102 },
}

local chatFrame = {
    width = 420,
    height = 240,
    system = "ChatFrame",
    systemIndex = 1,
}

function chatFrame:GetWidth() return self.width end
function chatFrame:GetHeight() return self.height end
function chatFrame:SetSize(w, h)
    self.width = w
    self.height = h
end

_G.ChatFrame1 = chatFrame

function FCF_SetWindowSize(frame, w, h)
    frame:SetSize(w, h)
    frame.fcfSetWindowSize = { w, h }
end

function FCF_SavePositionAndDimensions(frame)
    frame.fcfSaved = true
end

-- Spy: a present, ready Edit Mode manager. QUI must never call into it.
EditModeManagerFrame = {
    layoutInfo = { activeLayout = 1, layouts = {} },
}
function EditModeManagerFrame:IsInitialized() return true end
function EditModeManagerFrame:OnSystemSettingChange(frame, setting, value)
    settingChanges[#settingChanges + 1] = { frame = frame, setting = setting, value = value }
end
function EditModeManagerFrame:SaveLayouts()
    self.savedLayouts = true
end

local fakeProfile = { chat = {} }

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        GetCore = function() return { db = { profile = fakeProfile } } end,
    },
    Settings = {
        ProviderFeatures = {
            Register = function(_, feature)
                if feature and feature.id == "chatFrame1" then
                    registeredFeature = feature
                end
            end,
        },
    },
    QUI_LayoutMode_Utils = {
        BuildPositionCollapsible = function() end,
        BuildSizeCollapsible = function(_, config)
            capturedSizeConfig = config
        end,
        StandardRelayout = function() end,
    },
}

assert(loadfile("modules/chat/settings/chat_frame1.lua"))("QUI", ns)

local function HasLookupKey(feature, lookupKey)
    if type(feature.lookupKeys) ~= "table" then return false end
    for _, key in ipairs(feature.lookupKeys) do
        if key == lookupKey then return true end
    end
    return false
end

assert(registeredFeature, "chatFrame1 feature should register")
assert(HasLookupKey(registeredFeature, "chatFrame1"), "chatFrame1 lookup should resolve to the main chat feature before mover-key fallback")
assert(registeredFeature.layoutPositionOnly == false, "chatFrame1 Layout Mode drawer should include Frame Size controls")
assert(registeredFeature.render and registeredFeature.render.layout, "chatFrame1 layout renderer should be available")
registeredFeature.render.layout({ GetHeight = function() return 1 end }, { providerKey = "chatFrame1" })
assert(capturedSizeConfig and capturedSizeConfig.setSize, "chatFrame1 size config should expose setSize")

-- setSize: resizes the live frame via Blizzard's chat API, saves the legacy
-- floating-chat dimensions, mirrors the size into the QUI profile, and leaves
-- Edit Mode untouched.
capturedSizeConfig.setSize(640, 320)

assert(chatFrame.fcfSetWindowSize[1] == 640 and chatFrame.fcfSetWindowSize[2] == 320, "ChatFrame1 should be resized through Blizzard's chat API")
assert(chatFrame.fcfSaved == true, "legacy floating chat dimensions should still be saved")
assert(fakeProfile.chat.frameSize and fakeProfile.chat.frameSize.w == 640 and fakeProfile.chat.frameSize.h == 320,
    "setSize should mirror the chat size into the QUI profile")
assert(#settingChanges == 0, "setSize must NOT write Edit Mode settings (preset layouts can't persist them)")
assert(EditModeManagerFrame.savedLayouts ~= true, "setSize must NOT save Edit Mode layouts")

-- Resize grips call PersistCurrentSize after StartSizing/StopMovingOrSizing.
chatFrame.width = 701
chatFrame.height = 333

assert(ns.QUI and ns.QUI.ChatFrame1Sizing and ns.QUI.ChatFrame1Sizing.PersistCurrentSize, "chat sizing helper should expose current-size persistence for resize grips")
ns.QUI.ChatFrame1Sizing.PersistCurrentSize(chatFrame)

assert(fakeProfile.chat.frameSize.w == 701 and fakeProfile.chat.frameSize.h == 333,
    "PersistCurrentSize should mirror the current size into the QUI profile")
assert(#settingChanges == 0, "PersistCurrentSize must NOT write Edit Mode settings")

-- Setting ChatFrame1 to its current size is a no-op.
chatFrame.fcfSetWindowSize = nil
chatFrame.fcfSaved = false
chatFrame.width = 430
chatFrame.height = 170
local changed = ns.QUI.ChatFrame1Sizing.SetSize(430, 170)
assert(changed == false, "setting ChatFrame1 to its current size should report no change")
assert(chatFrame.fcfSetWindowSize == nil, "no-op size writes should not call Blizzard's chat sizing API")
assert(chatFrame.fcfSaved == false, "no-op size writes should not save legacy dimensions")

-- ApplyStoredSize: re-applies the QUI-stored size to the live frame on login,
-- after Edit Mode restores the (possibly preset) layout size, so QUI's size
-- wins. Resizes via the chat API; never re-persists or touches Edit Mode.
settingChanges = {}
fakeProfile.chat.frameSize = { w = 512, h = 256 }
chatFrame.width, chatFrame.height = 300, 200
chatFrame.fcfSetWindowSize = nil

local applied = ns.QUI.ChatFrame1Sizing.ApplyStoredSize()
assert(applied == true, "ApplyStoredSize should resize the frame when the stored size differs")
assert(chatFrame.width == 512 and chatFrame.height == 256, "ApplyStoredSize should apply the stored dimensions to the live frame")
assert(chatFrame.fcfSetWindowSize and chatFrame.fcfSetWindowSize[1] == 512 and chatFrame.fcfSetWindowSize[2] == 256,
    "ApplyStoredSize should route through Blizzard's chat sizing API")
assert(#settingChanges == 0, "ApplyStoredSize should not touch Edit Mode")

-- No-op when the live frame already matches the stored size.
chatFrame.fcfSetWindowSize = nil
local reapplied = ns.QUI.ChatFrame1Sizing.ApplyStoredSize()
assert(reapplied == false, "ApplyStoredSize should no-op when the frame already matches the stored size")
assert(chatFrame.fcfSetWindowSize == nil, "ApplyStoredSize no-op should not touch the chat sizing API")

print("OK: chat_frame_editmode_size_persistence_test")
