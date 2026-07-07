---------------------------------------------------------------------------
-- Bags views: currency bar. A footer-adjacent row on the BAG window showing
-- the user's settings-listed currencies as icon + amount segments. Config
-- is the shared currency-section model (currencyBar.currencyOrder array +
-- currencyBar.currencyEnabled map, STRING ids — the same shape the Info
-- Bar/datatext Currencies settings edit): render order ∩ enabled==true. A
-- pre-migration profile (settings page never opened) may still carry the
-- legacy currencyBar.currencies [id]=true set — rendered sorted until the
-- options page migrates it.
--
-- Data (verified, CurrencyInfoDocumentation.lua): C_CurrencyInfo.
-- GetCurrencyInfo(id) → CurrencyInfo { iconFileID (fileID), quantity
-- (number), ... }, MayReturnNothing — unknown IDs are skipped. Icon/identity
-- always come from the live struct; the AMOUNT is mode-aware: live mode uses
-- the struct's quantity, cached browsing uses the viewed character's
-- scanner-cached map (rec.currencies[id], scan_currencies.lua — zero
-- quantities are pruned there, so absent = 0).
--
-- Update cadence: the bag window's Refresh calls bar:Update() (which also
-- returns the extra content height for SetContentSize), and bag_window
-- subscribes CurrenciesChanged → ScheduleRefresh, so scanner drains land
-- here. Hidden (height 0) when disabled, list empty, or nothing renderable.
-- Clicks do nothing.
--
-- Hovering a segment shows a warband breakdown tooltip: account-wide
-- currencies (CurrencyInfo.isAccountWide) show the live quantity as the
-- warband total; per-character currencies list every scanned character's
-- amount (Storage rec.currencies, class-colored) plus the sum.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local Bags = ns.Bags or {}; ns.Bags = Bags
local Helpers = ns.Helpers
local GetSettings = Helpers.CreateDBGetter("bags")

local function CJKFont(fs, p, s, f)
    if ns.Helpers and ns.Helpers.ApplyFontWithFallback then
        ns.Helpers.ApplyFontWithFallback(fs, p, s, f)
    else
        fs:SetFont(p, s, f)
    end
end

local CurrencyBar = {}
Bags.CurrencyBar = CurrencyBar

local BAR_H = 18   -- extra content height while shown
local ICON = 14
local SEG_GAP = 12 -- gap between segments
local MAX_TOOLTIP_ROWS = 12

local function FormatQty(qty)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(qty) or tostring(qty)
end

--- BAG-02: warband/multi-character breakdown for the hovered currency.
local function ShowBreakdownTooltip(hit)
    local id = hit._currencyID
    if not id then return end
    local info = C_CurrencyInfo.GetCurrencyInfo(id) -- MayReturnNothing
    if not info then return end

    GameTooltip:SetOwner(hit, "ANCHOR_TOP")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(info.name or "", 1, 1, 1)

    if info.isAccountWide then
        -- Account-wide: the live quantity IS the warband total.
        GameTooltip:AddDoubleLine(ns.L["Warband (account-wide)"],
            FormatQty(info.quantity or 0), 0.8, 0.8, 0.8, 1, 1, 1)
    else
        local Store = Bags.Store
        if Store and Store.ListCharacters then
            local rows, total = {}, 0
            for _, key in ipairs(Store.ListCharacters()) do
                local rec = Store.GetCharacter(key)
                local qty = rec and rec.currencies and rec.currencies[id]
                if qty and qty > 0 then
                    local classToken = rec.details and rec.details.class
                    rows[#rows + 1] = {
                        name = key:match("^([^%-]+)") or key,
                        qty = qty,
                        color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] or nil,
                    }
                    total = total + qty
                end
            end
            table.sort(rows, function(a, b) return a.qty > b.qty end)
            GameTooltip:AddDoubleLine(ns.L["All Characters"], FormatQty(total),
                0.8, 0.8, 0.8, 1, 1, 1)
            for i = 1, math.min(#rows, MAX_TOOLTIP_ROWS) do
                local r = rows[i]
                local cr, cg, cb = 0.9, 0.9, 0.9
                if r.color then cr, cg, cb = r.color.r, r.color.g, r.color.b end
                GameTooltip:AddDoubleLine("  " .. r.name, FormatQty(r.qty),
                    cr, cg, cb, 1, 1, 1)
            end
            if #rows > MAX_TOOLTIP_ROWS then
                GameTooltip:AddLine("  …", 0.6, 0.6, 0.6)
            end
        end
    end
    GameTooltip:Show()
end

--- Re-render from settings + the viewed record. `live` mirrors the window's
--- mode (viewedCharacter == nil). Returns the content height the window must
--- reserve above the footer (0 when hidden).
local function Update(bar, record, live)
    local s = GetSettings()
    local cfg = s and s.currencyBar
    local ids = {}
    if cfg and cfg.enabled then
        if type(cfg.currencyOrder) == "table" then
            local en = cfg.currencyEnabled
            for _, sid in ipairs(cfg.currencyOrder) do
                if type(en) == "table" and en[sid] == true then
                    ids[#ids + 1] = tonumber(sid) or sid
                end
            end
        end
        if #ids == 0 and type(cfg.currencies) == "table" then
            -- legacy pre-migration set: everything listed, sorted
            for id in pairs(cfg.currencies) do ids[#ids + 1] = id end
            table.sort(ids)
        end
    end

    local shown = 0
    local x = 0
    for _, id in ipairs(ids) do
        local info = C_CurrencyInfo.GetCurrencyInfo(id) -- MayReturnNothing
        if info then
            local qty
            if live then
                qty = info.quantity or 0
            else
                qty = record and record.currencies and record.currencies[id] or 0
            end
            shown = shown + 1
            local seg = bar._segments[shown]
            if not seg then
                seg = { icon = bar:CreateTexture(nil, "ARTWORK") }
                seg.icon:SetSize(ICON, ICON)
                seg.amount = bar:CreateFontString(nil, "ARTWORK")
                CJKFont(seg.amount, Helpers.GetGeneralFont() or STANDARD_TEXT_FONT, 11, "OUTLINE")
                seg.amount:SetPoint("LEFT", seg.icon, "RIGHT", 3, 0)
                -- hover region for the warband breakdown tooltip
                seg.hit = CreateFrame("Frame", nil, bar)
                seg.hit:SetHeight(BAR_H)
                seg.hit:EnableMouse(true)
                seg.hit:SetScript("OnEnter", ShowBreakdownTooltip)
                seg.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
                bar._segments[shown] = seg
            end
            seg.icon:SetTexture(info.iconFileID)
            seg.amount:SetText(BreakUpLargeNumbers and BreakUpLargeNumbers(qty) or qty)
            seg.icon:ClearAllPoints()
            seg.icon:SetPoint("LEFT", bar, "LEFT", x, 0)
            seg.icon:Show()
            seg.amount:Show()
            local segWidth = ICON + 3 + math.ceil(seg.amount:GetStringWidth())
            seg.hit._currencyID = id
            seg.hit:ClearAllPoints()
            seg.hit:SetPoint("LEFT", bar, "LEFT", x, 0)
            seg.hit:SetWidth(segWidth)
            seg.hit:Show()
            x = x + segWidth + SEG_GAP
        end
    end
    for i = shown + 1, #bar._segments do
        bar._segments[i].icon:Hide()
        bar._segments[i].amount:Hide()
        if bar._segments[i].hit then
            bar._segments[i].hit._currencyID = nil
            bar._segments[i].hit:Hide()
        end
    end

    if shown == 0 then
        bar:Hide()
        return 0
    end
    bar:Show()
    return BAR_H
end

--- Build the bar on a chassis window (EnsureWindow-time, bag window only).
--- Anchors above the footer across the body's width; starts hidden.
function CurrencyBar.Attach(win)
    local bar = CreateFrame("Frame", nil, win)
    bar:SetPoint("BOTTOMLEFT", win._footer, "TOPLEFT", 8, 0)
    bar:SetPoint("BOTTOMRIGHT", win._footer, "TOPRIGHT", -8, 0)
    bar:SetHeight(BAR_H)
    bar:Hide()
    bar._segments = {} -- pooled { icon = Texture, amount = FontString }
    bar.Update = Update
    win._currencyBar = bar
    return bar
end
