-- tests/unit/groupframes_clickcast_roster_update_test.lua
-- Run: lua tests/unit/groupframes_clickcast_roster_update_test.lua
--
-- Regression: zoning into an instance (e.g. a follower dungeon) changes the
-- party roster. Secure group headers create/assign child unit buttons lazily as
-- the roster settles, often AFTER the one-shot PLAYER_ENTERING_WORLD catch-up.
-- Click-casting must be (re)applied to frames that appear on a roster change,
-- otherwise the new party frames have no bindings until the user /reloads.
-- The module must re-register frames on GROUP_ROSTER_UPDATE (out of combat
-- immediately; in combat deferred to PLAYER_REGEN_ENABLED).

local inCombat = false
local function noop() end

local SPELL_NAMES = { [774] = "Rejuvenation" }
local NAME_TO_ID  = { Rejuvenation = 774 }

local createdFrames = {}
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
            elseif key == "UnregisterEvent" then
                return function(self, e) self.events[e] = nil end
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
    setmetatable(frame, frameMT)
    table.insert(createdFrames, frame)
    return frame
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
RegisterAttributeDriver = noop
GameTooltip = { GetOwner = function() return nil end, AddLine = noop, AddDoubleLine = noop, Show = noop }
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

-- Debounce timers must run for the test; execute callbacks synchronously.
C_Timer = {
    After = function(_, fn) if fn then fn() end end,
    NewTimer = function(_, fn) if fn then fn() end return { Cancel = noop } end,
}

C_Spell = {
    GetSpellName = function(id) return SPELL_NAMES[id] end,
    GetSpellIDForSpellIdentifier = function(name) return NAME_TO_ID[name] end,
    GetBaseSpell = function(id) return id end,
}
C_ClassTalents = nil

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}; for k, vv in pairs(v) do t[k] = DeepCopy(vv) end; return t
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

_G.QUI = {
    db = {
        char = {
            clickCast = {
                enabled = true, _migratedFromProfile = true, rootSpellMigrationDone = true,
                bindings = {
                    { button = "LeftButton", modifiers = "", actionType = "spell",
                      spell = "Rejuvenation", spellID = 774 },
                },
            },
        },
        profile = {},
    },
}

-- Header starts with one child (player, solo) — mirrors a lazily-populated
-- SecureGroupHeader before zoning into a group instance.
local child1 = NewFrame("Button", "QUI_TestUnit1", nil, "SecureUnitButtonTemplate")
local partyHeader = NewFrame("Frame", "QUI_TestPartyHeader", nil, "SecureGroupHeaderTemplate")
partyHeader.attributes["child1"] = child1
ns.QUI_GroupFrames = {
    headers = { party = partyHeader, raid = false, self = false },
    raidGroupHeaders = {},
}

assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
local GFCC = assert(ns.QUI_GroupFrameClickCast)

-- Find the module's event frame (the one that listens for roster/zone events).
local eventFrame
for _, f in ipairs(createdFrames) do
    if f.events["PLAYER_ENTERING_WORLD"] and f.scripts["OnEvent"] then eventFrame = f break end
end
assert(eventFrame, "clickcast module should create an event frame")
local function fire(event, ...) eventFrame.scripts["OnEvent"](eventFrame, event, ...) end

-- Helper: given a registered child frame, return its click-cast proxy (or nil).
local function getProxy(child)
    local pname = child:GetAttribute("clickcast-proxyname")
    return pname and _G[pname]
end

-- Initial state: solo, one frame registered.
GFCC:Initialize()
GFCC:RegisterAllFrames()
-- With proxy routing: frame type1="click", cast attrs are on the proxy.
local p1 = assert(getProxy(child1), "player frame should have a click-cast proxy after registration")
assert(p1.attributes["type1"] == "macro", "player proxy should hold the spell macro action")

-- Zone into a follower dungeon: the secure header creates a new follower button.
local child2 = NewFrame("Button", "QUI_TestUnit2", nil, "SecureUnitButtonTemplate")
partyHeader.attributes["child2"] = child2
assert(child2.attributes["type1"] == nil, "sanity: new follower frame is unbound before any roster handling")

-- The roster-change event fires (out of combat).
fire("GROUP_ROSTER_UPDATE")

-- The new follower frame must get click-cast applied without a /reload.
local p2 = assert(getProxy(child2),
    "BUG: after GROUP_ROSTER_UPDATE the new follower frame should have a proxy (click-cast bound without /reload)")
assert(p2.attributes["type1"] == "macro",
    "BUG: new follower proxy should hold the spell macro after GROUP_ROSTER_UPDATE")
assert(p2.attributes["macrotext1"] and p2.attributes["macrotext1"]:find("Rejuvenation", 1, true),
    "new follower proxy should cast the configured spell")

-- Secure headers can be sparse while the roster is settling. A later child
-- must not be skipped just because an earlier child slot is temporarily empty.
partyHeader.attributes["child2"] = nil
local child4 = NewFrame("Button", "QUI_TestUnit4", nil, "SecureUnitButtonTemplate")
partyHeader.attributes["child4"] = child4
fire("GROUP_ROSTER_UPDATE")
local p4 = assert(getProxy(child4),
    "BUG: sparse secure-header child4 should still get a proxy after roster update")
assert(p4.attributes["type1"] == "macro",
    "BUG: sparse secure-header children should still be click-cast bound after roster updates")

-- And the in-combat case should defer, then apply when combat ends.
local child3 = NewFrame("Button", "QUI_TestUnit3", nil, "SecureUnitButtonTemplate")
partyHeader.attributes["child3"] = child3
inCombat = true
fire("GROUP_ROSTER_UPDATE")
assert(child3.attributes["type1"] == nil, "in combat, registration must be deferred (no secure writes)")
inCombat = false
fire("PLAYER_REGEN_ENABLED")
local p3 = assert(getProxy(child3),
    "BUG: deferred roster child should have a proxy after combat ends")
assert(p3.attributes["type1"] == "macro",
    "BUG: deferred roster registration should apply spell macro when combat ends")

print("OK: groupframes_clickcast_roster_update_test")
