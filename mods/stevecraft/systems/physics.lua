-- SteveCraft physics adapter. Native SM64 movement remains the fallback until
-- every Minecraft movement action has a verified SM64 state mapping.
local M = {}

function M.resolve_friction(block_id, catalog, default_value)
    local block = catalog and catalog[block_id] or nil
    local friction = block and block.friction or default_value or 0.6
    if type(friction) ~= "number" then return 0.6 end
    return math.max(0, math.min(1, friction))
end

function M.ground_drag(friction)
    friction = tonumber(friction) or 0.6
    -- Minecraft Java's ground movement scales horizontal velocity by the
    -- block friction factor and the vanilla 0.91 air/ground coefficient.
    return math.max(0, math.min(1, friction * 0.91))
end

function M.is_grounded(m)
    if m == nil then return false end
    if type(m.floorHeight) == "number" and type(m.pos) == "table" and type(m.pos.y) == "number" then
        return m.pos.y <= m.floorHeight + 4
    end
    return m.floor ~= nil
end

function M.status()
    return {
        native_mario_actions_preserved = true,
        java_ground_drag = true,
        full_java_player_physics = false,
    }
end

return M
