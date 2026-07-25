-- tests/unit/groupframes_preview_driver_test.lua
-- Run: lua tests/unit/groupframes_preview_driver_test.lua
-- The driver DEFINES functions that call WoW API but never at file scope, so it
-- loads with a fresh ns. Only the pure helpers are exercised here.
local ns = {}
assert(loadfile("QUI_GroupFrames/groupframes/settings/group_frames_preview_driver.lua"))("QUI_Options", ns)
local D = ns.QUI_GroupFramesPreview
local function test(n, f) print(n); f(); print("  ok") end
-- (The _BuildFilterStripMatches / _BuildTrackedMatches fake-match fabricators
-- were removed in Task 10 — filterStrip + tracked icon/square/bar previews now
-- render through the shared ns.AuraPreview placeholder renderer. That renderer's
-- coverage lives in tests/unit/aura_preview_test.lua; MRB fabrication is still
-- exercised via the live GF render tests.)

test("party grid: 5 units stack downward (grow DOWN), single column", function()
    local p = D._ComputeGridPositions("party", 5, { growDirection = "DOWN", spacing = 2 }, 100, 20)
    assert(#p == 5)
    assert(p[1].x == 0 and p[1].y == 0)
    assert(p[2].x == 0 and p[2].y == -(20 + 2))
    assert(p[5].y == -4 * (20 + 2))
end)

test("party grid: grow RIGHT lays units along +x", function()
    local p = D._ComputeGridPositions("party", 3, { growDirection = "RIGHT", spacing = 4 }, 100, 20)
    assert(p[1].x == 0 and p[2].x == (100 + 4) and p[3].x == 2 * (100 + 4))
    assert(p[1].y == 0 and p[2].y == 0)
end)

test("raid grouped: 10 units = 2 columns of 5 (vertical, groupGrow RIGHT)", function()
    local p = D._ComputeGridPositions("raid", 10,
        { growDirection = "DOWN", groupGrowDirection = "RIGHT", groupBy = "GROUP",
          spacing = 1, groupSpacing = 10 }, 80, 16)
    assert(p[1].x == 0 and p[5].x == 0)
    assert(p[6].x == (80 + 10) and p[6].y == 0)
    assert(p[2].y == -(16 + 1))
end)

test("raid flat (groupBy NONE) wraps by unitsPerFlat using spacing as colSpacing", function()
    local p = D._ComputeGridPositions("raid", 6,
        { growDirection = "DOWN", groupGrowDirection = "RIGHT", groupBy = "NONE",
          unitsPerFlat = 3, spacing = 2 }, 80, 16)
    assert(p[3].x == 0 and p[4].x == (80 + 2))
end)

test("roster has the requested count and stable fields", function()
    local r = D._BuildRoster("raid", 25)
    assert(#r == 25)
    for i = 1, 25 do
        assert(type(r[i].name) == "string" and r[i].name ~= "")
        assert(type(r[i].class) == "string")
        assert(r[i].role == "TANK" or r[i].role == "HEALER" or r[i].role == "DAMAGER")
        assert(type(r[i].healthPct) == "number")
    end
end)

test("roster is deterministic", function()
    local a = D._BuildRoster("party", 5)
    local b = D._BuildRoster("party", 5)
    for i = 1, 5 do assert(a[i].name == b[i].name and a[i].class == b[i].class) end
end)

test("raid snap: exact tiers pass through", function()
    assert(D._SnapRaidCount(5) == 5)
    assert(D._SnapRaidCount(20) == 20)
    assert(D._SnapRaidCount(40) == 40)
end)

test("raid snap: clamps below 5 and above 40", function()
    assert(D._SnapRaidCount(1) == 5)
    assert(D._SnapRaidCount(0) == 5)
    assert(D._SnapRaidCount(99) == 40)
    assert(D._SnapRaidCount(nil) == 25)   -- default when unset
end)

test("raid snap: rounds to nearest tier, ties round up", function()
    assert(D._SnapRaidCount(7) == 5)
    assert(D._SnapRaidCount(8) == 10)
    assert(D._SnapRaidCount(35) == 35)   -- 35 is a tier now: slider value renders 1:1
    assert(D._SnapRaidCount(33) == 35)   -- nearest multiple of 5
    assert(D._SnapRaidCount(32) == 30)   -- rounds down
    assert(D._SnapRaidCount(37) == 35)   -- |37-35|=2 < |37-40|=3
end)

test("filter normalize: nil yields all-true defaults", function()
    local fset = D._NormalizeFilter(nil)
    for _, k in ipairs({
        "threat", "dispel", "auras", "indicators", "targetedSpells",
        "targetHighlight", "pets", "range",
    }) do
        assert(fset[k] == true, "expected default true for " .. k)
    end
end)

test("filter normalize: explicit false preserved, unknown keys dropped", function()
    local fset = D._NormalizeFilter({
        threat = false,
        targetHighlight = false,
        pets = false,
        range = false,
        highlights = false,
        bogus = true,
    })
    assert(fset.threat == false)
    assert(fset.targetHighlight == false)
    assert(fset.pets == false)
    assert(fset.range == false)
    assert(fset.highlights == nil, "retired ambiguous key must be dropped")
    assert(fset.dispel == true)
    assert(fset.bogus == nil, "unknown key must be dropped")
end)

test("filter allows: missing/true -> allowed, false -> denied", function()
    assert(D._FilterAllows({ threat = false }, "threat") == false)
    assert(D._FilterAllows({ threat = false }, "auras") == true)
    assert(D._FilterAllows(nil, "auras") == true)
end)

test("chip enabled: threat default-on unless explicit false", function()
    assert(D._ChipEnabledInConfig({ indicators = {} }, "threat") == true)
    assert(D._ChipEnabledInConfig({ indicators = { showThreatBorder = false } }, "threat") == false)
end)

test("chip enabled: dispel requires cfg.enabled ~= false", function()
    assert(D._ChipEnabledInConfig({ healer = { dispelOverlay = { enabled = true } } }, "dispel") == true)
    assert(D._ChipEnabledInConfig({ healer = { dispelOverlay = { enabled = false } } }, "dispel") == false)
    assert(D._ChipEnabledInConfig({ healer = {} }, "dispel") == false)
    assert(D._ChipEnabledInConfig({
        healer = {
            dispelOverlay = { enabled = false },
            cleanseGlow = { enabled = true },
        },
    }, "dispel") == true, "glow-only config still has a useful Dispel chip")
end)

test("chip enabled: auras requires enabled ~= false", function()
    assert(D._ChipEnabledInConfig({ auras = { enabled = true } }, "auras") == true)
    assert(D._ChipEnabledInConfig({ auras = { enabled = false } }, "auras") == false)
    assert(D._ChipEnabledInConfig({}, "auras") == false)
end)

test("chip enabled: indicators true if ANY corner icon on", function()
    assert(D._ChipEnabledInConfig({ indicators = { showLeaderIcon = true } }, "indicators") == true)
    assert(D._ChipEnabledInConfig({ indicators = {} }, "indicators") == false)
end)

test("chip enabled: targeted spells have an explicit focus chip", function()
    assert(D._ChipEnabledInConfig(
        { targetedSpells = { enabled = true } }, "targetedSpells") == true)
    assert(D._ChipEnabledInConfig(
        { targetedSpells = { enabled = false } }, "targetedSpells") == false)
    assert(D._ChipEnabledInConfig({}, "targetedSpells") == false)
end)

test("chip enabled: target, pet and range samples are independently mapped", function()
    local cfg = {
        healer = { targetHighlight = { enabled = true } },
        pets = { enabled = true },
        range = { enabled = true },
    }
    assert(D._ChipEnabledInConfig(cfg, "targetHighlight") == true)
    assert(D._ChipEnabledInConfig(cfg, "pets") == true)
    assert(D._ChipEnabledInConfig(cfg, "range") == true)
    assert(D._ChipEnabledInConfig({}, "targetHighlight") == false)
    assert(D._ChipEnabledInConfig({}, "pets") == false)
    assert(D._ChipEnabledInConfig({}, "range") == false)
end)

test("disabling Target Highlight leaves name, level and health text visible", function()
    local function TextRegion()
        return {
            Hide = function(self) self.shown = false end,
            Show = function(self) self.shown = true end,
            SetText = function(self, text) self.text = text end,
            SetTextColor = function() end,
        }
    end
    local frame = {
        nameText = TextRegion(),
        levelText = TextRegion(),
        healthText = TextRegion(),
        healthBar = {
            SetMinMaxValues = function() end,
            SetValue = function() end,
            SetStatusBarColor = function() end,
        },
        SetAlpha = function(self, alpha) self.alpha = alpha end,
    }
    ns.QUI_GroupFrameChrome = {
        Apply = function() end,
        ResizeHealthForPower = function() end,
    }
    D._state.filter = D._NormalizeFilter({ targetHighlight = false })
    D._ApplyFrameSettings(frame, {
        name = "Preview", level = 80, role = "HEALER", class = "PRIEST", healthPct = 75,
    }, {
        general = {},
        power = { showPowerBar = false },
        name = { showName = true, showLevel = true },
        health = { showHealthText = true },
        indicators = {},
    }, {}, "party")
    assert(frame.nameText.shown == true and frame.nameText.text == "Preview")
    assert(frame.levelText.shown == true and frame.levelText.text == "80")
    assert(frame.healthText.shown == true and frame.healthText.text == "75%")
end)

test("aura focus filter selects the configured table only while enabled", function()
    local configured = { enabled = true }
    local vdb = { auras = configured }
    assert(D._AuraSettingsForFilter(vdb, { auras = true }) == configured)
    assert(D._AuraSettingsForFilter(vdb, nil) == configured)
    assert(D._AuraSettingsForFilter(vdb, { auras = false }) == nil)
end)

test("aura renderer toggle reaches show and complete hide/release paths", function()
    local calls = { show = 0, hide = 0, releaseAll = 0 }
    ns.QUI_GroupFrameAuraRender = {
        ReleaseAll = function(_, frame)
            assert(frame.previewUnit == "unit")
            calls.releaseAll = calls.releaseAll + 1
        end,
        Dispatch = function() error("empty fixture must not dispatch") end,
    }
    ns.QUI_GroupFramesAuraModel = {
        EnsureSeeded = function() end,
        ActiveElementsForSpec = function() return {} end,
    }
    ns.QUI_GroupFrameAuras = { EngineRendersElement = function() return false end }
    ns.AuraPreview = {
        Show = function(host, elements)
            assert(host.kind == "auraHost")
            assert(#elements == 0)
            calls.show = calls.show + 1
        end,
        Hide = function(host)
            assert(host.kind == "auraHost")
            calls.hide = calls.hide + 1
        end,
    }
    local frame = { previewUnit = "unit", _auraHost = { kind = "auraHost" } }
    D._RenderFrameAuras(frame, { enabled = true }, 0)
    D._RenderFrameAuras(frame, nil, 0)
    assert(calls.show == 1, "enabled Aura chip renders preview elements")
    assert(calls.hide == 1, "disabled Aura chip hides placeholder elements")
    assert(calls.releaseAll == 1, "disabled Aura chip releases renderer-owned elements")
end)

test("surface labels every single-tile sample with an independent control", function()
    local file = assert(io.open(
        "QUI_GroupFrames/groupframes/settings/group_frames_surface.lua", "r"))
    local source = file:read("*a")
    file:close()
    assert(source:find('{ key = "targetedSpells", label = ns.L["Targeted Spells"] }',
        1, true), "missing Targeted Spells preview chip")
    assert(source:find("card.AddRow(cells.targetedSpells, cells.targetHighlight)",
        1, true), "Targeted Spells / Target Highlight row is missing")
    assert(source:find("card.AddRow(cells.pets, cells.range)",
        1, true), "Pet Frames / Range Fade row is missing")
    assert(not source:find('{ key = "highlights"', 1, true),
        "ambiguous Highlights preview control must not return")

    local driverFile = assert(io.open(
        "QUI_GroupFrames/groupframes/settings/group_frames_preview_driver.lua", "r"))
    local driverSource = driverFile:read("*a")
    driverFile:close()
    assert(driverSource:find("F.targetHighlight ~= false", 1, true))
    assert(driverSource:find("F.pets ~= false", 1, true))
    assert(driverSource:find("F.range ~= false", 1, true))
    assert(not driverSource:find("F.highlights", 1, true))
end)

test("aura placeholder host rides the shared live container level (frame+11)", function()
    -- Filter strips and tracked icon/square/bar are drawn LIVE by a secure
    -- CustomAuraContainer the engine fills; the preview stands in for them with
    -- placeholders, which must sit where those containers sit (frame+11 host,
    -- frame+12 child/bar) -- above the chrome text frame.
    assert(D._AuraHostLevel(0) == 11)
    assert(D._AuraHostLevel(100) == 111)
    local frameLevel, healthBarLevel = 0, 1
    assert(D._AuraHostLevel(frameLevel) > healthBarLevel + 4)
end)

test("party roster reflects show-player, hide-DPS, role sort and self pin", function()
    local filtered = D._PrepareRoster("party", 5, {
        showPlayer = false, hideDPS = true,
    }, {})
    assert(#filtered == 1 and filtered[1].role == "HEALER")

    local sorted = D._PrepareRoster("party", 5, {
        sortMethod = "NAME",
    }, { partySelfFirst = true })
    assert(sorted[1].isSelf == true, "self-first survives name sorting")
end)

test("pet sample uses the outer edge when its anchor follows party growth", function()
    assert(D._EdgeSampleIndex(5, "DOWN", "BOTTOM") == 5)
    assert(D._EdgeSampleIndex(5, "UP", "TOP") == 5)
    assert(D._EdgeSampleIndex(5, "RIGHT", "RIGHT") == 5)
    assert(D._EdgeSampleIndex(5, "LEFT", "LEFT") == 5)
    assert(D._EdgeSampleIndex(5, "DOWN", "TOP") == 1)
    assert(D._EdgeSampleIndex(5, "DOWN", "RIGHT") == 1)

    local roster = D._BuildRoster("party", 5)
    D._AssignSampleFlags(roster, 5, { pets = { anchorTo = "BOTTOM" } },
        { growDirection = "DOWN" })
    assert(roster[1]._sampleTarget == true)
    assert(roster[1]._samplePet == nil)
    assert(roster[5]._samplePet == true,
        "bottom pet belongs on the last tile of a downward party")
end)

test("spotlight layout reflects horizontal and vertical orientation", function()
    local x, y = D._SpotlightOffset(3, 100, 20, 2, "HORIZONTAL", "RIGHT")
    assert(x == 204 and y == 0)
    local ux, uy = D._SpotlightOffset(3, 100, 20, 2, "VERTICAL", "UP")
    assert(ux == 0 and uy == 44)
end)

test("spotlight frames are pooled across refreshes", function()
    local file = assert(io.open(
        "QUI_GroupFrames/groupframes/settings/group_frames_preview_driver.lua", "r"))
    local source = file:read("*a")
    file:close()
    assert(source:find("local f = state.spotlightPool[i]", 1, true))
    assert(source:find("state.spotlightPool[i] = f", 1, true))
    assert(source:find("if state.spotlightPool then", 1, true))
    assert(source:find("state.spotlightPool = {}", 1, true),
        "teardown must release the complete Spotlight pool")
end)

test("party target companion uses all four live anchor mappings and gap", function()
    local frame = {
        ClearAllPoints = function(self) self.point = nil end,
        SetPoint = function(self, ...) self.point = { ... } end,
    }
    local member = {}
    D._ApplyCompanionAnchor(frame, member, { anchorTo = "RIGHT", anchorGap = 7 })
    assert(frame.point[1] == "LEFT" and frame.point[3] == "RIGHT" and frame.point[4] == 7)
    D._ApplyCompanionAnchor(frame, member, { anchorTo = "LEFT", anchorGap = 5 })
    assert(frame.point[1] == "RIGHT" and frame.point[3] == "LEFT" and frame.point[4] == -5)
    D._ApplyCompanionAnchor(frame, member, { anchorTo = "TOP", anchorGap = 3 })
    assert(frame.point[1] == "BOTTOM" and frame.point[3] == "TOP" and frame.point[5] == 3)
    D._ApplyCompanionAnchor(frame, member, { anchorTo = "BOTTOM", anchorGap = 4 })
    assert(frame.point[1] == "TOP" and frame.point[3] == "BOTTOM" and frame.point[5] == -4)
end)

test("dispel sample renders cleanse glow even with border disabled", function()
    local function TextRegion()
        return {
            Hide = function(self) self.shown = false end,
            Show = function(self) self.shown = true end,
            SetText = function(self, text) self.text = text end,
            SetTextColor = function() end,
        }
    end
    local glow = TextRegion()
    glow.tex = { SetVertexColor = function(self, ...) self.vertex = { ... } end }
    local frame = {
        nameText = TextRegion(), levelText = TextRegion(), healthText = TextRegion(),
        healthBar = {
            SetMinMaxValues = function() end, SetValue = function() end,
            SetStatusBarColor = function() end,
        },
        cleanseGlow = glow,
        SetAlpha = function() end,
    }
    ns.QUI_GroupFrameChrome = {
        Apply = function() end,
        ResizeHealthForPower = function() end,
    }
    D._state.filter = D._NormalizeFilter(nil)
    D._ApplyFrameSettings(frame, {
        name = "Preview", role = "HEALER", class = "PRIEST", healthPct = 75,
        _sampleDispel = "Magic",
    }, {
        general = {}, power = { showPowerBar = false }, name = {},
        health = {}, indicators = {},
        healer = {
            dispelOverlay = { enabled = false },
            cleanseGlow = { enabled = true, color = { 0.2, 0.8, 0.3, 0.9 } },
        },
    }, {}, "party")
    assert(glow.shown == true)
    assert(glow.tex.vertex[1] == 0.2 and glow.tex.vertex[4] == 0.9)
end)

test("tracked placeholders resolve REAL spell art, strips stay generic", function()
    -- A tracked element names its spells, so its placeholder has no excuse for
    -- a question mark. A filter strip's content only exists at runtime (the
    -- engine's filter decides), so it must NOT claim art even if the element
    -- happens to carry a spell list.
    C_Spell = { GetSpellTexture = function(id) return 900 + id end }
    local tracked = { mode = "tracked", displayType = "icon", spells = { 111, 222 } }
    assert(D._MakePlaceholderIcon(tracked, 1) == 1011, "slot 1 -> spell 111's art")
    assert(D._MakePlaceholderIcon(tracked, 2) == 1122, "slot 2 -> spell 222's art")
    assert(D._MakePlaceholderIcon(tracked, 9) == nil, "slot past the spell list has no art")
    assert(D._MakePlaceholderIcon({ mode = "filterStrip", spells = { 111 } }, 1) == nil,
        "filter strips must not claim spell art")
    C_Spell = nil
end)

test("transient indicators demo one tile each, no CENTER collisions", function()
    local demo = D._INDICATOR_DEMO
    local seen = {}
    local centerKeys = { readyCheck = true, resurrection = true, summon = true }
    for i = 1, #demo do
        local centers = 0
        for key in pairs(demo[i]) do
            assert(not seen[key], key .. " demoed on more than one tile")
            seen[key] = true
            if centerKeys[key] then centers = centers + 1 end
        end
        assert(centers <= 1, "tile " .. i .. " stacks two CENTER-anchored icons")
    end
    for _, key in ipairs({ "readyCheck", "resurrection", "summon",
                           "leader", "targetMarker", "phase" }) do
        assert(seen[key], key .. " is never demoed")
    end
end)

-- Aura placeholder pin: the GF surface must reproduce the LIVE RenderIcon pin
-- (icon-anchor flip + bottomPad), not the generic flow derivation.
assert(loadfile("QUI_GroupFrames/groupframes/group_frames_icon_layout.lua"))("QUI_GroupFrames", ns)
assert(loadfile("core/aura_glue.lua"))("QUI", ns)

test("aura pin: corner comes from the live GetIconAnchorForGrow flip", function()
    local pin = D._MakeAuraPin({ _bottomPad = 0 })
    local _, framePoint, _, _, corner =
        pin({ anchor = "BOTTOMRIGHT", growDirection = "UP", iconSize = 16 })
    assert(framePoint == "BOTTOMRIGHT")
    assert(corner == "BOTTOMRIGHT", "got " .. tostring(corner))
    local _, _, _, _, c2 = pin({ anchor = "TOPLEFT", growDirection = "RIGHT" })
    assert(c2 == "TOPLEFT")
end)

test("aura pin: BOTTOM anchors clear the power bar via _bottomPad", function()
    local pin = D._MakeAuraPin({ _bottomPad = 6 })
    local _, _, offX, offY = pin({ anchor = "BOTTOMRIGHT", growDirection = "LEFT",
                                   offsetX = -2, offsetY = -18 })
    assert(offX == -2)
    assert(offY == -18 + 6, "BOTTOM anchor adds bottomPad, got " .. tostring(offY))
    local _, _, _, topY = pin({ anchor = "TOPLEFT", growDirection = "RIGHT", offsetY = 16 })
    assert(topY == 16)
end)

print("ALL PASS")
