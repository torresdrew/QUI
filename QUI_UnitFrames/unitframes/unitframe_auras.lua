---------------------------------------------------------------------------
-- QUI Unit Frames - Aura System
-- Buff/debuff icon creation, updating, preview mode, and tracking.
-- Extracted from modules/unitframes/unitframes.lua for maintainability.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...

-- Upvalue caching for hot-path performance
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local type = type
local UnitExists = UnitExists

-- QUI_UF is created in unitframes.lua and exported to ns.QUI_UnitFrames.
-- This file loads after unitframes.lua, so the reference is available.
local QUI_UF = ns.QUI_UnitFrames
if not QUI_UF then return end

-- Internal helpers exposed by unitframes.lua
local GetUnitSettings = QUI_UF._GetUnitSettings
local UpdateFrame = QUI_UF._UpdateFrame
---------------------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------------------

-- Classification maps, the structured/classification filter-string builders and
-- the two-zone (buff/debuff) container split all moved to the shared core
-- modules: core/aura_elements.lua compiles an element's filter config into
-- Blizzard filter strings, core/aura_glue.lua builds the group descriptors +
-- owns the combat-regen replay queue, core/aura_slots.lua reconciles tracked
-- slots. This file now drives ONE secure CustomAuraContainer PER active aura
-- element through those modules (see LIVE AURA CONTAINERS below).

-- Boss engage is a global event; one shared listener avoids five frames
-- reprocessing every transient boss-slot pulse.
local bossEngageFrame

-- Map a user anchor corner to the icon/frame attach points (flip vertical only
-- for outside positioning) plus the 1px border-compensation X offset.
local AURA_ANCHOR_FRAMEPOINT = {
    TOPLEFT     = { "BOTTOMLEFT",  "TOPLEFT",     1 },
    TOPRIGHT    = { "BOTTOMRIGHT", "TOPRIGHT",   -1 },
    BOTTOMLEFT  = { "TOPLEFT",     "BOTTOMLEFT",  1 },
    BOTTOMRIGHT = { "TOPRIGHT",    "BOTTOMRIGHT", -1 },
}

local function MapAuraAnchorToFramePoint(anchor)
    local map = AURA_ANCHOR_FRAMEPOINT[anchor]
    if not map then return nil, nil, nil end
    return map[1], map[2], map[3]
end

---------------------------------------------------------------------------
-- LIVE AURA CONTAINERS — one secure CustomAuraContainer PER active element
---------------------------------------------------------------------------
-- Each enabled aura element (the unit's buff strip / debuff strip, plus any
-- tracked icon/square/bar) renders on its OWN secure per-unit
-- CustomAuraContainer, themed by the shared core glue:
--   element -> AuraGlue.ElementProfile + AuraGlue.ElementGroups
--           -> AuraGlue.RunConfigPass (AuraSkin.Configure OOC / Restyle combat),
--   tracked slots via AuraSlots.Sync (AddAuraSlot).
-- The container self-drives UNIT_AURA and reads aura data C-side, so no QUI Lua
-- ever reads a secret aura field on this path.
--
-- Containers pool on the frame by ORDINAL (frame._quiAuraContainers[i]); a
-- changing element list re-purposes them (group retire inside AuraSkin.Configure,
-- slot park via AuraSlots.Park) because engine containers can't be destroyed.
-- CREATION (CreateFrame + AddAuraGroup/AddAuraSlot button pooling) and container
-- anchoring are combat-legal since PTR7 68914 (the earlier 12.1 builds crashed
-- the client; proven in-game 2026-07-24), so the full pass runs live in combat.
-- Still queued via the restriction-aware AuraGlue.QueueRegenWork: work skipped
-- under the 12.1 aura SECRECY restriction (post-birth child styling/anchoring,
-- see aura_slots.lua) — secrecy is a separate mechanism from combat lockdown.

-- Lazily resolve the shared deps (AuraSkin needs the live secure button template
-- so it may bind slightly later than this file's top-level chunk; AuraGlue /
-- AuraSlots / AuraElements live in the QUI core addon, loaded before this file).
local AuraSkin     = (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
local AuraGlue     = ns.AuraGlue
local AuraSlots    = ns.AuraSlots
local AuraElements = ns.AuraElements
local function ResolveAuraDeps()
    AuraSkin     = AuraSkin     or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    AuraGlue     = AuraGlue     or ns.AuraGlue
    AuraSlots    = AuraSlots    or ns.AuraSlots
    AuraElements = AuraElements or ns.AuraElements
    return AuraSkin and AuraGlue and AuraSlots and AuraElements
end

-- Fresh-profile default bucket: one debuff strip + one buff strip, BOTH disabled
-- (the pre-element defaults shipped showBuffs / showDebuffs = false, so a fresh
-- profile renders nothing until the user enables a strip). Geometry + duration /
-- stack sub-tables mirror the flat auras keys in core/defaults.lua so a fresh
-- profile renders identically to the pre-element defaults.
-- MUST stay file-local on the runtime path: E.EnsureSeeded LATCHES elementsSeeded
-- after the first seed, so the default bucket fn has to be available whenever the
-- store is first touched (a conditionally-loaded Options file would let an
-- Options-disabled install latch an empty "*" bucket and lose the shipped strips).
local function DefaultUnitAuraBucket()
    local E = AuraElements or ns.AuraElements
    if not E then return {} end
    local debuff = E.NewFilterStripElement("HARMFUL")
    debuff.id = "debuffs"; debuff.enabled = false
    debuff.anchor = "TOPLEFT"; debuff.growDirection = "RIGHT"
    debuff.iconSize = 22; debuff.maxIcons = 4; debuff.iconsPerRow = 0
    debuff.spacing = 2; debuff.offsetX = 0; debuff.offsetY = 0
    debuff.rightClickCancel = false
    debuff.duration = { show = false, fontSize = 10, anchor = "CENTER", offsetX = 0, offsetY = 0, color = { 1, 1, 1, 1 } }
    debuff.stack    = { show = true,  fontSize = 10, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } }
    local buff = E.NewFilterStripElement("HELPFUL")
    buff.id = "buffs"; buff.enabled = false
    buff.anchor = "BOTTOMLEFT"; buff.growDirection = "RIGHT"
    buff.iconSize = 22; buff.maxIcons = 4; buff.iconsPerRow = 0
    buff.spacing = 2; buff.offsetX = 0; buff.offsetY = 0
    buff.duration = { show = true, fontSize = 12, anchor = "CENTER", offsetX = 0, offsetY = 0, color = { 1, 1, 1, 1 } }
    buff.stack    = { show = true, fontSize = 10, anchor = "BOTTOMRIGHT", offsetX = -1, offsetY = 1, color = { 1, 1, 1, 1 } }
    return { debuff, buff }
end

-- Published for the shared aura element editor mount (Task 9): the Icons tab
-- settings section threads this in as capabilities.defaultBucketFn so a fresh
-- profile viewed in Options seeds identically to this runtime default.
local UnitFrameAuras = ns.QUI_UnitFrameAuras or {}
ns.QUI_UnitFrameAuras = UnitFrameAuras
UnitFrameAuras.DefaultUnitAuraBucket = DefaultUnitAuraBucket

-- The per-unit aura settings table (quiUnitFrames.<unit>.auras), which gained the
-- element-model fields (elements / elementsSeeded). nil when the unit has none.
local function GetFrameAuraSettings(frame)
    if not frame then return nil end
    local unitKey = frame.unitKey or QUI_UF.GetFrameUnit(frame)
    local settings = GetUnitSettings and GetUnitSettings(unitKey)
    return settings and settings.auras or nil
end

-- Resolve the active CONTAINER-RENDERED elements for a frame (enabled strips +
-- tracked icon/square/bar, in bucket order). Unit frames never use per-spec
-- buckets, so the spec key is always nil. healthTint tracked elements are skipped
-- defensively (unit frames have no health-tint feeder; capabilities gate them at
-- the editor). Returns a SHARED module scratch — do not retain across a re-resolve.
local _activeElems = {}
local function ResolveContainerElements(frame)
    for i = #_activeElems, 1, -1 do _activeElems[i] = nil end
    local auras = GetFrameAuraSettings(frame)
    if not auras then return _activeElems end
    AuraElements = AuraElements or ns.AuraElements
    if not AuraElements then return _activeElems end
    AuraElements.EnsureSeeded(auras, DefaultUnitAuraBucket)
    local elements = AuraElements.ActiveElementsForSpec(auras, nil)
    for i = 1, #elements do
        local e = elements[i]
        if e.mode == "filterStrip"
            or (e.mode == "tracked" and e.displayType ~= "healthTint" and e.displayType ~= "border") then
            _activeElems[#_activeElems + 1] = e
        end
    end
    return _activeElems
end

-- Build the AuraSkin layout profile for one element WITH the unit-frame corner
-- flip folded in: MapAuraAnchorToFramePoint gives the flipped (icon-side) attach
-- corner, and a strip flipped ABOVE the frame edge (attach corner contains
-- "BOTTOM") must wrap upward so extra rows grow away from the frame. Built ONCE
-- here so the anchor pass and the configure pass share the exact same
-- profile+overrides (they can never drift).
local function ElementProfileFor(element)
    local attachPoint = (MapAuraAnchorToFramePoint(element.anchor or "TOPLEFT"))
    return AuraGlue.ElementProfile(element, {
        attachPoint = attachPoint,
        wrap = ((attachPoint or ""):find("BOTTOM", 1, true) and "UP" or "DOWN"),
    })
end

-- Anchor a container OOC relative to its unit frame. AuraSkin.LayoutAnchor(profile)
-- returns the flow-origin corner (grow + the flipped wrap); pinning THAT corner to
-- the frame's matching NON-flipped corner (framePoint) makes the auto-sized
-- container hang off the frame edge exactly where the pre-element 1x1 grid did,
-- with multi-row growth extending AWAY from the frame. borderOffsetX is the same
-- 1px border compensation the preview applies per icon. The container is
-- forbidden -> SetPoint is NEVER called in combat (callers gate on InCombatLockdown).
local function AnchorElementContainer(container, frame, element)
    local _, framePoint, borderOffsetX = MapAuraAnchorToFramePoint(element.anchor or "TOPLEFT")
    framePoint = framePoint or "TOPLEFT"
    local profile = ElementProfileFor(element)
    container:ClearAllPoints()
    container:SetPoint(AuraSkin.LayoutAnchor(profile), frame, framePoint,
        (borderOffsetX or 0) + (element.offsetX or 0), (element.offsetY or 0))
end

-- One container per active element, pooled by ORDINAL on the frame. allowCreate=
-- false (combat) NEVER creates containers/slots and never SetPoints; it only
-- mutates pre-created containers (SetUnit / pcall-guarded group reconcile inside
-- AuraGlue.RunConfigPass / enable). Any forbidden work skipped in combat sets
-- `incomplete`, which queues a full OOC replay via AuraGlue.QueueRegenWork.
-- Layout-mode preview owns a polarity's display while active: a previewed polarity
-- keeps its element containers disabled + hidden so the fake preview icons render
-- alone (until Task 10 rewires preview to feed the containers directly).
local function ApplyElementPass(frame, allowCreate)
    if not frame or not QUI_UF.GetFrameUnit(frame) then return end
    if not ResolveAuraDeps() then return end
    local AuraSurface = ns.AuraSurface
    if not AuraSurface then return end

    local unitKey = frame.unitKey or QUI_UF.GetFrameUnit(frame)
    local elems = ResolveContainerElements(frame)

    -- Boss frames preview as a GROUP — ShowAuraPreview("boss", ...) sets the
    -- "boss_*" key for all five — so map boss1..boss5 to "boss" here.
    local previewKey = unitKey
    if type(previewKey) == "string" and previewKey:match("^boss%d+$") then previewKey = "boss" end
    local previewMode = QUI_UF.auraPreviewMode
    local buffPreviewActive = previewMode and previewMode[previewKey .. "_buff"]
    local debuffPreviewActive = previewMode and previewMode[previewKey .. "_debuff"]

    AuraSurface.ApplyElementPass(frame, elems, {
        unit = QUI_UF.GetFrameUnit(frame),
        allowCreate = allowCreate == true,
        cancelEligible = (unitKey == "player"),
        profileFor = ElementProfileFor,
        anchorContainer = function(container, host, element)
            AnchorElementContainer(container, host, element)
        end,
        skip = function(element)
            local isDebuff = (element.auraType == "HARMFUL")
            return (isDebuff and debuffPreviewActive)
                or ((not isDebuff) and buffPreviewActive) or false
        end,
        onIncomplete = function(host)
            AuraGlue.QueueRegenWork(host, function(f) ApplyElementPass(f, true) end)
        end,
    })
end

-- Full pass. Public export name preserved (the combat-mutable test + any
-- unitframes.lua caller depend on it); also what the regen replay closure runs.
-- Creation/registration/anchoring are combat-legal since PTR7 68914, so the
-- pass always runs with allowCreate — skipped work (secrecy-gated child
-- styling) self-reports via `incomplete` and queues its own replay.
local function ApplyContainerConfig(frame)
    ApplyElementPass(frame, true)
end
QUI_UF.ApplyContainerConfig = ApplyContainerConfig

-- Public entry (callers in unitframes.lua depend on the name). The live
-- containers self-drive UNIT_AURA, so this is config-only, not a per-frame render
-- loop. The full pass (creation + reconcile + anchoring) is combat-legal since
-- PTR7 68914; in combat it keeps a SafeCall belt — a surprise restriction must
-- not error out of the event handler — and a failed pass queues the
-- restriction-aware replay (the pass itself queues its own partial gaps).
local function UpdateAuras(frame)
    if not frame or not QUI_UF.GetFrameUnit(frame) then return end
    if InCombatLockdown() then
        local ok = ns.SafeCall("best-effort-style", ApplyElementPass, frame, true)
        if not ok then
            AuraGlue = AuraGlue or ns.AuraGlue
            if AuraGlue then
                AuraGlue.QueueRegenWork(frame, function(f) ApplyElementPass(f, true) end)
            end
        end
        return
    end
    ApplyElementPass(frame, true)
end
QUI_UF.UpdateAuras = UpdateAuras

local function RefreshAllAuraContainers()
    local frames = QUI_UF and QUI_UF.frames
    if not frames then return end
    for _, frame in pairs(frames) do
        UpdateAuras(frame)
    end
end
ns.QUI_RefreshUnitFrameAuras = RefreshAllAuraContainers

local function SuppressContainerForPreview(frame)
    if not frame then return end
    UpdateAuras(frame)
end

-- Which polarities are in aura-preview for this frame. Boss frames preview as a
-- GROUP (ShowAuraPreview("boss",...) sets the shared "boss_*" key), so map
-- boss1..boss5 to "boss" to read the same flags ApplyElementPass consults.
local function PreviewPolarityFlags(unitKey)
    local key = unitKey
    if type(key) == "string" and key:match("^boss%d+$") then key = "boss" end
    local pm = QUI_UF.auraPreviewMode
    if not pm then return false, false end
    return pm[key .. "_buff"] == true, pm[key .. "_debuff"] == true
end

-- Preview resolve: the unit-frame corner flip, folded EXACTLY as the live path
-- folds it — the SAME ElementProfileFor (attachPoint + flipped wrap overrides)
-- the configure pass uses, pinned to the frame's NON-flipped corner with the
-- same 1px border compensation AnchorElementContainer applies. One source of
-- truth: preview reuses the live helpers, no duplicated flip logic.
local function PreviewResolve(element)
    local _, framePoint, borderOffsetX = MapAuraAnchorToFramePoint(element.anchor or "TOPLEFT")
    return ElementProfileFor(element), framePoint or "TOPLEFT",
        (borderOffsetX or 0) + (element.offsetX or 0), (element.offsetY or 0)
end

-- Shared aura-preview refresh. The caller has already flipped the polarity's
-- auraPreviewMode flag, so this reads them fresh and is order-independent when
-- buff + debuff preview overlap (one pooled placeholder set per frame). Step 1
-- re-runs the live pass, which disables + hides the previewed polarity's live
-- containers (SetEnabled/Hide is combat-legal). Step 2 draws placeholder
-- previews through the shared ns.AuraPreview for whichever polarity/polarities
-- are active, using the SAME layout math the live containers use
-- (ElementProfileFor over AuraGlue.ElementProfile, threaded via opts.resolve so
-- the corner flip lands in the preview too) — reading each element's own
-- duration{}/stack{}, never the pruned per-unit scalar keys the old fake-icon
-- renderer read.
local function RefreshAuraPreviewForFrame(frame, unitKey)
    if not frame then return end
    SuppressContainerForPreview(frame)
    local Preview = ns.AuraPreview
    if not Preview then return end
    local buffActive, debuffActive = PreviewPolarityFlags(unitKey)
    if not (buffActive or debuffActive) then
        Preview.Hide(frame)
        return
    end
    -- ResolveContainerElements returns a shared scratch; take it AFTER the live
    -- pass above (which also touches it) and hand it straight to Preview.Show.
    local elems = ResolveContainerElements(frame)
    Preview.Show(frame, elems, {
        resolve = PreviewResolve,
        only = function(e)
            if e.auraType == "HARMFUL" then return debuffActive end
            return buffActive
        end,
    })
end

-- (The legacy live-render body — the manual per-index aura polling loop and its
--  SafeSetCooldown / DisplayStackCount closures — was removed when the live
--  display moved to the secure CustomAuraContainer above, which reads aura data
--  C-side and never hands a secret value to QUI Lua.)

local function RefreshBossFrameForEngage(frame)
    if not frame or not QUI_UF.GetFrameUnit(frame) then return end

    if UnitExists(QUI_UF.GetFrameUnit(frame)) then
        UpdateFrame(frame)
    end
    UpdateAuras(frame)
end

local function EnsureBossEngageFrame()
    if bossEngageFrame then return end

    bossEngageFrame = CreateFrame("Frame")
    bossEngageFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    bossEngageFrame:SetScript("OnEvent", function()
        local frames = QUI_UF.frames
        if not frames then return end

        for i = 1, 5 do
            RefreshBossFrameForEngage(frames["boss" .. i])
        end
    end)
end

---------------------------------------------------------------------------
-- AURA TRACKING SETUP
---------------------------------------------------------------------------

local function SetupAuraTracking(frame)
    if not frame then return end

    local unit = QUI_UF.GetFrameUnit(frame)

    -- Live aura display is now a secure CustomAuraContainer per element — it
    -- self-drives UNIT_AURA internally (see AuraContainerPrivateMixin), so QUI
    -- no longer registers UNIT_AURA on the unit frame for aura rendering.  We
    -- still listen for token-change events so the container re-points at the
    -- new underlying unit when the token's subject changes (target/focus swap,
    -- pet summon, ToT change) — the container's token string is unchanged in
    -- those cases, so we force a re-parse via ApplyContainerConfig (which
    -- clears + re-adds the filters → Blizzard UpdateAllAuras).
    if unit == "target" then
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    elseif unit == "focus" then
        frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
    elseif unit == "pet" then
        frame:RegisterEvent("UNIT_PET")
    elseif unit == "targettarget" then
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")  -- ToT changes when target changes
        frame:RegisterEvent("UNIT_TARGET")            -- ToT changes when target's target changes
    elseif unit:match("^boss%d+$") then
        EnsureBossEngageFrame()
    end
    -- player: token never changes; container handles UNIT_AURA on its own.

    -- Hook into existing OnEvent or create new one
    local oldOnEvent = frame:GetScript("OnEvent")
    frame:SetScript("OnEvent", function(self, event, arg1, ...)
        if oldOnEvent then
            oldOnEvent(self, event, arg1, ...)
        end

        local frameUnit = QUI_UF.GetFrameUnit(self)
        if event == "PLAYER_TARGET_CHANGED" then
            if frameUnit == "target" or frameUnit == "targettarget" then
                UpdateAuras(self)
            end
        elseif event == "PLAYER_FOCUS_CHANGED" and frameUnit == "focus" then
            UpdateAuras(self)
        elseif event == "UNIT_PET" and frameUnit == "pet" then
            UpdateAuras(self)
        elseif event == "UNIT_TARGET" and frameUnit == "targettarget" then
            UpdateAuras(self)
        end
    end)

    -- Create + configure the containers once at load.  Container creation /
    -- anchoring touch a forbidden object, so do it OOC; UpdateAuras defers to
    -- PLAYER_REGEN_ENABLED if we somehow land here in combat.
    UpdateAuras(frame)

    -- Re-apply shortly after load to catch the case where the unit frame's
    -- final size/anchor settle a frame later (mirrors the legacy double-tap).
    C_Timer.After(0.2, function()
        UpdateAuras(frame)
    end)
end

-- Expose for unitframes.lua callers
QUI_UF.SetupAuraTracking = SetupAuraTracking

---------------------------------------------------------------------------
-- AURA PREVIEW MODE
---------------------------------------------------------------------------

function QUI_UF:ShowAuraPreview(unitKey, auraType)
    -- Handle boss frames specially - show aura preview on all 5
    if unitKey == "boss" then
        local previewKey = "boss_" .. auraType
        self.auraPreviewMode[previewKey] = true
        -- Only show if boss frame preview is active
        for i = 1, 5 do
            local bossKey = "boss" .. i
            local frame = self.frames[bossKey]
            if frame and self.previewMode[bossKey] then
                self:ShowAuraPreviewForFrame(frame, "boss", auraType)
            end
        end
        return
    end

    local frame = self.frames[unitKey]
    if not frame then return end

    local previewKey = unitKey .. "_" .. auraType
    self.auraPreviewMode[previewKey] = true

    self:ShowAuraPreviewForFrame(frame, unitKey, auraType)
end

-- Placeholder aura preview for one polarity. Delegates to the shared refresh so
-- overlapping buff/debuff previews (independent auraPreviewMode flags) resolve
-- from the pooled placeholder set on the frame. auraType is unused: the caller
-- has already set the polarity flag the refresh reads.
function QUI_UF:ShowAuraPreviewForFrame(frame, unitKey, _auraType)
    RefreshAuraPreviewForFrame(frame, unitKey)
end

function QUI_UF:HideAuraPreview(unitKey, auraType)
    -- Handle boss frames specially - hide aura preview on all 5
    if unitKey == "boss" then
        local previewKey = "boss_" .. auraType
        self.auraPreviewMode[previewKey] = false
        for i = 1, 5 do
            local bossKey = "boss" .. i
            local frame = self.frames[bossKey]
            if frame then
                self:HideAuraPreviewForFrame(frame, bossKey, auraType)
            end
        end
        return
    end

    local frame = self.frames[unitKey]
    if not frame then return end

    local previewKey = unitKey .. "_" .. auraType
    self.auraPreviewMode[previewKey] = false

    self:HideAuraPreviewForFrame(frame, unitKey, auraType)
end

-- Exit aura preview for one polarity. Delegates to the shared refresh: the
-- caller has already cleared this polarity's flag, so the refresh re-enables the
-- live container and Preview.Show/Hide reflects any still-active polarity.
function QUI_UF:HideAuraPreviewForFrame(frame, unitKey, _auraType)
    RefreshAuraPreviewForFrame(frame, unitKey)
end
