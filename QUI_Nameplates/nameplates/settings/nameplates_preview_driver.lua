--[[
    QUI Options V2 — Nameplates preview driver.

    Builds a mock enemy plate inside the preview band that sits above the
    settings tabs. The widget tree comes from the suite's REAL builders
    (NPHealth/NPCastbar/NPExtras Build + ApplyAppearance), so every
    appearance setting renders exactly as in the world; only the DATA is
    faked (no unit, no secrets, no events). Aura icons are a lightweight
    stand-in honoring the row settings — the real engine is delta-driven
    and deliberately not spun up from the options window.

    Exports (ns): QUI_BuildNameplatePreview(host), QUI_RefreshNameplatePreview().
]]

local ADDON_NAME, ns = ...

local UIKit = ns.UIKit
local Helpers = ns.Helpers

local PREVIEW_HP = 65        -- fake health percent
local PREVIEW_ABSORB = 12    -- fake absorb (same 0..100 domain)
local CAST_PROGRESS = 0.62
local FAKE_AURAS = {
    { icon = 136118, stacks = "3", duration = "8" },
    { icon = 135817, stacks = "",  duration = "14" },
    { icon = 136139, stacks = "",  duration = "2.4" },
}

local state = {
    host = nil,
    plate = nil,
    auraIcons = {},
}

local function NP()
    return ns.QUI_Nameplates
end

local function GetSettings()
    local profile = Helpers and Helpers.GetProfile and Helpers.GetProfile()
    return profile and profile.nameplates or nil
end

---------------------------------------------------------------------------
-- FAKE AURA ROW (settings-honoring stand-in)
---------------------------------------------------------------------------
local function PaintFakeAuras(plate, settings)
    local QUICore = ns.Addon
    local auras = settings.auras or {}
    local ch = auras.debuffs or {}
    local durS = auras.duration or {}
    local icons = state.auraIcons

    local enabled = auras.enabled ~= false and ch.enabled ~= false
    local size = ch.size or 26
    local spacing = ch.spacing or 2
    local growth = ch.growth or "RIGHT"
    local shown = enabled and math.min(#FAKE_AURAS, ch.limit or 4) or 0

    local row = plate.npPreviewAuraRow
    if not row then
        row = CreateFrame("Frame", nil, plate)
        row:SetSize(1, 1)
        plate.npPreviewAuraRow = row
    end
    -- Same anchoring contract as the live rows: row point → health bar point.
    row:ClearAllPoints()
    row:SetPoint(
        ch.point or "BOTTOM",
        plate.healthBar,
        ch.relativePoint or "TOP",
        QUICore:Pixels(ch.offsetX or 0, plate),
        QUICore:Pixels(ch.offsetY or 20, plate))

    local fontPath = UIKit.ResolveFontPath()
    for i = 1, #FAKE_AURAS do
        local holder = icons[i]
        if not holder and i <= shown then
            holder = CreateFrame("Frame", nil, row)
            holder.iconFrame = UIKit.CreateIcon(holder, size, 1, 0, 0, 0, 1)
            holder.stackText = UIKit.CreateText(holder.iconFrame, 11, nil, "OUTLINE", "OVERLAY")
            holder.stackText:SetPoint("BOTTOMRIGHT", holder.iconFrame, "BOTTOMRIGHT", 1, -1)
            holder.durationText = UIKit.CreateText(holder.iconFrame, 12, nil, "OUTLINE", "OVERLAY")
            icons[i] = holder
        end
        if holder then
            if i > shown then
                holder:Hide()
            else
                local fake = FAKE_AURAS[i]
                UIKit.UpdateIconLayout(holder.iconFrame, size, 1)
                QUICore:SetPixelPerfectSize(holder, size, size)
                holder:ClearAllPoints()
                local offset = (i - 1) * (size + spacing)
                if growth == "LEFT" then
                    holder:SetPoint("RIGHT", row, "RIGHT", -QUICore:Pixels(offset, plate), 0)
                elseif growth == "CENTER" then
                    holder:SetPoint("CENTER", row, "CENTER", QUICore:Pixels(offset, plate), 0)
                else
                    holder:SetPoint("LEFT", row, "LEFT", QUICore:Pixels(offset, plate), 0)
                end
                holder.iconFrame.texture:SetTexture(fake.icon)
                QUICore:ApplyFont(holder.stackText, nil, ch.textSize or 11, fontPath, "OUTLINE")
                holder.stackText:SetText(fake.stacks)

                -- Duration text mirrors the aura duration settings.
                if durS.enabled ~= false then
                    QUICore:ApplyFont(holder.durationText, nil, durS.size or 12, fontPath, "OUTLINE")
                    holder.durationText:ClearAllPoints()
                    holder.durationText:SetPoint(
                        durS.point or "CENTER",
                        holder.iconFrame,
                        durS.point or "CENTER",
                        durS.offsetX or 0,
                        durS.offsetY or 0)
                    local text = fake.duration
                    if durS.decimals ~= true and text:find("%.") then
                        text = text:match("^(%d+)") or text
                    end
                    holder.durationText:SetText(text)
                    holder.durationText:Show()
                else
                    holder.durationText:Hide()
                end
                holder:Show()
            end
        end
    end

    local extent = shown > 0 and (shown * size + (shown - 1) * spacing) or 1
    QUICore:SetPixelPerfectSize(row, extent, math.max(size, 1))
end

---------------------------------------------------------------------------
-- FAKE DATA PAINT
---------------------------------------------------------------------------
local function PaintFakeData(plate, settings)
    local np = NP()
    local QUICore = ns.Addon

    -- Health: hostile in-combat enemy through the REAL color resolver.
    plate.healthBar:SetMinMaxValues(0, 100)
    plate.healthBar:SetValue(PREVIEW_HP)
    local fakeState = {
        npReaction = "hostile",
        npInCombat = true,
        npIsPlayer = false,
        npTapDenied = false,
    }
    if np.Colors then
        local r, g, b = np.Colors.Resolve(fakeState, settings, { role = "DAMAGER", inInstance = false })
        plate.healthBar:SetStatusBarColor(r, g, b)
    end

    -- Absorb sliver (engine-anchored to the fill edge, static value).
    local absorbS = settings.absorbs or {}
    if plate.absorbBar then
        if absorbS.enabled ~= false then
            plate.absorbBar:SetMinMaxValues(0, 100)
            plate.absorbBar:SetValue(PREVIEW_ABSORB)
            plate.absorbBar:Show()
        else
            plate.absorbBar:Hide()
        end
    end

    -- Name + health text per style settings.
    plate.nameText:SetText(ns.L["Cleave Training Dummy"])
    plate.nameText:SetTextColor(1, 1, 1)
    local textS = settings.healthText or {}
    local style = textS.enabled == false and "none" or (textS.style or "percent")
    local pct = textS.hidePercentSymbol == true and tostring(PREVIEW_HP) or (PREVIEW_HP .. "%")
    if style == "none" then
        plate.healthText:SetText("")
    elseif style == "absolute" then
        plate.healthText:SetText("1.4M")
    elseif style == "both" then
        plate.healthText:SetText("1.4M | " .. pct)
    else
        plate.healthText:SetText(pct)
    end

    -- Castbar: mid-cast Pyroblast, interruptible.
    local cast = settings.castbar or {}
    local colors = settings.colors or {}
    local castBar = plate.castBar
    if castBar then
        if cast.enabled ~= false then
            castBar:SetMinMaxValues(0, 1)
            castBar:SetValue(CAST_PROGRESS)
            local c = colors.castInterruptible or { 0.70, 0.40, 0.90 }
            castBar:SetStatusBarColor(c[1], c[2], c[3])
            if plate.castIcon then
                plate.castIcon:SetTexture(135808)
            end
            if plate.castSpellText then
                plate.castSpellText:SetText(ns.L["Pyroblast"])
            end
            if castBar.timeText then
                castBar.timeText:SetText("1.1")
            end
            if plate.castUninterruptibleOverlay then
                plate.castUninterruptibleOverlay:SetAlpha(0)
            end
            if plate.castShield then
                plate.castShield:SetAlpha(0)
            end
            castBar:Show()

            -- Kick tick: static marker a bit past the cast edge.
            if plate.kickBar then
                if cast.kickTick ~= false then
                    local fillTex = castBar:GetStatusBarTexture()
                    if fillTex then
                        plate.kickBar:ClearAllPoints()
                        plate.kickBar:SetPoint("TOPLEFT", fillTex, "TOPRIGHT", 0, 0)
                        plate.kickBar:SetPoint("BOTTOMLEFT", fillTex, "BOTTOMRIGHT", 0, 0)
                    end
                    plate.kickBar:SetMinMaxValues(0, 1)
                    plate.kickBar:SetValue(0.18)
                    plate.kickBar:Show()
                else
                    plate.kickBar:Hide()
                end
            end
        else
            castBar:Hide()
            if plate.kickBar then plate.kickBar:Hide() end
        end
    end

    -- Raid marker (skull) + target glow, honoring their toggles.
    local markerS = settings.raidMarker or {}
    if plate.npRaidMarker then
        if markerS.enabled ~= false and SetRaidTargetIconTexture then
            pcall(SetRaidTargetIconTexture, plate.npRaidMarker, 8)
            plate.npRaidMarker:Show()
        else
            plate.npRaidMarker:Hide()
        end
    end
    local highlight = settings.highlight or {}
    if plate.npTargetGlow then
        if highlight.targetGlow ~= false then
            plate.npTargetGlow:Show()
        else
            plate.npTargetGlow:Hide()
        end
    end
    if plate.npHoverHighlight then plate.npHoverHighlight:SetAlpha(0) end
    if plate.npExecuteOverlay then plate.npExecuteOverlay:SetAlpha(0) end
    if plate.npHitboxVis then plate.npHitboxVis:Hide() end

    PaintFakeAuras(plate, settings)

    -- Scale the whole mock down when oversized bars would spill the band.
    local host = state.host
    if host and host.GetWidth then
        local hostW = host:GetWidth() or 0
        local hostH = host:GetHeight() or 0
        local health = settings.health or {}
        local auraS = (settings.auras and settings.auras.debuffs) or {}
        local plateW = (health.width or 210) + 80
        local plateH = (health.height or 24) + (cast.height or 17)
            + ((settings.name and settings.name.size or 11) + 8)
            + (auraS.size or 26) + 30
        local scale = 1
        if hostW > 0 and plateW > hostW then scale = hostW / plateW end
        if hostH > 0 and plateH * scale > hostH then scale = hostH / plateH end
        if scale < 1 then
            plate:SetScale(scale)
        else
            plate:SetScale(1)
        end
    end
end

---------------------------------------------------------------------------
-- BUILD / REFRESH
---------------------------------------------------------------------------
local function BuildPreviewPlate(host)
    local np = NP()
    if not (np and np.Health and np.Castbar) then return nil end

    local plate = CreateFrame("Frame", nil, host)
    plate:SetSize(1, 1)
    -- Slight downward bias: the mock's visual weight (name + auras) sits
    -- above the bar, so centering the anchor low keeps it balanced.
    plate:SetPoint("CENTER", host, "CENTER", 0, -14)

    np.Health.Build(plate)
    np.Castbar.Build(plate)
    if np.Extras and np.Extras.BuildPlate then
        np.Extras.BuildPlate(plate)
    end
    return plate
end

local function Refresh()
    local host = state.host
    local plate = state.plate
    if not host or not plate or not host:IsShown() then return end
    local settings = GetSettings()
    local np = NP()
    if not settings or not np then return end

    np.Health.ApplyAppearance(plate, settings)
    np.Castbar.ApplyAppearance(plate, settings)
    if np.Extras and np.Extras.ApplyAppearance then
        np.Extras.ApplyAppearance(plate, settings)
    end
    -- The lift overlay must never fire in the preview (it reparents the real
    -- bar into a HIGH-strata screen container).
    plate.npLiftOverlay = false
    if np.Castbar.ApplyLift then
        np.Castbar.ApplyLift(plate)
    end

    PaintFakeData(plate, settings)
end

-- Build (or rebind to a new host) and paint.
function ns.QUI_BuildNameplatePreview(host)
    if not host then return end
    if state.host ~= host or not state.plate then
        state.host = host
        state.auraIcons = {}
        state.plate = BuildPreviewPlate(host)
    end
    Refresh()
end

-- Settings changed while the options page is open.
function ns.QUI_RefreshNameplatePreview()
    Refresh()
end
