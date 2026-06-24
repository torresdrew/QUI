-- Regression guard: QUI_Bags bags.enabled defaults.
-- new_profile_defaults.lua (OnNewProfile seed) must have bags.enabled = true so
-- newly-created profiles get the bag UI on without user action.
-- core/defaults.lua (live AceDB fallback layer) must keep bags.enabled = false so
-- existing profiles that never wrote the key are NOT retroactively changed.

-- Load new-profile seed (ns-assignment pattern, not return).
local seedNs = {}
assert(loadfile("core/new_profile_defaults.lua"))("QUI", seedNs)
local newProfileSeed = seedNs.NewProfileSeed
assert(type(newProfileSeed) == "table", "ns.NewProfileSeed must be a table")
assert(type(newProfileSeed.bags) == "table",
    "ns.NewProfileSeed.bags must be a table")

-- PRIMARY assertion: new profiles get bags ON.
assert(newProfileSeed.bags.enabled == true,
    "new-profile seed: bags.enabled must be true (new profiles get bags on)")

-- GUARD assertion: live AceDB default stays false so existing profiles are untouched.
local liveNs = {}
assert(loadfile("core/defaults.lua"))("QUI", liveNs)
local liveBags = liveNs.defaults and liveNs.defaults.profile and liveNs.defaults.profile.bags
assert(type(liveBags) == "table", "live defaults must have a bags subtable")
assert(liveBags.enabled == false,
    "live AceDB default: bags.enabled must remain false (existing profiles untouched)")

print("PASS: new-profile seed bags.enabled == true; live default bags.enabled == false")
