-- tests/unit/tooltip_unit_aura_forbidden_probe_test.lua
-- Run: lua tests/unit/tooltip_unit_aura_forbidden_probe_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function assertContains(text, needle, reason)
    assert(text:find(needle, 1, true), reason)
end

local function assertOrder(text, first, second, reason)
    local firstIndex = assert(text:find(first, 1, true), "missing first marker: " .. first)
    local secondIndex = assert(text:find(second, 1, true), "missing second marker: " .. second)
    assert(firstIndex < secondIndex, reason)
end

local tooltipSkin = readFile("QUI_UI/skinning/system/tooltips.lua")
local tooltipQOL = readFile("QUI_UI/qol/tooltip.lua")

assertContains(tooltipSkin, "local auraTooltipType = Enum.TooltipDataType.UnitAura or Enum.TooltipDataType.Aura",
    "tooltip skinning must resolve the aura tooltip type with a client-version fallback")

assertContains(tooltipSkin, "TooltipDataProcessor.AddTooltipPostCall(auraTooltipType, RunHandlePostCall)",
    "tooltip skinning must subscribe to UnitAura post-calls so normal aura tooltips get QUI chrome")

assertContains(tooltipSkin, "local function HandleForbiddenAuraTooltip(tooltip)",
    "tooltip skinning must isolate forbidden AuraButtonTooltip probing in a dedicated helper")

assertContains(tooltipSkin, "if IsProtectedTooltip(tooltip) then",
    "tooltip post-call handling must check forbidden/protected tooltip owner chains")

local postCallBody = assert(tooltipSkin:match("local function HandlePostCall%(tooltip%)%s*(.-)%s*local function RunHandlePostCall"),
    "tooltip skinning must define HandlePostCall before RunHandlePostCall")

assertOrder(
    postCallBody,
    "if IsProtectedTooltip(tooltip) then",
    "SafeHookTooltipOnShow(tooltip)",
    "forbidden/protected aura tooltip checks must run before installing Show/NineSlice hooks")

assertContains(tooltipSkin, "dbg.tryAuraButtonTooltipSkin == true",
    "AuraButtonTooltip skinning attempts must be opt-in through tooltip debug state")

assertContains(tooltipSkin, "pcall(ApplyTooltipChrome, tooltip)",
    "AuraButtonTooltip experiments must be pcall-guarded")

assertContains(tooltipSkin, "TooltipDebugCount(\"skin.auraButtonTooltipForbidden\")",
    "forbidden AuraButtonTooltip encounters must be visible in tooltip debug counters")

assertContains(tooltipSkin, "PrivateAurasTooltipMixin",
    "AuraButtonTooltip probing must hook the real PrivateAurasTooltipMixin boundary")

assertContains(tooltipSkin, "hooksecurefunc(PrivateAurasTooltipMixin, \"ShowAuraTooltip\"",
    "AuraButtonTooltip probing must observe ShowAuraTooltip directly when TooltipDataProcessor is silent")

assertContains(tooltipSkin, "SetupAuraTooltipProbeHook()\n        QueueExtraTooltipDiscovery()",
    "AuraButtonTooltip probe hook must retry on ADDON_LOADED in case Blizzard loads the mixin late")

assertContains(tooltipSkin, "ns.QUI_GetAuraTooltipProbeStatus = function()",
    "tooltip skinning must expose AuraButtonTooltip probe install status")

assertContains(tooltipQOL, "subcmd == \"auratip\"",
    "tooltip debug command must expose an AuraButtonTooltip probe toggle")

assertContains(tooltipQOL, "ns.QUI_GetAuraTooltipProbeStatus",
    "tooltip debug auratip command must print skin-module probe status")

assertContains(tooltipQOL, "self.tryAuraButtonTooltipSkin = enabled",
    "tooltip debug AuraButtonTooltip probe must set the shared debug flag used by the skinner")

local function makeFrame(name)
    local frame = {
        name = name,
        shown = false,
        scripts = {},
        events = {},
    }

    function frame:GetName() return self.name end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:SetScript(scriptName, handler) self.scripts[scriptName] = handler end
    function frame:IsShown() return self.shown end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:SetAllPoints() self.allPoints = true end
    function frame:EnableMouse() end
    function frame:SetFrameLevel(level) self.frameLevel = level end
    function frame:SetFrameStrata(strata) self.frameStrata = strata end
    function frame:GetWidth() return 200 end
    function frame:GetHeight() return 80 end
    function frame:GetFrameLevel() return 10 end
    function frame:GetFrameStrata() return "TOOLTIP" end
    function frame:GetObjectType() return self.objectType or "GameTooltip" end
    function frame:GetOwner() return self.owner end
    function frame:GetParent() return self.parent end
    function frame:IsForbidden() return self.forbidden == true end
    function frame:IsProtected() return self.protected == true end

    return frame
end

local function makeFontObject(path, size, flags)
    local fontObject = { path = path, size = size, flags = flags }
    function fontObject:GetFont() return self.path, self.size, self.flags end
    function fontObject:SetFont(pathArg, sizeArg, flagsArg)
        self.path = pathArg
        self.size = sizeArg
        self.flags = flagsArg
    end
    return fontObject
end

local eventFrame
local hookedShows = {}
local methodHooks = {}
local callbacks = {}
local createdStyleFrames = {}
local debugCounts = {}

_G.UIParent = makeFrame("UIParent")
_G.WorldFrame = makeFrame("WorldFrame")
_G.GameTooltip = makeFrame("GameTooltip")
_G.GameTooltip.shown = true
_G.GameTooltipHeaderText = makeFontObject("Fonts\\FRIZQT__.TTF", 14, "")
_G.GameTooltipText = makeFontObject("Fonts\\FRIZQT__.TTF", 12, "")
_G.InCombatLockdown = function() return false end
_G.issecretvalue = function() return false end
_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
_G.ADDON_LOADED = "ADDON_LOADED"
_G.CreateFrame = function(_, name, parent)
    local frame = makeFrame(name)
    frame.parent = parent
    if not eventFrame then eventFrame = frame end
    createdStyleFrames[#createdStyleFrames + 1] = frame
    return frame
end
_G.C_Timer = { After = function(_, callback) callback() end }
_G.hooksecurefunc = function(target, methodName, callback)
    if type(target) == "table" and type(methodName) == "string" and type(callback) == "function" then
        methodHooks[target] = methodHooks[target] or {}
        methodHooks[target][methodName] = callback
    end
    if methodName == "Show" then
        hookedShows[target] = (hookedShows[target] or 0) + 1
    end
end
_G.wipe = function(tbl)
    for key in pairs(tbl) do tbl[key] = nil end
end
_G.Enum = {
    TooltipDataType = {
        Item = 1,
        Spell = 2,
        Unit = 3,
        UnitAura = 4,
    },
}
_G.PrivateAurasTooltipMixin = {
    ShowAuraTooltip = function() end,
}
_G.TooltipDataProcessor = {
    AddTooltipPostCall = function(tooltipType, callback)
        callbacks[tooltipType] = callback
    end,
}

local ns = {
    Helpers = {
        GetCore = function()
            return {
                db = { profile = { tooltip = {
                    enabled = true, skinTooltips = true, fontSize = 13,
                } } },
            }
        end,
        CreateStateTable = function() return setmetatable({}, { __mode = "k" }) end,
        FrameIsProtected = function(frame)
            return frame and frame.protected == true
        end,
        GetSkinBorderColor = function() return 1, 1, 1, 1 end,
        GetSkinBgColor = function() return 0, 0, 0, 1 end,
        GetGeneralFont = function() return "Fonts\\FRIZQT__.TTF" end,
        GetGeneralFontOutline = function() return "OUTLINE" end,
        IsSecretValue = function() return false end,
    },
    QUI_TooltipDebug = {
        enabled = true,
        Count = function(_, name, amount)
            debugCounts[name] = (debugCounts[name] or 0) + (amount or 1)
        end,
        Begin = function() return nil, nil end,
        End = function() end,
    },
    SkinBase = {
        SkinFrameText = function() end,
    },
    UIKit = {
        CreateBackground = function() return { SetVertexColor = function() end } end,
        CreateBorderLines = function() end,
        UpdateBorderLines = function() end,
    },
    WhenLoggedIn = function(fn) fn() end,
}

assert(loadfile("QUI_UI/skinning/system/tooltips.lua"))("QUI", ns)
local auraPostCall = assert(callbacks[Enum.TooltipDataType.UnitAura],
    "tooltip skinning must register a UnitAura TooltipDataProcessor callback")

local normalTooltip = makeFrame("NormalAuraTooltip")
auraPostCall(normalTooltip)
assert(hookedShows[normalTooltip] == 1,
    "normal UnitAura tooltip should install the standard tooltip Show hook")

local protectedOwner = makeFrame("ProtectedOwner")
protectedOwner.protected = true
local protectedTooltip = makeFrame("ProtectedAuraTooltip")
protectedTooltip.owner = protectedOwner

auraPostCall(protectedTooltip)
assert(hookedShows[protectedTooltip] == nil,
    "protected-owner UnitAura tooltip must return before installing Show/NineSlice hooks")

local auraTooltipHook = assert(methodHooks[PrivateAurasTooltipMixin]
        and methodHooks[PrivateAurasTooltipMixin].ShowAuraTooltip,
    "tooltip skinning must hook PrivateAurasTooltipMixin:ShowAuraTooltip for AuraButtonTooltip diagnostics")

local auraButtonTooltip = makeFrame("AuraButtonTooltip")
auraButtonTooltip.forbidden = true
auraTooltipHook(auraButtonTooltip, "player", { auraInstanceID = 1 })

assert(debugCounts["skin.auraButtonTooltipForbidden"] == 1,
    "ShowAuraTooltip hook should count forbidden AuraButtonTooltip even when TooltipDataProcessor is silent")

local status = assert(ns.QUI_GetAuraTooltipProbeStatus and ns.QUI_GetAuraTooltipProbeStatus(),
    "tooltip skinning must expose AuraButtonTooltip probe status at runtime")
assert(status.skinningLoaded == true, "probe status should report the skinning module as loaded")
assert(status.mixinVisible == true, "probe status should report PrivateAurasTooltipMixin visibility")
assert(status.showAuraTooltipVisible == true, "probe status should report ShowAuraTooltip visibility")
assert(status.hookInstalled == true, "probe status should report the direct ShowAuraTooltip hook is installed")
assert(status.observedTooltips == 1, "probe status should count observed AuraButtonTooltip invocations")

print("OK: tooltip_unit_aura_forbidden_probe_test")
