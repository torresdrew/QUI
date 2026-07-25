-- tests/unit/cdm_managed_aura_mirrors_test.lua
-- Run: lua tests/unit/cdm_managed_aura_mirrors_test.lua
local ns = {}
local loadChunk = dofile("tests/helpers/load_cdm_consolidated_chunk.lua")
loadChunk("QUI_CDM/cdm/cdm_managed_aura_mirrors.lua", "cdm_managed_aura_mirrors.lua")("QUI", ns)
local M = assert(ns.CDMManagedAuraMirrors)

local createdAuraContainers, createdHosts, styled = {}, {}, {}
local function frameBase()
    return {
        shown = false,
        points = {},
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetSize = function(self, w, h) self.size = { w, h } end,
        ClearAllPoints = function(self) self.points = {} end,
        SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end,
        SetAllPoints = function(self, target) self.allPoints = target end,
        GetFrameLevel = function() return 10 end,
        SetFrameLevel = function(self, level) self.level = level end,
        EnableMouse = function(self, value) self.mouse = value end,
        SetMouseClickEnabled = function(self, value) self.click = value end,
        SetMouseMotionEnabled = function(self, value) self.motion = value end,
    }
end

local function createFrame(kind, _, parent)
    if kind == "AuraContainer" then
        local c = frameBase()
        c.filters = {}
        c.added = {}
        c.SetUnit = function(self, unit) self.unit = unit end
        c.SetEnabled = function(self, enabled) self.enabled = enabled end
        c.AddAuraSlot = function(self, key, filter, options)
            local button = frameBase()
            options.initializeFrame(button)
            self.added[#self.added + 1] = { key = key, filter = filter, options = options, frame = button }
            self.filters[key] = options.candidateFilters
            return button
        end
        c.SetAuraSlotFilterString = function(self, key, filter) self.lastFilter = { key, filter } end
        c.SetAuraSlotCandidateFilters = function(self, key, filters) self.filters[key] = filters end
        createdAuraContainers[#createdAuraContainers + 1] = c
        return c
    end
    local host = frameBase()
    host.parent = parent
    createdHosts[#createdHosts + 1] = host
    return host
end

local manager = M.New({
    createFrame = createFrame,
    canCreate = function() return true end,
    canMutate = function() return true end,
    styleFrame = function(frame, profile) styled[#styled + 1] = { frame, profile } end,
    positionBase = function(icon, host, rowConfig)
        icon.host, icon.rowConfig = host, rowConfig
    end,
})
local owner = {}
assert(manager:BeginPass(owner) == true, "first pass creates the managed container")
local entry = { type = "spell", id = 100, overrideSpellID = 101, linkedSpellIDs = { 102, 100 } }
local record = manager:Acquire(owner, "essential:1:spell:100", entry, { iconSize = 32 })
assert(record and #record.slots == 3, "one exact managed slot is created per unique priority ID")
assert(#createdAuraContainers == 1 and #createdHosts == 1, "container and stable placement host are pooled")
assert(createdAuraContainers[1].unit == "player" and createdAuraContainers[1].enabled == true,
    "managed aura source is the enabled player unit")
assert(record.slots[1].spellID == 101 and record.slots[2].spellID == 100
    and record.slots[3].spellID == 102, "candidate priority is override, primary, linked")
assert(record.slots[1].frame.allPoints == record.host and record.slots[1].frame.mouse == false,
    "restricted aura child anchors at birth and leaves interaction to the base icon")

local base = {}
assert(manager:Position(record, base, owner, 4, -5, 30, 20, { size = 30 }) == true,
    "placement moves the stable host and positions the owned base")
assert(record.host.points[1][2] == owner and record.host.size[1] == 30 and record.host.size[2] == 20,
    "host receives the layout rect")
assert(base.host == record.host, "owned base follows the stable host")

manager:EndPass(owner)
assert(record.parked == false, "used record remains live at pass end")
manager:BeginPass(owner)
manager:EndPass(owner)
assert(record.parked == true and record.host.shown == false,
    "unused record is filter-parked and its host hidden")
for i = 1, #record.slots do
    assert(createdAuraContainers[1].filters[record.slots[i].key].maxDuration == 0,
        "every retired exact slot receives the impossible park filter")
end

local blocked = M.New({ createFrame = createFrame, canCreate = function() return false end })
assert(blocked:BeginPass({}) == false, "first-time container creation fails closed when forbidden")

print("OK: cdm_managed_aura_mirrors_test")
