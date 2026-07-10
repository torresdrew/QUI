--[[
    QUI Nameplates — lifecycle driver.

    Owns: events, the plate pool (+ login prewarm), Blizzard art suppression,
    the unit registry, two-phase SetUnit, token-swap self-heal, and recycle
    hygiene. Loads LAST in the suite TOC — every satellite module table
    exists by now.

    Perf contract (plans/009-nameplates.md):
    * pool + prewarm — a fresh pull never stacks CreateFrame spikes
    * appearance generation — pooled respawns skip all static styling
    * two-phase SetUnit — health paints synchronously, the rest one frame later
    * module-level handlers — zero per-event closure allocation on hot paths
    * O(1) registry — plates[unit], never a scan
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local Helpers = ns.Helpers
local NPHealth = NP.Health
local NPColors = NP.Colors
local NPCVars = NP.CVars
local NPExtras = NP.Extras

local type = type
local pcall = pcall
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local UnitCanAttack = UnitCanAttack
local hooksecurefunc = hooksecurefunc

local NPDriver = {}
NP.Driver = NPDriver

local plates = NP.plates

---------------------------------------------------------------------------
-- HIDDEN PARENT + SUPPRESSION STATE
---------------------------------------------------------------------------
local hiddenParent = CreateFrame("Frame", nil, UIParent)
hiddenParent:Hide()

-- Blizzard UnitFrame → suppression record. Weak keys; NO custom properties
-- are ever written on Blizzard frames (taint) — external maps only.
-- record = { active = bool, alphaHooked = bool, children = { [frame] = originalParent } }
local suppression = setmetatable({}, { __mode = "k" })
local alphaLock = setmetatable({}, { __mode = "k" })

-- UnitFrame children reparented away while suppressed (12.0.7 tree,
-- Blizzard_NamePlates.xml; a structure test tracks these against the
-- vendored snapshot for early warning at patch bumps).
local SUPPRESS_CHILD_KEYS = {
    "HealthBarsContainer",
    "castBar",
    "RaidTargetFrame",
    "ClassificationFrame",
    "AurasFrame",
    "PlayerLevelDiffFrame",
    "SoftTargetFrame",
}

local function PinAlphaZero(unitFrame)
    if alphaLock[unitFrame] then return end
    local record = suppression[unitFrame]
    if not (record and record.active) then return end
    alphaLock[unitFrame] = true
    pcall(unitFrame.SetAlpha, unitFrame, 0)
    alphaLock[unitFrame] = nil
end

local function SuppressBlizzardArt(base)
    local unitFrame = base and base.UnitFrame
    if not unitFrame then return end

    local record = suppression[unitFrame]
    if not record then
        record = { children = {} }
        suppression[unitFrame] = record
    end
    if record.active then return end
    record.active = true

    for i = 1, #SUPPRESS_CHILD_KEYS do
        local child = unitFrame[SUPPRESS_CHILD_KEYS[i]]
        if child and child.SetParent then
            local okParent, parent = pcall(child.GetParent, child)
            if okParent and parent and parent ~= hiddenParent then
                record.children[child] = parent
                pcall(child.SetParent, child, hiddenParent)
            end
        end
    end

    -- Blizzard castbar keeps ticking events while parked — silence it.
    local castBar = unitFrame.castBar
    if castBar and castBar.UnregisterAllEvents then
        pcall(castBar.UnregisterAllEvents, castBar)
    end

    -- Alpha-0 pin with re-entrancy lock; the hook is installed once per
    -- UnitFrame and self-gates on record.active (recycled friendly plates
    -- un-suppress without fighting the hook).
    if not record.alphaHooked then
        record.alphaHooked = true
        hooksecurefunc(unitFrame, "SetAlpha", PinAlphaZero)
    end
    pcall(unitFrame.SetAlpha, unitFrame, 0)
end

local function RestoreBlizzardArt(base)
    local unitFrame = base and base.UnitFrame
    if not unitFrame then return end
    local record = suppression[unitFrame]
    if not (record and record.active) then return end
    record.active = false

    for child, originalParent in pairs(record.children) do
        pcall(child.SetParent, child, originalParent)
        record.children[child] = nil
    end

    local castBar = unitFrame.castBar
    if castBar and castBar.OnLoad == nil and castBar.RegisterEvent then
        -- Event re-registration is owned by Blizzard's SetUnit on the next
        -- acquire; nothing to redo here.
    end
    pcall(unitFrame.SetAlpha, unitFrame, 1)
end
NPDriver.RestoreBlizzardArt = RestoreBlizzardArt

---------------------------------------------------------------------------
-- UNIT STATE (plain, type-gated fields consumed by the color resolver)
---------------------------------------------------------------------------
-- All reads gate through NP.Plain: type() alone cannot detect secrets (a
-- secret boolean reports type "boolean" and errors on its first truthiness
-- test). Secret/unavailable readings leave the plain fallback.
local function ComputeUnitState(plate)
    local unit = plate.unit
    if not unit then return end
    local ok, v

    ok, v = pcall(UnitIsPlayer, unit)
    plate.npIsPlayer = (ok and NP.Plain(v, "boolean")) or false

    ok, v = pcall(UnitReaction, unit, "player")
    local reaction = ok and NP.Plain(v, "number") or nil
    if reaction then
        if reaction >= 5 then
            plate.npReaction = "friendly"
        elseif reaction == 4 then
            plate.npReaction = "neutral"
        else
            plate.npReaction = "hostile"
        end
    else
        plate.npReaction = "hostile"
    end

    local okClass, _, classToken = pcall(UnitClass, unit)
    plate.npClassToken = okClass and NP.Plain(classToken, "string") or nil

    ok, v = pcall(UnitIsTapDenied, unit)
    plate.npTapDenied = (ok and NP.Plain(v, "boolean")) or false

    ok, v = pcall(UnitAffectingCombat, unit)
    -- nil (secret/unavailable) deliberately disables OOC darkening.
    if ok then
        plate.npInCombat = NP.Plain(v, "boolean")
    else
        plate.npInCombat = nil
    end
end

-- Deferred (frame 2) state: quest scan + target/focus flags.
local function ComputeDeferredState(plate)
    local unit = plate.unit
    if not unit then return end

    plate.npIsQuest = NPExtras.IsQuestUnit(unit) == true

    local ok, v = pcall(UnitIsUnit, unit, "target")
    plate.npIsTarget = (ok and NP.Plain(v, "boolean")) or false
    ok, v = pcall(UnitIsUnit, unit, "focus")
    plate.npIsFocus = (ok and NP.Plain(v, "boolean")) or false
end

---------------------------------------------------------------------------
-- PER-PLATE EVENTS (module-level handler; no closures)
---------------------------------------------------------------------------
local PLATE_UNIT_EVENTS = {
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_ABSORB_AMOUNT_CHANGED",
    "UNIT_NAME_UPDATE",
    "UNIT_THREAT_LIST_UPDATE",
    "UNIT_FLAGS", -- attackability demotion watcher (duel ends, MC drops)
}

local ClearUnit, ReleasePlate -- defined in the POOL section below

local function RebindPlate(plate, newUnit)
    local oldUnit = plate.unit
    if oldUnit and plates[oldUnit] == plate then
        plates[oldUnit] = nil
    end
    plate.unit = newUnit
    plates[newUnit] = plate
    for i = 1, #PLATE_UNIT_EVENTS do
        plate:RegisterUnitEvent(PLATE_UNIT_EVENTS[i], newUnit)
    end
    NP.Castbar.StopCast(plate)
    ComputeUnitState(plate)
    ComputeDeferredState(plate)
    NPExtras.UpdateThreat(plate)
    NPHealth.UpdateHealth(plate)
    NPHealth.UpdateAbsorbs(plate)
    NPHealth.UpdateName(plate)
    NPHealth.UpdateColor(plate, NP.GetSettings(), NPExtras.GetContext())
    NP.Auras.FullRescan(plate)
end

local function PlateOnEvent(plate, event, unit)
    -- Token-swap self-heal: Blizzard recycles base frames; if the base now
    -- carries a different unit token than we bound, rebind in place and tear
    -- down cast state (the scar behind this: stale plates after loading
    -- screens/mass despawns).
    if event == "UNIT_HEALTH" then
        local base = plate.npBase
        local token = NP.Plain(base and (base.unitToken or base.namePlateUnitToken), "string")
        if token and token ~= plate.unit then
            RebindPlate(plate, token)
            return
        end
        NPHealth.UpdateHealth(plate)
        if NPExtras.UpdateExecute then
            NPExtras.UpdateExecute(plate)
        end
        return
    end
    if event == "UNIT_MAXHEALTH" then
        NPHealth.UpdateHealth(plate)
        NPHealth.UpdateAbsorbs(plate)
        return
    end
    if event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        NPHealth.UpdateAbsorbs(plate)
        return
    end
    if event == "UNIT_NAME_UPDATE" then
        ComputeUnitState(plate)
        NPHealth.UpdateName(plate)
        NPHealth.UpdateColor(plate, NP.GetSettings(), NPExtras.GetContext())
        return
    end
    if event == "UNIT_THREAT_LIST_UPDATE" then
        NPExtras.UpdateThreat(plate)
        -- Combat state flips with threat activity; refresh the plain flag.
        local ok, v = pcall(UnitAffectingCombat, unit)
        plate.npInCombat = ok and NP.Plain(v, "boolean") or nil
        NPHealth.UpdateColor(plate, NP.GetSettings(), NPExtras.GetContext())
        return
    end
    if event == "UNIT_FLAGS" then
        -- Demotion mirror: an enemy plate whose unit became verifiably
        -- unattackable (duel over, charm ended) hands the unit to the
        -- friendly module, keeping the base suppressed across the swap.
        local ok, attackable = pcall(UnitCanAttack, "player", unit)
        if ok and NP.Plain(attackable, "boolean") == false then
            local base = plate.npBase
            ReleasePlate(plate)
            if base then
                NP.Friendly.HandleAdded(base, unit)
            end
        end
        return
    end
end

---------------------------------------------------------------------------
-- POOL
---------------------------------------------------------------------------
local pool = {}
local poolSize = 0

-- Decouple the plate's scale from the Blizzard base: the C engine scales
-- bases per-distance/spawn regardless of the min/max-scale CVar pin (the
-- 12.x driver no longer reads those CVars), and pixel-perfect sizing
-- compensates for effective scale AT STYLE TIME — any later base-scale
-- drift rendered the art at the wrong size (fresh plates spawning small).
-- With SetIgnoreParentScale the plate's effective scale is its own, pinned
-- to UIParent's, so sizes are deterministic and base scaling is inert.
local function PinPlateScale(plate)
    if not plate.SetIgnoreParentScale then return end
    local ok, es = pcall(UIParent.GetEffectiveScale, UIParent)
    es = ok and NP.Plain(es, "number") or nil
    if es and es > 0 then
        plate:SetScale(es)
    end
end
NPDriver.PinPlateScale = PinPlateScale

local function BuildPlate()
    local plate = CreateFrame("Frame", nil, hiddenParent)
    plate:Hide()
    plate:SetSize(1, 1)
    if plate.SetIgnoreParentScale then
        plate:SetIgnoreParentScale(true)
    end
    PinPlateScale(plate)
    plate:SetScript("OnEvent", PlateOnEvent)

    NPHealth.Build(plate)
    NP.Castbar.Build(plate)
    NP.Auras.Build(plate)
    if NPExtras.BuildPlate then
        NPExtras.BuildPlate(plate)
    end

    -- Stacking bounds: SetStackingBoundsFrame reads RENDERED region bounds,
    -- so the child carries an alpha-0 full-size texture (without it the
    -- bounds contribute nothing).
    local stackBounds = CreateFrame("Frame", nil, plate)
    local boundsTex = stackBounds:CreateTexture(nil, "BACKGROUND")
    boundsTex:SetAllPoints(stackBounds)
    boundsTex:SetColorTexture(1, 1, 1, 1)
    boundsTex:SetAlpha(0)
    plate.npStackBounds = stackBounds

    return plate
end

local function AcquirePlate()
    local plate
    if poolSize > 0 then
        plate = pool[poolSize]
        pool[poolSize] = nil
        poolSize = poolSize - 1
    else
        plate = BuildPlate()
    end
    return plate
end

-- Exhaustive recycle hygiene: caches, latches, cast state, deferred queues.
function ClearUnit(plate)
    local unit = plate.unit
    plate:UnregisterAllEvents()
    NP.Castbar.StopCast(plate)
    NP.Auras.Clear(plate)
    if NPExtras.ClearPlate then
        NPExtras.ClearPlate(plate)
    end

    local base = plate.npBase
    if base and base.SetStackingBoundsFrame then
        pcall(base.SetStackingBoundsFrame, base, nil)
    end

    if unit and plates[unit] == plate then
        plates[unit] = nil
    end
    if base then
        NP.platesByBase[base] = nil
    end

    plate.unit = nil
    plate.npBase = nil
    plate.npDeferredPending = nil
    plate.npLastMaxHP = nil
    plate.npLastAbsorbMax = nil
    plate.npAbsorbHidden = nil
    plate.npLastR, plate.npLastG, plate.npLastB = nil, nil, nil
    plate.npReaction = nil
    plate.npIsPlayer = nil
    plate.npClassToken = nil
    plate.npTapDenied = nil
    plate.npInCombat = nil
    plate.npIsQuest = nil
    plate.npThreat = nil
    plate.npIsTarget = nil
    plate.npIsFocus = nil

    plate:Hide()
    plate:ClearAllPoints()
    plate:SetParent(hiddenParent)
end

function ReleasePlate(plate)
    ClearUnit(plate)
    poolSize = poolSize + 1
    pool[poolSize] = plate
end

---------------------------------------------------------------------------
-- TWO-PHASE SETUNIT
---------------------------------------------------------------------------
-- Deferred second phase — one shared dispatcher walks a pending set so each
-- SetUnit allocates nothing.
local deferredPlates = {}
local deferFrame = CreateFrame("Frame")
deferFrame:Hide()
deferFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    for plate in pairs(deferredPlates) do
        deferredPlates[plate] = nil
        if plate.npDeferredPending and plate.unit then
            plate.npDeferredPending = nil
            ComputeDeferredState(plate)
            NPExtras.UpdateThreat(plate)
            NPHealth.UpdateName(plate)
            NPHealth.UpdateAbsorbs(plate)
            NPHealth.UpdateColor(plate, NP.GetSettings(), NPExtras.GetContext())
            NP.Auras.FullRescan(plate)
            if NPExtras.OnPlateShown then
                NPExtras.OnPlateShown(plate)
            end
            -- A plate acquired mid-cast missed its START event — probe once.
            if NP.Castbar.ProbeCast then
                NP.Castbar.ProbeCast(plate)
            end
        end
    end
end)

-- Full static styling for one plate (health/castbar/auras/extras appearance
-- + stacking bounds). Shared by the SetUnit generation gate and
-- RestyleActivePlates so a generation bump re-runs ALL static work.
local function ApplyPlateAppearance(plate, settings)
    -- Re-pin first: sizes below convert through the plate's effective scale.
    NPDriver.PinPlateScale(plate)
    NPHealth.ApplyAppearance(plate, settings)
    NP.Castbar.ApplyAppearance(plate, settings)
    NP.Auras.ApplyAppearance(plate, settings)
    if NPExtras.ApplyAppearance then
        NPExtras.ApplyAppearance(plate, settings)
    end

    -- Stacking bounds sized to name gap + bar + castbar × user spacing.
    local health = settings.health or {}
    local cast = settings.castbar or {}
    local nameS = settings.name or {}
    local spacing = (settings.cvars and settings.cvars.stackingSpacing) or 1.0
    local QUICore = ns.Addon
    local w = (health.width or 210)
    local h = ((health.height or 24) + (cast.height or 17) + ((nameS.size or 11) + math.abs(nameS.offsetY or 4)))
    plate.npStackBounds:ClearAllPoints()
    plate.npStackBounds:SetPoint("CENTER", plate, "CENTER", 0, 0)
    QUICore:SetPixelPerfectSize(plate.npStackBounds, w * spacing, h * spacing)
end

local function SetUnit(plate, unit, base)
    plate.unit = unit
    plate.npBase = base
    plates[unit] = plate
    NP.platesByBase[base] = plate

    -- Dimensionless child of the Blizzard base: single CENTER→CENTER anchor
    -- (whole-plate movement, no edge shimmer).
    plate:SetParent(base)
    plate:ClearAllPoints()
    plate:SetPoint("CENTER", base, "CENTER", 0, 0)
    plate:SetFrameLevel((base:GetFrameLevel() or 0) + 1)

    local settings = NP.GetSettings()

    -- Appearance generation: static styling only when stale.
    if plate.npAppearanceGen ~= NP.appearanceGen then
        plate.npAppearanceGen = NP.appearanceGen
        ApplyPlateAppearance(plate, settings)
    end

    for i = 1, #PLATE_UNIT_EVENTS do
        plate:RegisterUnitEvent(PLATE_UNIT_EVENTS[i], unit)
    end

    if base.SetStackingBoundsFrame then
        pcall(base.SetStackingBoundsFrame, base, plate.npStackBounds)
    end

    -- Phase 1 (synchronous): the health bar must display immediately.
    ComputeUnitState(plate)
    NPHealth.UpdateHealth(plate)
    NPHealth.UpdateColor(plate, settings, NPExtras.GetContext())
    plate:Show()

    -- Phase 2 (next frame): name/cast/auras/markers/quest.
    plate.npDeferredPending = true
    deferredPlates[plate] = true
    deferFrame:Show()
end

---------------------------------------------------------------------------
-- ADDED / REMOVED ROUTING
---------------------------------------------------------------------------
local function GetBase(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, base = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if ok then return base end
    return nil
end

-- Build (or rebuild) the enemy plate for a unit. Also the friendly module's
-- promotion entry point (duel starts): re-asserts suppression first so the
-- Blizzard UF stays hidden across the ownership swap — no flash.
local function BuildEnemyPlate(unit, base)
    base = base or GetBase(unit)
    if not base then return end
    SuppressBlizzardArt(base)
    local existing = plates[unit]
    if existing then
        ReleasePlate(existing)
    end
    local plate = AcquirePlate()
    SetUnit(plate, unit, base)
    return plate
end
NPDriver.BuildEnemyPlate = BuildEnemyPlate

local function OnNamePlateAdded(unit)
    if not NP.IsEnabled() then return end
    -- Personal resource display is Blizzard's — never touch the player plate.
    local okSelf, isSelf = pcall(UnitIsUnit, unit, "player")
    if okSelf and NP.Plain(isSelf, "boolean") == true then return end

    local base = GetBase(unit)
    if not base then return end

    -- Attackability routing. First-frame UnitCanAttack lies, which is why
    -- suppression already happened unconditionally in the driver hook — a
    -- wrong "friendly" verdict here only delays the enemy plate by a frame
    -- (the friendly handoff re-checks before restoring Blizzard art).
    -- A SECRET verdict routes enemy (fail toward the suppressed path).
    local okAtk, attackable = pcall(UnitCanAttack, "player", unit)
    if okAtk and NP.Plain(attackable, "boolean") == false then
        NP.Friendly.HandleAdded(base, unit)
        return
    end

    BuildEnemyPlate(unit, base)
end
NPDriver.RouteUnit = OnNamePlateAdded

local function OnNamePlateRemoved(unit)
    NP.Friendly.HandleRemoved(unit)
    local plate = plates[unit]
    if not plate then return end
    local base = plate.npBase
    ReleasePlate(plate)
    -- Restore symmetrically so a future non-QUI consumer of this base frame
    -- (friendly mode, disabled state) gets intact Blizzard art.
    if base then
        RestoreBlizzardArt(base)
    end
end

---------------------------------------------------------------------------
-- BLIZZARD DRIVER HOOKS
---------------------------------------------------------------------------
local hooksInstalled = false
local function InstallHooks()
    if hooksInstalled then return end
    local blizzDriver = _G.NamePlateDriverFrame
    if not blizzDriver then return end
    hooksInstalled = true

    -- Suppress-before-visible: this post-hook runs inside Blizzard's ADDED
    -- dispatch, right after AcquireUnitFrame/SetUnit and before the frame
    -- renders. Suppression is UNCONDITIONAL (first-frame UnitCanAttack lies);
    -- friendly routing restores the art when it settles.
    hooksecurefunc(blizzDriver, "OnNamePlateAdded", function(_, unit)
        if not NP.IsEnabled() then return end
        local okSelf, isSelf = pcall(UnitIsUnit, unit, "player")
        if okSelf and NP.Plain(isSelf, "boolean") == true then return end
        local base = GetBase(unit)
        if base then
            SuppressBlizzardArt(base)
        end
    end)

    -- Class resource bars: only ever attached to the player plate, which QUI
    -- leaves alone — no suppression needed, but the post-hook re-asserts our
    -- sizing after Blizzard rewrites it.
    hooksecurefunc(blizzDriver, "UpdateNamePlateOptions", function()
        if not NP.IsEnabled() then return end
        NPCVars.ApplyPlateSize()
    end)
end

---------------------------------------------------------------------------
-- PREWARM (login; ~20 frames staggered, then released)
---------------------------------------------------------------------------
local prewarmDone = false
local function Prewarm()
    if prewarmDone or not NP.IsEnabled() then return end
    prewarmDone = true
    local created = 0
    local ticker
    ticker = C_Timer.NewTicker(0.1, function()
        created = created + 1
        ReleasePlate(BuildPlate())
        if created >= 20 and ticker then
            ticker:Cancel()
        end
    end, 20)
end

---------------------------------------------------------------------------
-- SETTINGS REFRESH / TEARDOWN
---------------------------------------------------------------------------
local function RestyleActivePlates()
    local settings = NP.GetSettings()
    local context = NPExtras.GetContext()
    for unit, plate in pairs(plates) do
        if plate.npAppearanceGen ~= NP.appearanceGen then
            plate.npAppearanceGen = NP.appearanceGen
            ApplyPlateAppearance(plate, settings)
        end
        plate.npLastR = nil -- force color rewrite through the latch
        NPHealth.UpdateColor(plate, settings, context)
        NPHealth.UpdateHealth(plate)
    end
end

local function TeardownAll()
    for unit, plate in pairs(plates) do
        local base = plate.npBase
        ReleasePlate(plate)
        if base then
            RestoreBlizzardArt(base)
        end
    end
end

function NPDriver.Refresh()
    if NP.IsEnabled() then
        NP.BumpAppearanceGeneration()
        NPCVars.ApplyAll()
        RestyleActivePlates()
        Prewarm()
    else
        TeardownAll()
    end
end

-- Cross-suite refresh trigger (ns export per the global-assignment ratchet;
-- the bootstrap proxy makes it visible to every suite including QUI_Options).
ns.QUI_RefreshNameplates = NPDriver.Refresh

---------------------------------------------------------------------------
-- EVENTS
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("UI_SCALE_CHANGED")
eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")

-- Pixel-perfect sizing depends on the plate's EFFECTIVE scale, which is not
-- final while the loading screen is up: UIParent scale settles post-login
-- and the plate-scale CVar pin only applies on PEW. Plates styled before
-- that settle would keep wrong sizes forever (the appearance generation
-- deliberately makes styling sticky) — so the settle path bumps the
-- generation and restyles, immediately and once more a second later for
-- values that finalize late.
local function ReassertAppearance()
    if not NP.IsEnabled() then return end
    NP.BumpAppearanceGeneration()
    RestyleActivePlates()
end

eventFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        OnNamePlateAdded(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnNamePlateRemoved(unit)
    elseif event == "PLAYER_LOGIN" then
        InstallHooks()
        if NP.IsEnabled() then
            Prewarm()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        InstallHooks()
        if NP.IsEnabled() then
            NPExtras.RefreshContext()
            NPCVars.ApplyAll()
            ReassertAppearance()
            if C_Timer and C_Timer.After then
                C_Timer.After(1, ReassertAppearance)
            end
        end
    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        ReassertAppearance()
    end
end)

-- Login-class suites load during the loading screen: the Blizzard driver
-- frame usually exists already, so install eagerly too.
InstallHooks()

---------------------------------------------------------------------------
-- PERF INSTRUMENTATION (/qui perf)
---------------------------------------------------------------------------
local function SetupDebugInstrumentation()
    ns.QUI_PerfRegistry = ns.QUI_PerfRegistry or {}
    ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "NameplateDriver", frame = eventFrame }
    ns.QUI_PerfRegistry[#ns.QUI_PerfRegistry + 1] = { name = "NameplateDefer", frame = deferFrame, scriptType = "OnUpdate" }
end
if ns.DebugRegister then
    ns.DebugRegister(SetupDebugInstrumentation)
else
    SetupDebugInstrumentation()
end
