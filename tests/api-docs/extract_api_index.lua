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

local function makeSandbox()
    local captured = {}
    local APIDocumentation = {}
    function APIDocumentation:AddDocumentationTable(tbl)
        captured[#captured + 1] = tbl
    end
    return APIDocumentation, captured
end

local function returnsFlaggedSecret(returns)
    if type(returns) ~= "table" then return false end
    for _, r in ipairs(returns) do
        if r.IsSecret == true then return true end
    end
    return false
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
            if hasFlag then
                index[moduleName .. "." .. fn.Name] = entry
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
-- Only functions that carry at least one taint-relevant flag are included.
-- Known flags:
--   secretWhenCooldownsRestricted = true
--   secretArguments               = string  (omitted when "AllowedWhenTainted")
--   isSecretReturn                = true
function M.fromCorpus(corpusDir)
    local APIDocumentation, captured = makeSandbox()
    local files = discoverFiles(corpusDir)

    for _, path in ipairs(files) do
        local f = io.open(path, "rb")
        if f then
            local source = f:read("*a")
            f:close()
            local env = setmetatable({ APIDocumentation = APIDocumentation },
                { __index = _G })
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
        parts[#parts + 1] = string.format("    [%q] = { %s },\n", k, table.concat(fields, ", "))
    end
    parts[#parts + 1] = "}\n"
    return table.concat(parts)
end

return M
