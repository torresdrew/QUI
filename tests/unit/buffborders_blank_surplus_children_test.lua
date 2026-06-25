-- tests/unit/buffborders_blank_surplus_children_test.lua
-- Run: lua tests/unit/buffborders_blank_surplus_children_test.lua
--
-- Regression guard for stale icons/borders on empty buff/debuff/enchant slots.
--
-- Model history:
--   * SecureAuraHeader hid dead children in secure code; QUI blanked its parented
--     regions a frame later.
--   * The B2 insecure AuraButtonMixin pool made QUI Clear()+Hide() each pooled
--     button with no aura this pass.
--   * The E4 unification moved the player onto the SHARED secure
--     CustomAuraContainer. For LIVE buffs/debuffs, blanking surplus buttons is now
--     ENGINE-OWNED: CustomAuraContainerPrivateMixin:RefreshAuraFrames calls
--     auraFrame:ClearAuraInstance() on every pooled AuraSkin button past the live
--     count (see Blizzard_CustomAuraContainer.lua). QUI no longer pools or clears
--     the live aura buttons, so there is intentionally NO QUI Lua loop for them.
--
-- What survives as a QUI-owned guarantee: the SEPARATE insecure temp-enchant strip
-- (synthetic non-aura entries the container can't show) is QUI-pooled, so QUI must
-- Clear + Hide each strip button with no enchant this pass, or a stale enchant icon
-- sits on an empty slot. Guard that, plus that the live path delegates blanking to
-- the container rather than re-implementing a pool.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function sliceFunction(source, signature)
    local startPos = source:find(signature, 1, true)
    assert(startPos, signature .. " must exist in buffborders.lua")
    local nextFn = source:find("\nfunction ", startPos + 1, true)
    local nextLocal = source:find("\nlocal function ", startPos + 1, true)
    if nextLocal and (not nextFn or nextLocal < nextFn) then nextFn = nextLocal end
    return source:sub(startPos, nextFn or #source)
end

local source = readFile("QUI_ActionBars/actionbars/buffborders.lua")

-- No bespoke insecure aura-button pool for live buffs/debuffs (engine owns it now).
assert(not source:find("function AuraFrame:Update", 1, true),
    "buffborders.lua must NOT keep a bespoke AuraFrame:Update pool (the secure container blanks surplus buttons C-side)")
assert(not source:find("function AuraButton:Clear", 1, true),
    "buffborders.lua must NOT keep a bespoke AuraButton:Clear (engine ClearAuraInstance owns blanking)")

-- The SEPARATE temp-enchant strip is QUI-pooled, so it must Clear + Hide buttons
-- with no enchant this pass (and Show those that DO have one).
local updateBody = sliceFunction(source, "local function UpdateTempEnchants")
assert(updateBody:find("b:Show()", 1, true),
    "UpdateTempEnchants must Show strip buttons that have a live temp enchant")
assert(updateBody:find("b:Hide()", 1, true),
    "UpdateTempEnchants must Hide strip buttons with no temp enchant (no stale slot)")
assert(updateBody:find(".SetTexture, b.Icon, nil", 1, true) or updateBody:find("SetTexture(b.Icon, nil)", 1, true)
    or updateBody:find("b.Icon, nil", 1, true),
    "UpdateTempEnchants must clear the icon texture on empty strip buttons (no stale icon)")

print("OK: buffborders_blank_surplus_children_test")
