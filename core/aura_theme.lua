-- core/aura_theme.lua — QUI.AuraTheme: shared aura visual leaves (no frame logic, no secrets).
local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local AuraTheme = {}
ns.Addon = ns.Addon or {}
ns.Addon.AuraTheme = AuraTheme
_G.QUI = _G.QUI or {}
_G.QUI.AuraTheme = AuraTheme

-- QUI theme border color for the static per-icon border.  Returns the global skin
-- border color (accent / class / custom) via Helpers.GetSkinBorderColor, which
-- reads the live profile.  Falls back to white when the helper is not yet
-- available (early init).  Per-dispel-type colors are NOT defined here: the secure
-- engine colors the dispel-border overlay itself from DEBUFF_TYPE_*_COLOR (see
-- QUI.AuraSkin SetAuraBorder), so a QUI-side palette would be dead.
function AuraTheme.BorderColor()
    if Helpers and Helpers.GetSkinBorderColor then
        return Helpers.GetSkinBorderColor(nil, nil)
    end
    return 1, 1, 1, 1
end

-- Layout metrics consumed by QUI.AuraSkin (iconSize / spacing / grow / maxIcons).
-- Count + duration fonts are applied per-button via plain SetFont in
-- AuraSkin.styleButton (per-zone fontSize), so there are no shared font objects to
-- cache/refresh here — a global-font change reaches auras on the next Attach.
function AuraTheme.Metrics(profile)
    profile = profile or {}
    return {
        iconSize = profile.iconSize or 24,
        spacing  = profile.spacing  or 2,
        grow     = profile.grow     or "RIGHT",
        maxIcons = profile.maxIcons or 16,
    }
end
