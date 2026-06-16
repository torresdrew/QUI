-- tests/unit/anchoring_actionbar_resolver_taint_test.lua
-- Run: lua tests/unit/anchoring_actionbar_resolver_taint_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local function extractResolver(source, key)
    local startPattern = "\n    " .. key .. " = function%("
    local startPos = source:find(startPattern)
    assert(startPos, "missing resolver for " .. key)

    local endPos = source:find("\n    end,", startPos)
    assert(endPos, "missing resolver end for " .. key)

    return source:sub(startPos, endPos)
end

local source = readFile("modules/layout/anchoring.lua")

local blockedFallbacks = {
    { key = "bar1", frameName = "MainActionBar" },
    { key = "bar1", frameName = "MainMenuBar" },
    { key = "bar2", frameName = "MultiBarBottomLeft" },
    { key = "bar3", frameName = "MultiBarBottomRight" },
    { key = "bar4", frameName = "MultiBarRight" },
    { key = "bar5", frameName = "MultiBarLeft" },
    { key = "bar6", frameName = "MultiBar5" },
    { key = "bar7", frameName = "MultiBar6" },
    { key = "bar8", frameName = "MultiBar7" },
    { key = "petBar", frameName = "PetActionBar" },
    { key = "stanceBar", frameName = "StanceBar" },
    { key = "microMenu", frameName = "MicroMenuContainer" },
    { key = "bagBar", frameName = "BagsBar" },
}

for _, fallback in ipairs(blockedFallbacks) do
    local key = fallback.key
    local frameName = fallback.frameName
    local resolver = extractResolver(source, key)
    assert(
        not resolver:find('_G["' .. frameName .. '"]', 1, true),
        key .. " must not fall back to raw Blizzard " .. frameName)
    assert(
        resolver:find("return nil", 1, true),
        key .. " must bail until QUI owns the action bar frame")
end

print("OK: anchoring_actionbar_resolver_taint_test")
