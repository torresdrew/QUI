-- tests/taint/analyzer.lua
-- Static taint-flow analyzer. Accepts Lua source + filename, returns a list of
-- Finding records.

local Parser = dofile("tests/taint/parser/init.lua")
local Annotations = dofile("tests/taint/annotations.lua")
local Config = dofile("tests/taint/config.lua")

local M = {}

--- Resolve a CallExpr's Base node to a fully-qualified name string.
--- Returns the name string, or nil if it cannot be resolved.
--- Also returns a kind: "function" (dot-access or bare) or "method" (colon-access).
--- Examples:
---   VarExpr "foo"          → "foo", "function"
---   MemberExpr "C_Spell.GetSpellCharges"  → "C_Spell.GetSpellCharges", "function"
---   MemberExpr "obj:GetMethod" (Indexer=":") → "obj:GetMethod", "method"
local function callTargetName(baseNode)
    if not baseNode then return nil, nil end
    local t = baseNode.AstType
    if t == "VarExpr" then
        return baseNode.Name, "function"
    elseif t == "MemberExpr" then
        local parentName = callTargetName(baseNode.Base)
        if not parentName then return nil, nil end
        local identName = baseNode.Ident and baseNode.Ident.Data
        if not identName then return nil, nil end
        local sep = baseNode.Indexer  -- "." or ":"
        local kind = (sep == ":") and "method" or "function"
        return parentName .. sep .. identName, kind
    end
    return nil, nil
end

-- Built-in unsafe Lua sinks (calls that read a secret value at the Lua level).
-- NOTE: `type` is intentionally NOT here — it returns a fixed type-tag string
-- ("table", "number", etc.) and does not read value contents, so passing a
-- secret value to it leaks nothing.
local UNSAFE_BUILTIN_FUNCTIONS = {
    tonumber = true, tostring = true, print = true,
    pairs = true, ipairs = true, next = true,
    rawget = true, rawset = true, rawequal = true, rawlen = true,
    select = true, error = true, assert = true,
}

local COMPARISON_OPS = { ["=="]=true, ["~="]=true, ["<"]=true, [">"]=true,
    ["<="]=true, [">="]=true }
local ARITH_OPS = { ["+"]=true, ["-"]=true, ["*"]=true, ["/"]=true,
    ["%"]=true, ["^"]=true, [".."]=true }

local function isVarRef(expr)
    return type(expr) == "table" and expr.AstType == "VarExpr"
end

-- Returns true if expr is a tainted local OR a read of a tainted field (t.k).
-- fieldTaintSet is keyed by "<tableLocalName>.<field>".
-- Also handles deep chains: if any ancestor in the MemberExpr chain is a tainted
-- local, the whole chain is considered tainted (conservative over-approximation).
-- Clean-field whitelist: when registry:isCleanField(<field>) is true, reading
-- that field from any base is treated as non-secret (e.g. SpellCooldownInfo.
-- isOnGCD is always a clean boolean per Blizzard contract).
local function isTaintedRef(expr, taintSet, fieldTaintSet, registry)
    if type(expr) ~= "table" then return false end
    if expr.AstType == "VarExpr" then
        return taintSet[expr.Name] == true
    end
    if expr.AstType == "MemberExpr"
       and expr.Indexer == "."
       and expr.Ident and expr.Ident.Data then
        local field = expr.Ident.Data
        -- Clean-field whitelist applies regardless of base shape.
        if registry and registry.isCleanField and registry:isCleanField(field) then
            return false
        end
        if expr.Base and expr.Base.AstType == "VarExpr" then
            -- Field-write-then-read tracking
            local key = expr.Base.Name .. "." .. field
            if fieldTaintSet[key] == true then return true end
            -- Read of any field from a tainted base local
            if taintSet[expr.Base.Name] == true then return true end
        elseif expr.Base and expr.Base.AstType == "MemberExpr" then
            -- Recurse: deep chain (e.g. tainted.sub.field)
            return isTaintedRef(expr.Base, taintSet, fieldTaintSet, registry)
        end
    end
    return false
end

-- Extract the trailing method/field name from a qualified name produced by
-- callTargetName. The separator is "." for dot-access and ":" for colon-access,
-- so we split on the last "." or ":" character.
-- Examples: "cd:SetCooldownFromDurationObject" → "SetCooldownFromDurationObject"
--           "C_StringUtil.RoundToNearestString" → "RoundToNearestString"
--           "bare"                              → "bare"
local function getMethodNameFromQualified(qualified)
    local lastSep = qualified:match(".*[.:]()") -- () captures position after separator
    if lastSep then return qualified:sub(lastSep) end
    return qualified
end

--- Get line number from an AST node. AST nodes store line info in Tokens[1].Line.
local function nodeLine(node)
    return (node.Tokens and node.Tokens[1] and node.Tokens[1].Line) or 0
end

--- Emit a finding into `findings`. Severity defaults to advisory; later tasks
--- promote to strict by file path.
local function emit(findings, filePath, line, col, sink, sourceFunc, message)
    findings[#findings + 1] = {
        file = filePath, line = line or 0, col = col or 1,
        severity = "advisory",
        source_function = sourceFunc or "<unknown>",
        sink = sink, message = message or "",
        suppressed = false, suppression_reason = nil,
    }
end

-- Forward declarations so expression and statement walkers can call each other.
local walkExpr
local walkStatements

local function stripParens(expr)
    while type(expr) == "table" and expr.AstType == "Parentheses" do
        expr = expr.Inner
    end
    return expr
end

local function copySet(set)
    local copy = {}
    for k, v in pairs(set or {}) do
        if v then copy[k] = true end
    end
    return copy
end

local function clearParamTaint(taintSet, fieldTaintSet, funcNode)
    for _, arg in ipairs(funcNode.Arguments or {}) do
        local name = arg.Name
        if name then
            taintSet[name] = nil
            local prefix = name .. "."
            for key in pairs(fieldTaintSet) do
                if key:sub(1, #prefix) == prefix then
                    fieldTaintSet[key] = nil
                end
            end
        end
    end
end

local function walkFunctionBody(funcNode, taintSet, fieldTaintSet, findings, registry, filePath, debug)
    if not (funcNode.Body and funcNode.Body.Body) then return end
    local closureTaint = copySet(taintSet)
    local closureFieldTaint = copySet(fieldTaintSet)
    clearParamTaint(closureTaint, closureFieldTaint, funcNode)
    walkStatements(funcNode.Body.Body, closureTaint, closureFieldTaint, findings, registry, filePath, debug)
end

local function walkConditionExpr(expr, taintSet, fieldTaintSet, findings, registry, filePath)
    local inner = stripParens(expr)
    if isTaintedRef(inner, taintSet, fieldTaintSet, registry) then
        emit(findings, filePath, nodeLine(inner), 1, "<truthiness>",
            "<tainted-local>",
            "tainted value used as a branch condition without guard or C-side decode")
    end
    return walkExpr(expr, taintSet, fieldTaintSet, findings, registry, filePath)
end

-- Inspect a condition expression. If it matches a guard pattern, return a
-- table { kind = "untaint-then" | "untaint-else", locals = { name1, ... } }.
-- Otherwise return nil.
-- Patterns matched:
--   not Guard(x)  → kind = "untaint-then"  (untaint x in the then-branch)
--   Guard(x)      → kind = "untaint-else"  (untaint x in the else-branch)
local function analyzeGuard(cond, registry)
    if type(cond) ~= "table" then return nil end

    local negated = false
    local inner = cond
    if cond.AstType == "UnopExpr" and cond.Op == "not" then
        negated = true
        inner = cond.Rhs
    end

    if inner and inner.AstType == "CallExpr" then
        local name = callTargetName(inner.Base)
        if name and registry:isGuard(name) then
            local locals = {}
            if inner.Arguments then
                for _, a in ipairs(inner.Arguments) do
                    if isVarRef(a) then
                        locals[#locals + 1] = a.Name
                    end
                end
            end
            if #locals == 0 then return nil end
            return {
                kind = negated and "untaint-then" or "untaint-else",
                locals = locals,
            }
        end
    end
    return nil
end

--- Walk an expression for unsafe sinks consuming tainted locals.
--- Returns true if the expression itself is (or contains) a source call —
--- the caller uses this to decide whether the assigned-to variable is tainted.
--- fieldTaintSet tracks tainted table fields keyed by "<tableLocal>.<field>".
walkExpr = function(expr, taintSet, fieldTaintSet, findings, registry, filePath)
    if type(expr) ~= "table" then return false end
    local t = expr.AstType
    if not t then return false end

    if t == "Parentheses" then
        return walkExpr(expr.Inner, taintSet, fieldTaintSet, findings, registry, filePath)
    end

    if t == "Function" then
        -- Closure body. This is still intra-file and non-interprocedural, but
        -- tainted locals can be captured as upvalues by callbacks and sort
        -- predicates, so inherit the current scope and clear function params.
        walkFunctionBody(expr, taintSet, fieldTaintSet, findings, registry, filePath, nil)
        return false
    end

    if t == "BinopExpr" then
        local op = expr.Op
        local lhsTainted = isTaintedRef(expr.Lhs, taintSet, fieldTaintSet, registry)
        local rhsTainted = isTaintedRef(expr.Rhs, taintSet, fieldTaintSet, registry)
        if lhsTainted or rhsTainted then
            local sinkLabel
            if COMPARISON_OPS[op] then
                sinkLabel = "<comparison>"
            elseif ARITH_OPS[op] then
                sinkLabel = "<arith>"
            else
                sinkLabel = "<binop:" .. (op or "?") .. ">"
            end
            emit(findings, filePath, nodeLine(expr), 1, sinkLabel,
                "<tainted-local>",
                "tainted value used in " .. sinkLabel .. " without guard or unwrap")
        end
        -- Recurse and OR returns to propagate "contains source" up
        local lhsHadSource = walkExpr(expr.Lhs, taintSet, fieldTaintSet, findings, registry, filePath)
        local rhsHadSource = walkExpr(expr.Rhs, taintSet, fieldTaintSet, findings, registry, filePath)
        return lhsHadSource or rhsHadSource
    end

    if t == "CallExpr" then
        local name, kind = callTargetName(expr.Base)
        if name then
            -- pcall/xpcall(<source>, ...): treat the whole call as a source call.
            -- Lua signature: pcall(f, arg1, ...) and xpcall(f, msgh, arg1, ...).
            -- In both cases argument 1 is the function being protected.
            -- If that function is a registered source, the pcall result is tainted.
            if name == "pcall" or name == "xpcall" then
                local fnArg = expr.Arguments and expr.Arguments[1]
                if fnArg then
                    local fnName = callTargetName(fnArg)
                    if fnName and registry:isSource(fnName) then
                        -- Walk remaining arguments for nested sinks
                        for i = 2, #(expr.Arguments or {}) do
                            walkExpr(expr.Arguments[i], taintSet, fieldTaintSet, findings, registry, filePath)
                        end
                        return true  -- result is tainted (conservative: includes the ok bool)
                    end
                end
                -- fnArg is not a source — fall through to normal argument recursion
            end
            -- Source call: walk arguments for nested sinks but do not emit here
            if registry:isSource(name) then
                if expr.Arguments then
                    for _, a in ipairs(expr.Arguments) do
                        walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                    end
                end
                return true
            end
            -- Safe sink: tainted args are acceptable; still recurse into
            -- argument expressions to catch any nested unsafe sub-expressions
            -- (e.g. frame:SetText(tonumber(x)) — SetText is safe but tonumber is not).
            -- If the function is ALSO secret-returning (e.g. C_StringUtil
            -- formatters), the return value carries taint to the LHS — caller
            -- decides what to do with that based on context.
            if (kind == "method" and registry:isSafeSinkMethod(getMethodNameFromQualified(name))) or
               (kind == "function" and registry:isSafeSinkFunction(name)) then
                if expr.Arguments then
                    for _, a in ipairs(expr.Arguments) do
                        walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                    end
                end
                return registry:isSecretReturning(name)
            end
            -- Unwrap: emit review finding, but do NOT propagate taint forward
            if registry:isUnwrap(name) then
                findings[#findings + 1] = {
                    file = filePath, line = nodeLine(expr) or 0, col = 1,
                    severity = "review",
                    source_function = name,
                    sink = "<unwrap>",
                    message = "unwrap call site — consider piping to a C-side sink instead",
                    suppressed = false, suppression_reason = nil,
                }
                if expr.Arguments then
                    for _, a in ipairs(expr.Arguments) do
                        walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                    end
                end
                return false  -- result is non-tainted; do NOT mark as source
            end
            -- Unsafe builtin called with a tainted argument
            if UNSAFE_BUILTIN_FUNCTIONS[name] then
                if expr.Arguments then
                    for _, a in ipairs(expr.Arguments) do
                        if isTaintedRef(a, taintSet, fieldTaintSet, registry) then
                            emit(findings, filePath, nodeLine(expr), 1, name,
                                "<tainted-local>",
                                "tainted value passed to " .. name)
                        end
                        -- Recurse to catch deeper sinks even in non-tainted args
                        walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                    end
                end
                return false
            end
            -- Secret-returning function that is NOT also a safe sink (e.g. a
            -- user-defined wrapper). Recurse args, then propagate taint via
            -- return so downstream sinks get caught.
            if registry:isSecretReturning(name) then
                if expr.Arguments then
                    for _, a in ipairs(expr.Arguments) do
                        walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                    end
                end
                return true
            end
        end
        -- Non-source, non-builtin call: still recurse into arguments
        if expr.Arguments then
            for _, a in ipairs(expr.Arguments) do
                walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
            end
        end
        return false
    end

    if t == "UnopExpr" then
        local rhsTainted = isTaintedRef(expr.Rhs, taintSet, fieldTaintSet, registry)
        if rhsTainted then
            emit(findings, filePath, nodeLine(expr), 1, "<unop:" .. (expr.Op or "?") .. ">",
                "<tainted-local>",
                "tainted value used in unary " .. (expr.Op or "?"))
        end
        return walkExpr(expr.Rhs, taintSet, fieldTaintSet, findings, registry, filePath)
    end

    return false
end

--- Walk a statement list, updating taintSet/fieldTaintSet and emitting findings.
--- taintSet: map of varName → true for tainted variables.
--- fieldTaintSet: map of "<tableLocal>.<field>" → true for tainted fields.
--- debug: optional table; if present, records taintedAt[varName] = line.
walkStatements = function(stmts, taintSet, fieldTaintSet, findings, registry, filePath, debug)
    for _, stmt in ipairs(stmts) do
        local t = stmt.AstType
        if not t then
            -- skip Eof and other non-statement nodes
        elseif t == "Function" then
            -- function name() ... end OR local function name() ... end. Inherit
            -- tainted upvalues, but function parameters shadow outer locals.
            walkFunctionBody(stmt, taintSet, fieldTaintSet, findings, registry, filePath, debug)
        elseif t == "LocalStatement" then
            -- local a, b, c = expr1, expr2, expr3
            -- Each LHS variable is tainted if its corresponding RHS contains a
            -- source call or reads a tainted field. walkExpr also emits findings
            -- for any sinks in the RHS.
            -- When more LHS vars exist than RHS expressions, the last RHS may be
            -- a multi-return call (e.g. pcall/source). If it was tainted, propagate
            -- that taint to the overflow LHS vars as well.
            local localList = stmt.LocalList or {}
            local initList  = stmt.InitList  or {}
            local lastRhsTainted = false
            local lastRhsNode = nil
            for i, varEntry in ipairs(localList) do
                local varName = varEntry.Name
                if varName then
                    local rhs = initList[i]
                    if rhs then
                        -- Detect pcall/xpcall(<source>, ...): the FIRST return is
                        -- always a clean boolean (success flag), only the spilled
                        -- subsequent LHS vars carry the source's tainted result.
                        local rhsIsPcallOfSource = false
                        if rhs.AstType == "CallExpr" then
                            local pname = callTargetName(rhs.Base)
                            if pname == "pcall" or pname == "xpcall" then
                                local fnArg = rhs.Arguments and rhs.Arguments[1]
                                if fnArg then
                                    local fnName = callTargetName(fnArg)
                                    if fnName and registry:isSource(fnName) then
                                        rhsIsPcallOfSource = true
                                    end
                                end
                            end
                        end

                        local hadSource = walkExpr(rhs, taintSet, fieldTaintSet, findings, registry, filePath)
                        -- Also taint the local if the RHS directly reads a tainted field
                        local rhsTainted = hadSource or isTaintedRef(rhs, taintSet, fieldTaintSet, registry)
                        lastRhsTainted = rhsTainted
                        lastRhsNode = rhs
                        if rhsIsPcallOfSource then
                            -- LHS[i] of a pcall(<source>, ...) is the ok bool —
                            -- never tainted. But subsequent LHS vars (the spilled
                            -- result(s)) inherit the taint via lastRhsTainted.
                            taintSet[varName] = nil
                        elseif rhsTainted then
                            taintSet[varName] = true
                            if debug then
                                debug.taintedAt[varName] = nodeLine(rhs)
                            end
                        else
                            taintSet[varName] = nil
                        end
                    elseif lastRhsTainted then
                        -- No corresponding RHS: spill from the last multi-return expression.
                        taintSet[varName] = true
                        if debug then
                            debug.taintedAt[varName] = nodeLine(lastRhsNode)
                        end
                    else
                        taintSet[varName] = nil
                    end
                end
            end
        elseif t == "AssignmentStatement" then
            -- a, b = expr1, expr2
            -- Also handles t.k = expr (MemberExpr LHS with "." indexer).
            local lhsList = stmt.Lhs or {}
            local rhsList = stmt.Rhs or {}
            for i, lhsExpr in ipairs(lhsList) do
                local rhs = rhsList[i]
                if lhsExpr.AstType == "VarExpr" and lhsExpr.Name then
                    local varName = lhsExpr.Name
                    if rhs then
                        local hadSource = walkExpr(rhs, taintSet, fieldTaintSet, findings, registry, filePath)
                        -- Also taint when RHS reads a tainted local or field
                        -- (e.g. chargeInfo = result, where result is tainted)
                        local rhsTainted = hadSource or isTaintedRef(rhs, taintSet, fieldTaintSet, registry)
                        if rhsTainted then
                            taintSet[varName] = true
                            if debug then
                                debug.taintedAt[varName] = nodeLine(rhs)
                            end
                        else
                            taintSet[varName] = nil
                        end
                    end
                elseif lhsExpr.AstType == "MemberExpr" then
                    local base  = lhsExpr.Base
                    local field = lhsExpr.Ident and lhsExpr.Ident.Data
                    if base and base.AstType == "VarExpr" and field and lhsExpr.Indexer == "." then
                        local key = base.Name .. "." .. field
                        if rhs then
                            local hadSource = walkExpr(rhs, taintSet, fieldTaintSet, findings, registry, filePath)
                            local rhsTainted = hadSource or isTaintedRef(rhs, taintSet, fieldTaintSet, registry)
                            if rhsTainted then
                                fieldTaintSet[key] = true
                            else
                                fieldTaintSet[key] = nil
                            end
                        end
                    elseif rhs then
                        walkExpr(rhs, taintSet, fieldTaintSet, findings, registry, filePath)
                    end
                end
            end
        elseif t == "IfStatement" then
            -- Branch-aware: snapshot taint on entry, walk each clause on a
            -- private copy, then union the exits back into taintSet in-place.
            -- Guards (IsSecretValue/HasSecretValue) untaint locals in the
            -- appropriate branch; the union restores taint after the if/end.
            local entrySnapshot = {}
            for k, v in pairs(taintSet) do entrySnapshot[k] = v end
            local entryFieldSnapshot = {}
            for k, v in pairs(fieldTaintSet) do entryFieldSnapshot[k] = v end

            local branchExits = {}
            local branchFieldExits = {}
            local pendingUntaintForElse = nil  -- locals to untaint in a following else clause

            for _, clause in ipairs(stmt.Clauses) do
                -- Each branch starts from the pre-if entry state.
                local branchTaint = {}
                for k, v in pairs(entrySnapshot) do branchTaint[k] = v end
                local branchFieldTaint = {}
                for k, v in pairs(entryFieldSnapshot) do branchFieldTaint[k] = v end

                if clause.Condition then
                    local guarded = analyzeGuard(clause.Condition, registry)
                    if guarded then
                        if guarded.kind == "untaint-then" then
                            -- `not Guard(x)` → untaint x in this (then) branch
                            for _, n in ipairs(guarded.locals) do
                                branchTaint[n] = nil
                            end
                            pendingUntaintForElse = nil
                        elseif guarded.kind == "untaint-else" then
                            -- `Guard(x)` → x stays tainted in this branch;
                            -- the else clause (if any) should untaint it
                            pendingUntaintForElse = guarded.locals
                        end
                    else
                        -- Not a guard pattern — walk condition normally for sinks
                        walkConditionExpr(clause.Condition, branchTaint, branchFieldTaint, findings, registry, filePath)
                        pendingUntaintForElse = nil
                    end
                else
                    -- Else clause (Condition == nil): apply pending untaint
                    if pendingUntaintForElse then
                        for _, n in ipairs(pendingUntaintForElse) do
                            branchTaint[n] = nil
                        end
                        pendingUntaintForElse = nil
                    end
                end

                if clause.Body and clause.Body.Body then
                    walkStatements(clause.Body.Body, branchTaint, branchFieldTaint, findings, registry, filePath, debug)
                end

                branchExits[#branchExits + 1] = branchTaint
                branchFieldExits[#branchFieldExits + 1] = branchFieldTaint
            end

            -- Mutate taintSet in-place to the union of entry + all branch exits.
            -- Anything tainted in any branch (or on entry) remains tainted.
            for k in pairs(taintSet) do taintSet[k] = nil end
            for k, v in pairs(entrySnapshot) do
                if v then taintSet[k] = true end
            end
            for _, b in ipairs(branchExits) do
                for k, v in pairs(b) do
                    if v then taintSet[k] = true end
                end
            end
            -- Same union for fieldTaintSet.
            for k in pairs(fieldTaintSet) do fieldTaintSet[k] = nil end
            for k, v in pairs(entryFieldSnapshot) do
                if v then fieldTaintSet[k] = true end
            end
            for _, b in ipairs(branchFieldExits) do
                for k, v in pairs(b) do
                    if v then fieldTaintSet[k] = true end
                end
            end
        elseif t == "ReturnStatement" then
            if stmt.Arguments then
                for _, a in ipairs(stmt.Arguments) do
                    walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                end
            end
        elseif t == "CallStatement" then
            -- Standalone call expression (e.g. print(x), SomeAPI:method(x))
            if stmt.Expression then
                walkExpr(stmt.Expression, taintSet, fieldTaintSet, findings, registry, filePath)
            end
        elseif t == "GenericForStatement"
            or t == "NumericForStatement"
            or t == "WhileStatement"
            or t == "RepeatStatement" then
            -- Two-iteration fixpoint: walk the body twice.
            -- First pass establishes the post-iteration union taint state (findings
            -- discarded). Second pass walks with that union state and emits findings
            -- for real. This handles taint that flows across loop iterations.

            -- Walk header expressions for sinks (these run in the outer scope before/per loop).
            if t == "WhileStatement" and stmt.Condition then
                walkConditionExpr(stmt.Condition, taintSet, fieldTaintSet, findings, registry, filePath)
            elseif t == "NumericForStatement" then
                if stmt.Start then walkExpr(stmt.Start, taintSet, fieldTaintSet, findings, registry, filePath) end
                if stmt.End   then walkExpr(stmt.End,   taintSet, fieldTaintSet, findings, registry, filePath) end
                if stmt.Step  then walkExpr(stmt.Step,  taintSet, fieldTaintSet, findings, registry, filePath) end
            elseif t == "GenericForStatement" and stmt.Generators then
                for _, g in ipairs(stmt.Generators) do
                    walkExpr(g, taintSet, fieldTaintSet, findings, registry, filePath)
                end
            end
            -- RepeatStatement.Condition is walked AFTER the body (it's the until-clause).

            local body = stmt.Body
            if body and body.Body then
                -- First pass: collect findings into a discard list to establish
                -- post-iteration taint state without committing findings.
                local discardFindings = {}
                walkStatements(body.Body, taintSet, fieldTaintSet, discardFindings, registry, filePath, debug)

                -- Second pass: walk again with the post-first-pass union state and
                -- emit findings for real. This captures taint visible only on the
                -- second or later iteration.
                walkStatements(body.Body, taintSet, fieldTaintSet, findings, registry, filePath, debug)

                -- For RepeatStatement, the until-clause condition runs after the body.
                -- Walk it for sinks against the post-body taint state.
                if t == "RepeatStatement" and stmt.Condition then
                    walkConditionExpr(stmt.Condition, taintSet, fieldTaintSet, findings, registry, filePath)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Precondition-guarded API scan
-- ---------------------------------------------------------------------------
-- APIs whose api-index entry carries `preconditions` (RequiresUnitAuraAccess
-- etc.) HARD-ERROR under encounter/M+/PvP addon restrictions
-- (SecretPredicatesDocumentation: FailureMode = "Error"). A raw call is a
-- live crash path the secret-flow checks above never see — the 2026-07
-- external review found three shipped callers that way. This pass flags
-- every direct call to such an API at REVIEW tier unless the call is
-- "handled": lexically inside a scope that consults a restriction gate
-- (C_Secrets.ShouldAurasBeSecret), inside a pcall/xpcall-protected closure,
-- or the API is passed to pcall/xpcall as the protected function (that shape
-- is a reference, not a CallExpr, so it never flags). Scope gating is
-- order-insensitive and lexical — non-interprocedural, so a caller-side gate
-- needs a `-- @secret-safe: <reason>` annotation like every other heuristic.

-- Does this subtree contain a restriction-gate call? Stops at nested
-- Function nodes — they form their own gate scope. `visited` guards against
-- the parser's back-references (Scope/parent links make the AST a graph,
-- not a tree — a naive pairs() walk recurses forever).
local function containsGateCall(node, registry, visited)
    if type(node) ~= "table" or visited[node] then return false end
    visited[node] = true
    if node.AstType == "Function" then return false end
    if node.AstType == "CallExpr" then
        local name = callTargetName(node.Base)
        if name and registry:isRestrictionGate(name) then return true end
    end
    for k, v in pairs(node) do
        if k ~= "Tokens" and type(v) == "table" then
            if containsGateCall(v, registry, visited) then return true end
        end
    end
    return false
end

local function preconditionScan(node, registry, filePath, findings, gated, visited)
    if type(node) ~= "table" or visited[node] then return end
    visited[node] = true

    if node.AstType == "Function" then
        -- New gate scope: lexically-inherited gating OR a gate call anywhere
        -- in this body (order-insensitive).
        local bodyGated = gated or containsGateCall(node.Body, registry, {})
        for k, v in pairs(node) do
            if k ~= "Tokens" then
                preconditionScan(v, registry, filePath, findings, bodyGated, visited)
            end
        end
        return
    end

    if node.AstType == "CallExpr" then
        local name = callTargetName(node.Base)
        if name == "pcall" or name == "xpcall" then
            -- Everything under a pcall is protected: a closure argument scans
            -- gated, and a function REFERENCE argument is not a CallExpr so it
            -- never flags. (Conservatively treats every pcall argument as
            -- protected; only argument 1 truly is, but a guarded CALL in an
            -- outer argument position would still error before pcall runs —
            -- rare enough to trade for simplicity at review tier.)
            for k, v in pairs(node) do
                if k ~= "Tokens" then
                    preconditionScan(v, registry, filePath, findings, true, visited)
                end
            end
            return
        end
        if name and not gated then
            local flags = registry:preconditionFlags(name)
            if flags then
                local flagText = type(flags) == "table" and table.concat(flags, ",")
                    or "precondition-guarded"
                findings[#findings + 1] = {
                    file = filePath, line = nodeLine(node) or 0, col = 1,
                    severity = "review",
                    source_function = name,
                    sink = "<precondition>",
                    message = flagText .. " API called without a restriction gate or pcall — hard-errors under encounter/M+/PvP restrictions",
                    suppressed = false, suppression_reason = nil,
                }
            end
        end
        -- fall through: arguments/base still need scanning
    end

    for k, v in pairs(node) do
        if k ~= "Tokens" then
            preconditionScan(v, registry, filePath, findings, gated, visited)
        end
    end
end

--- Analyze a single Lua source string.
--- @param source string  Lua source code.
--- @param filePath string  File path for findings + severity classification.
--- @param registry table  Registry instance (sources/sinks/guards/unwraps).
--- @param config table  Project config (strict_paths/ignore_paths).
--- @param opts table|nil  Options: opts.exposeDebug returns a third debug return value;
---                        opts.includeSuppressed keeps suppressed findings in the list.
--- @return table|nil findings  List of Finding records, or nil on parse error.
--- @return string|nil err  Parse error message.
--- @return table|nil debug  Debug table (only when opts.exposeDebug is true).
function M.analyze(source, filePath, registry, config, opts)
    local ast, err = Parser.parse(source, filePath)
    if not ast then return nil, err end

    opts = opts or {}
    local findings = {}
    local taintSet = {}
    local fieldTaintSet = {}
    -- Always allocate debugInfo so annotation pass can always record warnings.
    local debugInfo = { taintedAt = {}, warnings = {} }

    -- Walk the top-level chunk body
    local stmts = ast.Body or {}
    walkStatements(stmts, taintSet, fieldTaintSet, findings, registry, filePath, debugInfo)

    -- Independent pass: raw calls to precondition-guarded APIs (review tier).
    -- Textual pre-filter first: the generic graph walk is expensive, and most
    -- files never mention a guarded API's name at all.
    local runPreScan = false
    for apiName in pairs(registry.preconditionAPIs or {}) do
        if source:find(getMethodNameFromQualified(apiName), 1, true) then
            runPreScan = true
            break
        end
    end
    if runPreScan then
        preconditionScan(ast, registry, filePath, findings, false, {})
    end

    -- Promote advisory → strict for files in strict_paths
    if Config.isStrictPath(config, filePath) then
        for _, f in ipairs(findings) do
            if f.severity == "advisory" then
                f.severity = "strict"
            end
        end
    end

    if Config.isStrictUnwrapPath(config, filePath) then
        for _, f in ipairs(findings) do
            if f.severity == "review" and f.sink == "<unwrap>" then
                f.severity = "strict"
            end
        end
    end

    -- Annotation pass: scan source for -- @secret-safe comments, mark findings.
    local annotations = Annotations.scan(source)
    Annotations.apply(findings, annotations)

    -- Harness warnings: emptyReason annotations on lines that have findings
    for line, a in pairs(annotations) do
        if a.emptyReason then
            for _, f in ipairs(findings) do
                if f.line == line then
                    debugInfo.warnings[#debugInfo.warnings + 1] = string.format(
                        "%s:%d: @secret-safe annotation requires a reason",
                        filePath, line)
                    break
                end
            end
        end
    end

    -- Filter suppressed findings unless opts.includeSuppressed
    local filtered
    if opts.includeSuppressed then
        filtered = findings
    else
        filtered = {}
        for _, f in ipairs(findings) do
            if not f.suppressed then
                filtered[#filtered + 1] = f
            end
        end
    end

    if opts.exposeDebug then
        return filtered, nil, debugInfo
    end
    return filtered
end

return M
