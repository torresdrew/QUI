-- tests/unit/safecall_bulkhead_t3_test.lua
-- Source-text contract pins for Task 3 (bulkhead unification: remaining
-- callback-dispatch + fire-and-forget audio sites converted from bare
-- pcall to ns.SafeCall). Per site: the converted shape is present, the old
-- bare-pcall shape is absent. Site 7 (modules/layout/layoutmode.lua) pins
-- the exact converted-site COUNT so any future addition/removal to the
-- discovery-scope conversions is forced to update this test deliberately.
-- Run: lua5.1 tests/unit/safecall_bulkhead_t3_test.lua
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

---------------------------------------------------------------------------
-- Site 1: QUI_Chat/chat/message_store.lua — Store.RemoveWhere predicate.
---------------------------------------------------------------------------
local messageStore = readAll("QUI_Chat/chat/message_store.lua")

check('site1: ns.SafeCall("bulkhead", pred, entry)',
    messageStore:find('ns.SafeCall("bulkhead", pred, entry)', 1, true) ~= nil)
check("site1: old bare pcall(pred, entry) gone",
    messageStore:find("pcall(pred, entry)", 1, true) == nil)
check("site1: keep-entry-on-failure flow unchanged (ok/matched feeds the same if)",
    messageStore:find('local ok, matched = ns.SafeCall("bulkhead", pred, entry)\n        if ok and matched then', 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 2: QUI_GroupFrames/groupframes/groupframes_cdprovider.lua — third-
-- party frame-provider registration + refresh callback.
---------------------------------------------------------------------------
local cdprovider = readAll("QUI_GroupFrames/groupframes/groupframes_cdprovider.lua")

check('site2a: ns.SafeCallMethod("bulkhead", api.v1, "RegisterFrameProvider", provider)',
    cdprovider:find('ns.SafeCallMethod("bulkhead", api.v1, "RegisterFrameProvider", provider)', 1, true) ~= nil)
check("site2a: old bare pcall(api.v1.RegisterFrameProvider, api.v1, provider) gone",
    cdprovider:find("pcall(api.v1.RegisterFrameProvider, api.v1, provider)", 1, true) == nil)

check('site2b: ns.SafeCall("bulkhead", cb) in Notify',
    cdprovider:find('if cb then ns.SafeCall("bulkhead", cb) end', 1, true) ~= nil)
check("site2b: old bare pcall(cb) gone",
    cdprovider:find("if cb then pcall(cb) end", 1, true) == nil)

-- The `local pcall = pcall` upvalue is now dead (both file pcalls converted)
-- and was removed to avoid a new luacheck unused-local warning.
check("site2: dead `local pcall = pcall` upvalue removed",
    cdprovider:find("local pcall = pcall", 1, true) == nil)
check("site2: no bare `pcall(` calls remain anywhere in the file",
    cdprovider:find("pcall(", 1, true) == nil)

---------------------------------------------------------------------------
-- Site 3: QUI_ActionBars/actionbars/gse_compat.lua — third-party
-- GSE.UpdateIcon forced-repaint call.
---------------------------------------------------------------------------
local gseCompat = readAll("QUI_ActionBars/actionbars/gse_compat.lua")

check('site3: ns.SafeCall("bulkhead", _G.GSE.UpdateIcon, _G[sequenceName], false)',
    gseCompat:find('ns.SafeCall("bulkhead", _G.GSE.UpdateIcon, _G[sequenceName], false)', 1, true) ~= nil)
check("site3: old bare pcall(_G.GSE.UpdateIcon, _G[sequenceName], false) gone",
    gseCompat:find("pcall(_G.GSE.UpdateIcon, _G[sequenceName], false)", 1, true) == nil)
check("site3: existence guard preserved (if _G.GSE and _G.GSE.UpdateIcon and _G[sequenceName] then)",
    gseCompat:find("if _G.GSE and _G.GSE.UpdateIcon and _G[sequenceName] then\n        ns.SafeCall(", 1, true) ~= nil)

-- Follow-up (Task 45f): the file's other pcall(btn.Update, btn) sites (:598/:627)
-- and the string.format guard (:997) were out of T3's scope but are now
-- converted by the 45f residual-site sweep.
local _, updateBtnTotal = gseCompat:gsub('ns%.SafeCallMethodIfPresent%("best%-effort%-style", btn, "Update"%)', "")
check('gse_compat: the 2 btn.Update sites converted to ns.SafeCall("best-effort-style", ...) (45f)',
    updateBtnTotal == 2)
check("gse_compat: old bare pcall(btn.Update, btn) gone",
    gseCompat:find("pcall(btn.Update, btn)", 1, true) == nil)
check('gse_compat: string.format guard converted to ns.SafeCall("report", string.format, fmt, ...) (45f)',
    gseCompat:find('ns.SafeCall("report", string.format, fmt, ...)', 1, true) ~= nil)
check("gse_compat: old bare pcall(string.format, fmt, ...) gone",
    gseCompat:find("pcall(string.format, fmt, ...)", 1, true) == nil)

---------------------------------------------------------------------------
-- Site 4: QUI_ActionBars/actionbars/settings/action_bars_content.lua —
-- NotifySelectedBarChanged listener fan-out.
---------------------------------------------------------------------------
local actionBarsContent = readAll("QUI_ActionBars/actionbars/settings/action_bars_content.lua")

check('site4: ns.SafeCall("bulkhead", callback, SelectedBarState.key, origin)',
    actionBarsContent:find('ns.SafeCall("bulkhead", callback, SelectedBarState.key, origin)', 1, true) ~= nil)
check("site4: old bare pcall(callback, SelectedBarState.key, origin) gone",
    actionBarsContent:find("pcall(callback, SelectedBarState.key, origin)", 1, true) == nil)

-- DECISION (site 4, brief option (a), behavior-preserving): a throwing
-- listener is still unregistered from SelectedBarListeners on ANY error —
-- identical to the old pcall behavior. Only error visibility changed (now
-- surfaced via the bulkhead policy instead of silently discarded). Option
-- (b) — keep the listener registered and report-only — was NOT implemented;
-- flagged in the task-3 report as a Drew decision if the drop-on-error
-- behavior should change.
check("site4: unregister-on-error still present (if not ok then SelectedBarListeners[owner] = nil end)",
    actionBarsContent:find("local ok = ns.SafeCall(\"bulkhead\", callback, SelectedBarState.key, origin)\n            if not ok then\n                SelectedBarListeners[owner] = nil\n            end", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 5: QUI_Chat/chat/modifiers/keyword_alert.lua — LSM-resolved sound
-- alert playback.
---------------------------------------------------------------------------
local keywordAlert = readAll("QUI_Chat/chat/modifiers/keyword_alert.lua")

check('site5: ns.SafeCall("best-effort-style", PlaySoundFile, resolved, "Master")',
    keywordAlert:find('ns.SafeCall("best-effort-style", PlaySoundFile, resolved, "Master")', 1, true) ~= nil)
check('site5: old bare pcall(PlaySoundFile, resolved, "Master") gone',
    keywordAlert:find('pcall(PlaySoundFile, resolved, "Master")', 1, true) == nil)

---------------------------------------------------------------------------
-- Site 6: modules/trackers/preytracker.lua — PlaySound fire-and-forget
-- alerts (stage transitions, ambush, quest completion).
---------------------------------------------------------------------------
local preytracker = readAll("modules/trackers/preytracker.lua")

for _, shape in ipairs({
    'ns.SafeCall("best-effort-style", PlaySound, STAGE_SOUNDS[2])',
    'ns.SafeCall("best-effort-style", PlaySound, STAGE_SOUNDS[3])',
    'ns.SafeCall("best-effort-style", PlaySound, STAGE_SOUNDS[4])',
    'ns.SafeCall("best-effort-style", PlaySound, SOUNDKIT.RAID_WARNING or 8959)',
    'ns.SafeCall("best-effort-style", PlaySound, COMPLETION_SOUND)',
}) do
    check("site6: converted shape present — " .. shape,
        preytracker:find(shape, 1, true) ~= nil)
end

for _, shape in ipairs({
    "pcall(PlaySound, STAGE_SOUNDS[2])",
    "pcall(PlaySound, STAGE_SOUNDS[3])",
    "pcall(PlaySound, STAGE_SOUNDS[4])",
    "pcall(PlaySound, SOUNDKIT.RAID_WARNING or 8959)",
    "pcall(PlaySound, COMPLETION_SOUND)",
}) do
    check("site6: old bare shape gone — " .. shape,
        preytracker:find(shape, 1, true) == nil)
end

-- NOT a drive-by: preytracker.lua's many OTHER pcall sites (currency info,
-- widget scans, quest progress, frame animation lifecycle, etc.) were not
-- in scope for the T3 PlaySound wave (19 pcall( before T3, minus the 5
-- converted PlaySound sites = 14). Task 45e later converted 6 more of
-- those remaining sites (widget suppression Hide/Show/Stop/Play mutator
-- guards -> best-effort-style; see safecall_migration_t45e_test.lua),
-- leaving 8 untouched probe-read sites (currency info, widget/parent
-- scans, quest progress) — updated here so this pin tracks the current
-- source instead of staying stuck on the pre-45e count.
local _, pcallTotal = preytracker:gsub("pcall%(", "")
check("preytracker: exactly 8 untouched pcall( sites survive (post-45e)",
    pcallTotal == 8)
check("preytracker: local pcall = pcall upvalue still present (other pcall sites still use it)",
    preytracker:find("local pcall = pcall", 1, true) ~= nil)

---------------------------------------------------------------------------
-- Site 7: modules/layout/layoutmode.lua — registered-callback dispatch
-- (bounded discovery scope).
--
-- Converted (15 sites — def.onOpen / def.onClose / def.onLiveMove /
-- def.setEnabled / def.setGameplayHidden / enter-exit callback arrays):
--   1.  :138  def.setGameplayHidden(true)   — Open(), gameplay-hide branch
--   2.  :159  def.setGameplayHidden(false)  — Open(), gameplay-restore branch
--   3.  :333  def.onOpen()                  — SetElementEnabled, enable branch
--   4.  :380  def.onClose()                 — SetElementEnabled, disable branch
--   5.  :521  cb()                          — Open(), self._enterCallbacks loop
--   6.  :541  def.onClose()                 — Open(), persisted-hidden branch
--   7.  :544  def.onOpen()                  — Open(), visible-preview branch
--   8.  :916  def.onClose()                 — Close(), element onClose sweep
--   9.  :927  def.setEnabled(false)         — Close(), re-enforce disabled state
--   10. :937  cb()                          — Close(), self._exitCallbacks loop
--   11. :1089 def.onOpen()                  — ActivateElement, fire preview
--   12. :2402 def2.onLiveMove(key)          — proxy-mover final live-reposition
--   13. :2408 def2.onLiveMove(self._barKey) — child-overlay final live-reposition
--   14. :4182 def.onClose()                 — SetHandleHidden, hide branch
--   15. :4187 def.onOpen()                  — SetHandleHidden, show branch
--
-- Examined-but-skipped (one-word reason):
--   All targetFrame/frame/parent/handle._parentFrame/bf/f
--   .SetParent/.SetFrameStrata/.ClearAllPoints/.SetPoint/.SetAllPoints/
--   .SetMovable/.SetAlpha/.EnableMouse/.GetSize calls (~61 sites spanning
--   :150-:4377) — reason: "frame-method" (direct Blizzard frame methods,
--   explicitly out of scope per the brief; a later mechanical wave).
--   Includes :875/:4170 `cb.SetParent(cb, savedParent)` — despite the local
--   variable being NAMED "cb", it is bound to a castbar FRAME object
--   (castbars["boss"..i]), not a registered callback — reason: "frame-method".
--
--   :1214 pcall(_G.QUI_ApplyFrameAnchor, key) and
--   :3207 pcall(_G.QUI_ApplyFrameAnchor, "bonusRollFrame") — reason:
--   "not-registered". _G.QUI_ApplyFrameAnchor is a single fixed QUI-internal
--   global function called directly by name; it is not a per-element
--   callable stored in a table/local via a registration API (unlike
--   def.onOpen/onClose/onLiveMove/setEnabled/setGameplayHidden and the
--   enter/exit callback arrays, which are populated by callers registering
--   distinct behavior per element). Judgment call — flagged in the task-3
--   report for Drew visibility; not implemented as bulkhead here.
--
--   :3526 xpcall(function() ... end, function(msg) return msg end) — reason:
--   "xpcall". Matched by the `pcall\(` search only because "xpcall("
--   contains "pcall(" as a substring; it is not a pcall call at all, and it
--   already self-reports via its own `if not ok and geterrorhandler then
--   geterrorhandler()(err) end` immediately after. Its wrapped callee is an
--   inline closure, not a registered callback.
---------------------------------------------------------------------------
local layoutmode = readAll("modules/layout/layoutmode.lua")

for _, shape in ipairs({
    'ns.SafeCall("bulkhead", def.setGameplayHidden, true)',
    'ns.SafeCall("bulkhead", def.setGameplayHidden, false)',
}) do
    check("site7: converted shape present — " .. shape,
        layoutmode:find(shape, 1, true) ~= nil)
end

check("site7: SetElementEnabled enable branch — if def.onOpen then ns.SafeCall(\"bulkhead\", def.onOpen) end",
    layoutmode:find('if enabled then\n        -- Show preview if element has one\n        if def.onOpen then ns.SafeCall("bulkhead", def.onOpen) end', 1, true) ~= nil)
check("site7: SetElementEnabled disable branch — if def.onClose then ns.SafeCall(\"bulkhead\", def.onClose) end",
    layoutmode:find('else\n        -- Hide preview if element has one\n        if def.onClose then ns.SafeCall("bulkhead", def.onClose) end', 1, true) ~= nil)

check("site7: Open() self._enterCallbacks loop converted",
    layoutmode:find('self._enterCallbacksRunning = true\n    for _, cb in ipairs(self._enterCallbacks) do\n        ns.SafeCall("bulkhead", cb)\n    end', 1, true) ~= nil)
check("site7: Open() persisted-hidden def.onClose converted",
    layoutmode:find('self._handles[key]:Hide()\n                if def.onClose then ns.SafeCall("bulkhead", def.onClose) end', 1, true) ~= nil)
check("site7: Open() visible-preview def.onOpen converted",
    layoutmode:find('-- Activate preview FIRST so frame is shown before CreateHandle\n                if def.onOpen then ns.SafeCall("bulkhead", def.onOpen) end', 1, true) ~= nil)

check("site7: Close() element onClose sweep converted",
    layoutmode:find('if def.onClose then\n            ns.SafeCall("bulkhead", def.onClose)\n        end', 1, true) ~= nil)
check("site7: Close() re-enforce-disabled def.setEnabled converted",
    layoutmode:find('if not enabled then\n                ns.SafeCall("bulkhead", def.setEnabled, false)\n            end', 1, true) ~= nil)
check("site7: Close() self._exitCallbacks loop converted",
    layoutmode:find('-- Fire exit callbacks\n    for _, cb in ipairs(self._exitCallbacks) do\n        ns.SafeCall("bulkhead", cb)\n    end', 1, true) ~= nil)

check("site7: ActivateElement onOpen converted",
    layoutmode:find('-- Fire preview\n    if def.onOpen then ns.SafeCall("bulkhead", def.onOpen) end', 1, true) ~= nil)

check("site7: proxy-mover def2.onLiveMove(key) converted",
    layoutmode:find('if def2.onLiveMove then\n                    ns.SafeCall("bulkhead", def2.onLiveMove, key)\n                end', 1, true) ~= nil)
check("site7: child-overlay def2.onLiveMove(self._barKey) converted",
    layoutmode:find('if def2 and def2.onLiveMove then\n                ns.SafeCall("bulkhead", def2.onLiveMove, self._barKey)\n            end', 1, true) ~= nil)

check("site7: SetHandleHidden hide-branch def.onClose converted",
    layoutmode:find('ns.SafeCall("bulkhead", def.onClose) end\n        return false', 1, true) ~= nil)
check("site7: SetHandleHidden show-branch def.onOpen converted",
    layoutmode:find('if hidden then hidden[key] = nil end\n        if def.onOpen then ns.SafeCall("bulkhead", def.onOpen) end', 1, true) ~= nil)

-- Exact converted-site count pin. See the numbered list in the comment
-- block above for what the original 15 sites are; Task 45d added 2 more
-- (the _G.QUI_ApplyFrameAnchor cross-module-seam sites at :1214/:3207,
-- converted per the T1d precedent) for a new total of 17.
local _, bulkheadCount = layoutmode:gsub('ns%.SafeCall%("bulkhead"', '')
check("site7: exactly 17 ns.SafeCall(\"bulkhead\" occurrences in layoutmode.lua",
    bulkheadCount == 17)

-- Formerly "out of scope for this (T3) wave" — Task 45d's mechanical
-- migration wave explicitly brought the frame-mutator-guard class (and the
-- two _G.QUI_ApplyFrameAnchor cross-module-seam sites) into scope, per its
-- brief's "also covers the T3-skipped layoutmode.lua:1214/:3207 ... convert
-- those two as well per the T1d cross-module-seam precedent" instruction.
-- These spot checks now pin the CONVERTED shape instead of the untouched
-- bare pcall (the full per-site table lives in the 45d report).
for _, shape in ipairs({
    'ns.SafeCallMethod("best-effort-style", frame, "SetAlpha", 0)',
    'ns.SafeCallMethod("best-effort-style", targetFrame, "SetParent", handle._savedTargetParent)',
    'ns.SafeCallMethod("best-effort-style", targetFrame, "SetPoint", "CENTER", UIParent, "CENTER", ox, oy)',
    'ns.SafeCallMethod("best-effort-style", bf, "SetParent", savedParent)',
    'if cb then ns.SafeCallMethod("best-effort-style", cb, "SetParent", savedParent) end',
    'ns.SafeCall("bulkhead", _G.QUI_ApplyFrameAnchor, key)',
    'ns.SafeCall("bulkhead", _G.QUI_ApplyFrameAnchor, "bonusRollFrame")',
}) do
    check("site7: T3-out-of-scope shape now converted by 45d — " .. shape,
        layoutmode:find(shape, 1, true) ~= nil)
end
-- And the bare pcall forms must be gone from those specific sites.
for _, shape in ipairs({
    "pcall(frame.SetAlpha, frame, 0)",
    "local ok, err = pcall(_G.QUI_ApplyFrameAnchor, \"bonusRollFrame\")",
}) do
    check("site7: pre-45d bare form no longer present — " .. shape,
        layoutmode:find(shape, 1, true) == nil)
end
check("site7: xpcall(function() ... site (not a pcall call) survives untouched",
    layoutmode:find("local ok, err = xpcall(function()", 1, true) ~= nil)

---------------------------------------------------------------------------
if fails > 0 then error(fails .. " failure(s) in safecall_bulkhead_t3_test") end
print("OK: safecall_bulkhead_t3_test (all checks passed)")
