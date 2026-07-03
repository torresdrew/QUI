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
