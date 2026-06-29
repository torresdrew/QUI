-- tests/unit/unitframes_boss_range_alpha_stability_test.lua
-- Run: lua tests/unit/unitframes_boss_range_alpha_stability_test.lua

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local source = readAll("QUI_UnitFrames/unitframes/unitframes.lua")

local startPos = assert(source:find("%-%- Boss Range Alpha"),
    "Boss Range Alpha section should exist")
local endPos = assert(source:find("%-%-%-+%s*\n%-%- CREATE: Unit Frame", startPos),
    "Boss Range Alpha section should end before CreateUnitFrame")
local body = source:sub(startPos, endPos)

-- Event-driven design: range alpha is driven by the engine's edge-triggered
-- UNIT_IN_RANGE_UPDATE event, never by a polling ticker. The secret in-range
-- payload is resolved by a secret-safe sink, so there is no per-tick flicker.
assert(body:find('RegisterUnitEvent("UNIT_IN_RANGE_UPDATE"', 1, true),
    "boss range alpha should register the per-unit UNIT_IN_RANGE_UPDATE event")
assert(body:find("boss1", 1, true) and body:find("boss5", 1, true),
    "boss range alpha should register UNIT_IN_RANGE_UPDATE for boss1-boss5")
assert(body:find("isInRange", 1, true),
    "boss range alpha should consume the UNIT_IN_RANGE_UPDATE isInRange payload")
assert(body:find("EvaluateColorValueFromBoolean", 1, true),
    "boss range alpha should resolve the secret in-range bool via the C_CurveUtil sink")
assert(not body:find("C_Timer.NewTicker", 1, true),
    "boss range alpha must be event-driven, not polled on a ticker")
assert(not body:find("IsSpellInRange", 1, true),
    "event-driven boss range alpha must not poll spell range each tick")
assert(not body:find("BOSS_RANGE_CHANGE_CONFIRMATIONS", 1, true),
    "event-driven boss range alpha has no debounce-confirmation counter")

do
    local rangeStart = assert(source:find("local bossRange = {", 1, true),
        "boss range alpha state table should exist")
    local rangeEnd = assert(source:find("---------------------------------------------------------------------------\n-- CREATE: Unit Frame",
        rangeStart, true), "boss range alpha section should end before CreateUnitFrame")
    local loader = loadstring or load
    local chunk = "local UpdateBossRangeAlpha, SeedBossFrameRangeAlpha\n"
        .. source:sub(rangeStart, rangeEnd - 1)
        .. "\nreturn { StartBossRangeCheck = StartBossRangeCheck,"
        .. " UpdateBossRangeAlpha = UpdateBossRangeAlpha,"
        .. " SeedBossFrameRangeAlpha = SeedBossFrameRangeAlpha }"

    local boss1Alpha
    local bossFrame = {
        unit = "boss1",
        SetAlpha = function(_, alpha) boss1Alpha = alpha end,
    }

    Helpers = {
        IsLayoutModeActive = function() return false end,
    }
    QUI_UF = {
        frames = { boss1 = bossFrame },
    }

    function GetUnitSettings()
        return { range = { enabled = true, outOfRangeAlpha = 0.4 } }
    end

    function UnitExists(unit)
        return unit == "boss1"
    end

    -- Secret-safe sink: resolve the (possibly secret) boolean to an alpha.
    C_CurveUtil = {
        EvaluateColorValueFromBoolean = function(value, ifTrue, ifFalse)
            if value then return ifTrue end
            return ifFalse
        end,
    }

    -- A polling ticker must never be created in the event-driven design.
    C_Timer = {
        NewTicker = function()
            error("boss range alpha must not create a polling ticker")
        end,
    }

    local eventFrame
    function CreateFrame()
        local frame = { unitEvents = {}, events = {} }
        function frame:RegisterUnitEvent(event, ...)
            self.unitEvents[event] = { ... }
        end
        function frame:RegisterEvent(event)
            self.events[event] = true
        end
        function frame:SetScript(script, handler)
            if script == "OnEvent" then self.onEvent = handler end
        end
        eventFrame = frame
        return frame
    end

    local api = assert(loader(chunk))()

    api.StartBossRangeCheck()
    assert(eventFrame, "StartBossRangeCheck should create the shared event frame")
    local registeredUnits = eventFrame.unitEvents["UNIT_IN_RANGE_UPDATE"]
    assert(registeredUnits,
        "boss range alpha should register UNIT_IN_RANGE_UPDATE as a unit event")
    do
        local seen = {}
        for _, u in ipairs(registeredUnits) do seen[u] = true end
        for i = 1, 5 do
            assert(seen["boss" .. i],
                "UNIT_IN_RANGE_UPDATE should be registered for boss" .. i)
        end
    end
    assert(boss1Alpha == 1,
        "StartBossRangeCheck should baseline existing boss frames to full alpha")
    assert(eventFrame.onEvent, "boss range alpha should install an OnEvent handler")

    -- Out of range: dim to the configured out-of-range alpha (single apply, no flicker).
    eventFrame.onEvent(eventFrame, "UNIT_IN_RANGE_UPDATE", "boss1", false)
    assert(boss1Alpha == 0.4,
        "out-of-range boss should dim to outOfRangeAlpha via the secret-safe sink")

    -- Back in range: restore full alpha.
    eventFrame.onEvent(eventFrame, "UNIT_IN_RANGE_UPDATE", "boss1", true)
    assert(boss1Alpha == 1,
        "in-range boss should return to full alpha")

    -- A range update for an absent boss slot must not touch existing frames.
    eventFrame.onEvent(eventFrame, "UNIT_IN_RANGE_UPDATE", "boss3", false)
    assert(boss1Alpha == 1,
        "range update for an absent boss slot should not change other frames")

    -- Spawn seed keeps the frame fully visible until the engine reports range.
    boss1Alpha = nil
    api.SeedBossFrameRangeAlpha(bossFrame)
    assert(boss1Alpha == 1,
        "a freshly spawned boss frame should seed to full alpha")
end

local auraSource = readAll("QUI_UnitFrames/unitframes/unitframe_auras.lua")
assert(auraSource:find("local bossEngageFrame", 1, true),
    "boss engage aura refresh should use one shared event frame")
assert(not auraSource:find("bossEngageState", 1, true),
    "boss engage aura refresh must not cache per-slot boss GUIDs")
assert(not auraSource:find("UnitGUID", 1, true),
    "boss engage aura refresh must not read secret UnitGUID values")
assert(not auraSource:find("BossUnitStateChanged", 1, true),
    "boss engage aura refresh should not compare cached boss identity")
assert(auraSource:find("RefreshBossFrameForEngage", 1, true),
    "boss engage aura refresh should be scoped to boss frames")
assert(not auraSource:find('frame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT"', 1, true),
    "boss frames should not each register the global engage event")
assert(auraSource:find('bossEngageFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT"', 1, true),
    "boss engage aura refresh should register the global event once")

do
    local createdFrames = {}

    local function newFrame(name)
        local frame = {
            name = name,
            events = {},
            unitEvents = {},
            scripts = {},
            hooks = {},
        }

        function frame:RegisterEvent(event)
            self.events[event] = true
        end

        function frame:RegisterUnitEvent(event, unit)
            self.unitEvents[event] = unit
        end

        function frame:GetScript(script)
            return self.scripts[script]
        end

        function frame:SetScript(script, handler)
            self.scripts[script] = handler
        end

        function frame:HookScript(script, handler)
            self.hooks[script] = self.hooks[script] or {}
            table.insert(self.hooks[script], handler)
        end

        function frame:Hide()
            self.hidden = true
        end

        return frame
    end

    function CreateFrame(frameType, name)
        local frame = newFrame(name or ("created" .. (#createdFrames + 1)))
        createdFrames[#createdFrames + 1] = frame
        return frame
    end

    local now = 100
    function GetTime()
        now = now + 1
        return now
    end

    local units = {}
    function UnitExists(unit)
        return units[unit] ~= nil
    end

    -- Aura setup runs its full OOC path so the engage-frame assertions below
    -- exercise real event registration (not the deferred combat queue).
    function InCombatLockdown()
        return false
    end

    local unitGuidCalls = 0
    local secretGUIDMT = {
        __eq = function()
            error("attempted to compare a secret boss UnitGUID")
        end,
    }

    function UnitGUID(unit)
        unitGuidCalls = unitGuidCalls + 1
        local data = units[unit]
        return data and data.guid or nil
    end

    C_Timer = {
        After = function()
            -- Initial delayed aura refreshes are irrelevant to this event test.
        end,
    }

    C_UnitAuras = {
        GetAuraDataByIndex = function()
            return nil
        end,
    }

    local updateFrameCalls = {}
    local ns = {
        Addon = {},
        Helpers = {
            ApplyCooldownFromAura = function()
                return false
            end,
            CreateStateTable = function()
                return setmetatable({}, { __mode = "k" })
            end,
            IsSecretValue = function()
                return false
            end,
        },
        QUI_UnitFrames = {
            frames = {},
            auraPreviewMode = {},
            _GetFontPath = function() return "Fonts\\FRIZQT__.TTF" end,
            _GetFontOutline = function() return "OUTLINE" end,
            _GetUnitSettings = function()
                return {
                    auras = {
                        showBuffs = true,
                        showDebuffs = true,
                    },
                }
            end,
            _UpdateFrame = function(frame)
                updateFrameCalls[#updateFrameCalls + 1] = frame.unit
            end,
        },
    }

    assert(loadfile("QUI_UnitFrames/unitframes/unitframe_auras.lua"))("QUI", ns)

    for i = 1, 5 do
        local key = "boss" .. i
        local frame = newFrame("unit-" .. key)
        frame.unit = key
        frame.unitKey = "boss"
        ns.QUI_UnitFrames.frames[key] = frame
        ns.QUI_UnitFrames.SetupAuraTracking(frame)
    end

    for i = 1, 5 do
        local key = "boss" .. i
        assert(not ns.QUI_UnitFrames.frames[key].events.INSTANCE_ENCOUNTER_ENGAGE_UNIT,
            "boss aura tracking should not register the global engage event on every boss frame")
    end

    local engageFrame
    for _, frame in ipairs(createdFrames) do
        if frame.events.INSTANCE_ENCOUNTER_ENGAGE_UNIT then
            assert(engageFrame == nil, "boss aura tracking should use exactly one shared engage event frame")
            engageFrame = frame
        end
    end

    assert(engageFrame and engageFrame.scripts.OnEvent,
        "boss aura tracking should install a shared engage event handler")

    units.boss1 = { guid = setmetatable({}, secretGUIDMT) }
    engageFrame.scripts.OnEvent(engageFrame, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    assert(#updateFrameCalls == 1 and updateFrameCalls[1] == "boss1",
        "first engage should refresh only the newly available boss slot")

    engageFrame.scripts.OnEvent(engageFrame, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    assert(#updateFrameCalls == 2 and updateFrameCalls[2] == "boss1",
        "duplicate engage events should refresh existing boss slots without GUID comparisons")

    units.boss2 = { guid = setmetatable({}, secretGUIDMT) }
    engageFrame.scripts.OnEvent(engageFrame, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    assert(#updateFrameCalls == 4 and updateFrameCalls[3] == "boss1" and updateFrameCalls[4] == "boss2",
        "a later boss slot should refresh alongside existing boss slots")

    units.boss1 = nil
    engageFrame.scripts.OnEvent(engageFrame, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    assert(#updateFrameCalls == 5 and updateFrameCalls[5] == "boss2",
        "despawning boss slots should skip UpdateFrame while existing boss slots refresh")

    assert(unitGuidCalls == 0,
        "boss engage aura refresh must never read UnitGUID secret values")
end

print("OK: unitframes_boss_range_alpha_stability_test")
