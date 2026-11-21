-- SteveCraft block registry and single-owner object spawning.
-- Block world state and persistence are managed by main.lua; this module owns
-- definitions, block icon loading, and idempotent local-object creation.

local Blocks = {}

Blocks.catalog = {
    ["minecraft:stone"] = {
        name = "Stone", short = "ST", index = 1,
        destroy_speed = 1.5, explosion_resistance = 6.0, friction = 0.6,
        texture = "blocks/stone",
        break_sound = "stone", step_sound = "stone", place_sound = "stone",
        collision = "full_cube",
    },
    ["minecraft:dirt"] = {
        name = "Dirt", short = "DI", index = 2,
        destroy_speed = 0.5, explosion_resistance = 0.5, friction = 0.6,
        texture = "blocks/dirt",
        break_sound = "dirt", step_sound = "dirt", place_sound = "dirt",
        collision = "full_cube",
    },
    ["minecraft:grass_block"] = {
        name = "Grass Block", short = "GR", index = 3,
        destroy_speed = 0.6, explosion_resistance = 0.6, friction = 0.6,
        texture = "blocks/grass_top",
        side_texture = "blocks/grass_side",
        break_sound = "grass", step_sound = "grass", place_sound = "grass",
        collision = "full_cube",
    },
    ["minecraft:oak_planks"] = {
        name = "Oak Planks", short = "OP", index = 4,
        destroy_speed = 2.0, explosion_resistance = 3.0, friction = 0.6,
        texture = "blocks/oak_planks",
        break_sound = "wood", step_sound = "wood", place_sound = "wood",
        collision = "full_cube",
    },
    ["minecraft:cobblestone"] = {
        name = "Cobblestone", short = "CO", index = 5,
        destroy_speed = 2.0, explosion_resistance = 6.0, friction = 0.6,
        texture = "blocks/cobblestone",
        break_sound = "stone", step_sound = "stone", place_sound = "stone",
        collision = "full_cube",
    },
    ["minecraft:glass"] = {
        name = "Glass", short = "GL", index = 6,
        destroy_speed = 0.3, explosion_resistance = 0.3, friction = 0.6,
        texture = "blocks/glass",
        break_sound = "stone", step_sound = "glass", place_sound = "stone",
        collision = "full_cube",
    },
    ["minecraft:bricks"] = {
        name = "Bricks", short = "BR", index = 7,
        destroy_speed = 2.0, explosion_resistance = 6.0, friction = 0.6,
        texture = "blocks/bricks",
        break_sound = "stone", step_sound = "stone", place_sound = "stone",
        collision = "full_cube",
    },
    ["minecraft:sand"] = {
        name = "Sand", short = "SA", index = 8,
        destroy_speed = 0.5, explosion_resistance = 0.5, friction = 0.6,
        texture = "blocks/sand",
        break_sound = "dirt", step_sound = "sand", place_sound = "dirt",
        collision = "full_cube",
    },
    ["minecraft:bedrock"] = {
        name = "Bedrock", short = "BE", index = 9,
        destroy_speed = -1.0, explosion_resistance = 3600000.0, friction = 0.6,
        texture = "blocks/bedrock",
        break_sound = "stone", step_sound = "stone", place_sound = "stone",
        collision = "full_cube",
    },
}

local index_to_id = {}
for block_id, definition in pairs(Blocks.catalog) do
    index_to_id[definition.index] = block_id
end

function Blocks.get_id_from_index(index)
    return index_to_id[index]
end

Blocks.texture_tiles = {
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

Blocks.default_hotbar = {
    "minecraft:stone",
    "minecraft:dirt",
    "minecraft:grass_block",
    "minecraft:oak_planks",
    "minecraft:cobblestone",
    "minecraft:glass",
    "minecraft:bricks",
    "minecraft:sand",
    "minecraft:bedrock",
}

-- Each placed block is local because the saved voxel grid is local Mod Storage.
-- Do not also call spawn_sync_object: SM64CoopDX may reject sync spawning until
-- area synchronization is ready, and mixing sync + local spawn routes makes
-- ownership and duplicate diagnosis unnecessarily fragile.
local spawned = {}
local texture_cache = {}

local function is_live(object)
    return object ~= nil
        and (type(ACTIVE_FLAG_DEACTIVATED) ~= "number"
            or object.activeFlags ~= ACTIVE_FLAG_DEACTIVATED)
end

function Blocks.spawn_once(world_cell_key, behavior_id, model_id, x, y, z, initialize)
    if type(world_cell_key) ~= "string" or world_cell_key == "" then
        return nil, "invalid_cell_key"
    end

    local existing = spawned[world_cell_key]
    if is_live(existing) then
        return existing, "already_spawned"
    end
    spawned[world_cell_key] = nil

    if type(spawn_non_sync_object) ~= "function" then
        return nil, "non_sync_spawn_unavailable"
    end

    local ok, object = pcall(
        spawn_non_sync_object,
        behavior_id,
        model_id,
        x, y, z,
        initialize
    )
    if not ok or object == nil then
        return nil, ok and "spawn_returned_nil" or tostring(object)
    end

    spawned[world_cell_key] = object
    return object, "created"
end

function Blocks.forget(world_cell_key, object)
    local current = spawned[world_cell_key]
    if current ~= nil and (object == nil or current == object) then
        spawned[world_cell_key] = nil
        return true
    end
    return false
end

function Blocks.clear_spawned()
    for key, object in pairs(spawned) do
        if object ~= nil and type(ACTIVE_FLAG_DEACTIVATED) == "number" then
            pcall(function()
                object.activeFlags = ACTIVE_FLAG_DEACTIVATED
            end)
        end
        spawned[key] = nil
    end
end

function Blocks.get_texture(block_id)
    local definition = Blocks.catalog[block_id]
    if not definition or type(definition.texture) ~= "string" then
        return nil
    end
    local name = definition.texture
    if texture_cache[name] ~= nil then return texture_cache[name] end
    if type(get_texture_info) ~= "function" then return nil end
    local ok, texture = pcall(get_texture_info, name)
    if ok and texture ~= nil then
        texture_cache[name] = texture
        return texture
    end
    return nil
end

function Blocks.get_footstep_material(block_id)
    local id = type(block_id) == "string" and block_id:lower() or ""
    if id:find("glass", 1, true) then return "glass" end
    if id:find("sand", 1, true) then return "sand" end
    if id:find("grass", 1, true) then return "grass" end
    if id:find("dirt", 1, true) or id:find("gravel", 1, true) then return "dirt" end
    if id:find("wood", 1, true) or id:find("planks", 1, true)
        or id:find("log", 1, true) then return "wood" end
    return "stone"
end

return Blocks
