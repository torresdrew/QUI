-- core/aura_skin.lua — QUI.AuraSkin: secure adapter wrapping CustomAuraContainer.
-- The ONLY QUI code that touches Blizzard's forbidden-object inbound API.
--
-- OFFICIAL Blizzard CustomAuraContainer usage (Blizzard_AuraContainer add-on):
-- the consumer CREATES each AuraButton as a child of the container, SIZES and
-- POSITIONS it (insecure SetSize/SetPoint on the buttons is the intended
-- pattern — the engine drives aura DATA, not button layout), wires the art
-- regions as CHILDREN of the button (required by GetValidatedForbiddenObjectTable,
-- which checks the region inherits the button's forbidden parent + layout
-- aspects), and registers the button via container:AddAuraFrame(button).  QUI
-- lays the buttons out in a grid relative to the container; the container is
-- positioned by the consumer.
local ADDON_NAME, ns = ...
ns.Addon = ns.Addon or {}
local AuraTheme = ns.Addon.AuraTheme
local AuraSkin = {}
ns.Addon.AuraSkin = AuraSkin
_G.QUI = _G.QUI or {}
_G.QUI.AuraSkin = AuraSkin

-- Profile field resolution (defaults match the task contract).  AuraTheme.Metrics
-- supplies iconSize / spacing / grow / maxIcons; the grid extras (maxPerRow,
-- offsetX, offsetY, anchor) are read straight off the profile here.
local function ResolveLayout(profile)
    profile = profile or {}
    local m = AuraTheme.Metrics(profile)
    return {
        maxIcons  = m.maxIcons,
        iconSize  = m.iconSize,
        spacing   = m.spacing,
        grow      = m.grow,
        maxPerRow = profile.maxPerRow or 0,
        offsetX   = profile.offsetX or 0,
        offsetY   = profile.offsetY or 0,
        anchor    = profile.anchor or "TOPLEFT",
    }
end

-- Compute the (x, y) offset of button index `i` (1-based) within the grid,
-- relative to the container `anchor` corner.  Mirrors the preview layout math in
-- QUI_UnitFrames/unitframes/unitframe_auras.lua (ShowAuraPreviewForFrame ~line
-- 635) so the live container layout == the layout-mode preview layout:
--   grow RIGHT/LEFT steps the COLUMN (x); UP/DOWN steps the ROW (y).
--   maxPerRow (>0) wraps to a new line every maxPerRow icons; the wrap axis is
--   perpendicular to grow (a horizontal grow wraps DOWN; a vertical grow wraps
--   to the RIGHT), so a grid fills out toward BOTTOM/RIGHT of the anchor corner.
local function GridOffset(i, L)
    local idx       = i - 1
    local perRow    = L.maxPerRow or 0
    local col, row
    if perRow and perRow > 0 then
        col = idx % perRow
        row = math.floor(idx / perRow)
    else
        col = idx
        row = 0
    end
    local step      = L.iconSize + L.spacing
    local x, y      = L.offsetX, L.offsetY
    if L.grow == "RIGHT" then
        x = x + col * step
        y = y - row * step          -- horizontal grow wraps downward
    elseif L.grow == "LEFT" then
        x = x - col * step
        y = y - row * step
    elseif L.grow == "UP" then
        y = y + col * step
        x = x + row * step          -- vertical grow wraps rightward
    elseif L.grow == "DOWN" then
        y = y - col * step
        x = x + row * step
    else
        x = x + col * step          -- unknown grow → treat as RIGHT
        y = y - row * step
    end
    return x, y
end

-- Build + wire one CustomAuraButton's art in Lua ONCE.  Mirrors Blizzard's official
-- AuraButton example (insecure CreateTexture + SetPoint + SetIcon — the engine
-- drives aura DATA, the addon drives presentation).  Idempotent (button._quiWired).
--
-- The inbound setters are used the SAME way as SetDurationText: pass the region +
-- an EMPTY options table — never a QUI-created formatter.  SetApplicationCount writes
-- options.formatter DIRECTLY (no securecopy), so a QUI formatter is a tainted value
-- assigned into the forbidden fontstring → blocked; with {} it stays nil and the
-- engine's own secret-safe `applications > 1` path (run secure-side) drives the
-- count.  SetAuraBorder DOES securecopy its options, so its field writes are safe;
-- ApplyAuraBorder reads the secret dispel fields secure-side.  Both run inside the
-- secure apply where secret compares are allowed — the earlier "blank" was the
-- unsized container, not these setters.
local function buildButtonArt(button)
    if button._quiWired then return end
    button._quiWired = true

    -- Static QUI border: a plain QUI-owned texture (NOT the secure SetAuraBorder),
    -- coloured by styleButton.  Aura-data-INDEPENDENT.  BACKGROUND (below the icon);
    -- shown as the neutral ring on buffs / non-dispel debuffs.
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(button)
    button._quiBorder = border

    -- Dispel overlay border (BORDER layer, above the static border, below the icon).
    -- SetAuraBorder securecopies its options, so this is addon-safe; the engine
    -- vertex-colours it by dispel type and shows it only on dispellable HARMFUL auras
    -- (showWhenHelpful=false), covering the static ring with the dispel colour.  A
    -- white base texture is required so the vertex colour is visible.
    local dispel = button:CreateTexture(nil, "BORDER")
    dispel:SetAllPoints(button)
    dispel:SetColorTexture(1, 1, 1, 1)
    if dispel.DisablePixelSnap then dispel:DisablePixelSnap() end
    button._quiDispel = dispel
    button:SetAuraBorder(dispel, {
        style = 1,                 -- AuraButtonBorderStyle.Color (secure-env enum; mirror value)
        showWhenHarmful = true,
        showWhenHelpful = false,
    })

    -- Icon (ARTWORK, inset 1px so the border shows as a ring).
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.Icon = icon
    button:SetIcon(icon)

    -- Dispel text symbol. AuraUtil.SetAuraSymbol only shows text when Blizzard's
    -- colorblind mode asks for it, so wiring this is visually inert for the
    -- normal case but uses the new 12.1 secure-side symbol path when needed.
    local symbol = button:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
    symbol:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    button._quiSymbol = symbol
    button:SetAuraSymbol(symbol, {
        showWhenHarmful = true,
        showWhenHelpful = false,
    })

    -- Duration cooldown swipe (frame child).
    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(button)
    cd:SetHideCountdownNumbers(true)
    button._quiCooldown = cd
    button:SetDurationCooldown(cd)

    -- Duration text.  Font template so it always has a font; no Lua formatter
    -- (Blizzard's C-side DefaultAuraDurationFormatter is secret-safe).
    local durText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    durText:SetPoint("CENTER", button, "CENTER", 0, 0)
    button._quiDuration = durText
    button:SetDurationText(durText, {})

    -- Stack count — EXACTLY like duration: fontstring + SetApplicationCount({}), NO
    -- formatter.  The engine's secure `applications > 1` path shows it for 2+ stacks
    -- and hides single stacks.
    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button._quiCount = count
    button:SetApplicationCount(count, {})
end

-- Apply STATIC appearance (border color, font, swipe) to one button.  Called
-- every Attach so a config change re-styles without a /reload.  All writes are
-- aura-data-INDEPENDENT (no secret branch), so they're safe.
local Helpers = ns.Helpers
local function styleButton(button, profile)
    -- Static QUI border: theme-color fill, shown as a 1px ring around the inset icon.
    local border = button._quiBorder
    if border then
        local r, g, b, a = AuraTheme.BorderColor()
        border:SetColorTexture(r, g, b, a or 1)
        if border.DisablePixelSnap then border:DisablePixelSnap() end
    end

    -- Duration font: QUI general font at profile.fontSize.
    local fontSize = profile.fontSize or 11
    if fontSize <= 0 then fontSize = 11 end
    local fontPath = (Helpers and Helpers.GetGeneralFont and Helpers.GetGeneralFont())
    local fontFlags = (Helpers and Helpers.GetGeneralFontOutline and Helpers.GetGeneralFontOutline()) or "OUTLINE"
    if fontPath and button._quiDuration then button._quiDuration:SetFont(fontPath, fontSize, fontFlags) end
    if fontPath and button._quiCount then button._quiCount:SetFont(fontPath, fontSize, fontFlags) end
    if fontPath and button._quiSymbol then button._quiSymbol:SetFont(fontPath, fontSize, fontFlags) end

    -- Swipe (config on the Cooldown — appearance, not aura data).
    local cd = button._quiCooldown
    if cd then
        cd:SetDrawSwipe(profile.hideSwipe ~= true)
        cd:SetReverse(profile.reverseSwipe == true)
        cd:SetHideCountdownNumbers(true)
    end
end

-- Position + size one button in the grid (insecure, intended by the pattern).
-- Called on every Attach so a config/layout change re-flows existing buttons.
local function layoutButton(button, container, i, L)
    button:SetSize(L.iconSize, L.iconSize)
    local x, y = GridOffset(i, L)
    button:ClearAllPoints()
    button:SetPoint(L.anchor, container, L.anchor, x, y)
end

-- Attach: create / size / position / wire / register / style maxIcons
-- CustomAuraButtons on `container`.  Idempotent and re-entrant:
--   * buttons are stored in container._quiButtons[i] and reused on re-Attach;
--   * art is built + registered ONCE per button (first creation only);
--   * size/position are re-applied every Attach (layout may have changed);
--   * style (border color/size, font size, swipe) is re-applied every Attach
--     so a config change propagates without a /reload;
--   * if maxIcons grew, the new buttons are created + registered now.
function AuraSkin.Attach(container, profile)
    local L = ResolveLayout(profile)

    -- The container MUST have a resolvable rect or its buttons never get a screen
    -- position (GetCenter returns nil → nothing paints).  A frame with anchor
    -- points but zero size has no computable rect, so size it 1x1 — it is only an
    -- anchor reference; the buttons extend out from its anchor corner via their
    -- own SetPoint.  (This was the player/unit/group blank: the named anchor frame
    -- was sized, but the AuraContainer child inside it was not.)
    container:SetSize(1, 1)

    local buttons = container._quiButtons
    if not buttons then
        buttons = {}
        container._quiButtons = buttons
    end

    for i = 1, L.maxIcons do
        local button = buttons[i]
        if not button then
            -- CREATE the button as a child of the container (the official
            -- pattern: the addon creates the AuraButton, not the engine).
            button = CreateFrame("AuraButton", nil, container, "CustomAuraButtonTemplate")
            buttons[i] = button
            buildButtonArt(button)
            layoutButton(button, container, i, L)
            -- REGISTER once — never re-add an already-registered button.
            container:AddAuraFrame(button)
        else
            -- Existing button: re-flow only (layout may have changed).
            layoutButton(button, container, i, L)
        end
        -- Re-apply QUI style every Attach so config changes (border, font,
        -- swipe) propagate without a /reload.  OOC, secret-safe.
        styleButton(button, profile)
    end

    container._quiAttached = true
end
