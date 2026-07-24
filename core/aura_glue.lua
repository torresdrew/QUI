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
-- Blizzard_AuraContainerShared.lua:41; the 68914 re-patch added
-- AuraInstanceIDOnly = 8 — INDEX finally maps to real insertion-order
-- semantics, with Default as the pre-re-patch fallback). Read lazily so
-- the file loads headless before enum stubs exist.
local function SortMethodFor(rule)
    local M = _G.AuraContainerSortMethod
    if not M then return 0 end
    local map = {
        INDEX = M.AuraInstanceIDOnly or M.Default, DEFAULT = M.Default,
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
        -- Optional per-element static border override; absent = theme color
        -- (aura_skin styleButton falls back to AuraTheme.BorderColor). The
        -- seeded GF "defensives" strip ships green through this field.
        borderColor  = element.borderColor,
        -- Optional per-element dispel-type border palette; absent = engine
        -- default dispel colors (aura_skin buildButtonArt only sets
        -- customDispelColorMap when this is a table). No UI exposure yet
        -- (task 10) -- this is the passthrough pin so a future writer isn't
        -- silently dropped before it ever reaches the runtime.
        dispelColors = element.dispelColors,
        -- PTR7 per-button tooltip controls (aura_skin styleButton applies
        -- them feature-detected). Same passthrough-pin rationale as
        -- dispelColors: no UI exposure yet, but a future writer must not be
        -- silently dropped before reaching the runtime.
        tooltipAnchor       = element.tooltipAnchor,
        tooltipAnchorX      = element.tooltipAnchorX,
        tooltipAnchorY      = element.tooltipAnchorY,
        tooltipHideInCombat = element.tooltipHideInCombat,
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
-- Probe verdicts are a property of the STRING (the unit only matters for
-- access), so they're cached for the session. The cache is only written
-- while aura access is unrestricted: GetUnitAuras carries
-- RequiresUnitAuraAccess (FailureMode=Error), so under encounter/M+/PvP
-- restrictions the pcall fails for EVERY string — reading that as "invalid
-- filter" would retire valid classified groups mid-pull and broaden their
-- replacements to bare polarity. When restricted with no cached verdict,
-- fail OPEN: the string already passed IsValidFilterString above, and every
-- QUI-compiled string is token-validated at compile time.
local probeVerdict = {}

function G.FilterStringUsable(unit, filterString)
    local AU = _G.AuraUtil
    if AU and AU.IsValidFilterString and not AU.IsValidFilterString(filterString) then
        return false
    end
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuras) then return true end
    local cached = probeVerdict[filterString]
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        -- Restricted: the probe can't run (every call fails), so trust any
        -- cached verdict — including false: handing a C-rejected string to
        -- AddAuraGroup would hard-error inside the secure dirty pass and
        -- poison the group. Uncached fails OPEN (string already passed
        -- IsValidFilterString above).
        if cached ~= nil then return cached end
        return true
    end
    -- Unrestricted: acceptance is permanent, but a cached REJECTION is
    -- re-verified — a rejection should be a deterministic C-parser verdict,
    -- yet a failure we can't positively attribute must not permanently
    -- retire a string on the strength of one probe (compiles are OOC-rare,
    -- so the re-probe is cheap).
    if cached == true then return true end
    local ok = (pcall(C_UnitAuras.GetUnitAuras, unit, filterString))
    if ok then
        probeVerdict[filterString] = true
        return true
    end
    -- Failure attribution: GetUnitAuras can fail for reasons other than the
    -- filter string (a restriction racing in after the ShouldAurasBeSecret
    -- check above, a transient unit problem). Re-probe with the bare
    -- polarity baseline — always C-valid — as the discriminator: if the
    -- baseline ALSO fails, the environment is unusable, so fail OPEN
    -- WITHOUT caching (the string already passed IsValidFilterString, and
    -- an uncached miss gets a clean re-probe later — caching false here
    -- would retire a valid group if restrictions begin before the next
    -- unrestricted probe).
    local baselineOk = (pcall(C_UnitAuras.GetUnitAuras, unit, "HELPFUL"))
    if not baselineOk then return true end
    -- Baseline healthy: retry the candidate ONCE before caching a rejection.
    -- The environment can recover between the two probes (a restriction
    -- window closing after the candidate failed but before the baseline
    -- ran) — a one-shot failure in that gap must not become a cached false
    -- that the restricted branch later trusts for the whole encounter. A
    -- deterministic C-parser rejection fails the retry identically.
    ok = (pcall(C_UnitAuras.GetUnitAuras, unit, filterString))
    probeVerdict[filterString] = ok
    return ok
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
    -- Canonicalize BEFORE the validity probe and BEFORE the string leaves
    -- this function: this is the group descriptor's "storage" — every
    -- caller (core/aura_skin.lua Configure) derives its registry key from
    -- g.filter, so canonicalizing here guarantees semantically-equal
    -- filters collapse onto the same key at the source, not just at the
    -- key-derivation choke point (which ALSO canonicalizes defensively —
    -- see AuraSkin.Configure). CanonicalizeFilterString is idempotent, so
    -- double-canonicalizing here + there is a cheap no-op, never a bug.
    for i = 1, #strings do
        local canonical = E.CanonicalizeFilterString and E.CanonicalizeFilterString(strings[i]) or strings[i]
        if G.FilterStringUsable(unit, canonical) then
            usable[#usable + 1] = canonical
        end
    end
    if #usable == 0 then
        usable[1] = (E.CanonicalizeFilterString and E.CanonicalizeFilterString(base)) or base
    end
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
    local ok = ns.SafeCall("chain-next", AuraSkin.Configure, container, profile, groups)
    if not ok then
        AuraSkin.Restyle(container, profile)
    end
    return ok
end

-- Shared combat/restriction replay queue. Owners (frames/hosts) register a
-- replay closure; each owner holds at most ONE pending closure (last write
-- wins — the closure re-derives everything from settings at fire time).
-- Fires only when BOTH blockers are clear: combat lockdown
-- (PLAYER_REGEN_ENABLED) AND the 12.1 aura restriction. 68675 AuraButton
-- children carry DenyTaintedAccessWhenAurasAreSecret (the provider applies
-- it immediately after initializeFrame), so a replay that styles children
-- while ShouldAurasBeSecret() hard-errors — regen alone is NOT a
-- sufficient fire signal: restrictions have no end event and are not
-- combat-lockdown-coupled. While work is pending and the restriction is
-- up, a short C_Timer poll re-checks until it clears (poll runs ONLY while
-- something is queued).
local _pending = {}
local _regenFrame
local _pollArmed = false

local function AurasAreSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

local FlushPending

local function ArmRestrictionPoll()
    if _pollArmed then return end
    local After = C_Timer and C_Timer.After
    if not After then return end
    _pollArmed = true
    After(0.5, function()
        _pollArmed = false
        FlushPending()
    end)
end

FlushPending = function()
    if next(_pending) == nil then return end
    if (InCombatLockdown and InCombatLockdown()) or AurasAreSecret() then
        ArmRestrictionPoll()
        return
    end
    local run = _pending
    _pending = {}
    for owner, fn in pairs(run) do
        -- ns.SafeCall's bulkhead policy probes err for secrecy BEFORE any
        -- tostring/format and already reports+dedups via the classified
        -- error handler; the manual tostring(err) forward this replaced
        -- skipped that probe (err here can carry aura/secret payload).
        ns.SafeCall("bulkhead", fn, owner)
    end
end

local function EnsureRegenFrame()
    if _regenFrame or not CreateFrame then return end
    _regenFrame = CreateFrame("Frame")
    _regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    _regenFrame:SetScript("OnEvent", FlushPending)
end

function G.QueueRegenWork(owner, fn)
    if (not InCombatLockdown or not InCombatLockdown()) and not AurasAreSecret() then
        fn(owner)
        return
    end
    EnsureRegenFrame()
    _pending[owner] = fn
    -- Combat end fires the regen event; a restriction active WITHOUT combat
    -- lockdown (or outliving it) has no event — poll until it clears.
    if not (InCombatLockdown and InCombatLockdown()) then
        ArmRestrictionPoll()
    end
end

return G
