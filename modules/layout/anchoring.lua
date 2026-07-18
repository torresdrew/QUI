--[[
    QUI Anchoring Module
    Unified anchoring system for castbars, unit frames, and custom frames
    Supports 9-point anchoring with X/Y offsets and dynamic anchor target registration
]]

local ADDON_NAME, ns = ...
local QUICore = ns.Addon
local nsHelpers = ns.Helpers

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_Anchoring = {}
ns.QUI_Anchoring = QUI_Anchoring

-- During early init, UIParent dimensions haven't settled (UI scale not fully
-- applied). Size-stable CENTER offset computation produces wrong values.
-- Force raw-point anchoring until dimensions are stable.
local _forceRawPointMode = true
C_Timer.After(0.5, function() _forceRawPointMode = false end)

-- Declared at module scope so the early writers (PositionFrame, the edit-mode
-- anchor guards, ApplyFrameAnchor) and the PLAYER_REGEN_ENABLED reader share ONE
-- upvalue. Previously the `local` lived below those writers, so they assigned a
-- stray global and combat-deferred re-positioning was silently dropped.
local pendingAnchoredFrameUpdateAfterCombat = false

-- Consumer-specific operations (position-only re-anchor, overlay anchoring)
-- that combat blocked, latched for the PLAYER_REGEN_ENABLED reconcile.
-- [originKey] = { [slotKey] = op }. The regen reconcile's bulk apply only
-- re-runs the DEFAULT apply (QUI_ApplyFrameAnchor, auto-sizing included);
-- without this latch a blocked consumer operation is silently replaced by
-- that full apply — a position-only consumer whose module owns the frame's
-- size then gets auto-sized (repro: width 77 → 333). Slots mirror the
-- resolve-retry slots (clearResolveRetrySlots drops a latched op once its
-- consumer resolves fully readable).
local pendingCombatConsumerOps = {}

local function latchCombatConsumerOp(originKey, slotKey, op)
    if not originKey or type(op) ~= "function" then return end
    local bySlot = pendingCombatConsumerOps[originKey]
    if not bySlot then
        bySlot = {}
        pendingCombatConsumerOps[originKey] = bySlot
    end
    bySlot[slotKey or "apply"] = op
end

local function drainPendingCombatConsumerOps()
    if next(pendingCombatConsumerOps) == nil then return end
    -- Swap in a clean table first: a replay that re-latches (fresh combat,
    -- another unreadable walk) must land in live state, not be dropped with
    -- the snapshot.
    local snapshot = pendingCombatConsumerOps
    pendingCombatConsumerOps = {}
    for originKey, bySlot in pairs(snapshot) do
        for _, op in pairs(bySlot) do
            -- pcall: one throwing consumer must not drop the remaining
            -- latched operations.
            pcall(op, originKey)
        end
    end
end

-- Anchor target registry: { name = { frame = frame, options = {...} } }
QUI_Anchoring.anchorTargets = {}

-- Category registry: { categoryName = { order = number } }
QUI_Anchoring.categories = {}

-- Anchored frame registry: { frame = { anchorTarget = name, anchorPoint = point, offsetX = x, offsetY = y, parentFrame = frame } }

-- Frames with active anchoring overrides — module positioning is blocked for these
QUI_Anchoring.layoutOwnedFrames = {}
-- Keys that a module has claimed for direct (module-driven) positioning.
-- ApplyFrameAnchor and ApplyAllFrameAnchors will SKIP these keys entirely,
-- including any saved or default frameAnchoring entries.  Used by features
-- like the resource bar swap that need to override anchored layouts
-- temporarily while still letting them snap back on release.  Module is
-- responsible for re-triggering anchor application when releasing the claim.
QUI_Anchoring.claimedAnchorKeys = {}

local Helpers = {}

-- Forward-declared tables (populated later, referenced by ResolveFrameForKey)
local CDM_LOGICAL_SIZE_KEYS = {}

-- Corner anchor names — used by the growAnchor apply-time conversion to
-- validate the corner string from FA entries.
local CORNER_POINTS = {
    TOPLEFT     = true,
    TOPRIGHT    = true,
    BOTTOMLEFT  = true,
    BOTTOMRIGHT = true,
}

-- Edit Mode hook state (declared early so ApplyFrameAnchor can set the guard)
local _editModeReapplyGuard = false  -- prevents recursive reapply during QUI's own SetPoint

-- Position-match check: returns true if the frame already has exactly one
-- anchor point matching the desired values.  Used by the Edit Mode ticker
-- to skip ClearAllPoints+SetPoint when Blizzard hasn't moved the frame,
-- preventing visual flashing on objective tracker, minimap children, etc.
local function FrameAlreadyAtPosition(frame, pt, relativeTo, relPt, x, y)
    if not frame or not frame.GetNumPoints then return false end
    if frame:GetNumPoints() ~= 1 then return false end
    local cp, crt, crp, cx, cy = frame:GetPoint(1)
    if cp ~= pt or crt ~= relativeTo or crp ~= relPt then return false end
    return math.abs((cx or 0) - (x or 0)) < 0.1 and math.abs((cy or 0) - (y or 0)) < 0.1
end

-- Smooth SetPoint: update an existing anchor in place when the point name
-- matches, avoiding the ClearAllPoints→SetPoint gap that causes a single-
-- frame visual "jiggle" (frame has no position between clear and set).
-- Falls back to ClearAllPoints+SetPoint when the point name differs or the
-- frame has multiple anchors.
local function SmoothSetPoint(frame, pt, relativeTo, relPt, x, y)
    -- Prefer the Edit Mode *Base setters so anchoring a detached system frame
    -- (e.g. ChatFrame1, anchored via Frame Positioning) never re-enters
    -- EditModeManagerFrame and taints its secure chat-event dispatch. Plain
    -- frames have no *Base method, so this is a transparent passthrough.
    local H = ns.Helpers
    local numPts = frame:GetNumPoints()
    if numPts == 1 then
        local cp = frame:GetPoint(1)
        if cp == pt then
            -- Same point name — update in place, no ClearAllPoints needed
            H.BaseSetPoint(frame, pt, relativeTo, relPt, x, y)
            return
        end
    end
    H.BaseClearAllPoints(frame)
    H.BaseSetPoint(frame, pt, relativeTo, relPt, x, y)
end

---------------------------------------------------------------------------
-- SECURE TAINT CLEANER — REMOVED (Unlock Mode replaced Edit Mode dependency)
-- Proxy-based positioning eliminated; all frame positioning defers to
-- PLAYER_REGEN_ENABLED when in combat. No taint to clean.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- SETUP HELPERS
---------------------------------------------------------------------------
function QUI_Anchoring:SetHelpers(helpers)
    Helpers = helpers or {}
end

-- Helper function wrappers (with fallbacks)
local function Scale(x, frame)
    return Helpers.Scale and Helpers.Scale(x, frame) or (QUICore and QUICore.Scale and QUICore:Scale(x, frame) or x)
end

local function PixelRound(frame, value)
    if value == 0 then return 0 end
    if QUICore and QUICore.PixelRound then
        return QUICore:PixelRound(value, frame)
    end
    return value
end

-- Only raw/saved frameAnchoring entries count as explicit overrides here.
-- AceDB serves defaults through metatables, and those defaults should not
-- suppress module-owned positioning logic unless the user actually saved an
-- override entry for that key.
--
-- Detection uses rawget so a key with no saved override returns nil (the
-- module owns positioning). But once an override exists, return the AceDB
-- proxy table — fields whose values match the default get stripped on save,
-- and the apply path (parent/point/relative reads, etc.) needs them filled
-- back in. Returning the raw stripped table caused castbars whose default
-- parent matches the saved value (e.g. playerCastbar parent="playerFrame")
-- to apply with parent=nil → fall back to UIParent CENTER → bar drifts to
-- screen center after the first reload following an import.
local function GetSavedFrameAnchorSettings(anchoringDB, key)
    if type(anchoringDB) ~= "table" or not key then
        return nil
    end
    if rawget(anchoringDB, key) == nil then
        return nil
    end
    local settings = anchoringDB[key]
    if type(settings) == "table" then
        return settings
    end
    return nil
end

local function GetBorderAdjustment(anchorPoint, borderSize)
    if not borderSize or borderSize == 0 then return 0, 0 end

    local adjX, adjY = 0, 0
    if anchorPoint == "TOPLEFT" then
        adjX = borderSize
        adjY = -borderSize
    elseif anchorPoint == "TOP" then
        adjY = -borderSize
    elseif anchorPoint == "TOPRIGHT" then
        adjX = -borderSize
        adjY = -borderSize
    elseif anchorPoint == "LEFT" then
        adjX = borderSize
    elseif anchorPoint == "RIGHT" then
        adjX = -borderSize
    elseif anchorPoint == "BOTTOMLEFT" then
        adjX = borderSize
        adjY = borderSize
    elseif anchorPoint == "BOTTOM" then
        adjY = borderSize
    elseif anchorPoint == "BOTTOMRIGHT" then
        adjX = -borderSize
        adjY = borderSize
    end
    return adjX, adjY
end

---------------------------------------------------------------------------
-- ANCHOR TARGET REGISTRY
---------------------------------------------------------------------------
-- Register a frame as an anchor target with a custom name
-- options can include: displayName, category, categoryOrder (for category sorting), order (for item sorting within category), and other custom properties
function QUI_Anchoring:RegisterAnchorTarget(name, frame, options)
    if not name or not frame then
        return false
    end

    options = options or {}
    self.anchorTargets[name] = {
        frame = frame,
        options = options
    }

    -- Register category with its order if provided
    local category = options.category
    if category then
        if not self.categories[category] then
            self.categories[category] = {
                order = options.categoryOrder or 999
            }
        end
    end

    return true
end

-- Unregister an anchor target
function QUI_Anchoring:UnregisterAnchorTarget(name)
    if not name then return false end
    self.anchorTargets[name] = nil
    return true
end

-- Get an anchor target by name
function QUI_Anchoring:GetAnchorTarget(name)
    if not name then return nil end

    -- Check registry only
    local registered = self.anchorTargets[name]
    if registered then
        return registered.frame
    end

    return nil
end

-- Get list of registered anchor targets for options dropdowns
-- Parameters:
--   include: optional table of anchor values to include (if provided, only these are included)
--   exclude: optional table of anchor values to exclude (if provided, these are filtered out)
--   excludeSelf: optional anchor target name to exclude (prevents self-anchoring)
-- Returns array of {value = name, text = displayName}
function QUI_Anchoring:GetAnchorTargetList(include, exclude, excludeSelf)
    exclude = exclude or {}

    -- Convert include/exclude to lookup tables for faster checking
    local includeLookup = {}
    local excludeLookup = {}

    if include == nil then
        includeLookup = nil
    elseif type(include) == "table" then
        for _, value in ipairs(include) do
            includeLookup[value] = true
        end
    end

    if type(exclude) == "table" then
        for _, value in ipairs(exclude) do
            excludeLookup[value] = true
        end
    end

    -- Helper to check if an anchor should be included
    local function ShouldInclude(value)
        -- Check exclude first
        if excludeLookup[value] then
            return false
        end
        -- Check excludeSelf (prevents self-anchoring)
        if excludeSelf and value == excludeSelf then
            return false
        end
        -- If include list is provided, check it
        if includeLookup then
            return includeLookup[value] == true
        end
        -- Otherwise include all
        return true
    end

    local list = {}

    -- Add special anchor targets (always check include/exclude)
    if ShouldInclude("disabled") then
        table.insert(list, {value = "disabled", text = "Disabled"})
    end
    if ShouldInclude("screen") then
        table.insert(list, {value = "screen", text = "Screen Center"})
    end

    -- Group registered anchor targets by category
    local categorized = {}
    local uncategorized = {}

    for name, data in pairs(self.anchorTargets) do
        if ShouldInclude(name) then
            local displayName = data.options and data.options.displayName or name
            displayName = tostring(displayName)
            -- Capitalize first letter and add spaces before capitals
            displayName = displayName:gsub("^%l", string.upper)
            displayName = displayName:gsub("([a-z])([A-Z])", "%1 %2")

            local category = data.options and data.options.category
            local order = data.options and data.options.order or 999
            local item = {value = name, text = displayName, category = category, order = order}

            if category then
                if not categorized[category] then
                    categorized[category] = {}
                end
                table.insert(categorized[category], item)
            else
                table.insert(uncategorized, item)
            end
        end
    end

    -- Sort categories by order (from category registry), then alphabetically
    local sortedCategories = {}
    for category, items in pairs(categorized) do
        local categoryInfo = self.categories[category] or {}
        local categoryOrder = categoryInfo.order or 999
        table.insert(sortedCategories, {name = category, order = categoryOrder})
        -- Sort items within category by order, then by text
        table.sort(items, function(a, b)
            if a.order ~= b.order then
                return a.order < b.order
            end
            return a.text < b.text
        end)
    end
    table.sort(sortedCategories, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.name < b.name
    end)

    -- Sort uncategorized items
    table.sort(uncategorized, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.text < b.text
    end)

    -- Build final list: special values, then categorized items, then uncategorized
    -- Add categorized items with headers
    for _, catInfo in ipairs(sortedCategories) do
        local category = catInfo.name
        -- Add category header (non-clickable, value is nil)
        table.insert(list, {value = nil, text = category, isHeader = true})
        -- Add items in this category
        for _, item in ipairs(categorized[category]) do
            table.insert(list, item)
        end
    end

    -- Add uncategorized items (only if there are any)
    if #uncategorized > 0 then
        -- Only add "Other" header if we have categorized items above
        if #sortedCategories > 0 then
            table.insert(list, {value = nil, text = "Other", isHeader = true})
        end
        for _, item in ipairs(uncategorized) do
            table.insert(list, item)
        end
    end

    return list
end

---------------------------------------------------------------------------
-- BORDER HELPER
---------------------------------------------------------------------------
-- Get border size from a frame's backdrop
local function GetBorderSize(frame)
    if not frame or not frame.GetBackdrop then
        return 0
    end

    local backdrop = frame:GetBackdrop()
    if not backdrop or not backdrop.edgeSize then
        return 0
    end

    return backdrop.edgeSize or 0
end

---------------------------------------------------------------------------
-- 9-POINT ANCHORING API
---------------------------------------------------------------------------
-- Valid anchor points
local VALID_ANCHOR_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Position a frame using 9-point anchoring system
-- Supports explicit dual anchor points or auto-detection based on source and target anchor point alignment
-- Parameters:
--   frame: Frame to position
--   anchorTarget: Name of anchor target or "none"/"disabled"/"screen"/"unitframe"
--   anchorPoint: Primary source anchor point (TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, RIGHT, BOTTOMLEFT, BOTTOM, BOTTOMRIGHT)
--   offsetX: X offset in pixels (this IS the gap/padding - maintains spacing when anchor target changes size)
--   offsetY: Y offset in pixels (this IS the gap/padding - maintains spacing when anchor target changes size)
--   parentFrame: Optional parent frame (for "unitframe" anchor type)
--   options: Optional table with:
--     - targetAnchorPoint: Primary target anchor point (defaults to source anchorPoint)
--     - sourceAnchorPoint2: Secondary source anchor point for dual anchors (e.g., "TOPRIGHT")
--     - targetAnchorPoint2: Secondary target anchor point for dual anchors (e.g., "BOTTOMRIGHT")
function QUI_Anchoring:PositionFrame(frame, anchorTarget, anchorPoint, offsetX, offsetY, parentFrame, options)
    if not frame then return false end

    -- Skip module positioning if this frame has an active anchoring override
    if self.layoutOwnedFrames[frame] then return true end

    -- Defer positioning if in combat or secure context to avoid taint.
    -- Allow during ADDON_LOADED / PEW safe window (ns._inInitSafeWindow).
    if InCombatLockdown() and not ns._inInitSafeWindow then
        pendingAnchoredFrameUpdateAfterCombat = true
        return false
    end

    options = options or {}
    offsetX = offsetX or 0
    offsetY = offsetY or 0

    -- Validate anchor point
    anchorPoint = anchorPoint or "CENTER"
    if not VALID_ANCHOR_POINTS[anchorPoint] then
        anchorPoint = "CENTER"
    end

    -- Get target anchor point from options (defaults to source anchor point for backward compatibility)
    local targetAnchorPoint = options.targetAnchorPoint or anchorPoint
    if not VALID_ANCHOR_POINTS[targetAnchorPoint] then
        targetAnchorPoint = anchorPoint
    end

    -- Check if explicit dual anchor points are provided
    local sourceAnchorPoint2 = options.sourceAnchorPoint2
    local targetAnchorPoint2 = options.targetAnchorPoint2
    local useExplicitDualAnchors = sourceAnchorPoint2 and targetAnchorPoint2 and
                                   VALID_ANCHOR_POINTS[sourceAnchorPoint2] and
                                   VALID_ANCHOR_POINTS[targetAnchorPoint2]

    -- Safely clear points (use pcall to handle secure frames)
    local success = pcall(function()
        frame:ClearAllPoints()
    end)
    if not success then
        -- Frame is secure/managed - defer the call
        C_Timer.After(0, function()
            if InCombatLockdown() then
                pendingAnchoredFrameUpdateAfterCombat = true
                return
            end
            if frame and frame.ClearAllPoints then
                pcall(frame.ClearAllPoints, frame)
            end
        end)
        return false
    end

    -- Handle "none", "disabled", or "screen" anchor targets (absolute positioning to screen center)
    -- "none" is kept for backward compatibility with existing castbar settings
    if not anchorTarget or anchorTarget == "none" or anchorTarget == "disabled" or anchorTarget == "screen" then
        frame:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
        return true
    end

    -- Handle "unitframe" anchor type (special case for castbars)
    if anchorTarget == "unitframe" and parentFrame then
        -- Get border sizes for pixel-perfect positioning
        local sourceBorderSize = GetBorderSize(frame)
        local targetBorderSize = GetBorderSize(parentFrame)

        -- Calculate border adjustments
        local sourceAdjX, sourceAdjY = GetBorderAdjustment(anchorPoint, sourceBorderSize)
        local targetAdjX, targetAdjY = GetBorderAdjustment(targetAnchorPoint, targetBorderSize)
        local netAdjX = targetAdjX - sourceAdjX
        local netAdjY = targetAdjY - sourceAdjY

        local scaledOffsetX = PixelRound(frame, Scale(offsetX, frame) + netAdjX)
        local scaledOffsetY = PixelRound(frame, Scale(offsetY, frame) + netAdjY)

        -- Use explicit dual anchors if provided
        if useExplicitDualAnchors then
            local sourceAdjX2, sourceAdjY2 = GetBorderAdjustment(sourceAnchorPoint2, sourceBorderSize)
            local targetAdjX2, targetAdjY2 = GetBorderAdjustment(targetAnchorPoint2, targetBorderSize)
            local netAdjX2 = targetAdjX2 - sourceAdjX2
            local netAdjY2 = targetAdjY2 - sourceAdjY2

            local scaledOffsetX2 = PixelRound(frame, Scale(offsetX, frame) + netAdjX2)
            local scaledOffsetY2 = PixelRound(frame, Scale(offsetY, frame) + netAdjY2)

            frame:SetPoint(anchorPoint, parentFrame, targetAnchorPoint, scaledOffsetX, scaledOffsetY)
            frame:SetPoint(sourceAnchorPoint2, parentFrame, targetAnchorPoint2, scaledOffsetX2, scaledOffsetY2)
            return true
        end

        -- Use source and target anchor points for single anchor positioning
        frame:SetPoint(anchorPoint, parentFrame, targetAnchorPoint, scaledOffsetX, scaledOffsetY)
        return true
    end

    -- Get anchor target frame
    local anchorFrame = self:GetAnchorTarget(anchorTarget)
    if not anchorFrame then
        return false
    end

    if not anchorFrame:IsShown() then
        return false
    end

    -- Get border sizes for pixel-perfect positioning
    local sourceBorderSize = GetBorderSize(frame)
    local targetBorderSize = GetBorderSize(anchorFrame)

    -- Calculate border adjustments
    local sourceAdjX, sourceAdjY = GetBorderAdjustment(anchorPoint, sourceBorderSize)
    local targetAdjX, targetAdjY = GetBorderAdjustment(targetAnchorPoint, targetBorderSize)
    local netAdjX = targetAdjX - sourceAdjX
    local netAdjY = targetAdjY - sourceAdjY

    -- offsetX and offsetY already provide the gap/padding functionality
    -- When the anchor target changes size, the offset maintains that gap
    local scaledOffsetX = PixelRound(frame, Scale(offsetX, frame) + netAdjX)
    local scaledOffsetY = PixelRound(frame, Scale(offsetY, frame) + netAdjY)

    -- Use explicit dual anchors if provided
    if useExplicitDualAnchors then
        local sourceAdjX2, sourceAdjY2 = GetBorderAdjustment(sourceAnchorPoint2, sourceBorderSize)
        local targetAdjX2, targetAdjY2 = GetBorderAdjustment(targetAnchorPoint2, targetBorderSize)
        local netAdjX2 = targetAdjX2 - sourceAdjX2
        local netAdjY2 = targetAdjY2 - sourceAdjY2

        -- offsetX and offsetY already provide the gap/padding for both anchor points
        local scaledOffsetX2 = PixelRound(frame, Scale(offsetX, frame) + netAdjX2)
        local scaledOffsetY2 = PixelRound(frame, Scale(offsetY, frame) + netAdjY2)

        frame:SetPoint(anchorPoint, anchorFrame, targetAnchorPoint, scaledOffsetX, scaledOffsetY)
        frame:SetPoint(sourceAnchorPoint2, anchorFrame, targetAnchorPoint2, scaledOffsetX2, scaledOffsetY2)
        return true
    end

    -- For single anchor point positioning, use direct SetPoint with source and target anchor points
    frame:SetPoint(anchorPoint, anchorFrame, targetAnchorPoint, scaledOffsetX, scaledOffsetY)

    return true
end

-- Snap a frame to an anchor target
-- Parameters:
--   frame: The frame to snap
--   anchorTarget: Name of the anchor target to snap to
--   anchorPoint: Anchor point (default: "BOTTOMLEFT" for most, "CENTER" for screen/disabled)
--   offsetX: X offset (default: 0)
--   offsetY: Y offset (default: 0)
--   options: Optional table with:
--     - checkVisible: If true, only snap if target is visible (default: true)
--     - setWidth: If true, set frame width to match target (default: false)
--     - clearWidth: If true, clear width setting (default: false)
--     - onSuccess: Callback function called on successful snap
--     - onFailure: Callback function called if snap fails
-- Returns: true if successful, false otherwise
function QUI_Anchoring:SnapTo(frame, anchorTarget, anchorPoint, offsetX, offsetY, options)
    if not frame or not anchorTarget then
        return false
    end

    options = options or {}
    offsetX = offsetX or 0
    offsetY = offsetY or 0

    -- Get anchor target frame
    local targetFrame = self:GetAnchorTarget(anchorTarget)
    if not targetFrame then
        if options.onFailure then
            options.onFailure("Anchor target not found: " .. tostring(anchorTarget))
        end
        return false
    end

    -- Check if target is visible (if requested)
    if options.checkVisible ~= false then
        if not targetFrame:IsShown() then
            if options.onFailure then
                local registered = self.anchorTargets and self.anchorTargets[anchorTarget]
                local displayName = registered and registered.options and registered.options.displayName or anchorTarget
                options.onFailure(displayName .. " not visible.")
            end
            return false
        end
    end

    -- Determine anchor point
    if not anchorPoint then
        if anchorTarget == "screen" or anchorTarget == "disabled" or anchorTarget == "none" then
            anchorPoint = "CENTER"
        else
            anchorPoint = "BOTTOMLEFT"
        end
    end

    -- Position the frame (dual anchors auto-detected based on anchor points)
    local positionOptions = {
        targetAnchorPoint = options.targetAnchorPoint,
    }
    local success = self:PositionFrame(frame, anchorTarget, anchorPoint, offsetX, offsetY, nil, positionOptions)

    -- Re-register state drivers for unit frames after positioning (ClearAllPoints breaks them)
    if success and frame._quiReRegisterStateDriver then
        C_Timer.After(0, function()
            if frame and frame._quiReRegisterStateDriver then
                frame._quiReRegisterStateDriver()
            end
        end)
    end

    if success and options.onSuccess then
        options.onSuccess()
    end

    return success
end

local anchoredFramesCombatFrame = CreateFrame("Frame")
anchoredFramesCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
anchoredFramesCombatFrame:SetScript("OnEvent", function()
    if not pendingAnchoredFrameUpdateAfterCombat
        and next(pendingCombatConsumerOps) == nil then return end

    -- The bulk apply runs only when the FLAG was set: a lone latched
    -- consumer op (position-only started in combat) must replay exactly
    -- itself, not be substituted by the auto-sizing full apply.
    local runFullApply = pendingAnchoredFrameUpdateAfterCombat
    pendingAnchoredFrameUpdateAfterCombat = false
    C_Timer.After(0.05, function()
        if InCombatLockdown() then
            -- Re-latch; consumer ops are still in pendingCombatConsumerOps.
            if runFullApply then
                pendingAnchoredFrameUpdateAfterCombat = true
            end
            return
        end
        if runFullApply and QUI_Anchoring then
            -- Every live writer of the pending flag (edit-mode layout swaps,
            -- anchor guards, ApplyFrameAnchor, PositionFrame) deferred a
            -- POSITION RE-STAMP; the retired legacy-registry walk that used
            -- to sit here no-oped over an empty table and lost it.
            local applyOK, status = pcall(
                QUI_Anchoring.ApplyAllFrameAnchors, QUI_Anchoring,
                false, drainPendingCombatConsumerOps)
            if not applyOK then
                -- The required full reconcile did not complete. Keep both the
                -- consumer ops and their queued after-apply drain alive, and
                -- retry the full pass on the next regen instead of silently
                -- degrading it to a consumer-only replay.
                pendingAnchoredFrameUpdateAfterCombat = true
                return
            end
            -- No pass can complete when the profile/layout is unavailable;
            -- do not strand the independently replayable consumer operations.
            if status == "skipped" then
                drainPendingCombatConsumerOps()
            end
            return
        end
        -- Consumer ops drain AFTER the bulk apply so their re-stamp (overlay
        -- position, size-untouched re-anchor) lands on top of it.
        drainPendingCombatConsumerOps()
    end)
end)

-- Re-apply QUI anchors when Blizzard re-applies its Edit Mode layout.
-- This fires on spec change (Blizzard swaps per-spec Edit Mode layouts),
-- login, and any other scenario where Blizzard repositions system frames.
-- Without this, Blizzard's layout pass can override QUI's frame positions.
local layoutUpdateFrame = CreateFrame("Frame")
layoutUpdateFrame:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")
local _layoutUpdatePending = false
layoutUpdateFrame:SetScript("OnEvent", function()
    if _layoutUpdatePending then return end
    _layoutUpdatePending = true
    -- Delay to let Blizzard finish its full layout pass before we re-stamp
    C_Timer.After(0.3, function()
        _layoutUpdatePending = false
        if InCombatLockdown() then
            pendingAnchoredFrameUpdateAfterCombat = true
            return
        end
        if not nsHelpers.IsEditModeActive() then
            if QUI_Anchoring then
                QUI_Anchoring:ApplyAllFrameAnchors()
            end
            -- Also re-position unit frames and group frames — Blizzard's per-spec
            -- layout pass overwrites QUI's positions for frames not in the
            -- anchoring system
            local RefreshUnitFrames = _G.QUI_RefreshUnitFrames
            if RefreshUnitFrames then pcall(RefreshUnitFrames) end
            local RefreshGroupFrames = _G.QUI_RefreshGroupFrames
            if RefreshGroupFrames then pcall(RefreshGroupFrames) end
        end
    end)
end)

---------------------------------------------------------------------------
-- EDIT MODE ANCHOR GUARD (3-layer defense)
-- Prevents Blizzard Edit Mode from overwriting QUI's frame positions.
--
-- Layer 1: ApplySystemAnchor post-hooks on each managed Blizzard frame
--          (catches individual frame repositioning during layout apply)
-- Layer 2: EditModeManagerFrame ExitEditMode hook
--          (full reapply when the Edit Mode panel closes)
-- Layer 3: EDIT_MODE_LAYOUTS_UPDATED event (above)
--          (catches spec changes, login, and other layout swaps)
---------------------------------------------------------------------------

-- Forward declarations (defined later after FRAME_RESOLVERS table)
local HasFrameResolverForKey
local ResolveApplyFrameForKey

local _anchorGuardedFrames = {}  -- [frame] = true, prevents double-hooking
local _setPointGuardedFrames = {} -- [frame] = true, prevents double-hooking SetPoint guards
-- Anch_anchorGuardedFrames / Anch_setPointGuardedFrames memprobe anchor

-- Layer 1: Hook ApplySystemAnchor on a single Blizzard frame
local DYNAMIC_REANCHOR_KEYS = { buffFrame = true, debuffFrame = true }

local function InstallAnchorGuard(frame, key)
    if _anchorGuardedFrames[frame] then return end
    -- chatFrame1 is detached from Edit Mode and owned by the chat module
    -- (chat_frame1.lua). A reactive ApplySystemAnchor/SetPoint guard re-SetPoints
    -- the frame from inside Blizzard's secure execution context, which taints the
    -- chat-event dispatch and throws a secret-string crash on secret channel/
    -- party payloads. The guard is also unnecessary post-detach: a frame-anchor
    -- to UIParent or another frame is a live SetPoint that needs no re-assertion
    -- (Edit Mode no longer manages the frame). ApplyFrameAnchor still positions
    -- it directly; we just never install the reactive hook.
    if key == "chatFrame1" then return end
    if not frame.ApplySystemAnchor then
        -- Frames without ApplySystemAnchor (e.g. UIWidget containers) get
        -- repositioned by Blizzard layout code via direct SetPoint calls.
        -- Hook SetPoint instead so QUI's anchor overrides stick.
        -- Skip for dynamically re-anchored containers (buff/debuff/buffBar):
        -- their layout code legitimately changes the anchor point to match
        -- growth direction, and the guard would fight that re-anchor on
        -- every aura update, resetting it back to the saved position.
        if DYNAMIC_REANCHOR_KEYS[key] then return end
        if _setPointGuardedFrames[frame] then return end
        _setPointGuardedFrames[frame] = true
        hooksecurefunc(frame, "SetPoint", function()
            if _editModeReapplyGuard then return end
            -- During layout mode, frames reparented to mover handles are
            -- repositioned by the handle system (TOPLEFT for boss frames).
            -- Without this guard, every SetPoint triggers a deferred
            -- ApplyFrameAnchor that overrides the handle anchoring, creating
            -- a feedback loop on every frame tick during drag.
            if _G.QUI_IsLayoutModeActive and _G.QUI_IsLayoutModeActive() then return end
            C_Timer.After(0, function()
                if InCombatLockdown() then
                    pendingAnchoredFrameUpdateAfterCombat = true
                    return
                end
                local anchoringDB = QUICore.db and QUICore.db.profile
                    and QUICore.db.profile.frameAnchoring
                local settings = GetSavedFrameAnchorSettings(anchoringDB, key)
                if settings then
                    QUI_Anchoring:ApplyFrameAnchor(key, settings)
                end
            end)
        end)
        return
    end
    _anchorGuardedFrames[frame] = true
    hooksecurefunc(frame, "ApplySystemAnchor", function()
        if _editModeReapplyGuard then return end
        -- Defer to escape Blizzard's secure execution context
        C_Timer.After(0, function()
            if InCombatLockdown() then
                pendingAnchoredFrameUpdateAfterCombat = true
                return
            end
            local anchoringDB = QUICore.db and QUICore.db.profile
                and QUICore.db.profile.frameAnchoring
            local settings = GetSavedFrameAnchorSettings(anchoringDB, key)
            if settings then
                QUI_Anchoring:ApplyFrameAnchor(key, settings)
            end
        end)
    end)
end

-- Install anchor guards on all currently-resolvable managed frames
local function InstallAllAnchorGuards()
    local anchoringDB = QUICore.db and QUICore.db.profile
        and QUICore.db.profile.frameAnchoring
    if not anchoringDB then return end
    for key, settings in pairs(anchoringDB) do
        if type(settings) == "table" and HasFrameResolverForKey(key) then
            local frame = ResolveApplyFrameForKey(key)
            if frame then
                InstallAnchorGuard(frame, key)
            end
        end
    end
end

-- Layer 2: Reapply all positions when Edit Mode panel closes
if EditModeManagerFrame then
    hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
        C_Timer.After(0, function()
            if InCombatLockdown() then
                pendingAnchoredFrameUpdateAfterCombat = true
                return
            end
            InstallAllAnchorGuards()
            if QUI_Anchoring then
                QUI_Anchoring:ApplyAllFrameAnchors()
            end
            local RefreshUnitFrames = _G.QUI_RefreshUnitFrames
            if RefreshUnitFrames then pcall(RefreshUnitFrames) end
        end)
    end)
end

-- Install guards after initial anchoring pass and on PLAYER_ENTERING_WORLD
-- (all Blizzard frames exist by then)
local anchorGuardInitFrame = CreateFrame("Frame")
anchorGuardInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
anchorGuardInitFrame:SetScript("OnEvent", function(f)
    f:UnregisterAllEvents()
    -- Delay to ensure ApplyAllFrameAnchors has run at least once
    C_Timer.After(1, InstallAllAnchorGuards)
end)

---------------------------------------------------------------------------
-- FRAME ANCHORING SYSTEM (centralized override positioning)
-- Forward declarations (defined below)
local DebouncedReapplyOverrides
local ComputeAnchorApplyOrder
---------------------------------------------------------------------------
-- Lazy resolver functions for all controllable frames
-- When a QUI module is disabled, its resolvers should NOT fall back to
-- Blizzard frames — let Blizzard / Edit Mode manage their own positions.
local function IsModuleDisabled(dbKey, enabledField)
    local profile = QUI and QUI.db and QUI.db.profile
    if not profile then return false end
    local db = profile[dbKey]
    if not db then return false end
    return db[enabledField or "enabled"] == false
end

local function IsBlizzardElementDisabled(elementKey)
    local profile = QUI and QUI.db and QUI.db.profile
    local elements = profile and profile.blizzardFrames and profile.blizzardFrames.elements
    local db = elements and elements[elementKey]
    return db and db.enabled == false
end

---------------------------------------------------------------------------
-- MANAGED-CONTAINER REPARENT
--
-- Blizzard's UIParentRightManagedFrameContainer is a secure layout chain.
-- Calling ClearAllPoints/SetPoint on any of its children from addon code
-- permanently taints the child's position data, which then propagates to
-- the container itself. The next time Blizzard reshuffles the chain
-- (e.g. CompactArenaFrame:RefreshMembers in raids), it fires
-- "AddOn 'QUI' tried to call the protected function
-- 'UIParentRightManagedFrameContainer:ClearAllPoints()'".
--
-- To let QUI layout mode keep positioning these frames, we reparent each
-- target into a QUI-owned holder (child of UIParent, OUTSIDE the managed
-- container) at login. The anchoring resolver returns the holder, so
-- ApplyFrameAnchor and layout-mode handles SetPoint on addon-safe frames.
-- The Blizzard frame rides along via a TOPLEFT→holder pin.
--
-- Reference implementation: ExtraActionButton in
-- modules/actionbars/actionbars.lua.
---------------------------------------------------------------------------

local MANAGED_REPARENT_TARGETS = {
    { key = "objectiveTracker",    frameName = "ObjectiveTrackerFrame",            holderName = "QUI_ObjectiveTrackerHolder"    },
    { key = "topCenterWidgets",    frameName = "UIWidgetTopCenterContainerFrame",  holderName = "QUI_TopCenterWidgetsHolder"    },
    { key = "belowMinimapWidgets", frameName = "UIWidgetBelowMinimapContainerFrame", holderName = "QUI_BelowMinimapWidgetsHolder" },
}

-- [key] = { holder, frame, installed, hookingSetPoint, hookingSetParent,
--           pendingReanchor, sizeHooked, setPointHooked, setParentHooked }
-- Declared here so FRAME_RESOLVERS closures can reference it via upvalue
-- capture; the table is populated later by InstallManagedReparent.
local managedReparentState = {}

local function MirrorHolderSize(key)
    local state = managedReparentState[key]
    if not state or not state.holder or not state.frame then return end
    local frame = state.frame
    local w = (frame.GetWidth  and frame:GetWidth())  or 0
    local h = (frame.GetHeight and frame:GetHeight()) or 0
    if type(w) ~= "number" or w < 1 then w = 1 end
    if type(h) ~= "number" or h < 1 then h = 1 end
    state.holder:SetSize(w, h)
end

local function ReanchorFrameToHolder(key)
    local state = managedReparentState[key]
    if not state or not state.holder or not state.frame then return end
    if InCombatLockdown() then return end
    local frame = state.frame
    state.hookingSetPoint = true
    pcall(frame.ClearAllPoints, frame)
    pcall(frame.SetPoint, frame, "TOPLEFT", state.holder, "TOPLEFT", 0, 0)
    state.hookingSetPoint = false
    MirrorHolderSize(key)
end

local function QueueManagedReanchor(key)
    local state = managedReparentState[key]
    if not state or state.pendingReanchor then return end
    state.pendingReanchor = true
    C_Timer.After(0, function()
        state.pendingReanchor = false
        if InCombatLockdown() then return end
        ReanchorFrameToHolder(key)
    end)
end

local function InstallManagedReparent(def)
    local state = managedReparentState[def.key]
    if state and state.installed then return state.holder end
    if InCombatLockdown() then return nil end

    local frame = _G[def.frameName]
    if not frame then return nil end

    state = state or {}
    managedReparentState[def.key] = state
    state.key   = def.key
    state.frame = frame

    -- Create the holder outside the managed container
    local holder = state.holder or _G[def.holderName]
    if not holder then
        holder = CreateFrame("Frame", def.holderName, UIParent)
        local strata = frame.GetFrameStrata and frame:GetFrameStrata() or "MEDIUM"
        holder:SetFrameStrata(strata)
        -- Seed with the frame's current footprint so layout-mode handles
        -- get a real hit area before OnSizeChanged fires
        local seedW = (frame.GetWidth  and frame:GetWidth())  or 0
        local seedH = (frame.GetHeight and frame:GetHeight()) or 0
        if type(seedW) ~= "number" or seedW < 1 then seedW = 200 end
        if type(seedH) ~= "number" or seedH < 1 then seedH = 200 end
        holder:SetSize(seedW, seedH)
        -- Place the holder wherever the frame currently sits (best-effort —
        -- ApplyFrameAnchor will overwrite this if the user has a saved anchor)
        holder:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    state.holder = holder

    -- Deregister from the current managed-container's layout chain BEFORE
    -- reparenting. Otherwise the container's showingFrames array still holds
    -- a reference to the frame, and any future Layout pass (e.g. cinematic
    -- start -> RemoveManagedFrame -> Layout -> SetSize) will iterate the
    -- frame, trigger our SetPoint hook, and taint the SetSize call on the
    -- container itself -> "AddOn 'QUI' tried to call the protected function
    -- 'UIParentRightManagedFrameContainer:SetSize()'".
    --
    -- RemoveManagedFrame and the ignoreFramePositionManager field are defined
    -- by UIParentManagedFrameContainerMixin. Calling / setting them is a
    -- plain Lua-table op, not a protected call.
    local currentParent = frame.GetParent and frame:GetParent() or nil
    if currentParent and currentParent.RemoveManagedFrame then
        pcall(currentParent.RemoveManagedFrame, currentParent, frame)
    end
    -- Prevent Blizzard from re-adding the frame on show / zone transition.
    frame.ignoreFramePositionManager = true

    -- Reparent the Blizzard frame into the holder
    state.hookingSetParent = true
    pcall(frame.SetParent, frame, holder)
    state.hookingSetParent = false

    -- Pin the frame to the holder's TOPLEFT
    ReanchorFrameToHolder(def.key)

    -- Mirror the frame's size onto the holder so layout-mode handles track it
    if frame.HookScript and not state.sizeHooked then
        state.sizeHooked = true
        frame:HookScript("OnSizeChanged", function()
            MirrorHolderSize(def.key)
        end)
    end

    -- If anything repositions the frame, reanchor back to the holder
    if not state.setPointHooked then
        state.setPointHooked = true
        hooksecurefunc(frame, "SetPoint", function()
            if state.hookingSetPoint then return end
            QueueManagedReanchor(def.key)
        end)
    end

    -- If anything reparents the frame back into a managed container
    -- (Edit Mode layout recalc, zone transition), reclaim it
    if not state.setParentHooked then
        state.setParentHooked = true
        hooksecurefunc(frame, "SetParent", function(self, newParent)
            if state.hookingSetParent then return end
            if newParent == state.holder then return end
            C_Timer.After(0, function()
                if InCombatLockdown() then return end
                if state.frame:GetParent() == state.holder then return end
                state.hookingSetParent = true
                pcall(state.frame.SetParent, state.frame, state.holder)
                state.hookingSetParent = false
                QueueManagedReanchor(def.key)
            end)
        end)
    end

    state.installed = true
    return holder
end

local function EnsureAllManagedReparents()
    if InCombatLockdown() then return end
    local installedAny = false
    for _, def in ipairs(MANAGED_REPARENT_TARGETS) do
        local wasInstalled = managedReparentState[def.key] and managedReparentState[def.key].installed
        if InstallManagedReparent(def) and not wasInstalled then
            installedAny = true
        end
    end
    -- After a new holder becomes available, re-apply anchors so any
    -- saved positions for these keys actually get committed to the
    -- holder (prior ApplyAllFrameAnchors passes got nil from the
    -- resolver and bailed).
    if installedAny and QUI_Anchoring and QUI_Anchoring.ApplyAllFrameAnchors then
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            pcall(QUI_Anchoring.ApplyAllFrameAnchors, QUI_Anchoring)
        end)
    end
end

-- Install reparents on login (all Blizzard frames exist by PLAYER_ENTERING_WORLD)
-- and retry on PLAYER_REGEN_ENABLED in case combat blocked the first attempt.
local managedReparentInitFrame = CreateFrame("Frame")
managedReparentInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
managedReparentInitFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
managedReparentInitFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        EnsureAllManagedReparents()
        return
    end
    -- Delay slightly so Blizzard's own frame setup has completed
    C_Timer.After(0.5, EnsureAllManagedReparents)
end)

local FRAME_RESOLVERS = {
    -- CDM Viewers
    cdmEssential = function() return _G.QUI_GetCDMViewerFrame and _G.QUI_GetCDMViewerFrame("essential") end,
    cdmUtility = function() return _G.QUI_GetCDMViewerFrame and _G.QUI_GetCDMViewerFrame("utility") end,
    buffIcon = function() return _G.QUI_GetCDMViewerFrame and _G.QUI_GetCDMViewerFrame("buffIcon") end,
    buffBar = function() return _G.QUI_GetCDMViewerFrame and _G.QUI_GetCDMViewerFrame("buffBar") end,
    rotationAssistIcon = function()
        local frame = _G.QUI_RotationAssistIcon
        if frame then
            return frame
        end

        if _G.QUI and _G.QUI.RotationAssistIcon and _G.QUI.RotationAssistIcon.GetFrame then
            frame = _G.QUI.RotationAssistIcon.GetFrame()
            if frame then
                return frame
            end
        end

        -- Lazy-create if the module hasn't built it yet.
        if _G.QUI_RefreshRotationAssistIcon then
            _G.QUI_RefreshRotationAssistIcon()
            return _G.QUI_RotationAssistIcon
        end

        return nil
    end,
    -- Resource Bars
    -- Swap-aware: when the primary/secondary swap mechanic is active, the
    -- bar physically occupying each natural slot changes (the bars exchange
    -- positions).  Anchoring is positional intent ("anchor at primary's
    -- slot"), not frame identity, so route through GetSwapAwareBarFor so
    -- external anchored elements stay visually stable across swap toggles.
    primaryPower = function()
        if QUICore and QUICore.GetSwapAwareBarFor then
            local f = QUICore:GetSwapAwareBarFor("primaryPower")
            if f then return f end
        end
        return QUICore and QUICore.powerBar
    end,
    secondaryPower = function()
        if QUICore and QUICore.GetSwapAwareBarFor then
            local f = QUICore:GetSwapAwareBarFor("secondaryPower")
            if f then return f end
        end
        return QUICore and QUICore.secondaryPowerBar
    end,
    -- Unit Frames
    playerFrame = function() return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.player end,
    targetFrame = function() return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.target end,
    totFrame = function() return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.targettarget end,
    focusFrame = function() return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.focus end,
    petFrame = function() return ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames and ns.QUI_UnitFrames.frames.pet end,
    bossFrames = function()
        -- Returns array of boss frames for iteration
        local frames = {}
        if ns.QUI_UnitFrames and ns.QUI_UnitFrames.frames then
            for i = 1, 5 do
                local f = ns.QUI_UnitFrames.frames["boss" .. i]
                if f then table.insert(frames, f) end
            end
        end
        return #frames > 0 and frames or nil
    end,
    -- Castbars
    playerCastbar = function() return ns.QUI_Castbar and ns.QUI_Castbar.castbars and ns.QUI_Castbar.castbars["player"] end,
    targetCastbar = function() return ns.QUI_Castbar and ns.QUI_Castbar.castbars and ns.QUI_Castbar.castbars["target"] end,
    focusCastbar = function() return ns.QUI_Castbar and ns.QUI_Castbar.castbars and ns.QUI_Castbar.castbars["focus"] end,
    petCastbar = function() return ns.QUI_Castbar and ns.QUI_Castbar.castbars and ns.QUI_Castbar.castbars["pet"] end,
    totCastbar = function() return ns.QUI_Castbar and ns.QUI_Castbar.castbars and ns.QUI_Castbar.castbars["targettarget"] end,
    -- Action Bars — prefer owned containers. Bail until QUI-owned containers
    -- exist because Blizzard's Edit Mode and frame-position systems continue
    -- to manage the raw Blizzard bars.
    -- When action bars are disabled, return nil so Blizzard/Edit Mode keeps control.
    bar1 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar1"]
        if owned then return owned end
        return nil
    end,
    bar2 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar2"]
        if owned then return owned end
        return nil
    end,
    bar3 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar3"]
        if owned then return owned end
        return nil
    end,
    bar4 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar4"]
        if owned then return owned end
        return nil
    end,
    bar5 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar5"]
        if owned then return owned end
        return nil
    end,
    bar6 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar6"]
        if owned then return owned end
        return nil
    end,
    bar7 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar7"]
        if owned then return owned end
        return nil
    end,
    bar8 = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bar8"]
        if owned then return owned end
        return nil
    end,
    petBar = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["pet"]
        if owned then return owned end
        -- Pet/stance/micro/bag bars are managed by Blizzard's Edit Mode and
        -- frame-position systems. Do not fall back to raw Blizzard frames:
        -- ApplyFrameAnchor would ClearAllPoints/SetPoint them before QUI owns
        -- safe containers, tainting later Blizzard layout passes.
        return nil
    end,
    stanceBar = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["stance"]
        if owned then return owned end
        return nil
    end,
    microMenu = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["microbar"]
        if owned then return owned end
        return nil
    end,
    bagBar = function()
        local owned = ns.ActionBarsOwned and ns.ActionBarsOwned.containers and ns.ActionBarsOwned.containers["bags"]
        if owned then return owned end
        return nil
    end,
    extraActionButton = function()
        local owned = _G["QUI_extraActionButtonHolder"]
        if owned then return owned end
        if IsBlizzardElementDisabled("extraActionButton") then return nil end
        return _G["ExtraActionBarFrame"]
    end,
    zoneAbility = function()
        local owned = _G["QUI_zoneAbilityHolder"]
        if owned then return owned end
        if IsBlizzardElementDisabled("zoneAbility") then return nil end
        return _G["ZoneAbilityFrame"]
    end,
    leaveVehicle = function() return _G["MainMenuBarVehicleLeaveButton"] end,
    equipmentDurability = function() return _G["DurabilityFrame"] end,
    -- QoL
    brezCounter = function() return _G["QUI_BrezCounter"] end,
    atonementCounter = function() return _G["QUI_AtonementCounter"] end,
    combatTimer = function() return _G["QUI_CombatTimer"] end,
    lustTimer = function() return _G["QUI_LustTimer"] end,
    rangeCheck = function() return _G["QUI_RangeCheckFrame"] end,
    actionTracker = function() return _G["QUI_ActionTracker"] end,
    xpTracker = function() return _G["QUI_XPTracker"] end,
    skyriding = function() return _G["QUI_Skyriding"] end,
    petWarning = function() return _G["QUI_PetWarningFrame"] end,
    focusCastAlert = function() return _G["QUI_FocusCastAlertFrame"] end,
    missingRaidBuffs = function() return _G["QUI_MissingRaidBuffs"] end,
    mplusTimer = function() return _G["QUI_MPlusTimerFrame"] end,
    preyTracker = function() return _G["QUI_PreyTracker"] end,
    crosshair = function() return _G["QUI_Crosshair"] end,
    totemBar = function()
        local owned = ns.QUI_TotemBar and ns.QUI_TotemBar.container
        if owned then return owned end
        if IsModuleDisabled("totemBar") then return nil end
        return _G["TotemFrame"]
    end,
    raidMarkersBar = function()
        return ns.QUI_RaidMarkersBar and ns.QUI_RaidMarkersBar.container
    end,
    readyCheck = function()
        if IsModuleDisabled("general", "skinReadyCheck") then return nil end
        return _G["ReadyCheckFrame"]
    end,
    bonusRollFrame = function() return _G["BonusRollFrame"] end,
    consumables = function() return _G["QUI_ConsumablesFrame"] end,
    alertAnchor = function() return _G["QUI_AlertFrameHolder"] end,
    toastAnchor = function() return _G["QUI_EventToastHolder"] end,
    bnetToastAnchor = function() return _G["QUI_BNetToastHolder"] end,
    tooltipAnchor = function() return _G["QUI_TooltipAnchor"] end,
    powerBarAlt = function() return _G["QUI_AltPowerBar"] end,
    lootFrame = function() return _G["QUI_LootFrame"] end,
    lootRollAnchor = function() return _G["QUI_LootRollAnchor"] end,
    partyKeystones = function() return _G["QUIKeyTrackerFrame"] end,
    -- Group Frames
    -- During edit/test mode the headers are hidden and re-parented to the mover;
    -- return the mover/test container so anchoring works with preview frames.
    partyFrames = function()
        local GFEM = ns.QUI_GroupFrameEditMode
        if GFEM then
            local active = GFEM:GetActiveFrame("party")
            if active then return active end
        end
        -- Return the anchor root frame so ApplyFrameAnchor positions the root.
        -- Headers are arranged within the root by UpdateAnchorRoot.
        local GF = ns.QUI_GroupFrames
        if GF and GF.anchorFrames and GF.anchorFrames.party then
            return GF.anchorFrames.party
        end
        return GF and GF.headers and GF.headers.party
    end,
    raidFrames = function()
        local GFEM = ns.QUI_GroupFrameEditMode
        if GFEM then
            local active = GFEM:GetActiveFrame("raid")
            if active then return active end
        end
        -- Return the anchor root frame so ApplyFrameAnchor positions the root.
        -- Headers are arranged within the root by UpdateAnchorRoot.
        local GF = ns.QUI_GroupFrames
        if GF and GF.anchorFrames and GF.anchorFrames.raid then
            return GF.anchorFrames.raid
        end
        return GF and GF.headers and GF.headers.raid
    end,
    -- Display — return the stable anchor proxy instead of raw Minimap.
    -- QUI_MinimapAnchor is parented to UIParent and holds the minimap's
    -- intended position. This makes anchoring-dependent frames immune to
    -- external addons that reparent/rescale Minimap for full-screen HUDs.
    minimap = function() return _G["QUI_MinimapAnchor"] or _G["Minimap"] end,
    datatextPanel = function() return _G["QUI_DatatextPanel"] end,
    -- Managed-container frames resolve to their QUI holder once reparented
    -- (see MANAGED_REPARENT_TARGETS above). Before the reparent installs
    -- (early login window, or a combat-deferred retry), the resolver
    -- returns nil so ApplyFrameAnchor bails early — SetPointing the raw
    -- Blizzard frame while it still lives inside the managed container
    -- would permanently taint the container. EnsureAllManagedReparents
    -- triggers a reapply once the holders are installed.
    objectiveTracker = function()
        local state = managedReparentState["objectiveTracker"]
        return state and state.holder or nil
    end,
    topCenterWidgets = function()
        local state = managedReparentState["topCenterWidgets"]
        return state and state.holder or nil
    end,
    belowMinimapWidgets = function()
        local state = managedReparentState["belowMinimapWidgets"]
        return state and state.holder or nil
    end,
    buffFrame = function()
        local owned = _G["QUI_BuffIconContainer"]
        if owned then return owned end
        if IsModuleDisabled("buffBorders", "enableBuffs") then return nil end
        return nil
    end,
    debuffFrame = function()
        local owned = _G["QUI_DebuffIconContainer"]
        if owned then return owned end
        if IsModuleDisabled("buffBorders", "enableDebuffs") then return nil end
        return nil
    end,
    chatFrame1 = function()
        -- The QUI chat display IS the chat frame under the takeover.
        -- ChatFrame1 itself is suppressed (hidden + neutered): never resolve
        -- it for anchoring — SetPoint on it would taint chat dispatch.
        if IsModuleDisabled("chat") then return nil end
        return _G["QUI_CustomChatFrame"]
    end,
    -- External (DandersFrames, AbilityTimeline)
    dandersParty = function()
        if ns.QUI_DandersFrames and ns.QUI_DandersFrames:IsAvailable() then
            local frames = ns.QUI_DandersFrames:GetContainerFrames("party")
            return frames and frames[1]
        end
    end,
    dandersRaid = function()
        if ns.QUI_DandersFrames and ns.QUI_DandersFrames:IsAvailable() then
            local frames = ns.QUI_DandersFrames:GetContainerFrames("raid")
            return frames and frames[1]
        end
    end,
    abilityTimelineTimeline = function()
        return _G["AbilityTimelineFrame"]
    end,
    abilityTimelineBigIcon = function()
        return _G["AbilityTimelineBigIconFrame"]
    end,
}

local CUSTOM_TRACKER_ANCHOR_PREFIX = "customTracker:"
local CUSTOM_TRACKER_ANCHOR_CATEGORY = "Cooldown Manager & Custom Tracker Bars"
local CUSTOM_TRACKER_ANCHOR_CATEGORY_ORDER = 90

local function GetCustomTrackerBarIDFromAnchorKey(key)
    if type(key) ~= "string" then return nil end
    if key:sub(1, #CUSTOM_TRACKER_ANCHOR_PREFIX) ~= CUSTOM_TRACKER_ANCHOR_PREFIX then
        return nil
    end
    local barID = key:sub(#CUSTOM_TRACKER_ANCHOR_PREFIX + 1)
    if barID == "" then
        return nil
    end
    return barID
end

local function ResolveCustomTrackerFrameForKey(key)
    local barID = GetCustomTrackerBarIDFromAnchorKey(key)
    if not barID then
        return nil
    end

    local migratedKey = "cdmCustom_customBar_" .. tostring(barID)
    local migratedResolver = FRAME_RESOLVERS and FRAME_RESOLVERS[migratedKey]
    if migratedResolver then
        local frame = migratedResolver()
        if frame then
            return frame
        end
    end

    local trackerModule = QUICore and QUICore.CustomTrackers
    local activeBars = trackerModule and trackerModule.activeBars
    if not activeBars then
        return nil
    end
    return activeBars[barID]
end

HasFrameResolverForKey = function(key)
    if FRAME_RESOLVERS[key] then
        return true
    end
    return GetCustomTrackerBarIDFromAnchorKey(key) ~= nil
end

-- Resolve a frame for direct anchoring apply.
-- Important: keep static keys on their original resolver path (no proxy substitution),
-- and only use dynamic resolution for custom tracker keys.
ResolveApplyFrameForKey = function(key)
    local resolver = FRAME_RESOLVERS[key]
    if resolver then
        local frame = resolver()
        if type(frame) == "table" and not frame.GetObjectType then
            frame = frame[1]
        end
        return frame
    end
    return ResolveCustomTrackerFrameForKey(key)
end

-- Blizzard-managed right-side frames are controlled by UIParentPanelManager.
-- Previously objectiveTracker, buffFrame, and debuffFrame were blocked here,
-- but the existing combat deferral and SecureHandlerStateTemplate taint cleaner
-- already handle taint safety for Edit Mode system frames, so they now use the
-- normal ApplyFrameAnchor path.
local UNSAFE_BLIZZARD_MANAGED_OVERRIDES = {
}

-- Frames that manage their own parent-relative positioning (e.g. anchored to
-- a Blizzard panel that opens/closes). The anchoring system skips SetPoint for
-- these but still marks them overridden so layout mode handles work.
local SELF_ANCHORED_FRAMES = {
    partyKeystones = true,
}

-- Frame display info for anchor target registration
local FRAME_ANCHOR_INFO = {
    cdmEssential    = { displayName = "CDM Essential Viewer",  category = "Cooldown Manager & Custom Tracker Bars",  order = 1 },
    cdmUtility      = { displayName = "CDM Utility Viewer",    category = "Cooldown Manager & Custom Tracker Bars",  order = 2 },
    buffIcon        = { displayName = "CDM Buff Icons",        category = "Cooldown Manager & Custom Tracker Bars",  order = 3 },
    buffBar         = { displayName = "CDM Buff Bars",         category = "Cooldown Manager & Custom Tracker Bars",  order = 4 },
    rotationAssistIcon = { displayName = "CDM Rotation Assist Icon", category = "Cooldown Manager & Custom Tracker Bars", order = 5 },
    primaryPower    = { displayName = "Primary Power Bar",     category = "Resource Bars",     order = 1 },
    secondaryPower  = { displayName = "Secondary Power Bar",   category = "Resource Bars",     order = 2 },
    playerFrame     = { displayName = "Player Frame",          category = "Unit Frames",       order = 1 },
    targetFrame     = { displayName = "Target Frame",          category = "Unit Frames",       order = 2 },
    totFrame        = { displayName = "Target of Target",      category = "Unit Frames",       order = 3 },
    focusFrame      = { displayName = "Focus Frame",           category = "Unit Frames",       order = 4 },
    petFrame        = { displayName = "Pet Frame",             category = "Unit Frames",       order = 5 },
    bossFrames      = { displayName = "Boss Frames",           category = "Unit Frames",       order = 6 },
    playerCastbar   = { displayName = "Player Castbar",        category = "Castbars",          order = 1 },
    targetCastbar   = { displayName = "Target Castbar",        category = "Castbars",          order = 2 },
    focusCastbar    = { displayName = "Focus Castbar",         category = "Castbars",          order = 3 },
    petCastbar      = { displayName = "Pet Castbar",           category = "Castbars",          order = 4 },
    totCastbar      = { displayName = "Target of Target Castbar", category = "Castbars",       order = 5 },
    bar1            = { displayName = "Action Bar 1",          category = "Action Bars",       order = 1 },
    bar2            = { displayName = "Action Bar 2",          category = "Action Bars",       order = 2 },
    bar3            = { displayName = "Action Bar 3",          category = "Action Bars",       order = 3 },
    bar4            = { displayName = "Action Bar 4",          category = "Action Bars",       order = 4 },
    bar5            = { displayName = "Action Bar 5",          category = "Action Bars",       order = 5 },
    bar6            = { displayName = "Action Bar 6",          category = "Action Bars",       order = 6 },
    bar7            = { displayName = "Action Bar 7",          category = "Action Bars",       order = 7 },
    bar8            = { displayName = "Action Bar 8",          category = "Action Bars",       order = 8 },
    petBar          = { displayName = "Pet Action Bar",        category = "Action Bars",       order = 9 },
    stanceBar       = { displayName = "Stance Bar",            category = "Action Bars",       order = 10 },
    microMenu       = { displayName = "Micro Menu",            category = "Action Bars",       order = 11 },
    bagBar          = { displayName = "Bag Bar",               category = "Action Bars",       order = 12 },
    extraActionButton = { displayName = "Extra Action Button", category = "Action Bars",       order = 13 },
    zoneAbility     = { displayName = "Zone Ability Button",   category = "Action Bars",       order = 14 },
    leaveVehicle    = { displayName = "Leave Vehicle Button", category = "Action Bars",       order = 15 },
    equipmentDurability = { displayName = "Equipment Durability", category = "Display",        order = 10 },
    brezCounter     = { displayName = "Brez Counter",          category = "QoL",               order = 1 },
    atonementCounter = { displayName = "Atonement Counter",    category = "QoL",               order = 2 },
    combatTimer     = { displayName = "Combat Timer",          category = "QoL",               order = 3 },
    lustTimer       = { displayName = "Lust Timer",            category = "QoL",               order = 14 },
    rangeCheck      = { displayName = "Target Distance Bracket Display", category = "QoL",      order = 4 },
    actionTracker   = { displayName = "Action Tracker",        category = "QoL",               order = 5 },
    xpTracker       = { displayName = "XP Tracker",            category = "QoL",               order = 6 },
    skyriding       = { displayName = "Skyriding",             category = "QoL",               order = 7 },
    petWarning      = { displayName = "Pet Warning",           category = "QoL",               order = 8 },
    focusCastAlert  = { displayName = "Focus Cast Alert",      category = "QoL",               order = 9 },
    missingRaidBuffs = { displayName = "Missing Raid Buffs",   category = "QoL",               order = 10 },
    mplusTimer      = { displayName = "M+ Timer",              category = "QoL",               order = 11 },
    readyCheck      = { displayName = "Ready Check",           category = "QoL",               order = 12 },
    preyTracker     = { displayName = "Prey Tracker",          category = "QoL",               order = 13 },
    partyFrames     = { displayName = "Party Frames",           category = "Group Frames",      order = 1 },
    raidFrames      = { displayName = "Raid Frames",            category = "Group Frames",      order = 2 },
    minimap         = { displayName = "Minimap",               category = "Display",           order = 1 },
    objectiveTracker = { displayName = "Objective Tracker",    category = "Display",           order = 2 },
    topCenterWidgets = { displayName = "Top Center Widgets",  category = "Display",           order = 3 },
    belowMinimapWidgets = { displayName = "Below Minimap Widgets", category = "Display",      order = 4 },
    buffFrame       = { displayName = "Buff Frame",            category = "Display",           order = 5 },
    debuffFrame     = { displayName = "Debuff Frame",          category = "Display",           order = 6 },
    chatFrame1      = { displayName = "Chat Frame",            category = "Display",           order = 7 },
    datatextPanel   = { displayName = "Datatext Panel",        category = "Display",           order = 8 },
    bonusRollFrame  = { displayName = "Bonus Roll",            category = "Display",           order = 9 },
    dandersParty    = { displayName = "DandersFrames Party",   category = "External",          order = 1 },
    dandersRaid     = { displayName = "DandersFrames Raid",    category = "External",          order = 2 },
    abilityTimelineTimeline = { displayName = "AbilityTimeline Timeline", category = "External", order = 3 },
    abilityTimelineBigIcon = { displayName = "AbilityTimeline Big Icon", category = "External", order = 4 },
}
ns.FRAME_ANCHOR_INFO = FRAME_ANCHOR_INFO

-- Phase G: Global hook for dynamic frame resolver registration from CDM containers.
-- Called by CDMContainers when creating custom containers.
_G.QUI_RegisterFrameResolver = function(key, info)
    if not key then return end
    if info.resolver then
        FRAME_RESOLVERS[key] = info.resolver
    end
    if info.displayName then
        FRAME_ANCHOR_INFO[key] = {
            displayName = info.displayName,
            category = info.category or "Cooldown Manager & Custom Tracker Bars",
            order = info.order or 100,
        }
    end
    -- CDM containers use logical sizing from viewerState
    if info.category == "Cooldown Manager & Custom Tracker Bars" and CDM_LOGICAL_SIZE_KEYS then
        CDM_LOGICAL_SIZE_KEYS[key] = true
    end
    -- Immediately register as anchor target so it appears in dropdowns
    -- even if RegisterAllFrameTargets already ran at init.
    if info.resolver and QUI_Anchoring and QUI_Anchoring.RegisterAnchorTarget then
        local frame = info.resolver()
        if frame then
            QUI_Anchoring:RegisterAnchorTarget(key, frame, {
                displayName = info.displayName or key,
                category = info.category or "Cooldown Manager & Custom Tracker Bars",
                categoryOrder = info.order or 100,
                order = info.order or 100,
            })
        end
    end
end

-- Phase G: Global hook to unregister a dynamic frame resolver.
_G.QUI_UnregisterFrameResolver = function(key)
    if not key then return end
    FRAME_RESOLVERS[key] = nil
    FRAME_ANCHOR_INFO[key] = nil
    if CDM_LOGICAL_SIZE_KEYS then
        CDM_LOGICAL_SIZE_KEYS[key] = nil
    end
end

local hideWithParentHidden = {}  -- keys hidden because their anchor parent is hidden
local resolveUnreadableRetried = {}  -- [originKey] = { [slotKey] = state }
-- Fresh-stack retry state for unreadable (secret/throwing) IsShown answers
-- inside ResolveParentFrame, ONE state per (originKey, consumer). slotKey
-- identifies the CONSUMER ("apply" = the default full apply, "positionOnly",
-- or an overlay FRAME) — consumers replay DIFFERENT operations, and a shared
-- state would let the first one suppress or hijack the others' retries.
-- state = {
--   op      — the NEWEST replay operation (function, or true = default full
--             apply). EVERY unreadable walk refreshes it, so whichever timer
--             fires replays current arguments: repeat calls with new
--             geometry, a resolver that swaps the chain-link frame, and
--             A→B→A flip-flops all resolve to the newest op.
--   pending — a C_Timer.After(0) retry is queued; at most one in flight
--             per consumer.
--   burned  — SET of chain-link frames whose unreadable answer already
--             consumed an ARM this episode. A replay re-entering the walk
--             on a burned frame does not re-arm (no zero-delay loop); a
--             genuinely NEW frame (recreated parent, deeper unreadable
--             link, resolver swap) may arm once more — chains are bounded
--             by the number of distinct frames seen.
--   arms    — total arms consumed this episode. Hard cap
--             (RESOLVE_RETRY_MAX_ARMS): frame identity alone cannot bound
--             a resolver that returns a FRESH unreadable frame each call.
-- }
local RESOLVE_RETRY_MAX_ARMS = 8
-- The state clears ONLY on the owning consumer's fully-readable resolution
-- (clearResolveRetrySlots — another consumer's readable replay must not
-- defuse a still-needed retry) and via the ApplyAllFrameAnchors wipe; the
-- timer validates identity (captured state == live state) before replaying,
-- so a readable call or wipe between arm and fire defuses it.
local function clearResolveRetrySlots(originKey, retryKey)
    local byKey = resolveUnreadableRetried[originKey]
    if byKey then
        byKey[retryKey or "apply"] = nil
        if next(byKey) == nil then
            resolveUnreadableRetried[originKey] = nil
        end
    end
    -- A fully-readable resolution also retires this consumer's latched
    -- combat op: the operation just ran against real state, so replaying
    -- the stale latch at regen would overwrite newer geometry.
    local bySlot = pendingCombatConsumerOps[originKey]
    if bySlot then
        bySlot[retryKey or "apply"] = nil
        if next(bySlot) == nil then
            pendingCombatConsumerOps[originKey] = nil
        end
    end
end
local hideWithParentUnreadableRetried = {}  -- [key] = parent FRAME that already
-- burned its one fresh-stack retry for an unreadable (secret/throwing)
-- visibility answer; cleared on the next readable pass so a later
-- unreadable episode gets a fresh retry. Prevents a persistent secret from
-- turning the C_Timer.After(0) retry into an every-frame poll loop. The
-- value is the parent frame IDENTITY (not `true`): a reparented child or a
-- recreated parent frame is a NEW episode and must re-arm the retry, or the
-- new parent's visibility decision would stay stale forever. Also wiped by
-- ApplyAllFrameAnchors with the rest of the runtime state (profile/spec
-- switches re-arm every key).
local _visibilityHooked = {}    -- [frame] = { onShow, onHide, alpha } — each
-- flag records a VERIFIED successful install (HookScript returns success and
-- can refuse/throw on forbidden frames); a missing flag retries on the next
-- InstallVisibilityHook call. Prevents double-hooking per script.
-- Anch_visibilityHooked memprobe anchor
local FRAME_ANCHOR_FALLBACKS    -- forward-declared; table populated below
local HUD_MIN_WIDTH_DEFAULT = (ns.Helpers and ns.Helpers.HUD_MIN_WIDTH_DEFAULT) or 200

---------------------------------------------------------------------------
-- ANCHOR PROXY SYSTEM REMOVED (Unlock Mode replaced Edit Mode dependency)
-- Proxy-based positioning eliminated; all frame positioning defers to
-- PLAYER_REGEN_ENABLED when in combat for protected frames.
---------------------------------------------------------------------------



-- Fallback anchor targets for when a resolved frame is unavailable (nil or hidden).
-- e.g. classes without a secondary resource should fall back to the primary bar.
--
-- Chain fallbacks matter when legacy profiles (QUI 3.0) have entries like
-- primaryPower.parent = "secondaryPower" for classes that never had a
-- secondary power bar (DK, druid in bear form, DH, rogue, warrior). The
-- walker hits secondaryPower → nil → fallback primaryPower → visited
-- (self-cycle) → needs another hop. Adding primaryPower → cdmEssential
-- gives the walker a sensible next step: land below CDM Essential where
-- the current default chain would have put it.
FRAME_ANCHOR_FALLBACKS = {
    secondaryPower = "primaryPower",
    primaryPower   = "cdmEssential",
    petFrame       = "playerFrame",
    totFrame       = "targetFrame",
}

-- Helper: resolve a single key to a visible frame (nil if unavailable)
local function ResolveFrameForKey(key)
    -- Dynamic custom tracker bars (customTracker:<barID>)
    do
        local customTrackerFrame = ResolveCustomTrackerFrameForKey(key)
        if customTrackerFrame then return customTrackerFrame end
    end

    -- Frame resolver
    local resolver = FRAME_RESOLVERS[key]
    if resolver then
        local frame = resolver()
        -- Boss frames resolver returns an array, take the first
        if type(frame) == "table" and not frame.GetObjectType then
            frame = frame[1]
        end
        if frame then return frame end
    end

    -- Anchor target registry
    local registered = QUI_Anchoring.anchorTargets[key]
    if registered then return registered.frame end

    return nil
end

-- Hook OnShow/OnHide on a frame so that when its visibility changes,
-- ApplyAllFrameAnchors re-runs. This lets children that were chain-walked
-- to a grandparent snap back when the intermediate parent reappears (and
-- vice versa when it hides again).
-- Also hooks SetAlpha: some frames (e.g. unit frames controlled by HUD
-- visibility) fade to alpha 0 instead of calling Hide(). We detect when
-- the effective alpha crosses the ~0 threshold and re-evaluate anchors.
local function InstallVisibilityHook(frame)
    if not frame or not frame.HookScript then return end
    local hooked = _visibilityHooked[frame]
    if not hooked then
        hooked = {}
        _visibilityHooked[frame] = hooked
    end
    local wantAlpha = frame.SetAlpha ~= nil
    if hooked.onShow and hooked.onHide and (hooked.alpha or not wantAlpha) then
        return
    end
    local function onVisibilityChanged()
        if QUI_Anchoring then
            QUI_Anchoring:ApplyAllFrameAnchors()
        end
    end
    -- HookScript RETURNS success and checks the frame's ScriptBindings
    -- forbidden aspect (SimpleScriptRegionAPIDocumentation HookScript:
    -- ChecksForbiddenAspects, Returns success) — it can refuse (false) or
    -- throw on a forbidden frame. Record each hook ONLY on a verified
    -- success, tracked separately, so a failed install retries on the next
    -- call instead of being permanently marked hooked.
    if not hooked.onShow then
        local ok, success = pcall(frame.HookScript, frame, "OnShow", onVisibilityChanged)
        if ok and success then hooked.onShow = true end
    end
    if not hooked.onHide then
        local ok, success = pcall(frame.HookScript, frame, "OnHide", onVisibilityChanged)
        if ok and success then hooked.onHide = true end
    end
    -- Detect alpha-based visibility changes (HUD fade system)
    if wantAlpha and not hooked.alpha then
        -- pcall: GetAlpha can throw on a tainted stack (same hazard as the
        -- hideWithParent visibility read). A throw counts as unknown alpha.
        local okAlpha, curAlpha = pcall(frame.GetAlpha, frame)
        -- Secret numbers pass the type check but error on comparison.
        local curAlphaSecret = not okAlpha
            or (nsHelpers and nsHelpers.IsSecretValue and nsHelpers.IsSecretValue(curAlpha))
        local wasAlphaHidden = (not curAlphaSecret) and type(curAlpha) == "number" and curAlpha < 0.01
        local okHook = pcall(hooksecurefunc, frame, "SetAlpha", function(self, alpha)
            if type(alpha) ~= "number" then return end
            -- Secret numbers pass the type check but error on comparison.
            -- The HUD curve override (hud_visibility.lua) passes secret
            -- HP-derived alphas through SetAlpha intentionally.
            if nsHelpers and nsHelpers.IsSecretValue and nsHelpers.IsSecretValue(alpha) then
                return
            end
            local isAlphaHidden = alpha < 0.01
            if isAlphaHidden ~= wasAlphaHidden then
                wasAlphaHidden = isAlphaHidden
                onVisibilityChanged()
            end
        end)
        if okHook then hooked.alpha = true end
    end
end

-- Resolve an anchor parent key to a frame.
-- Follows the FRAME_ANCHOR_FALLBACKS chain first, then walks up the user's
-- configured anchor chain when the resolved frame is nil or hidden
-- (e.g. Objective Tracker → Data Text Panel → Minimap: if the Data Text Panel
-- is disabled, follows Data Text Panel's own parent to reach Minimap).
--
-- Returns: frame, chainSettings, unreadable
--   frame         — the resolved visible parent frame (or UIParent)
--   chainSettings — when a chain walk occurred via the user's anchoring config,
--                   contains the anchor settings of the last hidden link so the
--                   caller can adopt its anchor points (replacing the hidden
--                   frame in the chain rather than using the child's own points).
--                   nil when no chain walk happened or only hardcoded fallbacks
--                   were used.
--   unreadable    — true when a chain link's visibility answered secret/threw:
--                   the resolution is a status-quo guess. In-combat callers
--                   MUST defer their mutation (the regen reconcile is already
--                   latched); out of combat positioning is safe and a
--                   fresh-stack retry is already armed.
-- originKey: optional key of the frame being anchored. Pre-seeding visited[originKey]
-- prevents the walker from resolving to the origin frame itself via fallback chains.
-- e.g. primaryPower.parent = "secondaryPower" on a class without a secondary resource
-- falls back to FRAME_ANCHOR_FALLBACKS["secondaryPower"] = "primaryPower", which would
-- return the primaryPower frame — creating a self-anchor. With originKey="primaryPower"
-- the visited guard breaks the loop and the walker returns UIParent instead.
-- retryOp: optional replay operation for the unreadable-link fresh-stack
-- retry. Callers whose operation is NOT QUI_ApplyFrameAnchor (position-only
-- re-anchor, overlay anchoring) pass their own replay closure so the retry
-- repeats THEIR operation; called as retryOp(originKey). Defaults to
-- QUI_ApplyFrameAnchor.
-- retryKey: STABLE identity for the consumer's latch slot (defaults to
-- "apply"). Distinct consumers must pass distinct keys or the first one to
-- hit an unreadable link suppresses the others' retries; the key must be
-- stable across re-entries (a fresh closure identity per call would re-arm
-- every pass — zero-delay loop). Overlay callers pass the overlay FRAME so
-- multiple overlays on one originKey each get their own retry.
local function ResolveParentFrame(parentKey, originKey, retryOp, retryKey)
    if not parentKey or parentKey == "screen" or parentKey == "disabled" then
        -- Fully-readable resolution (no chain walk): end this consumer's
        -- retry episode like every other readable return. A parent changed
        -- to screen/disabled while a retry was queued would otherwise leave
        -- the timer live to replay stale geometry over this resolution.
        if originKey then clearResolveRetrySlots(originKey, retryKey) end
        return UIParent, nil
    end

    local key = parentKey
    local visited = {}  -- guard against circular fallback chains
    if originKey then
        visited[originKey] = true  -- never resolve to the frame we're positioning
    end

    -- Grab the user's anchoring config for dynamic chain walking
    local anchoringDB = QUICore and QUICore.db and QUICore.db.profile
        and QUICore.db.profile.frameAnchoring

    -- Track the last hidden link's settings when walking the user's config chain
    local lastChainSettings = nil

    while key do
        if visited[key] then
            -- Cycle detected. The standard case: walker came back to a key
            -- it already tried (or to the originKey we're trying to position,
            -- pre-seeded to prevent self-anchoring). Before giving up, try
            -- one more hop via the hardcoded fallback table — this lets
            -- chains like "secondaryPower → primaryPower → cdmEssential"
            -- recover on classes that don't have a secondary power bar.
            -- A second unvisited hop continues the walk; otherwise we're
            -- truly stuck and fall through to UIParent below.
            local fallback = FRAME_ANCHOR_FALLBACKS[key]
            if fallback and not visited[fallback] then
                key = fallback
            else
                break
            end
        else
            visited[key] = true

            local frame = ResolveFrameForKey(key)

            -- Secret-safe visibility read: IsShown can throw on a tainted
            -- stack and can answer with a secret in 12.1 (truth-testing a
            -- secret throws), so never call it raw. Threshold 0 keeps
            -- alpha-faded frames valid chain links — only the hideWithParent
            -- path treats alpha ≈ 0 as hidden; the chain walk keys off
            -- IsShown alone, as before.
            local visible = false
            if frame then
                visible = nsHelpers.FrameVisibleSecure(frame, 0)
            end

            -- Frame exists and is provably shown → use it. Hook its
            -- visibility too: a later hide must re-run the chain walk so
            -- children walk past it — without the hook, the first hide
            -- after a visible resolution leaves children anchored through
            -- the stale chain until another explicit reapply.
            if visible == true then
                InstallVisibilityHook(frame)
                if originKey then clearResolveRetrySlots(originKey, retryKey) end
                return frame, lastChainSettings
            end

            -- Unreadable (nil) visibility: never chain-walk on a guess — a
            -- wrong walk repositions the child against the grandparent.
            -- Keep the configured link as the parent (SetPoint against a
            -- hidden frame is safe and the caller's combat probe still
            -- gates any mutation) and re-evaluate on a readable stack: in
            -- combat via the regen reconcile, out of combat via ONE
            -- fresh-stack C_Timer.After(0) retry per (originKey,
            -- frame-identity) episode.
            if visible == nil then
                -- Hook the guessed parent too: once the one-shot retry is
                -- consumed, a later visibility flip must still re-evaluate
                -- the chain (the hook install itself is safe — HookScript
                -- plus a pcall'd GetAlpha read).
                InstallVisibilityHook(frame)
                if InCombatLockdown() then
                    pendingAnchoredFrameUpdateAfterCombat = true
                    -- A consumer-specific caller (overlay anchoring) defers
                    -- its own operation too: the regen bulk apply only
                    -- replays the default apply, so latch the consumer op
                    -- for the regen drain or it is lost.
                    latchCombatConsumerOp(originKey, retryKey, retryOp)
                elseif originKey and frame then
                    local byKey = resolveUnreadableRetried[originKey]
                    if not byKey then
                        byKey = {}
                        resolveUnreadableRetried[originKey] = byKey
                    end
                    local slotKey = retryKey or "apply"
                    local state = byKey[slotKey]
                    if not state then
                        state = { burned = {} }
                        byKey[slotKey] = state
                    end
                    -- THIS walk is the consumer's newest operation — the
                    -- timer reads state.op at FIRE time, so whichever
                    -- retry fires replays the newest arguments no matter
                    -- which chain-link frame armed it (repeat-call,
                    -- replacement-parent, and A→B→A flip-flop races all
                    -- collapse onto this one field).
                    state.op = retryOp or true
                    -- Arm at most ONE timer at a time, and only for a
                    -- frame that has not consumed an arm this episode:
                    -- a replay that re-enters this walk on a still-secret,
                    -- already-burned frame must not re-arm (zero-delay
                    -- loop); a genuinely NEW frame (recreated parent,
                    -- deeper unreadable link, resolver swap) may arm once
                    -- more — retry chains are bounded by the number of
                    -- distinct frames seen this episode, with a hard cap
                    -- (state.arms): a resolver that constructs a FRESH
                    -- unreadable frame every call defeats the identity
                    -- bound and would otherwise schedule forever.
                    if not state.pending and not state.burned[frame]
                        and (state.arms or 0) < RESOLVE_RETRY_MAX_ARMS then
                        state.arms = (state.arms or 0) + 1
                        state.burned[frame] = true
                        state.pending = true
                        C_Timer.After(0, function()
                            -- Uncancellable timer: re-check state inside
                            -- the closure. Identity first: the consumer's
                            -- fully-readable resolution (or the
                            -- ApplyAllFrameAnchors wipe) between arm and
                            -- fire REPLACES/removes the live state — this
                            -- timer is then stale, and current geometry is
                            -- already applied; replaying would overwrite
                            -- it with old arguments.
                            local liveByKey = resolveUnreadableRetried[originKey]
                            if not liveByKey or liveByKey[slotKey] ~= state then
                                return
                            end
                            state.pending = false
                            local op = state.op
                            if InCombatLockdown() then
                                -- Timer crossed into combat. A consumer op
                                -- latches for the regen drain — flagging the
                                -- bulk apply instead would SUBSTITUTE the
                                -- auto-sizing full apply for the consumer's
                                -- operation (position-only repro: width
                                -- 77 → 333). The default apply keeps using
                                -- the bulk-apply flag.
                                if type(op) == "function" then
                                    latchCombatConsumerOp(originKey, slotKey, op)
                                else
                                    pendingAnchoredFrameUpdateAfterCombat = true
                                end
                                return
                            end
                            -- Replay the CALLER'S operation: a position-only
                            -- or overlay consumer must not be retried via the
                            -- full QUI_ApplyFrameAnchor apply.
                            local reapply
                            if type(op) == "function" then
                                reapply = op
                            else
                                reapply = _G.QUI_ApplyFrameAnchor
                            end
                            if reapply then reapply(originKey) end
                        end)
                    end
                end
                return frame, lastChainSettings, true
            end

            -- In Layout Mode, treat hidden-but-enabled frames as valid anchor
            -- targets. The mover overlay is visible even when the actual frame is
            -- hidden (e.g. pet bar on a class with no pet), so dependents should
            -- still anchor to it rather than walking up the chain.
            if frame and ns.QUI_LayoutMode and ns.QUI_LayoutMode.isActive then
                InstallVisibilityHook(frame)
                if originKey then clearResolveRetrySlots(originKey, retryKey) end
                return frame, lastChainSettings
            end

            -- Frame exists but hidden — hook its visibility so that when it
            -- reappears, children that chain-walked past it get re-anchored back.
            if frame then
                InstallVisibilityHook(frame)
            end

            -- Frame unavailable → try hardcoded fallback first
            local fallback = FRAME_ANCHOR_FALLBACKS[key]
            if fallback then
                key = fallback
            else
                -- No hardcoded fallback — walk up the user's configured anchor chain.
                -- If key itself has an anchor override with a parent, try that parent
                -- (e.g. datatextPanel is anchored to minimap → use minimap).
                local chainEntry = GetSavedFrameAnchorSettings(anchoringDB, key)
                local chainParent = chainEntry and chainEntry.parent
                if chainParent and chainParent ~= "screen" and chainParent ~= "disabled" then
                    -- Remember this hidden link's anchor settings so the child can
                    -- adopt them (replacing the hidden frame in the visual chain).
                    lastChainSettings = chainEntry
                    key = chainParent
                else
                    -- End of the chain; return the frame if it exists (even if hidden)
                    -- so that anchored frames keep their reference, or UIParent as last
                    -- resort. Fully-readable walk (an unreadable link returns above) —
                    -- the retry episode ends here.
                    if originKey then clearResolveRetrySlots(originKey, retryKey) end
                    return frame or UIParent, lastChainSettings
                end
            end
        end
    end

    -- Fully-readable walk (cycle/exhausted chain) — the retry episode ends.
    if originKey then clearResolveRetrySlots(originKey, retryKey) end
    return UIParent, lastChainSettings
end

-- No-op stubs: proxy system removed (Unlock Mode replaced Edit Mode dependency)
---@type fun(...)
_G.QUI_UpdateCDMAnchorProxyFrames = function() end
_G.QUI_GetCDMAnchorProxyFrame = function() return nil end

local function ClearCustomTrackerAnchorTargets()
    for name in pairs(QUI_Anchoring.anchorTargets) do
        if GetCustomTrackerBarIDFromAnchorKey(name) then
            QUI_Anchoring.anchorTargets[name] = nil
        end
    end
end

local function RegisterCustomTrackerAnchorTargets(self)
    ClearCustomTrackerAnchorTargets()

    local profile = QUICore and QUICore.db and QUICore.db.profile
    local bars = profile and profile.customTrackers and profile.customTrackers.bars
    if type(bars) ~= "table" then
        return
    end

    for index, barConfig in ipairs(bars) do
        local barID = barConfig and barConfig.id
        if type(barID) == "string" and barID ~= "" then
            local anchorKey = CUSTOM_TRACKER_ANCHOR_PREFIX .. barID
            local frame = ResolveCustomTrackerFrameForKey(anchorKey)
            if frame then
                local displayName = barConfig.name
                if type(displayName) ~= "string" or displayName == "" then
                    displayName = ("CDM Bar %d"):format(index)
                end
                self:RegisterAnchorTarget(anchorKey, frame, {
                    displayName = displayName,
                    category = CUSTOM_TRACKER_ANCHOR_CATEGORY,
                    categoryOrder = CUSTOM_TRACKER_ANCHOR_CATEGORY_ORDER,
                    order = index,
                })
            end
        end
    end
end

-- Register all controllable frames as anchor targets (for dropdown lists)
function QUI_Anchoring:RegisterAllFrameTargets()
    for key, resolver in pairs(FRAME_RESOLVERS) do
        local frame = resolver()
        -- Boss frames return an array; register the first one
        if type(frame) == "table" and not frame.GetObjectType then
            frame = frame[1]
        end
        if frame then
            local info = FRAME_ANCHOR_INFO[key] or {}
            self:RegisterAnchorTarget(key, frame, {
                displayName = info.displayName or key,
                category = info.category,
                categoryOrder = info.order,
                order = info.order,
            })
        end
    end
    RegisterCustomTrackerAnchorTargets(self)
end

-- Helper: mark a frame as layout-owned (blocks module positioning)
-- Stores the layout key (e.g. "playerFrame") so callers can do targeted reapply
local function SetFrameOverride(frame, active, key)
    if not frame then return end
    -- Boss frames resolver returns an array
    if type(frame) == "table" and not frame.GetObjectType then
        for _, f in ipairs(frame) do
            QUI_Anchoring.layoutOwnedFrames[f] = active and key or nil
        end
        -- Also mark BossTargetFrameContainer so internal anchoring checks
        -- on the container (used by Edit Mode overlay/nudge systems) work
        if BossTargetFrameContainer then
            QUI_Anchoring.layoutOwnedFrames[BossTargetFrameContainer] = active and key or nil
        end
    else
        QUI_Anchoring.layoutOwnedFrames[frame] = active and key or nil
    end
end

local VALID_BOSS_GROW_DIRECTION = {
    UP = true,
    DOWN = true,
    LEFT = true,
    RIGHT = true,
}

local function GetBossFrameLayout()
    local profile = QUICore and QUICore.db and QUICore.db.profile
    local boss = profile and profile.quiUnitFrames and profile.quiUnitFrames.boss
    if type(boss) ~= "table" then return "DOWN", 35, 35 end

    local direction = rawget(boss, "growDirection") or boss.growDirection or "DOWN"
    if not VALID_BOSS_GROW_DIRECTION[direction] then
        direction = "DOWN"
    end

    local legacySpacing = rawget(boss, "spacing")
    if legacySpacing == nil then
        legacySpacing = boss.spacing
    end
    legacySpacing = tonumber(legacySpacing) or 35

    local xSpacing = rawget(boss, "xSpacing")
    if xSpacing == nil then
        xSpacing = legacySpacing
    end
    xSpacing = tonumber(xSpacing) or legacySpacing

    local ySpacing = rawget(boss, "ySpacing")
    if ySpacing == nil then
        ySpacing = legacySpacing
    end
    ySpacing = tonumber(ySpacing) or legacySpacing

    return direction, xSpacing, ySpacing
end

local function GetBossStackPoint(direction, xSpacing, ySpacing)
    if direction == "UP" then
        return "BOTTOM", "TOP", 0, ySpacing
    elseif direction == "LEFT" then
        return "RIGHT", "LEFT", -xSpacing, 0
    elseif direction == "RIGHT" then
        return "LEFT", "RIGHT", xSpacing, 0
    end
    return "TOP", "BOTTOM", 0, -ySpacing
end

-- Track which parent frames have been hooked for OnSizeChanged
local hookedParentFrames = {}
local function SetupDebugInstrumentation()
    local mp = ns._memprobes or {}; ns._memprobes = mp
    mp[#mp + 1] = { name = "Anch_anchorGuardedFrames",   tbl = _anchorGuardedFrames }   -- Anch_anchorGuardedFrames / Anch_setPointGuardedFrames memprobe anchor
    mp[#mp + 1] = { name = "Anch_setPointGuardedFrames", tbl = _setPointGuardedFrames }
    mp[#mp + 1] = { name = "Anch_visibilityHooked", tbl = _visibilityHooked }            -- Anch_visibilityHooked memprobe anchor
    mp[#mp + 1] = { name = "Anch_hookedParentFrames", tbl = hookedParentFrames }
end
if ns.DebugRegister then -- gate contract: core/debug_gate.lua
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation() -- standalone test harness: no gate, run eagerly
end

CDM_LOGICAL_SIZE_KEYS.cdmEssential = true
CDM_LOGICAL_SIZE_KEYS.cdmUtility = true
CDM_LOGICAL_SIZE_KEYS.buffIcon = true
CDM_LOGICAL_SIZE_KEYS.buffBar = true
local CASTBAR_ANCHOR_KEYS = {
    playerCastbar = true,
    targetCastbar = true,
    focusCastbar = true,
    petCastbar = true,
    totCastbar = true,
}

-- Frames whose own size mutates at runtime (icons appear/disappear, bars
-- stack, totems drop/expire).  When one of these is the *child* being
-- anchored, sizeStable is disabled so the explicit edge relation tracks
-- the child's own growth.  When one of these is the *parent*, sizeStable
-- is also disabled so the child tracks the parent's growth edge instead
-- of being frozen at a CENTER↔CENTER offset baked from the initial size.
local DYNAMIC_SIZE_ANCHOR_KEYS = {
    -- buffIcon: the CDM buff-icon container resizes itself at runtime
    -- (LayoutBuffIcons calls SetSize per visible-icon count, every aura change
    -- in combat). It MUST be pin-eligible like its buffBar sibling: when the
    -- user anchors it (central frameAnchoring) to a restricted target — e.g.
    -- buffIcon -> secondaryPower -> primaryPower -> an essential container that
    -- hosts SecureActionButton icon children (clickableIcons) — AnchorOrPin has
    -- to pin it to UIParent at absolute coords instead of relative-anchoring it
    -- into the restricted anchor family. Without this, buffIcon inherits the
    -- family's anchoring restriction and its in-combat SetSize/Show are
    -- ADDON_ACTION_BLOCKED. The re-pin follow path (QUI_UpdateFramesAnchoredTo
    -- in-combat whitelist) and CDM_LOGICAL_SIZE_KEYS already list buffIcon;
    -- this was the missing trigger. The CDM-native ApplyBuffIconAnchor path
    -- already pins correctly, but it is bypassed once a central anchor exists.
    buffIcon = true,
    buffBar = true,
    buffFrame = true,
    debuffFrame = true,
    totemBar = true,
}

-- Custom CDM bars (cdmCustom_*) belong here too: when dynamicLayout drops
-- filtered icons mid-combat, the container width changes and any corner-to-
-- corner anchor (e.g. BOTTOMRIGHT→TOPRIGHT to a unit frame) must stay glued
-- to the anchor edge.  Their keys are minted dynamically so they can't sit
-- in the static table; the helper below covers both.
local function IsDynamicSizeAnchorKey(key)
    if not key then return false end
    if DYNAMIC_SIZE_ANCHOR_KEYS[key] then return true end
    if type(key) == "string" and key:find("^cdmCustom_") then return true end
    return false
end

-- Container-first aura keys: buffborders publishes its live forbidden
-- strip-1 AuraContainer on the insecure mover (mover._quiLiveContainer,
-- nil while the pool is empty or the host is gated off). The apply path
-- positions THAT container directly — its rect is the real auto-sized
-- display, so an aura container docked to it tracks live growth C-side.
-- The mover stays the resolver result everywhere else: all geometry reads
-- (GetPoint/GetWidth/_naturalW math) stay on insecure frames, and anything
-- that is NOT itself a forbidden aura container keeps anchoring to the
-- mover (forbidden aspects propagate through anchors; only
-- forbidden→forbidden docking is aspect-safe).
local FORBIDDEN_AURA_KEYS = { buffFrame = true, debuffFrame = true }

local function LiveAuraContainerFor(key)
    if not FORBIDDEN_AURA_KEYS[key] then return nil end
    local resolver = FRAME_RESOLVERS[key]
    local mover = resolver and resolver()
    if not mover then return nil end
    return mover._quiLiveContainer, mover
end

-- Aura→aura docking: when a forbidden-container key anchors to the OTHER
-- forbidden-container key, hand back the live container so the C-side
-- anchor system tracks its auto-sized rect (the whole point of
-- container-first). Every other originKey keeps the insecure mover —
-- forbidden aspects propagate to anchored frames.
--
-- Implemented as a post-hoc wrapper (capture + reassign) rather than an
-- inline edit at ResolveParentFrame's own definition (~line 2086): that
-- function is defined lexically BEFORE this file's FRAME_RESOLVERS-
-- dependent aura-key helpers, so a literal inline reference to
-- LiveAuraContainerFor there would resolve to a global (nil), not this
-- local. Reassigning the already-declared top-level local here — after
-- both dependencies exist and before any real call site (first call is at
-- ApplyFrameAnchor, well below) — augments it safely without touching the
-- original function's four internal return points. Extra return values
-- (chainSettings) are preserved via tail-call passthrough on the
-- non-swapped path; the swap path returns only the live container, since a
-- chain walk never happened for it.
do
    local ResolveParentFrameBase = ResolveParentFrame
    ResolveParentFrame = function(parentKey, originKey, retryOp, retryKey)
        if FORBIDDEN_AURA_KEYS[parentKey] and originKey and FORBIDDEN_AURA_KEYS[originKey] then
            local live = LiveAuraContainerFor(parentKey)
            if live then
                -- Successful early resolution (no chain walk): end the
                -- consumer's retry episode — same contract as the base's
                -- readable returns; a queued retry must not replay stale
                -- geometry over this resolution.
                clearResolveRetrySlots(originKey, retryKey)
                return live
            end
        end
        -- retryOp/retryKey must ride through: the base's unreadable-link
        -- retry replays the caller's own operation, latched per consumer.
        return ResolveParentFrameBase(parentKey, originKey, retryOp, retryKey)
    end
end

local function GetPointOffsetForRect(point, width, height)
    local halfW = (width or 0) * 0.5
    local halfH = (height or 0) * 0.5
    if point == "TOPLEFT" then
        return -halfW, halfH
    elseif point == "TOP" then
        return 0, halfH
    elseif point == "TOPRIGHT" then
        return halfW, halfH
    elseif point == "LEFT" then
        return -halfW, 0
    elseif point == "RIGHT" then
        return halfW, 0
    elseif point == "BOTTOMLEFT" then
        return -halfW, -halfH
    elseif point == "BOTTOM" then
        return 0, -halfH
    elseif point == "BOTTOMRIGHT" then
        return halfW, -halfH
    end
    return 0, 0
end

local function GetFrameAnchorRect(frame, key)
    if not frame then return 1, 1 end

    local width, height

    -- CDM viewers can briefly report Blizzard-sized dimensions in combat during
    -- morph/layout churn. Prefer logical layout dimensions when available.
    if CDM_LOGICAL_SIZE_KEYS[key] then
        local vs = _G.QUI_GetCDMViewerState and _G.QUI_GetCDMViewerState(frame)
        if vs then
            width = vs.row1Width or vs.iconWidth
            height = vs.totalHeight
        end
    end

    if not width or width <= 0 then
        width = frame.GetWidth and frame:GetWidth() or 1
    end
    if not height or height <= 0 then
        height = frame.GetHeight and frame:GetHeight() or 1
    end

    -- SetPoint offsets are in the parent's coordinate space.  The child frame's
    -- GetWidth/GetHeight return dimensions in its own coordinate space.  Multiply
    -- by the child's scale to get the visual extent in the parent's coordinate
    -- space so center-offset math correctly accounts for scaled frames (e.g.
    -- Minimap at scale 1.2).  CDM logical dimensions are already in parent space.
    if not CDM_LOGICAL_SIZE_KEYS[key] and frame.GetScale then
        local fScale = frame:GetScale() or 1
        if fScale > 0 and fScale ~= 1 then
            width = width * fScale
            height = height * fScale
        end
    end

    return math.max(1, width), math.max(1, height)
end

local function GetParentAnchorRect(frame, parentKey)
    if not frame then return 1, 1 end

    -- Never geometry-read a forbidden live aura container (its rect encodes
    -- the secret aura count): retarget to its insecure host mover, whose
    -- mirrored position + worst-case natural extent is the right proxy.
    -- Defense-in-depth: today this path is unreachable for those containers
    -- (their keys force useSizeStable=false), but that relies on
    -- FORBIDDEN_AURA_KEYS ⊆ DYNAMIC_SIZE_ANCHOR_KEYS staying in sync.
    if frame._quiHostMover then
        frame = frame._quiHostMover
    end

    local width, height

    -- CDM viewers: prefer logical layout dimensions when available.
    if parentKey then
        -- Normalize aliases (settings.parent may store the short form)
        if parentKey == "essential" then parentKey = "cdmEssential"
        elseif parentKey == "utility" then parentKey = "cdmUtility" end

        if CDM_LOGICAL_SIZE_KEYS[parentKey] then
            local resolver = FRAME_RESOLVERS[parentKey]
            local sourceFrame = resolver and resolver()
            if sourceFrame then
                local vs = _G.QUI_GetCDMViewerState and _G.QUI_GetCDMViewerState(sourceFrame)
                if vs then
                    width = vs.row1Width or vs.iconWidth
                    height = vs.totalHeight
                end
            end
        end
    end

    if not width or width <= 0 then
        width = frame.GetWidth and frame:GetWidth() or 1
    end
    if not height or height <= 0 then
        height = frame.GetHeight and frame:GetHeight() or 1
    end

    return math.max(1, width), math.max(1, height)
end

-- Layout mode handles enforce a minimum size of 20px. Offsets saved in
-- layout mode are computed relative to handle edges, so anchor-point math
-- here must use the same inflated dimensions for very small anchor markers.
-- Only inflate dimensions that are clearly positioning-only anchors (≤ 2px),
-- not real UI elements like thin power bars (4px+) whose saved offsets were
-- tuned against real frame dimensions.
local LAYOUT_HANDLE_MIN = 20
local TINY_ANCHOR_THRESHOLD = 3

local function ComputeCenterOffsetsForAnchor(frame, key, parentFrame, sourcePoint, targetPoint, offsetX, offsetY, parentKey)
    local frameW, frameH = GetFrameAnchorRect(frame, key)
    local parentW, parentH = GetParentAnchorRect(parentFrame, parentKey)

    -- Inflate very small dimensions (≤ 2px anchor markers) to the layout
    -- mode handle minimum. These are positioning-only frames whose handles
    -- were inflated to 20px — saved offsets reference the handle edges, not
    -- the real 1-2px frame edges. Applies to both parent (anchor target)
    -- and child (frame being positioned) when they're tiny markers.
    if parentFrame and parentFrame ~= UIParent then
        if parentW < TINY_ANCHOR_THRESHOLD then parentW = LAYOUT_HANDLE_MIN end
        if parentH < TINY_ANCHOR_THRESHOLD then parentH = LAYOUT_HANDLE_MIN end
    end
    if frameW < TINY_ANCHOR_THRESHOLD then frameW = LAYOUT_HANDLE_MIN end
    if frameH < TINY_ANCHOR_THRESHOLD then frameH = LAYOUT_HANDLE_MIN end

    local targetX, targetY = GetPointOffsetForRect(targetPoint or "CENTER", parentW, parentH)
    local sourceX, sourceY = GetPointOffsetForRect(sourcePoint or "CENTER", frameW, frameH)

    return (targetX + (offsetX or 0) - sourceX), (targetY + (offsetY or 0) - sourceY)
end

local function IsSizeStableAnchoringEnabled(settings)
    if type(settings) ~= "table" then
        return true
    end
    -- Default ON for all frame anchoring overrides.
    return settings.sizeStable ~= false
end

-- Map castbar anchor keys → unit settings path for width fallback
local CASTBAR_UNIT_KEY_MAP = {
    playerCastbar = "player",
    targetCastbar = "target",
    focusCastbar  = "focus",
    petCastbar    = "pet",
    totCastbar    = "targettarget",
}

-- Look up the configured castbar width from unitframes DB settings
local function GetCastbarConfiguredWidth(key)
    local unitKey = CASTBAR_UNIT_KEY_MAP[key]
    if not unitKey then return nil end
    local db = QUICore and QUICore.db
    if not db then return nil end
    local unitSettings = db.profile and db.profile.unitframes and db.profile.unitframes[unitKey]
    local castSettings = unitSettings and unitSettings.castbar
    local w = castSettings and castSettings.width
    return (type(w) == "number" and w > 0) and w or nil
end

-- Apply auto-width and auto-height to a frame
-- Origin keys whose pending POSITION-ONLY consumer op must survive the
-- bulk pass with module-owned geometry intact: armed only around the
-- ApplyAllFrameAnchors key loop (see the harvest there). Auto-sizing such
-- an origin BEFORE the op replays clobbers its size (repro: width 77 →
-- 333 — the replayed op re-stamps position only, never size).
-- Stack, rather than one mutable set: force=true may enter a nested bulk pass
-- synchronously from a SetWidth/SetPoint side effect. Every nested pass must
-- honor all still-active outer suppression sets and restore them on return.
local suppressAutoSizingKeys = {}

local function ApplyAutoSizing(frame, settings, parentFrame, key)
    if not frame then return end
    if key then
        for i = #suppressAutoSizingKeys, 1, -1 do
            local keys = suppressAutoSizingKeys[i]
            if keys and keys[key] then return end
        end
    end

    -- Auto-width: match anchor target width
    -- parentFrame may now be a live forbidden aura container (aura→aura
    -- docking via ResolveParentFrame's Step 4 swap). GetWidth() on a
    -- forbidden frame returns a secret value, not a throw — the pcall below
    -- would not catch the later `parentWidth > 0` comparison exploding on
    -- it. _quiHostMover only exists on a live container, so this exclusion
    -- is a no-op until Task 4 stamps it.
    if settings.autoWidth and parentFrame and parentFrame ~= UIParent
        and not parentFrame._quiHostMover
    then
        local ok, parentWidth = pcall(function() return parentFrame:GetWidth() end)
        if ok and parentWidth and parentWidth > 0 then
            -- Resource bars size to the actual source frame, not the proxy.
            -- The proxy min-width floor is meant for player/target only.
            local isResourceBar = (key == "primaryPower" or key == "secondaryPower")
            if isResourceBar then
                local parentKey = settings.parent
                if parentKey == "essential" then parentKey = "cdmEssential"
                elseif parentKey == "utility" then parentKey = "cdmUtility" end
                -- Resource bars should size to the actual icon content width.
                -- For CDM sources, prefer viewer state rawContentWidth (the
                -- pre-inflation icon row width). For non-CDM sources (e.g.
                -- another resource bar), use the source frame's GetWidth.
                local resolver = parentKey and FRAME_RESOLVERS[parentKey]
                local sourceFrame = resolver and resolver()
                if sourceFrame then
                    local contentWidth
                    if CDM_LOGICAL_SIZE_KEYS[parentKey] then
                        local vs = _G.QUI_GetCDMViewerState and _G.QUI_GetCDMViewerState(sourceFrame)
                        contentWidth = vs and vs.rawContentWidth
                    end
                    if not contentWidth or contentWidth <= 0 then
                        local frameOk, frameWidth = pcall(function() return sourceFrame:GetWidth() end)
                        if frameOk and frameWidth and frameWidth > 0 then
                            contentWidth = frameWidth
                        end
                    end
                    if contentWidth and contentWidth > 0 then
                        parentWidth = contentWidth
                    end
                end
            end
            local adjustedWidth = parentWidth + (settings.widthAdjust or 0)
            if adjustedWidth > 0 then
                pcall(function() frame:SetWidth(adjustedWidth) end)
                -- Resource bars use fragmented power displays (runes, essence)
                -- that size from bar:GetWidth(). Trigger a module refresh so
                -- fragments re-layout to match the new width.
                if isResourceBar then
                    C_Timer.After(0, function()
                        if key == "primaryPower" then
                            if QUICore and QUICore.UpdatePowerBar then QUICore:UpdatePowerBar() end
                        elseif key == "secondaryPower" then
                            if QUICore and QUICore.UpdateSecondaryPowerBar then QUICore:UpdateSecondaryPowerBar() end
                        end
                    end)
                end
            end
        end

        -- Hook parent OnSizeChanged so auto-width stays in sync when parent resizes
        if not hookedParentFrames[parentFrame] then
            hookedParentFrames[parentFrame] = true
            pcall(function()
                parentFrame:HookScript("OnSizeChanged", function()
                    DebouncedReapplyOverrides()
                end)
            end)
        end
    elseif settings.autoWidth and CASTBAR_ANCHOR_KEYS[key] then
        -- autoWidth is enabled but there is no valid anchor parent —
        -- fall back to the castbar's own configured width so it doesn't
        -- keep a stale width from a previous anchor target.
        local fallbackWidth = GetCastbarConfiguredWidth(key)
        if fallbackWidth then
            pcall(function() frame:SetWidth(fallbackWidth) end)
        end
    end

    -- Auto-height: match CDM Essential row 1 icon height (player/target only)
    if settings.autoHeight then
        local viewer = _G.QUI_GetCDMViewerFrame and _G.QUI_GetCDMViewerFrame("essential")
        if viewer then
            local vs = _G.QUI_GetCDMViewerState and _G.QUI_GetCDMViewerState(viewer)
            local iconHeight = vs and vs.row1IconHeight
            if iconHeight and iconHeight > 0 then
                local adjustedHeight = iconHeight + (settings.heightAdjust or 0)
                if adjustedHeight > 0 then
                    pcall(function() frame:SetHeight(adjustedHeight) end)
                end
            end

            -- Hook viewer OnSizeChanged so auto-height stays in sync when CDM resizes
            if not hookedParentFrames[viewer] then
                hookedParentFrames[viewer] = true
                pcall(function()
                    viewer:HookScript("OnSizeChanged", function()
                        DebouncedReapplyOverrides()
                    end)
                end)
            end
        end
    end
end

-- Returns true only when anchoring a child to parentFrame would make the child
-- anchoring-restricted: i.e. parentFrame is a genuinely protected Blizzard
-- frame.  UIParent is never restricted.  Insecure (addon-owned) parents never
-- restrict.  Returns false on any unknown / secret value.
-- ns.Helpers is used directly here (not the `Helpers` upvalue) because
-- ParentRestricts can run before QUI_Anchoring:SetHelpers populates `Helpers`.
local function ParentRestricts(parentFrame)
    if parentFrame == UIParent then return false end
    -- IsProtected catches directly-secure targets; IsAnchoringRestricted catches
    -- the dependent case (e.g. a QUI container hosting SecureActionButton icon
    -- children), where IsProtected stays false but SetSize is still combat-blocked
    -- and the restriction propagates to anything anchored to it.
    return ns.Helpers.FrameIsProtected(parentFrame)
        or ns.Helpers.FrameIsAnchoringRestricted(parentFrame)
end

-- True when `frame` is ITSELF protected / anchoring-restricted (e.g. a
-- SecureAuraHeader like the buff/debuff icon containers, which are explicitly
-- protected by their secure aura children).  Such a frame cannot be
-- SetPoint/SetSize'd in combat no matter what it is anchored to, so the
-- absolute-pin trick gains nothing AND throws away the native relative follow.
-- ns.Helpers used directly: AnchorOrPin can run before SetHelpers populates `Helpers`.
local function FrameSelfRestricts(frame)
    if frame == UIParent then return false end
    return ns.Helpers.FrameIsProtected(frame)
        or ns.Helpers.FrameIsAnchoringRestricted(frame)
end

-- Anchor frame's pt to parentFrame's relPt (+x, +y).  For dynamic-size keys
-- whose parent is protected, pins to UIParent at absolute coords so the frame
-- is never anchoring-restricted in combat (SetSize stays legal).  Everything
-- else keeps relative anchoring (free follow from WoW's SetPoint chain).  Never throws.
--
-- The pin is taken ONLY when the frame being positioned is itself INSECURE.  A
-- frame that is itself protected / a SecureAuraHeader (buffFrame/debuffFrame
-- containers) is already anchoring-restricted by its own secure children:
-- pinning it is combat-blocked (ClearAllPoints/SetPoint on a protected frame),
-- and the relative anchor it keeps instead tracks the parent's secure-side
-- resize natively for free — which the absolute pin could not (the re-pin can't
-- run in combat, so the frame would freeze at its last out-of-combat position).
--
-- Follow for the absolute-pin case is event-driven: QUI_UpdateFramesAnchoredTo
-- re-calls ApplyFrameAnchor (→ AnchorOrPin) when the target moves, re-pinning
-- with fresh rect coords.  No per-tick loop — protected Blizzard parents are
-- repositioned out of combat (Edit Mode), covered by ApplyAllFrameAnchors.
local function AnchorOrPin(key, frame, pt, parentFrame, relPt, x, y)
    -- Container-first fan-out for buff/debuff: SetPoint the live forbidden
    -- container at the stored anchor (raw pcall'd Clear+Set — GetPoint-style
    -- reads on forbidden frames are not known-safe, so no SmoothSetPoint /
    -- FrameAlreadyAtPosition on this branch) and mirror the insecure mover
    -- to the same spot as the layout-mode handle. If the parent resolved to
    -- a live container (aura→aura docking), the mover mirrors against that
    -- container's insecure host mover instead — an insecure frame must
    -- never anchor to a forbidden one.
    local live, mover = LiveAuraContainerFor(key)
    if live then
        pcall(live.ClearAllPoints, live)
        pcall(live.SetPoint, live, pt, parentFrame, relPt, x, y)
        if mover then
            local moverParent = parentFrame
            if moverParent and moverParent._quiHostMover then
                moverParent = moverParent._quiHostMover
            end
            SmoothSetPoint(mover, pt, moverParent, relPt, x, y)
        end
        return
    end
    -- Non-live fall-through (this key's own container pool is empty — e.g.
    -- debuff host with no strips while docked to the buff host): the parent
    -- may still be a live forbidden container from the aura→aura swap.
    -- Retarget to its insecure host mover — an insecure frame must never
    -- anchor to a forbidden one (aspects propagate through anchors).
    if parentFrame and parentFrame._quiHostMover then
        parentFrame = parentFrame._quiHostMover
    end
    if IsDynamicSizeAnchorKey(key) and ParentRestricts(parentFrame)
        and not FrameSelfRestricts(frame)
    then
        -- On hold/false (secret rect not yet readable) the helper leaves the
        -- existing point untouched; the event-driven follow path retries on the
        -- next move.
        ns.Helpers.PinFrameToTargetAbsolute(frame, pt, parentFrame, relPt, x, y)
        return
    end
    SmoothSetPoint(frame, pt, parentFrame, relPt, x, y)
end

-- Apply a single frame anchor override
function QUI_Anchoring:ApplyFrameAnchor(key, settings)
    if type(settings) ~= "table" then return end

    -- Skip keys that a module has claimed for direct positioning. The module
    -- (e.g. resourcebars swap) is fully responsible for SetPoint while
    -- claimed; we must not fight it from the anchoring system.
    if self.claimedAnchorKeys[key] then return end

    if not HasFrameResolverForKey(key) then
        return
    end

    local resolved = ResolveApplyFrameForKey(key)
    if not resolved then
        return
    end

    -- chatFrame1 resolves to the QUI chat display (a QUI-owned frame);
    -- SetPoint on it is taint-free. The old Edit-Mode detach gate died with
    -- the takeover (ChatFrame1 itself is suppressed and never positioned).

    -- Never anchor UIParent-managed right-side frames from addon code.
    -- Keep them on Blizzard defaults to avoid protected layout taint.
    -- Still mark them overridden so internal anchoring checks work.
    if UNSAFE_BLIZZARD_MANAGED_OVERRIDES[key] then
        SetFrameOverride(resolved, true, key)
        return
    end

    -- Self-anchored frames manage their own SetPoint (e.g. anchored to a
    -- Blizzard panel). Skip positioning but mark overridden for layout handles.
    if SELF_ANCHORED_FRAMES[key] then
        SetFrameOverride(resolved, true, key)
        return
    end

    -- Mark frame as overridden FIRST — blocks any module positioning from this point on
    SetFrameOverride(resolved, true, key)

    -- Defer protected frames to combat end; non-protected addon frames can
    -- still be repositioned during combat. Skip the bail during the
    -- ADDON_LOADED / PLAYER_ENTERING_WORLD safe window where protected calls
    -- are allowed even in combat (ns._inInitSafeWindow).
    if InCombatLockdown() and not ns._inInitSafeWindow then
        local probe = resolved
        if type(resolved) == "table" and not resolved.GetObjectType then
            -- Boss frames array — check first frame
            probe = resolved[1]
        end
        -- Fail-closed probe. IsProtected catches directly-secure targets; a
        -- protected DEPENDENT (e.g. secure macro buttons on the chat button
        -- bar, anchored to the chat container) blocks SetPoint the same way
        -- but leaves IsProtected() false — IsAnchoringRestricted is the
        -- query for that state. Both getters can throw on a tainted stack
        -- and both returns can be secret (truth-testing a secret itself
        -- throws); the helper pcalls and issecretvalue-probes each answer,
        -- and any error/secret/true counts as restricted — defer to combat
        -- end rather than mutate a frame whose state can't be proven.
        if ns.Helpers.FrameMutationRestricted(probe) then
            pendingAnchoredFrameUpdateAfterCombat = true
            return
        end
    end

    -- Only hideWithParent/keepInPlace make sense when settings.parent is a
    -- real frame key. For the "screen" and "disabled" sentinels there's no
    -- parent frame whose visibility we can track and no frame to SetPoint
    -- against other than UIParent, which is always visible. In those cases
    -- fall through to the normal chain-walk path so the frame is positioned
    -- via ResolveParentFrame (which correctly resolves screen/disabled to
    -- UIParent) instead of getting Hide()'d or teleported to UIParent center.
    local parentKey = settings.parent
    local parentIsSentinel = not parentKey or parentKey == "screen" or parentKey == "disabled"

    -- hideWithParent: skip fallback chain, hide child when direct parent is hidden
    local parentFrame
    if settings.hideWithParent and not parentIsSentinel then
        local directParent = ResolveFrameForKey(parentKey)
        -- Hook visibility so we re-evaluate when the parent shows/hides
        if directParent then
            InstallVisibilityHook(directParent)
        end
        -- Secret-safe visibility read (alpha ≈ 0 counts as hidden: HUD
        -- visibility fades frames to alpha 0 instead of calling Hide, so
        -- IsShown stays true). IsShown/GetAlpha can throw on a tainted
        -- stack and can answer with secrets — truth-testing a secret
        -- throws, and a secret number passes the type() check but throws
        -- on comparison — so the helper pcalls and probes every read.
        -- nil = unprovable: never Hide/Show the child on a guess.
        local directVisible = ns.Helpers.FrameVisibleSecure(directParent)
        if directVisible == nil then
            if InCombatLockdown() then
                -- In combat the whole apply defers to the regen reconcile.
                pendingAnchoredFrameUpdateAfterCombat = true
                return
            end
            -- Out of combat: retry ONCE on a fresh stack — a secure-context
            -- throw clears when the tainted stack unwinds, so After(0)
            -- usually reads clean. Single-shot per (key, parent-identity)
            -- episode (cleared on the next readable pass, re-armed when the
            -- resolved parent frame changes) so a persistent secret never
            -- becomes an every-frame poll; further re-evaluation then rides
            -- the parent's visibility hooks / regen / bulk re-applies.
            if hideWithParentUnreadableRetried[key] ~= directParent then
                hideWithParentUnreadableRetried[key] = directParent
                C_Timer.After(0, function()
                    -- Uncancellable timer: re-check state inside the closure.
                    if InCombatLockdown() then
                        pendingAnchoredFrameUpdateAfterCombat = true
                        return
                    end
                    local reapply = _G.QUI_ApplyFrameAnchor
                    if reapply then reapply(key) end
                end)
            end
            -- Fall through WITHOUT touching visibility: the child is still
            -- POSITIONED against the direct parent below (SetPoint works on
            -- hidden frames and is safe out of combat), so an unreadable
            -- parent can never strand the child unanchored — only the
            -- hide/show decision waits for a readable answer.
        else
            hideWithParentUnreadableRetried[key] = nil
            if not directVisible then
                -- Parent hidden/missing — hide the child frame.
                -- Same fail-closed probe as above: an error/secret answer from
                -- the protection getters counts as restricted.
                local canMutate = not InCombatLockdown()
                    or not ns.Helpers.FrameMutationRestricted(resolved)
                if canMutate then
                    if type(resolved) == "table" and not resolved.GetObjectType then
                        for _, frame in ipairs(resolved) do pcall(frame.Hide, frame) end
                    else
                        pcall(resolved.Hide, resolved)
                    end
                end
                hideWithParentHidden[key] = true
                return
            end
            -- Direct parent visible — restore child if we previously hid it
            if hideWithParentHidden[key] then
                local canMutate = not InCombatLockdown()
                    or not ns.Helpers.FrameMutationRestricted(resolved)
                if canMutate then
                    if type(resolved) == "table" and not resolved.GetObjectType then
                        for _, frame in ipairs(resolved) do pcall(frame.Show, frame) end
                    else
                        pcall(resolved.Show, resolved)
                    end
                end
                hideWithParentHidden[key] = nil
            end
        end
        parentFrame = directParent
    elseif settings.keepInPlace and not parentIsSentinel then
        -- Keep In Place: anchor directly to the parent frame even if hidden.
        -- WoW's SetPoint works on hidden frames, so the child stays at the
        -- correct relative position. No chain walk, no settings adoption.
        local directParent = ResolveFrameForKey(parentKey)
        if directParent then
            InstallVisibilityHook(directParent)
        end
        parentFrame = directParent or UIParent
    elseif CASTBAR_ANCHOR_KEYS[key] then
        -- Castbars use alpha-based visibility and are always :Show(). Skip
        -- chain walk entirely — always anchor to the direct parent even when
        -- it is hidden. Chain walking would override point/relative with the
        -- intermediate parent's settings (e.g. CENTER/CENTER), losing the
        -- castbar's explicit relation (e.g. TOP→BOTTOM).
        parentFrame = ResolveFrameForKey(settings.parent) or UIParent
    else
        local chainSettings, parentUnreadable
        -- Pass `key` as originKey so the walker can never resolve a fallback
        -- chain back to the frame we're positioning (self-anchor loop).
        parentFrame, chainSettings, parentUnreadable = ResolveParentFrame(settings.parent, key)

        -- In combat an unreadable chain link makes the resolution a guess
        -- and the parent itself may be combat-restricted — defer the WHOLE
        -- apply to the regen reconcile (ResolveParentFrame already latched
        -- it) instead of mutating the child on unproven state. Mirrors the
        -- hideWithParent in-combat defer above.
        if parentUnreadable and InCombatLockdown() then
            return
        end

        -- When a chain walk occurred (hidden intermediate frame), adopt the
        -- last hidden link's anchor points so the child "replaces" it visually.
        -- e.g. stance bar (BL→TL of pet bar) falls back to bar 6 — should use
        -- pet bar's anchor points (BL→BR of bar 6), not stance bar's own.
        if chainSettings then
            settings = {
                point = chainSettings.point or settings.point,
                relative = chainSettings.relative or settings.relative,
                offsetX = chainSettings.offsetX or settings.offsetX,
                offsetY = chainSettings.offsetY or settings.offsetY,
                sizeStableAnchoring = settings.sizeStableAnchoring,
            }
        end
    end

    -- Aura→aura docking swap, applied UNIFORMLY after every parent-resolution
    -- branch above: the hideWithParent / keepInPlace / castbar branches
    -- resolve via ResolveFrameForKey (mover), bypassing the swap inside
    -- ResolveParentFrame — and debuffFrame ships keepInPlace=true by default,
    -- so without this the default profile would never dock container→container.
    -- Placed AFTER the branches so their IsShown/GetAlpha visibility reads
    -- above always ran against the insecure mover. Idempotent when the chain
    -- walk already swapped (LiveAuraContainerFor returns the same container).
    if FORBIDDEN_AURA_KEYS[key] and parentKey and FORBIDDEN_AURA_KEYS[parentKey] then
        local liveParent = LiveAuraContainerFor(parentKey)
        if liveParent then
            parentFrame = liveParent
        end
    end

    -- If parent is hidden, anchor directly to it — when it becomes visible
    -- and gets repositioned, the child follows automatically.
    -- (No chain walk needed without proxy system.)

    local point = settings.point or "CENTER"
    local relative = settings.relative or "CENTER"
    local offsetX = settings.offsetX or 0
    local offsetY = settings.offsetY or 0

    -- growAnchor: apply-time corner conversion for FREE-POSITION dynamic-
    -- size containers (buff/debuff/auraBar with parent=disabled or screen).
    --
    -- For free-position containers, layout mode writes CENTER-relative drag
    -- offsets (just like every other frame). But the container's actual
    -- SetPoint anchor needs to be a CORNER so the icons don't drift toward
    -- the center as the container grows/shrinks. The corner is determined
    -- by icon grow direction (set via the buff borders config) and stored
    -- as `settings.growAnchor`. Read here at apply time so the math always
    -- uses fresh values: the container's current natural size and UIParent's
    -- current dimensions.
    --
    -- IMPORTANT: only fires when the entry is CENTER-anchored (or has no
    -- explicit point/relative — both mean "free position"). For chain-
    -- anchored containers (e.g. buffFrame.parent=minimap with explicit
    -- point=TOPRIGHT, relative=TOPLEFT), the user's stored anchor pair
    -- already provides a stable fixed-corner reference: the source corner
    -- of the SetPoint sits at a fixed location on the parent frame, and
    -- icons positioned inside the container relative to that same source
    -- corner stay stable as the container resizes. No conversion needed.
    -- Forcing the conversion would rewrite the user's `relative` from
    -- TOPLEFT to TOPRIGHT (or whatever growAnchor is) and visually break
    -- the chain anchor.
    -- growAnchor legacy CENTER→corner self-heal path.
    --
    -- As of 3.1.5 Phase 2, SavePendingPosition writes buff/debuff entries in
    -- CORNER format directly (point=corner, relative=corner, offsets in
    -- corner space). The normal apply path below handles those entries
    -- with zero special-case code — it just SetPoints with the stored
    -- values.
    --
    -- For LEGACY entries still in CENTER format (e.g. profiles that ran
    -- through v25's "normalize to CENTER/CENTER" repair, or profiles from
    -- before Phase 2 landed), this branch converts the CENTER offsets to
    -- corner offsets at apply time AND writes the corner format back to
    -- the DB. After the self-heal, the entry is in the new format and
    -- this branch will never fire for it again.
    --
    -- Only fires when:
    --   * The entry is CENTER/CENTER (or has no explicit point/relative)
    --   * growAnchor is set to a valid corner (from UpdateGrowAnchor)
    --   * The key is a buff/debuff/auraBar container
    --   * The container has a REAL size (not the 1×1 pre-LayoutIcons state).
    --     If the container is still at its initial 1×1, we SetPoint with
    --     a reasonable fallback position but DO NOT write back — we wait
    --     until LayoutIcons runs with real icons and re-triggers an apply.
    local entryPoint    = settings.point or "CENTER"
    local entryRelative = settings.relative or "CENTER"
    local isLegacyCenter = entryPoint == "CENTER" and entryRelative == "CENTER"

    -- Excludes aura→aura docked parents: this branch reads parentFrame's
    -- GetWidth/GetHeight directly below (no pcall-protected value gate), and
    -- ResolveParentFrame's Step 4 swap can hand back a live forbidden
    -- container as parentFrame when settings.parent is the OTHER aura key.
    -- That combination is also semantically free-position-only per the
    -- comment above (chain-anchored containers keep their own stable
    -- corner and skip this self-heal), so falling through to the normal
    -- AnchorOrPin path below is correct, not just safe.
    if isLegacyCenter
        and settings.growAnchor and CORNER_POINTS and CORNER_POINTS[settings.growAnchor]
        and (key == "buffFrame" or key == "debuffFrame")
        and not (parentFrame and parentFrame._quiHostMover)
    then
        local corner = settings.growAnchor
        local fwRaw = (resolved.GetWidth and resolved:GetWidth()) or 0
        local fhRaw = (resolved.GetHeight and resolved:GetHeight()) or 0
        local fw, fh = fwRaw, fhRaw
        local sizeIsReal = fwRaw >= 4 and fhRaw >= 4
        if fw < 4 then
            fw = resolved._naturalW or settings._minWidth or 32
        end
        if fh < 4 then
            fh = resolved._naturalH or settings._minHeight or 32
        end
        -- If we fell back via _naturalW/_naturalH, treat that as real
        -- enough to self-heal — LayoutIcons was here at some point.
        if not sizeIsReal and (resolved._naturalW and resolved._naturalW >= 4) then
            sizeIsReal = true
        end
        local pw = (parentFrame and parentFrame.GetWidth and parentFrame:GetWidth()) or UIParent:GetWidth()
        local ph = (parentFrame and parentFrame.GetHeight and parentFrame:GetHeight()) or UIParent:GetHeight()
        local GA_FRAC_X = { TOPLEFT = 0, TOPRIGHT = 1, BOTTOMLEFT = 0, BOTTOMRIGHT = 1 }
        local GA_FRAC_Y = { TOPLEFT = 1, TOPRIGHT = 1, BOTTOMLEFT = 0, BOTTOMRIGHT = 0 }
        local cornerX = offsetX + (GA_FRAC_X[corner] - 0.5) * (fw - pw)
        local cornerY = offsetY + (GA_FRAC_Y[corner] - 0.5) * (fh - ph)
        AnchorOrPin(key, resolved, corner, parentFrame, corner, cornerX, cornerY)

        -- Self-heal: promote this entry from legacy CENTER format to the
        -- new corner format if we have a real container size. Subsequent
        -- applies will take the normal (non-branch) path because point/
        -- relative are now the corner, and the stored offsets match the
        -- SetPoint we just applied.
        if sizeIsReal and QUICore and QUICore.db and QUICore.db.profile then
            local faDB = QUICore.db.profile.frameAnchoring
            local dbEntry = faDB and faDB[key]
            if dbEntry
                and (dbEntry.point == nil or dbEntry.point == "CENTER")
                and (dbEntry.relative == nil or dbEntry.relative == "CENTER")
            then
                dbEntry.point = corner
                dbEntry.relative = corner
                dbEntry.offsetX = math.floor(cornerX + 0.5)
                dbEntry.offsetY = math.floor(cornerY + 0.5)
                -- growAnchor stays set; it's the "which corner is growth
                -- aligned" metadata that UpdateGrowAnchor reads.
            end
        end

        -- Skip ApplyAutoSizing — buff/debuff containers manage their own
        -- size via LayoutIcons.
        return
    end

    local useSizeStable = IsSizeStableAnchoringEnabled(settings)
    -- During early init, UIParent dimensions haven't settled — CENTER offset
    -- computation produces wrong values. Use raw point instead; deferred
    -- timers will reapply with correct CENTER offsets later.
    if _forceRawPointMode then
        useSizeStable = false
    end
    if CASTBAR_ANCHOR_KEYS[key] then
        -- Castbars should preserve the explicit point relation (e.g. TOP->BOTTOM)
        -- so they track parent edge movement automatically in combat.
        useSizeStable = false
    end
    if IsDynamicSizeAnchorKey(key) or IsDynamicSizeAnchorKey(settings.parent) then
        useSizeStable = false
    end

    -- Boss frames: apply the saved anchor to boss1, then chain the rest
    -- according to the boss frame layout settings.
    if key == "bossFrames" and type(resolved) == "table" and not resolved.GetObjectType then
        local bossGrowDirection, bossSpacingX, bossSpacingY = GetBossFrameLayout()
        for i, frame in ipairs(resolved) do
            if useSizeStable then
                ApplyAutoSizing(frame, settings, parentFrame, key)
            end
            local targetParent = parentFrame
            local targetPt, targetRelPt, targetX, targetY
            if i == 1 then
                if useSizeStable then
                    local centerX, centerY = ComputeCenterOffsetsForAnchor(
                        frame, key, parentFrame, point, relative, offsetX, offsetY, settings.parent
                    )
                    targetPt, targetRelPt, targetX, targetY = "CENTER", "CENTER", centerX, centerY
                else
                    targetPt, targetRelPt, targetX, targetY = point, relative, offsetX, offsetY
                end
            else
                targetParent = resolved[i - 1]
                targetPt, targetRelPt, targetX, targetY = GetBossStackPoint(bossGrowDirection, bossSpacingX, bossSpacingY)
            end
            if targetParent and not FrameAlreadyAtPosition(frame, targetPt, targetParent, targetRelPt, targetX, targetY) then
                _editModeReapplyGuard = true
                pcall(SmoothSetPoint, frame, targetPt, targetParent, targetRelPt, targetX, targetY)
                _editModeReapplyGuard = false
            end
        end
        if not useSizeStable then
            ApplyAutoSizing(resolved[1], settings, parentFrame, key)
            for i = 2, #resolved do
                ApplyAutoSizing(resolved[i], settings, parentFrame, key)
            end
        end
        return
    end

    -- Normal single-frame case
    if useSizeStable then
        -- Size-stable anchoring: solve requested point->point relation into a
        -- center anchor. This prevents visual drift when frame dimensions mutate.
        ApplyAutoSizing(resolved, settings, parentFrame, key)
        local centerX, centerY = ComputeCenterOffsetsForAnchor(
            resolved, key, parentFrame, point, relative, offsetX, offsetY, settings.parent
        )
        -- SetPoint offsets are interpreted in the frame's OWN scaled coord
        -- space. centerX/Y are in UIParent (parent) coord. Divide by the
        -- frame's own scale so the visual position matches. No-op for scale=1.
        if resolved and resolved.GetScale then
            local fScale = resolved:GetScale() or 1
            if fScale > 0 and fScale ~= 1 then
                centerX = centerX / fScale
                centerY = centerY / fScale
            end
        end
        if not FrameAlreadyAtPosition(resolved, "CENTER", parentFrame, "CENTER", centerX, centerY) then
            _editModeReapplyGuard = true
            pcall(AnchorOrPin, key, resolved, "CENTER", parentFrame, "CENTER", centerX, centerY)
            _editModeReapplyGuard = false
        end
    else
        -- When parent or child frame is a tiny anchor marker (≤ 2px),
        -- saved offsets were computed against inflated handle edges. Raw
        -- SetPoint uses real frame edges, so convert to CENTER→CENTER with
        -- inflated dimensions to match the visual position from layout mode.
        -- Skip for dynamically-sized containers (buff/debuff) — they start
        -- at 1x1 intentionally and grow as icons appear; converting to
        -- CENTER would break the growth-edge anchoring that LayoutIcons
        -- depends on.
        local skipInflation = IsDynamicSizeAnchorKey(key)
            or IsDynamicSizeAnchorKey(settings.parent)
        local needsInflation = false
        if not skipInflation and parentFrame and parentFrame ~= UIParent and parentFrame.GetSize then
            local ok, pw, ph = pcall(parentFrame.GetSize, parentFrame)
            if ok and pw and ph and (pw < TINY_ANCHOR_THRESHOLD or ph < TINY_ANCHOR_THRESHOLD) then
                needsInflation = true
            end
        end
        if not skipInflation and not needsInflation and resolved and resolved.GetSize then
            local ok, rw, rh = pcall(resolved.GetSize, resolved)
            if ok and rw and rh and (rw < TINY_ANCHOR_THRESHOLD or rh < TINY_ANCHOR_THRESHOLD) then
                needsInflation = true
            end
        end
        if needsInflation then
            local centerX, centerY = ComputeCenterOffsetsForAnchor(
                resolved, key, parentFrame, point, relative, offsetX, offsetY, settings.parent
            )
            if not FrameAlreadyAtPosition(resolved, "CENTER", parentFrame, "CENTER", centerX, centerY) then
                _editModeReapplyGuard = true
                pcall(AnchorOrPin, key, resolved, "CENTER", parentFrame, "CENTER", centerX, centerY)
                _editModeReapplyGuard = false
            end
        else
            -- The mover can already sit at the saved point (FrameAlreadyAtPosition
            -- reads ITS geometry, always safe — resolved is the insecure mover)
            -- while a live forbidden container needs its own SetPoint: never
            -- observed by FrameAlreadyAtPosition, and pool-cycled/newly-claimed
            -- containers must always be (re)anchored. Skip the short-circuit
            -- whenever a live container is in play for this key.
            local live = LiveAuraContainerFor(key)
            if live or not FrameAlreadyAtPosition(resolved, point, parentFrame, relative, offsetX, offsetY) then
                _editModeReapplyGuard = true
                pcall(AnchorOrPin, key, resolved, point, parentFrame, relative, offsetX, offsetY)
                _editModeReapplyGuard = false
            end
        end
        ApplyAutoSizing(resolved, settings, parentFrame, key)
    end
end

-- Compute dependency-ordered apply sequence for frame anchoring overrides.
-- Uses Kahn's algorithm (topological sort) so that parent frames are
-- positioned before their children, preventing transient jumps when frames
-- are anchored in arbitrary chains (e.g. buffIcon → primaryPower → cdmEssential).
ComputeAnchorApplyOrder = function(anchoringDB)
    -- 1. Collect all enabled override keys
    local enabledSet = {}
    local enabledList = {}
    for key, settings in pairs(anchoringDB) do
        if type(settings) == "table" and HasFrameResolverForKey(key) then
            enabledSet[key] = true
            enabledList[#enabledList + 1] = key
        end
    end

    if #enabledList == 0 then return enabledList end

    -- 2. Build dependency edges (key depends on parent when parent is also overridden)
    local inDegree  = {}
    local childrenOf = {}
    for _, key in ipairs(enabledList) do
        inDegree[key] = 0
        childrenOf[key] = {}
    end

    for _, key in ipairs(enabledList) do
        local parent = anchoringDB[key].parent
        -- Normalize legacy aliases
        if parent == "essential" then parent = "cdmEssential" end
        if parent == "utility"  then parent = "cdmUtility"   end

        if parent and enabledSet[parent] then
            inDegree[key] = inDegree[key] + 1
            childrenOf[parent][#childrenOf[parent] + 1] = key
        end
    end

    -- 3. Kahn's BFS — roots (no in-system parent) first
    local sorted = {}
    local queue  = {}
    for _, key in ipairs(enabledList) do
        if inDegree[key] == 0 then
            queue[#queue + 1] = key
        end
    end

    local head = 1
    while head <= #queue do
        local key = queue[head]
        head = head + 1
        sorted[#sorted + 1] = key
        for _, child in ipairs(childrenOf[key]) do
            inDegree[child] = inDegree[child] - 1
            if inDegree[child] == 0 then
                queue[#queue + 1] = child
            end
        end
    end

    -- 4. Cycle fallback — append any remaining keys so they still get applied
    if #sorted < #enabledList then
        for _, key in ipairs(enabledList) do
            if inDegree[key] > 0 then
                sorted[#sorted + 1] = key
            end
        end
    end

    return sorted
end

-- Apply all saved frame anchor overrides (dependency-ordered)
-- Throttle: prevent ApplyAllFrameAnchors from running more than once per frame.
-- CDM bounds changes and PowerBar updates can trigger cascading re-anchor calls.
local _anchorThrottleFrame = nil
local _anchorThrottlePending = false
-- Coalesced replay: a request that lands while the throttle is armed (e.g. a
-- visibility flip right after this frame's apply already ran) must not be
-- dropped — one replay runs on the next frame.
local _anchorThrottleReplay = false
-- Work that semantically follows a full pass (not merely the REQUEST for
-- one). The combat reconcile uses this to keep consumer ops latched when its
-- request coalesces onto the next-frame replay.
local _anchorThrottleAfterApply = {}
-- force=true deliberately bypasses the once-per-frame throttle and can enter
-- synchronously from a geometry side effect. Completion callbacks belong to
-- the outermost successful pass, never to an inner forced pass.
local _anchorApplyDepth = 0

local function QueueAfterAnchorApply(callback)
    if callback then
        _anchorThrottleAfterApply[#_anchorThrottleAfterApply + 1] = callback
    end
end

local function RunAfterAnchorApply()
    if #_anchorThrottleAfterApply == 0 then return end
    local callbacks = _anchorThrottleAfterApply
    _anchorThrottleAfterApply = {}
    for _, callback in ipairs(callbacks) do
        callback()
    end
end

function QUI_Anchoring:ApplyAllFrameAnchors(force, afterApply)
    if not QUICore or not QUICore.db or not QUICore.db.profile then
        return "skipped"
    end
    local anchoringDB = QUICore.db.profile.frameAnchoring
    if not anchoringDB then return "skipped" end

    -- During layout mode, skip bulk reapply — the handle system owns frame
    -- positions. Debounced reapply (from module refreshes, OnSizeChanged)
    -- would yank frames away from movers. Individual ApplyFrameAnchor calls
    -- (from settings changes) are still allowed. force=true bypasses this
    -- (used by post-Close reapply in SaveAndClose/DiscardAndClose).
    if not force and _G.QUI_IsLayoutModeActive and _G.QUI_IsLayoutModeActive() then
        return "skipped"
    end

    -- Throttle: if already applied this frame, coalesce ONE replay on the
    -- next frame — dropping the request outright loses whatever state change
    -- (visibility flip, resize) triggered it.
    if not force and _anchorThrottlePending then
        QueueAfterAnchorApply(afterApply)
        _anchorThrottleReplay = true
        return "deferred"
    end
    QueueAfterAnchorApply(afterApply)
    _anchorThrottlePending = true
    if not _anchorThrottleFrame then
        _anchorThrottleFrame = CreateFrame("Frame")
        _anchorThrottleFrame:SetScript("OnUpdate", function(self)
            _anchorThrottlePending = false
            self:Hide()
            if _anchorThrottleReplay then
                _anchorThrottleReplay = false
                local replayOK, replayStatus = pcall(
                    QUI_Anchoring.ApplyAllFrameAnchors, QUI_Anchoring)
                if not replayOK then
                    -- A queued completion callback means this replay belongs
                    -- to a regen reconcile. Preserve its queue and relatch the
                    -- required full pass; ordinary replay failures retain the
                    -- prior error-reporting behavior.
                    if #_anchorThrottleAfterApply > 0 then
                        pendingAnchoredFrameUpdateAfterCombat = true
                    else
                        error(replayStatus, 0)
                    end
                elseif replayStatus == "skipped" then
                    -- Mirror the direct regen path: layout/profile state can
                    -- make the deferred full pass intentionally unavailable,
                    -- but its independently replayable consumer ops must not
                    -- remain queued until an unrelated future bulk apply.
                    RunAfterAnchorApply()
                end
            end
        end)
    end
    _anchorThrottleFrame:Show()

    _anchorApplyDepth = _anchorApplyDepth + 1
    local suppressionPushed = false
    local applyOK, applyError = xpcall(function()
        -- Consumer retries (position-only, overlay) armed against unreadable
        -- links live as state in resolveUnreadableRetried; the wipe below
        -- defuses their timers (identity check), and the bulk pass below only
        -- re-runs the DEFAULT apply per key. Harvest the pending consumer ops
        -- BEFORE the wipe and replay them after the pass — otherwise any bulk
        -- apply or visibility callback racing an armed consumer retry silently
        -- drops it (stale overlay, auto-sized position-only frame).
        local replayConsumerOps
        -- Same-origin sizing suppression: the bulk pass below runs the DEFAULT
        -- auto-sizing apply per key, but an origin with a pending POSITION-ONLY
        -- consumer op has module-owned geometry — sizing it before the op
        -- replays clobbers that size (width 77 → 333) while the replay only
        -- re-stamps position. Slot identity picks exactly those origins;
        -- unrelated keys and other consumer slots keep full sizing. Pending
        -- ops live in TWO stores: armed retry states (harvested here, replayed
        -- below) and combat-latched ops (drained by the regen handler right
        -- after this bulk apply returns).
        local positionOnlyPending
        for opOriginKey, bySlot in pairs(resolveUnreadableRetried) do
            for slotKey, state in pairs(bySlot) do
                if type(state.op) == "function" then
                    replayConsumerOps = replayConsumerOps or {}
                    replayConsumerOps[#replayConsumerOps + 1] = { op = state.op, key = opOriginKey }
                end
                if slotKey == "positionOnly" then
                    positionOnlyPending = positionOnlyPending or {}
                    positionOnlyPending[opOriginKey] = true
                end
            end
        end
        for opOriginKey, bySlot in pairs(pendingCombatConsumerOps) do
            if bySlot["positionOnly"] then
                positionOnlyPending = positionOnlyPending or {}
                positionOnlyPending[opOriginKey] = true
            end
        end

        -- Clear all runtime state before re-applying from current profile.
        -- Prevents stale overrides and anchor relationships from a previous
        -- profile leaking across profile/spec switches.
        wipe(self.layoutOwnedFrames)
        wipe(hideWithParentUnreadableRetried)
        wipe(resolveUnreadableRetried)

        local sorted = ComputeAnchorApplyOrder(anchoringDB)
        suppressAutoSizingKeys[#suppressAutoSizingKeys + 1] = positionOnlyPending or false
        suppressionPushed = true
        for _, key in ipairs(sorted) do
            self:ApplyFrameAnchor(key, anchoringDB[key])
        end
        suppressAutoSizingKeys[#suppressAutoSizingKeys] = nil
        suppressionPushed = false

        -- Ensure ApplySystemAnchor guards are installed for any newly resolved frames
        InstallAllAnchorGuards()

        -- Replay harvested consumer ops on top of the bulk pass. A replay that
        -- hits a still-unreadable link re-arms its own fresh retry episode.
        if replayConsumerOps then
            for _, entry in ipairs(replayConsumerOps) do
                -- pcall: one throwing consumer must not drop the rest.
                pcall(entry.op, entry.key)
            end
        end
    end, function(err)
        return err
    end)
    if suppressionPushed then
        suppressAutoSizingKeys[#suppressAutoSizingKeys] = nil
    end
    _anchorApplyDepth = _anchorApplyDepth - 1
    if not applyOK then
        error(applyError, 0)
    end

    -- A SetSize/SetPoint side effect may have requested another coalesced
    -- pass while this one was running. The callbacks belong after the whole
    -- replay chain; pending combat ops also keep the next pass's same-origin
    -- sizing suppression intact until then.
    if _anchorApplyDepth == 0 and not _anchorThrottleReplay then
        RunAfterAnchorApply()
    end
    return "applied"
end

---------------------------------------------------------------------------
-- GLOBAL CALLBACKS
---------------------------------------------------------------------------
-- Check if a frame-anchoring key has a saved/raw position in the DB.
-- Modules call this to skip self-positioning when the anchoring system manages the frame.
_G.QUI_HasFrameAnchor = function(key)
    if not key then return false end
    local core = QUICore
    local db = core and core.db and core.db.profile
    return GetSavedFrameAnchorSettings(db and db.frameAnchoring, key) ~= nil
end

-- Returns true when the anchoring system has hidden a frame because its
-- anchor parent is hidden (hideWithParent).  Other systems (CDM layout,
-- hud_visibility) should respect this and avoid re-showing the frame.
_G.QUI_IsFrameHiddenByAnchor = function(key)
    return hideWithParentHidden[key] or false
end

-- Mark/unmark a frame in the layoutOwnedFrames table so PositionFrame
-- skips module positioning for frames managed by layout mode handles,
-- even when they have no frameAnchoring DB entry.
_G.QUI_SetFrameLayoutOwned = function(frame, key)
    if QUI_Anchoring and frame then
        QUI_Anchoring.layoutOwnedFrames[frame] = key or nil
    end
end

-- Claim/release an anchoring key for module-driven positioning.  While
-- claimed, the anchoring system will not call SetPoint on the resolved
-- frame for that key — neither during single-key applies nor during the
-- full ApplyAllFrameAnchors pass.  Releasing the claim does NOT
-- automatically reapply: callers should follow up with
-- QUI_ForceReapplyFrameAnchor(key) if they want the frame snapped back to
-- its saved anchor immediately.
_G.QUI_ClaimAnchorKey = function(key, claimed)
    if not key then return end
    if not QUI_Anchoring then return end
    QUI_Anchoring.claimedAnchorKeys[key] = claimed and true or nil
end

_G.QUI_ApplyAllFrameAnchors = function(force)
    if QUI_Anchoring then
        QUI_Anchoring:ApplyAllFrameAnchors(force)
    end
end

_G.QUI_ApplyFrameAnchor = function(key)
    if not QUI_Anchoring or not QUICore or not QUICore.db or not QUICore.db.profile then
        return
    end
    local anchoringDB = QUICore.db.profile.frameAnchoring
    local settings = GetSavedFrameAnchorSettings(anchoringDB, key)
    if settings and HasFrameResolverForKey(key) then
        QUI_Anchoring:ApplyFrameAnchor(key, settings)
    end
end

-- Read-only: expose the frame the anchoring system SetPoints for a key
-- (e.g. "minimap" → the QUI_MinimapAnchor proxy). Layout mode uses this to
-- detect proxy-indirect keys whose proxy must be re-applied on drag so
-- frames anchored to the proxy follow immediately.
_G.QUI_ResolveAnchorApplyFrame = function(key)
    if not key then return nil end
    return ResolveApplyFrameForKey(key)
end

-- Read-only: resolve an anchor PARENT key to its live frame, exactly as
-- ApplyFrameAnchor's parent resolution does (frame resolvers + anchor
-- target registry). Used by layout mode to compute handle positions for
-- entries anchored to a frame that has no mover handle of its own.
_G.QUI_ResolveAnchorTargetFrame = function(key)
    if not key or key == "screen" or key == "disabled" then return nil end
    return ResolveFrameForKey(key)
end

-- Force re-apply: clears the frame's existing anchors first so the
-- anchor chain is definitely re-established. Used when a parent frame
-- moves and we need children to follow regardless of FrameAlreadyAtPosition.
_G.QUI_ForceReapplyFrameAnchor = function(key)
    if not QUI_Anchoring or not QUICore or not QUICore.db or not QUICore.db.profile then
        return
    end
    local anchoringDB = QUICore.db.profile.frameAnchoring
    local settings = GetSavedFrameAnchorSettings(anchoringDB, key)
    if not settings or not HasFrameResolverForKey(key) then return end
    local resolved = ResolveApplyFrameForKey(key)
    if resolved then
        if type(resolved) == "table" and not resolved.GetObjectType then
            for _, frame in ipairs(resolved) do pcall(frame.ClearAllPoints, frame) end
        else
            pcall(resolved.ClearAllPoints, resolved)
        end
    end
    QUI_Anchoring:ApplyFrameAnchor(key, settings)
end

-- Re-assert a frame's saved anchor after a programmatic resize (size
-- sliders). SetSize keeps the frame's CURRENT SetPoint fixed — for
-- size-stable anchored frames that point is CENTER, so the frame grows
-- symmetrically and drifts off its anchored corner/edge. Re-applying the
-- saved anchor re-solves the stored point relation against the NEW size,
-- keeping the anchor point visually pinned with growth away from it.
-- Free entries (parent="disabled"/no entry) keep center growth — there is
-- no anchor to pin. In layout mode, any pending drag position holds
-- pre-resize CENTER offsets and would yank the handle back — clear it and
-- re-sync the handle to the re-anchored frame.
_G.QUI_ReassertAnchorAfterResize = function(key)
    if not key or not QUICore or not QUICore.db or not QUICore.db.profile then
        return
    end
    local anchoringDB = QUICore.db.profile.frameAnchoring
    local settings = GetSavedFrameAnchorSettings(anchoringDB, key)
    if not settings then return end
    local parent = settings.parent
    if not parent or parent == "disabled" then return end
    if _G.QUI_LayoutModeClearPending then
        _G.QUI_LayoutModeClearPending(key)
    end
    _G.QUI_ForceReapplyFrameAnchor(key)
    if _G.QUI_LayoutModeSyncHandle then
        _G.QUI_LayoutModeSyncHandle(key)
    end
end

-- Position-only re-anchor: repositions a frame to its configured
-- parent without calling ApplyAutoSizing.
_G.QUI_ReanchorFramePositionOnly = function(key)
    if not key then return end
    if InCombatLockdown() then
        -- Started in combat: latch THIS operation for the regen drain.
        -- Silently dropping it left the frame stale, and the regen bulk
        -- apply is no substitute — it runs ApplyAutoSizing, exactly what
        -- this entry point exists to avoid (repro: width 77 → 333).
        latchCombatConsumerOp(key, "positionOnly", _G.QUI_ReanchorFramePositionOnly)
        return
    end
    if not QUI_Anchoring or not QUICore or not QUICore.db or not QUICore.db.profile then return end
    local anchoringDB = QUICore.db.profile.frameAnchoring
    if not anchoringDB then return end
    local settings = anchoringDB[key]
    if type(settings) ~= "table" then return end

    if not HasFrameResolverForKey(key) then return end
    local resolved = ResolveApplyFrameForKey(key)
    if not resolved then return end

    -- retryOp: an unreadable chain link must replay THIS position-only
    -- operation, not the full QUI_ApplyFrameAnchor apply (which would run
    -- ApplyAutoSizing — exactly what this entry point exists to avoid).
    -- Own retryKey: the latch slot must not collide with the full apply's.
    local parentFrame = ResolveParentFrame(settings.parent, key,
        _G.QUI_ReanchorFramePositionOnly, "positionOnly")
    if not parentFrame then return end
    -- ResolveParentFrame can hand back a live forbidden aura container
    -- (aura->aura docking). This path SetPoints `resolved` directly (no
    -- AnchorOrPin fan-out) and `resolved` is always the insecure mover — an
    -- insecure frame must never anchor to a forbidden one. Re-target to the
    -- container's host-mover back-pointer; nil pre-Task 4, so a no-op today.
    if parentFrame._quiHostMover then
        parentFrame = parentFrame._quiHostMover
    end

    local point = settings.point or "CENTER"
    local relative = settings.relative or "CENTER"
    local offsetX = settings.offsetX or 0
    local offsetY = settings.offsetY or 0
    local useSizeStable = IsSizeStableAnchoringEnabled(settings)
    if CASTBAR_ANCHOR_KEYS[key] or IsDynamicSizeAnchorKey(key)
        or IsDynamicSizeAnchorKey(settings.parent) then
        useSizeStable = false
    end

    local H = nsHelpers or ns.Helpers
    pcall(function()
        H.BaseClearAllPoints(resolved)
        if useSizeStable then
            local centerX, centerY = ComputeCenterOffsetsForAnchor(
                resolved, key, parentFrame, point, relative, offsetX, offsetY, settings.parent
            )
            H.BaseSetPoint(resolved, "CENTER", parentFrame, "CENTER", centerX, centerY)
        else
            H.BaseSetPoint(resolved, point, parentFrame, relative, offsetX, offsetY)
        end
    end)
end

-- Anchor an arbitrary overlay frame to a key's configured parent.
-- Used during Edit Mode to position QUI overlays at the correct anchored
-- location without touching the protected Blizzard system frame itself.
-- overlayFrame: the QUI overlay to position
-- key: frame anchoring key (e.g. "buffIcon")
-- overlayW, overlayH: explicit size for center offset math (icon content area)
_G.QUI_AnchorOverlayToParent = function(overlayFrame, key, overlayW, overlayH)
    if not overlayFrame or not key then return end
    if not QUI_Anchoring or not QUICore or not QUICore.db or not QUICore.db.profile then return end
    local anchoringDB = QUICore.db.profile.frameAnchoring
    if not anchoringDB then return end
    local settings = anchoringDB[key]
    if type(settings) ~= "table" then return end

    -- retryOp: an unreadable chain link must replay THIS overlay anchoring,
    -- not QUI_ApplyFrameAnchor — the full apply repositions the real frame
    -- and leaves the overlay stale. retryKey = the overlay frame: a STABLE
    -- identity (the closure below is fresh per call and would re-arm every
    -- pass), distinct per overlay so co-existing overlays on one originKey
    -- and the full apply's own retry never suppress each other.
    local parentFrame, _, parentUnreadable = ResolveParentFrame(
        settings.parent, key,
        function()
            _G.QUI_AnchorOverlayToParent(overlayFrame, key, overlayW, overlayH)
        end,
        overlayFrame)
    if not parentFrame then return end
    -- In combat an unreadable chain link defers this overlay reposition the
    -- same way ApplyFrameAnchor defers: the parent may be combat-restricted
    -- and the resolution is a guess.
    if parentUnreadable and InCombatLockdown() then return end
    -- ResolveParentFrame can hand back a live forbidden aura container
    -- (aura->aura docking). This path SetPoints an arbitrary insecure
    -- overlay frame directly — an insecure frame must never anchor to a
    -- forbidden one. Re-target to the container's host-mover back-pointer;
    -- nil pre-Task 4, so a no-op today.
    if parentFrame._quiHostMover then
        parentFrame = parentFrame._quiHostMover
    end

    local point = settings.point or "CENTER"
    local relative = settings.relative or "CENTER"
    local offsetX = settings.offsetX or 0
    local offsetY = settings.offsetY or 0
    local useSizeStable = IsSizeStableAnchoringEnabled(settings)
    if CASTBAR_ANCHOR_KEYS[key] or IsDynamicSizeAnchorKey(key)
        or IsDynamicSizeAnchorKey(settings.parent) then
        useSizeStable = false
    end

    overlayFrame:ClearAllPoints()
    if overlayW and overlayW > 0 then overlayFrame:SetWidth(overlayW) end
    if overlayH and overlayH > 0 then overlayFrame:SetHeight(overlayH) end
    if useSizeStable then
        -- Compute center offsets using the overlay's dimensions and parent rect
        local parentW, parentH = GetParentAnchorRect(parentFrame, settings.parent)
        -- Inflate very small parent dims (see ComputeCenterOffsetsForAnchor)
        if parentFrame ~= UIParent then
            if parentW < TINY_ANCHOR_THRESHOLD then parentW = LAYOUT_HANDLE_MIN end
            if parentH < TINY_ANCHOR_THRESHOLD then parentH = LAYOUT_HANDLE_MIN end
        end
        -- Also inflate tiny overlay dims
        local ow = (overlayW or 1) < TINY_ANCHOR_THRESHOLD and LAYOUT_HANDLE_MIN or (overlayW or 1)
        local oh = (overlayH or 1) < TINY_ANCHOR_THRESHOLD and LAYOUT_HANDLE_MIN or (overlayH or 1)
        local targetX, targetY = GetPointOffsetForRect(relative or "CENTER", parentW, parentH)
        local sourceX, sourceY = GetPointOffsetForRect(point or "CENTER", ow, oh)
        local centerX = (targetX + (offsetX or 0) - sourceX)
        local centerY = (targetY + (offsetY or 0) - sourceY)
        overlayFrame:SetPoint("CENTER", parentFrame, "CENTER", centerX, centerY)
    else
        overlayFrame:SetPoint(point, parentFrame, relative, offsetX, offsetY)
    end
end

-- Debounced reapply of frame anchoring overrides after module repositioning
local pendingOverrideReapply = nil

DebouncedReapplyOverrides = function()
    if pendingOverrideReapply then return end
    pendingOverrideReapply = true
    C_Timer.After(0.15, function()
        pendingOverrideReapply = nil
        if QUI_Anchoring then
            QUI_Anchoring:ApplyAllFrameAnchors()
        end
    end)
end

-- Hook module refresh globals to reapply overrides after modules reposition frames.
-- These globals are defined by modules that load before this file in QUI.toc.
local function HookRefreshGlobal(name)
    local original = _G[name]
    if not original then return end
    _G[name] = function(...)
        original(...)
        DebouncedReapplyOverrides()
    end
end

HookRefreshGlobal("QUI_RefreshCastbar")
HookRefreshGlobal("QUI_RefreshCastbars")
HookRefreshGlobal("QUI_RefreshUnitFrames")
HookRefreshGlobal("QUI_RefreshGroupFrames")
HookRefreshGlobal("QUI_RefreshNCDM")
HookRefreshGlobal("QUI_RefreshCDMBuffLayout")
HookRefreshGlobal("QUI_RefreshRaidBuffs")

-- Modules that load after utility (trackers, qol, dungeon) need deferred hooking
-- since their globals don't exist yet at file-load time.
C_Timer.After(0, function()
    HookRefreshGlobal("QUI_RefreshCustomTrackers")
    HookRefreshGlobal("QUI_RefreshBrezCounter")
    HookRefreshGlobal("QUI_RefreshAtonementCounter")
    HookRefreshGlobal("QUI_RefreshCombatTimer")
    HookRefreshGlobal("QUI_RefreshRangeCheck")
    HookRefreshGlobal("QUI_RefreshXPTracker")
    HookRefreshGlobal("QUI_RefreshActionTracker")
    HookRefreshGlobal("QUI_RefreshSkyriding")
    HookRefreshGlobal("QUI_RefreshPetWarning")
    HookRefreshGlobal("QUI_RefreshFocusCastAlert")
end)

-- Explicit post-update hooks — replaces the capture-and-rewrap pattern on
-- _G.QUI_UpdateAnchoredFrames. Registration is idempotent by name (re-
-- registering replaces the slot in place), hooks run in first-registration
-- order, each isolated by pcall. Integrations register here instead of
-- wrapping the global.
local anchoredFramesPostHooks = {}   -- array of { name = string, fn = function }

function QUI_Anchoring.RegisterAnchoredFramesPostHook(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then return end
    for _, hook in ipairs(anchoredFramesPostHooks) do
        if hook.name == name then
            hook.fn = fn
            return
        end
    end
    anchoredFramesPostHooks[#anchoredFramesPostHooks + 1] = { name = name, fn = fn }
end

local function RunAnchoredFramesPostHooks(...)
    for _, hook in ipairs(anchoredFramesPostHooks) do
        local ok, err = pcall(hook.fn, ...)
        if not ok then
            print("|cFFFF6666QUI:|r anchored-frames hook error [" .. hook.name .. "]: " .. tostring(err))
        end
    end
end

-- Global callback for updating anchored frames (called by NCDM, resource bars, etc.)
-- Preserve any existing unit-frame updater to avoid breaking legacy anchoring.
local previousUpdateAnchoredFrames = _G.QUI_UpdateAnchoredFrames
local previousUpdateAnchoredUnitFrames = _G.QUI_UpdateAnchoredUnitFrames
local previousUpdateCDMAnchoredUnitFrames = _G.QUI_UpdateCDMAnchoredUnitFrames

_G.QUI_UpdateAnchoredFrames = function(...)
    if previousUpdateAnchoredFrames and previousUpdateAnchoredFrames ~= _G.QUI_UpdateAnchoredFrames then
        previousUpdateAnchoredFrames(...)
    end
    -- Reapply frame anchoring overrides after modules finish repositioning
    DebouncedReapplyOverrides()
    RunAnchoredFramesPostHooks(...)
end

-- Backward compatibility aliases that also honor any pre-existing unit-frame updater
_G.QUI_UpdateAnchoredUnitFrames = function(...)
    if previousUpdateAnchoredUnitFrames and previousUpdateAnchoredUnitFrames ~= _G.QUI_UpdateAnchoredUnitFrames and previousUpdateAnchoredUnitFrames ~= previousUpdateAnchoredFrames then
        previousUpdateAnchoredUnitFrames(...)
    end
    _G.QUI_UpdateAnchoredFrames(...)
end

_G.QUI_UpdateCDMAnchoredUnitFrames = function(...)
    if previousUpdateCDMAnchoredUnitFrames and previousUpdateCDMAnchoredUnitFrames ~= _G.QUI_UpdateCDMAnchoredUnitFrames and previousUpdateCDMAnchoredUnitFrames ~= previousUpdateAnchoredFrames then
        previousUpdateCDMAnchoredUnitFrames(...)
    end
    _G.QUI_UpdateAnchoredFrames(...)
end

-- Targeted anchor update: only update frames anchored to a specific target.
-- Accepts a string key (e.g. "minimap") or a frame object (resolved via reverse lookup).
-- Updates both legacy anchored frames and frame anchoring overrides.
_G.QUI_UpdateFramesAnchoredTo = function(targetKeyOrFrame)
    if not targetKeyOrFrame then return end

    -- Resolve frame object to key via reverse lookup
    local targetKey = targetKeyOrFrame
    if type(targetKeyOrFrame) ~= "string" then
        targetKey = nil
        if QUI_Anchoring and QUI_Anchoring.anchorTargets then
            for name, entry in pairs(QUI_Anchoring.anchorTargets) do
                if entry.frame == targetKeyOrFrame then
                    targetKey = name
                    break
                end
            end
        end
        if not targetKey then return end
    end

    -- In combat, only process addon-owned targets. ApplyFrameAnchor keeps its
    -- own safety checks and will defer unsafe frame types automatically.
    -- buffFrame/debuffFrame are included because LayoutIcons defers to a clean
    -- timer context where SetSize/SetPoint work, and dependents need to follow.
    if InCombatLockdown() then
        if targetKey ~= "cdmEssential" and targetKey ~= "cdmUtility"
            and targetKey ~= "buffIcon" and targetKey ~= "buffBar"
            and targetKey ~= "buffFrame" and targetKey ~= "debuffFrame"
        then
            return
        end
    end

    local anchoringDB = QUICore and QUICore.db and QUICore.db.profile
        and QUICore.db.profile.frameAnchoring

    -- Walk the anchor chain: update direct dependents, then their dependents, etc.
    -- Use a BFS queue to avoid infinite loops from circular configs.
    local queue = { targetKey }
    local visited = { [targetKey] = true }

    while #queue > 0 do
        local currentTarget = table.remove(queue, 1)

        -- Reapply frame anchoring overrides whose parent matches this target
        -- and enqueue the updated keys so their dependents are also updated
        if anchoringDB and QUI_Anchoring then
            for key, settings in pairs(anchoringDB) do
                if type(settings) == "table" and settings.parent == currentTarget then
                    QUI_Anchoring:ApplyFrameAnchor(key, settings)
                    -- Enqueue this key so frames anchored to IT also update
                    if not visited[key] then
                        visited[key] = true
                        queue[#queue + 1] = key
                    end
                end
            end
        end
    end
end

if ns.Registry then
    ns.Registry:Register("anchoring", {
        refresh = _G.QUI_ApplyAllFrameAnchors,
        priority = 70,
        group = "anchoring",
        importCategories = { "layout" },
    })
end
