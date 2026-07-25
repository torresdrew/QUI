-- tests/unit/safecall_migration_t45b_test.lua
-- Source-text contract pins for Task 45b: QUI_Chat fallback discrimination +
-- mechanical pcall->ns.SafeCall migration. Pins occurrence counts of
-- ns.SafeCall("<policy>" per file/policy, spot-pins the two duplicated
-- FormatString conversions (message_format.lua + message_capture.lua),
-- chat.lua:405's URL-gsub fallback-to-original-text retention, the
-- combat_log_tab.lua geometry-unwrap discipline (existence guards, no
-- SafeCall on provably-non-throwing unprotected-frame setters), the
-- blizzard_suppress.lua uniform best-effort-style count, and confirms the
-- 10 analyzer-provable secret probe-read idiom sites in message_format.lua
-- were left untouched (SKIP RULE compliance spot checks).
-- Run: lua5.1 tests/unit/safecall_migration_t45b_test.lua
local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a"); f:close()
    return (d:gsub("\r\n", "\n"))
end

local fails = 0
local function check(name, ok)
    if ok then print("  ok  " .. name)
    else fails = fails + 1; print("FAIL  " .. name) end
end

local function countOf(src, needle)
    local n = 0
    local from = 1
    while true do
        local s = src:find(needle, from, true)
        if not s then break end
        n = n + 1
        from = s + #needle
    end
    return n
end

---------------------------------------------------------------------------
-- File: QUI_Chat/chat/message_format.lua
-- 28 converted (16 best-effort-style + 11 chain-next + 1 report) across the
-- 38 examined sites; 10 secret probe-read idiom sites (SKIP RULE) untouched.
---------------------------------------------------------------------------
local mf = readAll("QUI_Chat/chat/message_format.lua")

check("message_format.lua: 28x ns.SafeCall( total (38 examined - 10 SKIPped)",
    (countOf(mf, "ns.SafeCall(") + countOf(mf, "ns.SafeCallMethod(")) == 28)
check("message_format.lua: 16x ns.SafeCall(\"best-effort-style\"",
    (countOf(mf, 'ns.SafeCall("best-effort-style"') + countOf(mf, 'ns.SafeCallMethod("best-effort-style"')) == 16)
check("message_format.lua: 11x ns.SafeCall(\"chain-next\"",
    (countOf(mf, 'ns.SafeCall("chain-next"') + countOf(mf, 'ns.SafeCallMethod("chain-next"')) == 11)
check("message_format.lua: 1x ns.SafeCall(\"report\" (FormatString)",
    (countOf(mf, 'ns.SafeCall("report"') + countOf(mf, 'ns.SafeCallMethod("report"')) == 1)
check("message_format.lua: 10x bare pcall( remain (analyzer-provable secret probe-reads only)",
    countOf(mf, "pcall(") == 10)

-- FormatString duplicated idiom: report policy, nil-fallback flow kept.
check("message_format.lua: FormatString converted to ns.SafeCall(\"report\", string.format, ...)",
    mf:find('local ok, formatted = ns.SafeCall("report", string.format, fmt, ...)\n    if not ok then return nil end\n    return formatted', 1, true) ~= nil)

-- SKIP RULE spot checks: all 10 statement-split secret probe-read idiom
-- sites left inline (result feeds an IsSecret truth-test in the same scope).
check("message_format.lua: SKIP — SeedUnitClass UnitClass probe untouched",
    mf:find('local ok, _, englishClass = pcall(_G.UnitClass, unit)\n    if not ok or IsSecret(englishClass)', 1, true) ~= nil)
check("message_format.lua: SKIP — SeedUnitClass UnitName probe untouched",
    mf:find('local okName, name, server = pcall(_G.UnitName, unit)\n        if okName and not IsSecret(name)', 1, true) ~= nil)
check("message_format.lua: SKIP — SeedGuildMemberClasses Club.GetGuildClubId probe untouched",
    mf:find('local okClub, clubId = pcall(Club.GetGuildClubId)\n    if not okClub or IsSecret(clubId)', 1, true) ~= nil)
check("message_format.lua: SKIP — SeedGuildMemberClasses Club.GetClubMembers probe untouched",
    mf:find('local okMembers, members = pcall(Club.GetClubMembers, clubId)\n    if not okMembers or IsSecret(members)', 1, true) ~= nil)
check("message_format.lua: SKIP — SeedGuildMemberClasses Club.GetMemberInfo probe untouched",
    mf:find('local okInfo, info = pcall(Club.GetMemberInfo, clubId, memberId)\n            if okInfo and not IsSecret(info)', 1, true) ~= nil)
check("message_format.lua: SKIP — SeedGuildMemberClasses CreatureInfo.GetClassInfo probe untouched",
    mf:find('local okClass, classInfo = pcall(CreatureInfo.GetClassInfo, classID)\n                    if okClass and not IsSecret(classInfo)', 1, true) ~= nil)
check("message_format.lua: SKIP — ResolveSenderClass GetPlayerInfoByGUID probe untouched",
    mf:find('local ok, _, englishClass = pcall(_G.GetPlayerInfoByGUID, guid)', 1, true) ~= nil)
check("message_format.lua: SKIP — ResolveSenderClass UnitClassFromGUID probe untouched",
    mf:find('local ok, _, englishClass = pcall(_G.UnitClassFromGUID, guid)', 1, true) ~= nil)
check("message_format.lua: SKIP — ColorizeSenderName WrapTextInColorCode probe untouched",
    mf:find('local ok2, wrapped = pcall(color.WrapTextInColorCode, color, text)\n            -- Probe before the truth-test', 1, true) ~= nil)
check("message_format.lua: SKIP — DiscordNameColorize GetColorForChatType probe untouched",
    mf:find('local ok, colorInfo = pcall(CI.GetColorForChatType, "DISCORD_PLAYER_NAME")\n        if ok and not IsSecret(colorInfo)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_Chat/chat/message_capture.lua
-- 8/8 converted (0 SKIPped — no site here matches the secret probe-read idiom).
---------------------------------------------------------------------------
local mc = readAll("QUI_Chat/chat/message_capture.lua")

check("message_capture.lua: 8x ns.SafeCall( total (all examined sites converted)",
    (countOf(mc, "ns.SafeCall(") + countOf(mc, "ns.SafeCallMethod(")) == 8)
check("message_capture.lua: NO bare pcall( remains anywhere in file",
    mc:find("pcall(", 1, true) == nil)
check("message_capture.lua: FormatString converted to ns.SafeCall(\"report\", string.format, ...) (dup of message_format.lua, NOT deduped)",
    mc:find('local ok, formatted = ns.SafeCall("report", string.format, fmt, ...)\n    if not ok then return nil end\n    return formatted', 1, true) ~= nil)
check("message_capture.lua: SetLastTellTarget sink-forward (result was already fully discarded)",
    mc:find('ns.SafeCall("sink-forward", CFU.SetLastTellTarget, p.sender, typeKey)', 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_Chat/chat/chat.lua
-- 8/8 converted: 5x chain-next (timestamp CVar fallback chain, brief said
-- "7 remaining" as an orientation estimate; per-site audit found 8 legit
-- sites, all convertible — see task-45b-report.md) + 1x chain-next
-- (WrapChatText) + 1x report (URL-gsub, fallback-to-original-text kept) +
-- 1x bulkhead (RefreshAll hooks loop).
---------------------------------------------------------------------------
local cl = readAll("QUI_Chat/chat/chat.lua")

check("chat.lua: 8x ns.SafeCall( total",
    (countOf(cl, "ns.SafeCall(") + countOf(cl, "ns.SafeCallMethod(")) == 8)
check("chat.lua: NO bare pcall( remains anywhere in file",
    cl:find("pcall(", 1, true) == nil)
check("chat.lua: 6x ns.SafeCall(\"chain-next\" (5x timestamp CVar chain + WrapChatText)",
    (countOf(cl, 'ns.SafeCall("chain-next"') + countOf(cl, 'ns.SafeCallMethod("chain-next"')) == 6)
check("chat.lua: 1x ns.SafeCall(\"report\" (URL-gsub closure)",
    (countOf(cl, 'ns.SafeCall("report"') + countOf(cl, 'ns.SafeCallMethod("report"')) == 1)
check("chat.lua: 1x ns.SafeCall(\"bulkhead\" (RefreshAll modifier hooks loop)",
    (countOf(cl, 'ns.SafeCall("bulkhead"') + countOf(cl, 'ns.SafeCallMethod("bulkhead"')) == 1)

-- chat.lua:405 URL-gsub wrap: secret already ruled out at :396 (IsSecret(text)
-- check above), so a regex bug in the wrap closure must surface (report), and
-- the ORIGINAL text fallback on failure is unchanged.
check("chat.lua: URL-gsub closure converted to ns.SafeCall(\"report\", function() ... end)",
    cl:find('local success, result = ns.SafeCall("report", function()', 1, true) ~= nil)
check("chat.lua: URL-gsub original-text fallback retained on failure (`else return text, false end`)",
    cl:find("if success then\n        return result, result ~= text\n    else\n        return text, false\n    end", 1, true) ~= nil)

-- RefreshAll bulkhead: SafeCall's own onFailure forwarding replaces the old
-- manual `if not ok and geterrorhandler then geterrorhandler()(err) end`.
check("chat.lua: RefreshAll hooks loop converted, manual error-forward removed (SafeCall forwards internally)",
    cl:find('for i = 1, #hooks do\n            ns.SafeCall("bulkhead", hooks[i])\n        end', 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_Chat/chat/combat_log_tab.lua
-- 22 examined: 16 geometry-wrap sites UNWRAPPED (existence guards, no
-- SafeCall — module header + Embed()'s own comment prove ChatFrame2/the
-- quick-bar are unprotected and these calls are outside any combat-locked
-- path) + 6 combat/SecureHandler sites converted to best-effort-style
-- (SecureHandlerBaseTemplate creation/SetFrameRef/Execute + the two
-- InCombatLockdown()-branch/fallback cf.Show calls + LoadAddOn).
---------------------------------------------------------------------------
local clt = readAll("QUI_Chat/chat/combat_log_tab.lua")

check("combat_log_tab.lua: 6x ns.SafeCall(\"best-effort-style\" (combat/secure-handler sites)",
    (countOf(clt, 'ns.SafeCall("best-effort-style"') + countOf(clt, 'ns.SafeCallMethod("best-effort-style"')) == 6)
check("combat_log_tab.lua: NO bare pcall( remains anywhere in file",
    clt:find("pcall(", 1, true) == nil)

-- Combat/secure-handler CONVERTED sites.
check("combat_log_tab.lua: SecureShowCycle locked-branch cf.Show converted",
    clt:find('if not (cf.IsShown and cf:IsShown()) and cf.Show then\n            ns.SafeCallMethod("best-effort-style", cf, "Show")\n        end\n        QueueRegenCycle()', 1, true) ~= nil)
check("combat_log_tab.lua: secureShowDriver CreateFrame(SecureHandlerBaseTemplate) converted",
    clt:find('ns.SafeCall("best-effort-style", _G.CreateFrame, "Frame", "QUI_CombatLogSecureShow"', 1, true) ~= nil)
check("combat_log_tab.lua: SetFrameRef converted",
    clt:find('ns.SafeCallMethod("best-effort-style", secureShowDriver, "SetFrameRef", "quiCombatLog", cf)', 1, true) ~= nil)
check("combat_log_tab.lua: secure Execute snippet converted",
    clt:find('ns.SafeCallMethod("best-effort-style", secureShowDriver, "Execute", [=[', 1, true) ~= nil)
check("combat_log_tab.lua: SecureShowCycle fallback (non-locked) cf.Show converted",
    clt:find('-- poison every later filter apply for the session.\n    if not (cf.IsShown and cf:IsShown()) and cf.Show then\n        ns.SafeCallMethod("best-effort-style", cf, "Show")\n    end\nend', 1, true) ~= nil)
check("combat_log_tab.lua: EnsureLoaded LoadAddOn(\"Blizzard_CombatLog\") converted",
    clt:find('ns.SafeCall("best-effort-style", _G.C_AddOns.LoadAddOn, "Blizzard_CombatLog")', 1, true) ~= nil)

-- Geometry-wrap UNWRAPPED sites (existence guards, direct method call).
check("combat_log_tab.lua: ReassertJustify unwrapped (cf:SetJustifyH direct call)",
    clt:find('if cf.SetJustifyH then\n        cf:SetJustifyH(stockJustifyH or "LEFT")\n    end\nend', 1, true) ~= nil)
check("combat_log_tab.lua: RefreshFont SetFontObject unwrapped",
    clt:find("cf:SetFontObject(fo)\n    ReassertJustify(cf)", 1, true) ~= nil)
check("combat_log_tab.lua: SetFont durability hook SetFontObject unwrapped",
    clt:find("self:SetFontObject(cur)\n                ReassertJustify(self)", 1, true) ~= nil)
check("combat_log_tab.lua: StripChrome bg SetParent unwrapped",
    clt:find('if bg and bg.SetParent then bg:SetParent(park) end', 1, true) ~= nil)
check("combat_log_tab.lua: Embed quick-button bar SetParent/ClearAllPoints/SetPoint unwrapped",
    clt:find('if qb.SetParent then qb:SetParent(container) end\n    if qb.ClearAllPoints then qb:ClearAllPoints() end\n    if smf and qb.SetPoint then\n        qb:SetPoint("TOPLEFT", smf, "TOPLEFT", 0, 0)\n        qb:SetPoint("TOPRIGHT", smf, "TOPRIGHT", 0, 0)\n    end', 1, true) ~= nil)
check("combat_log_tab.lua: Embed ChatFrame2 SetParent/ClearAllPoints/SetPoint unwrapped",
    clt:find('if cf.SetParent then cf:SetParent(container) end\n    if cf.ClearAllPoints then cf:ClearAllPoints() end\n    if cf.SetPoint then cf:SetPoint("TOPLEFT", qb, "BOTTOMLEFT", 0, -2) end', 1, true) ~= nil)
check("combat_log_tab.lua: Deactivate cf/qb SetParent-to-park unwrapped",
    clt:find('if cf and cfPark and cf.SetParent then cf:SetParent(cfPark) end\n    if qb and park and qb.SetParent then qb:SetParent(park) end', 1, true) ~= nil)
check("combat_log_tab.lua: Deactivate stock SetFont handback unwrapped",
    clt:find('if stockFont and cf and cf.SetFont then\n        cf:SetFont(stockFont.file, stockFont.height, stockFont.flags)\n    end', 1, true) ~= nil)
check("combat_log_tab.lua: Deactivate stock SetJustifyH handback unwrapped",
    clt:find('if cf and cf.SetJustifyH then\n        cf:SetJustifyH(stockJustifyH or "LEFT")\n    end', 1, true) ~= nil)

---------------------------------------------------------------------------
-- File: QUI_Chat/chat/blizzard_suppress.lua
-- 18/18 converted uniformly to best-effort-style (protected chat-frame ops,
-- discard-correct; can throw lockdown = expected class, now counted).
---------------------------------------------------------------------------
local bs = readAll("QUI_Chat/chat/blizzard_suppress.lua")

check("blizzard_suppress.lua: 18x ns.SafeCall(\"best-effort-style\" (uniform policy)",
    (countOf(bs, 'ns.SafeCall("best-effort-style"') + countOf(bs, 'ns.SafeCallMethod("best-effort-style"')
    + countOf(bs, 'ns.SafeCallMethodIfPresent("best-effort-style"')) == 18)
check("blizzard_suppress.lua: NO bare pcall( remains anywhere in file",
    bs:find("pcall(", 1, true) == nil)
check("blizzard_suppress.lua: HookRegisterEvent strip converted",
    bs:find('ns.SafeCallMethod("best-effort-style", self, "UnregisterEvent", event)', 1, true) ~= nil)
check("blizzard_suppress.lua: NeuterOne UnregisterAllEvents converted",
    bs:find('ns.SafeCallMethod("best-effort-style", frame, "UnregisterAllEvents")', 1, true) ~= nil)
check("blizzard_suppress.lua: RestoreEventsOne canonical restore loop converted",
    bs:find('ns.SafeCallMethod("best-effort-style", frame, "RegisterEvent", event)', 1, true) ~= nil)
check("blizzard_suppress.lua: SafeSetParent converted",
    bs:find('inOwnSetParent = true\n    ns.SafeCallMethod("best-effort-style", region, "SetParent", parent)\n    inOwnSetParent = false', 1, true) ~= nil)
check("blizzard_suppress.lua: RestoreCombatLogChatMessages RegisterForMessages converted",
    bs:find('ns.SafeCallMethod("best-effort-style", cf, "RegisterForMessages", _G.GetChatWindowMessages(id))', 1, true) ~= nil)

if fails > 0 then error(fails .. " failure(s) in safecall_migration_t45b_test") end
print("OK: safecall_migration_t45b_test (all checks passed)")
