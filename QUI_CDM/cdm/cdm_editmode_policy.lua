-- QUI_CDM/cdm/cdm_editmode_policy.lua
-- One-shot Edit Mode policy enforcement for the CooldownViewer viewers,
-- mirroring the re-anchor reference addon:
--   * VisibleSetting = Always on ALL viewers
--   * HideWhenInactive = 1 on the buff viewers (BuffIcon + BuffBar)
-- This is what makes native item shown-state trustworthy for the claim pass:
-- with VisibleSetting=Always + HideWhenInactive=1, Blizzard shows an item
-- exactly while it is active, so the re-anchor engine can route shown frames
-- and leave hidden ones alone.
--
-- A layout stores a CooldownViewer setting ONLY when it has been changed away
-- from Blizzard's default; an ABSENT entry means "running at the default".
-- Both desired values ARE the Blizzard defaults, so fresh installs see zero
-- writes and no reload -- only stale saved values (e.g. VisibleSetting=Hidden,
-- or HideWhenInactive=0 written by the user or another addon) get a one-time
-- reset. SaveLayouts runs at most ONCE, at init, never at runtime: Blizzard
-- only applies saved layout changes on the next login, so a (dismissable)
-- reload prompt follows any actual change.
local _, ns = ...

local CDMEditModePolicy = {}
ns.CDMEditModePolicy = CDMEditModePolicy

-- Pure core: walk an Edit Mode layout's systems list and upsert the policy
-- values. `enums` carries the resolved enum values (injected for tests):
--   cooldownSystem, visSetting, visAlways, hideEnum, buffIconIdx, buffBarIdx
-- Returns true when any stored value changed. Reference semantics: an entry
-- already at the desired value is untouched; an ABSENT entry is left absent
-- when the Blizzard default equals the desired value (no forced reload for
-- users already at defaults); it is only inserted when default ~= desired.
local function UpsertSetting(settings, settingEnum, desiredValue, defaultValue)
    for _, s in ipairs(settings) do
        if s.setting == settingEnum then
            if s.value ~= desiredValue then
                s.value = desiredValue
                return true
            end
            return false
        end
    end
    if desiredValue == defaultValue then
        return false
    end
    settings[#settings + 1] = { setting = settingEnum, value = desiredValue }
    return true
end

function CDMEditModePolicy.ApplyToSystems(systems, enums)
    local changed = false
    for _, sysInfo in ipairs(systems) do
        if sysInfo.system == enums.cooldownSystem and type(sysInfo.settings) == "table" then
            -- VisibleSetting=Always on ALL viewers (default IS Always).
            if UpsertSetting(sysInfo.settings, enums.visSetting, enums.visAlways, enums.visAlways) then
                changed = true
            end
            -- HideWhenInactive=1 on the buff viewers only (default IS 1); only
            -- a stale 0 gets reset. Essential/Utility are always-shown icon
            -- rows -- HideWhenInactive is not policy-managed there.
            if sysInfo.systemIndex == enums.buffIconIdx or sysInfo.systemIndex == enums.buffBarIdx then
                if UpsertSetting(sysInfo.settings, enums.hideEnum, 1, 1) then
                    changed = true
                end
            end
        end
    end
    return changed
end

local _applied = false

function CDMEditModePolicy.Enforce()
    if _applied then return end
    if _G.QUI_IsCDMMasterEnabled and not _G.QUI_IsCDMMasterEnabled() then return end
    local C_EditMode = _G.C_EditMode
    local Enum = _G.Enum
    if not (C_EditMode and C_EditMode.GetLayouts and C_EditMode.SaveLayouts
            and Enum and Enum.EditModeSystem and Enum.EditModeSystem.CooldownViewer
            and Enum.EditModeCooldownViewerSetting and Enum.CooldownViewerVisibleSetting
            and Enum.EditModeCooldownViewerSystemIndices) then
        return
    end

    local layoutInfo = C_EditMode.GetLayouts()
    if type(layoutInfo) ~= "table" or type(layoutInfo.layouts) ~= "table" then return end

    -- Merge preset layouts in front so the activeLayout index (which counts
    -- presets first) resolves to the right entry -- same merge Blizzard's
    -- EditModeManagerFrame performs on its own layoutInfo.
    local numPresets = 0
    local presetMgr = _G.EditModePresetLayoutManager
    if presetMgr and presetMgr.GetCopyOfPresetLayouts then
        local presets = presetMgr:GetCopyOfPresetLayouts()
        if type(presets) == "table" then
            numPresets = #presets
            if _G.tAppendAll then
                _G.tAppendAll(presets, layoutInfo.layouts)
            else
                for i = 1, #layoutInfo.layouts do
                    presets[#presets + 1] = layoutInfo.layouts[i]
                end
            end
            layoutInfo.layouts = presets
        end
    end

    local activeLayout = type(layoutInfo.activeLayout) == "number"
        and layoutInfo.layouts[layoutInfo.activeLayout]
    if not activeLayout or type(activeLayout.systems) ~= "table" then return end

    -- Preset layouts are read-only: SaveLayouts cannot persist changes to
    -- them, which would loop enforce -> save -> reload forever (the preset
    -- resets on next login). Latch and leave them alone.
    if numPresets > 0 and type(layoutInfo.activeLayout) == "number"
        and layoutInfo.activeLayout <= numPresets then
        _applied = true
        return
    end

    local changed = CDMEditModePolicy.ApplyToSystems(activeLayout.systems, {
        cooldownSystem = Enum.EditModeSystem.CooldownViewer,
        visSetting = Enum.EditModeCooldownViewerSetting.VisibleSetting,
        visAlways = Enum.CooldownViewerVisibleSetting.Always,
        hideEnum = Enum.EditModeCooldownViewerSetting.HideWhenInactive,
        buffIconIdx = Enum.EditModeCooldownViewerSystemIndices.BuffIcon,
        buffBarIdx = Enum.EditModeCooldownViewerSystemIndices.BuffBar,
    })

    _applied = true
    if not changed then return end

    -- Blizzard applies saved layout changes only on the next login/reload.
    C_EditMode.SaveLayouts(layoutInfo)

    if _G.StaticPopupDialogs and _G.StaticPopup_Show then
        _G.StaticPopupDialogs["QUI_CDM_EDITMODE_RELOAD"] = {
            text = "QUI has reset stale Cooldown Manager Edit Mode settings"
                .. " (viewers must be Always visible with Hide-When-Inactive on"
                .. " for cooldown tracking to work).\n\nReload now to apply?",
            button1 = "Reload UI",
            button2 = _G.CANCEL or "Cancel",
            OnAccept = function()
                if _G.ReloadUI then _G.ReloadUI() end
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
            preferredIndex = 3,
        }
        _G.StaticPopup_Show("QUI_CDM_EDITMODE_RELOAD")
    end
end

-- Enforce once per session after the world is up: Edit Mode layouts are loaded
-- from saved variables well before PLAYER_ENTERING_WORLD, and the CDM master
-- toggle (profile DB) is resolvable by then too.
local enforceFrame = CreateFrame("Frame")
enforceFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
enforceFrame:SetScript("OnEvent", function(self, event)
    if event ~= "PLAYER_ENTERING_WORLD" then return end
    -- The _applied latch already makes Enforce a no-op on re-fire; the
    -- unregister is just cleanup (self-guarded for direct-call test harnesses).
    if self and self.UnregisterEvent then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
    CDMEditModePolicy.Enforce()
end)
