-- tests/unit/groupframes_clickcast_friend_enemy_test.lua
-- Run: lua tests/unit/groupframes_clickcast_friend_enemy_test.lua
--
-- Tests for per-binding Friendly/Enemy/Any target filter via
-- helpbutton/harmbutton secure attribute remap on the per-frame proxy.
--
-- Validates:
--   - friend keyboard binding: helpbutton-<vbtn> set, cast on "friend<vbtn>"
--     with a plain /cast [@mouseover] macro (NOT a 3-clause help/harm macro)
--   - enemy keyboard binding: harmbutton-<vbtn> set, cast on "enemy<vbtn>"
--   - "any" binding: NO helpbutton/harmbutton; cast on base vbtn with 3-clause macro
--   - after ClearFrameClickCast (unregister): helpbutton/harmbutton + remapped attrs cleared

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
            return tbl, function(key) local s = tbl[key]; if not s then s = {}; tbl[key] = s end; return s end
        end,
        DeepCopy = DeepCopy,
    },
}

-- Load the module fresh each scenario.
local function loadModule(clickCast)
    inCombat = false
    createdFrames = {}
    _G.QUI_ClickCastHeader = nil
    _G.QUI = { db = { char = { clickCast = DeepCopy(clickCast) }, profile = {} } }

    local child = NewFrame("Button", "QUI_TestUnit1", nil, "SecureUnitButtonTemplate")
    local partyHeader = NewFrame("Frame", "QUI_TestPartyHeader", nil, "SecureGroupHeaderTemplate")
    partyHeader.attributes["child1"] = child
    ns.QUI_GroupFrames = {
        headers = { party = partyHeader, raid = false, self = false },
        raidGroupHeaders = {},
    }

    assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
    local GFCC = assert(ns.QUI_GroupFrameClickCast, "clickcast module must expose its API")

    local eventFrame
    for _, f in ipairs(createdFrames) do
        if f.events and f.events["PLAYER_ENTERING_WORLD"] and f.scripts and f.scripts.OnEvent then
            eventFrame = f
            break
        end
    end
    assert(eventFrame, "could not find event frame")
    eventFrame.scripts.OnEvent(eventFrame, "PLAYER_ENTERING_WORLD")
    return GFCC, child, eventFrame
end

---------------------------------------------------------------------------
-- Scenario 1: Friend keyboard binding (key F, friend=true)
-- helpbutton-keyf = "friendkeyf", type-friendkeyf = "macro",
-- macrotext-friendkeyf = plain /cast [@mouseover] (NOT 3-clause help/harm)
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { key = "F", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774, friend = true },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "child missing clickcast-proxyname after setup")
    local proxy = assert(_G[proxyName], "proxy not found in _G: " .. tostring(proxyName))

    assert(proxy:GetAttribute("helpbutton-keyf") == "friendkeyf",
        "friend binding: expected helpbutton-keyf = 'friendkeyf', got: "
        .. tostring(proxy:GetAttribute("helpbutton-keyf")))

    assert(proxy:GetAttribute("type-friendkeyf") == "macro",
        "friend binding: expected type-friendkeyf = 'macro', got: "
        .. tostring(proxy:GetAttribute("type-friendkeyf")))

    local mt = proxy:GetAttribute("macrotext-friendkeyf")
    assert(mt, "friend binding: macrotext-friendkeyf is nil")
    assert(mt:find("@mouseover", 1, true),
        "friend binding: macro missing @mouseover: " .. tostring(mt))
    -- Must NOT be the 3-clause help/harm double-gate
    assert(not mt:find(",help,", 1, true) and not mt:find(",harm,", 1, true),
        "friend binding: macro must be plain single-clause, not 3-clause help/harm: " .. tostring(mt))

    -- Base vbtn must NOT have a cast macro (remap takes over)
    -- harmbutton must NOT be set
    assert(proxy:GetAttribute("harmbutton-keyf") == nil,
        "friend binding must not set harmbutton-keyf")

    print("OK: friend keyboard binding sets helpbutton-keyf + plain @mouseover macro on friendkeyf")
end

---------------------------------------------------------------------------
-- Scenario 2: Enemy keyboard binding (key F, enemy=true)
-- harmbutton-keyf = "enemykeyf", type-enemykeyf = "macro"
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { key = "F", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774, enemy = true },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "child missing clickcast-proxyname after setup")
    local proxy = assert(_G[proxyName], "proxy not found in _G")

    assert(proxy:GetAttribute("harmbutton-keyf") == "enemykeyf",
        "enemy binding: expected harmbutton-keyf = 'enemykeyf', got: "
        .. tostring(proxy:GetAttribute("harmbutton-keyf")))

    assert(proxy:GetAttribute("type-enemykeyf") == "macro",
        "enemy binding: expected type-enemykeyf = 'macro', got: "
        .. tostring(proxy:GetAttribute("type-enemykeyf")))

    local mt = proxy:GetAttribute("macrotext-enemykeyf")
    assert(mt, "enemy binding: macrotext-enemykeyf is nil")
    assert(mt:find("@mouseover", 1, true),
        "enemy binding: macro missing @mouseover: " .. tostring(mt))
    assert(not mt:find(",help,", 1, true) and not mt:find(",harm,", 1, true),
        "enemy binding: macro must be plain single-clause: " .. tostring(mt))

    assert(proxy:GetAttribute("helpbutton-keyf") == nil,
        "enemy binding must not set helpbutton-keyf")

    print("OK: enemy keyboard binding sets harmbutton-keyf + plain @mouseover macro on enemykeyf")
end

---------------------------------------------------------------------------
-- Scenario 3: Any binding (no friend/enemy) — regression guard
-- NO helpbutton/harmbutton; cast on base vbtn "keyf" with 3-clause macro
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { key = "F", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774 },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "child missing clickcast-proxyname")
    local proxy = assert(_G[proxyName], "proxy not found in _G")

    assert(proxy:GetAttribute("helpbutton-keyf") == nil,
        "any binding must NOT set helpbutton-keyf")
    assert(proxy:GetAttribute("harmbutton-keyf") == nil,
        "any binding must NOT set harmbutton-keyf")

    local mt = proxy:GetAttribute("macrotext-keyf")
    assert(mt, "any binding: macrotext-keyf is nil (regression)")
    assert(mt:find("@mouseover", 1, true),
        "any binding: macro missing @mouseover")
    -- 3-clause guard: must include both help and harm clauses
    assert(mt:find(",help,", 1, true) or mt:find("help,nodead", 1, true),
        "any binding: macro must be 3-clause with help clause: " .. tostring(mt))

    print("OK: any binding (no filter) uses base vbtn with 3-clause macro — no helpbutton/harmbutton")
end

---------------------------------------------------------------------------
-- Scenario 4: ClearFrameClickCast clears helpbutton/harmbutton + remapped attrs
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { key = "F", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774, friend = true },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "precondition: proxy registered")
    local proxy = assert(_G[proxyName], "proxy in _G")

    -- Precondition: attrs are set
    assert(proxy:GetAttribute("helpbutton-keyf") == "friendkeyf",
        "precondition: helpbutton-keyf must be set before clear")
    assert(proxy:GetAttribute("type-friendkeyf") == "macro",
        "precondition: type-friendkeyf must be set before clear")

    -- Disable click-cast: triggers ClearFrameClickCast for all registered frames
    _G.QUI.db.char.clickCast.enabled = false
    GFCC:RefreshBindings()

    assert(proxy:GetAttribute("helpbutton-keyf") == nil,
        "after clear: helpbutton-keyf must be nil, got: "
        .. tostring(proxy:GetAttribute("helpbutton-keyf")))
    assert(proxy:GetAttribute("type-friendkeyf") == nil,
        "after clear: type-friendkeyf must be nil, got: "
        .. tostring(proxy:GetAttribute("type-friendkeyf")))
    assert(proxy:GetAttribute("macrotext-friendkeyf") == nil,
        "after clear: macrotext-friendkeyf must be nil")

    print("OK: ClearFrameClickCast removes helpbutton/harmbutton and remapped attrs")
end

---------------------------------------------------------------------------
-- Scenario 5: Friend MOUSE binding (LeftButton, friend=true)
-- helpbutton1 = "friend1" (NO dash — numeric suffix), type-friend1, macrotext-friend1
-- Regression guard for FIX 1: numeric suffix must NOT produce "helpbutton-1"
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "LeftButton", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774, friend = true },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "mouse friend: child missing clickcast-proxyname after setup")
    local proxy = assert(_G[proxyName], "mouse friend: proxy not found in _G: " .. tostring(proxyName))

    -- Numeric suffix → NO dash: helpbutton1 (not helpbutton-1)
    assert(proxy:GetAttribute("helpbutton1") == "friend1",
        "mouse friend: expected helpbutton1 = 'friend1' (no dash), got: "
        .. tostring(proxy:GetAttribute("helpbutton1"))
        .. " (wrong key helpbutton-1 has: " .. tostring(proxy:GetAttribute("helpbutton-1")) .. ")")

    assert(proxy:GetAttribute("type-friend1") == "macro",
        "mouse friend: expected type-friend1 = 'macro', got: "
        .. tostring(proxy:GetAttribute("type-friend1")))

    local mt = proxy:GetAttribute("macrotext-friend1")
    assert(mt, "mouse friend: macrotext-friend1 is nil")
    assert(mt:find("@mouseover", 1, true),
        "mouse friend: macro missing @mouseover: " .. tostring(mt))
    assert(not mt:find(",help,", 1, true) and not mt:find(",harm,", 1, true),
        "mouse friend: macro must be plain single-clause, not 3-clause: " .. tostring(mt))

    -- harmbutton1 must NOT be set
    assert(proxy:GetAttribute("harmbutton1") == nil,
        "mouse friend: must not set harmbutton1")

    print("OK: friend mouse binding sets helpbutton1 (no dash) + plain @mouseover macro on friend1")
end

---------------------------------------------------------------------------
-- Scenario 6: Enemy MOUSE binding (RightButton, enemy=true)
-- harmbutton2 = "enemy2" (NO dash), type-enemy2, macrotext-enemy2
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "RightButton", modifiers = "", actionType = "spell",
              spell = "Rejuvenation", spellID = 774, enemy = true },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "mouse enemy: child missing clickcast-proxyname after setup")
    local proxy = assert(_G[proxyName], "mouse enemy: proxy not found in _G")

    -- Numeric suffix → NO dash: harmbutton2 (not harmbutton-2)
    assert(proxy:GetAttribute("harmbutton2") == "enemy2",
        "mouse enemy: expected harmbutton2 = 'enemy2' (no dash), got: "
        .. tostring(proxy:GetAttribute("harmbutton2"))
        .. " (wrong key harmbutton-2 has: " .. tostring(proxy:GetAttribute("harmbutton-2")) .. ")")

    assert(proxy:GetAttribute("type-enemy2") == "macro",
        "mouse enemy: expected type-enemy2 = 'macro', got: "
        .. tostring(proxy:GetAttribute("type-enemy2")))

    local mt = proxy:GetAttribute("macrotext-enemy2")
    assert(mt, "mouse enemy: macrotext-enemy2 is nil")
    assert(mt:find("@mouseover", 1, true),
        "mouse enemy: macro missing @mouseover: " .. tostring(mt))

    assert(proxy:GetAttribute("helpbutton2") == nil,
        "mouse enemy: must not set helpbutton2")

    print("OK: enemy mouse binding sets harmbutton2 (no dash) + plain @mouseover macro on enemy2")
end

---------------------------------------------------------------------------
-- Scenario 7: Modified MOUSE binding (LeftButton + shift, friend=true)
-- Engine reads: attr name = "shift-helpbutton1" (prefix before attr, numeric btnNum)
--              remapped button value = "friend1" (numeric base, NOT prefixed)
--              cast attrs: "shift-type-friend1", "shift-macrotext-friend1"
-- OLD (broken) names: "helpbutton-shift-1", "friendshift-1", "type-friendshift-1"
---------------------------------------------------------------------------
do
    local GFCC, child = loadModule({
        enabled = true,
        _migratedFromProfile = true,
        rootSpellMigrationDone = true,
        bindings = {
            { button = "LeftButton", modifiers = "shift", actionType = "spell",
              spell = "Rejuvenation", spellID = 774, friend = true },
        },
    })

    local proxyName = child:GetAttribute("clickcast-proxyname")
    assert(proxyName, "modified mouse friend: child missing clickcast-proxyname after setup")
    local proxy = assert(_G[proxyName], "modified mouse friend: proxy not found in _G: " .. tostring(proxyName))

    -- Correct engine-format attr name: prefix BEFORE attr name, numeric btnNum (no dash)
    assert(proxy:GetAttribute("shift-helpbutton1") == "friend1",
        "modified mouse friend: expected shift-helpbutton1 = 'friend1', got: "
        .. tostring(proxy:GetAttribute("shift-helpbutton1")))

    assert(proxy:GetAttribute("shift-type-friend1") == "macro",
        "modified mouse friend: expected shift-type-friend1 = 'macro', got: "
        .. tostring(proxy:GetAttribute("shift-type-friend1")))

    local mt = proxy:GetAttribute("shift-macrotext-friend1")
    assert(mt, "modified mouse friend: shift-macrotext-friend1 is nil")
    assert(mt:find("@mouseover", 1, true),
        "modified mouse friend: macro missing @mouseover: " .. tostring(mt))
    assert(not mt:find(",help,", 1, true) and not mt:find(",harm,", 1, true),
        "modified mouse friend: macro must be plain single-clause: " .. tostring(mt))

    -- Confirm the OLD broken attribute name is NOT set
    assert(proxy:GetAttribute("helpbutton-shift-1") == nil,
        "modified mouse friend: old broken attr 'helpbutton-shift-1' must NOT be set")

    print("OK: modified mouse friend binding uses shift-helpbutton1 + friend1 + shift-type-friend1")
end

print("OK: groupframes_clickcast_friend_enemy_test")
