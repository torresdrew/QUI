-- core/aura_slots.lua — QUI.AuraSlots: tracked icon/square/bar runtime on the
-- PTR4 AddAuraSlot contract (single-aura, manually anchored, excluded from
-- container flow).
--
-- Verified engine contract (vendored mirror, tests/framexml/.../Blizzard_AuraContainer/):
--   * AddAuraSlot(slotKey, filterString, options) creates the aura frame
--     SYNCHRONOUSLY (CreateAuraSlotFrame, Blizzard_CustomAuraContainer.lua:380)
--     and returns it → creation is combat-forbidden, same crash class as
--     AddAuraGroup. Never called while InCombatLockdown().
--   * Slots are addon-unremovable — the removal method exists only on the
--     private Managed mixin, never exposed to addons — but filter-MUTABLE:
--     SetAuraSlotFilterString (Blizzard_CustomAuraContainer.lua:403),
--     SetAuraSlotCandidateFilters (:412). Reconcile = rewrite.
--   * Park recipe: candidateFilters { maxDuration = 0 } never matches ANY
--     aura (Blizzard_AuraContainerUtil.lua:93 rejects duration > 0 and
--     duration == 0 alike) → the engine keeps a parked slot's frame hidden.
--   * The slot frame's visibility is engine-driven by aura presence; QUI
--     never reads aura data here — display is pure config (secrets-safe).
--   * The slot frame shares CustomAuraButtonTemplate with group buttons
--     (CreateAuraSlotFrame routes through the same AuraContainerUtil custom
--     frame provider as AddAuraGroup, Blizzard_CustomAuraContainer.lua:691-703),
--     so it exposes the SAME intrinsic inbound setters AuraSkin.WireButton
--     already wires: SetDurationCooldown (radial swipe) AND SetDurationBar
--     (Blizzard_CustomAuraButton.lua:183) — a StatusBar fill driven by the
--     engine's own secret-safe duration object, exactly like the cooldown.
--     "bar" display uses SetDurationBar; QUI never derives a duration fill
--     from a manual timestamp read.
local ADDON_NAME, ns = ...
local S = ns.AuraSlots or {}

-- 68675: slot frames carry DenyTaintedAccessWhenAurasAreSecret (applied by
-- the frame provider right after initializeFrame) — tainted child access
-- while auras are secret hard-errors. Gate every post-birth child write.
local function AurasAreSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end
ns.AuraSlots = S
_G.QUI = _G.QUI or {}
_G.QUI.AuraSlots = S

local E, AuraSkin, Helpers
local function Deps()
    E = E or ns.AuraElements
    AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin)
    Helpers = Helpers or ns.Helpers
    return E and AuraSkin and ns.AuraGlue
end

local PARK_FILTER = { maxDuration = 0 }

-- Per-container slot bookkeeping:
--   container._quiSlots = { { key = "t1", frame = <engine frame>, parked = bool }, ... }
-- Ordinal keys are stable for the container's lifetime; contents are rewritten
-- to whatever spell currently needs that ordinal.

local function SlotCandidateFilters(element, spellID)
    local cf = { includeSpellIDs = { [spellID] = true } }
    if E.EffectiveOnlyMine(element, spellID) then
        cf.isFromPlayerOrPlayerPet = true
    end
    return cf
end

-- Style one slot frame for the element's displayType. All writes are
-- aura-data-independent config; the engine drives visibility and (for
-- DurationCooldown / DurationBar) the actual fill.
local function StyleSlot(frame, element, index)
    local profile = ns.AuraGlue.ElementProfile(element)
    AuraSkin.WireButton(frame, profile)

    local isBar = (element.displayType == "bar")
    local barCfg = element.bar or {}
    local size = profile.iconSize
    if isBar then
        frame:SetSize(barCfg.length or 48, barCfg.thickness or 12)
    else
        frame:SetSize(size, size)
    end

    local icon = frame.Icon
    local blockColor = element.color or { 1, 1, 1 }
    if element.displayType == "square" or isBar then
        -- Colored block: hide the icon art (alpha on OUR texture, not the
        -- engine's), paint the QUI border texture as the block. For "bar" the
        -- border is the TRACK behind the StatusBar fill — dim it hard so the
        -- depleting fill reads against it (same full-strength color on both
        -- layers renders as a static block that never visibly depletes).
        if icon then icon:SetAlpha(0) end
        local block = frame._quiBorder
        if block then
            local trackDim = isBar and 0.25 or 1
            block:SetColorTexture((blockColor[1] or 1) * trackDim,
                (blockColor[2] or 1) * trackDim, (blockColor[3] or 1) * trackDim, 1)
            if block.DisablePixelSnap then block:DisablePixelSnap() end
        end
    else
        if icon then icon:SetAlpha(1) end
    end

    -- Duration display: "bar" is always a linear fill (it IS the button);
    -- icon/square honor the element's own swipeStyle, opting into the SAME
    -- linear fill instead of the native radial spinner. Both paths wire the
    -- engine's SetDurationBar (secret-safe, engine-driven) rather than any
    -- manual timestamp math — no Lua ever computes elapsed/remaining here.
    local cd = frame._quiCooldown
    local wantsLinear = isBar or element.swipeStyle == "horizontal" or element.swipeStyle == "vertical"
    if wantsLinear then
        if cd and cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
        local fill = frame._quiDurationBar
        if not fill and InCombatLockdown() then
            -- displayType flipped to a linear fill MID-COMBAT: creating the
            -- StatusBar child + SetDurationBar wiring is deferred to the regen
            -- replay (OOC-only creation, same principle as AddAuraSlot).
            return false
        end
        if not fill then
            fill = CreateFrame("StatusBar", nil, frame)
            fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
            fill:SetAllPoints(frame)
            frame._quiDurationBar = fill
        end
        -- Re-called EVERY style pass, not just at creation: direction rides
        -- element.reverseSwipe and the engine re-accepts SetDurationBar, so a
        -- Reverse Swipe toggle takes effect without a reload.
        frame:SetDurationBar(fill, {
            direction = (element.reverseSwipe and Enum.StatusBarTimerDirection.ElapsedTime)
                or Enum.StatusBarTimerDirection.RemainingTime,
            interpolation = Enum.StatusBarInterpolation.Immediate,
        })
        local vertical = (element.swipeStyle == "vertical")
            or (isBar and element.swipeStyle ~= "horizontal" and (barCfg.thickness or 12) >= (barCfg.length or 48))
        fill:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
        fill:SetStatusBarColor(blockColor[1] or 1, blockColor[2] or 1, blockColor[3] or 1, 1)
        fill:Show()
    else
        if frame._quiDurationBar then frame._quiDurationBar:Hide() end
        if cd and Helpers and Helpers.ApplyCooldownSwipeStyle then
            Helpers.ApplyCooldownSwipeStyle(cd, element)
        end
    end
    return true
end

-- Anchor slot #index (of `total` rendered slots) in the element's row
-- relative to the container. Container SetPoint is the consumer's job;
-- slots hang off the container corner. Forbidden-frame SetPoint → OOC only
-- (Sync gates). `total` drives CENTER's row-centering math and the last
-- row's icon count when a row wraps short of a full iconsPerRow.
local function AnchorSlot(frame, container, element, index, total)
    local profile = ns.AuraGlue.ElementProfile(element)
    local grow = element.growDirection or "RIGHT"
    local isBar = (element.displayType == "bar")
    local barCfg = element.bar or {}
    local w = isBar and (barCfg.length or 48) or profile.iconSize
    local h = isBar and (barCfg.thickness or 12) or profile.iconSize
    local step = (index - 1)
    local perRow = profile.maxPerRow or 0
    local col, rowI = step, 0
    if perRow > 0 then
        col  = step % perRow
        rowI = math.floor(step / perRow)
    end
    local dx, dy = 0, 0
    if grow == "RIGHT" then dx = col * (w + profile.spacing)
    elseif grow == "LEFT" then dx = -col * (w + profile.spacing)
    elseif grow == "UP" then dy = col * (h + profile.spacing)
    elseif grow == "DOWN" then dy = -col * (h + profile.spacing)
    elseif grow == "CENTER" then
        -- Center the row on the anchor: shift by half the row extent. A
        -- wrapped LAST row that is shorter than iconsPerRow centers on its
        -- own (smaller) icon count, not the full-row count.
        local rowN = total or 1
        if perRow > 0 then
            local rowsTotal = math.ceil((total or 1) / perRow)
            rowN = (rowI < rowsTotal - 1) and perRow or ((total or 1) - perRow * (rowsTotal - 1))
        end
        dx = (col - (rowN - 1) / 2) * (w + profile.spacing)
    end
    if rowI > 0 then
        -- Extra rows stack away from the anchored edge (matches the filter
        -- strip's wrap rule): vertical grows (UP/DOWN) are one-icon-per-column
        -- already, so extra columns advance ACROSS — leftward off a
        -- RIGHT-anchored corner, rightward otherwise (dx); horizontal grows
        -- (RIGHT/LEFT/CENTER) advance DOWN off a TOP anchor, UP off a
        -- BOTTOM anchor (dy).
        local vert = (grow == "UP" or grow == "DOWN")
        if vert then
            local anchorRight = tostring(profile.anchor or ""):find("RIGHT", 1, true)
            dx = dx + (anchorRight and -1 or 1) * rowI * (w + profile.spacing)
        else
            local anchorTop = tostring(profile.anchor or ""):find("TOP", 1, true)
            dy = dy + (anchorTop and -1 or 1) * rowI * (h + profile.spacing)
        end
    end
    frame:ClearAllPoints()
    frame:SetPoint(profile.anchor, container, element.anchor or "TOPLEFT", dx, dy)
end

local function ParkSlot(container, slot)
    if slot.parked then return end
    slot.parked = true
    container:SetAuraSlotCandidateFilters(slot.key, PARK_FILTER)
end

-- Reconcile ONE tracked element's spells onto its container's slot pool.
-- Returns true when fully applied; false when forbidden creation work was
-- skipped in combat (caller queues a regen replay via AuraGlue.QueueRegenWork).
function S.Sync(container, element, allowCreate)
    if not Deps() then return false end
    local pool = container._quiSlots
    if not pool then
        pool = {}
        container._quiSlots = pool
    end
    local spells = (element.enabled ~= false) and element.spells or nil
    local complete = true
    local want = 0
    if spells then
        local base = element.auraType or "HELPFUL"
        -- Pre-count the RENDERABLE spells (numeric entries only), capped by
        -- maxIcons. `total` feeds AnchorSlot's CENTER row math, so it must be
        -- the real rendered-icon count — a stray non-number entry must not
        -- inflate the centering, and the cap applies to icons rendered, not
        -- array positions. The main loop then stops once `want` hits `total`;
        -- the trailing ParkSlot loop retires any already-created slots past
        -- the bound (e.g. after the user lowers maxIcons).
        local total = 0
        for i = 1, #spells do
            if type(spells[i]) == "number" then total = total + 1 end
        end
        local cap = element.maxIcons
        if cap and cap > 0 and cap < total then total = cap end
        for i = 1, #spells do
            if want >= total then break end
            local spellID = spells[i]
            if type(spellID) == "number" then
                want = want + 1
                local slot = pool[want]
                if slot then
                    -- Rewrite in place — slots are filter-mutable.
                    container:SetAuraSlotFilterString(slot.key, base)
                    container:SetAuraSlotCandidateFilters(slot.key, SlotCandidateFilters(element, spellID))
                    slot.parked = false
                elseif allowCreate and not InCombatLockdown() then
                    local key = "t" .. tostring(want)
                    -- Style + anchor at BIRTH via initializeFrame: the frame
                    -- provider runs it BEFORE applying the 68675 access
                    -- restrictions (Blizzard_AuraContainerFrameProviders
                    -- CreateFrame), so a slot created while auras are secret
                    -- still comes up fully styled — the post-birth pass
                    -- below is restriction-gated and would skip it.
                    local slotIndex, slotTotal = want, total
                    local frame = container:AddAuraSlot(key, base, {
                        candidateFilters = SlotCandidateFilters(element, spellID),
                        initializeFrame = function(f)
                            StyleSlot(f, element, slotIndex)
                            AnchorSlot(f, container, element, slotIndex, slotTotal)
                        end,
                    })
                    slot = { key = key, frame = frame, parked = false }
                    pool[want] = slot
                else
                    -- AddAuraSlot creates a forbidden frame synchronously —
                    -- never in combat. Caller replays at regen.
                    complete = false
                end
                if slot and slot.frame then
                    -- 68675: slot frames are AuraButton children carrying
                    -- DenyTaintedAccessWhenAurasAreSecret — StyleSlot/
                    -- AnchorSlot (SetSize/SetPoint on the child) hard-error
                    -- while auras are secret. Report incomplete instead; the
                    -- caller's QueueRegenWork replay is restriction-aware
                    -- (core/aura_glue.lua) and re-runs Sync once both combat
                    -- and the restriction clear. The container-level
                    -- SetAuraSlot* rewrites above stay live — only CHILD
                    -- access is restricted.
                    if AurasAreSecret() then
                        complete = false
                    else
                        if StyleSlot(slot.frame, element, want) == false then
                            complete = false
                        end
                        if not InCombatLockdown() then
                            AnchorSlot(slot.frame, container, element, want, total)
                        else
                            complete = false
                        end
                    end
                end
            end
        end
    end
    for i = want + 1, #pool do
        ParkSlot(container, pool[i])
    end
    return complete
end

-- Park everything (element deleted/disabled; container returns to the pool).
function S.Park(container)
    local pool = container._quiSlots
    if not pool then return end
    for i = 1, #pool do
        ParkSlot(container, pool[i])
    end
end

return S
