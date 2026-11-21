-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone model assignment following the verified DynOS/Lua loading path.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.4.2-alpha"
local Assets = require("assets")
local Blocks = require("blocks")
local Sounds = require("sounds")
local Physics = require("physics")
local Camera = require("camera")
local HUD = require("hud")
local Model = require("model")

local BLOCK_CATALOG = Blocks.catalog
local DEFAULT_HOTBAR = Blocks.default_hotbar

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
local sMiningCellKey = nil
local sMiningFrames = 0
local sMiningRequiredFrames = 0

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
        false,
        grid_block_init,
        grid_block_loop
    )
    if ok then
        sGridBlockBehaviorId = behavior_id
    else
        print("[SteveCraft] ERROR: unable to register grid block collision behavior: " .. tostring(behavior_id))
    end
end

local function grid_object_registry_key(x, y, z)
    return tostring(sCurrentWorldKey or "unknown") .. ":" .. cell_key(x, y, z)
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

    local object, reason = Blocks.spawn_once(
        grid_object_registry_key(x, y, z),
        sGridBlockBehaviorId,
        E_MODEL_BREAKABLE_BOX,
        world_x, world_y, world_z,
        initialize
    )
    if object == nil and not sWarnedGridSpawn then
        print("[SteveCraft] ERROR: local grid block spawn failed: " .. tostring(reason))
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
    Blocks.clear_spawned()
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
    local wx, wy, wz = cell_center(x, y, z)
    Sounds.play_place(block_id, { x = wx, y = wy, z = wz })
    save_inventory()
    save_world_grid()
    return true
end

local original_place_grid_block = place_grid_block
place_grid_block = function(x, y, z, ...)
    local placed, reason = original_place_grid_block(x, y, z, ...)
    if placed then
        local cell = sWorldBlocks[cell_key(x, y, z)]
        if cell ~= nil then
            local px, py, pz = cell_center(x, y, z)
            stevecraft_play_block_sound("place", cell.id, { x = px, y = py, z = pz })
        end
    end
    return placed, reason
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
    Blocks.forget(grid_object_registry_key(x, y, z), cell.object)
    sWorldBlocks[key] = nil
    sWorldBlockCount = math.max(0, sWorldBlockCount - 1)
    inventory_add_block(cell.id, 1)
    local wx, wy, wz = cell_center(x, y, z)
    Sounds.play_break(cell.id, { x = wx, y = wy, z = wz })
    save_inventory()
    save_world_grid()
    return true
end

local original_remove_grid_block = remove_grid_block
remove_grid_block = function(x, y, z, ...)
    local cell = sWorldBlocks[cell_key(x, y, z)]
    local block_id = cell and cell.id or nil
    local removed, reason = original_remove_grid_block(x, y, z, ...)
    if removed then
        local px, py, pz = cell_center(x, y, z)
        stevecraft_play_block_sound("break", block_id, { x = px, y = py, z = pz })
    end
    return removed, reason
end



local function health_to_half_hearts(health)
    return Camera.health_to_half_hearts(health)
end

local function is_first_person_active()
    return Camera.is_active()
end

local function get_camera_ray(mario)
    return Camera.get_ray(mario)
end

local function trace_voxel_ray(origin, direction, max_distance, blocks)
    return Camera.trace_voxel_ray(origin, direction, max_distance, blocks, GRID_CELL_SIZE)
end

local function get_world_surface_hit(origin, direction)
    return Camera.get_world_surface_hit(origin, direction, VOXEL_RAY_REACH)
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
        sMiningRequiredFrames = 0
        return
    end

    local key = cell_key(x, y, z)
    local cell = sWorldBlocks[key]
    if cell == nil then
        sMiningCellKey = nil
        sMiningFrames = 0
        sMiningRequiredFrames = 0
        return
    end

    local definition = BLOCK_CATALOG[cell.id]
    if definition == nil or definition.destroy_speed < 0 then
        sMiningCellKey = key
        sMiningFrames = 0
        sMiningRequiredFrames = 0
        return
    end

    if sMiningCellKey ~= key then
        sMiningCellKey = key
        sMiningFrames = 0
        sMiningRequiredFrames = mining_frames_for_hardness(definition.destroy_speed) or 0
    end

    sMiningFrames = sMiningFrames + 1
    local required = sMiningRequiredFrames
    if required > 0 and sMiningFrames >= required then
        local removed, reason = remove_grid_block(x, y, z)
        if not removed then
            print("[SteveCraft] Cannot mine block: " .. tostring(reason))
        end
        sMiningCellKey = nil
        sMiningFrames = 0
        sMiningRequiredFrames = 0
    end
end


local sLastPlaceFrame = nil

local function consume_build_controls(m)
    if not m or m.playerIndex ~= 0 or not m.controller then return end
    ensure_world_loaded()

    local controller = m.controller
    local down = controller.buttonDown or 0
    local pressed = controller.buttonPressed or 0
    if (down & L_TRIG) == 0 then
        sMiningCellKey = nil
        sMiningFrames = 0
        sMiningRequiredFrames = 0
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
        local frame = tonumber(gGlobalTimer) or -1
        if frame < 0 or frame ~= sLastPlaceFrame then
            sLastPlaceFrame = frame
            local x, y, z = get_build_target(m, "place")
            if x then
                local placed, reason = place_grid_block(x, y, z)
                if not placed then
                    print("[SteveCraft] Cannot place block: " .. tostring(reason))
                end
            else
                print("[SteveCraft] No surface or voxel in the crosshair range.")
            end
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
        sMiningRequiredFrames = 0
    end

    if consumed ~= 0 then
        controller.buttonPressed = pressed & (~consumed)
        controller.buttonReleased = (controller.buttonReleased or 0) & (~consumed)
        controller.buttonDown = down & (~consumed)
    end
end

local function render_build_inventory()
    local mario = gMarioStates and gMarioStates[0] or nil
    local health = mario and mario.health or 0x0880
    HUD.render({
        inventory_loaded = sInventoryLoaded,
        inventory = sInventory,
        selected_slot = sSelectedSlot,
        catalog = BLOCK_CATALOG,
        height_offset = sBuildHeightOffset,
        health_points = Camera.health_to_half_hearts(health),
        hunger_points = STEVE_HUNGER_POINTS,
        armor_points = STEVE_ARMOR_POINTS,
        camera_active = Camera.is_active(),
        mining_frames = sMiningFrames,
        mining_required = sMiningRequiredFrames,
    })
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

local function get_footstep_material(mario)
    if mario == nil or mario.pos == nil then return "stone" end
    local x = math.floor((mario.pos.x or 0) / GRID_CELL_SIZE)
    local z = math.floor((mario.pos.z or 0) / GRID_CELL_SIZE)
    local y = math.floor(((mario.pos.y or 0) - 1) / GRID_CELL_SIZE)
    for offset = 0, 2 do
        local cell = sWorldBlocks[cell_key(x, y - offset, z)]
        if cell ~= nil then
            return Blocks.get_footstep_material(cell.id)
        end
    end
    return "stone"
end

local function apply_steve_to_mario(m)
    if m == nil or m.playerIndex ~= 0 then return end
    Camera.update_health(m)
    Camera.ensure(m)
    local state = Physics.update(m, Sounds, get_footstep_material)
    Model.apply_to_player(m, state)
end


local function stevecraft_play_block_sound(kind, block_id, position)
    if type(STEVECRAFT_SYSTEMS.sounds.play) ~= "function" then return false end
    local material = "stone"
    if type(block_id) == "string" then
        if block_id:find("dirt", 1, true) then material = "dirt"
        elseif block_id:find("grass", 1, true) then material = "grass"
        elseif block_id:find("planks", 1, true) then material = "wood"
        elseif block_id:find("glass", 1, true) then material = "glass"
        elseif block_id:find("sand", 1, true) then material = "sand"
        elseif block_id:find("bedrock", 1, true) then material = "stone"
        end
    end
    return STEVECRAFT_SYSTEMS.sounds.play(material .. "_" .. kind, position, 0.8, 1.0)
end

local sLastFootstepFrame = -1000
local update_stevecraft_footstep
update_stevecraft_footstep = function(m)
    if m == nil or m.pos == nil or not STEVECRAFT_SYSTEMS.physics.is_grounded(m) then return end
    local speed = math.abs(tonumber(m.forwardVel) or 0)
    if speed < 5 then return end
    local frame = tonumber(gGlobalTimer) or 0
    if frame - sLastFootstepFrame < 10 then return end
    local x = math.floor((m.pos.x or 0) / GRID_CELL_SIZE)
    local y = math.floor(((m.pos.y or 0) - 8) / GRID_CELL_SIZE)
    local z = math.floor((m.pos.z or 0) / GRID_CELL_SIZE)
    local cell = sWorldBlocks[cell_key(x, y, z)] or sWorldBlocks[cell_key(x, y - 1, z)]
    local block_id = cell and cell.id or "minecraft:stone"
    local did_play = stevecraft_play_block_sound("step", block_id, m.pos)
    if did_play then sLastFootstepFrame = frame end
end

local function on_warp()
    Model.reset()
    Camera.reset()
    Physics.reset()
    sMiningCellKey = nil
    sMiningFrames = 0
    sMiningRequiredFrames = 0
    deactivate_world_objects()
    sCurrentWorldKey = nil
    sCurrentWorldPrefix = nil
end


-- The CI harness exposes the pure generator only when explicitly requested.
if rawget(_G, "__STEVECRAFT_TEST") ~= nil then
    __STEVECRAFT_TEST.build_animation = Model.build_animation
    __STEVECRAFT_TEST.animation_value = Model.animation_value
    __STEVECRAFT_TEST.animation_constants = Model.animation_constants
    __STEVECRAFT_TEST.constants = Model.animation_constants
    __STEVECRAFT_TEST.apply_player_update = apply_steve_to_mario
    __STEVECRAFT_TEST.model = Model
    __STEVECRAFT_TEST.modules = {
        blocks = Blocks,
        sounds = Sounds,
        physics = Physics,
        camera = Camera,
        hud = HUD,
        model = Model,
    }
    __STEVECRAFT_TEST.camera = {
        ensure_first_person_camera = Camera.ensure,
        get_camera_ray = Camera.get_ray,
        trace_voxel_ray = trace_voxel_ray,
        health_to_half_hearts = Camera.health_to_half_hearts,
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

Assets.import_all()
Sounds.load()

-- Native Mario movement is retained. The invisible per-area grid creates real surface objects.
hook_event(HOOK_MARIO_UPDATE, apply_steve_to_mario)
hook_event(HOOK_BEFORE_MARIO_UPDATE, consume_build_controls)
hook_event(HOOK_ON_HUD_RENDER, render_build_inventory)
hook_event(HOOK_ON_WARP, on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
