-- tests/actionbars_extra_button_anchor_sync_test.lua
-- Run: lua tests/actionbars_extra_button_anchor_sync_test.lua

local function readFile(path)
    local fh = assert(io.open(path, "rb"), "failed to open " .. path)
    local text = fh:read("*a")
    fh:close()
    return text
end

local source = readFile("modules/actionbars/actionbars.lua")

local function blockBetween(startText, endText)
    local startPos = assert(source:find(startText, 1, true), "missing block start: " .. startText)
    local endPos = assert(source:find(endText, startPos, true), "missing block end: " .. endText)
    return source:sub(startPos, endPos - 1)
end

assert(
    source:find("local function SaveExtraButtonHolderPosition", 1, true),
    "extra/zone mover drags must use a shared persistence helper")

assert(
    source:find("profile.frameAnchoring", 1, true)
        and source:find("fa[buttonType]", 1, true),
    "extra/zone mover persistence must update frameAnchoring for the same key")

local dragStopBlock = blockBetween('mover:SetScript("OnDragStop"', "    return holder, mover")
assert(
    dragStopBlock:find("SaveExtraButtonHolderPosition", 1, true),
    "extra/zone mover drag stop must sync actionBars position and frameAnchoring")

local nudgeBlock = blockBetween('btn:SetScript("OnClick"', "    return btn")
assert(
    nudgeBlock:find("SaveExtraButtonHolderPosition", 1, true),
    "extra/zone mover nudges must sync actionBars position and frameAnchoring")

local reanchorBlock = blockBetween("local function QueueExtraButtonReanchor", "local function HookExtraButtonPositioning")
assert(
    reanchorBlock:find("ApplyExtraButtonSettings%(buttonType%)")
        and reanchorBlock:find("ApplyExtraButtonFrameAnchor%(buttonType%)"),
    "extra/zone reanchor refresh must reapply the saved frame anchor after updating holder size")

print("OK: actionbars_extra_button_anchor_sync_test")
