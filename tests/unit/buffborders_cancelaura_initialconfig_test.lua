-- tests/unit/buffborders_cancelaura_initialconfig_test.lua
-- Run: lua tests/unit/buffborders_cancelaura_initialconfig_test.lua
--
-- Regression guard for right-click-to-remove on buff/debuff/temp-enchant icons.
--
-- Model history:
--   * Old SecureAuraHeader model wired cancel via initialConfigFunction
--     (type=cancelaura) in the restricted environment.
--   * The B2 cutover used an insecure AuraButtonMixin whose OnClick called
--     CancelUnitBuff directly.
--   * The E4 unification moved the player onto the SHARED secure
--     CustomAuraContainer: own-buff right-click cancel is now NATIVE — the
--     CustomAuraButton intrinsic owns it C-side. QUI must NOT script the
--     forbidden buttons or call CancelUnitBuff (that would be taint / dead code).
--
-- What survives as a QUI-owned guarantee: the SEPARATE temp-enchant strip (temp
-- weapon enchants are not auras and the secure container cannot show them) keeps a
-- right-click cancel via CancelItemTempEnchantment, gated on InCombatLockdown
-- (cancel is protected in combat for everyone). Guard that:
--   * No Lua buff cancel remains (native intrinsic owns it).
--   * The temp-enchant button OnClick acts only on RightButton.
--   * It returns early under InCombatLockdown before CancelItemTempEnchantment.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local source = readFile("QUI_ActionBars/actionbars/buffborders.lua")

-- Own-buff cancel is native; no Lua cancel path may remain.
assert(not source:find("CancelUnitBuff", 1, true),
    "buffborders.lua must NOT call CancelUnitBuff: own-buff cancel is native (CustomAuraButton intrinsic)")
-- QUI must not SetScript an OnClick on a forbidden AuraButton (taint). AuraSkin
-- creates the AuraButtons; buffborders never does. Assert no AuraButton creation
-- here (the only buttons buffborders creates are the insecure temp-enchant ones).
assert(not source:find('CreateFrame("AuraButton"', 1, true),
    "buffborders.lua must NOT create forbidden AuraButtons (AuraSkin owns those)")

-- The temp-enchant cancel must exist and be combat-gated on RightButton.
-- Isolate the temp-enchant OnClick handler that performs the cancel (set via
-- SetScript("OnClick", ...) on the insecure strip button); the cancel call lives
-- AFTER that point, so anchor the search there to skip the comment/upvalue
-- mentions of CancelItemTempEnchantment earlier in the file.
local onClickStart = source:find('SetScript("OnClick"', 1, true)
assert(onClickStart, "buffborders.lua temp-enchant button must set an OnClick handler")
local cancelPos = source:find("CancelItemTempEnchantment", onClickStart, true)
assert(cancelPos, "buffborders.lua must keep temp-enchant cancel via CancelItemTempEnchantment")
local onClickBody = source:sub(onClickStart, cancelPos + 40)

assert(onClickBody:find("RightButton", 1, true),
    "temp-enchant OnClick must act only on RightButton")
local combatPos = onClickBody:find("InCombatLockdown", 1, true)
assert(combatPos, "temp-enchant OnClick must gate on InCombatLockdown (cancel is protected in combat)")
local localCancelPos = onClickBody:find("CancelItemTempEnchantment", 1, true)
assert(combatPos < localCancelPos,
    "temp-enchant OnClick must check InCombatLockdown BEFORE CancelItemTempEnchantment")

print("OK: buffborders_cancelaura_initialconfig_test")
