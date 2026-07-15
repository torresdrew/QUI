-- tests/taint/analyzer_test.lua
local Analyzer = dofile("tests/taint/analyzer.lua")
local Registry = dofile("tests/taint/registry.lua")
local Config = dofile("tests/taint/config.lua")

local function assert_eq(a, e, msg)
    if a ~= e then error((msg or "") .. ": expected " .. tostring(e) ..
        ", got " .. tostring(a), 2) end
end

-- Skeleton smoke test: no sources registered → no findings on any input.
local r = Registry.new()
local cfg = Config.loadFromString(nil)

local source = [[
local x = 1
local y = x + 2
return y
]]
local findings = Analyzer.analyze(source, "modules/foo.lua", r, cfg)
assert_eq(type(findings), "table", "findings is a table")
assert_eq(#findings, 0, "no findings on plain code with no sources registered")

-- Parse error returns nil + err
local bad = "local = "
local f2, err = Analyzer.analyze(bad, "modules/bad.lua", r, cfg)
assert_eq(f2, nil, "parse error returns nil")
assert(err and #err > 0, "parse error has message")

print("analyzer skeleton test passed")

-- Test: source detection tracks taint set
local r2 = Registry.new()
r2:addSource("C_Spell.GetSpellCharges")

local source2 = [[
local info = C_Spell.GetSpellCharges(123)
local n = info.currentCharges
return n
]]
local findings2, err2, debug2 = Analyzer.analyze(
    source2, "modules/foo.lua", r2, cfg, { exposeDebug = true })
assert(findings2, "no error: " .. tostring(err2))

-- After analysis, the debug table should record `info` was tainted.
assert(debug2.taintedAt, "debug.taintedAt present")
assert(debug2.taintedAt.info, "info marked tainted (source assignment)")

-- For now, no findings yet (rule only adds taint, doesn't emit on tainted reads)
assert_eq(#findings2, 0, "no findings yet — only taint tracking")

print("source detection test passed")

-- Test: tainted local in arithmetic emits a finding
local r3 = Registry.new()
r3:addSource("C_Spell.GetSpellCharges")

local source3 = [[
local info = C_Spell.GetSpellCharges(1)
local n = info + 1
return n
]]
local findings3 = Analyzer.analyze(source3, "modules/foo.lua", r3, cfg)
assert_eq(#findings3, 1, "one finding for arith on tainted")
assert_eq(findings3[1].severity, "advisory", "advisory by default")
assert_eq(findings3[1].sink, "<arith>", "sink labeled arith")

-- Test: tainted local in tonumber call
local source4 = [[
local info = C_Spell.GetSpellCharges(1)
local n = tonumber(info)
return n
]]
local findings4 = Analyzer.analyze(source4, "modules/foo.lua", r3, cfg)
assert_eq(#findings4, 1, "one finding for tonumber on tainted")
assert_eq(findings4[1].sink, "tonumber", "sink labeled tonumber")

-- Test: tainted local in comparison
local source5 = [[
local info = C_Spell.GetSpellCharges(1)
if info == nil then return end
return 1
]]
local findings5 = Analyzer.analyze(source5, "modules/foo.lua", r3, cfg)
assert_eq(#findings5, 1, "one finding for comparison on tainted")
assert_eq(findings5[1].sink, "<comparison>", "sink labeled comparison")

-- Test: tainted local used as branch truthiness
local source5b = [[
local info = C_Spell.GetSpellCharges(1)
if info then
    return 1
end
return 0
]]
local findings5b = Analyzer.analyze(source5b, "modules/foo.lua", r3, cfg)
assert_eq(#findings5b, 1, "one finding for truthiness on tainted")
assert_eq(findings5b[1].sink, "<truthiness>", "sink labeled truthiness")

print("unsafe sink test passed")

-- Test: source nested in binop propagates taint
local r4 = Registry.new()
r4:addSource("S")
local sourceN1 = [[
local a = 1
local x = a + S()
return x
]]
local fN1, _, dN1 = Analyzer.analyze(sourceN1, "modules/foo.lua", r4, cfg, {exposeDebug=true})
assert(dN1.taintedAt.x, "x should be tainted (source nested in binop)")

-- Test: parenthesized expression with source
local sourceN2 = [[
local x = (S())
return x
]]
local fN2, _, dN2 = Analyzer.analyze(sourceN2, "modules/foo.lua", r4, cfg, {exposeDebug=true})
assert(dN2.taintedAt.x, "x should be tainted (source in parens)")

-- Test: parenthesized binop with tainted operand emits finding
local sourceN3 = [[
local a = S()
local x = (a + 1) * 2
return x
]]
local fN3 = Analyzer.analyze(sourceN3, "modules/foo.lua", r4, cfg)
assert_eq(#fN3, 1, "(a + 1) * 2 should emit one finding for the inner +")
assert_eq(fN3[1].sink, "<arith>", "inner arith found")

-- Test: unop on tainted local emits finding
local sourceN4 = [[
local a = S()
local x = -a
return x
]]
local fN4 = Analyzer.analyze(sourceN4, "modules/foo.lua", r4, cfg)
assert_eq(#fN4, 1, "-a should emit a finding")
assert(fN4[1].sink:find("unop"), "sink labeled with unop, got: " .. fN4[1].sink)

print("nested taint propagation test passed")

-- Test: tainted local passed to safe sink method emits no finding
local r5 = Registry.new()
r5:addSource("C_Spell.GetSpellCooldownDuration")

local source6 = [[
local durObj = C_Spell.GetSpellCooldownDuration(123)
cd:SetCooldownFromDurationObject(durObj)
]]
local findings6 = Analyzer.analyze(source6, "modules/foo.lua", r5, cfg)
assert_eq(#findings6, 0, "no finding when piped to safe sink method")

-- Test: tainted local passed to C_StringUtil formatter (qualified safe sink)
local source7 = [[
local n = C_Spell.GetSpellCooldownDuration(1)
text:SetText(C_StringUtil.RoundToNearestString(n, 5))
]]
local findings7 = Analyzer.analyze(source7, "modules/foo.lua", r5, cfg)
assert_eq(#findings7, 0, "no finding through C_StringUtil + SetText pipeline")

-- Test: control — same value to tonumber emits one finding
local source8 = [[
local n = C_Spell.GetSpellCooldownDuration(1)
local m = tonumber(n)
]]
local findings8 = Analyzer.analyze(source8, "modules/foo.lua", r5, cfg)
assert_eq(#findings8, 1, "control: tonumber still emits finding")

print("safe sink test passed")

-- Test: every unwrap call produces a review finding
local r6 = Registry.new()
r6:addSource("C_Spell.GetSpellCharges")

local source9 = [[
local info = C_Spell.GetSpellCharges(1)
local n = Helpers.SafeValue(info, 0)
return n
]]
local findings9 = Analyzer.analyze(source9, "modules/foo.lua", r6, cfg)
assert_eq(#findings9, 1, "one review finding for unwrap call")
assert_eq(findings9[1].severity, "review", "review tier")
assert_eq(findings9[1].sink, "<unwrap>", "unwrap sink label")
assert_eq(findings9[1].source_function, "Helpers.SafeValue", "unwrap name in source_function")

-- Test: post-unwrap, value is untainted (no further finding on read)
local source10 = [[
local info = C_Spell.GetSpellCharges(1)
local n = Helpers.SafeToNumber(info, 0)
local m = n + 1
return m
]]
local findings10 = Analyzer.analyze(source10, "modules/foo.lua", r6, cfg)
assert_eq(#findings10, 1, "only the review finding; no arith finding on n")
assert_eq(findings10[1].severity, "review", "review tier")

print("unwrap test passed")

-- Test: guard untaints in then-branch
local r7 = Registry.new()
r7:addSource("C_Spell.GetSpellCharges")

local source11 = [[
local info = C_Spell.GetSpellCharges(1)
if not Helpers.IsSecretValue(info) then
    local n = info + 1
    return n
end
return 0
]]
local findings11 = Analyzer.analyze(source11, "modules/foo.lua", r7, cfg)
assert_eq(#findings11, 0, "guard makes arith on info safe in then-branch")

-- Test: guard untaints in else-branch
local source12 = [[
local info = C_Spell.GetSpellCharges(1)
if Helpers.IsSecretValue(info) then
    return 0
else
    local n = info + 1
    return n
end
]]
local findings12 = Analyzer.analyze(source12, "modules/foo.lua", r7, cfg)
assert_eq(#findings12, 0, "guard untaints in else-branch")

-- Test: after the if/end, taint is restored (union of branches)
local source13 = [[
local info = C_Spell.GetSpellCharges(1)
if not Helpers.IsSecretValue(info) then
    local n = info + 1
end
local m = info + 2
return m
]]
local findings13 = Analyzer.analyze(source13, "modules/foo.lua", r7, cfg)
assert_eq(#findings13, 1, "post-guard read still tainted")

print("guard test passed")

-- Test: HasSecretValue untaints all named-local args in then-branch
local r8 = Registry.new()
r8:addSource("C_Spell.GetSpellCharges")

local source14 = [[
local a = C_Spell.GetSpellCharges(1)
local b = C_Spell.GetSpellCharges(2)
if not Helpers.HasSecretValue(a, b) then
    local sum = a + b
    return sum
end
return 0
]]
local findings14 = Analyzer.analyze(source14, "modules/foo.lua", r8, cfg)
assert_eq(#findings14, 0, "HasSecretValue untaints all locals in then-branch")

print("HasSecretValue guard test passed")

-- Test: trailing annotation suppresses finding
local r9 = Registry.new()
r9:addSource("C_Spell.GetSpellCharges")

local source15 = [[
local info = C_Spell.GetSpellCharges(1)
local n = info + 1  -- @secret-safe: justified for unit test
return n
]]
local findings15 = Analyzer.analyze(source15, "modules/foo.lua", r9, cfg)
-- Default: filter suppressed findings out of the returned list
assert_eq(#findings15, 0, "annotated finding suppressed")

-- Verbose: returns all findings including suppressed
local findings15v = Analyzer.analyze(source15, "modules/foo.lua", r9, cfg,
    { includeSuppressed = true })
assert_eq(#findings15v, 1, "verbose includes suppressed")
assert_eq(findings15v[1].suppressed, true, "marked suppressed")
assert_eq(findings15v[1].suppression_reason, "justified for unit test", "reason captured")

-- Empty reason: harness warning, finding NOT suppressed
local source16 = [[
local info = C_Spell.GetSpellCharges(1)
local n = info + 1  -- @secret-safe:
return n
]]
local findings16, err16, debug16 = Analyzer.analyze(
    source16, "modules/foo.lua", r9, cfg, { exposeDebug = true })
assert_eq(#findings16, 1, "empty-reason annotation does not suppress")
assert(debug16.warnings, "harness warnings present")
assert_eq(#debug16.warnings, 1, "one warning for empty-reason annotation")

print("annotation suppression test passed")

-- Test: t.k = source(); local v = t.k → v is tainted
local r10 = Registry.new()
r10:addSource("C_Spell.GetSpellCharges")

local source17 = [[
local t = {}
t.x = C_Spell.GetSpellCharges(1)
local v = t.x
local n = v + 1
return n
]]
local findings17 = Analyzer.analyze(source17, "modules/foo.lua", r10, cfg)
assert_eq(#findings17, 1, "field-tainted local flows to arith")

-- Test: different field key not affected
local source18 = [[
local t = {}
t.x = C_Spell.GetSpellCharges(1)
t.y = 5
local v = t.y
local n = v + 1
return n
]]
local findings18 = Analyzer.analyze(source18, "modules/foo.lua", r10, cfg)
assert_eq(#findings18, 0, "different field is not tainted")

print("field-sensitivity test passed")

-- Test: stable loop (taint set unchanged across iterations)
local r11 = Registry.new()
r11:addSource("C_Spell.GetSpellCharges")

local source19 = [[
for i = 1, 10 do
    local info = C_Spell.GetSpellCharges(i)
    local n = info + 1
end
return 0
]]
local findings19 = Analyzer.analyze(source19, "modules/foo.lua", r11, cfg)
-- Loop body has one unsafe sink. The two-iteration walk should emit
-- exactly one finding (only the second-pass walk emits, first pass discarded).
assert(#findings19 >= 1, "loop body's unsafe sink found")
assert_eq(findings19[1].sink, "<arith>", "arith sink")

print("loop test passed")

-- Test: while condition walked for sinks
local r12 = Registry.new()
r12:addSource("S")

local sourceL1 = [[
local x = S()
while x > 5 do
    break
end
]]
local fL1 = Analyzer.analyze(sourceL1, "modules/foo.lua", r12, cfg)
assert_eq(#fL1, 1, "while-condition comparison emits")
assert_eq(fL1[1].sink, "<comparison>", "comparison sink")

-- Test: while condition rejects bare tainted truthiness
local sourceL1b = [[
local x = S()
while x do
    break
end
]]
local fL1b = Analyzer.analyze(sourceL1b, "modules/foo.lua", r12, cfg)
assert_eq(#fL1b, 1, "while-condition truthiness emits")
assert_eq(fL1b[1].sink, "<truthiness>", "truthiness sink")

-- Test: numeric-for End bound walked
-- The End expression is a bare VarExpr `x`. There is no registered sink shape
-- for a bare variable used as a loop bound (no comparison/arith/builtin call),
-- so 0 findings is expected. This is a known limitation: tainted values that
-- flow into numeric-for bounds are not caught unless they appear in a sink shape.
local sourceL2 = [[
local x = S()
for i = 1, x do
    break
end
]]
local fL2 = Analyzer.analyze(sourceL2, "modules/foo.lua", r12, cfg)
print("loop header walk tests — numeric-for End bound finding count: " .. #fL2 .. " (0 expected, bare VarExpr is not a sink shape)")
assert_eq(#fL2, 0, "bare tainted VarExpr as loop bound emits no finding (known limitation)")

-- Test: generic-for generator with tainted argument
-- pairs(t) — pairs is in UNSAFE_BUILTIN_FUNCTIONS; called with tainted t.
local sourceL3 = [[
local t = S()
for k, v in pairs(t) do
    break
end
]]
local fL3 = Analyzer.analyze(sourceL3, "modules/foo.lua", r12, cfg)
assert_eq(#fL3, 1, "pairs(tainted) emits one finding")
assert_eq(fL3[1].sink, "pairs", "pairs sink")

print("loop header expression tests passed")

-- Test: file under strict_paths → finding severity = strict
local strictCfg = Config.loadFromString([[
return { strict_paths = { "modules/cdm/" } }
]])

local r13 = Registry.new()
r13:addSource("C_Spell.GetSpellCharges")

local source20 = [[
local info = C_Spell.GetSpellCharges(1)
local n = info + 1
]]
local findings20 = Analyzer.analyze(
    source20, "modules/cdm/cdm_icon_renderer.lua", r13, strictCfg)
assert_eq(#findings20, 1, "one finding")
assert_eq(findings20[1].severity, "strict", "promoted to strict by path")

-- Same source, different path → advisory
local findings21 = Analyzer.analyze(
    source20, "modules/foo.lua", r13, strictCfg)
assert_eq(findings21[1].severity, "advisory", "advisory outside strict path")

-- Unwrap is review regardless of path
local source22 = [[
local info = C_Spell.GetSpellCharges(1)
local n = Helpers.SafeValue(info, 0)
]]
local findings22 = Analyzer.analyze(
    source22, "modules/cdm/cdm_icon_renderer.lua", r13, strictCfg)
assert_eq(findings22[1].severity, "review", "unwrap stays review")

local strictUnwrapCfg = Config.loadFromString([[
return {
    strict_paths = { "modules/cdm/" },
    strict_unwrap_paths = { "modules/cdm/" },
}
]])

local findings23 = Analyzer.analyze(
    source22, "modules/cdm/cdm_icon_renderer.lua", r13, strictUnwrapCfg)
assert_eq(findings23[1].severity, "strict",
    "unwrap is strict under configured CDM unwrap path")

local findings24 = Analyzer.analyze(
    source22, "modules/foo.lua", r13, strictUnwrapCfg)
assert_eq(findings24[1].severity, "review",
    "unwrap remains review outside configured CDM unwrap path")

print("severity test passed")

-- Test: pcall(<source>, ...) recognized as source, taint propagates
local r14 = Registry.new()
r14:addSource("C_Spell.GetSpellCharges")

local sourceP1 = [[
local ok, info = pcall(C_Spell.GetSpellCharges, 123)
local n = info + 1
return n
]]
local fP1 = Analyzer.analyze(sourceP1, "modules/foo.lua", r14, cfg)
assert_eq(#fP1, 1, "pcall(source,...) result is tainted, info+1 emits")

-- Test: xpcall(<source>, handler, ...) recognized too
local sourceP2 = [[
local ok, info = xpcall(C_Spell.GetSpellCharges, somehandler, 123)
local n = info + 1
return n
]]
local fP2 = Analyzer.analyze(sourceP2, "modules/foo.lua", r14, cfg)
assert_eq(#fP2, 1, "xpcall(source,...) result is tainted, info+1 emits")

-- Test: pcall(<non-source>, ...) does NOT taint
local sourceP3 = [[
local ok, info = pcall(some_other_function, 123)
local n = info + 1
return n
]]
local fP3 = Analyzer.analyze(sourceP3, "modules/foo.lua", r14, cfg)
assert_eq(#fP3, 0, "pcall(non-source,...) does NOT taint")

print("pcall source detection test passed")

-- Test: reading a field on a tainted base local is tainted
local r15 = Registry.new()
r15:addSource("C_Spell.GetSpellCharges")

-- Direct: pcall result, then field access
local sourceFB1 = [[
local ok, info = pcall(C_Spell.GetSpellCharges, 123)
local n = info.currentCharges + 1
return n
]]
local fFB1 = Analyzer.analyze(sourceFB1, "modules/foo.lua", r15, cfg)
assert_eq(#fFB1, 1, "info.field+1 emits when info is tainted")
assert_eq(fFB1[1].sink, "<arith>", "arith sink")

-- Bare field-tainted-base read into local, then arith
local sourceFB2 = [[
local info = C_Spell.GetSpellCharges(1)
local n = info.charges
local m = n + 1
return m
]]
local fFB2 = Analyzer.analyze(sourceFB2, "modules/foo.lua", r15, cfg)
assert_eq(#fFB2, 1, "field-of-tainted-base flows through to arith")

-- Field-on-clean-local does NOT taint
local sourceFB3 = [[
local info = { currentCharges = 5 }
local n = info.currentCharges + 1
return n
]]
local fFB3 = Analyzer.analyze(sourceFB3, "modules/foo.lua", r15, cfg)
assert_eq(#fFB3, 0, "field of clean local does not taint")

-- Deep chain: tainted.sub.field
local sourceFB4 = [[
local info = C_Spell.GetSpellCharges(1)
local n = info.sub.field + 1
return n
]]
local fFB4 = Analyzer.analyze(sourceFB4, "modules/foo.lua", r15, cfg)
assert_eq(#fFB4, 1, "deep field chain on tainted base flows")

-- Closure capture: sort/callback predicates must still see tainted upvalues.
local sourceFB5 = [[
local info = C_Spell.GetSpellCharges(1)
table.sort(rows, function(a, b)
    return info.currentCharges < 2
end)
]]
local fFB5 = Analyzer.analyze(sourceFB5, "modules/foo.lua", r15, cfg)
assert_eq(#fFB5, 1, "closure comparison on tainted upvalue emits")
assert_eq(fFB5[1].sink, "<comparison>", "comparison sink in closure")

-- Function parameters shadow tainted outer locals.
local sourceFB6 = [[
local info = C_Spell.GetSpellCharges(1)
local function f(info)
    return info + 1
end
return f(1)
]]
local fFB6 = Analyzer.analyze(sourceFB6, "modules/foo.lua", r15, cfg)
assert_eq(#fFB6, 0, "function parameter shadows tainted upvalue")

print("tainted-base field read test passed")

-- ===========================================================================
-- Secret-returning functions (taint propagates from the return value)
-- ---------------------------------------------------------------------------
-- C_StringUtil formatters accept secret-tagged arguments without erroring
-- (they are safe sinks), but they also RETURN secret-tagged values. The local
-- assigned from such a call must be treated as tainted, so downstream
-- comparisons like `s == "0"` get flagged. Closes the analyzer gap that hid
-- the live taint crash at damage_meter.lua:906.
-- ===========================================================================

local rSR = Registry.new()

-- Assignment from a secret-returning safe sink taints the LHS.
local srcSR1 = [[
local s = C_StringUtil.TruncateWhenZero(123)
return s
]]
local _fSR1, _eSR1, dSR1 = Analyzer.analyze(
    srcSR1, "modules/foo.lua", rSR, cfg, { exposeDebug = true })
assert(dSR1.taintedAt.s, "s tainted by C_StringUtil.TruncateWhenZero return")

-- Comparison on a secret-returning call's result emits a <comparison> finding.
local srcSR2 = [[
local s = C_StringUtil.TruncateWhenZero(123)
if s == "0" then return end
return 1
]]
local fSR2 = Analyzer.analyze(srcSR2, "modules/foo.lua", rSR, cfg)
assert_eq(#fSR2, 1, "comparison on secret-returning result emits one finding")
assert_eq(fSR2[1].sink, "<comparison>", "sink labeled comparison")

-- Existing safe-sink behavior preserved: passing a tainted arg into the same
-- function does not emit a finding for that argument-passing step.
local rSR3 = Registry.new()
rSR3:addSource("C_Spell.GetSpellInfo")
local srcSR3 = [[
local info = C_Spell.GetSpellInfo(1)
local s = C_StringUtil.TruncateWhenZero(info)
return s
]]
local fSR3 = Analyzer.analyze(srcSR3, "modules/foo.lua", rSR3, cfg)
assert_eq(#fSR3, 0, "passing tainted into safe-sink does not emit at call site")

-- Pipeline: SetText(C_StringUtil.TruncateWhenZero(secret)) is fully safe —
-- the SetText safe-sink method consumes the secret return inline.
local srcSR4 = [[
local info = C_Spell.GetSpellInfo(1)
frame:SetText(C_StringUtil.TruncateWhenZero(info))
]]
local fSR4 = Analyzer.analyze(srcSR4, "modules/foo.lua", rSR3, cfg)
assert_eq(#fSR4, 0, "SetText consumes secret-returning result safely")

-- Arithmetic on a secret-returning result emits an <arith> finding.
local srcSR5 = [[
local s = C_StringUtil.RoundToNearestString(100, 10)
local n = s + 1
return n
]]
local fSR5 = Analyzer.analyze(srcSR5, "modules/foo.lua", rSR, cfg)
assert_eq(#fSR5, 1, "arith on secret-returning result emits one finding")
assert_eq(fSR5[1].sink, "<arith>", "sink labeled arith")

-- Guard on the secret-returning result clears taint in the safe branch.
local srcSR6 = [[
local s = C_StringUtil.TruncateWhenZero(1)
if not Helpers.IsSecretValue(s) then
    if s == "0" then return end
end
return 1
]]
local fSR6 = Analyzer.analyze(srcSR6, "modules/foo.lua", rSR, cfg)
assert_eq(#fSR6, 0, "guard untaints secret-returning result in then-branch")

print("secret-returning test passed")

-- ---------------------------------------------------------------------------
-- Precondition-guarded API scan (<precondition>, review tier)
-- ---------------------------------------------------------------------------
local rPre = Registry.new()
rPre:addPreconditionAPI("C_UnitAuras.GetUnitAuras", { "RequiresUnitAuraAccess" })

local function preFindings(findings)
    local out = {}
    for _, f in ipairs(findings or {}) do
        if f.sink == "<precondition>" then out[#out + 1] = f end
    end
    return out
end

-- Raw call in an ungated function -> one review finding
local srcP1 = [[
local function scan(unit)
    local auras = C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    return auras
end
return scan
]]
local fP1 = preFindings(Analyzer.analyze(srcP1, "modules/foo.lua", rPre, cfg))
assert_eq(#fP1, 1, "raw guarded call flagged")
assert_eq(fP1[1].severity, "review", "precondition finding is review tier")
assert_eq(fP1[1].source_function, "C_UnitAuras.GetUnitAuras", "source names the API")

-- pcall'd function REFERENCE -> no finding (not a CallExpr)
local srcP2 = [[
local function scan(unit)
    local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, "HELPFUL")
    return ok and auras
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP2, "modules/foo.lua", rPre, cfg)), 0,
    "pcall function-reference not flagged")

-- Call inside a pcall'd closure -> protected, no finding
local srcP3 = [[
local function scan(unit)
    local ok = pcall(function()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end)
    return ok
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP3, "modules/foo.lua", rPre, cfg)), 0,
    "pcall-protected closure not flagged")

-- Gate consulted BEFORE the call in the same function scope -> no finding
local srcP4 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP4, "modules/foo.lua", rPre, cfg)), 0,
    "gate in same scope not flagged")

-- Gate in an OUTER function scope covers nested closures (lexical inherit)
local srcP5 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    local function inner()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
    return inner()
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP5, "modules/foo.lua", rPre, cfg)), 0,
    "outer-scope gate covers nested closure")

-- Gate in a SIBLING function does NOT cover (non-interprocedural)
local srcP6 = [[
local function gated()
    return C_Secrets.ShouldAurasBeSecret()
end
local function scan(unit)
    if gated() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP6, "modules/foo.lua", rPre, cfg)), 1,
    "sibling-function gate does not cover (needs @secret-safe annotation)")

-- @secret-safe annotation suppresses the finding
local srcP7 = [[
local function scan(unit)
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL") -- @secret-safe: caller gates
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP7, "modules/foo.lua", rPre, cfg)), 0,
    "@secret-safe suppresses precondition finding")

-- Unregistered API never flags
local srcP8 = [[
local function scan(unit)
    return C_UnitAuras.GetAuraDataBySpellName(unit, "Rejuvenation")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP8, "modules/foo.lua", rPre, cfg)), 0,
    "unregistered API not flagged")

-- Gate consulted AFTER the call -> flagged (the walk is statement-ordered;
-- a gate below the call cannot have protected it)
do
local srcP9 = [[
local function scan(unit)
    local auras = C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    return auras
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP9, "modules/foo.lua", rPre, cfg)), 1,
    "gate below the call does not protect it")

-- Guarded CALL in a non-first pcall argument -> flagged (evaluated before
-- pcall takes over; only argument 1 is protected)
end
do
local srcP10 = [[
local function scan(unit)
    local ok = pcall(print, C_UnitAuras.GetUnitAuras(unit, "HELPFUL"))
    return ok
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP10, "modules/foo.lua", rPre, cfg)), 1,
    "guarded call in outer pcall argument position flagged")

-- Positive gate clause + call in the ELSE branch -> not flagged: the else
-- of a single positive-gate if runs only when UNRESTRICTED
end
do
local srcP11 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then
        return nil
    else
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP11, "modules/foo.lua", rPre, cfg)), 0,
    "else branch of a positive gate is the unrestricted path")

-- Ordering applies inside nested blocks too: gate above the call in a loop
-- body is clean; a later sibling statement after the gated one stays gated
end
do
local srcP12 = [[
local function scan(units)
    for i = 1, #units do
        if C_Secrets.ShouldAurasBeSecret() then return nil end
        local auras = C_UnitAuras.GetUnitAuras(units[i], "HELPFUL")
        if auras then return auras end
    end
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP12, "modules/foo.lua", rPre, cfg)), 0,
    "gate above the call inside a nested block protects it")

-- Ignored gate result -> no protection (nothing branches on it)
end
do
local srcP14 = [[
local function scan(unit)
    local x = C_Secrets.ShouldAurasBeSecret()
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP14, "modules/foo.lua", rPre, cfg)), 1,
    "gate with ignored result does not protect")

-- Non-terminating positive branch -> no dominance for later statements
end
do
local srcP15 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then
        print("restricted")
    end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP15, "modules/foo.lua", rPre, cfg)), 1,
    "non-terminating gate branch does not protect later calls")

-- INVERTED gate: guarded call inside the RESTRICTED branch -> flagged (it
-- is a guaranteed hard error there)
end
do
local srcP16 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
    return nil
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP16, "modules/foo.lua", rPre, cfg)), 1,
    "guarded call inside the restricted branch flagged")

-- Negated gate: the then-branch is the unrestricted path -> clean
end
do
local srcP17 = [[
local function scan(unit)
    if not C_Secrets.ShouldAurasBeSecret() then
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
    return nil
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP17, "modules/foo.lua", rPre, cfg)), 0,
    "negated gate then-branch is the unrestricted path")

-- The authored `and`-chain idiom keeps working
end
do
local srcP18 = [[
local function scan(unit)
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        return nil
    end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP18, "modules/foo.lua", rPre, cfg)), 0,
    "and-chain positive gate with terminating body dominates")

-- pcall(API()) evaluates the call BEFORE pcall runs -> flagged
end
do
local srcP19 = [[
local function scan(unit)
    local ok = pcall(C_UnitAuras.GetUnitAuras(unit, "HELPFUL"))
    return ok
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP19, "modules/foo.lua", rPre, cfg)), 1,
    "call expression in pcall argument 1 evaluates unprotected")

-- File-local alias of a guarded API -> resolved and flagged
end
do
local srcP20 = [[
local GetAuras = C_UnitAuras.GetUnitAuras
local function scan(unit)
    return GetAuras(unit, "HELPFUL")
end
return scan
]]
local fP20 = preFindings(Analyzer.analyze(srcP20, "modules/foo.lua", rPre, cfg))
assert_eq(#fP20, 1, "aliased guarded call flagged")
assert_eq(fP20[1].source_function, "C_UnitAuras.GetUnitAuras",
    "alias finding names the canonical API")

-- Aliased call behind a proper gate stays clean
end
do
local srcP21 = [[
local GetAuras = C_UnitAuras.GetUnitAuras
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    return GetAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP21, "modules/foo.lua", rPre, cfg)), 0,
    "gated aliased call not flagged")

-- UNSOUND elseif: an earlier clause's true-path skips the gate entirely —
-- only clause 1 can prove dominance (2026-07 round-3)
end
do
local srcP23 = [[
local function scan(unit, mode)
    if mode == "off" then
        print("off")
    elseif C_Secrets.ShouldAurasBeSecret() then
        return nil
    end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP23, "modules/foo.lua", rPre, cfg)), 1,
    "elseif gate does not dominate (earlier clause can skip it)")

-- `gate() == true` bail dominates
end
do
local srcP24 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() == true then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP24, "modules/foo.lua", rPre, cfg)), 0,
    "gate() == true bail dominates")

-- `gate() or X` bail dominates: restricted implies the disjunction is true
end
do
local srcP25 = [[
local function scan(unit, cached)
    if C_Secrets.ShouldAurasBeSecret() or cached then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP25, "modules/foo.lua", rPre, cfg)), 0,
    "gate-or-X bail dominates (restricted implies condition true)")

-- ...but the BODY of a gate-or-X condition is restricted-reachable: a
-- guarded call inside it flags
end
do
local srcP26 = [[
local function scan(unit, fallback)
    if C_Secrets.ShouldAurasBeSecret() or fallback then
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP26, "modules/foo.lua", rPre, cfg)), 1,
    "guarded call in a restricted-reachable or-branch flagged")

-- Later-callback: a closure passed to an arbitrary call ESCAPES the gate —
-- it can run under a different restriction state
end
do
local srcP27 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    C_Timer.After(0, function()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end)
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP27, "modules/foo.lua", rPre, cfg)), 1,
    "escaping closure does not inherit the registration-site gate")

-- Arbitrary conjunct must NOT establish dominance: `someFlag and gate()`
-- can be false while restricted (2026-07 round-4)
end
do
local srcP28 = [[
local function scan(unit, someFlag)
    if someFlag and C_Secrets.ShouldAurasBeSecret() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP28, "modules/foo.lua", rPre, cfg)), 1,
    "arbitrary conjunct does not flip (flag false + restricted slips through)")

-- Unmodeled comparison grants nothing: `gate() ~= nil` is always true
end
do
local srcP29 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() ~= nil then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP29, "modules/foo.lua", rPre, cfg)), 1,
    "unmodeled gate comparison stays ungated")

-- Named callback escape: a local function passed as a call argument runs
-- later — the definition-time gate proves nothing
end
do
local srcP30 = [[
local f = CreateFrame("Frame")
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    local function onEvent(self, event, unit2)
        return C_UnitAuras.GetUnitAuras(unit2, "HELPFUL")
    end
    f:SetScript("OnEvent", onEvent)
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP30, "modules/foo.lua", rPre, cfg)), 1,
    "escaped named callback does not inherit the definition-time gate")

-- ...but a named local only ever CALLED synchronously still inherits (srcP5
-- shape) — covered by srcP5 above; re-assert with the escape prepass active
assert_eq(#preFindings(Analyzer.analyze(srcP5, "modules/foo.lua", rPre, cfg)), 0,
    "synchronously-called named local still inherits the gate")

-- Guarded alias init: `local Get = C_UnitAuras and C_UnitAuras.GetUnitAuras`
end
do
local srcP31 = [[
local GetAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras
local function scan(unit)
    return GetAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP31, "modules/foo.lua", rPre, cfg)), 1,
    "guarded alias init resolved and flagged")

-- Alias chain: `local A = api; local B = A; B()`
end
do
local srcP32 = [[
local A = C_UnitAuras.GetUnitAuras
local B = A
local function scan(unit)
    return B(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP32, "modules/foo.lua", rPre, cfg)), 1,
    "alias chain resolved and flagged")

-- Namespace alias: `local UA = C_UnitAuras; UA.GetUnitAuras()`
end
do
local srcP33 = [[
local UA = C_UnitAuras
local function scan(unit)
    return UA.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP33, "modules/foo.lua", rPre, cfg)), 1,
    "namespace alias resolved and flagged")

-- Gate aliases keep protection working: aliased gate function AND aliased
-- gate namespace both recognized (the repo's `local _C_ShouldAurasBeSecret =
-- C_Secrets and C_Secrets.ShouldAurasBeSecret` idiom)
end
do
local srcP34 = [[
local isSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret
local function scan(unit)
    if isSecret() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP34, "modules/foo.lua", rPre, cfg)), 0,
    "aliased gate function still dominates")

end
do
local srcP35 = [[
local S = C_Secrets
local function scan(unit)
    if S and S.ShouldAurasBeSecret and S.ShouldAurasBeSecret() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#preFindings(Analyzer.analyze(srcP35, "modules/foo.lua", rPre, cfg)), 0,
    "gate through a namespace alias still dominates")

-- strict_precondition_paths promotes precondition findings to strict
end
do
local cfgStrictLib = Config.loadFromString(
    "return { strict_precondition_paths = { 'libs/' } }")
local fP22 = preFindings(Analyzer.analyze(srcP1, "libs/SomeLib/foo.lua", rPre, cfgStrictLib))
assert_eq(#fP22, 1, "strict-precondition path still finds the raw call")
assert_eq(fP22[1].severity, "strict", "precondition finding promoted to strict")

end
do
-- preconditionOnly mode (vendored-lib coverage): the taint pass is skipped,
-- the raw guarded-call scan still runs
end
do
local srcP13 = [[
local function scan(unit)
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
local fP13 = Analyzer.analyze(srcP13, "libs/foo.lua", rPre, cfg, { preconditionOnly = true })
local preP13 = preFindings(fP13)
assert_eq(#preP13, 1, "preconditionOnly: guarded call still flagged")
assert_eq(#fP13, #preP13, "preconditionOnly: no non-precondition findings emitted")

end
print("precondition scan test passed")

-- ---------------------------------------------------------------------------
-- Secret event payload seeding (config event_payload_params)
-- ---------------------------------------------------------------------------
do
local rEvt = Registry.new()
rEvt:addSecretPayloadEvent("UNIT_AURA", { 4 })

-- Handler detected by its event-name comparison: configured param position 4
-- (updateInfo) is a taint source; position 3 (unit) is not.
local srcE1 = [[
local f = CreateFrame("Frame")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    if event == "UNIT_AURA" then
        print(unit)
        print(updateInfo)
    end
end)
]]
local fE1 = Analyzer.analyze(srcE1, "modules/foo.lua", rEvt, cfg)
assert_eq(#fE1, 1, "secret event payload param flagged at sink (unit param stays clean)")

-- Handler for a non-secret event: nothing seeded
local srcE2 = [[
local f = CreateFrame("Frame")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    if event == "PLAYER_LOGIN" then
        print(updateInfo)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcE2, "modules/foo.lua", rEvt, cfg), 0,
    "non-secret event handler not seeded")

-- Registry without configured events: no seeding at all
assert_eq(#Analyzer.analyze(srcE1, "modules/foo.lua", rPre, cfg), 0,
    "no event_payload_params config, no seeding")

end
print("secret event payload test passed")

-- Aspect + direct-use test blocks live in one do…end scope: the main chunk
-- was brushing Lua 5.1's 200-local limit, and block scoping frees these
-- locals' registers at the closing end.
do
-- Test: aspect-returning widget getters (secretReturnsForAspect) taint their
-- results ONLY inside config aspect_paths.
local rAsp = Registry.new()
rAsp:addAspectReturningMethod("GetAlpha", { "Alpha" })

local cfgAsp = Config.loadFromString([[return {
    aspect_paths = { "QUI_CDM/" },
}]])

local srcAsp = [[
local icon = GetIcon()
local a = icon:GetAlpha()
if a > 0.5 then return end
]]

-- Inside an aspect path: comparison on the getter result is flagged
local fAsp1 = Analyzer.analyze(srcAsp, "QUI_CDM/cdm/foo.lua", rAsp, cfgAsp)
assert_eq(#fAsp1, 1, "aspect getter result comparison flagged inside aspect_paths")

-- Outside aspect paths: same source, registry auto-stripped, nothing fires
local fAsp2 = Analyzer.analyze(srcAsp, "modules/foo.lua", rAsp, cfgAsp)
assert_eq(#fAsp2, 0, "aspect getter inert outside aspect_paths")

-- Empty aspect_paths (defaults): inert everywhere
local fAsp3 = Analyzer.analyze(srcAsp, "QUI_CDM/cdm/foo.lua", rAsp, cfg)
assert_eq(#fAsp3, 0, "aspect getter inert with default (empty) aspect_paths")

-- Piping the getter result straight into a safe sink stays clean
local srcAspSink = [[
local icon = GetIcon()
local other = GetOther()
other:SetAlpha(icon:GetAlpha())
]]
local rAspSink = Registry.new()
rAspSink:addAspectReturningMethod("GetAlpha", { "Alpha" })
assert_eq(#Analyzer.analyze(srcAspSink, "QUI_CDM/cdm/foo.lua", rAspSink, cfgAsp), 0,
    "aspect getter piped to C-side sink is clean")

print("aspect getter test passed")

-- Test: DIRECT source-call operands (no intermediate local) are flagged in
-- comparisons, unary ops, and unsafe-builtin arguments.
local rDirect = Registry.new()
rDirect:addSource("C_Spell.GetSpellCastCount")
rDirect:addAspectReturningMethod("GetAlpha", { "Alpha" })
rDirect:addAspectReturningMethod("IsShown", { "Shown" })

local srcDirect = [[
local icon = GetIcon()
if icon:GetAlpha() > 0.5 then return end
]]
assert_eq(#Analyzer.analyze(srcDirect, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "direct aspect-getter comparison flagged (no intermediate local)")

local srcDirectNot = [[
local icon = GetIcon()
if not icon:IsShown() then return end
]]
assert_eq(#Analyzer.analyze(srcDirectNot, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "direct aspect-getter under unary not flagged")

local srcDirectBuiltin = [[
local icon = GetIcon()
local s = tostring(icon:GetAlpha())
]]
assert_eq(#Analyzer.analyze(srcDirectBuiltin, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "direct aspect-getter passed to unsafe builtin flagged")

-- Dotted sources get the same direct-use coverage
local srcDirectDotted = [[
if C_Spell.GetSpellCastCount(61304) > 0 then return end
]]
assert_eq(#Analyzer.analyze(srcDirectDotted, "modules/foo.lua", rDirect, cfgAsp), 1,
    "direct dotted-source comparison flagged")

-- Outside aspect_paths the getters stay inert even in direct use
assert_eq(#Analyzer.analyze(srcDirect, "modules/foo.lua", rDirect, cfgAsp), 0,
    "direct aspect-getter inert outside aspect_paths")

print("direct source-call use test passed")

-- Test: BARE direct source-call truthiness (`if icon:IsShown() then`) —
-- result truth-tested without ever landing in a local.
local srcBareIf = [[
local icon = GetIcon()
if icon:IsShown() then return end
]]
assert_eq(#Analyzer.analyze(srcBareIf, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "bare aspect-getter if-condition flagged")
assert_eq(#Analyzer.analyze(srcBareIf, "modules/foo.lua", rDirect, cfgAsp), 0,
    "bare aspect-getter if-condition inert outside aspect_paths")

local srcBareWhile = [[
local icon = GetIcon()
while icon:IsShown() do DoThing() end
]]
assert_eq(#Analyzer.analyze(srcBareWhile, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "bare aspect-getter while-condition flagged")

local srcBareRepeat = [[
local icon = GetIcon()
repeat DoThing() until icon:IsShown()
]]
assert_eq(#Analyzer.analyze(srcBareRepeat, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "bare aspect-getter until-condition flagged")

-- Compound condition: exactly ONE finding (binop path), no double-emit
local srcCompound = [[
local icon = GetIcon()
local ready = IsReady()
if ready and icon:IsShown() then return end
]]
assert_eq(#Analyzer.analyze(srcCompound, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "compound condition emits exactly once")

-- Guard predicates as bare conditions stay clean (not sources)
local srcGuardCond = [[
local v = GetValue()
if IsSecretValue(v) then return end
]]
assert_eq(#Analyzer.analyze(srcGuardCond, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 0,
    "guard call as bare condition not flagged")

print("bare truthiness test passed")

-- Test: protected-call probes are NOT flagged — in expression context
-- pcall/xpcall truncate to the clean ok boolean.
local srcPcallIf = [[
if pcall(C_Spell.GetSpellCastCount, 61304) then return end
]]
assert_eq(#Analyzer.analyze(srcPcallIf, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 0,
    "bare pcall(source) if-condition stays clean")

local srcPcallNot = [[
if not pcall(C_Spell.GetSpellCastCount, 61304) then return end
]]
assert_eq(#Analyzer.analyze(srcPcallNot, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 0,
    "not pcall(source) stays clean")

local srcPcallBinop = [[
local usable = pcall(C_Spell.GetSpellCastCount, 61304) == true
]]
assert_eq(#Analyzer.analyze(srcPcallBinop, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 0,
    "pcall(source) == true comparison stays clean")

-- Protected call in LAST argument position spills every return into the
-- builtin — the secret returns reach it, so this must flag.
local srcPcallSpillBuiltin = [[
print(pcall(C_Spell.GetSpellCastCount, 61304))
]]
assert_eq(#Analyzer.analyze(srcPcallSpillBuiltin, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "pcall(source) spilling into builtin (last arg) flagged")

-- Non-last position truncates to the clean ok boolean.
local srcPcallTruncBuiltin = [[
print(pcall(C_Spell.GetSpellCastCount, 61304), "tail")
]]
assert_eq(#Analyzer.analyze(srcPcallTruncBuiltin, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 0,
    "pcall(source) truncated by non-last builtin position stays clean")

-- Parentheses truncate to one value even in last position.
local srcPcallParens = [[
print((pcall(C_Spell.GetSpellCastCount, 61304)))
]]
assert_eq(#Analyzer.analyze(srcPcallParens, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 0,
    "parenthesized pcall(source) in last position stays clean")

-- Multi-assignment spill still taints: the protected function's returns land
-- in the second local.
local srcPcallSpill = [[
local ok, v = pcall(C_Spell.GetSpellCastCount, 61304)
if v > 0 then return end
]]
assert_eq(#Analyzer.analyze(srcPcallSpill, "QUI_CDM/cdm/foo.lua", rDirect, cfgAsp), 1,
    "pcall multi-assign spill still tainted at comparison")

print("protected-call probe test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6 precondition soundness: prior-clause proofs, compound-else,
-- poisoned aliases, returned/stored callbacks
-- ---------------------------------------------------------------------------
do
local rPre6 = Registry.new()
rPre6:addPreconditionAPI("C_UnitAuras.GetUnitAuras", { "RequiresUnitAuraAccess" })
local function pre(findings)
    local out = {}
    for _, f in ipairs(findings or {}) do
        if f.sink == "<precondition>" then out[#out + 1] = f end
    end
    return out
end

-- elseif after a gate-bearing first clause: reaching it means the gate
-- evaluated FALSE -> unrestricted -> clean (was a false positive).
local src1 = [[
local function scan(unit, mode)
    if C_Secrets.ShouldAurasBeSecret() then
        return nil
    elseif mode == "full" then
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
    return nil
end
return scan
]]
assert_eq(#pre(Analyzer.analyze(src1, "modules/foo.lua", rPre6, cfg)), 0,
    "elseif after positive gate clause is unrestricted-proven")

-- else of a BARE positive gate stays protected (regression guard).
local src2 = [[
local function scan(unit)
    if C_Secrets.ShouldAurasBeSecret() then
        return nil
    else
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
end
return scan
]]
assert_eq(#pre(Analyzer.analyze(src2, "modules/foo.lua", rPre6, cfg)), 0,
    "else of bare positive gate stays protected")

-- else of a COMPOUND `gate() and ready` is restricted-REACHABLE
-- (gate true + ready false) -> flagged (was a false negative).
local src3 = [[
local function scan(unit, ready)
    if C_Secrets.ShouldAurasBeSecret() and ready then
        return nil
    else
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
end
return scan
]]
assert_eq(#pre(Analyzer.analyze(src3, "modules/foo.lua", rPre6, cfg)), 1,
    "else of compound gate-and-flag condition is restricted-reachable")

-- ANY prior gate clause proves later clauses, even with a non-gate first
-- clause: reaching clause 3 / else means the clause-2 gate evaluated false.
local src4 = [[
local function scan(unit, mode)
    if mode == "off" then
        return nil
    elseif C_Secrets.ShouldAurasBeSecret() then
        return nil
    elseif mode == "full" then
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    else
        return C_UnitAuras.GetUnitAuras(unit, "HARMFUL")
    end
end
return scan
]]
assert_eq(#pre(Analyzer.analyze(src4, "modules/foo.lua", rPre6, cfg)), 0,
    "any prior gate-bearing clause protects later clauses and else")

-- Poisoned gate alias: the alias name is rebound elsewhere in the file, so
-- it must not grant protection (round-6: file-scope union suppressed real
-- findings through scope-blind aliases).
local src5 = [[
local isSecret = C_Secrets.ShouldAurasBeSecret
local function other()
    local isSecret = function() return false end
    return isSecret()
end
local function scan(unit)
    if isSecret() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan, other
]]
assert_eq(#pre(Analyzer.analyze(src5, "modules/foo.lua", rPre6, cfg)), 1,
    "rebound gate alias is poisoned and grants no protection")

-- Un-conflicted alias keeps protecting (regression guard for poisoning).
local src6 = [[
local isSecret = C_Secrets.ShouldAurasBeSecret
local function scan(unit)
    if isSecret() then return nil end
    return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
end
return scan
]]
assert_eq(#pre(Analyzer.analyze(src6, "modules/foo.lua", rPre6, cfg)), 0,
    "un-conflicted gate alias still protects")

-- RETURNED closure escapes the definition-time gate.
local src7 = [[
local function make(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    return function()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
end
return make
]]
assert_eq(#pre(Analyzer.analyze(src7, "modules/foo.lua", rPre6, cfg)), 1,
    "returned closure does not inherit the definition-time gate")

-- TABLE-STORED closure escapes the definition-time gate.
local src8 = [[
local function make(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    local handlers = {
        scan = function()
            return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
        end,
    }
    return handlers
end
return make
]]
assert_eq(#pre(Analyzer.analyze(src8, "modules/foo.lua", rPre6, cfg)), 1,
    "table-stored closure does not inherit the definition-time gate")

-- ASSIGNED (module-export) closure escapes the definition-time gate.
local src9 = [[
local M = {}
local function setup(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    M.scan = function()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
end
return setup, M
]]
assert_eq(#pre(Analyzer.analyze(src9, "modules/foo.lua", rPre6, cfg)), 1,
    "assigned closure does not inherit the definition-time gate")

-- Named local function STORED into a table escapes too.
local src10 = [[
local M = {}
local function setup(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    local function scan()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
    M.scan = scan
end
return setup, M
]]
assert_eq(#pre(Analyzer.analyze(src10, "modules/foo.lua", rPre6, cfg)), 1,
    "stored named callback does not inherit the definition-time gate")

-- Synchronously-called local closure still inherits (regression guard).
local src11 = [[
local function setup(unit)
    if C_Secrets.ShouldAurasBeSecret() then return nil end
    local function scan()
        return C_UnitAuras.GetUnitAuras(unit, "HELPFUL")
    end
    return scan()
end
return setup
]]
assert_eq(#pre(Analyzer.analyze(src11, "modules/foo.lua", rPre6, cfg)), 0,
    "synchronously-called local function still inherits the gate")

print("round-6 precondition soundness test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6 secret-event detection: RegisterEvent linkage, vararg spill,
-- dispatch-branch overtaint
-- ---------------------------------------------------------------------------
do
local rEvt6 = Registry.new()
rEvt6:addSecretPayloadEvent("UNIT_AURA", { 4 })

-- Single-event frame: handler never compares the event name but the frame
-- registers a secret event -> payload position seeded via linkage.
local srcL1 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcL1, "modules/foo.lua", rEvt6, cfg), 1,
    "RegisterEvent-linked handler seeded without event-name comparison")

-- Same linkage through a NAMED local handler.
local srcL2 = [[
local f = CreateFrame("Frame")
local function OnEvent(self, event, unit, updateInfo)
    print(updateInfo)
end
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", OnEvent)
]]
assert_eq(#Analyzer.analyze(srcL2, "modules/foo.lua", rEvt6, cfg), 1,
    "RegisterEvent linkage resolves named local handlers")

-- Frame registering only NON-secret events: nothing seeded.
local srcL3 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcL3, "modules/foo.lua", rEvt6, cfg), 0,
    "non-secret RegisterEvent seeds nothing")

-- Vararg spill: configured position 4 lands in `...`; the spill's second
-- local is tainted, the first (unit, position 3) is not.
local srcL4 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    local unit, updateInfo = ...
    print(unit)
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcL4, "modules/foo.lua", rEvt6, cfg), 1,
    "vararg spill taints the configured payload position only")

-- Dispatch overtaint: payload use inside a branch for a DIFFERENT,
-- non-secret event stays clean; the secret-event branch still flags.
local srcL5 = [[
local f = CreateFrame("Frame")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    if event == "UNIT_AURA" then
        print(updateInfo)
    elseif event == "PLAYER_ENTERING_WORLD" then
        print(updateInfo)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcL5, "modules/foo.lua", rEvt6, cfg), 1,
    "non-secret dispatch branch untainted; secret branch still flags")

-- After the dispatch, taint is restored (branch union) — a tail read flags.
-- (RegisterEvent linkage detects the handler; the only comparison is against
-- a non-secret event.)
local srcL6 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    if event == "PLAYER_ENTERING_WORLD" then
        print("clean here")
    end
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcL6, "modules/foo.lua", rEvt6, cfg), 1,
    "taint restored after the dispatch branch (union)")

print("round-6 secret-event detection test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6 probe idiom + dispatch-branch spill suppression
-- ---------------------------------------------------------------------------
do
local rP6b = Registry.new()
rP6b:addSource("C_Spell.GetSpellCharges")

-- Compound probe: `x and issecretvalue and issecretvalue(x)` is the guard
-- idiom, not a tainted truth-test.
local srcG1 = [[
local info = C_Spell.GetSpellCharges(1)
if info and issecretvalue and issecretvalue(info) then
    info = nil
end
]]
assert_eq(#Analyzer.analyze(srcG1, "modules/foo.lua", rP6b, cfg), 0,
    "compound issecretvalue probe idiom not flagged")

-- An arbitrary extra conjunct disqualifies the probe shape: no guard
-- untaint applies, so the local is still tainted downstream (the truth-test
-- itself is an engine-legal existence check and no longer emits).
local srcG2 = [[
local info = C_Spell.GetSpellCharges(1)
local other = GetOther()
if info and other and issecretvalue(info) then
    info = nil
end
print(info)
]]
local fG2 = Analyzer.analyze(srcG2, "modules/foo.lua", rP6b, cfg)
assert_eq(#fG2, 1, "probe with unrelated conjunct grants no untaint (downstream flags)")
assert_eq(fG2[1].sink, "print", "the downstream sink is the finding")

local rEvt6b = Registry.new()
rEvt6b:addSecretPayloadEvent("UNIT_AURA", { 3, 4 })

-- Vararg spill inside an or-chained dispatch branch for OTHER events stays
-- clean; a spill outside any proving branch still flags.
local srcG3 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        local unit = ...
        if unit == "player" then print("ok") end
    end
end)
]]
assert_eq(#Analyzer.analyze(srcG3, "modules/foo.lua", rEvt6b, cfg), 0,
    "spill inside or-chained non-secret dispatch branch stays clean")

local srcG4 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    local unit = ...
    if unit == "player" then print("ok") end
end)
]]
assert_eq(#Analyzer.analyze(srcG4, "modules/foo.lua", rEvt6b, cfg), 1,
    "spill outside a proving branch still flags")

print("round-6 probe idiom + spill suppression test passed")
end

-- RegisterUnitEvent links handlers the same way as RegisterEvent.
do
local rEvt6c = Registry.new()
rEvt6c:addSecretPayloadEvent("UNIT_AURA", { 4 })
local srcRU = [[
local f = CreateFrame("Frame")
f:RegisterUnitEvent("UNIT_AURA", "player", "target")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcRU, "modules/foo.lua", rEvt6c, cfg), 1,
    "RegisterUnitEvent linkage seeds the handler")
print("round-6 RegisterUnitEvent linkage test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6b false-negative fixes: independent re-taint vs dispatch untaint,
-- assignment-statement vararg spill, select() extraction
-- ---------------------------------------------------------------------------
do
local r6b = Registry.new()
r6b:addSecretPayloadEvent("UNIT_AURA", { 3, 4 })
r6b:addSource("C_UnitAuras.GetUnitAuras")

-- A payload param re-tainted from an INDEPENDENT source must survive the
-- non-secret dispatch untaint.
local srcFN1 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    updateInfo = C_UnitAuras.GetUnitAuras("player", "HELPFUL")
    if event == "PLAYER_ENTERING_WORLD" then
        print(updateInfo)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcFN1, "modules/foo.lua", r6b, cfg), 1,
    "independent re-taint survives the dispatch-branch untaint")

-- `...` spill through a plain (non-local) assignment taints like the
-- LocalStatement spill.
local srcFN2 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    local unit, updateInfo
    unit, updateInfo = ...
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcFN2, "modules/foo.lua", r6b, cfg), 1,
    "assignment-statement vararg spill taints configured positions")

-- select(k, ...) extracts secret vararg positions.
local srcFN3 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    local updateInfo = select(2, ...)
    print(updateInfo)
end)
]]
assert_eq(#Analyzer.analyze(srcFN3, "modules/foo.lua", r6b, cfg), 1,
    "select() over secret vararg positions taints the result")

-- select below every secret position stays clean.
local srcFN4 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    local extra = select(3, ...)
    print(extra)
end)
]]
assert_eq(#Analyzer.analyze(srcFN4, "modules/foo.lua", r6b, cfg), 0,
    "select() past every secret position stays clean")

-- select('#', ...) is a count, not a value read.
local srcFN5 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    local n = select("#", ...)
    print(n)
end)
]]
assert_eq(#Analyzer.analyze(srcFN5, "modules/foo.lua", r6b, cfg), 0,
    "select('#', ...) stays clean")

-- Bare `...` handed to an unsafe builtin leaks the payload.
local srcFN6 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    print(...)
end)
]]
assert_eq(#Analyzer.analyze(srcFN6, "modules/foo.lua", r6b, cfg), 1,
    "bare vararg into an unsafe builtin flags")

-- Regression guards: pure event taint still untaints in non-secret dispatch
-- branches, for named params and assignment spills alike.
local srcFN7 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    if event == "PLAYER_ENTERING_WORLD" then
        print(updateInfo)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcFN7, "modules/foo.lua", r6b, cfg), 0,
    "pure event taint still untainted in non-secret dispatch branch")

local srcFN8 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local unit, updateInfo
        unit, updateInfo = ...
        print(updateInfo)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcFN8, "modules/foo.lua", r6b, cfg), 0,
    "assignment spill suppressed inside non-secret dispatch branch")

print("round-6b false-negative fix test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6b false-positive fixes: receiver identity, dynamic select,
-- existence-test idioms, do-block coverage
-- ---------------------------------------------------------------------------
do
local rFp = Registry.new()
rFp:addSecretPayloadEvent("UNIT_AURA", { 3, 4 })

-- Same-named receivers in sibling scopes do not cross-seed.
local srcS1 = [[
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("UNIT_AURA")
    f:SetScript("OnEvent", function(self, event, unit, updateInfo) end)
end
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(self, event, isLogin)
        if isLogin then print("login") end
    end)
end
]]
assert_eq(#Analyzer.analyze(srcS1, "modules/foo.lua", rFp, cfg), 0,
    "shadowed same-name receivers do not cross-seed")

-- A REBOUND receiver drops the old frame's registrations.
local srcS2 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo) end)
f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(self, event, isLogin)
    if isLogin then print("login") end
end)
]]
assert_eq(#Analyzer.analyze(srcS2, "modules/foo.lua", rFp, cfg), 0,
    "rebound receiver does not inherit prior registrations")

-- do-block bodies are walked (previously a total blind spot): linkage AND
-- taint rules apply inside them.
local srcS3 = [[
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("UNIT_AURA")
    f:SetScript("OnEvent", function(self, event, unit, updateInfo)
        print(updateInfo)
    end)
end
]]
assert_eq(#Analyzer.analyze(srcS3, "modules/foo.lua", rFp, cfg), 1,
    "do-block bodies are taint-walked (handler seeded and flagged)")

-- Dynamic-k select loop: call sites clean, the RESULT carries the taint.
local srcS4 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, ...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        print(v)
    end
end)
]]
local fS4 = Analyzer.analyze(srcS4, "modules/foo.lua", rFp, cfg)
assert_eq(#fS4, 1, "dynamic select loop: one finding (the print), not per select site")
assert_eq(fS4[1].sink, "print", "the surviving finding is the actual sink")

local rIdiom = Registry.new()
rIdiom:addSource("C_Spell.GetSpellCharges")
rIdiom:addSource("C_Spell.GetSpellCooldown")

-- `x and x.f` struct guard feeding an unwrap arg: no binop emission.
local srcS5 = [[
local chargeInfo = C_Spell.GetSpellCharges(1)
local cur = SafeToNumber(chargeInfo and chargeInfo.currentCharges, 0)
]]
local rIdiomU = Registry.new()
rIdiomU:addSource("C_Spell.GetSpellCharges")
rIdiomU:addUnwrap("SafeToNumber")
assert_eq(#Analyzer.analyze(srcS5, "modules/foo.lua", rIdiomU, cfg), 1,
    "struct guard into unwrap: only the unwrap review finding remains")

-- `x and Decode(x.f)` guard-before-use: no binop emission.
local srcS6 = [[
local chargeInfo = C_Spell.GetSpellCharges(1)
local active = chargeInfo and Decode(chargeInfo.isActive)
]]
assert_eq(#Analyzer.analyze(srcS6, "modules/foo.lua", rIdiom, cfg), 0,
    "guard-before-call idiom not flagged")

-- `Source() or DEFAULT` fallback: no binop emission, result still tainted.
local srcS7 = [[
local cdInfo = C_Spell.GetSpellCooldown(1) or DEFAULT
local d = cdInfo.duration + 1
]]
local fS7 = Analyzer.analyze(srcS7, "modules/foo.lua", rIdiom, cfg)
assert_eq(#fS7, 1, "source-or-default: only the downstream arith flags")
assert_eq(fS7[1].sink, "<arith>", "downstream arith still caught")

-- `C_X.Fn and C_X.Fn(id)` API-existence guard: no binop emission, result
-- still tainted downstream.
local srcS8 = [[
local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(1)
local d = cdInfo.duration + 1
]]
local fS8 = Analyzer.analyze(srcS8, "modules/foo.lua", rIdiom, cfg)
assert_eq(#fS8, 1, "existence-guarded source call: only the downstream arith flags")

-- Regression: unrelated conjunct with a source call still emits.
local srcS9 = [[
local ready = IsReady()
local x = ready and C_Spell.GetSpellCharges(1)
if x then return end
]]
assert(#Analyzer.analyze(srcS9, "modules/foo.lua", rIdiom, cfg) >= 1,
    "non-guard conjunct with source still emits")

print("round-6b false-positive fix test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6c: value flow through and/or, payload-copy dispatch untaint
-- ---------------------------------------------------------------------------
do
local r6c = Registry.new()
r6c:addSource("C_Spell.GetSpellCharges")

-- Guard-shape into an unsafe builtin: the YIELDED field is tainted.
local srcV1 = [[
local info = C_Spell.GetSpellCharges(1)
print(info and info.currentCharges)
]]
assert_eq(#Analyzer.analyze(srcV1, "modules/foo.lua", r6c, cfg), 1,
    "guard-shape into unsafe builtin flags (value flow)")

-- Guard-shape assignment keeps the taint on the target.
local srcV2 = [[
local info = C_Spell.GetSpellCharges(1)
local cur = info and info.currentCharges
print(cur)
]]
assert_eq(#Analyzer.analyze(srcV2, "modules/foo.lua", r6c, cfg), 1,
    "guard-shape assignment propagates taint (value flow)")

-- Comparison through the guard shape flags.
local srcV3 = [[
local info = C_Spell.GetSpellCharges(1)
if (info and info.currentCharges) > 0 then return end
]]
assert_eq(#Analyzer.analyze(srcV3, "modules/foo.lua", r6c, cfg), 1,
    "comparison over guard shape flags (value flow)")

-- `x and DecodeHelper(x.f)`: a falsy SECRET x is yielded by the and (the
-- index never evaluates on that path), so the decoded target stays tainted —
-- round-6d superseded the earlier struct-assertion shortcut; table-or-nil
-- API contracts use `-- @secret-safe:` instead.
local srcV4 = [[
local info = C_Spell.GetSpellCharges(1)
local active = info and Decode(info.isActive)
if active == true then return end
]]
assert_eq(#Analyzer.analyze(srcV4, "modules/foo.lua", r6c, cfg), 1,
    "decode-helper guard still flags: falsy secret bypasses the index")

-- Truthy tainted lhs flows through `or`.
local srcV5 = [[
local count = C_Spell.GetSpellCharges(1)
local n = count or 0
print(n)
]]
assert_eq(#Analyzer.analyze(srcV5, "modules/foo.lua", r6c, cfg), 1,
    "or-lhs taint flows to the target")

local rEvt6c2 = Registry.new()
rEvt6c2:addSecretPayloadEvent("UNIT_AURA", { 3, 4 })
rEvt6c2:addSource("C_UnitAuras.GetUnitAuras")

-- Payload COPIES join the dispatch untaint set (round-6c FP fix)...
local srcV6 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    local u = unit
    if event == "PLAYER_ENTERING_WORLD" then
        print(u)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcV6, "modules/foo.lua", rEvt6c2, cfg), 0,
    "payload copy untaints in non-secret dispatch branch")

-- ...including param-to-param copies...
local srcV7 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    unit = updateInfo
    if event == "PLAYER_ENTERING_WORLD" then
        print(unit)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcV7, "modules/foo.lua", rEvt6c2, cfg), 0,
    "param-to-param copy stays event taint, untaints in dispatch branch")

-- ...while copies still flag OUTSIDE proving branches...
local srcV8 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    local u = unit
    print(u)
end)
]]
assert_eq(#Analyzer.analyze(srcV8, "modules/foo.lua", rEvt6c2, cfg), 1,
    "payload copy still flags outside a proving branch")

-- ...and INDEPENDENT re-taint still survives the dispatch untaint.
local srcV9 = [[
local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    updateInfo = C_UnitAuras.GetUnitAuras("player", "HELPFUL")
    if event == "PLAYER_ENTERING_WORLD" then
        print(updateInfo)
    end
end)
]]
assert_eq(#Analyzer.analyze(srcV9, "modules/foo.lua", rEvt6c2, cfg), 1,
    "independent source re-taint survives dispatch untaint")

print("round-6c value-flow + payload-copy test passed")
end

-- ---------------------------------------------------------------------------
-- Round-6d: sound and-falsy value flow (secret-false yields), struct
-- assertions, plain-ref existence emissions
-- ---------------------------------------------------------------------------
do
local r6d = Registry.new()
r6d:addSource("C_Spell.GetFlag")

-- A falsy secret lhs IS the yield of `and` — taint must flow.
local srcD1 = [[
local isActive = C_Spell.GetFlag(1)
local v = isActive and 1
print(v)
]]
assert_eq(#Analyzer.analyze(srcD1, "modules/foo.lua", r6d, cfg), 1,
    "and-falsy secret yield flows to the sink")

-- Same through a non-indexing call rhs (`x and Wrap(x)`).
local srcD2 = [[
local isActive = C_Spell.GetFlag(1)
local v = isActive and Wrap(isActive)
print(v)
]]
assert_eq(#Analyzer.analyze(srcD2, "modules/foo.lua", r6d, cfg), 1,
    "and-falsy yield flows through non-indexing call rhs")

-- ...and through the a-and-b-or-c ternary idiom.
local srcD3 = [[
local isActive = C_Spell.GetFlag(1)
print(isActive and 1 or 0)
]]
assert_eq(#Analyzer.analyze(srcD3, "modules/foo.lua", r6d, cfg), 1,
    "ternary idiom over secret flag flows to the sink")

-- The decode idiom is NOT type-provable: `info and Decode(info.isActive)` —
-- the index inside Decode's argument only evaluates when info is TRUTHY, so
-- a secret-false info short-circuits past it and IS the yield. The
-- comparison must flag; genuinely table-or-nil API structs carry a
-- `-- @secret-safe:` annotation instead (round-6d follow-up: the struct-
-- assertion shortcut was itself a reproducible false negative).
local srcD4 = [[
local info = C_Spell.GetFlag(1)
local v = info and Decode(info.isActive)
if v == true then return end
]]
local fD4 = Analyzer.analyze(srcD4, "modules/foo.lua", r6d, cfg)
assert_eq(#fD4, 1, "decode idiom flags: falsy secret can bypass the index")
assert_eq(fD4[1].sink, "<comparison>", "flags at the comparison consumer")

-- Same through a 3-term chain: still exactly ONE finding, at the consumer —
-- the and/or chain itself never emits (plain-ref existence tests).
local srcD5 = [[
local cached = IsCached()
local info = C_Spell.GetFlag(1)
local v = cached and info and Decode(info.isActive)
if v == true then return end
]]
local fD5 = Analyzer.analyze(srcD5, "modules/foo.lua", r6d, cfg)
assert_eq(#fD5, 1, "3-term chain: one finding at the consumer, none at the binop")
assert_eq(fD5[1].sink, "<comparison>", "3-term finding is the comparison")

-- The @secret-safe annotation is the sanctioned suppression for
-- API-contract table-or-nil structs.
local srcD6 = [[
local info = C_Spell.GetFlag(1)
local v = info and Decode(info.isActive)
if v == true then return end -- @secret-safe: GetFlag returns table-or-nil per docs
]]
assert_eq(#Analyzer.analyze(srcD6, "modules/foo.lua", r6d, cfg), 0,
    "@secret-safe annotation suppresses the contract-safe decode site")

print("round-6d and-falsy value-flow test passed")
end
