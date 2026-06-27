-- tests/unit/buffborders_unified_stack_test.lua
-- Run: lua tests/unit/buffborders_unified_stack_test.lua
--
-- Locks in the 12.1 rollback to TWO CustomAuraContainers:
--   * separate named anchors QUI_BuffIconContainer and QUI_DebuffIconContainer;
--   * each anchor owns exactly one CustomAuraContainerTemplate child;
--   * buffs and debuffs use independent filters and maxFrameCount values;
--   * no roundUpFrameIndex/cumulative stacked-filter math remains;
--   * private-aura slots parent to the debuff anchor.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_ActionBars/actionbars/buffborders.lua")

-- Separate named anchors.
assert(src:find('CreateFrame("Frame", "QUI_BuffIconContainer", UIParent)', 1, true),
    "must create the named buff anchor QUI_BuffIconContainer")
assert(src:find('CreateFrame("Frame", "QUI_DebuffIconContainer", UIParent)', 1, true),
    "must create the named debuff anchor QUI_DebuffIconContainer")
assert(src:find("debuffContainer", 1, true),
    "the debuffContainer upvalue/uses must be restored")

-- Independent filters on independent containers.
assert(src:find("BuildAuraFilter(settings, true)", 1, true),
    "buff container must use the helpful filter")
assert(src:find("BuildAuraFilter(settings, false)", 1, true),
    "debuff container must use the harmful filter")
assert(not src:find("roundUpFrameIndex", 1, true),
    "two-container path must not use stacked-filter roundUpFrameIndex")
assert(not src:find("buffMax + debuffMax", 1, true),
    "two-container path must not use cumulative maxFrameCount math")

-- Private auras live with the debuff anchor.
assert(src:find('CreateFrame("Frame", "QUI_PlayerPrivateAura" .. i, debuffContainer)', 1, true),
    "private-aura slots must parent to debuffContainer")

print("buffborders_two_container_stack_test: OK")
