-- tests/unit/auctionhouse_filter_clearx_strata_test.lua
-- Run: lua tests/unit/auctionhouse_filter_clearx_strata_test.lua
--
-- Regression guard: the Auction House filter dropdown's clear-filters "X"
-- (FilterButton.ClearFiltersButton, atlas auctionhouse-ui-filter-redx; see
-- Blizzard_AuctionHouseSearchBar.xml:19-37) must render on top of the QUI
-- backdrop. The backdrop SkinButton adds is a child of FilterButton at its frame
-- level and otherwise draws over the X. Raising the X does NOT hold (the
-- dropdown/menu machinery re-levels child buttons on interaction), so the skin
-- must instead LOWER its own backdrop below the dropdown's children -- the
-- proven professions.lua belowChildren technique.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function assertContains(text, needle, reason)
    assert(text:find(needle, 1, true), reason)
end

local source = readFile("QUI_Skinning/skinning/frames/auctionhouse.lua")

-- The belowChildren opt lowers SkinButton's own backdrop to max(0, button level - 1) --
-- the same SetFrameLevel the old manual GetBackdrop/SetFrameLevel block did -- so the
-- clear-filters "X" (a child of FilterButton) stays on top of the QUI backdrop.
assertContains(
    source,
    "SkinBase.SkinButton(searchBar.FilterButton, { strip = true, font = true, belowChildren = true })",
    "AH filter backdrop must be lowered below the dropdown's children (belowChildren) so the clear-X stays on top")

print("OK: auctionhouse_filter_clearx_strata_test")
