-- tests/unit/cdm_debug_cdtest_details_test.lua
-- Run: lua tests/unit/cdm_debug_cdtest_details_test.lua

SlashCmdList = {}
UIParent = {}
GetTime = function() return 1 end

function strtrim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local secretShown = { token = "shown" }
local secretText = { token = "text" }

function issecretvalue(value)
    return value == secretShown or value == secretText
end

C_CurveUtil = {
    EvaluateColorValueFromBoolean = function()
        error("cdtest must not decode secret booleans through C_CurveUtil in Lua")
    end,
}

C_StringUtil = {
    WrapString = function(value, prefix, suffix)
        if issecretvalue(value) then
            return (prefix or "") .. "<wrapped-secret>" .. (suffix or "")
        end
        return (prefix or "") .. tostring(value) .. (suffix or "")
    end,
}

local lines = {}
local originalPrint = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    lines[#lines + 1] = table.concat(parts, " ")
end

DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, message)
        lines[#lines + 1] = tostring(message)
    end,
}

local function newObject(objectType)
    local object = {
        _objectType = objectType or "Frame",
        _shown = true,
        _text = nil,
    }
    function object:SetSize() end
    function object:SetPoint() end
    function object:SetFrameStrata() end
    function object:EnableMouse() end
    function object:SetMovable() end
    function object:RegisterForDrag() end
    function object:SetScript() end
    function object:StartMoving() end
    function object:StopMovingOrSizing() end
    function object:SetAllPoints() end
    function object:SetColorTexture() end
    function object:SetTexture(value) self.texture = value end
    function object:SetDrawSwipe(value) self.drawSwipe = value end
    function object:GetDrawSwipe() return self.drawSwipe end
    function object:SetDrawEdge(value) self.drawEdge = value end
    function object:GetDrawEdge() return self.drawEdge end
    function object:Clear() self.cleared = true end
    function object:SetReverse(value) self.reverse = value end
    function object:SetCooldownFromDurationObject(value, clear) self.durationObject = value; self.clear = clear end
    function object:SetCooldown(startTime, duration, modRate) self.start = startTime; self.duration = duration; self.modRate = modRate end
    function object:SetCooldownDuration(duration, modRate) self.durationOnly = duration; self.durationModRate = modRate end
    function object:SetCooldownFromExpirationTime(expiration, duration, modRate) self.expiration = expiration; self.expirationDuration = duration; self.expirationModRate = modRate end
    function object:GetCooldownTimes() return 0, 0 end
    function object:GetCooldownDuration() return 0 end
    function object:CreateTexture() return newObject("Texture") end
    function object:CreateFontString() return newObject("FontString") end
    function object:SetText(value) self._text = value end
    function object:GetText() return self._text end
    function object:Show() self._shown = true end
    function object:Hide() self._shown = false end
    function object:IsShown() return self._shown end
    function object:GetObjectType() return self._objectType end
    function object:SetJustifyH() end
    function object:SetWidth() end
    function object:SetMultiLine() end
    function object:SetMaxLetters() end
    function object:SetFontObject() end
    function object:SetAutoFocus() end
    function object:ClearFocus() end
    function object:SetScrollChild(child) self.child = child end
    function object:GetVerticalScrollRange() return 0 end
    function object:SetVerticalScroll() end
    function object:GetNumRegions() return self._regions and #self._regions or 0 end
    function object:GetRegions()
        if self._regions then
            return unpack(self._regions)
        end
        return nil
    end
    function object:GetNumChildren() return self._children and #self._children or 0 end
    function object:GetChildren()
        if self._children then
            return unpack(self._children)
        end
        return nil
    end
    return object
end

function CreateFrame(frameType)
    return newObject(frameType or "Frame")
end

local function fontString(text, shown)
    local fs = newObject("FontString")
    fs._text = text
    fs._shown = shown
    return fs
end

local chargeCurrent = fontString(secretText, secretShown)
function chargeCurrent:IsShown() return secretShown end

local chargeCount = newObject("Frame")
chargeCount.Current = chargeCurrent
function chargeCount:IsShown() return secretShown end

local applicationsText = fontString("4", true)
local applications = newObject("Frame")
applications.Applications = applicationsText
applications.DisplayText = applicationsText
applications._regions = { applicationsText }

local childCooldown = newObject("Cooldown")
function childCooldown:IsShown() return secretShown end

local child = newObject("Frame")
child.Applications = applications
child.ChargeCount = chargeCount
child.Cooldown = childCooldown
child.Icon = newObject("Texture")
child.Icon.GetTexture = function() return 237530 end

local iconStackText = fontString("4", secretShown)
function iconStackText:IsShown() return secretShown end

local icon = {
    _runtimeSpellID = 55090,
    _blizzMirrorCooldownID = 27928,
    _blizzMirrorCategory = "essential",
    _stackTextSource = "Applications",
    _lastMirrorStackTextEpoch = 17,
    _resolvedCooldownMode = "cooldown",
    StackText = iconStackText,
    stackText = secretText,
    stackTextSource = "ChargeCount",
    stackTextShown = secretShown,
    stackTextEpoch = 17,
    cooldownChargesCount = secretText,
    cooldownChargesShown = secretShown,
    chargeCountFrameShown = secretShown,
    chargeTextOwnerShown = secretShown,
    _spellEntry = {
        name = "Scourge Strike",
        id = 27928,
        spellID = 55090,
        overrideSpellID = 55090,
        viewerType = "essential",
        kind = "cooldown",
        type = "spell",
        hasCharges = false,
    },
    IsShown = function() return true end,
}

local state = {
    viewerCategory = "essential",
    isActive = true,
    spellID = 55090,
    overrideSpellID = 55090,
    hasAura = false,
    selfAura = false,
    charges = false,
    hasAuraInstanceID = false,
    stackText = secretText,
    stackTextSource = "ChargeCount",
    stackTextShown = secretShown,
    stackTextEpoch = 17,
    cooldownChargesCount = secretText,
    cooldownChargesShown = secretShown,
    chargeCountFrameShown = secretShown,
    chargeTextOwnerShown = secretShown,
}

local ns = {
    CDMIcons = {},
    CDMIconFactory = {
        _iconPools = {
            essential = { icon },
        },
    },
    CDMBlizzMirror = {
        BindNewChildren = function() end,
        GetCooldownMethodTestPayload = function(cooldownID, category)
            assert(cooldownID == 27928, "unexpected cooldownID")
            assert(category == "essential", "category should be passed through")
            return {
                cooldownID = cooldownID,
                child = child,
                childCooldown = childCooldown,
                state = state,
                iconTexture = 237530,
                auraProbeLines = { "auraProbe ok" },
                childCooldownShown = secretShown,
                childCooldownStartMS = 0,
                childCooldownDurationMS = 0,
                childCooldownDurationValue = 0,
                setCooldownStart = 0,
                setCooldownDuration = 0,
                setCooldownDurationOnly = 0,
                setCooldownExpirationTime = 0,
                setCooldownExpirationDuration = 0,
            }
        end,
    },
    CDMResolvers = {
        IsAuraEntry = function() return false end,
        ResolveCooldownState = function()
            return {
                mode = "cooldown",
                active = true,
                isActive = true,
                auraActive = true,
                isOnCooldown = false,
                hasCharges = false,
                rechargeActive = false,
                hasChargesRemaining = true,
                count = {
                    shown = true,
                    value = 4,
                    sinkText = "4",
                    source = "Applications",
                },
                countSinkText = "4",
            }
        end,
    },
    CDMAuraRuntime = {
        ResolveAbilityAuraSpellID = function()
            return 194310, true
        end,
        ResolveState = function()
            return {
                isActive = true,
                auraUnit = "target",
                auraInstanceID = 42,
                resolvedAuraSpellID = 194310,
                hasExpirationTime = false,
                count = {
                    shown = true,
                    value = 4,
                    sinkText = "4",
                    source = "Applications",
                },
                auraData = {
                    applications = 4,
                    spellId = 194310,
                    name = "Festering Wound",
                },
            }
        end,
    },
    CDMSources = {
        QuerySpellCooldown = function()
            return { isActive = secretShown, isOnGCD = false, startTime = 0, duration = 0, modRate = 1 }
        end,
        QuerySpellCharges = function()
            return { currentCharges = secretText, maxCharges = 2, isActive = secretShown, cooldownStartTime = 0, cooldownDuration = 0 }
        end,
        QuerySpellDisplayCount = function()
            return secretText
        end,
        QuerySpellCount = function()
            return 4
        end,
        QuerySpellUsable = function()
            return secretShown, false
        end,
    },
}

assert(loadfile("QUI_Debug/cdm_debug.lua"))("QUI_Debug", ns)
SlashCmdList["QUI_CDMDEBUG"]("cdtest 27928 essential")

print = originalPrint
local output = table.concat(lines, "\n")

assert(output:find("ChargeCount.Current shown= <SECRET:table>", 1, true),
    "cdtest should preserve secret text shown-state")
assert(output:find("mirrorStack", 1, true), "cdtest should include mirror stack fields")
assert(output:find("chargeCountFrameShown= <SECRET:table>", 1, true),
    "cdtest should preserve mirrored charge frame shown-state as secret")
assert(output:find("chargeTextOwnerShown= <SECRET:table>", 1, true),
    "cdtest should preserve mirrored charge text-owner shown-state as secret")
assert(output:find("icon#1 resolverCount", 1, true),
    "cdtest should include resolver count details")
assert(output:find("icon#1 iconStack", 1, true)
    and output:find("cooldownChargesShown= <SECRET:table>", 1, true),
    "cdtest should include mirrored icon charge show-state")
assert(output:find("countSink= 4", 1, true),
    "cdtest should include aura application count sink")
assert(output:find("chargesApi", 1, true),
    "cdtest should include charge API details")
assert(output:find("displayCountApi <SECRET:table>", 1, true),
    "cdtest should preserve secret display counts as opaque values")

originalPrint("OK: cdm_debug_cdtest_details_test")
