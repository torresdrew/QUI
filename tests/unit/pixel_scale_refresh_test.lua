-- tests/unit/pixel_scale_refresh_test.lua
-- Run: lua tests/unit/pixel_scale_refresh_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local src = readFile("core/scaling.lua")

assert(src:find("QueueScaleRefresh", 1, true),
    "ApplyUIScale or scale-change handling must queue delayed UIKit refreshes")

assert(src:find("'DISPLAY_SIZE_CHANGED'", 1, true) or src:find('"DISPLAY_SIZE_CHANGED"', 1, true),
    "Pixel-perfect scaling must listen for display size changes")

print("OK: pixel_scale_refresh_test")
