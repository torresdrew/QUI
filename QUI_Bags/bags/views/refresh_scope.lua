---------------------------------------------------------------------------
-- Bags views: refresh-scope classifier (PURE, headless-testable).
-- Decides how much of the bag window a BagsChanged event must repaint:
--   Classify(changed)  → "full" | "dress-all" | "dress-bags"
--   LayoutSignature(…) → string; two renders with equal signatures place
--   every button at identical coordinates, so a changed-bag repaint may
--   re-dress buttons in place without recomputing the layout.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local Bags = ns.Bags or {}; ns.Bags = Bags

local RefreshScope = {}
Bags.RefreshScope = RefreshScope

--- changed: the BagsChanged payload — nil (unknown scope: full render),
--- {} (synthetic re-dress ping: lock/cooldown/equipment-set visuals — the
--- summaries consumer skips these the same way), or an unordered array of
--- changed bag IDs.
function RefreshScope.Classify(changed)
    if type(changed) ~= "table" then return "full" end
    if #changed == 0 then return "dress-all" end
    return "dress-bags"
end

--- Merge a changed-bag array into a pending set ({ [bagID] = true });
--- pending nil seeds a fresh set. Coalesces bag IDs across the events one
--- scheduled repaint consumes.
function RefreshScope.UnionBags(pending, changed)
    pending = pending or {}
    for _, bagID in ipairs(changed) do pending[bagID] = true end
    return pending
end

--- Placement signature over exactly the inputs cell placement depends on.
--- slots: CollectSlots shape — ordered array of { bagID, slot, entry|nil }
--- (hidden bags already excluded). opts: { layoutMode, reagentDisplay,
--- groupEmptySlots, getRecent(cell) → bool }. buildDetails(entry) →
--- details|nil (Details.Build; injected — pure). Per mode:
---   categories: per occupied cell bucket-or-recent + the Group sort keys
---     (quality with Group's entry-fallback coalesce, name, itemID) —
---     equal ⇒ identical Group order ⇒ identical Compute placement.
---   flat + groupEmptySlots: occupancy pattern (the collapse points).
---   flat: purely positional — the bag/slot cell list alone.
--- Geometry (columns/iconSize/spacing) is excluded on purpose: it only
--- changes via settings paths that already run the full render.
function RefreshScope.LayoutSignature(slots, opts, buildDetails)
    local categories = opts.layoutMode == "categories"
    local parts = {
        categories and "cat"
            or ("flat:" .. tostring(opts.reagentDisplay or "separate")
                .. (opts.groupEmptySlots and ":g" or ":-")),
    }
    for _, cell in ipairs(slots) do
        if categories then
            if cell.entry then
                local details = buildDetails and buildDetails(cell.entry) or nil
                local recent = opts.getRecent and opts.getRecent(cell) or false
                parts[#parts + 1] = table.concat({
                    cell.bagID, cell.slot,
                    recent and "recent" or Bags.CategoryLayout.Categorize(details),
                    (details and details.quality) or cell.entry.quality or -1,
                    (details and details.name) or "",
                    cell.entry.itemID or 0,
                }, "\1")
            end
        elseif opts.groupEmptySlots then
            parts[#parts + 1] = cell.bagID .. "\1" .. cell.slot
                .. "\1" .. (cell.entry and 1 or 0)
        else
            parts[#parts + 1] = cell.bagID .. "\1" .. cell.slot
        end
    end
    return table.concat(parts, "\2")
end
