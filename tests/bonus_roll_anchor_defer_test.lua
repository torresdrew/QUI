-- tests/bonus_roll_anchor_defer_test.lua
-- Run: lua tests/bonus_roll_anchor_defer_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local source = readFile("modules/layout/layoutmode.lua")
local block = assert(
    source:match("%-%- BonusRollFrame: reapply.-%-%- Chat frame"),
    "BonusRollFrame anchoring hook block should exist")

assert(
    block:find("C_Timer.After%(0", 1, false) or block:find("RunNextFrame", 1, true),
    "BonusRollFrame anchoring must defer out of Blizzard Show/SetPoint setup")

assert(
    not block:find('hooksecurefunc%(bonusRollFrame, "SetPoint", ApplyBonusRollAnchor%)', 1, false),
    "BonusRollFrame SetPoint hook must schedule, not apply synchronously")

assert(
    not block:find('hooksecurefunc%(bonusRollFrame, "Show", ApplyBonusRollAnchor%)', 1, false),
    "BonusRollFrame Show hook must schedule, not apply synchronously")

assert(
    not block:find('HookScript%("OnShow", ApplyBonusRollAnchor%)', 1, false),
    "BonusRollFrame OnShow hook must schedule, not apply synchronously")

print("OK: bonus_roll_anchor_defer_test")
