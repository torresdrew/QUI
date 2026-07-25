-- tests/unit/aura_preview_test.lua
-- Coverage for the shared aura preview renderer (core/aura_preview.lua) and the
-- three surfaces' rewire onto it. Two layers:
--   1. Source-text pins — the module consumes AuraGlue.ElementProfile (the SAME
--      layout math the live containers use, no duplicated layout constants),
--      reuses a per-host pool (_quiAuraPreview), never reads aura data, and
--      derives the flow corner with FlowFor's exact idiom; the three surface
--      files drive ns.AuraPreview (UF threading its corner flip through
--      opts.resolve); the GF fake-match fabricators are gone.
--   2. Behavioral — load the real ElementProfile + the module under a stub
--      CreateFrame and exercise P.Show / P.Hide, including POSITION-asserting
--      fidelity checks (SetPoint capture) against the live engines' layouts:
--      the UF corner flip, multi-row grow LEFT / wrap UP, column growth
--      direction, and CENTER grow symmetry (incl. short-line centering).
-- Run: lua tests/unit/aura_preview_test.lua

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a"); f:close()
    return (d:gsub("\r\n", "\n"))
end

local fails = 0
local function check(name, ok)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name) end
end

---------------------------------------------------------------------------
-- 1. SOURCE-TEXT PINS: core/aura_preview.lua
---------------------------------------------------------------------------
local src = readAll("core/aura_preview.lua")

check("published as ns.AuraPreview", src:find("ns.AuraPreview = P", 1, true) ~= nil)
check("exports P.Show", src:find("function P.Show", 1, true) ~= nil)
check("exports P.Hide", src:find("function P.Hide", 1, true) ~= nil)
check("icon placeholders reuse AuraSkin preview wiring",
    src:find("Skin.WirePreviewButton", 1, true) ~= nil)
-- WYSIWYG: layout comes from AuraGlue.ElementProfile, NOT re-derived constants.
check("consumes AuraGlue.ElementProfile (shared layout math)",
    src:find("ns.AuraGlue", 1, true) ~= nil and src:find("G.ElementProfile(element)", 1, true) ~= nil)
check("no duplicated layout: grow/wrap/perRow read off the profile, not recomputed",
    src:find("p.wrap", 1, true) ~= nil
    and src:find("p.maxPerRow", 1, true) ~= nil and src:find("p.iconSize", 1, true) ~= nil)
-- Flow corner uses FlowFor's EXACT explicit branch (the and/or idiom fell
-- through for grow DOWN + wrap UP, previewing a downward column growing upward).
check("flow corner derived with FlowFor's explicit if/else (no and/or idiom)",
    src:find('if column then up = (grow == "UP") else up = (p.wrap == "UP") end', 1, true) ~= nil)
-- Surface-anchoring seam: default pin at element.anchor, overridable resolve.
check("opts.resolve seam with a DefaultResolve fallback",
    src:find("DefaultResolve", 1, true) ~= nil
    and src:find("opts.resolve", 1, true) ~= nil)
-- Pool reuse keyed on the host frame.
check("reuses a per-host pool (_quiAuraPreview)",
    src:find("hostFrame._quiAuraPreview", 1, true) ~= nil
    and src:find("hostFrame._quiAuraPreview = pool", 1, true) ~= nil)
check("hides pool surplus rather than destroying frames",
    src:find("for i = cursor + 1, #pool do HidePreviewFrame(pool[i]) end", 1, true) ~= nil)
-- Placeholder icon only — the preview never reads real aura data.
check("draws placeholders, never reads aura data",
    src:find("PLACEHOLDER_ICON", 1, true) ~= nil
    and src:find("GetUnitAuras", 1, true) == nil
    and src:find("GetAuraDataBy", 1, true) == nil
    and src:find("UnitAura(", 1, true) == nil
    and src:find("expirationTime", 1, true) == nil)
-- healthTint tracked draws no icon slot (it tints a bar), so it is skipped.
check("skips healthTint tracked (no icon slot for a bar tint)",
    src:find('e.displayType ~= "healthTint"', 1, true) ~= nil)
-- Tracked bar/square preview as element.color rectangles.
check("tracked bar previews as a bar.length x bar.thickness colored rectangle",
    src:find('displayType == "bar"', 1, true) ~= nil
    and src:find(".length", 1, true) ~= nil and src:find(".thickness", 1, true) ~= nil
    and src:find("SetColorTexture", 1, true) ~= nil)
check("tracked square previews as an iconSize color swatch",
    src:find('displayType == "square"', 1, true) ~= nil)
-- Pure at file scope: no CreateFrame outside P.Show/AcquireIcon (loads headless).
check("no top-level frame creation (headless-loadable)",
    not src:match("\nlocal%s+%w+%s*=%s*CreateFrame")
    and not src:match("\nCreateFrame%("))

---------------------------------------------------------------------------
-- 1b. SOURCE-TEXT PINS: the three surfaces drive ns.AuraPreview
---------------------------------------------------------------------------
local uf = readAll("QUI_UnitFrames/unitframes/unitframe_auras.lua")
check("UF drives ns.AuraPreview (Show + Hide)",
    uf:find("ns.AuraPreview", 1, true) ~= nil
    and uf:find(".Show(frame", 1, true) ~= nil and uf:find(".Hide(frame)", 1, true) ~= nil)
check("UF threads its corner flip through opts.resolve (live helpers, no dup)",
    uf:find("resolve = PreviewResolve", 1, true) ~= nil
    and uf:match("local function PreviewResolve%(element%).-MapAuraAnchorToFramePoint.-ElementProfileFor.-\nend") ~= nil)
check("UF old fake-icon renderer gone (PREVIEW_AURAS table removed)",
    uf:find("PREVIEW_AURAS", 1, true) == nil and uf:find("previewBuffIcons", 1, true) == nil)

-- Group frames split by what the LIVE module says the renderer draws: only
-- missingRaidBuff + healthTint/border feeders go through the real renderer;
-- filter strips and tracked icon/square/bar are drawn live by a secure
-- CustomAuraContainer the ENGINE fills, which a preview cannot feed -- those
-- get placeholders here.
local gfp = readAll("QUI_GroupFrames/groupframes/settings/group_frames_preview_driver.lua")
check("GF asks the live module which elements the renderer draws",
    gfp:find("GFA.EngineRendersElement(element)", 1, true) ~= nil
    and gfp:find("ns.QUI_GroupFrameAuras", 1, true) ~= nil)
check("GF drives ns.AuraPreview for the engine-container elements",
    gfp:find("Preview.Show(auraHost, previewElements", 1, true) ~= nil
    and gfp:find("Preview.Hide(auraHost)", 1, true) ~= nil)
check("GF threads the live RenderIcon pin + real spell art through opts",
    gfp:find("resolve = MakeAuraPin(f, profileOverrides)", 1, true) ~= nil
    and gfp:find("icon = MakePlaceholderIcon", 1, true) ~= nil
    and gfp:find("dispelColor = MakePreviewDispelColor", 1, true) ~= nil
    and gfp:find("IL.GetIconAnchorForGrow(anchor, p.grow)", 1, true) ~= nil)
check("GF hosts placeholders at the live container level",
    gfp:find("f._auraHost:SetFrameLevel(Driver._AuraHostLevel", 1, true) ~= nil)
check("GF does NOT resurrect the pre-cutover renderer path for strips",
    gfp:find("BuildFilterStripMatches", 1, true) == nil
    and gfp:find("BuildTrackedMatches", 1, true) == nil)

local bb = readAll("QUI_ActionBars/actionbars/buffborders.lua")
check("BB drives ns.AuraPreview on the mover hosts (Show + Hide)",
    bb:find("ns.AuraPreview", 1, true) ~= nil
    and bb:find("Preview.Show(buffContainer", 1, true) ~= nil
    and bb:find("Preview.Show(debuffContainer", 1, true) ~= nil
    and bb:find("Preview.Hide(buffContainer)", 1, true) ~= nil)
check("BB bespoke preview-grid code removed (CreatePreviewGrid / overlay gone)",
    bb:find("CreatePreviewGrid", 1, true) == nil
    and bb:find("previewBuffOverlay", 1, true) == nil
    and bb:find("PREVIEW_BUFF_TEXTURES", 1, true) == nil)

local gf = readAll("QUI_GroupFrames/groupframes/settings/group_frames_preview_driver.lua")
-- The two fake-match fabricators are deleted (only the removal-note comment may
-- still name them). Pin that no FUNCTION definition survives.
check("GF fabricators deleted (_BuildFilterStripMatches / _BuildTrackedMatches)",
    gf:find("function Driver._BuildFilterStripMatches", 1, true) == nil
    and gf:find("function Driver._BuildTrackedMatches", 1, true) == nil)
check("GF keeps MRB on the real renderer",
    gf:find("Driver._BuildMissingRaidBuffMatches", 1, true) ~= nil)

---------------------------------------------------------------------------
-- 2. BEHAVIORAL: exercise the module under a stub CreateFrame + real profile.
--    The module DEFINES frame work only inside P.Show, so it loads with a fresh
--    ns; we hand it the REAL AuraGlue.ElementProfile so the layout is the live
--    math, and a recording CreateFrame stub that captures SetPoint args.
---------------------------------------------------------------------------
local createCount = 0
local function StubTexture()
    local t = { _tex = true }
    function t:SetAllPoints() end
    function t:SetTexture(v) self.kind = "icon"; self.tex = v end
    function t:SetTexCoord() end
    function t:SetColorTexture(r, g, b, a) self.kind = "color"; self.color = { r, g, b, a } end
    return t
end
local function StubFrame()
    createCount = createCount + 1
    local f = { shown = false }
    function f:CreateTexture() return StubTexture() end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:ClearAllPoints() self.point = nil end
    function f:SetPoint(p, rel, rp, x, y)
        self.point = { p = p, rel = rel, rp = rp, x = x, y = y }
    end
    function f:SetAlpha(a) self.alpha = a end
    return f
end
_G.CreateFrame = function() return StubFrame() end

local ns = {}
assert(loadfile("core/aura_glue.lua"))("QUI", ns)          -- real ElementProfile
assert(loadfile("core/aura_preview.lua"))("QUI", ns)
local P = ns.AuraPreview
check("module returns ns.AuraPreview after load", type(P) == "table")

local function filterStrip(over)
    local e = { mode = "filterStrip", auraType = "HELPFUL", anchor = "TOPLEFT",
                maxIcons = 3, iconSize = 20, spacing = 2, growDirection = "RIGHT" }
    if over then for k, v in pairs(over) do e[k] = v end end
    return e
end

-- (a) worst-case footprint: maxIcons placeholders, sized off ElementProfile.
local host = {}
P.Show(host, { filterStrip() })
local pool = host._quiAuraPreview
check("Show builds maxIcons placeholders on the host pool",
    type(pool) == "table" and #pool == 3 and pool[1].shown and pool[3].shown)
check("placeholder size comes from ElementProfile.iconSize (WYSIWYG)",
    pool[1].w == 20 and pool[1].h == 20)
check("default resolve pins the flow corner at element.anchor (BB/GF parity)",
    pool[1].point.p == "TOPLEFT" and pool[1].point.rp == "TOPLEFT"
    and pool[1].point.x == 0 and pool[2].point.x == 22)

-- (b) pool reuse: fewer icons on re-show hides surplus, creates no new frames.
local createdAfterFirst = createCount
P.Show(host, { filterStrip({ maxIcons = 1 }) })
check("re-show reuses the SAME pool table (no realloc)", host._quiAuraPreview == pool)
check("re-show creates no new frames (pool reuse)", createCount == createdAfterFirst)
check("re-show shows the kept icon, hides the surplus",
    pool[1].shown == true and pool[2].shown == false and pool[3].shown == false)

-- (c) POSITION FIDELITY: UF corner flip via opts.resolve. A BOTTOMLEFT buff
-- strip lives BELOW the frame on the live UF path (flipped attach corner +
-- flipped wrap + 1px border compensation) — the preview must match, not mirror
-- into the frame.
local ufHost = {}
P.Show(ufHost, { filterStrip({ anchor = "BOTTOMLEFT", maxIcons = 4, iconsPerRow = 2 }) }, {
    resolve = function(e)
        -- Mimic the UF fold (unitframe_auras.lua PreviewResolve): flipped
        -- attachPoint -> flipped wrap, pinned at the frame's own corner with
        -- the +1px border compensation.
        return ns.AuraGlue.ElementProfile(e, { attachPoint = "TOPLEFT", wrap = "DOWN" }),
            "BOTTOMLEFT", 1 + (e.offsetX or 0), (e.offsetY or 0)
    end,
})
local ufPool = ufHost._quiAuraPreview
check("UF flip: block origin corner is the FLIPPED corner (TOPLEFT, not BOTTOMLEFT)",
    ufPool[1].point.p == "TOPLEFT")
check("UF flip: pinned to the frame's own BOTTOMLEFT (hangs below the frame)",
    ufPool[1].point.rp == "BOTTOMLEFT")
check("UF flip: border compensation offset applied (+1px)",
    ufPool[1].point.x == 1)
check("UF flip: wrap row extends DOWN, away from the frame (dy negative)",
    ufPool[3].point.y == -22)

-- (c2) POSITION FIDELITY: a resolve may override the pin CORNER outright. The
-- GF unit-frame path takes the corner's horizontal side from the FRAME anchor
-- (IconLayout.GetIconAnchorForGrow) -- information the flow derivation, which
-- reads only grow/wrap, cannot reconstruct.
local cornerHost = {}
P.Show(cornerHost, { filterStrip({ anchor = "BOTTOMRIGHT", growDirection = "UP", maxIcons = 2 }) }, {
    resolve = function(e)
        return ns.AuraGlue.ElementProfile(e), "BOTTOMRIGHT", 0, 0, "BOTTOMRIGHT"
    end,
})
local cornerPool = cornerHost._quiAuraPreview
check("resolve's 5th return overrides the flow-derived pin corner",
    cornerPool[1].point.p == "BOTTOMRIGHT" and cornerPool[1].point.rp == "BOTTOMRIGHT")
check("corner override leaves flow DIRECTION alone (grow UP still marches +y)",
    cornerPool[2].point.y > 0)

-- (c3) opts.icon supplies real spell art per slot; nil falls back to the
-- placeholder question mark.
local iconHost = {}
P.Show(iconHost, { filterStrip({ maxIcons = 2 }) }, {
    icon = function(_, index) return index == 1 and 12345 or nil end,
})
local iconPool = iconHost._quiAuraPreview
check("opts.icon paints the caller's texture on the slot it names",
    iconPool[1]._tex.tex == 12345)
check("slots the caller cannot name keep the placeholder icon",
    iconPool[2]._tex.tex == 134400)

-- (d) POSITION FIDELITY: 10 icons, perRow 4, grow LEFT, wrap UP (BOTTOMRIGHT
-- anchor) — flow origin BOTTOMRIGHT, dx marches negative, row 2 dy positive.
local gridHost = {}
P.Show(gridHost, { filterStrip({ anchor = "BOTTOMRIGHT", growDirection = "LEFT",
    maxIcons = 10, iconsPerRow = 4 }) })
local gridPool = gridHost._quiAuraPreview
check("grow LEFT + wrap UP: flow origin corner BOTTOMRIGHT",
    gridPool[1].point.p == "BOTTOMRIGHT" and gridPool[1].point.rp == "BOTTOMRIGHT")
check("grow LEFT: dx negative (icons march left)",
    gridPool[2].point.x == -22)
check("wrap UP: row 2 dy positive (rows stack upward)",
    gridPool[5].point.x == 0 and gridPool[5].point.y == 22)

-- (e) POSITION FIDELITY: grow DOWN column on a BOTTOM anchor — the and/or idiom
-- bug case (grow DOWN fell through to wrap UP and previewed growing upward).
-- Columns take `up` from grow: dy must be NEGATIVE.
local colHost = {}
P.Show(colHost, { filterStrip({ anchor = "BOTTOMLEFT", growDirection = "DOWN", maxIcons = 3 }) })
local colPool = colHost._quiAuraPreview
check("grow DOWN column: flow origin corner TOPLEFT (up from grow, not wrap)",
    colPool[1].point.p == "TOPLEFT")
check("grow DOWN column: icons stack downward (dy NEGATIVE)",
    colPool[2].point.x == 0 and colPool[2].point.y == -22)
check("grow DOWN column: third icon continues down",
    colPool[3].point.y == -44)

-- (f) POSITION FIDELITY: CENTER grow — strip centered on the anchor (GF
-- IconLayout.SingleRowOffset parity): first/last placeholder symmetric.
local centerHost = {}
P.Show(centerHost, { filterStrip({ growDirection = "CENTER", maxIcons = 3 }) })
local centerPool = centerHost._quiAuraPreview
-- span = 3*20 + 2*2 = 64; dx_i = (i-1)*22 - 32 -> -32, -10, 12
check("CENTER: first/last placeholder centers symmetric about the anchor",
    (centerPool[1].point.x + 10) == -(centerPool[3].point.x + 10))
check("CENTER: middle placeholder centered exactly on the anchor",
    (centerPool[2].point.x + 10) == 0)
-- Short final line centers on its OWN occupancy (CalculateSlotOffset parity):
-- 5 icons perRow 3 -> line 2 holds 2 icons, span 42, centers at -11/+11.
local centerWrapHost = {}
P.Show(centerWrapHost, { filterStrip({ growDirection = "CENTER", maxIcons = 5, iconsPerRow = 3 }) })
local cwPool = centerWrapHost._quiAuraPreview
check("CENTER wrap: short final line centered on its own occupancy",
    (cwPool[4].point.x + 10) == -(cwPool[5].point.x + 10)
    and cwPool[4].point.y == -22)

-- (g) tracked bar branch: one rectangle per spell, bar dims + element.color fill.
local barHost = {}
P.Show(barHost, { { mode = "tracked", displayType = "bar", auraType = "HELPFUL",
    anchor = "TOPLEFT", spells = { 101 }, bar = { length = 50, thickness = 10 },
    color = { 1, 0, 0, 1 }, iconSize = 16 } })
local barPool = barHost._quiAuraPreview
check("tracked bar draws one rectangle per configured spell",
    type(barPool) == "table" and #barPool == 1 and barPool[1].shown)
check("bar rectangle sized bar.length x bar.thickness",
    barPool[1].w == 50 and barPool[1].h == 10)
do
    local tex = barPool[1]._tex
    check("bar texture used SetColorTexture with element.color",
        type(tex) == "table" and tex.kind == "color"
        and tex.color and tex.color[1] == 1 and tex.color[2] == 0 and tex.color[3] == 0)
    local icoTex = pool[1]._tex
    check("icon texture used SetTexture (question-mark placeholder)",
        type(icoTex) == "table" and icoTex.kind == "icon")
end

-- (h) tracked square branch: iconSize color swatch, not a question-mark icon.
local sqHost = {}
P.Show(sqHost, { { mode = "tracked", displayType = "square", auraType = "HELPFUL",
    anchor = "TOPLEFT", spells = { 7, 8 }, color = { 0, 1, 0 }, iconSize = 18 } })
local sqPool = sqHost._quiAuraPreview
check("tracked square draws one swatch per spell at iconSize^2",
    #sqPool == 2 and sqPool[1].w == 18 and sqPool[1].h == 18)
check("square swatch filled with element.color (not the question-mark icon)",
    sqPool[1]._tex.kind == "color" and sqPool[1]._tex.color[2] == 1)

-- (i) tracked count caps at maxIcons (live renderer's min(#ordered, maxIcons)).
local capHost = {}
P.Show(capHost, { { mode = "tracked", displayType = "icon", auraType = "HELPFUL",
    anchor = "TOPLEFT", spells = { 1, 2, 3 }, maxIcons = 2, iconSize = 16 } })
check("tracked placeholder count = min(#spells, maxIcons)",
    #capHost._quiAuraPreview == 2)

-- (j) healthTint tracked is skipped (no icon slot).
local htHost = {}
P.Show(htHost, { { mode = "tracked", displayType = "healthTint", auraType = "HELPFUL",
    anchor = "TOPLEFT", spells = { 202 } } })
local htPool = htHost._quiAuraPreview
check("healthTint tracked draws no placeholder", type(htPool) == "table" and #htPool == 0)

-- (k) opts.only filters after the mode gate.
local onlyHost = {}
P.Show(onlyHost, {
    filterStrip({ auraType = "HELPFUL", maxIcons = 2 }),
    filterStrip({ auraType = "HARMFUL", maxIcons = 4, anchor = "BOTTOMRIGHT", growDirection = "LEFT" }),
}, { only = function(e) return e.auraType == "HARMFUL" end })
check("opts.only renders only the matching polarity (4 debuff icons)",
    #onlyHost._quiAuraPreview == 4)

-- (l) Shared AuraSkin preview seam: the generic placeholder owns only fake
-- data, while runtime AuraSkin owns icon chrome, text positioning and swipe
-- styling. This stub captures the exact resolved profile handed across that
-- seam and provides the regions AuraPreview fills with representative data.
do
    local styledNS = { AuraGlue = ns.AuraGlue }
    styledNS.Addon = {
        AuraSkin = {
            WirePreviewButton = function(frame, profile)
                frame.wiredProfile = profile
                frame._tex = frame._tex or StubTexture()
                frame.Icon = frame._tex
                frame._quiDispel = frame._quiDispel or StubTexture()
                function frame._quiDispel:Show() self.shown = true end
                function frame._quiDispel:Hide() self.shown = false end
                function frame._quiDispel:SetVertexColor(...) self.vertex = { ... } end
                frame._quiDuration = frame._quiDuration or {
                    SetText = function(self, text) self.text = text end,
                }
                frame._quiCount = frame._quiCount or {
                    SetText = function(self, text) self.text = text end,
                }
                frame._quiCooldown = frame._quiCooldown or {
                    SetCooldown = function(self, start, duration)
                        self.start, self.duration = start, duration
                    end,
                }
            end,
            ReleasePreviewButton = function(frame) frame.releasedPreviewSkin = true end,
        },
    }
    assert(loadfile("core/aura_preview.lua"))("QUI", styledNS)
    local styledHost = {}
    local harmful = filterStrip({
        auraType = "HARMFUL",
        maxIcons = 1,
        duration = { show = true },
        stack = { show = true },
    })
    styledNS.AuraPreview.Show(styledHost, { harmful }, {
        resolve = function(element)
            return styledNS.AuraGlue.ElementProfile(element, {
                showDispelBorder = true,
                iconSkin = "Gloss",
            }), "TOPLEFT", 0, 0
        end,
        dispelColor = function() return 0.2, 0.6, 1, 1 end,
    })
    local styled = styledHost._quiAuraPreview[1]
    check("AuraSkin receives the resolved profile including surface overrides",
        styled.wiredProfile.iconSkin == "Gloss"
        and styled.wiredProfile.showDispelBorder == true)
    check("placeholder supplies representative duration and stack text",
        styled._quiDuration.text ~= nil and styled._quiCount.text == "2")
    check("placeholder starts a representative cooldown on the shared region",
        styled._quiCooldown.duration ~= nil and styled._quiCooldown.duration > 0)
    check("harmful placeholder applies the caller's dispel-ring sample color",
        styled._quiDispel.shown == true and styled._quiDispel.vertex[2] == 0.6)
    styledNS.AuraPreview.Hide(styledHost)
    check("Hide releases external preview-skin ownership",
        styled.releasedPreviewSkin == true)
end

-- (m) Hide hides the whole pool.
P.Hide(host)
check("Hide hides every pooled placeholder",
    pool[1].shown == false and pool[2].shown == false and pool[3].shown == false)

if fails > 0 then error(fails .. " failure(s) in aura_preview_test") end
print("OK: aura_preview_test (all checks passed)")
