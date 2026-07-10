--[[
    QUI Nameplates — reaction/class/threat/quest color resolver.

    A single resolver returning PLAIN r,g,b sourced from profile tables only.
    Every return path is verifiably non-secret, which is what enables the
    skip-if-unchanged latch in front of SetStatusBarColor.

    Contract: the resolver reads NO Unit* API. The driver precomputes plate
    state fields as plain values (or leaves them nil) with type()-gated reads:
        plate.npReaction    "hostile" | "neutral" | "friendly"
        plate.npIsPlayer    boolean
        plate.npClassToken  "MAGE" etc. or nil
        plate.npTapDenied   boolean
        plate.npIsQuest     boolean
        plate.npInCombat    boolean (unit affecting combat; ooc darkening)
        plate.npThreat      "high" | "offtank" | "near" | "low" | nil
        plate.npIsTarget    boolean
        plate.npIsFocus     boolean
    Threat/role context (tank vs dps ladder branch) comes from the cached
    zone/role context (plate_extras) — also plain values.

    Priority ladder (v1): tap-denied → quest → threat (instance-gated,
    role-aware) → target/focus override → enemy-player class color →
    reaction → out-of-combat darkening multiplier.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local NPColors = {}
NP.Colors = NPColors

local FALLBACK = { 0.39, 0.11, 0.09 }

local RAID_CLASS_COLORS = _G.RAID_CLASS_COLORS or {}

local function FromTable(t, fallback)
    t = t or fallback or FALLBACK
    return t[1] or 1, t[2] or 1, t[3] or 1
end

-- Threat branch: role-aware. context.role is the PLAYER's cached role
-- ("TANK"/"HEALER"/"DAMAGER"), context.inInstance a plain boolean; both
-- refreshed on PEW/zone/role events by plate_extras — never per plate.
local function ResolveThreat(colors, plate, context)
    if not context or context.inInstance ~= true then return nil end
    local threat = plate.npThreat
    if threat == nil then return nil end
    local isTank = context.role == "TANK"
    if isTank then
        if threat == "high" then
            return colors.tankHasAggro
        elseif threat == "offtank" then
            return colors.offTankAggro
        else
            return colors.tankNoAggro
        end
    else
        if threat == "high" then
            return colors.dpsHasAggro
        elseif threat == "near" then
            return colors.dpsNearAggro
        end
    end
    return nil
end

-- Returns plain r, g, b. `context` is the cached zone/role context.
function NPColors.Resolve(plate, settings, context)
    local colors = (settings and settings.colors) or {}

    -- 1. Tap-denied
    if plate.npTapDenied == true then
        return FromTable(colors.tapped)
    end

    -- 2. Quest mob
    if colors.questEnabled ~= false and plate.npIsQuest == true then
        return FromTable(colors.quest)
    end

    -- 3. Threat (instance-gated, role-aware)
    if colors.threatEnabled ~= false and plate.npReaction ~= "friendly" then
        local threatColor = ResolveThreat(colors, plate, context)
        if threatColor then
            return FromTable(threatColor)
        end
    end

    -- 4. Target / focus override
    if colors.targetEnabled == true and plate.npIsTarget == true then
        return FromTable(colors.target)
    end
    if colors.focusEnabled == true and plate.npIsFocus == true then
        return FromTable(colors.focus)
    end

    -- 5. Enemy-player class colors
    if colors.classColorEnemyPlayers ~= false and plate.npIsPlayer == true then
        local classColor = plate.npClassToken and RAID_CLASS_COLORS[plate.npClassToken]
        if classColor then
            return classColor.r or 1, classColor.g or 1, classColor.b or 1
        end
    end

    -- 6. Reaction
    local r, g, b
    if plate.npReaction == "friendly" then
        r, g, b = FromTable(colors.friendly)
    elseif plate.npReaction == "neutral" then
        r, g, b = FromTable(colors.neutral)
    else
        r, g, b = FromTable(colors.hostile)
    end

    -- 7. Out-of-combat darkening (plain boolean gate — the driver only sets
    -- npInCombat from a type()-checked UnitAffectingCombat read).
    if colors.oocDarken ~= false and plate.npInCombat == false and plate.npReaction ~= "friendly" then
        local f = colors.oocDarkenFactor or 0.75
        return r * f, g * f, b * f
    end

    return r, g, b
end
