-- core/aura_glue.lua — QUI.AuraGlue: the ONE copy of the settings→container
-- runtime glue shared by buffborders, unit frames and group frames.
-- Element (core/aura_elements.lua) → AuraSkin profile + group descriptors →
-- AuraSkin.Configure/Restyle, plus the shared combat-regen replay queue.
-- Loadable headless: no top-level frame creation, engine enums read lazily.
local ADDON_NAME, ns = ...
local G = ns.AuraGlue or {}
ns.AuraGlue = G
_G.QUI = _G.QUI or {}
_G.QUI.AuraGlue = G

local E -- ns.AuraElements, resolved lazily (TOC order guarantees it, but stay defensive)
local AuraSkin

-- Resolved separately, not as one joint gate: ElementGroups only ever reads
-- E (AuraElements) and RunConfigPass only ever reads AuraSkin. A shared
-- gate that required both would make ElementGroups depend on AuraSkin being
-- loaded too — AuraSkin needs the live secure button template and is never
-- loaded in the headless test harness, so that would silently break
-- ElementGroups there despite it having no actual AuraSkin dependency.
local function ResolveE()
    E = E or ns.AuraElements
    return E
end

local function ResolveAuraSkin()
    AuraSkin = AuraSkin or (ns.Addon and ns.Addon.AuraSkin) or (_G.QUI and _G.QUI.AuraSkin)
    return AuraSkin
end

-- Settings sort keys → AuraContainerSortMethod (plain global, verified
-- Blizzard_AuraContainerShared.lua:46; no Index member exists — INDEX maps to
-- Default). Read lazily so the file loads headless before enum stubs exist.
local function SortMethodFor(rule)
    local M = _G.AuraContainerSortMethod
    if not M then return 0 end
    local map = {
        INDEX = M.Default, DEFAULT = M.Default,
        EXPIRY = M.Expiration, EXPIRY_ONLY = M.ExpirationOnly,
        NAME = M.Name, NAME_ONLY = M.NameOnly,
        BIG_DEFENSIVE = M.BigDefensive,
        IMPORTANT_ONLY = M.ImportantOnly, UF_DEBUFF = M.UnitFrameDebuff,
    }
    return map[rule or "INDEX"] or M.Default
end

local function SortDirectionFor(reverse)
    local D = _G.AuraContainerSortDirection
    if not D then return reverse and 1 or 0 end
    return reverse and D.Reverse or D.Normal
end

-- Map one element onto the AuraSkin layout-profile contract (aura_skin.lua
-- ResolveLayout). Wrap axis derives from the element's anchor corner: a
-- BOTTOM-corner strip grows its extra rows UPWARD, away from the pinned edge.
-- `overrides` (optional) lets a surface adjust attachPoint/wrap/offsets — the
-- unit-frame corner flip passes the vertically-flipped attachPoint here.
function G.ElementProfile(element, overrides)
    local anchor = element.anchor or "TOPLEFT"
    local maxIcons = element.maxIcons or 0
    if maxIcons <= 0 then maxIcons = 40 end   -- 0 = "unlimited"; engine needs a number
    local p = {
        maxIcons     = maxIcons,
        iconSize     = (element.iconSize and element.iconSize > 0) and element.iconSize or 22,
        spacing      = element.spacing or 2,
        grow         = element.growDirection or "RIGHT",
        maxPerRow    = element.iconsPerRow or 0,
        offsetX      = element.offsetX or 0,
        offsetY      = element.offsetY or 0,
        anchor       = anchor,
        wrap         = (anchor:find("BOTTOM", 1, true) and "UP" or "DOWN"),
        borderSize   = element.borderSize or 1,
        fontSize     = (element.duration and element.duration.fontSize) or 9,
        hideSwipe    = element.hideSwipe or false,
        reverseSwipe = element.reverseSwipe or false,
        swipeStyle   = element.swipeStyle or "radial",
        duration     = element.duration,
        stack        = element.stack,
    }
    if overrides then
        for k, v in pairs(overrides) do p[k] = v end
    end
    return p
end

-- AuraSkin.Configure's AddAuraGroup registers eagerly, and a polarity-invalid
-- AuraFilters combo HARD-ERRORS inside the secure dirty pass, poisoning the
-- group (registration inserts the filter BEFORE the throwing call, so pcall
-- would strand it). Pre-validate every string with our own insecure
-- GetUnitAuras and only hand accepted strings to the container.
-- The C-side probe alone is NOT sufficient: the C parser tolerates unknown
-- components (e.g. "HARMFUL|modifiers") that the container's Lua-side
-- AuraUtil.IsValidFilterString assert rejects inside AddAuraGroup — check
-- both.
function G.FilterStringUsable(unit, filterString)
    local AU = _G.AuraUtil
    if AU and AU.IsValidFilterString and not AU.IsValidFilterString(filterString) then
        return false
    end
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuras) then return true end
    return (pcall(C_UnitAuras.GetUnitAuras, unit, filterString))
end

-- One enabled filterStrip element → the group descriptor array for ITS OWN
-- container. classify-mode strips fan out one group per usable classification
-- string; off/whitelist strips ride the bare polarity (per-spell restriction
-- travels in candidateFilters). Guarantees at least one group so an element
-- never silently renders nothing. Cancel: engine-side right-click cancel is
-- only offered on cancel-eligible hosts (player-unit) for HELPFUL strips,
-- honoring the per-element opt-out.
function G.ElementGroups(unit, element, profile, cancelEligible)
    if not ResolveE() then return {} end
    local base = element.auraType or "HELPFUL"
    local strings = E.CompileFilters(element)
    local usable = {}
    for i = 1, #strings do
        if G.FilterStringUsable(unit, strings[i]) then
            usable[#usable + 1] = strings[i]
        end
    end
    if #usable == 0 then usable[1] = base end
    local cf = E.CompileCandidateFilters(element)
    local sortMethod = SortMethodFor(element.sortRule)
    local sortDirection = SortDirectionFor(element.sortReverse == true)
    local cancel
    if cancelEligible and base == "HELPFUL" and element.rightClickCancel ~= false then
        cancel = "RightButtonUp"
    end
    local groups = {}
    for i = 1, #usable do
        groups[i] = {
            key              = "s" .. i,
            filter           = usable[i],
            maxFrameCount    = profile.maxIcons,
            sortMethod       = sortMethod,
            sortDirection    = sortDirection,
            candidateFilters = cf,
            cancelButtons    = cancel,
        }
    end
    return groups
end

-- The ONE combat-aware Configure wrapper (previously copy-pasted in every
-- surface): OOC configures directly; in combat Configure is pcall-guarded
-- (group mutation may be restricted; new keys are skipped inside AuraSkin)
-- with the always-combat-legal Restyle as fallback.
function G.RunConfigPass(container, profile, groups, allowCreate)
    if not ResolveAuraSkin() then return false end
    if allowCreate then
        AuraSkin.Configure(container, profile, groups)
        return true
    end
    local ok = pcall(AuraSkin.Configure, container, profile, groups)
    if not ok then
        AuraSkin.Restyle(container, profile)
    end
    return ok
end

-- Shared combat-regen replay queue. Owners (frames/hosts) register a
-- replay closure; each owner holds at most ONE pending closure (last write
-- wins — the closure re-derives everything from settings at fire time).
-- Fires once at PLAYER_REGEN_ENABLED; immediate execution when OOC.
local _pending = {}
local _regenFrame
local function EnsureRegenFrame()
    if _regenFrame or not CreateFrame then return end
    _regenFrame = CreateFrame("Frame")
    _regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    _regenFrame:SetScript("OnEvent", function()
        local run = _pending
        _pending = {}
        for owner, fn in pairs(run) do
            local ok, err = pcall(fn, owner)
            if not ok then
                (ns.DebugPrint or print)("QUI AuraGlue regen replay error: " .. tostring(err))
            end
        end
    end)
end

function G.QueueRegenWork(owner, fn)
    if not InCombatLockdown or not InCombatLockdown() then
        fn(owner)
        return
    end
    EnsureRegenFrame()
    _pending[owner] = fn
end

return G
