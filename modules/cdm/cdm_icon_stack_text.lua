local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CDM Icon Stack Text
--
-- Taint-aware stack/count text sink for icon FontStrings. CDMIconStackPolicy
-- decides what value should be shown; this module owns the write/clear
-- mechanics.
---------------------------------------------------------------------------

local CDMIconStackText = {}
ns.CDMIconStackText = CDMIconStackText

local type = type

local issecretvalue = issecretvalue or function() return false end

function CDMIconStackText.TextHasDisplay(text)
    if issecretvalue(text) then
        return true
    end
    if type(text) == "string" then
        return text ~= ""
    end
    return text ~= nil
end

function CDMIconStackText.ValueIsPresent(value)
    if issecretvalue(value) then
        return true
    end
    return value ~= nil
end

function CDMIconStackText.ValueIsMissing(value)
    return not CDMIconStackText.ValueIsPresent(value)
end

function CDMIconStackText.Clear(icon)
    if not icon or not icon.StackText then return end
    icon.StackText.SetText(icon.StackText, "")
    icon.StackText.Hide(icon.StackText)
    icon._stackTextSource = nil
end

function CDMIconStackText.Show(icon, value, source)
    if not icon or not icon.StackText then return false end
    local setOk = true
    local setErr = icon.StackText.SetText(icon.StackText, value)
    if not setOk and icon.StackText.SetFormattedText then
        setOk = true
        setErr = icon.StackText.SetFormattedText(icon.StackText, "%s", value)
    end

    local showOk = false
    local showErr
    if setOk then
        showOk = true
        showErr = icon.StackText.Show(icon.StackText)
    end

    if source ~= nil then
        icon._stackTextSource = source
    end

    return setOk, setErr, showOk, showErr
end
