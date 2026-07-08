-- tests/unit/buffborders_no_secureauraheader_test.lua
-- PTR4 removed SecureAuraHeaderTemplate from Mainline. The buff right-click
-- cancel path is now SetCancelAuraButtons on engine-created AuraButtons.
local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return (data:gsub("\r\n", "\n"))
end
local src = readAll("QUI_ActionBars/actionbars/buffborders.lua")

assert(not src:find("SecureAuraHeaderTemplate", 1, true), "SecureAuraHeaderTemplate removed in PTR4")
assert(not src:find("buffCancelHeader", 1, true), "cancel-header machinery must be fully deleted")
assert(not src:find("initialConfigFunction", 1, true), "no secure-header initialConfigFunction remains")
assert(not src:find("RegisterStateDriver", 1, true), "cancel visibility driver deleted with the header")
assert(src:find("cancelButtons", 1, true), "buff group must request click-cancel via cancelButtons")
assert(not src:find("AddAuraFilter", 1, true), "AddAuraFilter replaced by AuraSkin.Configure groups")
assert(src:find("AuraSkin.Configure", 1, true), "must configure containers via AuraSkin.Configure")
assert(src:find("SORT_TRANSLATIONS", 1, true), "sort dropdown must feed AddAuraGroup sortMethod")

-- buffSortReverse must not fall through to the debuff toggle (and/or pitfall):
-- BuildZoneGroups must branch explicitly on isBuff for sortRev, not
-- `isBuff and settings.buffSortReverse or settings.debuffSortReverse` (that
-- collapses to the debuff toggle whenever buffSortReverse is false).
assert(not src:find("isBuff and settings.buffSortReverse or settings.debuffSortReverse", 1, true),
    "buff/debuff sortReverse must not use the and/or fallthrough idiom")
print("buffborders_no_secureauraheader_test OK")
