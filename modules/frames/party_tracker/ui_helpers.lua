--[[
    QUI Party Tracker — UI Helpers
    Shared icon layering helpers for party-frame tracker elements.
]]

local ADDON_NAME, ns = ...

local PARTY_TRACKER_ICON_LEVEL_OFFSET = 8

function ns.PartyTracker_SyncIconLayer(icon, parent)
    parent = parent or (icon and icon:GetParent())
    if not icon or not parent then return end

    -- Match the normal group-frame icon stack so fullscreen UI like the
    -- world map sits above these trackers the same way it does other icons.
    local anchorFrame = parent.healthBar or parent
    local strata = anchorFrame.GetFrameStrata and anchorFrame:GetFrameStrata()
    if strata then
        icon:SetFrameStrata(strata)
    end

    local baseLevel = anchorFrame.GetFrameLevel and anchorFrame:GetFrameLevel() or 0
    icon:SetFrameLevel(baseLevel + PARTY_TRACKER_ICON_LEVEL_OFFSET)
end
