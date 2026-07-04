-- tests/unit/aura_skin_reflow_test.lua
-- Run: lua tests/unit/aura_skin_reflow_test.lua
--
-- AuraSkin.Reflow is the combat-legal subset of AuraSkin.Attach: re-apply
-- size/position/style to EXISTING pooled buttons only. Creating a forbidden
-- AuraButton (CreateFrame / AddAuraFrame) is combat-restricted on 12.1 —
-- creation in combat crashes the client — but mutating pre-created buttons
-- (SetPoint / SetSize / fonts / textures) is legal in combat. Reflow must
-- therefore contain NO creation and NO registration.

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end

local src = readAll("core/aura_skin.lua")

-- Reflow must exist.
local startPos = src:find("function AuraSkin.Reflow(container, profile)", 1, true)
assert(startPos, "aura_skin.lua must define AuraSkin.Reflow(container, profile)")

-- Slice the Reflow function body (up to the first line-leading `end`).
local endPos = src:find("\nend", startPos, true)
assert(endPos, "AuraSkin.Reflow must be a well-formed function")
local body = src:sub(startPos, endPos)

-- The combat contract: no creation, no registration inside Reflow.
assert(not body:find("CreateFrame", 1, true),
    "AuraSkin.Reflow must NOT CreateFrame (AuraButton creation is combat-forbidden)")
assert(not body:find("AddAuraFrame", 1, true),
    "AuraSkin.Reflow must NOT register buttons (AddAuraFrame is creation-path only)")

-- It must re-flow and re-style existing buttons.
assert(body:find("_quiButtons", 1, true),
    "AuraSkin.Reflow must read the existing container._quiButtons pool")
assert(body:find("layoutButton", 1, true),
    "AuraSkin.Reflow must re-apply grid layout via layoutButton")
assert(body:find("styleButton", 1, true),
    "AuraSkin.Reflow must re-apply static style via styleButton")

-- Guard: nil pool (container never Attached) must be a safe no-op.
assert(body:find("if not buttons then return end", 1, true),
    "AuraSkin.Reflow must no-op when the container has no button pool yet")

print("OK: aura_skin_reflow_test")
