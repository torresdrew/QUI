local function readAll(path)
    local handle = assert(io.open(path, "rb"))
    local contents = handle:read("*a")
    handle:close()
    return contents:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function fileExists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function dirname(path)
    return path:match("^(.*[/\\])") or ""
end

local loadSource = loadstring or load

local function findChunk(source, chunkName)
    local marker = "-- Inlined from " .. chunkName .. "\n"
    local markerStart, markerEnd = source:find(marker, 1, true)
    assert(markerStart, "missing consolidated chunk: " .. chunkName)

    local chunkStart = markerEnd + 1
    local nextMarker = source:find("\nend\n\ndo\n-- Inlined from ", chunkStart, true)
    local chunkEnd
    if nextMarker then
        chunkEnd = nextMarker - 1
    else
        local finalEnd = source:match("()\nend%s*$", chunkStart)
        assert(finalEnd, "missing end wrapper for consolidated chunk: " .. chunkName)
        chunkEnd = finalEnd - 1
    end
    return source:sub(chunkStart, chunkEnd)
end

return function(path, chunkName)
    local standalonePath = dirname(path) .. chunkName
    if fileExists(standalonePath) then
        local source = readAll(standalonePath)
        return assert(loadSource(source, "@" .. standalonePath))
    end

    local source = readAll(path)
    local chunk = findChunk(source, chunkName)
    return assert(loadSource(chunk, "@" .. path .. "#" .. chunkName))
end
