local ADDON_NAME, ns = ...

-- Unpack a generated payload that ships as a long-bracket STRING rather than
-- a Lua table. The generators emit the table body only; the `return ` prefix
-- is added here so the emitted text stays a bare table constructor.
--
-- Why payloads are packed at all: an unused chunk lexes ONE token instead of
-- compiling thousands of table fields, and the string is collectable the
-- moment its consumer drops the reference.
--
-- Cost of packing: `luac -p` no longer validates the contents, so every packed
-- payload needs a gate that loads it. Two families exist, and they do NOT
-- share one:
--
--   * Payloads unpacked through ns.Unpack -- today exactly one, the options
--     search cache (QUI_Options/search_cache.lua, compiled on first search
--     by QUI_Options/framework.lua). Those MUST be covered by
--     tests/unit/packed_payload_shape_test.lua.
--
--   * The ten locale overlays (core/locale/<loc>.lua). Packed the same way,
--     but they do NOT call ns.Unpack: each carries its own inline
--     `assert(loadstring("return " .. [==[...]==], "@core/locale/<loc>.lua"))()`.
--     That is TOC load order, not preference -- the locale block is
--     QUI.toc:80-104 and this file is line 109, so ns.Unpack does not exist
--     yet when an overlay runs, and the block cannot move (locale.lua captures
--     ns.LocaleData.active as an upvalue and login-time consumers read ns.L).
--     Their lost `luac -p` coverage is made up by
--     tools/i18n/test_overlay_roundtrip.py, which loads every overlay and
--     re-emits it through the real writer byte for byte, and
--     tests/unit/search_cache_locale_consistency_test.lua, which loads each
--     one as the active locale and checks its key hit rate against the cache.
--
-- ns.Unpack guarantees a table or raises -- never nil, never a bare scalar --
-- so later tasks can trust the return value without re-checking its type.
function ns.Unpack(packed, chunkname)
    local chunk, err = loadstring("return " .. packed, chunkname)
    if not chunk then
        error(("ns.Unpack: %s: %s"):format(tostring(chunkname), tostring(err)), 0)
    end
    local result = chunk()
    if type(result) ~= "table" then
        error(("ns.Unpack: %s: payload did not evaluate to a table (got %s)")
            :format(tostring(chunkname), type(result)), 0)
    end
    return result
end
