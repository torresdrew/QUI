local ADDON_NAME, ns = ...

local IconLayout = ns.QUI_GroupFrameIconLayout or {}
ns.QUI_GroupFrameIconLayout = IconLayout

-- Canonical dispel-type default color palette. Shared by groupframes.lua
-- (_dispel.defaultColors) and groupframes_auras.lua (AURA_DISPEL_COLORS) so a
-- palette change lands in exactly one place. NOTE: the settings UI keeps its
-- own 4-color seed (no Bleed) by design — do not point it here.
IconLayout.DISPEL_DEFAULT_COLORS = {
    Magic   = { 0.2, 0.6, 1.0, 1 },  -- Blue
    Curse   = { 0.6, 0.0, 1.0, 1 },  -- Purple
    Disease = { 0.6, 0.4, 0.0, 1 },  -- Brown
    Poison  = { 0.0, 0.6, 0.0, 1 },  -- Green
    Bleed   = { 0.8, 0.0, 0.0, 1 },  -- Red
}

-- Single-row offset for slot `index` (1-based) growing `direction` from the
-- anchor. CENTER centres the whole strip of `totalCount` icons on the anchor.
local function SingleRowOffset(index, iconSize, spacing, direction, totalCount)
    local step = ((index or 1) - 1) * ((iconSize or 0) + (spacing or 0))
    if direction == "LEFT" then
        return -step, 0
    elseif direction == "UP" then
        return 0, step
    elseif direction == "DOWN" then
        return 0, -step
    elseif direction == "CENTER" then
        local count = totalCount or 1
        local totalSpan = count * (iconSize or 0) + math.max(count - 1, 0) * (spacing or 0)
        return step - (totalSpan / 2), 0
    end
    return step, 0
end

-- `perRow` (optional, >0) wraps the strip into multiple rows/columns: every
-- `perRow` icons the strip steps once along the perpendicular axis (`rowDir`).
-- perRow nil/0 keeps the legacy single-line layout, so every existing caller
-- that omits the two new args is byte-for-byte unchanged.
-- rowDir is the wrap axis: for a horizontal grow (LEFT/RIGHT/CENTER) it is
-- "UP"/"DOWN" (default DOWN); for a vertical grow (UP/DOWN) it is "LEFT"/"RIGHT"
-- (default RIGHT). The caller derives it from the strip's frame anchor so rows
-- stack away from the frame edge rather than into it.
function IconLayout.CalculateSlotOffset(index, iconSize, spacing, direction, totalCount, perRow, rowDir)
    perRow = perRow or 0
    if perRow <= 0 then
        return SingleRowOffset(index, iconSize, spacing, direction, totalCount)
    end

    local zeroBased = (index or 1) - 1
    local major = zeroBased % perRow            -- position within the row/column
    local line = math.floor(zeroBased / perRow) -- which row/column
    local stepUnit = (iconSize or 0) + (spacing or 0)
    local wrap = line * stepUnit

    -- Centre each line on its own occupancy: full rows use perRow, the final
    -- short row uses its real count so it stays centred too.
    local lineCount = perRow
    if totalCount and totalCount > 0 then
        local remaining = totalCount - line * perRow
        if remaining < perRow then lineCount = remaining end
    end

    local x, y = SingleRowOffset(major + 1, iconSize, spacing, direction, lineCount)

    if direction == "UP" or direction == "DOWN" then
        if rowDir == "LEFT" then x = x - wrap else x = x + wrap end
    else
        if rowDir == "UP" then y = y + wrap else y = y - wrap end
    end
    return x, y
end

local function ComposeAnchor(horizontal, vertical)
    if vertical == "TOP" then
        if horizontal == "LEFT" then return "TOPLEFT" end
        if horizontal == "RIGHT" then return "TOPRIGHT" end
        return "TOP"
    elseif vertical == "BOTTOM" then
        if horizontal == "LEFT" then return "BOTTOMLEFT" end
        if horizontal == "RIGHT" then return "BOTTOMRIGHT" end
        return "BOTTOM"
    end

    if horizontal == "LEFT" then return "LEFT" end
    if horizontal == "RIGHT" then return "RIGHT" end
    return "CENTER"
end

function IconLayout.GetIconAnchorForGrow(frameAnchor, direction)
    local anchor = frameAnchor or "CENTER"
    local horizontal = anchor:find("LEFT") and "LEFT"
        or anchor:find("RIGHT") and "RIGHT"
        or "CENTER"
    local vertical = anchor:find("TOP") and "TOP"
        or anchor:find("BOTTOM") and "BOTTOM"
        or "CENTER"

    if direction == "LEFT" then
        horizontal = "RIGHT"
    elseif direction == "RIGHT" or direction == "CENTER" then
        horizontal = "LEFT"
    elseif direction == "UP" then
        vertical = "BOTTOM"
    elseif direction == "DOWN" then
        vertical = "TOP"
    end

    return ComposeAnchor(horizontal, vertical)
end

function IconLayout.CalculateStripSize(count, iconSize, spacing, direction)
    local size = iconSize or 0
    local gap = spacing or 0
    local visible = math.max(count or 0, 0)
    if visible <= 0 then
        return 0, 0
    end

    if direction == "UP" or direction == "DOWN" then
        return size, visible * size + math.max(visible - 1, 0) * gap
    end

    return visible * size + math.max(visible - 1, 0) * gap, size
end

