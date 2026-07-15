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

local stripParensFwd  -- assigned below (stripParens); needed here lexically

-- Is `e` an existence guard for the callee `calleeName` — a name chain equal
-- to the callee or a dotted prefix of it, or an `and`-chain of such chains
-- (`C_Spell and C_Spell.GetSpellCooldown` guarding `C_Spell.GetSpellCooldown(...)`)?
local function isExistenceGuardFor(e, calleeName)
    if stripParensFwd then e = stripParensFwd(e) end
    if type(e) ~= "table" then return false end
    if e.AstType == "BinopExpr" and e.Op == "and" then
        return isExistenceGuardFor(e.Lhs, calleeName)
            and isExistenceGuardFor(e.Rhs, calleeName)
    end
    if e.AstType ~= "VarExpr" and e.AstType ~= "MemberExpr" then return false end
    local chain = callTargetName(e)
    if not chain then return false end
    return calleeName == chain
        or calleeName:sub(1, #chain + 1) == (chain .. ".")
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
stripParensFwd = stripParens

-- VALUE-flow taint: like isTaintedRef, but follows short-circuit and/or —
-- `info and info.f` YIELDS the tainted field, so a VALUE consumer
-- (assignment, unsafe-builtin argument, comparison/arith operand) sees taint
-- even though the binop itself is an exempt existence test (round-6c:
-- `print(info and info.f)` and `local v = info and info.f` were reproducible
-- false negatives after the round-6b binop exemptions).
--
-- `X and Y` yields value(Y) when everything is truthy, or the FALSY value of
-- X. A falsy secret (secret-false boolean) is still secret, so lhs taint
-- must flow (round-6d: `isActive and Wrap(isActive)` leaked unflagged).
-- There is NO sound type shortcut here: an index of X inside Y
-- (`chargeInfo and Decode(chargeInfo.isActive)`) proves nothing about the
-- falsy path — the index only evaluates when X is TRUTHY, so a secret-false
-- X short-circuits straight past it (round-6d follow-up: the struct-
-- assertion exception was itself a reproducible false negative). Sites where
-- the API contract guarantees table-or-nil carry a `-- @secret-safe:`
-- annotation instead. `X or Y` yields either side. NOT used for
-- truthiness/condition checks — those keep isTaintedRef.

-- Can this sub-expression's FALSY value carry taint? (`X and Y` yields
-- falsy(X); falsy(A and B) is falsy(A) or falsy(B); falsy(A or B) is
-- falsy(B).)
local function falsyYieldTainted(expr, taintSet, fieldTaintSet, registry)
    expr = stripParens(expr)
    if type(expr) ~= "table" then return false end
    if expr.AstType == "VarExpr" or expr.AstType == "MemberExpr" then
        return isTaintedRef(expr, taintSet, fieldTaintSet, registry)
    end
    if expr.AstType == "BinopExpr" then
        if expr.Op == "and" then
            return falsyYieldTainted(expr.Lhs, taintSet, fieldTaintSet, registry)
                or falsyYieldTainted(expr.Rhs, taintSet, fieldTaintSet, registry)
        end
        if expr.Op == "or" then
            return falsyYieldTainted(expr.Rhs, taintSet, fieldTaintSet, registry)
        end
    end
    return false
end

local function isValueTainted(expr, taintSet, fieldTaintSet, registry)
    expr = stripParens(expr)
    if isTaintedRef(expr, taintSet, fieldTaintSet, registry) then return true end
    if type(expr) == "table" and expr.AstType == "BinopExpr" then
        if expr.Op == "and" then
            return isValueTainted(expr.Rhs, taintSet, fieldTaintSet, registry)
                or falsyYieldTainted(expr.Lhs, taintSet, fieldTaintSet, registry)
        end
        if expr.Op == "or" then
            return isValueTainted(expr.Lhs, taintSet, fieldTaintSet, registry)
                or isValueTainted(expr.Rhs, taintSet, fieldTaintSet, registry)
        end
    end
    return false
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

-- Unquoted value of a StringExpr node, or nil.
local function stringLiteralValue(n)
    if type(n) ~= "table" or n.AstType ~= "StringExpr" then return nil end
    local raw = n.Value and n.Value.Data
    if type(raw) ~= "string" then return nil end
    return raw:match("^[\"'](.*)[\"']$") or raw
end

-- Secret event payload detection (config event_payload_params): a function
-- whose body compares something against a secret-payload event-name literal
-- (`event == "UNIT_AURA"`) is treated as that event's handler, and the
-- configured payload parameter positions become taint sources. Positional by
-- necessity — the api-index metadata is per-event, not per-argument — and
-- keyed to the SetScript OnEvent signature (self, event, payload...); a
-- dispatch helper with a shifted signature needs its own config entry.
-- Handlers that never compare the event name are additionally detected via
-- the file-level RegisterEvent/SetScript linkage (collectRegisteredHandlers
-- below). Payload forwarded into helper functions (`Handle(unit, info)`)
-- stays unmodeled — the analyzer is non-interprocedural by design; helpers
-- need their own config entry or an annotation.
local function secretEventParamHits(funcNode, registry)
    if not registry.hasSecretPayloadEvents or not registry:hasSecretPayloadEvents() then
        return nil
    end
    local hits
    local function walk(n, visited)
        if type(n) ~= "table" or visited[n] then return end
        visited[n] = true
        if n.AstType == "Function" then return end -- nested closure = own handler scope
        if n.AstType == "BinopExpr" and (n.Op == "==" or n.Op == "~=") then
            local lit = stringLiteralValue(n.Lhs) or stringLiteralValue(n.Rhs)
            local params = lit and registry:secretPayloadParams(lit)
            if params then
                hits = hits or {}
                for _, pos in ipairs(params) do hits[pos] = true end
            end
        end
        for k, v in pairs(n) do
            if k ~= "Tokens" and type(v) == "table" then walk(v, visited) end
        end
    end
    walk(funcNode.Body, {})
    return hits
end

-- Per-analyze() module state (the walkers have fixed signatures and the walk
-- is single-threaded/synchronous; both are set in M.analyze / walkFunctionBody
-- and restored on exit):
--   registeredHandlerHits: Function AST node → {paramPos: true} for handlers
--     linked to secret events via RegisterEvent (no comparison needed).
--   fnEventCtx: the INNERMOST enclosing detected handler's context —
--     { eventName, payloadNames = {name:true}, varargSecret = {relPos:true} } —
--     consumed by the event-dispatch branch untaint and the vararg spill rule.
local registeredHandlerHits
local fnEventCtx

-- File-level RegisterEvent/SetScript linkage (round-6: handlers that never
-- compare the event name — single-event frames — were undetected): a receiver
-- that registers a secret-payload event AND assigns an OnEvent handler marks
-- that handler function's configured payload positions as taint sources.
-- Receiver identity is the parser's scope-resolved Variable OBJECT plus a
-- REBIND GENERATION (round-6b: bare-name union seeded unrelated same-named
-- frames across scopes, and a re-bound `f = CreateFrame(...)` inherited the
-- old frame's registrations — both reproducible false positives). The
-- statement-ordered walk bumps a variable's generation at every binding, so
-- registrations before a rebind never pair with handlers set after it.
-- Handlers resolve to inline closures or named local functions (by name).
-- Dotted receivers (`self.frame:RegisterEvent`) and handlers passed through
-- variables stay unmodeled.
local function collectRegisteredHandlers(ast, registry)
    if not registry.hasSecretPayloadEvents or not registry:hasSecretPayloadEvents() then
        return nil
    end
    local recvEvents = {}   -- recvKey → {paramPos: true}
    local recvHandlers = {} -- recvKey → { handler expr nodes }
    local localFns = {}     -- name → Function statement node
    local gen = {}          -- Variable object / global-name key → rebind generation
    local function recvKeyOf(base)
        if type(base) ~= "table" or base.AstType ~= "VarExpr" then return nil end
        local id = base.Variable or ("g:" .. tostring(base.Name))
        return tostring(id) .. "#" .. (gen[id] or 0)
    end
    -- Keys that leave the AST tree: Scope/Variable link INTO the parser's
    -- scope graph (parent chains reach the whole program) — recursing there
    -- with the per-statement `seen` tables below turns the walk quadratic
    -- and hangs on large files.
    local SKIP_KEYS = { Tokens = true, Scope = true, Variable = true }
    -- CallExprs in the CURRENT statement, outside nested closures/blocks
    -- (those walk in their own statement order via scanBlocks below).
    local function scanCalls(n, seen)
        if type(n) ~= "table" or seen[n] then return end
        seen[n] = true
        if n.AstType == "Function" or n.AstType == "Statlist" then return end
        if n.AstType == "CallExpr" then
            local name, kind = callTargetName(n.Base)
            if name and kind == "method"
                and n.Base and n.Base.AstType == "MemberExpr" then
                local method = getMethodNameFromQualified(name)
                local recv = recvKeyOf(n.Base.Base)
                if recv and (method == "RegisterEvent" or method == "RegisterUnitEvent") then
                    local lit = stringLiteralValue(n.Arguments and n.Arguments[1])
                    local params = lit and registry:secretPayloadParams(lit)
                    if params then
                        local set = recvEvents[recv] or {}
                        for _, pos in ipairs(params) do set[pos] = true end
                        recvEvents[recv] = set
                    end
                elseif recv and (method == "SetScript" or method == "HookScript") then
                    local lit = stringLiteralValue(n.Arguments and n.Arguments[1])
                    local handler = n.Arguments and n.Arguments[2]
                    if lit == "OnEvent" and type(handler) == "table" then
                        local list = recvHandlers[recv] or {}
                        list[#list + 1] = handler
                        recvHandlers[recv] = list
                    end
                end
            end
        end
        for k, v in pairs(n) do
            if not SKIP_KEYS[k] and type(v) == "table" then scanCalls(v, seen) end
        end
    end
    local walkStmts
    -- Nested blocks and closure bodies re-enter the ordered statement walk.
    local function scanBlocks(n, seen)
        if type(n) ~= "table" or seen[n] then return end
        seen[n] = true
        if n.AstType == "Statlist" then
            walkStmts(n.Body)
            return
        end
        if n.AstType == "Function" then
            if n.IsLocal and n.Name and n.Name.Name then
                localFns[n.Name.Name] = n
            end
            walkStmts(n.Body and n.Body.Body)
            return
        end
        for k, v in pairs(n) do
            if not SKIP_KEYS[k] and type(v) == "table" then scanBlocks(v, seen) end
        end
    end
    walkStmts = function(stmts)
        if type(stmts) ~= "table" then return end
        for _, stmt in ipairs(stmts) do
            scanCalls(stmt, {})
            scanBlocks(stmt, {})
            -- Bindings bump LAST: calls in this statement saw the receiver's
            -- pre-binding generation.
            if stmt.AstType == "LocalStatement" then
                for _, v in ipairs(stmt.LocalList or {}) do
                    gen[v] = (gen[v] or 0) + 1
                end
            elseif stmt.AstType == "AssignmentStatement" then
                for _, l in ipairs(stmt.Lhs or {}) do
                    if type(l) == "table" and l.AstType == "VarExpr" then
                        local id = l.Variable or ("g:" .. tostring(l.Name))
                        gen[id] = (gen[id] or 0) + 1
                    end
                end
            end
        end
    end
    walkStmts(ast.Body or {})
    local hits
    for recv, set in pairs(recvEvents) do
        for _, handler in ipairs(recvHandlers[recv] or {}) do
            local fnNode
            if handler.AstType == "Function" then
                fnNode = handler
            elseif handler.AstType == "VarExpr" and localFns[handler.Name] then
                fnNode = localFns[handler.Name]
            end
            if fnNode then
                hits = hits or {}
                local hset = hits[fnNode] or {}
                for pos in pairs(set) do hset[pos] = true end
                hits[fnNode] = hset
            end
        end
    end
    return hits
end

local function walkFunctionBody(funcNode, taintSet, fieldTaintSet, findings, registry, filePath, debug)
    if not (funcNode.Body and funcNode.Body.Body) then return end
    local closureTaint = copySet(taintSet)
    local closureFieldTaint = copySet(fieldTaintSet)
    clearParamTaint(closureTaint, closureFieldTaint, funcNode)
    local eventParams = secretEventParamHits(funcNode, registry)
    local regHits = registeredHandlerHits and registeredHandlerHits[funcNode]
    if regHits then
        eventParams = eventParams or {}
        for pos in pairs(regHits) do eventParams[pos] = true end
    end
    local prevCtx = fnEventCtx
    if eventParams then
        local nArgs = #(funcNode.Arguments or {})
        local payloadNames = {}
        local varargSecret
        for pos in pairs(eventParams) do
            local arg = funcNode.Arguments and funcNode.Arguments[pos]
            local name = arg and arg.Name
            if name then
                closureTaint[name] = true
                payloadNames[name] = true
            elseif funcNode.VarArg and pos > nArgs then
                -- Configured position lands in `...`: remember its RELATIVE
                -- vararg index so a `local unit, info = ...` spill taints the
                -- right locals (see the DotsExpr rule in walkStatements).
                -- `select(pos, ...)` and forwarding `...` stay unmodeled.
                varargSecret = varargSecret or {}
                varargSecret[pos - nArgs] = true
            end
        end
        local evArg = funcNode.Arguments and funcNode.Arguments[2]
        fnEventCtx = {
            eventName = evArg and evArg.Name or nil,
            payloadNames = payloadNames,
            varargSecret = varargSecret,
        }
    else
        -- Nested closures are their own handler scope: payload upvalues stay
        -- tainted via closureTaint, but the dispatch/vararg rules reset.
        fnEventCtx = nil
    end
    walkStatements(funcNode.Body.Body, closureTaint, closureFieldTaint, findings, registry, filePath, debug)
    fnEventCtx = prevCtx
end

-- pcall/xpcall used INSIDE an expression (condition, binop/unop operand,
-- builtin argument) truncates to its first return — the ok boolean — which is
-- always clean. Only multi-assignment (`local ok, v = pcall(src)`) spills the
-- protected function's possibly-secret returns; that flows through the
-- statement walkers, not these sites. Used to mask the source-contribution of
-- a DIRECT protected call so `if pcall(SecretSource, id) then` stays clean.
local function isProtectedCallExpr(expr)
    local inner = stripParens(expr)
    if type(inner) ~= "table" or inner.AstType ~= "CallExpr" then return false end
    local name = callTargetName(inner.Base)
    return name == "pcall" or name == "xpcall"
end

local function walkConditionExpr(expr, taintSet, fieldTaintSet, findings, registry, filePath)
    local inner = stripParens(expr)
    if isTaintedRef(inner, taintSet, fieldTaintSet, registry) then
        emit(findings, filePath, nodeLine(inner), 1, "<truthiness>",
            "<tainted-local>",
            "tainted value used as a branch condition without guard or C-side decode")
    end
    local hadSource = walkExpr(expr, taintSet, fieldTaintSet, findings, registry, filePath)
    -- Bare direct source-call condition (`if icon:IsShown() then`): the call
    -- result is truth-tested without ever landing in a local, so the
    -- tainted-ref check above can't see it. Only the bare-call shape emits
    -- here — compound conditions (and/or, comparisons, unary not) already
    -- emit inside walkExpr, and guard/gate calls are not sources.
    if hadSource and inner and inner.AstType == "CallExpr"
        and not isProtectedCallExpr(inner) then
        emit(findings, filePath, nodeLine(inner), 1, "<truthiness>",
            "<tainted-local>",
            "tainted value used as a branch condition without guard or C-side decode")
    end
    return hadSource
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

    -- Probe idiom (round-6): `x and issecretvalue and issecretvalue(x)` —
    -- the RIGHTMOST conjunct is the guard call; every leading conjunct must
    -- be either a guarded local itself (existence pre-check) or a dotted
    -- prefix of the guard's own call chain (`Helpers`, `issecretvalue`).
    -- An arbitrary extra conjunct disqualifies the shape. Negated compound
    -- probes are not modeled.
    if not negated and inner and inner.AstType == "BinopExpr" and inner.Op == "and" then
        local conjuncts = {}
        local function flatten(n)
            n = stripParens(n)
            if type(n) == "table" and n.AstType == "BinopExpr" and n.Op == "and" then
                flatten(n.Lhs)
                flatten(n.Rhs)
            else
                conjuncts[#conjuncts + 1] = n
            end
        end
        flatten(inner)
        local last = conjuncts[#conjuncts]
        if type(last) == "table" and last.AstType == "CallExpr" then
            local guardName = callTargetName(last.Base)
            if guardName and registry:isGuard(guardName) then
                local locals, guardedSet = {}, {}
                for _, a in ipairs(last.Arguments or {}) do
                    if isVarRef(a) then
                        locals[#locals + 1] = a.Name
                        guardedSet[a.Name] = true
                    end
                end
                if #locals > 0 then
                    for i = 1, #conjuncts - 1 do
                        local c = conjuncts[i]
                        local ok = false
                        if type(c) == "table"
                            and (c.AstType == "VarExpr" or c.AstType == "MemberExpr") then
                            local chain = callTargetName(c)
                            if chain then
                                ok = (guardedSet[chain] and c.AstType == "VarExpr")
                                    or guardName == chain
                                    or guardName:sub(1, #chain + 1) == (chain .. ".")
                            end
                        end
                        if not ok then return nil end
                    end
                    return { kind = "untaint-else", locals = locals }
                end
            end
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

    if t == "DotsExpr" then
        -- Bare `...` inside a detected secret-event handler whose configured
        -- payload positions land in the vararg carries secrets (round-6b:
        -- `print(...)` / `{...}` leaked unflagged). The LocalStatement /
        -- AssignmentStatement spill rules intercept `x, y = ...` BEFORE this,
        -- so position-precise mapping still wins there.
        local ctx = fnEventCtx
        return (ctx and ctx.varargSecret and not ctx.suppressSpill) and true or false
    end

    if t == "BinopExpr" then
        local op = expr.Op
        -- Value-consuming ops (comparison/arith/concat) see and/or value flow
        -- (`(x and x.f) > 0` reads the field); and/or themselves keep the
        -- plain-ref check so the existence-test exemptions below stay narrow.
        local refCheck = (COMPARISON_OPS[op] or ARITH_OPS[op]) and isValueTainted or isTaintedRef
        local lhsTainted = refCheck(expr.Lhs, taintSet, fieldTaintSet, registry)
        local rhsTainted = refCheck(expr.Rhs, taintSet, fieldTaintSet, registry)
        -- Recurse FIRST: a direct source-call operand (`icon:GetAlpha() > 0.5`
        -- with no intermediate local) returns "contains source" and must count
        -- as a tainted operand — assignment-only detection missed these.
        -- Direct pcall/xpcall operands truncate to the clean ok boolean.
        local lhsHadSource = walkExpr(expr.Lhs, taintSet, fieldTaintSet, findings, registry, filePath)
            and not isProtectedCallExpr(expr.Lhs)
        local rhsHadSource = walkExpr(expr.Rhs, taintSet, fieldTaintSet, findings, registry, filePath)
            and not isProtectedCallExpr(expr.Rhs)
        -- EXISTENCE-TEST rule for and/or (round-6b/6d, exposed by the
        -- DoStatement fix): truth-testing a secret is engine-legal (the
        -- shipped issecretvalue probe depends on it) — only content ops
        -- hard-error. Plain tainted REFS (VarExpr/MemberExpr) as and/or
        -- operands are existence tests and never emit at the binop;
        -- isValueTainted carries their yielded taint to the real consumers
        -- (assignments, sinks, comparison/arith operands). Direct SOURCE
        -- CALL operands still emit — their result is truth-tested inline
        -- without landing anywhere — unless existence-guarded
        -- (`C_X.Fn and C_X.Fn(id)`) or defaulted (`Src() or DFLT`).
        -- Comparisons, arithmetic, concat and every nested sink still emit.
        local emitLhsTainted, emitRhsTainted = lhsTainted, rhsTainted
        local emitLhsSource,  emitRhsSource  = lhsHadSource, rhsHadSource
        if op == "and" or op == "or" then
            local lhs, rhs = stripParens(expr.Lhs), stripParens(expr.Rhs)
            local function isPlainRef(e)
                return type(e) == "table"
                    and (e.AstType == "VarExpr" or e.AstType == "MemberExpr")
            end
            if isPlainRef(lhs) then emitLhsTainted = false end
            if isPlainRef(rhs) then emitRhsTainted = false end
            if op == "and" and rhsHadSource
                and type(rhs) == "table" and rhs.AstType == "CallExpr" then
                local calleeName = callTargetName(rhs.Base)
                if calleeName and isExistenceGuardFor(lhs, calleeName) then
                    emitRhsSource = false
                end
            end
            if op == "or" and type(lhs) == "table"
                and lhs.AstType == "CallExpr" and lhsHadSource then
                emitLhsSource = false
            end
        end
        if emitLhsTainted or emitRhsTainted or emitLhsSource or emitRhsSource then
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
            -- select() over the handler vararg: position-precise extraction.
            -- `select(k, ...)` yields vararg values from k on — tainted when
            -- any configured secret position is >= k; `select("#", ...)` is a
            -- COUNT and stays clean (the generic DotsExpr rule above would
            -- otherwise flag it). A DYNAMIC clean index (the canonical
            -- `for i = 1, select("#", ...) do local v = select(i, ...)` loop)
            -- taints the RESULT without flagging the call site — selecting
            -- from the vararg reads no content (round-6b: the fall-through to
            -- the unsafe-builtin walk emitted a reproducible false positive
            -- on that idiom). A TAINTED index still falls through and flags.
            if name == "select" and fnEventCtx and fnEventCtx.varargSecret
                and not fnEventCtx.suppressSpill then
                local kArg = expr.Arguments and expr.Arguments[1]
                local dotsArg = expr.Arguments and expr.Arguments[2]
                if dotsArg and dotsArg.AstType == "DotsExpr" and kArg then
                    if kArg.AstType == "NumberExpr" then
                        local k = tonumber(kArg.Value and kArg.Value.Data)
                        if k then
                            for pos in pairs(fnEventCtx.varargSecret) do
                                if pos >= k then return true end
                            end
                            return false
                        end
                    elseif stringLiteralValue(kArg) == "#" then
                        return false
                    elseif not isTaintedRef(kArg, taintSet, fieldTaintSet, registry) then
                        walkExpr(kArg, taintSet, fieldTaintSet, findings, registry, filePath)
                        return true
                    end
                end
            end
            -- Unsafe builtin called with a tainted argument
            if UNSAFE_BUILTIN_FUNCTIONS[name] then
                if expr.Arguments then
                    local nArgs = #expr.Arguments
                    for i, a in ipairs(expr.Arguments) do
                        -- Recurse to catch deeper sinks; a direct source-call
                        -- argument (`tostring(icon:GetAlpha())`) is tainted
                        -- too. A protected call spills every return ONLY when
                        -- it is bare in LAST position — `print(pcall(src))`
                        -- hands the secret returns to the builtin. Non-last
                        -- position and parentheses (`print((pcall(src)))`)
                        -- both truncate to the clean ok boolean.
                        local argHadSource = walkExpr(a, taintSet, fieldTaintSet, findings, registry, filePath)
                        if argHadSource and isProtectedCallExpr(a)
                            and (i < nArgs or a.AstType == "Parentheses") then
                            argHadSource = false
                        end
                        if argHadSource
                            or isValueTainted(a, taintSet, fieldTaintSet, registry) then
                            emit(findings, filePath, nodeLine(expr), 1, name,
                                "<tainted-local>",
                                "tainted value passed to " .. name)
                        end
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
            -- Aspect-returning widget getter (api-index secretReturnsForAspect):
            -- the result may be secret when the receiver's aspect has been
            -- secretized. Bare method-name match — receivers are plain locals.
            -- The registry is aspect-stripped for files outside aspect_paths,
            -- so this never fires there.
            if kind == "method"
                and registry:isAspectReturningMethod(getMethodNameFromQualified(name)) then
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
        -- Direct source-call operand (`not icon:IsShown()`) counts too;
        -- `not pcall(...)` consumes only the clean ok boolean.
        local rhsHadSource = walkExpr(expr.Rhs, taintSet, fieldTaintSet, findings, registry, filePath)
            and not isProtectedCallExpr(expr.Rhs)
        if rhsTainted or rhsHadSource then
            emit(findings, filePath, nodeLine(expr), 1, "<unop:" .. (expr.Op or "?") .. ">",
                "<tainted-local>",
                "tainted value used in unary " .. (expr.Op or "?"))
        end
        return rhsHadSource
    end

    return false
end

-- Mark a variable's taint as INDEPENDENT of the event payload: once a name
-- (payload param or not) is re-tainted from another source, the dispatch
-- untaint below must not clear it — its secret no longer rides the event.
local function markIndependentTaint(varName)
    if fnEventCtx and fnEventCtx.payloadNames then
        fnEventCtx.payloadNames[varName] = nil
    end
end

-- Does this RHS carry ONLY event-payload taint — a copy of a payload param
-- (`local u = unit`) or a field read off one? Such copies JOIN the dispatch-
-- untaint set instead of being marked independent: `u` must untaint alongside
-- `unit` inside a non-secret dispatch branch (round-6c: the independent mark
-- on plain copies was a reproducible false positive).
local function eventTaintedOnly(expr)
    local ctx = fnEventCtx
    if not ctx or not ctx.payloadNames then return false end
    expr = stripParens(expr)
    if type(expr) ~= "table" then return false end
    if expr.AstType == "VarExpr" then
        return ctx.payloadNames[expr.Name] == true
    end
    if expr.AstType == "MemberExpr" then
        local root = expr
        while type(root.Base) == "table" and root.Base.AstType == "MemberExpr" do
            root = root.Base
        end
        return type(root.Base) == "table" and root.Base.AstType == "VarExpr"
            and ctx.payloadNames[root.Base.Name] == true
    end
    return false
end

-- Route a freshly-tainted assignment target into the right dispatch-untaint
-- bucket: payload copies join payloadNames, everything else goes independent.
local function classifyAssignedTaint(varName, rhs)
    if eventTaintedOnly(rhs) then
        fnEventCtx.payloadNames[varName] = true
    else
        markIndependentTaint(varName)
    end
end

-- Event-dispatch branch check: inside a detected secret-event handler, is this
-- if-clause condition `<eventParam> == "LIT"` where LIT is NOT a configured
-- secret-payload event? Such a branch handles a DIFFERENT event, so the secret
-- payload params cannot be live there — untainting them kills the round-6
-- overtaint where every branch of a multi-event dispatcher flagged payload
-- use meant for a non-secret event. Only names still carrying pure
-- event-entry taint are cleared (see markIndependentTaint).
local function nonSecretEventBranch(cond, registry)
    local ctx = fnEventCtx
    if not ctx or not ctx.eventName then return false end
    local function check(n)
        n = stripParens(n)
        if type(n) ~= "table" then return false end
        -- `event == "A" or event == "B"` protects when EVERY disjunct names
        -- a non-secret event.
        if n.AstType == "BinopExpr" and n.Op == "or" then
            return check(n.Lhs) and check(n.Rhs)
        end
        if n.AstType ~= "BinopExpr" or n.Op ~= "==" then return false end
        local lit = stringLiteralValue(n.Lhs) or stringLiteralValue(n.Rhs)
        if not lit or registry:secretPayloadParams(lit) then return false end
        local var = (isVarRef(n.Lhs) and n.Lhs) or (isVarRef(n.Rhs) and n.Rhs)
        return (var and var.Name == ctx.eventName) or false
    end
    return check(cond)
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
            local lastRhsDotsIndex = nil
            for i, varEntry in ipairs(localList) do
                local varName = varEntry.Name
                if varName then
                    local rhs = initList[i]
                    if rhs and rhs.AstType == "DotsExpr" then
                        -- Vararg spill (`local unit, info = ...`) inside a
                        -- detected secret-event handler whose configured
                        -- payload positions land in `...`: LHS k maps to
                        -- relative vararg index k - <dots position> + 1.
                        -- Suppressed inside dispatch branches proven to
                        -- handle a different, non-secret event.
                        local vsecret = fnEventCtx and not fnEventCtx.suppressSpill
                            and fnEventCtx.varargSecret
                        lastRhsNode = rhs
                        lastRhsDotsIndex = i
                        lastRhsTainted = false
                        if vsecret and vsecret[1] then
                            taintSet[varName] = true
                            fnEventCtx.payloadNames[varName] = true
                            if debug then debug.taintedAt[varName] = nodeLine(rhs) end
                        else
                            taintSet[varName] = nil
                        end
                    elseif rhs then
                        lastRhsDotsIndex = nil
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
                        -- Also taint the local if the RHS directly reads a
                        -- tainted field, including through and/or value flow.
                        local rhsTainted = hadSource or isValueTainted(rhs, taintSet, fieldTaintSet, registry)
                        lastRhsTainted = rhsTainted
                        lastRhsNode = rhs
                        if rhsIsPcallOfSource then
                            -- LHS[i] of a pcall(<source>, ...) is the ok bool —
                            -- never tainted. But subsequent LHS vars (the spilled
                            -- result(s)) inherit the taint via lastRhsTainted.
                            taintSet[varName] = nil
                        elseif rhsTainted then
                            taintSet[varName] = true
                            classifyAssignedTaint(varName, rhs)
                            if debug then
                                debug.taintedAt[varName] = nodeLine(rhs)
                            end
                        else
                            taintSet[varName] = nil
                        end
                    elseif lastRhsDotsIndex then
                        -- Overflow LHS var fed by a `...` spill: taint per the
                        -- handler's relative secret vararg positions (same
                        -- dispatch-branch suppression as above).
                        local vsecret = fnEventCtx and not fnEventCtx.suppressSpill
                            and fnEventCtx.varargSecret
                        if vsecret and vsecret[i - lastRhsDotsIndex + 1] then
                            taintSet[varName] = true
                            fnEventCtx.payloadNames[varName] = true
                            if debug then debug.taintedAt[varName] = nodeLine(lastRhsNode) end
                        else
                            taintSet[varName] = nil
                        end
                    elseif lastRhsTainted then
                        -- No corresponding RHS: spill from the last multi-return expression.
                        taintSet[varName] = true
                        markIndependentTaint(varName)
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
            -- Also handles t.k = expr (MemberExpr LHS with "." indexer) and a
            -- `...` spill (`unit, info = ...`) inside a detected secret-event
            -- handler — round-6b: the spill was modeled only for
            -- LocalStatement, so plain assignments were a false negative.
            local lhsList = stmt.Lhs or {}
            local rhsList = stmt.Rhs or {}
            local dotsIndex, dotsNode = nil, nil
            for i, lhsExpr in ipairs(lhsList) do
                local rhs = rhsList[i]
                if lhsExpr.AstType == "VarExpr" and lhsExpr.Name then
                    local varName = lhsExpr.Name
                    if rhs and rhs.AstType == "DotsExpr" then
                        local vsecret = fnEventCtx and not fnEventCtx.suppressSpill
                            and fnEventCtx.varargSecret
                        dotsIndex, dotsNode = i, rhs
                        if vsecret and vsecret[1] then
                            taintSet[varName] = true
                            fnEventCtx.payloadNames[varName] = true
                            if debug then debug.taintedAt[varName] = nodeLine(rhs) end
                        else
                            taintSet[varName] = nil
                        end
                    elseif rhs then
                        dotsIndex = nil
                        local hadSource = walkExpr(rhs, taintSet, fieldTaintSet, findings, registry, filePath)
                        -- Also taint when RHS reads a tainted local or field
                        -- (e.g. chargeInfo = result), incl. and/or value flow.
                        local rhsTainted = hadSource or isValueTainted(rhs, taintSet, fieldTaintSet, registry)
                        if rhsTainted then
                            taintSet[varName] = true
                            classifyAssignedTaint(varName, rhs)
                            if debug then
                                debug.taintedAt[varName] = nodeLine(rhs)
                            end
                        else
                            taintSet[varName] = nil
                        end
                    elseif dotsIndex then
                        -- Overflow LHS var fed by the `...` spill.
                        local vsecret = fnEventCtx and not fnEventCtx.suppressSpill
                            and fnEventCtx.varargSecret
                        if vsecret and vsecret[i - dotsIndex + 1] then
                            taintSet[varName] = true
                            fnEventCtx.payloadNames[varName] = true
                            if debug then debug.taintedAt[varName] = nodeLine(dotsNode) end
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
                            local rhsTainted = hadSource or isValueTainted(rhs, taintSet, fieldTaintSet, registry)
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

                local suppressSpill = false
                if clause.Condition then
                    -- Dispatch branch for a different, non-secret event: the
                    -- secret payload params are not live here — untaint the
                    -- named params AND suppress the vararg-spill rule for the
                    -- branch body (a `local unit = ...` inside it spills that
                    -- OTHER event's payload).
                    if nonSecretEventBranch(clause.Condition, registry) then
                        suppressSpill = true
                        for n in pairs(fnEventCtx.payloadNames) do
                            branchTaint[n] = nil
                        end
                    end
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
                    local prevSuppress = fnEventCtx and fnEventCtx.suppressSpill
                    if suppressSpill and fnEventCtx then
                        fnEventCtx.suppressSpill = true
                    end
                    walkStatements(clause.Body.Body, branchTaint, branchFieldTaint, findings, registry, filePath, debug)
                    if fnEventCtx then fnEventCtx.suppressSpill = prevSuppress end
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
        elseif t == "DoStatement" then
            -- Plain `do … end` block (round-6b: these bodies were silently
            -- skipped — an entire blind spot for every rule in this walker).
            -- Locals inside are block-scoped, but the name-keyed taint sets
            -- treat the union conservatively, same as if-branch bodies.
            if stmt.Body and stmt.Body.Body then
                walkStatements(stmt.Body.Body, taintSet, fieldTaintSet, findings, registry, filePath, debug)
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

-- File-local alias resolution (built by collectPreconditionAliases):
--   aliases.map[localName] = canonical dotted name (guarded API or gate)
--   aliases.ns[localName]  = canonical namespace ("C_UnitAuras", "C_Secrets")
-- Resolves `local Get = C_UnitAuras.GetUnitAuras; Get(...)` and
-- `local UA = C_UnitAuras; UA.GetUnitAuras(...)` call names back to their
-- canonical form for both the guarded-API and restriction-gate lookups.
local function resolveAliasedName(name, aliases)
    if not name or not aliases then return name end
    if aliases.map[name] then return aliases.map[name] end
    local prefix, rest = name:match("^([%w_]+)([.:].+)$")
    if prefix and aliases.ns[prefix] then
        return aliases.ns[prefix] .. rest
    end
    return name
end

-- Gate recognition is PROTECTION-GRANTING, so unlike the finding-emitting API
-- resolution it must not trust an alias name that the file ever binds to
-- anything else (round-6: the file-scope alias union ignored scope and
-- reassignment, so `local isSecret = C_Secrets.ShouldAurasBeSecret` in one
-- scope let an UNRELATED `isSecret` elsewhere suppress real findings).
-- aliases.poisoned holds names with conflicting bindings (see the fixpoint in
-- M.analyze); a poisoned hop grants no protection. Direct registry names
-- (extra_restriction_gates wrappers) are unaffected.
local function isGateName(name, registry, aliases)
    if not name then return false end
    if registry:isRestrictionGate(name) then return true end
    if not aliases then return false end
    local poisoned = aliases.poisoned or {}
    if aliases.map[name] then
        return (not poisoned[name]) and registry:isRestrictionGate(aliases.map[name])
    end
    local prefix, rest = name:match("^([%w_]+)([.:].+)$")
    if prefix and aliases.ns[prefix] then
        return (not poisoned[prefix])
            and registry:isRestrictionGate(aliases.ns[prefix] .. rest)
    end
    return false
end

-- Gate polarity of an if-clause condition:
--   "positive": condition true implies RESTRICTED — a bare gate call,
--     possibly guarded by an `and` chain (`C_Secrets and C_Secrets.X and
--     C_Secrets.X()` — the authored idiom).
--   "negative": condition true implies UNRESTRICTED (`not gate()`,
--     `A and not gate()`).
--   nil: no gate, or an unmodeled shape (gate under `or`,
--     non-boolean-literal comparisons like `gate() ~= nil`) — callers treat
--     the branch as UNKNOWN and inherit their state; unmodeled shapes never
--     grant protection (2026-07 round-4).
local function gateConditionPolarity(cond, registry, aliases)
    if type(cond) ~= "table" then return nil end
    local t = cond.AstType
    if t == "Parentheses" then
        return gateConditionPolarity(cond.Inner, registry, aliases)
    end
    if t == "CallExpr" then
        local name = callTargetName(cond.Base)
        if isGateName(name, registry, aliases) then return "positive" end
        return nil
    end
    if t == "UnopExpr" and cond.Op == "not" then
        local p = gateConditionPolarity(cond.Rhs, registry, aliases)
        if p == "positive" then return "negative" end
        if p == "negative" then return "positive" end
        return nil
    end
    if t == "BinopExpr" and cond.Op == "and" then
        -- `A and gate()`: the whole condition true implies the gate's
        -- verdict; either operand may carry it (the other is just a guard).
        return gateConditionPolarity(cond.Rhs, registry, aliases)
            or gateConditionPolarity(cond.Lhs, registry, aliases)
    end
    if t == "BinopExpr" and (cond.Op == "==" or cond.Op == "~=") then
        -- Boolean-literal comparisons: `gate() == true`, `gate() ~= false`
        -- keep the polarity; `gate() == false`, `gate() ~= true` invert it.
        local lhsIsLit = type(cond.Lhs) == "table" and cond.Lhs.AstType == "BooleanExpr"
        local rhsIsLit = type(cond.Rhs) == "table" and cond.Rhs.AstType == "BooleanExpr"
        local lit = (lhsIsLit and cond.Lhs) or (rhsIsLit and cond.Rhs) or nil
        if lit then
            local other = lhsIsLit and cond.Rhs or cond.Lhs
            local p = gateConditionPolarity(other, registry, aliases)
            if p then
                local keep = (cond.Op == "==" and lit.Value == true)
                    or (cond.Op == "~=" and lit.Value == false)
                if keep then return p end
                return p == "positive" and "negative" or "positive"
            end
        end
        return nil
    end
    return nil
end

-- Dotted name of a bare name/member chain ("C_Secrets",
-- "C_Secrets.ShouldAurasBeSecret"); nil for anything else.
local function nameChainOf(n)
    if type(n) ~= "table" then return nil end
    if n.AstType == "Parentheses" then return nameChainOf(n.Inner) end
    if n.AstType == "VarExpr" or n.AstType == "MemberExpr" then
        return (callTargetName(n))
    end
    return nil
end

-- Is `expr` an existence guard FOR the gate named `gateName` — i.e. a
-- dotted prefix of the gate's own call chain (`C_Secrets`,
-- `C_Secrets.ShouldAurasBeSecret` for gate `C_Secrets.ShouldAurasBeSecret()`),
-- or an `and`-chain of such prefixes? An arbitrary conjunct (`someFlag and
-- gate()`) can be false while restricted and must NOT establish dominance
-- (2026-07 round-4).
local function isGuardPrefixFor(expr, gateName)
    if type(expr) ~= "table" then return false end
    if expr.AstType == "Parentheses" then return isGuardPrefixFor(expr.Inner, gateName) end
    if expr.AstType == "BinopExpr" and expr.Op == "and" then
        return isGuardPrefixFor(expr.Lhs, gateName) and isGuardPrefixFor(expr.Rhs, gateName)
    end
    local name = nameChainOf(expr)
    if not name then return false end
    return gateName == name or gateName:sub(1, #name + 1) == (name .. ".")
end

-- Flip-safety: does a RESTRICTED state GUARANTEE this condition evaluates
-- true? Only then does a terminating body prove the code after the if runs
-- unrestricted. Returns the gate call's SYNTACTIC name on success (the
-- prefix check runs against the name as written, aliases included), nil
-- otherwise. `or` disjuncts are safe (restricted ⇒ the gate disjunct is
-- true ⇒ the whole `or` is true). `and` conjuncts are accepted ONLY when
-- they are existence guards for the gate itself.
local function restrictedImpliesTrue(cond, registry, aliases)
    if type(cond) ~= "table" then return nil end
    local t = cond.AstType
    if t == "Parentheses" then return restrictedImpliesTrue(cond.Inner, registry, aliases) end
    if t == "CallExpr" then
        local name = callTargetName(cond.Base)
        if isGateName(name, registry, aliases) then return name end
        return nil
    end
    if t == "BinopExpr" then
        if cond.Op == "or" then
            return restrictedImpliesTrue(cond.Lhs, registry, aliases)
                or restrictedImpliesTrue(cond.Rhs, registry, aliases)
        end
        if cond.Op == "and" then
            local n = restrictedImpliesTrue(cond.Rhs, registry, aliases)
            if n and isGuardPrefixFor(cond.Lhs, n) then return n end
            n = restrictedImpliesTrue(cond.Lhs, registry, aliases)
            if n and isGuardPrefixFor(cond.Rhs, n) then return n end
            return nil
        end
        if cond.Op == "==" or cond.Op == "~=" then
            local lhsIsLit = type(cond.Lhs) == "table" and cond.Lhs.AstType == "BooleanExpr"
            local rhsIsLit = type(cond.Rhs) == "table" and cond.Rhs.AstType == "BooleanExpr"
            local lit = (lhsIsLit and cond.Lhs) or (rhsIsLit and cond.Rhs) or nil
            if lit then
                local other = lhsIsLit and cond.Rhs or cond.Lhs
                local keep = (cond.Op == "==" and lit.Value == true)
                    or (cond.Op == "~=" and lit.Value == false)
                if keep then return restrictedImpliesTrue(other, registry, aliases) end
            end
        end
    end
    return nil
end

-- Does a clause body (Statlist) unconditionally leave the enclosing
-- function? Only `return` and a trailing error() call count — anything
-- weaker means execution continues past the if with the restriction state
-- unknown.
local function bodyTerminates(stmtlist)
    local body = type(stmtlist) == "table" and stmtlist.Body
    if type(body) ~= "table" or #body == 0 then return false end
    local last = body[#body]
    if last.AstType == "ReturnStatement" then return true end
    if last.AstType == "CallStatement" then
        local expr = last.Expression
        if expr and expr.AstType == "CallExpr" then
            return callTargetName(expr.Base) == "error"
        end
    end
    return false
end

-- File-scope aliases of precondition-guarded APIs, restriction gates and
-- their NAMESPACES (2026-07 round-4: guarded aliases, alias chains and
-- namespace aliases were invisible):
--   local GetAuras = C_UnitAuras.GetUnitAuras            → map
--   local Get = C_UnitAuras and C_UnitAuras.GetUnitAuras → map (guarded init)
--   local Also = GetAuras                                → map (chain hop)
--   local UA = C_UnitAuras                               → ns
--   local isSecret = C_Secrets.ShouldAurasBeSecret       → map (gate alias)
-- The walk is STATEMENT-ORDERED so chains resolve through earlier hops.
-- Scoping/shadowing are not modeled (file-scope union). For the
-- finding-EMITTING resolution that over-approximation only ADDs findings;
-- for gate protection it could SUPPRESS them, so aliases.binds records every
-- binding of every name (locals, assignments, function names, parameters,
-- for-variables) and M.analyze poisons any alias name with a conflicting
-- binding — poisoned names never grant protection (isGateName) and never
-- serve as chain hops (aliases.poisoned is the `blocked` set fed back in by
-- the fixpoint loop).
local function collectPreconditionAliases(node, registry, aliases, visited)
    if type(node) ~= "table" or visited[node] then return end
    visited[node] = true
    local poisoned = aliases.poisoned or {}
    -- Record a binding of `name`: canonical string when the bound value is a
    -- recognized gate/API/namespace, false (conflict) otherwise or on any
    -- disagreement between bindings.
    local function recordBind(name, canonical)
        if not name then return end
        local binds = aliases.binds
        if binds[name] == nil then
            binds[name] = canonical or false
        elseif binds[name] ~= canonical then
            binds[name] = false
        end
    end
    -- Canonical name an init expression resolves to, unwrapping the guarded
    -- `A and A.f` / `A and A.f or fallback` idioms by scanning operands.
    local function resolveInit(init)
        if type(init) ~= "table" then return nil end
        local t = init.AstType
        if t == "Parentheses" then return resolveInit(init.Inner) end
        if t == "MemberExpr" or t == "VarExpr" then
            local name = callTargetName(init)
            if not name then return nil end
            -- A chain hop through a poisoned name is ambiguous — refuse it.
            local base = name:match("^([%w_]+)")
            if base and poisoned[base] then return nil end
            return resolveAliasedName(name, aliases)
        end
        if t == "BinopExpr" and (init.Op == "and" or init.Op == "or") then
            local n = resolveInit(init.Rhs)
            if n and (registry:preconditionFlags(n) or registry:isRestrictionGate(n)
                or registry.preconditionNamespaces[n]) then
                return n
            end
            n = resolveInit(init.Lhs)
            if n and (registry:preconditionFlags(n) or registry:isRestrictionGate(n)
                or registry.preconditionNamespaces[n]) then
                return n
            end
        end
        return nil
    end
    local function harvest(vars, inits, nameOf)
        if type(vars) ~= "table" then return end
        inits = type(inits) == "table" and inits or {}
        for i, var in ipairs(vars) do
            local localName = nameOf(var)
            if localName then
                local resolved = resolveInit(inits[i])
                local canonical
                -- Registration stays PERMISSIVE even for poisoned names — the
                -- finding-emitting resolution may over-approximate; poisoning
                -- only blocks gate protection and chain hops.
                if resolved and (registry:preconditionFlags(resolved)
                    or registry:isRestrictionGate(resolved)) then
                    canonical = resolved
                    aliases.map[localName] = resolved
                elseif resolved and registry.preconditionNamespaces[resolved] then
                    canonical = resolved
                    aliases.ns[localName] = resolved
                end
                recordBind(localName, canonical)
            end
        end
    end
    if node.AstType == "Statlist" and type(node.Body) == "table" then
        for _, stmt in ipairs(node.Body) do
            collectPreconditionAliases(stmt, registry, aliases, visited)
        end
        return
    end
    if node.AstType == "LocalStatement" then
        harvest(node.LocalList, node.InitList, function(v) return v.Name end)
    elseif node.AstType == "AssignmentStatement" then
        harvest(node.Lhs, node.Rhs, function(v)
            return v.AstType == "VarExpr" and v.Name or nil
        end)
    elseif node.AstType == "Function" then
        -- Function names and parameters are bindings too (a local function or
        -- a parameter reusing an alias name makes that name ambiguous).
        if node.Name and node.Name.Name then recordBind(node.Name.Name, nil) end
        for _, arg in ipairs(node.Arguments or {}) do
            if arg.Name then recordBind(arg.Name, nil) end
        end
        collectPreconditionAliases(node.Body, registry, aliases, visited)
        return
    elseif node.AstType == "NumericForStatement" then
        if node.Variable and node.Variable.Name then
            recordBind(node.Variable.Name, nil)
        end
    elseif node.AstType == "GenericForStatement" then
        for _, v in ipairs(node.VariableList or {}) do
            if v.Name then recordBind(v.Name, nil) end
        end
    end
    for k, v in pairs(node) do
        if k ~= "Tokens" and type(v) == "table" then
            collectPreconditionAliases(v, registry, aliases, visited)
        end
    end
end

local preconditionScan

-- Ordered walk over a statement list. Dominance is deliberately narrow: the
-- `gated` state flips true for FOLLOWING statements only when an if-clause
-- whose condition is a POSITIVE gate (`if gate() then`) has a body that
-- unconditionally returns/errors — the authored bail idiom. A gate whose
-- result is ignored (`local _ = gate()`), inverted without a terminating
-- branch, or buried in an unmodeled expression proves nothing and no longer
-- protects later calls (2026-07 re-review: the old any-gate-in-statement
-- flip accepted all of those).
local function preconditionScanBody(stmts, registry, filePath, findings, gated, visited, aliases)
    if type(stmts) ~= "table" then return end
    -- Escape prepass (round-4 named-callback false negative; round-6 widened
    -- to returned and stored callbacks): a local function — `local function
    -- f` or `local f = function()` — whose NAME is later passed as a call
    -- argument (`f:SetScript("OnEvent", OnEvent)`), RETURNED, assigned
    -- anywhere (module export, table field, re-bind), or placed in a table
    -- constructor, escapes exactly like an inline closure — its body runs
    -- later under an unknown restriction state, so it must scan UNGATED
    -- regardless of gates above its definition. A name only ever used as a
    -- call BASE (`inner()`) stays synchronous and inherits normally.
    -- Cross-list escapes (defined here, passed elsewhere) are not modeled.
    local escapedFns
    do
        local defined
        for _, stmt in ipairs(stmts) do
            if stmt.AstType == "Function" and stmt.IsLocal
                and stmt.Name and stmt.Name.Name then
                defined = defined or {}
                defined[stmt.Name.Name] = true
            elseif stmt.AstType == "LocalStatement"
                and type(stmt.LocalList) == "table" then
                for i, v in ipairs(stmt.LocalList) do
                    local init = stmt.InitList and stmt.InitList[i]
                    if v.Name and type(init) == "table"
                        and init.AstType == "Function" then
                        defined = defined or {}
                        defined[v.Name] = true
                    end
                end
            end
        end
        if defined then
            local function mark(a)
                if type(a) == "table" and a.AstType == "VarExpr"
                    and defined[a.Name] then
                    escapedFns = escapedFns or {}
                    escapedFns[a.Name] = true
                end
            end
            local function findEscapes(n, seen)
                if type(n) ~= "table" or seen[n] then return end
                seen[n] = true
                local t = n.AstType
                if (t == "CallExpr" or t == "ReturnStatement")
                    and type(n.Arguments) == "table" then
                    for _, a in ipairs(n.Arguments) do mark(a) end
                elseif t == "AssignmentStatement" and type(n.Rhs) == "table" then
                    for _, a in ipairs(n.Rhs) do mark(a) end
                elseif t == "LocalStatement" and type(n.InitList) == "table" then
                    -- `local g = f` can be called synchronously, but tracking
                    -- that alias is out of scope — treat as an escape
                    -- (over-report direction).
                    for _, a in ipairs(n.InitList) do mark(a) end
                elseif t == "ConstructorExpr" and type(n.EntryList) == "table" then
                    for _, entry in ipairs(n.EntryList) do
                        if entry then mark(entry.Value) end
                    end
                end
                for k, v in pairs(n) do
                    if k ~= "Tokens" and type(v) == "table" then findEscapes(v, seen) end
                end
            end
            for _, stmt in ipairs(stmts) do findEscapes(stmt, {}) end
        end
    end
    for _, stmt in ipairs(stmts) do
        if stmt.AstType == "IfStatement" and type(stmt.Clauses) == "table" then
            local flip = false
            local soleGatePolarity, gateClauseCount = nil, 0
            for _, clause in ipairs(stmt.Clauses) do
                if clause.Condition then
                    local p = gateConditionPolarity(clause.Condition, registry, aliases)
                    if p then
                        gateClauseCount = gateClauseCount + 1
                        soleGatePolarity = p
                    end
                end
            end
            -- Dominance flip: ONLY the FIRST clause can prove it. An
            -- `elseif gate() then return end` is unsound — when an earlier
            -- clause's condition is true, the gate is never evaluated and
            -- that branch falls through with the restriction state unknown.
            -- Flip-safety additionally requires restrictedImpliesTrue (a
            -- restricted state cannot slip past the condition) plus a
            -- terminating body.
            do
                local first = stmt.Clauses[1]
                if first and first.Condition
                    and restrictedImpliesTrue(first.Condition, registry, aliases)
                    and bodyTerminates(first.Body) then
                    flip = true
                end
            end
            -- priorsProve: reaching clause k means every earlier condition
            -- was evaluated AND false. If ANY earlier condition is
            -- restricted-implies-true, its falsity proves the state was
            -- unrestricted at that evaluation — so clause k's condition AND
            -- body run only UNRESTRICTED. This protects `elseif`/`else`
            -- after an `if gate() then …` (round-6 false positive) and
            -- replaces the old sole-positive-gate else shortcut, which
            -- wrongly protected the else of compound conditions like
            -- `if gate() and ready then` — that else IS restricted-reachable
            -- via `ready == false` while gate() is true (round-6 false
            -- negative; restrictedImpliesTrue refuses arbitrary conjuncts).
            local priorsProve = false
            for _, clause in ipairs(stmt.Clauses) do
                local entryProven = priorsProve
                local scanGated
                if clause.Condition then
                    local pol = gateConditionPolarity(clause.Condition, registry, aliases)
                    if entryProven then
                        -- Every earlier clause would have caught a restricted
                        -- state — this clause is unrestricted-only.
                        scanGated = true
                    elseif pol == "negative" then
                        -- Branch runs only when UNRESTRICTED.
                        scanGated = true
                    elseif pol == "positive" then
                        -- Branch runs only when RESTRICTED: a guarded API
                        -- call here is a GUARANTEED hard error — scan
                        -- ungated so it flags even under an outer gate
                        -- (the gate was just re-consulted and came back
                        -- restricted).
                        scanGated = false
                    elseif restrictedImpliesTrue(clause.Condition, registry, aliases) then
                        -- Unmodeled polarity but restricted GUARANTEES entry
                        -- (`gate() or fallback`): the body is
                        -- restricted-REACHABLE, so a guarded call inside it
                        -- can hard-error — scan ungated.
                        scanGated = false
                    else
                        -- No/unmodeled gate (`gate() ~= nil`, gate under a
                        -- comparison): UNKNOWN conditions never grant
                        -- protection — inherit (2026-07 round-4; the old
                        -- gate-anywhere-in-condition fallback suppressed
                        -- real findings).
                        scanGated = gated
                    end
                    preconditionScan(clause.Condition, registry, filePath,
                        findings, gated or entryProven, visited, aliases)
                    priorsProve = priorsProve
                        or (restrictedImpliesTrue(clause.Condition, registry, aliases) ~= nil)
                else
                    -- else clause: runs when every condition was false.
                    if entryProven then
                        scanGated = true
                    elseif gateClauseCount == 1 and soleGatePolarity == "negative" then
                        -- Sole negative gate (`if not gate() then A else B`):
                        -- B is restricted-reachable — scan ungated.
                        scanGated = false
                    else
                        scanGated = gated
                    end
                end
                preconditionScanBody(clause.Body and clause.Body.Body,
                    registry, filePath, findings, scanGated, visited, aliases)
            end
            if flip then gated = true end
        elseif stmt.AstType == "Function" and stmt.IsLocal
            and stmt.Name and stmt.Name.Name
            and escapedFns and escapedFns[stmt.Name.Name] then
            -- Escaped named callback (see the prepass above): its body must
            -- not inherit a definition-time gate.
            preconditionScan(stmt, registry, filePath, findings, false, visited, aliases)
        elseif stmt.AstType == "LocalStatement" and escapedFns
            and type(stmt.LocalList) == "table" then
            -- `local f = function()` whose name escapes: the closure body
            -- scans UNGATED first (visited then skips it in the full-stmt
            -- scan below, which covers the remaining inits normally).
            for i, v in ipairs(stmt.LocalList) do
                local init = stmt.InitList and stmt.InitList[i]
                if type(init) == "table" and init.AstType == "Function"
                    and v.Name and escapedFns[v.Name] then
                    preconditionScan(init, registry, filePath, findings, false, visited, aliases)
                end
            end
            preconditionScan(stmt, registry, filePath, findings, gated, visited, aliases)
        else
            preconditionScan(stmt, registry, filePath, findings, gated, visited, aliases)
        end
    end
end

function preconditionScan(node, registry, filePath, findings, gated, visited, aliases)
    if type(node) ~= "table" or visited[node] then return end
    visited[node] = true

    if node.AstType == "Function" then
        -- New gate scope: the body walks in statement order, seeded with the
        -- lexically-inherited state at the definition point. Parameters
        -- cannot contain calls in Lua 5.1, so only the body needs scanning.
        preconditionScanBody(node.Body and node.Body.Body, registry, filePath,
            findings, gated, visited, aliases)
        return
    end

    if node.AstType == "Statlist" then
        -- Every nested block (while/for/do bodies) walks in statement order
        -- too, so gate-below-call inside a block is caught the same way as
        -- at function top level. (IfStatement clause bodies are routed
        -- through preconditionScanBody's polarity handling and never reach
        -- here — their Statlist nodes are already in `visited`.)
        preconditionScanBody(node.Body, registry, filePath, findings, gated, visited, aliases)
        return
    end

    if node.AstType == "ReturnStatement" then
        -- A RETURNED closure runs in the caller under an unknown restriction
        -- state — scan ungated, same rule as closures passed to arbitrary
        -- calls (round-6: returned callbacks inherited the definition-time
        -- gate).
        if type(node.Arguments) == "table" then
            for _, a in ipairs(node.Arguments) do
                local g = gated
                if type(a) == "table" and a.AstType == "Function" then g = false end
                preconditionScan(a, registry, filePath, findings, g, visited, aliases)
            end
        end
        return
    end

    if node.AstType == "ConstructorExpr" then
        -- TABLE-STORED closures escape (callback/handler tables run their
        -- entries later via unknown paths) — scan ungated.
        if type(node.EntryList) == "table" then
            for _, entry in ipairs(node.EntryList) do
                if entry then
                    if type(entry.Key) == "table" then
                        preconditionScan(entry.Key, registry, filePath, findings, gated, visited, aliases)
                    end
                    local v = entry.Value
                    local g = gated
                    if type(v) == "table" and v.AstType == "Function" then g = false end
                    preconditionScan(v, registry, filePath, findings, g, visited, aliases)
                end
            end
        end
        return
    end

    if node.AstType == "AssignmentStatement" then
        -- STORED closures escape (module exports, table fields, upvalue
        -- re-binds): `M.handler = function() … end` runs later under an
        -- unknown restriction state — scan ungated.
        if type(node.Lhs) == "table" then
            for _, l in ipairs(node.Lhs) do
                preconditionScan(l, registry, filePath, findings, gated, visited, aliases)
            end
        end
        if type(node.Rhs) == "table" then
            for _, r in ipairs(node.Rhs) do
                local g = gated
                if type(r) == "table" and r.AstType == "Function" then g = false end
                preconditionScan(r, registry, filePath, findings, g, visited, aliases)
            end
        end
        return
    end

    if node.AstType == "CallExpr" then
        local name = callTargetName(node.Base)
        if name == "pcall" or name == "xpcall" then
            -- Only argument 1 is protected, and only when it is a CLOSURE:
            -- pcall(function() API() end) runs the body under protection,
            -- while pcall(API(...)) evaluates the call BEFORE pcall takes
            -- over and must flag. A function REFERENCE argument is not a
            -- CallExpr so it never flags. The base, every other argument,
            -- and xpcall's handler evaluate/run unprotected — inherited
            -- state.
            local args = node.Arguments
            if type(args) == "table" then
                for i = 1, #args do
                    local argGated = gated
                    if i == 1 and args[i].AstType == "Function" then
                        argGated = true
                    end
                    preconditionScan(args[i], registry, filePath, findings,
                        argGated, visited, aliases)
                end
            end
            preconditionScan(node.Base, registry, filePath, findings, gated, visited, aliases)
            return
        end
        if name and not gated then
            -- Resolve file-local aliases: direct (`local Get =
            -- C_UnitAuras.GetUnitAuras; Get()`) and namespace (`local UA =
            -- C_UnitAuras; UA.GetUnitAuras()`).
            local canonical = name
            if not registry:preconditionFlags(name) then
                canonical = resolveAliasedName(name, aliases)
            end
            local flags = registry:preconditionFlags(canonical)
            if flags then
                local flagText = type(flags) == "table" and table.concat(flags, ",")
                    or "precondition-guarded"
                findings[#findings + 1] = {
                    file = filePath, line = nodeLine(node) or 0, col = 1,
                    severity = "review",
                    source_function = canonical,
                    sink = "<precondition>",
                    message = flagText .. " API called without a restriction gate or pcall — hard-errors under encounter/M+/PvP restrictions",
                    suppressed = false, suppression_reason = nil,
                }
            end
        end
        -- A CLOSURE passed to an arbitrary call ESCAPES: it can run later
        -- (timers, hooks, event registration) under a different restriction
        -- state, so a gate at the registration site proves nothing for its
        -- body — escaping closures scan UNGATED (2026-07 round-3
        -- later-callback false negative). Everything else inherits. The
        -- pcall branch above already returned, so this never demotes a
        -- protected pcall closure.
        local args = node.Arguments
        if type(args) == "table" then
            for i = 1, #args do
                local argGated = gated
                if type(args[i]) == "table" and args[i].AstType == "Function" then
                    argGated = false
                end
                preconditionScan(args[i], registry, filePath, findings,
                    argGated, visited, aliases)
            end
        end
        preconditionScan(node.Base, registry, filePath, findings, gated, visited, aliases)
        return
    end

    for k, v in pairs(node) do
        if k ~= "Tokens" then
            preconditionScan(v, registry, filePath, findings, gated, visited, aliases)
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
    -- Aspect-returning getters only taint inside config aspect_paths; swap in
    -- the aspect-stripped registry view everywhere else (see registry.lua).
    if registry.aspectStripped and not Config.isAspectPath(config, filePath) then
        registry = registry:aspectStripped()
    end
    local findings = {}
    local taintSet = {}
    local fieldTaintSet = {}
    -- Always allocate debugInfo so annotation pass can always record warnings.
    local debugInfo = { taintedAt = {}, warnings = {} }

    -- Walk the top-level chunk body. preconditionOnly mode (vendored-lib
    -- coverage via config precondition_only_paths) skips the taint pass —
    -- only the raw guarded-call scan below runs.
    local stmts = ast.Body or {}
    if not opts.preconditionOnly then
        registeredHandlerHits = collectRegisteredHandlers(ast, registry)
        fnEventCtx = nil
        walkStatements(stmts, taintSet, fieldTaintSet, findings, registry, filePath, debugInfo)
        registeredHandlerHits = nil
        fnEventCtx = nil
    end

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
        -- Alias fixpoint: names with CONFLICTING bindings are poisoned and the
        -- collection re-runs with them blocked, so chains resolved through a
        -- poisoned hop dissolve too (each round can only shrink the maps —
        -- terminates in at most one round per alias name). The permissive
        -- map/ns stay in use for finding EMISSION; only gate protection
        -- consults `poisoned` (see isGateName).
        local blocked = {}
        local aliases
        repeat
            aliases = { map = {}, ns = {}, binds = {}, poisoned = blocked }
            collectPreconditionAliases(ast, registry, aliases, {})
            local changed = false
            for name, canon in pairs(aliases.map) do
                if not blocked[name] and aliases.binds[name] ~= canon then
                    blocked[name] = true
                    changed = true
                end
            end
            for name, canon in pairs(aliases.ns) do
                if not blocked[name] and aliases.binds[name] ~= canon then
                    blocked[name] = true
                    changed = true
                end
            end
        until not changed
        preconditionScan(ast, registry, filePath, findings, false, {}, aliases)
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

    -- Promote precondition findings → strict for files in
    -- strict_precondition_paths (audited vendored libs like LibOpenRaid):
    -- once a lib's raw guarded calls are fixed/annotated, a regression fails
    -- CI instead of hiding at review tier. Annotated sites are suppressed
    -- below and never reach the gate.
    if Config.isStrictPreconditionPath and Config.isStrictPreconditionPath(config, filePath) then
        for _, f in ipairs(findings) do
            if f.sink == "<precondition>" then
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
