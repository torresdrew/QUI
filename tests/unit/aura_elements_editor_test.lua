-- tests/unit/aura_elements_editor_test.lua
-- Run: lua tests/unit/aura_elements_editor_test.lua
--
-- Source-text pins for the shared aura element editor (Task 8): the GF auras
-- editor + spell list were moved into QUI_Options/ and generalized by a
-- capabilities table so unit frames / buff borders can share ONE editor. This
-- file is a headless WoW-frame builder, so we pin its contract by source text
-- rather than executing it.

local function read(p)
    local h = io.open(p, "rb")
    if not h then return nil end
    local s = h:read("*a")
    h:close()
    return s
end

local fails = 0
local function check(n, ok)
    if ok then print("  ok  " .. n) else fails = fails + 1; print("FAIL  " .. n) end
end

local EDITOR = "QUI_Options/aura_elements_editor.lua"
local SPELLLIST = "QUI_Options/aura_spell_list.lua"
local OLD_EDITOR = "QUI_GroupFrames/groupframes/settings/group_frames_auras_editor.lua"
local OLD_SPELLLIST = "QUI_GroupFrames/groupframes/settings/group_frames_spell_list.lua"

local editor = read(EDITOR)
local spelllist = read(SPELLLIST)

-- Files moved -------------------------------------------------------------
check("new editor exists at " .. EDITOR, editor ~= nil)
check("new spell list exists at " .. SPELLLIST, spelllist ~= nil)
check("old editor deleted", read(OLD_EDITOR) == nil)
check("old spell list deleted", read(OLD_SPELLLIST) == nil)

if not editor then
    print(("%d failures"):format(fails))
    os.exit(1)
end

-- Exports -----------------------------------------------------------------
check("editor exports ns.QUI_AuraElementsEditor", editor:find("ns.QUI_AuraElementsEditor", 1, true) ~= nil)
check("editor exports RenderAuras", editor:find("function AurasEditor.RenderAuras", 1, true) ~= nil)
check("spell list exports ns.QUI_AuraSpellList", spelllist:find("ns.QUI_AuraSpellList", 1, true) ~= nil)

-- Model import: core AuraElements, NOT the GF shim ------------------------
check("editor consumes ns.AuraElements", editor:find("ns.AuraElements", 1, true) ~= nil)
check("editor does NOT import the ns.QUI_GroupFramesAuraModel shim",
    editor:find("= ns.QUI_GroupFramesAuraModel", 1, true) == nil
    and editor:find("QUI_GroupFramesAuraModel.", 1, true) == nil)
check("editor consumes moved spell list ns.QUI_AuraSpellList",
    editor:find("ns.QUI_AuraSpellList", 1, true) ~= nil)

-- Capability gates present ------------------------------------------------
for _, gate in ipairs({
    "capabilities", "elementTypes", "trackedDisplayTypes",
    "maxStripElements", "cancelEligible", "allowSpecOverride",
    "defaultBucketFn",
}) do
    check("editor references capability field: " .. gate, editor:find(gate, 1, true) ~= nil)
end
check("editor reads caps.cancelEligible for the cancel toggle gate",
    editor:find("caps.cancelEligible", 1, true) ~= nil)
check("editor reads caps.allowSpecOverride to constrain the bucket",
    editor:find("caps.allowSpecOverride", 1, true) ~= nil)
check("editor counts against caps.maxStripElements",
    editor:find("caps.maxStripElements", 1, true) ~= nil)
check("editor gates the add menu on caps.elementTypes",
    editor:find("caps.elementTypes", 1, true) ~= nil or editor:find("elementTypes.filterStrip", 1, true) ~= nil)

-- EnsureSeeded threads defaultBucketFn (never the one-arg legacy form) -----
check("editor calls EnsureSeeded with the capability default bucket fn",
    editor:find("EnsureSeeded(auras, caps.defaultBucketFn)", 1, true) ~= nil)

-- New per-element controls write the right fields -------------------------
check("sort dropdown writes element.sortRule",
    editor:find("SORT_OPTIONS", 1, true) ~= nil and editor:find('"sortRule"', 1, true) ~= nil)
check("sort has a reverse toggle (sortReverse)", editor:find('"sortReverse"', 1, true) ~= nil)
check("right-click cancel toggle writes rightClickCancel",
    editor:find('"rightClickCancel"', 1, true) ~= nil)
check("filter mode gains the flags option", editor:find('"flags"', 1, true) ~= nil)
check("flags mode writes element.filterFlags", editor:find("element.filterFlags", 1, true) ~= nil)
check("filter mode uses the canonical classify value (not legacy classification)",
    editor:find('value = "classify"', 1, true) ~= nil)
check("shared text-region widgets factored (AddTextRegionWidgets)",
    editor:find("AddTextRegionWidgets", 1, true) ~= nil)
check("text region wires duration and stack sub-tables",
    editor:find('"duration"', 1, true) ~= nil and editor:find('"stack"', 1, true) ~= nil)

-- Tracked editor restoration ----------------------------------------------
check("tracked display type dropdown", editor:find('"displayType"', 1, true) ~= nil)
check("tracked builds display options from capabilities.trackedDisplayTypes",
    editor:find("BuildTrackedDisplayOptions", 1, true) ~= nil)
check("tracked Buff/Debuff dropdown writes element.auraType",
    editor:find('"auraType"', 1, true) ~= nil)
check("tracked bar sliders write element.bar.thickness / length",
    editor:find('"thickness"', 1, true) ~= nil and editor:find('"length"', 1, true) ~= nil
    and editor:find("element.bar", 1, true) ~= nil)
check("tracked spell list uses the moved CreateListFrame",
    editor:find("SpellList.CreateListFrame", 1, true) ~= nil)

-- Schema mount ------------------------------------------------------------
local schema = read("QUI_GroupFrames/groupframes/settings/group_frames_schema.lua")
check("schema resolves editor via ns.QUI_AuraElementsEditor",
    schema and schema:find("ns.QUI_AuraElementsEditor", 1, true) ~= nil)
check("schema no longer imports ns.QUI_GroupFramesAurasSettings",
    schema and schema:find("QUI_GroupFramesAurasSettings", 1, true) == nil)
check("schema passes capabilities.maxStripElements = 4",
    schema and schema:find("maxStripElements", 1, true) ~= nil and schema:find("= 4", 1, true) ~= nil)
check("schema passes defaultBucketFn = AuraDefaults.DefaultStripBucket",
    schema and schema:find("AuraDefaults.DefaultStripBucket", 1, true) ~= nil)
check("schema passes suggestions = AuraDefaults.GetSuggestionSpells",
    schema and schema:find("AuraDefaults.GetSuggestionSpells", 1, true) ~= nil)

-- TOC surgery -------------------------------------------------------------
local optsToc = read("QUI_Options/QUI_Options.toc")
local gfToc = read("QUI_GroupFrames/QUI_GroupFrames.toc")
check("QUI_Options.toc loads aura_spell_list.lua",
    optsToc and optsToc:find("aura_spell_list.lua", 1, true) ~= nil)
check("QUI_Options.toc loads aura_elements_editor.lua",
    optsToc and optsToc:find("aura_elements_editor.lua", 1, true) ~= nil)
check("QUI_Options.toc no longer loads the old GF editor path",
    optsToc and optsToc:find("group_frames_auras_editor.lua", 1, true) == nil)
check("QUI_Options.toc no longer loads the old GF spell-list path",
    optsToc and optsToc:find("group_frames_spell_list.lua", 1, true) == nil)
check("QUI_GroupFrames.toc does not reference the moved editor",
    gfToc and gfToc:find("group_frames_auras_editor.lua", 1, true) == nil)
check("QUI_GroupFrames.toc does not reference the moved spell list",
    gfToc and gfToc:find("group_frames_spell_list.lua", 1, true) == nil)

-- Task 9: UF + BB mounts -----------------------------------------------------
-- The unit-frames Icons tab and the action-bars Buff/Debuff tab replace their
-- old inline aura builders (which read flat auraDB/buffBorders keys migration
-- v50 pruned once elements shipped) with mounts of this same shared editor.
local ufSchema = read("QUI_UnitFrames/unitframes/settings/unit_frames_schema.lua")
local ufAuras = read("QUI_UnitFrames/unitframes/unitframe_auras.lua")
local bbContent = read("QUI_ActionBars/actionbars/settings/action_bars_buffdebuff_content.lua")
local bbAuras = read("QUI_ActionBars/actionbars/buffborders.lua")

check("UF schema mounts RenderAuras",
    ufSchema and ufSchema:find("AurasEditor.RenderAuras(editorHost, auraDB", 1, true) ~= nil)
check("UF mount offers tracked elements (tracked = true)",
    ufSchema and ufSchema:find("tracked = true", 1, true) ~= nil)
check("UF mount gates cancelEligible on unitKey == player",
    ufSchema and ufSchema:find('cancelEligible      = (unitKey == "player")', 1, true) ~= nil)
check("UF mount forces allowSpecOverride = false (no per-spec buckets on UF)",
    ufSchema and ufSchema:find("allowSpecOverride   = false", 1, true) ~= nil)
check("UF mount threads defaultBucketFn = ns.QUI_UnitFrameAuras.DefaultUnitAuraBucket",
    ufSchema and ufSchema:find("UnitFrameAuras.DefaultUnitAuraBucket", 1, true) ~= nil)
check("unitframe_auras.lua publishes ns.QUI_UnitFrameAuras.DefaultUnitAuraBucket",
    ufAuras and ufAuras:find("ns.QUI_UnitFrameAuras", 1, true) ~= nil
    and ufAuras:find("UnitFrameAuras.DefaultUnitAuraBucket = DefaultUnitAuraBucket", 1, true) ~= nil)

check("BB content mounts RenderAuras for buffAuras",
    bbContent and bbContent:find('AurasEditor.RenderAuras(editorHost, auras, "*"', 1, true) ~= nil
    and bbContent:find('"buffAuras"', 1, true) ~= nil)
check("BB content mounts RenderAuras for debuffAuras",
    bbContent and bbContent:find('"debuffAuras"', 1, true) ~= nil)
check("BB mounts are filterStrip-only (no tracked icons/squares/bars)",
    bbContent and bbContent:find("elementTypes      = { filterStrip = true }", 1, true) ~= nil
    and bbContent:find("tracked = true", 1, true) == nil)
check("BB debuff mount is cancelEligible = false (engine cancel is buff-only)",
    bbContent and bbContent:find("BB.DefaultDebuffBucket, false)", 1, true) ~= nil)
check("BB buff mount is cancelEligible = true",
    bbContent and bbContent:find("BB.DefaultBuffBucket, true)", 1, true) ~= nil)
check("buffborders.lua publishes ns.QUI_BuffBorders.DefaultBuffBucket/DefaultDebuffBucket",
    bbAuras and bbAuras:find("ns.QUI_BuffBorders", 1, true) ~= nil
    and bbAuras:find("BB.DefaultBuffBucket = DefaultBuffBucket", 1, true) ~= nil
    and bbAuras:find("BB.DefaultDebuffBucket = DefaultDebuffBucket", 1, true) ~= nil)

-- Frame-level BB toggles SURVIVED migration (Blizzard-frame banish gates the
-- runtime still reads: enableBuffs/enableDebuffs, hide*/fade*, iconSkin,
-- externalSkinning, borderSize, fontSize) — their rows must still exist.
check("BB keeps the enableBuffs row (frame-level gate, survived migration)",
    bbContent and bbContent:find('"enableBuffs"', 1, true) ~= nil)
check("BB keeps the enableDebuffs row (frame-level gate, survived migration)",
    bbContent and bbContent:find('"enableDebuffs"', 1, true) ~= nil)

-- Deleted per-strip dbKeys (pruned by migrations.lua's SeedAuraElements) must
-- not reappear in either settings file.
for _, deadKey in ipairs({ "buffIconSize", "debuffMaxIcons", "buffFilterPlayer" }) do
    check("dead dbKey removed from UF schema: " .. deadKey,
        ufSchema and ufSchema:find(deadKey, 1, true) == nil)
    check("dead dbKey removed from BB content: " .. deadKey,
        bbContent and bbContent:find(deadKey, 1, true) == nil)
end

if fails > 0 then
    print(("%d failures"):format(fails))
    os.exit(1)
end
print("aura_elements_editor_test: all checks passed")
