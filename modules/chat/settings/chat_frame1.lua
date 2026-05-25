local ADDON_NAME, ns = ...

local Helpers = ns.Helpers
ns.QUI = ns.QUI or {}
local ChatFrame1Sizing = ns.QUI.ChatFrame1Sizing or {}
ns.QUI.ChatFrame1Sizing = ChatFrame1Sizing

local Settings = ns.Settings
local ProviderFeatures = Settings and Settings.ProviderFeatures

-- ChatFrame1 size bounds. Lower limits match Blizzard's CHAT_FRAME_MIN_*; upper
-- limits are loose enough to allow large displays without being unbounded.
local CHAT_RESIZE_MIN_W, CHAT_RESIZE_MAX_W = 296, 1400
local CHAT_RESIZE_MIN_H, CHAT_RESIZE_MAX_H = 120, 900

local function IsChatLayoutLockedDown()
    local I = ns.QUI and ns.QUI.Chat and ns.QUI.Chat._internals
    return (type(InCombatLockdown) == "function" and InCombatLockdown())
        or (I and I.IsChatMessagingLockedDown and I.IsChatMessagingLockedDown())
end

local function SafeFrameNumber(value, fallback)
    if Helpers and Helpers.IsSecretValue and Helpers.IsSecretValue(value) then
        return fallback or 0
    end
    return tonumber(value) or fallback or 0
end

local function ReadSafeNumber(value)
    if Helpers and Helpers.IsSecretValue and Helpers.IsSecretValue(value) then
        return nil
    end
    return tonumber(value)
end

local function ReadRoundedFrameNumber(value)
    value = ReadSafeNumber(value)
    if not value then return nil end
    return math.floor(value + 0.5)
end

local function IsSameFrameSize(frame, width, height)
    if not frame or type(frame.GetWidth) ~= "function" or type(frame.GetHeight) ~= "function" then
        return false
    end

    local currentWidth = ReadRoundedFrameNumber(frame:GetWidth())
    local currentHeight = ReadRoundedFrameNumber(frame:GetHeight())
    if not currentWidth or not currentHeight then return false end

    return currentWidth == math.floor(width + 0.5)
        and currentHeight == math.floor(height + 0.5)
end

local function SaveLegacyChatDimensions(frame)
    if frame and _G.FCF_SavePositionAndDimensions then
        _G.FCF_SavePositionAndDimensions(frame)
    end
end

-- QUI-owned chat size store. Edit Mode preset layouts (Modern/Classic) are
-- regenerated from code on load, so a size written into a preset's active
-- layout can't be saved and reverts on /reload. QUI therefore owns chat-frame
-- size outright: we mirror it into the QUI profile and re-apply on login (see
-- ApplyStoredSize). We deliberately do NOT write Blizzard's Edit Mode layout.
local function GetChatProfileDB()
    local core = Helpers and Helpers.GetCore and Helpers.GetCore()
    return core and core.db and core.db.profile and core.db.profile.chat
end

local function StoreChatFrameSize(width, height)
    width = ReadSafeNumber(width)
    height = ReadSafeNumber(height)
    if not width or not height then return end
    local chatDB = GetChatProfileDB()
    if not chatDB then return end
    chatDB.frameSize = chatDB.frameSize or {}
    chatDB.frameSize.w = math.floor(width + 0.5)
    chatDB.frameSize.h = math.floor(height + 0.5)
end

function ChatFrame1Sizing.PersistSize(frame, width, height)
    frame = frame or _G.ChatFrame1
    -- Profile store is the source of truth; SaveLegacyChatDimensions keeps the
    -- legacy floating-chat config (position + dimensions) coherent. No Edit
    -- Mode layout write — see the store comment above.
    StoreChatFrameSize(width, height)
    SaveLegacyChatDimensions(frame)
    return true
end

-- Re-apply the QUI-stored chat size to the live frame. Called deferred on
-- login after Edit Mode restores its (possibly preset) layout size, so QUI's
-- size wins. Only resizes the live frame — it does not re-persist. No-op when
-- nothing is stored or the size already matches.
function ChatFrame1Sizing.ApplyStoredSize()
    local chatDB = GetChatProfileDB()
    local stored = chatDB and chatDB.frameSize
    if type(stored) ~= "table" then return false end
    local width = ReadSafeNumber(stored.w)
    local height = ReadSafeNumber(stored.h)
    if not width or not height then return false end
    local frame = _G.ChatFrame1
    if not frame then return false end
    if IsChatLayoutLockedDown() then return false end
    if IsSameFrameSize(frame, width, height) then return false end
    if _G.FCF_SetWindowSize then
        _G.FCF_SetWindowSize(frame, width, height)
    else
        frame:SetSize(width, height)
    end
    return true
end

function ChatFrame1Sizing.PersistCurrentSize(frame)
    frame = frame or _G.ChatFrame1
    if not frame or type(frame.GetWidth) ~= "function" or type(frame.GetHeight) ~= "function" then
        return false
    end

    local width = ReadSafeNumber(frame:GetWidth())
    local height = ReadSafeNumber(frame:GetHeight())
    if not width or not height then
        SaveLegacyChatDimensions(frame)
        return false
    end

    return ChatFrame1Sizing.PersistSize(frame, width, height)
end

function ChatFrame1Sizing.SetSize(width, height)
    local frame = _G.ChatFrame1
    if not frame or type(width) ~= "number" or type(height) ~= "number" then return false end
    if IsChatLayoutLockedDown() then return false end
    if IsSameFrameSize(frame, width, height) then return false end

    if _G.FCF_SetWindowSize then
        _G.FCF_SetWindowSize(frame, width, height)
    else
        frame:SetSize(width, height)
    end

    ChatFrame1Sizing.PersistSize(frame, width, height)

    if _G.QUI_RefreshChatSizeSliders then
        _G.QUI_RefreshChatSizeSliders()
    end

    return true
end

if not ProviderFeatures or type(ProviderFeatures.Register) ~= "function" then
    return
end

local function ChatGetSize()
    local f = _G.ChatFrame1
    if not f then return CHAT_RESIZE_MIN_W, CHAT_RESIZE_MIN_H end
    return SafeFrameNumber(f:GetWidth(), CHAT_RESIZE_MIN_W), SafeFrameNumber(f:GetHeight(), CHAT_RESIZE_MIN_H)
end

local function ChatSetSize(w, h)
    ChatFrame1Sizing.SetSize(w, h)
end

local function ApplyChat()
    if _G.QUI_RefreshChat then
        _G.QUI_RefreshChat()
    end
end

local function RenderChatLayout(host, options)
    local providerKey = (options and options.providerKey) or "chatFrame1"
    local U = ns.QUI_LayoutMode_Utils
    local Settings2 = ns.Settings
    local RenderAdapters = Settings2 and Settings2.RenderAdapters
    if not host or not U
        or type(U.BuildPositionCollapsible) ~= "function"
        or type(U.BuildSizeCollapsible) ~= "function"
        or type(U.StandardRelayout) ~= "function" then
        if RenderAdapters and type(RenderAdapters.RenderPositionOnly) == "function" then
            return RenderAdapters.RenderPositionOnly(host, providerKey)
        end
        return 80
    end

    local prevPosOnly = U._layoutModePositionOnly
    U._layoutModePositionOnly = false
    local sections = {}
    local function relayout() U.StandardRelayout(host, sections) end
    local ok, err = xpcall(function()
        U.BuildPositionCollapsible(host, providerKey, nil, sections, relayout)
        U.BuildSizeCollapsible(host, {
            getSize = ChatGetSize,
            setSize = ChatSetSize,
            minW = CHAT_RESIZE_MIN_W, maxW = CHAT_RESIZE_MAX_W,
            minH = CHAT_RESIZE_MIN_H, maxH = CHAT_RESIZE_MAX_H,
            widthDescription  = "ChatFrame1 width in pixels. Blizzard persists this across logout.",
            heightDescription = "ChatFrame1 height in pixels. Blizzard persists this across logout.",
        }, sections, relayout)
        relayout()
    end, function(msg) return msg end)
    U._layoutModePositionOnly = prevPosOnly
    if not ok and geterrorhandler then geterrorhandler()(err) end
    return host:GetHeight()
end

local function RegisterChatFeature(id, subPageIndex, chatSections, includeLayoutRenderer)
    local feature = {
        id = id,
        moverKey = "chatFrame1",
        lookupKeys = { id },
        category = "chat",
        nav = {
            tileId = "chat_tooltips",
            subPageIndex = subPageIndex,
        },
        getDB = function(profile)
            return profile and profile.chat
        end,
        apply = ApplyChat,
        providerKey = "chatFrame1",
        providerOptions = {
            chatSections = chatSections,
        },
        render = includeLayoutRenderer and {
            layout = RenderChatLayout,
        } or nil,
    }

    if includeLayoutRenderer then
        feature.layoutPositionOnly = false
    end

    ProviderFeatures:Register(feature)
end

RegisterChatFeature("chatFrame1", 1, "general", true)
RegisterChatFeature("chatFrame1Filters", 2, "filters")
RegisterChatFeature("chatFrame1ButtonBar", 3, "buttonBar")
RegisterChatFeature("chatFrame1Alerts", 4, "alerts")
RegisterChatFeature("chatFrame1History", 5, "history")
