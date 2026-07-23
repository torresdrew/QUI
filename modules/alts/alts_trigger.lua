---------------------------------------------------------------------------
-- QUI Alts — open trigger. The roster UI (alts/views/*, roster_data.lua) now
-- ships in the main addon and compiles at login; the window itself still
-- builds on first open inside Window.Toggle. Gated on the opt-in alts.enabled
-- flag so a disabled module never opens. Open call sites (datatexts, slash
-- command) route here.
---------------------------------------------------------------------------
local _, ns = ...

_G.QUI_OpenAltsRoster = function()
    local p = QUI and QUI.db and QUI.db.profile
    if p and p.alts and p.alts.enabled == false then return end
    if ns.Alts and ns.Alts.Window then ns.Alts.Window.Toggle() end
end
