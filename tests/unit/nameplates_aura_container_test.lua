-- tests/unit/nameplates_aura_container_test.lua
-- Run: lua tests/unit/nameplates_aura_container_test.lua
--
-- 12.1 CustomAuraContainer path: Build probes the engine frame type and
-- prefers it; SetUnit-time configuration binds the unit BEFORE Configure,
-- carries the composed filter strings + spell lists as candidate filters,
-- and honors per-context/channel enables; Clear disables without unbinding;
-- the Lua delta consumer is bypassed; legacy path remains the fallback.

local function fail(msg)
    print("FAIL: nameplates_aura_container_test - " .. msg)
    os.exit(1)
end
local function noop() end

local function NewRegion(parent)
    return { _parent = parent, _shown = true,
        SetParent = noop, SetAllPoints = noop, SetPoint = noop, ClearAllPoints = noop,
        SetSize = noop, SetColorTexture = noop, SetTexture = noop, SetAlpha = noop,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetText = noop, SetFont = noop, SetTextColor = noop, SetJustifyH = noop }
end
local function NewFrame(parent)
    local f = NewRegion(parent)
    f._scripts = {}
    f.SetScript = function(self, k, h) self._scripts[k] = h end
    f.GetScript = function(self, k) return self._scripts[k] end
    f.RegisterEvent = noop; f.RegisterUnitEvent = noop; f.UnregisterAllEvents = noop
    f.EnableMouse = noop; f.SetFrameLevel = noop; f.GetFrameLevel = function() return 1 end
    f.IsShown = function(self) return self._shown end
    f.CreateTexture = function(self) return NewRegion(self) end
    f.CreateFontString = function(self) return NewRegion(self) end
    return f
end

local containersEnabled = true
CreateFrame = function(kind, name, parent, template)
    if kind == "AuraContainer" then
        if not containersEnabled then error("unknown frame type") end
        local c = NewFrame(parent)
        c._groups = {}
        c._enabled = nil
        c.AddAuraGroup = function(self, key, filter, opts) self._groups[key] = { filter = filter, opts = opts } end
        c.HasAuraGroup = function(self, key) return self._groups[key] ~= nil end
        c.SetUnit = function(self, unit) assert(type(unit) == "string", "SetUnit requires a unit"); self._unit = unit end
        c.SetEnabled = function(self, e) self._enabled = e end
        return c
    end
    return NewFrame(parent)
end
UIParent = NewFrame(nil)
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
C_Timer = { After = function() end, NewTicker = function() return { Cancel = noop } end }
InCombatLockdown = function() return false end
C_UnitAuras = nil; C_CurveUtil = nil; C_StringUtil = nil; CreateColor = nil
Enum = {}
AuraContainerSortMethod = { Default = 0, Expiration = 4 }

-- AuraSkin/AuraGlue stubs recording configure passes
local configures = {}
_G.QUI = { AuraSkin = {
    Configure = function(container, profile, groups)
        configures[#configures + 1] = { container = container, profile = profile, groups = groups, unitAtConfigure = container._unit }
    end,
    Restyle = noop,
    LayoutAnchor = function(profile) return "TOPLEFT" end,
} }

local settings = {
    enabled = true,
    auras = {
        enabled = true, mineOnly = true,
        duration = { enabled = true, size = 12 },
        debuffs = { enabled = true, size = 26, limit = 5, growth = "RIGHT", spacing = 2, textSize = 11,
                    allowList = {}, blockList = { [666] = true } },
        buffs = { enabled = false, size = 24, limit = 4, allowList = {}, blockList = {} },
        cc = { enabled = true, size = 24, limit = 3, allowList = { [8122] = true }, blockList = {} },
    },
}
local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        GetModuleSettings = function() return settings end,
        TruncateUTF8 = function(s) return s end,
    },
    UIKit = { CreateIcon = function(parent) local f = NewFrame(parent); f.texture = NewRegion(f); f.border = NewRegion(f); return f end,
        CreateText = function(p) return NewRegion(p) end, ResolveFontPath = function() return "" end,
        UpdateIconLayout = noop, CreateBackground = function(p) return NewRegion(p) end,
        CreateBorderLines = noop, UpdateBorderLines = noop },
    Addon = { Pixels = function(_, v) return v end, SetPixelPerfectSize = noop, ApplyFont = noop },
    AuraGlue = nil, -- exercise the direct AuraSkin.Configure branch
    AuraEvents = { Subscribe = function() fail("container mode must not subscribe the dispatcher tier") end },
}

assert(loadfile("QUI_Nameplates/nameplates/shared.lua"))("QUI_Nameplates", ns)
assert(loadfile("QUI_Nameplates/nameplates/plate_extras.lua"))("QUI_Nameplates", ns)
IsInInstance = function() return false, "none" end
UnitGroupRolesAssigned = function() return "DAMAGER" end
UnitThreatSituation = function() return nil end
UnitName = function() return "x" end
C_TooltipInfo = nil
assert(loadfile("QUI_Nameplates/nameplates/plate_auras.lua"))("QUI_Nameplates", ns)

local NP = ns.QUI_Nameplates
local Auras = NP.Auras
local function test(n, f) print(n); f(); print("  ok") end

local plate = NewFrame(UIParent)
plate.healthBar = NewFrame(plate)
plate.nameText = NewRegion(plate)

test("Build prefers the engine containers (one per channel)", function()
    Auras.Build(plate)
    if plate.npAuraMode ~= "container" then fail("must choose container mode") end
    for _, ch in ipairs({ "debuffs", "buffs", "cc" }) do
        local c = plate.npAuraContainers[ch]
        if not c then fail("missing container for " .. ch) end
        if c._enabled ~= false then fail("containers start disabled") end
    end
end)

test("SetUnit-time configure: unit bound BEFORE Configure; lists ride as candidate filters", function()
    Auras.ApplyAppearance(plate, settings)
    plate.unit = "nameplate3"
    plate.npAurasEnabled = true
    Auras.FullRescan(plate)
    if #configures < 2 then fail("expected configure passes, got " .. #configures) end
    local byFilter = {}
    for _, cfg in ipairs(configures) do
        if cfg.unitAtConfigure ~= "nameplate3" then fail("SetUnit must precede Configure") end
        byFilter[cfg.groups[1].filter] = cfg.groups[1]
    end
    local debuff = byFilter["HARMFUL|INCLUDE_NAME_PLATE_ONLY|PLAYER"]
    if not debuff then fail("debuff group filter missing (mine-only)") end
    if not (debuff.candidateFilters and debuff.candidateFilters.excludeSpellIDs
        and debuff.candidateFilters.excludeSpellIDs[666]) then
        fail("block list must ride as excludeSpellIDs")
    end
    if debuff.maxFrameCount ~= 5 then fail("limit must map to maxFrameCount") end
    if debuff.sortMethod ~= 4 then fail("expiration sort expected") end
    local cc = byFilter["HARMFUL|CROWD_CONTROL"]
    if not cc then fail("cc group missing") end
    if not (cc.candidateFilters and cc.candidateFilters.includeSpellIDs
        and cc.candidateFilters.includeSpellIDs[8122]) then
        fail("allow list must ride as includeSpellIDs")
    end
    -- disabled buffs channel: either no configure or hidden container
    local buffs = plate.npAuraContainers.buffs
    if buffs._enabled == true then fail("disabled channel container must not enable") end
end)

test("delta consumer bypasses container plates", function()
    NP.plates.nameplate3 = plate
    -- reaching the Lua path would touch npAuraSets (nil in container mode)
    local h = ns.AuraEvents -- consumer isn't subscribed in container mode; call internal via public seam:
    -- FullRescan on a container plate must not touch npAuraSets either
    Auras.FullRescan(plate)
    if plate.npAuraSets then fail("container mode must not build legacy sets") end
    NP.plates.nameplate3 = nil
end)

test("Clear disables and hides without unbinding", function()
    Auras.Clear(plate)
    for _, ch in ipairs({ "debuffs", "cc" }) do
        local c = plate.npAuraContainers[ch]
        if c._enabled ~= false then fail(ch .. " must disable on Clear") end
        if c._shown then fail(ch .. " must hide on Clear") end
        if c._unit ~= "nameplate3" then fail("unit binding stays (SetUnit(nil) is illegal)") end
    end
end)

test("legacy fallback when the frame type is unavailable", function()
    containersEnabled = false
    local subscribed = false
    ns.AuraEvents = { Subscribe = function() subscribed = true end }
    local plate2 = NewFrame(UIParent)
    plate2.healthBar = NewFrame(plate2)
    plate2.nameText = NewRegion(plate2)
    Auras.Build(plate2)
    if plate2.npAuraMode ~= "legacy" then fail("must fall back to legacy") end
    if not plate2.npAuraSets then fail("legacy sets must build") end
    if not subscribed then fail("legacy mode must subscribe the dispatcher tier") end
end)

print("OK: nameplates_aura_container_test")
