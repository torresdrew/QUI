-- core/aura_preview.lua — QUI.AuraPreview: placeholder-icon preview for aura
-- elements. Live containers render engine-side with unknowable counts, so
-- preview draws the worst-case footprint using EXACTLY the layout math the live
-- path uses (AuraGlue.ElementProfile) — WYSIWYG by construction, no duplicated
-- layout constants. Plain insecure frames: safe anywhere, combat included.
--
-- Loadable headless: no top-level frame creation. Every CreateFrame happens
-- inside P.Show (and only when a real client is present), so this file loads
-- clean under the bare test ns before any WoW API stub exists.
local ADDON_NAME, ns = ...
local P = ns.AuraPreview or {}
ns.AuraPreview = P
_G.QUI = _G.QUI or {}
_G.QUI.AuraPreview = P

local PLACEHOLDER_ICON = 134400 -- INV_Misc_QuestionMark

-- Acquire (or reuse) the pooled placeholder frame at `index`. The visual (icon
-- vs colored rectangle) is (re)applied per-Show in LayoutElement, so a pool
-- frame can flip shape freely across re-renders.
local function AcquireIcon(host, pool, index)
    local f = pool[index]
    if not f then
        f = CreateFrame("Frame", nil, host)
        f._tex = f:CreateTexture(nil, "ARTWORK")
        f._tex:SetAllPoints(f)
        pool[index] = f
    end
    f:Show()
    return f
end

-- Default surface resolve: profile straight off the shared layout math, pinned
-- at the element's own anchor corner with the element's own offsets — the exact
-- pin the BB/GF live paths use (BB AnchorElementContainer pins
-- AuraSkin.LayoutAnchor(profile) to the mover at element.anchor; GF RenderIcon
-- pins the grow-derived icon corner to the frame at element.anchor).
-- Surfaces with their OWN anchoring fold (the unit-frame corner flip) pass
-- opts.resolve instead, reusing their live helpers so preview and live share
-- one source of truth: fn(element) -> profile, framePoint, offsetX, offsetY.
local function DefaultResolve(element)
    local G = ns.AuraGlue
    if not (G and G.ElementProfile) then return nil end
    return G.ElementProfile(element), element.anchor or "TOPLEFT",
        element.offsetX or 0, element.offsetY or 0
end

-- Lay one element's worst-case grid: placeholders positioned by the same
-- grow/wrap/perRow rules the live layouts apply, all derived from the resolved
-- PROFILE (never re-read off raw element geometry keys):
--   * flow-origin corner: exactly AuraSkin FlowFor's derivation (columns take
--     `up` from grow, rows take it from the profile's wrap — already the
--     FLIPPED wrap when a surface resolve folds a corner flip in), pinned to
--     the host at the resolved framePoint with the resolved offsets;
--   * CENTER grow: mirrors GF IconLayout.SingleRowOffset/CalculateSlotOffset —
--     each line centered on the anchor, a short final line centered on its own
--     occupancy;
--   * filterStrip -> maxIcons worst case; tracked -> min(#spells, maxIcons)
--     matching the live renderer's min(#ordered, maxIcons) cap;
--   * tracked bar -> bar.length x bar.thickness rectangle in element.color;
--     tracked square -> iconSize^2 swatch in element.color.
local function LayoutElement(host, pool, poolCursor, element, resolve)
    local p, framePoint, offX, offY = resolve(element)
    if not p then return poolCursor end

    local count
    if element.mode == "tracked" then
        local spells = element.spells
        local n = (type(spells) == "table") and #spells or 0
        local cap = element.maxIcons
        count = (cap and cap > 0 and cap < n) and cap or n
    else
        count = p.maxIcons
    end
    if count > 40 then count = 40 end
    if count < 1 then return poolCursor end

    -- Flow-origin corner (mirrors aura_skin.lua FlowFor exactly).
    local grow = p.grow
    local column = (grow == "UP" or grow == "DOWN")
    local left = (grow == "LEFT")
    local up
    if column then up = (grow == "UP") else up = (p.wrap == "UP") end
    local corner = (up and "BOTTOM" or "TOP") .. (left and "RIGHT" or "LEFT")

    -- Column growth degrades to one icon per line (engine parity: a row-major
    -- flow layout can't express a multi-column vertical grid); the line index
    -- then walks the vertical axis via `row` below.
    local perRow = (p.maxPerRow and p.maxPerRow > 0) and p.maxPerRow or count
    if column then perRow = 1 end
    local centered = (grow == "CENTER")

    local size, gap = p.iconSize, p.spacing
    local displayType = (element.mode == "tracked") and element.displayType or nil
    local isBar = (displayType == "bar")
    local isSwatch = isBar or (displayType == "square")
    local w = isBar and ((element.bar and element.bar.length) or 48) or size
    local h = isBar and ((element.bar and element.bar.thickness) or 12) or size
    local stepX = w + gap
    local stepY = h + gap
    local color = element.color

    for i = 1, count do
        poolCursor = poolCursor + 1
        local f = AcquireIcon(host, pool, poolCursor)
        f:SetSize(w, h)
        if isSwatch then
            f._tex:SetTexCoord(0, 1, 0, 1)
            f._tex:SetColorTexture((color and color[1]) or 1, (color and color[2]) or 1,
                (color and color[3]) or 1, (color and color[4]) or 1)
        else
            f._tex:SetTexture(PLACEHOLDER_ICON)
            f._tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        -- `row` is the wrap-line index, `col` the position within the line. For
        -- column growth perRow=1 makes `row` the along-column index (col=0), so
        -- dy walks the vertical axis — never swap them.
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        local dx
        if centered then
            -- GF IconLayout parity: center each line on its own occupancy (the
            -- final short line centers on its real count).
            local lineCount = perRow
            local remaining = count - row * perRow
            if remaining < perRow then lineCount = remaining end
            local lineSpan = lineCount * w + math.max(lineCount - 1, 0) * gap
            dx = col * stepX - lineSpan / 2
        else
            dx = (col * stepX) * (left and -1 or 1)
        end
        local dy = (row * stepY) * (up and 1 or -1)
        f:ClearAllPoints()
        f:SetPoint(corner, host, framePoint, offX + dx, offY + dy)
        f:SetAlpha(element.enabled ~= false and 1 or 0.35)
    end
    return poolCursor
end

-- Show placeholder previews for the given elements on hostFrame. Pool is reused
-- across calls (keyed on hostFrame._quiAuraPreview); surplus frames from a prior
-- larger render are hidden. healthTint tracked elements draw no placeholder
-- (they tint a health bar, not an icon slot) so they are skipped here.
-- opts.only (optional): filter fn(element) -> bool applied AFTER the mode gate.
-- opts.resolve (optional): fn(element) -> profile, framePoint, offsetX, offsetY
-- replacing DefaultResolve when the surface folds its own anchoring into the
-- profile/pin (the unit-frame corner flip).
function P.Show(hostFrame, elements, opts)
    local pool = hostFrame._quiAuraPreview
    if not pool then
        pool = {}
        hostFrame._quiAuraPreview = pool
    end
    local resolve = (opts and opts.resolve) or DefaultResolve
    local cursor = 0
    for i = 1, #elements do
        local e = elements[i]
        local render = (e.mode == "filterStrip")
            or (e.mode == "tracked" and e.displayType ~= "healthTint" and e.displayType ~= "border")
        if render and opts and opts.only then render = opts.only(e) end
        if render then
            cursor = LayoutElement(hostFrame, pool, cursor, e, resolve)
        end
    end
    for i = cursor + 1, #pool do pool[i]:Hide() end
end

function P.Hide(hostFrame)
    local pool = hostFrame._quiAuraPreview
    if not pool then return end
    for i = 1, #pool do pool[i]:Hide() end
end

return P
