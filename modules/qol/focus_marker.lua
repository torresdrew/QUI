local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

---------------------------------------------------------------------------
-- FOCUS + RAID MARKER BUTTON (GRP-04)
--
-- One action that sets your focus AND puts a raid marker on it — via a
-- mouseover-aware macro:
--     /focus [@mouseover,harm,nodead][]
--     /tm    [@mouseover,harm,nodead][] <marker>
-- Two ways to press it:
--   * a character macro named "QUI Focus Marker" (written/updated with
--     CreateMacro/EditMacro, both 12.x FrameXML-verified) — drag it to any
--     action bar or keybind it like any macro;
--   * a named secure button (QUI_FocusMarkerButton, SecureActionButtonTemplate
--     type=macro) for users who bind clicks directly.
--
-- SECURE RULES: attribute writes and macro writes happen OUT OF COMBAT
-- only; changes made in combat are queued and applied on
-- PLAYER_REGEN_ENABLED. Nothing Blizzard-owned is touched.
---------------------------------------------------------------------------

local GetSettings = Helpers.CreateDBGetter("general")

local MACRO_NAME = "QUI Focus Marker"
local MACRO_ICON = 132219 -- crossed swords

local button
local pendingApply = false

local function Cfg()
    local s = GetSettings()
    return s and s.focusMarker or nil
end

-- <<< QUI_TEST_EXTRACT macro_body
-- Build the macro body. marker: 1-8 (raid target index). useMouseover:
-- prefer a hostile living mouseover, falling back to the current target.
local function BuildMacroBody(marker, useMouseover)
    marker = tonumber(marker) or 8
    if marker < 1 then marker = 1 elseif marker > 8 then marker = 8 end
    if useMouseover then
        return ("/focus [@mouseover,harm,nodead][]\n/tm [@mouseover,harm,nodead][] %d"):format(marker)
    end
    return ("/focus\n/tm %d"):format(marker)
end
-- <<< QUI_TEST_EXTRACT macro_body

local function EnsureButton()
    if button then return button end
    button = CreateFrame("Button", "QUI_FocusMarkerButton", UIParent, "SecureActionButtonTemplate")
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:SetAttribute("type", "macro")
    button:SetAttribute("type1", "macro")
    return button
end

-- Find our macro by name scan (GetNumMacros → numAccount, numCharacter;
-- GetMacroInfo(index) → name; character macros start after
-- MAX_ACCOUNT_MACROS — all 12.x FrameXML-verified in Blizzard_MacroUI.lua).
local function FindMacroIndex()
    if not (GetNumMacros and GetMacroInfo) then return nil end
    local numAccount, numCharacter = GetNumMacros()
    for i = 1, numAccount or 0 do
        if GetMacroInfo(i) == MACRO_NAME then return i end
    end
    local base = MAX_ACCOUNT_MACROS or 120
    for i = base + 1, base + (numCharacter or 0) do
        if GetMacroInfo(i) == MACRO_NAME then return i end
    end
    return nil
end

local function WriteCharacterMacro(body)
    if not (CreateMacro and EditMacro) then return end
    local index = FindMacroIndex()
    if index then
        pcall(EditMacro, index, MACRO_NAME, MACRO_ICON, body)
    else
        -- nil tab = account/general macros; pcall guards the macro cap.
        pcall(CreateMacro, MACRO_NAME, MACRO_ICON, body, nil)
    end
end

local function Apply()
    local cfg = Cfg()
    if not cfg or not cfg.enabled then
        pendingApply = false
        if button and not InCombatLockdown() then
            button:SetAttribute("macrotext", "")
            button:SetAttribute("macrotext1", "")
        end
        return
    end

    if InCombatLockdown() then
        pendingApply = true
        return
    end
    pendingApply = false

    local body = BuildMacroBody(cfg.marker, cfg.useMouseover ~= false)
    local btn = EnsureButton()
    btn:SetAttribute("macrotext", body)
    btn:SetAttribute("macrotext1", body)

    if cfg.writeMacro ~= false then
        WriteCharacterMacro(body)
    end
end

local frame = CreateFrame("Frame")
-- Literal RegisterEvent call so tools/generate_event_allowlist.lua detects it.
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function()
    if pendingApply then Apply() end
end)

ns.RefreshFocusMarker = Apply

if ns.WhenLoggedIn then
    ns.WhenLoggedIn(Apply)
end
