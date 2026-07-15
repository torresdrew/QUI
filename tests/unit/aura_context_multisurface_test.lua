-- Source-literal pins for the encounter/instance cascade wiring across all three
-- CustomAuraContainer surfaces + the combat-safe refresh routing. These can't run
-- headless (WoW frames/events), so the wiring is pinned at the source level — the
-- pins ARE the spec (same convention as unitframe_auras_container_test.lua).
local failures = 0
local function check(n, ok) if ok then print("  ok  " .. n) else failures = failures + 1; print("FAIL  " .. n) end end
local function read(p) local f = assert(io.open(p, "r")); local s = f:read("*a"); f:close(); return s end

local ctx = read("core/aura_context.lua")
local uf  = read("QUI_UnitFrames/unitframes/unitframe_auras.lua")
local bb  = read("QUI_ActionBars/actionbars/buffborders.lua")
local gf  = read("QUI_GroupFrames/groupframes/groupframes.lua")

-- aura_context drives ALL THREE surfaces through one combat-safe driver, used by
-- both zone (OOC) and encounter (in-combat) handlers.
check("context refreshes group frames",  ctx:find("ns.QUI_RefreshGroupFrameAuras", 1, true) ~= nil)
check("context refreshes unit frames",   ctx:find("ns.QUI_RefreshUnitFrameAuras", 1, true) ~= nil)
check("context refreshes buff borders",  ctx:find("ns.QUI_RefreshBuffBorderAuras", 1, true) ~= nil)
check("encounter start routes live",     ctx:find("OnEncounterStart", 1, true) ~= nil
    and ctx:find("RefreshAuraSurfaces()", 1, true) ~= nil)
check("zone handler routes surfaces",    ctx:find("OnZoneContextEvent", 1, true) ~= nil)
check("registers ENCOUNTER_START",       ctx:find('RegisterEvent("ENCOUNTER_START")', 1, true) ~= nil)
check("registers ENCOUNTER_END",         ctx:find('RegisterEvent("ENCOUNTER_END")', 1, true) ~= nil)

-- Each surface publishes a combat-safe entry on the shared ns (NOT _G — ratchet).
check("GF publishes ns entry",  gf:find("ns.QUI_RefreshGroupFrameAuras = function", 1, true) ~= nil)
check("GF entry uses RefreshAllFrames (combat-split, NOT RefreshSettings)",
    gf:find('RefreshAllFrames("auraContext")', 1, true) ~= nil)
check("UF publishes ns entry",  uf:find("ns.QUI_RefreshUnitFrameAuras", 1, true) ~= nil)
check("BB publishes ns entry",  bb:find("ns.QUI_RefreshBuffBorderAuras", 1, true) ~= nil)

-- Each surface's resolve passes the compacted cascade keys (FillContextKeys).
check("UF resolve passes cascade keys",
    uf:find("ActiveElementsForSpec(auras, nil, nil, ck)", 1, true) ~= nil
    and uf:find("FillContextKeys", 1, true) ~= nil)
check("BB resolve passes cascade keys",
    bb:find("ActiveElementsForSpec(store, nil, nil, ck)", 1, true) ~= nil
    and bb:find("FillContextKeys", 1, true) ~= nil)

-- No surface uses the combat-bailing full refresh (RefreshSettings) for the
-- encounter path -- that would drop the whole pass in combat.
check("context does NOT call RefreshSettings-bound global on encounter",
    ctx:find("RefreshGroupFrames()", 1, true) == nil)

print("aura_context_multisurface_test " .. (failures == 0 and "OK" or "FAILED"))
os.exit(failures == 0 and 0 or 1)
