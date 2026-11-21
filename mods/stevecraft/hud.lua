-- SteveCraft HUD renderer.
-- HUD art is loaded from the exact Java sprite and block paths embedded in ModFS.
local HUD = {}
local Assets = require("assets")

local loaded = false
local textures = {}

local texture_paths = {
    hotbar = "textures/gui/sprites/hud/hotbar.png",
    selection = "textures/gui/sprites/hud/hotbar_selection.png",
    crosshair = "textures/gui/sprites/hud/crosshair.png",

    heart_full = "textures/gui/sprites/hud/heart/full.png",
    heart_half = "textures/gui/sprites/hud/heart/half.png",
    heart_empty = "textures/gui/sprites/hud/heart/container.png",

    food_full = "textures/gui/sprites/hud/food_full.png",
    food_half = "textures/gui/sprites/hud/food_half.png",
    food_empty = "textures/gui/sprites/hud/food_empty.png",

    armor_full = "textures/gui/sprites/hud/armor_full.png",
    armor_half = "textures/gui/sprites/hud/armor_half.png",
    armor_empty = "textures/gui/sprites/hud/armor_empty.png",

    block_stone = "textures/stevecraft/icons/stone.png",
    block_dirt = "textures/stevecraft/icons/dirt.png",
    block_grass = "textures/stevecraft/icons/grass_block.png",
    block_wood = "textures/stevecraft/icons/oak_planks.png",
    block_cobblestone = "textures/stevecraft/icons/cobblestone.png",
    block_glass = "textures/stevecraft/icons/glass.png",
    block_bricks = "textures/stevecraft/icons/bricks.png",
    block_sand = "textures/stevecraft/icons/sand.png",
    block_bedrock = "textures/stevecraft/icons/bedrock.png",
}

local hud_tiles = {
    heart_full = "heart_full",
    heart_half = "heart_half",
    heart_empty = "heart_empty",
    food_full = "food_full",
    food_half = "food_half",
    food_empty = "food_empty",
    armor_full = "armor_full",
    armor_half = "armor_half",
    armor_empty = "armor_empty",
    crosshair = "crosshair",
}

local block_tiles = {
    ["minecraft:stone"] = "block_stone",
    ["minecraft:dirt"] = "block_dirt",
    ["minecraft:grass_block"] = "block_grass",
    ["minecraft:oak_planks"] = "block_wood",
    ["minecraft:cobblestone"] = "block_cobblestone",
    ["minecraft:glass"] = "block_glass",
    ["minecraft:bricks"] = "block_bricks",
    ["minecraft:sand"] = "block_sand",
    ["minecraft:bedrock"] = "block_bedrock",
}

local function is_power_of_two(value)
    value = math.floor(tonumber(value) or 0)
    return value > 0 and (value & (value - 1)) == 0
end

local function load_textures()
    if loaded then return end
    loaded = true
    if type(get_texture_info) ~= "function" then return end

    for key, relative_path in pairs(texture_paths) do
        local uri = Assets.get_uri(relative_path)
        if uri ~= nil then
            local ok, info = pcall(get_texture_info, uri)
            if ok and type(info) == "table" and info.texture ~= nil
                and is_power_of_two(info.width) and is_power_of_two(info.height) then
                textures[key] = info
            elseif ok and type(info) == "table" then
                -- DJUI's HUD texture renderer rejects non-power-of-two images.
                -- Use the pixel HUD fallback instead of raising a script error.
                print("[SteveCraft] HUD sprite skipped (non-power-of-two): " .. relative_path)
            end
        end
    end
end

local function render_texture(texture, x, y, scale_x, scale_y)
    if texture == nil or type(djui_hud_render_texture) ~= "function" then return false end
    local ok = pcall(
        djui_hud_render_texture,
        texture, x, y,
        scale_x or 1, scale_y or scale_x or 1
    )
    return ok
end

local function render_tile(tile_name, x, y, scale)
    local texture = textures[tile_name]
    if texture == nil then return false end
    local width = math.max(1, tonumber(texture.width) or 16)
    local height = math.max(1, tonumber(texture.height) or 16)
    local target_size = 16 * (scale or 1)
    return render_texture(texture, x, y, target_size / width, target_size / height)
end

local function render_block_icon(tile_name, x, y, scale)
    local texture = textures[tile_name]
    if texture == nil then return false end
    local width = math.max(1, tonumber(texture.width) or 32)
    local height = math.max(1, tonumber(texture.height) or 32)
    local target_size = 20 * (scale or 1)
    return render_texture(texture, x, y, target_size / width, target_size / height)
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
        if not render_tile("crosshair", screen_width * 0.5 - 8, screen_height * 0.5 - 8, 1) then
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

    local hotbar_scale = math.max(0.90, math.min(1.20, (screen_width - 18) / 232))
    local hotbar_x = (screen_width - 184 * hotbar_scale) * 0.5
    local hotbar_y = screen_height - 27 * hotbar_scale - 10
    -- Procedural pixel bar: unlike the original 182x22 PNG, all HUD geometry
    -- is independent of MPOT textures and cannot trigger DJUI's texture error.
    rect(hotbar_x, hotbar_y, 184 * hotbar_scale, 27 * hotbar_scale, 5, 5, 5, 245)
    rect(hotbar_x + 2 * hotbar_scale, hotbar_y + 2 * hotbar_scale,
        180 * hotbar_scale, 23 * hotbar_scale, 90, 90, 90, 255)
    rect(hotbar_x + 3 * hotbar_scale, hotbar_y + 3 * hotbar_scale,
        178 * hotbar_scale, 21 * hotbar_scale, 35, 35, 35, 255)

    for slot = 1, 9 do
        local slot_x = hotbar_x + (2 + (slot - 1) * 20) * hotbar_scale
        local slot_y = hotbar_y + 5 * hotbar_scale
        if slot == selected_slot then
            rect(slot_x - 1 * hotbar_scale, slot_y - 1 * hotbar_scale,
                20 * hotbar_scale, 20 * hotbar_scale, 245, 225, 170, 255)
            rect(slot_x + 1 * hotbar_scale, slot_y + 1 * hotbar_scale,
                16 * hotbar_scale, 16 * hotbar_scale, 25, 25, 25, 255)
        else
            rect(slot_x, slot_y, 18 * hotbar_scale, 18 * hotbar_scale, 18, 18, 18, 255)
        end

        local item = inventory[slot]
        if item and item.id then
            local icon = block_tiles[item.id]
            -- Dedicated 32x32 isometric icon, generated from this block's
            -- official top/side textures and bundled inside the mod.
            local icon_x = slot_x - 1 * hotbar_scale
            local icon_y = slot_y - 1 * hotbar_scale
            if not render_block_icon(icon, icon_x, icon_y, hotbar_scale) then
                rect(icon_x + 3 * hotbar_scale, icon_y + 3 * hotbar_scale,
                    14 * hotbar_scale, 14 * hotbar_scale, 130, 130, 130, 255)
            end
            text(item.count or 0, slot_x + 12 * hotbar_scale, slot_y + 13 * hotbar_scale, 0.46 * hotbar_scale)
        end
    end

    local selected = inventory[selected_slot]
    if selected and selected.id and context.catalog and context.catalog[selected.id] then
        local name = context.catalog[selected.id].name or selected.id
        text(name .. "  Y " .. tostring(context.height_offset or 0),
            math.max(4, (screen_width - #name * 5.5) * 0.5),
            hotbar_y - 15, 0.62)
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
    textures = {}
    loaded = false
end

return HUD
