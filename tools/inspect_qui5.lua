-- Forensics script: load the donor SV file and report effective state per profile.
-- Run with: lua tools/inspect_qui5.lua <path-to-sv.lua>

local svPath = arg[1] or "C:\\Users\\andre\\Downloads\\QUI5.lua"
local f = assert(loadfile(svPath))
f()

local AceRoot = _G.QUI5DB or _G.QUIDB
if not AceRoot then
    error("no AceDB root found in " .. svPath)
end

print("=== AceDB roots present ===")
for k in pairs(AceRoot) do print("  " .. k) end

print("")
print("=== profileKeys (char -> profile binding) ===")
for char, profName in pairs(AceRoot.profileKeys or {}) do
    print(string.format("  %s -> %s", char, profName))
end

print("")
print("=== Effective _schemaVersion per profile (Lua dup-key last-wins) ===")
for name, prof in pairs(AceRoot.profiles or {}) do
    print(string.format("  [%s] _schemaVersion = %s", name, tostring(prof._schemaVersion)))
end

print("")
print("=== Container shape vs containerType (v31 -> containerType only; v32+ -> shape too) ===")
for name, prof in pairs(AceRoot.profiles or {}) do
    local containers = prof.ncdm and prof.ncdm.containers
    if type(containers) == "table" then
        local cnames = {}
        for k in pairs(containers) do cnames[#cnames+1] = k end
        table.sort(cnames)
        for _, cname in ipairs(cnames) do
            local c = containers[cname]
            print(string.format("  [%s].ncdm.containers.%s: containerType=%s shape=%s",
                name, cname, tostring(c.containerType), tostring(c.shape)))
        end
    end
end

print("")
print("=== Pandemic glow keys per profile (v36: *PandemicDebuffEnabled + *PandemicBuffEnabled; pre-v36: single *PandemicEnabled) ===")
for name, prof in pairs(AceRoot.profiles or {}) do
    local cg = prof.customGlow
    if type(cg) == "table" then
        local keys = {}
        for k in pairs(cg) do
            if k:find("[Pp]andemic") then keys[#keys+1] = k end
        end
        table.sort(keys)
        print(string.format("  [%s]: %s", name, table.concat(keys, ", ")))
    end
end

print("")
print("=== Entry kind stamping (v32+ stamps kind=aura/cooldown on entries) ===")
for name, prof in pairs(AceRoot.profiles or {}) do
    local containers = prof.ncdm and prof.ncdm.containers
    if type(containers) == "table" then
        for cname, c in pairs(containers) do
            local entries = c.entries
            if type(entries) == "table" then
                local total, withKind, types = 0, 0, {}
                for _, e in pairs(entries) do
                    if type(e) == "table" then
                        total = total + 1
                        if e.kind then withKind = withKind + 1 end
                        local t = e.type or "spell"
                        types[t] = (types[t] or 0) + 1
                    end
                end
                if total > 0 then
                    local tparts = {}
                    for t, n in pairs(types) do tparts[#tparts+1] = string.format("%s=%d", t, n) end
                    table.sort(tparts)
                    print(string.format("  [%s].%s: %d entries (%s), %d carry kind",
                        name, cname, total, table.concat(tparts, ","), withKind))
                end
            end
        end
    end
end

print("")
print("=== Per-char ncdm state (visible spec, anchored profile) ===")
for char, charData in pairs(AceRoot.char or {}) do
    if type(charData) == "table" and charData.ncdm then
        local n = charData.ncdm
        print(string.format("  [%s]: _lastSpecID=%s",
            char, tostring(n._lastSpecID)))
        if type(n._specProfilesByProfile) == "table" then
            for prof, specs in pairs(n._specProfilesByProfile) do
                if type(specs) == "table" then
                    for specID, _ in pairs(specs) do
                        print(string.format("    profile=%s specID=%s",
                            prof, tostring(specID)))
                    end
                end
            end
        end
    end
end

print("")
print("=== Sanity: NaN / negative / non-finite numeric values anywhere in profiles ===")
local function walk(t, path, seen)
    seen = seen or {}
    if seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
        local p = path .. "." .. tostring(k)
        if type(v) == "number" then
            if v ~= v then
                print(string.format("  NaN at %s", p))
            elseif v == math.huge or v == -math.huge then
                print(string.format("  inf at %s = %s", p, tostring(v)))
            end
        elseif type(v) == "table" then
            walk(v, p, seen)
        end
    end
end
for name, prof in pairs(AceRoot.profiles or {}) do
    walk(prof, "profiles." .. name, {})
end
print("  (none found if no lines above)")

print("")
print("=== global.ncdm.specTrackerSpells (custom bar per-spec entries) ===")
local gncdm = AceRoot.global and AceRoot.global.ncdm
if gncdm and type(gncdm.specTrackerSpells) == "table" then
    for containerKey, byContainer in pairs(gncdm.specTrackerSpells) do
        if type(byContainer) == "table" then
            for specKey, list in pairs(byContainer) do
                if type(list) == "table" then
                    local total, withKind = 0, 0
                    for _, e in pairs(list) do
                        if type(e) == "table" then
                            total = total + 1
                            if e.kind then withKind = withKind + 1 end
                        end
                    end
                    if total > 0 then
                        print(string.format("  %s[%s]: %d entries, %d carry kind",
                            containerKey, tostring(specKey), total, withKind))
                    end
                end
            end
        end
    end
end
