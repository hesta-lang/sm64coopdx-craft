-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone model assignment following the verified DynOS/Lua loading path.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.4.0-alpha"
local STEVE_GEO_NAME = "mario_geo"
local STEVE_GEO_FILE = "actors/minecraft_steve_geo.bin"

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

    -- Resolve the actor by its ModFS filepath, not the generic internal name
    -- "mario_geo". This prevents the lookup from accidentally resolving the
    -- built-in Mario layout when the custom actor file has not been registered.
    local lookup_name = STEVE_GEO_NAME
    if type(mod_fs_get) == "function" and type(MOD_FS_URI_FORMAT) == "string" then
        local mod_fs = nil
        local fs_ok, fs_result = pcall(mod_fs_get)
        if fs_ok then mod_fs = fs_result end
        if mod_fs == nil and type(mod_fs_create) == "function" then
            local create_ok, create_result = pcall(mod_fs_create)
            if create_ok then mod_fs = create_result end
        end
        if mod_fs ~= nil and type(mod_fs.modPath) == "string" then
            lookup_name = string.format(MOD_FS_URI_FORMAT, mod_fs.modPath, STEVE_GEO_FILE)
        end
    end

    local ok, modelId = pcall(smlua_model_util_get_id, lookup_name)
    if not ok then
        print("[SteveCraft] ERROR: GeoLayout lookup raised an error: " .. tostring(modelId))
        return nil
    end

    if type(modelId) ~= "number" or modelId == E_MODEL_ERROR_MODEL then
        print('[SteveCraft] ERROR: DynOS could not resolve Steve actor "' .. lookup_name .. '".')
        print("[SteveCraft] Verify that actors/minecraft_steve_geo.bin is present in the installed mod.")
        return nil
    end

    sModelId = modelId
    print("[SteveCraft] Steve actor URI resolved to extended model id=" .. tostring(modelId))
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
    update_steve_health(m)
    ensure_first_person_camera(m)
    local state = update_steve_controller(m)
    if m.marioObj == nil then return end

    local modelId = load_steve_model()
    if modelId == nil then return end
    -- The official SM64CoopDX player-model example reapplies the extended model
    -- on every HOOK_MARIO_UPDATE. A one-shot assignment can be overwritten by
    -- the normal player renderer during later frames.
    local already_applied = (sModelAppliedObject == m.marioObj)

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
    if not already_applied and register_steve_animations() then
        sCurrentSteveAnimation = nil
    end
    apply_steve_animation(m, state)

    if not already_applied then
        if currentId == modelId then
            print("[SteveCraft] Steve model assigned and verified on the existing marioObj.")
        else
            print("[SteveCraft] Steve model assigned; read-back verification is unavailable on this build.")
        end
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
local VOXEL_RAY_REACH = GRID_CELL_SIZE * 6
local INVENTORY_SIZE = 9
local INVENTORY_MAX_STACK = 64
local STEVE_HUNGER_POINTS = 20
local STEVE_ARMOR_POINTS = 0
local MINING_FRAMES_PER_HARDNESS = 45

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
local sFirstPersonInitialized = false
local sFirstPersonWarningShown = false
local sLastMarioHealth = nil
local sMiningCellKey = nil
local sMiningFrames = 0

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


local function health_to_half_hearts(health)
    local minimum = 0x00FF
    local maximum = 0x0880
    health = tonumber(health) or minimum
    local fraction = (health - minimum) / (maximum - minimum)
    fraction = math.max(0, math.min(1, fraction))
    return math.max(0, math.min(20, math.floor(fraction * 20 + 0.5)))
end

local function update_steve_health(m)
    if m == nil or m.playerIndex ~= 0 or type(m.health) ~= "number" then return end
    local health = m.health
    if sLastMarioHealth ~= nil and health < sLastMarioHealth then
        local damage = sLastMarioHealth - health
        local shake = SHAKE_SMALL_DAMAGE or 3
        if damage >= 0x0180 then
            shake = SHAKE_LARGE_DAMAGE or 5
        elseif damage >= 0x00C0 then
            shake = SHAKE_MED_DAMAGE or 4
        end
        if type(set_camera_shake_from_hit) == "function" then
            pcall(set_camera_shake_from_hit, shake)
        end
    end
    sLastMarioHealth = health
end

local function ensure_first_person_camera(m)
    if type(set_first_person_enabled) ~= "function" then
        if not sFirstPersonWarningShown then
            print("[SteveCraft] WARNING: this SM64CoopDX build does not expose first-person camera controls.")
            sFirstPersonWarningShown = true
        end
        return false
    end

    local camera = gFirstPersonCamera
    if not sFirstPersonInitialized then
        if type(first_person_reset) == "function" then
            pcall(first_person_reset)
        end
        camera = gFirstPersonCamera
        if camera ~= nil then
            local facing = 0
            if m and m.faceAngle and type(m.faceAngle.y) == "number" then
                facing = m.faceAngle.y
            end
            camera.yaw = facing + 0x8000
            camera.pitch = 0
            camera.centerL = false
            camera.forcePitch = false
            camera.forceYaw = false
            camera.forceRoll = true
            camera.fov = 70
        end
        local ok, err = pcall(set_first_person_enabled, true)
        if not ok then
            print("[SteveCraft] ERROR: unable to enable first-person camera: " .. tostring(err))
            return false
        end
        sFirstPersonInitialized = true
        print("[SteveCraft] SM64CoopDX first-person camera enabled.")
    elseif camera ~= nil then
        -- L is SteveCraft's build modifier, so do not let the camera recenter
        -- itself whenever the player holds that trigger.
        camera.centerL = false
        if camera.enabled ~= true then
            pcall(set_first_person_enabled, true)
        end
    end
    return true
end

local function is_first_person_active()
    if type(get_first_person_enabled) == "function" then
        local ok, enabled = pcall(get_first_person_enabled)
        return ok and enabled == true
    end
    return gFirstPersonCamera ~= nil and gFirstPersonCamera.enabled == true
end

local function get_camera_ray(m)
    local camera = gFirstPersonCamera
    if camera == nil or type(camera.yaw) ~= "number" or type(camera.pitch) ~= "number" then
        return nil
    end

    local origin = gLakituState and gLakituState.pos or nil
    if origin == nil then
        if m == nil or m.pos == nil then return nil end
        origin = { x = m.pos.x, y = (m.pos.y or 0) + 120, z = m.pos.z }
    end

    local yaw_sin = type(sins) == "function" and sins(camera.yaw) or math.sin(camera.yaw * math.pi / 32768)
    local yaw_cos = type(coss) == "function" and coss(camera.yaw) or math.cos(camera.yaw * math.pi / 32768)
    local pitch_sin = type(sins) == "function" and sins(camera.pitch) or math.sin(camera.pitch * math.pi / 32768)
    local pitch_cos = type(coss) == "function" and coss(camera.pitch) or math.cos(camera.pitch * math.pi / 32768)

    -- Match the forward vector used by first_person_cam.c when it builds
    -- Lakitu's focus from the camera yaw and pitch.
    local direction = {
        x = -pitch_cos * yaw_sin,
        y = -pitch_sin,
        z = -pitch_cos * yaw_cos,
    }
    return origin, direction
end

local function trace_voxel_ray(origin, direction, max_distance, blocks)
    if origin == nil or direction == nil then return nil end
    blocks = blocks or sWorldBlocks
    max_distance = max_distance or VOXEL_RAY_REACH

    local x = math.floor((origin.x or 0) / GRID_CELL_SIZE)
    local y = math.floor((origin.y or 0) / GRID_CELL_SIZE)
    local z = math.floor((origin.z or 0) / GRID_CELL_SIZE)
    local previous_x, previous_y, previous_z = nil, nil, nil

    local function axis_parameters(origin_value, cell, direction_value)
        if math.abs(direction_value) < 0.000001 then
            return math.huge, math.huge, 0
        end
        local step = direction_value > 0 and 1 or -1
        local boundary = direction_value > 0 and ((cell + 1) * GRID_CELL_SIZE) or (cell * GRID_CELL_SIZE)
        local max_value = (boundary - origin_value) / direction_value
        local delta_value = GRID_CELL_SIZE / math.abs(direction_value)
        return max_value, delta_value, step
    end

    local max_x, delta_x, step_x = axis_parameters(origin.x or 0, x, direction.x or 0)
    local max_y, delta_y, step_y = axis_parameters(origin.y or 0, y, direction.y or 0)
    local max_z, delta_z, step_z = axis_parameters(origin.z or 0, z, direction.z or 0)

    for _ = 1, 64 do
        if blocks[cell_key(x, y, z)] ~= nil then
            return x, y, z, previous_x, previous_y, previous_z
        end

        local distance
        if max_x <= max_y and max_x <= max_z then
            distance = max_x
            max_x = max_x + delta_x
            previous_x, previous_y, previous_z = x, y, z
            x = x + step_x
        elseif max_y <= max_z then
            distance = max_y
            max_y = max_y + delta_y
            previous_x, previous_y, previous_z = x, y, z
            y = y + step_y
        else
            distance = max_z
            max_z = max_z + delta_z
            previous_x, previous_y, previous_z = x, y, z
            z = z + step_z
        end

        if distance > max_distance then return nil end
    end
    return nil
end

local function get_world_surface_hit(origin, direction)
    if type(collision_find_surface_on_ray) ~= "function" then return nil end
    local dx = direction.x * VOXEL_RAY_REACH
    local dy = direction.y * VOXEL_RAY_REACH
    local dz = direction.z * VOXEL_RAY_REACH
    local ok, result = pcall(
        collision_find_surface_on_ray,
        origin.x, origin.y, origin.z,
        dx, dy, dz,
        2.0
    )
    if not ok or result == nil or result.surface == nil or result.hitPos == nil then
        return nil
    end
    return result
end

local function get_build_target(m, purpose)
    if not m or not m.pos then return nil end

    if is_first_person_active() then
        local origin, direction = get_camera_ray(m)
        if origin ~= nil and direction ~= nil then
            local hit_x, hit_y, hit_z, previous_x, previous_y, previous_z =
                trace_voxel_ray(origin, direction, VOXEL_RAY_REACH, sWorldBlocks)

            if purpose == "remove" then
                if hit_x ~= nil then return hit_x, hit_y, hit_z end
                return nil
            end

            if purpose == "place" then
                if hit_x ~= nil then
                    if previous_x ~= nil then return previous_x, previous_y, previous_z end
                    return nil
                end

                local hit = get_world_surface_hit(origin, direction)
                if hit ~= nil then
                    local normal = hit.surface.normal or { x = 0, y = 1, z = 0 }
                    local position = hit.hitPos
                    return math.floor((position.x + (normal.x or 0)) / GRID_CELL_SIZE),
                        math.floor((position.y + (normal.y or 0)) / GRID_CELL_SIZE),
                        math.floor((position.z + (normal.z or 0)) / GRID_CELL_SIZE)
                end
                return nil
            end
        end
    end

    -- Compatibility fallback for builds without the first-person camera API.
    local yaw = 0
    if m.faceAngle and type(m.faceAngle.y) == "number" then
        yaw = m.faceAngle.y
    elseif m.marioObj and type(m.marioObj.oMoveAngleYaw) == "number" then
        yaw = m.marioObj.oMoveAngleYaw
    end
    return compute_target_cell(m.pos, yaw, sBuildHeightOffset)
end

local function mining_frames_for_hardness(hardness)
    if type(hardness) ~= "number" or hardness < 0 then return nil end
    return math.max(1, math.ceil(hardness * MINING_FRAMES_PER_HARDNESS))
end

local function update_block_mining(m)
    local x, y, z = get_build_target(m, "remove")
    if x == nil then
        sMiningCellKey = nil
        sMiningFrames = 0
        return
    end

    local key = cell_key(x, y, z)
    local cell = sWorldBlocks[key]
    if cell == nil then
        sMiningCellKey = nil
        sMiningFrames = 0
        return
    end

    local definition = BLOCK_CATALOG[cell.id]
    if definition == nil or definition.destroy_speed < 0 then
        sMiningCellKey = key
        sMiningFrames = 0
        return
    end

    if sMiningCellKey ~= key then
        sMiningCellKey = key
        sMiningFrames = 0
    end

    sMiningFrames = sMiningFrames + 1
    local required = mining_frames_for_hardness(definition.destroy_speed)
    if required ~= nil and sMiningFrames >= required then
        local removed, reason = remove_grid_block(x, y, z)
        if not removed then
            print("[SteveCraft] Cannot mine block: " .. tostring(reason))
        end
        sMiningCellKey = nil
        sMiningFrames = 0
    end
end


local function consume_build_controls(m)
    if not m or m.playerIndex ~= 0 or not m.controller then return end
    ensure_world_loaded()

    local controller = m.controller
    local down = controller.buttonDown or 0
    local pressed = controller.buttonPressed or 0
    if (down & L_TRIG) == 0 then
        sMiningCellKey = nil
        sMiningFrames = 0
        return
    end

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
        local x, y, z = get_build_target(m, "place")
        if x then
            local placed, reason = place_grid_block(x, y, z)
            if not placed then
                print("[SteveCraft] Cannot place block: " .. tostring(reason))
            end
        else
            print("[SteveCraft] No surface or voxel in the crosshair range.")
        end
        consumed = consumed | A_BUTTON
    end

    -- Hold L+B on a voxel to mine it. Mining time is scaled by the block's
    -- Java hardness; this is a bare-hand prototype, not the Java tool system.
    if (down & B_BUTTON) ~= 0 then
        update_block_mining(m)
        consumed = consumed | B_BUTTON
    else
        sMiningCellKey = nil
        sMiningFrames = 0
    end

    if consumed ~= 0 then
        controller.buttonPressed = pressed & (~consumed)
        controller.buttonReleased = (controller.buttonReleased or 0) & (~consumed)
        controller.buttonDown = down & (~consumed)
    end
end

local BLOCK_HUD_COLORS = {
    ["minecraft:stone"] = { 132, 132, 132 },
    ["minecraft:dirt"] = { 126, 82, 52 },
    ["minecraft:grass_block"] = { 86, 150, 64 },
    ["minecraft:oak_planks"] = { 174, 129, 72 },
    ["minecraft:cobblestone"] = { 102, 102, 102 },
    ["minecraft:glass"] = { 170, 218, 230 },
    ["minecraft:bricks"] = { 166, 76, 62 },
    ["minecraft:sand"] = { 218, 203, 139 },
    ["minecraft:bedrock"] = { 62, 62, 70 },
}

local HEART_MASK = {
    "0110110",
    "1111111",
    "1111111",
    "0111110",
    "0011100",
    "0001000",
}
local FOOD_MASK = {
    "0001100",
    "0011110",
    "0111110",
    "0011111",
    "0001111",
    "0000011",
}
local ARMOR_MASK = {
    "001000",
    "011100",
    "111110",
    "111110",
    "011100",
    "001000",
}

local function hud_rect(x, y, width, height, r, g, b, a)
    if type(djui_hud_set_color) ~= "function" or type(djui_hud_render_rect) ~= "function" then
        return false
    end
    djui_hud_set_color(r, g, b, a or 255)
    djui_hud_render_rect(x, y, width, height)
    return true
end

local function draw_pixel_icon(mask, x, y, pixel, fill, empty, left_half_only)
    for row = 1, #mask do
        local line = mask[row]
        for column = 1, #line do
            if line:sub(column, column) == "1" then
                local color = fill
                if left_half_only and column > 4 then color = empty end
                hud_rect(
                    x + (column - 1) * pixel,
                    y + (row - 1) * pixel,
                    pixel, pixel,
                    color[1], color[2], color[3], color[4] or 255
                )
            end
        end
    end
end

local function render_crosshair(screen_width, screen_height)
    if not is_first_person_active() then return end
    local center_x = math.floor(screen_width * 0.5)
    local center_y = math.floor(screen_height * 0.5)
    -- Black outline with a small white center, matching the Minecraft plus reticle.
    hud_rect(center_x - 8, center_y - 1, 17, 3, 0, 0, 0, 220)
    hud_rect(center_x - 1, center_y - 8, 3, 17, 0, 0, 0, 220)
    hud_rect(center_x - 6, center_y, 13, 1, 245, 245, 245, 255)
    hud_rect(center_x, center_y - 6, 1, 13, 245, 245, 245, 255)
end

local function render_status_bars(screen_width, screen_height)
    local mario = gMarioStates and gMarioStates[0] or nil
    local health = mario and mario.health or sLastMarioHealth or 0x0880
    local half_hearts = health_to_half_hearts(health)
    local pixel = 2
    local icon_width = 14
    local gap = 3
    local row_width = 10 * icon_width + 9 * gap
    local left_x = 18
    local right_x = math.max(left_x + row_width + 12, screen_width - row_width - 18)
    local y = screen_height - 82

    for heart = 0, 9 do
        local value = math.max(0, math.min(2, half_hearts - heart * 2))
        local full = { 222, 48, 48, 255 }
        local empty = { 72, 30, 34, 255 }
        draw_pixel_icon(HEART_MASK, left_x + heart * (icon_width + gap), y, pixel, full, empty, value == 1)
        if value == 0 then
            draw_pixel_icon(HEART_MASK, left_x + heart * (icon_width + gap), y, pixel, empty, empty, false)
        end
    end

    -- Hunger and armor are visual indicators only in this release. SM64CoopDX
    -- has no Minecraft food/armor state to map yet; health is driven by MarioState.
    for icon_index = 0, 9 do
        local x = right_x + icon_index * (icon_width + gap)
        draw_pixel_icon(
            FOOD_MASK, x, y, pixel,
            { 220, 147, 54, 255 }, { 70, 48, 27, 255 }, false
        )
        draw_pixel_icon(
            ARMOR_MASK, left_x + icon_index * (icon_width + gap), y - 18, pixel,
            { 160, 170, 180, 255 }, { 48, 54, 62, 255 }, false
        )
    end
end

local function render_build_inventory()
    if not sInventoryLoaded then return end

    if type(djui_hud_set_resolution) == "function" and type(RESOLUTION_DJUI) == "number" then
        djui_hud_set_resolution(RESOLUTION_DJUI)
    end
    if type(djui_hud_set_font) == "function" and type(FONT_NORMAL) == "number" then
        djui_hud_set_font(FONT_NORMAL)
    end

    local screen_width = type(djui_hud_get_screen_width) == "function" and djui_hud_get_screen_width() or 320
    local screen_height = type(djui_hud_get_screen_height) == "function" and djui_hud_get_screen_height() or 240
    render_crosshair(screen_width, screen_height)
    render_status_bars(screen_width, screen_height)

    if type(djui_hud_render_rect) ~= "function" then
        if type(djui_hud_print_text) == "function" then
            local parts = {}
            for slot = 1, INVENTORY_SIZE do
                local item = sInventory[slot]
                local definition = item and BLOCK_CATALOG[item.id] or nil
                local label = definition and definition.short or "--"
                local count = item and item.count or 0
                parts[#parts + 1] = (slot == sSelectedSlot and ">" or "") .. label .. ":" .. tostring(count)
            end
            djui_hud_print_text(table.concat(parts, "  "), 2, screen_height - 24, 0.6)
        end
        return
    end

    local gap = 4
    local slot_size = math.max(22, math.min(40, (screen_width - 28 - 8 * gap) / 9))
    local total_width = slot_size * 9 + gap * 8
    local start_x = (screen_width - total_width) * 0.5
    local start_y = screen_height - slot_size - 12

    for slot = 1, INVENTORY_SIZE do
        local x = start_x + (slot - 1) * (slot_size + gap)
        local selected = slot == sSelectedSlot
        hud_rect(x - (selected and 2 or 1), start_y - (selected and 2 or 1),
            slot_size + (selected and 4 or 2), slot_size + (selected and 4 or 2),
            selected and 244 or 20, selected and 214 or 20, selected and 88 or 20, 255)
        hud_rect(x, start_y, slot_size, slot_size, 54, 54, 54, 210)
        local item = sInventory[slot]
        local definition = item and BLOCK_CATALOG[item.id] or nil
        if definition then
            local color = BLOCK_HUD_COLORS[item.id] or { 130, 130, 130 }
            local inset = math.max(4, math.floor(slot_size * 0.25))
            hud_rect(x + inset, start_y + inset, slot_size - inset * 2,
                slot_size - inset * 2, color[1], color[2], color[3], 255)
            if type(djui_hud_print_text) == "function" then
                local count = tostring(item.count)
                djui_hud_set_color(255, 255, 255, 255)
                djui_hud_print_text(count, x + slot_size - 12, start_y + slot_size - 12, 0.55)
            end
        end
    end

    if type(djui_hud_print_text) == "function" then
        local selected = sInventory[sSelectedSlot]
        local definition = selected and BLOCK_CATALOG[selected.id] or nil
        local selected_text = definition and (definition.name .. "  Y " .. tostring(sBuildHeightOffset)) or "Empty slot"
        djui_hud_set_color(255, 235, 170, 255)
        local text_width = type(djui_hud_measure_text) == "function" and djui_hud_measure_text(selected_text) * 0.65 or #selected_text * 5
        djui_hud_print_text(selected_text, math.max(4, (screen_width - text_width) * 0.5), start_y - 24, 0.65)

        if sMiningCellKey ~= nil then
            local progress = math.min(1, sMiningFrames / math.max(1, MINING_FRAMES_PER_HARDNESS))
            local bar_width = math.min(140, screen_width * 0.3)
            local bar_x = (screen_width - bar_width) * 0.5
            local bar_y = start_y - 10
            hud_rect(bar_x, bar_y, bar_width, 4, 20, 20, 20, 220)
            hud_rect(bar_x, bar_y, bar_width * progress, 4, 220, 190, 90, 255)
        end
    end
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
    sFirstPersonInitialized = false
    sLastMarioHealth = nil
    sMiningCellKey = nil
    sMiningFrames = 0
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
    __STEVECRAFT_TEST.constants = __STEVECRAFT_TEST.animation_constants
    __STEVECRAFT_TEST.camera = {
        ensure_first_person_camera = ensure_first_person_camera,
        get_camera_ray = get_camera_ray,
        trace_voxel_ray = trace_voxel_ray,
        health_to_half_hearts = health_to_half_hearts,
        mining_frames_for_hardness = mining_frames_for_hardness,
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
