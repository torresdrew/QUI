-- tests/unit/buffborders_no_secureauraheader_test.lua
-- Run: lua tests/unit/buffborders_no_secureauraheader_test.lua
--
-- buffborders.lua was unified onto the SHARED secure CustomAuraContainer model
-- (Task E4): the player buff/debuff display now flows through the SAME container +
-- QUI.AuraSkin path the unit/group frames use, replacing the bespoke insecure
-- pooled-button model. This source-text gate locks in the cutover:
--   * NO "SecureAuraHeader" reference may remain (the secure-header machinery was
--     deleted long ago and must never return).
--   * NO bespoke insecure QUI_AuraButtonTemplate / AuraButton pooling may remain
--     (the player uses CustomAuraContainerTemplate via AuraSkin now).
--   * Buff/debuff zones drive the container: CreateFrame("AuraContainer", ...),
--     AuraSkin.Attach, AddAuraFilter, SetUnit("player"), SetEnabled.
--   * Right-click cancel of own buffs is NATIVE (the CustomAuraButton intrinsic
--     owns it C-side): there must be NO QUI buff-cancel OnClick / CancelUnitBuff.
--   * Temp weapon enchants keep a SMALL SEPARATE insecure strip with right-click
--     CancelItemTempEnchantment (they are not auras; the container can't show them).
--   * The entry contract MUST still publish _G.QUI_RefreshBuffBorders.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_ActionBars/actionbars/buffborders.lua")

-- The secure-header machinery must stay gone.
assert(not src:find("SecureAuraHeader", 1, true),
    "buffborders.lua must not reference SecureAuraHeader")

-- The bespoke insecure pooled-button model must be gone (unified onto the shared
-- container path).
assert(not src:find("QUI_AuraButtonTemplate", 1, true),
    "buffborders.lua must NOT use the bespoke QUI_AuraButtonTemplate (player uses CustomAuraContainerTemplate via AuraSkin)")
assert(not src:find("CancelUnitBuff", 1, true),
    "buffborders.lua must NOT cancel buffs in Lua: own-buff right-click cancel is NATIVE (CustomAuraButton intrinsic, C-side)")

-- The player buff/debuff zones must drive the shared secure container.
assert(src:find('CreateFrame("AuraContainer", nil, anchorFrame, "CustomAuraContainerTemplate")', 1, true),
    "buffborders.lua must create the zone container via CreateFrame(\"AuraContainer\", ..., \"CustomAuraContainerTemplate\")")
assert(src:find("AuraSkin.Attach", 1, true),
    "buffborders.lua must theme/pool buttons via the shared QUI.AuraSkin.Attach")
assert(src:find("AddAuraFilter", 1, true),
    "buffborders.lua must register zone filters via container:AddAuraFilter")
assert(src:find('SetUnit("player")', 1, true),
    "buffborders.lua must point the container at the player via SetUnit(\"player\")")
assert(src:find("SetEnabled(true)", 1, true),
    "buffborders.lua must enable the container via SetEnabled(true)")
assert(src:find("BuildAuraFilter", 1, true),
    "buffborders.lua must honor the user filter flags via BuildAuraFilter")

-- The weapon-enchant strip is a small SEPARATE insecure display (synthetic non-
-- aura entries the secure container cannot show) and keeps its own cancel.
assert(src:find("CancelItemTempEnchantment", 1, true),
    "buffborders.lua must keep the separate temp-enchant strip with CancelItemTempEnchantment")
assert(src:find("GetWeaponEnchantInfo", 1, true),
    "buffborders.lua must read temp enchants via GetWeaponEnchantInfo (not auras)")
assert(src:find("InCombatLockdown", 1, true),
    "buffborders.lua must gate temp-enchant cancel on InCombatLockdown (cancel is protected in combat)")

-- The temp-enchant cancel OnClick must gate combat before the cancel call.
-- Anchor on the actual OnClick handler (not the comment/upvalue mentions of
-- CancelItemTempEnchantment earlier in the file).
local onClickStart = src:find('SetScript("OnClick"', 1, true)
assert(onClickStart, "temp-enchant button must set an OnClick handler")
local cancelInOnClick = src:find("CancelItemTempEnchantment", onClickStart, true)
assert(cancelInOnClick, "temp-enchant OnClick must call CancelItemTempEnchantment")
local guardWindow = src:sub(onClickStart, cancelInOnClick)
assert(guardWindow:find("InCombatLockdown", 1, true),
    "temp-enchant OnClick must check InCombatLockdown before CancelItemTempEnchantment")
assert(guardWindow:find("RightButton", 1, true),
    "temp-enchant OnClick must act only on RightButton")

-- The forbidden container buttons must never be scripted by QUI (the intrinsic
-- owns native cancel). AuraSkin owns the buttons; buffborders must not SetScript a
-- buff/debuff button cancel.
assert(not src:find("CancelUnitBuff", 1, true),
    "buffborders.lua must not implement any Lua buff-cancel path (native intrinsic)")

assert(src:find('_G.QUI_RefreshBuffBorders = ', 1, true),
    "buffborders.lua must still publish _G.QUI_RefreshBuffBorders (entry contract)")

print("buffborders_no_secureauraheader_test: OK")
