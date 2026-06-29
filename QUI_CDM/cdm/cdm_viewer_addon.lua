-- QUI_CDM/cdm/cdm_viewer_addon.lua
-- Shared identity/loading helper for Blizzard's CooldownViewer addon.
local _, ns = ...

local CDMCooldownViewerAddon = {}
ns.CDMCooldownViewerAddon = CDMCooldownViewerAddon

CDMCooldownViewerAddon.PRIMARY = "Blizzard_CooldownViewer"

function CDMCooldownViewerAddon.IsViewerAddon(addonName)
    return addonName == CDMCooldownViewerAddon.PRIMARY
end

function CDMCooldownViewerAddon.Load(loader)
    if not loader then
        if C_AddOns and C_AddOns.LoadAddOn then
            loader = function(name) return C_AddOns.LoadAddOn(name) end
        elseif LoadAddOn then
            loader = LoadAddOn
        end
    end
    if not loader then return false end

    local addonName = CDMCooldownViewerAddon.PRIMARY
    local ok, loaded = pcall(loader, addonName)
    if ok and loaded ~= false then
        return true, addonName
    end
    return false
end
