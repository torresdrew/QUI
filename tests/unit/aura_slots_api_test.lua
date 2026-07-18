-- tests/unit/aura_slots_api_test.lua
-- Source-text contract pins for core/aura_slots.lua (forbidden objects can't
-- run headless). Run: lua5.1 tests/unit/aura_slots_api_test.lua
local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a"); f:close()
    return (d:gsub("\r\n", "\n"))
end
local src = readAll("core/aura_slots.lua")
local fails = 0
local function check(name, ok)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name) end
end

check("exports S.Sync", src:find("function S.Sync", 1, true) ~= nil)
check("exports S.Park", src:find("function S.Park", 1, true) ~= nil)
check("slot creation via AddAuraSlot", src:find(":AddAuraSlot(", 1, true) ~= nil)
check("NO slot removal API (addon-unremovable; reconcile by rewrite)",
    src:find("UnregisterAuraSlot", 1, true) == nil and src:find("ClearAuraSlots", 1, true) == nil)
check("stale slots reconciled via SetAuraSlotFilterString",
    src:find(":SetAuraSlotFilterString(", 1, true) ~= nil)
check("candidate filters rewritten via SetAuraSlotCandidateFilters",
    src:find(":SetAuraSlotCandidateFilters(", 1, true) ~= nil)
check("park filter is the never-match maxDuration=0 recipe",
    src:find("maxDuration = 0", 1, true) ~= nil)
check("creation gated on InCombatLockdown (AddAuraSlot creates a forbidden frame synchronously)",
    src:find("InCombatLockdown()", 1, true) ~= nil)
check("slot frames wired through AuraSkin.WireButton",
    src:find("AuraSkin.WireButton(", 1, true) ~= nil)
check("onlyMine routed to isFromPlayerOrPlayerPet",
    src:find("isFromPlayerOrPlayerPet", 1, true) ~= nil)
check("per-spell include map drives the slot filter",
    src:find("includeSpellIDs", 1, true) ~= nil)
check("no Lua reads of aura data (secrets-safe by construction)",
    src:find("GetAuraDataBy", 1, true) == nil and src:find("GetUnitAuras", 1, true) == nil
    and src:find("UnitAura(", 1, true) == nil)
check("bar/linear fill rides the engine's SetDurationBar, never Lua duration math",
    src:find(":SetDurationBar(", 1, true) ~= nil and src:find("GetTime()", 1, true) == nil)
check("icon/square swipe styling routes through the shared helper",
    src:find("ApplyCooldownSwipeStyle", 1, true) ~= nil and src:find("swipeStyle", 1, true) ~= nil)
check("mid-combat linear-fill creation deferred (StatusBar child is OOC-only)",
    src:find("not fill and InCombatLockdown()", 1, true) ~= nil)
check("bar track dimmed behind the fill (depletion must read visually)",
    src:find("trackDim", 1, true) ~= nil)

if fails > 0 then error(fails .. " failure(s) in aura_slots_api_test") end
print("OK: aura_slots_api_test (all checks passed)")
