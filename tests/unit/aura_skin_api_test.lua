-- tests/unit/aura_skin_api_test.lua
-- Source-text assertion test for core/aura_skin.lua.
-- AuraSkin cannot be behaviorally unit-tested headless (needs the live secure
-- template); source-text assertions verify the structural contract instead.
-- Run: lua tests/unit/aura_skin_api_test.lua

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    data = data:gsub("\r\n", "\n")
    return data
end

local src = readAll("core/aura_skin.lua")

-- Public namespace exposure
assert(src:find("QUI.AuraSkin", 1, true),
    "aura_skin.lua must expose QUI.AuraSkin")
assert(src:find("ns.Addon.AuraSkin", 1, true),
    "aura_skin.lua must register on ns.Addon.AuraSkin")

-- Public API surface
assert(src:find("AuraSkin.Attach", 1, true),
    "aura_skin.lua must define AuraSkin.Attach")

-- OFFICIAL Blizzard AuraButton example: the addon CREATES each button as a child
-- of the container, SIZES + POSITIONS it, wires the regions in Lua, and registers
-- it via container:AddAuraFrame.  The engine-pool APIs are not used.
assert(src:find('CreateFrame("AuraButton", nil, container, "CustomAuraButtonTemplate")', 1, true),
    "aura_skin.lua must CreateFrame an AuraButton from CustomAuraButtonTemplate (official pattern)")
assert(not src:find("AddAuraFramesFromTemplate", 1, true),
    "aura_skin.lua must NOT use AddAuraFramesFromTemplate (old engine-pool pattern, removed)")
assert(not src:find("GetAuraFrameCount", 1, true),
    "aura_skin.lua must NOT use GetAuraFrameCount (old engine-pool pattern, removed)")
assert(not src:find("GetAuraFrame(", 1, true),
    "aura_skin.lua must NOT re-fetch buttons via GetAuraFrame (old engine-pool pattern, removed)")

-- The addon SIZES + POSITIONS each button (the engine drives aura DATA, not layout).
assert(src:find("button:SetSize", 1, true),
    "aura_skin.lua must SetSize each button (official pattern sizes the buttons)")
assert(src:find("button:SetPoint", 1, true),
    "aura_skin.lua must SetPoint each button in a grid (official pattern positions the buttons)")

-- No script on the forbidden buttons (the intrinsic owns its scripts;
-- UntrustedScriptExecution).
assert(not src:find("button:SetScript", 1, true),
    "aura_skin.lua must NOT set any script on the forbidden buttons (taint)")

-- Idempotency: buttons are pooled on the container and reused on re-Attach; the
-- per-button art build is guarded so it wires the inbound API only once.
assert(src:find("_quiButtons", 1, true),
    "aura_skin.lua must store buttons on container._quiButtons for idempotent reuse")
assert(src:find("_quiWired", 1, true),
    "aura_skin.lua art build must have a per-button idempotency guard (_quiWired)")

-- SetTheme / Detach / DurationFormatter remain removed (dead/incorrect APIs).
assert(not src:find("AuraSkin.SetTheme", 1, true),
    "aura_skin.lua must NOT define AuraSkin.SetTheme (dead API, removed)")
assert(not src:find("AuraSkin.Detach", 1, true),
    "aura_skin.lua must NOT define AuraSkin.Detach (dead API, removed)")
assert(not src:find("AuraSkin.DurationFormatter", 1, true),
    "aura_skin.lua must NOT define AuraSkin.DurationFormatter (plain Lua fn is not a NumericFormatter)")
assert(not src:find("formatter = AuraSkin", 1, true),
    "aura_skin.lua must NOT pass a Lua formatter to SetDurationText")

-- Secret-safe inbound subset (matches Blizzard's official AuraButton example):
-- ApplyAuraInstance runs each Apply* in order (count -> border -> ... -> icon ->
-- visibility).  ApplyApplicationCount (`applications > 1`) and ApplyAuraBorder
-- (`auraData.isHarmful and ...`) BRANCH ON SECRET aura fields and throw on an
-- addon-created button; the swallowed throw blanks the button (icon + visibility
-- come AFTER and never run).  So ONLY the secret-safe setters are wired.
assert(src:find("SetIcon", 1, true),
    "aura_skin.lua must call SetIcon to wire the aura icon texture")
assert(src:find("SetDurationCooldown", 1, true),
    "aura_skin.lua must call SetDurationCooldown on the button")
assert(src:find("SetDurationText", 1, true),
    "aura_skin.lua must call SetDurationText on the button")
assert(src:find("AddAuraFrame(button)", 1, true),
    "aura_skin.lua must register each button via container:AddAuraFrame(button)")

-- Stack count: wired EXACTLY like duration — fontstring + SetApplicationCount with
-- an EMPTY options table, NO formatter.  A QUI-created formatter is a tainted value
-- and SetApplicationCount writes options.formatter directly (no securecopy), so it
-- would throw; with {} the engine's secret-safe `applications > 1` path drives it.
assert(src:find("button:SetApplicationCount(count, {})", 1, true),
    "aura_skin.lua must wire SetApplicationCount with an empty options table (no formatter)")
assert(not src:find("CreateNumericRuleFormatter", 1, true),
    "aura_skin.lua must NOT pass a QUI-created formatter to SetApplicationCount (tainted value -> blocked)")
-- Dispel border: SetAuraBorder securecopies its options, so it is addon-safe; the
-- engine vertex-colours it by dispel type secure-side.
assert(src:find("button:SetAuraBorder", 1, true),
    "aura_skin.lua must wire SetAuraBorder for the per-dispel-type border colour")
assert(src:find("showWhenHelpful = false", 1, true),
    "aura_skin.lua dispel border must set showWhenHelpful = false (buffs keep the static ring)")

-- Static QUI border: a button-child texture ALWAYS shown (aura-data-INDEPENDENT,
-- so it renders regardless of the secure apply path).  BACKGROUND draw layer.
assert(src:find('button:CreateTexture(nil, "BACKGROUND")', 1, true),
    "aura_skin.lua must create a BACKGROUND-layer button child texture for the static QUI border")
assert(src:find("_quiBorder", 1, true),
    "aura_skin.lua must store the static border texture on button._quiBorder")
assert(src:find("AuraTheme.BorderColor", 1, true),
    "aura_skin.lua must color the border via AuraTheme.BorderColor() (QUI theme color)")
assert(src:find("DisablePixelSnap", 1, true),
    "aura_skin.lua must call DisablePixelSnap on the border texture (1px solid crispness)")

-- Duration font: honors profile.fontSize via plain SetFont (secret-safe).
assert(src:find("profile.fontSize", 1, true),
    "aura_skin.lua must read profile.fontSize for the duration font")
assert(src:find(":SetFont(", 1, true),
    "aura_skin.lua must call SetFont to apply the profile font size (plain, secret-safe)")

-- Swipe: cooldown honors profile.hideSwipe + profile.reverseSwipe.
assert(src:find("SetDrawSwipe", 1, true),
    "aura_skin.lua must call SetDrawSwipe on the cooldown (profile.hideSwipe)")
assert(src:find("SetReverse", 1, true),
    "aura_skin.lua must call SetReverse on the cooldown (profile.reverseSwipe)")
assert(src:find("profile.hideSwipe", 1, true),
    "aura_skin.lua must read profile.hideSwipe to drive SetDrawSwipe")
assert(src:find("profile.reverseSwipe", 1, true),
    "aura_skin.lua must read profile.reverseSwipe to drive SetReverse")

-- Art regions are button children (created on 'button'), so they inherit the
-- button's forbidden parent + layout aspects.
assert(src:find("button:CreateTexture", 1, true),
    "aura_skin.lua icon/border textures must be created as button:CreateTexture (button child)")
assert(src:find("button:CreateFontString", 1, true),
    "aura_skin.lua font strings must be created as button:CreateFontString (button child)")
assert(src:find('CreateFrame("Cooldown", nil, button,', 1, true),
    "aura_skin.lua cooldown frame must be CreateFrame(\"Cooldown\", nil, button, ...) (button child)")

-- AuraTheme consumption
assert(src:find("AuraTheme.Metrics", 1, true),
    "aura_skin.lua must call AuraTheme.Metrics for layout params")

print("OK: aura_skin_api_test")
