-- tests/unit/groupframes_clickcast_default_preservation_test.lua
-- Run: lua tests/unit/groupframes_clickcast_default_preservation_test.lua
--
-- Regression guard for the wildcard-routing regression:
--   WriteFrameRouting must route ONLY the mouse buttons that have a click-cast
--   binding.  Unbound buttons must stay untouched so Blizzard's native
--   left-click=target and right-click=menu survive on group/unit frames.
--
-- RED case (documented inline): old wildcard code wrote *type1/*type2/*type*
--   + blanket type1/type2 regardless of what was bound, hijacking ALL mouse
--   buttons and silencing unbound ones.
-- GREEN case: per-bound-button routing — only the configured button gets
--   type<N>="click" + clickbutton<N>=proxy; all others are untouched.

local inCombat = false
local function noop() end
local SPELL_NAMES = { [774] = "Rejuvenation" }
local NAME_TO_ID  = { Rejuvenation = 774 }

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
    GetSpellName = function(id) return SPELL_NAMES[id] end,
    GetSpellIDForSpellIdentifier = function(name) return NAME_TO_ID[name] end,
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
    _G.QUI.db.char.clickCast = DeepCopy(clickCast)

    local child = NewFrame("Button", "QUI_TestUnitDP1", nil, "SecureUnitButtonTemplate")
    local partyHeader = NewFrame("Frame", "QUI_TestPartyHeaderDP", nil, "SecureGroupHeaderTemplate")
    partyHeader.attributes["child1"] = child

    ns.QUI_GroupFrames = {
        headers = { party = partyHeader, raid = false, self = false },
        raidGroupHeaders = {},
    }

    assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
    assert(ns.QUI_GroupFrameClickCast, "module must export QUI_GroupFrameClickCast")
    return ns.QUI_GroupFrameClickCast, child
end

---------------------------------------------------------------------------
-- Scenario A: ONLY left-click bound → left routed, right UNTOUCHED (native menu)
-- RED with old wildcard code: type2="click" + clickbutton2=proxy would be set,
-- killing the native right-click menu.
-- GREEN with per-button fix: type2 remains nil, clickbutton2 remains nil.
---------------------------------------------------------------------------
do
    local cc = {
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "LeftButton", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774 },
        },
    }

    local gfcc, child = loadModule(cc)
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "frame must have clickcast-proxyname after setup")
    local proxy = assert(_G[proxyName], "proxy must be in _G")
    local a = child.attributes

    -- Left-click IS bound → must be routed to proxy.
    assert(a["type1"] == "click",
        "LEFT bound: frame type1 must be 'click' (routes to proxy), got: " .. tostring(a["type1"]))
    assert(a["clickbutton1"] == proxy,
        "LEFT bound: frame clickbutton1 must be the proxy")

    -- Right-click is NOT bound → must NOT be touched (native menu must survive).
    -- OLD CODE (RED): set type2="click" + clickbutton2=proxy → this assert would FAIL.
    -- NEW CODE (GREEN): type2 stays nil.
    assert(a["type2"] == nil,
        "RIGHT unbound: frame type2 must be nil (native menu must survive), got: " .. tostring(a["type2"]))
    assert(a["clickbutton2"] == nil,
        "RIGHT unbound: frame clickbutton2 must be nil, got: " .. tostring(a["clickbutton2"]))

    -- No wildcard hijack.
    assert(a["*type*"] == nil,
        "no *type* wildcard must be written, got: " .. tostring(a["*type*"]))
    assert(a["*type1"] == nil,
        "no *type1 wildcard must be written, got: " .. tostring(a["*type1"]))
    assert(a["*type2"] == nil,
        "no *type2 wildcard must be written, got: " .. tostring(a["*type2"]))
    assert(a["*clickbutton*"] == nil,
        "no *clickbutton* wildcard must be written, got: " .. tostring(a["*clickbutton*"]))

    print("OK [GREEN]: left-only binding routes type1 only; right stays native (nil)")
end

---------------------------------------------------------------------------
-- Scenario B: NO mouse bindings (keyboard-only config) → NOTHING routed on frame.
-- OLD CODE (RED): blanket wildcards still written, killing ALL native interactions.
-- NEW CODE (GREEN): all routing attrs remain nil.
---------------------------------------------------------------------------
do
    local cc = {
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { key = "F", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774 },
        },
    }

    local gfcc, child = loadModule(cc)
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    local a = child.attributes

    -- No mouse binding → no frame routing at all.
    assert(a["type1"] == nil,
        "keyboard-only: frame type1 must be nil (no mouse bound), got: " .. tostring(a["type1"]))
    assert(a["type2"] == nil,
        "keyboard-only: frame type2 must be nil, got: " .. tostring(a["type2"]))
    assert(a["clickbutton1"] == nil,
        "keyboard-only: frame clickbutton1 must be nil, got: " .. tostring(a["clickbutton1"]))
    assert(a["clickbutton2"] == nil,
        "keyboard-only: frame clickbutton2 must be nil, got: " .. tostring(a["clickbutton2"]))
    assert(a["*type*"] == nil,
        "keyboard-only: no *type* wildcard, got: " .. tostring(a["*type*"]))

    -- clickcast-proxyname is still written (proxy exists for keyboard use).
    assert(child:GetAttribute("clickcast-proxyname") ~= nil,
        "keyboard-only: clickcast-proxyname must still be set (proxy needed for key binds)")

    print("OK [GREEN]: keyboard-only config writes no frame routing attrs; native clicks survive")
end

---------------------------------------------------------------------------
-- Scenario C: After ClearFrameClickCast, routed attrs are restored to backup
-- (nil, since the frame had no prior type1/clickbutton1).
---------------------------------------------------------------------------
do
    local cc = {
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "LeftButton", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774 },
        },
    }

    local gfcc, child = loadModule(cc)
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    -- Confirm routed before clearing.
    assert(child.attributes["type1"] == "click", "precondition: type1 routed before clear")

    -- Now disable (triggers ClearFrameClickCast internally via RefreshBindings).
    _G.QUI.db.char.clickCast.enabled = false
    gfcc:RefreshBindings()

    local a = child.attributes
    -- After clear, routing attrs must be gone (restored to original nil).
    assert(a["type1"] == nil,
        "after clear: type1 must be nil (restored from backup), got: " .. tostring(a["type1"]))
    assert(a["clickbutton1"] == nil,
        "after clear: clickbutton1 must be nil, got: " .. tostring(a["clickbutton1"]))
    assert(a["clickcast-proxyname"] == nil,
        "after clear: clickcast-proxyname must be nil")

    print("OK [GREEN]: ClearFrameClickCast restores routing attrs to pre-registration state")
end

---------------------------------------------------------------------------
-- Scenario D: Both left AND right bound → both routed; modifier-only binding
-- (shift+LeftButton) routes only the prefixed attr.
---------------------------------------------------------------------------
do
    local cc = {
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "LeftButton",  modifiers = "",      actionType = "spell",
              spell = "Rejuvenation", spellID = 774 },
            { button = "RightButton", modifiers = "",      actionType = "menu" },
            { button = "LeftButton",  modifiers = "shift", actionType = "spell",
              spell = "Rejuvenation", spellID = 774 },
        },
    }

    local gfcc, child = loadModule(cc)
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    local proxyName = child:GetAttribute("clickcast-proxyname")
    local proxy = assert(_G[proxyName], "proxy must exist")
    local a = child.attributes

    -- Unmodified left → routed.
    assert(a["type1"] == "click", "left bound: type1 must be 'click'")
    assert(a["clickbutton1"] == proxy, "left bound: clickbutton1 must be proxy")

    -- Unmodified right → routed (explicitly bound to menu).
    assert(a["type2"] == "click", "right bound: type2 must be 'click'")
    assert(a["clickbutton2"] == proxy, "right bound: clickbutton2 must be proxy")

    -- Shift+left → routed with shift- prefix.
    assert(a["shift-type1"] == "click",
        "shift+left bound: shift-type1 must be 'click', got: " .. tostring(a["shift-type1"]))
    assert(a["shift-clickbutton1"] == proxy,
        "shift+left bound: shift-clickbutton1 must be proxy")

    -- No wildcards written even when multiple buttons are bound.
    assert(a["*type*"]       == nil, "no *type* wildcard")
    assert(a["*clickbutton*"] == nil, "no *clickbutton* wildcard")

    print("OK [GREEN]: multi-binding routes only the exact per-button attrs; no wildcards")
end

print("OK: groupframes_clickcast_default_preservation_test")
