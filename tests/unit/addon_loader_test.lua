-- Verifies core/addon_loader.lua: manifest shape, LOD staggered loading,
-- and the toggle helper's Enable/Disable/Load calls.
-- Standalone: stubs ns + C_AddOns; loads manifest + loader via loadfile.

local function newEnv()
    local calls = {}
    local state = { loaded = {}, enabled = {}, exists = {}, loadFails = {}, deps = {} }
    -- Capture the most recently created frame stub so tests can fire its events.
    local lastFrame
    _G.CreateFrame = function()
        local frame = { _events = {}, _scripts = {} }
        function frame:RegisterEvent(evt) self._events[evt] = true end
        function frame:UnregisterEvent(evt) self._events[evt] = nil end
        function frame:SetScript(name, fn) self._scripts[name] = fn end
        function frame:FireEvent(evt)
            if self._scripts["OnEvent"] then self._scripts["OnEvent"](self, evt) end
        end
        lastFrame = frame
        return frame
    end
    _G.C_AddOns = {
        DoesAddOnExist = function(n) return state.exists[n] ~= false end,
        IsAddOnLoaded = function(n) return state.loaded[n] == true end,
        -- Accept optional second arg (character name) per fix 4; ignore it in stub.
        GetAddOnEnableState = function(n, _char)
            if state.enabled[n] == false then return 0 end
            return 2
        end,
        EnableAddOn  = function(n) calls[#calls+1] = "enable:"..n;  state.enabled[n] = true  end,
        DisableAddOn = function(n) calls[#calls+1] = "disable:"..n; state.enabled[n] = false end,
        SaveAddOns   = function()  calls[#calls+1] = "save" end,
        LoadAddOn = function(n)
            calls[#calls+1] = "load:"..n
            if state.loadFails[n] then return nil, "DEP_MISSING" end
            if state.enabled[n] == false then return nil, "DISABLED" end
            state.loaded[n] = true
            return true
        end,
        -- Hard TOC deps per folder ({ [folder] = {dep, ...} }); none by default.
        GetAddOnDependencies = function(n)
            local d = state.deps[n]
            if d then return unpack(d) end
        end,
    }
    -- C_Timer.After runs synchronously in tests (stagger collapses to in-order)
    -- UNLESS InCombatLockdown returns true, in which case step() parks and returns.
    _G.C_Timer = { After = function(_, fn) fn() end }
    _G.InCombatLockdown = function() return false end
    _G.UnitName = function() return "TestPlayer", nil end
    local ns = {
        QUI_Modules = { notified = {}, NotifyChanged = function(self, id)
            self.notified[#self.notified+1] = id
        end },
        RunAfterFirstFrame = function(fn) fn() end,
        WhenLoggedIn = function(fn) fn() end,
    }
    return ns, calls, state, function() return lastFrame end
end

local function loadLoader(ns)
    local manifest = assert(loadfile("core/addon_manifest.lua"))("QUI", ns)
    assert(type(manifest) == "table" and #manifest > 0, "manifest returns entries")
    assert(loadfile("core/addon_loader.lua"))("QUI", ns)
    assert(ns.AddonLoader, "ns.AddonLoader set")
    return ns.AddonLoader
end

-- 1) Manifest shape: 13 entries, classes valid, folders unique;
--    legacyFlag present on exactly QUI_Chat, QUI_GroupFrames, QUI_Bags, absent on all
--    others; flag field absent on every entry.
do
    local ns = newEnv()
    loadLoader(ns)
    local seen, lod, login, host = {}, 0, 0, 0
    local legacyFlagFolders = {}
    local lateLoadFolders = {}
    local selfBootstrapFolders = {}
    local hostModules = {}
    for _, e in ipairs(ns.AddonManifest) do
        if e.folder then
            -- FOLDER ENTRY: a shipped sibling addon folder.
            assert(type(e.folder) == "string" and e.folder:match("^QUI_"), "folder name")
            assert(not seen[e.folder], "unique folder"); seen[e.folder] = true
            assert(e.class == "login" or e.class == "lod", "class")
            -- sources documents the PRE-SPLIT module paths; folders born after
            -- the suite split (QUI_UI) legitimately have an empty list.
            assert(type(e.sources) == "table", "sources")
            -- host-backed fields must NOT appear on a folder entry
            assert(e.hostAddon == nil and e.module == nil and e.flag == nil,
                "folder entry must not carry host-backed fields: " .. e.folder)
            -- track which entries carry legacyFlag
            if e.legacyFlag ~= nil then
                assert(type(e.legacyFlag) == "table" and #e.legacyFlag > 0,
                    "legacyFlag must be a non-empty table on " .. e.folder)
                legacyFlagFolders[#legacyFlagFolders + 1] = e.folder
            end
            if e.lateLoad ~= nil then
                assert(e.lateLoad == true, "lateLoad must be boolean true on " .. e.folder)
                assert(e.class == "lod", "lateLoad only valid on lod entries: " .. e.folder)
                lateLoadFolders[#lateLoadFolders + 1] = e.folder
            end
            if e.selfBootstrap ~= nil then
                assert(e.selfBootstrap == true, "selfBootstrap must be boolean true on " .. e.folder)
                assert(e.class == "lod", "selfBootstrap only valid on lod entries: " .. e.folder)
                selfBootstrapFolders[#selfBootstrapFolders + 1] = e.folder
            end
            if e.class == "lod" then lod = lod + 1 else login = login + 1 end
        else
            -- HOST-BACKED ENTRY: a module shipping inside another folder's addon.
            assert(type(e.hostAddon) == "string" and e.hostAddon:match("^QUI_"),
                "host-backed entry needs a hostAddon")
            assert(type(e.module) == "string" and #e.module > 0,
                "host-backed entry needs a module name")
            assert(type(e.flag) == "table" and #e.flag > 0,
                "host-backed entry needs a non-empty flag table")
            -- a host-backed entry has no standalone folder/class/sources/legacyFlag
            assert(e.class == nil and e.sources == nil and e.legacyFlag == nil,
                "host-backed entry must not carry folder-entry fields: " .. e.module)
            host = host + 1
            hostModules[#hostModules + 1] = e.module
        end
    end
    assert(login == 6, "6 login-class entries, got " .. login)
    assert(lod == 3, "3 lod folder entries (QUI_UI/QUI_DamageMeter/QUI_Bags), got " .. lod)
    assert(host == 3, "3 host-backed entries (minimap/infobar/alts; skinning/datatexts/qol ride bundle), got " .. host)
    assert(#legacyFlagFolders == 3,
        "exactly 3 legacyFlag entries, got " .. #legacyFlagFolders)
    -- Sort for deterministic comparison (manifest order may vary)
    table.sort(legacyFlagFolders)
    assert(legacyFlagFolders[1] == "QUI_Bags",
        "1st legacyFlag entry must be QUI_Bags, got " .. tostring(legacyFlagFolders[1]))
    assert(legacyFlagFolders[2] == "QUI_Chat",
        "2nd legacyFlag entry must be QUI_Chat, got " .. tostring(legacyFlagFolders[2]))
    assert(legacyFlagFolders[3] == "QUI_GroupFrames",
        "3rd legacyFlag entry must be QUI_GroupFrames, got " .. tostring(legacyFlagFolders[3]))
    table.sort(hostModules)
    assert(table.concat(hostModules, ",") == "alts,infobar,minimap",
        "host modules must be alts/infobar/minimap (skinning/datatexts/qol ride bundle), got " .. table.concat(hostModules, ","))
    -- lateLoad: none today. QUI_Minimap now eager-loads (skinned/anchored
    -- before the first frame, re-applying after EditMode settles), so no entry
    -- is flagged lateLoad. The mechanism itself is retained for future use.
    assert(#lateLoadFolders == 0,
        "no lateLoad entries expected, got " .. #lateLoadFolders)
    -- selfBootstrap: exactly QUI_UI. Its eager tier loads via the [Bootstrap]
    -- TOC directive at startup; the core's automatic LOD passes skip it (a
    -- LoadAddOn there would also pull the untagged lazy Alts remainder).
    assert(#selfBootstrapFolders == 1,
        "exactly 1 selfBootstrap entry (QUI_UI), got " .. #selfBootstrapFolders)
    assert(selfBootstrapFolders[1] == "QUI_UI",
        "selfBootstrap entry must be QUI_UI, got " .. tostring(selfBootstrapFolders[1]))
end

-- 2) LOD stagger: the automatic passes load only the NON-selfBootstrap LOD
--    folders (QUI_DamageMeter/QUI_Bags) when addon-enabled, regardless of
--    profile content. QUI_UI is selfBootstrap — its eager tier loads via the
--    [Bootstrap] TOC directive at startup, so the core MUST NOT LoadAddOn it
--    here (that would also pull the untagged lazy Alts remainder). Profile
--    flags are no longer load gates; only addon enable state matters. Two
--    variants: empty profile and a profile with damageMeter.native.enabled=
--    false both produce 2 loads, and neither loads QUI_UI.
do
    -- 2a) Empty profile: the 2 non-selfBootstrap LOD folders load, in manifest
    --    order; QUI_UI is excluded.
    do
        local ns, calls = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        loader:LoadEnabledLODModules()
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads == 2, "2a: expected 2 loads (selfBootstrap QUI_UI excluded), got " .. #loads)
        assert(loads[1] == "load:QUI_DamageMeter", "2a 1st: damagemeter")
        assert(loads[2] == "load:QUI_Bags",        "2a 2nd: bags")
        for _, c in ipairs(loads) do
            assert(c ~= "load:QUI_UI", "2a: selfBootstrap QUI_UI must NOT be loaded by the stagger")
        end
        assert(#ns.QUI_Modules.notified == 2, "2a: one notify per load")
    end

    -- 2b) Profile with damageMeter.native.enabled=false: DamageMeter still loads
    --    (profile flags are not load gates); QUI_UI still excluded.
    do
        local ns, calls = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function()
            return { damageMeter = { native = { enabled = false } } }
        end
        loader:LoadEnabledLODModules()
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads == 2, "2b: expected 2 loads (flag-false profile), got " .. #loads)
        assert(loads[1] == "load:QUI_DamageMeter",
            "2b: DamageMeter must load even when profile flag is false")
        for _, c in ipairs(loads) do
            assert(c ~= "load:QUI_UI", "2b: selfBootstrap QUI_UI must NOT be loaded by the stagger")
        end
    end
end

-- 3) Toggle helper: lod enable = Enable+Load now; login enable = reload; disable = reload;
--    LoadAddOn failure returns "reload"; SaveAddOns called after Enable/Disable;
--    disabled hard dep returns "depDisabled" + the dep folder.
--    Also documents the loader-level contract: enabling a login-class addon that is
--    already loaded returns "loaded" (the module ran at load time; the row layer in
--    module_addons_content.lua compensates by checking the dormant-guard flag flip).
do
    local ns, calls, state = newEnv()
    local loader = loadLoader(ns)

    -- enable a disabled LOD folder: Enable → Load → "loaded", SaveAddOns called
    state.enabled.QUI_UI = false
    assert(loader.SetModuleAddonEnabled("QUI_UI", true) == "loaded")
    assert(calls[1] == "enable:QUI_UI", "1st call enable")
    assert(calls[2] == "save",          "2nd call save after enable")
    assert(calls[3] == "load:QUI_UI",   "3rd call load")

    -- disable a login-class module → "reload", SaveAddOns called
    -- Clear in-place so the C_AddOns stubs (which close over the same table) see the reset.
    for k in pairs(calls) do calls[k] = nil end
    assert(loader.SetModuleAddonEnabled("QUI_UnitFrames", false) == "reload")
    assert(calls[1] == "disable:QUI_UnitFrames", "disable call")
    assert(calls[2] == "save",                   "save after disable")

    -- enable a login-class that is NOT yet loaded → "reload" (addon enabled, will load on reload)
    assert(loader.SetModuleAddonEnabled("QUI_UnitFrames", true) == "reload",
        "login-class not yet loaded: enable must return reload")

    -- enable a login-class that IS already loaded → "loaded" (loader-level contract:
    -- the module ran at load time; the module_addons_content row handles the
    -- dormant-guard-flag flip case separately by prompting reload when flipped+loaded).
    state.loaded.QUI_UnitFrames = true
    assert(loader.SetModuleAddonEnabled("QUI_UnitFrames", true) == "loaded",
        "login-class already loaded: enable must return loaded")

    -- missing addon
    state.exists.QUI_Chat = false
    assert(loader.SetModuleAddonEnabled("QUI_Chat", true) == "missing")

    -- LOD enable whose LoadAddOn fails → "reload"
    state.enabled.QUI_UI = false
    state.loaded.QUI_UI  = nil
    state.loadFails.QUI_UI = true
    assert(loader.SetModuleAddonEnabled("QUI_UI", true) == "reload",
        "LoadAddOn failure must return reload")
    state.loadFails.QUI_UI = nil

    -- enable a LOD folder whose existing-on-disk hard dep is disabled →
    -- "depDisabled" + dep folder; enable+save still recorded, no LoadAddOn attempt.
    -- (Synthetic dep: QUI_UI declares a hard dep on QUI_DamageMeter for this case;
    -- the dep mechanism is folder-generic.)
    state.deps.QUI_UI = { "QUI_DamageMeter" }
    state.enabled.QUI_UI = false
    state.loaded.QUI_UI = nil
    state.enabled.QUI_DamageMeter = false
    for k in pairs(calls) do calls[k] = nil end
    local result, dep = loader.SetModuleAddonEnabled("QUI_UI", true)
    assert(result == "depDisabled",
        "disabled dep: expected depDisabled, got " .. tostring(result))
    assert(dep == "QUI_DamageMeter",
        "disabled dep: 2nd return must name the dep, got " .. tostring(dep))
    assert(calls[1] == "enable:QUI_UI", "enable still recorded before dep check")
    assert(calls[2] == "save",          "save still recorded before dep check")
    for _, c in ipairs(calls) do
        assert(not c:match("^load:"), "disabled dep: LoadAddOn must not be attempted")
    end

    -- same folder with the dep enabled → prior token ("loaded"), no regression
    state.enabled.QUI_DamageMeter = true
    assert(loader.SetModuleAddonEnabled("QUI_UI", true) == "loaded",
        "deps all enabled: LOD enable must still return loaded")

    -- GetAddOnDependencies absent (headless / older client) → old behavior:
    -- falls through to the load attempt (which fails on a disabled dep) → "reload"
    _G.C_AddOns.GetAddOnDependencies = nil
    state.loaded.QUI_UI = nil
    state.enabled.QUI_UI = false
    state.enabled.QUI_DamageMeter = false
    state.loadFails.QUI_UI = true  -- client would fail with DEP_DISABLED
    assert(loader.SetModuleAddonEnabled("QUI_UI", true) == "reload",
        "GetAddOnDependencies absent: must fall back to reload, not depDisabled")
end

-- 4) Combat parking: no loads during lockdown; all drain after PLAYER_REGEN_ENABLED.
--    The 2 non-selfBootstrap LOD folders are addon-enabled (default stub) so both
--    load post-regen; selfBootstrap QUI_UI is excluded from the stagger.
do
    local ns, calls, state, getLastFrame = newEnv()
    local loader = loadLoader(ns)
    loader.GetProfile = function() return {} end  -- DB ready; profile content not used for gating

    -- Enter simulated combat before the stagger starts.
    _G.InCombatLockdown = function() return true end

    loader:LoadEnabledLODModules()
    -- The first step() should have parked immediately — no load calls.
    local loadsBefore = {}
    for _, c in ipairs(calls) do if c:match("^load:") then loadsBefore[#loadsBefore+1] = c end end
    assert(#loadsBefore == 0, "no loads during combat, got " .. #loadsBefore)

    -- The frame must have registered for PLAYER_REGEN_ENABLED.
    local frame = getLastFrame()
    assert(frame, "regenResumeFrame created")
    assert(frame._events["PLAYER_REGEN_ENABLED"], "registered PLAYER_REGEN_ENABLED")

    -- Leave combat and fire the event; C_Timer.After is still synchronous so
    -- the remaining chain drains immediately.
    _G.InCombatLockdown = function() return false end
    frame:FireEvent("PLAYER_REGEN_ENABLED")

    -- The 2 non-selfBootstrap LOD folders must now be loaded in manifest order.
    local loadsAfter = {}
    for _, c in ipairs(calls) do if c:match("^load:") then loadsAfter[#loadsAfter+1] = c end end
    assert(#loadsAfter == 2, "both non-selfBootstrap lod folders loaded after regen, got " .. #loadsAfter)
    assert(loadsAfter[1] == "load:QUI_DamageMeter", "post-regen 1st: damagemeter")
    assert(loadsAfter[2] == "load:QUI_Bags",        "post-regen 2nd: bags")
    for _, c in ipairs(loadsAfter) do
        assert(c ~= "load:QUI_UI", "post-regen: selfBootstrap QUI_UI must NOT load via the stagger")
    end

    -- Frame must have unregistered after draining.
    assert(not frame._events["PLAYER_REGEN_ENABLED"], "unregistered after drain")
end

-- 5) Combat guard on SetModuleAddonEnabled: enabling a LOD addon mid-combat
--    records EnableAddOn+SaveAddOns but skips LoadNow, returns "reload".
--    Out of combat: LoadNow fires and returns "loaded".
do
    -- In-combat path: no "load:" call, returns "reload"
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        state.enabled.QUI_UI = false
        _G.InCombatLockdown = function() return true end
        local result = loader.SetModuleAddonEnabled("QUI_UI", true)
        assert(result == "reload", "in-combat LOD enable must return 'reload', got " .. tostring(result))
        local hasLoad = false
        for _, c in ipairs(calls) do if c:match("^load:") then hasLoad = true end end
        assert(not hasLoad, "in-combat LOD enable must not call LoadAddOn")
        -- EnableAddOn and SaveAddOns still recorded
        assert(calls[1] == "enable:QUI_UI", "EnableAddOn still called in combat")
        assert(calls[2] == "save",          "SaveAddOns still called in combat")
        _G.InCombatLockdown = function() return false end
    end

    -- Out-of-combat path: LoadNow fires, returns "loaded"
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        state.enabled.QUI_UI = false
        _G.InCombatLockdown = function() return false end
        local result = loader.SetModuleAddonEnabled("QUI_UI", true)
        assert(result == "loaded", "out-of-combat LOD enable must return 'loaded', got " .. tostring(result))
        local hasLoad = false
        for _, c in ipairs(calls) do if c:match("^load:") then hasLoad = true end end
        assert(hasLoad, "out-of-combat LOD enable must call LoadAddOn")
    end
end

-- 6) Anchoring catch-up: RegisterAllFrameTargets + ApplyAllFrameAnchors called
--    exactly once after a stagger that loaded ≥1 module; NOT called when nothing loaded.
do
    -- 6a) At least one load → both anchoring methods called exactly once.
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end  -- all flags on
        local anchorCalls = {}
        ns.QUI_Anchoring = {
            RegisterAllFrameTargets = function(self) anchorCalls[#anchorCalls+1] = "register" end,
            ApplyAllFrameAnchors    = function(self) anchorCalls[#anchorCalls+1] = "apply" end,
        }
        loader:LoadEnabledLODModules()
        assert(#anchorCalls == 2, "expect 2 anchoring calls after stagger, got " .. #anchorCalls)
        assert(anchorCalls[1] == "register", "RegisterAllFrameTargets called first")
        assert(anchorCalls[2] == "apply",    "ApplyAllFrameAnchors called second")
    end

    -- 6b) Nothing eligible (all already loaded) → anchoring methods NOT called.
    do
        local ns, calls, state = newEnv()
        -- Mark all LOD folders as already loaded so nothing gets enqueued.
        state.loaded.QUI_UI          = true
        state.loaded.QUI_DamageMeter = true
        state.loaded.QUI_Bags        = true
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        local anchorCalls = {}
        ns.QUI_Anchoring = {
            RegisterAllFrameTargets = function(self) anchorCalls[#anchorCalls+1] = "register" end,
            ApplyAllFrameAnchors    = function(self) anchorCalls[#anchorCalls+1] = "apply" end,
        }
        loader:LoadEnabledLODModules()
        assert(#anchorCalls == 0, "no anchoring calls when nothing loaded, got " .. #anchorCalls)
    end

    -- 6c) Combat-deferred stagger: anchoring fires after regen drain (loads happened post-combat).
    do
        local ns, calls, state, getLastFrame = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        local anchorCalls = {}
        ns.QUI_Anchoring = {
            RegisterAllFrameTargets = function(self) anchorCalls[#anchorCalls+1] = "register" end,
            ApplyAllFrameAnchors    = function(self) anchorCalls[#anchorCalls+1] = "apply" end,
        }
        _G.InCombatLockdown = function() return true end
        loader:LoadEnabledLODModules()
        -- Still in combat — no anchoring yet.
        assert(#anchorCalls == 0, "no anchoring during combat")
        -- Leave combat, drain queue.
        _G.InCombatLockdown = function() return false end
        local frame = getLastFrame()
        frame:FireEvent("PLAYER_REGEN_ENABLED")
        -- Now anchoring must have fired.
        assert(#anchorCalls == 2, "anchoring called after combat drain, got " .. #anchorCalls)
        assert(anchorCalls[1] == "register", "register after combat drain")
        assert(anchorCalls[2] == "apply",    "apply after combat drain")
    end
end

-- 7) Eager load (loading-screen path): LoadEnabledLODModulesEager loads every
--    eligible NON-selfBootstrap LOD folder synchronously in manifest order, in
--    ONE pass with NO combat parking (it runs inside the ADDON_LOADED safe
--    window), and runs the anchoring catch-up exactly once when ≥1 folder
--    loaded. QUI_UI is selfBootstrap: its eager tier (skinning/minimap/
--    datatexts/infobar/qol/dungeon) loads via the [Bootstrap] TOC directive at
--    startup, so the eager pass MUST NOT LoadAddOn it (that call would also
--    pull the untagged lazy Alts remainder, defeating the lazy tier).
do
    -- 7a) The 2 non-selfBootstrap LOD folders load in manifest order; one notify
    --     each; anchoring catch-up once. QUI_UI is excluded.
    do
        local ns, calls = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        local anchorCalls = {}
        ns.QUI_Anchoring = {
            RegisterAllFrameTargets = function() anchorCalls[#anchorCalls+1] = "register" end,
            ApplyAllFrameAnchors    = function() anchorCalls[#anchorCalls+1] = "apply" end,
        }
        loader:LoadEnabledLODModulesEager()
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads == 2, "7a: expected 2 eager loads (selfBootstrap QUI_UI excluded), got " .. #loads)
        assert(loads[1] == "load:QUI_DamageMeter", "7a 1st: damagemeter")
        assert(loads[2] == "load:QUI_Bags",        "7a 2nd: bags")
        for _, c in ipairs(loads) do
            assert(c ~= "load:QUI_UI", "7a: selfBootstrap QUI_UI must NOT eager-load")
        end
        assert(#ns.QUI_Modules.notified == 2, "7a: one notify per eager load")
        assert(#anchorCalls == 2, "7a: anchoring catch-up runs once (register+apply)")
        assert(anchorCalls[1] == "register" and anchorCalls[2] == "apply", "7a: register then apply")
    end

    -- 7b) Combat is IRRELEVANT to the eager path: still loads the 2 in lockdown
    --     (the safe window sanctions loading even during a combat /reload).
    do
        local ns, calls = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        _G.InCombatLockdown = function() return true end
        loader:LoadEnabledLODModulesEager()
        _G.InCombatLockdown = function() return false end
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads == 2, "7b: eager load ignores combat lockdown, got " .. #loads)
    end

    -- 7c) selfBootstrap QUI_UI is excluded EVEN when fully addon-enabled (its
    --     enable state is irrelevant to the automatic pass). The 2 others load.
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        -- QUI_UI left at the default "All"-enabled stub: it must still be skipped.
        local anchorCalls = {}
        ns.QUI_Anchoring = {
            RegisterAllFrameTargets = function() anchorCalls[#anchorCalls+1] = "register" end,
            ApplyAllFrameAnchors    = function() anchorCalls[#anchorCalls+1] = "apply" end,
        }
        loader:LoadEnabledLODModulesEager()
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads == 2, "7c: selfBootstrap QUI_UI skipped even when enabled, got " .. #loads)
        for _, c in ipairs(loads) do assert(c ~= "load:QUI_UI", "7c: ui must not load") end
        assert(#anchorCalls == 2, "7c: anchoring still runs (2 loaded)")
    end

    -- 7d) DB not ready (GetProfile nil) → inert, no loads.
    do
        local ns, calls = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return nil end
        loader:LoadEnabledLODModulesEager()
        local loads = 0
        for _, c in ipairs(calls) do if c:match("^load:") then loads = loads + 1 end end
        assert(loads == 0, "7d: no eager loads when DB not ready, got " .. loads)
    end

    -- 7e) Two-stage split: the eager pass loads the 2 non-selfBootstrap folders;
    --     QUI_UI is NEVER among the automatic-pass loads (it [Bootstrap]-loads
    --     natively at startup). The staggered post-login pass is then a no-op
    --     catch-up — everything it would load is already loaded.
    do
        local ns, calls = newEnv()
        local loader = loadLoader(ns)
        loader.GetProfile = function() return {} end
        ns.QUI_Anchoring = {
            RegisterAllFrameTargets = function() end,
            ApplyAllFrameAnchors    = function() end,
        }
        -- Stage 1: eager — QUI_UI is NOT among the loads (selfBootstrap).
        loader:LoadEnabledLODModulesEager()
        local afterEager, uiEager = 0, false
        for _, c in ipairs(calls) do
            if c:match("^load:") then
                afterEager = afterEager + 1
                if c == "load:QUI_UI" then uiEager = true end
            end
        end
        assert(afterEager == 2, "7e: eager loads the 2 non-selfBootstrap folders, got " .. afterEager)
        assert(not uiEager, "7e: selfBootstrap QUI_UI must NOT eager-load (it [Bootstrap]-loads natively)")
        -- Stage 2: staggered post-login — both already loaded, loads nothing new,
        -- and still excludes QUI_UI.
        loader:LoadEnabledLODModules()
        local total, uiEver = 0, false
        for _, c in ipairs(calls) do
            if c:match("^load:") then
                total = total + 1
                if c == "load:QUI_UI" then uiEver = true end
            end
        end
        assert(total == 2, "7e: staggered catch-up loads nothing new, got " .. total)
        assert(not uiEver, "7e: QUI_UI never loaded by the automatic passes")
    end
end

-- 8) Per-character enable gating (Blizzard AddOnUtil idiom): query by the
--    player GUID and require Enum.AddOnEnableState.All. "Some" means the
--    addon is enabled on OTHER characters only — it must NOT gate as
--    enabled here (the old any-non-zero check loaded it anyway, defeating
--    the per-character AddOns-list boundary). Without a GUID (headless /
--    very early) the aggregate no-arg query keeps the legacy behavior.
do
    local ns, calls, state = newEnv()
    state.someOnly = {} -- folder → true = enabled on other characters only
    _G.Enum = { AddOnEnableState = { None = 0, Some = 1, All = 2 } }
    _G.UnitGUID = function() return "Player-1234-DEADBEEF" end
    _G.C_AddOns.GetAddOnEnableState = function(n, _char)
        if state.enabled[n] == false then return 0 end
        -- a Some addon never answers All, with or without a character arg
        if state.someOnly[n] then return 1 end
        return 2
    end
    local loader = loadLoader(ns)
    loader.GetProfile = function() return {} end
    state.someOnly.QUI_Bags = true
    assert(loader.IsModuleAddonEnabled("QUI_Bags") == false,
        "8: Some (enabled on another character only) must gate as disabled here")
    assert(loader.IsModuleAddonEnabled("QUI_UI") == true,
        "8: All must still gate as enabled")
    loader:LoadEnabledLODModulesEager()
    for _, c in ipairs(calls) do
        assert(c ~= "load:QUI_Bags", "8: a per-character-disabled addon must not eager-load")
    end
    -- no GUID → aggregate fallback (any non-zero = enabled, legacy behavior)
    _G.UnitGUID = nil
    assert(loader.IsModuleAddonEnabled("QUI_Bags") == true,
        "8: without a GUID the aggregate fallback treats Some as enabled")
    _G.Enum = nil
end

-- 9) LoadLazyBlock: loads the QUI_UI lazy remainder (the Alts roster UI) on
--    first trigger, combat-parks like the stagger, and is idempotent.
do
    -- 9a) Out of combat: LoadLazyBlock loads QUI_UI and runs the callback.
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        state.loaded.QUI_UI = nil
        _G.InCombatLockdown = function() return false end
        local cbRan = false
        loader:LoadLazyBlock(function() cbRan = true end)
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads == 1, "9a: expected 1 load, got " .. #loads)
        assert(loads[1] == "load:QUI_UI", "9a: must load QUI_UI, got " .. tostring(loads[1]))
        assert(cbRan, "9a: callback must run after load")
        assert(state.loaded.QUI_UI == true, "9a: QUI_UI marked loaded")
    end

    -- 9b) In combat: does NOT load; after PLAYER_REGEN_ENABLED, loads + runs cb.
    do
        local ns, calls, state, getLastFrame = newEnv()
        local loader = loadLoader(ns)
        state.loaded.QUI_UI = nil
        _G.InCombatLockdown = function() return true end
        local cbRan = false
        loader:LoadLazyBlock(function() cbRan = true end)
        -- Parked: no load, no callback yet.
        local before = {}
        for _, c in ipairs(calls) do if c:match("^load:") then before[#before+1] = c end end
        assert(#before == 0, "9b: no load during combat, got " .. #before)
        assert(not cbRan, "9b: callback must not run during combat")
        local frame = getLastFrame()
        assert(frame, "9b: regenResumeFrame created")
        assert(frame._events["PLAYER_REGEN_ENABLED"], "9b: registered PLAYER_REGEN_ENABLED")
        -- Leave combat; fire regen; chain drains (C_Timer.After synchronous).
        _G.InCombatLockdown = function() return false end
        frame:FireEvent("PLAYER_REGEN_ENABLED")
        local after = {}
        for _, c in ipairs(calls) do if c:match("^load:") then after[#after+1] = c end end
        assert(#after == 1, "9b: 1 load after regen, got " .. #after)
        assert(after[1] == "load:QUI_UI", "9b: QUI_UI loaded after regen")
        assert(cbRan, "9b: callback runs after regen drain")
        assert(not frame._events["PLAYER_REGEN_ENABLED"], "9b: unregistered after drain")
    end

    -- 9c) Bootstrap-loaded state: IsAddOnLoaded returns true (the [Bootstrap]-tagged
    --     files compiled at login), but the untagged lazy remainder (e.g. the Alts
    --     roster window) has NOT been compiled yet.  LoadLazyBlock MUST call
    --     C_AddOns.LoadAddOn unconditionally — mirroring the Blizzard pattern for
    --     split-file LOD addons (AuctionHouseFrame_LoadUI, etc.) — so that the
    --     remainder compiles on first open.  An IsModuleLoaded guard here is the
    --     exact bug being fixed: it would skip LoadAddOn, leaving ns.Alts.Window
    --     nil.  This assertion would FAIL against the old guarded code (which
    --     asserted loads==0) and PASS against the fixed unconditional code.
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        -- Model the first-open state: bootstrap files compiled (IsAddOnLoaded=true),
        -- but the lazy remainder is not yet loaded.
        state.loaded.QUI_UI = true
        _G.InCombatLockdown = function() return false end
        local cbRan = false
        loader:LoadLazyBlock(function() cbRan = true end)
        local loads = {}
        for _, c in ipairs(calls) do if c:match("^load:") then loads[#loads+1] = c end end
        assert(#loads >= 1, "9c: LoadAddOn must be called even when IsAddOnLoaded is true " ..
            "(bootstrap-loaded; lazy remainder may not yet be compiled), got " .. #loads)
        assert(loads[1] == "load:QUI_UI", "9c: must call LoadAddOn for QUI_UI, got " .. tostring(loads[1]))
        assert(cbRan, "9c: callback must run after load")
    end

    -- 9d) No callback supplied: must not error.
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        state.loaded.QUI_UI = nil
        _G.InCombatLockdown = function() return false end
        loader:LoadLazyBlock(nil)  -- nil onLoaded
        assert(state.loaded.QUI_UI == true, "9d: loads even with nil callback")
    end
end

-- 10) selfBootstrap does NOT disable the LIVE bundle-enable path: enabling
--     "UI Bundle" from the Module Addons row (SetModuleAddonEnabled) is a
--     deliberate user action that must still LoadNow(QUI_UI). That path loads
--     the folder directly and does NOT route through CollectEligibleLODFolders,
--     so the selfBootstrap guard (which only gates the automatic eager/staggered
--     passes) does not suppress it.
do
    -- Out of combat: a disabled QUI_UI enabled live → Enable + Save + Load now,
    -- returns "loaded".
    do
        local ns, calls, state = newEnv()
        local loader = loadLoader(ns)
        state.enabled.QUI_UI = false
        state.loaded.QUI_UI  = nil
        _G.InCombatLockdown = function() return false end
        assert(loader.SetModuleAddonEnabled("QUI_UI", true) == "loaded",
            "10: live UI Bundle enable must still load QUI_UI despite selfBootstrap")
        local sawLoad = false
        for _, c in ipairs(calls) do if c == "load:QUI_UI" then sawLoad = true end end
        assert(sawLoad, "10: SetModuleAddonEnabled must call LoadAddOn(QUI_UI) (live enable)")
        assert(state.loaded.QUI_UI == true, "10: QUI_UI marked loaded after live enable")
    end
end

print("addon_loader_test OK")
