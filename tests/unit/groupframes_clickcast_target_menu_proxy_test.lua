-- tests/unit/groupframes_clickcast_target_menu_proxy_test.lua
-- Run: lua tests/unit/groupframes_clickcast_target_menu_proxy_test.lua
--
-- WoW 12.0.7's SecureUnitButton_OnClick gates the native "target" and
-- "togglemenu" actions behind C_ClickBindings -- only Blizzard's default
-- unmodified left->target and right->menu interactions are registered, so a
-- MODIFIED (or non-default-button) click resolving to either type returns
-- ClickBindingType.None and is silently dropped. The fix routes those bindings
-- through a hidden child SecureActionButton via the ungated "click" action.
--
-- This test asserts:
--   * plain unmodified left->target stays a NATIVE type="target"
--   * plain unmodified right->menu stays a NATIVE type="togglemenu"
--   * alt+left->target becomes type="click" + clickbutton=<proxy>
--   * ctrl+right->menu becomes type="click" + clickbutton=<proxy>
--   * the proxy is a SecureActionButton with useparent-unit + per-button type

local inCombat = false
local function noop() end

-- ---- frame mock ---------------------------------------------------------
local frameMT
local function NewFrame(frameType, name, parent, template)
    local frame = {
        frameType = frameType, name = name, parent = parent, template = template,
        attributes = {}, scripts = {}, hooks = {}, events = {},
        secureWraps = {}, overrideBindings = {}, frameRefs = {},
    }
    frameMT = frameMT or {
        __index = function(_, key)
            if key == "SetAttribute" then
                return function(self, attr, value)
                    assert(not inCombat, "must not mutate secure attributes in combat")
                    self.attributes[attr] = value
                end
            elseif key == "GetAttribute" then
                return function(self, attr) return self.attributes[attr] end
            elseif key == "GetName" then
                return function(self) return self.name end
            elseif key == "SetScript" then
                return function(self, s, h) self.scripts[s] = h end
            elseif key == "HookScript" then
                return function(self, s, h) self.hooks[s] = self.hooks[s] or {}; table.insert(self.hooks[s], h) end
            elseif key == "RegisterEvent" then
                return function(self, e) self.events[e] = true end
            elseif key == "CreateTexture" or key == "CreateFontString" then
                return function(self) return NewFrame(key, nil, self, nil) end
            elseif key == "EnableMouseWheel" then
                return function(self, enabled) self.mouseWheelEnabled = enabled end
            elseif key == "ClearBindings" then
                return function(self) self.overrideBindings = {} end
            elseif key == "SetBindingClick" then
                return function(self, priority, bindKey, target, button)
                    self.overrideBindings[bindKey] = { priority = priority, target = target, button = button }
                end
            elseif key == "SetFrameRef" then
                return function(self, label, ref) self.frameRefs[label] = ref end
            elseif key == "GetFrameRef" then
                return function(self, label) return self.frameRefs[label] end
            elseif key == "IsVisible" then
                return function(self) return self.visible ~= false end
            elseif key == "GetMousePosition" then
                return function(self)
                    if self.underMouse == true then return 0.5, 0.5 end
                    return nil
                end
            elseif key == "Execute" then
                return function(self, snippet)
                    local loader = loadstring or load
                    local chunk, err = loader("local self = ...\n" .. snippet)
                    assert(chunk, err)
                    return chunk(self)
                end
            end
            return noop
        end,
    }
    return setmetatable(frame, frameMT)
end

function CreateFrame(frameType, name, parent, template)
    local f = NewFrame(frameType, name, parent, template)
    if name then _G[name] = f end
    return f
end

function InCombatLockdown() return inCombat end
function UnitClass() return "Druid", "DRUID" end
function UnitIsDeadOrGhost() return false end
function UnitIsConnected() return true end
function UnitIsPlayer() return true end
function GetSpecialization() return 1 end
function GetSpecializationInfo() return 102 end
SecureHandlerWrapScript = noop
RegisterStateDriver = noop
RegisterAttributeDriver = noop
UnregisterStateDriver = noop
GameTooltip = { GetOwner = function() return nil end, AddLine = noop, AddDoubleLine = noop, Show = noop }
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

C_Timer = { After = function() end, NewTimer = function() return { Cancel = noop } end }

C_Spell = {
    GetSpellName = function() return nil end,
    GetSpellIDForSpellIdentifier = function() return nil end,
    GetBaseSpell = function(id) return id end,
}
C_ClassTalents = nil

-- ---- ns / Helpers -------------------------------------------------------
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, vv in pairs(v) do t[k] = DeepCopy(vv) end
    return t
end

local ns = {
    Helpers = {
        CreateStateTable = function()
            local tbl = setmetatable({}, { __mode = "k" })
            return tbl
        end,
        DeepCopy = DeepCopy,
    },
}

-- ---- DB: target + menu bindings, plain and modified --------------------
_G.QUI = {
    db = {
        char = {
            clickCast = {
                enabled = true,
                _migratedFromProfile = true,
                rootSpellMigrationDone = true,
                bindings = {
                    { button = "LeftButton",  modifiers = "",     actionType = "target" },
                    { button = "LeftButton",  modifiers = "alt",  actionType = "target" },
                    { button = "RightButton", modifiers = "",     actionType = "menu"   },
                    { button = "RightButton", modifiers = "ctrl", actionType = "menu"   },
                },
            },
        },
        profile = {},
    },
}

-- ---- group frame headers mock ------------------------------------------
local child = NewFrame("Button", "QUI_TestUnit1", nil, "SecureUnitButtonTemplate")
local partyHeader = NewFrame("Frame", "QUI_TestPartyHeader", nil, "SecureGroupHeaderTemplate")
partyHeader.attributes["child1"] = child
ns.QUI_GroupFrames = {
    headers = { party = partyHeader, raid = false, self = false },
    raidGroupHeaders = {},
}

-- ---- load + apply -------------------------------------------------------
assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
local GFCC = assert(ns.QUI_GroupFrameClickCast, "module should export QUI_GroupFrameClickCast")
GFCC:Initialize()
assert(GFCC:IsEnabled(), "click-cast should be enabled after Initialize")
GFCC:RegisterAllFrames()

local a = child.attributes

-- In the proxy routing model every click on the frame delegates through the
-- click-cast proxy (frame type1="click", clickbutton1=proxy).  Cast and action
-- attrs live on the proxy, not the frame directly.
local proxyName = child:GetAttribute("clickcast-proxyname")
assert(proxyName, "registered frame must have clickcast-proxyname after setup")
local proxy = assert(_G[proxyName], "click-cast proxy must be in _G")
local pa = proxy.attributes

-- ---- 1. plain unmodified left->target: frame routes to proxy, proxy is "target"
assert(a["type1"] == "click",
    "frame type1 must be 'click' (delegates all clicks to proxy), got: " .. tostring(a["type1"]))
assert(a["clickbutton1"] == proxy,
    "frame clickbutton1 must be the click-cast proxy")
assert(pa["type1"] == "target",
    "proxy type1 must be 'target' for plain left->target, got: " .. tostring(pa["type1"]))
assert(pa["clickbutton1"] == nil,
    "proxy must NOT add another click indirection for plain target")

-- ---- 2. plain unmodified right->menu: proxy carries togglemenu
assert(a["type2"] == "click",
    "frame type2 must be 'click' (delegates to proxy), got: " .. tostring(a["type2"]))
assert(pa["type2"] == "togglemenu",
    "proxy type2 must be 'togglemenu' for plain right->menu, got: " .. tostring(pa["type2"]))
assert(pa["clickbutton2"] == nil,
    "proxy must NOT add another click indirection for plain menu")

-- ---- 3. alt+left->target: proxy routes through the ungated target sub-proxy
assert(pa["alt-type1"] == "click",
    "BUG: proxy alt-type1 must be 'click' to route modified target through ungated sub-proxy, got: "
    .. tostring(pa["alt-type1"]))
local tProxy = pa["alt-clickbutton1"]
assert(type(tProxy) == "table" and tProxy.template == "SecureActionButtonTemplate",
    "proxy alt-clickbutton1 must be a SecureActionButton target sub-proxy")
assert(tProxy.attributes["type1"] == "target" and tProxy.attributes["type"] == "target",
    "target sub-proxy must carry type=target on bare + numbered buttons")
assert(tProxy.attributes["useparent-unit"] == true,
    "target sub-proxy must resolve its unit from the parent unit button")
assert(tProxy.attributes["useOnKeyDown"] == false,
    "target sub-proxy must act on up-click regardless of cast-on-keydown CVar")

-- ---- 4. ctrl+right->menu: proxy routes through the ungated menu sub-proxy
assert(pa["ctrl-type2"] == "click",
    "BUG: proxy ctrl-type2 must be 'click' to route modified menu through ungated sub-proxy, got: "
    .. tostring(pa["ctrl-type2"]))
local mProxy = pa["ctrl-clickbutton2"]
assert(type(mProxy) == "table" and mProxy.template == "SecureActionButtonTemplate",
    "proxy ctrl-clickbutton2 must be a SecureActionButton menu sub-proxy")
assert(mProxy.attributes["type2"] == "togglemenu",
    "menu sub-proxy must carry type=togglemenu on the numbered button")

-- ---- 5. target and menu sub-proxies are distinct
assert(tProxy ~= mProxy, "target and menu sub-proxies must be separate buttons")

-- ---- 6. RefreshBindings is idempotent
inCombat = false
GFCC:RefreshBindings()
-- After refresh with the same bindings, routing is re-applied.
local proxyName2 = child:GetAttribute("clickcast-proxyname")
local proxy2 = proxyName2 and _G[proxyName2]
assert(proxy2 and proxy2.attributes["alt-type1"] == "click",
    "after RefreshBindings, modified target routing should persist on proxy")

print("OK: groupframes_clickcast_target_menu_proxy_test")
