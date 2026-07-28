-- tests/unit/nameplates_aura_delta_test.lua
-- Run: lua tests/unit/nameplates_aura_delta_test.lua
--
-- Aura delta consumer against the dispatcher contract
-- (plans/009-nameplates.md): pooled updateInfo is wiped after dispatch so
-- the consumer must copy what it keeps; added auras classify into channels
-- via server membership + local lists; removed IDs dirty their channel;
-- updated IDs take the in-place fast path; rebuilds intersect the
-- server-ordered ID list with the local set; rebuilds are rate-limited to
-- one flush per plate per frame.

local function fail(msg)
    print("FAIL: nameplates_aura_delta_test - " .. msg)
    os.exit(1)
end

local function noop() end

---------------------------------------------------------------------------
-- Frame environment
---------------------------------------------------------------------------
local function NewRegion(parent)
    return {
        _parent = parent, _shown = true, _alpha = 1,
        SetParent = function(self, p) self._parent = p end,
        GetParent = function(self) return self._parent end,
        SetAllPoints = noop, SetPoint = noop, ClearAllPoints = noop,
        SetSize = noop, SetWidth = noop, SetHeight = noop,
        SetColorTexture = noop, SetVertexColor = noop,
        SetTexture = function(self, t) self._texture = t end,
        SetAlpha = function(self, a) self._alpha = a end,
        SetAlphaFromBoolean = function(self, b, tA, fA) self._boolAlpha = { b, tA, fA } end,
        SetTexCoord = noop, Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetText = function(self, t) self._text = t end,
        SetFont = noop, SetJustifyH = noop,
    }
end

local function NewFrame(parent)
    local f = NewRegion(parent)
    f._scripts = {}
    f.SetScript = function(self, k, h) self._scripts[k] = h end
    f.GetScript = function(self, k) return self._scripts[k] end
    f.RegisterEvent = noop
    f.RegisterUnitEvent = noop
    f.UnregisterAllEvents = noop
    f.EnableMouse = noop
    f.SetFrameLevel = noop
    f.GetFrameLevel = function() return 1 end
    f.IsShown = function(self) return self._shown end
    f.CreateTexture = function(self) return NewRegion(self) end
    f.CreateFontString = function(self) return NewRegion(self) end
    f.SetDrawEdge = noop
    f.SetHideCountdownNumbers = noop
    f.SetCooldownFromDurationObject = function(self, d) self._durObj = d end
    f.Clear = function(self) self._durObj = nil end
    return f
end

CreateFrame = function(_, _, parent) return NewFrame(parent) end
UIParent = NewFrame(nil)
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
C_Timer = { NewTicker = function() return { Cancel = noop } end, After = function() end }
C_CurveUtil = nil
CreateColor = nil
Enum = {}
C_StringUtil = nil

---------------------------------------------------------------------------
-- C_UnitAuras world
---------------------------------------------------------------------------
-- auraWorld[unit] = { [instanceID] = { spellId, icon, channels = {debuffs=true,...} } }
local auraWorld = { nameplate1 = {} }
local serverOrder = {}   -- ordered instanceIDs returned per filter query

local FILTERS = {
    debuffsMine = "HARMFUL|INCLUDE_NAME_PLATE_ONLY|PLAYER",
    buffs = "HELPFUL|INCLUDE_NAME_PLATE_ONLY",
    cc = "HARMFUL|CROWD_CONTROL",
}
local function channelOfFilter(filter)
    if filter == FILTERS.debuffsMine then return "debuffs" end
    if filter == FILTERS.buffs then return "buffs" end
    if filter == FILTERS.cc then return "cc" end
    return nil
end

C_UnitAuras = {
    IsAuraFilteredOutByInstanceID = function(unit, instanceID, filter)
        local rec = auraWorld[unit] and auraWorld[unit][instanceID]
        local channel = channelOfFilter(filter)
        if not rec or not channel then return true end
        return not rec.channels[channel]
    end,
    GetUnitAuraInstanceIDs = function(unit, filter)
        local channel = channelOfFilter(filter)
        local out = {}
        for _, id in ipairs(serverOrder) do
            local rec = auraWorld[unit] and auraWorld[unit][id]
            if rec and channel and rec.channels[channel] then
                out[#out + 1] = id
            end
        end
        return out
    end,
    GetAuraDataByAuraInstanceID = function(unit, instanceID)
        local rec = auraWorld[unit] and auraWorld[unit][instanceID]
        if not rec then return nil end
        return { auraInstanceID = instanceID, spellId = rec.spellId, icon = rec.icon }
    end,
    GetAuraDuration = function(unit, instanceID)
        return { _id = instanceID, IsZero = function() return false end }
    end,
    GetAuraApplicationDisplayCount = function(unit, instanceID)
        local rec = auraWorld[unit] and auraWorld[unit][instanceID]
        return rec and rec.stacks or ""
    end,
    GetAuraDispelTypeColor = function() return nil end,
}

---------------------------------------------------------------------------
-- QUI namespace + dispatcher capture
---------------------------------------------------------------------------
local settings = {
    enabled = true,
    auras = {
        enabled = true,
        mineOnly = true,
        importantList = { [700] = true },
        debuffs = { enabled = true, size = 26, limit = 3, growth = "RIGHT", spacing = 2, blockList = { [666] = true }, allowList = {} },
        buffs = { enabled = true, size = 24, limit = 2, growth = "RIGHT", spacing = 2, allowList = {}, blockList = {} },
        cc = { enabled = true, size = 24, limit = 2, growth = "LEFT", spacing = 2, allowList = {}, blockList = {} },
    },
    health = {}, name = {}, castbar = {},
}

local subscribedCallback = nil
local ns = {
    Helpers = {
        IsSecretValue = function(v) return type(v) == "table" and v._secret == true end,
        GetModuleSettings = function() return settings end,
        TruncateUTF8 = function(s) return s end,
    },
    UIKit = {
        CreateIcon = function(parent)
            local iconFrame = NewFrame(parent)
            iconFrame.texture = NewRegion(iconFrame)
            iconFrame.border = NewRegion(iconFrame)
            return iconFrame
        end,
        CreateText = function(parent) return NewRegion(parent) end,
        ResolveFontPath = function() return "" end,
        UpdateIconLayout = noop,
        CreateBackground = function(parent) return NewRegion(parent) end,
        CreateBorderLines = noop, UpdateBorderLines = noop,
    },
    Addon = {
        Pixels = function(_, v) return v end,
        SetPixelPerfectSize = function(_, f, w) f._extent = w end,
        ApplyFont = noop,
    },
    AuraEvents = {
        Subscribe = function(_, tier, cb)
            if tier ~= "nameplate" then fail("must subscribe to the nameplate tier") end
            subscribedCallback = cb
        end,
    },
    LSM = nil,
}

assert(loadfile("QUI_Nameplates/nameplates/shared.lua"))("QUI_Nameplates", ns)
assert(loadfile("QUI_Nameplates/nameplates/plate_extras.lua"))("QUI_Nameplates", ns)

-- plate_extras needs these stubs at load
IsInInstance = function() return false, "none" end
UnitGroupRolesAssigned = function() return "DAMAGER" end
UnitThreatSituation = function() return nil end
UnitName = function() return "Player" end
C_TooltipInfo = nil
InCombatLockdown = function() return false end

assert(loadfile("QUI_Nameplates/nameplates/plate_auras.lua"))("QUI_Nameplates", ns)

local NP = ns.QUI_Nameplates
local Auras = NP.Auras

-- Build a plate
local plate = NewFrame(UIParent)
plate.unit = "nameplate1"
plate.healthBar = NewFrame(plate)
plate.nameText = NewRegion(plate)
Auras.Build(plate)
Auras.ApplyAppearance(plate, settings)
NP.plates.nameplate1 = plate

if not subscribedCallback then fail("Build must subscribe to the dispatcher (lazily)") end

-- The flush frame is module-internal. Reload the module with a recording
-- CreateFrame so every module frame (including the flush frame) is reachable,
-- then drive flushes by invoking the shown frames' OnUpdate handlers.
local recordedFrames = {}
local baseCreateFrame = CreateFrame
CreateFrame = function(...)
    local f = baseCreateFrame(...)
    recordedFrames[#recordedFrames + 1] = f
    return f
end
-- reload module cleanly with recording enabled
NP.Auras = nil
subscribedCallback = nil
assert(loadfile("QUI_Nameplates/nameplates/plate_auras.lua"))("QUI_Nameplates", ns)
Auras = NP.Auras
plate = NewFrame(UIParent)
plate.unit = "nameplate1"
plate.healthBar = NewFrame(plate)
plate.nameText = NewRegion(plate)
Auras.Build(plate)
Auras.ApplyAppearance(plate, settings)
NP.plates.nameplate1 = plate

local function Flush()
    for _, f in ipairs(recordedFrames) do
        local h = f._scripts and f._scripts.OnUpdate
        if h and f._shown then h(f) end
    end
end

local function test(n, f) print(n); f(); print("  ok") end

---------------------------------------------------------------------------
test("added deltas classify into channels; pooled payload is not retained", function()
    auraWorld.nameplate1[101] = { spellId = 589, icon = 136207, stacks = 3, channels = { debuffs = true } }
    auraWorld.nameplate1[102] = { spellId = 700, icon = 1, stacks = "", channels = { debuffs = true } }
    auraWorld.nameplate1[103] = { spellId = 666, icon = 2, stacks = "", channels = { debuffs = true } }
    serverOrder = { 102, 101, 103 }

    -- simulate the dispatcher: pooled table, wiped after dispatch
    local pooled = {
        addedAuras = {
            { auraInstanceID = 101, spellId = 589, icon = 136207 },
            { auraInstanceID = 102, spellId = 700, icon = 1 },
            { auraInstanceID = 103, spellId = 666, icon = 2 },
        },
        removedAuraInstanceIDs = {},
        updatedAuraInstanceIDs = {},
    }
    subscribedCallback("nameplate1", pooled)
    -- dispatcher contract: wipe after dispatch
    wipe(pooled.addedAuras); wipe(pooled.removedAuraInstanceIDs); wipe(pooled.updatedAuraInstanceIDs)

    if plate.npAuraSets.debuffs[101] ~= 589 then fail("589 must be in the debuff set") end
    if plate.npAuraSets.debuffs[102] ~= 700 then fail("700 must be in the debuff set") end
    if plate.npAuraSets.debuffs[103] ~= nil then fail("block-listed 666 must not enter the set") end
    if plate.npAuraImportant.debuffs[102] ~= true then fail("700 must be flagged important") end

    Flush()
    local row = plate.npAuraRows.debuffs
    if not row.icons[1] or not row.icons[1]._shown then fail("first icon must render") end
    if not row.icons[2] or not row.icons[2]._shown then fail("second icon must render") end
    -- server order: 102 first, then 101
    if row.icons[1].npInstanceID ~= 102 then fail("render must follow server order (102 first)") end
    if row.icons[2].npInstanceID ~= 101 then fail("render must follow server order (101 second)") end
    -- icon texture survived the pooled wipe (copied at add time)
    if row.icons[2].iconFrame.texture._texture ~= 136207 then
        fail("icon texture must be copied out of the pooled payload")
    end
    if row.icons[2].stackText._text ~= 3 then fail("stacks must paint") end
end)

test("updated delta takes the in-place fast path", function()
    local holder = plate.npAuraRows.debuffs.icons[2]  -- instance 101
    holder.cd._durObj = nil
    subscribedCallback("nameplate1", {
        addedAuras = {},
        removedAuraInstanceIDs = {},
        updatedAuraInstanceIDs = { 101 },
    })
    if not holder.cd._durObj or holder.cd._durObj._id ~= 101 then
        fail("update must re-arm the cooldown in place")
    end
    if plate.npAuraDirty.debuffs then fail("pure update must NOT dirty the channel") end
end)

test("removed delta drops the aura and rebuilds the channel", function()
    auraWorld.nameplate1[102] = nil
    serverOrder = { 101 }
    subscribedCallback("nameplate1", {
        addedAuras = {},
        removedAuraInstanceIDs = { 102 },
        updatedAuraInstanceIDs = {},
    })
    if plate.npAuraSets.debuffs[102] ~= nil then fail("removed aura must leave the set") end
    Flush()
    local row = plate.npAuraRows.debuffs
    if row.icons[1].npInstanceID ~= 101 then fail("survivor must move to slot 1") end
    if row.icons[2] and row.icons[2]._shown then fail("second slot must hide") end
end)

test("nil updateInfo = full rescan from server state", function()
    auraWorld.nameplate1[201] = { spellId = 8122, icon = 3, stacks = "", channels = { cc = true } }
    serverOrder = { 101, 201 }
    subscribedCallback("nameplate1", nil)
    Flush()
    if plate.npAuraSets.cc[201] ~= 8122 then fail("full rescan must pick up the CC aura") end
    local ccRow = plate.npAuraRows.cc
    if not (ccRow.icons[1] and ccRow.icons[1]._shown and ccRow.icons[1].npInstanceID == 201) then
        fail("CC row must render after rescan")
    end
end)

test("Clear wipes sets, hides icons, drops fast-path handles", function()
    Auras.Clear(plate)
    if next(plate.npAuraSets.debuffs) then fail("debuff set must wipe") end
    if next(plate.npAuraIconByID) then fail("fast-path handles must wipe") end
    for _, row in pairs(plate.npAuraRows) do
        for _, holder in ipairs(row.icons) do
            if holder._shown then fail("all icons must hide on Clear") end
        end
    end
end)

print("OK: nameplates_aura_delta_test")
