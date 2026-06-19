-- tests/unit/skinning_addon_loaded_gate_test.lua
-- Run: lua tests/unit/skinning_addon_loaded_gate_test.lua
--
-- C_AddOns.IsAddOnLoaded returns loadedOrLoading first and fully-loaded second.
-- Skin catch-up gates must use the fully-loaded result so they do not run while
-- Blizzard's LOD frame globals are still being created.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function assertContains(text, needle, reason)
    assert(text:find(needle, 1, true), reason)
end

local function assertAbsent(text, needle, reason)
    assert(not text:find(needle, 1, true), reason)
end

local apiDocs = readFile("tests/framexml/Interface/AddOns/Blizzard_APIDocumentationGenerated/AddOnsDocumentation.lua")
assertContains(apiDocs, "{ Name = \"loadedOrLoading\", Type = \"bool\", Nilable = false }",
    "local API docs must expose IsAddOnLoaded's loading-state return")
assertContains(apiDocs, "{ Name = \"loaded\", Type = \"bool\", Nilable = false }",
    "local API docs must expose IsAddOnLoaded's fully-loaded return")

local uikit = readFile("core/uikit.lua")
assertContains(uikit, "function SkinBase.IsAddOnFullyLoaded(addonName)",
    "SkinBase must expose a shared fully-loaded addon gate")
assertAbsent(uikit, "if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(addonName) then",
    "SkinBase.OnAddOnLoaded must not treat loadedOrLoading as loaded")

for _, path in ipairs({
    "QUI_Skinning/skinning/character_pane/inspect.lua",
    "QUI_Skinning/skinning/gameplay/keystone.lua",
    "QUI_Skinning/skinning/frames/statustracking.lua",
    "QUI_Skinning/skinning/frames/auctionhouse.lua",
    "QUI_Skinning/skinning/frames/professions.lua",
    "QUI_Skinning/skinning/frames/craftingorders.lua",
}) do
    local source = readFile(path)
    assertAbsent(source, "C_AddOns.IsAddOnLoaded(",
        path .. " must use SkinBase.IsAddOnFullyLoaded instead of the loading-state return")
    assertContains(source, "IsAddOnFullyLoaded(",
        path .. " must retain an immediate catch-up path for already-loaded Blizzard addons")
end

print("OK: skinning_addon_loaded_gate_test")
