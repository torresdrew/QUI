-- tests/unit/cdm_resolvers_empty_barrel_proc_test.lua
-- Run: lua tests/unit/cdm_resolvers_empty_barrel_proc_test.lua
-- luacheck: globals InCombatLockdown geterrorhandler CreateFrame issecretvalue
--
-- Regression for the Brewmaster Empty Barrel apex procs (Purifying / Celestial /
-- Fortifying Brew). These fire as an ACTIVE override child (childIsActive=true,
-- overrideSpellID set) whose override spell has NO cooldown lane of its own --
-- the free-cast proc version. The base brew is either idle or rolling a charge
-- recharge.
--
-- The Void Volley override-lane resolver (ResolveActiveOverrideChildCooldownLane)
-- must NOT intercept these: with no real (non-GCD) base cooldown to paint over
-- the override, they have to fall through to the charge-recharge / gcd / casting
-- chain that surfaced them before, not collapse to mode=inactive and drop off
-- the CDM bar. Void Volley (base major cooldown rolling) stays covered by
-- cdm_resolvers_void_volley_override_test.lua.

local function noop() end

function InCombatLockdown() return false end
function issecretvalue() return false end
function geterrorhandler() return function(err) error(err) end end
function CreateFrame()
    return { RegisterEvent = noop, RegisterUnitEvent = noop, SetScript = noop }
end

-- Purifying Brew base 119582; proc override id is arbitrary here (distinct, and
-- carries no cooldown lane -- the free proc cast).
local PB_BASE, PB_PROC, PB_CDID = 119582, 5559001, 9101

-- Cooldown/charge state the stubbed sources report, mutated per scenario.
local baseCooldown = { isActive = false, isOnGCD = false }
local baseCharges  = { maxCharges = 2, chargeCount = 1, isActive = true }

local ns = {
    Helpers = {},
    CDMSources = {
        QuerySpellCooldown = function(spellID)
            if spellID == PB_BASE then
                return { isActive = baseCooldown.isActive == true,
                         isOnGCD = baseCooldown.isOnGCD == true }
            end
            -- The proc override never owns a cooldown lane.
            return { isActive = false, isOnGCD = false }
        end,
        QuerySpellCooldownDuration = function() return nil end,
        QuerySpellCharges = function(spellID)
            if spellID == PB_BASE then return baseCharges end
            return nil
        end,
        -- No live spell override and no proc overlay -> NOT a transient proc
        -- ready; the override reaches us only through the cooldown-info mirror
        -- field, exactly the Empty Barrel shape.
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

local function ResolveMode()
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
    return ns.CDMResolvers.ResolveCooldownState(context)
end

-- Scenario 1: proc fired, base brew rolling a charge recharge (1/2), override
-- child active with no cooldown of its own. Must surface the recharge swipe --
-- pre-4.0.4 behaviour -- not vanish.
baseCooldown.isActive, baseCooldown.isOnGCD = false, false
baseCharges.isActive = true
local charging = ResolveMode()
assert(charging.mode == "cooldown",
    "active override child over a recharging base must surface the charge lane, got "
        .. tostring(charging.mode))

-- Scenario 2: base at max charges, an incidental GCD ticking from another cast,
-- override child active. Must still surface (gcd swipe), never inactive.
baseCooldown.isActive, baseCooldown.isOnGCD = true, true
baseCharges.isActive = false
local gcd = ResolveMode()
assert(gcd.mode ~= "inactive",
    "active override child with no real base cooldown must not collapse to inactive, got "
        .. tostring(gcd.mode))

print("cdm_resolvers_empty_barrel_proc_test: PASS")
