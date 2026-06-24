-- tests/unit/groupframes_clickcast_click_direction_test.lua
-- Run: lua tests/unit/groupframes_clickcast_click_direction_test.lua
--
-- Tests for the clickDirection setting (down / up / both).
-- Validates:
--   - clickDirection="down" (or nil) → source frame RegisterForClicks("AnyDown")
--   - clickDirection="up"            → source frame RegisterForClicks("AnyUp")
--   - clickDirection="both"          → source frame RegisterForClicks("AnyUp","AnyDown")
--   - the per-frame proxy RegisterForClicks("AnyUp") regardless of setting
--
-- Driven via RefreshBindings after setting clickCast.clickDirection,
-- and via the _test.GetOrCreateProxy + _test.GetButtonDirections hooks.

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

-- The party header child that SetupFrameClickCast registers.
local function MakePartyChild(name)
    return NewFrame("Button", name, nil, "SecureUnitButtonTemplate")
end

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

    local child1 = MakePartyChild("QUI_TestDirChild1_" .. math.random(1e6))
    local partyHeader = NewFrame("Frame", "QUI_TestDirHeader_" .. math.random(1e6), nil, "SecureGroupHeaderTemplate")
    -- Header:GetAttribute("child1") returns the unit button child
    partyHeader.attributes["child1"] = child1

    ns.QUI_GroupFrames = {
        headers = { party = partyHeader, raid = false, self = false },
        raidGroupHeaders = {},
    }

    assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
    assert(ns.QUI_GroupFrameClickCast, "clickcast module must expose its API")
    return ns.QUI_GroupFrameClickCast, child1, partyHeader
end

-- Helper: return the registeredClicks table for a source frame after RefreshBindings
-- Bindings must be present so SetupFrameClickCast runs; use one mouse binding.
local function makeClickCastWithDir(direction)
    local cc = {
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "LeftButton", modifiers = "", actionType = "spell", spell = "Rejuvenation", spellID = 774 },
        },
    }
    if direction ~= nil then
        cc.clickDirection = direction
    end
    return cc
end

---------------------------------------------------------------------------
-- Test 1: GetButtonDirections — "down" (default) → "AnyDown"
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir("down"))
    local test = gfcc._test
    assert(test.GetButtonDirections, "_test must expose GetButtonDirections")

    local v1, v2 = test.GetButtonDirections()
    assert(v1 == "AnyDown", 'GetButtonDirections("down") v1 must be "AnyDown", got: ' .. tostring(v1))
    assert(v2 == nil, 'GetButtonDirections("down") must return only one value, got v2=' .. tostring(v2))

    print("OK: GetButtonDirections down → AnyDown")
end

---------------------------------------------------------------------------
-- Test 2: GetButtonDirections — nil direction defaults to "AnyDown"
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir(nil))
    local test = gfcc._test

    local v1, v2 = test.GetButtonDirections()
    assert(v1 == "AnyDown", 'GetButtonDirections(nil) must default to "AnyDown", got: ' .. tostring(v1))
    assert(v2 == nil, 'GetButtonDirections(nil) must return only one value')

    print("OK: GetButtonDirections nil → AnyDown")
end

---------------------------------------------------------------------------
-- Test 3: GetButtonDirections — "up" → "AnyUp"
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir("up"))
    local test = gfcc._test

    local v1, v2 = test.GetButtonDirections()
    assert(v1 == "AnyUp", 'GetButtonDirections("up") must be "AnyUp", got: ' .. tostring(v1))
    assert(v2 == nil, 'GetButtonDirections("up") must return only one value')

    print("OK: GetButtonDirections up → AnyUp")
end

---------------------------------------------------------------------------
-- Test 4: GetButtonDirections — "both" → "AnyUp", "AnyDown"
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir("both"))
    local test = gfcc._test

    local v1, v2 = test.GetButtonDirections()
    assert(v1 == "AnyUp",   'GetButtonDirections("both") v1 must be "AnyUp", got: '   .. tostring(v1))
    assert(v2 == "AnyDown", 'GetButtonDirections("both") v2 must be "AnyDown", got: ' .. tostring(v2))

    print("OK: GetButtonDirections both → AnyUp, AnyDown")
end

---------------------------------------------------------------------------
-- Test 5: UseActionOnKeyDown — "down" → true
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir("down"))
    local test = gfcc._test
    assert(test.UseActionOnKeyDown, "_test must expose UseActionOnKeyDown")

    assert(test.UseActionOnKeyDown() == true,
        'UseActionOnKeyDown with direction="down" must return true')

    print("OK: UseActionOnKeyDown down → true")
end

---------------------------------------------------------------------------
-- Test 6: UseActionOnKeyDown — nil direction → true
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir(nil))
    local test = gfcc._test

    assert(test.UseActionOnKeyDown() == true,
        'UseActionOnKeyDown with direction=nil must return true')

    print("OK: UseActionOnKeyDown nil → true")
end

---------------------------------------------------------------------------
-- Test 7: UseActionOnKeyDown — "both" → true
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir("both"))
    local test = gfcc._test

    assert(test.UseActionOnKeyDown() == true,
        'UseActionOnKeyDown with direction="both" must return true')

    print("OK: UseActionOnKeyDown both → true")
end

---------------------------------------------------------------------------
-- Test 8: UseActionOnKeyDown — "up" → false
---------------------------------------------------------------------------
do
    local gfcc = loadModule(makeClickCastWithDir("up"))
    local test = gfcc._test

    assert(test.UseActionOnKeyDown() == false,
        'UseActionOnKeyDown with direction="up" must return false')

    print("OK: UseActionOnKeyDown up → false")
end

---------------------------------------------------------------------------
-- Test 9: Source frame RegisterForClicks("AnyDown") when direction="down"
---------------------------------------------------------------------------
do
    local gfcc, sourceFrame = loadModule(makeClickCastWithDir("down"))
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    local rc = sourceFrame.registeredClicks
    assert(type(rc) == "table", "source frame must have had RegisterForClicks called (got: " .. type(rc) .. ")")
    assert(#rc == 1, "direction=down: expected 1 arg to RegisterForClicks, got " .. tostring(#rc))
    assert(rc[1] == "AnyDown",
        'direction=down: source frame must be registered for "AnyDown", got: ' .. tostring(rc[1]))

    print("OK: source frame RegisterForClicks AnyDown when direction=down")
end

---------------------------------------------------------------------------
-- Test 10: Source frame RegisterForClicks("AnyUp") when direction="up"
---------------------------------------------------------------------------
do
    local gfcc, sourceFrame = loadModule(makeClickCastWithDir("up"))
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    local rc = sourceFrame.registeredClicks
    assert(type(rc) == "table", "source frame must have had RegisterForClicks called (got: " .. type(rc) .. ")")
    assert(#rc == 1, "direction=up: expected 1 arg to RegisterForClicks, got " .. tostring(#rc))
    assert(rc[1] == "AnyUp",
        'direction=up: source frame must be registered for "AnyUp", got: ' .. tostring(rc[1]))

    print("OK: source frame RegisterForClicks AnyUp when direction=up")
end

---------------------------------------------------------------------------
-- Test 11: Source frame RegisterForClicks("AnyUp","AnyDown") when direction="both"
---------------------------------------------------------------------------
do
    local gfcc, sourceFrame = loadModule(makeClickCastWithDir("both"))
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    local rc = sourceFrame.registeredClicks
    assert(type(rc) == "table", "source frame must have had RegisterForClicks called (got: " .. type(rc) .. ")")
    assert(#rc == 2, "direction=both: expected 2 args to RegisterForClicks, got " .. tostring(#rc))
    assert(rc[1] == "AnyUp",
        'direction=both: arg1 must be "AnyUp", got: ' .. tostring(rc[1]))
    assert(rc[2] == "AnyDown",
        'direction=both: arg2 must be "AnyDown", got: ' .. tostring(rc[2]))

    print("OK: source frame RegisterForClicks AnyUp,AnyDown when direction=both")
end

---------------------------------------------------------------------------
-- Test 12: Per-frame proxy RegisterForClicks("AnyUp") regardless of direction
---------------------------------------------------------------------------
do
    for _, dir in ipairs({ "down", "up", "both" }) do
        local gfcc, sourceFrame = loadModule(makeClickCastWithDir(dir))
        gfcc:Initialize()
        gfcc:RegisterAllFrames()

        local test = gfcc._test
        -- proxy was created by SetupFrameClickCast during RegisterAllFrames
        local proxy = test.GetOrCreateProxy(sourceFrame)
        assert(proxy, "proxy must exist after Initialize+RegisterAllFrames for dir=" .. tostring(dir))
        local rc = proxy.registeredClicks
        assert(type(rc) == "table",
            "proxy must have had RegisterForClicks called for dir=" .. tostring(dir)
            .. " (got: " .. type(rc) .. ")")
        assert(#rc == 1,
            "proxy: expected 1 arg to RegisterForClicks for dir=" .. tostring(dir)
            .. ", got " .. tostring(#rc))
        assert(rc[1] == "AnyUp",
            'proxy must always be registered for "AnyUp" regardless of direction, dir='
            .. tostring(dir) .. ", got: " .. tostring(rc[1]))
    end

    print("OK: proxy RegisterForClicks AnyUp regardless of clickDirection")
end

---------------------------------------------------------------------------
-- Test 13: RefreshBindings re-applies direction on direction change
---------------------------------------------------------------------------
do
    local gfcc, sourceFrame = loadModule(makeClickCastWithDir("down"))
    gfcc:Initialize()
    gfcc:RegisterAllFrames()

    -- Verify initial state: AnyDown
    local rc = sourceFrame.registeredClicks
    assert(type(rc) == "table" and rc[1] == "AnyDown",
        "initial direction=down: expected AnyDown, got: " .. tostring(rc and rc[1]))

    -- Change direction to "up" and refresh
    _G.QUI.db.char.clickCast.clickDirection = "up"
    gfcc:RefreshBindings()

    -- Source frame should now be registered for AnyUp
    rc = sourceFrame.registeredClicks
    assert(type(rc) == "table",
        "source frame must have registeredClicks after RefreshBindings (got: " .. type(rc) .. ")")
    assert(#rc == 1 and rc[1] == "AnyUp",
        'after change to "up" + RefreshBindings: expected AnyUp, got: ' .. tostring(rc and rc[1]))

    print("OK: RefreshBindings re-applies direction on direction change")
end

print("OK: groupframes_clickcast_click_direction_test")
