-- tests/taint/annotations.lua
-- Scan Lua source for `-- @secret-safe: <reason>` comments and produce a
-- per-line lookup of suppressions.

local M = {}

-- Match `-- @secret-safe:` followed by optional space + reason text. Captures
-- the reason text (may be empty if user wrote `-- @secret-safe:` only).
local PATTERN = "%-%-%s*@secret%-safe:%s*(.*)$"

--- Scan source. Returns a table indexed by 1-based line number, with each
--- entry { reason = string|nil, emptyReason = boolean }.
function M.scan(source)
    local result = {}
    local lineNum = 0
    local pendingForNextLine = nil

    -- Iterate lines including final no-newline line
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        lineNum = lineNum + 1
        local trimmed = line:match("^%s*(.-)%s*$")
        local reason = trimmed:match(PATTERN)

        if reason ~= nil then
            -- Is this an annotation-only line (no code)?
            local codePart = trimmed:gsub(PATTERN, "")
            codePart = codePart:match("^%s*(.-)%s*$")
            if codePart == "" then
                -- Annotation-only line → applies to the NEXT non-blank line
                pendingForNextLine = {
                    reason = (#reason > 0) and reason or nil,
                    emptyReason = (#reason == 0),
                }
            else
                -- Trailing-style annotation → applies to THIS line
                result[lineNum] = {
                    reason = (#reason > 0) and reason or nil,
                    emptyReason = (#reason == 0),
                }
                pendingForNextLine = nil
            end
        else
            -- No annotation on this line. If pending, attach to this line
            -- (only if this line has actual code, not blank).
            if pendingForNextLine and trimmed ~= "" then
                result[lineNum] = pendingForNextLine
                pendingForNextLine = nil
            end
        end
    end

    return result
end

--- Apply annotations to a list of findings. Mutates findings in place,
--- setting suppressed=true and suppression_reason on matches.
function M.apply(findings, annotations)
    for _, f in ipairs(findings) do
        local a = annotations[f.line]
        if a and a.reason then
            f.suppressed = true
            f.suppression_reason = a.reason
        end
    end
end

return M
