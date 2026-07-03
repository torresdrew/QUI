-- tests/unit/buffborders_late_child_tooltip_test.lua
-- Run: lua tests/unit/buffborders_late_child_tooltip_test.lua
--
-- Regression guard: tooltips on buff icons whose secure cancel-overlay child was
-- created AFTER config time.
--
-- Root cause (12.1): live buff tooltips come from the forbidden
-- CustomAuraButton's intrinsic OnEnter (Blizzard_AuraButton.lua ShowTooltip).
-- QUI's alpha-0 SecureAuraHeader cancel children sit on top of every grid slot,
-- so hover only reaches the forbidden button when the child has
-- SetPropagateMouseMotion(true). That call CANNOT come from the
-- initialConfigFunction snippet: it runs on a restricted frame handle
-- (SecureGroupHeaders.lua CallRestrictedClosure) and RestrictedFrames.lua
-- handles expose no SetPropagateMouseMotion/SetPassThroughButtons, so the
-- `if self.SetPropagateMouseMotion` clauses are silently dead. Only the
-- insecure RefreshBuffCancelChildren pass applies them — and it used to run
-- only at ApplyContainerConfig. SecureAuraHeader creates children lazily as the
-- live buff count exceeds its all-time max (configureAuras child..i), so any
-- child born after config blocked mouse motion at its slot: no tooltip (and
-- swallowed left-clicks) for exactly the transient short buffs that pushed the
-- count up. Confirmed in-game: CanPropagateMouseMotion() false on late children.
--
-- The fix must:
--   * watch the header's "childN" attribute assignments (an insecure
--     HookScript on OnAttributeChanged — setAttributesWithoutResponse still
--     fires the script; NOT a UNIT_AURA registration, which the banish-taint
--     test forbids for the live display);
--   * defer the styling pass one frame (the attribute lands mid-layout);
--   * skip already-styled children via a marker so the per-event cost is nil;
--   * defer to PLAYER_REGEN_ENABLED when in combat (the setters are protected).

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local source = readFile("QUI_ActionBars/actionbars/buffborders.lua")

-- Trigger: insecure post-hook on the header's OnAttributeChanged catches each
-- "childN" attribute the header assigns at child creation. Must NOT register
-- UNIT_AURA (buffborders_blizzard_banish_taint_test forbids that pattern).
assert(source:find('HookScript("OnAttributeChanged", OnCancelHeaderAttributeChanged)', 1, true),
    "buffborders.lua must post-hook the cancel header's OnAttributeChanged to catch late-created children")
assert(source:find('name:find("^child%d")', 1, true),
    "the OnAttributeChanged hook must filter to childN attribute assignments")

-- The styling pass must be deferred one frame (the childN attribute lands
-- mid-layout inside the header's secure update).
assert(source:find("StyleNewCancelChildren", 1, true),
    "buffborders.lua must have a StyleNewCancelChildren pass for late-created children")
local schedulePos = source:find("ScheduleChildStyle", 1, true)
assert(schedulePos, "buffborders.lua must schedule the late-child styling pass")
assert(source:find("C_Timer.After(0, RunScheduledChildStyle)", 1, true),
    "late-child styling must defer one frame via C_Timer.After(0, ...)")

-- Already-styled children must be skipped (marker set where styling happens).
assert(source:find("_quiCancelStyled", 1, true),
    "StyleBuffCancelChild must mark styled children so the UNIT_AURA pass skips them")

-- The protected setters cannot run in combat: pending flag + regen flush.
assert(source:find("pendingChildStyle", 1, true),
    "late-child styling must queue via pendingChildStyle when InCombatLockdown")
local regenPos = source:find('RegisterEvent("PLAYER_REGEN_ENABLED")', 1, true)
assert(regenPos, "buffborders.lua must keep the PLAYER_REGEN_ENABLED handler")
local regenBody = source:sub(regenPos, regenPos + 600)
assert(regenBody:find("pendingChildStyle", 1, true),
    "PLAYER_REGEN_ENABLED handler must flush pendingChildStyle")

-- The initialConfigFunction dead clauses must NOT be the only propagation path:
-- the insecure styling helper must still apply both protected setters.
local stylePos = source:find("local function StyleBuffCancelChild", 1, true)
assert(stylePos, "StyleBuffCancelChild helper must exist")
local styleBody = source:sub(stylePos, stylePos + 900)
assert(styleBody:find("SetPropagateMouseMotion", 1, true),
    "StyleBuffCancelChild must apply SetPropagateMouseMotion (tooltip pass-through)")
assert(styleBody:find("SetPassThroughButtons", 1, true),
    "StyleBuffCancelChild must apply SetPassThroughButtons (left-click pass-through)")

print("OK: buffborders_late_child_tooltip_test")
