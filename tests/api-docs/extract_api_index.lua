-- Sandboxed Blizzard APIDocumentation table loader.
-- Runs each *.lua in a corpus directory under a controlled environment that
-- stubs APIDocumentation:AddDocumentationTable, captures registered tables,
-- and builds a compact flag index keyed by "Module.Function".
--
-- Usage:
--   local Extract = dofile("tests/api-docs/extract_api_index.lua")
--   local index = Extract.fromCorpus("tests/api-docs/synthetic-corpus")
--   print(Extract.renderLua(index))

local M = {}

-- ---------------------------------------------------------------------------
-- Sandbox helpers
-- ---------------------------------------------------------------------------

-- Doc files reference Enum.* / Constants.* values inside table constructors
-- (12.1.0.68675+ aspect flags, e.g. SecretReturnsForAspect =
-- { Enum.SecretAspect.Alpha }); a plain Lua host has neither global, so the
-- nil index would abort the chunk and silently drop every table in the file.
-- Auto-vivify with stable string placeholders — none of the extracted flags
-- carry these values, they just have to be indexable without erroring.
local function makeAutoTable(prefix)
    return setmetatable({}, {
        __index = function(t, k)
            local v = setmetatable({}, {
                __index = function(_, k2)
                    return prefix .. "." .. tostring(k) .. "." .. tostring(k2)
                end,
            })
            rawset(t, k, v)
            return v
        end,
    })
end

local function makeSandbox()
    local captured = {}
    local APIDocumentation = {}
    function APIDocumentation:AddDocumentationTable(tbl)
        captured[#captured + 1] = tbl
    end
    return APIDocumentation, captured
end

-- SecretReturnsForAspect / SecretArgumentsAddAspect (12.1.0.68675+) carry
-- lists of Enum.SecretAspect.* values. The sandbox auto-vivifies Enum into
-- placeholder strings ("Enum.SecretAspect.Alpha"); strip the prefix so the
-- index stores bare aspect names ({"Alpha"}).
local function collectAspects(v)
    if type(v) ~= "table" then return nil end
    local names = {}
    for _, item in ipairs(v) do
        local s = tostring(item)
        names[#names + 1] = s:match("^Enum%.SecretAspect%.(.+)$") or s
    end
    if #names == 0 then return nil end
    table.sort(names)
    return names
end

local function returnsFlaggedSecret(returns)
    if type(returns) ~= "table" then return false end
    for _, r in ipairs(returns) do
        if r.IsSecret == true then return true end
    end
    return false
end

-- Precondition flags (e.g. RequiresUnitAuraAccess = true) gate the whole
-- call: SecretPredicatesDocumentation.lua gives RequiresUnitAuraAccess
-- FailureMode = "Error", i.e. the API HARD-ERRORS under encounter/M+/PvP
-- restrictions. Audits that only looked for Secret* flags missed every
-- guarded-but-erroring API (the 2026-07 external review found three shipped
-- callers that way), so capture any truthy Requires*-prefixed flag.
local function collectPreconditions(fn)
    local pre
    for k, v in pairs(fn) do
        if type(k) == "string" and v == true and k:match("^Requires%u") then
            pre = pre or {}
            pre[#pre + 1] = k
        end
    end
    if pre then table.sort(pre) end
    return pre
end

local function processTable(tbl, index)
    -- Blizzard doc tables expose two names: tbl.Name (bare, e.g. "Spell") and
    -- tbl.Namespace (the runtime accessor, e.g. "C_Spell"). Code calls the
    -- function via the namespace form, so prefer that. Fall back to Name for
    -- older docs / synthetic fixtures that don't carry a Namespace.
    local moduleName = tbl.Namespace or tbl.Name
    if not moduleName then return end
    if type(tbl.Functions) == "table" then
        for _, fn in ipairs(tbl.Functions) do
            local entry = {}
            local hasFlag = false
            if fn.SecretWhenCooldownsRestricted then
                entry.secretWhenCooldownsRestricted = true
                hasFlag = true
            end
            if fn.SecretArguments and fn.SecretArguments ~= "AllowedWhenTainted" then
                entry.secretArguments = fn.SecretArguments
                hasFlag = true
            end
            if returnsFlaggedSecret(fn.Returns) then
                entry.isSecretReturn = true
                hasFlag = true
            end
            local retAspects = collectAspects(fn.SecretReturnsForAspect)
            if retAspects then
                entry.secretReturnsForAspect = retAspects
                hasFlag = true
            end
            local argAspects = collectAspects(fn.SecretArgumentsAddAspect)
            if argAspects then
                entry.secretArgumentsAddAspect = argAspects
                hasFlag = true
            end
            local pre = collectPreconditions(fn)
            if pre then
                entry.preconditions = pre
                hasFlag = true
            end
            if hasFlag then
                index[moduleName .. "." .. fn.Name] = entry
            end
        end
    end
    -- Events: keyed "event:LITERAL_NAME" (addon code registers by literal
    -- name, and the prefix keeps them from ever colliding with function
    -- lookups). Flagged when the event itself carries a truthy Secret*/
    -- Requires* flag, or any payload field is secretizable (Secret* flag or
    -- IsSecret) — those payloads land in handler args and poison table keys
    -- and comparisons downstream.
    if type(tbl.Events) == "table" then
        for _, ev in ipairs(tbl.Events) do
            local entry = {}
            local hasFlag = false
            local flags
            for k, v in pairs(ev) do
                if type(k) == "string" and v == true
                    and (k:match("^Secret%u") or k:match("^Requires%u")) then
                    flags = flags or {}
                    flags[#flags + 1] = k
                    hasFlag = true
                end
            end
            if flags then
                table.sort(flags)
                entry.eventFlags = flags
            end
            if type(ev.Payload) == "table" then
                for _, field in ipairs(ev.Payload) do
                    if type(field) == "table" then
                        if field.IsSecret == true then
                            entry.secretPayload = true
                            hasFlag = true
                        else
                            for k, v in pairs(field) do
                                if type(k) == "string" and v == true and k:match("^Secret%u") then
                                    entry.secretPayload = true
                                    hasFlag = true
                                    break
                                end
                            end
                        end
                    end
                    if entry.secretPayload then break end
                end
            end
            if hasFlag and ev.LiteralName then
                index["event:" .. ev.LiteralName] = entry
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- File discovery
-- ---------------------------------------------------------------------------

local function discoverFiles(corpusDir)
    local files = {}
    local isWindows = package.config:sub(1, 1) == "\\"
    local cmd
    if isWindows then
        cmd = string.format('dir /b "%s\\*.lua" 2>nul', corpusDir:gsub("/", "\\"))
    else
        cmd = string.format('find "%s" -maxdepth 1 -type f -name "*.lua" 2>/dev/null', corpusDir)
    end
    local p = io.popen(cmd, "r")
    if p then
        for line in p:lines() do
            line = line:gsub("\\", "/"):match("^%s*(.-)%s*$")
            if line ~= "" then
                if isWindows and not line:find("/") then
                    -- Windows dir /b returns just the basename; prepend corpusDir
                    line = corpusDir:gsub("\\", "/") .. "/" .. line
                end
                files[#files + 1] = line
            end
        end
        p:close()
    end
    return files
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build a flag index from all *.lua files in corpusDir.
-- Returns a flat table: { ["Module.Function"] = { flags... }, ... }
-- (plus { ["event:LITERAL_NAME"] = { flags... } } for flagged events).
-- Only entries that carry at least one taint-relevant flag are included.
-- Known flags:
--   secretWhenCooldownsRestricted = true
--   secretArguments               = string  (omitted when "AllowedWhenTainted")
--   isSecretReturn                = true
--   secretReturnsForAspect        = { "Alpha", ... }  (aspect names, sorted)
--   secretArgumentsAddAspect      = { "Alpha", ... }  (aspect names, sorted)
--   preconditions                 = { "RequiresUnitAuraAccess", ... }
--   eventFlags                    = { "SecretInActivePvPMatch", ... }
--   secretPayload                 = true
function M.fromCorpus(corpusDir)
    local APIDocumentation, captured = makeSandbox()
    local files = discoverFiles(corpusDir)

    for _, path in ipairs(files) do
        local f = io.open(path, "rb")
        if f then
            local source = f:read("*a")
            f:close()
            local env = setmetatable({
                APIDocumentation = APIDocumentation,
                Enum = makeAutoTable("Enum"),
                Constants = makeAutoTable("Constants"),
            }, { __index = _G })
            local chunk
            if setfenv then
                -- Lua 5.1
                chunk = (loadstring or load)(source, path)
                if chunk then
                    setfenv(chunk, env)
                    pcall(chunk)
                end
            else
                -- Lua 5.2+
                chunk = load(source, path, "t", env)
                if chunk then
                    pcall(chunk)
                end
            end
        end
    end

    local index = {}
    for _, tbl in ipairs(captured) do
        processTable(tbl, index)
    end
    return index
end

--- Render an index table as sorted, committable Lua source.
-- The output is a return statement so it can be loaded with load()/loadfile().
function M.renderLua(index)
    local keys = {}
    for k in pairs(index) do
        keys[#keys + 1] = k
    end
    table.sort(keys)

    local parts = {
        "-- Auto-generated by tests/api-docs/extract_api_index.lua. Do not edit by hand.\n",
        "return {\n",
    }
    local function renderNameList(list)
        local quoted = {}
        for i, name in ipairs(list) do
            quoted[i] = string.format("%q", name)
        end
        return "{ " .. table.concat(quoted, ", ") .. " }"
    end

    for _, k in ipairs(keys) do
        local entry = index[k]
        local fields = {}
        if entry.secretWhenCooldownsRestricted then
            fields[#fields + 1] = "secretWhenCooldownsRestricted = true"
        end
        if entry.secretArguments then
            fields[#fields + 1] = string.format("secretArguments = %q", entry.secretArguments)
        end
        if entry.isSecretReturn then
            fields[#fields + 1] = "isSecretReturn = true"
        end
        if entry.secretReturnsForAspect then
            fields[#fields + 1] = "secretReturnsForAspect = "
                .. renderNameList(entry.secretReturnsForAspect)
        end
        if entry.secretArgumentsAddAspect then
            fields[#fields + 1] = "secretArgumentsAddAspect = "
                .. renderNameList(entry.secretArgumentsAddAspect)
        end
        if entry.preconditions then
            fields[#fields + 1] = "preconditions = " .. renderNameList(entry.preconditions)
        end
        if entry.eventFlags then
            fields[#fields + 1] = "eventFlags = " .. renderNameList(entry.eventFlags)
        end
        if entry.secretPayload then
            fields[#fields + 1] = "secretPayload = true"
        end
        parts[#parts + 1] = string.format("    [%q] = { %s },\n", k, table.concat(fields, ", "))
    end
    parts[#parts + 1] = "}\n"
    return table.concat(parts)
end

return M
