-- QUI_CDM/cdm/cdm_reanchor_realenv.lua
-- Wires the re-anchor boot env to the live ns modules + WoW globals. The three
-- cdm_containers-internal deps (getSettings/resolveAdditional/onMetrics) are
-- injected via ctx at the Initialize call site. Used by the guarded construction
-- of ns._cdmBoot; the runtime stays inert until the LayoutContainer splice (2b-4).
local _, ns = ...

local CDMReanchorRealEnv = {}
ns.CDMReanchorRealEnv = CDMReanchorRealEnv

-- After Task 5 the decorate passes make ZERO raw SetFont writes on live Blizzard
-- CDM secret-tracked fontstrings. The countdown now goes through the taint-safe
-- Cooldown:SetCountdownFont(fontName) API (AllowedWhenUntainted). The native
-- charge/stack count font is left at Blizzard's default (own-fontstring styling
-- is DEFERRED -- needs a combat-safe non-secret charge query, flagged for Drew).
-- After Task 3 the decorate passes also make ZERO SetFrameStrata/SetFrameLevel/
-- SetIgnoreParentAlpha writes on live Blizzard CDM frames -- those were the
-- primary taint vector (Blizzard's own per-item OnEvent then threw on secret
-- cooldown/aura values). The securecall boundary is kept for owned swipe/chrome
-- writes inside Decorate (own-child writes, run under the single secure
-- chokepoint for clarity). Child-widget restyle (swipe/icon crop) is taint-safe
-- either way -- folded under the one boundary so there is a single chokepoint.
local _securecall = securecallfunction or function(fn, ...) return fn(...) end
local _issecretvalue = issecretvalue or function() return false end

local function IsBuffIconKey(key)
    return key == "buff" or key == "buffIcon"
end

-- Task A G4: per-(size,outline) font-object cache.
-- SetCountdownFont(fontName) requires a global font-OBJECT name (cstring).
-- A single shared object (QUI_CDM_CountFont) caused last-writer-wins size
-- collapse: cooldown rows (durationSize 16, cdm_containers.lua:1445) and
-- aura rows (14, :1491) both overwrote the same font object each pass →
-- wrong size on whichever row was decorated last + flicker on split-trigger
-- refreshes. One lazy font object per distinct (size, outline) tuple fixes
-- the collapse. Colour (G3) is re-applied every pass (cheap, and a container's
-- colour config can differ from another container that shares the same size).
-- CreateFont is a WoW-only global; the guard keeps tests runnable in plain Lua.
local _countFontCache = {}   -- [key] -> fontObjectName  (key = size_outline_r,g,b,a)

local function _EnsureCountFont(font, sz, outline, color)
    if not CreateFont then return nil end
    -- Validate size > 0 (GetFont can return garbage — skinning-getfont-size-guard)
    sz = (type(sz) == "number" and sz > 0) and sz or 14
    outline = outline or ""
    -- Key on (size, outline, COLOUR): the colour is re-applied to the shared object
    -- every pass, so two rows that share a (size,outline) but differ in
    -- durationTextColor would otherwise last-writer-wins clobber each other's colour
    -- (the same collapse class G4 fixed for size). Byte-encode the colour into the key.
    local ck = ""
    if type(color) == "table" then
        ck = "_" .. math.floor((color[1] or 1) * 255 + 0.5)
            .. "," .. math.floor((color[2] or 1) * 255 + 0.5)
            .. "," .. math.floor((color[3] or 1) * 255 + 0.5)
            .. "," .. math.floor((color[4] or 1) * 255 + 0.5)
    end
    local key = sz .. (outline ~= "" and "_" .. outline or "") .. ck
    local name = _countFontCache[key]
    if not name then
        name = "QUI_CDM_CountFont_" .. key
        CreateFont(name)
        _countFontCache[key] = name
    end
    local fo = _G[name]
    if fo then
        if fo.SetFont and font then
            fo:SetFont(font, sz, outline)
        end
        -- G3: colour the font object so the Cooldown countdown inherits the
        -- user's configured duration text colour (rowConfig.durationTextColor,
        -- same field as the owned-icon path — cdm_icon_renderer.lua:2442).
        -- A fresh CreateFont defaults white; we style our OWN font object —
        -- not a Blizzard-owned fontstring — so this write is taint-safe.
        if fo.SetTextColor then
            local r, g, b, a = 1, 1, 1, 1
            if type(color) == "table" then
                r = color[1] or 1; g = color[2] or 1
                b = color[3] or 1; a = color[4] or 1
            end
            fo:SetTextColor(r, g, b, a)
        end
    end
    return name
end

-- Re-anchored Blizzard item frames already carry the native charge/count text.
-- Leave those native fontstrings visible as the mirror source; do not query a
-- replacement display count, create an owned count fontstring, or alpha-hide the
-- native ChargeCount / Applications regions.

local function _DecorateWork(decorator, live, shell, rowConfig)
    -- Task 2 places the QUI border as an own child of the live icon, so
    -- shell.Border is now a redundant double-border once the lift is gone.
    if shell and shell.Border and shell.Border.Hide then shell.Border:Hide() end
    return decorator:Decorate(live, rowConfig)
end

-- Bar reskin for the trackedBar surface. Re-anchored Blizzard BuffBar frames are
-- StatusBars, not icons: the icon decorate would crop + stretch the native icon under
-- the two-point overlay. Mirror the re-anchor reference addons -- HIDE the native icon
-- + chrome, restyle the native StatusBar with the QUI texture + color (so it's not
-- Blizzard-styled), and re-apply on SetBarContent/SetBarWidth (Blizzard reverts those
-- every aura tick). All writes run under securecall.
--
-- G1/G12/G15 (faithfulness pass): the bar's border, bg, icon and Name are OWN CHILDREN of
-- the LIVE bar frame chain (live / live.Bar), NOT cross-chain on the QUI shell. The de-taint
-- removed the old strata "lift" that forced the live frame above the shell, so the
-- shell<->live z-order is now indeterminate -- an opaque shell.Bg OR the solid full-rect
-- shell.Border could render OVER the native StatusBar fill (the "solid rectangle, no fill"
-- bug). Putting border (BACKGROUND on live, around the rect), bg (BACKGROUND on live.Bar,
-- behind the fill), icon (ARTWORK on live, left of the bar) and Name (OVERLAY on live.Bar,
-- above the fill) in the SAME parent chain as the native fill makes their z-order
-- deterministic with no strata write. Child creation/render on the live frame from
-- non-secret data is taint-safe (same own-child pattern applyChrome uses for the icon
-- border). Native matched frames direct-anchor with no per-slot visual shell, so the
-- legacy shell bar-widgets (shell.Bg/shell.BarIcon) are retired entirely.
local _barHooked = setmetatable({}, { __mode = "k" })

-- Per-(live frame) own bar widgets. External weak table keyed by the live frame -- never
-- a key written onto the Blizzard-owned frame. Created lazily, reused across re-apply.
local _barWidgets = setmetatable({}, { __mode = "k" })

-- Resolve the bar's spell icon, LIVE-FIRST so dynamic buffs (Roll the Bones, Eclipse)
-- show the actual rolled/phase icon: Blizzard keeps live.Icon.Icon at the live displayed-
-- aura form (taint-safe fileID read). Fall back to the curated entry's spellID only when
-- there is no live texture. issecretvalue-guarded (a combat-secret texture is skipped).
local function _ResolveBarIconTexture(live, entry)
    if live and live.Icon and live.Icon.Icon and live.Icon.Icon.GetTexture then
        local ok, t = pcall(live.Icon.Icon.GetTexture, live.Icon.Icon)
        if ok and t and not _issecretvalue(t) then return t end
    end
    local sid = entry and (entry.spellID or entry.overrideSpellID or entry.id)
    if type(sid) == "number" and C_Spell and C_Spell.GetSpellTexture then
        local ok, t = pcall(C_Spell.GetSpellTexture, sid)
        if ok and t and not _issecretvalue(t) then return t end
    end
    return nil
end

-- Create (once, cached) the own bar widgets as CHILDREN of the live bar chain:
--   bg     -- BACKGROUND texture on live.Bar  (always behind the native StatusBar fill)
--   name   -- OVERLAY fontstring on live.Bar  (always above the fill)
--   icon   -- ARTWORK texture on live         (the left icon area of the item frame)
--   border -- BACKGROUND texture on live      (the QUI theme border, around the whole rect)
-- The border lives on the LIVE chain (not the cross-chain shell): with the strata lift
-- retired, a shell-side solid border could render OVER the live fill (same occlusion class
-- as the old shell.Bg). Single-chain border + bg + fill + name => deterministic z-order.
-- Guarded so unit-test mocks without Create* return nil widgets (each apply is guarded).
local function _EnsureBarWidgets(live)
    if not live then return nil end
    local w = _barWidgets[live]
    if w then return w end
    w = {}
    local bar = live.Bar
    if bar and bar.CreateTexture then
        w.bg = bar:CreateTexture(nil, "BACKGROUND")
    end
    if bar and bar.CreateFontString then
        w.name = bar:CreateFontString(nil, "OVERLAY")
    end
    if live.CreateTexture then
        w.icon = live:CreateTexture(nil, "ARTWORK")
        w.border = live:CreateTexture(nil, "BACKGROUND")
    end
    _barWidgets[live] = w
    return w
end

-- Reskin the native bar frame + paint the own bar widgets. HIDE the native icon/chrome,
-- restyle the native StatusBar (QUI texture + color) and span it right of the icon area,
-- then render the own bg/icon/Name children (deterministic z-order, same chain as the
-- native fill). Re-applied via the SetBarContent/SetBarWidth hooks so the icon tracks
-- aura swaps and the Name re-resolves. The curated entry (for the icon/name fallback) is
-- read from _barWidgets[live].entry, cached by _BarDecorateWork -- the re-apply hook has
-- no shell.
local function _BarReskinWork(live, settings)
    local bar = live.Bar
    if not bar then return end
    settings = settings or {}
    local showIcon = not settings.hideIcon
    local iconSize = settings.barHeight or 25
    if live.Icon and live.Icon.Hide then live.Icon:Hide() end
    if live.DebuffBorder and live.DebuffBorder.Hide then live.DebuffBorder:Hide() end
    if bar.BarBG and bar.BarBG.Hide then
        bar.BarBG:Hide()
        if bar.BarBG.SetAlpha then bar.BarBG:SetAlpha(0) end
    end
    if bar.Pip and bar.Pip.Hide then
        bar.Pip:Hide()
        if bar.Pip.SetAlpha then bar.Pip:SetAlpha(0) end
    end

    -- Native StatusBar spans the frame to the right of the own left icon area.
    if bar.ClearAllPoints and bar.SetPoint then
        local leftInset = showIcon and (iconSize + 2) or 1
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", live, "TOPLEFT", leftInset, -1)
        bar:SetPoint("BOTTOMRIGHT", live, "BOTTOMRIGHT", -1, 1)
    end

    local LSM = ns.LSM
    if bar.SetStatusBarTexture and LSM and LSM.Fetch then
        local tex = LSM:Fetch("statusbar", settings.texture or "Quazii v5")
            or LSM:Fetch("statusbar", "Quazii v5")
        if tex then bar:SetStatusBarTexture(tex) end
    end
    if bar.SetStatusBarColor then
        local opacity = settings.barOpacity or 1.0
        local r, g, b
        if settings.useClassColor and UnitClass and RAID_CLASS_COLORS then
            local _, class = UnitClass("player")
            -- @secret-policy: collapse-only — UnitClass can return SECRET on 12.1 PTR7
            -- (SecretWhenUnitIdentityRestricted); collapse so the barColor fallback applies.
            if _issecretvalue(class) then class = nil end
            local cc = class and RAID_CLASS_COLORS[class]
            if cc then r, g, b = cc.r, cc.g, cc.b end
        end
        if not r then
            local c = settings.barColor or { 0.376, 0.647, 0.980, 1 }
            r, g, b = c[1] or 0.376, c[2] or 0.647, c[3] or 0.980
        end
        bar:SetStatusBarColor(r, g, b, opacity)
    end

    -- Own bar visuals as CHILDREN of the live bar chain (deterministic z-order vs fill).
    local w = _EnsureBarWidgets(live)
    if w then
        -- G1: opaque bg on live.Bar BACKGROUND -> renders BEHIND the native fill in the
        -- SAME chain, so the fill/progress stays visible (no cross-chain occlusion).
        if w.bg then
            local bg = settings.bgColor or { 0, 0, 0, 1 }
            w.bg:SetColorTexture(bg[1] or 0, bg[2] or 0, bg[3] or 0, 1)
            w.bg:ClearAllPoints()
            w.bg:SetAllPoints(bar)
            w.bg:Show()
        end
        -- G12: own icon at the left, sourced LIVE-FIRST so dynamic buffs track aura swaps.
        if w.icon then
            if showIcon then
                local tex = _ResolveBarIconTexture(live, w.entry)
                if tex then w.icon:SetTexture(tex) end
                w.icon:ClearAllPoints()
                w.icon:SetPoint("LEFT", live, "LEFT", 1, 0)
                local sz = iconSize - 2
                if w.icon.SetSize then w.icon:SetSize(sz, sz) end
                if w.icon.SetTexCoord then w.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
                w.icon:Show()
            elseif w.icon.Hide then
                w.icon:Hide()
            end
        end
        -- G15: own QUI-font Name on live.Bar OVERLAY (mirrors cdm_bar_renderer NameText).
        -- The native bar.Name is hidden via SetAlpha(0) (taint-safe region-hide, same as
        -- Pip/BarBG). The native bar.Duration is left PASSTHROUGH at Blizzard's default
        -- font: its text is the secret remaining-time, which cannot be owned without a
        -- secret read, so we never blank or restyle it.
        if w.name then
            local Helpers = ns.Helpers
            if Helpers and Helpers.GetGeneralFont and w.name.SetFont then
                local font = Helpers.GetGeneralFont()
                local outline = Helpers.GetGeneralFontOutline and Helpers.GetGeneralFontOutline() or ""
                if font then w.name:SetFont(font, settings.nameSize or 12, outline) end
            end
            -- Name source: curated spell name (non-secret, stable) first; native font-
            -- string text as fallback, forwarded STRAIGHT THROUGH to SetText (it may be a
            -- secret string in combat -- we never branch/compare on it).
            local entry = w.entry
            local sid = entry and (entry.spellID or entry.overrideSpellID or entry.id)
            local nm
            if type(sid) == "number" and C_Spell and C_Spell.GetSpellName then
                local ok, n = pcall(C_Spell.GetSpellName, sid)
                if ok and type(n) == "string" then nm = n end
            end
            if nm then
                w.name:SetText(nm)
            elseif bar.Name and bar.Name.GetText then
                w.name:SetText(bar.Name:GetText())
            end
            w.name:ClearAllPoints()
            w.name:SetPoint("LEFT", bar, "LEFT", 4, 0)
            if w.name.SetJustifyH then w.name:SetJustifyH("LEFT") end
            w.name:Show()
            if bar.Name and bar.Name.SetAlpha then bar.Name:SetAlpha(0) end
        end
        -- G1 (border): own QUI theme border as a CHILD of the live bar frame (same chain as
        -- bg/fill/name -> deterministic z-order). Replaces the cross-chain shell.Border (a
        -- full-rect solid fill whose draw order vs the live fill is indeterminate once the
        -- strata lift is gone -> could occlude the whole bar). SAME skin-border recipe as the
        -- icon path (applyChrome / positionShell): GetSkinBorderColor(settings, "") +
        -- Core:Pixels + SetColorTexture, anchored -bs/+bs to live. Bars carry their config on
        -- `settings` (cdm_bar_renderer.lua:882), so the resolver + borderSize read from there.
        -- Honors settings.borderSize (Hide if 0). Re-applied each decorate pass like bg/icon.
        if w.border then
            local Helpers = ns.Helpers
            local Core = ns.Addon or _G.QUI
            local borderSize = settings.borderSize or 0
            if borderSize > 0 then
                local bs = (Core and Core.Pixels) and Core:Pixels(borderSize, live) or borderSize
                local r, g, b, a = 0, 0, 0, 1
                if Helpers and Helpers.GetSkinBorderColor then
                    r, g, b, a = Helpers.GetSkinBorderColor(settings, "")
                end
                w.border:SetColorTexture(r, g, b, a)
                w.border:ClearAllPoints()
                w.border:SetPoint("TOPLEFT", live, "TOPLEFT", -bs, bs)
                w.border:SetPoint("BOTTOMRIGHT", live, "BOTTOMRIGHT", bs, -bs)
                w.border:Show()
            elseif w.border.Hide then
                w.border:Hide()
            end
        end
    end
end

-- Full bar decorate pass: reskin the native bar + paint the own bar widgets. Native
-- matched frames direct-anchor with no per-slot visual shell; `shell` here is the minimal
-- direct-anchor stand-in `{ _spellEntry = ... }` (no .Bg/.BarIcon/.Border), so the only
-- field read off it is _spellEntry -- the retired _StyleBarShell shell-occluder hide is gone.
-- SetFrameStrata/SetFrameLevel/SetIgnoreParentAlpha on the live frame are removed -- they
-- were the taint vector for secret-tracked bar frames. SetAlpha is KEPT (taint-safe, the
-- re-anchor reference sets per-frame alpha: claimed 1 / unclaimed 0): a claimed frame may
-- have been alpha-0'd by a prior Sink or by the anchor guard when momentarily unclaimed, so
-- re-assert visibility here. The curated entry is cached on the live frame's widget record
-- so the shell-less re-apply hook can still resolve icon/name.
local function _BarDecorateWork(live, shell, settings)
    if live and live.SetAlpha then live:SetAlpha(1) end
    local w = _EnsureBarWidgets(live)
    if w then w.entry = (shell and shell._spellEntry) or nil end
    _BarReskinWork(live, settings)
end

-- Test seams: expose work functions for direct unit-test call recording.
-- Not used by the runtime (which reaches them through the securecall'd decorate closure).
CDMReanchorRealEnv._DecorateWork    = _DecorateWork
CDMReanchorRealEnv._BarDecorateWork = _BarDecorateWork
CDMReanchorRealEnv._BarReskinWork   = _BarReskinWork

-- Install the re-apply hooks once per live bar frame (Blizzard reverts the skin on every
-- SetBarContent/SetBarWidth + re-shows the Pip). Bodies securecalled -- CDM-frame hooks.
local function _InstallBarReskinHooks(live, getSettingsFn, key)
    if _barHooked[live] or not hooksecurefunc then return end
    _barHooked[live] = true
    local function reapply()
        _BarReskinWork(live, getSettingsFn and getSettingsFn(key) or nil)
    end
    if live.SetBarContent then hooksecurefunc(live, "SetBarContent", function() _securecall(reapply) end) end
    if live.SetBarWidth then hooksecurefunc(live, "SetBarWidth", function() _securecall(reapply) end) end
    -- Native chrome Blizzard re-shows without a SetBarContent tick (the "red on black"
    -- layer): re-hide on every Show. Pip + BarBG textures, DebuffBorder frame.
    local function hideOnShow(region)
        if region and region.Show then
            hooksecurefunc(region, "Show", function(self)
                _securecall(function()
                    if self.Hide then self:Hide() end
                    if self.SetAlpha then self:SetAlpha(0) end
                end)
            end)
        end
    end
    if live.Bar then
        hideOnShow(live.Bar.Pip)
        hideOnShow(live.Bar.BarBG)
    end
    hideOnShow(live.DebuffBorder)
end

function CDMReanchorRealEnv.BuildEnv(ctx)
    ctx = ctx or {}
    local Containers = ctx.CDMContainers or ns.CDMContainers
    local SpellData  = ctx.CDMSpellData or ns.CDMSpellData
    local Layout     = ctx.CDMLayout or ns.CDMLayout
    local Icons      = ctx.CDMIcons or ns.CDMIcons
    local Factory    = ctx.CDMIconFactory or ns.CDMIconFactory
    local Sources    = ctx.CDMSources or ns.CDMSources
    local Core       = ctx.core or _G.QUI
    local DecorateMod = ctx.CDMReanchorDecorate or ns.CDMReanchorDecorate

    local Helpers = ns.Helpers
    -- QUI border rides ON the live icon as a CHILD (icon-relative z-order). Chrome state
    -- lives in an EXTERNAL weak table keyed by the live frame -- never a key on the
    -- Blizzard-owned frame. This icon-child border is the prerequisite for dropping the
    -- live-frame strata/level lift (Task 3): z-ordered against the icon itself, the border
    -- no longer needs the lift to stay above the Blizzard icon.
    local _chrome = setmetatable({}, { __mode = "k" })
    local function applyChrome(frame, rowConfig, _firstChrome)
        -- ALL chrome writes re-assert EVERY pass, matching the re-anchor
        -- reference's per-collect-pass cadence: Blizzard re-asserts its own
        -- swipe/bling/countdown values on refresh, so a once-only write drifts
        -- back. The old firstChrome gating on the Cooldown widget writes was
        -- based on a wrong taint theory (write cadence was NOT the wedge; the
        -- reference re-applies these per pass and is taint-clean in-game). The
        -- param is kept for the decorate-module signature but no longer gates.
        -- Re-assert claimed visibility. A re-claimed frame may have been alpha-0'd
        -- by a prior Sink or by the anchor guard while momentarily unclaimed; with
        -- the park retired there is no viewer-level catch-all to restore it. SetAlpha
        -- is taint-safe -- the re-anchor reference sets per-frame alpha directly
        -- (claimed 1 / unclaimed 0) rather than parking the viewer.
        if frame and frame.SetAlpha then frame:SetAlpha(1) end
        -- Strip native Blizzard item chrome (IconOverlay bevel, OOR shadow,
        -- rounding mask) and crop the icon to QUI zoom. Runs every pass:
        -- Blizzard re-asserts the icon texcoord when it swaps the spell icon.
        if Icons and Icons.NeutralizeBlizzardItemChrome then
            Icons.NeutralizeBlizzardItemChrome(frame, rowConfig)
        end
        if type(rowConfig) ~= "table" then return end
        local cd = frame.Cooldown
        -- Match the owned-icon swipe (cdm_icon_factory CreateIconBare) so matched
        -- (native Blizzard swipe) and additional (QUI swipe) icons render identically;
        -- kill the ready-flash bling (QUI uses its own glow systems).
        if cd then
            if cd.SetSwipeTexture then cd:SetSwipeTexture("Interface\\Buttons\\WHITE8X8") end
            -- Swipe COLOUR is owned by CDMReanchorAuraPhase via its SetSwipeColor
            -- hook (non-secret reassert), which re-paints the QUI cooldown/aura
            -- colour after every Blizzard recolour. A hardcoded colour here would
            -- fight Blizzard's per-refresh ITEM_AURA_COLOR and wash out the
            -- totem/buff phase.
            if cd.SetDrawBling then cd:SetDrawBling(false) end
        end
        -- Task 5/A: style the native countdown via SetCountdownFont (AllowedWhenUntainted)
        -- instead of raw SetFont on secret-tracked fontstrings.
        -- G4: _EnsureCountFont returns a per-(size,outline) font-object name so
        --     rows with different durationSize (16 vs 14) get distinct objects.
        -- G3: durationTextColor passed to _EnsureCountFont so the font object is
        --     coloured — same rowConfig field as the owned-icon path (:2442).
        -- G2: hideDurationText forwarded to SetHideCountdownNumbers — same field as
        --     the owned-icon path (cdm_icon_renderer.lua:2440).
        -- Charge/stack count: raw SetFont on native charge/stack fontstrings removed;
        -- own-QUI-fontstring path is DEFERRED (needs combat-safe non-secret charge
        -- query -- flagged for Drew).
        if Helpers and Helpers.GetGeneralFont then
            local font = Helpers.GetGeneralFont()
            local outline = Helpers.GetGeneralFontOutline and Helpers.GetGeneralFontOutline() or ""
            local dtc = rowConfig.durationTextColor or {1, 1, 1, 1}
            if font then
                local countFontName = _EnsureCountFont(font, rowConfig.durationSize or 14, outline, dtc)
                if cd and cd.SetCountdownFont and countFontName then
                    cd:SetCountdownFont(countFontName)
                end
            end
        end
        -- G2: forward the hide-duration-text toggle to the native Cooldown.
        -- Uses rowConfig.hideDurationText — same field as the owned-icon path
        -- (cdm_icon_renderer.lua:2440). SetHideCountdownNumbers is
        -- AllowedWhenUntainted; runs within the existing securecall pass.
        if cd and cd.SetHideCountdownNumbers then
            cd:SetHideCountdownNumbers(rowConfig.hideDurationText and true or false)
        end
        -- Reference-parity PER-PASS writes on claimed frames:
        -- 1) Re-enable the cooldown swipe. Blank-on-acquire writes
        --    SetDrawSwipe(false) on every acquired native item and nothing
        --    re-enabled it on claim -- a blanked-then-claimed frame lost its
        --    cooldown swirl for the session. Swipe VISIBILITY stays owned by
        --    the aura-phase SetSwipeColor hook (alpha-0 when disabled), so an
        --    unconditional draw-enable cannot fight the user toggle. The
        --    re-anchor reference re-asserts this on every collect pass.
        if cd and cd.SetDrawSwipe then cd:SetDrawSwipe(true) end
        -- 2) Keep the NATIVE stack/charge text above the cooldown swirl:
        --    Applications/ChargeCount are child FRAMES (CooldownViewer.xml:54/
        --    :189) so a frame-level raise is valid, and Blizzard resets pooled
        --    frame levels on zone transitions, so it must re-run every pass
        --    (the reference re-raises per collect pass, +23 relative). Writes
        --    land on the CHILD frames only -- the live item frame keeps its
        --    zero strata/level-write posture. pcall'd so an unexpected
        --    region-shaped key can never break the decorate pass.
        local lvlOk, baseLvl = pcall(frame.GetFrameLevel, frame)
        if lvlOk and type(baseLvl) == "number" then
            local textLvl = baseLvl + 23
            local apps = frame.Applications
            if apps and apps.SetFrameLevel then
                pcall(apps.SetFrameLevel, apps, textLvl)
            end
            local charge = frame.ChargeCount
            if charge and charge.SetFrameLevel then
                pcall(charge.SetFrameLevel, charge, textLvl)
            end
        end
        -- QUI border as an OWN child texture of the live icon. SAME skin-border recipe as
        -- positionShell (GetSkinBorderColor + Core:Pixels + SetColorTexture, anchored
        -- -bs/+bs) -> uniform chrome with owned icons. Border ONLY: icons have no bg (the
        -- Blizzard Icon texture is the fill). Idempotent: create once, re-colour/re-anchor
        -- each pass. Only CreateTexture + SetColorTexture/SetPoint/Show/Hide on an OWN
        -- child run here -- no strata/level/ignore-alpha state write on the live frame.
        if frame.CreateTexture then
            local chrome = _chrome[frame]
            if not chrome then
                chrome = { border = frame:CreateTexture(nil, "BACKGROUND") }
                _chrome[frame] = chrome
            end
            local tex = chrome.border
            local borderSize = rowConfig.borderSize or 0
            if borderSize > 0 and tex then
                local bs = (Core and Core.Pixels) and Core:Pixels(borderSize, frame) or borderSize
                local r, g, b, a = 0, 0, 0, 1
                if Helpers and Helpers.GetSkinBorderColor then
                    r, g, b, a = Helpers.GetSkinBorderColor(rowConfig, "")
                end
                tex:SetColorTexture(r, g, b, a)
                tex:ClearAllPoints()
                tex:SetPoint("TOPLEFT", frame, "TOPLEFT", -bs, bs)
                tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", bs, -bs)
                tex:Show()
            elseif tex then
                tex:Hide()
            end
        end
        -- Stack/charge count stays native. NEVER raw-SetFont or alpha-hide the
        -- Blizzard ChargeCount / Applications fontstrings; they are already the
        -- live mirrored count source for re-anchored frames.
    end

    -- One decorator per runtime. The Blizzard frame is decorated CHROME-ONLY: neutralize
    -- its native chrome, apply the QUI font to its NATIVE count/countdown, and carry the
    -- QUI border as an OWN child of the live icon (applyChrome). It keeps rendering its
    -- own icon/swipe/count (cheap -- no per-tick API cooldown). Nothing is written onto
    -- Blizzard-owned object STATE (no strata/level/alpha) -- the border is an own child.
    local decorator
    if DecorateMod and DecorateMod.New then
        decorator = DecorateMod.New({
            hideRegion = function(frame, name)
                local region = frame[name]
                if not region then return end
                -- SetAlpha(0) + Hide(): both taint-safe on a named Blizzard child
                -- region. G6 wants SpellActivationAlert fully hidden (not just
                -- transparent) as the belt-and-suspenders first pass; the load-
                -- bearing re-hide is the ShowAlert hook (CDMReanchorProcGlow).
                if region.SetAlpha then region:SetAlpha(0) end
                if region.Hide then region:Hide() end
            end,
            applyChrome = applyChrome,
        })
    end
    local decorate = function(live, shell, rowConfig, key)
        -- trackedBar: re-anchored frames are StatusBars -> bar reskin (hide native icon +
        -- restyle the native StatusBar), NOT the icon decorate. Both run under securecall
        -- so the item-level writes don't taint the secret-tracked CDM frame's OnEvent.
        if key == "trackedBar" then
            _securecall(_BarDecorateWork, live, shell, ctx.getSettings and ctx.getSettings(key) or nil)
            _InstallBarReskinHooks(live, ctx.getSettings, key)
            return true
        end
        if decorator then
            -- Chrome-decorate the Blizzard frame: neutralize its native item chrome, style
            -- the native countdown, and carry the QUI border as an OWN child of the live
            -- icon. _DecorateWork sets NO strata/level on the live frame (de-tainted) -- the
            -- icon-child border is z-ordered against the icon itself, so it needs no lift; the
            -- cross-chain shell.Border is hidden (would otherwise double-border the icon).
            return _securecall(_DecorateWork, decorator, live, shell, rowConfig)
        end
    end

    -- Lightweight slot hosts: per-slot QUI frames that host hover/click overlays.
    -- In the native model they are NOT visual shells and are never the anchor target
    -- for Blizzard frames. Pooled per container; reused across refreshes, surplus
    -- hidden only after a generation pass proves it is stale.
    local shellPools = setmetatable({}, { __mode = "k" })
    local function getShellPool(container)
        local p = shellPools[container]
        if not p then p = { list = {}, used = 0, generation = 0 }; shellPools[container] = p end
        return p
    end

    local function isInCombatLockdown()
        if ctx.isInCombat then return ctx.isInCombat() end
        return (InCombatLockdown and InCombatLockdown()) or false
    end

    local function isInitSafeWindow()
        if ctx.isInitSafeWindow then return ctx.isInitSafeWindow() end
        return ns._inInitSafeWindow == true
    end

    -- Out of combat (or in the init-safe window) every slot-host op is legal. In
    -- combat a QUI-owned host/container is mutable only when it is not protected
    -- and not anchoring-restricted. Essential/Utility hosts can carry visible
    -- SecureActionButtonTemplate descendants, so their layout usually defers in
    -- combat. BuffIcon has no secure click slot, and trackedBar renders through
    -- owned StatusBars fed by Blizzard's BuffBarCooldownViewer.
    local function canMutateProtectedShells(frame)
        if (not isInCombatLockdown()) or isInitSafeWindow() then return true end
        if not (frame and Helpers) then return false end
        return not (Helpers.FrameIsProtected(frame)
            or Helpers.FrameIsAnchoringRestricted(frame))
    end

    local function hideShell(shell)
        if not shell then return end
        local overlay = shell._quiCdmHoverOverlay
        if overlay and overlay.Hide and ((not overlay.IsShown) or overlay:IsShown()) then
            overlay:Hide()
        end
        if shell.Hide and ((not shell.IsShown) or shell:IsShown()) then
            shell:Hide()
        end
        shell._spellEntry = nil
        shell._quiTooltipContext = nil
        shell.__quiTooltipContext = nil
        shell.__customTrackerIcon = nil
    end

    local function beginShellPass(container)
        local p = getShellPool(container)
        p.generation = (p.generation or 0) + 1
        p.used = 0
        return p.generation
    end

    local function endShellPass(container)
        local p = shellPools[container]
        if not p then return true end
        if not canMutateProtectedShells() then
            p.cleanupPending = true
            return false
        end
        local generation = p.generation or 0
        for i = 1, #p.list do
            local shell = p.list[i]
            if shell and shell._quiCdmShellGeneration ~= generation then
                hideShell(shell)
            end
        end
        p.cleanupPending = nil
        return true
    end

    local function resetShells(container)
        local p = shellPools[container]
        if not p then return end
        if not canMutateProtectedShells() then
            p.cleanupPending = true
            return false
        end
        for i = 1, #p.list do
            local s = p.list[i]
            hideShell(s)
        end
        p.used = 0
        return true
    end
    local function getContainerFor(key)
        if Containers and Containers.GetContainer then return Containers.GetContainer(key) end
        return nil
    end

    local function getShellTooltipContext(_containerKey)
        return "cdm"
    end

    local function runShellTooltipScript(shell, scriptName)
        if not (shell and shell.GetScript) then return end
        local script = shell:GetScript(scriptName)
        if script then script(shell) end
    end

    local function ensureHoverOverlay(shell)
        if not (shell and shell.CreateTexture and CreateFrame) then return nil end
        local overlay = shell._quiCdmHoverOverlay
        if not overlay then
            overlay = CreateFrame("Frame", nil, shell)
            overlay._quiCdmHoverOverlay = true
            overlay:SetAllPoints(shell)
            overlay:EnableMouse(true)
            if overlay.SetMouseClickEnabled then
                overlay:SetMouseClickEnabled(false)
            end
            if overlay.SetMouseMotionEnabled then
                overlay:SetMouseMotionEnabled(true)
            end
            overlay:SetScript("OnEnter", function(self)
                runShellTooltipScript(self:GetParent(), "OnEnter")
            end)
            overlay:SetScript("OnLeave", function(self)
                runShellTooltipScript(self:GetParent(), "OnLeave")
            end)
            shell._quiCdmHoverOverlay = overlay
        end
        overlay:SetAllPoints(shell)
        overlay:Show()
        return overlay
    end

    local function raiseHoverOverlay(shell)
        local overlay = shell and shell._quiCdmHoverOverlay
        if not overlay then return end
        if overlay.SetFrameStrata and shell.GetFrameStrata then
            overlay:SetFrameStrata(shell:GetFrameStrata())
        end
        if overlay.SetFrameLevel and shell.GetFrameLevel then
            overlay:SetFrameLevel(shell:GetFrameLevel() + 4)
        end
    end

    local function ensureShellTooltip(shell)
        if not shell then return end
        if not shell._quiCdmTooltipWired then
            shell._quiCdmTooltipWired = true
            shell:EnableMouse(true)
            if shell.SetMouseClickEnabled then
                shell:SetMouseClickEnabled(false)
            end
            if shell.SetMouseMotionEnabled then
                shell:SetMouseMotionEnabled(true)
            end
            shell:SetScript("OnEnter", function(self)
                local Factory = ns.CDMIconFactory
                if Factory and Factory.ShowEntryTooltip then
                    Factory.ShowEntryTooltip(self, self._spellEntry, self._quiTooltipContext or "cdm")
                end
            end)
            shell:SetScript("OnLeave", function()
                local Factory = ns.CDMIconFactory
                if Factory and Factory.HideEntryTooltip then
                    Factory.HideEntryTooltip()
                elseif GameTooltip and GameTooltip.Hide then
                    GameTooltip.Hide(GameTooltip)
                end
            end)
        end
        ensureHoverOverlay(shell)
    end

    -- Matched native frames no longer have a visual shell to host tooltip scripts.
    -- ensureLiveTooltip provides the entry tooltip via an OWN-CHILD mouse-catcher
    -- overlay on the LIVE frame -- mirroring the old shell hover overlay, but
    -- mounted on the live frame.
    --
    -- CRITICAL TAINT DIFFERENCE vs ensureShellTooltip: that fn SetScript'd/EnableMouse'd the
    -- SHELL (a QUI frame). Here the target is the LIVE Blizzard frame, so we must NEVER
    -- SetScript/EnableMouse/HookScript IT -- that would clobber Blizzard's native scripts and
    -- risk taint. EVERY mouse/script write rides OUR overlay (a QUI CreateFrame child). The
    -- ONLY live-frame touches are the taint-safe CreateFrame(child) and a NON-SECRET
    -- live:GetFrameLevel() read for the raise. The overlay is raised +4 above the live frame's
    -- own content (icon/swipe) so it catches the mouse over the icon. The overlay is cached in
    -- an EXTERNAL weak table keyed by the live frame -- never a custom key on the Blizzard
    -- frame -- and the entry rides OUR overlay (overlay._entry), read back by the scripts.
    local _liveTooltip = setmetatable({}, { __mode = "k" })
    local function ensureLiveTooltip(live, entry)
        if not (live and CreateFrame) then return nil end
        local overlay = _liveTooltip[live]
        if not overlay then
            overlay = CreateFrame("Frame", nil, live)
            overlay:SetAllPoints(live)
            overlay:EnableMouse(true)
            if overlay.SetMouseClickEnabled then
                overlay:SetMouseClickEnabled(false)
            end
            if overlay.SetMouseMotionEnabled then
                overlay:SetMouseMotionEnabled(true)
            end
            -- Raise OUR overlay above the live frame's own content so it catches the mouse
            -- over the icon/swipe. SetFrameLevel is on OUR overlay (taint-safe); reading
            -- live:GetFrameLevel() is a non-secret read on the Blizzard frame.
            if overlay.SetFrameLevel then
                local baseLevel = (live.GetFrameLevel and live:GetFrameLevel()) or 0
                overlay:SetFrameLevel(baseLevel + 4)
            end
            overlay:SetScript("OnEnter", function(self)
                local Factory = ns.CDMIconFactory
                if Factory and Factory.ShowEntryTooltip then
                    Factory.ShowEntryTooltip(self, self._entry, "cdm")
                end
            end)
            overlay:SetScript("OnLeave", function()
                local Factory = ns.CDMIconFactory
                if Factory and Factory.HideEntryTooltip then
                    Factory.HideEntryTooltip()
                elseif GameTooltip and GameTooltip.Hide then
                    GameTooltip.Hide(GameTooltip)
                end
            end)
            _liveTooltip[live] = overlay
        end
        -- Refresh the entry on OUR overlay + re-span/show it (the live frame's rect may have
        -- moved between passes). All writes are on the QUI overlay -- taint-safe.
        -- Re-enable mouse on reuse: hideLiveTooltip calls EnableMouse(false) when sinking;
        -- a re-claimed frame must restore mouse-motion so the tooltip fires again.
        overlay._entry = entry
        overlay:SetAllPoints(live)
        overlay:EnableMouse(true)
        overlay:Show()
        return overlay
    end

    -- hideLiveTooltip: tear down the direct-anchor tooltip overlay for a sunk/retired
    -- buff slot.  bridge:Sink only SetAlpha(0)'s the live frame; an alpha-0 frame
    -- STILL receives mouse events, so without this the overlay keeps showing a stale
    -- _entry tooltip (phantom tooltip / dead-zone).  All ops are on OUR overlay, never
    -- the live Blizzard frame.  Nil-safe: no overlay -> no-op.
    local function hideLiveTooltip(live)
        if not live then return end
        local overlay = _liveTooltip[live]
        if not overlay then return end
        overlay:Hide()
        overlay:EnableMouse(false)
    end

    local function mintShell(_entry, containerKey)
        local container = getContainerFor(containerKey)
        if not (container and container.CreateTexture) then return nil end
        local p = getShellPool(container)
        local nextIndex = (p.used or 0) + 1
        local shell = p.list[nextIndex]
        if not shell then
            -- Legacy visual shell fallback. Normal matched native entries use
            -- mintClickSlot/positionClickSlot instead; keep this for older tests and
            -- defensive callers that still pass explicit shell wrappers.
            if not canMutateProtectedShells(container) then
                p.cleanupPending = true
                return nil
            end
            shell = CreateFrame("Frame", nil, container)
            shell._quiCdmShell = true
            shell.Border = shell:CreateTexture(nil, "BACKGROUND", nil, -8)
            p.list[nextIndex] = shell
        elseif shell.IsShown and not shell:IsShown() and not canMutateProtectedShells(shell) then
            p.cleanupPending = true
            return nil
        end
        p.used = nextIndex
        shell._quiCdmShellGeneration = p.generation or 0
        local tooltipContext = getShellTooltipContext(containerKey)
        shell._spellEntry = _entry
        shell._quiTooltipContext = tooltipContext
        shell.__quiTooltipContext = tooltipContext
        shell.__customTrackerIcon = nil
        if canMutateProtectedShells(shell) then
            ensureShellTooltip(shell)
        end
        if shell.Show and ((not shell.IsShown) or not shell:IsShown()) then
            shell:Show()
        end
        return shell
    end
    local function mintClickSlot(_entry, containerKey)
        local container = getContainerFor(containerKey)
        if not container then return nil end
        local p = getShellPool(container)
        local nextIndex = (p.used or 0) + 1
        local slot = p.list[nextIndex]
        if not slot then
            if not canMutateProtectedShells(container) then
                p.cleanupPending = true
                return nil
            end
            slot = CreateFrame("Frame", nil, container)
            slot._quiCdmClickSlot = true
            p.list[nextIndex] = slot
        elseif slot.IsShown and not slot:IsShown() and not canMutateProtectedShells(slot) then
            p.cleanupPending = true
            return nil
        end
        p.used = nextIndex
        slot._quiCdmShellGeneration = p.generation or 0
        local tooltipContext = getShellTooltipContext(containerKey)
        slot._spellEntry = _entry
        slot._quiTooltipContext = tooltipContext
        slot.__quiTooltipContext = tooltipContext
        slot.__customTrackerIcon = nil
        if canMutateProtectedShells(slot) then
            ensureShellTooltip(slot)
        end
        if slot.Show and ((not slot.IsShown) or not slot:IsShown()) then
            slot:Show()
        end
        return slot
    end
    local function positionShell(shell, container, x, y, w, h, rowConfig)
        if not (shell and shell.ClearAllPoints) then return end
        if not canMutateProtectedShells(shell) then
            return false
        end
        shell:ClearAllPoints()
        shell:SetPoint("CENTER", container, "CENTER", x, y)
        if w and h and shell.SetSize then shell:SetSize(w, h) end
        -- QUI border: SAME skin-border resolver as owned icons -> uniform chrome.
        local borderSize = (type(rowConfig) == "table" and rowConfig.borderSize) or 0
        local tex = shell.Border
        if borderSize > 0 and tex then
            local bs = (Core and Core.Pixels) and Core:Pixels(borderSize, shell) or borderSize
            local r, g, b, a = 0, 0, 0, 1
            if Helpers and Helpers.GetSkinBorderColor then
                r, g, b, a = Helpers.GetSkinBorderColor(rowConfig, "")
            end
            tex:SetColorTexture(r, g, b, a)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", shell, "TOPLEFT", -bs, bs)
            tex:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", bs, -bs)
            tex:Show()
        elseif tex then
            tex:Hide()
        end
        raiseHoverOverlay(shell)
        return true
    end
    local function positionClickSlot(container, live, entry, containerKey, x, y, w, h)
        if not (container and live and w and h) then return nil end
        local slot = mintClickSlot(entry, containerKey)
        if not slot then return nil end
        if not canMutateProtectedShells(slot) then
            return nil
        end
        slot:ClearAllPoints()
        slot:SetPoint("CENTER", container, "CENTER", x, y)
        if slot.SetSize then slot:SetSize(w, h) end
        if slot.SetFrameStrata then
            local strata = (live.GetFrameStrata and live:GetFrameStrata())
                or (container.GetFrameStrata and container:GetFrameStrata())
            if strata then slot:SetFrameStrata(strata) end
        end
        if slot.SetFrameLevel then
            local liveLevel = live.GetFrameLevel and live:GetFrameLevel()
            local containerLevel = container.GetFrameLevel and container:GetFrameLevel()
            slot:SetFrameLevel(((liveLevel or containerLevel or 0) + 8))
        end
        raiseHoverOverlay(slot)
        return slot
    end
    local function updateClickOverlay(shell, entry, viewerType)
        if Icons and Icons.UpdateSecureClickOverlay then
            Icons.UpdateSecureClickOverlay(shell, entry, viewerType)
        end
    end

    -- Aura ground truth for non-Blizzard/custom BuffIcon owned fallbacks.
    -- Blizzard-CDM-backed buff icons are native-only: the runtime renders
    -- Blizzard's BuffIconCooldownViewer child or nothing. This query must not
    -- synthesize replacements for Blizzard-tracked buffs. Secret results are
    -- treated as no-signal.
    local function entryAuraIsPresent(entry)
        if type(entry) ~= "table" then return false end
        local query = Sources and Sources.QueryPlayerAuraBySpellID
        if not query then return false end
        local function present(id)
            if type(id) ~= "number" or _issecretvalue(id) then return false end
            local ok, aura = pcall(query, id)
            return (ok and aura ~= nil and not _issecretvalue(aura)) or false
        end
        if present(entry.overrideSpellID) or present(entry.spellID) or present(entry.id) then
            return true
        end
        local linked = entry.linkedSpellIDs
        if type(linked) == "table" then
            for i = 1, #linked do
                if present(linked[i]) then return true end
            end
        end
        return false
    end

    -- Managed aura mirrors: the owned spell icon is the always-available base;
    -- an engine-owned CustomAuraButton overlays it only while the configured
    -- player aura is present. The aura child is styled and anchored to a stable
    -- QUI host at BIRTH, before Blizzard applies aura-secret access denial.
    local function rowConfigForEntry(entry, containerKey)
        local settings = ctx.getSettings and ctx.getSettings(containerKey) or {}
        if Layout and Layout.BuildRows then
            local rows = Layout.BuildRows(settings)
            local wanted = entry and entry._assignedRow
            for i = 1, #rows do
                if rows[i].rowNum == wanted then return rows[i] end
            end
            if rows[1] then return rows[1] end
        end
        return {
            size = settings.iconSize or 42,
            borderSize = settings.borderSize or 2,
            borderColorSource = settings.borderColorSource,
            borderColor = settings.borderColor or settings.borderColorTable,
            durationSize = settings.durationSize or 14,
            durationOffsetX = settings.durationOffsetX or 0,
            durationOffsetY = settings.durationOffsetY or 8,
            durationTextColor = settings.durationTextColor,
            durationAnchor = settings.durationAnchor or "TOP",
            hideDurationText = settings.hideDurationText,
            stackSize = settings.stackSize or 14,
            stackOffsetX = settings.stackOffsetX or 0,
            stackOffsetY = settings.stackOffsetY or -8,
            stackTextColor = settings.stackTextColor,
            stackAnchor = settings.stackAnchor or "BOTTOM",
            hideStackText = settings.hideStackText,
        }
    end

    local function auraProfileFromRow(rowConfig)
        rowConfig = rowConfig or {}
        local br, bg, bb, ba = 0, 0, 0, 1
        if Helpers and Helpers.GetSkinBorderColor then
            br, bg, bb, ba = Helpers.GetSkinBorderColor(rowConfig, "")
        elseif type(rowConfig.borderColor) == "table" then
            br, bg, bb, ba = rowConfig.borderColor[1] or 0,
                rowConfig.borderColor[2] or 0, rowConfig.borderColor[3] or 0,
                rowConfig.borderColor[4] or 1
        end
        return {
            iconSize = rowConfig.size or 42,
            borderColor = { br, bg, bb, ba },
            duration = {
                fontSize = rowConfig.durationSize or 14,
                anchor = rowConfig.durationAnchor or "CENTER",
                offsetX = rowConfig.durationOffsetX or 0,
                offsetY = rowConfig.durationOffsetY or 0,
                color = rowConfig.durationTextColor,
                show = rowConfig.hideDurationText ~= true,
            },
            stack = {
                fontSize = rowConfig.stackSize or 14,
                anchor = rowConfig.stackAnchor or "BOTTOMRIGHT",
                offsetX = rowConfig.stackOffsetX or 0,
                offsetY = rowConfig.stackOffsetY or 0,
                color = rowConfig.stackTextColor,
                show = rowConfig.hideStackText ~= true,
            },
        }
    end

    local auraMirrors
    if ns.CDMManagedAuraMirrors and ns.CDMManagedAuraMirrors.New then
        auraMirrors = ns.CDMManagedAuraMirrors.New({
            createFrame = CreateFrame,
            isSecret = _issecretvalue,
            canCreate = function()
                return (not isInCombatLockdown()) or isInitSafeWindow()
            end,
            canMutate = canMutateProtectedShells,
            aurasAreSecret = function()
                return C_Secrets and C_Secrets.ShouldAurasBeSecret
                    and C_Secrets.ShouldAurasBeSecret() or false
            end,
            styleFrame = function(frame, profile)
                local skin = ns.AuraSkin or (ns.Addon and ns.Addon.AuraSkin)
                if skin and skin.WireButton then skin.WireButton(frame, profile) end
            end,
            restyleFrame = function(frame, rowConfig)
                local skin = ns.AuraSkin or (ns.Addon and ns.Addon.AuraSkin)
                if skin and skin.WireButton then
                    skin.WireButton(frame, auraProfileFromRow(rowConfig))
                end
            end,
            positionBase = function(icon, host, rowConfig)
                if icon.GetScale and icon:GetScale() ~= 1 then icon:SetScale(1) end
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", host, "CENTER", 0, 0)
                icon:Show()
                if Icons and Icons.OnContainerIconPlaced then
                    Icons.OnContainerIconPlaced(icon, rowConfig)
                end
            end,
        })
    end

    local function beginAuraMirrorPass(container)
        return auraMirrors and auraMirrors:BeginPass(container) or false
    end

    local function acquireAuraMirror(entry, containerKey, placementKey)
        if not auraMirrors then return nil end
        local swipe = ns._OwnedSwipe and ns._OwnedSwipe.GetSettings
            and ns._OwnedSwipe.GetSettings() or nil
        if swipe and swipe.showCooldownIconAuraPhase == false then return nil end
        local container = getContainerFor(containerKey)
        if not container then return nil end
        local profile = auraProfileFromRow(rowConfigForEntry(entry, containerKey))
        return auraMirrors:Acquire(container, placementKey, entry, profile)
    end

    local function positionAuraMirror(record, baseIcon, container, x, y, w, h, rowConfig)
        return auraMirrors and auraMirrors:Position(
            record, baseIcon, container, x, y, w, h, rowConfig) or false
    end

    local function endAuraMirrorPass(container)
        return auraMirrors and auraMirrors:EndPass(container) or true
    end

    return {
        CDMReanchor        = ns.CDMReanchor,
        CDMReanchorWiring  = ns.CDMReanchorWiring,
        CDMReanchorRuntime = ns.CDMReanchorRuntime,
        CDMPlacementPlanner = ns.CDMPlacementPlanner,
        uiParent = ctx.uiParent or _G.UIParent,
        index = ctx.CDMIndex or ns.CDMIndex,
        getContainer = function(key)
            if Containers and Containers.GetContainer then return Containers.GetContainer(key) end
            return nil
        end,
        getCurated = function(key)
            if SpellData and SpellData.BuildSpellListFromOwned then
                return SpellData:BuildSpellListFromOwned(key)
            end
            return {}
        end,
        getSettings = ctx.getSettings,
        resolveAdditional = ctx.resolveAdditional or function() return {} end,
        onMetrics = ctx.onMetrics,
        -- Combat-lockdown predicate shared with the shell deps. applySize gates its
        -- protected container:SetSize on this (the container parents secure click
        -- overlays, so SetSize is blocked in combat); deferred resize recovers on
        -- PLAYER_REGEN_ENABLED. true = mutation allowed (out of combat or init-safe window).
        canMutate = canMutateProtectedShells,
        buildLayout = Layout and Layout.BuildIconLayout or nil,
        -- Flat-schema fallback layout: used by the runtime when the row-based
        -- BuildIconLayout bails (no row1/2/3 schema). Dispatch by surface: trackedBar
        -- settings carry barWidth (StatusBar dims) -> bar-stack layout; buff settings
        -- carry iconSize -> single-line icon grid.
        buildBuffLayout = Layout and function(s, icons, opts, key)
            -- Dispatch by KEY (reliable): trackedBar uses the bar-stack layout (barWidth is
            -- often defaulted downstream, not stored on the DB, so a schema check misses it);
            -- buff uses the single-line icon grid.
            if key == "trackedBar" and Layout.BuildBuffBarLayout then
                return Layout.BuildBuffBarLayout(s, icons, opts)
            end
            return (Layout.BuildBuffGridLayout and Layout.BuildBuffGridLayout(s, icons, opts)) or nil
        end or nil,
        -- Active-mode filter inputs. frameIsActive reads the live Blizzard item's
        -- CooldownViewerItemMixin:IsActive(), issecretvalue-guarded + fail-open (a
        -- combat-secret active state returns true so a possibly-active frame is never
        -- hidden). inCombat resolves the "combat" display mode.
        frameIsActive = function(frame, containerKey, entry)
            if not frame then return true end
            -- BuffIcon: IsActive is authoritative. It reads Blizzard's plain
            -- isActive field, and CooldownViewerBuffItemMixin:ShouldBeActive
            -- already reports totems (totemData not expired) and infinite auras
            -- (expirationTime == 0) as active -- so a readable FALSE means the
            -- aura really ended and the entry must clear even while Blizzard
            -- keeps the frame natively SHOWN (Hide-When-Inactive off, settings
            -- dialog visible). The old IsShown-first fast-path classified those
            -- expired-but-shown frames active forever. Only when IsActive is
            -- unreadable (combat-secret) fall back to the native shown state,
            -- failing open so a possibly-active frame is never hidden.
            if IsBuffIconKey(containerKey) then
                -- Pure native-usability predicate. Deliberately no aura-truth
                -- override here: a stale hidden native frame must not be
                -- claimed just because the aura is live. Blizzard-CDM buffs
                -- wait for the native frame; custom/owned fallbacks are handled
                -- separately by the runtime.
                if frame.IsActive then
                    local ok, active = pcall(frame.IsActive, frame)
                    if ok and not _issecretvalue(active) then
                        return active and true or false
                    end
                end
                if frame.IsShown then
                    local ok, shown = pcall(frame.IsShown, frame)
                    if not ok then return true end
                    if _issecretvalue(shown) then return true end
                    return shown and true or false
                end
                return true
            end
            if not frame.IsActive then return true end
            local ok, active = pcall(frame.IsActive, frame)
            if not ok then return true end
            if _issecretvalue(active) then return true end
            return active and true or false
        end,
        -- Aura ground truth for non-Blizzard/custom owned fallbacks (see the
        -- helper's header above BuildEnv's return).
        entryAuraIsPresent = entryAuraIsPresent,
        inCombat = function() return isInCombatLockdown() end,
        -- Active-mode filter must NOT hide frames while the user positions the
        -- container in a QUI surface: QUI layout mode or the CDM edit overlay.
        -- Blizzard Edit Mode deliberately does NOT expand the runtime: the
        -- native Cooldown Manager owns its own frames there, and expanding on
        -- it made opening Edit Mode flash CDM placeholders over the containers.
        isEditMode = function()
            if Helpers and Helpers.IsLayoutModeActive and Helpers.IsLayoutModeActive() then
                return true
            end
            local cdmEdit = _G.QUI_IsCDMEditModeActive
            if cdmEdit and cdmEdit() then return true end
            return false
        end,
        pixelRound = function(v, c)
            if Core and Core.PixelRound then return Core:PixelRound(v, c) end
            return v
        end,
        -- POOL MEMBERSHIP: legacy BuildIcons is the only other pool writer, so
        -- an engine-minted owned icon that skips registration is invisible to
        -- every content driver -- cdm_icon_runtime_refresh (stack text, aura
        -- wakes, cooldown refresh) and cdm_effects (glow/desat) walk
        -- Factory:GetIconPool(viewerType). Keyed acquire registers; keyed
        -- release removes. Un-keyed calls keep the legacy shape untouched.
        acquireIcon = function(c, e, containerKey)
            if not (Factory and Factory.AcquireIcon) then return nil end
            -- Only a clickableIcons container's owned icons ever get a secure
            -- clickButton; pass that through so AcquireIcon can reuse a protected
            -- icon from the dedicated pool (mutation-safe) instead of minting a
            -- fresh one every refresh (bounded, stable identity).
            local clickable = false
            if containerKey and ctx.getSettings then
                local s = ctx.getSettings(containerKey)
                clickable = (s and s.clickableIcons) and true or false
            end
            local icon = Factory:AcquireIcon(c, e, clickable)
            if icon and containerKey and Factory.EnsurePool then
                local pool = Factory:EnsurePool(containerKey)
                pool[#pool + 1] = icon
            end
            return icon
        end,
        -- Companion to acquireIcon: Factory recycle (Hide + ClearAllPoints +
        -- pool return) for the runtime's per-pass owned-icon release.
        releaseIcon = function(icon, containerKey)
            if not (Factory and Factory.ReleaseIcon) then return end
            -- Recycle FIRST: if the Factory refuses (protected in combat) it
            -- returns false; keep pool membership so the icon stays tracked and
            -- the caller (ReleaseOwnedIcons) can retry it on the regen drain.
            local ok = Factory:ReleaseIcon(icon)
            if ok == false then return false end
            if containerKey and Factory.GetIconPool then
                local pool = Factory:GetIconPool(containerKey)
                for i = #pool, 1, -1 do
                    if pool[i] == icon then
                        table.remove(pool, i)
                        break
                    end
                end
            end
            return ok
        end,
        onIconPlaced = function(icon, rowConfig)
            if Icons and Icons.OnContainerIconPlaced then Icons.OnContainerIconPlaced(icon, rowConfig) end
        end,
        decorate = decorate,
        -- Exposed for direct unit testing of the icon-child border (not used by the
        -- runtime, which reaches applyChrome through decorate -> decorator:Decorate).
        applyChrome = applyChrome,
        mintShell = mintShell,
        positionShell = positionShell,
        positionClickSlot = positionClickSlot,
        beginAuraMirrorPass = beginAuraMirrorPass,
        acquireAuraMirror = acquireAuraMirror,
        positionAuraMirror = positionAuraMirror,
        endAuraMirrorPass = endAuraMirrorPass,
        -- Native direct-anchor tooltip overlay on the LIVE frame.
        ensureLiveTooltip = ensureLiveTooltip,
        -- Teardown companion: hides + disables mouse on the overlay for a sunk/retired
        -- direct-anchor frame so alpha-0 frames no longer catch the mouse.
        hideLiveTooltip = hideLiveTooltip,
        updateClickOverlay = updateClickOverlay,
        beginShellPass = beginShellPass,
        endShellPass = endShellPass,
        resetShells = resetShells,
    }
end
