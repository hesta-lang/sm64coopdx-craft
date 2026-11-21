-- Minecraft Java HUD renderer. The actual PNG sprite artwork is extracted from
-- the official version's asset index into the packaged assets/ directory.
local M = {}

function M.layout(width, height)
    width = tonumber(width) or 320
    height = tonumber(height) or 180
    local scale = math.min(width / 320, height / 180)
    local left = (width - 320 * scale) * 0.5
    local top = (height - 180 * scale) * 0.5
    local hotbar_x = left + 69 * scale
    local hotbar_y = top + 158 * scale
    return {
        scale = scale, origin_x = left, origin_y = top,
        hotbar = { x = hotbar_x, y = hotbar_y, w = 182 * scale, h = 22 * scale },
        selected = { x = hotbar_x + 1 * scale, y = hotbar_y - 1 * scale, w = 24 * scale, h = 24 * scale },
        offhand_left = { x = hotbar_x - 24 * scale, y = hotbar_y, w = 22 * scale, h = 22 * scale },
        offhand_right = { x = hotbar_x + 184 * scale, y = hotbar_y, w = 22 * scale, h = 22 * scale },
        hearts = { x = left + 9 * scale, y = top + 135 * scale, count = 10, step = 8 * scale },
        armor = { x = left + 9 * scale, y = top + 125 * scale, count = 10, step = 8 * scale },
        hunger = { x = left + 231 * scale, y = top + 135 * scale, count = 10, step = 8 * scale },
        experience = { x = left + 65 * scale, y = top + 151 * scale, w = 190 * scale, h = 5 * scale },
        crosshair = { x = left + 152.5 * scale, y = top + 82.5 * scale, w = 15 * scale, h = 15 * scale },
    }
end

function M.health_units(health, min_health, max_health)
    min_health = min_health or 0x00FF
    max_health = max_health or 0x0880
    local fraction = ((tonumber(health) or min_health) - min_health) / (max_health - min_health)
    fraction = math.max(0, math.min(1, fraction))
    return math.max(0, math.min(20, math.floor(fraction * 20 + 0.5)))
end

local function render_texture(texture, x, y, width, height)
    if texture == nil or type(djui_hud_render_texture) ~= "function" then return false end
    local ok = pcall(djui_hud_render_texture, texture, x, y, width, height)
    return ok
end

local function choose_bar_sprite(textures, prefix, value, index)
    local amount = math.max(0, math.min(20, tonumber(value) or 0))
    local units = amount - (index * 2)
    if units >= 2 then return textures[prefix .. "_full"] end
    if units == 1 then return textures[prefix .. "_half"] end
    return textures[prefix .. "_empty"]
end

function M.render(context)
    context = context or {}
    local textures = context.textures or {}
    if type(djui_hud_get_screen_width) ~= "function"
        or type(djui_hud_get_screen_height) ~= "function" then
        return false
    end
    local width = djui_hud_get_screen_width()
    local height = djui_hud_get_screen_height()
    local layout = M.layout(width, height)
    if type(djui_hud_set_resolution) == "function" and RESOLUTION_DJUI ~= nil then
        djui_hud_set_resolution(RESOLUTION_DJUI)
    end
    if type(djui_hud_set_color) == "function" then
        djui_hud_set_color(255, 255, 255, 255)
    end

    render_texture(textures.hotbar, layout.hotbar.x, layout.hotbar.y, layout.hotbar.w, layout.hotbar.h)
    render_texture(textures.hotbar_selection, layout.selected.x + (math.max(1, math.min(9, context.selected_slot or 1)) - 1) * 20 * layout.scale, layout.selected.y, layout.selected.w, layout.selected.h)

    render_texture(textures.hotbar_offhand_left, layout.offhand_left.x, layout.offhand_left.y, layout.offhand_left.w, layout.offhand_left.h)
    render_texture(textures.hotbar_offhand_right, layout.offhand_right.x, layout.offhand_right.y, layout.offhand_right.w, layout.offhand_right.h)
    if textures.experience_background ~= nil then
        render_texture(textures.experience_background, layout.experience.x, layout.experience.y, layout.experience.w, layout.experience.h)
        local progress = math.max(0, math.min(1, tonumber(context.experience_progress) or 0))
        if progress > 0 then
            render_texture(textures.experience_progress, layout.experience.x, layout.experience.y, layout.experience.w * progress, layout.experience.h)
        end
    end

    for index = 0, 9 do
        local x = layout.hearts.x + index * layout.hearts.step
        local armor_x = layout.armor.x + index * layout.armor.step
        local hunger_x = layout.hunger.x + index * layout.hunger.step
        render_texture(choose_bar_sprite(textures, "heart", context.health_units or 20, index), x, layout.hearts.y, 9 * layout.scale, 9 * layout.scale)
        if context.armor_units ~= nil then
            render_texture(choose_bar_sprite(textures, "armor", context.armor_units, index), armor_x, layout.armor.y, 9 * layout.scale, 9 * layout.scale)
        end
        if context.hunger_units ~= nil then
            render_texture(choose_bar_sprite(textures, "food", context.hunger_units, index), hunger_x, layout.hunger.y, 9 * layout.scale, 9 * layout.scale)
        end
    end

    local slots = context.slots or {}
    for index = 1, 9 do
        local slot = slots[index]
        local texture = slot and slot.texture or nil
        local x = layout.hotbar.x + (2 + ((index - 1) * 20)) * layout.scale
        local y = layout.hotbar.y + 3 * layout.scale
        render_texture(texture, x, y, 16 * layout.scale, 16 * layout.scale)
        if slot and tonumber(slot.count) and slot.count > 1 and type(djui_hud_print_text) == "function" then
            local label = tostring(slot.count)
            pcall(djui_hud_print_text, label, x + 8 * layout.scale, y + 9 * layout.scale, 0.6 * layout.scale)
        end
    end

    if context.first_person then
        render_texture(textures.crosshair, layout.crosshair.x, layout.crosshair.y, layout.crosshair.w, layout.crosshair.h)
    end

    if context.selected_name and type(djui_hud_print_text) == "function" then
        pcall(djui_hud_print_text, context.selected_name, width * 0.5 - 35 * layout.scale, height - 62 * layout.scale, 0.65 * layout.scale)
    end

    if type(djui_hud_set_color) == "function" then
        djui_hud_set_color(255, 255, 255, 255)
    end
    return true
end

return M
