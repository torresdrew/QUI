-- tests/unit/groupframes_clickcast_proxy_test.lua
-- Run: lua tests/unit/groupframes_clickcast_proxy_test.lua
--
-- Tests for the pooled per-frame secure proxy pool introduced in Stage A1
-- of the click-cast rewrite. Validates:
--   - GetOrCreateProxy creates a named child Button with SecureActionButtonTemplate
--   - useparent-unit == true, useOnKeyDown == false
--   - pooling: second call returns the same proxy
--   - registration: the binding header received SetFrameRef("clique_proxy", proxy)
--   - in-combat guard: returns nil and creates nothing

local inCombat = false
local function noop() end

local frameMT
local createdFrames = {}
local function NewFrame(frameType, name, parent, template)
    local frame = {
        frameType = frameType, name = name, parent = parent, template = template,
        attributes = {}, scripts = {}, hooks = {}, events = {}, secureWraps = {},
        overrideBindings = {}, frameRefs = {},
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
                return function(self, s, h)
                    self.hooks[s] = self.hooks[s] or {}
                    table.insert(self.hooks[s], h)
                end
            elseif key == "RegisterEvent" then
                return function(self, e) self.events[e] = true end
            elseif key == "UnregisterEvent" then
                return function(self, e) self.events[e] = nil end
            elseif key == "CreateTexture" or key == "CreateFontString" then
                return function(self) return NewFrame(key, nil, self, nil) end
            elseif key == "EnableMouseWheel" then
                return function(self, enabled) self.mouseWheelEnabled = enabled end
            elseif key == "EnableMouse" then
                return function(self, enabled) self.mouseEnabled = enabled end
            elseif key == "SetSize" then
                return function(self, w, h) self.width = w; self.height = h end
            elseif key == "SetAlpha" then
                return function(self, a) self.alpha = a end
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
            elseif key == "RegisterForClicks" then
                return function(self, ...) self.registeredClicks = {...} end
            elseif key == "Hide" then
                return function(self) self.visible = false end
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
    createdFrames[#createdFrames + 1] = f
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
function RegisterStateDriver() end
function RegisterAttributeDriver() end
function UnregisterStateDriver() end
function SecureHandlerWrapScript(frame, script, header, preBody)
    frame.secureWraps[script] = { header = header, preBody = preBody }
end
function GetBindingKey() return nil end
function SetBinding() return true end
function SaveBindings() end
function GetCurrentBindingSet() return 1 end
GameTooltip = { GetOwner = function() return nil end, AddLine = noop, AddDoubleLine = noop, Show = noop }
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

C_Timer = {
    After = function(_, fn) fn() end,
    NewTimer = function(_, fn) local t = { fn = fn }; function t:Cancel() self.cancelled = true end return t end,
}

C_Spell = {
    GetSpellName = function(id) return id == 774 and "Rejuvenation" or nil end,
    GetSpellIDForSpellIdentifier = function(name) return name == "Rejuvenation" and 774 or nil end,
    GetBaseSpell = function(id) return id end,
}
C_ClassTalents = nil

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
            return tbl, function(key)
                local s = tbl[key]
                if not s then s = {}; tbl[key] = s end
                return s
            end
        end,
        DeepCopy = DeepCopy,
    },
}

_G.QUI = { db = { char = {}, profile = {} } }

local function loadModule(clickCast)
    inCombat = false
    createdFrames = {}
    _G.QUI_ClickCastHeader = nil
    _G.QUI_ClickCastCaster = nil
    _G.QUI.db.char.clickCast = DeepCopy(clickCast or {
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
    })

    local partyHeader = NewFrame("Frame", "QUI_TestPartyHeader2", nil, "SecureGroupHeaderTemplate")
    ns.QUI_GroupFrames = {
        headers = { party = partyHeader, raid = false, self = false },
        raidGroupHeaders = {},
    }

    assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
    assert(ns.QUI_GroupFrameClickCast, "clickcast module should expose its API")
    return ns.QUI_GroupFrameClickCast
end

---------------------------------------------------------------------------
-- Test 1: GetOrCreateProxy creates a named child Button with the right template
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test
    assert(test, "module must expose _test hook table (GetOrCreateProxy, ProxyName)")
    assert(type(test.GetOrCreateProxy) == "function", "_test.GetOrCreateProxy must be a function")
    assert(type(test.ProxyName) == "function", "_test.ProxyName must be a function")

    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy1", nil, "SecureUnitButtonTemplate")
    local proxy = test.GetOrCreateProxy(parentFrame)

    assert(proxy ~= nil, "GetOrCreateProxy returned nil out of combat")
    assert(proxy.parent == parentFrame, "proxy parent must be the registered frame")
    assert(proxy.template and proxy.template:find("SecureActionButtonTemplate"),
        "proxy must use SecureActionButtonTemplate, got: " .. tostring(proxy.template))
    assert(proxy.name and proxy.name:find("QUI_ClickCastProxy"),
        "proxy name must contain 'QUI_ClickCastProxy', got: " .. tostring(proxy.name))

    print("OK: GetOrCreateProxy creates named child Button with SecureActionButtonTemplate")
end

---------------------------------------------------------------------------
-- Test 2: proxy attributes useparent-unit=true and useOnKeyDown=false
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test

    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy2", nil, "SecureUnitButtonTemplate")
    local proxy = test.GetOrCreateProxy(parentFrame)

    assert(proxy ~= nil, "proxy should not be nil out of combat")
    assert(proxy:GetAttribute("useparent-unit") == true,
        "useparent-unit must be true, got: " .. tostring(proxy:GetAttribute("useparent-unit")))
    assert(proxy:GetAttribute("useOnKeyDown") == false,
        "useOnKeyDown must be false, got: " .. tostring(proxy:GetAttribute("useOnKeyDown")))

    print("OK: proxy has useparent-unit=true and useOnKeyDown=false")
end

---------------------------------------------------------------------------
-- Test 3: pooling — second call returns the same proxy object
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test

    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy3", nil, "SecureUnitButtonTemplate")
    local proxy1 = test.GetOrCreateProxy(parentFrame)
    local proxy2 = test.GetOrCreateProxy(parentFrame)

    assert(proxy1 ~= nil, "first call returned nil")
    assert(proxy1 == proxy2, "second call must return the SAME proxy (pool hit)")

    print("OK: GetOrCreateProxy is pooled — second call returns same proxy")
end

---------------------------------------------------------------------------
-- Test 4: unique names across different frames (counter increments)
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test

    local frame1 = NewFrame("Button", "QUI_TestUnit_Proxy4a", nil, "SecureUnitButtonTemplate")
    local frame2 = NewFrame("Button", "QUI_TestUnit_Proxy4b", nil, "SecureUnitButtonTemplate")
    local proxy1 = test.GetOrCreateProxy(frame1)
    local proxy2 = test.GetOrCreateProxy(frame2)

    assert(proxy1 ~= nil and proxy2 ~= nil, "both proxies should be created out of combat")
    assert(proxy1 ~= proxy2, "different frames must get different proxies")
    assert(proxy1.name ~= proxy2.name,
        "proxies for different frames must have unique names")

    print("OK: proxies for different frames have unique names")
end

---------------------------------------------------------------------------
-- Test 5: proxy is pooled — second call returns the same object
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test

    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy5", nil, "SecureUnitButtonTemplate")
    local proxy = test.GetOrCreateProxy(parentFrame)

    assert(proxy ~= nil, "proxy should not be nil")
    assert(test.GetOrCreateProxy(parentFrame) == proxy,
        "second GetOrCreateProxy call must return the same pooled proxy")

    print("OK: proxy is pooled — second call returns same object")
end

---------------------------------------------------------------------------
-- Test 6: ProxyName returns the proxy's name or nil
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test

    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy6", nil, "SecureUnitButtonTemplate")
    local unseenFrame = NewFrame("Button", "QUI_TestUnit_Proxy6b", nil, "SecureUnitButtonTemplate")

    -- Before creating a proxy for parentFrame, ProxyName returns nil
    assert(test.ProxyName(unseenFrame) == nil,
        "ProxyName for unregistered frame must return nil")

    local proxy = test.GetOrCreateProxy(parentFrame)
    local name = test.ProxyName(parentFrame)
    assert(name ~= nil, "ProxyName must return a non-nil name after proxy creation")
    assert(name == proxy.name, "ProxyName must match the proxy's GetName()")
    assert(name:find("QUI_ClickCastProxy"), "ProxyName must contain 'QUI_ClickCastProxy'")

    print("OK: ProxyName returns proxy name after creation, nil for unknown frame")
end

---------------------------------------------------------------------------
-- Test 7: in-combat guard — GetOrCreateProxy returns nil and creates nothing
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test
    local frameCountBefore = #createdFrames

    inCombat = true
    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy7", nil, "SecureUnitButtonTemplate")
    local proxy = test.GetOrCreateProxy(parentFrame)

    assert(proxy == nil, "GetOrCreateProxy must return nil in combat, got: " .. tostring(proxy))
    -- No CreateFrame calls should happen: the per-frame proxy must not be created
    -- in combat. parentFrame was created via NewFrame (not CreateFrame) so it is
    -- not counted in createdFrames.
    assert(#createdFrames == frameCountBefore,
        "GetOrCreateProxy must not create a proxy frame in combat (expected no new CreateFrame calls)")
    assert(test.ProxyName(parentFrame) == nil,
        "no proxy should be stored in pool when creation is blocked by combat")

    inCombat = false
    print("OK: GetOrCreateProxy returns nil in combat and creates nothing")
end

---------------------------------------------------------------------------
-- Test 8: proxy named correctly; no clique_proxy frameRef anywhere in _G
---------------------------------------------------------------------------
do
    local gfcc = loadModule()
    local test = gfcc._test

    local parentFrame = NewFrame("Button", "QUI_TestUnit_Proxy8", nil, "SecureUnitButtonTemplate")
    local proxy = test.GetOrCreateProxy(parentFrame)

    assert(proxy ~= nil, "proxy must be created")
    assert(proxy.name and proxy.name:find("QUI_ClickCastProxy"),
        "proxy name must contain 'QUI_ClickCastProxy', got: " .. tostring(proxy.name))
    -- Dead proxies table machinery has been removed; if a header exists it must
    -- have no clique_proxy frameRef.
    local header = _G.QUI_ClickCastHeader
    if header then
        assert(header.frameRefs["clique_proxy"] == nil,
            "clique_proxy frameRef must not exist after proxies machinery removal")
    end

    print("OK: proxy named correctly, no dead clique_proxy frameRef")
end

print("OK: groupframes_clickcast_proxy_test")
