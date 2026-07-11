-- tests/unit/unitframe_auras_combat_mutable_test.lua
-- Run: lua tests/unit/unitframe_auras_combat_mutable_test.lua
--
-- Combat-mutation split for the per-element unit-frame aura containers.
-- Creation of a forbidden CustomAuraContainer (+ its AddAuraGroup/AddAuraSlot
-- button pooling) is combat-restricted (crashes the 12.1 client); MUTATION of a
-- pre-created one (SetUnit / filters / anchor / enable) is combat-legal.
-- UpdateAuras applies the mutation subset immediately (pcall-guarded) AND still
-- queues the full pass via the shared AuraGlue.QueueRegenWork queue so a wrong
-- PTR assumption self-heals at regen. This is the SAME split Task 4 landed for
-- group frames, with the unit-frame differences: corner-flip anchoring, a
-- player-only cancel-eligible gate, and per-polarity preview suppression.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_UnitFrames/unitframes/unitframe_auras.lua")

local function slice(marker)
    local startPos = src:find(marker, 1, true)
    assert(startPos, "missing: " .. marker)
    local endPos = src:find("\nend", startPos, true)
    assert(endPos, "unterminated function at: " .. marker)
    return src:sub(startPos, endPos)
end

-- ApplyElementPass: the single per-element pass, allowCreate-gated.
local pass = slice("local function ApplyElementPass(frame, allowCreate)")

-- Forbidden CREATION (container frame) is allowCreate AND OOC only.
assert(pass:find("if allowCreate and not InCombatLockdown() and CreateFrame then", 1, true),
    "container creation must be gated on allowCreate + not InCombatLockdown()")
assert(pass:find('CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")', 1, true),
    "creation uses the CustomAuraContainerTemplate")

-- Forbidden-frame SetPoint (anchor) is OOC only; SetUnit mutation is not.
local anchorGate = pass:find("if not InCombatLockdown() then", 1, true)
local anchorCall = pass:find("AnchorElementContainer(container, frame, element)", 1, true)
assert(anchorGate and anchorCall and anchorGate < anchorCall,
    "AnchorElementContainer (forbidden SetPoint) must be gated on not InCombatLockdown()")
assert(pass:find("container:SetUnit(QUI_UF.GetFrameUnit(frame))", 1, true),
    "SetUnit is combat-legal mutation and runs before the config/enable branch")

-- Group / slot reconcile flows through the shared core glue; the combat
-- pcall(Configure)/Restyle fallback lives INSIDE AuraGlue.RunConfigPass, so this
-- file just threads allowCreate through — it never pcalls Configure itself.
assert(pass:find("AuraGlue.RunConfigPass(container, profile, groups, allowCreate)", 1, true),
    "filter strips reconcile groups via AuraGlue.RunConfigPass(..., allowCreate)")
assert(pass:find("AuraGlue.ElementGroups(QUI_UF.GetFrameUnit(frame), element, profile, cancelEligible)", 1, true),
    "filter strips build descriptors via AuraGlue.ElementGroups with the cancel-eligible gate")
assert(pass:find("AuraSlots.Sync(container, element, allowCreate)", 1, true),
    "tracked elements reconcile slots via AuraSlots.Sync(..., allowCreate)")
assert(not pass:find("pcall(AuraSkin", 1, true),
    "the combat Configure guard lives in core (AuraGlue.RunConfigPass), not here")

-- UNIT-FRAME SPECIFICS ----------------------------------------------------------
-- cancel is player-unit only (HELPFUL strips) — AuraGlue.ElementGroups honors it.
assert(pass:find('local cancelEligible = (unitKey == "player")', 1, true),
    "right-click cancel is offered only on the player unit (cancelEligible gate)")
-- A previewed polarity keeps its element containers disabled + hidden so the
-- fake preview icons own the display (per-polarity suppression, not per-zone).
assert(pass:find("previewSuppressed", 1, true)
    and pass:find("buffPreviewActive", 1, true)
    and pass:find("debuffPreviewActive", 1, true),
    "a previewed polarity must suppress its matching-polarity element containers")

-- Skipped forbidden work queues a regen replay via the shared core queue.
assert(pass:find("AuraGlue.QueueRegenWork(frame, function(f) ApplyElementPass(f, true) end)", 1, true),
    "incomplete (forbidden work skipped in combat) must queue a regen replay via AuraGlue.QueueRegenWork")

-- UpdateAuras: combat = pcall'd mutable pass now + STILL queue.
local update = slice("local function UpdateAuras(frame)")
assert(update:find("InCombatLockdown()", 1, true), "UpdateAuras must branch on combat")
assert(update:find("pcall(ApplyElementPass, frame, false)", 1, true),
    "UpdateAuras must pcall the mutation-only pass immediately in combat")
assert(update:find("AuraGlue.QueueRegenWork(frame, function(f) ApplyElementPass(f, true) end)", 1, true),
    "UpdateAuras must STILL queue the full pass for regen (self-heal)")
assert(update:find("ApplyElementPass(frame, true)", 1, true),
    "UpdateAuras runs the full creating pass OOC")

-- Preview suppression rides the combat-aware full pass (the preview flag is set
-- by the caller before this runs; UpdateAuras handles the combat mutation +
-- queue), so it never touches a forbidden object directly in combat.
local suppress = slice("local function SuppressContainerForPreview(frame)")
assert(suppress:find("UpdateAuras(frame)", 1, true),
    "preview suppression delegates to the combat-aware UpdateAuras")

-- The public export names survive (callers in unitframes.lua depend on them).
assert(src:find("QUI_UF.ApplyContainerConfig = ApplyContainerConfig", 1, true),
    "QUI_UF.ApplyContainerConfig export must keep its name")
assert(src:find("QUI_UF.UpdateAuras = UpdateAuras", 1, true),
    "QUI_UF.UpdateAuras export must keep its name")

print("OK: unitframe_auras_combat_mutable_test")
