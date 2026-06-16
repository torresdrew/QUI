--[[
  view_sv.lua

  Read a QUI SavedVariables Lua file, embed its contents into a self-
  contained HTML viewer (`tools/view_sv.html`), and open the file in your
  browser. The viewer is QUI-aware: tabs for profiles / chars / global,
  search across keys and values, and a diff-vs-defaults toggle on profiles.

  Usage:
    lua tools/view_sv.lua --in "<path-to-QUI.lua>"
    lua tools/view_sv.lua --in "<path>" --out tools/view_sv.html

  Example (Windows retail SavedVariables):
    lua tools/view_sv.lua \
      --in "C:/Program Files (x86)/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/QUI.lua"

  Run from the repository root so bundled libs and core/ resolve.
]]

local function ScriptDir()
    local p = (arg and arg[0]) or ""
    p = p:gsub("\\", "/")
    local dir = p:match("(.*/)")
    if dir == nil or dir == "" then return "./" end
    return dir
end

local SCRIPT_DIR = ScriptDir()
local REPO_ROOT  = SCRIPT_DIR .. "../"

----------------------------------------------------------------------------
-- Args
----------------------------------------------------------------------------

local function ParseArgs(argv)
    local opts = { _in = nil, _out = SCRIPT_DIR .. "view_sv.html", help = false }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--help" or a == "-h" then
            opts.help = true
        elseif a == "--in" then
            i = i + 1
            opts._in = argv[i]
        elseif a == "--out" then
            i = i + 1
            opts._out = argv[i]
        else
            io.stderr:write("Unknown argument: " .. tostring(a) .. "\n")
            opts.help = true
        end
        i = i + 1
    end
    return opts
end

local function PrintHelp()
    io.write([[
view_sv.lua — render QUI SavedVariables to a browseable HTML page.

  --in   <path>   Path to QUI.lua SavedVariables file (required)
  --out  <path>   Output HTML path (default: tools/view_sv.html)
  --help          Show this help

Run from repo root.
]])
end

local args = ParseArgs(arg or {})
if args.help or not args._in then
    PrintHelp()
    if not args.help then os.exit(1) end
    os.exit(0)
end

----------------------------------------------------------------------------
-- Load the SV file
--
-- The SV file is plain Lua that declares two globals: QUI_DB and QUIDB.
-- We dofile() it directly. We also load `core/defaults.lua` through the
-- shared headless env so we can ship defaults alongside the SV for the
-- viewer's diff feature.
----------------------------------------------------------------------------

local env = dofile(SCRIPT_DIR .. "_addon_env.lua")
local ns  = env.LoadCore()  -- populates ns.defaults from core/defaults.lua

local function ReadFile(path)
    local f, err = io.open(path, "rb")
    if not f then error("Could not open --in file: " .. tostring(err)) end
    local data = f:read("*a")
    f:close()
    return data
end

local function LoadSV(path)
    -- Reset before loading so leftovers from earlier runs don't bleed in.
    _G.QUI_DB, _G.QUIDB = nil, nil
    local chunk, err = loadfile(path)
    if not chunk then error("Failed to parse SV file: " .. tostring(err)) end
    chunk()
    return _G.QUI_DB, _G.QUIDB
end

local QUI_DB, QUIDB = LoadSV(args._in)
if type(QUI_DB) ~= "table" and type(QUIDB) ~= "table" then
    error("SV file did not declare QUI_DB or QUIDB (is this a QUI SavedVariables file?)")
end

----------------------------------------------------------------------------
-- Lua → JSON encoder
--
-- Rules:
--   - Tables that are dense 1..N integer-keyed sequences  → JSON arrays
--   - Anything else (mixed keys, sparse numeric, etc.)    → JSON objects,
--     with all keys stringified. Numeric keys appear as quoted numeric
--     strings (e.g. "103"). Keys are sorted: numbers ascending, then
--     strings alphabetically — gives stable, human-readable output.
--   - NaN / ±Inf / functions / userdata                   → null
--
-- Cycles aren't expected in SV data, but we guard with a depth cap.
----------------------------------------------------------------------------

local MAX_DEPTH = 64

local function isSequence(t)
    local n = #t
    if n == 0 then
        return next(t) == nil  -- empty table: treat as empty object {}
    end
    local count = 0
    for k in pairs(t) do
        count = count + 1
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n then
            return false
        end
    end
    return count == n
end

local ESCAPES = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
}

local function encodeString(s)
    s = s:gsub('[\\"%z\1-\31]', function(c)
        local e = ESCAPES[c]
        if e then return e end
        return string.format('\\u%04x', c:byte())
    end)
    return '"' .. s .. '"'
end

local function encodeNumber(n)
    if n ~= n then return "null" end
    if n == math.huge or n == -math.huge then return "null" end
    if n % 1 == 0 and n >= -1e15 and n <= 1e15 then
        return string.format("%d", n)
    end
    return tostring(n)
end

local function keyToString(k)
    local t = type(k)
    if t == "string"  then return k end
    if t == "number"  then return encodeNumber(k):gsub("^null$", "NaN") end
    if t == "boolean" then return tostring(k) end
    return tostring(k)
end

local function compareKeys(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb then
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end
    -- numbers before strings before everything else
    if ta == "number" then return true  end
    if tb == "number" then return false end
    if ta == "string" then return true  end
    if tb == "string" then return false end
    return tostring(a) < tostring(b)
end

local function encodeValue(v, depth)
    depth = depth or 0
    if depth > MAX_DEPTH then return '"<depth-cap>"' end
    local t = type(v)
    if v == nil          then return "null"  end
    if t == "boolean"    then return v and "true" or "false" end
    if t == "number"     then return encodeNumber(v) end
    if t == "string"     then return encodeString(v) end
    if t == "table" then
        if isSequence(v) then
            local parts = {}
            for i = 1, #v do parts[i] = encodeValue(v[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, compareKeys)
        local parts = {}
        for i, k in ipairs(keys) do
            parts[i] = encodeString(keyToString(k)) .. ":" .. encodeValue(v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"  -- function / userdata / thread
end

----------------------------------------------------------------------------
-- Build payload
----------------------------------------------------------------------------

local function FileBasename(p)
    p = p:gsub("\\", "/")
    return (p:match("([^/]+)$")) or p
end

local payload = {
    meta = {
        generated  = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        sourcePath = args._in,
        sourceName = FileBasename(args._in),
        toolVersion = "1.0",
    },
    QUI_DB   = QUI_DB or {},
    QUIDB    = QUIDB  or {},
    defaults = ns.defaults or {},
}

local payloadJson = encodeValue(payload, 0)

----------------------------------------------------------------------------
-- Render template → output
----------------------------------------------------------------------------

local TEMPLATE_PATH = SCRIPT_DIR .. "view_sv.template.html"
local template = ReadFile(TEMPLATE_PATH)

-- Single placeholder. Use a literal replacement (no pattern processing) so
-- accidental `%` in JSON strings don't corrupt the output.
local placeholder = "__SV_DATA__"
local i1, i2 = template:find(placeholder, 1, true)
if not i1 then
    error("Template missing __SV_DATA__ placeholder: " .. TEMPLATE_PATH)
end
local rendered = template:sub(1, i1 - 1) .. payloadJson .. template:sub(i2 + 1)

local function WriteFile(path, content)
    local f, err = io.open(path, "wb")
    if not f then error("Could not write --out file: " .. tostring(err)) end
    f:write(content)
    f:close()
end

WriteFile(args._out, rendered)

----------------------------------------------------------------------------
-- Summary
----------------------------------------------------------------------------

local function CountKeys(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local profiles = (QUI_DB and QUI_DB.profiles) or {}
local chars    = (QUIDB  and QUIDB.char)      or {}

io.write(string.format(
    "Wrote %s\n  source:    %s\n  profiles:  %d  (%s)\n  chars:     %d\n  payload:   %.1f KB\n",
    args._out,
    args._in,
    CountKeys(profiles),
    table.concat((function()
        local names = {}
        for name in pairs(profiles) do names[#names + 1] = name end
        table.sort(names)
        return names
    end)(), ", "),
    CountKeys(chars),
    #payloadJson / 1024
))
