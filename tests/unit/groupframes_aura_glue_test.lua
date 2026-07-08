-- tests/unit/groupframes_aura_glue_test.lua
-- Run: lua tests/unit/groupframes_aura_glue_test.lua
local function read(p) local h = assert(io.open(p, "rb")); local s = h:read("*a"); h:close(); return s end
local src = read("QUI_GroupFrames/groupframes/groupframes_auras.lua")
local privateSrc = read("QUI_GroupFrames/groupframes/groupframes_private_auras.lua")
local fails = 0
local function check(n, ok) if ok then print("  ok  " .. n) else fails = fails + 1; print("FAIL  " .. n) end end

check("references the model module", src:find("QUI_GroupFramesAuraModel", 1, true) ~= nil)
check("calls ActiveElementsForSpec", src:find("ActiveElementsForSpec", 1, true) ~= nil)
check("calls PopulateElementMatches", src:find("PopulateElementMatches", 1, true) ~= nil)
check("defines BuildElementRenderList", src:find("BuildElementRenderList", 1, true) ~= nil)

local privateRefresh = privateSrc:find("RefreshPrivateDispelState(unit)", 1, true)
local overlayRefresh = privateSrc:find("GF:UpdateDispelOverlay(frame)", 1, true)
check("private dispel refresh rechecks visible overlays after cache update",
    privateRefresh ~= nil
    and overlayRefresh ~= nil
    and privateRefresh < overlayRefresh
    and privateSrc:find("frame:IsShown()", privateRefresh, true) ~= nil)

-- PTR4 UNIT_AURA fully-secret payload guards (Task 7) ------------------------
-- groupframes_auras.lua needs real WoW frames + the AuraEvents subscription and
-- cannot run headless, so pin the two secret gates by source position (same
-- idiom as groupframes_auras_container_test.lua).
do
    local ad_i  = src:find("local function ApplyAuraDelta", 1, true)
    local add_i = ad_i and src:find("if updateInfo.addedAuras then", ad_i, true)
    local sec_i = ad_i and src:find("AurasAreSecret()", ad_i, true)
    check("ApplyAuraDelta bails on AurasAreSecret before indexing the cache by instanceID",
        ad_i ~= nil and add_i ~= nil and sec_i ~= nil and sec_i < add_i)

    -- Fast stack/duration path: the == reseat (RefreshUpdatedIcons/Bars) must be
    -- skipped while auras are secret (updatedAuraInstanceIDs are secret then).
    local nUp_i  = src:find("local nUpdated = #updated", 1, true)
    local ri_i   = nUp_i and src:find("Render.RefreshUpdatedIcons", nUp_i, true)
    local fsec_i = nUp_i and src:find("AurasAreSecret()", nUp_i, true)
    check("fast stack/duration path guards the == reseat on AurasAreSecret",
        nUp_i ~= nil and ri_i ~= nil and fsec_i ~= nil and fsec_i < ri_i)
end

if fails > 0 then error(fails .. " failures") end
print("ALL PASS")
