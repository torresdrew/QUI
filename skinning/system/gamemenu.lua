local addonName, ns = ...

local GetCore = ns.Helpers.GetCore
local SkinBase = ns.SkinBase

---------------------------------------------------------------------------
-- GAME MENU (ESC MENU) SKINNING + QUAZII UI BUTTON
---------------------------------------------------------------------------

-- Static colors
local COLORS = {
    text = { 0.9, 0.9, 0.9, 1 },
}

local FONT_FLAGS = "OUTLINE"

-- TAINT SAFETY: Use a weak-keyed state table instead of writing custom
-- properties directly on Blizzard frame tables. GameMenuFrame is a
-- registered Edit Mode system frame; writing properties like
-- GameMenuFrame.quiSkinned taints the frame table.
local frameState = setmetatable({}, { __mode = "k" })
local function S(f)
    if not frameState[f] then frameState[f] = {} end
    return frameState[f]
end

-- Get game menu font size from settings
local function GetGameMenuFontSize()
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    return settings and settings.gameMenuFontSize or 12
end

-- Style a button with QUI theme
local function StyleButton(button, sr, sg, sb, sa, bgr, bgg, bgb, bga)
    if not button then return end

    local bs = S(button)

    -- Create backdrop if needed
    if not bs.quiBackdrop then
        bs.quiBackdrop = CreateFrame("Frame", nil, button, "BackdropTemplate")
        bs.quiBackdrop:SetAllPoints()
        bs.quiBackdrop:SetFrameLevel(button:GetFrameLevel())
        bs.quiBackdrop:EnableMouse(false)
    end

    local btnPx = SkinBase.GetPixelSize(bs.quiBackdrop, 1)
    bs.quiBackdrop:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = btnPx,
        insets = { left = btnPx, right = btnPx, top = btnPx, bottom = btnPx }
    })

    -- Button bg slightly lighter than main bg
    local btnBgR = math.min(bgr + 0.07, 1)
    local btnBgG = math.min(bgg + 0.07, 1)
    local btnBgB = math.min(bgb + 0.07, 1)
    bs.quiBackdrop:SetBackdropColor(btnBgR, btnBgG, btnBgB, 1)
    bs.quiBackdrop:SetBackdropBorderColor(sr, sg, sb, sa)

    -- Hide default textures
    if button.Left then button.Left:SetAlpha(0) end
    if button.Right then button.Right:SetAlpha(0) end
    if button.Center then button.Center:SetAlpha(0) end
    if button.Middle then button.Middle:SetAlpha(0) end

    -- Hide highlight/pushed/normal/disabled textures
    local highlight = button:GetHighlightTexture()
    if highlight then highlight:SetAlpha(0) end
    local pushed = button:GetPushedTexture()
    if pushed then pushed:SetAlpha(0) end
    local normal = button:GetNormalTexture()
    if normal then normal:SetAlpha(0) end
    local disabled = button:GetDisabledTexture()
    if disabled then disabled:SetAlpha(0) end

    -- Style button text
    local text = button:GetFontString()
    if text then
        local QUI = _G.QUI
        local fontPath = QUI and QUI.GetGlobalFont and QUI:GetGlobalFont() or STANDARD_TEXT_FONT
        local fontSize = GetGameMenuFontSize()
        text:SetFont(fontPath, fontSize, FONT_FLAGS)
        text:SetTextColor(unpack(COLORS.text))
    end

    -- Store colors for hover effects
    bs.quiSkinColor = { sr, sg, sb, sa }
    bs.quiBgColor = { btnBgR, btnBgG, btnBgB, 1 }

    -- Set hover scripts without replacing existing handlers
    -- Only hook once (check via state table)
    if not bs.quiHooked then
        button:HookScript("OnEnter", function(self)
            local s = S(self)
            if s.quiBackdrop then
                if s.quiBgColor then
                    local r, g, b, a = unpack(s.quiBgColor)
                    s.quiBackdrop:SetBackdropColor(math.min(r + 0.15, 1), math.min(g + 0.15, 1), math.min(b + 0.15, 1), a)
                end
                if s.quiSkinColor then
                    local r, g, b, a = unpack(s.quiSkinColor)
                    s.quiBackdrop:SetBackdropBorderColor(math.min(r * 1.4, 1), math.min(g * 1.4, 1), math.min(b * 1.4, 1), a)
                end
            end
            local txt = self:GetFontString()
            if txt then txt:SetTextColor(1, 1, 1, 1) end
        end)

        button:HookScript("OnLeave", function(self)
            local s = S(self)
            if s.quiBackdrop then
                if s.quiBgColor then
                    s.quiBackdrop:SetBackdropColor(unpack(s.quiBgColor))
                end
                if s.quiSkinColor then
                    s.quiBackdrop:SetBackdropBorderColor(unpack(s.quiSkinColor))
                end
            end
            local txt = self:GetFontString()
            if txt then txt:SetTextColor(unpack(COLORS.text)) end
        end)
        bs.quiHooked = true
    end

    bs.quiStyled = true
end

-- Update button colors (for live refresh)
local function UpdateButtonColors(button, sr, sg, sb, sa, bgr, bgg, bgb, bga)
    local bs = S(button)
    if not button or not bs.quiBackdrop then return end

    local btnBgR = math.min(bgr + 0.07, 1)
    local btnBgG = math.min(bgg + 0.07, 1)
    local btnBgB = math.min(bgb + 0.07, 1)
    bs.quiBackdrop:SetBackdropColor(btnBgR, btnBgG, btnBgB, 1)
    bs.quiBackdrop:SetBackdropBorderColor(sr, sg, sb, sa)
    bs.quiSkinColor = { sr, sg, sb, sa }
    bs.quiBgColor = { btnBgR, btnBgG, btnBgB, 1 }
end

-- Hide Blizzard decorative elements
local function HideBlizzardDecorations()
    if GameMenuFrame.Border then GameMenuFrame.Border:Hide() end
    if GameMenuFrame.Header then GameMenuFrame.Header:Hide() end
end

-- Dim background frame
local dimFrame = nil

local function CreateDimFrame()
    if dimFrame then return dimFrame end

    dimFrame = CreateFrame("Frame", "QUIGameMenuDim", UIParent)
    dimFrame:SetAllPoints(UIParent)
    dimFrame:SetFrameStrata("DIALOG")
    dimFrame:SetFrameLevel(0)
    dimFrame:EnableMouse(false)  -- Don't capture mouse events
    dimFrame:Hide()

    -- Dark overlay texture
    dimFrame.overlay = dimFrame:CreateTexture(nil, "BACKGROUND")
    dimFrame.overlay:SetAllPoints()
    dimFrame.overlay:SetColorTexture(0, 0, 0, 0.5)

    return dimFrame
end

local function ShowDimBehindGameMenu()
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    if not settings or not settings.skinGameMenu or not settings.gameMenuDim then return end

    local dim = CreateDimFrame()
    dim:SetFrameStrata("DIALOG")
    dim:SetFrameLevel(GameMenuFrame:GetFrameLevel() - 1)
    dim:Show()
end

local function HideDimBehindGameMenu()
    if dimFrame then
        dimFrame:Hide()
    end
end

-- Expose for settings toggle
_G.QUI_RefreshGameMenuDim = function()
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general

    if settings and settings.gameMenuDim and GameMenuFrame:IsShown() then
        ShowDimBehindGameMenu()
    else
        HideDimBehindGameMenu()
    end
end

-- Main skinning function
local function SkinGameMenu()
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    if not settings or not settings.skinGameMenu then return end

    if not GameMenuFrame then return end
    if S(GameMenuFrame).quiSkinned then return end

    -- Get colors based on setting
    local sr, sg, sb, sa, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()

    -- Hide Blizzard decorations
    HideBlizzardDecorations()

    -- Create backdrop (inline instead of SkinBase.CreateBackdrop to avoid
    -- writing GameMenuFrame.quiBackdrop on a registered Edit Mode system frame)
    local gmS = S(GameMenuFrame)
    if not gmS.quiBackdrop then
        gmS.quiBackdrop = CreateFrame("Frame", nil, GameMenuFrame, "BackdropTemplate")
        gmS.quiBackdrop:SetAllPoints()
        gmS.quiBackdrop:SetFrameLevel(GameMenuFrame:GetFrameLevel())
        gmS.quiBackdrop:EnableMouse(false)
    end
    local gmPx = SkinBase.GetPixelSize(gmS.quiBackdrop, 1)
    gmS.quiBackdrop:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = gmPx,
        insets = { left = gmPx, right = gmPx, top = gmPx, bottom = gmPx },
    })
    gmS.quiBackdrop:SetBackdropColor(bgr, bgg, bgb, bga)
    gmS.quiBackdrop:SetBackdropBorderColor(sr, sg, sb, sa)

    -- Adjust frame padding for cleaner look
    GameMenuFrame.topPadding = 15
    GameMenuFrame.bottomPadding = 15
    GameMenuFrame.leftPadding = 15
    GameMenuFrame.rightPadding = 15
    GameMenuFrame.spacing = 2

    -- Style all buttons in the pool
    if GameMenuFrame.buttonPool then
        for button in GameMenuFrame.buttonPool:EnumerateActive() do
            StyleButton(button, sr, sg, sb, sa, bgr, bgg, bgb, bga)
        end
    end

    GameMenuFrame:MarkDirty()
    S(GameMenuFrame).quiSkinned = true
end

-- Refresh colors on already-skinned game menu (for live preview)
local function RefreshGameMenuColors()
    if not GameMenuFrame or not S(GameMenuFrame).quiSkinned then return end

    -- Get colors based on setting
    local sr, sg, sb, sa, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()

    -- Update main frame backdrop (stored in state table, not on frame)
    local gmS = S(GameMenuFrame)
    if gmS.quiBackdrop then
        gmS.quiBackdrop:SetBackdropColor(bgr, bgg, bgb, bga)
        gmS.quiBackdrop:SetBackdropBorderColor(sr, sg, sb, sa)
    end

    -- Update all buttons
    if GameMenuFrame.buttonPool then
        for button in GameMenuFrame.buttonPool:EnumerateActive() do
            UpdateButtonColors(button, sr, sg, sb, sa, bgr, bgg, bgb, bga)
        end
    end
end

-- Refresh font size on game menu buttons
local function RefreshGameMenuFontSize()
    if not GameMenuFrame then return end

    local fontSize = GetGameMenuFontSize()
    local QUI = _G.QUI
    local fontPath = QUI and QUI.GetGlobalFont and QUI:GetGlobalFont() or STANDARD_TEXT_FONT

    if GameMenuFrame.buttonPool then
        for button in GameMenuFrame.buttonPool:EnumerateActive() do
            local text = button:GetFontString()
            if text then
                text:SetFont(fontPath, fontSize, FONT_FLAGS)
            end
        end
    end

    -- Mark dirty to recalculate layout if needed
    if GameMenuFrame.MarkDirty then
        GameMenuFrame:MarkDirty()
    end
end

-- Expose refresh functions globally
_G.QUI_RefreshGameMenuColors = RefreshGameMenuColors
_G.QUI_RefreshGameMenuFontSize = RefreshGameMenuFontSize

---------------------------------------------------------------------------
-- QUAZII UI BUTTON INJECTION
---------------------------------------------------------------------------

-- Inject button on every InitButtons call (buttonPool gets reset each time)
local function InjectQUIButton()
    local core = GetCore()
    local settings = core and core.db and core.db.profile and core.db.profile.general
    if not settings or settings.addQUIButton == false then return end

    if not GameMenuFrame or not GameMenuFrame.buttonPool then return end

    -- Find the Macros button to insert after
    local macrosIndex = nil
    for button in GameMenuFrame.buttonPool:EnumerateActive() do
        if button:GetText() == MACROS then
            macrosIndex = button.layoutIndex
            break
        end
    end

    if macrosIndex then
        -- Shift buttons after Macros down by 1
        for button in GameMenuFrame.buttonPool:EnumerateActive() do
            if button.layoutIndex and button.layoutIndex > macrosIndex then
                button.layoutIndex = button.layoutIndex + 1
            end
        end

        -- Add QUI button
        local quiButton = GameMenuFrame:AddButton("QUI", function()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
            HideUIPanel(GameMenuFrame)
            local QUI = _G.QUI
            if QUI and QUI.GUI then
                QUI.GUI:Show()
            end
        end)
        quiButton.layoutIndex = macrosIndex + 1
        GameMenuFrame:MarkDirty()
    end
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------

-- Hook into GameMenuFrame button initialization (with defensive check)
if GameMenuFrame and GameMenuFrame.InitButtons then
    hooksecurefunc(GameMenuFrame, "InitButtons", function()
        -- TAINT SAFETY: Defer ALL addon code out of secure InitButtons callback.
        -- GameMenuFrame:InitButtons fires in the same call chain as Edit Mode entry;
        -- synchronous addon code here taints the secure execution context, causing
        -- TargetUnit() ADDON_ACTION_FORBIDDEN errors.
        C_Timer.After(0, function()
            -- Inject QUI button (always, regardless of skinning setting)
            InjectQUIButton()

            -- Skin menu if enabled
            SkinGameMenu()

            -- Style any new buttons that were added
            if S(GameMenuFrame).quiSkinned and GameMenuFrame.buttonPool then
                local sr, sg, sb, sa, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()

                for button in GameMenuFrame.buttonPool:EnumerateActive() do
                    if not S(button).quiStyled then
                        StyleButton(button, sr, sg, sb, sa, bgr, bgg, bgb, bga)
                    end
                end
            end
        end)
    end)

    -- Hook Show/Hide for dim effect and button re-styling
    -- TAINT SAFETY: Defer ALL addon code out of OnShow callback.
    -- GameMenuFrame is shown in the same secure call chain as Edit Mode entry.
    GameMenuFrame:HookScript("OnShow", function()
        C_Timer.After(0, function()
            ShowDimBehindGameMenu()

            -- Button styling
            if not GameMenuFrame:IsShown() then return end
            if not S(GameMenuFrame).quiSkinned or not GameMenuFrame.buttonPool then return end

            local sr, sg, sb, sa, bgr, bgg, bgb, bga = SkinBase.GetSkinColors()
            for button in GameMenuFrame.buttonPool:EnumerateActive() do
                -- Force full re-styling every time (hooks may be lost on pool recycle)
                S(button).quiStyled = nil
                StyleButton(button, sr, sg, sb, sa, bgr, bgg, bgb, bga)
            end
        end)
    end)
    GameMenuFrame:HookScript("OnHide", function()
        C_Timer.After(0, HideDimBehindGameMenu)
    end)
end
