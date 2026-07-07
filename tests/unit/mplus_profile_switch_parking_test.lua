-- Behavioral test: profile changes arriving inside a Mythic+ context are
-- parked and replayed at key end, instead of silently dropped (which left
-- the UI stale-profiled until a manual /reload).
--
-- Loads the real core/main.lua against a stub environment, drives
-- OnProfileChanged with a stubbed C_ChallengeMode, and exercises the
-- watcher's replay gates (challenge over, combat over).
--
-- Plain Lua 5.1, run from repo root:
--   lua tests/unit/mplus_profile_switch_parking_test.lua

local function noop() end

local createdFrames = {}
local function frameStub()
    local f = { scripts = {}, registered = {} }
    f.RegisterEvent = function(self, ev) self.registered[ev] = true end
    f.UnregisterEvent = function(self, ev) self.registered[ev] = nil end
    f.UnregisterAllEvents = function(self)
        for k in pairs(self.registered) do self.registered[k] = nil end
    end
    f.RegisterUnitEvent = noop
    f.IsEventRegistered = function(self, ev) return self.registered[ev] == true end
    f.SetScript = function(self, k, fn) self.scripts[k] = fn end
    f.GetScript = function(self, k) return self.scripts[k] end
    f.HookScript = function(self, k, fn) self.scripts[k] = fn end
    f.Hide = noop; f.Show = noop; f.IsShown = function() return true end
    f.SetAlpha = noop; f.GetAlpha = function() return 1 end
    f.SetScale = noop; f.GetScale = function() return 1 end
    f.SetPoint = noop; f.ClearAllPoints = noop; f.GetPoint = function() return nil end
    f.SetSize = noop; f.SetParent = noop
    f.CreateTexture = function() return frameStub() end
    f.CreateFontString = function() return frameStub() end
    f.SetFrameStrata = noop; f.EnableMouse = noop
    createdFrames[#createdFrames + 1] = f
    return f
end

_G.CreateFrame = function() return frameStub() end
local inCombat = false
_G.InCombatLockdown = function() return inCombat end
_G.C_Timer = { After = noop, NewTicker = function() return { Cancel = noop } end }
_G.hooksecurefunc = noop
_G.UIParent = frameStub()
_G.GetScreenWidth = function() return 2560 end
_G.GetScreenHeight = function() return 1440 end
_G.GetPhysicalScreenSize = function() return 2560, 1440 end
_G.LibStub = setmetatable({}, { __call = function() return nil end })
_G.wipe = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
_G.geterrorhandler = function() return print end
_G.EventRegistry = { RegisterCallback = noop, RegisterFrameEventAndCallback = noop }
_G.C_AddOns = { GetAddOnMetadata = function() return "4.0.5" end }

-- Controllable challenge state
local challenge = { active = true, mapID = 400 }
_G.C_ChallengeMode = {
    IsChallengeModeActive = function() return challenge.active end,
    GetActiveChallengeMapID = function() return challenge.mapID end,
}

local printed = {}
local realPrint = print
print = function(msg) printed[#printed + 1] = tostring(msg) end

local QUICore = {}
_G.QUI = { NewModule = function() return QUICore end }

assert(loadfile("core/main.lua"))("QUI", {})
print = realPrint
assert(type(QUICore.OnProfileChanged) == "function", "OnProfileChanged should be defined")

QUICore.db = { GetCurrentProfile = function() return "OldProfile" end }

-- 1. Profile change during an active key: parked, not dropped, user told once.
print = function(msg) printed[#printed + 1] = tostring(msg) end
QUICore:OnProfileChanged("OnProfileChanged", QUICore.db, "NewProfile")
print = realPrint
assert(QUICore._parkedProfileChange, "profile change during M+ must be parked")
assert(QUICore._parkedProfileChange.profileKey == "NewProfile", "park records the profile key")
local watcher = QUICore._challengeParkWatcher
assert(watcher, "park must install the replay watcher")
assert(watcher.registered.PLAYER_ENTERING_WORLD and watcher.registered.CHALLENGE_MODE_COMPLETED
    and watcher.registered.CHALLENGE_MODE_RESET and watcher.registered.PLAYER_REGEN_ENABLED,
    "watcher must listen for key-end / combat-end signals")
assert(#printed == 1 and printed[1]:find("deferred", 1, true), "user is told the change is deferred")

-- 2. A second switch during the same key coalesces silently to the newest.
print = function(msg) printed[#printed + 1] = tostring(msg) end
QUICore:OnProfileChanged("OnProfileChanged", QUICore.db, "NewestProfile")
print = realPrint
assert(QUICore._parkedProfileChange.profileKey == "NewestProfile", "latest switch wins")
assert(#printed == 1, "coalesced parks announce only once")

-- Replace the heavy cascade with a spy for replay assertions.
local replays = {}
function QUICore:OnProfileChanged(event, db, profileKey)
    replays[#replays + 1] = { event = event, db = db, profileKey = profileKey }
end
local onEvent = watcher.scripts.OnEvent
assert(type(onEvent) == "function", "watcher must have an OnEvent handler")

-- 3. Key still running (timer done but still inside the dungeon): no replay.
challenge.active = false
onEvent()
assert(#replays == 0 and QUICore._parkedProfileChange, "still inside the M+ map: stay parked")

-- 4. Out of the dungeon but in combat: no replay.
challenge.mapID = nil
inCombat = true
onEvent()
assert(#replays == 0 and QUICore._parkedProfileChange, "in combat: stay parked")

-- 5. All clear: replay once with the parked args, then disarm.
inCombat = false
onEvent()
assert(#replays == 1, "clear of key and combat: replay exactly once")
assert(replays[1].event == "OnProfileChanged" and replays[1].profileKey == "NewestProfile"
    and replays[1].db == QUICore.db, "replay passes the parked event and newest profile key")
assert(QUICore._parkedProfileChange == nil, "park slot cleared after replay")
assert(next(watcher.registered) == nil, "watcher unregisters after replay")

-- 6. Stray late event with nothing parked: harmless, stays disarmed.
onEvent()
assert(#replays == 1, "no double replay")

print("OK: mplus_profile_switch_parking")
