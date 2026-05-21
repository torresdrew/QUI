-- tests/unit/helpers_aura_ownership_test.lua
-- Run: lua tests/unit/helpers_aura_ownership_test.lua

function LibStub() return nil end

local units = {
    player = "Player-1",
    pet = "Pet-1",
    vehicle = "Vehicle-1",
    party1 = "Player-2",
}

function UnitIsUnit(left, right)
    return units[left] ~= nil and units[left] == units[right]
end

function UnitGUID(unit)
    return units[unit]
end

local ns = {}
assert(loadfile("core/utils.lua"))("QUI", ns)

local owns = assert(ns.Helpers.IsAuraOwnedByPlayerOrPet, "ownership helper should be exported")

assert(owns({
    isFromPlayerOrPlayerPet = true,
    sourceUnit = "party1",
}) == false, "player-controlled source is not proof of local ownership")

assert(owns({
    isFromPlayerOrPlayerPet = true,
    sourceUnit = "player",
}) == true, "player sourceUnit should prove ownership")

assert(owns({
    isFromPlayerOrPlayerPet = true,
    sourceGUID = "Pet-1",
}) == true, "pet sourceGUID should prove ownership")

assert(owns({
    isFromPlayerOrPlayerPet = false,
    sourceUnit = "player",
}) == false, "explicit non-player-controlled source should reject before source fallback")

assert(owns({
    isFromPlayerOrPlayerPet = true,
}) == false, "ownership should be unknown without local source proof")

print("OK: helpers_aura_ownership_test")
