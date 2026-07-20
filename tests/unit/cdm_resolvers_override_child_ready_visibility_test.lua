-- tests/unit/cdm_resolvers_override_child_ready_visibility_test.lua
-- Run: lua tests/unit/cdm_resolvers_override_child_ready_visibility_test.lua
-- luacheck: globals InCombatLockdown geterrorhandler CreateFrame issecretvalue
--
-- Brewmaster Empty Barrel apex procs (Purifying / Celestial / Fortifying
-- Brew) fire as an ACTIVE override child while the base brew sits on a REAL
-- non-GCD cooldown (0/2 charges, or Fortifying's plain 6-min cd). The lane
-- resolver correctly classifies the proc as mode="inactive" (the proc IS
-- ready, matching Blizzard), but containers configured iconDisplayMode
-- "active" hide inactive icons -- so the proc vanished from the bar instead
-- of surfacing. The resolver must therefore flag this shape as
-- overrideChildReady so the visibility layer keeps the icon shown, and the
-- flag must survive into the cooldown ACTIVITY state the visibility layer
-- reads.
--
-- The flag must stay FALSE for:
--   * a persistent form/spec override that is simply ready with its base
--     cooldown idle (Druid Stampeding Roar in form) -- hiding a plain ready
--     icon is exactly what iconDisplayMode="active" is for, and
--   * an override child whose own cooldown lane is rolling (Shadow Priest
--     Void Volley just cast) -- that renders mode="cooldown" and is visible
--     through isOnCooldown already.

local function noop() end

function InCombatLockdown() return false end
function issecretvalue() return false end
function geterrorhandler() return function(err) error(err) end end
function CreateFrame()
    return { RegisterEvent = noop, RegisterUnitEvent = noop, SetScript = noop }
end

-- Purifying Brew base 119582; proc override id is arbitrary (distinct, no
-- cooldown lane of its own -- the free proc cast).
local PB_BASE, PB_PROC, PB_CDID = 119582, 5559001, 9101

-- Cooldown state the stubbed sources report, mutated per scenario.
local baseCooldown = { isActive = true, isOnGCD = false }
local overrideCooldown = { isActive = false, isOnGCD = false }
local baseCharges = { maxCharges = 2, chargeCount = 0, isActive = true }

local ns = {
    Helpers = {},
    CDMSources = {
        QuerySpellCooldown = function(spellID)
            if spellID == PB_BASE then
                return { isActive = baseCooldown.isActive == true,
                         isOnGCD = baseCooldown.isOnGCD == true }
            end
            if spellID == PB_PROC then
                return { isActive = overrideCooldown.isActive == true,
                         isOnGCD = overrideCooldown.isOnGCD == true }
            end
            return { isActive = false, isOnGCD = false }
        end,
        QuerySpellCooldownDuration = function() return nil end,
        QuerySpellCharges = function(spellID)
            if spellID == PB_BASE then return baseCharges end
            return nil
        end,
        -- Empty Barrel shape: no live spell override and no proc overlay --
        -- the override reaches us only through the cooldown-info mirror field.
        QueryOverrideSpell = function() return nil end,
        QueryIsSpellKnownOrPlayerSpell = function() return true end,
        QuerySpellInfo = function() return nil end,
    },
    CDMBlizzMirror = {
        GetStateByCooldownID = function(cooldownID, viewerCategory)
            if cooldownID == PB_CDID and viewerCategory == "essential" then
                return {
                    cooldownID = PB_CDID,
                    mirrorEpoch = 3,
                    spellID = PB_BASE,
                    overrideSpellID = PB_PROC,
                    viewerCategory = "essential",
                    childIsActive = true,
                    charges = true,
                }
            end
        end,
    },
}

local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_runtime_queries.lua", "cdm_runtime_queries.lua")("QUI", ns)
loadChunk("QUI_CDM/cdm/cdm_resolvers.lua", "cdm_resolvers.lua")("QUI", ns)

local function ResolveState()
    local entry = {
        id = PB_BASE,
        spellID = PB_BASE,
        overrideSpellID = PB_PROC,
        viewerType = "essential",
        type = "spell",
        charges = true,
    }
    local icon = { _spellEntry = entry, _runtimeSpellID = PB_PROC }
    local context = ns.CDMResolvers.BuildCooldownStateContext(icon, entry, PB_PROC, {
        containerKey = "essential",
        useBuffSwipe = false,
        skipAuraPhase = false,
        showGCDSwipe = true,
    })
    context.mirrorCooldownID = PB_CDID
    context.mirrorCategory = "essential"
    return ns.CDMResolvers.ResolveCooldownState(context), entry
end

-- Scenario 1: proc live while the base brew is fully on a real cooldown
-- (0/2 charges). Lane resolver classifies "inactive" (proc ready) -- the
-- flag must mark the live override child so visibility keeps the icon.
baseCooldown.isActive, baseCooldown.isOnGCD = true, false
overrideCooldown.isActive = false
local resolved, entry = ResolveState()
assert(resolved.mode == "inactive",
    "proc over fully-spent base must classify inactive (ready), got "
        .. tostring(resolved.mode))
assert(resolved.overrideChildReady == true,
    "proc over fully-spent base must set overrideChildReady on the resolved state")

local activity = ns.CDMResolvers.ResolveCooldownActivityStateFromResolvedState(entry, resolved)
assert(activity, "activity state should derive from resolved state")
assert(activity.overrideChildReady == true,
    "overrideChildReady must survive into the cooldown activity state")

-- Scenario 1b: proc live while the base brew rolls a CHARGE recharge (1/2).
-- The live proc outranks the recharge lane -- Blizzard's viewer queries the
-- override spell (no cooldown of its own) and shows the proc READY, not the
-- base's recharge swipe. Must classify inactive + flag, not "cooldown".
baseCooldown.isActive, baseCooldown.isOnGCD = false, false
baseCharges.isActive = true
overrideCooldown.isActive = false
local rechargeResolved, rechargeEntry = ResolveState()
assert(rechargeResolved.mode == "inactive",
    "proc over recharging base must classify inactive (proc outranks recharge), got "
        .. tostring(rechargeResolved.mode))
assert(rechargeResolved.overrideChildReady == true,
    "proc over recharging base must set overrideChildReady")
local rechargeActivity = ns.CDMResolvers.ResolveCooldownActivityStateFromResolvedState(
    rechargeEntry, rechargeResolved)
assert(rechargeActivity and rechargeActivity.overrideChildReady == true,
    "recharging-base activity state must report overrideChildReady")

-- Scenario 1c: base fully idle but the proc-overlay event cache flags the
-- override spellID (SPELL_ACTIVATION_OVERLAY_GLOW_SHOW fired). The overlay
-- is the authoritative proc edge -- flag must fire even with nothing
-- rolling on the base.
ns.CDMResolvers.SetProcOverlayProbe(function(spellID)
    return spellID == PB_PROC
end)
baseCooldown.isActive, baseCooldown.isOnGCD = false, false
baseCharges.isActive = false
overrideCooldown.isActive = false
local overlayResolved = ResolveState()
assert(overlayResolved.mode == "inactive",
    "overlay-flagged proc over idle base must classify inactive, got "
        .. tostring(overlayResolved.mode))
assert(overlayResolved.overrideChildReady == true,
    "overlay-flagged proc over idle base must set overrideChildReady")
ns.CDMResolvers.SetProcOverlayProbe(nil)

-- Scenario 2: persistent override merely READY with the base cooldown idle
-- and NO proc overlay (form override shape -- Druid Stampeding Roar in
-- form). Indistinguishable from a proc by cooldown queries alone; flag must
-- stay false so iconDisplayMode="active" still hides it.
baseCooldown.isActive, baseCooldown.isOnGCD = false, false
baseCharges.isActive = false
overrideCooldown.isActive = false
local readyResolved, readyEntry = ResolveState()
assert(readyResolved.mode == "inactive",
    "ready override with idle base must classify inactive, got "
        .. tostring(readyResolved.mode))
assert(readyResolved.overrideChildReady ~= true,
    "ready override with idle base must NOT set overrideChildReady")
local readyActivity = ns.CDMResolvers.ResolveCooldownActivityStateFromResolvedState(
    readyEntry, readyResolved)
assert(readyActivity and readyActivity.overrideChildReady ~= true,
    "idle-base activity state must NOT report overrideChildReady")

-- Scenario 3: override child owns a ROLLING cooldown lane (Void Volley just
-- cast while Voidform runs). Renders mode="cooldown"; flag must stay false.
baseCooldown.isActive, baseCooldown.isOnGCD = true, false
baseCharges.isActive = true
overrideCooldown.isActive = false
overrideCooldown.isActive, overrideCooldown.isOnGCD = true, false
local rollingResolved = ResolveState()
assert(rollingResolved.mode == "cooldown",
    "override child with rolling own lane must classify cooldown, got "
        .. tostring(rollingResolved.mode))
assert(rollingResolved.overrideChildReady ~= true,
    "override child with rolling own lane must NOT set overrideChildReady")

-- Renderer wiring pins: the visibility gates that hide inactive icons under
-- iconDisplayMode="active" must consult the flag, and the runtime store
-- write must persist it for the stored-state activity path.
local handle = assert(io.open("QUI_CDM/cdm/cdm_icon_renderer.lua", "rb"))
local rendererSource = handle:read("*a")
handle:close()
local _, gateCount = rendererSource:gsub(
    "elseif cooldownState%.overrideChildReady == true then%s*shouldShow = true", "%0")
assert(gateCount >= 2,
    "both non-aura container visibility gates must keep overrideChildReady icons shown (found "
        .. tostring(gateCount) .. ")")
assert(rendererSource:find(
    "state%.overrideChildReady = resolvedState and resolvedState%.overrideChildReady or nil"),
    "StoreIconRuntimeState must persist overrideChildReady into the runtime store")

-- Icon ART pin: SyncBlizzMirrorIconState's no-aura texture write runs on
-- every mirror pass and used to paint GetEntryTexture(entry) FIRST -- the
-- saved entry art (Keg Smash) -- clobbering the live-display override art
-- (the procced brew) that UpdateIconCooldownOwned had just applied from
-- runtimeSid. The live-resolved runtimeSid must win; entry art is the
-- fallback. In-game 2026-07-19: Keg Smash icon stayed default through
-- every Empty Barrel proc because of this ordering.
assert(rendererSource:find(
    "local baseTex = GetSpellTexture%(runtimeSid%) or GetEntryTexture%(entry%)"),
    "mirror sync no-aura texture write must prefer the live-display runtimeSid art over the saved entry art")

-- Proc ART ground truth (probe round 2, in-game 2026-07-19): at proc time
-- the Blizzard child's icon texture flips to a SECRET value while every
-- spell-ID surface (GetOverrideSpell, cooldown-info override fields,
-- override events) stays silent. The ONLY way to render the proc art is to
-- forward the child's texture verbatim -- SetTexture is SecretArguments
-- "AllowedWhenTainted" (SimpleTextureBaseAPIDocumentation.lua:441) -- and
-- it must never be compared or truth-tested when secret.
local handle2 = assert(io.open("QUI_CDM/cdm/cdm_blizz_mirror.lua", "rb"))
local mirrorSource = handle2:read("*a")
handle2:close()
assert(mirrorSource:find("packed%.childIconTexture"),
    "mirror PackState must capture the Blizzard child's live icon texture")
assert(rendererSource:find(
    "function _resolverRuntimePolicy%.ApplyMirrorChildTexture"),
    "renderer must define the child-texture forward helper (policy method -- 200-local ceiling)")
local _, forwardCalls = rendererSource:gsub(
    "not _resolverRuntimePolicy%.ApplyMirrorChildTexture%(icon", "%0")
assert(forwardCalls >= 2,
    "both cooldown texture sites must try the child-texture forward first (found "
        .. tostring(forwardCalls) .. ")")
-- Secret discipline inside the helper: probe first, forward-only, poison the
-- dedup fields so the first clean post-proc texture repaints.
assert(rendererSource:find(
    "if issecretvalue and issecretvalue%(tex%) then%s*icon%.Icon%.SetTexture%(icon%.Icon, tex%)%s*icon%._lastTexture = nil%s*icon%._desiredTexture = nil"),
    "child-texture helper must probe-then-forward secret textures and poison texture dedup state")

print("cdm_resolvers_override_child_ready_visibility_test: PASS")
