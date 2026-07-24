-- tests/unit/safecall_redundant_removal_t2_test.lua
-- Source-text contract pins for Task 2 (delete pcalls proven redundant around
-- code that cannot throw). Per file: the deleted pcall shapes are gone, the
-- retained logic is present, and at least one upstream sanitize/guard line
-- that makes each deletion safe is pinned as load-bearing (no pcall left to
-- paper over a regression if that guard ever moves/breaks).
--
-- Run: lua5.1 tests/unit/safecall_redundant_removal_t2_test.lua

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a"); f:close()
    return (d:gsub("\r\n", "\n"))
end

local fails = 0
local function check(name, ok)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name) end
end

---------------------------------------------------------------------------
-- Site 1-3: QUI_UnitFrames/unitframes/unitframes.lua
---------------------------------------------------------------------------
local unitframes = readAll("QUI_UnitFrames/unitframes/unitframes.lua")

-- Site 2/3 (TruncateName): deleted shapes absent.
check("unitframes: NO pcall(function() return #name end) remains",
    unitframes:find("pcall(function() return #name end)", 1, true) == nil)
check("unitframes: NO pcall(string.sub, name, 1, i - 1) remains",
    unitframes:find("pcall(string.sub, name, 1, i - 1)", 1, true) == nil)

-- Site 2/3: retained logic, now direct.
check("unitframes: nameLen is now a direct #name (wrapper gone)",
    unitframes:find("local nameLen = #name", 1, true) ~= nil)
check("unitframes: TruncateName now returns string.sub(name, 1, i - 1) directly",
    unitframes:find("return string.sub(name, 1, i - 1)\nend", 1, true) ~= nil)

-- Site 2/3 sanitize-trace: name is proven a non-secret plain string by this
-- guard (secret path already returned above it) before either deleted pcall
-- site is reached. Now load-bearing.
check("unitframes: TruncateName's non-secret/type(name)==string guard still present (load-bearing)",
    unitframes:find('if not name or type(name) ~= "string" then return name end', 1, true) ~= nil)
check("unitframes: TruncateName's IsSecretValue(name) early-return still present (load-bearing)",
    unitframes:find("if IsSecretValue(name) then", 1, true) ~= nil)

-- Site 1 (FormatPowerText "current"/else branches): deleted shape absent.
-- Both former sites shared this exact pcall body; a single pin covers both.
check("unitframes: NO pcall(function() ... result = powerStr or \"\" ... end) remains",
    unitframes:find('local fmtOk = pcall(function()\n            result = powerStr or ""\n        end)', 1, true) == nil)

-- Site 1: retained logic, now direct, in both former branches.
check('unitframes: FormatPowerText "current" branch is now a direct assignment',
    unitframes:find('elseif style == "current" then\n        result = powerStr or ""\n    elseif style == "both" then', 1, true) ~= nil)
check('unitframes: FormatPowerText default/else branch is now a direct assignment',
    unitframes:find('else\n        result = powerStr or ""\n    end\n\n    return result', 1, true) ~= nil)

-- Site 1: NOT a drive-by — the "percent" and "both" branches' string_format
-- pcalls (never proven plain: powerPct isn't sanitized here) must survive.
local _, fmtOkTotal = unitframes:gsub("local fmtOk = pcall%(function%(%)", "")
check("unitframes: the 2 untouched FormatPowerText pcalls (percent/both string_format) survive",
    fmtOkTotal == 2)

-- Site 1 sanitize-trace: powerStr is guaranteed a plain Lua string by this
-- (untouched) pcall-guarded assignment before either deleted site consumes
-- it via `powerStr or ""`. Now load-bearing.
check("unitframes: powerStr init/assignment pcall still present (load-bearing sanitize for site 1)",
    unitframes:find('local powerStr = ""\n    pcall(function()\n        local abbr = AbbreviateNumbers or AbbreviateLargeNumbers\n        powerStr = abbr and abbr(power) or tostring(power)\n    end)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 4: QUI_Options/shared.lua
---------------------------------------------------------------------------
local optShared = readAll("QUI_Options/shared.lua")

check("shared.lua: NO pcall(function() return math.max(0, maxScroll or 0) end) remains",
    optShared:find("pcall(function() return math.max(0, maxScroll or 0) end)", 1, true) == nil)
check("shared.lua: NO pcall(function() return currentScroll + 0 end) remains",
    optShared:find("pcall(function() return currentScroll + 0 end)", 1, true) == nil)
check("shared.lua: NO pcall-wrapped OnMouseWheel arithmetic (okNewScroll) remains",
    optShared:find("local okNewScroll, newScroll = pcall(function()", 1, true) == nil)

check("shared.lua: GetSafeVerticalScrollRange arithmetic is now direct",
    optShared:find("return math.max(0, maxScroll or 0)", 1, true) ~= nil)
check("shared.lua: GetSafeVerticalScroll arithmetic is now direct",
    optShared:find("return currentScroll + 0", 1, true) ~= nil)
check("shared.lua: OnMouseWheel newScroll is now a direct math.max/min expression",
    optShared:find("local newScroll = math.max(0, math.min(currentScroll - (delta * SCROLL_STEP), maxScroll))", 1, true) ~= nil)

-- NOT a drive-by: the outer raw-Blizzard-getter pcalls (frame-lifecycle
-- guard, not arithmetic) were not in scope and must survive untouched.
check("shared.lua: outer pcall(scrollFrame.GetVerticalScrollRange...) still present (out of scope, untouched)",
    optShared:find("local ok, maxScroll = pcall(scrollFrame.GetVerticalScrollRange, scrollFrame)", 1, true) ~= nil)
check("shared.lua: outer pcall(scrollFrame.GetVerticalScroll...) still present (out of scope, untouched)",
    optShared:find("local ok, currentScroll = pcall(scrollFrame.GetVerticalScroll, scrollFrame)", 1, true) ~= nil)

-- Sanitize-trace: the file's own documented policy that these are plain UI
-- scroll frames (never combat/protected), which is why the pure-arithmetic
-- wrap on their already-fetched values was redundant. Now load-bearing.
check("shared.lua: 'non-secure options frames' policy comment still present (load-bearing sanitize-trace)",
    optShared:find("these are non-secure options frames", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 5: modules/layout/layoutmode_settings.lua
---------------------------------------------------------------------------
local layoutSettings = readAll("modules/layout/layoutmode_settings.lua")

check("layoutmode_settings: NO pcall-wrapped OnMouseWheel arithmetic (okNew) remains",
    layoutSettings:find("local okNew, newScroll = pcall(function()", 1, true) == nil)
check("layoutmode_settings: OnMouseWheel newScroll is now a direct math.max/min expression",
    layoutSettings:find("local newScroll = math.max(0, math.min(currentScroll - (delta * SCROLL_STEP), maxScroll))", 1, true) ~= nil)

-- Follow-up (T1a suite-wide convention): the un-cited pcall around the
-- SetVerticalScroll call itself (a different, non-arithmetic site — own
-- frame, plain clamped number) was later unwrapped to a direct method call.
check("layoutmode_settings: OnMouseWheel SetVerticalScroll is now a direct self:SetVerticalScroll(newScroll) call (T1a follow-up)",
    layoutSettings:find("pcall(self.SetVerticalScroll, self, newScroll)", 1, true) == nil
    and layoutSettings:find("self:SetVerticalScroll(newScroll)", 1, true) ~= nil)

-- Sanitize-trace: SafeGetVerticalScroll/SafeGetVerticalScrollRange (untouched
-- by this task) guarantee a plain Lua number return (fallback 0 on failure,
-- else the sanitized value) — this contract is what makes the site 5
-- deletion safe. Now load-bearing.
check("layoutmode_settings: SafeGetVerticalScroll still guarantees a plain-number return (load-bearing sanitize-trace)",
    layoutSettings:find("local function SafeGetVerticalScroll(scrollFrame)", 1, true) ~= nil
    and layoutSettings:find("return ok2 and safeCurrent or 0", 1, true) ~= nil)
check("layoutmode_settings: SafeGetVerticalScrollRange still guarantees a plain-number return (load-bearing sanitize-trace)",
    layoutSettings:find("local function SafeGetVerticalScrollRange(scrollFrame)", 1, true) ~= nil
    and layoutSettings:find("return ok2 and safeMax or 0", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 6: modules/dungeon/brez_counter.lua
---------------------------------------------------------------------------
local brezCounter = readAll("modules/dungeon/brez_counter.lua")

check("brez_counter: NO pcall(tonumber, value) remains",
    brezCounter:find("pcall(tonumber, value)", 1, true) == nil)
check("brez_counter: tonumber(value) is now a direct call",
    brezCounter:find("local num = tonumber(value)", 1, true) ~= nil)

-- Sanitize-trace: value is nil-or-secret filtered before tonumber() is ever
-- reached; tonumber() itself never throws on a single plain argument
-- (total function in Lua 5.1). Now load-bearing.
check("brez_counter: value nil/secret guard still present (load-bearing sanitize-trace)",
    brezCounter:find("if value == nil or Helpers.IsSecretValue(value) then", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 7-8: QUI_GroupFrames/groupframes/groupframes.lua
---------------------------------------------------------------------------
local groupframes = readAll("QUI_GroupFrames/groupframes/groupframes.lua")

check("groupframes: NO pcall(StaticPopup_FindVisible, ...) remains",
    groupframes:find("pcall(StaticPopup_FindVisible,", 1, true) == nil)
check("groupframes: NO pcall(C_SummonInfo.GetSummonConfirmTimeLeft) remains",
    groupframes:find("pcall(C_SummonInfo.GetSummonConfirmTimeLeft)", 1, true) == nil)

check("groupframes: StaticPopup_FindVisible('CONFIRM_SUMMON') is now a direct call",
    groupframes:find('local popup = StaticPopup_FindVisible("CONFIRM_SUMMON")', 1, true) ~= nil)
check("groupframes: StaticPopup_FindVisible('CONFIRM_SUMMON_SCENARIO') is now a direct call",
    groupframes:find('popup = StaticPopup_FindVisible("CONFIRM_SUMMON_SCENARIO")', 1, true) ~= nil)
check("groupframes: StaticPopup_FindVisible('CONFIRM_SUMMON_STARTING_AREA') is now a direct call",
    groupframes:find('popup = StaticPopup_FindVisible("CONFIRM_SUMMON_STARTING_AREA")', 1, true) ~= nil)
check("groupframes: C_SummonInfo.GetSummonConfirmTimeLeft() is now a direct call",
    groupframes:find("local timeLeft = C_SummonInfo.GetSummonConfirmTimeLeft()", 1, true) ~= nil)

-- Nil-checks kept per brief (site 7/8 explicitly say "keep any nil-check").
check("groupframes: popup truthy nil-check kept (CONFIRM_SUMMON)",
    groupframes:find('if popup then return true, "CONFIRM_SUMMON" end', 1, true) ~= nil)
check("groupframes: IsSecretValue(popup) probe kept (defensive, still present)",
    groupframes:find("if not IsSecretValue(popup) then", 1, true) ~= nil)
check("groupframes: IsSecretValue(timeLeft) probe kept (defensive, still present)",
    groupframes:find("if not IsSecretValue(timeLeft) then", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 9: QUI_ResourceBars/resourcebars/resourcebars.lua
---------------------------------------------------------------------------
local resourcebars = readAll("QUI_ResourceBars/resourcebars/resourcebars.lua")

for _, shape in ipairs({
    "pcall(function() return bar:IsShown() end)",
    "pcall(function() return bar:GetEffectiveAlpha() end)",
    "pcall(function() return bar:GetCenter() end)",
    "pcall(function() return bar:GetWidth() end)",
    "pcall(function() return bar:GetHeight() end)",
    "pcall(function() return UIParent:GetCenter() end)",
}) do
    check("resourcebars: NO " .. shape .. " remains",
        resourcebars:find(shape, 1, true) == nil)
end

check("resourcebars: IsBarVisuallyShown now calls bar:IsShown() directly",
    resourcebars:find("if not bar:IsShown() then return false end", 1, true) ~= nil)
check("resourcebars: IsBarVisuallyShown now calls bar:GetEffectiveAlpha() directly",
    resourcebars:find("local alpha = bar:GetEffectiveAlpha()", 1, true) ~= nil)
check("resourcebars: GetLiveBarRect now calls bar:GetCenter() directly",
    resourcebars:find("local cx, cy = bar:GetCenter()", 1, true) ~= nil)
check("resourcebars: GetLiveBarRect now calls bar:GetWidth()/GetHeight() directly",
    resourcebars:find("local w, h = bar:GetWidth(), bar:GetHeight()", 1, true) ~= nil)
check("resourcebars: GetLiveBarRect now calls UIParent:GetCenter() directly",
    resourcebars:find("local scx, scy = UIParent:GetCenter()", 1, true) ~= nil)

-- Existence/nil checks kept per brief ("bar and bar:GetWidth()" — expressed
-- here as the function-entry `if not bar then return` plus the retained
-- type()/range checks on every geometry read).
check("resourcebars: bar-nil guard kept at IsBarVisuallyShown entry",
    resourcebars:find("local function IsBarVisuallyShown(bar)\n    if not bar then return false end", 1, true) ~= nil)
check("resourcebars: bar-nil guard kept at GetLiveBarRect entry",
    resourcebars:find("local function GetLiveBarRect(bar)\n    if not bar then return nil end", 1, true) ~= nil)
check("resourcebars: type(w)/type(h) range checks kept in GetLiveBarRect",
    resourcebars:find('if type(w) ~= "number" or type(h) ~= "number" or w <= 1 or h <= 1 then', 1, true) ~= nil)

-- Sanitize-trace: IsBarVisuallyShown/GetLiveBarRect are reached via THREE
-- call chains, not just one, and each bails out of combat before either
-- helper runs, so the SecretWhenAnchoringSecret / SecretReturnsForAspect
-- gating on GetWidth/GetHeight/GetCenter/IsShown/GetEffectiveAlpha (real
-- Blizzard doc annotations — see task-2-report.md) can never trigger at
-- these call sites. All three bails are load-bearing for the site 9
-- deletion:
--   1. QUICore:UpdateResourceBarsProxy (direct caller of IsBarVisuallyShown)
--   2. CaptureNaturalSlotsIfPossible (calls GetLiveBarRect via
--      CaptureLiveBarSlot)
--   3. the swap-bootstrap phase-2 C_Timer.After(0.3, ...) callback (also
--      calls GetLiveBarRect via CaptureLiveBarSlot)
check("resourcebars: UpdateResourceBarsProxy's combat-lockdown bail-out still present (load-bearing sanitize-trace for site 9)",
    resourcebars:find("function QUICore:UpdateResourceBarsProxy()\n    if InCombatLockdown() then return end", 1, true) ~= nil)
check("resourcebars: CaptureNaturalSlotsIfPossible's combat-lockdown bail-out still present (load-bearing sanitize-trace for site 9)",
    resourcebars:find("local function CaptureNaturalSlotsIfPossible()\n    if ShouldSwapBars() then return end  -- bars are in swap mode; positions aren't natural\n    if InCombatLockdown() then return end", 1, true) ~= nil)
check("resourcebars: swap-bootstrap phase-2 callback's combat-lockdown bail-out still present (load-bearing sanitize-trace for site 9)",
    resourcebars:find("C_Timer.After(0.3, function()\n            if InCombatLockdown() then\n                _swapBootstrapForcingNatural = false\n                ScheduleSwapBootstrap()\n                return\n            end", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 10: modules/qol/blizzard_mover.lua
---------------------------------------------------------------------------
local blizzardMover = readAll("modules/qol/blizzard_mover.lua")

check("blizzard_mover: NO pcall(function() wrapping strip.onDrag*Callback assignments remains",
    blizzardMover:find("pcall(function()\n\t\t\tstrip.onDragStartCallback", 1, true) == nil)
check("blizzard_mover: strip.onDragStartCallback assignment is now direct",
    blizzardMover:find("strip.onDragStartCallback = function() return false end", 1, true) ~= nil)
check("blizzard_mover: strip.onDragStopCallback assignment is now direct",
    blizzardMover:find("strip.onDragStopCallback = function() return false end", 1, true) ~= nil)

-- Sanitize-trace: strip is guaranteed a valid, non-nil frame by this
-- fallback-creation guard immediately above the (deleted) wrapper — plain
-- field assignment on our own freshly-created frame cannot throw.
-- Now load-bearing.
check("blizzard_mover: strip fallback-creation guard still present (load-bearing sanitize-trace)",
    blizzardMover:find('if not ok or not strip then strip = CreateFrame("Frame", nil, anchor) end', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 11: modules/qol/tooltip.lua
---------------------------------------------------------------------------
local tooltip = readAll("modules/qol/tooltip.lua")

check("tooltip: NO pcall(C_Spell.GetSpellTexture, spellID) remains",
    tooltip:find("pcall(C_Spell.GetSpellTexture, spellID)", 1, true) == nil)
check("tooltip: NO pcall(C_Item.GetItemMaxStackSizeByID, itemID) remains",
    tooltip:find("pcall(C_Item.GetItemMaxStackSizeByID, itemID)", 1, true) == nil)

check("tooltip: C_Spell.GetSpellTexture(spellID) is now a direct call",
    tooltip:find("local result = C_Spell.GetSpellTexture(spellID)", 1, true) ~= nil)
check("tooltip: C_Item.GetItemMaxStackSizeByID(itemID) is now a direct call",
    tooltip:find("local stackSize = C_Item.GetItemMaxStackSizeByID(itemID)", 1, true) ~= nil)

-- Result nil-checks kept (type checks on both).
check("tooltip: GetSpellTexture result type-check kept",
    tooltip:find('if result and type(result) == "number" then', 1, true) ~= nil)
check("tooltip: GetItemMaxStackSizeByID result type-check kept",
    tooltip:find('if type(stackSize) ~= "number" or stackSize <= 1 then return end', 1, true) ~= nil)

-- Sanitize-trace: spellID/itemID are type(number)-checked AND
-- issecretvalue()-rejected immediately above, before either deleted pcall
-- site is reached. Now load-bearing. (Neither wrapped function carries a
-- SecretReturns/SecretWhen* annotation on its RETURN in the Blizzard docs —
-- see task-2-report.md — so no result-side secret-probe is required.)
check("tooltip: spellID type+secret guard still present before AddSpellIDToTooltip's call site (load-bearing)",
    tooltip:find('if type(spellID) ~= "number" then return end\n        if type(issecretvalue) == "function" and issecretvalue(spellID) then return end', 1, true) ~= nil)
check("tooltip: itemID type+secret guard still present before AddItemMaxStackSizeToTooltip's call site (load-bearing)",
    tooltip:find('if type(itemID) ~= "number" then return end\n        if type(issecretvalue) == "function" and issecretvalue(itemID) then return end', 1, true) ~= nil)

---------------------------------------------------------------------------
if fails > 0 then error(fails .. " failure(s) in safecall_redundant_removal_t2_test") end
print("OK: safecall_redundant_removal_t2_test (all checks passed)")
