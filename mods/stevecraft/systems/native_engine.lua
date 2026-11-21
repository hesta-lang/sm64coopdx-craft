-- SteveCraft adapter for functions already compiled into SM64CoopDX.
-- This module does NOT load a native library: the host engine owns the C runtime.
local Native = {}

local function has_function(name)
    return type(_G[name]) == "function"
end

function Native.has_function(name)
    return type(name) == "string" and has_function(name)
end

function Native.first_person_api_available()
    return has_function("set_first_person_enabled")
        and has_function("get_first_person_enabled")
end

function Native.get_first_person_camera()
    return gFirstPersonCamera
end

function Native.reset_first_person()
    if not has_function("first_person_reset") then
        return false, "first_person_reset is unavailable"
    end
    local ok, result = pcall(first_person_reset)
    if not ok then return false, result end
    return true, result
end

function Native.set_first_person_enabled(enabled)
    if not has_function("set_first_person_enabled") then
        return false, "set_first_person_enabled is unavailable"
    end
    local ok, result = pcall(set_first_person_enabled, enabled == true)
    if not ok then return false, result end
    return true, result
end

function Native.is_first_person_enabled()
    if has_function("get_first_person_enabled") then
        local ok, result = pcall(get_first_person_enabled)
        if ok then return result == true end
    end
    local camera = Native.get_first_person_camera()
    return camera ~= nil and camera.enabled == true
end

function Native.get_lakitu_position()
    local state = gLakituState
    return state ~= nil and state.pos or nil
end

-- SM64CoopDX angle units are 0x10000 per revolution. Prefer its native
-- sine/cosine functions and fall back only in isolated test harnesses.
function Native.sins(angle)
    if has_function("sins") then
        local ok, value = pcall(sins, angle)
        if ok and type(value) == "number" then return value end
    end
    return math.sin((tonumber(angle) or 0) * math.pi / 32768)
end

function Native.coss(angle)
    if has_function("coss") then
        local ok, value = pcall(coss, angle)
        if ok and type(value) == "number" then return value end
    end
    return math.cos((tonumber(angle) or 0) * math.pi / 32768)
end

-- These ray/floor queries execute in the engine's native collision system.
function Native.find_surface_on_ray(start_x, start_y, start_z, dir_x, dir_y, dir_z, precision)
    if not has_function("collision_find_surface_on_ray") then
        return nil, "collision_find_surface_on_ray is unavailable"
    end
    local ok, result = pcall(
        collision_find_surface_on_ray,
        start_x, start_y, start_z,
        dir_x, dir_y, dir_z,
        precision or 2.0
    )
    if not ok then return nil, result end
    return result
end

function Native.find_floor(x, y, z)
    if not has_function("collision_find_floor") then
        return nil, "collision_find_floor is unavailable"
    end
    local ok, result = pcall(collision_find_floor, x, y, z)
    if not ok then return nil, result end
    return result
end

function Native.read_player_physics_state(mario)
    if mario == nil then return nil end
    local velocity = mario.vel
    local position = mario.pos
    return {
        action = tonumber(mario.action) or 0,
        forward_speed = tonumber(mario.forwardVel) or 0,
        velocity_x = velocity and (tonumber(velocity.x) or 0) or 0,
        velocity_y = velocity and (tonumber(velocity.y) or 0) or 0,
        velocity_z = velocity and (tonumber(velocity.z) or 0) or 0,
        position = position,
        floor = mario.floor,
        floor_height = tonumber(mario.floorHeight),
        face_angle = mario.faceAngle,
        controller = mario.controller,
    }
end

function Native.capabilities()
    return {
        host_c_player_physics = true,
        first_person_camera = Native.first_person_api_available(),
        native_surface_ray = has_function("collision_find_surface_on_ray"),
        native_floor_query = has_function("collision_find_floor"),
        native_dynamic_surfaces =
            has_function("smlua_collision_add_surface")
            and has_function("smlua_collision_delete_surface"),
        native_object_collision =
            has_function("hook_behavior")
            and has_function("load_object_collision_model"),
        native_audio =
            has_function("audio_sample_load")
            and has_function("audio_sample_play"),
        custom_c_library_loaded = false,
    }
end

return Native
