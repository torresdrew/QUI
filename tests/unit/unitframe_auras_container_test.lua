-- tests/unit/unitframe_auras_container_test.lua
-- Source-text assertion test for QUI_UnitFrames/unitframes/unitframe_auras.lua.
--
-- The unit-frame aura LIVE display was cut over to Blizzard's secure
-- CustomAuraContainer (via QUI.AuraSkin).  The container is a forbidden,
-- self-driving object that cannot be exercised headless, so these source-text
-- assertions pin the structural contract:
--   * live path uses the secure container template + AuraSkin adapter,
--   * classification filters map onto the container's AddAuraFilter API,
--   * the public entry names callers depend on still exist,
--   * the layout-mode preview renderer is preserved,
--   * forbidden-object work is combat-deferred.
-- Run: lua tests/unit/unitframe_auras_container_test.lua

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    data = data:gsub("\r\n", "\n")
    return data
end

local src = readAll("QUI_UnitFrames/unitframes/unitframe_auras.lua")

-- LIVE PATH: secure CustomAuraContainer + AuraSkin adapter --------------------
assert(src:find('"CustomAuraContainerTemplate"', 1, true),
    "live path must create CustomAuraContainerTemplate frames")
assert(src:find("QUI.AuraSkin", 1, true) or src:find("ns.Addon.AuraSkin", 1, true),
    "live path must resolve the QUI.AuraSkin adapter")
assert(src:find("AuraSkin.Attach", 1, true),
    "live path must call AuraSkin.Attach to pool + theme container buttons")

-- FILTERS: classification filters map onto the container's AddAuraFilter -------
assert(src:find("AddAuraFilter", 1, true),
    "live path must register filters via container:AddAuraFilter")
assert(src:find("ClearAuraFilters", 1, true),
    "live path must clear filters before re-adding (re-config)")
assert(src:find("BuildClassificationFilters", 1, true),
    "classification-derived filter strings must still feed the container")
assert(src:find("BUFF_CLASSIFICATION_MAP", 1, true)
    and src:find("DEBUFF_CLASSIFICATION_MAP", 1, true),
    "both buff and debuff classification maps must be consulted")

-- UNIT + ENABLE: container is told its unit and switched on --------------------
assert(src:find("SetUnit", 1, true),
    "live path must call container:SetUnit(frame.unit)")
assert(src:find("SetEnabled", 1, true),
    "live path must call container:SetEnabled to self-drive UNIT_AURA")

-- PUBLIC ENTRY NAMES preserved (callers in unitframes.lua depend on these) -----
assert(src:find("QUI_UF.UpdateAuras = UpdateAuras", 1, true),
    "QUI_UF.UpdateAuras must remain exposed")
assert(src:find("QUI_UF.SetupAuraTracking = SetupAuraTracking", 1, true),
    "QUI_UF.SetupAuraTracking must remain exposed")
assert(src:find("function QUI_UF:ShowAuraPreview(", 1, true),
    "QUI_UF:ShowAuraPreview must remain defined")
assert(src:find("function QUI_UF:ShowAuraPreviewForFrame(", 1, true),
    "QUI_UF:ShowAuraPreviewForFrame must remain defined")
assert(src:find("function QUI_UF:HideAuraPreview(", 1, true),
    "QUI_UF:HideAuraPreview must remain defined")
assert(src:find("function QUI_UF:HideAuraPreviewForFrame(", 1, true),
    "QUI_UF:HideAuraPreviewForFrame must remain defined")

-- DEAD ICON FACTORY removed (preview is self-contained; factory was cutover) -----
assert(not src:find("local function CreateAuraIcon(", 1, true),
    "dead factory CreateAuraIcon must be absent after cutover")
assert(not src:find("local function GetAuraIcon(", 1, true),
    "dead factory GetAuraIcon must be absent after cutover")
assert(not src:find("local function ApplyAuraIconSettings(", 1, true),
    "dead factory ApplyAuraIconSettings must be absent after cutover")
-- Preview must suppress the live container so fake icons render alone.
assert(src:find("SuppressContainerForPreview", 1, true),
    "preview must disable the live container while showing fake icons")

-- COMBAT SAFETY: forbidden-object work is deferred to PLAYER_REGEN_ENABLED -----
assert(src:find("InCombatLockdown", 1, true),
    "container setup must guard on InCombatLockdown()")
assert(src:find('"PLAYER_REGEN_ENABLED"', 1, true),
    "deferred container work must replay on PLAYER_REGEN_ENABLED")

-- The live container display must NOT re-introduce a manual per-icon aura read
-- loop (the whole point of the cutover is no QUI Lua reading secret aura data).
assert(not src:find("C_UnitAuras.GetAuraDataByIndex", 1, true),
    "live path must not poll C_UnitAuras.GetAuraDataByIndex (container self-drives)")

print("OK: unitframe_auras_container_test")
