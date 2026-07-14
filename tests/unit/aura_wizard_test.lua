local ns = dofile("tools/_addon_env.lua").LoadCore()
local W, E = ns.QUI_AuraWizard, ns.AuraElements
local failures=0; local function check(n,ok,d) if ok then print("  ok  "..n) else failures=failures+1; print("FAIL  "..n.." "..(d or "")) end end
do -- RoleDefaults
  local h = W.RoleDefaults("HEALER")
  check("healer party buffs mine", h.groupParty.buffs[1]=="mine")
  check("healer party debuffs dispellable", h.groupParty.debuffs[1]=="dispellable")
  check("healer player defensives", h.player.buffs[1]=="defensives")
  local t = W.RoleDefaults("TANK")
  check("tank target boss", t.target.debuffs[1]=="boss")
  local d = W.RoleDefaults("DAMAGER")
  check("dps target mine", d.target.debuffs[1]=="mine")
end
do -- SeedSurface produces an element that derives back to the intent
  local e = W.SeedSurface({}, "HARMFUL", "dispellable")
  check("seed harmful element", e.mode=="filterStrip" and e.auraType=="HARMFUL")
  check("seed derives dispellable", E.DeriveWhatToShow(e)=="dispellable", E.DeriveWhatToShow(e))
end
do -- PlayerSpecID: nil-safe outside the game client (no C_SpecializationInfo stub in harness)
  check("PlayerSpecID nil-guarded", W.PlayerSpecID() == nil)
end
do -- ActiveBucketKey (Finding 1): resolves to the spec bucket only when one exists
  local elements = { ["*"] = {} }
  check("no override -> '*'", W.ActiveBucketKey(elements, 261) == "*")
  check("nil specID -> '*'", W.ActiveBucketKey(elements, nil) == "*")
  elements[261] = {}
  check("override present -> spec key", W.ActiveBucketKey(elements, 261) == 261)
end
do -- SeedBucketForRole (Finding 2): retargets the debuff strip, defensives survives
  local debuffs = E.NewFilterStripElement("HARMFUL"); debuffs.id = "debuffs"
  local defensives = E.NewFilterStripElement("HELPFUL")
  defensives.id = "defensives"
  defensives.filterMode = "classify"
  defensives.classifications = { bigDefensive = true, externalDefensive = true }
  local bucket = { debuffs, defensives }

  local result = W.SeedBucketForRole(bucket, nil, { "dispellable" }, nil)

  check("retarget: element count unchanged", #result == 2, tostring(#result))
  check("retarget: debuff strip retargeted", E.DeriveWhatToShow(result[1]) == "dispellable", E.DeriveWhatToShow(result[1]))
  check("retarget: debuff strip enabled", result[1].enabled == true)
  check("retarget: defensives id survives", result[2].id == "defensives")
  check("retarget: defensives classification survives",
    result[2].classifications.bigDefensive == true and result[2].classifications.externalDefensive == true)
end
do -- SeedBucketForRole: buff intent skips the defensives strip, appends a new one
  local defensives = E.NewFilterStripElement("HELPFUL")
  defensives.id = "defensives"
  defensives.filterMode = "classify"
  defensives.classifications = { bigDefensive = true, externalDefensive = true }
  local bucket = { defensives }

  local result = W.SeedBucketForRole(bucket, { "mine" }, nil, nil)

  check("buff retarget: defensives untouched + new strip appended", #result == 2, tostring(#result))
  check("buff retarget: defensives id survives", result[1].id == "defensives")
  check("buff retarget: new strip derives mine", E.DeriveWhatToShow(result[2]) == "mine", E.DeriveWhatToShow(result[2]))
end
do -- SeedBucketForRole: empty/absent bucket seeds from defaultBucketFn, deep-copied
  local seedDebuff = E.NewFilterStripElement("HARMFUL"); seedDebuff.id = "debuffs"
  local seedBucket = { seedDebuff }
  local function defaultFn() return seedBucket end

  local result = W.SeedBucketForRole(nil, nil, { "boss" }, defaultFn)

  check("empty-seed: one element from default", #result == 1, tostring(#result))
  check("empty-seed: retargeted + enabled", E.DeriveWhatToShow(result[1]) == "boss" and result[1].enabled == true)
  check("empty-seed: deep-copied, not aliased", result[1] ~= seedDebuff)
  check("empty-seed: source table untouched by retarget", seedDebuff.gateBossAura ~= true)
end
do -- Finding 1 + 2 integration: spec-override bucket retargets independently of "*"
  local starDebuff = E.NewFilterStripElement("HARMFUL"); starDebuff.id = "debuffs"
  local overrideDebuff = E.NewFilterStripElement("HARMFUL"); overrideDebuff.id = "debuffs"
  local auras = { elements = { ["*"] = { starDebuff }, [105] = { overrideDebuff } } }

  local key = W.ActiveBucketKey(auras.elements, 105)
  check("finding1: resolves to spec bucket", key == 105)

  auras.elements[key] = W.SeedBucketForRole(auras.elements[key], nil, { "dispellable" }, nil)
  check("finding1: override bucket retargeted", E.DeriveWhatToShow(auras.elements[105][1]) == "dispellable")
  check("finding1: '*' bucket left untouched", E.DeriveWhatToShow(auras.elements["*"][1]) ~= "dispellable")
end
do -- WizardSteps
    check("healer+party = 5 steps", #W.WizardSteps("HEALER", { party = true, player = true }) == 5)
    check("tank+party = 4 steps (no placeHoTs)", #W.WizardSteps("TANK", { party = true }) == 4)
    local s = W.WizardSteps("HEALER", { player = true }) -- party unchecked
    check("no party = 3 steps", #s == 3, tostring(#s))
    check("no party: step2 surfaces", s[2] == "surfaces")
    check("no party: step3 review", s[3] == "review")
    local h = W.WizardSteps("HEALER", { party = true })
    check("healer step3 partyAuras", h[3] == "partyAuras")
    check("healer step4 placeHoTs", h[4] == "placeHoTs")
end

do -- FocusDefaults mirrors Target
    check("focus mirrors tank target (boss)", W.FocusDefaults("TANK").debuffs[1] == "boss")
    check("focus mirrors dps target (mine)", W.FocusDefaults("DAMAGER").debuffs[1] == "mine")
    check("focus healer target empty", #W.FocusDefaults("HEALER").debuffs == 0)
end

do -- CommitTrackedHoTs
    local bucket = {}
    W.CommitTrackedHoTs(bucket, {
        [774]  = { corner = "TOPLEFT",  displayType = "square" },
        [8936] = { corner = "TOPRIGHT", displayType = "icon" },
    })
    check("commit appends 2 tracked", #bucket == 2, tostring(#bucket))
    local e774
    for _, e in ipairs(bucket) do if e.spells and e.spells[1] == 774 then e774 = e end end
    check("774 mode tracked", e774 and e774.mode == "tracked")
    check("774 displayType square", e774 and e774.displayType == "square")
    check("774 anchor TOPLEFT", e774 and e774.anchor == "TOPLEFT")
    -- re-commit REPLACES: no duplicate, and the staged corner/display wins
    -- (the review step promises the wizard's selection replaces the layout —
    -- a silent keep-the-old-config no-op broke that promise).
    W.CommitTrackedHoTs(bucket, { [774] = { corner = "BOTTOMLEFT", displayType = "bar" } })
    local n774, new774 = 0, nil
    for _, e in ipairs(bucket) do if e.spells and e.spells[1] == 774 then n774 = n774 + 1; new774 = e end end
    check("774 not duplicated", n774 == 1, tostring(n774))
    check("774 re-commit replaces corner", new774 and new774.anchor == "BOTTOMLEFT", tostring(new774 and new774.anchor))
    check("774 re-commit replaces display", new774 and new774.displayType == "bar", tostring(new774 and new774.displayType))
    check("untouched sibling keeps config", (function()
        for _, e in ipairs(bucket) do
            if e.spells and e.spells[1] == 8936 then return e.anchor == "TOPRIGHT" and e.displayType == "icon" end
        end
    end)())
end

do -- CommitTrackedHoTs: same-corner HoTs step sideways (matches step-4 preview)
    local bucket = {}
    W.CommitTrackedHoTs(bucket, {
        [774]   = { corner = "TOPLEFT",  displayType = "icon" },
        [8936]  = { corner = "TOPLEFT",  displayType = "icon" },
        [33763] = { corner = "TOPRIGHT", displayType = "icon" },
    })
    local by = {}
    for _, e in ipairs(bucket) do by[e.spells[1]] = e end
    check("first TOPLEFT unshifted", (by[774].offsetX or 0) == 0, tostring(by[774].offsetX))
    check("second TOPLEFT stepped +x (iconSize+2)", by[8936].offsetX == 18, tostring(by[8936].offsetX))
    check("other corner slot independent", (by[33763].offsetX or 0) == 0, tostring(by[33763].offsetX))

    local b2 = {}
    W.CommitTrackedHoTs(b2, {
        [100] = { corner = "BOTTOMRIGHT", displayType = "icon" },
        [200] = { corner = "BOTTOMRIGHT", displayType = "icon" },
    })
    local by2 = {}
    for _, e in ipairs(b2) do by2[e.spells[1]] = e end
    check("right-side corner steps -x (toward center)", by2[200].offsetX == -18, tostring(by2[200].offsetX))

    -- re-commit into a bucket with an existing tracked HoT on the corner:
    -- the counter seeds from the bucket, so the new one keeps stepping
    W.CommitTrackedHoTs(bucket, { [155777] = { corner = "TOPLEFT", displayType = "icon" } })
    local e3
    for _, e in ipairs(bucket) do if e.spells[1] == 155777 then e3 = e end end
    check("counter seeds from existing bucket", e3 and e3.offsetX == 36, tostring(e3 and e3.offsetX))
end

do -- CommitTrackedHoTs: same-corner BARS step vertically (they're wide — a
   -- sideways icon-width step would still overlap; matches step-4 preview)
    local bucket = {}
    W.CommitTrackedHoTs(bucket, {
        [774]  = { corner = "TOPLEFT", displayType = "bar" },
        [8936] = { corner = "TOPLEFT", displayType = "bar" },
        [200]  = { corner = "TOPLEFT", displayType = "icon" },
    })
    local by = {}
    for _, e in ipairs(bucket) do by[e.spells[1]] = e end
    -- Step derives from the element's own bar thickness (whatever
    -- NewTrackedElement seeds) + 2px gap.
    local step = ((by[8936].bar and by[8936].bar.thickness) or 4) + 2
    check("first TOPLEFT bar unshifted", (by[774].offsetY or 0) == 0, tostring(by[774].offsetY))
    check("second TOPLEFT bar steps down (thickness+2)", by[8936].offsetY == -step,
        tostring(by[8936].offsetY) .. " vs -" .. tostring(step))
    check("bars don't shift sideways", (by[8936].offsetX or 0) == 0, tostring(by[8936].offsetX))
    check("icon slot independent of bar slot", (by[200].offsetX or 0) == 0 and (by[200].offsetY or 0) == 0)

    local b2 = {}
    W.CommitTrackedHoTs(b2, {
        [100] = { corner = "BOTTOMLEFT", displayType = "bar" },
        [300] = { corner = "BOTTOMLEFT", displayType = "bar" },
    })
    local by2 = {}
    for _, e in ipairs(b2) do by2[e.spells[1]] = e end
    local step2 = ((by2[300].bar and by2[300].bar.thickness) or 4) + 2
    check("bottom corner bar steps up (+y)", by2[300].offsetY == step2,
        tostring(by2[300].offsetY) .. " vs " .. tostring(step2))
end

do -- SeedBucketForRole: multiple intents claim SEPARATE strips (review fix —
   -- the old loop retargeted the same first strip per key, last intent won)
  local bucket = {}
  W.SeedBucketForRole(bucket, nil, { "dispellable", "boss", "crowdControl" }, nil)
  local derived = {}
  for _, e in ipairs(bucket) do derived[#derived + 1] = E.DeriveWhatToShow(e) end
  check("3 debuff intents -> 3 strips", #bucket == 3, tostring(#bucket))
  check("intents preserved in order", table.concat(derived, ",") == "dispellable,boss,crowdControl", table.concat(derived, ","))
end
do -- SeedBucketForRole: "defensives" intent enables the shipped strip in place (no clone)
  local defensives = E.NewFilterStripElement("HELPFUL")
  defensives.id = "defensives"; defensives.enabled = false
  defensives.filterMode = "classify"
  defensives.classifications = { bigDefensive = true, externalDefensive = true }
  local bucket = { defensives }
  W.SeedBucketForRole(bucket, { "defensives" }, nil, nil)
  check("defensives intent: no clone appended", #bucket == 1, tostring(#bucket))
  check("defensives intent: shipped strip enabled in place", bucket[1].enabled == true and bucket[1].id == "defensives")
end
do -- SeedBucketForRole explicit: unchecked polarity strips get disabled
  local buff = E.NewFilterStripElement("HELPFUL"); buff.enabled = true
  local debuff = E.NewFilterStripElement("HARMFUL"); debuff.enabled = true
  local bucket = { buff, debuff }
  W.SeedBucketForRole(bucket, { "mine" }, {}, nil, true) -- buffs: mine; debuffs: none
  check("explicit: buff strip claimed + enabled", bucket[1].enabled == true and E.DeriveWhatToShow(bucket[1]) == "mine")
  check("explicit: unchecked debuff strip disabled", bucket[2].enabled == false)
end
do -- SeedBucketForRole non-explicit (role defaults): empty keys leave strips untouched
  local debuff = E.NewFilterStripElement("HARMFUL"); debuff.enabled = true
  local bucket = { debuff }
  W.SeedBucketForRole(bucket, nil, nil, nil)
  check("role-default: empty keys leave strip enabled", bucket[1].enabled == true)
end
do -- SurfaceIsCustomized: deep compare, volatile ids ignored
  local function defFn()
    local e = E.NewFilterStripElement("HARMFUL")
    e.iconSize = 20
    return { e }
  end
  local auras = { elementsSeeded = true, elements = { ["*"] = defFn() } }
  check("untouched surface not customized", W.SurfaceIsCustomized(auras, defFn, "*") == false)
  auras.elements["*"][1].whitelist = { [774] = true }
  check("whitelist edit detected", W.SurfaceIsCustomized(auras, defFn, "*") == true)
  auras.elements["*"][1].whitelist = {}
  auras.elements["*"][1].iconSize = 21
  check("geometry edit detected", W.SurfaceIsCustomized(auras, defFn, "*") == true)
end

do -- PARTY intent menus exist and use valid WhatToShow keys
    check("PARTY_BUFF_INTENTS is table", type(W.PARTY_BUFF_INTENTS) == "table" and #W.PARTY_BUFF_INTENTS >= 1)
    check("PARTY_DEBUFF_INTENTS is table", type(W.PARTY_DEBUFF_INTENTS) == "table" and #W.PARTY_DEBUFF_INTENTS >= 1)
    check("buff menu first key = mine", W.PARTY_BUFF_INTENTS[1].key == "mine")
    check("debuff menu has boss", (function()
        for _, e in ipairs(W.PARTY_DEBUFF_INTENTS) do if e.key == "boss" then return true end end
        return false
    end)())
end

print("aura_wizard_test "..(failures==0 and "OK" or "FAILED")); os.exit(failures==0 and 0 or 1)
