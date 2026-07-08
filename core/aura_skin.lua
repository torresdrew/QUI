-- core/aura_skin.lua — QUI.AuraSkin: secure adapter wrapping CustomAuraContainer.
-- The ONLY QUI code that touches Blizzard's forbidden-object inbound API.
--
-- 12.1 PTR4 contract (Blizzard_CustomAuraContainer add-on): the engine, not
-- the addon, CREATES and anchors CustomAuraButtons and auto-sizes the
-- CONTAINER (the outer rect grows to fit its flowed children); the engine's
-- flow layout is SetPoint-only and never SetSizes an individual button, so
-- BUTTON sizing is QUI's job (see styleButton). The addon calls
-- container:AddAuraGroup(groupKey, filterString, options) to declare a group
-- of auras; the engine allocates buttons in batches and hands each one to
-- options.initializeFrame ONCE (securecallfunction), where the addon wires
-- the art regions as CHILDREN of the button (required by
-- GetValidatedForbiddenObjectTable, which checks the region inherits the
-- button's forbidden parent + layout aspects) and hooks the inbound setters.
-- Layout (grid shape, growth direction, row wrap) is container-wide and
-- per-group, driven entirely through Set* mutators — QUI no longer sizes or
-- positions buttons itself. Groups can never be removed and a group's filter
-- string is immutable once registered, so AuraSkin.Configure reconciles a
-- composite registry key instead of clearing and re-adding.
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
        -- Point ON THE BUTTON pinned to the container's anchor corner.  Unit
        -- frames pass the vertically-flipped corner so the grid renders OUTSIDE
        -- the frame edge (buffs above a TOP anchor, below a BOTTOM anchor —
        -- preview parity); omitted → same corner (in-frame strips, buff borders).
        attachPoint = profile.attachPoint or profile.anchor or "TOPLEFT",
        -- Wrap axis for the container-wide flow layout: "UP" wraps upward,
        -- default "DOWN". buffborders sets this from its growUp toggle.
        wrap = profile.wrap,
    }
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
-- from initializeFrame at button birth and from Restyle/Configure so a config
-- change re-styles without a /reload.  All writes are aura-data-INDEPENDENT
-- (no secret branch), so they're safe.
local Helpers = ns.Helpers
local function styleButton(button, profile)
    -- The engine's flow layout positions buttons but never sizes them
    -- (ApplyElementLayout is SetPoint-only; elementWidth only advances the
    -- flow cursor) — a 0x0 button paints none of its art. Insecure SetSize
    -- on the forbidden button is the same legal-mutation class as the fonts
    -- below, and the engine never overwrites it.
    local size = profile.iconSize or 22
    if size <= 0 then size = 22 end
    button:SetSize(size, size)

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

-- Map the QUI grow vocabulary onto the PTR4 container-wide flow layout
-- (verified: SetAuraLayoutAnchorPoint / SetAuraLayoutGrowthDirection with
-- AnchorUtil.FlowDirection {Left=-1, Right=1, Up=1, Down=-1} /
-- SetAuraLayoutRowWidth in PIXELS, nil = no wrap).
-- Column-primary growth (grow UP/DOWN) wraps after every icon (rowWidth =
-- iconSize); a multi-column vertical grid (maxPerRow with vertical grow) is
-- not expressible in a row-major flow layout and degrades to one column.
-- Flow derivation: primary axis from grow (RIGHT/LEFT = rows; UP/DOWN =
-- column, one icon per row), wrap axis from profile.wrap ("UP" wraps upward,
-- default "DOWN" — buffborders sets wrap from its growUp toggle). The flow
-- origin corner combines both.
local function FlowFor(L)
    local grow = L.grow
    local column = (grow == "UP" or grow == "DOWN")
    local left = (grow == "LEFT")
    local up
    if column then up = (grow == "UP") else up = (L.wrap == "UP") end
    local anchor = (up and "BOTTOM" or "TOP") .. (left and "RIGHT" or "LEFT")
    return anchor, left, up, column
end

-- The container corner the grid flows from. Consumers pin THIS corner in
-- their SetPoint so the auto-sized rect grows away from the pinned spot.
function AuraSkin.LayoutAnchor(profile)
    local anchor = FlowFor(ResolveLayout(profile))
    return anchor
end

local function ApplyContainerLayout(container, L)
    local anchor, left, up, column = FlowFor(L)
    local FD = AnchorUtil.FlowDirection
    container:SetAuraLayoutAnchorPoint(anchor)
    container:SetAuraLayoutGrowthDirection(
        left and FD.Left or FD.Right,
        up and FD.Up or FD.Down)
    container:SetAuraLayoutPadding(0, 0, 0, 0)
    local rowWidth
    if column then
        rowWidth = L.iconSize                 -- wrap after every icon → column
    elseif L.maxPerRow and L.maxPerRow > 0 then
        rowWidth = L.maxPerRow * L.iconSize + (L.maxPerRow - 1) * L.spacing + 0.5
    end
    container:SetAuraLayoutRowWidth(rowWidth) -- nil → no wrap (math.huge)
end

-- Per-group flow contribution: spacing + explicit element size.
local function GroupLayout(L)
    return {
        elementSpacingX = L.spacing,
        elementSpacingY = L.spacing,
        elementWidth    = L.iconSize,
        elementHeight   = L.iconSize,
    }
end

-- Per-group initializeFrame: the engine securecallfunction()s this once per
-- button it creates (batches of 10; one batch pre-allocated at AddAuraGroup).
-- Style reads container._quiProfile at call time so buttons born after a
-- settings change pick up the current profile. cancelButtons is a STRING of
-- RegisterForClicks tokens (e.g. "RightButtonUp"); cancel itself runs in the
-- button intrinsic via C_UnitAuras.CancelAuraByInstanceID — combat-legal, no
-- secure header.
local function MakeInitializer(container, groupDesc)
    local cancel = groupDesc.cancelButtons
    return function(button)
        buildButtonArt(button)
        styleButton(button, container._quiProfile or {})
        if cancel and button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(cancel)
        end
        local reg = container._quiButtons
        if not reg then
            reg = {}
            container._quiButtons = reg
        end
        if not button._quiTracked then
            button._quiTracked = true
            reg[#reg + 1] = button
        end
    end
end

-- Configure: reconcile this container's aura groups + grid shape.
-- PTR4 groups can NEVER be removed by addons (the group-clearing API is
-- private-mixin-only, not addon-callable) and a group's filter string is
-- immutable — so the registry key embeds the filter string: any filter
-- change lands on a fresh key, the old key is retired to zero frames, and
-- repeat Configures with the same settings only touch the mutators. The
-- consumer keeps SetUnit (MUST run before Configure — group registration
-- eagerly parses auras), SetEnabled/Show/Hide, and container anchoring.
-- NOT combat-safe by contract: consumers pcall this in combat and fall back
-- to Restyle + an OOC replay queue.
function AuraSkin.Configure(container, profile, groups)
    local L = ResolveLayout(profile)
    container._quiProfile = profile
    local registered = container._quiGroups
    if not registered then
        registered = {}
        container._quiGroups = registered
    end
    local wanted = {}
    for i = 1, #groups do
        local g = groups[i]
        local gkey = g.key or ""
        -- "|" is the composite-key separator; a "|" inside g.key would let two
        -- distinct (key, filter) pairs collapse onto one registry entry and
        -- silently clobber each other's group.
        assert(not gkey:find("|", 1, true),
            "AuraSkin group key must not contain '|'")
        local key = gkey .. "|" .. g.filter
        wanted[key] = true
        local maxCount   = g.maxFrameCount or L.maxIcons
        local sortMethod = g.sortMethod or AuraContainerSortMethod.Default
        local sortDir    = g.sortDirection or AuraContainerSortDirection.Normal
        -- HasAuraGroup heals registry desync: a prior AddAuraGroup may have
        -- registered engine-side but thrown before our bookkeeping ran.
        if registered[key] or container:HasAuraGroup(key) then
            container:SetAuraGroupMaxFrameCount(key, maxCount)
            container:SetAuraGroupSortMethod(key, sortMethod, sortDir)
            container:SetAuraGroupCandidateFilters(key, g.candidateFilters)
            container:SetAuraGroupLayout(key, GroupLayout(L))
            registered[key] = true
        elseif not InCombatLockdown() then
            container:AddAuraGroup(key, g.filter, {
                maxFrameCount    = maxCount,
                sortMethod       = sortMethod,
                sortDirection    = sortDir,
                candidateFilters = g.candidateFilters,
                initializeFrame  = MakeInitializer(container, g),
                layout           = GroupLayout(L),
            })
            registered[key] = true
        end
        -- (in combat with an unregistered key: skip — AddAuraGroup runs
        -- frameProvider:CreateFrameBatch() synchronously, i.e. forbidden
        -- frame creation in combat. Consumers queue an OOC replay, so the
        -- group materializes at regen.)
    end
    -- Retire groups no longer wanted: unremovable, so show zero frames.
    for key in pairs(registered) do
        if not wanted[key] then
            container:SetAuraGroupMaxFrameCount(key, 0)
        end
    end
    ApplyContainerLayout(container, L)

    -- Re-style every button we've seen so an OOC config change (border,
    -- font, swipe, icon size) propagates without a /reload — initializeFrame
    -- only styles a button at birth.
    local reg = container._quiButtons
    if reg then
        for i = 1, #reg do
            local button = reg[i]
            if button then
                styleButton(button, profile)
            end
        end
    end
end

-- Restyle: combat-legal subset — re-apply fonts/colors/swipe to every
-- engine-created button we've seen. No layout (engine-owned), no group changes.
function AuraSkin.Restyle(container, profile)
    container._quiProfile = profile
    local reg = container._quiButtons
    if not reg then return end
    for i = 1, #reg do
        local button = reg[i]
        if button then
            styleButton(button, profile)
        end
    end
end
