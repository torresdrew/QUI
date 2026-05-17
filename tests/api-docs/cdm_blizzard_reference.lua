-- CDM-specific Blizzard API facts that are too important to live only in
-- comments or agent instructions. The vendored FrameXML documentation remains
-- the raw source; this table records the policy CDM code and tests enforce.

return {
    sourceDocs = {
        cooldownViewer = "tests/api-docs/blizzard/CooldownViewerDocumentation.lua",
        cooldownFrame = "tests/api-docs/blizzard/FrameAPICooldownDocumentation.lua",
        curveUtil = "tests/api-docs/blizzard/CurveUtilDocumentation.lua",
        statusBar = "tests/api-docs/blizzard/SimpleStatusBarAPIDocumentation.lua",
        totem = "tests/api-docs/blizzard/TotemDocumentation.lua",
        unitAura = "tests/api-docs/blizzard/UnitAuraDocumentation.lua",
    },

    apiIndexContracts = {
        ["C_CooldownViewer.GetCooldownViewerCategorySet"] = {
            secretArguments = "AllowedWhenUntainted",
        },
        ["C_CooldownViewer.GetCooldownViewerCooldownInfo"] = {
            secretArguments = "AllowedWhenUntainted",
        },
        ["C_CooldownViewer.GetValidAlertTypes"] = {
            secretArguments = "AllowedWhenUntainted",
        },
        ["C_UnitAuras.GetAuraDuration"] = {
            secretArguments = "AllowedWhenUntainted",
        },
        ["Totem.GetTotemDuration"] = {
            secretArguments = "AllowedWhenUntainted",
        },
    },

    durationObjectSources = {
        ["C_UnitAuras.GetAuraDuration"] = {
            doc = "unitAura",
            returnType = "LuaDurationObject",
            use = "aura duration lane",
        },
        ["Totem.GetTotemDuration"] = {
            doc = "totem",
            runtimeName = "GetTotemDuration",
            returnType = "LuaDurationObject",
            use = "totem duration lane",
        },
    },

    durationObjectSinks = {
        SetCooldownFromDurationObject = {
            doc = "cooldownFrame",
            receiver = "CooldownFrame",
            argumentType = "LuaDurationObject",
            policy = "preferred cooldown frame sink for secret-capable timing",
        },
        SetTimerDuration = {
            doc = "statusBar",
            receiver = "StatusBar",
            argumentType = "LuaDurationObject",
            policy = "preferred bar fill sink for secret-capable timing",
        },
    },

    cooldownFrame = {
        preferredSecretSafeSetter = "SetCooldownFromDurationObject",
        unsafeSecretSetters = {
            "SetCooldown",
            "SetCooldownFromExpirationTime",
            "SetCooldownDuration",
            "SetCooldownUNIX",
        },
        numericFallback = {
            facade = "CDMRenderers.ApplyNumericCooldown",
            method = "SetCooldown",
            allowedCallSites = {
                ["modules/cdm/cdm_renderers.lua"] = true,
            },
            policy = "clean item timing only; never secret-derived cooldown timing",
        },
    },

    secretBooleanDecode = {
        functionName = "C_CurveUtil.EvaluateColorValueFromBoolean",
        docFunctionName = "EvaluateColorValueFromBoolean",
        doc = "curveUtil",
        secretArguments = "AllowedWhenTainted",
        valueIfTrue = 1,
        valueIfFalse = 0,
        returnType = "SingleColorValue",
        policy = "only approved Lua-visible decode path for potentially-secret booleans",
    },
}
