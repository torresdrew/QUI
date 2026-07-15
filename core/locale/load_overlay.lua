local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Non-enUS translations ship inside the per-locale QUI_OptionsSearch_<loc>
-- LoadOnDemand sub-addons (combined UI-string overlay + settings search
-- index — one folder per locale); load the active one SYNCHRONOUSLY right
-- here — LoadAddOn returns after the sub-addon's files execute, so the
-- overlay's ns.LocaleData.active lands before core/locale/locale.lua (next
-- in the TOC) captures it as an upvalue, and before any string consumer
-- compiles. enUS needs no overlay (enUS.lua above is the always-loaded
-- base; the English search index stays in the lazy plain QUI_OptionsSearch
-- addon), so enUS clients skip ~4.9 MB of inactive translation
-- parse/compile. The bundled search index self-apply no-ops at this point
-- (QUI_Options is LoadOnDemand); GUI:EnsureSearchCacheLoaded consumes the
-- parked ns.QUI_SearchCache on first search.
--
-- QUIDB (SavedVariables) is not yet loaded at this point in the file list,
-- so the selectedLocale override only takes effect via GetLocale() parity
-- with the chunks' own gate expression — same behavior as when the chunks
-- lived in this TOC.
---------------------------------------------------------------------------

local want = (QUIDB and QUIDB.global and QUIDB.global.selectedLocale) or (GetLocale and GetLocale())
if type(want) == "string" and want ~= "enUS" then
    local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if loader then
        -- Missing/disabled overlay addon (unshipped locale, user disabled
        -- it): pcall keeps login alive; ns.L falls back to the enUS base.
        pcall(loader, "QUI_OptionsSearch_" .. want)
    end
end
