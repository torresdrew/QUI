--[[
  gen_new_profile_seed.lua

  One-shot generator: decode a full QUI profile export string (QUI1:), strip
  it, and emit importstrings/starter_profile.lua — the compressed Starter
  Profile string that is BOTH the fresh-install seed (decoded lazily by
  core/new_profile_defaults.lua via the AceDB OnNewProfile hook) and the
  Profiles-tab preset. Existing profiles are never touched.

  Meta/latch/runtime keys are stripped (any "_"-prefixed key at ANY depth +
  the fpsBackup runtime CVar buffer) so the seed carries ONLY genuine
  settings; the migration/compat layers still stamp
  _schemaVersion/_defaultsVersion on the seeded profile afterwards exactly as
  they do for a fresh profile. Orphan CDM container satellites (anchors/
  cooldown-effect overrides/glow keys left behind by a deleted container —
  same rule as core/migrations.lua's v51 squash step (f)) are purged too.

  Usage:
    lua tools/gen_new_profile_seed.lua <path-to-string-file>
    lua tools/gen_new_profile_seed.lua -                       # string on stdin
    lua tools/gen_new_profile_seed.lua --from-seed              # reprocess the
                                                                  -- shipped string in place
]]

local function ScriptDir()
    local p = (arg and arg[0]) or ""
    p = p:gsub("\\", "/")
    local dir = p:match("(.*/)")
    if dir == nil or dir == "" then return "./" end
    return dir
end

local env = dofile(ScriptDir() .. "_addon_env.lua")
env.LoadLibs()

local LibDeflate    = LibStub("LibDeflate")
local AceSerializer = LibStub("AceSerializer-3.0")

----------------------------------------------------------------------------
-- Strip set: anything that is migration/runtime state, not a setting.
----------------------------------------------------------------------------
local function ShouldStripTopKey(k)
    if type(k) ~= "string" then return false end
    if k:sub(1, 1) == "_" then return true end   -- every meta/latch key is "_"-prefixed
    if k == "fpsBackup" then return true end       -- runtime CVar backup buffer (defaults.lua = nil)
    if k == "powerBarAltPosition" then return true end -- dead legacy position store, no runtime consumer
    return false
end

----------------------------------------------------------------------------
-- Orphan-satellite purge: DeleteContainer historically leaked per-container
-- keys (frameAnchoring/cooldownEffects/customGlow) that never got cleaned up
-- when the container itself was removed. Mirrors
-- Migrations.PurgeOrphanContainerSatellites (core/migrations.lua v51 squash step (f)) — kept
-- as its own copy here because this tool cannot load addon files (only
-- tools/_addon_env.lua's headless lib stubs). Keep the customGlow suffix
-- list in lockstep with the migrations.lua copy. (cdm_containers.lua's
-- PurgeContainerSatellites needs no list — it prefix-matches on a known
-- containerKey.)
----------------------------------------------------------------------------
-- Ordered longest-suffix-first: several suffixes share a tail (every
-- Pandemic*Enabled variant ends in "Enabled"), so a shorter generic suffix
-- must never be tried before the longer specific one it is a tail of, or it
-- mis-derives the container prefix (e.g. stripping bare "Enabled" from
-- "<liveKey>PandemicBuffEnabled" yields "<liveKey>PandemicBuff", which is
-- not a live container key, wrongly orphaning a LIVE key). The match loop
-- below stops at the first suffix that matches the key's tail at all
-- (break unconditionally on match, not only on delete) so this ordering is
-- load-bearing, not cosmetic. Keep in lockstep with core/migrations.lua.
local CDM_GLOW_SUFFIXES = {
    "PandemicDebuffEnabled", "PandemicBuffEnabled", "PandemicEnabled",
    "Thickness", "Frequency", "GlowType", "XOffset", "YOffset", "Enabled",
    "Color", "Scale", "Lines",
}

local function PurgeOrphanSatellites(p)
    local ncdm = p.ncdm
    local live = {}
    if ncdm and type(ncdm.containers) == "table" then
        for key in pairs(ncdm.containers) do live[key] = true end
    end

    local anchors = p.frameAnchoring
    if type(anchors) == "table" then
        local toRemove = {}
        for k in pairs(anchors) do
            if type(k) == "string" then
                local key = k:match("^cdmCustom_(.+)$")
                if key and not live[key] then toRemove[#toRemove + 1] = k end
            end
        end
        for _, k in ipairs(toRemove) do anchors[k] = nil end
    end

    local effects = p.cooldownEffects
    if type(effects) == "table" then
        local toRemove = {}
        for k in pairs(effects) do
            if type(k) == "string" then
                local key = k:match("^hide_(.+)$")
                if key and not live[key] then toRemove[#toRemove + 1] = k end
            end
        end
        for _, k in ipairs(toRemove) do effects[k] = nil end
    end

    local glow = p.customGlow
    if type(glow) == "table" then
        local toRemove = {}
        for k in pairs(glow) do
            if type(k) == "string" then
                for _, suffix in ipairs(CDM_GLOW_SUFFIXES) do
                    local key = k:match("^(.+)" .. suffix .. "$")
                    if key then
                        -- First matching suffix wins and stops the search
                        -- (see the ordering note on CDM_GLOW_SUFFIXES above).
                        -- Only container-shaped prefixes; never touch the
                        -- essential/utility builtin glow keys.
                        if key ~= "essential" and key ~= "utility"
                            and (key:find("^custom_") or key:find("^customBar_"))
                            and not live[key] then
                            toRemove[#toRemove + 1] = k
                        end
                        break
                    end
                end
            end
        end
        for _, k in ipairs(toRemove) do glow[k] = nil end
    end

    return true
end

----------------------------------------------------------------------------
-- Decode
----------------------------------------------------------------------------
local function ReadInput(path)
    if path == "-" then return io.read("*a") end
    local f, err = io.open(path, "rb")
    if not f then error("Could not open input: " .. tostring(err)) end
    local data = f:read("*a")
    f:close()
    return data
end

local function Decode(raw)
    raw = (raw:gsub("%s+", ""))
    assert(raw:sub(1, 5) == "QUI1:", "expected a QUI1: full-profile string")
    local compressed = assert(LibDeflate:DecodeForPrint(raw:sub(6)), "DecodeForPrint failed")
    local serialized = assert(LibDeflate:DecompressDeflate(compressed), "DecompressDeflate failed")
    local ok, payload = AceSerializer:Deserialize(serialized)
    assert(ok, "Deserialize failed: " .. tostring(payload))
    assert(type(payload) == "table", "payload is not a table")
    return payload
end

----------------------------------------------------------------------------
-- Recursive strip: ShouldStripTopKey applies at EVERY depth, not just the
-- root, so nested meta/latch keys (ncdm._specProfiles, chat.tabs[n].
-- _groupsVersion, etc.) never ship. Returns only the top-level doomed-key
-- list for the summary printout; deeper strips happen silently in the
-- recursive calls.
----------------------------------------------------------------------------
local function StripMetaKeysDeep(t)
    local doomed = {}
    for k, v in pairs(t) do
        if ShouldStripTopKey(k) then
            doomed[#doomed + 1] = k
        elseif type(v) == "table" then
            StripMetaKeysDeep(v)
        end
    end
    table.sort(doomed, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(doomed) do t[k] = nil end
    return doomed
end

----------------------------------------------------------------------------
-- Main
----------------------------------------------------------------------------
local inPath  = arg[1] or error("usage: gen_new_profile_seed.lua <string-file>|--from-seed [out.lua]")
local outPath = arg[2] or (ScriptDir() .. "../importstrings/starter_profile.lua")

local profile
if inPath == "--from-seed" then
    -- Reprocess the shipped string in place: register the loader, decode the
    -- current starter_profile.lua data, re-strip + re-encode.
    _G.QUI = _G.QUI or {}
    _G.QUI._importLoaders = {}
    assert(loadfile(ScriptDir() .. "../importstrings/starter_profile.lua"))("QUI", {})
    local loader = assert(_G.QUI._importLoaders.StarterProfile, "StarterProfile loader missing")
    local entry = loader()
    local data = type(entry) == "table" and entry.data or entry
    profile = Decode(assert(data, "starter_profile.lua carries no data string"))
else
    profile = Decode(ReadInput(inPath))
end
profile._quiBundledGlobals = nil

local strippedTop = StripMetaKeysDeep(profile)
PurgeOrphanSatellites(profile)

-- Force the shipped new-user theme to QUI's Classic Mint, regardless of the
-- source profile's theme. general.themePreset is the live read (main.lua and
-- the options theme picker, QUI_Options/framework.lua); the top-level copy is
-- the legacy store. Set both + the derived accent color so every consumer
-- resolves mint. Mint = "Classic Mint" -> {0.204, 0.827, 0.600} (#34D399).
local function ApplyThemeOverride(p)
    local function mint() return { 0.204, 0.827, 0.6, 1 } end
    p.themePreset = "Classic Mint"
    p.addonAccentColor = mint()
    if type(p.general) ~= "table" then p.general = {} end
    p.general.themePreset = "Classic Mint"
    p.general.addonAccentColor = mint()
    p.general.skinUseClassColor = false   -- picker keeps this in sync with the preset
end
ApplyThemeOverride(profile)

----------------------------------------------------------------------------
-- Encode: payload = seed keys at top level + the empty bundled-globals block
-- (core/new_profile_defaults.lua drops it on decode; profile_io's import
-- validation expects the key on preset installs).
----------------------------------------------------------------------------
local payload = {}
for k, v in pairs(profile) do payload[k] = v end
payload._quiBundledGlobals = { ncdm_specTrackerSpells = {}, specTrackerSpells = {} }

local serialized = AceSerializer:Serialize(payload)
local compressed = LibDeflate:CompressDeflate(serialized)
local encoded    = "QUI1:" .. LibDeflate:EncodeForPrint(compressed)

-- Pick a long-bracket level that cannot collide with the blob contents.
local bracket = "[["
local close   = "]]"
if encoded:find("]]", 1, true) then bracket, close = "[==[", "]==]" end

local body = table.concat({
    "-- QUI Starter Profile export string.",
    "-- AUTO-GENERATED by tools/gen_new_profile_seed.lua -- DO NOT EDIT BY HAND.",
    "-- SINGLE SOURCE for the fresh-install seed (decoded lazily by",
    "-- core/new_profile_defaults.lua via the OnNewProfile hook) AND the",
    "-- Profiles-tab \"Starter Profile\" preset — they cannot drift.",
    "-- Stripped on generation: every \"_\"-prefixed meta/latch key at ANY depth +",
    "-- fpsBackup + orphan CDM container satellites.",
    "-- Regenerate after curating: lua tools/gen_new_profile_seed.lua <string-file>",
    "-- Reprocess in place (re-strip only): lua tools/gen_new_profile_seed.lua --from-seed",
    "-- Decode guard: tests/unit/starter_preset_matches_seed_test.lua",
    "",
    "QUI._importLoaders.StarterProfile = function()",
    "    return {",
    "    name = \"Starter Profile\",",
    "    description = \"QUI starter profile (the shipped new-profile defaults)\",",
    "    data = " .. bracket .. encoded .. close .. ",",
    "    }",
    "end",
    "",
}, "\n")

local f = assert(io.open(outPath, "wb"))
f:write(body)
f:close()

local kept = 0
for _ in pairs(profile) do kept = kept + 1 end
io.write(string.format(
    "Wrote %s\n  kept %d top-level setting keys, stripped %d top-level meta/runtime keys"
        .. " (deep strip also ran below top level): %s\n",
    outPath, kept, #strippedTop, table.concat(strippedTop, ", ")))
