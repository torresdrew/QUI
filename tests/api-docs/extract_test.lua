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

-- Precondition-guarded function (RequiresUnitAuraAccess hard-errors under
-- restrictions) must be indexed even though its SecretArguments value is the
-- ignored "AllowedWhenTainted"
assert_true(index["C_Test.GuardedGetter"], "precondition-guarded function indexed")
assert_eq(index["C_Test.GuardedGetter"].preconditions[1], "RequiresUnitAuraAccess",
    "RequiresUnitAuraAccess precondition captured")
assert_true(index["C_Test.GuardedGetter"].secretArguments == nil,
    "AllowedWhenTainted still omitted")

-- Events: event-level Secret* flag and secretizable payload fields
assert_true(index["event:TEST_SECRET_EVENT"], "secret-flagged event indexed")
assert_eq(index["event:TEST_SECRET_EVENT"].eventFlags[1], "SecretInActivePvPMatch",
    "event-level flag captured")
assert_true(index["event:TEST_SECRET_PAYLOAD_EVENT"], "secret-payload event indexed")
assert_eq(index["event:TEST_SECRET_PAYLOAD_EVENT"].secretPayload, true,
    "secretPayload captured")
assert_true(not index["event:TEST_CLEAN_EVENT"], "clean event NOT indexed")

-- Doc files that reference Enum.* / Constants.* inside table constructors
-- (12.1.0.68675+ aspect flags, e.g. SecretReturnsForAspect =
-- { Enum.SecretAspect.Alpha }) must still load: a plain Lua host has neither
-- global, and an indexing error would silently drop the whole file's tables.
assert_true(index["C_TestEnumRefs.GetAspectValue"], "Enum-referencing file still indexed")
assert_eq(index["C_TestEnumRefs.GetAspectValue"].secretWhenCooldownsRestricted, true,
    "flags captured from Enum-referencing file")
assert_eq(index["C_TestEnumRefs.SetAspectValue"].secretArguments, "AllowedWhenUntainted",
    "secretArguments captured alongside SecretArgumentsAddAspect")
assert_eq(index["C_TestEnumRefs.GetConstantsValue"].secretArguments, "NotAllowed",
    "Constants.* reference does not abort file")

-- Aspect flags themselves are captured as bare aspect-name lists
assert_eq(index["C_TestEnumRefs.GetAspectValue"].secretReturnsForAspect[1], "Alpha",
    "SecretReturnsForAspect captured as aspect name")
assert_eq(index["C_TestEnumRefs.SetAspectValue"].secretArgumentsAddAspect[1], "Alpha",
    "SecretArgumentsAddAspect captured as aspect name")

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
