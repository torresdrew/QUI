local _, ns = ...

---------------------------------------------------------------------------
-- BLIZZARD CHILD DEBUG HELPERS (satellite of cdm_blizz_mirror.lua)
--
-- Blizzard child frames now stay in Blizzard's viewers. QUI icons consume
-- mirrored state by cooldownID, while debug tooling can still inspect the
-- original child frame and its native regions.
--
-- Split out of cdm_blizz_mirror.lua (which sits at Lua's 200-local
-- main-chunk ceiling). Public surface is unchanged:
-- CDMBlizzMirror.GetChildDebugLines and .GetCooldownMethodTestPayload.
-- Parent internals arrive via CDMBlizzMirror._* exports (set by the parent
-- before this file loads).
---------------------------------------------------------------------------

local CDMBlizzMirror = ns.CDMBlizzMirror
if not CDMBlizzMirror then return end  -- REQUIRED nil guard

-- Parent internals (exported for this satellite; not for other suites).
local GetInstanceChild = CDMBlizzMirror._GetInstanceChild
local PackState = CDMBlizzMirror._PackState
local ResolveInstanceKey = CDMBlizzMirror._ResolveInstanceKey
local BuildAuraProbeLines = CDMBlizzMirror._BuildAuraProbeLines
local ReadChildAuraData = CDMBlizzMirror._ReadChildAuraData
local DecodePotentialSecretBoolean = CDMBlizzMirror._DecodePotentialSecretBoolean
local SafeFrameField = CDMBlizzMirror._SafeFrameField
local RawFrameField = CDMBlizzMirror._RawFrameField
local SafeFrameBooleanField = CDMBlizzMirror._SafeFrameBooleanField
local SafeFrameShownField = CDMBlizzMirror._SafeFrameShownField
local _mirrorState = CDMBlizzMirror._mirrorState

-- Reuses the parent's FindMirrorFontString: identical self/regions/children
-- recursive FontString search; redundant nil-checks on {...} tables dropped.
local FindFirstFontString = CDMBlizzMirror._FindMirrorFontString

local function SafeCall(owner, method, ...)
    local fn = owner and owner[method]
    if not fn then return nil end
    return fn(owner, ...)
end

local function SafeFieldText(owner)
    local text = SafeCall(owner, "GetText")
    if issecretvalue and issecretvalue(text) then
        return "<SECRET:" .. type(text) .. ">"
    end
    if text == nil then return "nil" end
    return tostring(text)
end

local function SafeShown(owner)
    if not owner then return "nil" end
    local shown = SafeCall(owner, "IsShown")
    local decoded = DecodePotentialSecretBoolean(shown)
    if decoded ~= nil then
        CDMBlizzMirror._knownShownByFrame[owner] = decoded
        return tostring(decoded)
    end
    decoded = CDMBlizzMirror._knownShownByFrame[owner]
    if decoded ~= nil then
        return tostring(decoded)
    end
    if issecretvalue and issecretvalue(shown) then
        return "<SECRET:" .. type(shown) .. ">"
    end
    if shown == nil then return "nil" end
    return tostring(shown == true)
end

local function SafeTexture(owner)
    if not owner then return "nil" end
    local tex = SafeCall(owner, "GetTexture")
    if issecretvalue and issecretvalue(tex) then return "<SECRET:" .. type(tex) .. ">" end
    if tex ~= nil then return tostring(tex) end
    local atlas = SafeCall(owner, "GetAtlas")
    if issecretvalue and issecretvalue(atlas) then return "atlas:<SECRET:" .. type(atlas) .. ">" end
    if atlas ~= nil then return "atlas:" .. tostring(atlas) end
    return "nil"
end

local function SafeName(owner)
    if not owner then return "nil" end
    local name = SafeCall(owner, "GetName")
    if issecretvalue and issecretvalue(name) then return "<SECRET:" .. type(name) .. ">" end
    if name ~= nil then return tostring(name) end
    return tostring(owner)
end

local function FormatDebugIDList(ids)
    if type(ids) ~= "table" or #ids == 0 then return "nil" end
    local out = {}
    for i, id in ipairs(ids) do
        if issecretvalue and issecretvalue(id) then
            out[i] = "<SECRET:" .. type(id) .. ">"
        else
            out[i] = tostring(id)
        end
    end
    return table.concat(out, ",")
end

local function AddDebugLine(lines, ...)
    local out = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if issecretvalue and issecretvalue(value) then
            out[#out + 1] = "<SECRET:" .. type(value) .. ">"
        elseif value == nil then
            out[#out + 1] = "nil"
        else
            out[#out + 1] = tostring(value)
        end
    end
    lines[#lines + 1] = table.concat(out, " ")
end

local function SafeDebugScalar(value)
    if issecretvalue and issecretvalue(value) then
        return "<SECRET:" .. type(value) .. ">"
    end
    if value == nil then return "nil" end
    return value
end

function CDMBlizzMirror.GetChildDebugLines(cooldownID, viewerCategory)
    local lines = {}
    local function AddTextOwnerDebugLine(label, owner)
        if not owner then
            AddDebugLine(lines, "Text", label, "owner=nil")
            return
        end
        AddDebugLine(lines,
            "Text", label,
            "owner=", SafeName(owner),
            "type=", SafeDebugScalar(SafeCall(owner, "GetObjectType")),
            "shown=", SafeShown(owner),
            "decodedShown=", SafeFrameShownField(owner),
            "text=", SafeFieldText(owner))
    end

    local child = cooldownID and GetInstanceChild(cooldownID, viewerCategory)
    local state = PackState(cooldownID, viewerCategory)
    AddDebugLine(lines,
        "state cdID=", cooldownID,
        "cat=", state and state.viewerCategory,
        "active=", state and state.isActive,
        "durObj=", state and state.durObj,
        "hasInst=", state and state.hasAuraInstanceID,
        "auraUnit=", state and state.auraUnit,
        "epoch=", state and state.mirrorEpoch,
        "spell=", state and state.spellID,
        "ov=", state and state.overrideSpellID,
        "tooltip=", state and state.overrideTooltipSpellID,
        "links=", state and FormatDebugIDList(state.linkedSpellIDs),
        "totemSlot=", state and state.totemSlot,
        "totemSpellID=", state and state.totemSpellID)

    if not child then
        AddDebugLine(lines, "child=nil")
        return lines
    end

    AddDebugLine(lines,
        "child name=", SafeName(child),
        "shown=", SafeShown(child),
        "alpha=", SafeCall(child, "GetAlpha"),
        "cooldownID=", child.cooldownID,
        "wasSetFromAura=", SafeFrameBooleanField(child, "wasSetFromAura"),
        "parent=", SafeName(SafeCall(child, "GetParent")))
    AddDebugLine(lines,
        "child fields isActive=", SafeFrameBooleanField(child, "isActive"),
        "cooldownIsActive=", SafeFrameBooleanField(child, "cooldownIsActive"),
        "wasSetFromCooldown=", SafeFrameBooleanField(child, "wasSetFromCooldown"),
        "wasSetFromCharges=", SafeFrameBooleanField(child, "wasSetFromCharges"),
        "cooldownStart=", SafeFrameField(child, "cooldownStartTime"),
        "cooldownDuration=", SafeFrameField(child, "cooldownDuration"),
        "cooldownShowSwipe=", SafeFrameBooleanField(child, "cooldownShowSwipe"))
    AddDebugLine(lines,
        "child charge cooldownChargesShown=", SafeFrameBooleanField(child, "cooldownChargesShown"),
        "chargeCountFrameShown=", SafeFrameShownField(child.ChargeCount),
        "cooldownChargesCount=", RawFrameField(child, "cooldownChargesCount"),
        "stackText=", state and state.stackText,
        "stackSource=", state and state.stackTextSource,
        "stackShown=", state and state.stackTextShown,
        "stackEpoch=", state and state.stackTextEpoch)

    local childAuraData = ReadChildAuraData(child)
    AddDebugLine(lines,
        "child auraInstanceID=", SafeDebugScalar(SafeFrameField(child, "auraInstanceID")),
        "auraDataUnit=", SafeDebugScalar(SafeFrameField(child, "auraDataUnit")),
        "auraUnit=", SafeDebugScalar(SafeFrameField(child, "auraUnit")),
        "auraData.inst=", SafeDebugScalar(childAuraData and childAuraData.auraInstanceID),
        "auraData.spellId=", SafeDebugScalar(childAuraData and childAuraData.spellId),
        "auraData.spellID=", SafeDebugScalar(childAuraData and childAuraData.spellID),
        "auraData.name=", SafeDebugScalar(childAuraData and childAuraData.name))

    local icon = child.Icon
    AddDebugLine(lines,
        "Icon shown=", SafeShown(icon),
        "alpha=", SafeCall(icon, "GetAlpha"),
        "tex=", SafeTexture(icon),
        "parent=", SafeName(SafeCall(icon, "GetParent")))

    local cd = child.Cooldown
    local startMS, durationMS = SafeCall(cd, "GetCooldownTimes")
    AddDebugLine(lines,
        "Cooldown shown=", SafeShown(cd),
        "alpha=", SafeCall(cd, "GetAlpha"),
        "times=", startMS, "/", durationMS,
        "duration=", SafeCall(cd, "GetCooldownDuration"),
        "drawSwipe=", SafeCall(cd, "GetDrawSwipe"),
        "drawEdge=", SafeCall(cd, "GetDrawEdge"),
        "parent=", SafeName(SafeCall(cd, "GetParent")))

    AddDebugLine(lines,
        "DurationText shown=", SafeShown(FindFirstFontString(cd)),
        "text=", SafeFieldText(FindFirstFontString(cd)))

    local apps = child.Applications
    AddTextOwnerDebugLine("Applications", apps)
    AddTextOwnerDebugLine("Applications.Applications", apps and apps.Applications)
    AddTextOwnerDebugLine("Applications.DisplayText", apps and apps.DisplayText)
    AddTextOwnerDebugLine("Applications.FirstFontString", FindFirstFontString(apps))
    AddDebugLine(lines,
        "Applications shown=", SafeShown(apps),
        "text=", SafeFieldText(apps and (apps.Applications or FindFirstFontString(apps))),
        "parent=", SafeName(SafeCall(apps, "GetParent")))

    local charges = child.ChargeCount
    AddTextOwnerDebugLine("ChargeCount", charges)
    AddTextOwnerDebugLine("ChargeCount.Current", charges and charges.Current)
    AddTextOwnerDebugLine("ChargeCount.DisplayText", charges and charges.DisplayText)
    AddTextOwnerDebugLine("ChargeCount.FirstFontString", FindFirstFontString(charges))
    AddDebugLine(lines,
        "ChargeCount shown=", SafeShown(charges),
        "decodedShown=", SafeFrameShownField(charges),
        "text=", SafeFieldText(charges and (charges.Current or FindFirstFontString(charges))),
        "parent=", SafeName(SafeCall(charges, "GetParent")))

    AddTextOwnerDebugLine("Icon.Applications", icon and icon.Applications)
    AddTextOwnerDebugLine("Icon.DisplayText", icon and icon.DisplayText)

    local bar = child.Bar
    AddDebugLine(lines,
        "Bar shown=", SafeShown(bar),
        "value=", SafeCall(bar, "GetValue"),
        "parent=", SafeName(SafeCall(bar, "GetParent")))
    local barIcon = bar and bar.Icon
    AddTextOwnerDebugLine("Bar.Icon.Applications", barIcon and barIcon.Applications)
    AddTextOwnerDebugLine("Bar.Icon.DisplayText", barIcon and barIcon.DisplayText)

    AddTextOwnerDebugLine("Frame.DisplayText", child.DisplayText)
    AddTextOwnerDebugLine("Frame.Text", child.Text)
    AddTextOwnerDebugLine("Frame.Text.FirstFontString", FindFirstFontString(child.Text))
    AddTextOwnerDebugLine("Frame.Count", child.Count)
    AddTextOwnerDebugLine("Frame.StackText", child.StackText)
    AddTextOwnerDebugLine("Frame.Stacks", child.Stacks)

    return lines
end

function CDMBlizzMirror.GetCooldownMethodTestPayload(cooldownID, viewerCategory)
    local child = cooldownID and GetInstanceChild(cooldownID, viewerCategory)
    local key = cooldownID and ResolveInstanceKey(cooldownID, viewerCategory)
    local s = key and _mirrorState[key]
    if not child or not s then return nil end

    local state = PackState(cooldownID, viewerCategory)
    local icon = child.Icon
    local cd = child.Cooldown
    local childStartMS, childDurationMS = SafeCall(cd, "GetCooldownTimes")
    return {
        cooldownID = cooldownID,
        child = child,
        childCooldown = cd,
        state = state,
        iconTexture = SafeCall(icon, "GetTexture"),
        auraProbeLines = BuildAuraProbeLines(cooldownID, state and state.viewerCategory),
        childCooldownShown = SafeCall(cd, "IsShown"),
        childCooldownStartMS = childStartMS,
        childCooldownDurationMS = childDurationMS,
        childCooldownDurationValue = SafeCall(cd, "GetCooldownDuration"),

        auraDurObj = s.auraDurObj,
        auraDurObjSource = s.auraDurObjSource,
        totemDurObj = s.totemDurObj,
        totemDurObjSource = s.totemDurObjSource,
        lastCooldownSetter = s.lastCooldownSetter,

        setDurationObjectArg = s.lastDurationObjectArg,
        setDurationObjectClearIfZero = s.lastDurationObjectClearIfZero,

        setCooldownStart = s.lastSetCooldownStart or child.cooldownStartTime,
        setCooldownDuration = s.lastSetCooldownDuration or child.cooldownDuration,
        setCooldownModRate = s.lastSetCooldownModRate,

        setCooldownDurationOnly = s.lastSetCooldownDurationOnly
            or s.lastSetCooldownDuration
            or child.cooldownDuration,
        setCooldownDurationModRate = s.lastSetCooldownDurationModRate
            or s.lastSetCooldownModRate,

        setCooldownExpirationTime = s.lastSetCooldownExpirationTime,
        setCooldownExpirationDuration = s.lastSetCooldownExpirationDuration
            or s.lastSetCooldownDuration
            or child.cooldownDuration,
        setCooldownExpirationModRate = s.lastSetCooldownExpirationModRate
            or s.lastSetCooldownModRate,
    }
end
