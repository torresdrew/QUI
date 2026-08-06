--[[
    QUI Options - Reorderable List

    Compact editable list: one 26px row per entry, hover highlight, drag to
    reorder with a live drop indicator, arrow buttons as the drag-free
    alternative, optional remove button, and an optional per-row disclosure
    that folds the entry's own settings into the row instead of stacking a
    full card per entry down the page.

    Extracted from the info-bar zone editor's row list
    (modules/infobar/settings/infobar_content.lua), which is the visual
    reference. Two behavioural differences, both deliberate:

      * Row heights are MEASURED, not assumed. The info-bar version derives
        the drop gap from a fixed row height, which is only correct because
        none of its rows can expand. An expanded row here is taller than 26px,
        so the drop gap is resolved against real row extents.
      * Disclosure state is owned by the CALLER (spec.expanded) and keyed by
        spec.identify, so it survives the structural rebuild that every
        add/remove/reorder triggers.
      * An enable/disable toggle sits ON the collapsed row -- the standard V3
        pill (GUI:CreateFormToggle in bare mode), bound via
        spec.getToggleBinding -- and the whole row is the disclosure hit area,
        so the chevron is an affordance rather than the only way in. A row whose
        only setting was that toggle therefore needs no disclosure at all,
        which is what spec.hasDetail gates.

    Usage:
        local frame, height = ns.QUI_ReorderList.Build(parent, yOffset, spec)
]]

local ADDON_NAME, ns = ...

local ReorderList = {}
ns.QUI_ReorderList = ReorderList

local ROW_HEIGHT   = 26
local ROW_INSET    = 4      -- visual gap between a row and the next
local LIST_TOP     = 24     -- space reserved for the hint line
local DETAIL_INSET = 16     -- left indent for an expanded detail panel
local PILL_WIDTH   = 26     -- in-row enable/disable pill toggle (V3 standard)
local PILL_GAP     = 8      -- pill to label

local function GetAccent()
    if ns.UIKit and ns.UIKit.GetAccentColor then
        local r, g, b = ns.UIKit.GetAccentColor()
        if r then return r, g, b end
    end
    return 0.19, 0.51, 0.98
end

--- Build a reorderable list into `parent` at vertical offset `y`.
---
--- @param parent Frame   Container to build into.
--- @param y      number  Negative offset from the parent's TOPLEFT.
--- @param spec   table
---   .items       table     REQUIRED. The live array being reordered, mutated in place.
---   .getLabel    function  REQUIRED. (item, index) -> text[, dimmed]
---   .identify    function  REQUIRED. (item) -> stable key. Used to re-derive a
---                          row's CURRENT index at click time (build-time
---                          indices go stale under debounced rebuilds) and to
---                          key disclosure state.
---   .onChange    function  REQUIRED. Called after the array is mutated.
---   .onRemove    function|nil  (item, index) -> nil. Omit for no remove button.
---   .canRemove   function|nil  (item) -> bool. Per-row gate on the remove
---                          button, for lists that mix permanent and
---                          user-added entries. Default: all removable.
---   .buildDetail function|nil  (container, item, index) -> height. Omit for no
---                          disclosure. Called only while the row is expanded.
---   .hasDetail   function|nil  (item, index) -> bool. Per-row gate on the
---                          disclosure, for lists where some rows have nothing
---                          left to show once their toggle is on the row. A row
---                          that fails it gets no chevron and does not expand on
---                          click. Default: every row expands.
---   .expanded    table|nil Caller-owned map of identify() -> true.
---   .GUI         table|nil The QUI GUI framework object, needed for the
---                          in-row pill toggle (same convention as
---                          QUI_BorderControl.Attach). Required by
---                          .getToggleBinding.
---   .getToggleBinding function|nil (item, index) -> dbTable, dbKey[, description]
---                          The row's own stored table and the boolean key the
---                          in-row pill toggle binds to. Return nil for a row
---                          with no toggle. The framework widget owns the DB
---                          write, so there is nothing to persist here.
---   .onToggle    function|nil  (item, index) -> nil. Post-flip hook, for the
---                          caller's live refresh. The row's label is re-derived
---                          afterwards, so a getLabel that dims on the bound
---                          flag updates without a rebuild.
---   .getTooltip  function|nil (item, index) -> title, body
---   .onControl   function|nil Called with every button this widget creates, so
---                          the caller can gate them behind a master toggle.
---   .hintText    string|nil Shown above a non-empty list.
---   .emptyText   string|nil Shown instead when the list is empty.
--- @return Frame listFrame, number height  The list frame and the height it consumed.
function ReorderList.Build(parent, y, spec)
    local items = spec.items
    local accR, accG, accB = GetAccent()

    local listFrame = CreateFrame("Frame", nil, parent)
    listFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    listFrame:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local hintFs = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintFs:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 4, -4)
    hintFs:SetPoint("RIGHT", listFrame, "RIGHT", -4, 0)
    hintFs:SetJustifyH("LEFT")
    hintFs:SetTextColor(0.6, 0.6, 0.6, 0.8)
    hintFs:SetText(#items > 0 and (spec.hintText or "") or (spec.emptyText or ""))

    -- Row extents, filled as rows are laid out: extents[i] = { top, bottom }
    -- measured as positive distances below the list frame's top edge. The drop
    -- gap is resolved against these rather than a fixed stride, so an expanded
    -- (taller) row still maps to the right insertion point.
    local extents = {}
    local dropLine = listFrame:CreateTexture(nil, "OVERLAY")
    dropLine:SetHeight(2)
    dropLine:SetColorTexture(accR, accG, accB, 0.9)
    if ns.UIKit and ns.UIKit.DisablePixelSnap then
        ns.UIKit.DisablePixelSnap(dropLine)
    end
    dropLine:Hide()

    -- Gap index 1..#items+1; gap g sits immediately above row g.
    local function DropGapFromCursor()
        local top = listFrame:GetTop()
        if not top or #extents == 0 then return 1 end
        local _, cursorY = GetCursorPosition()
        cursorY = cursorY / listFrame:GetEffectiveScale()
        local offset = top - cursorY
        for i = 1, #extents do
            local e = extents[i]
            if offset < (e.top + e.bottom) * 0.5 then return i end
        end
        return #extents + 1
    end

    local function GapOffset(gap)
        if #extents == 0 then return LIST_TOP end
        if gap > #extents then return extents[#extents].bottom end
        return extents[gap].top
    end

    local ry = LIST_TOP
    for idx = 1, #items do
        local item = items[idx]
        local capturedKey = spec.identify(item)
        local rowTop = ry

        local r = CreateFrame("Frame", nil, listFrame)
        r:SetHeight(ROW_HEIGHT - ROW_INSET)
        r:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, -ry)
        r:SetPoint("RIGHT", listFrame, "RIGHT", 0, 0)

        local hoverBg = r:CreateTexture(nil, "BACKGROUND")
        hoverBg:SetAllPoints()
        hoverBg:SetColorTexture(accR, accG, accB, 0.08)
        hoverBg:Hide()

        -- Re-derive the live index at click time; build-time indices go stale
        -- because every mutation triggers a debounced structural rebuild.
        local function findCurrentIndex()
            for i = 1, #items do
                if spec.identify(items[i]) == capturedKey then return i end
            end
            return nil
        end

        local function makeRowButton(text, xOff, tip)
            local btn = CreateFrame("Button", nil, r)
            btn:SetSize(16, 16)
            btn:SetPoint("RIGHT", r, "RIGHT", xOff, 0)
            btn:SetNormalFontObject("GameFontNormalSmall")
            btn:SetText(text)
            btn:GetFontString():SetTextColor(accR, accG, accB, 1)
            btn:SetScript("OnEnter", function(self)
                hoverBg:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tip, 1, 1, 1)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
                if not r:IsMouseOver() then hoverBg:Hide() end
            end)
            if spec.onControl then spec.onControl(btn) end
            return btn
        end

        -- Disclosure is gated per ROW, not per list: with the enable/disable
        -- toggle now on the row itself, a row can be left with nothing to
        -- disclose while its neighbours still have editors.
        local canExpand = spec.buildDetail ~= nil
        if canExpand and spec.hasDetail then
            canExpand = spec.hasDetail(item, idx) and true or false
        end
        local isExpanded = canExpand and spec.expanded and spec.expanded[capturedKey] or false

        local function ToggleExpanded()
            if not (canExpand and spec.expanded) then return end
            spec.expanded[capturedKey] = (not isExpanded) or nil
            spec.onChange()
        end

        -- The chevron gutter is reserved whenever the LIST has disclosure, not
        -- whenever THIS row does, so labels stay aligned in a list that mixes
        -- expandable and flat rows.
        local labelLeft = 4
        if spec.buildDetail ~= nil then
            labelLeft = 20
            if canExpand then
                local chevron = CreateFrame("Button", nil, r)
                chevron:SetSize(14, 14)
                chevron:SetPoint("LEFT", r, "LEFT", 3, 0)
                chevron:SetNormalFontObject("GameFontNormalSmall")
                chevron:SetText(isExpanded and "v" or ">")
                chevron:GetFontString():SetTextColor(accR, accG, accB, 1)
                chevron:SetScript("OnClick", ToggleExpanded)
                chevron:SetScript("OnEnter", function() hoverBg:Show() end)
                chevron:SetScript("OnLeave", function()
                    if not r:IsMouseOver() then hoverBg:Hide() end
                end)
                if spec.onControl then spec.onControl(chevron) end
            end
        end

        local nameFs
        local function RefreshLabel()
            local text, dimmed = spec.getLabel(item, idx)
            nameFs:SetText(text)
            if dimmed then
                nameFs:SetTextColor(0.6, 0.6, 0.6, 1)
            else
                nameFs:SetTextColor(0.9, 0.9, 0.9, 1)
            end
        end

        -- Enable/disable rides ON the collapsed row, drawn as the SAME 26x14
        -- pill every other QUI setting uses (GUI:CreateFormToggle in bare
        -- mode -- label nil) rather than a bespoke in-row control. It binds
        -- straight to the row's own stored table, so the DB write, cross-widget
        -- sync and the standard tooltip all come from the framework.
        --
        -- The gutter is reserved for every row of a toggling list, so a row
        -- that opts out (no binding) still lines its label up with its
        -- neighbours.
        if spec.getToggleBinding then
            local bindTable, bindKey, bindDescription
            if spec.GUI then
                bindTable, bindKey, bindDescription = spec.getToggleBinding(item, idx)
            end
            if bindTable and bindKey then
                local pill = spec.GUI:CreateFormToggle(r, nil, bindKey, bindTable, function()
                    if spec.onToggle then
                        local curIdx = findCurrentIndex()
                        spec.onToggle(item, curIdx or idx)
                    end
                    RefreshLabel()
                end, bindDescription and { description = bindDescription } or nil)
                pill:ClearAllPoints()
                pill:SetPoint("LEFT", r, "LEFT", labelLeft, 0)
                -- No hover wiring needed: the pill sits inside the row's rect,
                -- so the row's own OnLeave guard (IsMouseOver) keeps hoverBg up
                -- while the cursor is on it.
                if spec.onControl then spec.onControl(pill) end
            end
            labelLeft = labelLeft + PILL_WIDTH + PILL_GAP
        end

        nameFs = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFs:SetPoint("LEFT", r, "LEFT", labelLeft, 0)
        nameFs:SetPoint("RIGHT", r, "RIGHT", -70, 0)
        nameFs:SetJustifyH("LEFT")
        RefreshLabel()

        -- Drag to reorder. Arrows stay as the drag-free alternative.
        -- A plain left click anywhere on the row is the disclosure hit area;
        -- the chevron is an affordance, not the only way in. `dragged` is the
        -- discriminator: a drag fires OnDragStart, then OnDragStop, then
        -- OnMouseUp, so the click handler has to swallow that trailing release
        -- or every reorder would also toggle the row. The child buttons
        -- (toggle, arrows, remove) consume their own clicks, so they never
        -- reach here.
        local dragged = false
        r:EnableMouse(true)
        r:RegisterForDrag("LeftButton")
        r:SetScript("OnMouseDown", function(_, button)
            if button == "LeftButton" then dragged = false end
        end)
        r:SetScript("OnMouseUp", function(_, button)
            if button ~= "LeftButton" then return end
            if dragged then
                dragged = false
                return
            end
            ToggleExpanded()
        end)
        r:SetScript("OnEnter", function(self)
            hoverBg:Show()
            if spec.getTooltip then
                local title, body = spec.getTooltip(item, idx)
                if title then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(title, accR, accG, accB)
                    if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
                    GameTooltip:Show()
                end
            end
        end)
        r:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            if not self:IsMouseOver() then hoverBg:Hide() end
        end)
        r:SetScript("OnDragStart", function(self)
            GameTooltip:Hide()
            dragged = true
            self:SetAlpha(0.4)
            dropLine:Show()
            self:SetScript("OnUpdate", function()
                dropLine:ClearAllPoints()
                dropLine:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, -GapOffset(DropGapFromCursor()) + 1)
                dropLine:SetPoint("RIGHT", listFrame, "RIGHT", -4, 0)
            end)
        end)
        r:SetScript("OnDragStop", function(self)
            self:SetScript("OnUpdate", nil)
            self:SetAlpha(1)
            dropLine:Hide()
            local gap = DropGapFromCursor()
            local curIdx = findCurrentIndex()
            if not curIdx then return end
            -- Removing the row first shifts every later gap down by one.
            local target = (gap > curIdx) and (gap - 1) or gap
            if target ~= curIdx then
                table.remove(items, curIdx)
                table.insert(items, target, item)
                spec.onChange()
            end
        end)

        -- Removability is per ROW, not per list: a list can mix permanent
        -- entries with user-added ones. A row that cannot be removed gets no
        -- x button at all rather than a dead one, and its arrows slide right
        -- into the freed slot.
        local removable = spec.onRemove ~= nil
            and (spec.canRemove == nil or spec.canRemove(item))
        local removeOffset = -4
        if removable then
            local removeBtn = makeRowButton("x", -4, spec.removeTooltip or "")
            removeBtn:SetScript("OnClick", function()
                local curIdx = findCurrentIndex()
                if curIdx then spec.onRemove(items[curIdx], curIdx) end
            end)
        else
            removeOffset = 16
        end

        local upBtn = makeRowButton("^", removeOffset - 40, spec.moveUpTooltip or "")
        upBtn:SetScript("OnClick", function()
            local curIdx = findCurrentIndex()
            if curIdx and curIdx > 1 then
                table.remove(items, curIdx)
                table.insert(items, curIdx - 1, item)
                spec.onChange()
            end
        end)
        upBtn:SetAlpha(idx > 1 and 1 or 0.3)

        local downBtn = makeRowButton("v", removeOffset - 20, spec.moveDownTooltip or "")
        downBtn:SetScript("OnClick", function()
            local curIdx = findCurrentIndex()
            if curIdx and curIdx < #items then
                table.remove(items, curIdx)
                table.insert(items, curIdx + 1, item)
                spec.onChange()
            end
        end)
        downBtn:SetAlpha(idx < #items and 1 or 0.3)

        ry = ry + ROW_HEIGHT

        if isExpanded then
            local detail = CreateFrame("Frame", nil, listFrame)
            detail:SetPoint("TOPLEFT", listFrame, "TOPLEFT", DETAIL_INSET, -ry)
            detail:SetPoint("RIGHT", listFrame, "RIGHT", -4, 0)
            local detailHeight = spec.buildDetail(detail, item, idx) or 0
            detail:SetHeight(math.max(detailHeight, 1))
            ry = ry + detailHeight + ROW_INSET
        end

        extents[idx] = { top = rowTop, bottom = ry }
    end

    local height = math.max(ry, LIST_TOP)
    listFrame:SetHeight(height)
    return listFrame, height
end
