-- Permanent guard for the multi-addon suite:
--  * every manifest entry has a folder, TOC, bootstrap-first, Dependencies: QUI
--  * LoadOnDemand flag matches manifest class
--  * every .lua on disk under a sub-addon belongs to exactly one TOC
--    (its own, or QUI_Options.toc for settings/ files)
--  * core QUI.toc references no moved module paths
--  * bootstrap.lua files are byte-identical to the template

local manifest = assert(loadfile("core/addon_manifest.lua"))()

local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end

-- Parse a TOC's .lua file lines. A file line is "<path>.lua" optionally
-- followed by whitespace + a per-file directive tag like "[Bootstrap]" (a
-- 12.1 per-file load tier). The tag is stripped before recording the path;
-- `tier` records true when the [Bootstrap] tag was present.
local function tocLuaEntries(tocPath)
    local body = assert(readFile(tocPath), "missing " .. tocPath)
    local set, order, tier = {}, {}, {}
    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        if not line:match("^%s*#") then
            -- Match a .lua path, then an optional trailing " [Bootstrap]" tag.
            local path, tag = line:match("^(%S+%.lua)%s*(%[%w+%])%s*$")
            if not path then
                path = line:match("^(%S+%.lua)%s*$")
            end
            if path then
                local norm = path:gsub("\\", "/")
                assert(not set[norm], "duplicate in " .. tocPath .. ": " .. norm)
                set[norm] = true
                order[#order + 1] = norm
                tier[norm] = (tag == "[Bootstrap]")
            end
        end
    end
    return set, order, tier
end

local template = assert(readFile("core/templates/subaddon_bootstrap.lua"))
local optionsSet = tocLuaEntries("QUI_Options/QUI_Options.toc")

for _, e in ipairs(manifest) do
    -- Host-backed entries ship inside another addon's folder and have no
    -- `folder` field, so the folder/TOC/bootstrap/disk-coverage checks below
    -- (which require a sibling folder + its own .toc) don't apply to them.
    if e.folder then
        local toc = e.folder .. "/" .. e.folder .. ".toc"
        local body = assert(readFile(toc), "missing " .. toc)
        assert(body:match("## Dependencies: QUI"), e.folder .. ": Dependencies")
        local isLOD = body:match("## LoadOnDemand: 1") ~= nil
        assert(isLOD == (e.class == "lod"), e.folder .. ": LoadOnDemand mismatch vs manifest")
        local set, order = tocLuaEntries(toc)
        assert(order[1] == "bootstrap.lua", e.folder .. ": bootstrap must be first")
        assert(readFile(e.folder .. "/bootstrap.lua") == template, e.folder .. ": bootstrap drift")

        -- disk coverage: every .lua under the folder is in exactly one TOC
        local p = io.popen(('find %q -name "*.lua" -type f'):format(e.folder))
        for path in p:lines() do
            local rel = path:gsub("^" .. e.folder .. "/", "")
            local inOwn = set[rel] or rel == "bootstrap.lua"
            local optRel = "../" .. e.folder .. "/" .. rel
            local inOptions = optionsSet[optRel]
            assert(inOwn or inOptions, "orphan file (in no TOC): " .. path)
            assert(not (inOwn and inOptions), "double-loaded file: " .. path)
        end
        p:close()
    end
end

-- core TOC must not reference moved dirs
local coreSet = tocLuaEntries("QUI.toc")
for norm in pairs(coreSet) do
    local dir = norm:match("^modules/([%w_]+)/")
    if dir then
        assert(dir == "layout" or dir == "ui" or dir == "integrations",
            "moved module still in QUI.toc: " .. norm)
    end
end

-- QUI_UI bundle guard: the merged cosmetic + utility addon. Most files are
-- eager ([Bootstrap]); bootstrap loads first; disk files are covered by either
-- QUI_UI.toc or QUI_Options.toc (settings); and the intra-bundle order keeps
-- the datatext registry ahead of its minimap/info-bar consumers.
--
-- Lazy tier (Task S4): the heavy Alts roster UI is untagged so it does NOT load
-- at startup — the first roster-open does LoadAddOn("QUI_UI") and pulls the whole
-- untagged remainder at once. The lazy set is EXACTLY these alts runtime files;
-- everything else (including the eager alts.lua + alts_trigger.lua) is [Bootstrap].
do
    local set, order, tier = tocLuaEntries("QUI_UI/QUI_UI.toc")

    -- The exact, closed set of files allowed to be untagged (lazy).
    local LAZY = {
        ["alts/roster_data.lua"]        = true,
        ["alts/views/shared.lua"]       = true,
        ["alts/views/window.lua"]       = true,
        ["alts/views/filter_popup.lua"] = true,
        ["alts/views/roster.lua"]       = true,
        ["alts/views/professions.lua"]  = true,
        ["alts/views/reputations.lua"]  = true,
        ["alts/views/weeklies.lua"]     = true,
        ["alts/views/currencies.lua"]   = true,
        ["alts/views/equipment.lua"]    = true,
        ["alts/views/search.lua"]       = true,
    }

    -- bootstrap-first and byte-identical to the shared template
    assert(order[1] == "bootstrap.lua", "QUI_UI: bootstrap must be first")
    assert(tier["bootstrap.lua"] == true, "QUI_UI: bootstrap.lua must be tagged [Bootstrap]")
    assert(readFile("QUI_UI/bootstrap.lua") == template, "QUI_UI: bootstrap drift")

    -- Every lazy entry must actually be present (untagged) and every other
    -- listed .lua must be eager ([Bootstrap]). No file may be both.
    for _, norm in ipairs(order) do
        if LAZY[norm] then
            assert(tier[norm] == false,
                "QUI_UI: lazy entry must be untagged (no [Bootstrap]): " .. norm)
        else
            assert(tier[norm] == true,
                "QUI_UI: non-lazy file must be eager [Bootstrap]: " .. norm)
        end
    end
    -- Coverage: every expected lazy file is present in the TOC.
    for lazyPath in pairs(LAZY) do
        assert(set[lazyPath], "QUI_UI: expected lazy file missing from TOC: " .. lazyPath)
    end
    -- The eager trigger stub must be present and tagged [Bootstrap].
    assert(tier["alts/alts_trigger.lua"] == true,
        "QUI_UI: alts/alts_trigger.lua must be eager [Bootstrap]")
    assert(tier["alts/alts.lua"] == true,
        "QUI_UI: alts/alts.lua must stay eager [Bootstrap]")

    -- disk coverage: every .lua under QUI_UI is in QUI_UI.toc OR QUI_Options.toc
    local p = io.popen('find "QUI_UI" -name "*.lua" -type f')
    for path in p:lines() do
        local rel = path:gsub("^QUI_UI/", "")
        local inOwn = set[rel] or rel == "bootstrap.lua"
        local inOptions = optionsSet["../QUI_UI/" .. rel]
        assert(inOwn or inOptions, "QUI_UI orphan file (in no TOC): " .. path)
        assert(not (inOwn and inOptions), "QUI_UI double-loaded file: " .. path)
    end
    p:close()

    -- ordering invariants: the datatext registry loads before the minimap
    -- 3-slot panel and the info bar that consume it.
    local function firstIndex(prefix)
        for i, norm in ipairs(order) do
            if norm:sub(1, #prefix) == prefix then return i end
        end
        return nil
    end
    local iData = firstIndex("datatexts/")
    local iMini = firstIndex("minimap/")
    local iInfo = firstIndex("infobar/")
    assert(iData, "QUI_UI: no datatexts/ files listed")
    assert(iMini, "QUI_UI: no minimap/ files listed")
    assert(iInfo, "QUI_UI: no infobar/ files listed")
    assert(iData < iMini, "QUI_UI: datatexts/ must load before minimap/")
    assert(iData < iInfo, "QUI_UI: datatexts/ must load before infobar/")
end

-- Group 1 guard: locale/search index addons stay index-only (engine lives in QUI_Options).
do
    local p = io.popen('ls -d QUI_OptionsSearch* 2>/dev/null')
    for folder in p:lines() do
        local _, order = tocLuaEntries(folder .. "/" .. folder .. ".toc")
        assert(#order == 1 and order[1] == "search_cache.lua",
            folder .. ": must contain only search_cache.lua (one-of-N index)")
    end
    p:close()
end

print("suite_toc_consistency_test OK")
