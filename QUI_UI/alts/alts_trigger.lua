---------------------------------------------------------------------------
-- QUI Alts — eager trigger stub. The heavy roster UI (alts/views/*,
-- roster_data.lua) is LAZY: it is untagged in QUI_UI.toc and does not load at
-- startup. The first roster-open loads the QUI_UI lazy block via
-- AddonLoader:LoadLazyBlock (LoadAddOn("QUI_UI"), combat-parked), then toggles
-- the window. Gated on the opt-in alts.enabled flag so a disabled module never
-- pays the compile. Open call sites (datatexts, slash command) route here.
---------------------------------------------------------------------------
local _, ns = ...

_G.QUI_OpenAltsRoster = function()
    local p = QUI and QUI.db and QUI.db.profile
    if p and p.alts and p.alts.enabled == false then return end
    if ns.AddonLoader then
        ns.AddonLoader:LoadLazyBlock(function()
            if ns.Alts and ns.Alts.Window then ns.Alts.Window.Toggle() end
        end)
    end
end
