-- tests/unit/nameplates_preview_test.lua
-- Run: lua tests/unit/nameplates_preview_test.lua
--
-- Options preview driver: builds the mock plate through the suite's REAL
-- builders, paints fake data honoring settings (health text style, castbar
-- toggle, aura row limit, duration precision), rebinds on a new host, and
-- never engages the lift overlay.

local function fail(msg)
    print("FAIL: nameplates_preview_test - " .. msg)
    os.exit(1)
end

local function noop() end

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
        SetAlphaFromBoolean = noop,
        SetHorizTile = noop, SetVertTile = noop, SetTexCoord = noop,
        AddMaskTexture = noop, SetBlendMode = noop,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetText = function(self, t) self._text = t end,
        SetFormattedText = noop, SetTextColor = noop, SetFont = noop,
        SetJustifyH = noop,
    }
end

local function NewFrame(parent)
    local f = NewRegion(parent)
    f._scripts = {}
    f.SetScript = function(self, k, h) self._scripts[k] = h end
    f.GetScript = function(self, k) return self._scripts[k] end
    f.HookScript = noop
    f.RegisterEvent = noop
    f.RegisterUnitEvent = noop
    f.UnregisterAllEvents = noop
    f.EnableMouse = noop
    f.SetFrameStrata = noop
    f.SetFrameLevel = noop
    f.GetFrameLevel = function() return 1 end
    f.SetScale = function(self, s) self._scale = s end
    f.SetIgnoreParentScale = noop
    f.SetShown = function(self, s) if s then self:Show() else self:Hide() end end
    f.IsShown = function(self) return self._shown end
    f.GetWidth = function(self) return self._w or 700 end
    f.GetHeight = function(self) return self._h or 160 end
    f.CreateTexture = function(self) return NewRegion(self) end
    f.CreateMaskTexture = function(self) return NewRegion(self) end
    f.CreateFontString = function(self) return NewRegion(self) end
    f.SetStatusBarTexture = noop
    f.GetStatusBarTexture = function(self) return self._fill or NewRegion(self) end
    f.SetStatusBarColor = function(self, r, g, b) self._color = { r, g, b } end
    f.SetMinMaxValues = function(self, lo, hi) self._minMax = { lo, hi } end
    f.SetValue = function(self, v) self._value = v end
    f.SetDrawEdge = noop
    f.SetHideCountdownNumbers = noop
    f.SetCooldownFromDurationObject = noop
    f.Clear = noop
    f.GetRegions = function() return nil end
    return f
end

CreateFrame = function(_, _, parent) return NewFrame(parent) end
UIParent = NewFrame(nil)
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
C_Timer = { After = function() end, NewTicker = function() return { Cancel = noop } end }
GetTime = function() return 0 end
InCombatLockdown = function() return false end
SetCVar = noop
SetRaidTargetIconTexture = function(tex, i) tex._markIndex = i end
RAID_CLASS_COLORS = {}
C_StringUtil = nil
C_CurveUtil = nil
C_UnitAuras = nil
CreateColor = nil
Enum = {}
UnitCastingInfo = function() return nil end
UnitChannelInfo = function() return nil end
GetPlayerInfoByGUID = function() return nil end
IsPlayerSpell = function() return false end
IsSpellKnown = function() return false end
C_Spell = nil

local settings = {
    enabled = true,
    health = { width = 210, height = 24, borderSize = 1 },
    healthText = { enabled = true, style = "percent", size = 10 },
    name = { enabled = true, size = 11 },
    castbar = { enabled = true, height = 17, kickTick = true, liftOverlay = true },
    absorbs = { enabled = true },
    colors = { castInterruptible = { 0.7, 0.4, 0.9 } },
    highlight = { targetGlow = true },
    raidMarker = { enabled = true },
    auras = {
        enabled = true,
        duration = { enabled = true, size = 12, decimals = false },
        debuffs = { enabled = true, size = 26, limit = 2, growth = "RIGHT", spacing = 2, textSize = 11 },
        buffs = {}, cc = {},
    },
}
local ns = {
    Helpers = {
        IsSecretValue = function() return false end,
        SafeToNumber = function(v, fb) return tonumber(v) or fb or 0 end,
        TruncateUTF8 = function(s) return s end,
        GetModuleSettings = function() return settings end,
        GetProfile = function() return { nameplates = settings } end,
    },
    UIKit = {
        CreateBackground = function(parent) return NewRegion(parent) end,
        CreateBorderLines = noop, UpdateBorderLines = noop,
        CreateText = function(parent) return NewRegion(parent) end,
        ResolveFontPath = function() return "" end,
        CreateIcon = function(parent)
            local f = NewFrame(parent)
            f.texture = NewRegion(f)
            f.border = NewRegion(f)
            return f
        end,
        UpdateIconLayout = noop,
    },
    Addon = {
        Pixels = function(_, v) return v end,
        SetPixelPerfectSize = function(_, f, w, h) f._w, f._h = w, h end,
        ApplyFont = noop,
    },
    L = setmetatable({}, { __index = function(_, k) return k end }),
    AuraEvents = { Subscribe = noop },
    LSM = nil,
}

assert(loadfile("core/cast_engine.lua"))("QUI", ns)
for _, file in ipairs({ "shared.lua", "cvars.lua", "plate_colors.lua", "plate_health.lua",
    "plate_castbar.lua", "plate_auras.lua", "plate_extras.lua" }) do
    assert(loadfile("QUI_Nameplates/nameplates/" .. file))("QUI_Nameplates", ns)
end
assert(loadfile("QUI_Nameplates/nameplates/settings/nameplates_preview_driver.lua"))("QUI_Nameplates", ns)

if not ns.QUI_BuildNameplatePreview then fail("driver must export ns.QUI_BuildNameplatePreview") end

local function test(n, f) print(n); f(); print("  ok") end

local host = NewFrame(UIParent)

test("build paints a full mock plate from real builders", function()
    ns.QUI_BuildNameplatePreview(host)
    local NP = ns.QUI_Nameplates
    -- find the plate: driver keeps it internal; assert through effects.
    -- Rebuild returns same state; drive assertions via a second refresh:
    ns.QUI_RefreshNameplatePreview()
    -- the plate was parented under host — walk host children is not possible
    -- with these stubs, so assert via the module-level state the driver
    -- exposes indirectly: painting must not error and the fake settings
    -- must produce a visible castbar (checked below through a rebind).
end)

-- Rebind to a fresh host and keep handles by intercepting CreateFrame.
local created = {}
local baseCreate = CreateFrame
CreateFrame = function(kind, name, parent)
    local f = baseCreate(kind, name, parent)
    created[#created + 1] = f
    return f
end
local host2 = NewFrame(UIParent)

test("rebinding to a new host rebuilds; castbar + kick tick painted", function()
    ns.QUI_BuildNameplatePreview(host2)
    -- the mock plate is the first created frame parented to host2
    local plate
    for _, f in ipairs(created) do
        if f._parent == host2 then plate = f break end
    end
    if not plate then fail("mock plate must build on the new host") end
    if not plate.castBar._shown then fail("castbar must show in the preview") end
    if plate.castBar._value ~= 0.62 then fail("castbar must paint the fake progress") end
    if plate.castSpellText._text ~= "Pyroblast" then fail("spell name must paint") end
    if not plate.kickBar._shown then fail("kick tick must show when enabled") end
    if plate.healthBar._value ~= 65 then fail("health must paint the fake percent") end
    if plate.healthText._text ~= "65%" then fail("health text must honor the style") end
    if plate.nameText._text ~= "Cleave Training Dummy" then fail("name must paint") end
    if not plate.npRaidMarker._shown then fail("raid marker must show when enabled") end
    if plate.npRaidMarker._markIndex ~= 8 then fail("marker must be skull") end
    if not plate.npTargetGlow._shown then fail("target glow must show when enabled") end

    -- lift overlay must never engage in the preview
    if plate.npLiftOverlay then fail("preview must force the lift overlay off") end
    if plate.castBar._parent ~= plate then fail("castbar must stay parented to the mock plate") end

    -- aura row honors the limit (2 of 3 fakes) and duration precision
    local rowIcons = 0
    for _, f in ipairs(created) do
        if f.iconFrame and f._shown then rowIcons = rowIcons + 1 end
    end
    if rowIcons ~= 2 then fail("aura row must honor the limit (expected 2, got " .. rowIcons .. ")") end
    for _, f in ipairs(created) do
        if f.iconFrame and f._shown and f.durationText._text == "2.4" then
            fail("decimals off must truncate the fake duration")
        end
    end
end)

test("settings changes repaint through the refresh export", function()
    local plate
    for _, f in ipairs(created) do
        if f._parent == host2 then plate = f break end
    end
    settings.castbar.enabled = false
    settings.healthText.style = "both"
    ns.QUI_RefreshNameplatePreview()
    if plate.castBar._shown then fail("disabling the castbar must hide it in the preview") end
    if plate.kickBar._shown then fail("kick tick must hide with the castbar") end
    if plate.healthText._text ~= "1.4M | 65%" then
        fail("style 'both' must repaint, got " .. tostring(plate.healthText._text))
    end
end)

print("OK: nameplates_preview_test")
