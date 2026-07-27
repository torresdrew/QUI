-- Loads the group-frame event dispatcher out of groupframes.lua into a
-- caller-supplied environment.
--
-- Two regions are needed and they must share one env: the "THROTTLE:
-- Trailing-edge flush" section builds _state.throttleChannels and
-- _state.ThrottleAllows, which OnEvent then reads on every unit event. Loading
-- OnEvent alone would leave the throttle gate nil.
--
-- The env must supply CreateFrame before this runs — the throttle section
-- creates its flush frame at load time.

local function readAll(path)
    local handle = assert(io.open(path, "rb"))
    local contents = handle:read("*a")
    handle:close()
    return contents:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function loadIn(chunk, name, env)
    if setfenv then  -- Lua 5.1
        local fn = assert(loadstring(chunk, name))
        setfenv(fn, env)
        return fn
    end
    return assert(load(chunk, name, "t", env))
end

local SOURCE_PATH = "QUI_GroupFrames/groupframes/groupframes.lua"

-- Returns OnEvent, and (via the env) the flush frame the throttle section made.
return function(env)
    local source = readAll(SOURCE_PATH)

    local throttleStart = assert(source:find("\n-- THROTTLE: Trailing-edge flush\n", 1, true),
        "throttle-flush section banner should exist")
    local throttleStop = assert(source:find("\n-- EVENTS: Centralized event dispatch\n", throttleStart, true),
        "throttle-flush section should end at the event-dispatch banner")
    local throttleSource = source:sub(throttleStart, throttleStop)

    local onEventStart = assert(source:find("local function OnEvent(self, event, arg1, ...)", 1, true),
        "OnEvent should exist")
    local onEventStop = assert(source:find("\neventFrame:SetScript(\"OnEvent\", OnEvent)", onEventStart, true),
        "OnEvent should end before eventFrame:SetScript")
    local onEventSource = source:sub(onEventStart, onEventStop - 1)

    local chunk = throttleSource .. "\n" .. onEventSource .. "\nreturn OnEvent\n"
    return loadIn(chunk, "@" .. SOURCE_PATH .. "#dispatch", env)()
end
