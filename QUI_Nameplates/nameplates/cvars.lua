--[[
    QUI Nameplates — CVar ownership, sizing, stacking.

    Single owner for every nameplate CVar QUI touches. All writers route
    through the combat gate: in combat the write is queued and replayed on
    PLAYER_REGEN_ENABLED. uihider's two friendly-visibility toggles delegate
    here via ns.QUI_NameplatesCVars (see modules/ui/uihider.lua).

    Scale environment is pinned (min/max/selected scale = 1) — the plate art,
    hitbox math, and any future lift-overlay assume effective plate scale 1.

    12.x note: stacking is the nameplateStackingTypes bitfield
    (Enum.NamePlateStackType) plus per-frame SetStackingBoundsFrame; the old
    nameplateOverlapH/V + nameplateMaxDistance CVars survive as runtime CVars
    but are no longer referenced by Blizzard's driver — writes stay
    pcall-wrapped so a future removal degrades silently.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local pcall = pcall
local type = type
local tostring = tostring
local InCombatLockdown = InCombatLockdown
local SetCVar = SetCVar
local CreateFrame = CreateFrame

local NPCVars = {}
ns.QUI_NameplatesCVars = NPCVars
NP.CVars = NPCVars

---------------------------------------------------------------------------
-- COMBAT-DEFERRED WRITE GATE
---------------------------------------------------------------------------
local pendingCVars = {}      -- [name] = value (last write wins)
local pendingActions = {}    -- ordered list of deferred non-CVar actions (size/insets)
local hasPending = false

local replayFrame = CreateFrame("Frame")
replayFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local function WriteCVar(name, value)
    pcall(SetCVar, name, value)
end

-- Queue-or-write. Values are always plain (profile-derived); never secrets.
function NPCVars.Set(name, value)
    if InCombatLockdown() then
        pendingCVars[name] = value
        hasPending = true
        return
    end
    WriteCVar(name, value)
end

-- Defer an arbitrary restricted call (SetNamePlateSize / hit-test insets).
-- `key` dedupes: the latest closure per key wins on replay.
local function RunOrDefer(key, fn)
    if InCombatLockdown() then
        pendingActions[key] = fn
        hasPending = true
        return
    end
    pcall(fn)
end

replayFrame:SetScript("OnEvent", function()
    if not hasPending then return end
    hasPending = false
    for name, value in pairs(pendingCVars) do
        WriteCVar(name, value)
    end
    wipe(pendingCVars)
    for _, fn in pairs(pendingActions) do
        pcall(fn)
    end
    wipe(pendingActions)
end)

---------------------------------------------------------------------------
-- SCALE ENVIRONMENT + GLOBAL CVARS
---------------------------------------------------------------------------
function NPCVars.ApplyScaleEnvironment()
    if not NP.IsEnabled() then return end
    local s = NP.GetSettings()
    local cv = s.cvars or {}

    -- Pin effective plate scale to 1 — required by the pixel-perfect plate
    -- art and by every scale assumption downstream (hitbox, stacking bounds).
    NPCVars.Set("nameplateMinScale", 1)
    NPCVars.Set("nameplateMaxScale", 1)
    NPCVars.Set("nameplateSelectedScale", 1)
    NPCVars.Set("nameplateShowAll", 1)
    if cv.maxDistance then
        NPCVars.Set("nameplateMaxDistance", cv.maxDistance)
    end
end

---------------------------------------------------------------------------
-- HITBOX (C_NamePlate.SetNamePlateSize + hit-test insets)
---------------------------------------------------------------------------
-- One global size for all plates in 12.0 (per-reaction variants are gone);
-- derived from the configured health bar size × the user's hitbox scale.
-- Grows from CENTER — no Y-compensation is possible, so the stacking bounds
-- frame (per-plate) is what actually shapes overlap behavior.
function NPCVars.ApplyPlateSize()
    if not NP.IsEnabled() then return end
    if not (C_NamePlate and C_NamePlate.SetNamePlateSize) then return end
    local s = NP.GetSettings()
    local cv = s.cvars or {}
    local health = s.health or {}
    local w = (health.width or 210) * ((cv.hitboxScaleX or 100) / 100)
    local h = (health.height or 24) * ((cv.hitboxScaleY or 100) / 100)
    -- Give vertical room for name + castbar so clicks land naturally.
    local castH = (s.castbar and s.castbar.height or 17)
    local nameH = (s.name and ((s.name.size or 11) + math.abs(s.name.offsetY or 4)) or 15)
    local totalH = h + castH + nameH
    RunOrDefer("plateSize", function()
        C_NamePlate.SetNamePlateSize(w, totalH)
    end)

    -- SecretArguments = NotAllowed: plain profile numbers only.
    if C_NamePlateManager and C_NamePlateManager.SetNamePlateHitTestInsets
        and Enum and Enum.NamePlateType then
        RunOrDefer("hitInsets", function()
            C_NamePlateManager.SetNamePlateHitTestInsets(Enum.NamePlateType.Enemy, 0, 0, 0, 0)
            C_NamePlateManager.SetNamePlateHitTestInsets(Enum.NamePlateType.Friendly, 0, 0, 0, 0)
        end)
    end
end

---------------------------------------------------------------------------
-- STACKING
---------------------------------------------------------------------------
-- Global stacking-type bitfield. The per-plate rendered-bounds frames are
-- owned by the driver (attached in SetUnit, detached in ClearUnit).
function NPCVars.ApplyStacking()
    if not NP.IsEnabled() then return end
    local s = NP.GetSettings()
    local cv = s.cvars or {}
    if not (C_CVar and C_CVar.SetCVarBitfield and Enum and Enum.NamePlateStackType) then return end
    RunOrDefer("stacking", function()
        C_CVar.SetCVarBitfield("nameplateStackingTypes", Enum.NamePlateStackType.Enemy, cv.stackingEnemy ~= false)
        C_CVar.SetCVarBitfield("nameplateStackingTypes", Enum.NamePlateStackType.Friendly, cv.stackingFriendly == true)
    end)
end

---------------------------------------------------------------------------
-- FRIENDLY VISIBILITY (uihider handshake + friendly module)
---------------------------------------------------------------------------
-- uihider's request, remembered so mode flips can reconcile against it.
local uihiderRequest = nil   -- { players = bool, npcs = bool } or nil

local function FriendlyMode()
    local s = NP.GetSettings()
    return (s.friendly and s.friendly.mode) or "nameonly"
end

-- Active = the suite is enabled AND managing friendly plates (mode ~= off).
-- When inactive, uihider falls back to its own raw SetCVar writes.
function NPCVars:IsActive()
    return NP.IsEnabled() and FriendlyMode() ~= "off"
end

-- Resolve what the friendly visibility CVar group should be, combining the
-- friendly module's mode with uihider's hide-toggles (most-hidden wins).
local function ApplyFriendlyVisibility()
    local s = NP.GetSettings()
    local friendly = s.friendly or {}
    local mode = FriendlyMode()
    if mode == "off" then return end  -- relinquished: not ours to write

    local showPlayers = friendly.showInWorld ~= false
    local showNPCs = friendly.showInWorld ~= false
    if uihiderRequest then
        if uihiderRequest.players == false then showPlayers = false end
        if uihiderRequest.npcs == false then showNPCs = false end
    end
    NPCVars.Set("nameplateShowFriends", showPlayers and 1 or 0)
    NPCVars.Set("nameplateShowFriendlyPlayers", showPlayers and 1 or 0)
    NPCVars.Set("nameplateShowFriendlyNpcs", showNPCs and 1 or 0)
    -- Legacy capitalization kept in sync (some client builds still read it).
    NPCVars.Set("nameplateShowFriendlyNPCs", showNPCs and 1 or 0)
end
NPCVars.ApplyFriendlyVisibility = ApplyFriendlyVisibility

-- uihider delegation entry point (called inside its C_Timer.After(0) closure).
function NPCVars:RequestFriendlyVisibility(showPlayers, showNPCs)
    uihiderRequest = uihiderRequest or {}
    uihiderRequest.players = showPlayers and true or false
    uihiderRequest.npcs = showNPCs and true or false
    ApplyFriendlyVisibility()
end

---------------------------------------------------------------------------
-- FULL APPLY (login / settings refresh / zone change)
---------------------------------------------------------------------------
function NPCVars.ApplyAll()
    if not NP.IsEnabled() then return end
    NPCVars.ApplyScaleEnvironment()
    NPCVars.ApplyPlateSize()
    NPCVars.ApplyStacking()
    ApplyFriendlyVisibility()
end
