local addonName, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- MERCHANT GRID EXTENDER
--
-- Grows the vendor "Items" tab into a configurable Columns x Rows grid by
-- raising MERCHANT_ITEMS_PER_PAGE (so Blizzard's own fill loop populates the
-- extra buttons) and re-asserting layout after Blizzard's per-update
-- re-anchor. The Buyback tab is left on the vanilla path.
--
-- Geometry verified vs 12.0.7 FrameXML MerchantFrame.xml:
--   MerchantItem1 TOPLEFT (11, -69) from MerchantFrame
--   col stride 165 (153 cell + 12 gap); row stride 52 (44 cell + 8 gap)
--   base frame 336 x 444; MerchantItem1..12 exist in XML (11/12 buyback-only)
--   MerchantNextPageButton anchors x=310 from BOTTOMLEFT -> reposition to W-26
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("merchantGrid")

local BASE_W, BASE_H         = 336, 444
local ORIGIN_X, ORIGIN_Y     = 11, -69
local COL_STRIDE, ROW_STRIDE = 165, 52
local VANILLA_PER_PAGE       = 10
local XML_BUTTONS            = 12
local MIN_COLS, MAX_COLS     = 2, 4
local MIN_ROWS, MAX_ROWS     = 5, 8
local MAX_BUTTONS            = MAX_COLS * MAX_ROWS   -- 32
local NEXT_PAGE_INSET        = 26                    -- next-page x = W - 26 (336-26=310 == vanilla)
local BUYBACK_ANCHOR_X       = 30                    -- MerchantBuyBackItem XML offset from its ref slot
local BUYBACK_ANCHOR_Y       = -53                   -- (BOTTOMLEFT 30,-53) — mirrors MerchantFrame.xml

-- Vanilla relative anchors for the slots Blizzard's Lua never re-anchors itself
-- (even columns + buyback 11/12). MerchantItem1 and odd slots 3/5/7/9 ARE
-- re-anchored by Blizzard every UpdateMerchantInfo/BuybackInfo (and item1 grid
-- coords equal vanilla), so RestoreVanilla only needs to reset these.
local VANILLA_RELANCHORS = {
    { 2,  "MerchantItem1",  "TOPRIGHT",   12,   0 },
    { 4,  "MerchantItem3",  "TOPRIGHT",   12,   0 },
    { 6,  "MerchantItem5",  "TOPRIGHT",   12,   0 },
    { 8,  "MerchantItem7",  "TOPRIGHT",   12,   0 },
    { 10, "MerchantItem9",  "TOPRIGHT",   12,   0 },
    { 11, "MerchantItem9",  "BOTTOMLEFT",  0, -15 },
    { 12, "MerchantItem11", "TOPRIGHT",   12,   0 },
}

local MerchantGrid = {}
if _G.QUI then _G.QUI.MerchantGrid = MerchantGrid end

local buttonsBuilt        = false
local hookInstalled       = false
local pendingPanelUpdate  = false

local function ClampedConfig()
    local s = GetSettings()
    local enabled = (s and s.enabled == true) or false
    local cols = (s and s.columns) or MIN_COLS
    local rows = (s and s.rows) or MIN_ROWS
    if cols < MIN_COLS then cols = MIN_COLS elseif cols > MAX_COLS then cols = MAX_COLS end
    if rows < MIN_ROWS then rows = MIN_ROWS elseif rows > MAX_ROWS then rows = MAX_ROWS end
    return enabled, cols, rows
end

-- Lazily create MerchantItem13..32 from the virtual template. Buy/cost/
-- tooltip scripts wire up automatically; they need no separate skinning
-- (identical template to 1..12; QUI skins only window chrome + page arrows).
local function EnsureButtons()
    if buttonsBuilt then return end
    local frame = _G.MerchantFrame
    if not frame then return end
    for i = XML_BUTTONS + 1, MAX_BUTTONS do
        if not _G["MerchantItem" .. i] then
            CreateFrame("Frame", "MerchantItem" .. i, frame, "MerchantItemTemplate")
        end
    end
    buttonsBuilt = true
end

local function SafePanelUpdate()
    local frame = _G.MerchantFrame
    if not frame then return end
    if InCombatLockdown() then
        pendingPanelUpdate = true   -- re-flow after combat (PLAYER_REGEN_ENABLED)
        return
    end
    if _G.UpdateUIPanelPositions then
        _G.UpdateUIPanelPositions(frame)
    end
end

-- MerchantBuyBackItem (the "last sold" quick-slot shown on the Items tab) is
-- XML-anchored to MerchantItem10's BOTTOMLEFT and Blizzard NEVER re-anchors it
-- in Lua. At 2 cols item10 is the bottom-right slot, so the buyback slot rests
-- below the grid. At >2 cols (or >5 rows) item10 lands in the grid INTERIOR and
-- drags the buyback slot on top of the item buttons. Re-pin it to the slot that
-- inherits item10's ROLE in the grid: last row, 2nd column -> (rows-1)*cols + 2.
-- That index is always in column 1 (x == vanilla 206), tracks the bottom row,
-- and equals 10 at 2x5 (so ApplyGrid stays pixel-vanilla at the default size).
-- <<< QUI_TEST_EXTRACT buyback_anchor
local function BuybackRefIndex(cols, rows)
    return (rows - 1) * cols + 2
end

-- Runs AFTER Blizzard's UpdateMerchantInfo: override its 2-col re-anchor and
-- its MerchantItem11/12:Hide(); place 1..N into the grid, hide N+1..MAX,
-- resize the frame, and re-pin the next-page button.
local function ApplyGrid(cols, rows)
    local frame = _G.MerchantFrame
    local n = cols * rows
    for i = 1, MAX_BUTTONS do
        local b = _G["MerchantItem" .. i]
        if b then
            if i <= n then
                local col = (i - 1) % cols
                local rowIdx = math.floor((i - 1) / cols)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", frame, "TOPLEFT",
                    ORIGIN_X + col * COL_STRIDE, ORIGIN_Y - rowIdx * ROW_STRIDE)
                b:Show()
            else
                b:Hide()
            end
        end
    end

    local w = BASE_W + (cols - MIN_COLS) * COL_STRIDE
    local h = BASE_H + (rows - MIN_ROWS) * ROW_STRIDE
    frame:SetSize(w, h)

    local nextBtn = _G.MerchantNextPageButton
    if nextBtn then
        nextBtn:ClearAllPoints()
        nextBtn:SetPoint("CENTER", frame, "BOTTOMLEFT", w - NEXT_PAGE_INSET, 96)
    end

    -- Re-pin the buyback quick-slot below the grid (see BuybackRefIndex note).
    local buyback = _G.MerchantBuyBackItem
    local ref = _G["MerchantItem" .. BuybackRefIndex(cols, rows)]
    if buyback and ref then
        buyback:ClearAllPoints()
        buyback:SetPoint("TOPLEFT", ref, "BOTTOMLEFT", BUYBACK_ANCHOR_X, BUYBACK_ANCHOR_Y)
    end

    SafePanelUpdate()
end

-- Buyback tab or feature disabled: vanilla dimensions, extra buttons hidden,
-- and the even/buyback slots' XML relative anchors re-established (ApplyGrid
-- re-pointed them to absolute grid coords; Blizzard never resets these, so
-- without this they stay scattered at columns != 2 until /reload). Slots
-- 1/3/5/7/9 self-heal: Blizzard re-anchors them each update.
local function RestoreVanilla()
    local frame = _G.MerchantFrame
    if not frame then return end
    for _, a in ipairs(VANILLA_RELANCHORS) do
        local b = _G["MerchantItem" .. a[1]]
        local rel = _G[a[2]]
        if b and rel then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", rel, a[3], a[4], a[5])
        end
    end
    for i = XML_BUTTONS + 1, MAX_BUTTONS do
        local b = _G["MerchantItem" .. i]
        if b then b:Hide() end
    end
    frame:SetSize(BASE_W, BASE_H)
    local nextBtn = _G.MerchantNextPageButton
    if nextBtn then
        nextBtn:ClearAllPoints()
        nextBtn:SetPoint("CENTER", frame, "BOTTOMLEFT", BASE_W - NEXT_PAGE_INSET, 96)
    end
    -- Restore the buyback slot to its XML anchor (item10 BOTTOMLEFT 30,-53);
    -- item10 itself is reset above via VANILLA_RELANCHORS, so this is pixel-exact.
    local buyback = _G.MerchantBuyBackItem
    local item10 = _G.MerchantItem10
    if buyback and item10 then
        buyback:ClearAllPoints()
        buyback:SetPoint("TOPLEFT", item10, "BOTTOMLEFT", BUYBACK_ANCHOR_X, BUYBACK_ANCHOR_Y)
    end
    SafePanelUpdate()
end
-- <<< QUI_TEST_EXTRACT buyback_anchor

local function OnMerchantUpdate()
    local frame = _G.MerchantFrame
    if not frame then return end
    local enabled, cols, rows = ClampedConfig()
    if enabled and frame.selectedTab == 1 then
        ApplyGrid(cols, rows)
    else
        RestoreVanilla()
    end
end

local function InstallHook()
    if hookInstalled then return end
    if type(_G.MerchantFrame_Update) ~= "function" then return end
    hooksecurefunc("MerchantFrame_Update", OnMerchantUpdate)
    hookInstalled = true
end

-- Set the page-size global BEFORE Blizzard's fill loop runs. Buttons 13..N are
-- created FIRST so the invariant holds: MERCHANT_ITEMS_PER_PAGE > 12 implies the
-- extra buttons exist (else Blizzard's `for i=1,MERCHANT_ITEMS_PER_PAGE` loop
-- would nil-index MerchantItem13ItemButton). Buyback ignores this global (uses
-- its own BUYBACK_ITEMS_PER_PAGE), so it is safe to leave set on the buyback tab.
local function ApplyPageSize()
    local enabled, cols, rows = ClampedConfig()
    if enabled then
        EnsureButtons()
        _G.MERCHANT_ITEMS_PER_PAGE = cols * rows
    else
        _G.MERCHANT_ITEMS_PER_PAGE = VANILLA_PER_PAGE
    end
end

-- Public: re-read config and re-apply live (settings onChange + registry).
function MerchantGrid.Refresh()
    ApplyPageSize()
    if ClampedConfig() then InstallHook() end
    if _G.MerchantFrame and _G.MerchantFrame:IsShown()
        and type(_G.MerchantFrame_Update) == "function" then
        _G.MerchantFrame_Update()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_SHOW" then
        if ClampedConfig() then
            ApplyPageSize()
            InstallHook()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingPanelUpdate then
            pendingPanelUpdate = false
            SafePanelUpdate()
        end
    end
end)

-- LOD: this sub-addon's own ADDON_LOADED is not delivered (core eager-loads it
-- from OnEnable). Install via WhenLoggedIn. Nil only in the headless harness.
if ns.WhenLoggedIn then
    ns.WhenLoggedIn(function()
        if ClampedConfig() then
            ApplyPageSize()
            InstallHook()
        end
    end)
end

if ns.Registry then
    ns.Registry:Register("merchantGrid", {
        refresh = MerchantGrid.Refresh,
        priority = 30,
        group = "qol",
    })
end
