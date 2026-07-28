-- tests/unit/nameplates_friendly_test.lua
-- Run: lua tests/unit/nameplates_friendly_test.lua
--
-- Friendly plates (plans/009-nameplates.md Phase 5): effective-mode
-- resolution with honest instance gating, bars-mode thin plates from their
-- own pool, name-only handoff restoring Blizzard art, and the
-- pending-watcher promotion / UNIT_FLAGS demotion pair keeping suppression
-- across ownership swaps.

local function fail(msg)
    print("FAIL: nameplates_friendly_test - " .. msg)
    os.exit(1)
end

local function noop() end

-- Frame env (same shape as the lifecycle test)
local function NewRegion(parent)
    return {
        _parent = parent, _shown = true, _alpha = 1,
        SetParent = function(self, p) self._parent = p end,
        GetParent = function(self) return self._parent end,
        SetAllPoints = noop, SetPoint = noop, ClearAllPoints = noop,
        SetSize = noop, SetWidth = noop, SetHeight = noop,
        SetColorTexture = noop, SetVertexColor = noop, SetTexture = noop,
        SetAlpha = function(self, a) self._alpha = a end,
        GetAlpha = function(self) return self._alpha end,
        SetHorizTile = noop, SetVertTile = noop, SetTexCoord = noop,
        AddMaskTexture = noop, SetBlendMode = noop,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetText = function(self, t) self._text = t end,
        SetFormattedText = noop, SetTextColor = noop, SetFont = noop,
        SetJustifyH = noop,
    }
end

local createdFrames = {}
local function NewFrame(parent)
    local f = NewRegion(parent)
    f._events = {}
    f._scripts = {}
    f._level = 1
    f.RegisterEvent = function(self, e) self._events[e] = "all" end
    f.RegisterUnitEvent = function(self, e, u) self._events[e] = u end
    f.UnregisterAllEvents = function(self) for k in pairs(self._events) do self._events[k] = nil end end
    f.SetScript = function(self, k, h) self._scripts[k] = h end
    f.GetScript = function(self, k) return self._scripts[k] end
    f.EnableMouse = noop
    f.SetFrameLevel = noop
    f.GetFrameLevel = function() return 1 end
    f.IsShown = function(self) return self._shown end
    f.CreateTexture = function(self) return NewRegion(self) end
    f.CreateMaskTexture = function(self) return NewRegion(self) end
    f.CreateFontString = function(self) return NewRegion(self) end
    f.SetStatusBarTexture = noop
    f.GetStatusBarTexture = function() return nil end
    f.SetStatusBarColor = function(self, r, g, b) self._color = { r, g, b } end
    f.SetMinMaxValues = function(self, lo, hi) self._minMax = { lo, hi } end
    f.SetValue = function(self, v) self._value = v end
    f.SetStackingBoundsFrame = function(self, frame) self._stackBounds = frame end
    f.SetDrawEdge = noop
    f.SetHideCountdownNumbers = noop
    f.SetCooldownFromDurationObject = noop
    f.Clear = noop
    return f
end

CreateFrame = function(_, _, parent)
    local f = NewFrame(parent)
    createdFrames[#createdFrames + 1] = f
    return f
end
UIParent = NewFrame(nil)
C_Timer = { After = function() end, NewTicker = function() return { Cancel = noop } end }
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
InCombatLockdown = function() return false end
SetCVar = noop
GetTime = function() return 0 end

local world = { units = {} }
local function U(u) return world.units[u] end
UnitExists = function(u) local d = U(u) return d ~= nil end
UnitIsUnit = function(a, b) return a == b end
UnitCanAttack = function(_, u) local d = U(u) return d and d.canAttack == true end
UnitIsPlayer = function(u) local d = U(u) return d and d.isPlayer == true end
UnitReaction = function(u) local d = U(u) return d and d.reaction or 2 end
UnitClass = function(u) local d = U(u) return "x", d and d.class or nil end
UnitIsTapDenied = function() return false end
UnitAffectingCombat = function() return false end
UnitThreatSituation = function() return nil end
UnitHealth = function(u) local d = U(u) return d and d.health or 0 end
UnitHealthMax = function(u) local d = U(u) return d and d.maxHealth or 1 end
UnitGetTotalAbsorbs = function() return 0 end
UnitIsDeadOrGhost = function() return false end
UnitName = function(u) local d = U(u) return d and d.name or "Friend" end
UnitHealthPercent = function() return 100 end
CurveConstants = nil
IsInInstance = function() return world.inInstance == true, world.instanceType or "none" end
UnitGroupRolesAssigned = function() return "DAMAGER" end
GetRaidTargetIndex = function() return nil end
SetRaidTargetIconTexture = noop
RAID_CLASS_COLORS = { PRIEST = { r = 1, g = 0.96, b = 0.98 } }
UnitCastingInfo = function() return nil end
UnitChannelInfo = function() return nil end
GetPlayerInfoByGUID = function() return nil end
C_TooltipInfo = nil
C_CurveUtil = nil
C_UnitAuras = nil
C_StringUtil = nil
CreateColor = nil
Enum = {}

local bases = {}
local function NewBase(token)
    local base = NewFrame(UIParent)
    base.unitToken = token
    base.UnitFrame = NewFrame(base)
    base.UnitFrame.HealthBarsContainer = NewFrame(base.UnitFrame)
    base.UnitFrame.castBar = NewFrame(base.UnitFrame)
    base.UnitFrame.RaidTargetFrame = NewFrame(base.UnitFrame)
    base.UnitFrame.ClassificationFrame = NewFrame(base.UnitFrame)
    base.UnitFrame.AurasFrame = NewFrame(base.UnitFrame)
    base.UnitFrame.PlayerLevelDiffFrame = NewFrame(base.UnitFrame)
    base.UnitFrame.SoftTargetFrame = NewFrame(base.UnitFrame)
    bases[token] = base
    return base
end
C_NamePlate = {
    GetNamePlateForUnit = function(t) return bases[t] end,
    SetNamePlateSize = noop,
    GetNamePlates = function()
        local out = {}
        for _, b in pairs(bases) do out[#out + 1] = b end
        return out
    end,
}
hooksecurefunc = function(target, method, fn)
    local orig = target[method] or noop
    target[method] = function(...) orig(...); fn(...) end
end
NamePlateDriverFrame = NewFrame(UIParent)
NamePlateDriverFrame.OnNamePlateAdded = function() end
NamePlateDriverFrame.UpdateNamePlateOptions = function() end

local cvarWrites = {}
local settings = {
    enabled = true,
    friendly = { mode = "bars", classColorNames = true, barWidth = 150, barHeight = 12, showInInstances = false },
    health = {}, name = {}, castbar = {}, colors = {}, highlight = {}, raidMarker = {},
    auras = { enabled = false }, cvars = {},
}
local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        TruncateUTF8 = function(s, n) return s end,
        GetModuleSettings = function() return settings end,
    },
    UIKit = {
        CreateBackground = function(parent) return NewRegion(parent) end,
        CreateBorderLines = noop, UpdateBorderLines = noop,
        CreateText = function(parent) return NewRegion(parent) end,
        ResolveFontPath = function() return "" end,
        CreateIcon = function(parent) local f = NewFrame(parent); f.texture = NewRegion(f); f.border = NewRegion(f); return f end,
        UpdateIconLayout = noop,
    },
    Addon = {
        SetPixelPerfectSize = noop,
        Pixels = function(_, v) return v end,
        ApplyFont = noop,
    },
    AuraEvents = { Subscribe = noop },
    LSM = nil,
}

assert(loadfile("core/cast_engine.lua"))("QUI", ns)
for _, file in ipairs({ "shared.lua", "cvars.lua", "plate_colors.lua", "plate_health.lua",
    "plate_castbar.lua", "plate_auras.lua", "plate_extras.lua", "friendly.lua", "driver.lua" }) do
    assert(loadfile("QUI_Nameplates/nameplates/" .. file))("QUI_Nameplates", ns)
end

local NP = ns.QUI_Nameplates
local Friendly = NP.Friendly

local driverEventFrame
for _, entry in ipairs(ns.QUI_PerfRegistry or {}) do
    if entry.name == "NameplateDriver" then driverEventFrame = entry.frame end
end
local dispatch = driverEventFrame:GetScript("OnEvent")

local function FireAdded(token)
    NamePlateDriverFrame.OnNamePlateAdded(NamePlateDriverFrame, token)
    dispatch(driverEventFrame, "NAME_PLATE_UNIT_ADDED", token)
end
local function FireRemoved(token)
    dispatch(driverEventFrame, "NAME_PLATE_UNIT_REMOVED", token)
end

local function test(n, f) print(n); f(); print("  ok") end

---------------------------------------------------------------------------
test("GetEffectiveMode: instance gating is honest", function()
    local fs = { mode = "bars" }
    if Friendly.GetEffectiveMode(fs, { inInstance = false }) ~= "bars" then fail("world keeps bars") end
    if Friendly.GetEffectiveMode({ mode = "bars", showInInstances = true }, { inInstance = true }) ~= "nameonly" then
        fail("instance + bars must degrade to nameonly (protected plates)")
    end
    if Friendly.GetEffectiveMode({ mode = "bars", showInInstances = false }, { inInstance = true }) ~= "off" then
        fail("instance with showInInstances=false must relinquish (off)")
    end
    if Friendly.GetEffectiveMode({ mode = "off" }, { inInstance = false }) ~= "off" then fail("off stays off") end
    if Friendly.GetEffectiveMode({ mode = "nameonly" }, { inInstance = true }) ~= "nameonly" then fail("nameonly in instance") end
end)

test("bars mode: friendly unit gets a thin plate, art stays suppressed", function()
    world.units.nameplate1 = { canAttack = false, reaction = 6, isPlayer = true, class = "PRIEST",
        health = 80, maxHealth = 100, name = "Healer" }
    local base = NewBase("nameplate1")
    FireAdded("nameplate1")

    local plate = NP.friendlyPlates.nameplate1
    if not plate then fail("bars mode must build a friendly plate") end
    if NP.plates.nameplate1 then fail("friendly unit must not get an enemy plate") end
    if base.UnitFrame._alpha ~= 0 then fail("bars mode keeps Blizzard art suppressed") end
    if plate.healthBar._value ~= 80 then fail("friendly health must paint") end
    local c = plate.healthBar._color
    if not c or math.abs(c[1] - 1) > 1e-6 then fail("friendly player must class-color (PRIEST r=1)") end
    if NP:GetPlateAnchor("nameplate1") ~= plate.healthBar then fail("GetPlateAnchor must cover friendly plates") end
end)

test("promotion: unit becomes attackable → full enemy plate, no art flash", function()
    world.units.nameplate1.canAttack = true
    -- find the watcher (frame with UNIT_FLAGS registered for nameplate1 and an npUnit field)
    local watcher
    for _, f in ipairs(createdFrames) do
        if f.npUnit == "nameplate1" and f._events.UNIT_FLAGS == "nameplate1" then watcher = f end
    end
    if not watcher then fail("pending watcher missing") end
    watcher:GetScript("OnEvent")(watcher, "UNIT_FLAGS", "nameplate1")

    if NP.friendlyPlates.nameplate1 then fail("friendly plate must release on promotion") end
    if not NP.plates.nameplate1 then fail("promotion must build an enemy plate") end
    if bases.nameplate1.UnitFrame._alpha ~= 0 then fail("suppression must hold across the swap") end
end)

test("demotion: enemy plate's UNIT_FLAGS hands back to friendly", function()
    world.units.nameplate1.canAttack = false
    local plate = NP.plates.nameplate1
    plate._scripts.OnEvent(plate, "UNIT_FLAGS", "nameplate1")
    if NP.plates.nameplate1 then fail("enemy plate must release on demotion") end
    if not NP.friendlyPlates.nameplate1 then fail("demotion must rebuild the friendly plate (bars mode)") end
end)

test("REMOVED releases friendly plate and watcher", function()
    FireRemoved("nameplate1")
    if NP.friendlyPlates.nameplate1 then fail("friendly plate must release") end
    for _, f in ipairs(createdFrames) do
        if f.npUnit == "nameplate1" then fail("watcher must detach") end
    end
end)

test("nameonly mode: art restored, no thin plate", function()
    settings.friendly.mode = "nameonly"
    world.units.nameplate2 = { canAttack = false, reaction = 6, health = 1, maxHealth = 1 }
    local base = NewBase("nameplate2")
    FireAdded("nameplate2")
    if NP.friendlyPlates.nameplate2 then fail("nameonly must not build a thin plate") end
    if base.UnitFrame._alpha ~= 1 then fail("nameonly must restore Blizzard art") end
    FireRemoved("nameplate2")
end)

print("OK: nameplates_friendly_test")
