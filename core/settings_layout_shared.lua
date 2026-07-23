--- QUI settings — shared provider-panel layout scaffold.
---
--- The `MakeLayout(content)` top-to-bottom stacking helper (headerAt /
--- sectionAt / closeSection / placeCustom + sections/relayoutSections) is
--- copy-pasted across many `*/settings/*` provider files. Those files load in
--- the QUI_Options surface context (QUI_Options.toc), which shares no addon
--- ancestor with the modules that own them, so the only shared home that is
--- always loaded first is core.
---
--- This is THE builder: every provider file delegates here (directly or via
--- the modules/ui settings wrapper). QUI_Options is resolved at CALL time,
--- which is safe because ns.QUI_Options keeps ONE table identity for the
--- whole session — core/gui_shell.lua installs it and QUI_Options/shared.lua
--- ADOPTS it (`ns.QUI_Options or {}`), never replaces it. The historical
--- "stub-then-replace dance" (file-level Opts/PAD upvalues re-resolved after
--- options load) guarded against a replacement that no longer happens.

local _, ns = ...

local Shared = ns.QUI_SettingsLayoutShared or {}
ns.QUI_SettingsLayoutShared = Shared

---------------------------------------------------------------------------
-- Nine-point anchor dropdown options — the ONE definition (was copy-pasted
-- across 7 settings files). Returns a FRESH table per call: dropdown
-- consumers may decorate their options list, so a shared static would alias
-- state across call sites. Retained statics (Options.NINE_POINT_ANCHOR_
-- OPTIONS, SettingsLayout.NINE_POINT_OPTIONS) are single instances built
-- from this factory, preserving their existing sharing semantics.
---------------------------------------------------------------------------
function Shared.BuildNinePointAnchorOptions()
    local L = ns.L
    return {
        { value = "TOPLEFT", text = L["Top Left"] },
        { value = "TOP", text = L["Top"] },
        { value = "TOPRIGHT", text = L["Top Right"] },
        { value = "LEFT", text = L["Left"] },
        { value = "CENTER", text = L["Center"] },
        { value = "RIGHT", text = L["Right"] },
        { value = "BOTTOMLEFT", text = L["Bottom Left"] },
        { value = "BOTTOM", text = L["Bottom"] },
        { value = "BOTTOMRIGHT", text = L["Bottom Right"] },
    }
end

-- Standard provider-panel layout. `U` is the layout-mode utils (ctx.U); when
-- layout mode is positioning-only we hand back the suppressed layout instead.
-- QUI_Options is resolved at entry: callers build the panel on settings-open,
-- long after the on-demand QUI_Options addon has merged into the bootstrap
-- stub (same table identity; see header). startY overrides the -10 top pad
-- (hud_layering starts at -38 below its page banner).
function Shared.MakeLayout(content, U, startY)
    -- U is the layout-mode utils (ctx.U / ns.QUI_LayoutMode_Utils). Some
    -- provider files never wired the positioning-only suppression and pass no
    -- U; `U and` keeps the guard a no-op for them (identical to their old body)
    -- while preserving suppression for the files that do pass U.
    if U and U._layoutModePositionOnly then
        return U.MakeSuppressedProviderLayout(content)
    end
    local Opts = ns.QUI_Options
    local PAD = (ns.QUI_Options and ns.QUI_Options.PADDING) or 15
    local HEADER_GAP = 26
    local SECTION_GAP = 14
    local y = startY or -10
    local L = {}
    local sections = {}

    function L.headerAt(text)
        local h = Opts.CreateAccentDotLabel(content, text, y)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
        h:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
        y = y - HEADER_GAP
    end
    function L.sectionAt()
        local c = Opts.CreateSettingsCardGroup(content, y)
        c.frame:ClearAllPoints()
        c.frame:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
        c.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
        return c
    end
    function L.closeSection(c)
        c.Finalize()
        y = y - c.frame:GetHeight() - SECTION_GAP
    end
    function L.placeCustom(frame, height)
        -- Defensive reparent: callers sometimes create with nil parent and
        -- rely on anchoring alone (QoL FPS-preset button block). SetParent
        -- ensures the frame hides / is reclaimed with the settings page
        -- rather than orphaning to UIParent and lingering after close.
        frame:SetParent(content)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
        frame:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
        frame:SetHeight(height)
        y = y - height - SECTION_GAP
    end

    local function relayoutSections()
        local cy = y
        for _, s in ipairs(sections) do
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, cy)
            s:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
            cy = cy - s:GetHeight() - 4
        end
        content:SetHeight(math.abs(cy) + 16)
    end
    -- Finalize tail used by the finish-family providers (skinning, prey,
    -- datatexts legacy collapsibles, etc.) that size the scroll body directly
    -- instead of via relayoutSections.
    function L.finish()
        content:SetHeight(math.abs(y) + 10)
        return content:GetHeight()
    end
    -- Muted word-wrapped paragraph between a header and its card (QoL and
    -- Click Cast pages). GUI/colors resolve at call time: intro only runs
    -- during panel build, after QUI_Options has merged its methods into the
    -- core-created QUI.GUI table.
    function L.intro(text)
        local G = QUI and QUI.GUI
        local frame = CreateFrame("Frame", nil, content)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
        frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
        local lbl = G:CreateLabel(frame, text, 11, G.Colors.textMuted)
        lbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        lbl:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(true)
        local approxHeight = math.max(18, math.ceil(#text / 90) * 15)
        frame:SetHeight(approxHeight)
        y = y - approxHeight - 8
        return lbl, frame
    end
    -- Cursor access for provider bodies that interleave manual placement
    -- (chat window list; click-cast aliases getY as offset).
    function L.getY() return y end
    function L.setY(newY) y = newY end
    L.sections = sections
    L.relayoutSections = relayoutSections

    return L
end
