-- tests/unit/encounter_journal_font_scope_test.lua
-- Run: lua tests/unit/encounter_journal_font_scope_test.lua
--
-- The Encounter Journal contains parchment/body text with Blizzard-managed
-- font objects and adaptive sizing. Its QUI skin should apply frame chrome
-- without recursively replacing every content font.

-- luacheck: globals _G

local callbacks = {}
local calls = {}

_G.EncounterJournal = { name = "EncounterJournal" }

local function CreateStateTable()
    local tbl = setmetatable({}, { __mode = "k" })
    return tbl, function(key)
        local state = tbl[key]
        if not state then
            state = {}
            tbl[key] = state
        end
        return state
    end
end

local ns = {
    Helpers = {
        CreateStateTable = CreateStateTable,
        GetCore = function()
            return {
                db = {
                    profile = {
                        general = {
                            skinEncounterJournal = true,
                        },
                    },
                },
            }
        end,
    },
    Registry = {
        Register = function() end,
    },
}

ns.SkinBase = {
    RefreshFrameBackdropColors = function() end,
    IsSkinned = function() return false end,
    SkinButtonFrameTemplate = function(frame)
        calls.buttonFrame = frame
    end,
    SkinFrameText = function(frame, opts)
        calls[#calls + 1] = { frame = frame, opts = opts or {} }
    end,
    MarkSkinned = function(frame)
        calls.marked = frame
    end,
    OnAddOnLoaded = function(addon, callback)
        callbacks[addon] = callback
    end,
}

assert(loadfile("modules/skinning/frames/journals.lua"))("QUI", ns)
assert(type(callbacks.Blizzard_EncounterJournal) == "function", "Encounter Journal load hook must be registered")

callbacks.Blizzard_EncounterJournal()

assert(calls.buttonFrame == _G.EncounterJournal, "Encounter Journal must still get QUI frame chrome")
assert(calls.marked == _G.EncounterJournal, "Encounter Journal must be marked skinned")

for _, call in ipairs(calls) do
    assert(not (call.frame == _G.EncounterJournal and call.opts.recurse == true),
        "Encounter Journal skinning must not recursively replace content fonts")
end

print("OK: encounter_journal_font_scope_test")
