---------------------------------------------------------------------------
-- QUI Third-Party Frame Cleanup
-- Suppresses white backdrops and visible NineSlice borders on frames
-- that QUI's per-frame skinning modules don't cover (typically from
-- other loaded addons). Runs a delayed scan after login and re-scans
-- when new addons load.
---------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local Helpers = ns.Helpers
local SkinBase = ns.SkinBase

local issecretvalue = issecretvalue

-- Weak-keyed set of frames we've already processed
local processed = setmetatable({}, { __mode = "k" })
local initialized = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function IsEnabled()
    local db = QUI.db and QUI.db.profile
    return db and db.general and db.general.skinThirdParty ~= false
end

--- Returns true if the frame name matches a known Blizzard/QUI prefix
--- so we don't accidentally suppress intentional Blizzard NineSlices
--- that QUI simply hasn't skinned.
local function IsBlizzardOrQUIFrame(name)
    if type(name) ~= "string" then return false end
    -- QUI-owned frames
    if name:find("^QUI") or name:find("^Quazii") then return true end
    -- Common Blizzard prefixes — these frames may have intentional NineSlices
    -- that QUI doesn't skin; leave them alone.
    if name:find("^Blizzard_")
        or name:find("^GameTooltip")
        or name:find("^ItemRef")
        or name:find("^Interface")
        or name:find("^Minimap")
        or name:find("^PlayerFrame")
        or name:find("^TargetFrame")
        or name:find("^ChatFrame")
        or name:find("^SpellBook")
        or name:find("^Character")
        or name:find("^WorldMap")
        or name:find("^Quest")
        or name:find("^Gossip")
        or name:find("^Merchant")
        or name:find("^Mail")
        or name:find("^Friends")
        or name:find("^Communities")
        or name:find("^Encounter")
        or name:find("^Collections")
        or name:find("^Wardrobe")
        or name:find("^Talent")
        or name:find("^Professions")
        or name:find("^AuctionHouse")
        or name:find("^TradeSkill")
        or name:find("^LFG")
        or name:find("^PVE")
        or name:find("^Garrison")
        or name:find("^Adventure")
        or name:find("^ClassTalent")
        or name:find("^Settings")
        or name:find("^Video")
        or name:find("^Audio")
        or name:find("^KeyBinding")
        or name:find("^Macro")
        or name:find("^Addon")
        or name:find("^BankFrame")
        or name:find("^Guild")
        or name:find("^Calendar")
        or name:find("^Achievement")
        or name:find("^ContainerFrame")
        or name:find("^EditMode")
        or name:find("^HelpFrame")
        or name:find("^DropDown")
    then
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Suppress a single frame's white backdrop / visible NineSlice
---------------------------------------------------------------------------

local suppressingBackdrop = false

local function SuppressFrame(f)
    local isS = issecretvalue

    -- White backdrop → darken
    if f.GetBackdropColor then
        local rok, r, g, b = pcall(f.GetBackdropColor, f)
        if rok and not isS(r) and r and r > 0.9 and g > 0.9 and b > 0.9 then
            local hok, h = pcall(f.GetHeight, f)
            if hok and not isS(h) and h and h > 10 then
                suppressingBackdrop = true
                pcall(f.SetBackdropColor, f, 0.05, 0.05, 0.05, 0.95)
                pcall(f.SetBackdropBorderColor, f, 0, 0, 0, 1)
                suppressingBackdrop = false
                processed[f] = true
            end
        end
    end

    -- Visible NineSlice → hide
    if f.NineSlice then
        local aok, a = pcall(f.NineSlice.GetAlpha, f.NineSlice)
        if aok and not isS(a) and a and a > 0 then
            pcall(f.NineSlice.SetAlpha, f.NineSlice, 0)
            processed[f] = true
        end
    end
end

--- Returns true if a frame should be left alone (Blizzard, QUI, or
--- already handled by a per-frame skinning module).
local function ShouldSkipFrame(f)
    if SkinBase.IsSkinned(f) then return true end
    local name = f:GetName()
    return IsBlizzardOrQUIFrame(name)
end

---------------------------------------------------------------------------
-- Core scan
---------------------------------------------------------------------------

local function ScanAndSuppress()
    if not IsEnabled() then return end

    local isS = issecretvalue
    local f = EnumerateFrames()
    while f do
        if not processed[f] and not ShouldSkipFrame(f) then
            local ok, vis = pcall(f.IsVisible, f)
            if ok and not isS(vis) and vis then
                SuppressFrame(f)
            end
        end
        f = EnumerateFrames(f)
    end
end

---------------------------------------------------------------------------
-- Real-time hook — catch white backdrops set after the initial scan
---------------------------------------------------------------------------

if BackdropTemplateMixin and BackdropTemplateMixin.SetBackdropColor then
    hooksecurefunc(BackdropTemplateMixin, "SetBackdropColor", function(self, r, g, b)
        if suppressingBackdrop then return end
        if not initialized or not IsEnabled() then return end
        -- Fast path: skip non-white colors immediately (most common case).
        -- Color check is 3 number comparisons vs ShouldSkipFrame's string matching.
        local isS = issecretvalue
        if isS(r) then return end
        if not r or r <= 0.9 or not g or g <= 0.9 or not b or b <= 0.9 then return end
        if processed[self] then
            -- Frame was already processed but just got its color reset —
            -- clear the processed flag so we re-evaluate.
            processed[self] = nil
        end
        if ShouldSkipFrame(self) then return end
        local hok, h = pcall(self.GetHeight, self)
        if hok and not isS(h) and h and h > 10 then
            suppressingBackdrop = true
            pcall(self.SetBackdropColor, self, 0.05, 0.05, 0.05, 0.95)
            pcall(self.SetBackdropBorderColor, self, 0, 0, 0, 1)
            suppressingBackdrop = false
            processed[self] = true
        end
    end)
end

---------------------------------------------------------------------------
-- Refresh (called by registry on profile/theme change)
---------------------------------------------------------------------------

local function Refresh()
    -- Clear processed set so we re-evaluate everything
    wipe(processed)
    if IsEnabled() then
        C_Timer.After(0.1, ScanAndSuppress)
    end
end

_G.QUI_RefreshThirdPartySkinning = Refresh

---------------------------------------------------------------------------
-- Event handling
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Run after a delay so other addons and QUI skinning modules finish first
        C_Timer.After(1.5, function()
            initialized = true
            ScanAndSuppress()
        end)
    elseif event == "ADDON_LOADED" then
        -- Re-scan when a new addon loads (after initialization)
        if initialized and arg1 ~= ADDON_NAME then
            C_Timer.After(0.5, ScanAndSuppress)
        end
    end
end)

---------------------------------------------------------------------------
-- Registry
---------------------------------------------------------------------------

if ns.Registry then
    ns.Registry:Register("skinThirdParty", {
        refresh = Refresh,
        priority = 99,  -- Run after all other skinning modules
        group = "skinning",
        importCategories = { "skinning", "theme" },
    })
end
