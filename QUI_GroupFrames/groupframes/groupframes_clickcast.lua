--[[
    QUI Click-Casting Framework
    Native click-casting that works independently of Clique.
    Supports group frames (party/raid) and individual unit frames
    (player, target, focus, pet, boss).
    Features: modifier combos, smart resurrection, per-spec profiles,
    Clique coexistence, binding tooltip on frame hover,
    keyboard key bindings for pseudo-mouseover casting.
]]

local ADDON_NAME, ns = ...
local Helpers = ns.Helpers

-- Click-cast settings live on db.char (per-character), not on the shared
-- profile. Bindings reference class-specific spells, and a single AceDB
-- profile is shared across every character on the account by default —
-- storing them on the profile leaked one class's bindings onto another
-- (e.g. Druid bindings appearing on a Paladin alt). GetDB returns the
-- character-scoped wrapper so existing `db.clickCast` access shape is
-- preserved.
local function GetDB()
    return _G.QUI and _G.QUI.db and _G.QUI.db.char or nil
end

-- Forward-declared so Initialize (defined before the migration block)
-- can call it. Body is assigned later in the file.
local MigrateProfileClickCastToChar

-- Upvalue hot-path globals
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local table_insert = table.insert
local table_remove = table.remove

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------
local QUI_GFCC = {}
ns.QUI_GroupFrameClickCast = QUI_GFCC

-- Track registered frames
local registeredFrames = Helpers.CreateStateTable()
local hookedFrames = Helpers.CreateStateTable() -- Tracks frames with OnEnter/OnLeave hooks (permanent)
local secureWrappedFrames = Helpers.CreateStateTable() -- Tracks frames with secure WrapScript (permanent)
local activeBindings = {} -- Resolved mouse bindings for current spec
local keyboardBindings = {} -- Resolved SCROLL-WHEEL bindings (per-frame, hover-only)
-- Resolved KEYBOARD-KEY bindings. Each key's cast macro is written to every
-- registered frame's per-frame proxy as a virtual button; the secure OnEnter wrap
-- binds the key (priority override, header-owned) to the hovered frame's proxy by
-- NAME, and OnLeave releases it so off-frame the key keeps its action-bar binding.
-- @mouseover in the proxy's macro targets the hovered unit.
local globalKeyBindings = {}
local isEnabled = false
-- Coalesces deferred cold-login re-resolve fired by data-ready event handlers
-- so a burst schedules only one.
local dataReadyRefreshScheduled = false
local IsUnresolvedButConfigured  -- forward-declared; used by the OnEnter recovery hook above its body
local HasConfiguredBindings      -- forward-declared; kept local (body defined later, near IsUnresolvedButConfigured)

---------------------------------------------------------------------------
-- PING MACROS: /ping [@mouseover] <type> for each ping action type
---------------------------------------------------------------------------
local PING_MACROS = {
    ping         = "/ping [@mouseover]",
    ping_assist  = "/ping [@mouseover] assist",
    ping_attack  = "/ping [@mouseover] attack",
    ping_warning = "/ping [@mouseover] warning",
    ping_onmyway = "/ping [@mouseover] onmyway",
}

-- Three-clause @mouseover cast macro shared by every spell-cast binding path
-- (mouse buttons, scroll/keyboard virtual buttons — all on the per-frame proxy).
local function BuildMouseoverCastMacro(spell)
    return "/cast [@mouseover,help,nodead] " .. spell
        .. "; [@mouseover,harm,nodead] " .. spell
        .. "; [@mouseover] " .. spell
end

-- Single-clause @mouseover cast for friend/enemy bindings.
-- The helpbutton/harmbutton remap is the filter; no help/harm clause needed.
local function BuildPlainMouseoverCastMacro(spell)
    return "/cast [@mouseover] " .. spell
end

-- Attribute name for a (possibly numeric) button suffix.
-- Numeric mouse suffixes take no dash (helpbutton1), non-numeric virtual
-- button names take a dash (helpbutton-keyf). Mirrors the secure engine's
-- own resolution rule (tonumber(suffix) and "" or "-").
local function ButtonAttrName(attr, suffix)
    return attr .. (tonumber(suffix) and "" or "-") .. suffix
end

local PING_LABELS = {
    ping         = "Ping",
    ping_assist  = "Ping: Assist",
    ping_attack  = "Ping: Attack",
    ping_warning = "Ping: Warning",
    ping_onmyway = "Ping: On My Way",
}

---------------------------------------------------------------------------
-- MODIFIER / BUTTON HELPERS
---------------------------------------------------------------------------
local BUTTON_NAMES = {
    LeftButton = "Left Click",
    RightButton = "Right Click",
    MiddleButton = "Middle Click",
    Button4 = "Button 4",
    Button5 = "Button 5",
    ScrollUp = "Scroll Up",
    ScrollDown = "Scroll Down",
}

-- Scroll wheel buttons use override bindings (like keyboard keys),
-- not the SetAttribute("typeN") system used by regular mouse buttons.
local SCROLL_WHEEL_KEYS = {
    ScrollUp = "MOUSEWHEELUP",
    ScrollDown = "MOUSEWHEELDOWN",
}

-- Friendly display names for binding keys shown in tooltips
local KEY_DISPLAY_NAMES = {
    MOUSEWHEELUP = "Scroll Up",
    MOUSEWHEELDOWN = "Scroll Down",
}

local MODIFIER_LABELS = {
    [""]      = "",
    ["shift"] = "Shift+",
    ["ctrl"]  = "Ctrl+",
    ["alt"]   = "Alt+",
    ["shift-ctrl"]  = "Shift+Ctrl+",
    ["shift-alt"]   = "Shift+Alt+",
    ["ctrl-alt"]    = "Ctrl+Alt+",
    ["shift-ctrl-alt"] = "Shift+Ctrl+Alt+",
}

---------------------------------------------------------------------------
-- MODIFIER HELPERS
---------------------------------------------------------------------------
-- Parse modifier string into canonical alphabetical order (alt-ctrl-shift-)
-- for WoW's SecureButton attribute system.
local function ModifiersToAttributePrefix(mods)
    if not mods or mods == "" then return "" end
    local lower = mods:lower()
    local hasAlt   = lower:find("alt") ~= nil
    local hasCtrl  = lower:find("ctrl") ~= nil
    local hasShift = lower:find("shift") ~= nil
    local result = ""
    if hasAlt   then result = result .. "alt-" end
    if hasCtrl  then result = result .. "ctrl-" end
    if hasShift then result = result .. "shift-" end
    return result
end

-- Convert our modifier format to WoW binding prefix ("SHIFT-", "CTRL-ALT-")
-- Binding keys use UPPERCASE, same alphabetical order.
local function ModifiersToBindingPrefix(mods)
    if not mods or mods == "" then return "" end
    local lower = mods:lower()
    local hasAlt   = lower:find("alt") ~= nil
    local hasCtrl  = lower:find("ctrl") ~= nil
    local hasShift = lower:find("shift") ~= nil
    local result = ""
    if hasAlt   then result = result .. "ALT-" end
    if hasCtrl  then result = result .. "CTRL-" end
    if hasShift then result = result .. "SHIFT-" end
    return result
end

---------------------------------------------------------------------------
-- RESURRECTION SPELLS: Per-class res spell IDs
---------------------------------------------------------------------------
local RES_SPELLS = {
    PRIEST      = 2006,   -- Resurrection
    PALADIN     = 7328,   -- Redemption
    SHAMAN      = 2008,   -- Ancestral Spirit
    DRUID       = 50769,  -- Revive
    MONK        = 115178, -- Resuscitate
    EVOKER      = 361227, -- Return
    WARLOCK     = 20707,  -- Soulstone
    DEATHKNIGHT = 61999,  -- Raise Ally
}

local function GetResurrectionSpellName()
    local _, classToken = UnitClass("player")
    local spellID = RES_SPELLS[classToken]
    if spellID then
        local name = C_Spell.GetSpellName(spellID)
        return name
    end
    return nil
end

---------------------------------------------------------------------------
-- SECURE HANDLER: Keyboard binding infrastructure
---------------------------------------------------------------------------
-- The header (SecureHandlerBaseTemplate) owns all override bindings.
-- WrapScript hooks on each frame use `owner` (the header) to call
-- SetBindingClick/ClearBindings — the frame itself does NOT need
-- SecureHandlerBaseTemplate methods.
--
-- On hover: header reads key count + key/vbtn attributes, calls
-- SetBindingClick to route each key to the hovered frame's virtual button.
-- On leave: header clears all override bindings.
---------------------------------------------------------------------------
local bindingHeader

-- Clear-only safety net for keyboard overrides. Bindings are armed/cleared by the
-- per-frame OnEnter/OnLeave/OnHide secure wraps (edge-driven; see ENTER_SNIPPET /
-- LEAVE_SNIPPET). This [@mouseover,exists] attribute driver catches the one case
-- those edges miss: a frame that lost the cursor WITHOUT firing OnLeave/OnHide (a
-- secure unit-button recycled under a stationary cursor, a unit-watch hide). It
-- NEVER binds -- it only releases a stale override, and only when geometry proves
-- the cursor has truly left the last-entered frame. Uses GetMousePosition (cursor
-- normalized into the frame's own rect; a non-nil result means inside) rather than
-- IsUnderMouse, whose post-12.0 semantics return false for valid in-frame hits and
-- stranded the override. Runs in the header's managed environment, so it shares
-- the `currentHoverFrame` env-global the wraps maintain.
local DANGLING_SNIPPET = [[
    if name ~= "cc-hasunit" or value ~= "false" then return end
    if not currentHoverFrame then return end
    local x, y = currentHoverFrame:GetMousePosition()
    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 and currentHoverFrame:IsVisible() then
        return
    end
    self:ClearBindings()
    currentHoverFrame = nil
]]

local function GetBindingHeader()
    if not bindingHeader then
        bindingHeader = CreateFrame("Frame", "QUI_ClickCastHeader", UIParent,
            "SecureHandlerBaseTemplate,SecureHandlerAttributeTemplate")
        -- Install the clear-only dangling net (see DANGLING_SNIPPET). The driver
        -- writes the "cc-hasunit" attribute on a 0.2s-throttled, mouseover-blind
        -- tick; the handler acts only on the false edge and only ever clears.
        bindingHeader:SetAttribute("_onattributechanged", DANGLING_SNIPPET)
        RegisterAttributeDriver(bindingHeader, "cc-hasunit", "[@mouseover,exists] true; false")
    end
    return bindingHeader
end

-- WrapScript pre-body for OnEnter.
-- `self` = the hovered frame, `owner` = the header (SecureHandlerBaseTemplate).
-- Binds ALL override keys (scroll-wheel + keyboard) to the per-frame proxy by
-- name via SetBindingClick. The proxy is named so SetBindingClick can find it
-- by string name; the proxy holds the cast attrs so the right action fires.
-- Edge-driven, fully secure, fires in combat. `currentHoverFrame` tracks the
-- active hover so OnLeave clears ONLY for that frame.
local ENTER_SNIPPET = [[
    owner:ClearBindings()
    currentHoverFrame = self

    if self:GetAttribute("clickcast-active") ~= 1 then return end

    local pname = self:GetAttribute("clickcast-proxyname")
    if not pname then return end

    local count = owner:GetAttribute("clickcast-keycount") or 0
    if count == 0 then return end

    for i = 1, count do
        local key  = owner:GetAttribute("clickcast-key"  .. i)
        local vbtn = owner:GetAttribute("clickcast-vbtn" .. i)
        if key and vbtn then
            owner:SetBindingClick(true, key, pname, vbtn)
        end
    end
]]

-- WrapScript pre-body for OnLeave. Guard on currentHoverFrame so a stale leave
-- from a frame we've already moved off of can't clear the active bindings.
local LEAVE_SNIPPET = [[
    if currentHoverFrame == self then
        owner:ClearBindings()
        currentHoverFrame = nil
    end
]]

-- No OnHide wrap (matches the reference addon): a group/raid unit button
-- recycles (hide/show) constantly during roster churn, and clearing on hide
-- wipes the binding while the cursor is still parked on the frame -- with no
-- re-arm under a stationary cursor the key then falls through to the action bar.
-- A genuine lost cursor (frame hidden for real) is released by the clear-only
-- dangling driver, which checks frame visibility.

local CLEAR_HEADER_BINDINGS_SNIPPET = [[
    self:ClearBindings()
    currentHoverFrame = nil
]]

-- Wrap a frame's OnEnter/OnLeave with secure handler snippets.
-- Only called once per frame (tracked by secureWrappedFrames).
-- No OnHide wrap: group/raid unit buttons recycle (hide/show) constantly during
-- roster churn, and clearing on hide wipes the binding while the cursor is still
-- parked on the frame. A genuine lost cursor is handled by the clear-only
-- dangling driver (checks frame visibility).
local function WrapFrameSecureHandlers(frame)
    if secureWrappedFrames[frame] then return end
    if InCombatLockdown() then return end

    local header = GetBindingHeader()
    SecureHandlerWrapScript(frame, "OnEnter", header, ENTER_SNIPPET)
    SecureHandlerWrapScript(frame, "OnLeave", header, LEAVE_SNIPPET)

    secureWrappedFrames[frame] = true
end

local function ClearHeaderOverrideBindings()
    if InCombatLockdown() then return end
    if bindingHeader and bindingHeader.Execute then
        bindingHeader:Execute(CLEAR_HEADER_BINDINGS_SNIPPET)
    end
end

-- Build virtual button name from a binding's modifiers + key.
local function GetVirtualButtonName(binding)
    return "key" .. (binding.modifiers or ""):gsub("%-", "") .. binding.key:lower()
end

-- Forward-declared; body assigned after GetCurrentSpecID/GetStableLoadoutID are defined.
local KeyboardContextUnresolved

-- Update the header's key-mapping attributes for ALL override-binding paths:
-- both scroll-wheel (keyboardBindings) and keyboard keys (globalKeyBindings).
-- The unified list is what the new ENTER_SNIPPET reads to bind all keys to the
-- per-frame proxy on hover.
-- Guard: if the keyboard resolve came up empty only because spec/loadout data
-- hasn't landed yet (cold login), keep the last-good list — same logic as
-- ApplyGlobalKeyboardBindings / KeyboardContextUnresolved.
local function UpdateHeaderKeyAttributes()
    local header = GetBindingHeader()
    if InCombatLockdown() then return end

    -- If globalKeyBindings is empty but context is transiently unresolved,
    -- keep the existing header key list (last-good preservation).
    if #globalKeyBindings == 0 and #keyboardBindings == 0 and KeyboardContextUnresolved() then
        return
    end

    -- Clear old attributes
    local oldCount = header:GetAttribute("clickcast-keycount") or 0
    for i = 1, oldCount do
        header:SetAttribute("clickcast-key" .. i, nil)
        header:SetAttribute("clickcast-vbtn" .. i, nil)
    end

    -- Unified list: scroll-wheel first, then keyboard keys
    local total = #keyboardBindings + #globalKeyBindings
    header:SetAttribute("clickcast-keycount", total)

    local idx = 0
    for _, binding in ipairs(keyboardBindings) do
        idx = idx + 1
        local modPrefix = ModifiersToBindingPrefix(binding.modifiers)
        local fullKey = modPrefix .. binding.key:upper()
        local vBtn = GetVirtualButtonName(binding)
        header:SetAttribute("clickcast-key" .. idx, fullKey)
        header:SetAttribute("clickcast-vbtn" .. idx, vBtn)
    end
    for _, binding in ipairs(globalKeyBindings) do
        idx = idx + 1
        local modPrefix = ModifiersToBindingPrefix(binding.modifiers)
        local fullKey = modPrefix .. binding.key:upper()
        local vBtn = GetVirtualButtonName(binding)
        header:SetAttribute("clickcast-key" .. idx, fullKey)
        header:SetAttribute("clickcast-vbtn" .. idx, vBtn)
    end
end

---------------------------------------------------------------------------
-- SECURE ACTION PROXIES: target / menu (12.0.7 click-binding gate workaround)
---------------------------------------------------------------------------
-- WoW 12.0.7's SecureUnitButton_OnClick gates the native "target" and
-- "togglemenu" actions behind C_ClickBindings: only Blizzard's default
-- unmodified left->target and right->menu interactions are registered, so a
-- click carrying a modifier (or on any other button) that resolves to either
-- type returns Enum.ClickBindingType.None and is silently dropped -- the click
-- does nothing. Route those through a hidden child SecureActionButton via the
-- ungated "click" action: a SecureActionButton's own SecureActionButton_OnClick
-- has no such gate. `useparent-unit` makes the proxy resolve the unit from the
-- parent unit button, so it tracks header-managed party/raid children whose
-- unit reassigns. One proxy per (frame, action); cached weakly. The proxy
-- frames are permanent (frames can't be destroyed) but harmless -- alpha 0,
-- mouse disabled, reachable only by the secure delegate.
local targetProxies = setmetatable({}, { __mode = "k" })
local menuProxies = setmetatable({}, { __mode = "k" })

local function GetActionProxy(frame, cache, actionType)
    local proxy = cache[frame]
    if proxy then return proxy end
    if InCombatLockdown() then return nil end
    proxy = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
    proxy:SetSize(1, 1)
    proxy:SetAlpha(0)
    proxy:EnableMouse(false)          -- never catches a real click; only the secure "click" delegate reaches it
    proxy:RegisterForClicks("AnyUp")
    proxy:SetAttribute("type", actionType)
    -- The secure resolver looks up "type" by BUTTON SUFFIX (RightButton->type2);
    -- the bare "type" may not fall back, so set every button explicitly.
    for i = 1, 5 do proxy:SetAttribute("type" .. i, actionType) end
    proxy:SetAttribute("useparent-unit", true)
    -- Act on the up-click regardless of the "cast on key down" CVar; without
    -- this the delegated click is skipped on up when ActionButtonUseKeyDown is on.
    proxy:SetAttribute("useOnKeyDown", false)
    cache[frame] = proxy
    return proxy
end

local function GetTargetProxy(frame) return GetActionProxy(frame, targetProxies, "target") end
local function GetMenuProxy(frame)   return GetActionProxy(frame, menuProxies, "togglemenu") end

---------------------------------------------------------------------------
-- PER-FRAME SECURE PROXIES: pooled SecureActionButton per registered frame
-- Each registered frame gets its own named proxy so the ENTER_SNIPPET can
-- route ALL override keys (scroll + keyboard) to it via SetBindingClick by
-- name. The proxy MUST be named because SetBindingClick silently no-ops on an
-- unnamed button. `useparent-unit` lets the proxy resolve the unit from its
-- parent unit button. proxyBackup snapshots the frame's original routing attrs
-- before any routing write so they can be restored on disable.
---------------------------------------------------------------------------
local proxyPool      = setmetatable({}, { __mode = "k" })
local proxyBackup    = setmetatable({}, { __mode = "k" })
-- [proxy] = {remappedAttr = true, ...} — helpbutton-*/harmbutton-* remapped attrs written
local proxyRemapVBtns = setmetatable({}, { __mode = "k" })
-- [frame] = list of attr names written by WriteFrameRouting (cleared by TeardownFrameRouting).
local frameRoutingWritten = setmetatable({}, { __mode = "k" })
local proxyCounter = 0

-- All modifier prefixes the secure engine recognises for mouse buttons.
local ALL_MOD_PREFIXES = {
    "", "alt-", "ctrl-", "shift-",
    "alt-ctrl-", "alt-shift-", "ctrl-shift-", "alt-ctrl-shift-",
}

-- Build the complete list of per-button routing attribute names we snapshot
-- in GetOrCreateProxy (before any write ever happens). Covers every
-- modifier×button combination so reassert passes never overwrite the backup.
local PROXY_BACKUP_ATTRS = (function()
    local list = {}
    local btns = { "1", "2", "3", "4", "5" }
    for _, pfx in ipairs(ALL_MOD_PREFIXES) do
        for _, n in ipairs(btns) do
            list[#list + 1] = pfx .. "type"        .. n
            list[#list + 1] = pfx .. "clickbutton" .. n
        end
    end
    return list
end)()

-- Return (creating if needed) the per-frame proxy. Returns nil in combat.
local function GetOrCreateProxy(frame)
    local existing = proxyPool[frame]
    if existing then return existing end
    if InCombatLockdown() then return nil end

    proxyCounter = proxyCounter + 1
    local proxy = CreateFrame("Button",
        "QUI_ClickCastProxy" .. proxyCounter,
        frame, "SecureActionButtonTemplate")
    proxy:SetAttribute("useparent-unit", true)
    proxy:SetAttribute("useOnKeyDown", false)
    proxy:RegisterForClicks("AnyUp")

    -- Snapshot original routing attrs before any routing write.
    local backup = {}
    for _, attr in ipairs(PROXY_BACKUP_ATTRS) do
        backup[attr] = frame:GetAttribute(attr)
    end
    proxyBackup[frame] = backup

    proxyPool[frame] = proxy
    return proxy
end

-- Return the stored proxy's name for this frame, or nil if none created yet.
local function ProxyName(frame)
    local proxy = proxyPool[frame]
    if not proxy then return nil end
    return proxy:GetName()
end

---------------------------------------------------------------------------
-- BUTTON NUMBER HELPER
---------------------------------------------------------------------------
local BUTTON_NUMBERS = {
    LeftButton = "1",
    RightButton = "2",
    MiddleButton = "3",
    Button4 = "4",
    Button5 = "5",
}

---------------------------------------------------------------------------
-- A2: FRAME ROUTING — write/restore the click-delegation attrs on the frame
-- that tell the SecureUnitButton system to hand each click to the proxy.
---------------------------------------------------------------------------

-- Write per-bound-button routing attrs on FRAME so only configured mouse buttons
-- delegate to the proxy.  Unbound buttons (e.g. unbound right-click) are NOT
-- touched, so Blizzard's native left=target and right=menu survive on group frames.
-- Scroll-wheel entries in activeBindings are excluded (they use the override path).
local function WriteFrameRouting(frame, proxy)
    if InCombatLockdown() then return end

    local written = {}
    frameRoutingWritten[frame] = written

    for _, b in ipairs(activeBindings) do
        -- Scroll-wheel buttons are not real mouse buttons; skip them here.
        if not SCROLL_WHEEL_KEYS[b.button] then
            local prefix = ModifiersToAttributePrefix(b.modifiers)
            local btnNum = BUTTON_NUMBERS[b.button]
            if btnNum then
                local typeAttr   = prefix .. "type"        .. btnNum
                local clickAttr  = prefix .. "clickbutton" .. btnNum
                -- backup[typeAttr] and backup[clickAttr] were captured in
                -- GetOrCreateProxy (before any write), covering all modifier×button
                -- combos.  No dynamic snapshot needed here.
                frame:SetAttribute(typeAttr,  "click")
                frame:SetAttribute(clickAttr, proxy)
                written[#written + 1] = typeAttr
                written[#written + 1] = clickAttr
            end
        end
    end

    frame:SetAttribute("clickcast-proxyname", proxy:GetName())
end

-- Restore every routing attr written by WriteFrameRouting (from backup or nil),
-- then clear clickcast-proxyname.
local function TeardownFrameRouting(frame)
    if InCombatLockdown() then return end
    local backup  = proxyBackup[frame]
    local written = frameRoutingWritten[frame]
    if written then
        for _, attr in ipairs(written) do
            local orig = backup and backup[attr]
            frame:SetAttribute(attr, orig)
        end
        frameRoutingWritten[frame] = nil
    end
    frame:SetAttribute("clickcast-proxyname", nil)
end

---------------------------------------------------------------------------
-- A3: Write cast attrs to the PROXY (not the frame).
-- SetFrameKeyAttributes → proxy virtual buttons (scroll-wheel bindings).
-- ClearFrameKeyAttributes → clears from proxy.
---------------------------------------------------------------------------

-- Set virtual-button action attributes on the PROXY for scroll-wheel bindings.
local function SetFrameKeyAttributes(proxy, frame)
    if InCombatLockdown() then return end
    for _, binding in ipairs(keyboardBindings) do
        local vBtn = GetVirtualButtonName(binding)
        local actionType = binding.actionType or "spell"

        if actionType == "spell" then
            if binding.friend then
                local remapped = "friend" .. vBtn
                proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, BuildPlainMouseoverCastMacro(binding.spell))
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("helpbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            elseif binding.enemy then
                local remapped = "enemy" .. vBtn
                proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, BuildPlainMouseoverCastMacro(binding.spell))
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("harmbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            else
                proxy:SetAttribute("type-" .. vBtn, "macro")
                proxy:SetAttribute("macrotext-" .. vBtn, BuildMouseoverCastMacro(binding.spell))
            end
        elseif actionType == "macro" then
            if binding.friend then
                local remapped = "friend" .. vBtn
                proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, binding.macro)
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("helpbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            elseif binding.enemy then
                local remapped = "enemy" .. vBtn
                proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, binding.macro)
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("harmbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            else
                proxy:SetAttribute("type-" .. vBtn, "macro")
                proxy:SetAttribute("macrotext-" .. vBtn, binding.macro)
            end
        elseif actionType == "target" then
            -- Scroll/key triggers are never the default left-click, so a native
            -- "target" always hits the 12.0.7 gate -- route through the proxy.
            local tProxy = GetTargetProxy(frame)
            if tProxy then
                proxy:SetAttribute("type-" .. vBtn, "click")
                proxy:SetAttribute("clickbutton-" .. vBtn, tProxy)
            end
        elseif actionType == "focus" then
            proxy:SetAttribute("type-" .. vBtn, "focus")
        elseif actionType == "assist" then
            proxy:SetAttribute("type-" .. vBtn, "assist")
        elseif actionType == "menu" then
            local mProxy = GetMenuProxy(frame)
            if mProxy then
                proxy:SetAttribute("type-" .. vBtn, "click")
                proxy:SetAttribute("clickbutton-" .. vBtn, mProxy)
            end
        elseif actionType:match("^ping") then
            proxy:SetAttribute("type-" .. vBtn, "macro")
            proxy:SetAttribute("macrotext-" .. vBtn, PING_MACROS[actionType] or "/ping [@mouseover]")
        end
    end
end

-- Clear virtual-button scroll-wheel attributes from a proxy.
local function ClearFrameKeyAttributes(proxy)
    if InCombatLockdown() then return end
    for _, binding in ipairs(keyboardBindings) do
        local vBtn = GetVirtualButtonName(binding)
        proxy:SetAttribute("type-" .. vBtn, nil)
        proxy:SetAttribute("macrotext-" .. vBtn, nil)
        proxy:SetAttribute("clickbutton-" .. vBtn, nil)
        -- Clear any helpbutton/harmbutton remapped attrs written by friend/enemy bindings
        proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), nil)
        proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), nil)
        proxy:SetAttribute("type-friend" .. vBtn, nil)
        proxy:SetAttribute("macrotext-friend" .. vBtn, nil)
        proxy:SetAttribute("type-enemy" .. vBtn, nil)
        proxy:SetAttribute("macrotext-enemy" .. vBtn, nil)
    end
    -- Clear any tracked remapped attrs (covers mouse-path remaps too for scroll case)
    local remapSet = proxyRemapVBtns[proxy]
    if remapSet then
        for attr in pairs(remapSet) do
            proxy:SetAttribute(attr, nil)
        end
        proxyRemapVBtns[proxy] = nil
    end
end

---------------------------------------------------------------------------
-- BINDING RESOLUTION: Build active binding set for current spec/loadout
---------------------------------------------------------------------------

-- Resolve the current spell name from a binding's spellID (root spell).
-- If a talent override is active, GetSpellName returns the override name,
-- which is what /cast needs. Falls back to stored spell name string.
local function ResolveSpellName(binding)
    if binding.spellID then
        local name = C_Spell.GetSpellName(binding.spellID)
        if name then return name end
    end
    return binding.spell
end

local function GetCurrentSpecID()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    if specID and specID ~= 0 then return specID end
    return nil
end

-- Return the stable saved-loadout config ID for the current spec.
-- GetActiveConfigID() returns an ephemeral staging copy that changes each
-- session; GetLastSelectedSavedConfigID() returns the persistent saved ID.
local function GetStableLoadoutID()
    local specID = GetCurrentSpecID()
    if not specID or not C_ClassTalents then return nil, specID end
    local savedID = C_ClassTalents.GetLastSelectedSavedConfigID and C_ClassTalents.GetLastSelectedSavedConfigID(specID)
    if savedID then return savedID, specID end
    local activeID = C_ClassTalents.GetActiveConfigID()
    if activeID and activeID ~= 0 then return activeID, specID end
    return nil, specID
end

-- Look up the correct binding table for the current spec/loadout settings.
local function GetActiveBindingTable()
    local db = GetDB()
    if not db or not db.clickCast then return nil end
    local cc = db.clickCast

    if cc.perSpec then
        local specID = GetCurrentSpecID()
        if not specID then return nil end

        if cc.perLoadout then
            local configID = GetStableLoadoutID()
            if configID and cc.loadoutBindings and cc.loadoutBindings[specID] then
                return cc.loadoutBindings[specID][configID]
            end
            return nil
        end

        local specBindings = cc.specBindings and cc.specBindings[specID]
        if specBindings then return specBindings end
    end

    return cc.bindings
end

local function ResolveBindings()
    wipe(activeBindings)
    wipe(keyboardBindings)
    wipe(globalKeyBindings)

    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return end

    local bindings = GetActiveBindingTable()
    if not bindings then return end

    for _, binding in ipairs(bindings) do
        -- A binding needs a trigger (key or button) and either a spell, macro,
        -- or a non-spell action type (target/focus/assist/menu/ping).
        local actionType = binding.actionType or "spell"
        local hasAction = binding.spell or binding.macro or actionType ~= "spell"
        -- Resolve current spell name from root spellID at apply-time
        local spellName = (actionType == "spell") and ResolveSpellName(binding) or binding.spell

        if binding.key and hasAction then
            -- Keyboard key: macro written to each frame's proxy; bound to the
            -- hovered frame's proxy (by name) on the secure OnEnter wrap.
            table_insert(globalKeyBindings, {
                key = binding.key,
                modifiers = binding.modifiers or "",
                spell = spellName,
                macro = binding.macro,
                actionType = actionType,
                friend = binding.friend,
                enemy = binding.enemy,
            })
        elseif binding.button and hasAction then
            local scrollKey = SCROLL_WHEEL_KEYS[binding.button]
            if scrollKey then
                -- Scroll wheel must be hover-only (a global mousewheel bind would
                -- eat scrolling everywhere), so it keeps the per-frame override path.
                table_insert(keyboardBindings, {
                    key = scrollKey,
                    modifiers = binding.modifiers or "",
                    spell = spellName,
                    macro = binding.macro,
                    actionType = actionType,
                    friend = binding.friend,
                    enemy = binding.enemy,
                })
            else
                -- Mouse binding
                table_insert(activeBindings, {
                    button = binding.button,
                    modifiers = binding.modifiers or "",
                    spell = spellName,
                    macro = binding.macro,
                    actionType = actionType,
                    friend = binding.friend,
                    enemy = binding.enemy,
                })
            end
        end
    end
end

---------------------------------------------------------------------------
-- KEYBOARD KEY VIRTUAL BUTTONS ON PROXY (A3/A4)
-- Keyboard keys are routed via the header's unified key list (UpdateHeaderKeyAttributes)
-- to the per-frame proxy by name on hover (ENTER_SNIPPET). The proxy itself holds
-- the cast attrs (virtual buttons) so the right action fires.
-- True while the spec/loadout context is still landing: keep last-good state.
---------------------------------------------------------------------------
local proxyKeyVBtns = setmetatable({}, { __mode = "k" }) -- [proxy] = {vBtn=true,...}

KeyboardContextUnresolved = function()
    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.perSpec then return false end
    if not GetCurrentSpecID() then return true end
    if db.clickCast.perLoadout and not GetStableLoadoutID() then return true end
    return false
end

-- Build the macro text for a keyboard binding on the proxy.
local function BuildKeyMacro(binding)
    local actionType = binding.actionType or "spell"
    if actionType == "spell" then
        return BuildMouseoverCastMacro(binding.spell)
    elseif actionType == "macro" then
        return binding.macro or ""
    elseif actionType == "target" then
        return "/target [@mouseover]"
    elseif actionType == "focus" then
        return "/focus [@mouseover]"
    elseif actionType == "assist" then
        return "/assist [@mouseover]"
    elseif actionType:match("^ping") then
        return PING_MACROS[actionType] or "/ping [@mouseover]"
    end
    return nil
end

-- Write keyboard-key virtual-button cast attrs to a proxy.
-- Called after GetOrCreateProxy; frame is the parent for target/menu sub-proxies.
local function ApplyKeyboardAttrsToProxy(proxy, frame)
    if InCombatLockdown() then return end
    if #globalKeyBindings == 0 and KeyboardContextUnresolved() then return end

    -- Clear stale attrs from previous apply on this proxy.
    local oldVBtns = proxyKeyVBtns[proxy]
    if oldVBtns then
        for vBtn in pairs(oldVBtns) do
            proxy:SetAttribute("type-" .. vBtn, nil)
            proxy:SetAttribute("macrotext-" .. vBtn, nil)
            proxy:SetAttribute("unit-" .. vBtn, nil)
            proxy:SetAttribute("clickbutton-" .. vBtn, nil)
            proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), nil)
            proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), nil)
            proxy:SetAttribute("type-friend" .. vBtn, nil)
            proxy:SetAttribute("macrotext-friend" .. vBtn, nil)
            proxy:SetAttribute("type-enemy" .. vBtn, nil)
            proxy:SetAttribute("macrotext-enemy" .. vBtn, nil)
        end
    end
    -- Clear old remap tracking for this proxy before rebuilding.
    proxyRemapVBtns[proxy] = nil
    local vBtnSet = {}
    proxyKeyVBtns[proxy] = vBtnSet

    for _, b in ipairs(globalKeyBindings) do
        local vBtn = GetVirtualButtonName(b)
        vBtnSet[vBtn] = true
        local actionType = b.actionType or "spell"
        if actionType == "menu" then
            proxy:SetAttribute("type-" .. vBtn, "togglemenu")
            proxy:SetAttribute("unit-" .. vBtn, "mouseover")
        elseif actionType == "target" then
            local tProxy = GetTargetProxy(frame)
            if tProxy then
                proxy:SetAttribute("type-" .. vBtn, "click")
                proxy:SetAttribute("clickbutton-" .. vBtn, tProxy)
            end
        else
            local actionType2 = b.actionType or "spell"
            if actionType2 == "spell" and b.friend then
                local remapped = "friend" .. vBtn
                proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, BuildPlainMouseoverCastMacro(b.spell))
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("helpbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            elseif actionType2 == "spell" and b.enemy then
                local remapped = "enemy" .. vBtn
                proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, BuildPlainMouseoverCastMacro(b.spell))
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("harmbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            elseif actionType2 == "macro" and b.friend then
                local remapped = "friend" .. vBtn
                proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, b.macro)
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("helpbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            elseif actionType2 == "macro" and b.enemy then
                local remapped = "enemy" .. vBtn
                proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), remapped)
                proxy:SetAttribute("type-" .. remapped, "macro")
                proxy:SetAttribute("macrotext-" .. remapped, b.macro)
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[ButtonAttrName("harmbutton", vBtn)] = true
                remapSet["type-" .. remapped] = true
                remapSet["macrotext-" .. remapped] = true
            else
                local mt = BuildKeyMacro(b)
                if mt then
                    proxy:SetAttribute("type-" .. vBtn, "macro")
                    proxy:SetAttribute("macrotext-" .. vBtn, mt)
                end
            end
        end
    end
end

-- Clear keyboard-key virtual-button attrs from a proxy.
local function ClearKeyboardAttrsFromProxy(proxy)
    if InCombatLockdown() then return end
    local oldVBtns = proxyKeyVBtns[proxy]
    if not oldVBtns then return end
    for vBtn in pairs(oldVBtns) do
        proxy:SetAttribute("type-" .. vBtn, nil)
        proxy:SetAttribute("macrotext-" .. vBtn, nil)
        proxy:SetAttribute("unit-" .. vBtn, nil)
        proxy:SetAttribute("clickbutton-" .. vBtn, nil)
        -- Clear any helpbutton/harmbutton remapped attrs
        proxy:SetAttribute(ButtonAttrName("helpbutton", vBtn), nil)
        proxy:SetAttribute(ButtonAttrName("harmbutton", vBtn), nil)
        proxy:SetAttribute("type-friend" .. vBtn, nil)
        proxy:SetAttribute("macrotext-friend" .. vBtn, nil)
        proxy:SetAttribute("type-enemy" .. vBtn, nil)
        proxy:SetAttribute("macrotext-enemy" .. vBtn, nil)
    end
    proxyKeyVBtns[proxy] = nil
    -- Clear any tracked remapped attrs from the mouse/scroll path
    local remapSet = proxyRemapVBtns[proxy]
    if remapSet then
        for attr in pairs(remapSet) do
            proxy:SetAttribute(attr, nil)
        end
        proxyRemapVBtns[proxy] = nil
    end
end

-- Publish keyboard key attrs to ALL currently registered proxies.
-- Called after ResolveBindings so the new globalKeyBindings list is live.
local function ApplyGlobalKeyboardBindings()
    if InCombatLockdown() then return end
    for frame in pairs(registeredFrames) do
        local proxy = proxyPool[frame]
        if proxy then
            ApplyKeyboardAttrsToProxy(proxy, frame)
        end
    end
end

-- Clear keyboard key attrs from all registered proxies (on disable/teardown).
local function ClearGlobalKeyboardBindings()
    if InCombatLockdown() then return end
    for frame in pairs(registeredFrames) do
        local proxy = proxyPool[frame]
        if proxy then
            ClearKeyboardAttrsFromProxy(proxy)
        end
    end
end

---------------------------------------------------------------------------
-- CLICK DIRECTION: Controls whether source frames fire on key down, up, or both.
-- The per-frame proxy always stays pinned to RegisterForClicks("AnyUp") because
-- the delegated click sends no direction arg of its own — only the source frame's
-- direction affects when the cast fires. This mirrors the reference addon's design.
---------------------------------------------------------------------------

-- Return the RegisterForClicks argument(s) for the source frame based on the
-- configured clickDirection setting:
--   "both"        → "AnyUp", "AnyDown"
--   "up"          → "AnyUp"
--   "down" / nil  → "AnyDown"
local function GetButtonDirections()
    local db = GetDB()
    local dir = db and db.clickCast and db.clickCast.clickDirection
    if dir == "both" then
        return "AnyUp", "AnyDown"
    elseif dir == "up" then
        return "AnyUp"
    else
        return "AnyDown"
    end
end

-- True when the source frame should register the action on key/button DOWN
-- (i.e. direction is "down" or "both"). False when "up" only.
local function UseActionOnKeyDown()
    local db = GetDB()
    local dir = db and db.clickCast and db.clickCast.clickDirection
    return dir ~= "up"
end

-- BUTTON_NUMBERS is defined above the A2 FRAME ROUTING section (moved up so
-- WriteFrameRouting can reference it without a forward-declaration).

---------------------------------------------------------------------------
-- FRAME SETUP: Apply click-cast attributes to a frame
---------------------------------------------------------------------------
local function SetupFrameClickCast(frame)
    if not frame or registeredFrames[frame] then return end
    if InCombatLockdown() then return end

    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return end

    -- Get (or create) the per-frame named proxy.
    local proxy = GetOrCreateProxy(frame)
    if not proxy then return end

    -- Write mouse cast attrs to the PROXY (A3).
    for _, binding in ipairs(activeBindings) do
        local prefix = ModifiersToAttributePrefix(binding.modifiers)
        local btnNum = BUTTON_NUMBERS[binding.button] or "1"
        local actionType = binding.actionType or "spell"

        if actionType == "spell" then
            if binding.friend then
                -- Friend-only: helpbutton remap → cast on remapped button.
                -- Engine resolution: SecureButton_GetModifiedAttribute reads
                -- livemodifierprefix .. attrname .. GetButtonSuffix(button), so
                -- for alt+LeftButton the attr is "alt-helpbutton1" (prefix before
                -- the attr name, numeric btnNum appended without dash).
                local helpAttr = prefix .. "helpbutton" .. btnNum  -- e.g. "shift-helpbutton1"
                local remapped = "friend" .. btnNum                -- e.g. "friend1" (no prefix)
                local typeAttr = prefix .. "type-friend" .. btnNum -- e.g. "shift-type-friend1"
                local textAttr = prefix .. "macrotext-friend" .. btnNum
                proxy:SetAttribute(helpAttr, remapped)
                local macro
                if db.clickCast.smartRes and prefix == "" and btnNum == "1" then
                    local resSpell = GetResurrectionSpellName()
                    if resSpell then
                        macro = "/cast [@mouseover,help,dead] " .. resSpell
                            .. "; [@mouseover] " .. binding.spell
                    end
                end
                proxy:SetAttribute(typeAttr, "macro")
                proxy:SetAttribute(textAttr, macro or BuildPlainMouseoverCastMacro(binding.spell))
                -- Track remapped attrs for ClearFrameClickCast
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[helpAttr] = true
                remapSet[typeAttr] = true
                remapSet[textAttr] = true
            elseif binding.enemy then
                -- Enemy-only: harmbutton remap → cast on remapped button.
                local harmAttr = prefix .. "harmbutton" .. btnNum  -- e.g. "shift-harmbutton1"
                local remapped = "enemy" .. btnNum                 -- e.g. "enemy1" (no prefix)
                local typeAttr = prefix .. "type-enemy" .. btnNum
                local textAttr = prefix .. "macrotext-enemy" .. btnNum
                proxy:SetAttribute(harmAttr, remapped)
                proxy:SetAttribute(typeAttr, "macro")
                proxy:SetAttribute(textAttr, BuildPlainMouseoverCastMacro(binding.spell))
                -- Track remapped attrs for ClearFrameClickCast
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[harmAttr] = true
                remapSet[typeAttr] = true
                remapSet[textAttr] = true
            else
                -- Any (neither flag): 3-clause macro; smart-res on unmodified left-click.
                local macro
                if db.clickCast.smartRes and prefix == "" and btnNum == "1" then
                    local resSpell = GetResurrectionSpellName()
                    if resSpell then
                        macro = "/cast [@mouseover,help,dead] " .. resSpell
                            .. "; [@mouseover,help,nodead] " .. binding.spell
                            .. "; [@mouseover,harm,nodead] " .. binding.spell
                            .. "; [@mouseover] " .. binding.spell
                    end
                end
                proxy:SetAttribute(prefix .. "type" .. btnNum, "macro")
                proxy:SetAttribute(prefix .. "macrotext" .. btnNum, macro or BuildMouseoverCastMacro(binding.spell))
            end
        elseif actionType == "macro" then
            if binding.friend then
                -- Friend-only macro: helpbutton remap → run user macro on remapped button.
                local helpAttr = prefix .. "helpbutton" .. btnNum
                local remapped = "friend" .. btnNum
                local typeAttr = prefix .. "type-friend" .. btnNum
                local textAttr = prefix .. "macrotext-friend" .. btnNum
                proxy:SetAttribute(helpAttr, remapped)
                proxy:SetAttribute(typeAttr, "macro")
                proxy:SetAttribute(textAttr, binding.macro)
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[helpAttr] = true
                remapSet[typeAttr] = true
                remapSet[textAttr] = true
            elseif binding.enemy then
                -- Enemy-only macro: harmbutton remap → run user macro on remapped button.
                local harmAttr = prefix .. "harmbutton" .. btnNum
                local remapped = "enemy" .. btnNum
                local typeAttr = prefix .. "type-enemy" .. btnNum
                local textAttr = prefix .. "macrotext-enemy" .. btnNum
                proxy:SetAttribute(harmAttr, remapped)
                proxy:SetAttribute(typeAttr, "macro")
                proxy:SetAttribute(textAttr, binding.macro)
                local remapSet = proxyRemapVBtns[proxy]
                if not remapSet then remapSet = {}; proxyRemapVBtns[proxy] = remapSet end
                remapSet[harmAttr] = true
                remapSet[typeAttr] = true
                remapSet[textAttr] = true
            else
                proxy:SetAttribute(prefix .. "type" .. btnNum, "macro")
                proxy:SetAttribute(prefix .. "macrotext" .. btnNum, binding.macro)
            end
        elseif actionType == "target" then
            -- Plain unmodified left-click targets natively; every other target
            -- trigger is gated in 12.0.7 -- route through the ungated click proxy.
            if prefix == "" and btnNum == "1" then
                proxy:SetAttribute(prefix .. "type" .. btnNum, "target")
            else
                local tProxy = GetTargetProxy(frame)
                if tProxy then
                    proxy:SetAttribute(prefix .. "type" .. btnNum, "click")
                    proxy:SetAttribute(prefix .. "clickbutton" .. btnNum, tProxy)
                end
            end
        elseif actionType == "focus" then
            proxy:SetAttribute(prefix .. "type" .. btnNum, "focus")
        elseif actionType == "assist" then
            proxy:SetAttribute(prefix .. "type" .. btnNum, "assist")
        elseif actionType == "menu" then
            -- Plain unmodified right-click opens menu natively; others gated.
            if prefix == "" and btnNum == "2" then
                proxy:SetAttribute(prefix .. "type" .. btnNum, "togglemenu")
            else
                local mProxy = GetMenuProxy(frame)
                if mProxy then
                    proxy:SetAttribute(prefix .. "type" .. btnNum, "click")
                    proxy:SetAttribute(prefix .. "clickbutton" .. btnNum, mProxy)
                end
            end
        elseif actionType:match("^ping") then
            proxy:SetAttribute(prefix .. "type" .. btnNum, "macro")
            proxy:SetAttribute(prefix .. "macrotext" .. btnNum, PING_MACROS[actionType] or "/ping [@mouseover]")
        end
    end

    -- Write scroll-wheel virtual button cast attrs to proxy (A3).
    if #keyboardBindings > 0 then
        SetFrameKeyAttributes(proxy, frame)
        frame:EnableMouseWheel(true)
    end

    -- Write keyboard-key virtual button cast attrs to proxy (A3/A4).
    ApplyKeyboardAttrsToProxy(proxy, frame)

    -- Install secure hover wraps whenever there are any override keys (A4).
    -- Always wrap registered frames — the snippets are no-ops if keycount=0.
    WrapFrameSecureHandlers(frame)

    -- Write frame routing attrs so clicks delegate to the proxy (A2).
    WriteFrameRouting(frame, proxy)

    -- Register the source frame for the configured click direction.
    -- The proxy stays pinned to "AnyUp" (set in GetOrCreateProxy); only the
    -- source frame changes so the engine sees the correct up/down event.
    frame:RegisterForClicks(GetButtonDirections())

    -- Live-registration marker, read by the secure hover snippets.
    frame:SetAttribute("clickcast-active", 1)

    registeredFrames[frame] = true

    -- Only add script hooks once per frame — HookScript is additive and
    -- cannot be removed, so re-hooking on every RefreshBindings would
    -- duplicate tooltip lines and resurrection swaps.
    if not hookedFrames[frame] then
        hookedFrames[frame] = true

        -- Binding lifecycle is SECURE-ONLY: the OnEnter wrap binds, the OnLeave
        -- wrap clears, and the clear-only dangling driver releases a lost cursor.
        -- Smart-res is baked into the proxy's left-click macro at setup time
        -- (the [@mouseover,help,dead] clause), not swapped insecurely on hover.

        -- Cold-login recovery: if spec/loadout data arrives after the bounded
        -- startup retry is exhausted, a hover on any registered frame triggers
        -- a one-shot re-resolve so keyboard click-cast revives without a /reload.
        -- This is the only insecure OnEnter hook — it only schedules a timer and
        -- never touches secure attributes directly.
        frame:HookScript("OnEnter", function()
            if not isEnabled then return end
            if #globalKeyBindings > 0 then return end        -- already resolved
            if KeyboardContextUnresolved() then return end   -- still unresolved
            -- Spec data just landed but retry is exhausted — schedule recovery.
            C_Timer.After(0, function()
                if not isEnabled then return end
                if InCombatLockdown() then
                    -- Can't run secure setup mid-combat; defer to PLAYER_REGEN_ENABLED.
                    QUI_GFCC.pendingRefresh = true
                    return
                end
                QUI_GFCC:RefreshBindings()
            end)
        end)

        -- Tooltip showing available bindings (mouse + keyboard).
        -- Always install the hook — check db.clickCast.showTooltip at runtime
        -- so toggling the setting takes effect without reload.
        frame:HookScript("OnEnter", function(self)
            if not isEnabled then return end
            local ccdb = GetDB()
            if not ccdb or not ccdb.clickCast or not ccdb.clickCast.showTooltip then return end
            if #activeBindings == 0 and #keyboardBindings == 0 and #globalKeyBindings == 0 then return end

            -- Check if we should show tooltip (avoid conflict with unit tooltip)
            local existingOwner = GameTooltip:GetOwner()
            if existingOwner == self then
                -- Append to existing unit tooltip
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(ns.L["Click-Cast Bindings:"], 0.2, 0.83, 0.6)
                for _, binding in ipairs(activeBindings) do
                    local modLabel = MODIFIER_LABELS[binding.modifiers or ""] or ""
                    local buttonLabel = BUTTON_NAMES[binding.button] or binding.button
                    local at = binding.actionType or "spell"
                    local spellLabel = PING_LABELS[at] or binding.spell or at or "?"
                    GameTooltip:AddDoubleLine(
                        modLabel .. buttonLabel,
                        spellLabel,
                        0.8, 0.8, 0.8, 1, 1, 1
                    )
                end
                -- globalKeyBindings = keyboard keys; keyboardBindings = scroll-wheel
                -- binds. Both render their macros on the per-frame proxy.
                for _, keyTable in ipairs({ globalKeyBindings, keyboardBindings }) do
                    for _, binding in ipairs(keyTable) do
                        local modLabel = MODIFIER_LABELS[binding.modifiers or ""] or ""
                        local keyLabel = KEY_DISPLAY_NAMES[binding.key] or binding.key or "?"
                        local at = binding.actionType or "spell"
                        local spellLabel = PING_LABELS[at] or binding.spell or at or "?"
                        GameTooltip:AddDoubleLine(
                            modLabel .. keyLabel,
                            spellLabel,
                            0.8, 0.8, 0.8, 1, 1, 1
                        )
                    end
                end
                GameTooltip:Show()
            end
        end)
    end
end

---------------------------------------------------------------------------
-- CLEAR: Remove click-cast attributes from a frame (A5)
---------------------------------------------------------------------------
local function ClearFrameClickCast(frame)
    if not frame or not registeredFrames[frame] then return end
    if InCombatLockdown() then return end

    -- Restore the frame's original routing attrs (from backup) and clear proxyname.
    TeardownFrameRouting(frame)

    -- Clear cast attrs from the proxy.
    local proxy = proxyPool[frame]
    if proxy then
        -- Clear mouse cast attrs from proxy.
        local modPrefixes = { "", "alt-", "ctrl-", "shift-", "alt-ctrl-", "alt-shift-", "ctrl-shift-", "alt-ctrl-shift-" }
        for _, prefix in ipairs(modPrefixes) do
            for _, btnNum in pairs(BUTTON_NUMBERS) do
                proxy:SetAttribute(prefix .. "type" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "macrotext" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "clickbutton" .. btnNum, nil)
            end
        end
        -- Clear helpbutton/harmbutton and remapped attrs for mouse bindings.
        -- Attr names follow the engine's resolution format: prefix before the attr
        -- name, numeric btnNum appended without dash (e.g. "shift-helpbutton1").
        for _, prefix in ipairs(modPrefixes) do
            for _, btnNum in pairs(BUTTON_NUMBERS) do
                proxy:SetAttribute(prefix .. "helpbutton" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "harmbutton" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "type-friend" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "macrotext-friend" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "type-enemy" .. btnNum, nil)
                proxy:SetAttribute(prefix .. "macrotext-enemy" .. btnNum, nil)
            end
        end
        -- Clear any remaining tracked remap attrs.
        local remapSet = proxyRemapVBtns[proxy]
        if remapSet then
            for attr in pairs(remapSet) do
                proxy:SetAttribute(attr, nil)
            end
            proxyRemapVBtns[proxy] = nil
        end
        -- Clear scroll-wheel virtual-button attrs from proxy.
        ClearFrameKeyAttributes(proxy)
        -- Clear keyboard-key virtual-button attrs from proxy.
        ClearKeyboardAttrsFromProxy(proxy)
    end

    -- Drop out of the secure hover snippets.
    frame:SetAttribute("clickcast-active", nil)

    registeredFrames[frame] = nil
end

---------------------------------------------------------------------------
-- REASSERT: Re-apply frame routing after CompactUnitFrame_SetUnit clobbers (A5)
---------------------------------------------------------------------------
local function ReassertFrameClickRouting(frame)
    if not registeredFrames[frame] then return end
    if InCombatLockdown() then return end
    local proxy = proxyPool[frame]
    if not proxy then return end
    WriteFrameRouting(frame, proxy)
end

local function ReassertAllFrameClickRouting()
    if InCombatLockdown() then
        QUI_GFCC.pendingRefresh = true
        return
    end
    for frame in pairs(registeredFrames) do
        ReassertFrameClickRouting(frame)
    end
end

local function RegisterHeaderChildren(header)
    if not header then return end
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child then
            SetupFrameClickCast(child)
        end
    end
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

-- Minimal test hook: exposes private pool/routing functions for unit tests.
QUI_GFCC._test = {
    GetOrCreateProxy             = GetOrCreateProxy,
    ProxyName                    = ProxyName,
    WriteFrameRouting            = WriteFrameRouting,
    TeardownFrameRouting         = TeardownFrameRouting,
    ReassertFrameClickRouting    = ReassertFrameClickRouting,
    ApplyKeyboardAttrsToProxy    = ApplyKeyboardAttrsToProxy,
    GetButtonDirections          = GetButtonDirections,
    UseActionOnKeyDown           = UseActionOnKeyDown,
    BuildPlainMouseoverCastMacro = BuildPlainMouseoverCastMacro,
}

function QUI_GFCC:Initialize()
    -- One-time per-character: copy legacy profile.quiGroupFrames.clickCast
    -- onto db.char.clickCast. Initialize can run before PLAYER_ENTERING_WORLD
    -- (groupframes/unitframes call it during their own init), so the
    -- migration must run here too — otherwise the first session after
    -- upgrade reads empty char defaults until PLAYER_ENTERING_WORLD fires.
    MigrateProfileClickCastToChar()

    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return end

    -- Check Clique coexistence
    if IsAddOnLoaded and IsAddOnLoaded("Clique") then
        -- Clique is loaded — disable QUI click-cast by default
        -- unless user explicitly enabled it
        if not db.clickCast.forceOverClique then
            return
        end
    end

    -- Re-entrant Initialize (already set up once): refresh through the
    -- consistent path. A bare re-resolve here updates only the header's key
    -- attributes; if the resolve is transiently empty (spec/loadout data not
    -- ready yet) that would zero the header while frames stay keyboard-wrapped
    -- — silently killing keyboard click-cast (mouse, set directly on the frame,
    -- survives). RefreshBindings rebuilds the header and frames together.
    if isEnabled then
        self:RefreshBindings()
        return
    end

    ResolveBindings()
    UpdateHeaderKeyAttributes()
    ApplyGlobalKeyboardBindings()
    isEnabled = true
end

function QUI_GFCC:RegisterFrame(frame)
    if not isEnabled then return end
    SetupFrameClickCast(frame)
end


function QUI_GFCC:RegisterAllFrames()
    if not isEnabled then return end
    local GF = ns.QUI_GroupFrames
    if not GF or not GF.headers then return end

    -- Walk header children directly rather than relying on a cached list.
    -- This always gets current children regardless of creation timing.
    for _, headerKey in ipairs({"party", "raid", "self"}) do
        RegisterHeaderChildren(GF.headers[headerKey])
    end

    -- Raid section headers used for grouped raids and raid self-first ordering.
    -- These are separate from headers.raid and must be registered independently.
    if GF.raidGroupHeaders then
        for _, header in ipairs(GF.raidGroupHeaders) do
            RegisterHeaderChildren(header)
        end
    end

    -- Spotlight header children
    RegisterHeaderChildren(GF.spotlightHeader)

    -- Re-assert frame routing for already-registered frames: CompactUnitFrame_SetUnit
    -- clobbers *type1 etc. when it reassigns a unit to a header child on roster changes.
    ReassertAllFrameClickRouting()
end

function QUI_GFCC:RegisterUnitFrames()
    if not isEnabled then return end
    local db = GetDB()
    if not db or not db.clickCast then return end

    local ufSettings = db.clickCast.unitFrames
    if not ufSettings then return end

    local UF = ns.QUI_UnitFrames
    if not UF or not UF.frames then return end

    for unitKey, frame in pairs(UF.frames) do
        -- Boss frames: boss1-boss5 all use the "boss" setting
        local settingKey = unitKey:match("^boss%d$") and "boss" or unitKey
        if ufSettings[settingKey] then
            SetupFrameClickCast(frame)
            -- Also register portrait if it exists
            if frame.portrait and frame.portrait.GetAttribute then
                SetupFrameClickCast(frame.portrait)
            end
        end
    end
end

function QUI_GFCC:RefreshBindings()
    if InCombatLockdown() then return end

    local db = GetDB()
    local enabled = db and db.clickCast and db.clickCast.enabled

    -- Clear all existing bindings
    for frame in pairs(registeredFrames) do
        ClearFrameClickCast(frame)
    end
    wipe(registeredFrames)

    if not enabled then
        -- Disable: clear bindings and mark as disabled
        wipe(activeBindings)
        wipe(keyboardBindings)
        wipe(globalKeyBindings)
        UpdateHeaderKeyAttributes()
        ClearHeaderOverrideBindings()
        ClearGlobalKeyboardBindings()
        isEnabled = false
        return
    end

    -- Enable/refresh: resolve bindings and re-apply
    isEnabled = true
    ResolveBindings()
    UpdateHeaderKeyAttributes()          -- scroll-wheel + keyboard key attrs on header
    ApplyGlobalKeyboardBindings()        -- keyboard cast attrs on proxy virtual buttons
    self:RegisterAllFrames()
    self:RegisterUnitFrames()
end

function QUI_GFCC:IsEnabled()
    return isEnabled
end


function QUI_GFCC:GetEditableBindings()
    local db = GetDB()
    if not db or not db.clickCast then return {} end
    local cc = db.clickCast

    if cc.perSpec then
        local specID = GetCurrentSpecID()
        if specID then
            if cc.perLoadout then
                local configID = GetStableLoadoutID()
                if configID then
                    if not cc.loadoutBindings then cc.loadoutBindings = {} end
                    if not cc.loadoutBindings[specID] then cc.loadoutBindings[specID] = {} end
                    if not cc.loadoutBindings[specID][configID] then cc.loadoutBindings[specID][configID] = {} end
                    return cc.loadoutBindings[specID][configID]
                end
            end
            if not cc.specBindings then cc.specBindings = {} end
            if not cc.specBindings[specID] then cc.specBindings[specID] = {} end
            return cc.specBindings[specID]
        end
    end

    if not cc.bindings then cc.bindings = {} end
    return cc.bindings
end

function QUI_GFCC:AddBinding(binding)
    if not binding then return false, "No binding specified" end
    if not binding.button and not binding.key then return false, "No button or key specified" end

    local bindings = self:GetEditableBindings()
    local mod = binding.modifiers or ""

    -- Duplicate detection: same trigger+modifier combo
    for _, existing in ipairs(bindings) do
        if (existing.modifiers or "") == mod then
            if binding.key and existing.key and existing.key == binding.key then
                return false, "A binding for " .. (MODIFIER_LABELS[mod] or "") .. binding.key .. " already exists"
            elseif binding.button and existing.button and existing.button == binding.button then
                return false, "A binding for " .. (MODIFIER_LABELS[mod] or "") .. (BUTTON_NAMES[binding.button] or binding.button) .. " already exists"
            end
        end
    end

    table_insert(bindings, binding)

    if not InCombatLockdown() then
        self:RefreshBindings()
    else
        self.pendingRefresh = true
    end
    return true
end

function QUI_GFCC:RemoveBinding(index)
    local bindings = self:GetEditableBindings()
    if index < 1 or index > #bindings then return false end

    table_remove(bindings, index)

    if not InCombatLockdown() then
        self:RefreshBindings()
    else
        self.pendingRefresh = true
    end
    return true
end

function QUI_GFCC:GetButtonNames()
    return BUTTON_NAMES
end

function QUI_GFCC:GetModifierLabels()
    return MODIFIER_LABELS
end

-- Global ping keybinds use Blizzard's native binding actions directly
-- (TOGGLEPINGLISTENER, PINGATTACK, PINGWARNING, PINGONMYWAY, PINGASSIST).
-- No SecureActionButtons needed — the UI binds keys to these native actions.

---------------------------------------------------------------------------
-- ROOT SPELL MIGRATION: Convert stored spell names to root spellIDs
---------------------------------------------------------------------------
local function MigrateBindingsToRootSpells(bindingTable)
    if not bindingTable then return end
    for _, binding in ipairs(bindingTable) do
        if (binding.actionType or "spell") == "spell" and not binding.spellID and binding.spell then
            local spellID = C_Spell.GetSpellIDForSpellIdentifier(binding.spell)
            if spellID then
                local baseID = C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(spellID) or spellID
                binding.spellID = baseID
                local rootName = C_Spell.GetSpellName(baseID)
                if rootName then binding.spell = rootName end
            end
        end
    end
end

local function RunRootSpellMigration()
    local db = GetDB()
    if not db or not db.clickCast then return end
    local cc = db.clickCast
    if cc.rootSpellMigrationDone then return end

    -- Migrate shared bindings
    MigrateBindingsToRootSpells(cc.bindings)

    -- Migrate per-spec bindings
    if cc.specBindings then
        for _, specTable in pairs(cc.specBindings) do
            MigrateBindingsToRootSpells(specTable)
        end
    end

    -- Migrate per-loadout bindings
    if cc.loadoutBindings then
        for _, specTable in pairs(cc.loadoutBindings) do
            for _, loadoutTable in pairs(specTable) do
                MigrateBindingsToRootSpells(loadoutTable)
            end
        end
    end

    cc.rootSpellMigrationDone = true
end

---------------------------------------------------------------------------
-- PROFILE → CHAR MIGRATION
-- v3.5.3 moved click-cast settings from db.profile.quiGroupFrames.clickCast
-- to db.char.clickCast so bindings stop leaking across characters that
-- share an AceDB profile. On the first login per character after the
-- upgrade, we deep-copy the legacy profile data over the freshly-seeded
-- char defaults. Stale profile data is left in place so a downgrade can
-- recover it.
---------------------------------------------------------------------------
local DeepCopy = ns.Helpers.DeepCopy

function MigrateProfileClickCastToChar()
    local QUI = _G.QUI
    if not QUI or not QUI.db then return end
    local charDB = QUI.db.char
    local profile = QUI.db.profile
    if not charDB or not profile then return end

    if not charDB.clickCast then charDB.clickCast = {} end
    if charDB.clickCast._migratedFromProfile then return end

    local source = profile.quiGroupFrames and profile.quiGroupFrames.clickCast
    if type(source) == "table" then
        for k, v in pairs(source) do
            charDB.clickCast[k] = DeepCopy(v)
        end
    end

    charDB.clickCast._migratedFromProfile = true
end

---------------------------------------------------------------------------
-- EVENTS: Spec/loadout change and combat end
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
-- Cold-login data-ready signals: spec/talent data can land after the bounded
-- startup retry gives up, so re-resolve when the client says it's available.
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")

local loadoutDebounceTimer = nil
local rosterDebounceTimer = nil

-- Startup catch-up: on a cold login, spec/loadout data lands asynchronously
-- after PLAYER_ENTERING_WORLD, so the first binding resolve can come up empty
-- and leave the secure header at keycount 0 (keyboard click-cast dead) while the
-- directly-applied mouse attributes still work. A single fixed-delay pass loses
-- that race and nothing re-runs it. Retry RefreshBindings until the active
-- binding table actually resolves -- the way an in-world /reload (data already
-- cached) gets it right on the first pass. Bounded so a profile with genuinely
-- no resolvable bindings doesn't spin.
local STARTUP_REFRESH_INTERVAL = 1.0
local STARTUP_REFRESH_MAX_ATTEMPTS = 12
local startupRefreshAttempts = 0

-- True when the character has click-cast bindings configured somewhere (shared /
-- per-spec / per-loadout). Lets the catch-up tell "data not ready yet" (retry)
-- apart from "nothing to apply" (stop).
function HasConfiguredBindings()
    local db = GetDB()
    if not db or not db.clickCast then return false end
    local cc = db.clickCast
    if cc.bindings and #cc.bindings > 0 then return true end
    if cc.specBindings then
        for _, t in pairs(cc.specBindings) do
            if type(t) == "table" and #t > 0 then return true end
        end
    end
    if cc.loadoutBindings then
        for _, specTable in pairs(cc.loadoutBindings) do
            if type(specTable) == "table" then
                for _, t in pairs(specTable) do
                    if type(t) == "table" and #t > 0 then return true end
                end
            end
        end
    end
    return false
end

-- True when click-cast is on and configured but nothing has resolved yet
-- (all three binding tables empty) -- i.e. spec/loadout data is still landing.
-- Shared by the startup retry guard and the data-ready event handlers so they
-- agree on "still dead". Must check globalKeyBindings (keyboard keys) too, or a
-- resolved keyboard-only config would look perpetually unresolved.
IsUnresolvedButConfigured = function()
    local db = GetDB()
    if not db or not db.clickCast or not db.clickCast.enabled then return false end
    return #activeBindings == 0 and #keyboardBindings == 0 and #globalKeyBindings == 0
        and HasConfiguredBindings()
end

local function RunStartupRefresh()
    -- Secure setup can't run in combat; defer to PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then
        QUI_GFCC.pendingRefresh = true
        return
    end

    startupRefreshAttempts = startupRefreshAttempts + 1
    QUI_GFCC:RefreshBindings()

    -- Bindings configured but nothing resolved => spec/loadout data isn't ready
    -- yet. Retry for a bounded window. If the data lands after the window closes,
    -- two catch-alls pick it up: the PLAYER_TALENT_UPDATE /
    -- ACTIVE_PLAYER_SPECIALIZATION_CHANGED handlers (proactive), and the on-hover
    -- re-resolve (on demand, when the user reaches for the keybind).
    if startupRefreshAttempts < STARTUP_REFRESH_MAX_ATTEMPTS and IsUnresolvedButConfigured() then
        C_Timer.After(STARTUP_REFRESH_INTERVAL, RunStartupRefresh)
    end
end

eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Migrate old QUI ping bindings (CLICK format and QUI_PING_* action
        -- names) to Blizzard's native ping actions.
        local OLD_TO_NATIVE = {
            ["CLICK QUI_PingButton_Contextual:LeftButton"] = "TOGGLEPINGLISTENER",
            ["CLICK QUI_PingButton_Assist:LeftButton"]     = "PINGASSIST",
            ["CLICK QUI_PingButton_Attack:LeftButton"]     = "PINGATTACK",
            ["CLICK QUI_PingButton_Warning:LeftButton"]    = "PINGWARNING",
            ["CLICK QUI_PingButton_OnMyWay:LeftButton"]    = "PINGONMYWAY",
            ["QUI_PING"]         = "TOGGLEPINGLISTENER",
            ["QUI_PING_ASSIST"]  = "PINGASSIST",
            ["QUI_PING_ATTACK"]  = "PINGATTACK",
            ["QUI_PING_WARNING"] = "PINGWARNING",
            ["QUI_PING_ONMYWAY"] = "PINGONMYWAY",
        }
        local didMigrate = false
        for oldBinding, nativeAction in pairs(OLD_TO_NATIVE) do
            local key1, key2 = GetBindingKey(oldBinding)
            if key1 then SetBinding(key1, nativeAction); didMigrate = true end
            if key2 then SetBinding(key2, nativeAction); didMigrate = true end
        end
        if didMigrate then SaveBindings(GetCurrentBindingSet()) end

        -- One-time per-character: copy legacy profile.quiGroupFrames.clickCast
        -- onto db.char.clickCast. Must run before RunRootSpellMigration so
        -- the root-spell pass operates on the migrated char-level data.
        MigrateProfileClickCastToChar()

        -- Migrate existing bindings to store root spellIDs
        RunRootSpellMigration()

        -- After /reload or zone transition, re-register all frames.
        -- Spec data and group composition may not be fully available during
        -- ADDON_LOADED, so this catch-up ensures bindings are applied.
        if not isEnabled then
            -- Try to initialize if not done yet (covers case where
            -- ADDON_LOADED ran before DB was ready)
            QUI_GFCC:Initialize()
        end
        if isEnabled then
            startupRefreshAttempts = 0
            C_Timer.After(STARTUP_REFRESH_INTERVAL, RunStartupRefresh)
        end
        return
    end

    if not isEnabled then return end

    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Re-resolve bindings for new spec
        C_Timer.After(0.5, function()
            if not InCombatLockdown() then
                QUI_GFCC:RefreshBindings()
            else
                QUI_GFCC.pendingRefresh = true
            end
        end)
    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
        -- Spec/talent data may have just become available on a cold login. This is
        -- the catch-all that revives keyboard click-cast if the bounded startup
        -- retry gave up before the data landed. These fire frequently, so act only
        -- while still stranded (keycount 0 with bindings configured) and coalesce
        -- a burst into a single deferred resolve.
        if not dataReadyRefreshScheduled and IsUnresolvedButConfigured() then
            dataReadyRefreshScheduled = true
            C_Timer.After(0.5, function()
                dataReadyRefreshScheduled = false
                if not IsUnresolvedButConfigured() then return end
                if not InCombatLockdown() then
                    QUI_GFCC:RefreshBindings()
                else
                    QUI_GFCC.pendingRefresh = true
                end
            end)
        end
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_COMBAT_CONFIG_CHANGED" then
        -- Loadout changed within same spec — only relevant if perLoadout is on
        local db = GetDB()
        if not db or not db.clickCast or not db.clickCast.perLoadout then return end

        -- Debounce: talent API may not be ready immediately
        if loadoutDebounceTimer then loadoutDebounceTimer:Cancel() end
        loadoutDebounceTimer = C_Timer.NewTimer(0.5, function()
            loadoutDebounceTimer = nil
            if not InCombatLockdown() then
                QUI_GFCC:RefreshBindings()
            else
                QUI_GFCC.pendingRefresh = true
            end
        end)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Roster changed (e.g. zoning into a dungeon adds party members, including
        -- NPC followers). Secure group headers create and assign their child unit
        -- buttons lazily as the roster settles — frequently AFTER the one-shot
        -- PLAYER_ENTERING_WORLD catch-up — so frames that appear on a roster change
        -- would otherwise have no click-cast bindings until the next /reload.
        -- Re-register all frames: SetupFrameClickCast is idempotent (it skips
        -- already-registered frames), so this only binds the newly created ones.
        -- Debounce because GRU fires in bursts and the header needs a moment to
        -- create/assign children.
        if rosterDebounceTimer then rosterDebounceTimer:Cancel() end
        rosterDebounceTimer = C_Timer.NewTimer(0.3, function()
            rosterDebounceTimer = nil
            if not InCombatLockdown() then
                QUI_GFCC:RegisterAllFrames()
                QUI_GFCC:RegisterUnitFrames()
            else
                QUI_GFCC.pendingRefresh = true
            end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Apply any deferred binding changes
        if QUI_GFCC.pendingRefresh then
            QUI_GFCC.pendingRefresh = false
            QUI_GFCC:RefreshBindings()
        end
    end
end)
