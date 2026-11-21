-- Minecraft Java HUD layout model. Coordinates are calculated in a 320x180
-- virtual canvas and scaled uniformly to the active DJUI resolution.
local M = {}

function M.layout(width, height)
    width = tonumber(width) or 320
    height = tonumber(height) or 180
    local scale = math.min(width / 320, height / 180)
    local left = (width - 320 * scale) * 0.5
    local top = (height - 180 * scale) * 0.5
    return {
        scale = scale,
        origin_x = left,
        origin_y = top,
        hotbar = { x = left + 115 * scale, y = top + 153 * scale, w = 182 * scale, h = 22 * scale },
        selected = { x = left + 114 * scale, y = top + 152 * scale, w = 24 * scale, h = 24 * scale },
        offhand = { x = left + 91 * scale, y = top + 153 * scale, w = 22 * scale, h = 22 * scale },
        hearts = { x = left + 9 * scale, y = top + 137 * scale, count = 10, step = 8 * scale },
        hunger = { x = left + 231 * scale, y = top + 137 * scale, count = 10, step = 8 * scale },
        armor = { x = left + 9 * scale, y = top + 127 * scale, count = 10, step = 8 * scale },
        experience = { x = left + 65 * scale, y = top + 149 * scale, w = 190 * scale, h = 5 * scale },
    }
end

function M.health_units(health, min_health, max_health)
    min_health = min_health or 0x00FF
    max_health = max_health or 0x0880
    local fraction = ((tonumber(health) or min_health) - min_health) / (max_health - min_health)
    return math.max(0, math.min(20, math.floor(fraction * 20 + 0.5)))
end

return M
