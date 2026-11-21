package.path = "mods/stevecraft/?.lua;" .. package.path

local storage = {}
local spawned = {}
local sync_spawn_calls = 0
local local_spawn_calls = 0
local hooks = {}
local behavior = nil
local collision_calls = 0
local hud_lines = {}
local hud_rect_calls = 0

local audio_samples = {}
local audio_events = {}
function audio_sample_load(path)
    local sample = { path = path }
    audio_samples[path] = sample
    return sample
end
function audio_sample_play(sample, position, volume)
    audio_events[#audio_events + 1] = {
        sample = sample, position = position, volume = volume,
    }
    return true
end

local modfs_file = nil
local modfs_saved = false
local modfs = { modPath = "stevecraft" }

function modfs:get_file(path)
    assert(path == "actors/minecraft_steve_geo.bin", "unexpected ModFS actor path")
    return modfs_file
end

function modfs:create_file(path, is_text)
    assert(path == "actors/minecraft_steve_geo.bin", "unexpected ModFS actor path")
    assert(is_text == false, "DynOS actor must be stored as binary")
    modfs_file = { size = 0, bytes = "", isText = is_text }
    function modfs_file:set_text_mode(value) self.isText = value; return true end
    function modfs_file:erase(count)
        self.bytes = self.bytes:sub(math.min(#self.bytes + 1, count + 1))
        self.size = #self.bytes
        return true
    end
    function modfs_file:rewind() self.offset = 0; return true end
    function modfs_file:write_bytes(value)
        self.bytes = value
        self.size = #value
        return true
    end
    return modfs_file
end

function modfs:save()
    modfs_saved = true
    return true
end

function mod_fs_get() return modfs end
function mod_fs_create() error("existing ModFS should be reused") end

local model_lookup_names = {}
function smlua_model_util_get_id(name)
    model_lookup_names[#model_lookup_names + 1] = name
    if name == "modfs:/stevecraft/actors/minecraft_steve_geo.bin" then
        return 321
    end
    return E_MODEL_ERROR_MODEL
end

local function copy(source)
    local result = {}
    for k, v in pairs(source) do result[k] = v end
    return result
end

-- SM64CoopDX constants and callbacks mocked for deterministic Lua 5.4 tests.
ACT_FLAG_SWIMMING = 1 << 0
ACT_FLAG_AIR = 1 << 1
ACT_FLAG_MOVING = 1 << 2
E_MODEL_ERROR_MODEL = -1
E_MODEL_BREAKABLE_BOX = 123
OBJ_LIST_SURFACE = 9
OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE = 1
ACTIVE_FLAG_DEACTIVATED = 0x20
X_BUTTON = 1 << 4
B_BUTTON = 1 << 5
L_TRIG = 1 << 6
L_JPAD = 1 << 7
R_JPAD = 1 << 8
U_JPAD = 1 << 9
D_JPAD = 1 << 10
RESOLUTION_N64 = 1
RESOLUTION_DJUI = 2
FONT_NORMAL = 1
MOD_FS_URI_FORMAT = "modfs:/%s/%s"

gNetworkPlayers = {
    [0] = { currLevelNum = 1, currAreaIndex = 1 },
}
gCurrLevelNum = 1
gCurrAreaIndex = 1
gGlobalTimer = 1
gGlobalObjectCollisionData = {
    breakable_box_seg8_collision_08012D70 = 777,
}

function get_current_save_file_num()
    return 1
end

function mod_storage_save(key, value)
    storage[key] = tostring(value)
    return true
end

function mod_storage_load(key, default_value)
    local value = storage[key]
    if value == nil then return default_value end
    return value
end

function mod_storage_load_all()
    return copy(storage)
end

function mod_storage_remove(key)
    storage[key] = nil
    return true
end

function hook_behavior(_, object_list, synchronized, init_callback, loop_callback)
    assert(object_list == OBJ_LIST_SURFACE, "block behavior must live in the surface object list")
    assert(synchronized == false, "local persistent grid must not register a synchronized behavior")
    behavior = { init = init_callback, loop = loop_callback }
    return 900
end

function spawn_sync_object(...)
    sync_spawn_calls = sync_spawn_calls + 1
    error("local persisted blocks must not use the network-synchronized spawn path")
end

function spawn_non_sync_object(behavior_id, model_id, x, y, z, initialize)
    assert(behavior_id == 900, "unexpected behavior ID")
    assert(model_id == E_MODEL_BREAKABLE_BOX, "unexpected block placeholder model")
    local object = {
        oPosX = x, oPosY = y, oPosZ = z,
        activeFlags = 1,
    }
    if initialize then initialize(object) end
    behavior.init(object)
    spawned[#spawned + 1] = object
    local_spawn_calls = local_spawn_calls + 1
    return object
end

function obj_scale(object, scale)
    object.scale = scale
end

function load_object_collision_model()
    collision_calls = collision_calls + 1
end

function djui_hud_set_resolution() end
function djui_hud_set_font() end
function djui_hud_set_color() end
function djui_hud_measure_text(value) return #value * 8 end
function djui_hud_get_screen_width() return 640 end
function djui_hud_get_screen_height() return 360 end
function djui_hud_render_rect()
    hud_rect_calls = hud_rect_calls + 1
end
function djui_hud_print_text(value)
    hud_lines[#hud_lines + 1] = value
end

_G.__STEVECRAFT_TEST = {}
dofile("mods/stevecraft/main.lua")

local animation = __STEVECRAFT_TEST.build_animation
local build = __STEVECRAFT_TEST.build_system
local model = __STEVECRAFT_TEST.model
assert(type(animation) == "function", "animation generator export missing")
assert(type(build) == "table", "build system export missing")
assert(type(behavior) == "table", "custom surface behavior was not registered")

local function state()
    return build.get_build_system_state()
end

local function find_cell(x, y, z)
    return state().blocks[tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)]
end

local function test_catalog()
    local catalog = build.catalog
    assert(catalog["minecraft:stone"].destroy_speed == 1.5)
    assert(catalog["minecraft:stone"].explosion_resistance == 6.0)
    assert(catalog["minecraft:glass"].destroy_speed == 0.3)
    assert(catalog["minecraft:bedrock"].destroy_speed == -1.0)
    assert(catalog["minecraft:bedrock"].explosion_resistance == 3600000.0)
    assert(#build.default_hotbar == 9)
    assert(build.constants.inventory_size == 9)
    assert(build.constants.max_stack == 64)
    print("PASS: Java 26.3 block catalogue and hotbar metadata")
end

local function test_grid_math()
    local x, y, z = build.cell_center(1, 2, -1)
    assert(x == 135 and y == 225 and z == -45)
    x, y, z = build.compute_target_cell({ x = 0, y = 0, z = 0 }, 0, 0)
    assert(x == 0 and y == 0 and z == 1)
    x, y, z = build.compute_target_cell({ x = 0, y = 90, z = 0 }, 16384, 1)
    assert(x == 1 and y == 2 and z == 0)
    assert(build.cell_key(-2, 0, 4) == "-2,0,4")
    print("PASS: invisible grid coordinate and forward-target math")
end

local function test_world_load_and_collision()
    assert(build.ensure_world_loaded() == true)
    assert(state().block_count == 0)
    assert(state().world_key == "1_1_1")

    local placed, reason = build.place_grid_block(0, 0, 1)
    assert(placed == true, "first placement failed: " .. tostring(reason))
    local snapshot = state()
    assert(snapshot.block_count == 1)
    assert(snapshot.inventory[1].count == 63)
    local cell = find_cell(0, 0, 1)
    assert(cell and cell.id == "minecraft:stone")
    assert(cell.object ~= nil)
    assert(cell.object.collisionData == 777)
    assert(cell.object.scale == build.constants.object_scale)
    assert(cell.object.oCollisionDistance > 0)
    assert(cell.object.oDrawingDistance > 0)
    assert(#spawned == 1 and local_spawn_calls == 1, "one placement created more than one object")
    assert(sync_spawn_calls == 0, "grid attempted a second synchronized spawn path")

    local duplicate = build.place_grid_block(0, 0, 1)
    assert(duplicate == false, "occupied cell accepted a second block")
    assert(state().inventory[1].count == 63, "failed placement consumed inventory")

    behavior.loop(cell.object)
    assert(collision_calls == 1, "block behavior did not register a dynamic collision update")

    assert(storage["sc_world_1_1_1_chunk_1"] ~= nil, "grid data was not persisted")
    local removed, remove_reason = build.remove_grid_block(0, 0, 1)
    assert(removed == true, "block removal failed: " .. tostring(remove_reason))
    assert(state().block_count == 0)
    assert(state().inventory[1].count == 64, "removed block was not returned to inventory")
    assert(cell.object.activeFlags == ACTIVE_FLAG_DEACTIVATED, "removed object was not deactivated")
    assert(storage["sc_world_1_1_1_chunk_1"] == nil, "empty grid storage chunk was not removed")
    print("PASS: place, duplicate rejection, dynamic collision loop, remove, and refund")
end

local function test_bedrock_and_full_inventory()
    build.select_inventory_slot(9)
    local placed = build.place_grid_block(1, 0, 0)
    assert(placed == true)
    local ok, reason = build.remove_grid_block(1, 0, 0)
    assert(ok == false and reason == "unbreakable")
    assert(find_cell(1, 0, 0) ~= nil, "bedrock was removed")
    assert(state().inventory[9].count == 63, "bedrock count changed after failed break")

    -- A breakable block cannot be removed when its matching stack is already full.
    build.select_inventory_slot(1)
    assert(build.place_grid_block(2, 0, 0) == true)
    assert(state().inventory[1].count == 63)
    assert(build.inventory_add_block("minecraft:stone", 1) == true)
    assert(state().inventory[1].count == 64)
    ok, reason = build.remove_grid_block(2, 0, 0)
    assert(ok == false and reason == "inventory_full")
    assert(find_cell(2, 0, 0) ~= nil, "block disappeared despite full inventory")
    print("PASS: unbreakable bedrock and no item loss when inventory is full")
end

local function test_hotbar_and_input()
    build.select_inventory_slot(1)
    local m = {
        playerIndex = 0,
        controller = {
            buttonDown = L_TRIG | R_JPAD,
            buttonPressed = L_TRIG | R_JPAD,
            buttonReleased = 0,
        },
        pos = { x = 0, y = 0, z = 0 },
        faceAngle = { y = 0 },
    }
    build.handle_build_input(m)
    assert(state().selected_slot == 2)
    assert((m.controller.buttonPressed & R_JPAD) == 0, "hotbar input was not consumed")
    assert((m.controller.buttonDown & R_JPAD) == 0, "held hotbar input leaked into Mario controls")
    assert((m.controller.buttonDown & L_TRIG) ~= 0, "build modifier was unexpectedly cleared")

    m.controller.buttonDown = L_TRIG | U_JPAD
    m.controller.buttonPressed = L_TRIG | U_JPAD
    build.handle_build_input(m)
    assert(state().build_height_offset == 1)
    assert((m.controller.buttonPressed & U_JPAD) == 0)

    -- Simulate duplicate A press callbacks in the same engine frame.
    gGlobalTimer = 300
    m.controller.buttonDown = X_BUTTON
    m.controller.buttonPressed = X_BUTTON
    build.handle_build_input(m)
    local after_first = state().block_count
    assert(build.is_place_button_latched(), "first A press was not latched")

    -- Repeat the touch press event on a later frame without releasing A.
    gGlobalTimer = 301
    m.controller.buttonDown = X_BUTTON
    m.controller.buttonPressed = X_BUTTON
    build.handle_build_input(m)
    assert(state().block_count == after_first,
        "repeated A event across held frames created another block")
    assert(build.is_place_button_latched(), "held A press unexpectedly cleared its latch")

    -- A real release rearms placement. The next tap targets the same occupied cell.
    m.controller.buttonDown = 0
    m.controller.buttonPressed = 0
    m.controller.buttonReleased = X_BUTTON
    build.handle_build_input(m)
    assert(not build.is_place_button_latched(), "A release did not rearm placement")

    gGlobalTimer = 302
    m.controller.buttonDown = X_BUTTON
    m.controller.buttonPressed = X_BUTTON
    m.controller.buttonReleased = 0
    build.handle_build_input(m)
    assert(build.is_place_button_latched(), "new A press did not latch")
    assert(state().block_count == after_first, "occupied cell spawned a second block")
    assert(sync_spawn_calls == 0, "input handler used synchronized spawning")

    m.controller.buttonDown = 0
    m.controller.buttonPressed = 0
    m.controller.buttonReleased = 0
    build.render_inventory()
    assert(#hud_lines >= 2, "inventory HUD did not render")
    print("PASS: hotbar selection, layer control, consumed inputs, and HUD")
end

local function test_per_area_persistence_and_chunk_limits()
    -- Fill one area's grid and confirm its bounded chunks exist while active.
    gNetworkPlayers[0].currAreaIndex = 2
    assert(build.ensure_world_loaded() == true)
    assert(state().world_key == "1_1_2")
    assert(state().block_count == 0)

    local cell_count = 48
    for index = 0, cell_count - 1 do
        local slot = (index % 8) + 1
        build.select_inventory_slot(slot)
        local item = state().inventory[slot]
        if item.count == 0 then assert(build.inventory_add_block(item.id, 64)) end
        local ok, reason = build.place_grid_block(index, 0, 0)
        assert(ok == true, "bulk placement failed at " .. index .. ": " .. tostring(reason))
    end
    assert(state().block_count == cell_count)
    local prefix = "sc_world_1_1_2_chunk_"
    local chunk_count = 0
    for key, value in pairs(storage) do
        if key:sub(1, #prefix) == prefix then
            chunk_count = chunk_count + 1
            assert(#value <= build.constants.storage_chunk_size, "storage chunk exceeded safe mod-storage length")
        end
    end
    assert(chunk_count > 1, "large active grid was not split into bounded storage chunks")

    -- Changing area destroys all saved construction data, not just live objects.
    local area2_object = find_cell(0, 0, 0).object
    gNetworkPlayers[0].currAreaIndex = 3
    assert(build.ensure_world_loaded() == true)
    assert(state().block_count == 0)
    assert(area2_object.activeFlags == ACTIVE_FLAG_DEACTIVATED)
    for key in pairs(storage) do
        assert(key:sub(1, 9) ~= "sc_world_", "old scene block data survived an area change")
    end

    -- Returning to a previous area must not resurrect its blocks.
    gNetworkPlayers[0].currAreaIndex = 2
    assert(build.ensure_world_loaded() == true)
    assert(state().block_count == 0)
    gNetworkPlayers[0].currAreaIndex = 1
    assert(build.ensure_world_loaded() == true)
    assert(state().world_key == "1_1_1")
    assert(state().block_count == 0, "blocks from the previous scene were restored")

    -- Explicit scene reset also removes all persisted world-grid keys.
    assert(build.place_grid_block(10, 0, 0) == true)
    build.reset_scene()
    assert(state().block_count == 0)
    for key in pairs(storage) do
        assert(key:sub(1, 9) ~= "sc_world_", "scene reset left a saved block key")
    end
    print("PASS: scene changes and new game reset clear all prior blocks")
end

local function test_block_limit()
    gNetworkPlayers[0].currAreaIndex = 4
    assert(build.ensure_world_loaded() == true)
    local target = 0
    for slot = 1, 9 do
        build.select_inventory_slot(slot)
        for _ = 1, 14 do
            local entry = state().inventory[slot]
            if entry.count > 0 and target < build.constants.max_blocks then
                local ok, reason = build.place_grid_block(target, 0, 0)
                assert(ok == true, "grid capacity fill failed: " .. tostring(reason))
                target = target + 1
            end
        end
    end
    -- Tests can seed the remaining stacks through the public inventory helper.
    while target < build.constants.max_blocks do
        for slot = 1, 9 do
            build.select_inventory_slot(slot)
            local entry = state().inventory[slot]
            if entry.count == 0 then
                build.inventory_add_block(entry.id, 64)
                entry = state().inventory[slot]
            end
            if entry.count > 0 and target < build.constants.max_blocks then
                local ok = build.place_grid_block(target, 0, 0)
                assert(ok == true)
                target = target + 1
            end
        end
        local total = 0
        for _, entry in ipairs(state().inventory) do total = total + entry.count end
        if total == 0 and target < build.constants.max_blocks then
            -- Use a new test save slot to replenish a finite test-only inventory.
            assert(false, "test inventory was exhausted before the configured grid cap")
        end
    end
    local ok, reason = build.place_grid_block(999, 0, 0)
    assert(ok == false and reason == "grid_full")
    assert(state().block_count == build.constants.max_blocks)
    print("PASS: configured per-area block limit")
end

test_catalog()
test_grid_math()
test_world_load_and_collision()
test_bedrock_and_full_inventory()
test_hotbar_and_input()
test_per_area_persistence_and_chunk_limits()
test_block_limit()

local function test_first_person_camera_and_voxel_ray()
    local camera = __STEVECRAFT_TEST.camera
    local native = __STEVECRAFT_TEST.modules.native_engine
    assert(type(camera) == "table", "camera system export missing")
    assert(type(native) == "table", "native engine adapter export missing")

    local hit_x, hit_y, hit_z, previous_x, previous_y, previous_z = camera.trace_voxel_ray(
        { x = 45, y = 45, z = 45 },
        { x = 0, y = 0, z = 1 },
        450,
        { ["0,0,2"] = { id = "minecraft:stone" } }
    )
    assert(hit_x == 0 and hit_y == 0 and hit_z == 2, "voxel DDA missed the target block")
    assert(previous_x == 0 and previous_y == 0 and previous_z == 1, "voxel DDA did not return the placement-adjacent cell")

    assert(camera.health_to_half_hearts(0x0880) == 20, "full Mario health did not map to 20 half-hearts")
    assert(camera.health_to_half_hearts(0x00FF) == 0, "minimum Mario health did not map to zero half-hearts")
    assert(camera.health_to_half_hearts(0x0880 + 100) == 20, "health mapping did not clamp at maximum")

    assert(camera.mining_frames_for_hardness(1.5) == 68, "stone hardness mining time is incorrect")
    assert(camera.mining_frames_for_hardness(0.5) == 23, "dirt hardness mining time is incorrect")
    assert(camera.mining_frames_for_hardness(-1) == nil, "bedrock must not receive a mining duration")

    gFirstPersonCamera = {
        enabled = false,
        yaw = 0,
        pitch = 0,
        centerL = true,
        forcePitch = true,
        forceYaw = true,
        forceRoll = false,
        fov = 70,
    }
    gLakituState = { pos = { x = 10, y = 110, z = 20 } }
    function first_person_reset()
        gFirstPersonCamera.pitch = 0
        gFirstPersonCamera.yaw = 0
    end
    function set_first_person_enabled(enabled)
        gFirstPersonCamera.enabled = enabled
    end
    function get_first_person_enabled()
        return gFirstPersonCamera.enabled
    end
    function sins(angle) return math.sin(angle * math.pi / 32768) end
    function coss(angle) return math.cos(angle * math.pi / 32768) end
    function collision_find_surface_on_ray(sx, sy, sz, dx, dy, dz, precision)
        return {
            surface = { normal = { x = 0, y = 1, z = 0 } },
            hitPos = { x = sx + dx, y = sy + dy, z = sz + dz },
            precision = precision,
        }
    end
    function collision_find_floor(x, y, z)
        return { queried = true, x = x, y = y, z = z }
    end

    local capabilities = native.capabilities()
    assert(capabilities.host_c_player_physics == true, "host C physics ownership was not detected")
    assert(capabilities.first_person_camera == true, "native first-person C API was not detected")
    assert(capabilities.native_surface_ray == true, "native surface-ray C API was not detected")
    local floor = native.find_floor(1, 2, 3)
    assert(floor and floor.queried and floor.y == 2, "native C floor query did not pass through")
    local snapshot = native.read_player_physics_state({
        action = 7, forwardVel = 12, vel = { x = 1, y = 2, z = 3 },
        pos = { x = 4, y = 5, z = 6 }, floor = {},
    })
    assert(snapshot.action == 7 and snapshot.forward_speed == 12 and snapshot.velocity_y == 2,
        "MarioState C physics snapshot was not read correctly")

    local enabled = camera.ensure_first_person_camera({ faceAngle = { y = 0 } })
    assert(enabled == true and gFirstPersonCamera.enabled == true, "first-person camera did not enable")
    assert(gFirstPersonCamera.yaw == 0x8000, "camera did not initialize to Mario's forward direction")
    assert(gFirstPersonCamera.centerL == false, "build modifier L still recenters the camera")
    assert(gFirstPersonCamera.forcePitch == false and gFirstPersonCamera.forceYaw == false,
        "first-person camera input was locked")

    local origin, direction = camera.get_camera_ray({ pos = { x = 0, y = 0, z = 0 } })
    assert(origin.x == 10 and origin.y == 110 and origin.z == 20, "camera ray did not use Lakitu's camera position")
    assert(math.abs(direction.z - 1) < 0.0001, "camera ray direction does not match the first-person view")
    local surface_hit = camera.get_world_surface_hit(origin, direction, 100)
    assert(surface_hit and surface_hit.precision == 2.0,
        "surface ray did not route through native C collision query")

    build.render_inventory()
    assert(hud_rect_calls > 20, "first-person crosshair and pixel HUD did not render rectangles")
    gFirstPersonCamera = nil
    gLakituState = nil
    print("PASS: first-person setup, center-camera ray, voxel DDA, hearts, damage mapping, and hardness timing")
end


test_first_person_camera_and_voxel_ray()

local function test_model_asset_registration()
    assert(type(model) == "table", "model registration export missing")
    local bytes = model.get_actor_binary()
    assert(type(bytes) == "string", "embedded DYNOSBIN did not decode")
    assert(#bytes == model.expected_binary_size, "embedded actor size mismatch")
    assert(bytes:sub(1, 8) == "DYNOSBIN", "embedded actor header is invalid")

    local uri = model.ensure_actor_in_modfs()
    assert(uri == "modfs:/stevecraft/actors/minecraft_steve_geo.bin", "wrong ModFS actor URI")
    assert(modfs_file ~= nil and modfs_file.bytes == bytes, "original actor bytes were not copied to ModFS")
    assert(modfs_saved == true, "ModFS actor was not saved")

    local model_id = model.load_actor()
    assert(model_id == 321, "Steve model did not resolve from the ModFS URI")
    assert(#model_lookup_names == 1, "loader attempted a fallback model name")
    assert(model_lookup_names[1] == uri, "loader resolved a built-in symbol instead of the mod actor")
    local update_function = __STEVECRAFT_TEST.apply_player_update
    assert(type(update_function) == "function", "player update callback export missing")
    local captured = {}
    for index = 1, debug.getinfo(update_function, "u").nups do
        local name, value = debug.getupvalue(update_function, index)
        captured[name] = value
    end
    assert(type(captured.Camera) == "table", "player update did not bind the camera module")
    assert(type(captured.Physics) == "table", "player update did not bind the physics module")
    assert(type(captured.Model) == "table", "player update did not bind the model module")
    print("PASS: embedded DYNOSBIN import and modular player callbacks")
end

local function test_separated_modules_and_audio()
    local modules = __STEVECRAFT_TEST.modules
    assert(type(modules) == "table", "subsystem module exports missing")
    for _, name in ipairs({ "blocks", "sounds", "physics", "camera", "hud", "model", "native_engine" }) do
        assert(type(modules[name]) == "table", "missing module: " .. name)
    end

    local sounds = modules.sounds
    assert(sounds.load() == true, "sound samples did not load")
    local expected_samples = {
        "modfs:/stevecraft/assets/sounds/stone_step.ogg",
        "modfs:/stevecraft/assets/sounds/dirt_step.ogg",
        "modfs:/stevecraft/assets/sounds/grass_step.ogg",
        "modfs:/stevecraft/assets/sounds/wood_step.ogg",
        "modfs:/stevecraft/assets/sounds/stone_place.ogg",
        "modfs:/stevecraft/assets/sounds/dirt_break.ogg",
    }
    for _, uri in ipairs(expected_samples) do
        assert(audio_samples[uri] ~= nil, "missing imported Java sound: " .. uri)
    end
    local assets = require("systems/assets")
    assert(assets.get_uri("sounds/stone_step.ogg")
        == "modfs:/stevecraft/assets/sounds/stone_step.ogg",
        "asset URI did not resolve through the active ModFS")

    local physics = modules.physics
    local walker = {
        action = ACT_FLAG_MOVING,
        forwardVel = 5,
        floor = {},
        pos = { x = 0, y = 0, z = 0 },
        vel = { y = 0 },
    }
    gGlobalTimer = 700
    local audio_baseline = #audio_events
    local state_name = physics.update(walker, sounds, function() return "wood" end)
    assert(state_name == "move", "movement adapter did not detect walking")
    assert(#audio_events == audio_baseline + 1, "footstep sound did not fire exactly once")
    assert(audio_events[audio_baseline + 1].sample.path == "modfs:/stevecraft/assets/sounds/wood_step.ogg", "wrong material footstep sound")
    physics.update(walker, sounds, function() return "wood" end)
    assert(#audio_events == audio_baseline + 1, "footstep cadence played twice in one frame")

    sounds.play_place("minecraft:stone", walker.pos)
    sounds.play_break("minecraft:dirt", walker.pos)
    assert(audio_events[audio_baseline + 2].sample.path == "modfs:/stevecraft/assets/sounds/stone_place.ogg")
    assert(audio_events[audio_baseline + 3].sample.path == "modfs:/stevecraft/assets/sounds/dirt_break.ogg")
    print("PASS: separate modules and original block/footstep sound playback")
end

test_separated_modules_and_audio()
test_model_asset_registration()

local modules = __STEVECRAFT_TEST.modules
assert(type(modules) == "table", "modular subsystem exports missing")
for _, name in ipairs({ "blocks", "sounds", "physics", "camera", "hud", "model" }) do
    assert(type(modules[name]) == "table", "missing current subsystem module: " .. name)
end
assert(type(modules.blocks.catalog) == "table", "block catalogue was not loaded")
assert(type(modules.sounds.play_place) == "function", "block audio adapter was not loaded")
assert(type(modules.camera.get_ray) == "function", "first-person camera module was not loaded")
assert(type(modules.hud.render) == "function", "HUD renderer was not loaded")
print("PASS: current SteveCraft modules and ModFS resource URI adapter")

print("SteveCraft build-system validation passed.")
