local ns = dofile("tools/_addon_env.lua").LoadCore(); local E = ns.AuraElements
local failures=0; local function check(n,ok,d) if ok then print("  ok  "..n) else failures=failures+1; print("FAIL  "..n.." "..(d or "")) end end
local function auras() return { elements = {
    ["*"]   = { { id="a", enabled=true, mode="filterStrip" } },
    [268]   = { { id="b", enabled=true, mode="filterStrip" } },
    ["i2549"] = { { id="c", enabled=true, mode="filterStrip" } },
} } end
do
  check("nil context = spec bucket (unchanged)", E.ActiveElementsForSpec(auras(), 268)[1].id=="b")
  check("nil context nil spec = star", E.ActiveElementsForSpec(auras(), nil)[1].id=="a")
  check("instance key wins over spec", E.ActiveElementsForSpec(auras(), 268, nil, {"i2549"})[1].id=="c")
  check("missing instance falls to spec", E.ActiveElementsForSpec(auras(), 268, nil, {"i9999"})[1].id=="b")
  check("InstanceBucketKey", E.InstanceBucketKey(2549)=="i2549" and E.InstanceBucketKey(nil)==nil)
end
print("aura_cascade_test "..(failures==0 and "OK" or "FAILED")); os.exit(failures==0 and 0 or 1)
