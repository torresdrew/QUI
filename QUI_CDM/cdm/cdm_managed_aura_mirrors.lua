-- QUI_CDM/cdm/cdm_managed_aura_mirrors.lua
-- Exact aura overlays for duplicate CDM placements. Blizzard's managed
-- CustomAuraContainer owns aura identity, visibility, stacks, and duration;
-- QUI owns only stable placement hosts and static presentation.
local _, ns = ...

local CDMManagedAuraMirrors = {}
ns.CDMManagedAuraMirrors = CDMManagedAuraMirrors

local InstanceMT = { __index = CDMManagedAuraMirrors }
local PARK_FILTER = { maxDuration = 0 }

local function AppendID(out, seen, value, isSecret)
    if type(value) ~= "number" or (isSecret and isSecret(value)) or seen[value] then return end
    seen[value] = true
    out[#out + 1] = value
end

function CDMManagedAuraMirrors.ResolveCandidateIDs(entry, isSecret)
    local out, seen = {}, {}
    if type(entry) ~= "table" then return out end
    AppendID(out, seen, entry.overrideSpellID, isSecret)
    AppendID(out, seen, entry.spellID, isSecret)
    if entry.type == nil or entry.type == "spell" then
        AppendID(out, seen, entry.id, isSecret)
    end
    local linked = entry.linkedSpellIDs
    if type(linked) == "table" then
        for i = 1, #linked do AppendID(out, seen, linked[i], isSecret) end
    end
    return out
end

local function CandidateFilter(spellID)
    return { includeSpellIDs = { [spellID] = true } }
end

function CDMManagedAuraMirrors.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _pools = setmetatable({}, { __mode = "k" }),
    }
    return setmetatable(self, InstanceMT)
end

function CDMManagedAuraMirrors:_GetPool(ownerContainer, allowCreate)
    local pool = self._pools[ownerContainer]
    if pool or not allowCreate then return pool end
    local createFrame = self._deps.createFrame
    if not createFrame then return nil end
    local auraContainer = createFrame("AuraContainer", nil, ownerContainer,
        "CustomAuraContainerTemplate")
    if not auraContainer then return nil end
    if auraContainer.SetSize then auraContainer:SetSize(1, 1) end
    if auraContainer.SetUnit then auraContainer:SetUnit("player") end
    if auraContainer.SetEnabled then auraContainer:SetEnabled(true) end
    if auraContainer.Show then auraContainer:Show() end
    pool = {
        auraContainer = auraContainer,
        records = {},
        generation = 0,
    }
    self._pools[ownerContainer] = pool
    return pool
end

function CDMManagedAuraMirrors:BeginPass(ownerContainer)
    local canCreate = not self._deps.canCreate or self._deps.canCreate(ownerContainer)
    local pool = self:_GetPool(ownerContainer, canCreate)
    if not pool then return false end
    pool.generation = pool.generation + 1
    return true
end

local function ParkRecord(pool, record)
    if record.parked then return end
    local auraContainer = pool.auraContainer
    for i = 1, #record.slots do
        auraContainer:SetAuraSlotCandidateFilters(record.slots[i].key, PARK_FILTER)
    end
    record.parked = true
end

function CDMManagedAuraMirrors:Acquire(ownerContainer, placementKey, entry, profile)
    local pool = self._pools[ownerContainer]
    if not pool then return nil end
    local ids = CDMManagedAuraMirrors.ResolveCandidateIDs(entry, self._deps.isSecret)
    if #ids == 0 then return nil end

    local record = pool.records[placementKey]
    if not record then
        local createFrame = self._deps.createFrame
        if not createFrame then return nil end
        local host = createFrame("Frame", nil, ownerContainer)
        if not host then return nil end
        record = { placementKey = placementKey, host = host, slots = {} }
        pool.records[placementKey] = record
    end

    local auraContainer = pool.auraContainer
    for i = 1, #ids do
        local spellID = ids[i]
        local slot = record.slots[i]
        if slot then
            auraContainer:SetAuraSlotFilterString(slot.key, "HELPFUL")
            auraContainer:SetAuraSlotCandidateFilters(slot.key, CandidateFilter(spellID))
            slot.spellID = spellID
        else
            local key = placementKey .. ":aura:" .. tostring(i)
            local host = record.host
            local styleFrame = self._deps.styleFrame
            local frame = auraContainer:AddAuraSlot(key, "HELPFUL", {
                candidateFilters = CandidateFilter(spellID),
                initializeFrame = function(button)
                    if styleFrame then styleFrame(button, profile or {}) end
                    if button.ClearAllPoints then button:ClearAllPoints() end
                    if button.SetAllPoints then
                        button:SetAllPoints(host)
                    elseif button.SetPoint then
                        button:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
                        button:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
                    end
                    if button.SetFrameLevel then
                        local base = host.GetFrameLevel and host:GetFrameLevel() or 0
                        -- First candidate is the highest-priority CDM identity.
                        button:SetFrameLevel(base + 32 - i)
                    end
                    -- The owned CDM icon beneath owns tooltip/click behavior.
                    if button.EnableMouse then button:EnableMouse(false) end
                    if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
                    if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(false) end
                end,
            })
            slot = { key = key, frame = frame, spellID = spellID }
            record.slots[i] = slot
        end
    end
    for i = #ids + 1, #record.slots do
        auraContainer:SetAuraSlotCandidateFilters(record.slots[i].key, PARK_FILTER)
    end

    record.entry = entry
    record.generation = pool.generation
    record.parked = false
    record.profile = profile
    if record.host.Show then record.host:Show() end
    return record
end

function CDMManagedAuraMirrors:Position(record, baseIcon, ownerContainer, x, y, w, h, rowConfig)
    if not (record and record.host and baseIcon) then return false end
    local canMutate = self._deps.canMutate
    if canMutate and not canMutate(record.host) then return false end
    local host = record.host
    host:ClearAllPoints()
    host:SetPoint("CENTER", ownerContainer, "CENTER", x, y)
    if host.SetSize and w and h then host:SetSize(w, h) end
    if host.Show then host:Show() end
    local positionBase = self._deps.positionBase
    if positionBase then positionBase(baseIcon, host, rowConfig) end
    local restyleFrame = self._deps.restyleFrame
    if restyleFrame and not (self._deps.aurasAreSecret and self._deps.aurasAreSecret()) then
        for i = 1, #record.slots do
            local slot = record.slots[i]
            if slot.frame then restyleFrame(slot.frame, rowConfig or record.profile or {}) end
        end
    end
    return true
end

function CDMManagedAuraMirrors:EndPass(ownerContainer)
    local pool = self._pools[ownerContainer]
    if not pool then return true end
    local canMutate = self._deps.canMutate
    for _, record in pairs(pool.records) do
        if record.generation ~= pool.generation then
            ParkRecord(pool, record)
            if record.host.Hide and (not canMutate or canMutate(record.host)) then
                record.host:Hide()
            end
        end
    end
    return true
end

return CDMManagedAuraMirrors
