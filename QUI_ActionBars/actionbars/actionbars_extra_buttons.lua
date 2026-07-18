local ADDON_NAME, ns = ...
local env = ns.ActionBarsEnv
env.ADDON_NAME = ADDON_NAME
env.ns = ns
env.SetChunkEnv(1, env)

---------------------------------------------------------------------------
-- EXTRA BUTTON CUSTOMIZATION (Extra Action Button & Zone Ability)
---------------------------------------------------------------------------
do

extraBtnState = {
    extraActionHolder = nil,
    extraActionMover = nil,
    zoneAbilityHolder = nil,
    zoneAbilityMover = nil,
    moversVisible = false,
    hookingSetPoint = false,
    extraActionSetPointHooked = false,
    zoneAbilitySetPointHooked = false,
    extraAbilityContainerSetPointHooked = false,
    hookingSetParent = false,
    extraActionSetParentHooked = false,
    zoneAbilitySetParentHooked = false,
    extraAbilityContainerSetParentHooked = false,
    extraActionShowHooked = false,
    zoneAbilityShowHooked = false,
    extraAbilityContainerShowHooked = false,
    pageArrowShowHooked = {},
    pageArrowRetryTimer = nil,
    pageArrowRetryAttempts = 0,
    PAGE_ARROW_RETRY_MAX_ATTEMPTS = 15,
    PAGE_ARROW_RETRY_DELAY = 0.2,
    -- Ownership is monotonic for the session.  A /reload is the only safe
    -- hand-back after either surface has taken the shared Blizzard container.
    containerOwned = false,
    containerNeutralized = false,
    zoneOwned = false,
}

function GetExtraButtonDB(buttonType)
    local core = GetCore()
    if not core or not core.db or not core.db.profile then return nil end
    return core.db.profile.actionBars and core.db.profile.actionBars.bars
        and core.db.profile.actionBars.bars[buttonType]
end

function GetSavedExtraButtonFrameAnchor(buttonType)
    local core = GetCore()
    local profile = core and core.db and core.db.profile
    local fa = profile and profile.frameAnchoring
    if type(fa) ~= "table" or not buttonType then return nil end
    local entry = rawget(fa, buttonType)
    if type(entry) == "table" then
        return entry
    end
    return nil
end

-- Position a holder from the active profile's saved bars position (or the
-- hardcoded creation default).  Used at holder creation AND as the
-- NO-OVERRIDE FALLBACK on refresh: a profile whose mover was never dragged
-- has no raw frameAnchoring override (AceDB strips default-equal entries on
-- save), so the central anchoring apply skips the key -- without this
-- fallback a profile switch/import left the holder at the PREVIOUS
-- profile's position.
function ApplyExtraButtonHolderFallbackPosition(buttonType, holder)
    if not holder then return end
    local settings = GetExtraButtonDB(buttonType)
    local point, relativeTo, relPoint, x, y =
        GetExtraButtonInitialPosition(buttonType, settings and settings.position)
    if not point then
        point, relativeTo, relPoint = "CENTER", UIParent, "CENTER"
        x = buttonType == "extraActionButton" and -100 or 100
        y = -200
    end
    holder:ClearAllPoints()
    holder:SetPoint(point, relativeTo or UIParent, relPoint or point, x or 0, y or 0)
end

function ApplyExtraButtonFrameAnchor(buttonType)
    -- COMBAT GATE (extra path): the extra holder hosts the anchored
    -- ExtraAbilityContainer, and a granted button puts a secure chain under
    -- it -- SetPoint on the holder is anchoring-restricted exactly when a
    -- button is up.  Defer to the PLAYER_REGEN_ENABLED reconcile.  The zone
    -- holder only ever hosts the unprotected ZoneAbilityFrame, so its anchor
    -- applies live (mid-combat grants keep tracking the mover); the central
    -- anchoring path still fail-closed-probes the live protection state
    -- before any in-combat SetPoint and defers itself if restricted.
    if buttonType == "extraActionButton"
        and InCombatLockdown() and not inInitSafeWindow
    then
        ActionBarsOwned.pendingExtraButtonRefresh = true
        return
    end
    local HasAnchor = _G.QUI_HasFrameAnchor
    local ApplyAnchor = _G.QUI_ApplyFrameAnchor
    if HasAnchor and ApplyAnchor and HasAnchor(buttonType) then
        ApplyAnchor(buttonType)
        return
    end
    -- NO-OVERRIDE FALLBACK (see ApplyExtraButtonHolderFallbackPosition).
    local holder = buttonType == "extraActionButton"
        and extraBtnState.extraActionHolder
        or extraBtnState.zoneAbilityHolder
    if not holder then return end
    -- Zone reaches here in combat: probe the holder's live state the same
    -- way the central anchoring path would and defer if restricted.
    if InCombatLockdown() and not inInitSafeWindow
        and Helpers.FrameMutationRestricted(holder)
    then
        ActionBarsOwned.pendingExtraButtonRefresh = true
        return
    end
    ApplyExtraButtonHolderFallbackPosition(buttonType, holder)
end

function SaveExtraButtonFrameAnchor(buttonType, point, relPoint, x, y)
    local core = GetCore()
    local profile = core and core.db and core.db.profile
    if not profile or not buttonType or not point then return end

    if type(profile.frameAnchoring) ~= "table" then
        profile.frameAnchoring = {}
    end

    local fa = profile.frameAnchoring
    local entry = rawget(fa, buttonType)
    if type(entry) ~= "table" then
        entry = {}
        fa[buttonType] = entry
    end

    entry.parent = "screen"
    entry.point = point
    entry.relative = relPoint or point
    entry.offsetX = x or 0
    entry.offsetY = y or 0
    entry.sizeStable = true
    entry.autoWidth = false
    entry.autoHeight = false
    entry.hideWithParent = false
    entry.keepInPlace = true
    entry.widthAdjust = 0
    entry.heightAdjust = 0
end

function SaveExtraButtonHolderPosition(buttonType, holder)
    if not holder then return end

    local core = GetCore()
    local point, relPoint, x, y

    if core and core.SnapFramePosition then
        local snappedPoint, _, snappedRelPoint, snappedX, snappedY = core:SnapFramePosition(holder)
        point, relPoint, x, y = snappedPoint, snappedRelPoint, snappedX, snappedY
    end

    if not point and holder.GetPoint then
        local fallbackPoint, _, fallbackRelPoint, fallbackX, fallbackY = holder:GetPoint(1)
        point, relPoint, x, y = fallbackPoint, fallbackRelPoint, fallbackX, fallbackY
    end

    if not point then return end

    x = Helpers.SafeToNumber(x, 0)
    y = Helpers.SafeToNumber(y, 0)
    relPoint = relPoint or point

    local db = GetExtraButtonDB(buttonType)
    if db then
        db.position = { point = point, relPoint = relPoint, x = x, y = y }
    end

    SaveExtraButtonFrameAnchor(buttonType, point, relPoint, x, y)
    ApplyExtraButtonFrameAnchor(buttonType)

    if _G.QUI and _G.QUI.SendMessage then
        _G.QUI:SendMessage("QUI_FRAME_ANCHOR_CHANGED", buttonType)
    end
end

function GetExtraButtonInitialPosition(buttonType, fallbackPosition)
    local anchor = GetSavedExtraButtonFrameAnchor(buttonType)
    if anchor then
        local parentKey = anchor.parent
        local parentFrame
        if not parentKey or parentKey == "screen" or parentKey == "disabled" then
            parentFrame = UIParent
        elseif parentKey == "extraActionButton" and buttonType ~= "extraActionButton" then
            parentFrame = extraBtnState.extraActionHolder or _G["QUI_extraActionButtonHolder"]
        elseif parentKey == "zoneAbility" and buttonType ~= "zoneAbility" then
            parentFrame = extraBtnState.zoneAbilityHolder or _G["QUI_zoneAbilityHolder"]
        end

        if parentFrame then
            local point = anchor.point or "CENTER"
            return point, parentFrame, anchor.relative or point, anchor.offsetX or 0, anchor.offsetY or 0
        end
    end

    if fallbackPosition and fallbackPosition.point then
        return fallbackPosition.point, UIParent, fallbackPosition.relPoint or fallbackPosition.point,
            fallbackPosition.x or 0, fallbackPosition.y or 0
    end

    return nil
end

function CreateExtraButtonNudgeButton(parent, direction, holder, buttonType)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(18, 18)
    btn:SetFrameStrata("HIGH")
    btn:SetFrameLevel(100)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0.1, 0.1, 0.1, 0.7)

    local line1 = btn:CreateTexture(nil, "ARTWORK")
    line1:SetColorTexture(1, 1, 1, 0.9)
    line1:SetSize(7, 2)

    local line2 = btn:CreateTexture(nil, "ARTWORK")
    line2:SetColorTexture(1, 1, 1, 0.9)
    line2:SetSize(7, 2)

    if direction == "DOWN" then
        line1:SetPoint("CENTER", btn, "CENTER", -2, 1)
        line1:SetRotation(math.rad(-45))
        line2:SetPoint("CENTER", btn, "CENTER", 2, 1)
        line2:SetRotation(math.rad(45))
    elseif direction == "UP" then
        line1:SetPoint("CENTER", btn, "CENTER", -2, -1)
        line1:SetRotation(math.rad(45))
        line2:SetPoint("CENTER", btn, "CENTER", 2, -1)
        line2:SetRotation(math.rad(-45))
    elseif direction == "LEFT" then
        line1:SetPoint("CENTER", btn, "CENTER", 1, -2)
        line1:SetRotation(math.rad(-45))
        line2:SetPoint("CENTER", btn, "CENTER", 1, 2)
        line2:SetRotation(math.rad(45))
    elseif direction == "RIGHT" then
        line1:SetPoint("CENTER", btn, "CENTER", -1, -2)
        line1:SetRotation(math.rad(45))
        line2:SetPoint("CENTER", btn, "CENTER", -1, 2)
        line2:SetRotation(math.rad(-45))
    end

    btn:SetScript("OnEnter", function(self)
        line1:SetVertexColor(1, 0.8, 0, 1)
        line2:SetVertexColor(1, 0.8, 0, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        line1:SetVertexColor(1, 1, 1, 0.9)
        line2:SetVertexColor(1, 1, 1, 0.9)
    end)

    btn:SetScript("OnClick", function()
        local dx, dy = 0, 0
        if direction == "UP" then dy = 1
        elseif direction == "DOWN" then dy = -1
        elseif direction == "LEFT" then dx = -1
        elseif direction == "RIGHT" then dx = 1
        end
        if holder.AdjustPointsOffset then
            holder:AdjustPointsOffset(dx, dy)
        else
            local point, relativeTo, relativePoint, xOfs, yOfs = holder:GetPoint(1)
            if point then
                holder:ClearAllPoints()
                holder:SetPoint(point, relativeTo, relativePoint, (xOfs or 0) + dx, (yOfs or 0) + dy)
            end
        end
        SaveExtraButtonHolderPosition(buttonType, holder)
    end)

    return btn
end

function CreateExtraButtonHolder(buttonType, displayName)
    local settings = GetExtraButtonDB(buttonType)
    if not settings then return nil, nil end

    local holder = CreateFrame("Frame", "QUI_" .. buttonType .. "Holder", UIParent)
    holder:SetSize(64, 64)
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)

    ApplyExtraButtonHolderFallbackPosition(buttonType, holder)

    local mover = CreateFrame("Frame", "QUI_" .. buttonType .. "Mover", holder, "BackdropTemplate")
    mover:SetAllPoints(holder)
    ns.SkinBase.ApplyPixelBackdrop(mover, 2, true, false, {0.376, 0.647, 0.980, 1}, {0.2, 0.8, 0.6, 0.5})
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:SetFrameStrata("HIGH")
    mover:Hide()

    local text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetText(displayName)
    mover.text = text

    local nudgeUp = CreateExtraButtonNudgeButton(mover, "UP", holder, buttonType)
    nudgeUp:SetPoint("BOTTOM", mover, "TOP", 0, 4)
    local nudgeDown = CreateExtraButtonNudgeButton(mover, "DOWN", holder, buttonType)
    nudgeDown:SetPoint("TOP", mover, "BOTTOM", 0, -4)
    local nudgeLeft = CreateExtraButtonNudgeButton(mover, "LEFT", holder, buttonType)
    nudgeLeft:SetPoint("RIGHT", mover, "LEFT", -4, 0)
    local nudgeRight = CreateExtraButtonNudgeButton(mover, "RIGHT", holder, buttonType)
    nudgeRight:SetPoint("LEFT", mover, "RIGHT", 4, 0)

    mover:SetScript("OnDragStart", function(self)
        holder:StartMoving()
    end)

    mover:SetScript("OnDragStop", function(self)
        holder:StopMovingOrSizing()
        SaveExtraButtonHolderPosition(buttonType, holder)
    end)

    return holder, mover
end

extraButtonOriginalParents = {}

function GetExtraButtonVisualFrame(buttonType, blizzFrame)
    if not blizzFrame then return nil end

    if buttonType == "extraActionButton" then
        return blizzFrame.button or _G["ExtraActionButton1"]
    end

    local container = blizzFrame.SpellButtonContainer
    if container then
        if container.EnumerateActive then
            for button in container:EnumerateActive() do
                if button then
                    return button
                end
            end
        end
        return container
    end

    return blizzFrame.SpellButton
end

function GetExtraButtonHolderSize(buttonType, blizzFrame, settings, scale)
    local width = Helpers.SafeToNumber(blizzFrame:GetWidth(), 64)
    local height = Helpers.SafeToNumber(blizzFrame:GetHeight(), 64)

    -- hideArtwork only applies while the surface is ENABLED: the disabled
    -- path restores stock artwork, so the holder must span the full stock
    -- frame bounds -- a stale saved flag would otherwise shrink the holder
    -- to the trimmed visual-button footprint under restored artwork.
    if settings.enabled == true and settings.hideArtwork then
        local visualFrame = GetExtraButtonVisualFrame(buttonType, blizzFrame)
        if visualFrame then
            local visualWidth = visualFrame.GetWidth and Helpers.SafeToNumber(visualFrame:GetWidth(), width) or width
            local visualHeight = visualFrame.GetHeight and Helpers.SafeToNumber(visualFrame:GetHeight(), height) or height
            if visualWidth > 0 then width = visualWidth end
            if visualHeight > 0 then height = visualHeight end
        end
    end

    scale = Helpers.SafeToNumber(scale, 1)
    if scale <= 0 then scale = 1 end

    return math.max(width * scale, 64), math.max(height * scale, 64)
end

-- Blizzard's HorizontalLayout anchors ExtraActionBarFrame by TOPLEFT and sizes
-- ExtraAbilityContainer from the unscaled child.  Offset the container so the
-- scaled bar's visual center still lands on the holder without repinning the
-- protected child or replacing Blizzard's layout methods.
local function GetExtraActionContainerAnchorOffset(container, bar, scale, offsetX, offsetY)
    scale = Helpers.SafeToNumber(scale, 1)
    if scale <= 0 then scale = 1 end

    offsetX = Helpers.SafeToNumber(offsetX, 0)
    offsetY = Helpers.SafeToNumber(offsetY, 0)
    if not container or not bar then return offsetX, offsetY end

    local barWidth = Helpers.SafeToNumber(bar:GetWidth(), 0)
    local barHeight = Helpers.SafeToNumber(bar:GetHeight(), 0)
    if barWidth <= 0 or barHeight <= 0 then return offsetX, offsetY end

    -- Match LayoutMixin:CalculateFrameSize for this template.  The local
    -- ExtraAbilityContainer XML has no padding and uses minimumWidth/fixedHeight.
    local childLayoutWidth = barWidth
    local childLayoutHeight = barHeight
    if container.respectChildScale then
        childLayoutWidth = childLayoutWidth * scale
        childLayoutHeight = childLayoutHeight * scale
    end

    local layoutWidth = Helpers.SafeToNumber(container.fixedWidth, 0)
    if layoutWidth <= 0 then layoutWidth = childLayoutWidth end
    local minimumWidth = Helpers.SafeToNumber(container.minimumWidth, 0)
    local maximumWidth = Helpers.SafeToNumber(container.maximumWidth, 0)
    if minimumWidth > 0 then layoutWidth = math.max(layoutWidth, minimumWidth) end
    if maximumWidth > 0 then layoutWidth = math.min(layoutWidth, maximumWidth) end

    local layoutHeight = Helpers.SafeToNumber(container.fixedHeight, 0)
    if layoutHeight <= 0 then layoutHeight = childLayoutHeight end
    local minimumHeight = Helpers.SafeToNumber(container.minimumHeight, 0)
    local maximumHeight = Helpers.SafeToNumber(container.maximumHeight, 0)
    if minimumHeight > 0 then layoutHeight = math.max(layoutHeight, minimumHeight) end
    if maximumHeight > 0 then layoutHeight = math.min(layoutHeight, maximumHeight) end

    local visualWidth = barWidth * scale
    local visualHeight = barHeight * scale
    return offsetX + (layoutWidth - visualWidth) / 2,
        offsetY + (visualHeight - layoutHeight) / 2
end

-- Anchor the shared ExtraAbilityContainer onto the extra-action holder.
--
-- ExtraActionBarFrame owns the secure ExtraActionButton1
-- (SecureActionButtonTemplate) and therefore cannot be reparented or repinned
-- in combat.  ExtraAbilityContainer, by contrast, is a stable Blizzard frame
-- (EditMode + UIParent-managed layout container) that Blizzard NEVER reparents
-- on a grant: ExtraActionBar_Update only calls ExtraAbilityContainer:AddFrame
-- (which parents the button INTO the container).  So if we own the container's
-- position, a button granted mid-combat lands in an already-anchored container
-- and shows on the user's mover with zero addon-originated in-combat protected
-- calls.  Blizzard's secure AddFrame/layout path remains untouched.  We
-- exclude the container from Blizzard's layout/position managers so nothing
-- drags it back.  We never call ExtraAbilityContainer:RemoveFrame -- it does
-- SetParent(nil)+Hide() on its child (ExtraAbilityContainer.lua) -- we only own
-- the container's own parent/point.
function ApplyExtraActionContainerAnchor(holder, offsetX, offsetY, scale)
    local container = ExtraAbilityContainer
    if not container or not holder then return end

    if not extraButtonOriginalParents["extraActionButton"] then
        extraButtonOriginalParents["extraActionButton"] = container:GetParent()
    end

    container.ignoreInLayout = true
    container.ignoreFramePositionManager = true
    if container.SetIsLayoutFrame then
        pcall(container.SetIsLayoutFrame, container, false)
    end

    -- The managed-frame system honors ignoreFramePositionManager only at
    -- AddManagedFrame time; a container that was already visible before this
    -- takeover is already registered in the manager's showingFrames, and
    -- UpdateManagedFrames (cinematic end, Alt-Z UI re-show) still
    -- ClearAllPoints+SetParent's it despite the flag.  NEVER deregister it
    -- ourselves: an insecure write into the manager's showingFrames table
    -- (raw key removal included) taints the table, and the manager's secure
    -- pairs() walk over it then blocks the protected ClearAllPoints on the
    -- OTHER managed frames (live ADDON_ACTION_BLOCKED).  RemoveManagedFrame
    -- is no better -- it re-runs the whole manager Layout from insecure code.
    -- Accept the transient clobber instead: the container SetParent /
    -- SetPoint / Show / ApplySystemAnchor hooks re-pin right after it
    -- (deferred to PLAYER_REGEN_ENABLED when the clobber lands in combat).

    extraBtnState.containerOwned = true

    extraBtnState.hookingSetParent = true
    container:SetParent(holder)
    extraBtnState.hookingSetParent = false

    local anchorX, anchorY = GetExtraActionContainerAnchorOffset(
        container, ExtraActionBarFrame, scale, offsetX, offsetY)

    -- ExtraAbilityContainer is an EditMode system frame; use the *Base point
    -- setters when present so we bypass the EditMode SetPoint override (writing
    -- through the override from insecure code taints the EditMode layout system).
    extraBtnState.hookingSetPoint = true
    if container.ClearAllPointsBase and container.SetPointBase then
        container:ClearAllPointsBase()
        container:SetPointBase("CENTER", holder, "CENTER", anchorX, anchorY)
    else
        container:ClearAllPoints()
        container:SetPoint("CENTER", holder, "CENTER", anchorX, anchorY)
    end
    extraBtnState.hookingSetPoint = false
end

-- One-time neutralization of ExtraAbilityContainer's own layout/mouse/EditMode
-- behavior so it cannot fight our ownership.  Ownership is session-long: once
-- either extra or zone management acquires the shared container, a /reload is
-- the only hand-back.  Live restoration would re-enter Blizzard's protected
-- managed-layout path from insecure code.
function NeutralizeExtraAbilityContainer()
    local container = ExtraAbilityContainer
    if not container or extraBtnState.containerNeutralized then return end
    if InCombatLockdown() and not inInitSafeWindow then return end
    extraBtnState.containerNeutralized = true

    -- Stop Blizzard's OnShow/OnHide from re-running managed layout.  Our own
    -- Show hooksecurefunc still fires to re-pin.
    container:SetScript("OnShow", nil)
    container:SetScript("OnHide", nil)

    -- Hide the EditMode selection overlay (we own the position via our mover).
    local sel = container.Selection
    if sel then
        sel:SetAlpha(0)
        if sel.EnableMouse then sel:EnableMouse(false) end
        if not extraBtnState.containerSelectionHooked then
            extraBtnState.containerSelectionHooked = true
            hooksecurefunc(sel, "Show", function(self)
                self:SetAlpha(0)
                -- EnableMouse is protected on this frame (secure descendant).
                if self.EnableMouse and not InCombatLockdown() then
                    self:EnableMouse(false)
                end
            end)
        end
    end

    -- Keep ExtraActionBarFrame from absorbing clicks when empty.
    if ExtraActionBarFrame and ExtraActionBarFrame:IsMouseEnabled() then
        ExtraActionBarFrame:EnableMouse(false)
    end

    -- Newly added ability buttons must stay clickable.
    if container.AddFrame and not extraBtnState.containerAddFrameHooked then
        extraBtnState.containerAddFrameHooked = true
        hooksecurefunc(container, "AddFrame", function(_, frame)
            if frame and frame.EnableMouse and not InCombatLockdown() then
                frame:EnableMouse(true)
            end
        end)
    end
end

-- In-combat mutation probe for the zone path.  ZoneAbilityFrame is expected
-- unprotected (its spell buttons inherit no secure template) and nothing
-- protected anchors to it (the shared container's layout anchors every child
-- to the container itself, and the secure extra-action frame sorts FIRST by
-- priority), so the zone reclaim normally runs even in combat.  Trust the
-- client over that static expectation: if the frame reports protected or
-- anchoring-restricted (future FrameXML churn, a foreign anchor), defer the
-- mutation to PLAYER_REGEN_ENABLED instead of drawing ADDON_ACTION_BLOCKED.
-- Both getters' returns are secret-capable (ObjectSecurity aspect) and both
-- can throw on a tainted stack -- Helpers.FrameMutationRestricted pcalls each
-- getter and probes the answer before ANY truth-test; an error or unreadable
-- (secret) answer counts as restricted.
--
-- The HOLDER is probed too: the reclaim SetParents/SetPoints the zone frame
-- ONTO the holder and then SetSizes the holder itself, so a secure dependent
-- that restricts the holder (not the zone frame) blocks the same mutations.
-- Either frame restricted defers the whole reclaim to regen.
--
-- DELIBERATE SAFETY EXCEPTION to the dual-mover invariant: when this
-- fail-closed probe defers a mid-combat reclaim, the zone frame TEMPORARILY
-- remains inside the shared ExtraAbilityContainer — i.e. it rides the extra
-- mover's position — until PLAYER_REGEN_ENABLED reconciles. Taint-free
-- beats absolute two-mover separation during combat; the separation is
-- restored at regen. The window opens whenever the probe cannot PROVE the
-- zone frame and its holder mutable in combat: a protected dependent
-- anchoring to either (central frameAnchoring resolves "zoneAbility" to the
-- holder), the frame itself reporting protected, a secret answer from
-- either getter, or a getter throwing on a tainted stack — every one of
-- those counts as restricted.
local function ZoneFrameCombatMutable(frame, holder)
    if not InCombatLockdown() or inInitSafeWindow then return true end
    if Helpers.FrameMutationRestricted(frame) then return false end
    if holder and Helpers.FrameMutationRestricted(holder) then return false end
    return true
end

local function IsExtraButtonEnabled(buttonType)
    local settings = GetExtraButtonDB(buttonType)
    return (settings and settings.enabled) == true
end

-- SESSION-LONG OWNERSHIP: either enabled surface acquires the shared
-- ExtraAbilityContainer.  Once acquired, ownership remains until /reload.
-- This keeps the extracted zone entry from leaving an empty 250x120 managed
-- layout participant and avoids an insecure live hand-back through Blizzard's
-- protected managed-frame path.
function ShouldOwnExtraAbilityContainer()
    return extraBtnState.containerOwned
        or extraBtnState.zoneOwned
        or IsExtraButtonEnabled("extraActionButton")
        or IsExtraButtonEnabled("zoneAbility")
end

-- DUAL-MOVER INVARIANT (user requirement): extra action and zone ability
-- each keep their OWN mover; outside the deliberate safety exception above
-- (ZoneFrameCombatMutable deferring a restricted mid-combat reclaim until
-- PLAYER_REGEN_ENABLED), the zone ability never rides the extra-action
-- mover.  Once extracted, it stays on the zone holder for the session.  A
-- disabled setting resets stock appearance; /reload with both surfaces disabled
-- is the safe full hand-back to Blizzard.
function IsZoneAbilityManaged()
    return extraBtnState.zoneOwned or ShouldOwnExtraAbilityContainer()
end

-- Reparent the (unprotected) ZoneAbilityFrame onto its own holder.  Enabled
-- settings apply styling; disabled settings keep stock appearance on the same
-- session-owned holder.  Combat-legal in the expected topology (no
-- secure descendant, nothing protected anchored to it); the probe defers to
-- regen if the client disagrees.
local function EvictZoneAbilityFrame(scale, offsetX, offsetY)
    local blizzFrame = ZoneAbilityFrame
    local holder = extraBtnState.zoneAbilityHolder
    if not blizzFrame or not holder then return nil, nil end
    if not ZoneFrameCombatMutable(blizzFrame, holder) then
        ActionBarsOwned.pendingExtraButtonRefresh = true
        return nil, nil
    end
    blizzFrame:SetScale(scale)
    blizzFrame.ignoreInLayout = true
    blizzFrame.ignoreFramePositionManager = true
    extraBtnState.hookingSetParent = true
    blizzFrame:SetParent(holder)
    extraBtnState.hookingSetParent = false
    extraBtnState.hookingSetPoint = true
    blizzFrame:ClearAllPoints()
    blizzFrame:SetPoint("CENTER", holder, "CENTER", offsetX, offsetY)
    extraBtnState.hookingSetPoint = false
    extraBtnState.zoneOwned = true
    -- The zone entry stays in container.frames (RemoveFrame would
    -- SetParent(nil)+Hide the frame, and insecure writes into Blizzard's
    -- tables taint them).  ignoreInLayout makes the next Layout pass skip
    -- the evicted frame, but that pass only runs once something marks the
    -- container dirty -- do it here or the container keeps its stale
    -- two-child width.  Out of combat only: MarkDirty SetScripts OnUpdate
    -- (protected on this container -- secure descendant) and the insecure
    -- layout pass would SetPoint the protected extra bar; the deferred
    -- regen refresh re-runs the eviction and marks dirty then.
    local container = ExtraAbilityContainer
    if container and container.MarkDirty then
        if not InCombatLockdown() or inInitSafeWindow then
            pcall(container.MarkDirty, container)
        else
            ActionBarsOwned.pendingExtraButtonRefresh = true
        end
    end
    return blizzFrame, holder
end

function ApplyExtraButtonSettings(buttonType)
    local settings = GetExtraButtonDB(buttonType)
    local enabled = (settings and settings.enabled) == true
    local effectiveSettings = settings or {}
    local scale = enabled and (effectiveSettings.scale or 1.0) or 1.0
    local offsetX = enabled and (effectiveSettings.offsetX or 0) or 0
    local offsetY = enabled and (effectiveSettings.offsetY or 0) or 0

    local blizzFrame
    local holder

    if buttonType == "extraActionButton" then
        if not ShouldOwnExtraAbilityContainer() then return end
        -- COMBAT GATE (load-bearing).  ExtraActionBarFrame owns the secure
        -- ExtraActionButton1, so it (and its ancestors, the container
        -- included) cannot be rescaled/reparented/repinned in combat --
        -- SetScale/SetParent/ClearAllPoints/SetPoint would be
        -- ADDON_ACTION_BLOCKED.  Ownership is established once, out of combat:
        -- anchor the shared ExtraAbilityContainer to the mover, so Blizzard's
        -- in-combat AddFrame drops the button into a container that already
        -- sits on the mover (no addon in-combat repin needed).  A refresh that
        -- lands mid-combat is deferred to PLAYER_REGEN_ENABLED.
        if InCombatLockdown() and not inInitSafeWindow then
            ActionBarsOwned.pendingExtraButtonRefresh = true
            return
        end
        blizzFrame = ExtraActionBarFrame
        holder = extraBtnState.extraActionHolder
        if not blizzFrame or not holder then return end
        blizzFrame:SetScale(scale)
        -- Own the CONTAINER, not ExtraActionBarFrame (protected).  Zone-only
        -- management also takes shell ownership so its extracted entry cannot
        -- leave an empty managed-layout participant.
        ApplyExtraActionContainerAnchor(holder, offsetX, offsetY, scale)
        NeutralizeExtraAbilityContainer()
    else
        if not IsZoneAbilityManaged() then return end
        -- NO blanket combat gate: ZoneAbilityFrame is unprotected (its spell
        -- buttons inherit no secure template; OnClick is insecure
        -- CastSpellByID), and Blizzard re-adds it to the shared container
        -- from UNIT_AURA / SPELLS_CHANGED / ACTIONBAR_SLOT_CHANGED / vehicle
        -- events; all fire mid-combat, so the reclaim must run in
        -- combat too or a mid-fight grant strands the button at the Blizzard
        -- position until regen.  EvictZoneAbilityFrame still probes the live
        -- protection/anchoring state and self-defers to regen if the client
        -- reports the frame restricted.
        blizzFrame, holder = EvictZoneAbilityFrame(scale, offsetX, offsetY)
        if not blizzFrame or not holder then return end
    end

    local holderWidth, holderHeight = GetExtraButtonHolderSize(
        buttonType, blizzFrame, effectiveSettings, scale)
    holder:SetSize(holderWidth, holderHeight)

    if enabled and effectiveSettings.hideArtwork then
        if buttonType == "extraActionButton" and blizzFrame.button and blizzFrame.button.style then
            blizzFrame.button.style:SetAlpha(0)
        end
        if buttonType == "zoneAbility" and blizzFrame.Style then
            blizzFrame.Style:SetAlpha(0)
        end
    else
        if buttonType == "extraActionButton" and blizzFrame.button and blizzFrame.button.style then
            blizzFrame.button.style:SetAlpha(1)
        end
        if buttonType == "zoneAbility" and blizzFrame.Style then
            blizzFrame.Style:SetAlpha(1)
        end
    end

    if not enabled or not effectiveSettings.fadeEnabled then
        blizzFrame:SetAlpha(1)
    end

    -- Disabled means stock appearance now, not unsafe live ownership restore.
    -- A /reload with both surfaces disabled returns full ownership to Blizzard.
    if not enabled and type(SetupBarMouseover) == "function" then
        SetupBarMouseover(buttonType)
    end
end

pendingExtraButtonReanchor = {}

function QueueExtraButtonReanchor(buttonType)
    if pendingExtraButtonReanchor[buttonType] then return end
    pendingExtraButtonReanchor[buttonType] = true

    C_Timer.After(0, function()
        pendingExtraButtonReanchor[buttonType] = false

        -- Per-path combat handling lives in ApplyExtraButtonSettings and
        -- ApplyExtraButtonFrameAnchor: the protected extra path (settings AND
        -- holder anchor -- a granted button hangs a secure chain under the
        -- extra holder) defers itself to PLAYER_REGEN_ENABLED; the
        -- unprotected zone path applies even in combat (mid-fight grants).
        -- The zone path is also active when only EXTRA is enabled (dual-mover
        -- invariant: the disabled zone frame still holds its own mover).
        local active
        if buttonType == "zoneAbility" then
            active = IsZoneAbilityManaged()
        else
            active = ShouldOwnExtraAbilityContainer()
        end
        if active then
            ApplyExtraButtonSettings(buttonType)
            ApplyExtraButtonFrameAnchor(buttonType)
        end
    end)
end

function QueueManagedExtraButtonReanchor(buttonType)
    local holder = buttonType == "extraActionButton"
        and extraBtnState.extraActionHolder
        or extraBtnState.zoneAbilityHolder
    local active
    if buttonType == "zoneAbility" then
        active = IsZoneAbilityManaged()
    else
        active = ShouldOwnExtraAbilityContainer()
    end
    if holder and active then
        QueueExtraButtonReanchor(buttonType)
    end
end

-- Hook Blizzard frames to prevent them from repositioning.
-- After reparenting, the managed container won't reposition these frames,
-- but other Blizzard code (e.g. ability grant, zone transition) may call
-- SetPoint directly.  The hooks re-anchor to our holder after each attempt.
function HookExtraButtonPositioning()
    -- EXTRA ACTION: we own ExtraAbilityContainer.  Re-pin is driven by the
    -- container's own reposition/show and by ExtraActionBarFrame showing on a
    -- grant.  We deliberately do NOT hook ExtraActionBarFrame:SetParent --
    -- Blizzard must stay free to parent the bar INTO the container (that is how
    -- a granted button ends up riding our mover).
    if ExtraActionBarFrame and not extraBtnState.extraActionShowHooked then
        extraBtnState.extraActionShowHooked = true
        hooksecurefunc(ExtraActionBarFrame, "Show", function()
            QueueExtraButtonReanchor("extraActionButton")
        end)
    end

    if ExtraAbilityContainer and not extraBtnState.extraAbilityContainerSetPointHooked then
        extraBtnState.extraAbilityContainerSetPointHooked = true
        hooksecurefunc(ExtraAbilityContainer, "SetPoint", function()
            if extraBtnState.hookingSetPoint then return end
            C_Timer.After(0, function()
                if extraBtnState.hookingSetPoint then return end
                QueueManagedExtraButtonReanchor("extraActionButton")
            end)
        end)
    end

    if ExtraAbilityContainer and not extraBtnState.extraAbilityContainerSetParentHooked then
        extraBtnState.extraAbilityContainerSetParentHooked = true
        hooksecurefunc(ExtraAbilityContainer, "SetParent", function()
            if extraBtnState.hookingSetParent then return end
            C_Timer.After(0, function()
                if extraBtnState.hookingSetParent then return end
                QueueManagedExtraButtonReanchor("extraActionButton")
            end)
        end)
    end

    if ExtraAbilityContainer and not extraBtnState.extraAbilityContainerShowHooked then
        extraBtnState.extraAbilityContainerShowHooked = true
        hooksecurefunc(ExtraAbilityContainer, "Show", function()
            QueueManagedExtraButtonReanchor("extraActionButton")
        end)
    end

    -- Edit Mode re-applies its own anchor to the container; reclaim it.
    if ExtraAbilityContainer and ExtraAbilityContainer.ApplySystemAnchor
        and not extraBtnState.extraAbilityContainerAnchorHooked then
        extraBtnState.extraAbilityContainerAnchorHooked = true
        hooksecurefunc(ExtraAbilityContainer, "ApplySystemAnchor", function()
            QueueManagedExtraButtonReanchor("extraActionButton")
        end)
    end

    -- ZONE ABILITY: unprotected frame reparented straight onto its own mover.
    -- Reclaim it if Blizzard re-adds it to the shared container.  Blizzard
    -- updates it from UNIT_AURA / SPELLS_CHANGED / ACTIONBAR_SLOT_CHANGED /
    -- vehicle events, which fire mid-combat, and AddFrame reparents it into
    -- the container each time — so the reclaim runs in combat too.  That is
    -- legal: the frame has no secure descendant.  The C_Timer.After(0) hop
    -- stays load-bearing — it exits the secure execution context of the
    -- Blizzard event dispatch that triggered the reparent.
    local function HookSetParentForType(blizzFrame, buttonType, holder)
        if not blizzFrame then return end
        hooksecurefunc(blizzFrame, "SetParent", function(self, newParent)
            if extraBtnState.hookingSetParent then return end
            if newParent == holder then return end
            C_Timer.After(0, function()
                if extraBtnState.hookingSetParent then return end
                -- Dual-mover invariant: the zone frame is reclaimed whenever
                -- EITHER surface is managed (extra ownership of the shared
                -- container implies zone eviction to its own holder).
                if holder and IsZoneAbilityManaged() then
                    if not ZoneFrameCombatMutable(blizzFrame, holder) then
                        ActionBarsOwned.pendingExtraButtonRefresh = true
                        return
                    end
                    extraBtnState.hookingSetParent = true
                    blizzFrame:SetParent(holder)
                    extraBtnState.hookingSetParent = false
                    QueueExtraButtonReanchor(buttonType)
                end
            end)
        end)
    end

    if ZoneAbilityFrame and not extraBtnState.zoneAbilitySetPointHooked then
        extraBtnState.zoneAbilitySetPointHooked = true
        hooksecurefunc(ZoneAbilityFrame, "SetPoint", function(self)
            if extraBtnState.hookingSetPoint then return end
            C_Timer.After(0, function()
                if extraBtnState.hookingSetPoint then return end
                QueueManagedExtraButtonReanchor("zoneAbility")
            end)
        end)
    end
    if ZoneAbilityFrame and not extraBtnState.zoneAbilitySetParentHooked then
        extraBtnState.zoneAbilitySetParentHooked = true
        HookSetParentForType(ZoneAbilityFrame, "zoneAbility", extraBtnState.zoneAbilityHolder)
    end
    if ZoneAbilityFrame and not extraBtnState.zoneAbilityShowHooked then
        extraBtnState.zoneAbilityShowHooked = true
        hooksecurefunc(ZoneAbilityFrame, "Show", function()
            QueueExtraButtonReanchor("zoneAbility")
        end)
    end

    -- Container housekeeping runs from the extra branch for either enabled
    -- surface.  Once acquired, ownership stays session-long; /reload with both
    -- surfaces disabled is the full Blizzard hand-back.
end

function ShowExtraButtonMovers()
    extraBtnState.moversVisible = true
    if extraBtnState.extraActionMover then extraBtnState.extraActionMover:Show() end
    if extraBtnState.zoneAbilityMover then extraBtnState.zoneAbilityMover:Show() end
end

function HideExtraButtonMovers()
    extraBtnState.moversVisible = false
    if extraBtnState.extraActionMover then extraBtnState.extraActionMover:Hide() end
    if extraBtnState.zoneAbilityMover then extraBtnState.zoneAbilityMover:Hide() end
end

function ToggleExtraButtonMovers()
    if extraBtnState.moversVisible then
        HideExtraButtonMovers()
    else
        ShowExtraButtonMovers()
    end
end

-- Assign to upvalue for forward declaration in event handler
InitializeExtraButtons = function()
    if InCombatLockdown() and not inInitSafeWindow then
        ActionBarsOwned.pendingExtraButtonInit = true
        return
    end

    -- Idempotent: a deferred re-init (pendingExtraButtonInit) must not create
    -- a second set of named holder frames.
    if not extraBtnState.extraActionHolder then
        extraBtnState.extraActionHolder, extraBtnState.extraActionMover =
            CreateExtraButtonHolder("extraActionButton", "Extra Action Button")
    end
    if not extraBtnState.zoneAbilityHolder then
        extraBtnState.zoneAbilityHolder, extraBtnState.zoneAbilityMover =
            CreateExtraButtonHolder("zoneAbility", "Zone Ability")
    end

    local function applyAll()
        ApplyExtraButtonSettings("extraActionButton")
        ApplyExtraButtonFrameAnchor("extraActionButton")
        ApplyExtraButtonSettings("zoneAbility")
        ApplyExtraButtonFrameAnchor("zoneAbility")
        HookExtraButtonPositioning()
    end

    -- Combat /reload: protected calls are only allowed while the PEW init
    -- safe window is open.  A 0.5s timer lands after the window closes, so
    -- the extra path would defer to PLAYER_REGEN_ENABLED and active buttons
    -- would sit at Blizzard positions for the rest of that combat.  Take
    -- ownership synchronously inside the window; the delayed pass stays as a
    -- reconcile for Blizzard frames that settle late.
    if inInitSafeWindow then
        applyAll()
    end
    C_Timer.After(0.5, applyAll)
end

-- Assign to upvalue for forward declaration in event handler
RefreshExtraButtons = function()
    -- No blanket combat gate: per-path handling lives in
    -- ApplyExtraButtonSettings.  The protected extra path defers itself to
    -- PLAYER_REGEN_ENABLED; the unprotected zone path applies live so
    -- mid-combat grants and refreshes track the mover.
    ApplyExtraButtonSettings("extraActionButton")
    ApplyExtraButtonFrameAnchor("extraActionButton")
    ApplyExtraButtonSettings("zoneAbility")
    ApplyExtraButtonFrameAnchor("zoneAbility")
    -- Set up hooks on any newly available frames (handles late-loaded
    -- frames like ZoneAbilityFrame that may not exist at init time).
    HookExtraButtonPositioning()
end

_G.QUI_ToggleExtraButtonMovers = ToggleExtraButtonMovers
_G.QUI_RefreshExtraButtons = RefreshExtraButtons
ActionBarsOwned.extraBtnState = extraBtnState

end -- do (extra buttons)

---------------------------------------------------------------------------
