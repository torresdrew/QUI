--[[
    QUI Nameplates — spec- and role-linked plate presets (v1.1 stretch).

    A preset is a deep snapshot of the nameplates settings subtree. Two
    storage tiers:

    * SPEC presets — per specialization index, stored in the PROFILE
      (settings.specPresets[specIndex]); auto-switch via
      settings.specAutoSwitch.
    * ROLE presets — per TANK/HEALER/DAMAGER, stored ACCOUNT-WIDE in
      db.global.nameplateRolePresets so every character shares them;
      auto-switch via the same global table's autoSwitch flag.

    Auto-switch fires on PLAYER_SPECIALIZATION_CHANGED and (role tier only)
    on initial login — a tank alt logs in with the tank setup. /reload never
    re-applies (it would stomp unsaved tweaks mid-session). When both tiers
    are armed and have a preset, the SPEC preset wins (more specific).

    Excluded from snapshots: `enabled` (reload semantics — a preset must
    never silently disable the module), and the preset storage itself.
]]

local ADDON_NAME, ns = ...
local NP = ns.QUI_Nameplates
if not NP then return end

local type = type
local pairs = pairs
local pcall = pcall
local wipe = wipe
local CreateFrame = CreateFrame

local NPPresets = {}
NP.Presets = NPPresets

-- Keys that never enter (or leave) a snapshot.
local EXCLUDED_KEYS = {
    enabled = true,
    specPresets = true,
    specAutoSwitch = true,
}
NPPresets.EXCLUDED_KEYS = EXCLUDED_KEYS

---------------------------------------------------------------------------
-- DEEP COPY (plain profile tables only — no frames, no secrets)
---------------------------------------------------------------------------
local function CopyDeep(src)
    if type(src) ~= "table" then return src end
    local dst = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDeep(v)
        else
            dst[k] = v
        end
    end
    return dst
end
NPPresets.CopyDeep = CopyDeep

---------------------------------------------------------------------------
-- SNAPSHOT / APPLY (pure over the settings table — unit-tested offline)
---------------------------------------------------------------------------
function NPPresets.Snapshot(settings)
    settings = settings or NP.GetSettings()
    local snap = {}
    for k, v in pairs(settings) do
        if not EXCLUDED_KEYS[k] then
            snap[k] = CopyDeep(v)
        end
    end
    return snap
end

-- Deep-copy a snapshot back over the live settings. Top-level tables are
-- wiped first so keys removed since the snapshot don't survive as ghosts;
-- excluded keys are left untouched.
function NPPresets.ApplySnapshot(settings, snap)
    if type(settings) ~= "table" or type(snap) ~= "table" then return false end
    for k, v in pairs(snap) do
        if not EXCLUDED_KEYS[k] then
            if type(v) == "table" then
                if type(settings[k]) ~= "table" then
                    settings[k] = {}
                else
                    wipe(settings[k])
                end
                for k2, v2 in pairs(CopyDeep(v)) do
                    settings[k][k2] = v2
                end
            else
                settings[k] = v
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- PER-SPEC STORAGE
---------------------------------------------------------------------------
local function PresetStore()
    local settings = NP.GetSettings()
    settings.specPresets = settings.specPresets or {}
    return settings.specPresets, settings
end

function NPPresets.HasPreset(specIndex)
    if type(specIndex) ~= "number" then return false end
    local store = PresetStore()
    return type(store[specIndex]) == "table"
end

function NPPresets.SaveForSpec(specIndex)
    if type(specIndex) ~= "number" then return false end
    local store, settings = PresetStore()
    store[specIndex] = NPPresets.Snapshot(settings)
    return true
end

function NPPresets.ClearForSpec(specIndex)
    if type(specIndex) ~= "number" then return false end
    local store = PresetStore()
    store[specIndex] = nil
    return true
end

function NPPresets.ApplyForSpec(specIndex)
    if not NPPresets.HasPreset(specIndex) then return false end
    local store, settings = PresetStore()
    local ok = NPPresets.ApplySnapshot(settings, store[specIndex])
    if ok and ns.QUI_RefreshNameplates then
        ns.QUI_RefreshNameplates()
    end
    return ok
end

---------------------------------------------------------------------------
-- ROLE PRESETS (account-wide: db.global)
---------------------------------------------------------------------------
NPPresets.ROLES = { "TANK", "HEALER", "DAMAGER" }
local VALID_ROLES = { TANK = true, HEALER = true, DAMAGER = true }

-- Read-only peek: never materializes the store (auto-switch and existence
-- checks run on every spec change and must not write saved variables).
local function PeekRoleStore()
    local db = _G.QUI and _G.QUI.db
    local g = db and db.global
    return g and g.nameplateRolePresets or nil
end
NPPresets.PeekRoleStore = PeekRoleStore

-- Lazy-initialized global store for write paths (save/toggle UI); nothing
-- is written until the feature is used, so exports stay untouched.
function NPPresets.GetRoleStore()
    local db = _G.QUI and _G.QUI.db
    local g = db and db.global
    if not g then return nil end
    g.nameplateRolePresets = g.nameplateRolePresets or { autoSwitch = false }
    return g.nameplateRolePresets
end

function NPPresets.HasRolePreset(role)
    if not VALID_ROLES[role] then return false end
    local store = PeekRoleStore()
    return store ~= nil and type(store[role]) == "table"
end

function NPPresets.SaveForRole(role)
    if not VALID_ROLES[role] then return false end
    local store = NPPresets.GetRoleStore()
    if not store then return false end
    store[role] = NPPresets.Snapshot(NP.GetSettings())
    return true
end

function NPPresets.ClearForRole(role)
    if not VALID_ROLES[role] then return false end
    local store = NPPresets.GetRoleStore()
    if not store then return false end
    store[role] = nil
    return true
end

function NPPresets.ApplyForRole(role)
    if not NPPresets.HasRolePreset(role) then return false end
    local store = PeekRoleStore()
    local ok = NPPresets.ApplySnapshot(NP.GetSettings(), store[role])
    if ok and ns.QUI_RefreshNameplates then
        ns.QUI_RefreshNameplates()
    end
    return ok
end

---------------------------------------------------------------------------
-- CURRENT SPEC / ROLE + AUTO-SWITCH
---------------------------------------------------------------------------
function NPPresets.GetCurrentSpec()
    if not GetSpecialization then return nil end
    local ok, spec = pcall(GetSpecialization)
    spec = ok and NP.Plain(spec, "number") or nil
    if spec and spec > 0 then return spec end
    return nil
end

function NPPresets.GetCurrentRole()
    local spec = NPPresets.GetCurrentSpec()
    if not spec or not GetSpecializationRole then return nil end
    local ok, role = pcall(GetSpecializationRole, spec)
    role = ok and NP.Plain(role, "string") or nil
    if role and VALID_ROLES[role] then return role end
    return nil
end

-- Precedence: spec preset (profile, most specific) → role preset (global).
local function AutoSwitch()
    if not NP.IsEnabled() then return end

    local settings = NP.GetSettings()
    if settings.specAutoSwitch == true then
        local spec = NPPresets.GetCurrentSpec()
        if spec and NPPresets.HasPreset(spec) then
            NPPresets.ApplyForSpec(spec)
            return
        end
    end

    local store = PeekRoleStore()
    if store and store.autoSwitch == true then
        local role = NPPresets.GetCurrentRole()
        if role and NPPresets.HasRolePreset(role) then
            NPPresets.ApplyForRole(role)
        end
    end
end
NPPresets.AutoSwitch = AutoSwitch

local eventFrame = CreateFrame("Frame")
if eventFrame.RegisterUnitEvent then
    eventFrame:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
else
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
end
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        -- arg1 = isInitialLogin. Fresh login applies the role/spec setup
        -- (a tank alt gets tank plates); /reload deliberately does not —
        -- it would stomp unsaved tweaks mid-session.
        if arg1 == true then
            AutoSwitch()
        end
        return
    end
    -- PLAYER_SPECIALIZATION_CHANGED
    if arg1 ~= nil and arg1 ~= "player" then return end
    AutoSwitch()
end)
