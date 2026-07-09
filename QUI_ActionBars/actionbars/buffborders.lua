-- buffborders.lua
-- Player buff/debuff icon display on Blizzard's secure CustomAuraContainer
-- model (the SAME path the unit/group frames use via QUI.AuraSkin). QUI exposes
-- two named anchor frames (QUI_BuffIconContainer and QUI_DebuffIconContainer)
-- on UIParent; each owns its own forbidden AuraContainer
-- ("CustomAuraContainerTemplate") that QUI.AuraSkin pools CustomAuraButtons onto.
-- The container self-drives UNIT_AURA and renders aura DATA C-side (secret-safe).
-- CREATION of the forbidden container/buttons is combat-restricted (combat
-- creation crashes the 12.1 client) and stays deferred to PLAYER_REGEN_ENABLED;
-- MUTATION of pre-created objects (anchor/size/groups/enable) is combat-legal
-- (pcall-guarded — PTR4 may still restrict group mutation in combat), so
-- config changes apply live in combat and the full pass still replays at
-- regen.
--
-- Right-click cancel of own buffs is engine-owned per PTR4: the buff group is
-- registered with cancelButtons (a RegisterForClicks token string), and each
-- CustomAuraButton cancels itself via SetCancelAuraButtons/
-- C_UnitAuras.CancelAuraByInstanceID internally. QUI never scripts the
-- forbidden CustomAuraButtons and never calls CancelUnitBuff directly.
--
-- TEMP WEAPON ENCHANTS render inside the buff container itself (PTR4
-- AddItemEnchantment, placement=BeforeAuraGroups): the engine owns their
-- frames, updates and flow position — no addon events, no lead-in offset.
-- Known gap: the engine click-cancel path is auraInstanceID-only and
-- no-ops for enchants, so right-click cancel of a temp enchant is
-- unavailable until Blizzard wires their own enchant-cancel TODO.

local _, ns = ...
local Helpers = ns.Helpers

-- Aura skin (shared secure container adapter — the SINGLE path that touches the
-- forbidden CustomAuraButton inbound API). Re-resolved in ResolveAuraDeps in
-- case core/aura_skin.lua loaded after this file's top-level chunk.
local AuraSkin = (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
-- Shared element-model core (core/aura_elements, aura_glue, aura_slots): the ONE
-- copy of the element schema + settings→container glue every QUI aura surface
-- uses. Resolved lazily via ResolveAuraDeps (TOC order loads QUI core first, but
-- stay defensive across sub-addon load timing).
local E = ns.AuraElements or (_G.QUI and _G.QUI.AuraElements)
local G = ns.AuraGlue    or (_G.QUI and _G.QUI.AuraGlue)
local S = ns.AuraSlots   or (_G.QUI and _G.QUI.AuraSlots)

-- Upvalue caching
local type = type
local ipairs = ipairs
local pcall = pcall
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

---------------------------------------------------------------------------
-- DEFAULTS
---------------------------------------------------------------------------
local DEFAULTS = {
    enableBuffs = true,
    enableDebuffs = true,
    showBuffBorders = true,
    showDebuffBorders = true,
    hideBuffFrame = false,
    hideDebuffFrame = false,
    fadeBuffFrame = false,
    fadeDebuffFrame = false,
    fadeOutAlpha = 0,
    externalSkinning = false,
    iconSkin = "Default",
    borderSize = 2,
    fontSize = 12,
    fontOutline = true,
    showStacks = true,
    hideSwipe = false,
}

local function GetSettings()
    return Helpers.GetModuleSettings("buffBorders", DEFAULTS)
end

---------------------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------------------
-- The fixed per-zone icon cap. Mirrors Blizzard's BUFF_MAX_DISPLAY /
-- DEBUFF_MAX_DISPLAY; the container's maxFrameCount caps how many of the pooled
-- AuraSkin buttons render, and AuraSkin pools exactly this many.
local BUFF_MAX_DISPLAY = 40
local DEBUFF_MAX_DISPLAY = 40

---------------------------------------------------------------------------
-- ELEMENT-MODEL CORE (shared aura_elements / aura_glue / aura_slots)
--
-- The two hosts (buff mover / debuff mover) each render a per-element bucket
-- STORE under the SAME container contract every QUI aura surface uses:
--   element (core/aura_elements) → AuraGlue.ElementProfile + ElementGroups
--     → AuraGlue.RunConfigPass (AuraSkin.Configure OOC / Restyle in combat).
-- Filter, sort and layout are ALL element-borne now (the container forwards the
-- element's AuraFilters string to the C-side aura read, secret-safe). BB is
-- STRIPS-ONLY: it never creates AddAuraSlot frames, so the pass SKIPS tracked
-- elements entirely and only ever PARKS a container's slot pool (never Syncs).
---------------------------------------------------------------------------
local function ResolveAuraDeps()
    AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    E = E or ns.AuraElements or (_G.QUI and _G.QUI.AuraElements)
    G = G or ns.AuraGlue    or (_G.QUI and _G.QUI.AuraGlue)
    S = S or ns.AuraSlots   or (_G.QUI and _G.QUI.AuraSlots)
    return AuraSkin and E and G and S
end

-- The player buff host is the only cancel-eligible BB host (own buffs).
-- ElementGroups additionally gates cancel to HELPFUL strips — but eligibility
-- must ALSO be per-host: the debuff editor mount hides the cancel toggle
-- (cancelEligible=false), so a HELPFUL strip living in the DEBUFF store must
-- not silently gain cancel behavior the user can't see or turn off.

-- Immutable empty active list: passed as a host's "active strips" when the
-- frame-level toggle (enableBuffs/hideBuffFrame) is off, so every pooled
-- container retires (disabled + hidden) instead of rendering.
local EMPTY = {}

-- Reusable scratch for the strip resolves (config path, not a hot render loop,
-- but avoid per-pass churn).
local _buffStrips = {}
local _debuffStrips = {}

-- Default element buckets — the runtime source of truth for a fresh profile,
-- transcribed from the core/defaults.lua buffBorders block (iconSize 35,
-- iconsPerRow 10, spacing 0, buffGrowLeft=true ⇒ growDirection LEFT + TOPRIGHT
-- origin, stack/duration text keys, fontSize 12). MUST stay file-local on the
-- runtime path: E.EnsureSeeded LATCHES elementsSeeded after the first seed, so an
-- Options-only bucket would let an Options-disabled install latch an EMPTY "*"
-- bucket and permanently lose the shipped strip.
local function DefaultBuffBucket()
    local EE = E or ns.AuraElements or (_G.QUI and _G.QUI.AuraElements)
    if not EE then return {} end
    local e = EE.NewFilterStripElement("HELPFUL")
    e.id = "buffs"
    e.enabled = true                     -- enableBuffs default
    e.iconSize = 35
    e.iconsPerRow = 10
    -- Stored default buffIconSpacing/debuffIconSpacing is the SENTINEL 0
    -- ("use default"); HEAD's BuildZoneProfile resolved 0 -> 2px. The element
    -- model carries RESOLVED values, so seed 2, not the raw sentinel.
    e.spacing = 2
    e.growDirection = "LEFT"             -- buffGrowLeft = true
    e.anchor = "TOPRIGHT"                -- growLeft + growUp=false ⇒ TOPRIGHT origin
    e.maxIcons = BUFF_MAX_DISPLAY
    e.sortRule = "INDEX"
    e.sortReverse = false
    e.rightClickCancel = true
    e.duration = { show = true, fontSize = 12, anchor = "CENTER", offsetX = 0, offsetY = 0, color = { 1, 1, 1, 1 } }
    e.stack = { show = true, fontSize = 12, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } }
    return { e }
end

local function DefaultDebuffBucket()
    local EE = E or ns.AuraElements or (_G.QUI and _G.QUI.AuraElements)
    if not EE then return {} end
    local e = EE.NewFilterStripElement("HARMFUL")
    e.id = "debuffs"
    e.enabled = true                     -- enableDebuffs default
    e.iconSize = 35
    e.iconsPerRow = 10
    -- Stored default buffIconSpacing/debuffIconSpacing is the SENTINEL 0
    -- ("use default"); HEAD's BuildZoneProfile resolved 0 -> 2px. The element
    -- model carries RESOLVED values, so seed 2, not the raw sentinel.
    e.spacing = 2
    e.growDirection = "LEFT"             -- debuffGrowLeft = true
    e.anchor = "TOPRIGHT"                -- growLeft + growUp=false ⇒ TOPRIGHT origin
    e.maxIcons = DEBUFF_MAX_DISPLAY
    e.sortRule = "INDEX"
    e.sortReverse = false
    e.rightClickCancel = false           -- the engine cannot cancel debuffs
    e.duration = { show = true, fontSize = 12, anchor = "CENTER", offsetX = 0, offsetY = 0, color = { 1, 1, 1, 1 } }
    e.stack = { show = true, fontSize = 12, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } }
    return { e }
end

-- Published for the shared aura element editor mount (Task 9): the Buff/
-- Debuff settings tab threads these in as capabilities.defaultBucketFn so a
-- fresh profile viewed in Options seeds identically to the runtime defaults
-- above.
local BB = ns.QUI_BuffBorders or {}
ns.QUI_BuffBorders = BB
BB.DefaultBuffBucket = DefaultBuffBucket
BB.DefaultDebuffBucket = DefaultDebuffBucket

-- Create-on-demand element STORE per host: { elementsSeeded, elements =
-- { ["*"] = { element, ... } } }. Element lists are NEVER declared in
-- core/defaults.lua (AceDB copyDefaults re-fills deleted array indices), so the
-- store is created here and seeded exactly once behind elementsSeeded.
local function GetBuffStore(settings)
    settings.buffAuras = settings.buffAuras or {}
    return settings.buffAuras
end
local function GetDebuffStore(settings)
    settings.debuffAuras = settings.debuffAuras or {}
    return settings.debuffAuras
end

-- One element → AuraSkin layout profile. BB anchors each container at the
-- element's OWN anchor corner on the mover (no unit-frame corner flip), so no
-- profile overrides are needed.
local function ElementProfileFor(element)
    return G.ElementProfile(element)
end

-- Fallback profile when a host has NO enabled strip (keeps the mover handle a
-- grabbable size in layout mode): synthesize from the shipped default bucket.
local function FallbackProfile(defaultBucketFn)
    local bucket = defaultBucketFn()
    if bucket and bucket[1] then return ElementProfileFor(bucket[1]) end
    return G.ElementProfile({})
end

-- Resolve a host's ENABLED filterStrip elements into `out`. EnsureSeeded latches
-- the shipped default bucket first. BB is STRIPS-ONLY: a tracked element
-- (icon/square/bar) would need AuraSlots.Sync/AddAuraSlot, which BB never does,
-- so tracked elements are skipped ENTIRELY here — the pass parks (never Syncs)
-- any container a tracked element might otherwise have claimed. BB never uses
-- spec buckets, so the specID is always nil.
local function ResolveStrips(store, defaultBucketFn, out)
    for i = #out, 1, -1 do out[i] = nil end
    if not store then return out end
    E.EnsureSeeded(store, defaultBucketFn)
    local elements = E.ActiveElementsForSpec(store, nil)
    for i = 1, #elements do
        local e = elements[i]
        if e.mode == "filterStrip" then
            out[#out + 1] = e
        end
    end
    return out
end

-- Natural grid extent of a fully-populated row (mover handle covers the full
-- possible width/height — the container renders an unknown live count C-side).
local function GridExtent(profile)
    local cols = math.min(profile.maxPerRow > 0 and profile.maxPerRow or profile.maxIcons, profile.maxIcons)
    if cols < 1 then cols = 1 end
    local rows = math.ceil(profile.maxIcons / cols)
    local w = cols * profile.iconSize + math.max(0, cols - 1) * profile.spacing
    local h = rows * profile.iconSize + math.max(0, rows - 1) * profile.spacing
    return w, h
end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
-- The QUI named anchor frames (created in Init) are the published, movable
-- frames the anchoring system resolves by global name and positions. Each host
-- owns a POOL of forbidden AuraContainers (._quiAuraContainers[ordinal]) — one
-- per active filterStrip element in that host's element store.
local buffContainer = nil       -- QUI_BuffIconContainer (named anchor / buff host)
local debuffContainer = nil     -- QUI_DebuffIconContainer (named anchor / debuff host)
local initialized = false

-- Blizzard frame banish state
local blizzBuffBanished = false
local blizzDebuffBanished = false
local blizzardBanishState = Helpers.CreateStateTable()
local blizzardBanishParent

local function GetBlizzardBanishState(frame)
    local state = blizzardBanishState[frame]
    if not state then
        state = {}
        blizzardBanishState[frame] = state
    end
    return state
end

-- Layout mode preview state
local previewActive = false

-- debug counters; nil until QUI_Debug activates instrumentation
local buffBorderStats

---------------------------------------------------------------------------
-- COMBAT DEFERRAL
-- The AuraContainer is a forbidden object: create / pool / anchor / filter /
-- enable changes are restricted in combat, so any such work attempted during
-- InCombatLockdown() is queued and replayed on PLAYER_REGEN_ENABLED.
---------------------------------------------------------------------------
local pendingContainerWork = false

local function ApplyContainerConfig() end  -- forward declaration

-- Replays container work that was deferred because it was attempted in combat
-- (AuraContainer is a forbidden object). Run from the always-registered
-- PLAYER_REGEN_ENABLED handler below; the pendingContainerWork gate makes combat
-- end a no-op unless work was actually queued — no unconditional full rebuild.
local function FlushPendingContainerWork()
    if pendingContainerWork then
        pendingContainerWork = false
        ApplyContainerConfig()
    end
end

local function QueueContainerWork()
    pendingContainerWork = true
end

---------------------------------------------------------------------------
-- BANISH / RESTORE BLIZZARD FRAMES
---------------------------------------------------------------------------
local function SetDescendantMouse(frame, enable)
    for i = 1, frame:GetNumChildren() do
        local child = select(i, frame:GetChildren())
        if child then
            if child.EnableMouse then child:EnableMouse(enable) end
            SetDescendantMouse(child, enable)
        end
    end
end

local function EnsureBlizzardBanishParent()
    if not blizzardBanishParent then
        blizzardBanishParent = CreateFrame("Frame", "QUI_BuffBordersHiddenParent", UIParent)
        blizzardBanishParent:Hide()
    end
    return blizzardBanishParent
end

local function RemoveFromManagedContainer(frame)
    if not frame then return nil end
    local currentParent = frame.GetParent and frame:GetParent() or nil
    if currentParent and currentParent.RemoveManagedFrame then
        pcall(currentParent.RemoveManagedFrame, currentParent, frame)
    end
    frame.ignoreFramePositionManager = true
    return currentParent
end

local function BanishBlizzardFrame(frame)
    if not frame then return false end
    if InCombatLockdown() and not ns._inInitSafeWindow then return false end

    local state = GetBlizzardBanishState(frame)
    if not state.banished then
        state.originalParent = frame.GetParent and frame:GetParent() or UIParent
        state.originalAlpha = frame.GetAlpha and frame:GetAlpha() or 1
        state.originalMouse = frame.IsMouseEnabled and frame:IsMouseEnabled()
        state.originalIgnoreFramePositionManager = frame.ignoreFramePositionManager
    end

    RemoveFromManagedContainer(frame)

    local hiddenParent = EnsureBlizzardBanishParent()
    if frame.SetParent and frame:GetParent() ~= hiddenParent then
        pcall(frame.SetParent, frame, hiddenParent)
    end
    if frame.SetAlpha then pcall(frame.SetAlpha, frame, 0) end
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, false) end
    SetDescendantMouse(frame, false)

    state.banished = true
    return true
end

local function RestoreBlizzardFrame(frame)
    if not frame then return false end
    if InCombatLockdown() and not ns._inInitSafeWindow then return false end

    local state = blizzardBanishState[frame]
    if state and state.originalIgnoreFramePositionManager ~= nil then
        frame.ignoreFramePositionManager = state.originalIgnoreFramePositionManager
    else
        frame.ignoreFramePositionManager = nil
    end

    local parent = state and state.originalParent or UIParent
    if frame.SetParent and parent then
        pcall(frame.SetParent, frame, parent)
    end

    local alpha = (state and state.originalAlpha ~= nil) and state.originalAlpha or 1
    if frame.SetAlpha then pcall(frame.SetAlpha, frame, alpha) end

    local mouse = not (state and state.originalMouse == false)
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, mouse) end
    SetDescendantMouse(frame, mouse)

    if frame.Show then pcall(frame.Show, frame) end
    if state then state.banished = false end
    return true
end

---------------------------------------------------------------------------
-- BLIZZARD FRAME MANAGEMENT
---------------------------------------------------------------------------
local function ManageBlizzardFrames()
    local settings = GetSettings()
    if not settings then return end

    if settings.enableBuffs then
        if BanishBlizzardFrame(BuffFrame) then
            blizzBuffBanished = true
        end
    else
        if blizzBuffBanished then
            if RestoreBlizzardFrame(BuffFrame) then
                blizzBuffBanished = false
            end
        end
    end

    if settings.enableDebuffs then
        if BanishBlizzardFrame(DebuffFrame) then
            blizzDebuffBanished = true
        end
    else
        if blizzDebuffBanished then
            if RestoreBlizzardFrame(DebuffFrame) then
                blizzDebuffBanished = false
            end
        end
    end
end

---------------------------------------------------------------------------
-- LIVE CONTAINER CONFIG (shared per-element secure path)
-- Each host mover (buff / debuff) owns a POOL of forbidden AuraContainers, one
-- per active filterStrip element in its store, pooled by ORDINAL on the mover.
-- The containers self-drive UNIT_AURA and render aura DATA C-side (secret-safe);
-- QUI never reads a secret aura field on this path. CREATION is OOC-only (combat
-- creation crashes the 12.1 client); MUTATION of a pre-created container
-- (anchor / groups / unit / enable) is combat-legal, so config changes apply
-- live in combat and the full pass replays at PLAYER_REGEN_ENABLED.
---------------------------------------------------------------------------

-- Anchor one element's container on a base frame. AuraSkin.LayoutAnchor(profile)
-- is the flow-origin corner (grow + wrap); pinning THAT corner to the base's
-- element.anchor corner makes the auto-sized container hang off the base with
-- multi-row growth extending away from the origin.
local function AnchorElementContainer(container, baseFrame, element)
    local profile = ElementProfileFor(element)
    container:ClearAllPoints()
    container:SetPoint(AuraSkin.LayoutAnchor(profile), baseFrame, element.anchor or "TOPRIGHT",
        (element.offsetX or 0), (element.offsetY or 0))
end

-- One host's per-element container pass, pooled by ordinal on the mover.
-- allowCreate=true is the full OOC pass (may CreateFrame the forbidden containers
-- and reconcile groups). allowCreate=false is the combat pass: only combat-legal
-- mutation of pre-created containers (SetUnit / group reconcile via
-- AuraGlue.RunConfigPass's pcall+Restyle fallback / enable); any work needing
-- creation sets `incomplete` and the caller queues an OOC replay. BB is
-- STRIPS-ONLY, so every container is filterStrip-configured and its slot pool is
-- PARKED (AuraSlots.Park, never AuraSlots.Sync). `strips` is EMPTY when the host
-- is frame-gated off, which retires every pooled container.
local function ApplyMoverElements(moverFrame, strips, isBuff, allowCreate)
    local pool = moverFrame._quiAuraContainers
    if not pool then
        pool = {}
        moverFrame._quiAuraContainers = pool
    end
    local incomplete = false
    local createdFresh = false
    for i = 1, #strips do
        local element = strips[i]
        local container = pool[i]
        if not container then
            if allowCreate and not InCombatLockdown() and CreateFrame then
                container = CreateFrame("AuraContainer", nil, moverFrame, "CustomAuraContainerTemplate")
                pool[i] = container
                createdFresh = true
            else
                -- Creation is OOC-only (forbidden object); queue a regen replay.
                incomplete = true
            end
        end
        if container then
            if i == 1 then
                -- Publish strip 1 as THE live container for this host: the
                -- central anchoring system positions it directly and docks the
                -- sibling aura host to it (container-first). Cleared when the
                -- host retires every strip (see below) so anchor targets never
                -- degenerate to a hidden container.
                moverFrame._quiLiveContainer = container
                container._quiHostMover = moverFrame
            end
            -- SetUnit BEFORE Configure: group registration parses auras eagerly.
            container:SetUnit("player")
            if not InCombatLockdown() and i > 1 then
                -- Strip 1 is positioned by the central anchoring system
                -- (container-first). Later strips hang off strip 1's live
                -- container so they track its auto-sized growth too.
                -- pcall: forbidden→forbidden relativeTo acceptance is a PTR4
                -- in-game unknown — on rejection fall back to the mover and
                -- queue an OOC replay rather than aborting the whole pass.
                local okA = pcall(AnchorElementContainer, container, pool[1] or moverFrame, element)
                if not okA then
                    pcall(AnchorElementContainer, container, moverFrame, element)
                    incomplete = true
                end
            end
            local profile = ElementProfileFor(element)
            local groups = G.ElementGroups("player", element, profile, isBuff)
            if not G.RunConfigPass(container, profile, groups, allowCreate) then incomplete = true end
            -- Strips-only: keep any slot pool a re-purposed container carries parked.
            S.Park(container)
            -- Temp weapon enchants render INSIDE the buff container
            -- (PTR4 AddItemEnchantment, placement=BeforeAuraGroups — the
            -- engine-owned version of the old strip + lead-in). First call
            -- creates forbidden frames → OOC only; the layout mutator
            -- re-applies every pass. Known gap: engine right-click cancel is
            -- instanceID-only and no-ops for enchants (Blizzard's own
            -- BuffFrame still cancels via the legacy path) — accepted.
            if isBuff and i == 1 then
                if InCombatLockdown() and not container._quiEnchantsAdded then
                    incomplete = true
                else
                    local okE = pcall(AuraSkin.ConfigureEnchantments, container, profile)
                    if not okE or not container._quiEnchantsAdded then
                        incomplete = true
                    end
                end
            end
            container:SetEnabled(true)
            container:Show()
        end
    end
    if #strips == 0 then
        -- Host retired every strip: clear the published live container so
        -- the central anchoring system never anchors to a hidden container.
        -- The retired container's own _quiHostMover back-pointer is
        -- intentionally left in place (inert — every consumer path
        -- re-derives liveness via mover._quiLiveContainer first).
        moverFrame._quiLiveContainer = nil
    end

    -- Retire pooled containers beyond the active strip count (empty groups + park
    -- slots + disable + hide — all combat-legal on a pre-created container).
    for i = #strips + 1, #pool do
        local container = pool[i]
        if not G.RunConfigPass(container, container._quiProfile or {}, {}, allowCreate) then incomplete = true end
        S.Park(container)
        container:SetEnabled(false)
        container:Hide()
    end
    return incomplete, createdFresh
end

-- Disable + hide every pooled container on a host mover (layout-mode preview
-- owns the display while active, so the live secure containers go dark and the
-- fake preview icons render alone). SetEnabled/Hide is combat-legal; preview
-- only toggles OOC (its caller gates on InCombatLockdown).
local function DisableMoverContainers(moverFrame)
    local pool = moverFrame._quiAuraContainers
    if not pool then return end
    for i = 1, #pool do
        local c = pool[i]
        if c then
            pcall(c.SetEnabled, c, false)
            pcall(c.Hide, c)
        end
    end
end

-- Heart of the live path, shared by both passes. allowCreate=true is the full
-- OOC pass; allowCreate=false is the combat-legal mutation subset. Reads the
-- per-host element STORES (never the old per-strip settings keys); frame-level
-- toggles (enableBuffs/hideBuffFrame/fade*) stay settings-level reads.
local function ApplyConfigPass(allowCreate)
    if not buffContainer or not debuffContainer then return end
    if previewActive then return end
    if not ResolveAuraDeps() then return end

    local settings = GetSettings()
    if not settings then return end

    local buffStrips   = ResolveStrips(GetBuffStore(settings),   DefaultBuffBucket,  _buffStrips)
    local debuffStrips = ResolveStrips(GetDebuffStore(settings), DefaultDebuffBucket, _debuffStrips)

    -- Mover natural extent = first ENABLED strip's grid extent (unchanged
    -- profile math — temp enchants render INSIDE the buff container now, so
    -- there is no lead-in to widen for).
    local buffProfile   = buffStrips[1]   and ElementProfileFor(buffStrips[1])   or FallbackProfile(DefaultBuffBucket)
    local debuffProfile = debuffStrips[1] and ElementProfileFor(debuffStrips[1]) or FallbackProfile(DefaultDebuffBucket)

    local bw, bh = GridExtent(buffProfile)
    buffContainer._naturalW, buffContainer._naturalH = bw, bh
    buffContainer:SetSize(bw, bh)

    local dw, dh = GridExtent(debuffProfile)
    debuffContainer._naturalW, debuffContainer._naturalH = dw, dh
    debuffContainer:SetSize(dw, dh)

    -- Frame-level gates stay settings-level; element.enabled governs per-strip
    -- visibility WITHIN a shown host (ActiveElementsForSpec already filtered it).
    -- When a host is gated off, pass EMPTY so every pooled container retires.
    local anyBuffs   = settings.enableBuffs   and not settings.hideBuffFrame
    local anyDebuffs = settings.enableDebuffs and not settings.hideDebuffFrame
    local buffActive   = anyBuffs   and buffStrips   or EMPTY
    local debuffActive = anyDebuffs and debuffStrips or EMPTY

    local inc1, fresh1, inc2, fresh2
    if allowCreate then
        inc1, fresh1 = ApplyMoverElements(buffContainer,   buffActive,   true,  true)
        inc2, fresh2 = ApplyMoverElements(debuffContainer, debuffActive, false, true)
        if inc1 or inc2 then QueueContainerWork() end
    else
        -- In-combat mutation of a pre-created container is 12.1-PTR-legal
        -- (anchor/size/enable; group reconcile is pcall-guarded inside
        -- AuraGlue.RunConfigPass). pcall-guard the whole mover pass too: on any
        -- restriction error the queued full pass still reconciles at
        -- PLAYER_REGEN_ENABLED. The combat path never creates, so freshN
        -- stays nil/false here.
        local ok1, ok2
        ok1, inc1, fresh1 = pcall(ApplyMoverElements, buffContainer,   buffActive,   true,  false)
        ok2, inc2, fresh2 = pcall(ApplyMoverElements, debuffContainer, debuffActive, false, false)
        if (not ok1) or (not ok2) or inc1 or inc2 then QueueContainerWork() end
    end

    -- Fade support (SetAlpha is unprotected on the named mover frames).
    if anyBuffs then
        buffContainer:SetAlpha(settings.fadeBuffFrame and (settings.fadeOutAlpha or 0) or 1)
    else
        buffContainer:SetAlpha(0)
    end
    if anyDebuffs then
        debuffContainer:SetAlpha(settings.fadeDebuffFrame and (settings.fadeOutAlpha or 0) or 1)
    else
        debuffContainer:SetAlpha(0)
    end

    -- Containers may have just been created/re-pooled: re-run the central
    -- anchor apply so the container-first SetPoint lands on the CURRENT
    -- strip-1 containers (combat-legal mutation; AnchorOrPin pcalls the
    -- forbidden SetPoint). Layout mode owns handle positions while active --
    -- EXCEPT a freshly-created live container has never been SetPoint'd, and
    -- an unanchored frame does not render (fail-invisible): the central apply
    -- is the only owner of strip-1 anchors, so fresh creation overrides the
    -- layout-mode gate (the mover mirror side-effect is harmless here -- in
    -- the triggering scenario the host had no layout handle to begin with).
    if ((not Helpers.IsLayoutModeActive()) or fresh1 or fresh2) and _G.QUI_ApplyFrameAnchor then
        _G.QUI_ApplyFrameAnchor("buffFrame")
        _G.QUI_ApplyFrameAnchor("debuffFrame")
    end

    if buffBorderStats then buffBorderStats.containerConfigs = buffBorderStats.containerConfigs + 1 end
end

-- Full OOC pass (re-assigned to the forward declaration above; also what
-- FlushPendingContainerWork replays at PLAYER_REGEN_ENABLED).
ApplyContainerConfig = function()
    ApplyConfigPass(true)
end

-- Combat-legal mutation pass on pre-created objects.
local function ApplyMutableConfig()
    ApplyConfigPass(false)
end

-- Public re-config. OOC: run the full pass. In combat: apply the combat-legal
-- mutation subset immediately (live feedback on pre-created containers) AND
-- queue the full pass — creation can only run at PLAYER_REGEN_ENABLED.
local function ApplyOrDefer()
    if previewActive then return end
    if InCombatLockdown() then
        ApplyMutableConfig()
        QueueContainerWork()
        return
    end
    ApplyContainerConfig()
end

---------------------------------------------------------------------------
-- LAYOUT MODE PREVIEW
-- The secure container cannot be fed fake auras, so during preview each host's
-- live container is disabled + hidden and the shared placeholder preview
-- (ns.AuraPreview) renders alone on the mover host — WYSIWYG via the SAME
-- AuraGlue.ElementProfile layout math the live path uses. Restored on exit.
---------------------------------------------------------------------------
local function ShowPreview()
    if previewActive then return end
    if not buffContainer or not debuffContainer then return end

    local settings = GetSettings()
    if not settings then return end
    local Preview = ns.AuraPreview
    if not Preview or not ResolveAuraDeps() then return end
    previewActive = true

    -- Disable the live secure containers so the placeholder icons own each host
    -- (this also hides the strip-1 container's engine-rendered enchant frames —
    -- they are children of the SAME container, no separate hide needed).
    if not InCombatLockdown() then
        DisableMoverContainers(buffContainer)
        DisableMoverContainers(debuffContainer)
    end

    if not buffContainer:IsShown() then buffContainer:Show() end
    if not debuffContainer:IsShown() then debuffContainer:Show() end
    buffContainer:SetAlpha(1)
    debuffContainer:SetAlpha(1)

    -- Resolve each host's enabled strips and draw the placeholder preview ON the
    -- mover host. Size the host to the first strip's worst-case grid extent so
    -- the layout-mode grab handle covers the placeholders (mirrors
    -- ApplyConfigPass; the live containers — and their engine-rendered temp
    -- enchants — are disabled/hidden above, so there is nothing to widen for).
    local buffStrips  = ResolveStrips(GetBuffStore(settings), DefaultBuffBucket, _buffStrips)
    local buffProfile = buffStrips[1] and ElementProfileFor(buffStrips[1]) or FallbackProfile(DefaultBuffBucket)
    local bw, bh = GridExtent(buffProfile)
    buffContainer._naturalW, buffContainer._naturalH = bw, bh
    buffContainer:SetSize(bw, bh)
    Preview.Show(buffContainer, buffStrips)

    local debuffStrips  = ResolveStrips(GetDebuffStore(settings), DefaultDebuffBucket, _debuffStrips)
    local debuffProfile = debuffStrips[1] and ElementProfileFor(debuffStrips[1]) or FallbackProfile(DefaultDebuffBucket)
    local dw, dh = GridExtent(debuffProfile)
    debuffContainer._naturalW, debuffContainer._naturalH = dw, dh
    debuffContainer:SetSize(dw, dh)
    Preview.Show(debuffContainer, debuffStrips)

    if _G.QUI_LayoutModeSyncHandle then
        _G.QUI_LayoutModeSyncHandle("buffFrame")
        _G.QUI_LayoutModeSyncHandle("debuffFrame")
    end
end

local function HidePreview()
    if not previewActive then return end
    previewActive = false

    local Preview = ns.AuraPreview
    if Preview then
        Preview.Hide(buffContainer)
        Preview.Hide(debuffContainer)
    end

    ApplyOrDefer()
end

---------------------------------------------------------------------------
-- GROW ANCHOR (settings → frame anchoring corner)
---------------------------------------------------------------------------
local GROW_ANCHOR_FRAC_X = { TOPLEFT = 0, TOPRIGHT = 1, BOTTOMLEFT = 0, BOTTOMRIGHT = 1 }
local GROW_ANCHOR_FRAC_Y = { TOPLEFT = 1, TOPRIGHT = 1, BOTTOMLEFT = 0, BOTTOMRIGHT = 0 }

-- The mover's grow corner is the first ENABLED filterStrip element's `anchor`
-- in the matching per-host store (buffAuras / debuffAuras). Since v50 that
-- element `anchor` IS the old growLeft/growUp→corner formula's output (the
-- migration seeded it from the user's toggles before pruning the flat
-- buff*/debuffGrowLeft/GrowUp keys). Falls back to the host default corner
-- ("TOPRIGHT", matching Default{Buff,Debuff}Bucket) when no strip is enabled.
local function FirstEnabledStripAnchor(store, fallback)
    if type(store) == "table" and type(store.elements) == "table" then
        local bucket = store.elements["*"]
        if type(bucket) == "table" then
            for _, e in ipairs(bucket) do
                if type(e) == "table" and e.enabled ~= false and e.mode == "filterStrip"
                    and GROW_ANCHOR_FRAC_X[e.anchor] ~= nil then
                    return e.anchor
                end
            end
        end
    end
    return fallback
end

local function UpdateGrowAnchor(faKey)
    if not faKey then return end
    local profile = QUI and QUI.db and QUI.db.profile
    if not profile then return end
    local bbDB = profile.buffBorders
    if type(bbDB) ~= "table" then return end

    local newCorner
    if faKey == "buffFrame" then
        newCorner = FirstEnabledStripAnchor(bbDB.buffAuras, "TOPRIGHT")
    elseif faKey == "debuffFrame" then
        newCorner = FirstEnabledStripAnchor(bbDB.debuffAuras, "TOPRIGHT")
    else
        return
    end

    if not profile.frameAnchoring then
        profile.frameAnchoring = {}
    end
    if not profile.frameAnchoring[faKey] then
        profile.frameAnchoring[faKey] = {}
    end
    local entry = profile.frameAnchoring[faKey]
    local oldCorner = entry.growAnchor

    if oldCorner == newCorner then return end

    local isNewCornerFormat = entry.point == oldCorner
        and entry.relative == oldCorner
        and GROW_ANCHOR_FRAC_X[oldCorner] ~= nil

    local isFreePosition = entry.parent == "disabled" or entry.parent == "screen"
    if isNewCornerFormat and oldCorner and isFreePosition then
        local pw = UIParent:GetWidth()
        local ph = UIParent:GetHeight()
        local dX = (GROW_ANCHOR_FRAC_X[oldCorner] - GROW_ANCHOR_FRAC_X[newCorner]) * pw
        local dY = (GROW_ANCHOR_FRAC_Y[oldCorner] - GROW_ANCHOR_FRAC_Y[newCorner]) * ph
        entry.offsetX = math.floor((entry.offsetX or 0) + dX + 0.5)
        entry.offsetY = math.floor((entry.offsetY or 0) + dY + 0.5)
        entry.point = newCorner
        entry.relative = newCorner
    end

    entry.growAnchor = newCorner

    if _G.QUI_ApplyFrameAnchor then
        _G.QUI_ApplyFrameAnchor(faKey)
    end
end

---------------------------------------------------------------------------
-- FULL REFRESH (called from settings / profile switch)
---------------------------------------------------------------------------
local Init  -- forward declaration

local function FullRefresh()
    if not buffContainer or not debuffContainer then return end

    ManageBlizzardFrames()

    UpdateGrowAnchor("buffFrame")
    UpdateGrowAnchor("debuffFrame")

    if previewActive then
        HidePreview()
        ShowPreview()
        return
    end

    ApplyOrDefer()

    -- Re-run frame anchoring now that natural sizes are settled.
    if not Helpers.IsLayoutModeActive() then
        if _G.QUI_ApplyFrameAnchor then
            _G.QUI_ApplyFrameAnchor("buffFrame")
            _G.QUI_ApplyFrameAnchor("debuffFrame")
            if _G.QUI_UpdateFramesAnchoredTo then
                _G.QUI_UpdateFramesAnchoredTo("buffFrame")
                _G.QUI_UpdateFramesAnchoredTo("debuffFrame")
            end
        end
    else
        if _G.QUI_LayoutModeSyncHandle then
            _G.QUI_LayoutModeSyncHandle("buffFrame")
            _G.QUI_LayoutModeSyncHandle("debuffFrame")
        end
    end
end

local function TryDeferredFullRefresh()
    if previewActive then return end
    if not initialized then
        Init()
        return
    end
    if not buffContainer or not debuffContainer then return end
    FullRefresh()
end

---------------------------------------------------------------------------
-- INITIALIZATION
---------------------------------------------------------------------------
local function BuildFrames()
    -- Plain insecure named anchor frames on UIParent. These are the published,
    -- movable frames that the anchoring system resolves by name and positions;
    -- SetSize/Show/SetPoint on them are unprotected. Each owns one forbidden
    -- AuraContainer (created in ApplyContainerConfig) parented to it.
    buffContainer = CreateFrame("Frame", "QUI_BuffIconContainer", UIParent)
    buffContainer:SetSize(1, 1)
    buffContainer:SetClampedToScreen(true)

    debuffContainer = CreateFrame("Frame", "QUI_DebuffIconContainer", UIParent)
    debuffContainer:SetSize(1, 1)
    debuffContainer:SetClampedToScreen(true)
end

Init = function()
    if initialized then return true end
    initialized = true

    BuildFrames()

    UpdateGrowAnchor("buffFrame")
    UpdateGrowAnchor("debuffFrame")

    local applyAnchor = _G.QUI_ApplyFrameAnchor
    if applyAnchor then
        applyAnchor("buffFrame")
        applyAnchor("debuffFrame")
    end

    ManageBlizzardFrames()

    -- Create + configure the live containers (forbidden objects → OOC; defers to
    -- PLAYER_REGEN_ENABLED if Init somehow lands in combat). Temp weapon
    -- enchants render inside the buff container as part of this same pass
    -- (AuraSkin.ConfigureEnchantments, called from ApplyMoverElements) — no
    -- separate enchant event wiring needed.
    ApplyOrDefer()

    -- Re-apply shortly after build so anchoring + first auras settle (mirrors the
    -- legacy double-tap).
    C_Timer.After(0.1, ApplyOrDefer)
    C_Timer.After(0.5, TryDeferredFullRefresh)
    C_Timer.After(2.0, TryDeferredFullRefresh)
    return true
end

---------------------------------------------------------------------------
-- EVENT HANDLING
---------------------------------------------------------------------------
-- The live container self-drives UNIT_AURA C-side, so QUI no longer polls
-- auras on UNIT_AURA. Weapon-enchant events are gone too — temp enchants
-- render INSIDE the buff container now (AuraSkin.ConfigureEnchantments,
-- called from ApplyMoverElements) and the engine self-drives their updates
-- the same way.

-- Combat-end handler: replay container work that was deferred during combat.
-- Gated by pendingContainerWork (set only when ApplyOrDefer hits an in-combat
-- forbidden-object restriction), so this is a no-op on a normal combat end.
local paRegenFrame = CreateFrame("Frame")
paRegenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
paRegenFrame:SetScript("OnEvent", function()
    FlushPendingContainerWork()
end)

-- Debug instrumentation.
local function SetupDebugInstrumentation()
    buffBorderStats = {
        containerConfigs = 0,
    }
    local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "BB_containerConfigs", counter = true, fn = function() return buffBorderStats.containerConfigs end }
    local reg = ns.QUI_PerfRegistry or {}; ns.QUI_PerfRegistry = reg
    reg[#reg + 1] = { name = "BuffBorders_CombatEnd", frame = paRegenFrame }
end
if ns.DebugRegister then -- gate contract: core/debug_gate.lua
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation() -- standalone test harness: no gate, run eagerly
end

-- Primary initialization is called from core/main.lua during the ADDON_LOADED
-- safe window. Keep this retry for unusual load orders and combat-end recovery.
C_Timer.After(1, TryDeferredFullRefresh)

---------------------------------------------------------------------------
-- EXPORTS
---------------------------------------------------------------------------
local function RefreshBuffBorders()
    if not initialized and not Init() then return end
    FullRefresh()
end

QUI.BuffBorders = {
    Init = Init,
    Apply = RefreshBuffBorders,
    ShowPreview = ShowPreview,
    HidePreview = HidePreview,
}

-- Global function for config panel / layout mode to call
_G.QUI_RefreshBuffBorders = RefreshBuffBorders

-- Layout mode preview hooks
_G.QUI_BuffBordersShowPreview = ShowPreview
_G.QUI_BuffBordersHidePreview = HidePreview

if ns.Registry then
    ns.Registry:Register("buffBorders", {
        refresh = _G.QUI_RefreshBuffBorders,
        priority = 60,
        group = "ui",
        importCategories = { "cdm" },
    })
end
