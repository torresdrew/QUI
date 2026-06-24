-- tests/unit/groupframes_clickcast_remove_last_keyboard_binding_test.lua
-- Run: lua tests/unit/groupframes_clickcast_remove_last_keyboard_binding_test.lua
--
-- Regression: removing the LAST keyboard click-cast key while a mouse binding
-- remained left the caster's stale key attributes (cc-keycount / cc-key /
-- macrotext) in place, because ApplyGlobalKeyboardBindings bailed on the
-- "transient empty resolve" guard whenever ANY binding was still configured.
-- The removed key then re-armed on hover and fired a dead action instead of
-- falling through to its normal action-bar binding, until a /reload.
--
-- Repro: bind U (keyboard) + a mouse binding, hover (U click-casts), remove U,
-- hover again, press U -> nothing (stale caster override), /reload -> normal.
-- The fix gates the guard on the spec/loadout CONTEXT being unresolved, not on
-- "any binding configured", so a resolved-but-empty keyboard list is honored.

local inCombat = false
local function noop() end

local SPELL_NAMES = { [774] = "Rejuvenation", [8936] = "Regrowth" }
local NAME_TO_ID  = { Rejuvenation = 774, Regrowth = 8936 }

local frameMT
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
function RegisterStateDriver() end
function RegisterAttributeDriver() end
function UnregisterStateDriver() end
function SecureHandlerWrapScript(frame, script, header, preBody)
    frame.secureWraps[script] = { header = header, preBody = preBody }
end
GameTooltip = { GetOwner = function() return nil end, AddLine = noop, AddDoubleLine = noop, Show = noop }
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

C_Timer = { After = function() end, NewTimer = function() return { Cancel = noop } end }

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

-- Shared (perSpec = false) config so the spec/loadout context is always resolved
-- and an empty keyboard resolve is authoritative. One keyboard key (U) + one
-- mouse binding -- the mouse binding is what kept the old guard true after U was
-- removed.
_G.QUI = {
    db = {
        char = {
            clickCast = {
                enabled = true,
                perSpec = false,
                _migratedFromProfile = true,
                rootSpellMigrationDone = true,
                bindings = {
                    { key = "U", modifiers = "", actionType = "spell",
                      spell = "Rejuvenation", spellID = 774 },
                    { button = "LeftButton", modifiers = "", actionType = "spell",
                      spell = "Regrowth", spellID = 8936 },
                },
            },
        },
        profile = {},
    },
}

local child = NewFrame("Button", "QUI_TestUnit1", nil, "SecureUnitButtonTemplate")
local partyHeader = NewFrame("Frame", "QUI_TestPartyHeader", nil, "SecureGroupHeaderTemplate")
partyHeader.attributes["child1"] = child
ns.QUI_GroupFrames = {
    headers = { party = partyHeader, raid = false, self = false },
    raidGroupHeaders = {},
}

assert(loadfile("QUI_GroupFrames/groupframes/groupframes_clickcast.lua"))("QUI", ns)
local GFCC = assert(ns.QUI_GroupFrameClickCast)

local function RunWrap(frame, script)
    local wrap = assert(frame.secureWraps[script], "frame missing secure wrap: " .. script)
    local chunk = assert((loadstring or load)("local self, owner = ...\n" .. wrap.preBody))
    return chunk(frame, wrap.header)
end

GFCC:Initialize()
GFCC:RegisterAllFrames()

-- Keyboard keys published to the header's unified key list; cast macros on the proxy.
local header = assert(_G.QUI_ClickCastHeader, "binding header should exist for keyboard binding")
local proxyName = child:GetAttribute("clickcast-proxyname")
assert(proxyName, "registered frame must have clickcast-proxyname")
local proxy = assert(_G[proxyName], "proxy must be in _G")

-- Precondition: U is published to the header and the proxy holds the cast macro.
assert((header:GetAttribute("clickcast-keycount") or 0) == 1,
    "precondition: U should be the one published keyboard key on the header")
assert(header:GetAttribute("clickcast-key1") == "U", "precondition: clickcast-key1 should be U")
assert(proxy:GetAttribute("macrotext-keyu"), "precondition: proxy should hold U's cast macro")
RunWrap(child, "OnEnter")
assert(header.overrideBindings.U and header.overrideBindings.U.button == "keyu",
    "precondition: hovering should arm U on the header (bound to proxy)")

-- Remove U (the only keyboard key). A mouse binding remains configured.
assert(GFCC:RemoveBinding(1))

-- Re-fetch proxy after removal (same proxy, cleared state).
proxyName = child:GetAttribute("clickcast-proxyname")
proxy = proxyName and _G[proxyName]

-- THE FIX: stale keyboard state must be gone from both header and proxy.
assert((header:GetAttribute("clickcast-keycount") or 0) == 0,
    "BUG: removing the last keyboard key left a stale clickcast-keycount on the header")
assert(header:GetAttribute("clickcast-key1") == nil,
    "BUG: stale clickcast-key1 (U) survived removal of the last keyboard key")
assert(not proxy or proxy:GetAttribute("macrotext-keyu") == nil,
    "BUG: stale U cast macro survived removal on proxy -- key fires a dead action instead of its normal binding")

-- And hovering must NOT re-arm U, so the key falls through to its normal binding.
RunWrap(child, "OnEnter")
assert(not header.overrideBindings.U,
    "BUG: U re-armed on header after removal -- normal binding stays shadowed until /reload")

-- The remaining mouse binding must still be live on the proxy (the guard change
-- must not break the mouse path).
local activeProxy = child:GetAttribute("clickcast-proxyname") and _G[child:GetAttribute("clickcast-proxyname")]
assert(activeProxy and activeProxy:GetAttribute("type1") == "macro"
    and (activeProxy:GetAttribute("macrotext1") or ""):find("Regrowth", 1, true),
    "the remaining mouse binding should still be on the proxy after last keyboard key removal")

print("OK: groupframes_clickcast_remove_last_keyboard_binding_test")
