-- Tests for extract_api_index.lua
-- Run from the repo root: lua tests/api-docs/extract_test.lua

local Extract = dofile("tests/api-docs/extract_api_index.lua")

local function assert_eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. ": expected " .. tostring(e) .. ", got " .. tostring(a), 2)
    end
end

local function assert_true(v, msg)
    if not v then error(msg or "assertion failed", 2) end
end

-- ---------------------------------------------------------------------------
-- Index extraction
-- ---------------------------------------------------------------------------

local index = Extract.fromCorpus("tests/api-docs/synthetic-corpus")

-- SecretWhenCooldownsRestricted function must be indexed with the flag set
assert_true(index["C_Test.GetSecretValue"], "secret-flagged function indexed")
assert_eq(index["C_Test.GetSecretValue"].secretWhenCooldownsRestricted, true,
    "secretWhenCooldownsRestricted flag captured")

-- Clean function (no flags) must NOT appear in the index
assert_true(not index["C_Test.GetCleanValue"], "clean function NOT indexed (no flag)")

-- Function with SecretArguments + IsSecret return
assert_true(index["C_Test.RestrictedReturn"], "restricted function indexed")
assert_eq(index["C_Test.RestrictedReturn"].isSecretReturn, true,
    "isSecretReturn captured")
assert_eq(index["C_Test.RestrictedReturn"].secretArguments, "Restricted",
    "secretArguments captured")

-- ---------------------------------------------------------------------------
-- renderLua round-trip
-- ---------------------------------------------------------------------------

local rendered = Extract.renderLua(index)

-- Must be valid Lua
local f = (loadstring or load)(rendered, "rendered")
assert_true(f ~= nil, "rendered output must be loadable Lua")

local ok, decoded = pcall(f)
assert_true(ok and type(decoded) == "table", "rendered loads to a table")

-- Re-render must be identical (idempotency / determinism)
local rendered2 = Extract.renderLua(decoded)
assert_eq(rendered, rendered2, "render is idempotent")

print("extract test passed")
