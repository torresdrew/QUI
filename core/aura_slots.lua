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

-- KNOWN ENGINE LIMITATION (12.1, deliberate Blizzard privacy design —
-- Blizzard_AuraContainerUtil.CanApplyIdentityCandidateFilters): the engine
-- IGNORES includeSpellIDs/excludeSpellIDs for (a) HARMFUL auras on
-- assistable units and (b) HELPFUL auras on non-assistable units ("it
-- shouldn't be possible to filter out debuffs on player targets because that
-- would allow for extremely specific displays"). A tracked slot in those
-- quadrants would bind an ARBITRARY aura of that polarity — misinformation
-- under a per-spell config. There is no addon-side post-verify (slot frames
-- are engine-owned/forbidden), so QUI FAILS CLOSED in two tiers:
--   * STATIC token-class parks: HARMFUL slots on assist-class tokens
--     (player/pet/party/raid) and HELPFUL slots on never-assistable tokens
--     (boss) park unconditionally.
--   * LIVE probe (party/raid HELPFUL): the engine's check is LIVE
--     UnitCanAssist("player", unit) per aura at bind time — an open-world
--     cross-faction, mind-controlled, dead/released, phased, or
--     not-yet-streamed group member fails it and its includeSpellIDs are
--     silently skipped, so the assist-class token alone missed exactly
--     that window. Sync additionally gates on LiveAssistProbe; group-frame
--     unit-state events (UNIT_FACTION/UNIT_FLAGS/UNIT_PHASE/
--     UNIT_CONNECTION) re-drive Sync when the probe flips (groupframes
--     RefreshTrackedSlotAssist), and EVENT-LESS flips — zone-rule changes
--     on instance entry, visibility drift — are caught by the
--     PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA sweeps plus a slow 5s
--     safety ticker (groupframes SweepTrackedSlotAssist), so a parked slot
--     can never stay parked across a zone transition. player/pet are
--     exempt — own units never degrade. Shells are CONSTRUCTED even while
--     the probe is false (parked, whenever creation is combat-legal):
--     unpark is a filter REWRITE and stays available mid-combat, so a
--     member untrusted at first Sync doesn't lose the whole fight to the
--     regen replay.
-- target/focus stay VARIABLE: reaction flips per target with no re-Sync,
-- so those tokens keep engine behavior (their gate applies per-aura at
-- bind time) — the residual "tracked buff on a currently-hostile target"
-- case remains engine best-effort and is the documented remainder of this
-- limitation.

-- Token-class reaction: "assist" (assistable-class while valid), "hostile"
-- (never assistable), or nil (variable — target/focus/arena/unknown).
local function TokenReactionClass(unit)
    if type(unit) ~= "string" then return nil end
    if unit == "player" or unit == "pet" then return "assist" end
    local p4 = unit:sub(1, 4)
    if p4 == "part" or p4 == "raid" then return "assist" end
    if p4 == "boss" then return "hostile" end
    return nil
end

-- Live assistability for the party/raid HELPFUL quadrant. Mirrors the
-- engine's per-aura UnitCanAssist gate
-- (Blizzard_AuraContainerUtil.CanApplyIdentityCandidateFilters), HARDENED
-- to require every positively checkable trust signal: plain UnitCanAssist
-- alone still passes for dead/released or phased members whose filter
-- flags have not streamed, yet the engine skips their include-list
-- filters (observed live) — so connected + alive + assistable + visible +
-- not phased, or park. Any throw inside the chain (secret identity state
-- under teardown/restriction) fails CLOSED — a parked slot shows nothing,
-- never an arbitrary buff. player/pet exempt by LEXICAL token compare
-- (never UnitIsUnit here: SecretWhenUnitComparisonRestricted).
local function LiveAssistProbe(unit)
    if unit == "player" or unit == "pet" then return true end
    local ok, trusted = pcall(function()
        if not (UnitIsConnected(unit)
            and not UnitIsDeadOrGhost(unit)
            and UnitCanAssist("player", unit)
            and UnitIsVisible(unit)) then
            return false
        end
        -- UnitPhaseReason is SecretWhenUnitIdentityRestricted (12.1 PTR7):
        -- probe explicitly so the secret case parks without riding the
        -- throw path (any residual throw still fails CLOSED via pcall).
        local phase = UnitPhaseReason(unit)
        if issecretvalue and issecretvalue(phase) then return false end -- @secret-policy: reject-secret-value — fail-closed park
        return not phase
    end)
    return ok and trusted == true -- @secret-policy: reject-secret-value — fail-closed park
end
S.LiveAssistProbe = LiveAssistProbe

-- 68824: the engine honors includeSpellIDs on ANY unit for spells whose aura
-- secrecy is NeverSecret (identity-filter exemption in AuraContainerUtil).
-- Parking those slots is over-conservative — a never-secret whitelisted
-- debuff (e.g. raid-utility exhaustion class) may render on friendly units.
-- Absent API/enum (pre-68824) → false → behavior unchanged.
local function SpellNeverSecret(spellID)
    local CS = C_Secrets
    if not (CS and CS.GetSpellAuraSecrecy and Enum and Enum.SecrecyLevel) then
        return false
    end
    local ok, level = pcall(CS.GetSpellAuraSecrecy, spellID)
    -- @secret-safe: level is a plain enum for a literal spellID argument
    return ok and level == Enum.SecrecyLevel.NeverSecret
end

-- Identity-filter decision for this container's unit right now. Returns
-- (enforceable, liveGoverned, live):
--   enforceable — the engine will honor includeSpellIDs (else FAIL CLOSED);
--   liveGoverned — the decision rides LiveAssistProbe (party/raid HELPFUL)
--     and must be re-checked whenever live unit state changes;
--   live — the probe value used (meaningful only when liveGoverned).
-- Sync records `live` on the container (_quiAssistApplied) so readers
-- judge staleness against what was ACTUALLY applied, never a shadow cache.
local function IdentityFilterEnforceable(container, base)
    local ok, unit = pcall(function()
        return container.GetUnit and container:GetUnit()
    end)
    if not ok then return true, false, nil end
    local class = TokenReactionClass(unit)
    if class == nil then return true, false, nil end
    local harmful = type(base) == "string" and base:find("HARMFUL", 1, true) ~= nil
    if harmful then
        return class ~= "assist", false, nil
    end
    if class == "hostile" then return false, false, nil end
    if unit == "player" or unit == "pet" then return true, false, nil end
    -- class == "assist" party/raid, HELPFUL: the static class is necessary
    -- but not sufficient — the engine's gate is LIVE UnitCanAssist (see
    -- header).
    local live = LiveAssistProbe(unit)
    return live, true, live
end

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
    -- Applied-state record for the live-assist stale check (groupframes
    -- TrackedAssistStale): nil = this container's quadrant is not governed
    -- by the live probe; true/false = the probe value these slot filters
    -- were last reconciled against. Sync is the ONLY writer — a reader-side
    -- dedupe cache proved unable to track it (any config pass can run Sync
    -- under a different probe value than the last event sweep observed,
    -- leaving slots parked with no flip left for the reader to see).
    container._quiAssistApplied = nil
    local parkAll = false
    if spells then
        local base = element.auraType or "HELPFUL"
        local enforceable, liveGoverned, live = IdentityFilterEnforceable(container, base)
        if liveGoverned then
            container._quiAssistApplied = live
        end
        -- FAIL CLOSED: when the engine ignores identity filters for this
        -- unit-class/polarity (see header), don't render arbitrary auras
        -- under a tracked-spell config.
        if not enforceable then
            if liveGoverned then
                -- LIVE-governed quadrant (party/raid HELPFUL): the probe can
                -- flip back MID-COMBAT, and slot CREATION is combat-forbidden
                -- while filter REWRITES are combat-legal. Build/keep the slot
                -- shells but PARK them, so an in-combat trust flip unparks
                -- by rewriting filters in place — without shells, a member
                -- untrusted at first Sync rendered nothing for the whole
                -- fight (creation deferred to the regen replay).
                parkAll = true
            else
                -- Statically never-enforceable (token-class park): leave
                -- `want` at 0 — enforceability can never flip for this
                -- container+polarity, so shells would be permanent dead
                -- weight (slots are addon-unremovable).
                spells = nil
            end
        end
    end
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
                local parkThis = parkAll and not SpellNeverSecret(spellID)
                if slot then
                    if parkThis then
                        ParkSlot(container, slot)
                    else
                        -- Rewrite in place — slots are filter-mutable.
                        container:SetAuraSlotFilterString(slot.key, base)
                        container:SetAuraSlotCandidateFilters(slot.key, SlotCandidateFilters(element, spellID))
                        slot.parked = false
                    end
                elseif allowCreate and not InCombatLockdown() then
                    local key = "t" .. tostring(want)
                    -- Style + anchor at BIRTH via initializeFrame: the frame
                    -- provider runs it BEFORE applying the 68675 access
                    -- restrictions (Blizzard_AuraContainerFrameProviders
                    -- CreateFrame), so a slot created while auras are secret
                    -- still comes up fully styled — the post-birth pass
                    -- below is restriction-gated and would skip it.
                    local slotIndex, slotTotal = want, total
                    local birthFilters = parkThis and PARK_FILTER or SlotCandidateFilters(element, spellID)
                    local frame = container:AddAuraSlot(key, base, {
                        candidateFilters = birthFilters,
                        initializeFrame = function(f)
                            StyleSlot(f, element, slotIndex)
                            AnchorSlot(f, container, element, slotIndex, slotTotal)
                        end,
                    })
                    slot = { key = key, frame = frame, parked = parkThis }
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
    -- No live-governed quadrant remains on a fully parked container — clear
    -- the applied record so the stale check never re-drives a retired one.
    container._quiAssistApplied = nil
    local pool = container._quiSlots
    if not pool then return end
    for i = 1, #pool do
        ParkSlot(container, pool[i])
    end
end

return S
