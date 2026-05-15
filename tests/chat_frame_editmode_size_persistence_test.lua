-- tests/chat_frame_editmode_size_persistence_test.lua
-- Run: lua tests/chat_frame_editmode_size_persistence_test.lua

local registeredFeature
local capturedSizeConfig
local settingChanges = {}

function InCombatLockdown() return false end

Enum = {
    EditModeChatFrameDisplayOnlySetting = {
        Width = 101,
        Height = 102,
    },
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

local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
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

capturedSizeConfig.setSize(640, 320)

assert(chatFrame.fcfSetWindowSize[1] == 640 and chatFrame.fcfSetWindowSize[2] == 320, "ChatFrame1 should still be resized through Blizzard's chat API")
assert(chatFrame.fcfSaved == true, "legacy floating chat dimensions should still be saved for non-default chat compatibility")
assert(#settingChanges == 2, "ChatFrame1 resize should update Edit Mode width and height settings")
assert(settingChanges[1].frame == chatFrame and settingChanges[1].setting == Enum.EditModeChatFrameDisplayOnlySetting.Width and settingChanges[1].value == 640, "width should be synced to Edit Mode")
assert(settingChanges[2].frame == chatFrame and settingChanges[2].setting == Enum.EditModeChatFrameDisplayOnlySetting.Height and settingChanges[2].value == 320, "height should be synced to Edit Mode")
assert(EditModeManagerFrame.savedLayouts == true, "Edit Mode layouts should be saved so /reload keeps the new chat size")

settingChanges = {}
EditModeManagerFrame.savedLayouts = false
chatFrame.width = 701
chatFrame.height = 333

assert(ns.QUI and ns.QUI.ChatFrame1Sizing and ns.QUI.ChatFrame1Sizing.PersistCurrentSize, "chat sizing helper should expose current-size persistence for resize grips")
ns.QUI.ChatFrame1Sizing.PersistCurrentSize(chatFrame)

assert(#settingChanges == 2, "current ChatFrame1 size should be syncable after direct resize grips")
assert(settingChanges[1].value == 701 and settingChanges[2].value == 333, "current frame dimensions should be persisted exactly")
assert(EditModeManagerFrame.savedLayouts == true, "current-size persistence should save Edit Mode layouts")

settingChanges = {}
EditModeManagerFrame.savedLayouts = false
chatFrame.fcfSetWindowSize = nil
chatFrame.fcfSaved = false
chatFrame.width = 430
chatFrame.height = 170
_G.QUI_RefreshChatSizeSliders = function()
    error("no-op ChatFrame1 size refresh should not re-enter slider sync", 2)
end

local changed = ns.QUI.ChatFrame1Sizing.SetSize(430, 170)

assert(changed == false, "setting ChatFrame1 to its current size should report no change")
assert(chatFrame.fcfSetWindowSize == nil, "no-op ChatFrame1 size writes should not call Blizzard's chat sizing API")
assert(chatFrame.fcfSaved == false, "no-op ChatFrame1 size writes should not save legacy dimensions")
assert(#settingChanges == 0, "no-op ChatFrame1 size writes should not sync Edit Mode settings")
assert(EditModeManagerFrame.savedLayouts == false, "no-op ChatFrame1 size writes should not save Edit Mode layouts")

print("OK: chat_frame_editmode_size_persistence_test")
