-- tests/taint/findings.lua
-- Finding records + renderers for the taint analyzer.

local M = {}

local VALID_SEVERITIES = { strict = true, advisory = true, review = true }

--- Construct a finding record. Fills defaults for unset fields.
function M.new(spec)
    assert(type(spec.file) == "string", "file must be a string")
    assert(type(spec.line) == "number", "line must be a number")
    assert(type(spec.severity) == "string", "severity must be a string")
    assert(VALID_SEVERITIES[spec.severity],
        "severity must be strict|advisory|review, got: " .. tostring(spec.severity))
    if spec.col ~= nil then
        assert(type(spec.col) == "number", "col must be a number")
    end

    local message = spec.message or ""
    message = message:gsub("[\r\n]+", " ")  -- collapse newlines to single space

    local suppression_reason = spec.suppression_reason
    if suppression_reason then
        suppression_reason = suppression_reason:gsub("[\r\n]+", " ")
    end

    return {
        file             = spec.file,
        line             = spec.line,
        col              = spec.col or 1,
        severity         = spec.severity,
        source_function  = spec.source_function or "<unknown>",
        sink             = spec.sink or "<unknown>",
        message          = message,
        suppressed       = spec.suppressed or false,
        suppression_reason = suppression_reason,
    }
end

local function compareFindings(a, b)
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return a.line < b.line end
    if a.col ~= b.col then return a.col < b.col end
    if a.severity ~= b.severity then return a.severity < b.severity end
    if a.sink ~= b.sink then return a.sink < b.sink end
    if a.source_function ~= b.source_function then return a.source_function < b.source_function end
    return a.message < b.message
end

--- Render findings as plain text, one per line, sorted by file:line:col.
function M.renderText(findings)
    if #findings == 0 then return "" end
    local sorted = {}
    for i, f in ipairs(findings) do sorted[i] = f end
    table.sort(sorted, compareFindings)

    local lines = {}
    for _, f in ipairs(sorted) do
        lines[#lines + 1] = string.format(
            "%s:%d:%d [%s] %s: %s (source: %s)",
            f.file, f.line, f.col, f.severity, f.sink, f.message, f.source_function
        )
    end
    -- Trailing newline so the rendered block reads like a file
    return table.concat(lines, "\n") .. "\n"
end

local function escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

--- Render findings as JSON, one object per finding, sorted by file:line:col.
function M.renderJSON(findings)
    if #findings == 0 then return "[]\n" end
    local sorted = {}
    for i, f in ipairs(findings) do sorted[i] = f end
    table.sort(sorted, compareFindings)

    local parts = { "[\n" }
    for i, f in ipairs(sorted) do
        local sep = (i < #sorted) and "," or ""
        parts[#parts + 1] = string.format(
            '  {"file": "%s", "line": %d, "col": %d, "severity": "%s", ' ..
            '"source_function": "%s", "sink": "%s", "message": "%s", ' ..
            '"suppressed": %s, "suppression_reason": %s}%s\n',
            escape(f.file), f.line, f.col, escape(f.severity),
            escape(f.source_function), escape(f.sink), escape(f.message),
            tostring(f.suppressed),
            f.suppression_reason and ('"' .. escape(f.suppression_reason) .. '"') or "null",
            sep
        )
    end
    parts[#parts + 1] = "]\n"
    return table.concat(parts)
end

--- Render findings as GitHub Actions workflow annotation lines.
-- advisory/review → ::warning, strict → ::error
function M.renderGitHub(findings)
    if #findings == 0 then return "" end
    local sorted = {}
    for i, f in ipairs(findings) do sorted[i] = f end
    table.sort(sorted, compareFindings)
    local parts = {}
    for _, f in ipairs(sorted) do
        local kind = (f.severity == "strict") and "error" or "warning"
        parts[#parts + 1] = string.format(
            "::%s file=%s,line=%d,col=%d::[%s] %s: %s (source: %s)\n",
            kind, f.file, f.line, f.col, f.severity, f.sink, f.message, f.source_function
        )
    end
    return table.concat(parts)
end

return M
