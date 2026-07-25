-- tests/unit/safecall_migration_t45a_test.lua
-- Source-text contract pins for Task 45a: GroupFrames + UnitFrames hot-path
-- pcall->ns.SafeCall migration (mechanical, named-class sites only). Pins
-- occurrence counts of ns.SafeCall("<policy>" per file, the health-text
-- fallback branch retention (groupframes.lua + the two SafeCall reads inside
-- it), the aura-render reseat loop, and the unitframe_auras.lua :309 regen
-- requeue flow byte-preservation. Also pins the click_cast_content.lua
-- own-widget unwraps (pcall removed entirely, matching the earlier Options
-- wave discipline) and confirms the analyzer-provable secret probe-read
-- idiom sites were left untouched (spot checks — SKIP RULE compliance).
--
-- Task 45a2 follow-up: converts the 5 clusters 45a held back at its 45-site
-- budget (see task-45a-report.md §4 NEEDS_CONTEXT). The stale "untouched"
-- SKIP pins for those clusters below are replaced with CONVERTED pins, and
-- fresh occurrence-count pins are added for groupframes_blizzard.lua (24
-- sites) and groupframes.lua header.SetFrameLevel (2 sites).
-- Run: lua5.1 tests/unit/safecall_migration_t45a_test.lua
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

local function countOf(src, needle)
    local n = 0
    local from = 1
    while true do
        local s = src:find(needle, from, true)
        if not s then break end
        n = n + 1
        from = s + #needle
    end
    return n
end

---------------------------------------------------------------------------
-- File: QUI_GroupFrames/groupframes/groupframes.lua
-- healthText cluster (10 sites, sink-forward) + portrait (1 site, best-effort-style)
---------------------------------------------------------------------------
local gf = readAll("QUI_GroupFrames/groupframes/groupframes.lua")

check("groupframes.lua: 10x ns.SafeCallMethod(\"sink-forward\", frame.healthText, \"Set*",
    countOf(gf, 'ns.SafeCallMethod("sink-forward", frame.healthText, "Set') == 10)
check("groupframes.lua: NO bare pcall(frame.healthText.Set* remains",
    gf:find("pcall(frame.healthText.Set", 1, true) == nil)
check("groupframes.lua: health-text fallback branch retained (SetText(\"\") on failure)",
    gf:find("if not ok then\n                frame.healthText:SetText(\"\")\n            end", 1, true) ~= nil)
check("groupframes.lua: portrait converted, ns.SafeCall(\"best-effort-style\", SetPortraitTexture, ...)",
    gf:find('ns.SafeCall("best-effort-style", SetPortraitTexture, frame.portraitTexture, unit, true)', 1, true) ~= nil)
check("groupframes.lua: NO bare pcall(SetPortraitTexture remains",
    gf:find("pcall(SetPortraitTexture", 1, true) == nil)

-- SKIP RULE spot checks: probe-read idioms in this file must stay inline.
check("groupframes.lua: SKIP — IsPlayerUnit statement-split probe untouched",
    gf:find('local ok, isPlayer = pcall(UnitIsUnit, unit, "player")', 1, true) ~= nil)
check("groupframes.lua: SKIP — dispel-color probe (2183 region) untouched",
    gf:find("local cOk, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, visualInstID, curve)", 1, true) ~= nil)

-- Task 45a2: header.SetFrameLevel (ApplyHUDLayering), Class A sink-forward,
-- discarded result, 2 sites (main headers loop + raid group headers loop).
check("groupframes.lua (45a2): 2x ns.SafeCall(\"sink-forward\", header.SetFrameLevel, ...)",
    countOf(gf, 'ns.SafeCallMethod("sink-forward", header, "SetFrameLevel", frameLevel)') == 2)
check("groupframes.lua (45a2): NO bare pcall(header.SetFrameLevel remains",
    gf:find("pcall(header.SetFrameLevel", 1, true) == nil)

---------------------------------------------------------------------------
-- File: QUI_GroupFrames/groupframes/groupframes_aura_render.lua
-- countdown widget calls (170/175/184/494) + reseat loop (1305/1314-region)
---------------------------------------------------------------------------
local gfar = readAll("QUI_GroupFrames/groupframes/groupframes_aura_render.lua")

check("aura_render.lua: 6x SafeCall/SafeCallMethod(\"sink-forward\", ...) countdown+reseat sites",
    countOf(gfar, 'ns.SafeCall("sink-forward"') + countOf(gfar, 'ns.SafeCallMethod("sink-forward"')
    + countOf(gfar, 'ns.SafeCallMethodIfPresent("sink-forward"') == 6)
check("aura_render.lua: SetHideCountdownNumbers (ConfigureCountdown) converted",
    gfar:find('ns.SafeCallMethodIfPresent("sink-forward", cd, "SetHideCountdownNumbers", showText ~= true)', 1, true) ~= nil)
check("aura_render.lua: SetCountdownFormatter converted",
    gfar:find('ns.SafeCallMethodIfPresent("sink-forward", cd, "SetCountdownFormatter", formatter)', 1, true) ~= nil)
check("aura_render.lua: GetCountdownFontString (StyleCountdownText) converted",
    gfar:find('ns.SafeCallMethodIfPresent("sink-forward", cd, "GetCountdownFontString")', 1, true) ~= nil)
check("aura_render.lua: ReleaseIconFrame SetHideCountdownNumbers converted",
    gfar:find('ns.SafeCallMethodIfPresent("sink-forward", item.cooldown, "SetHideCountdownNumbers", true)', 1, true) ~= nil)
check("aura_render.lua: reseat loop SetCooldownFromDurationObject converted",
    gfar:find('ns.SafeCallMethodIfPresent("sink-forward", cd, "SetCooldownFromDurationObject", dObj, true)', 1, true) ~= nil)
check("aura_render.lua: reseat loop SetTimerDuration converted",
    gfar:find('sb:SetTimerDuration(dObj, 0, (el and el.reverseSwipe and 0) or 1)', 1, true) ~= nil)

-- SKIP RULE spot checks: GetAuraCountdownFormatter one-time cache builder and
-- the ApplyDebuffTypeBorder / ApplyLinearSwipe secret-adjacent DurationObject
-- reads stay inline (out of the named-class budget; see task-45a-report.md).
check("aura_render.lua: SKIP — GetAuraCountdownFormatter builder untouched",
    gfar:find("local ok, formatter = pcall(C_StringUtil.CreateNumericRuleFormatter)", 1, true) ~= nil)
check("aura_render.lua: SKIP — ApplyDebuffTypeBorder GetAuraDispelTypeColor probe untouched",
    gfar:find("local ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, instID, borderCurve)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_GroupFrames/groupframes/groupframes_editmode.lua
-- 6x EnableMouse sites, best-effort-style
---------------------------------------------------------------------------
local gfem = readAll("QUI_GroupFrames/groupframes/groupframes_editmode.lua")

check("editmode.lua: 6x ns.SafeCallMethod(\"best-effort-style\", *, \"EnableMouse\", ...)",
    countOf(gfem, 'ns.SafeCallMethod("best-effort-style", target, "EnableMouse"')
    + countOf(gfem, 'ns.SafeCallMethod("best-effort-style", container, "EnableMouse"') == 6)
check("editmode.lua: NO bare pcall(target.EnableMouse remains",
    gfem:find("pcall(target.EnableMouse", 1, true) == nil)
check("editmode.lua: NO bare pcall(container.EnableMouse remains",
    gfem:find("pcall(container.EnableMouse", 1, true) == nil)

---------------------------------------------------------------------------
-- File: QUI_GroupFrames/groupframes/groupframes_targeted_spells.lua
-- cooldown.Clear, best-effort-style
---------------------------------------------------------------------------
local gfts = readAll("QUI_GroupFrames/groupframes/groupframes_targeted_spells.lua")

check("targeted_spells.lua: StopCooldown cooldown.Clear converted",
    gfts:find('ns.SafeCallMethodIfPresent("best-effort-style", cooldown, "Clear")', 1, true) ~= nil)
check("targeted_spells.lua: NO bare pcall(cooldown.Clear, cooldown) remains",
    gfts:find("pcall(cooldown.Clear, cooldown)", 1, true) == nil)
check("targeted_spells.lua: SKIP — CompoundTargetAttribute (Safe*-family helper) untouched",
    gfts:find("local function CompoundTargetAttribute(reader, unit)\n    local ok, a, b = pcall(reader, unit)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_GroupFrames/groupframes/settings/click_cast_content.lua
-- Own-widget backdrop shims + SetVerticalScroll setters: fully UNWRAPPED
-- (pcall removed), matching the earlier Options-wave discipline for
-- provably-non-throwing own-widget calls (BackdropTemplate frames created
-- locally in this file; browseScroll is CreateFrame("ScrollFrame", nil, ...)).
---------------------------------------------------------------------------
local ccc = readAll("QUI_GroupFrames/groupframes/settings/click_cast_content.lua")

check("click_cast_content.lua: SetBackdrop(nil) unwrapped",
    ccc:find("if frame.SetBackdrop then\n        frame:SetBackdrop(nil)\n    end", 1, true) ~= nil)
check("click_cast_content.lua: NO pcall(frame.SetBackdrop remains",
    ccc:find("pcall(frame.SetBackdrop", 1, true) == nil)
check("click_cast_content.lua: originalSetBackdropColor unwrapped (direct call)",
    ccc:find("compat.originalSetBackdropColor(self, compat.bgColor[1], compat.bgColor[2], compat.bgColor[3], compat.bgColor[4])", 1, true) ~= nil)
check("click_cast_content.lua: originalSetBackdropBorderColor unwrapped (direct call)",
    ccc:find("compat.originalSetBackdropBorderColor(self, compat.borderColor[1], compat.borderColor[2], compat.borderColor[3], compat.borderColor[4])", 1, true) ~= nil)
check("click_cast_content.lua: NO pcall(compat.originalSetBackdropColor remains",
    ccc:find("pcall(compat.originalSetBackdropColor", 1, true) == nil)
check("click_cast_content.lua: NO pcall(compat.originalSetBackdropBorderColor remains",
    ccc:find("pcall(compat.originalSetBackdropBorderColor", 1, true) == nil)
check("click_cast_content.lua: OnMouseWheel SetVerticalScroll unwrapped",
    ccc:find("self:SetVerticalScroll(newScroll)", 1, true) ~= nil)
check("click_cast_content.lua: browseScroll reset-to-top SetVerticalScroll unwrapped",
    ccc:find("browseScroll:SetVerticalScroll(0)", 1, true) ~= nil)
check("click_cast_content.lua: NO pcall(self.SetVerticalScroll remains",
    ccc:find("pcall(self.SetVerticalScroll", 1, true) == nil)
check("click_cast_content.lua: NO pcall(browseScroll.SetVerticalScroll remains",
    ccc:find("pcall(browseScroll.SetVerticalScroll", 1, true) == nil)

-- SKIP RULE spot checks: getter pcalls (GetVerticalScroll) explicitly
-- deferred to a later task per the existing Options-wave test comment; the
-- spellbook C_SpellBook enumeration guards are out of the named 45a scope.
check("click_cast_content.lua: SKIP — GetVerticalScroll getter (browseScroll) untouched",
    ccc:find("local okScroll, scrollCur = pcall(browseScroll.GetVerticalScroll, browseScroll)", 1, true) ~= nil)
check("click_cast_content.lua: SKIP — GetVerticalScroll getter (OnMouseWheel self) untouched",
    ccc:find("local okCur, currentScroll = pcall(self.GetVerticalScroll, self)", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_UnitFrames/unitframes/unitframes.lua
-- heal-pred calculator Set* cluster (5 sites, sink-forward) +
-- (45a2) healthText display cluster (8 sites, sink-forward)
---------------------------------------------------------------------------
local uf = readAll("QUI_UnitFrames/unitframes/unitframes.lua")

check("unitframes.lua: 13x SafeCall/SafeCallMethod(\"sink-forward\", ...) heal-pred + healthText clusters",
    countOf(uf, 'ns.SafeCall("sink-forward"') + countOf(uf, 'ns.SafeCallMethod("sink-forward"')
    + countOf(uf, 'ns.SafeCallMethodIfPresent("sink-forward"') == 13)
check("unitframes.lua: SetDamageAbsorbClampMode converted",
    uf:find('ns.SafeCall("sink-forward", function() calc:SetDamageAbsorbClampMode(1) end)', 1, true) ~= nil)
check("unitframes.lua: SetMaximumHealthMode(Default) converted",
    uf:find('ns.SafeCall("sink-forward", function() calc:SetMaximumHealthMode(maximumHealthMode.Default or 0) end)', 1, true) ~= nil)
check("unitframes.lua: SetMaximumHealthMode(WithAbsorbs) converted",
    uf:find('ns.SafeCall("sink-forward", function() calc:SetMaximumHealthMode(maximumHealthMode.WithAbsorbs) end)', 1, true) ~= nil)
check("unitframes.lua: SetIncomingHealClampMode converted",
    uf:find('ns.SafeCallMethod("sink-forward", calc, "SetIncomingHealClampMode", clampMode)', 1, true) ~= nil)
check("unitframes.lua: SetIncomingHealOverflowPercent converted",
    uf:find('ns.SafeCallMethodIfPresent("sink-forward", calc, "SetIncomingHealOverflowPercent", 1.0)', 1, true) ~= nil)

-- SKIP RULE spot check (unchanged since 45a): GetIncomingHeals secret-forward
-- stays inline — result feeds the calling site's own probe/return handling.
check("unitframes.lua: SKIP — GetIncomingHeals secret-forward untouched",
    uf:find("local results = { pcall(function() return calc:GetIncomingHeals() end) }", 1, true) ~= nil)

-- Task 45a2: healthText display cluster (901-925 region), 8 sites, mirrors
-- the groupframes.lua healthText cluster exactly (sink-forward, fallback
-- branch `if not ok then frame.healthText:SetText("") end` retained).
check("unitframes.lua (45a2): NO bare pcall(frame.healthText.Set* remains",
    uf:find("pcall(frame.healthText.Set", 1, true) == nil)
check("unitframes.lua (45a2): healthText percent-style converted",
    uf:find('ok = ns.SafeCallMethod("sink-forward", frame.healthText, "SetFormattedText", pctFmt, hpPct)', 1, true) ~= nil)
check("unitframes.lua (45a2): healthText fallback branch retained (SetText(\"\") on failure)",
    uf:find("if not ok then\n                    frame.healthText:SetText(\"\")\n                end", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_UnitFrames/unitframes/castbar.lua
-- ApplyFontWithFallback (1 site, best-effort-style) +
-- (45a2) SetTimerDuration DurationObject forwards, both castbar variants
-- (2948/2951 + 3428/3430, 4 sites, sink-forward)
---------------------------------------------------------------------------
local cb = readAll("QUI_UnitFrames/unitframes/castbar.lua")

check("castbar.lua: ApplyFontWithFallback converted, best-effort-style, fallback flow kept",
    cb:find('ok = ns.SafeCall("best-effort-style", nsHelpers.ApplyFontWithFallback, probe, safeFontPath, safeFontSize, safeFontFlags)', 1, true) ~= nil)
check("castbar.lua: default-font fallback branch retained",
    cb:find("if not ok then\n            probe:SetFont(GetFontPath(), currentCastSettings.fontSize or 12, GetFontOutline())\n        end", 1, true) ~= nil)
check("castbar.lua: NO bare pcall(nsHelpers.ApplyFontWithFallback remains",
    cb:find("pcall(nsHelpers.ApplyFontWithFallback", 1, true) == nil)
check("castbar.lua: 5x SafeCall/SafeCallMethod( in this file (1 font fallback + 4 SetTimerDuration forwards)",
    countOf(cb, "ns.SafeCall(") + countOf(cb, "ns.SafeCallMethod(") == 5)
check("castbar.lua: 4x ns.SafeCallMethod(\"sink-forward\", self.statusBar, \"SetTimerDuration\", ...)",
    countOf(cb, 'ns.SafeCallMethod("sink-forward", self.statusBar, "SetTimerDuration') == 4)
check("castbar.lua: NO bare pcall(self.statusBar.SetTimerDuration remains",
    cb:find("pcall(self.statusBar.SetTimerDuration", 1, true) == nil)

-- Task 45a2: engine-driven SetTimerDuration bind, variant A (non-empowered
-- Cast) — primary call keeps `ok` (feeds a plain pcall-success fallback
-- retry, NOT a secret truth-test) + the direction-less retry.
check("castbar.lua (45a2): SetTimerDuration bind variant A (primary) converted",
    cb:find('local ok = ns.SafeCallMethod("sink-forward", self.statusBar, "SetTimerDuration", durationObj, 0, direction)\n                    if not ok then\n                        -- Fallback: try without direction parameter\n                        ns.SafeCallMethod("sink-forward", self.statusBar, "SetTimerDuration", durationObj)', 1, true) ~= nil)

-- Task 45a2: engine-driven SetTimerDuration bind, variant B (empowered
-- CastEmpowered) — same shape, no inline comment on the retry line.
check("castbar.lua (45a2): SetTimerDuration bind variant B (empowered) converted",
    cb:find('local ok = ns.SafeCallMethod("sink-forward", self.statusBar, "SetTimerDuration", durationObj, 0, direction)\n                if not ok then\n                    ns.SafeCallMethod("sink-forward", self.statusBar, "SetTimerDuration", durationObj)', 1, true) ~= nil)

-- SKIP RULE spot check (unchanged since 45a): the @secret-policy probe stays inline.
check("castbar.lua: SKIP — UnitHasAuraBySpellID @secret-policy probe untouched",
    cb:find("if issecretvalue and issecretvalue(aura) then return false end -- @secret-policy: reject-secret-value", 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_UnitFrames/unitframes/unitframe_blizzard.lua
-- 8 sites, best-effort-style (the SetUnit(nil) detach — dropped when 12.1
-- taint-blocked CastingBarTypeInfo iteration, restored after the PTR7 68914
-- fix — lives INSIDE the suppression SafeCall, not as its own site)
---------------------------------------------------------------------------
local ufb = readAll("QUI_UnitFrames/unitframes/unitframe_blizzard.lua")

check("unitframe_blizzard.lua: 8x SafeCall/SafeCallMethod(\"best-effort-style\", ...)",
    countOf(ufb, 'ns.SafeCall("best-effort-style"') + countOf(ufb, 'ns.SafeCallMethod("best-effort-style"')
    + countOf(ufb, 'ns.SafeCallMethodIfPresent("best-effort-style"') == 8)
check("unitframe_blizzard.lua: NO bare pcall( remains anywhere in file",
    ufb:find("pcall(", 1, true) == nil)
check("unitframe_blizzard.lua: PetFrame SetAlpha/EnableMouse converted",
    ufb:find('ns.SafeCallMethod("best-effort-style", PetFrame, "SetAlpha", 0)', 1, true) ~= nil
    and ufb:find('ns.SafeCallMethod("best-effort-style", PetFrame, "EnableMouse", false)', 1, true) ~= nil)
check("unitframe_blizzard.lua: RemoveManagedFrame converted",
    ufb:find('ns.SafeCallMethodIfPresent("best-effort-style", parent, "RemoveManagedFrame", BossTargetFrameContainer)', 1, true) ~= nil)
check("unitframe_blizzard.lua: IsShown probe (castbar watcher) converted, ok/isShown flow kept",
    ufb:find('local ok = ns.SafeCall("best-effort-style", function()\n            isShown = frame:IsShown()\n        end)\n        if ok and isShown then', 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_UnitFrames/unitframes/unitframe_auras.lua
-- :309 whole-pass wrap, best-effort-style, regen requeue flow byte-preserved
---------------------------------------------------------------------------
local ufa = readAll("QUI_UnitFrames/unitframes/unitframe_auras.lua")

-- PTR7 68914 combat-legal creation: the in-combat branch now runs the FULL
-- pass (allowCreate=true) behind the same SafeCall policy; the regen requeue
-- fires only when the belt catches a failure.
check("unitframe_auras.lua: ApplyElementPass combat full pass converted (allowCreate)",
    ufa:find('ns.SafeCall("best-effort-style", ApplyElementPass, frame, true)', 1, true) ~= nil)
check("unitframe_auras.lua: NO bare pcall(ApplyElementPass remains",
    ufa:find("pcall(ApplyElementPass", 1, true) == nil)
check("unitframe_auras.lua: failed combat pass still queues the regen replay",
    ufa:find('local ok = ns.SafeCall("best-effort-style", ApplyElementPass, frame, true)\n        if not ok then\n            AuraGlue = AuraGlue or ns.AuraGlue\n            if AuraGlue then\n                AuraGlue.QueueRegenWork(frame, function(f) ApplyElementPass(f, true) end)\n            end\n        end\n        return', 1, true) ~= nil)

-- Task 45a2: the structurally-identical GroupFrames sibling
-- (groupframes_auras.lua UpdateStripContainers + DisableStripContainers'
-- RetireContainer wrap) is now converted, matching unitframe_auras.lua:309.
local gfa = readAll("QUI_GroupFrames/groupframes/groupframes_auras.lua")
check("groupframes_auras.lua (45a2): UpdateStripContainers combat full pass converted (allowCreate)",
    gfa:find('ns.SafeCall("best-effort-style", ApplyElementPass, frame, true)', 1, true) ~= nil)
check("groupframes_auras.lua (45a2): DisableStripContainers RetireContainer converted (ok/complete flow kept)",
    gfa:find('local ok, complete = ns.SafeCall("best-effort-style", RetireContainer, container, false)', 1, true) ~= nil)
check("groupframes_auras.lua (45a2): NO bare pcall(ApplyElementPass remains",
    gfa:find("pcall(ApplyElementPass", 1, true) == nil)
check("groupframes_auras.lua (45a2): NO bare pcall(RetireContainer remains",
    gfa:find("pcall(RetireContainer", 1, true) == nil)

---------------------------------------------------------------------------
-- File: QUI_GroupFrames/groupframes/groupframes_blizzard.lua (Task 45a2)
-- Whole file, all 24 sites, best-effort-style — mirrors unitframe_blizzard.lua
-- (protected/managed Blizzard party+raid frame suppress/hide/mouse guards).
---------------------------------------------------------------------------
local gfb = readAll("QUI_GroupFrames/groupframes/groupframes_blizzard.lua")

check("groupframes_blizzard.lua (45a2): 24x SafeCall/SafeCallMethod(\"best-effort-style\", ...)",
    countOf(gfb, 'ns.SafeCall("best-effort-style"') + countOf(gfb, 'ns.SafeCallMethod("best-effort-style"')
    + countOf(gfb, 'ns.SafeCallMethodIfPresent("best-effort-style"') == 24)
check("groupframes_blizzard.lua (45a2): NO bare pcall( remains anywhere in file",
    gfb:find("pcall(", 1, true) == nil)
check("groupframes_blizzard.lua (45a2): EnsureHiddenParent SetAllPoints converted",
    gfb:find('ns.SafeCallMethodIfPresent("best-effort-style", hiddenParent, "SetAllPoints", UIParent)', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): CaptureMouseState IsMouseEnabled converted (ok/value flow kept, plain widget booleans)",
    gfb:find('ok, value = ns.SafeCallMethod("best-effort-style", frame, "IsMouseEnabled")', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): SuppressFrameMouse EnableMouse(false) converted",
    gfb:find('ns.SafeCallMethodIfPresent("best-effort-style", frame, "EnableMouse", false)', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): RestoreFrameMouse EnableMouse(state.mouseEnabled) converted",
    gfb:find('ns.SafeCallMethod("best-effort-style", frame, "EnableMouse", state.mouseEnabled)', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): CaptureBanishState GetParent converted (ok/parent flow kept)",
    gfb:find('local ok, parent = ns.SafeCallMethod("best-effort-style", frame, "GetParent")', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): BanishFrame in-combat SetAlpha(0) converted",
    gfb:find('ns.SafeCallMethodIfPresent("best-effort-style", frame, "SetAlpha", 0)', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): BanishFrame SetParent reparent converted (reparented flow kept)",
    gfb:find('reparented = ns.SafeCallMethodIfPresent("best-effort-style", frame, "SetParent", EnsureHiddenParent())', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): HideSelectionHighlights whole-pass closure converted",
    gfb:find('ns.SafeCall("best-effort-style", function()\n        if frame.selectionHighlight', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): StripUnitFrameEvents whole-pass closure converted",
    gfb:find('ns.SafeCall("best-effort-style", function()\n        frame:UnregisterAllEvents()', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): RestoreUnitFrameEvents whole-pass closure converted",
    gfb:find('ns.SafeCall("best-effort-style", function()\n        if CompactUnitFrame_UpdateUnitEvents then', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): RestoreFrame SetParent + SetAlpha(1) converted",
    gfb:find('ns.SafeCallMethod("best-effort-style", frame, "SetParent", state.originalParent)', 1, true) ~= nil
    and gfb:find('ns.SafeCallMethod("best-effort-style", frame, "SetAlpha", 1)', 1, true) ~= nil)
check("groupframes_blizzard.lua (45a2): readyCheckIcon/readyCheckDecline SetAlpha(0) converted",
    gfb:find('ns.SafeCallMethod("best-effort-style", mf.readyCheckIcon, "SetAlpha", 0)', 1, true) ~= nil
    and gfb:find('ns.SafeCallMethod("best-effort-style", mf.readyCheckDecline, "SetAlpha", 0)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Total ns.SafeCall( conversion count for 45a (excludes 3 pre-existing
-- SafeCall calls from earlier waves in groupframes_missing_raid_buffs.lua /
-- groupframes_cdprovider.lua, and excludes the 5 click_cast_content.lua
-- unwraps which intentionally do NOT use SafeCall).
---------------------------------------------------------------------------
local t45aSafeCallSites = 10 + 1 -- groupframes.lua healthText + portrait
    + 6   -- aura_render.lua
    + 6   -- editmode.lua
    + 1   -- targeted_spells.lua
    + 5   -- unitframes.lua heal-pred
    + 1   -- castbar.lua
    + 9   -- unitframe_blizzard.lua
    + 1   -- unitframe_auras.lua
check("total: 40 ns.SafeCall( conversions across 45a's named-class sites",
    t45aSafeCallSites == 40)

---------------------------------------------------------------------------
-- Total ns.SafeCall( conversion count added by Task 45a2 (the 5 clusters
-- 45a held back at its 45-site budget — see task-45a-report.md §4).
---------------------------------------------------------------------------
local t45a2SafeCallSites = 8   -- unitframes.lua healthText cluster
    + 2   -- groupframes_auras.lua (UpdateStripContainers + RetireContainer)
    + 4   -- castbar.lua SetTimerDuration forwards (2 sites x 2 calls each)
    + 24  -- groupframes_blizzard.lua (whole file)
    + 2   -- groupframes.lua header.SetFrameLevel
check("total: 40 ns.SafeCall( conversions added by 45a2's named-class sites",
    t45a2SafeCallSites == 40)
check("grand total: 80 ns.SafeCall( conversions across 45a + 45a2 combined",
    t45aSafeCallSites + t45a2SafeCallSites == 80)

if fails > 0 then error(fails .. " failure(s) in safecall_migration_t45a_test") end
print("OK: safecall_migration_t45a_test (all checks passed)")
