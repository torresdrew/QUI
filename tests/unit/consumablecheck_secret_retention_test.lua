-- tests/unit/consumablecheck_secret_retention_test.lua
-- Run: lua tests/unit/consumablecheck_secret_retention_test.lua
--
-- AuraScanCount() already collapses the buff scan to 0 while
-- C_Secrets.ShouldAurasBeSecret() (consumablecheck.lua:781-786) with the
-- stated intent "keep the last displayed state instead of erroring" — but
-- UpdateConsumables reset every button to Not-Ready BEFORE the scan, so a
-- restricted UNIT_AURA event destroyed the last-known display anyway. The
-- secrecy gate must run before the reset.

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local source = readFile("modules/qol/consumablecheck.lua")

local fnStart = assert(source:find("UpdateConsumables = function()", 1, true))
local resetMarker = assert(source:find("-- Reset all buttons", fnStart, true))
local head = source:sub(fnStart, resetMarker)

assert(head:find("ShouldAurasBeSecret", 1, true),
    "UpdateConsumables must gate on aura secrecy BEFORE resetting buttons")

print("PASS consumablecheck_secret_retention_test")
