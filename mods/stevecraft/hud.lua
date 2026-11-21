-- SteveCraft HUD renderer.
-- Uses replaceable PNG files in textures/; the shipped sprites are original
-- SteveCraft artwork. Users can replace them with licensed vanilla copies.

local HUD = {}
local Assets = require("assets")
local atlas = nil
local hotbar = nil
local selection = nil
local loaded = false

local hud_tiles = {
    heart_full = { 0, 16 },
    heart_half = { 16, 16 },
    heart_empty = { 32, 16 },
    food_full = { 48, 16 },
    food_half = { 64, 16 },
    food_empty = { 80, 16 },
    armor_full = { 96, 16 },
    armor_half = { 112, 16 },
    armor_empty = { 128, 16 },
    crosshair = { 144, 16 },
}
local block_tiles = {
    ["minecraft:stone"] = { 0, 0 },
    ["minecraft:dirt"] = { 16, 0 },
    ["minecraft:grass_block"] = { 32, 0 },
    ["minecraft:oak_planks"] = { 64, 0 },
    ["minecraft:cobblestone"] = { 80, 0 },
    ["minecraft:glass"] = { 96, 0 },
    ["minecraft:bricks"] = { 112, 0 },
    ["minecraft:sand"] = { 128, 0 },
    ["minecraft:bedrock"] = { 144, 0 },
}

local function load_textures()
    if loaded then return end
    loaded = true
    if type(get_texture_info) ~= "function" then return end
    local atlas_uri = Assets.get_uri("textures/stevecraft_atlas.png")
    local hotbar_uri = Assets.get_uri("textures/hud/hotbar.png")
    local selection_uri = Assets.get_uri("textures/hud/hotbar_selection.png")
    local ok, result = false, nil
    if atlas_uri ~= nil then ok, result = pcall(get_texture_info, atlas_uri) end
    if ok then atlas = result end
    if hotbar_uri ~= nil then
        ok, result = pcall(get_texture_info, hotbar_uri)
        if ok then hotbar = result end
    end
    if selection_uri ~= nil then
        ok, result = pcall(get_texture_info, selection_uri)
        if ok then selection = result end
    end
end

local function render_texture(texture, x, y, scale_x, scale_y)
    if texture == nil or type(djui_hud_render_texture) ~= "function" then return false end
    local ok = pcall(djui_hud_render_texture, texture, x, y, scale_x or 1, scale_y or scale_x or 1)
    return ok
end

local function render_tile(tile, x, y, scale)
    if atlas == nil or tile == nil or type(djui_hud_render_texture_tile) ~= "function" then return false end
    local ok = pcall(
        djui_hud_render_texture_tile,
        atlas,
        x, y,
        scale or 1, scale or 1,
        tile[1], tile[2], 16, 16
    )
    return ok
end

local function rect(x, y, w, h, r, g, b, a)
    if type(djui_hud_set_color) ~= "function" or type(djui_hud_render_rect) ~= "function" then return end
    djui_hud_set_color(r, g, b, a or 255)
    djui_hud_render_rect(x, y, w, h)
end

local function text(value, x, y, scale, color)
    if type(djui_hud_print_text) ~= "function" then return end
    color = color or { 255, 255, 255, 255 }
    if type(djui_hud_set_color) == "function" then
        djui_hud_set_color(color[1], color[2], color[3], color[4] or 255)
    end
    djui_hud_print_text(tostring(value), x, y, scale or 0.5)
end

local function render_meter_row(prefix, points, x, y, scale)
    local size = 16 * scale
    local gap = 1.5 * scale
    for index = 0, 9 do
        local value = math.max(0, math.min(2, (points or 0) - index * 2))
        local suffix = value == 2 and "_full" or (value == 1 and "_half" or "_empty")
        local tile = hud_tiles[prefix .. suffix]
        local draw_x = x + index * (size + gap)
        if not render_tile(tile, draw_x, y, scale) then
            local color = prefix == "heart" and { 190, 37, 42 } or
                (prefix == "food" and { 190, 111, 43 } or { 150, 160, 170 })
            rect(draw_x, y, size, size, color[1], color[2], color[3], value == 0 and 100 or 255)
        end
    end
end

function HUD.render(context)
    context = context or {}
    if not context.inventory_loaded then return end
    load_textures()

    if type(djui_hud_set_resolution) == "function" and type(RESOLUTION_DJUI) == "number" then
        djui_hud_set_resolution(RESOLUTION_DJUI)
    end
    if type(djui_hud_set_font) == "function" and type(FONT_NORMAL) == "number" then
        djui_hud_set_font(FONT_NORMAL)
    end

    local screen_width = type(djui_hud_get_screen_width) == "function" and djui_hud_get_screen_width() or 320
    local screen_height = type(djui_hud_get_screen_height) == "function" and djui_hud_get_screen_height() or 240
    local inventory = context.inventory or {}
    local selected_slot = context.selected_slot or 1

    if context.camera_active then
        if not render_tile(hud_tiles.crosshair, screen_width * 0.5 - 8, screen_height * 0.5 - 8, 1) then
            rect(screen_width * 0.5 - 1, screen_height * 0.5 - 7, 2, 14, 245, 245, 245, 255)
            rect(screen_width * 0.5 - 7, screen_height * 0.5 - 1, 14, 2, 245, 245, 245, 255)
        end
    end

    local icon_scale = math.max(0.55, math.min(0.78, screen_width / 440))
    local row_width = 10 * 16 * icon_scale + 9 * 1.5 * icon_scale
    local meter_y = screen_height - 58 * icon_scale - 32
    render_meter_row("armor", context.armor_points or 0, 4, meter_y - 14 * icon_scale, icon_scale)
    render_meter_row("heart", context.health_points or 20, 4, meter_y, icon_scale)
    render_meter_row("food", context.hunger_points or 20, screen_width - row_width - 4, meter_y, icon_scale)

    local hotbar_scale = math.max(0.72, math.min(1.0, (screen_width - 24) / 256))
    local hotbar_x = (screen_width - 182 * hotbar_scale) * 0.5 - hotbar_scale
    local hotbar_y = screen_height - 22 * hotbar_scale - 12 - 5 * hotbar_scale
    if not render_texture(hotbar, hotbar_x, hotbar_y, hotbar_scale, hotbar_scale) then
        rect((screen_width - 184 * hotbar_scale) * 0.5, hotbar_y + 5 * hotbar_scale,
            184 * hotbar_scale, 22 * hotbar_scale, 18, 18, 18, 210)
    end

    for slot = 1, 9 do
        local slot_x = hotbar_x + (2 + (slot - 1) * 20) * hotbar_scale
        local slot_y = hotbar_y + 6 * hotbar_scale
        if slot == selected_slot then
            if not render_texture(selection, slot_x - 6 * hotbar_scale, slot_y - 5 * hotbar_scale,
                0.65 * hotbar_scale, 0.65 * hotbar_scale) then
                rect(slot_x - 1, slot_y - 1, 20 * hotbar_scale, 20 * hotbar_scale, 245, 225, 170, 255)
            end
        end

        local item = inventory[slot]
        if item and item.id then
            local icon = block_tiles[item.id]
            if not render_tile(icon, slot_x + 2 * hotbar_scale, slot_y + 2 * hotbar_scale, 0.75 * hotbar_scale) then
                rect(slot_x + 4 * hotbar_scale, slot_y + 4 * hotbar_scale,
                    12 * hotbar_scale, 12 * hotbar_scale, 130, 130, 130, 255)
            end
            text(item.count or 0, slot_x + 11 * hotbar_scale, slot_y + 12 * hotbar_scale, 0.42 * hotbar_scale)
        end
    end

    local selected = inventory[selected_slot]
    if selected and selected.id and context.catalog and context.catalog[selected.id] then
        local name = context.catalog[selected.id].name or selected.id
        text(name .. "  Y " .. tostring(context.height_offset or 0),
            math.max(4, (screen_width - #name * 5) * 0.5),
            hotbar_y - 13, 0.55)
    end

    if context.mining_frames and context.mining_frames > 0
        and context.mining_required and context.mining_required > 0 then
        local progress = math.min(1, context.mining_frames / context.mining_required)
        local width = math.min(140, screen_width * 0.3)
        local x = (screen_width - width) * 0.5
        local y = hotbar_y - 8
        rect(x, y, width, 4, 20, 20, 20, 220)
        rect(x, y, width * progress, 4, 220, 190, 90, 255)
    end
end

function HUD.reset()
    atlas = nil
    hotbar = nil
    selection = nil
    loaded = false
end

return HUD
