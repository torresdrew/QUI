---------------------------------------------------------------------------
-- QUI Module Registry
-- Central registry mapping modules to refresh functions, priorities,
-- groups, and import categories. Enables targeted refresh after selective
-- profile imports and ordered refresh on profile change.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local Registry = {}
ns.Registry = Registry

Registry._modules = {}     -- name → module definition
Registry._moduleOrder = nil -- sorted name list (built lazily)

---------------------------------------------------------------------------
-- REGISTRATION
---------------------------------------------------------------------------

--- Register a module with the registry.
--- @param name string Unique module identifier
--- @param def table { refresh=fn|table, priority=number, group=string, importCategories={...} }
---   refresh can be a single function OR a table of named functions:
---     refresh = ApplyAll                          -- single
---     refresh = { all = ApplyAll, auras = RefreshAuras }  -- named
---   When refresh is a table, RefreshAll/RefreshByCategories call the "all"
---   entry (or iterate all entries if no "all" key exists).
function Registry:Register(name, def)
    if not name or type(def) ~= "table" then return end
    def.name = name
    def.priority = def.priority or 50
    self._modules[name] = def
    self._moduleOrder = nil -- invalidate sort cache
end

---------------------------------------------------------------------------
-- INTERNAL SORT
---------------------------------------------------------------------------

function Registry:_RebuildOrder()
    local order = {}
    for name in pairs(self._modules) do
        order[#order + 1] = name
    end
    table.sort(order, function(a, b)
        local pa = self._modules[a].priority
        local pb = self._modules[b].priority
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    self._moduleOrder = order
end

--- Check if a module is registered.
--- @param name string Module identifier
--- @return boolean
function Registry:Has(name)
    return self._modules[name] ~= nil
end

---------------------------------------------------------------------------
-- REFRESH HOOKS
---------------------------------------------------------------------------

Registry._refreshHooks = {} -- name → { hookFn, ... }

--- Register a post-refresh hook for a module.
--- The hook fires after ANY refresh call targeting this module (default or named).
--- Used by anchoring and Layout Mode to react to module refreshes.
--- @param name string Module identifier to hook
--- @param hookFn function Callback to run after refresh
function Registry:HookRefresh(name, hookFn)
    if not self._refreshHooks[name] then
        self._refreshHooks[name] = {}
    end
    local hooks = self._refreshHooks[name]
    hooks[#hooks + 1] = hookFn
end

local function RunPostRefreshHooks(self, name)
    local hooks = self._refreshHooks[name]
    if hooks then
        for i = 1, #hooks do
            pcall(hooks[i])
        end
    end
end

---------------------------------------------------------------------------
-- REFRESH API
---------------------------------------------------------------------------

local function SafeCallRefresh(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("|cFFFF6666QUI:|r refresh error [" .. name .. "]: " .. tostring(err))
    end
end

--- Resolve the callable refresh function from a module definition.
--- If refresh is a table, returns the "all" entry or nil.
local function GetDefaultRefresh(m)
    local r = m.refresh
    if type(r) == "function" then return r end
    if type(r) == "table" then return r.all end
    return nil
end

--- Refresh a single module by name.
--- @param name string Module identifier
--- @param fnName string|nil Named sub-function (for table-valued refresh). Omit for default.
--- @param ... any Extra arguments forwarded to the refresh function.
function Registry:Refresh(name, fnName, ...)
    local m = self._modules[name]
    if not m then return end
    local r = m.refresh
    if not r then return end

    if fnName then
        -- Named sub-function lookup (refresh must be a table)
        if type(r) == "table" and r[fnName] then
            SafeCallRefresh(name .. "." .. fnName, r[fnName], ...)
        end
    else
        -- Default: call the function directly, or "all" entry from table
        local fn = GetDefaultRefresh(m)
        if fn then
            SafeCallRefresh(name, fn, ...)
        elseif type(r) == "table" then
            -- No "all" key — call every entry
            for subName, subFn in pairs(r) do
                SafeCallRefresh(name .. "." .. subName, subFn, ...)
            end
        end
    end

    RunPostRefreshHooks(self, name)
end

--- Refresh all modules, optionally filtered by group.
--- @param groupFilter string|nil Only refresh modules in this group (nil = all)
function Registry:RefreshAll(groupFilter)
    if not self._moduleOrder then self:_RebuildOrder() end
    for _, name in ipairs(self._moduleOrder) do
        local m = self._modules[name]
        if not groupFilter or m.group == groupFilter then
            local fn = GetDefaultRefresh(m)
            if fn then
                SafeCallRefresh(name, fn)
            elseif type(m.refresh) == "table" then
                for subName, subFn in pairs(m.refresh) do
                    SafeCallRefresh(name .. ":" .. tostring(subName), subFn)
                end
            end
            RunPostRefreshHooks(self, name)
        end
    end
end

---------------------------------------------------------------------------
-- OPTIONS PAGE REGISTRY
---------------------------------------------------------------------------

Registry._options = {}
Registry._optionsOrder = nil

--- Register an options page for automatic tab discovery.
--- @param key string Unique page identifier
--- @param def table { label=string, order=number, pageBuilder=function, hasSubTabs=boolean }
function Registry:RegisterOptions(key, def)
    if not key or type(def) ~= "table" then return end
    def.key = key
    def.order = def.order or 50
    self._options[key] = def
    self._optionsOrder = nil
end

--- Get all registered options pages sorted by order.
--- @return table Array of option page definitions
function Registry:GetOrderedOptions()
    if not self._optionsOrder then
        local order = {}
        for key in pairs(self._options) do
            order[#order + 1] = key
        end
        table.sort(order, function(a, b)
            local oa = self._options[a].order
            local ob = self._options[b].order
            if oa ~= ob then return oa < ob end
            return a < b
        end)
        self._optionsOrder = order
    end

    local result = {}
    for i, key in ipairs(self._optionsOrder) do
        result[i] = self._options[key]
    end
    return result
end

---------------------------------------------------------------------------
-- IMPORT CATEGORY REFRESH
---------------------------------------------------------------------------

--- Refresh only modules whose importCategories overlap with the given IDs.
--- Used by selective profile import to avoid refreshing unrelated modules.
--- @param categoryIDs table Array of category ID strings
function Registry:RefreshByCategories(categoryIDs)
    if not categoryIDs or #categoryIDs == 0 then return end

    local categorySet = {}
    for _, id in ipairs(categoryIDs) do
        categorySet[id] = true
    end

    if not self._moduleOrder then self:_RebuildOrder() end
    for _, name in ipairs(self._moduleOrder) do
        local m = self._modules[name]
        if m.importCategories then
            for _, catID in ipairs(m.importCategories) do
                if categorySet[catID] then
                    local fn = GetDefaultRefresh(m)
                    if fn then
                        SafeCallRefresh(name, fn)
                    elseif type(m.refresh) == "table" then
                        for subName, subFn in pairs(m.refresh) do
                            SafeCallRefresh(name .. ":" .. tostring(subName), subFn)
                        end
                    end
                    RunPostRefreshHooks(self, name)
                    break -- don't call refresh twice for same module
                end
            end
        end
    end
end

