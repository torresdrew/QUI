local _, ns = ...

---------------------------------------------------------------------------
-- CDM Icon Cooldown Policy
--
-- Private controller used by CDMIcons. It owns icon-local GCD swipe flags.
---------------------------------------------------------------------------

local CDMIconCooldownPolicy = {}
ns.CDMIconCooldownPolicy = CDMIconCooldownPolicy

function CDMIconCooldownPolicy.Create()
    local controller = {}

    function controller:MarkGCDSwipe(icon)
        if not icon then return end
        icon._showingGCDSwipe = true
        icon._showingRealCooldownSwipe = nil
    end

    function controller:ClearGCDSwipe(icon)
        if not icon then return end
        icon._showingGCDSwipe = nil
    end

    return controller
end
