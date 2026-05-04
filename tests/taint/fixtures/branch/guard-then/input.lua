local info = C_Spell.GetSpellCharges(1)
if not Helpers.IsSecretValue(info) then
    local n = info + 1
    return n
end
return 0
