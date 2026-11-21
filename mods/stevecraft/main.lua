-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone model assignment following the verified DynOS/Lua loading path.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.3.0-alpha"
local STEVE_GEO_NAME = "mario_geo"

local sModelId = nil
local sModelLoadAttempted = false
local sModelAppliedObject = nil
local sWarned = false
local sVerifyWarned = false
local sLastSteveState = nil

local sAnimationsRegistered = false
local sCurrentSteveAnimation = nil
local STEVE_ANIMATION_FRAMES = 24
local STEVE_ANIMATION_PARTS = 20
local STEVE_ANIM_IDLE = "stevecraft_idle"
local STEVE_ANIM_WALK = "stevecraft_walk"

-- These zero-based channel indices follow MarioAnimPart in include/types.h.
-- The original mario_geo has exactly 20 GEO_ANIMATED_PART nodes in this traversal order.
local STEVE_PART = {
    TORSO = 2,
    HEAD = 3,
    LEFT_ARM = 5,
    LEFT_FOREARM = 6,
    RIGHT_ARM = 9,
    RIGHT_FOREARM = 10,
    LEFT_THIGH = 13,
    LEFT_LEG = 14,
    RIGHT_THIGH = 17,
    RIGHT_LEG = 18,
}

local function round_animation_value(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function steve_animation_value(kind, part, axis, frame)
    local phase = (frame / STEVE_ANIMATION_FRAMES) * (math.pi * 2)
    local wave = math.sin(phase)

    if kind == "idle" then
        if axis == 1 and part == STEVE_PART.TORSO then
            return round_animation_value(wave * 96) -- ~0.53 degrees
        end
        if axis == 1 and part == STEVE_PART.HEAD then
            return round_animation_value(wave * -32)
        end
        return 0
    end

    if kind == "walk" and axis == 1 then
        local swing = wave * 5461 -- ~30 degrees in SM64's 16-bit angle units
        if part == STEVE_PART.LEFT_ARM then return round_animation_value(swing) end
        if part == STEVE_PART.RIGHT_ARM then return round_animation_value(-swing) end
        if part == STEVE_PART.LEFT_THIGH then return round_animation_value(-swing) end
        if part == STEVE_PART.RIGHT_THIGH then return round_animation_value(swing) end

        -- Subtle elbow bend layered over the opposing Minecraft-style swing.
        if part == STEVE_PART.LEFT_FOREARM then
            return round_animation_value(math.max(0, wave) * 900)
        end
        if part == STEVE_PART.RIGHT_FOREARM then
            return round_animation_value(math.max(0, -wave) * 900)
        end
    end

    return 0
end

local function build_steve_animation(kind)
    local values = {}
    local index = {}

    -- ANIM_FLAG_6 (0x40) tells the renderer to skip the reserved root translation.
    -- The index format still requires three [frameCount, valueOffset] pairs here.
    for _ = 1, 3 do
        index[#index + 1] = STEVE_ANIMATION_FRAMES
        index[#index + 1] = 0
    end

    -- Each GEO_ANIMATED_PART consumes X/Y/Z rotation channels in traversal order.
    for part = 0, STEVE_ANIMATION_PARTS - 1 do
        for axis = 1, 3 do
            local valueOffset = #values
            index[#index + 1] = STEVE_ANIMATION_FRAMES
            index[#index + 1] = valueOffset

            for frame = 0, STEVE_ANIMATION_FRAMES - 1 do
                values[#values + 1] = steve_animation_value(kind, part, axis, frame)
            end
        end
    end

    return values, index
end

local function register_steve_animations()
    if sAnimationsRegistered then return true end
    if type(smlua_anim_util_register_animation) ~= "function" then
        print("[SteveCraft] WARNING: custom animation registration API unavailable.")
        return false
    end

    local definitions = {
        { kind = "idle", name = STEVE_ANIM_IDLE },
        { kind = "walk", name = STEVE_ANIM_WALK },
    }

    for _, definition in ipairs(definitions) do
        local values, index = build_steve_animation(definition.kind)
        local expectedIndexLength = 6 + (STEVE_ANIMATION_PARTS * 3 * 2)
        if #index ~= expectedIndexLength
            or #values ~= STEVE_ANIMATION_PARTS * 3 * STEVE_ANIMATION_FRAMES then
            print("[SteveCraft] ERROR: generated animation channel count is invalid for " .. definition.name)
            return false
        end

        local ok, err = pcall(
            smlua_anim_util_register_animation,
            definition.name,
            0x40, -- ANIM_FLAG_6: no root translation; rotate animated parts only
            0,    -- animYTransDivisor
            0,    -- startFrame
            0,    -- loopStart
            STEVE_ANIMATION_FRAMES,
            values,
            index
        )
        if not ok then
            print("[SteveCraft] ERROR: animation registration failed for " .. definition.name .. ": " .. tostring(err))
            return false
        end
        print("[SteveCraft] Registered " .. definition.name .. " (" .. #values .. " values, " .. #index .. " index entries).")
    end

    sAnimationsRegistered = true
    return true
end

local function apply_steve_animation(m, state)
    if not sAnimationsRegistered or m.marioObj == nil then return end
    if type(smlua_anim_util_set_animation) ~= "function" then return end

    local target = state == "move" and STEVE_ANIM_WALK or STEVE_ANIM_IDLE
    if target == sCurrentSteveAnimation then return end

    local ok, err = pcall(smlua_anim_util_set_animation, m.marioObj, target)
    if not ok then
        print("[SteveCraft] ERROR: unable to select " .. target .. ": " .. tostring(err))
        return
    end

    sCurrentSteveAnimation = target
    print("[SteveCraft] Animation selected: " .. target)
end

-- Bedrock-inspired animation-controller pattern: observe conditions and select a state.
-- It selects the formula-generated idle/walk animation without changing movement or collision.
local function get_steve_controller_state(m)
    local action = m.action or 0
    if (action & ACT_FLAG_SWIMMING) ~= 0 then
        return "swim"
    end
    if (action & ACT_FLAG_AIR) ~= 0 then
        local verticalSpeed = 0.0
        if m.vel ~= nil then
            verticalSpeed = m.vel.y or 0.0
        end
        if verticalSpeed > 0.0 then return "jump" end
        return "fall"
    end
    if (action & ACT_FLAG_MOVING) ~= 0 then
        return "move"
    end
    return "idle"
end

local function update_steve_controller(m)
    local state = get_steve_controller_state(m)
    if state ~= sLastSteveState then
        sLastSteveState = state
        print("[SteveCraft] Controller state: " .. state)
    end
    return state
end

-- The name passed to the API is a GeoLayout symbol, not the .bin filename.
local function load_steve_model()
    if sModelLoadAttempted then return sModelId end
    sModelLoadAttempted = true

    if type(smlua_model_util_get_id) ~= "function" then
        print("[SteveCraft] ERROR: smlua_model_util_get_id API unavailable.")
        return nil
    end

    local ok, modelId = pcall(smlua_model_util_get_id, STEVE_GEO_NAME)
    if not ok then
        print("[SteveCraft] ERROR: GeoLayout lookup raised an error: " .. tostring(modelId))
        return nil
    end

    if type(modelId) ~= "number" or modelId == E_MODEL_ERROR_MODEL then
        print('[SteveCraft] ERROR: DynOS could not resolve GeoLayout symbol "' .. STEVE_GEO_NAME .. '".')
        print("[SteveCraft] Check actor registration and the internal GeoLayout name in the .geo.bin.")
        return nil
    end

    sModelId = modelId
    print("[SteveCraft] GeoLayout resolved to extended model id=" .. tostring(modelId))
    return sModelId
end

-- Read-back verification uses the model-id mapping exposed by SM64CoopDX's C API.
local function get_current_extended_model_id(obj)
    if type(obj_get_model_id_extended) ~= "function" then
        if not sVerifyWarned then
            print("[SteveCraft] WARNING: obj_get_model_id_extended unavailable; assignment cannot be read back.")
            sVerifyWarned = true
        end
        return nil
    end

    local ok, currentId = pcall(obj_get_model_id_extended, obj)
    if not ok or type(currentId) ~= "number" then
        if not sVerifyWarned then
            print("[SteveCraft] WARNING: model read-back failed: " .. tostring(currentId))
            sVerifyWarned = true
        end
        return nil
    end
    return currentId
end

local function apply_steve_to_mario(m)
    if m == nil or m.playerIndex ~= 0 then return end
    local state = update_steve_controller(m)
    if m.marioObj == nil then return end

    local modelId = load_steve_model()
    if modelId == nil then return end
    if sModelAppliedObject == m.marioObj then
        apply_steve_animation(m, state)
        return
    end

    -- Calls the engine's native loader and assigns the model to the existing player object.
    local ok, result = pcall(obj_set_model_extended, m.marioObj, modelId)
    if not ok or result == false then
        if not sWarned then
            print("[SteveCraft] ERROR: obj_set_model_extended failed: " .. tostring(result))
            sWarned = true
        end
        return
    end

    -- The native setter returns void; verify its effect by querying the object's graph-node model.
    local currentId = get_current_extended_model_id(m.marioObj)
    if currentId ~= nil and currentId ~= modelId then
        if not sWarned then
            print("[SteveCraft] ERROR: model assignment did not persist. Expected extended id=" .. tostring(modelId) .. ", got=" .. tostring(currentId))
            sWarned = true
        end
        return
    end

    sModelAppliedObject = m.marioObj
    if register_steve_animations() then
        sCurrentSteveAnimation = nil
        apply_steve_animation(m, state)
    end
    if currentId == modelId then
        print("[SteveCraft] Steve model assigned and verified on the existing marioObj.")
    else
        print("[SteveCraft] Steve model assigned; read-back verification is unavailable on this build.")
    end
end


-- Minecraft Java 26.3 block catalogue. Values are from the validated runtime-registry artifact.
-- Friction is 0.6 for these blocks, so their SM64 collision uses SURFACE_DEFAULT.
local BLOCK_CATALOG = {
    ["minecraft:stone"] = {
        name = "Stone", short = "ST", index = 1,
        destroy_speed = 1.5, explosion_resistance = 6.0, friction = 0.6,
        break_sound = "minecraft:block.stone.break", step_sound = "minecraft:block.stone.step",
        place_sound = "minecraft:block.stone.place", collision = "full_cube",
    },
    ["minecraft:dirt"] = {
        name = "Dirt", short = "DI", index = 2,
        destroy_speed = 0.5, explosion_resistance = 0.5, friction = 0.6,
        break_sound = "minecraft:block.gravel.break", step_sound = "minecraft:block.gravel.step",
        place_sound = "minecraft:block.gravel.place", collision = "full_cube",
    },
    ["minecraft:grass_block"] = {
        name = "Grass", short = "GR", index = 3,
        destroy_speed = 0.6, explosion_resistance = 0.6, friction = 0.6,
        break_sound = "minecraft:block.grass.break", step_sound = "minecraft:block.grass.step",
        place_sound = "minecraft:block.grass.place", collision = "full_cube",
    },
    ["minecraft:oak_planks"] = {
        name = "Oak Planks", short = "OP", index = 4,
        destroy_speed = 2.0, explosion_resistance = 3.0, friction = 0.6,
        break_sound = "minecraft:block.wood.break", step_sound = "minecraft:block.wood.step",
        place_sound = "minecraft:block.wood.place", collision = "full_cube",
    },
    ["minecraft:cobblestone"] = {
        name = "Cobblestone", short = "CO", index = 5,
        destroy_speed = 2.0, explosion_resistance = 6.0, friction = 0.6,
        break_sound = "minecraft:block.stone.break", step_sound = "minecraft:block.stone.step",
        place_sound = "minecraft:block.stone.place", collision = "full_cube",
    },
    ["minecraft:glass"] = {
        name = "Glass", short = "GL", index = 6,
        destroy_speed = 0.3, explosion_resistance = 0.3, friction = 0.6,
        break_sound = "minecraft:block.glass.break", step_sound = "minecraft:block.glass.step",
        place_sound = "minecraft:block.glass.place", collision = "full_cube",
    },
    ["minecraft:bricks"] = {
        name = "Bricks", short = "BR", index = 7,
        destroy_speed = 2.0, explosion_resistance = 6.0, friction = 0.6,
        break_sound = "minecraft:block.stone.break", step_sound = "minecraft:block.stone.step",
        place_sound = "minecraft:block.stone.place", collision = "full_cube",
    },
    ["minecraft:sand"] = {
        name = "Sand", short = "SA", index = 8,
        destroy_speed = 0.5, explosion_resistance = 0.5, friction = 0.6,
        break_sound = "minecraft:block.sand.break", step_sound = "minecraft:block.sand.step",
        place_sound = "minecraft:block.sand.place", collision = "full_cube",
    },
    ["minecraft:bedrock"] = {
        name = "Bedrock", short = "BE", index = 9,
        destroy_speed = -1.0, explosion_resistance = 3600000.0, friction = 0.6,
        break_sound = "minecraft:block.stone.break", step_sound = "minecraft:block.stone.step",
        place_sound = "minecraft:block.stone.place", collision = "full_cube",
    },
}

local DEFAULT_HOTBAR = {
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

local GRID_CELL_SIZE = 90
local GRID_OBJECT_SCALE = 0.45
local GRID_MAX_BLOCKS_PER_AREA = 128
local GRID_STORAGE_CHUNK_SIZE = 800
local GRID_MAX_BUILD_HEIGHT_OFFSET = 8
local GRID_BUILD_DISTANCE = GRID_CELL_SIZE * 1.5
local INVENTORY_SIZE = 9
local INVENTORY_MAX_STACK = 64

local sGridBlockBehaviorId = nil
local sGridBehaviorInit = nil
local sGridBehaviorLoop = nil
local sCurrentWorldKey = nil
local sCurrentWorldPrefix = nil
local sCurrentSaveSlot = nil
local sWorldBlocks = {}
local sInventory = {}
local sInventoryLoaded = false
local sSelectedSlot = 1
local sBuildHeightOffset = 0
local sWarnedGridCollision = false
local sWarnedGridSpawn = false
local sWorldBlockCount = 0

local function copy_table(source)
    local result = {}
    for key, value in pairs(source or {}) do
        result[key] = value
    end
    return result
end

local function get_block_definition(block_id)
    return BLOCK_CATALOG[block_id]
end

local function cell_key(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function cell_center(x, y, z)
    return x * GRID_CELL_SIZE + GRID_CELL_SIZE * 0.5,
        y * GRID_CELL_SIZE + GRID_CELL_SIZE * 0.5,
        z * GRID_CELL_SIZE + GRID_CELL_SIZE * 0.5
end

local function compute_target_cell(position, yaw, height_offset)
    local angle = (yaw or 0) * math.pi / 32768
    local forward_x = math.sin(angle)
    local forward_z = math.cos(angle)
    local target_x = (position.x or 0) + forward_x * GRID_BUILD_DISTANCE
    local target_z = (position.z or 0) + forward_z * GRID_BUILD_DISTANCE
    local target_y = math.floor(((position.y or 0) + 1) / GRID_CELL_SIZE)
        + (height_offset or 0)
    return math.floor(target_x / GRID_CELL_SIZE), target_y, math.floor(target_z / GRID_CELL_SIZE)
end

local function count_world_blocks(blocks)
    local total = 0
    for _ in pairs(blocks or {}) do total = total + 1 end
    return total
end

local function get_current_save_slot()
    if type(get_current_save_file_num) == "function" then
        local ok, value = pcall(get_current_save_file_num)
        if ok and type(value) == "number" and value > 0 then
            return math.floor(value)
        end
    end
    return 1
end

local function get_world_context()
    local network_player = gNetworkPlayers and gNetworkPlayers[0] or nil
    local level = network_player and network_player.currLevelNum or gCurrLevelNum
    local area = network_player and network_player.currAreaIndex or gCurrAreaIndex
    local save_slot = get_current_save_slot()
    if type(level) ~= "number" or level <= 0 then return nil end
    if type(area) ~= "number" or area <= 0 then area = 1 end

    level = math.floor(level)
    area = math.floor(area)
    local world_id = tostring(save_slot) .. "_" .. tostring(level) .. "_" .. tostring(area)
    return world_id, "sc_world_" .. world_id .. "_", save_slot, level, area
end

local function safe_storage_load(key, default_value)
    if type(mod_storage_load) ~= "function" then return default_value end
    local ok, value = pcall(mod_storage_load, key, default_value)
    if not ok or value == nil then return default_value end
    return value
end

local function safe_storage_save(key, value)
    if type(mod_storage_save) ~= "function" then return true end
    local ok, result = pcall(mod_storage_save, key, tostring(value))
    return ok and result ~= false
end

local function safe_storage_remove(key)
    if type(mod_storage_remove) ~= "function" then return true end
    local ok, result = pcall(mod_storage_remove, key)
    return ok and result ~= false
end

local function safe_storage_load_all()
    if type(mod_storage_load_all) ~= "function" then return {} end
    local ok, result = pcall(mod_storage_load_all)
    if not ok or type(result) ~= "table" then return {} end
    return result
end

local function inventory_id_key(save_slot, slot)
    return "sc_inventory_" .. tostring(save_slot) .. "_slot_" .. tostring(slot) .. "_id"
end

local function inventory_count_key(save_slot, slot)
    return "sc_inventory_" .. tostring(save_slot) .. "_slot_" .. tostring(slot) .. "_count"
end

local function inventory_selected_key(save_slot)
    return "sc_inventory_" .. tostring(save_slot) .. "_selected"
end

local function save_inventory()
    if not sInventoryLoaded then return false end
    local save_slot = sCurrentSaveSlot or get_current_save_slot()
    local ok = true
    for slot = 1, INVENTORY_SIZE do
        local entry = sInventory[slot]
        if entry then
            ok = safe_storage_save(inventory_id_key(save_slot, slot), entry.id) and ok
            ok = safe_storage_save(inventory_count_key(save_slot, slot), entry.count) and ok
        end
    end
    ok = safe_storage_save(inventory_selected_key(save_slot), sSelectedSlot) and ok
    return ok
end

local function load_inventory()
    local save_slot = get_current_save_slot()
    sCurrentSaveSlot = save_slot
    sInventory = {}

    for slot = 1, INVENTORY_SIZE do
        local default_id = DEFAULT_HOTBAR[slot]
        local saved_id = safe_storage_load(inventory_id_key(save_slot, slot), default_id)
        if not BLOCK_CATALOG[saved_id] then saved_id = default_id end
        local saved_count = tonumber(safe_storage_load(inventory_count_key(save_slot, slot), "64")) or 64
        saved_count = math.max(0, math.min(INVENTORY_MAX_STACK, math.floor(saved_count)))
        sInventory[slot] = { id = saved_id, count = saved_count }
    end

    local selected = tonumber(safe_storage_load(inventory_selected_key(save_slot), "1")) or 1
    sSelectedSlot = math.max(1, math.min(INVENTORY_SIZE, math.floor(selected)))
    sInventoryLoaded = true
end

local function ensure_inventory_loaded()
    local save_slot = get_current_save_slot()
    if not sInventoryLoaded or sCurrentSaveSlot ~= save_slot then
        load_inventory()
    end
end

local function inventory_consume_selected()
    ensure_inventory_loaded()
    local entry = sInventory[sSelectedSlot]
    if not entry or entry.count <= 0 or not BLOCK_CATALOG[entry.id] then return nil end
    entry.count = entry.count - 1
    save_inventory()
    return entry.id
end

local function inventory_can_add_block(block_id, amount)
    ensure_inventory_loaded()
    amount = amount or 1
    if not BLOCK_CATALOG[block_id] or amount <= 0 then return false end
    local available = 0
    for slot = 1, INVENTORY_SIZE do
        local entry = sInventory[slot]
        if entry and entry.id == block_id then
            available = available + (INVENTORY_MAX_STACK - entry.count)
        elseif entry and entry.count == 0 then
            available = available + INVENTORY_MAX_STACK
        end
        if available >= amount then return true end
    end
    return false
end

local function inventory_add_block(block_id, amount)
    ensure_inventory_loaded()
    amount = amount or 1
    if not inventory_can_add_block(block_id, amount) then return false end

    for slot = 1, INVENTORY_SIZE do
        local entry = sInventory[slot]
        if entry and entry.id == block_id and entry.count < INVENTORY_MAX_STACK then
            local added = math.min(amount, INVENTORY_MAX_STACK - entry.count)
            entry.count = entry.count + added
            amount = amount - added
            if amount <= 0 then save_inventory(); return true end
        end
    end

    for slot = 1, INVENTORY_SIZE do
        local entry = sInventory[slot]
        if entry and entry.count == 0 then
            entry.id = block_id
            local added = math.min(amount, INVENTORY_MAX_STACK)
            entry.count = added
            amount = amount - added
            if amount <= 0 then save_inventory(); return true end
        end
    end

    save_inventory()
    return amount == 0
end

local function select_inventory_slot(slot)
    ensure_inventory_loaded()
    while slot < 1 do slot = slot + INVENTORY_SIZE end
    while slot > INVENTORY_SIZE do slot = slot - INVENTORY_SIZE end
    sSelectedSlot = slot
    save_inventory()
    return sSelectedSlot
end

local function grid_block_init(obj)
    obj.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    local collision = gGlobalObjectCollisionData
        and gGlobalObjectCollisionData.breakable_box_seg8_collision_08012D70
    if collision then
        obj.collisionData = collision
    elseif not sWarnedGridCollision then
        print("[SteveCraft] WARNING: breakable-box collision data is unavailable; blocks will be visual only.")
        sWarnedGridCollision = true
    end

    obj.oCollisionDistance = GRID_CELL_SIZE * 20
    obj.oDrawingDistance = GRID_CELL_SIZE * 24
    obj.oOpacity = 255
    if type(obj_scale) == "function" then
        obj_scale(obj, GRID_OBJECT_SCALE)
    end
end

local function grid_block_loop(obj)
    if obj.collisionData ~= nil and type(load_object_collision_model) == "function" then
        load_object_collision_model()
    end
end

sGridBehaviorInit = grid_block_init
sGridBehaviorLoop = grid_block_loop
if type(hook_behavior) == "function" then
    local ok, behavior_id = pcall(
        hook_behavior,
        nil,
        OBJ_LIST_SURFACE,
        true,
        grid_block_init,
        grid_block_loop
    )
    if ok then
        sGridBlockBehaviorId = behavior_id
    else
        print("[SteveCraft] ERROR: unable to register grid block collision behavior: " .. tostring(behavior_id))
    end
end

local function spawn_grid_block(block_id, x, y, z)
    if not sGridBlockBehaviorId or type(E_MODEL_BREAKABLE_BOX) ~= "number" then
        if not sWarnedGridSpawn then
            print("[SteveCraft] ERROR: block behavior or vanilla cube model is unavailable.")
            sWarnedGridSpawn = true
        end
        return nil
    end

    local definition = BLOCK_CATALOG[block_id]
    if not definition then return nil end
    local world_x, world_y, world_z = cell_center(x, y, z)
    local function initialize(obj)
        obj.oBehParams2ndByte = definition.index
        obj.oAnimState = 0
    end

    local object = nil
    if type(spawn_sync_object) == "function" then
        local ok, result = pcall(
            spawn_sync_object,
            sGridBlockBehaviorId,
            E_MODEL_BREAKABLE_BOX,
            world_x, world_y, world_z,
            initialize
        )
        if ok then object = result end
    end
    if object == nil and type(spawn_non_sync_object) == "function" then
        local ok, result = pcall(
            spawn_non_sync_object,
            sGridBlockBehaviorId,
            E_MODEL_BREAKABLE_BOX,
            world_x, world_y, world_z,
            initialize
        )
        if ok then object = result end
    end

    if object == nil and not sWarnedGridSpawn then
        print("[SteveCraft] ERROR: SM64CoopDX could not spawn a grid block object.")
        sWarnedGridSpawn = true
    end
    return object
end

local function world_chunk_prefix(world_prefix)
    return world_prefix .. "chunk_"
end

local function save_world_grid()
    if not sCurrentWorldPrefix then return false end
    if type(mod_storage_save) ~= "function" then return true end

    local records = {}
    for _, cell in pairs(sWorldBlocks) do
        records[#records + 1] = string.format(
            "%d,%d,%d,%s", cell.x, cell.y, cell.z, cell.id
        )
    end
    table.sort(records)

    local chunks = {}
    local current = {}
    local current_length = 0
    for _, record in ipairs(records) do
        local extra = #record + (#current > 0 and 1 or 0)
        if current_length + extra > GRID_STORAGE_CHUNK_SIZE and #current > 0 then
            chunks[#chunks + 1] = table.concat(current, ";")
            current = {}
            current_length = 0
            extra = #record
        end
        current[#current + 1] = record
        current_length = current_length + extra
    end
    if #current > 0 then chunks[#chunks + 1] = table.concat(current, ";") end

    local prefix = world_chunk_prefix(sCurrentWorldPrefix)
    local save_ok = true
    for index, chunk in ipairs(chunks) do
        save_ok = safe_storage_save(prefix .. tostring(index), chunk) and save_ok
    end

    local all = safe_storage_load_all()
    for key in pairs(all) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then
            local old_index = tonumber(key:sub(#prefix + 1))
            if old_index and old_index > #chunks then
                safe_storage_remove(key)
            end
        end
    end
    return save_ok
end

local function deactivate_world_objects()
    for _, cell in pairs(sWorldBlocks) do
        local object = cell.object
        if object and type(ACTIVE_FLAG_DEACTIVATED) == "number" then
            pcall(function() object.activeFlags = ACTIVE_FLAG_DEACTIVATED end)
        end
    end
end

local function load_world_grid(world_prefix)
    sWorldBlocks = {}
    sWorldBlockCount = 0
    local prefix = world_chunk_prefix(world_prefix)
    local all = safe_storage_load_all()
    local chunks = {}

    for key, value in pairs(all) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then
            local index = tonumber(key:sub(#prefix + 1))
            if index and type(value) == "string" then
                chunks[#chunks + 1] = { index = index, value = value }
            end
        end
    end
    table.sort(chunks, function(a, b) return a.index < b.index end)

    for _, chunk in ipairs(chunks) do
        for record in chunk.value:gmatch("[^;]+") do
            local x, y, z, block_id = record:match("^(-?%d+),(-?%d+),(-?%d+),([%w_:%.%-]+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x and y and z and BLOCK_CATALOG[block_id] and sWorldBlockCount < GRID_MAX_BLOCKS_PER_AREA then
                local key = cell_key(x, y, z)
                if not sWorldBlocks[key] then
                    local object = spawn_grid_block(block_id, x, y, z)
                    sWorldBlocks[key] = {
                        id = block_id, x = x, y = y, z = z, object = object
                    }
                    sWorldBlockCount = sWorldBlockCount + 1
                end
            end
        end
    end
end

local function ensure_world_loaded()
    ensure_inventory_loaded()
    local world_key, world_prefix = get_world_context()
    if not world_key then return false end
    if sCurrentWorldKey == world_key then return true end

    if sCurrentWorldKey ~= nil then
        deactivate_world_objects()
    end
    sCurrentWorldKey = world_key
    sCurrentWorldPrefix = world_prefix
    sBuildHeightOffset = 0
    load_world_grid(world_prefix)
    print("[SteveCraft] Loaded invisible build grid for level/area " .. world_key .. " (" .. sWorldBlockCount .. " blocks).")
    return true
end

local function place_grid_block(x, y, z)
    if not ensure_world_loaded() then return false, "world_not_ready" end
    local key = cell_key(x, y, z)
    if sWorldBlocks[key] then return false, "occupied" end
    if sWorldBlockCount >= GRID_MAX_BLOCKS_PER_AREA then return false, "grid_full" end

    local selected = sInventory[sSelectedSlot]
    if not selected or selected.count <= 0 or not BLOCK_CATALOG[selected.id] then
        return false, "inventory_empty"
    end

    local block_id = selected.id
    local object = spawn_grid_block(block_id, x, y, z)
    if object == nil then return false, "spawn_failed" end

    sWorldBlocks[key] = { id = block_id, x = x, y = y, z = z, object = object }
    sWorldBlockCount = sWorldBlockCount + 1
    selected.count = selected.count - 1
    save_inventory()
    save_world_grid()
    return true
end

local function remove_grid_block(x, y, z)
    if not ensure_world_loaded() then return false, "world_not_ready" end
    local key = cell_key(x, y, z)
    local cell = sWorldBlocks[key]
    if not cell then return false, "empty" end

    local definition = BLOCK_CATALOG[cell.id]
    if not definition or definition.destroy_speed < 0 then
        return false, "unbreakable"
    end
    if not inventory_can_add_block(cell.id, 1) then
        return false, "inventory_full"
    end

    if cell.object and type(ACTIVE_FLAG_DEACTIVATED) == "number" then
        pcall(function() cell.object.activeFlags = ACTIVE_FLAG_DEACTIVATED end)
    end
    sWorldBlocks[key] = nil
    sWorldBlockCount = math.max(0, sWorldBlockCount - 1)
    inventory_add_block(cell.id, 1)
    save_inventory()
    save_world_grid()
    return true
end

local function get_build_target(m)
    if not m or not m.pos then return nil end
    local yaw = 0
    if m.faceAngle and type(m.faceAngle.y) == "number" then
        yaw = m.faceAngle.y
    elseif m.marioObj and type(m.marioObj.oMoveAngleYaw) == "number" then
        yaw = m.marioObj.oMoveAngleYaw
    end
    return compute_target_cell(m.pos, yaw, sBuildHeightOffset)
end

local function consume_build_controls(m)
    if not m or m.playerIndex ~= 0 or not m.controller then return end
    ensure_world_loaded()

    local controller = m.controller
    local down = controller.buttonDown or 0
    local pressed = controller.buttonPressed or 0
    if (down & L_TRIG) == 0 then return end

    local consumed = 0
    if (pressed & L_JPAD) ~= 0 then
        select_inventory_slot(sSelectedSlot - 1)
        consumed = consumed | L_JPAD
    end
    if (pressed & R_JPAD) ~= 0 then
        select_inventory_slot(sSelectedSlot + 1)
        consumed = consumed | R_JPAD
    end
    if (pressed & U_JPAD) ~= 0 then
        sBuildHeightOffset = math.min(GRID_MAX_BUILD_HEIGHT_OFFSET, sBuildHeightOffset + 1)
        consumed = consumed | U_JPAD
    end
    if (pressed & D_JPAD) ~= 0 then
        sBuildHeightOffset = math.max(-GRID_MAX_BUILD_HEIGHT_OFFSET, sBuildHeightOffset - 1)
        consumed = consumed | D_JPAD
    end

    if (pressed & A_BUTTON) ~= 0 then
        local x, y, z = get_build_target(m)
        if x then
            local placed, reason = place_grid_block(x, y, z)
            if not placed then
                print("[SteveCraft] Cannot place block: " .. tostring(reason))
            end
        end
        consumed = consumed | A_BUTTON
    end
    if (pressed & B_BUTTON) ~= 0 then
        local x, y, z = get_build_target(m)
        if x then
            local removed, reason = remove_grid_block(x, y, z)
            if not removed and reason ~= "empty" then
                print("[SteveCraft] Cannot remove block: " .. tostring(reason))
            end
        end
        consumed = consumed | B_BUTTON
    end

    if consumed ~= 0 then
        controller.buttonPressed = pressed & (~consumed)
        controller.buttonReleased = (controller.buttonReleased or 0) & (~consumed)
        controller.buttonDown = down & (~consumed)
    end
end

local function render_build_inventory()
    if not sInventoryLoaded or type(djui_hud_print_text) ~= "function" then return end
    if type(djui_hud_set_resolution) == "function" and type(RESOLUTION_N64) == "number" then
        djui_hud_set_resolution(RESOLUTION_N64)
    end
    if type(djui_hud_set_font) == "function" and type(FONT_NORMAL) == "number" then
        djui_hud_set_font(FONT_NORMAL)
    end

    local parts = {}
    for slot = 1, INVENTORY_SIZE do
        local item = sInventory[slot]
        local definition = item and BLOCK_CATALOG[item.id] or nil
        local label = definition and definition.short or "--"
        local count = item and item.count or 0
        if slot == sSelectedSlot then
            parts[#parts + 1] = ">" .. label .. ":" .. tostring(count) .. "<"
        else
            parts[#parts + 1] = label .. ":" .. tostring(count)
        end
    end

    local line = table.concat(parts, "  ")
    local scale = 0.28
    local width = type(djui_hud_measure_text) == "function" and djui_hud_measure_text(line) * scale or #line * 3
    local x = math.max(2, (320 - width) * 0.5)

    if type(djui_hud_set_color) == "function" then
        djui_hud_set_color(255, 255, 255, 230)
    end
    djui_hud_print_text(line, x, 211, scale)

    local selected = sInventory[sSelectedSlot]
    local definition = selected and BLOCK_CATALOG[selected.id] or nil
    local selected_text = definition and (definition.name .. "  Layer " .. tostring(sBuildHeightOffset)) or "No block selected"
    if type(djui_hud_set_color) == "function" then
        djui_hud_set_color(255, 220, 90, 230)
    end
    local selected_width = type(djui_hud_measure_text) == "function" and djui_hud_measure_text(selected_text) * 0.28 or #selected_text * 3
    djui_hud_print_text(selected_text, math.max(2, (320 - selected_width) * 0.5), 198, 0.28)
end

local function get_build_system_state()
    return {
        world_key = sCurrentWorldKey,
        blocks = copy_table(sWorldBlocks),
        inventory = copy_table(sInventory),
        selected_slot = sSelectedSlot,
        build_height_offset = sBuildHeightOffset,
        block_count = sWorldBlockCount,
    }
end

local function on_warp()
    sModelAppliedObject = nil
    sLastSteveState = nil
    sCurrentSteveAnimation = nil
    deactivate_world_objects()
    sCurrentWorldKey = nil
    sCurrentWorldPrefix = nil
end


-- The CI harness exposes the pure generator only when explicitly requested.
if rawget(_G, "__STEVECRAFT_TEST") ~= nil then
    __STEVECRAFT_TEST.build_animation = build_steve_animation
    __STEVECRAFT_TEST.animation_value = steve_animation_value
    __STEVECRAFT_TEST.animation_constants = {
        frames = STEVE_ANIMATION_FRAMES,
        parts = STEVE_ANIMATION_PARTS,
        expected_index_length = 6 + (STEVE_ANIMATION_PARTS * 3 * 2),
    }
    __STEVECRAFT_TEST.build_system = {
        catalog = BLOCK_CATALOG,
        default_hotbar = copy_table(DEFAULT_HOTBAR),
        constants = {
            cell_size = GRID_CELL_SIZE,
            object_scale = GRID_OBJECT_SCALE,
            max_blocks = GRID_MAX_BLOCKS_PER_AREA,
            storage_chunk_size = GRID_STORAGE_CHUNK_SIZE,
            inventory_size = INVENTORY_SIZE,
            max_stack = INVENTORY_MAX_STACK,
        },
        cell_key = cell_key,
        cell_center = cell_center,
        compute_target_cell = compute_target_cell,
        inventory_add_block = inventory_add_block,
        inventory_can_add_block = inventory_can_add_block,
        select_inventory_slot = select_inventory_slot,
        ensure_inventory_loaded = ensure_inventory_loaded,
        ensure_world_loaded = ensure_world_loaded,
        place_grid_block = place_grid_block,
        remove_grid_block = remove_grid_block,
        get_build_system_state = get_build_system_state,
        get_world_context = get_world_context,
        get_behavior_init = function() return sGridBehaviorInit end,
        get_behavior_loop = function() return sGridBehaviorLoop end,
        get_behavior_id = function() return sGridBlockBehaviorId end,
        render_inventory = render_build_inventory,
        handle_build_input = consume_build_controls,
    }
    return
end

-- Native Mario movement is retained. The invisible per-area grid creates real surface objects.
hook_event(HOOK_MARIO_UPDATE, apply_steve_to_mario)
hook_event(HOOK_BEFORE_MARIO_UPDATE, consume_build_controls)
hook_event(HOOK_ON_HUD_RENDER, render_build_inventory)
hook_event(HOOK_ON_WARP, on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
