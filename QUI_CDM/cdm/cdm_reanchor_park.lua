-- QUI_CDM/cdm/cdm_reanchor_park.lua
-- Viewer parking for the re-anchor engine, decoupled from the mirror's
-- SuppressViewers. Alpha-0 the Blizzard CooldownViewer frames so unclaimed /
-- newly-pooled item frames don't flash at their native positions. Re-anchored
-- children opt out via SetIgnoreParentAlpha(true) (the decorator's lift), so they
-- stay visible. A SetAlpha hook re-asserts 0 when Blizzard re-shows the viewer.
-- DI'd + idempotent; this replaces the mirror's viewer-hide once the mirror is gone.
local _, ns = ...

local CDMReanchorPark = {}
ns.CDMReanchorPark = CDMReanchorPark

local InstanceMT = { __index = CDMReanchorPark }

function CDMReanchorPark.New(deps)
    deps = deps or {}
    local self = {
        _deps = deps,
        _keys = deps.keys or { "essential", "utility", "buff", "trackedBar" },
        _parked = setmetatable({}, { __mode = "k" }),
    }
    return setmetatable(self, InstanceMT)
end

-- Park one viewer: force alpha 0 and (once) hook SetAlpha to re-assert 0 so a
-- Blizzard re-show doesn't unpark it. Combat-safe (alpha is unprotected).
function CDMReanchorPark:Park(viewer)
    if not viewer then return false end
    local deps = self._deps
    if not self._parked[viewer] then
        self._parked[viewer] = true
        local hooksec = deps.hooksecurefunc
        if hooksec and viewer.SetAlpha then
            local park = self
            hooksec(viewer, "SetAlpha", function(v, a)
                if park._reasserting then return end
                if a ~= 0 then
                    park._reasserting = true
                    v:SetAlpha(0)
                    park._reasserting = false
                end
            end)
        end
    end
    if viewer.SetAlpha then
        self._reasserting = true
        viewer:SetAlpha(0)
        self._reasserting = false
    end
    return true
end

function CDMReanchorPark:ParkAll(getViewer)
    if not getViewer then return end
    for i = 1, #self._keys do
        self:Park(getViewer(self._keys[i]))
    end
end

function CDMReanchorPark:IsParked(viewer)
    return self._parked[viewer] == true
end
