-- tests/cdm_icon_factory_mirror_empty_stack_test.lua
-- Run: lua tests/cdm_icon_factory_mirror_empty_stack_test.lua

local BuildCooldownStateContext = dofile("tests/helpers/cdm_context_builder_stub.lua")

local function noop() end

local inCombat = false
function InCombatLockdown() return inCombat end
function GetTime() return 100 end
function CreateFrame()
    return {
        RegisterEvent = noop,
        RegisterUnitEvent = noop,
        UnregisterAllEvents = noop,
        SetScript = noop,
    }
end
function wipe(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

C_Timer = {
    After = function(_, callback) callback() end,
    NewTimer = function()
        return { Cancel = noop }
    end,
}
C_StringUtil = {
    TruncateWhenZero = function(value)
        return value == 0 and "" or tostring(value)
    end,
}

local stackWrites = {}
local textureWrites = {}
local secretAuraIcon = { token = "secret-aura-icon" }

local ns = {
    Helpers = {
        GetGeneralFont = function() return "Fonts\\FRIZQT__.TTF" end,
        GetGeneralFontOutline = function() return "" end,
        CreateDBGetter = function()
            return function()
                return {
                    essential = {
                        desaturateOnCooldown = true,
                    },
                    buff = {
                        desaturateOnCooldown = true,
                    },
                }
            end
        end,
        IsSecretValue = function() return false end,
        SafeValue = function()
            error("SafeValue must not be used in the icon factory combat display path")
        end,
        SafeToNumber = function(value) return value end,
        CanAccessTable = function(tbl) return type(tbl) == "table" end,
    },
    Addon = {
        db = {
            profile = { ncdm = {} },
            char = { ncdm = {} },
        },
    },
    CDMShared = {
        IsRuntimeEnabled = function() return true end,
        IsSafeNumeric = function(value) return type(value) == "number" end,
    },
    CDMSources = {
        QuerySpellCharges = function(spellID)
            if spellID == 49998 then
                return {
                    currentCharges = 3,
                    maxCharges = 3,
                    isActive = false,
                }
            end
            return nil
        end,
        QuerySpellCooldown = function()
            return {
                startTime = 0,
                duration = 0,
                isActive = false,
            }
        end,
        QuerySpellDisplayCount = function(spellID)
            if spellID == 49998 then
                return 3
            end
            return nil
        end,
    },
    CDMResolvers = {
        BuildCooldownStateContext = BuildCooldownStateContext,
        _textureCycleCache = {},
        _FinalizeImports = noop,
        Subscribe = noop,
        GetEntryTexture = function() return nil end,
        GetSpellTexture = function() return nil end,
        ResolveCooldownState = function(context)
            local entry = context and context.entry
            if entry and entry.spellID == 195182 then
                return {
                    mode = "aura",
                    active = true,
                    isActive = true,
                    auraActive = true,
                    isTotemInstance = false,
                    count = {
                        sinkText = "7",
                        value = 7,
                        shown = true,
                        source = "display-count",
                    },
                }
            end
            if entry and entry.spellID == 195183 then
                return {
                    mode = "aura",
                    active = true,
                    isActive = true,
                    auraActive = true,
                    isTotemInstance = false,
                    auraData = {
                        icon = secretAuraIcon,
                    },
                    count = {
                        sinkText = "8",
                        value = 8,
                        shown = true,
                        source = "display-count",
                    },
                    resolvedAuraSpellID = 195183,
                }
            end
            return {
                mode = "inactive",
                active = false,
                isActive = false,
                auraActive = false,
            }
        end,
        ResolveMacro = function() return nil end,
        IsAuraEntry = function(entry) return entry and entry.type == "aura" end,
        ResolveSpellActiveState = function() return nil end,
        ResolveCooldownActivityState = function()
            return { isOnCooldown = false, rechargeActive = false }
        end,
    },
}

assert(loadfile("modules/cdm/cdm_icon_factory.lua"))("QUI", ns)
dofile("tests/helpers/load_cdm_icon_runtime.lua")(ns)
assert(loadfile("modules/cdm/cdm_icons.lua"))("QUI", ns)

ns.CDMIcons.DebugStackText = function(_icon, op, value, reason)
    stackWrites[#stackWrites + 1] = { op = op, value = value, reason = reason }
end
ns.CDMIcons.ShouldAllowStackTextWrites = function() return true end

local function MakeStackText()
    return {
        SetText = function(_, value)
            stackWrites[#stackWrites + 1] = { op = "set", value = value }
        end,
        Hide = function()
            stackWrites[#stackWrites + 1] = { op = "frame-hide" }
        end,
        Show = function()
            stackWrites[#stackWrites + 1] = { op = "frame-show" }
        end,
        SetTextColor = function() end,
    }
end

local function MakeCooldown()
    return {
        SetDrawSwipe = function() end,
        SetDrawBling = function() end,
        SetSwipeTexture = function() end,
        SetSwipeColor = function() end,
        SetHideCountdownNumbers = function() end,
        SetReverse = function() end,
        Clear = function() end,
        Show = function() end,
    }
end

local staleIcon = {
    _spellEntry = {
        id = 49998,
        spellID = 49998,
        type = "spell",
        kind = "cooldown",
        viewerType = "essential",
        name = "Death Strike",
    },
    Icon = {
        Show = function() end,
    },
    Cooldown = MakeCooldown(),
    StackText = MakeStackText(),
    TextOverlay = {
        Show = function() end,
    },
}

ns.CDMIconFactory.SetIconBlizzMirrorBinding(staleIcon, 12345, "essential")

assert(#stackWrites >= 1, "binding an empty mirror-backed cooldown should clear stale stack text")
assert(stackWrites[1].op == "set" and stackWrites[1].value == "", "binding should clear stale stack text")

stackWrites = {}

local icon = {
    _spellEntry = {
        id = 49998,
        spellID = 49998,
        type = "spell",
        kind = "cooldown",
        viewerType = "essential",
        name = "Death Strike",
    },
    _blizzMirrorCooldownID = 12345,
    _blizzMirrorCategory = "essential",
    Icon = {
        SetTexture = function() end,
        SetDesaturated = function() end,
        SetVertexColor = function() end,
    },
    Cooldown = MakeCooldown(),
    StackText = MakeStackText(),
}

ns.CDMIcons.OnContainerIconPlaced(icon)

assert(stackWrites[1] and stackWrites[1].op == "hide",
    "mirror-empty cooldown icon should hide stack text")
assert(stackWrites[1].reason == "mirror-stack-empty", "mirror-empty cooldown icon should use mirror-empty reason")

stackWrites = {}
inCombat = true

local marrowrendIcon = {
    _spellEntry = {
        id = 195182,
        spellID = 195182,
        type = "spell",
        kind = "cooldown",
        viewerType = "essential",
        name = "Marrowrend",
    },
    _blizzMirrorCooldownID = 195182,
    _blizzMirrorCategory = "essential",
    Icon = {
        SetTexture = function() end,
        SetDesaturated = function() end,
        SetVertexColor = function() end,
    },
    Cooldown = MakeCooldown(),
    StackText = MakeStackText(),
}

ns.CDMIcons.OnContainerIconPlaced(marrowrendIcon)

local marrowrendText
local marrowrendHideReason
for _, write in ipairs(stackWrites) do
    if write.op == "set" and write.value ~= "" then
        marrowrendText = write.value
    elseif write.op == "hide" then
        marrowrendHideReason = write.reason
    end
end
assert(marrowrendText == "7", "Marrowrend should forward the resolver's display count")
assert(marrowrendHideReason ~= "mirror-stack-empty",
    "mirror-empty cooldown stack pass must not clobber resolver aura counts in combat")

stackWrites = {}
textureWrites = {}

local secretTextureIcon = {
    _spellEntry = {
        id = 195183,
        spellID = 195183,
        type = "aura",
        kind = "aura",
        viewerType = "buff",
        name = "Secret Aura Icon",
    },
    Icon = {
        SetTexture = function(_, texture)
            textureWrites[#textureWrites + 1] = texture
        end,
        SetDesaturated = function() end,
        SetVertexColor = function() end,
    },
    Cooldown = MakeCooldown(),
    StackText = MakeStackText(),
}

ns.CDMIcons.OnContainerIconPlaced(secretTextureIcon)

assert(textureWrites[1] == secretAuraIcon, "combat aura icon texture should be passed directly to SetTexture")
local secretAuraText
for _, write in ipairs(stackWrites) do
    if write.op == "set" and write.value ~= "" then
        secretAuraText = write.value
    end
end
assert(secretAuraText == "8", "combat aura count should be applied without SafeValue filtering")

print("OK: cdm_icon_factory_mirror_empty_stack_test")
