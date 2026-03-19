---------------------------------------------------------------------------
-- QUI Deferred Initialization
-- Groups of init functions that run on first demand instead of at login.
-- Each group is triggered by its subsystem's entry point (e.g., Layout
-- Mode Open, Options Show). Files register via ns.RegisterDeferredInit()
-- and the trigger calls ns.EnsureDeferredGroup().
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local groups = {}

--- Register a deferred init function in a named group.
--- If the group has already been loaded, the function runs immediately.
--- @param group string Group name (e.g., "layoutmode", "options")
--- @param fn function The init function to defer
function ns.RegisterDeferredInit(group, fn)
    local g = groups[group]
    if not g then
        g = { loaded = false, inits = {} }
        groups[group] = g
    end
    if g.loaded then
        fn()
    else
        g.inits[#g.inits + 1] = fn
    end
end

--- Run all deferred inits for a group (idempotent).
--- @param group string Group name
function ns.EnsureDeferredGroup(group)
    local g = groups[group]
    if not g or g.loaded then return end
    g.loaded = true
    for i, fn in ipairs(g.inits) do
        fn()
        g.inits[i] = nil
    end
end
