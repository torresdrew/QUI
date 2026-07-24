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

-- 68675: the frame provider applies DenyTaintedAccessWhenAurasAreSecret to
-- every AuraButton child IMMEDIATELY AFTER initializeFrame
-- (Blizzard_AuraContainerFrameProviders.lua CreateFrame). Birth styling
-- inside initializeFrame is therefore always safe; any LATER tainted call
-- on a button (restyle, SetCancelAuraButtons) hard-errors while
-- ShouldAurasBeSecret() is true. Every post-birth button pass below gates
-- on this and reschedules via ScheduleRestrictedRestyle — there is NO
-- restriction-end event, so a short poll re-checks until it clears.
local function AurasAreSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

local _restrictedRestyle = {}   -- container -> true
local _restrictedPollArmed = false
local function ScheduleRestrictedRestyle(container)
    _restrictedRestyle[container] = true
    if _restrictedPollArmed then return end
    local After = C_Timer and C_Timer.After
    if not After then return end
    _restrictedPollArmed = true
    local function tick()
        if AurasAreSecret() then
            After(0.5, tick)
            return
        end
        _restrictedPollArmed = false
        local run = _restrictedRestyle
        _restrictedRestyle = {}
        for c in pairs(run) do
            if c._quiProfile then
                AuraSkin.Restyle(c, c._quiProfile)
            end
        end
    end
    After(0.5, tick)
end

-- ns.AuraElements, resolved lazily: TOC order loads this file BEFORE
-- core/aura_elements.lua (QUI.toc lists aura_skin.lua ahead of
-- aura_elements.lua), so it must not be captured at file-load time — only
-- read the first time Configure actually runs, by which point the whole
-- core/ slice is loaded. Mirrors core/aura_glue.lua's ResolveE.
local AuraElements
local function ResolveAuraElements()
    AuraElements = AuraElements or ns.AuraElements
    return AuraElements
end

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
-- count.  AddDispelTypeTexture DOES securecopy its options, so its field writes are
-- safe; ApplyDispelTypeTextures reads the secret dispel fields secure-side.  Both run
-- inside the secure apply where secret compares are allowed — the earlier "blank" was
-- the unsized container, not these setters.
local function buildButtonArt(button)
    if button._quiWired then return end
    button._quiWired = true

    -- Static QUI border: a plain QUI-owned texture (NOT the secure dispel texture),
    -- coloured by styleButton.  Aura-data-INDEPENDENT.  BACKGROUND (below the icon);
    -- shown as the neutral ring on buffs / non-dispel debuffs.
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(button)
    button._quiBorder = border

    -- Dispel overlay border (BORDER layer, above the static border, below the
    -- icon).  Only the TEXTURE is created here; the engine registration
    -- (AddDispelTypeTexture) + its options (dispelColors/dispelAssets) live in
    -- styleButton so profile changes re-apply to live buttons.  The engine
    -- vertex-colours it by dispel type and shows it only on dispellable
    -- HARMFUL auras, covering the static ring with the dispel colour.  A white
    -- base texture is required so the vertex colour is visible.
    -- (SetAuraBorder survives at 68914 only as a compat shim —
    -- ClearDispelTypeTextures + AddDispelTypeTexture, removed after 12.1.)
    local dispel = button:CreateTexture(nil, "BORDER")
    dispel:SetAllPoints(button)
    dispel:SetColorTexture(1, 1, 1, 1)
    if dispel.DisablePixelSnap then dispel:DisablePixelSnap() end
    button._quiDispel = dispel

    -- Icon (ARTWORK, inset 1px so the border shows as a ring).  Cropped 8% per
    -- edge to cut the bevel baked into icon art (engine's ApplyIcon only calls
    -- SetTexture on it, never texcoords, so this one-time crop sticks).
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.Icon = icon
    button:SetIcon(icon)

    -- Dispel text symbol. The engine only shows it when Blizzard's colorblind
    -- mode asks for it, so wiring this is visually inert for the normal case but
    -- uses the 12.1 secure-side symbol path when needed.  (SetAuraSymbol is a
    -- deprecated alias of SetDispelTypeText at 68914, removed after 12.1.)
    local symbol = button:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
    symbol:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    button._quiSymbol = symbol
    button:SetDispelTypeText(symbol, {
        showWhenHarmful = true,
        showWhenHelpful = false,
    })

    -- Duration cooldown swipe (frame child).
    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(button)
    cd:SetHideCountdownNumbers(true)
    button._quiCooldown = cd
    button:SetDurationCooldown(cd)

    -- Linear duration fill (StatusBar child), created at BIRTH like every
    -- other art piece: initializeFrame runs pre-restriction, so a mid-combat
    -- or mid-secrecy birth still gets the child. styleButton's linear branch
    -- (and aura_slots StyleSlot, which routes through WireButton) only WIRES
    -- it — child creation on a restricted button post-birth is not possible,
    -- and a missing fill on a combat-born button would otherwise be
    -- unrecoverable until some later OOC pass (stop-gate 2026-07-24).
    -- Hidden until a linear swipeStyle wants it; SetDurationBar wiring stays
    -- style-time. Footprint: SetAllPoints(button), default child frame level
    -- — a child frame draws above ALL parent-owned regions, so the fill sits
    -- above the icon exactly like the native radial Cooldown swipe; the
    -- StatusBar only paints its FILLED portion, so the icon shows through
    -- the depleted part.
    local fill = CreateFrame("StatusBar", nil, button)
    fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetAllPoints(button)
    fill:Hide()
    button._quiDurationBar = fill

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

    -- PTR7 per-button tooltip controls (68824+ AuraButton API; feature-
    -- detected so headless mocks without them keep working). Values are
    -- GameTooltip anchor TOKENS ("ANCHOR_TOPRIGHT", ...) — the setter
    -- hard-asserts on anything else (Blizzard_AuraButton.lua:53), hence the
    -- pcall: a stale/imported profile string must not error every style
    -- pass. There is no nil-reset API and the template pre-seeds a REAL
    -- default (ANCHOR_BOTTOMLEFT,0,0 KeyValues, Blizzard_AuraButton.xml:11-13),
    -- so the pre-override triple is cached ONCE via GetTooltipAnchorPoint and
    -- restored when the override clears. _quiTipAnchored is set only on a
    -- SUCCESSFUL set — a rejected token must not mark the button customized
    -- (first-set failure) nor un-mark a previously applied custom anchor
    -- (later-pass failure), so it is left untouched on pcall failure.
    if button.SetTooltipAnchorPoint then
        if profile.tooltipAnchor then
            if not button._quiTipPrev and button.GetTooltipAnchorPoint then
                button._quiTipPrev = { button:GetTooltipAnchorPoint() }
            end
            local ok = pcall(button.SetTooltipAnchorPoint, button, profile.tooltipAnchor,
                profile.tooltipAnchorX or 0, profile.tooltipAnchorY or 0)
            if ok then button._quiTipAnchored = true end
        elseif button._quiTipAnchored then
            local prev = button._quiTipPrev
            pcall(button.SetTooltipAnchorPoint, button,
                (prev and prev[1]) or "ANCHOR_BOTTOMLEFT",
                (prev and prev[2]) or 0, (prev and prev[3]) or 0)
            button._quiTipAnchored = nil
        end
    end
    if button.SetHideTooltipInCombat then
        button:SetHideTooltipInCombat(profile.tooltipHideInCombat == true)
    end

    -- Dispel ring options (dispelColors palette / dispelAssets custom
    -- textures) apply HERE, not at button birth, so an options change
    -- restyles live buttons: Clear + Add mirrors the engine's own
    -- SetAuraBorder shim shape, and the Add's UpdateAuraDisplay re-renders.
    -- Unchecking an override naturally resets — the fresh options table
    -- simply omits the map. AddDispelTypeTexture securecopies its options,
    -- so passing addon tables (and nested color/asset tables) is safe.
    local dispel = button._quiDispel
    if dispel and button.ClearDispelTypeTextures and button.AddDispelTypeTexture then
        local borderOpts = {
            style = 3,              -- CustomAuraButtonDispelTypeTextureStyle.PreserveAsset
            showWhenHarmful = true, -- (secure-env enum; mirror value). PreserveAsset keeps
            showWhenHelpful = false, -- QUI's white texture, engine vertex-colors it.
        }
        if type(profile.dispelColors) == "table" then
            borderOpts.customDispelColorMap = profile.dispelColors
        end
        -- customDispelAssetMap only applies under the CustomAsset style (4);
        -- dispelColors still composes — the engine applies the custom vertex
        -- colour after styling the asset.
        if type(profile.dispelAssets) == "table" then
            borderOpts.style = 4    -- CustomAuraButtonDispelTypeTextureStyle.CustomAsset
            borderOpts.customDispelAssetMap = profile.dispelAssets
        end
        button:ClearDispelTypeTextures()
        button:AddDispelTypeTexture(dispel, borderOpts)
    end

    -- Static QUI border: per-element override when set, else theme color.
    -- borderColor is optional on the element (absent = theme) — the seeded
    -- group-frames "defensives" strip ships green via this field.
    local border = button._quiBorder
    if border then
        local bc = profile.borderColor
        local r, g, b, a
        if type(bc) == "table" then
            r, g, b, a = bc[1] or 1, bc[2] or 1, bc[3] or 1, bc[4]
        else
            r, g, b, a = AuraTheme.BorderColor()
        end
        border:SetColorTexture(r, g, b, a or 1)
        if border.DisablePixelSnap then border:DisablePixelSnap() end
    end

    -- Text regions: duration + stack. The element model carries per-region
    -- config (duration{} / stack{}); fall back to the legacy flat fontSize so
    -- pre-migration profiles and non-element callers keep rendering.
    local fontPath = (Helpers and Helpers.GetGeneralFont and Helpers.GetGeneralFont())
    local fontFlags = (Helpers and Helpers.GetGeneralFontOutline and Helpers.GetGeneralFontOutline()) or "OUTLINE"
    local function styleText(fs, cfg, fallbackSize, defAnchor, defX, defY)
        if not fs then return end
        local size = (cfg and cfg.fontSize) or fallbackSize or 11
        if size <= 0 then size = 11 end
        if fontPath then fs:SetFont(fontPath, size, fontFlags) end
        fs:ClearAllPoints()
        fs:SetPoint((cfg and cfg.anchor) or defAnchor, button, (cfg and cfg.anchor) or defAnchor,
            (cfg and cfg.offsetX) or defX, (cfg and cfg.offsetY) or defY)
        local c = cfg and cfg.color
        if c then fs:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1) end
        fs:SetAlpha(cfg and cfg.show == false and 0 or 1)
    end
    styleText(button._quiDuration, profile.duration, profile.fontSize, "CENTER", 0, 0)
    styleText(button._quiCount, profile.stack, profile.fontSize, "BOTTOMRIGHT", -1, 1)
    if fontPath and button._quiSymbol then button._quiSymbol:SetFont(fontPath, (profile.fontSize and profile.fontSize > 0) and profile.fontSize or 11, fontFlags) end

    -- Swipe (config on the Cooldown — appearance, not aura data). Linear
    -- ("horizontal"/"vertical") ports StyleSlot's linear branch
    -- (aura_slots.lua:93-134) onto group/strip buttons: group-created
    -- buttons get CustomAuraButtonTemplate the same as slot frames
    -- (Blizzard_CustomAuraContainer.lua AddAuraGroup and CreateAuraSlotFrame
    -- both prepend it via CreateCustomFrameProvider,
    -- Blizzard_AuraContainerFrameProviders.lua:34), which always inherits
    -- CustomAuraButtonInboundMixin = CreateFromMixins(CustomAuraButtonSharedMixin)
    -- (Blizzard_CustomAuraButton.xml:5-8) — the SAME mixin that defines
    -- SetDurationBar (Blizzard_CustomAuraButton.lua:183) already relied on
    -- for SetDurationCooldown above. So button:SetDurationBar is available
    -- here exactly like it is on slot frames.
    local cd = button._quiCooldown
    local wantsLinear = profile.swipeStyle == "horizontal" or profile.swipeStyle == "vertical"
    if wantsLinear and button.SetDurationBar then
        if cd and cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
        local fill = button._quiDurationBar
        if not fill and InCombatLockdown() then
            -- Belt only: buildButtonArt creates the fill at birth on every
            -- wired button, so this fires solely for a foreign/legacy button
            -- — never create a child on a restricted button post-birth; the
            -- next OOC pass re-covers it.
            return
        end
        if not fill then
            fill = CreateFrame("StatusBar", nil, button)
            fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
            fill:SetAllPoints(button)
            button._quiDurationBar = fill
        end
        -- Re-called EVERY style pass (Configure/Restyle), not just at
        -- creation, so a Reverse Swipe / style toggle takes effect without a
        -- reload — same as StyleSlot.
        button:SetDurationBar(fill, {
            direction = (profile.reverseSwipe and Enum.StatusBarTimerDirection.ElapsedTime)
                or Enum.StatusBarTimerDirection.RemainingTime,
            interpolation = Enum.StatusBarInterpolation.Immediate,
        })
        fill:SetOrientation(profile.swipeStyle == "vertical" and "VERTICAL" or "HORIZONTAL")
        -- No per-strip color source exists on the ElementProfile contract
        -- (aura_glue.lua G.ElementProfile has no `color` field — unlike
        -- StyleSlot's `element.color`, which is a per-slot-element field
        -- with no strip-art analogue) — leave the WHITE8x8 texture
        -- untinted rather than inventing a source StyleSlot doesn't share.
        fill:Show()
    else
        if button._quiDurationBar then button._quiDurationBar:Hide() end
        if cd then
            cd:SetDrawSwipe(profile.hideSwipe ~= true)
            cd:SetReverse(profile.reverseSwipe == true)
            cd:SetHideCountdownNumbers(true)
        end
    end
end

-- Map the QUI grow vocabulary onto the 68914-re-patch flow layout
-- (Blizzard_AuraContainerFlowLayout.lua: SetFlowLayoutAnchorPoint /
-- SetFlowLayoutGrowthDirection(h, v) with AnchorUtil.FlowDirection
-- {Left=-1, Right=1, Up=1, Down=-1} / SetFlowLayoutAxis
-- {Horizontal=0, Vertical=1} / SetFlowLayoutMaximumLineSize in PIXELS,
-- nil = no wrap). Column-primary growth (grow UP/DOWN) is now NATIVE:
-- axis=Vertical flows icons down/up a column and maxPerRow caps icons
-- per column, so a multi-column vertical grid finally works (the old
-- row-major SetAuraLayoutRowWidth API degraded it to a single column).
-- Flow derivation: primary axis from grow (RIGHT/LEFT = rows; UP/DOWN =
-- columns), wrap axis from profile.wrap ("UP" wraps upward, default
-- "DOWN" — buffborders sets wrap from its growUp toggle). The flow
-- origin corner combines both.
local function FlowFor(L)
    -- CENTER has no native flow direction (SetFlowLayoutAnchorPoint only
    -- accepts corners) — it behaves as a RIGHT-growing row internally; the
    -- container auto-sizes, and LayoutAnchor pins that auto-sized rect's
    -- CENTER to the host so the row reads as centered overall.
    local grow = L.grow == "CENTER" and "RIGHT" or L.grow
    local column = (grow == "UP" or grow == "DOWN")
    local left = (grow == "LEFT")
    local up
    if column then up = (grow == "UP") else up = (L.wrap == "UP") end
    local anchor = (up and "BOTTOM" or "TOP") .. (left and "RIGHT" or "LEFT")
    return anchor, left, up, column
end

-- The point consumers pin in their SetPoint. Ordinarily this IS the container
-- corner the grid flows from, so the auto-sized rect grows away from the
-- pinned spot. CENTER grow is the one exception: the engine flow layout has
-- no center flow, so FlowFor still derives a corner for the engine, but the
-- consumer instead pins the auto-sized container's OWN center to the host —
-- that centers the whole row without any engine-side center flow.
function AuraSkin.LayoutAnchor(profile)
    local L = ResolveLayout(profile)
    if L.grow == "CENTER" then
        return "CENTER"
    end
    local anchor = FlowFor(L)
    return anchor
end

local function ApplyContainerLayout(container, L)
    local anchor, left, up, column = FlowFor(L)
    local FD = AnchorUtil.FlowDirection
    local AX = AnchorUtil.FlowLayoutAxis
    container:SetFlowLayoutAnchorPoint(anchor)
    container:SetFlowLayoutGrowthDirection(
        left and FD.Left or FD.Right,
        up and FD.Up or FD.Down)
    container:SetFlowLayoutPadding(0, 0, 0, 0)
    container:SetFlowLayoutAxis(column and AX.Vertical or AX.Horizontal)
    -- Line cap along the PRIMARY axis: rows cap at maxPerRow icons wide,
    -- columns cap at maxPerRow icons tall (both dims are iconSize squares).
    local lineSize
    if L.maxPerRow and L.maxPerRow > 0 then
        lineSize = L.maxPerRow * L.iconSize + (L.maxPerRow - 1) * L.spacing + 0.5
    end
    container:SetFlowLayoutMaximumLineSize(lineSize) -- nil → no wrap (math.huge)
end

-- Per-group flow contribution: spacing + explicit element size.
local function GroupLayout(L, g)
    local t = {
        elementSpacing = L.spacing,   -- 68914 re-patch renamed the spacing
        lineSpacing    = L.spacing,   -- keys (was elementSpacingX/Y)
        elementWidth   = L.iconSize,
        elementHeight  = L.iconSize,
    }
    -- 68824: explicit ordering. Registration order was the implicit order;
    -- layoutIndex pins it so a fallback-path re-registration (new composite
    -- key appends LAST) can no longer reorder groups visually.
    if g and type(g._quiOrder) == "number" then
        t.layoutIndex = g._quiOrder
    end
    return t
end

-- Per-group initializeFrame: the engine securecallfunction()s this once per
-- button it creates (batches of 10; one batch pre-allocated at AddAuraGroup),
-- and the SAME closure persists for the group's entire lifetime — addons can
-- never replace it (groups are unremovable, PTR4 contract). So this must NOT
-- close over groupDesc.cancelButtons as a frozen value: a later right-click-
-- cancel toggle would never reach a batch-later button born from this stale
-- closure. Instead read container._quiCancelButtons (latched by Configure,
-- see below) at CALL time, so every button — however late it's born — picks
-- up whatever is current. Style reads container._quiProfile the same way, for
-- the same reason. cancelButtons is a STRING of RegisterForClicks tokens
-- (e.g. "RightButtonUp"); nil clears click registration (Blizzard_AuraButton.lua
-- SetCancelAuraButtons: nil -> RegisterForClicks() with no args). Cancel
-- itself runs in the button intrinsic via C_UnitAuras.CancelAuraByInstanceID
-- — combat-legal, no secure header.
local function MakeInitializer(container, _groupDesc)
    return function(button)
        buildButtonArt(button)
        styleButton(button, container._quiProfile or {})
        if button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(container._quiCancelButtons)
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

-- Iterate every live engine button. 68824+ containers expose sanctioned
-- enumeration (GetAuraGroupFrame/GetAuraGroupFrameCount); older containers
-- fall back to the birth-time _quiButtons registry MakeInitializer maintains.
-- Item-enchant frames are NOT group members — they only exist in the
-- registry, so the engine path also walks the registry for any button not
-- yet seen (dedup via button._quiTracked is already set at birth).
local function EachTrackedButton(container, fn)
    local seen
    if container.GetAuraGroupFrame and container.GetAuraGroupFrameCount then
        seen = {}
        local registered = container._quiGroups
        if registered then
            for key in pairs(registered) do
                local count = container:GetAuraGroupFrameCount(key)
                for i = 1, count or 0 do
                    local button = container:GetAuraGroupFrame(key, i)
                    if button then
                        seen[button] = true
                        fn(button)
                    end
                end
            end
        end
    end
    local reg = container._quiButtons
    if reg then
        for i = 1, #reg do
            local button = reg[i]
            if button and not (seen and seen[button]) then
                fn(button)
            end
        end
    end
end

-- Configure: reconcile this container's aura groups + grid shape.
-- 68824+: SetAuraGroupFilterString lets a group's filter mutate in place, so
-- capable containers (canMutateFilter below) register with the BARE group
-- key and a filter change is an in-place rewrite — no new group, no leak.
--
-- PRE-68824 FALLBACK: PTR4 groups can NEVER be removed by addons (the
-- group-clearing API is private-mixin-only, not addon-callable) and a
-- group's filter string is immutable — so the registry key embeds the
-- filter string: any filter change lands on a fresh key, the old key is
-- retired to zero frames, and repeat Configures with the same settings only
-- touch the mutators. The consumer keeps SetUnit (MUST run before Configure
-- — group registration eagerly parses auras), SetEnabled/Show/Hide, and
-- container anchoring.
--
-- KNOWN RESOURCE BOUND (fallback path only, accepted): each NEVER-BEFORE-
-- SEEN canonical filter string permanently costs one engine frame provider
-- + one eager frame batch (FrameCreationBatchSize = 10 buttons) per live
-- container until /reload — pre-68824 Blizzard exposes no group removal.
-- Growth is bounded by DISTINCT filter strings ever configured, NOT by
-- change count: a returning string reuses its still-registered key below
-- (registered[key] persists through retire), so cycling A→B→A stabilizes at
-- two groups. Worst realistic case is a user iterating novel filter edits on
-- a 40-frame raid surface; a /reload reclaims everything. Capable (68824+)
-- containers never hit this bound at all — SetAuraGroupFilterString rewrites
-- the SAME group in place, so the key set is bounded by group COUNT, not by
-- every filter string ever seen.
-- NOT combat-safe by contract: consumers pcall this in combat and fall back
-- to Restyle + an OOC replay queue.
function AuraSkin.Configure(container, profile, groups)
    local L = ResolveLayout(profile)
    container._quiProfile = profile
    -- Latch the current right-click-cancel setting on the CONTAINER, not the
    -- per-group descriptor: groups are unremovable and a group's
    -- initializeFrame closure can't be swapped, so this is the only place a
    -- later toggle can reach an existing group's buttons (MakeInitializer
    -- reads this at button-birth time; the restyle loop below and Restyle
    -- re-assert it on every button already born). AuraGlue.ElementGroups
    -- gives every group in one element's array the SAME cancel value (single
    -- `cancel` local closes over all of them) — "last non-nil wins" is just
    -- defensive uniformity, not a real per-group split.
    local cancel
    for i = 1, #groups do
        local c = groups[i].cancelButtons
        if c then cancel = c end
    end
    container._quiCancelButtons = cancel
    local registered = container._quiGroups
    if not registered then
        registered = {}
        container._quiGroups = registered
    end
    local wanted = {}
    local E = ResolveAuraElements()
    -- 68824+: SetAuraGroupFilterString exists → filters mutate in place, so
    -- the registry key can be the bare group key (see header). Probed once
    -- per Configure call, not per group — the container's capability can't
    -- change mid-loop.
    local canMutateFilter = container.SetAuraGroupFilterString ~= nil
    for i = 1, #groups do
        local g = groups[i]
        -- Registration order (the caller's array order) was always the
        -- IMPLICIT visual order; stamp it explicitly onto the descriptor so
        -- GroupLayout can pin it via layoutIndex — see GroupLayout's header
        -- for why this matters on the fallback path.
        g._quiOrder = i
        local gkey = g.key or ""
        -- "|" is the composite-key separator; a "|" inside g.key would let two
        -- distinct (key, filter) pairs collapse onto one registry entry and
        -- silently clobber each other's group.
        assert(not gkey:find("|", 1, true),
            "AuraSkin group key must not contain '|'")
        -- Canonicalize the filter string HERE, at the composite-key choke
        -- point, regardless of whether the caller already did (AuraGlue.
        -- ElementGroups does — see its comment): this is the ONE place
        -- named in the file header where "every DISTINCT string retains a
        -- group until reload" bites, so it gets its own defensive pass.
        -- CanonicalizeFilterString is idempotent — re-canonicalizing an
        -- already-canonical string is a cheap no-op, never a bug. The
        -- canonical form is what gets REGISTERED with the engine too (not
        -- just hashed into the key), so a group's own immutable filter
        -- string is always the canonical one.
        local filter = (E and E.CanonicalizeFilterString) and E.CanonicalizeFilterString(g.filter) or g.filter
        -- 68824+: group filters are mutable (SetAuraGroupFilterString), so the
        -- registry key is the BARE group key and a filter change is an
        -- in-place rewrite — the composite-key retire scheme (and its
        -- accepted frame-provider leak, see header) only applies to
        -- pre-68824 containers.
        local key = canMutateFilter and gkey or (gkey .. "|" .. filter)
        wanted[key] = true
        local maxCount   = g.maxFrameCount or L.maxIcons
        local sortMethod = g.sortMethod or AuraContainerSortMethod.Default
        local sortDir    = g.sortDirection or AuraContainerSortDirection.Normal
        -- HasAuraGroup heals registry desync: a prior AddAuraGroup may have
        -- registered engine-side but thrown before our bookkeeping ran.
        if registered[key] or container:HasAuraGroup(key) then
            if canMutateFilter and registered[key] ~= filter then
                container:SetAuraGroupFilterString(key, filter)
            end
            container:SetAuraGroupMaxFrameCount(key, maxCount)
            container:SetAuraGroupSortMethod(key, sortMethod, sortDir)
            container:SetAuraGroupCandidateFilters(key, g.candidateFilters)
            container:SetAuraGroupLayout(key, GroupLayout(L, g))
            registered[key] = filter
        else
            -- AddAuraGroup (frameProvider:CreateFrameBatch() included) is
            -- combat-legal since PTR7 68914 — earlier 12.1 builds crashed the
            -- client on in-combat creation; proven in-game 2026-07-24.
            -- initializeFrame runs BEFORE the 68675 access restrictions apply
            -- (see aura_slots.lua birth-path note), so this is safe under
            -- aura secrecy too.
            container:AddAuraGroup(key, filter, {
                maxFrameCount    = maxCount,
                sortMethod       = sortMethod,
                sortDirection    = sortDir,
                candidateFilters = g.candidateFilters,
                initializeFrame  = MakeInitializer(container, g),
                layout           = GroupLayout(L, g),
            })
            registered[key] = filter
        end
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
    -- only styles a button at birth. Skipped while auras are secret (68675
    -- restricted children, see AurasAreSecret above); buttons keep their
    -- birth styling and the pass replays once the restriction clears.
    if AurasAreSecret() then
        ScheduleRestrictedRestyle(container)
        return
    end
    EachTrackedButton(container, function(button)
        styleButton(button, profile)
        if button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(container._quiCancelButtons)
        end
    end)
end

-- Restyle: combat-legal subset — re-apply fonts/colors/swipe to every
-- engine-created button we've seen. No layout (engine-owned), no group
-- changes. Takes no groups argument, so it re-asserts whatever cancel state
-- Configure last latched onto the container (_quiCancelButtons) rather than
-- re-deriving it — this is the path a combat-blocked Configure falls back to
-- (AuraGlue.RunConfigPass), so a right-click-cancel toggle still reaches
-- live buttons even when the full reconcile is skipped.
function AuraSkin.Restyle(container, profile)
    container._quiProfile = profile
    -- 68675: button writes hard-error on restricted children while auras
    -- are secret — defer to the restriction-clear poll instead. (This was
    -- the "combat-legal" fallback path; combat legality no longer implies
    -- child-access legality.)
    if AurasAreSecret() then
        ScheduleRestrictedRestyle(container)
        return
    end
    EachTrackedButton(container, function(button)
        styleButton(button, profile)
        if button.SetCancelAuraButtons then
            button:SetCancelAuraButtons(container._quiCancelButtons)
        end
    end)
end

-- Register the three weapon temp-enchant displays on a container (PTR4
-- AddItemEnchantment) and (re)apply their flow layout. The engine renders
-- them inline with the aura flow (BeforeAuraGroups = enchants lead the row)
-- and self-drives updates from weapon-enchant state — no addon events.
-- Registration is add-once per container lifetime: there is NO remove API
-- (same retirement semantics as aura groups) and AddItemEnchantment asserts
-- on a duplicate slot. hidePermanent keeps parity with the old
-- GetWeaponEnchantInfo strip (temp enchants only). The layout call is a
-- plain mutator and re-runs every pass so icon size/spacing changes apply.
-- First call creates forbidden frames → OOC only; callers pcall + queue.
function AuraSkin.ConfigureEnchantments(container, profile)
    local slots = _G.AuraContainerItemEnchantmentSlot
    local placement = _G.CustomAuraContainerItemEnchantmentPlacement
    if not (slots and placement and container.AddItemEnchantment) then
        return false
    end
    -- Stamp the profile BEFORE AddItemEnchantment: frame creation is
    -- synchronous and the initializer styles via container._quiProfile.
    container._quiProfile = profile
    local L = ResolveLayout(profile)
    container:SetItemEnchantmentLayout({
        placement      = placement.BeforeAuraGroups,
        elementSpacing = L.spacing,   -- 68914 re-patch key rename
        lineSpacing    = L.spacing,   -- (was elementSpacingX/Y)
        elementWidth   = L.iconSize,
        elementHeight  = L.iconSize,
    })
    -- 68824: temp weapon enchants support native click-to-cancel — the same
    -- RegisterForClicks tokens as aura buttons. Re-assert on every pass so a
    -- cancel toggle reaches enchant frames born on an earlier pass.
    -- 68675: button writes hard-error on restricted children while auras are
    -- secret (same restriction Configure/Restyle gate on) — skip the
    -- re-assert during a secret window; the OOC restriction-clear replay
    -- (ScheduleRestrictedRestyle) re-covers this pass once auras clear.
    if not AurasAreSecret() then
        local reg = container._quiButtons
        if reg then
            for i = 1, #reg do
                local b = reg[i]
                if b and b.SetCancelAuraButtons then
                    b:SetCancelAuraButtons(container._quiCancelButtons)
                end
            end
        end
    end
    if not container._quiEnchantsAdded then
        local init = MakeInitializer(container, {})
        for _, slot in ipairs({ slots.MainHand, slots.OffHand, slots.Ranged }) do
            container:AddItemEnchantment(slot, {
                initializeFrame = init,
                hidePermanent   = true,
            })
        end
        container._quiEnchantsAdded = true
    end
    return true
end

-- Wire + style ONE engine-created aura frame outside the group
-- initializeFrame path — AddAuraSlot returns its frame directly, so the slot
-- runtime (core/aura_slots.lua) calls this on the returned frame. Same art,
-- same styling, same forbidden-object legality class as the group path.
function AuraSkin.WireButton(button, profile)
    buildButtonArt(button)
    styleButton(button, profile or {})
end
