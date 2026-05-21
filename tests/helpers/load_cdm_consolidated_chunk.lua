local function readAll(path)
    local handle = assert(io.open(path, "rb"))
    local contents = handle:read("*a")
    handle:close()
    return contents:gsub("\r\n", "\n"):gsub("\r", "\n")
end

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
    local source = readAll(path)
    local chunk = findChunk(source, chunkName)
    return assert(loadstring(chunk, "@" .. path .. "#" .. chunkName))
end
