-- tests/unit/buffborders_cancel_combat_visibility_test.lua
-- Run: lua tests/unit/buffborders_cancel_combat_visibility_test.lua
--
-- Regression guard: in-combat tooltips + right-click cancel safety on the buff
-- border cancel overlay (user report 2026-07-03: in combat, hovering the buff
-- border shows no tooltips and right-click cancel misses certain buffs).
--
-- Two root causes, one architectural constraint:
--
-- 1. The secure header DOES construct children mid-combat: SecureAuraHeader_Update
--    runs in Blizzard's secure UNIT_AURA/OnShow context, where protected-template
--    CreateFrame + SetPoint are legal in combat. The earlier late-child fix
--    assumed otherwise and deferred ALL styling to PLAYER_REGEN_ENABLED, so a
--    child born in combat blocked mouse motion (no tooltip, swallowed left-click)
--    at its slot for the whole fight. The insecure setters really are
--    combat-blocked (SetPropagateMouseMotion / SetPassThroughButtons are
--    IsProtectedFunction + HasRestrictions per SimpleScriptRegionAPIDocumentation),
--    so the fix is at construction time: restricted handles DO expose EnableMouse
--    (RestrictedFrames.lua HANDLE:EnableMouse), so the initialConfigFunction
--    snippet births every child mouse-transparent; the insecure styling pass
--    re-enables mouse when it applies the pass-through setters OOC.
--
-- 2. The cancel overlay's order can NEVER exactly match the display order in
--    combat: CustomAuraContainer assigns auras to display buttons in
--    AuraUtil.DefaultAuraCompare priority order (own-first, then isPriorityAura,
--    then canApplyAura, then auraInstanceID) while SecureAuraHeader only sorts
--    INDEX/NAME/TIME (+separateOwn). Priority procs — a combat phenomenon —
--    reorder the display but not the header, so a right-click on slot N cancels
--    a DIFFERENT aura than the one shown there. Since the divergence cannot be
--    reconciled insecurely in combat (aura data is secret), the overlay is
--    hidden in combat via a secure visibility state driver: tooltips and
--    left-clicks work over every buff, and no wrong aura can be canceled.
--    Combat-end re-show triggers SecureAuraHeader_OnShow -> full secure update.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local source = readFile("QUI_ActionBars/actionbars/buffborders.lua")

-- Children must be born mouse-transparent: the restricted initialConfigFunction
-- snippet is the only code that runs at construction time (including mid-combat
-- construction), and EnableMouse is the one relevant method restricted handles
-- expose.
local configPos = source:find("initialConfig = string.format", 1, true)
assert(configPos, "ConfigureBuffCancelHeader must build the initialConfigFunction snippet")
local configBody = source:sub(configPos, configPos + 600)
assert(configBody:find("self:EnableMouse(false)", 1, true),
    "initialConfigFunction snippet must EnableMouse(false) so unstyled children never block tooltips/clicks")

-- The insecure styling pass must re-enable mouse when it applies the
-- pass-through setters (it only runs OOC, where all three calls are legal).
local stylePos = source:find("local function StyleBuffCancelChild", 1, true)
assert(stylePos, "StyleBuffCancelChild helper must exist")
local styleBody = source:sub(stylePos, stylePos + 900)
assert(styleBody:find("EnableMouse, child, true", 1, true),
    "StyleBuffCancelChild must re-enable mouse (children are born mouse-disabled)")
assert(styleBody:find("SetPropagateMouseMotion", 1, true),
    "StyleBuffCancelChild must still apply SetPropagateMouseMotion")

-- The overlay must be hidden in combat by a SECURE visibility driver (display
-- order and header order diverge in combat and cannot be reconciled insecurely;
-- a misaligned overlay right-click cancels the WRONG buff).
assert(source:find('RegisterStateDriver(header, "visibility"', 1, true),
    "cancel header must register a secure visibility state driver")
assert(source:find("[combat] hide", 1, true),
    "the visibility driver must hide the cancel overlay in combat")
assert(source:find('UnregisterStateDriver(header, "visibility")', 1, true),
    "disabling the overlay must unregister the visibility driver (a live driver would fight manual Hide)")

-- The disabled path (no buffs shown) must tear the driver down before hiding.
local disablePos = source:find("if not anyBuffs then", 1, true)
assert(disablePos, "ConfigureBuffCancelHeader must keep the anyBuffs-off path")
local disableBody = source:sub(disablePos, disablePos + 300)
assert(disableBody:find("CancelHeaderCombatDriver", 1, true),
    "the anyBuffs-off path must drop the visibility driver")

print("OK: buffborders_cancel_combat_visibility_test")
