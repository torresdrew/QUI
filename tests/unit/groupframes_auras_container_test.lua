-- tests/unit/groupframes_auras_container_test.lua
-- Source-text assertion test for QUI_GroupFrames/groupframes/groupframes_auras.lua.
--
-- STEP D1a moved the generic buff/debuff STRIP display from the v46 element
-- engine to Blizzard's secure per-unit CustomAuraContainer (via QUI.AuraSkin).
-- The container is a forbidden, self-driving object that cannot be exercised
-- headless, so these source-text assertions pin the structural contract:
--   * each unit frame gets buff + debuff CustomAuraContainer zones,
--   * classification → AddAuraFilter, SetUnit, SetEnabled self-drive,
--   * the engine NO LONGER renders filterStrip elements (container's job) and
--     NO LONGER renders the dropped tracked icon/square/bar display,
--   * Missing Raid Buffs (missingRaidBuff) + the healthTint tint feeder STILL
--     flow through the (untouched) element renderer,
--   * forbidden-object work is combat-deferred to PLAYER_REGEN_ENABLED.
--
-- STEP D1b extends this with a conservative dead-code trim: the orphaned
-- Lua-side strip-filter primitives (AuraPassesSpellFilter / AuraPassesFilter /
-- GetAuraPriority) were removed from the engine file, while the renderer +
-- model square/bar paths were KEPT — they are still live via the layout-mode
-- preview driver (a second R.Dispatch consumer) and the aura editor.
-- Run: lua tests/unit/groupframes_auras_container_test.lua

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("QUI_GroupFrames/groupframes/groupframes_auras.lua")
local callSrc = readAll("QUI_GroupFrames/groupframes/groupframes.lua")

local fails = 0
local function check(name, ok)
    if ok then
        print("  ok  " .. name)
    else
        fails = fails + 1
        print("FAIL  " .. name)
    end
end

-- LIVE STRIP PATH: secure CustomAuraContainer + AuraSkin adapter --------------
check("creates CustomAuraContainerTemplate frames",
    src:find('"CustomAuraContainerTemplate"', 1, true) ~= nil)
check("resolves the QUI.AuraSkin adapter",
    src:find("QUI.AuraSkin", 1, true) ~= nil or src:find("ns.Addon.AuraSkin", 1, true) ~= nil)
check("calls AuraSkin.Attach to pool + theme container buttons",
    src:find("AuraSkin.Attach", 1, true) ~= nil)

-- Per-unit buff + debuff zones ------------------------------------------------
check("creates a per-unit buff container",
    src:find("frame.buffContainer", 1, true) ~= nil
    and src:find("CreateFrame(\"AuraContainer\", nil, frame, \"CustomAuraContainerTemplate\")", 1, true) ~= nil)
check("creates a per-unit debuff container",
    src:find("frame.debuffContainer", 1, true) ~= nil)

-- FILTERS / UNIT / ENABLE: container is told its filters, unit, and switched on
check("registers filters via container:AddAuraFilter(filterString, {})",
    src:find("AddAuraFilter", 1, true) ~= nil)
check("clears filters before re-adding (re-config)",
    src:find("ClearAuraFilters", 1, true) ~= nil)
check("HELPFUL strips → buff zone, HARMFUL strips → debuff zone",
    src:find('"HELPFUL"', 1, true) ~= nil and src:find('"HARMFUL"', 1, true) ~= nil)
check("calls container:SetUnit(frame.unit)",
    src:find("SetUnit(frame.unit)", 1, true) ~= nil)
check("calls container:SetEnabled to self-drive UNIT_AURA",
    src:find("SetEnabled(true)", 1, true) ~= nil and src:find("SetEnabled(false)", 1, true) ~= nil)

-- PUBLIC ENTRY NAMES the call sites in groupframes.lua depend on --------------
check("QUI_GFA.ApplyStripContainers exposed",
    src:find("QUI_GFA.ApplyStripContainers = ApplyStripContainers", 1, true) ~= nil)
check("QUI_GFA.UpdateStripContainers exposed",
    src:find("QUI_GFA.UpdateStripContainers = UpdateStripContainers", 1, true) ~= nil)
check("QUI_GFA.DisableStripContainers exposed (unit clear)",
    src:find("QUI_GFA.DisableStripContainers = DisableStripContainers", 1, true) ~= nil)
check("groupframes.lua wires UpdateStripContainers on unit assign",
    callSrc:find("UpdateStripContainers(", 1, true) ~= nil)
check("groupframes.lua wires DisableStripContainers on unit clear",
    callSrc:find("DisableStripContainers(", 1, true) ~= nil)

-- ENGINE NO LONGER RENDERS STRIPS / DROPPED TRACKED DISPLAY -------------------
-- The single gate the engine routes every element through.
check("EngineRendersElement gate defined + exported",
    src:find("local function EngineRendersElement", 1, true) ~= nil
    and src:find("QUI_GFA.EngineRendersElement = EngineRendersElement", 1, true) ~= nil)
-- The dead Lua-side strip match builder is gone (container filters C-side now).
check("BuildFilterStripMatches (strip Lua render path) removed",
    src:find("local function BuildFilterStripMatches", 1, true) == nil)
-- The renderer must no longer dispatch a filterStrip element.
check("RenderFrameElements no longer dispatches a filterStrip match build",
    src:find("BuildFilterStripMatches(frame.unit", 1, true) == nil)

-- MRB + TINT STILL FLOW THROUGH THE ELEMENT RENDERER (kept this step) ---------
check("missingRaidBuff handling still present in the render path",
    src:find('"missingRaidBuff"', 1, true) ~= nil
    and src:find("QUI_GroupFrameMissingRaidBuffs", 1, true) ~= nil
    and src:find("BuildMatches", 1, true) ~= nil)
check("healthTint tracked feeder kept in the engine gate",
    src:find('element.displayType == "healthTint"', 1, true) ~= nil)
check("RenderFrameElements still defined + exported (MRB + tint renderer)",
    src:find("QUI_GFA.RenderFrameElements = RenderFrameElements", 1, true) ~= nil)

-- COMBAT SAFETY: forbidden-object work deferred to PLAYER_REGEN_ENABLED -------
check("strip container setup guards on InCombatLockdown()",
    src:find("InCombatLockdown()", 1, true) ~= nil)
check("deferred container work replays on PLAYER_REGEN_ENABLED",
    src:find('"PLAYER_REGEN_ENABLED"', 1, true) ~= nil)
check("a combat-deferral queue exists for forbidden container work",
    src:find("QueueContainerCombatWork", 1, true) ~= nil)

-- The live strip container must NOT re-introduce a manual per-icon aura read
-- loop on this path — the whole point is no QUI Lua reading secret aura data.
check("strip container path adds no GetAuraDataByIndex poll",
    src:find("ApplyStripContainers", 1, true) ~= nil
    and src:find("C_UnitAuras.GetAuraDataByIndex", 1, true) == nil)

-- STEP D1b: DEAD-CODE TRIM (engine-only) -------------------------------------
-- D1b removed the last orphaned Lua-side strip-filter primitives from the
-- engine file. These had ZERO callers across QUI_GroupFrames/ after the D1a
-- cutover (the live strip filters C-side in the container). Pin their removal.
check("D1b: AuraPassesSpellFilter (whitelist/blacklist) removed",
    src:find("local function AuraPassesSpellFilter", 1, true) == nil)
check("D1b: AuraPassesFilter (inline classification query) removed",
    src:find("local function AuraPassesFilter", 1, true) == nil)
check("D1b: GetAuraPriority + PRIORITY_* sort constants removed",
    src:find("local function GetAuraPriority", 1, true) == nil
    and src:find("PRIORITY_DISPELLABLE", 1, true) == nil)
-- KEPT: the classification maps still feed the secure container's C-side filter
-- build (CONTAINER_*_CLASS_MAP → BuildZoneFilters), so they must survive D1b.
check("D1b: BUFF/DEBUFF_CLASSIFICATION_MAP kept (container filter source)",
    src:find("BUFF_CLASSIFICATION_MAP", 1, true) ~= nil
    and src:find("DEBUFF_CLASSIFICATION_MAP", 1, true) ~= nil
    and src:find("CONTAINER_BUFF_CLASS_MAP", 1, true) ~= nil)

-- STEP D1b: ENTANGLEMENT — renderer/model square+bar paths are NOT dead -------
-- The runtime engine gate (EngineRendersElement) only governs the in-combat
-- render path. The layout-mode PREVIEW DRIVER (group_frames_preview_driver.lua)
-- is a SECOND live consumer of R.Dispatch that renders EVERY element type —
-- filterStrip, tracked icon/square/bar, MRB — so the renderer's RenderSquare /
-- RenderBar / Dispatch-filterStrip paths and the model's NewFilterStripElement /
-- NewTrackedElement constructors (also used by the editor) are LIVE, not dead.
-- D1b therefore deliberately left aura_render.lua + aura_model.lua untouched.
-- These assertions guard that the live preview paths were NOT mistakenly trimmed.
local renderSrc = readAll("QUI_GroupFrames/groupframes/groupframes_aura_render.lua")
local modelSrc  = readAll("QUI_GroupFrames/groupframes/groupframes_aura_model.lua")
local previewSrc = readAll("QUI_GroupFrames/groupframes/settings/group_frames_preview_driver.lua")
check("D1b: preview driver still dispatches every element type via R.Dispatch",
    previewSrc:find("Render:Dispatch(f, element, matches)", 1, true) ~= nil
    and previewSrc:find('element.mode == "filterStrip"', 1, true) ~= nil)
check("D1b: R.RenderSquare KEPT (live via preview tracked-square)",
    renderSrc:find("function R.RenderSquare", 1, true) ~= nil)
check("D1b: R.RenderBar KEPT (live via preview tracked-bar)",
    renderSrc:find("function R.RenderBar", 1, true) ~= nil)
check("D1b: R.RenderIcon + R.RenderHealthTint + R.Dispatch KEPT",
    renderSrc:find("function R.RenderIcon", 1, true) ~= nil
    and renderSrc:find("function R.RenderHealthTint", 1, true) ~= nil
    and renderSrc:find("function R.SyncHealthBarTint", 1, true) ~= nil
    and renderSrc:find("function R.Dispatch", 1, true) ~= nil)
check("D1b: model NewFilterStripElement + NewTrackedElement KEPT (editor uses them)",
    modelSrc:find("function Model.NewFilterStripElement", 1, true) ~= nil
    and modelSrc:find("function Model.NewTrackedElement", 1, true) ~= nil
    and modelSrc:find("function Model.NewMissingRaidBuffElement", 1, true) ~= nil)
check("D1b: model DISPLAY_TYPES square/bar/icon KEPT (editor + Validate)",
    modelSrc:find("square = true", 1, true) ~= nil
    and modelSrc:find("bar = true", 1, true) ~= nil
    and modelSrc:find("icon = true", 1, true) ~= nil)

if fails > 0 then error(fails .. " failure(s) in groupframes_auras_container_test") end
print("OK: groupframes_auras_container_test (" .. "all checks passed)")
