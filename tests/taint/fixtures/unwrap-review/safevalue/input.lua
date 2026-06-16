local info = C_Spell.GetSpellCharges(1)
local n = Helpers.SafeValue(info, 0)
return n
