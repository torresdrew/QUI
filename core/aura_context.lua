--[[
    QUI Aura Spec-Context Refresh Driver

    Single PLAYER_SPECIALIZATION_CHANGED listener that nudges every surface
    resolving the aura-element cascade (group frames, unit frames, action-bar
    buff borders): per-spec buckets re-resolve AND compiled candidateFilters
    that depend on the player's capabilities (dispelTypes="mine" sentinel)
    recompile. Each surface's refresh entry is itself combat-split — OOC it
    runs the full pass; in combat it applies the candidateFilter mutation
    subset live and queues any forbidden creation for PLAYER_REGEN_ENABLED —
    so firing this live is safe (loadout swaps can land near combat edges).

    The instance/encounter ("i"..mapID / "e"..encounterID) cascade rungs that
    used to live here were removed along with the Auras > Encounters browser;
    legacy context buckets in saved profiles are simply never selected anymore
    (see core/migrations.lua's v58 notes for the bucket shapes).
]]

local ADDON_NAME, ns = ...

-- Refresh entries are published on the shared suite `ns` by each surface addon
-- (not _G, per the global-assignment ratchet); absent entries (surface not
-- loaded) skip.
local function RefreshAuraSurfaces()
    if ns.QUI_RefreshGroupFrameAuras then ns.QUI_RefreshGroupFrameAuras() end
    if ns.QUI_RefreshUnitFrameAuras then ns.QUI_RefreshUnitFrameAuras() end
    if ns.QUI_RefreshBuffBorderAuras then ns.QUI_RefreshBuffBorderAuras() end
end

-- Guarded so this module loads without error under the headless lua5.1 test
-- harness (WoW globals may be absent outside it).
if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    f:SetScript("OnEvent", function(_, _, arg1)
        if arg1 == "player" or arg1 == nil then
            RefreshAuraSurfaces()
        end
    end)
end
