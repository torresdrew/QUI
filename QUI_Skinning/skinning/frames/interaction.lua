---------------------------------------------------------------------------
-- INTERACTION FRAMES SKINNING
--
-- Skins the everyday NPC-interaction and player-storage frames:
--   - BankFrame        (PortraitFrameTemplate)
--   - MerchantFrame    (ButtonFrameTemplate)
--   - GuildBankFrame   (BasicFrameTemplate,  LOD via Blizzard_GuildBankUI)
--
-- All three lean on SkinBase.SkinButtonFrameTemplate for the standard
-- chrome strip + backdrop + close-button styling. Frame-specific sub-
-- elements (bag slot grids, tab strips, message lists) get explicit coverage
-- where Blizzard owns them outside the root frame's descendant tree.
---------------------------------------------------------------------------

local addonName, ns = ...
local SkinBase = ns.SkinBase
local GetCore = ns.Helpers.GetCore

local function IsSettingEnabled(key)
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    return settings and settings[key]
end

---------------------------------------------------------------------------
-- Generic refresh: re-apply current skin colors to a previously-skinned
-- frame's QUI backdrop. Used by all three refreshers below.
---------------------------------------------------------------------------
local RefreshBackdropColors = SkinBase.RefreshFrameBackdropColors

---------------------------------------------------------------------------
-- BankFrame
---------------------------------------------------------------------------
local function SkinBank()
    if not IsSettingEnabled("skinBank") then return end
    local frame = _G.BankFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    -- depth 6: the tab-settings icon-selector popup's SelectedIconDescription sits
    -- at child-depth 5 and is re-fonted via SetFontObject on icon-select; a
    -- shallower font-object lock stops one level short and misses it.
    SkinBase.SkinWindow(frame, { depth = 6 })
    SkinBase.MarkSkinned(frame)
end

local function RefreshBank() RefreshBackdropColors(_G.BankFrame) end
_G.QUI_RefreshBankColors = RefreshBank
if ns.Registry then
    ns.Registry:Register("skinBank", {
        refresh = RefreshBank,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- MerchantFrame
---------------------------------------------------------------------------
local function SkinMerchant()
    if not IsSettingEnabled("skinMerchant") then return end
    local frame = _G.MerchantFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    -- MerchantFrameTab1 (Items), MerchantFrameTab2 (Buyback)
    SkinBase.SkinWindow(frame, { tabs = SkinBase.CollectNumberedTabs("MerchantFrame", 2) })
    -- Page navigation arrows (interior) — directional chevron + QUI backdrop.
    if _G.MerchantPrevPageButton then SkinBase.SkinNextPrevButton(_G.MerchantPrevPageButton, "prev") end
    if _G.MerchantNextPageButton then SkinBase.SkinNextPrevButton(_G.MerchantNextPageButton, "next") end
    SkinBase.MarkSkinned(frame)
end

local function RefreshMerchant() RefreshBackdropColors(_G.MerchantFrame) end
_G.QUI_RefreshMerchantColors = RefreshMerchant
if ns.Registry then
    ns.Registry:Register("skinMerchant", {
        refresh = RefreshMerchant,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- GossipFrame (NPC dialog / quest-giver greeting) — ButtonFrameTemplate, ships
-- in Blizzard_UIPanels_Game alongside Bank/Merchant.
---------------------------------------------------------------------------

-- Gossip text readability.
-- Greeting / option / quest rows render in QuestFont / QuestFontLeft, whose font
-- OBJECT ships PURE BLACK (Blizzard_Fonts_Shared FontStyles.xml: QuestFont
-- <Color r="0" g="0" b="0"/>) for the original parchment background; quest-title
-- rows also wrap their title in an embedded |cFF000000 escape code (NORMAL_QUEST_
-- DISPLAY). Worse, the 12.x quest-contrast theme system actively RE-DARKENS the
-- text: UIThemeContainerMixin:UpdateFontStrings (Blizzard_AccessibilityTemplates)
-- drives every RegisterFontString'd gossip fontstring to PARCHMENT_MATERIAL_TEXT_
-- COLOR on every open (GossipFrameSharedMixin:Update -> :UpdateTheme) and on the
-- PROXY_QUEST_TEXT_CONTRAST cvar. On QUI's dark backdrop that is black-on-dark.
--
-- Fix (mirrors the reference addon): per pooled row, force the fontstring white
-- AND post-hook SetTextColor to re-force white whenever the theme system recolors
-- it; remap the embedded dark color codes (which beat SetTextColor) to light on
-- SetText / SetFormattedText; and crop the inline option-icon coords. The global
-- font-object override only swaps the FACE (never color), so it cannot help here.
local GOSSIP_CODE_REMAP = { ["000000"] = "ffffff", ["414141"] = "7b8489" }

local function GossipReplaceCode(code)
    return "|cFF" .. (GOSSIP_CODE_REMAP[string.lower(code)] or code)
end

-- Re-force white whenever the quest-contrast theme system recolors a row (guarded
-- against self-recursion: re-setting to white satisfies the r==g==b==1 test).
local function GossipForceTextColor(fontString, r, g, b)
    if r ~= 1 or g ~= 1 or b ~= 1 then
        fontString:SetTextColor(1, 1, 1)
    end
end

-- SetText post-hook: crop the inline option icon and remap dark color codes, then
-- re-set via SetFormattedText with the trailing skip sentinel so it cannot re-enter.
local function GossipStripText(button, text)
    if not text or text == "" then return end
    local startText = text
    local iconText, iconCount = string.gsub(text, ":32:32:0:0", ":32:32:0:0:64:64:5:59:5:59")
    if iconCount > 0 then text = iconText end
    local colorText, colorCount = string.gsub(text, "|c[fF][fF](%x%x%x%x%x%x)", GossipReplaceCode)
    if colorCount > 0 then text = colorText end
    if startText ~= text then button:SetFormattedText("%s", text, true) end
end

-- SetFormattedText post-hook: remap dark codes embedded in the FORMAT (e.g.
-- NORMAL_QUEST_DISPLAY's |cFF000000) and re-apply with the skip sentinel.
local function GossipStripFormatted(button, textFormat, text, skip)
    if skip or not text or text == "" then return end
    local colorText, colorCount = string.gsub(textFormat, "|c[fF][fF](%x%x%x%x%x%x)", GossipReplaceCode)
    if colorCount > 0 then button:SetFormattedText(colorText, text, true) end
end

-- Recolor + de-darken one pooled row, once per fontstring. The SetTextColor hook
-- keeps it white across the theme system's per-open re-color; the SetText /
-- SetFormattedText hooks keep the code remap durable across every rebind.
local function GossipColorRow(row)
    if not row then return end
    -- Greeting-text rows: a plain FontString, no host button.
    local greetingText = row.GreetingText
    if greetingText and not SkinBase.GetFrameData(greetingText, "qGossipColored") then
        greetingText:SetTextColor(1, 1, 1)
        hooksecurefunc(greetingText, "SetTextColor", GossipForceTextColor)
        SkinBase.SetFrameData(greetingText, "qGossipColored", true)
    end
    -- Option / quest-title rows: a button whose NormalText carries the text.
    local fs = row.GetFontString and row:GetFontString()
    if fs and not SkinBase.GetFrameData(fs, "qGossipColored") then
        fs:SetTextColor(1, 1, 1)
        hooksecurefunc(fs, "SetTextColor", GossipForceTextColor)
        GossipStripText(row, row.GetText and row:GetText())
        hooksecurefunc(row, "SetText", GossipStripText)
        if row.SetFormattedText then
            hooksecurefunc(row, "SetFormattedText", GossipStripFormatted)
        end
        SkinBase.SetFrameData(fs, "qGossipColored", true)
    end
end

local function SkinGossip()
    if not IsSettingEnabled("skinGossip") then return end
    local frame = _G.GossipFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    SkinBase.SkinWindow(frame)
    -- Greeting panel: thin QUI scrollbar + durable fonts on the pooled gossip/
    -- quest option buttons (WowScrollBoxList rows re-face on rebind).
    local greeting = frame.GreetingPanel
    if greeting then
        if greeting.ScrollBar then SkinBase.SkinTrimScrollBar(greeting.ScrollBar) end
        if greeting.ScrollBox and SkinBase.HookScrollBoxRowFonts then
            SkinBase.HookScrollBoxRowFonts(greeting.ScrollBox, 3)
            -- QuestFont/QuestFontLeft ship pure black for the parchment era; recolor
            -- each pooled row to readable near-white + remap embedded |cFF000000 codes
            -- (these override SetTextColor) so gossip text is legible on the dark skin.
            if SkinBase.HookScrollBoxAcquired then
                SkinBase.HookScrollBoxAcquired(greeting.ScrollBox, GossipColorRow, { sync = true })
            end
        end
    end
    SkinBase.MarkSkinned(frame)
end

-- Theme refresh is driven via ns.Registry below (the modern path); no legacy
-- _G.QUI_RefreshGossipColors global (the older Bank/Merchant ones are vestigial,
-- write-only, and tracked by the global-assignment ratchet).
local function RefreshGossip() RefreshBackdropColors(_G.GossipFrame) end
if ns.Registry then
    ns.Registry:Register("skinGossip", {
        refresh = RefreshGossip,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- QuestFrame (NPC quest detail / progress / reward / greeting dialog) —
-- ButtonFrameTemplate, ships in Blizzard_UIPanels_Game. Panels are hidden and
-- shown one at a time; SkinFrameText/LockFrameTextObjects walk hidden children
-- too, so skinning once at load covers every panel.
---------------------------------------------------------------------------
local function SkinQuest()
    if not IsSettingEnabled("skinQuest") then return end
    local frame = _G.QuestFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    SkinBase.SkinWindow(frame, { depth = 5 })
    SkinBase.MarkSkinned(frame)
end

local function RefreshQuest() RefreshBackdropColors(_G.QuestFrame) end
if ns.Registry then
    ns.Registry:Register("skinQuest", {
        refresh = RefreshQuest,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- GuildBankFrame (LOD: Blizzard_GuildBankUI)
---------------------------------------------------------------------------
local function SkinGuildBank()
    if not IsSettingEnabled("skinGuildBank") then return end
    local frame = _G.GuildBankFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    -- Bottom PanelTabs (Items/Log/Money Log/Tab Info) re-show slice art + swap font
    -- via PanelTemplates_Select/DeselectTab on selection; SkinTabGroup installs the
    -- qTabArtClamped guard so the global PanelTemplates hooks re-clamp them.
    SkinBase.SkinWindow(frame, { tabs = SkinBase.CollectNumberedTabs("GuildBankFrame", 4) })
    SkinBase.MarkSkinned(frame)
end

local function RefreshGuildBank() RefreshBackdropColors(_G.GuildBankFrame) end
_G.QUI_RefreshGuildBankColors = RefreshGuildBank
if ns.Registry then
    ns.Registry:Register("skinGuildBank", {
        refresh = RefreshGuildBank,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- ClassTrainerFrame (learn-spells-from-NPC) — ButtonFrameTemplate, LOD via
-- Blizzard_TrainerUI.
---------------------------------------------------------------------------
local function SkinTrainer()
    if not IsSettingEnabled("skinTrainer") then return end
    local frame = _G.ClassTrainerFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    SkinBase.SkinWindow(frame)
    SkinBase.MarkSkinned(frame)
end

local function RefreshTrainer() RefreshBackdropColors(_G.ClassTrainerFrame) end
if ns.Registry then
    ns.Registry:Register("skinTrainer", {
        refresh = RefreshTrainer,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- MacroFrame (macro editor) — ButtonFrameTemplate, LOD via Blizzard_MacroUI.
-- Tabs: MacroFrameTab1 (Character), MacroFrameTab2 (Account).
---------------------------------------------------------------------------
local function SkinMacro()
    if not IsSettingEnabled("skinMacro") then return end
    local frame = _G.MacroFrame
    if not frame or SkinBase.IsSkinned(frame) then return end
    SkinBase.SkinWindow(frame, { tabs = SkinBase.CollectNumberedTabs("MacroFrame", 2) })
    SkinBase.MarkSkinned(frame)
end

local function RefreshMacro() RefreshBackdropColors(_G.MacroFrame) end
if ns.Registry then
    ns.Registry:Register("skinMacro", {
        refresh = RefreshMacro,
        priority = 80,
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end

---------------------------------------------------------------------------
-- INITIALIZATION
-- Bank and Merchant ship in Blizzard_UIPanels_Game (always loaded);
-- OnAddOnLoaded short-circuits the already-loaded case so this works for
-- both LOD and always-loaded addons.
---------------------------------------------------------------------------
SkinBase.OnAddOnLoaded("Blizzard_UIPanels_Game", function()
    SkinBank()
    SkinMerchant()
    SkinGossip()
    SkinQuest()
end, 0)

SkinBase.OnAddOnLoaded("Blizzard_GuildBankUI", SkinGuildBank, 0)
SkinBase.OnAddOnLoaded("Blizzard_TrainerUI", SkinTrainer, 0)
SkinBase.OnAddOnLoaded("Blizzard_MacroUI", SkinMacro, 0)
