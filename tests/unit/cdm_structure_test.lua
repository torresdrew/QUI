-- tests/unit/cdm_structure_test.lua
-- Headless verification of CDM load-manifest structure. Run: lua tests/unit/cdm_structure_test.lua

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local function indexOf(text, needle)
    local first = string.find(text, needle, 1, true)
    return first
end

local xml = readAll("modules/cdm/cdm.xml")

local domain = indexOf(xml, 'file="cdm_domain.lua"')
local visibility = indexOf(xml, 'file="hud_visibility.lua"')
local runtime = indexOf(xml, 'file="cdm_runtime.lua"')
local renderers = indexOf(xml, 'file="cdm_frame_writes.lua"')
local spellData = indexOf(xml, 'file="cdm_spelldata.lua"')
local mirror = indexOf(xml, 'file="cdm_blizz_mirror.lua"')
local icons = indexOf(xml, 'file="cdm_icon_renderer.lua"')
local bars = indexOf(xml, 'file="cdm_bar_renderer.lua"')
local containers = indexOf(xml, 'file="cdm_containers.lua"')
local settingsPage = indexOf(xml, 'file="settings\\containers_page.lua"')
local composer = indexOf(xml, 'file="settings\\composer.lua"')

assert(domain, "cdm_domain.lua should be loaded")
assert(visibility, "hud_visibility.lua should be loaded")
assert(domain < visibility, "domain facts should load before visibility/runtime consumers")

assert(runtime, "cdm_runtime.lua should be loaded")
assert(renderers, "cdm_frame_writes.lua should be loaded")
assert(spellData, "cdm_spelldata.lua should be loaded")
assert(mirror, "cdm_blizz_mirror.lua should be loaded")
assert(icons, "cdm_icon_renderer.lua should be loaded")
assert(bars, "cdm_bar_renderer.lua should be loaded")
assert(containers, "cdm_containers.lua should be loaded")
assert(settingsPage, "settings\\containers_page.lua should be loaded")
assert(composer, "settings\\composer.lua should be loaded")
assert(runtime < renderers, "runtime data should load before renderer effects")
assert(renderers < spellData, "renderer exports should load before spell data consumers")
assert(runtime < mirror, "runtime data should load before mirror capture")
assert(mirror < icons, "mirror capture should load before icon rendering")
assert(icons < bars, "icon rendering should load before bar rendering")
assert(bars < containers, "bar rendering should load before container layout")
assert(containers < settingsPage, "container settings page should load after container exports")
assert(settingsPage < composer, "composer should load from the settings folder after the settings page shell")

local removedHotPathFiles = {
    "cdm_renderers.lua",
    "cdm_icons.lua",
    "cdm_bars.lua",
    "cdm_runtime_store.lua",
    "cdm_scheduler.lua",
    "cdm_sources.lua",
    "cdm_runtime_queries.lua",
    "cdm_resolvers.lua",
    "cdm_icon_factory.lua",
    "cdm_icon_stack_text.lua",
    "cdm_icon_stack_policy.lua",
    "cdm_icon_mirror_index.lua",
    "cdm_icon_runtime_refresh.lua",
    "cdm_icon_update_scheduler.lua",
    "cdm_icon_refresh_batch.lua",
    "cdm_icon_refresh_walker.lua",
    "cdm_icon_item_visual_policy.lua",
    "cdm_icon_visibility_policy.lua",
    "cdm_icon_range_policy.lua",
    "cdm_icon_cooldown_policy.lua",
    "cdm_icon_custom_bar_policy.lua",
    "cdm_effects.lua",
    "cdm_index.lua",
    "cdm_catalog.lua",
    "cdm_shared.lua",
    "cdm_provider.lua",
    "cdm_composer.lua",
    "cdm_aura_catalog.lua",
    "cdm_aura_runtime.lua",
    "cdm_layout.lua",
    "cdm_buff_layout.lua",
    "cdm_layout_mode.lua",
    "settings\\containers_page_schema.lua",
    "settings\\containers_page_model.lua",
    "settings\\containers_page_surface.lua",
}

for _, fileName in ipairs(removedHotPathFiles) do
    assert(not indexOf(xml, 'file="' .. fileName .. '"'), fileName .. " should be consolidated out of cdm.xml")
end

assert(not indexOf(xml, 'file="glows.lua"'), "glows.lua should remain consolidated")
assert(not indexOf(xml, 'file="swipe.lua"'), "swipe.lua should remain consolidated")
assert(not indexOf(xml, 'file="highlighter.lua"'), "highlighter.lua should remain consolidated")

print("OK: cdm_structure_test")
