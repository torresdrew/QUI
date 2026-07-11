-- tests/unit/cdm_hud_visibility_no_blizzard_fallback_test.lua
-- Run: lua tests/unit/cdm_hud_visibility_no_blizzard_fallback_test.lua
--
-- CDM HUD visibility may fade QUI-owned containers, but must not enumerate
-- Blizzard CooldownViewer globals during cold login. Touching those viewers from
-- the generic visibility controller can taint Blizzard's UNIT_AURA path.

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local hud = read("QUI_CDM/cdm/hud_visibility.lua")
assert(not hud:find("DEFAULT_VIEWER_FRAME_NAMES", 1, true),
    "hud_visibility must not keep a Blizzard CooldownViewer fallback list")
assert(not hud:find("GetViewerFrameNames", 1, true),
    "hud_visibility must not ask the provider for Blizzard viewer names")
assert(not hud:find("_G[blizzName]", 1, true),
    "hud_visibility must not collect Blizzard viewer globals")

-- Re-anchored viewer fade: live Blizzard item frames stay parented to their
-- native viewers (SetPoint bridge, never SetParent), so container fades never
-- reach the icon art/swipe/count. The CDM controller must drive viewer alpha
-- too — but only through the boot-gated helper, never by enumerating globals.
local helperStart = assert(hud:find("local function ApplyReanchorViewerAlpha(alpha)", 1, true),
    "hud_visibility must define ApplyReanchorViewerAlpha (re-anchored viewer fade)")
local helperStop = assert(hud:find("\nend", helperStart, true))
local helper = hud:sub(helperStart, helperStop)
assert(helper:find("ns._cdmBoot", 1, true),
    "viewer fade must be gated on ns._cdmBoot (inert during cold login)")
assert(helper:find("GetViewerForKey", 1, true),
    "viewer fade must resolve viewers via the boot wiring, not globals")
assert(helper:find("_securecall(_rawViewerSetAlpha, viewer, alpha)", 1, true),
    "viewer fade must write alpha via securecall'd raw SetAlpha")
assert(helper:find("if not IsCDMMasterEnabled() then alpha = 1 end", 1, true),
    "viewer fade must pin viewers to alpha 1 while the CDM master toggle is off")

-- All four CDM alpha-application sites must drive the viewers: the fade tick,
-- the already-at-target early return, the layout-mode snap, and the
-- curve-driven HP override.
local count = 0
for _ in hud:gmatch("ApplyReanchorViewerAlpha%(") do count = count + 1 end
assert(count >= 5,  -- 1 definition + 4 call sites
    "expected the viewer fade applied at all 4 CDM alpha sites, found " .. (count - 1) .. " calls")

local containers = read("QUI_CDM/cdm/cdm_containers.lua")
local start = assert(containers:find("function CDMProvider:GetViewerFrames()", 1, true),
    "missing CDMProvider:GetViewerFrames")
local stop = assert(containers:find("\nend", start, true), "missing end of GetViewerFrames")
local block = containers:sub(start, stop)
assert(block:find("return self.emptyFrames", 1, true),
    "CDMProvider:GetViewerFrames must return emptyFrames before owned containers initialize")
assert(not block:find("_G[blizzName]", 1, true),
    "CDMProvider:GetViewerFrames must not return Blizzard globals pre-init")

print("OK: cdm_hud_visibility_no_blizzard_fallback_test")
