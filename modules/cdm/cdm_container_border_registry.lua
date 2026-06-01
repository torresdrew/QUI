-- Border Coloring registry: CDM per-row icon containers (multi-instance).
--
-- The per-row icon border color is stored on each row table (row1/row2/row3)
-- of the built-in cooldown containers and every unified/custom container.
-- The resolver reads borderColorSource + borderColor (prefix ""); migration
-- v40 renames the legacy per-row borderColorTable onto borderColor and stamps
-- borderColorSource = "custom" so existing per-row colors are preserved.
local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

-- Collect every per-row settings table that drives icon borders. Returns the
-- SAME row tables that hold the keys so migration + bulk-apply mutate them in
-- place. Idempotent: migration skips any table already carrying the source key.
local function CollectContainerRows(profile)
    local out = {}
    local ncdm = profile and profile.ncdm
    if type(ncdm) ~= "table" then return out end

    local seen = {}
    local function addRows(container)
        if type(container) ~= "table" then return end
        for i = 1, 3 do
            local rowTable = container["row" .. i]
            if type(rowTable) == "table" and not seen[rowTable] then
                seen[rowTable] = true
                out[#out + 1] = rowTable
            end
        end
    end

    -- Built-in top-level containers (the live tables GetContainerDB returns first).
    addRows(ncdm.essential)
    addRows(ncdm.utility)

    -- Unified containers mirror + any custom containers.
    if type(ncdm.containers) == "table" then
        for _, container in pairs(ncdm.containers) do
            addRows(container)
        end
    end

    return out
end

if Helpers and Helpers.BorderRegistry then
    Helpers.BorderRegistry.Register({
        key      = "cdmContainers",
        label    = "CDM Icon Containers",
        category = "CDM",
        prefix   = "",
        multi    = true,
        db       = function(p)
            local insts = CollectContainerRows(p)
            return insts and insts[1]
        end,
        instances = CollectContainerRows,
        refresh  = function() if _G.QUI_RefreshNCDM then _G.QUI_RefreshNCDM() end end,
        legacy   = { table = "borderColorTable" },
    })
end
