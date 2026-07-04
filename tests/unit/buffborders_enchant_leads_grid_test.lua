-- tests/unit/buffborders_enchant_leads_grid_test.lua
-- Run: lua tests/unit/buffborders_enchant_leads_grid_test.lua
--
-- The temp-enchant strip LEADS the buff row (default-UI parity): enchants
-- render at the grid origin corner and the secure aura container is anchored
-- liveEnchantCount cells further along the grow direction. Rationale: the
-- enchant count is Lua-visible (GetWeaponEnchantInfo — item info, not aura
-- data) while the live aura count is secret, so dynamic packing can only start
-- from the enchant side. The cancel header must shift by the SAME offset or
-- its uniform secure grid misaligns with the display buttons and right-click
-- cancels the wrong aura. The whole container shifts (rows 2+ indent too):
-- a ragged first-row indent cannot be mirrored by the secure header.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_ActionBars/actionbars/buffborders.lua")

local function slice(marker)
    local startPos = src:find(marker, 1, true)
    assert(startPos, "missing: " .. marker)
    local endPos = src:find("\nend", startPos, true)
    assert(endPos, "unterminated function at: " .. marker)
    return src:sub(startPos, endPos)
end

-- The live enchant count must be a tracked upvalue.
assert(src:find("local liveEnchantCount = 0", 1, true),
    "must track liveEnchantCount as a file-local")

-- The strip anchors AT the buff grid origin corner (leads the row), not below
-- the max grid extent.
local strip = slice("local function UpdateTempEnchants()")
assert(strip:find("tempEnchantFrame:SetPoint(point, buffContainer, point, 0, 0)", 1, true),
    "the strip must pin its grow corner to the buff anchor's SAME corner at (0,0) — it leads the row")
assert(strip:find("liveEnchantCount = ", 1, true),
    "UpdateTempEnchants must maintain liveEnchantCount")
-- Existing pins that must survive the rewrite:
assert(strip:find(":Show()", 1, true) and strip:find(":Hide()", 1, true),
    "UpdateTempEnchants must still Show/Hide strip buttons per live enchant")

-- The container anchor must offset by the enchant extent along the grow
-- direction for the buff zone.
local anchor = slice("local function AnchorAuraContainer(")
assert(anchor:find("liveEnchantCount", 1, true),
    "AnchorAuraContainer must offset the buff zone by the live enchant extent")

-- The cancel header must apply the SAME offset (alignment with the display
-- grid is what makes right-click cancel hit the right aura).
local header = slice("local function ConfigureBuffCancelHeader(")
assert(header:find("liveEnchantCount", 1, true),
    "ConfigureBuffCancelHeader must shift the header by the same enchant offset")

-- Enchant events must re-run the config pass when the count changes (the grid
-- origin moved); in combat that resolves to the mutable pass + queued full pass.
local refresh = slice("local function RefreshTempEnchants()")
assert(refresh:find("UpdateTempEnchants()", 1, true),
    "RefreshTempEnchants must refresh the strip")
assert(refresh:find("ApplyOrDefer()", 1, true),
    "RefreshTempEnchants must re-run the config pass when the enchant count changed")
assert(src:find("RefreshTempEnchants()", src:find("WEAPON_ENCHANT_CHANGED", 1, true), true),
    "the WEAPON_ENCHANT_CHANGED handler must route through RefreshTempEnchants")

-- The buff zone's natural width must include the enchant lead-in (mover /
-- anchoring extent must cover the shifted grid).
local pass = slice("local function ApplyConfigPass(allowCreate)")
assert(pass:find("liveEnchantCount", 1, true),
    "ApplyConfigPass must widen the buff zone's natural extent by the enchant lead-in")

print("OK: buffborders_enchant_leads_grid_test")
