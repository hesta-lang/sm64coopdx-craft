-- SteveCraft first-person camera adapter and voxel ray utilities.
-- The view itself is provided by SM64CoopDX's native first-person camera.

local Camera = {}
local Native = require("systems/native_engine")
local initialized = false
local warning_shown = false
local last_health = nil

function Camera.ensure(mario)
    if not Native.first_person_api_available() then
        if not warning_shown then
            print("[SteveCraft] WARNING: first-person camera APIs are unavailable in this build.")
            warning_shown = true
        end
        return false
    end

    local camera = Native.get_first_person_camera()
    if not initialized then
        Native.reset_first_person()
        camera = Native.get_first_person_camera()
        if camera ~= nil then
            local facing = mario and mario.faceAngle and mario.faceAngle.y or 0
            camera.yaw = facing + 0x8000
            camera.pitch = 0
            camera.centerL = false
            camera.forcePitch = false
            camera.forceYaw = false
            camera.forceRoll = true
            camera.fov = 70
        end
        local ok, err = Native.set_first_person_enabled(true)
        if not ok then
            print("[SteveCraft] ERROR: couldn't enable first-person camera: " .. tostring(err))
            return false
        end
        initialized = true
        print("[SteveCraft] SM64CoopDX native first-person camera enabled.")
    elseif camera ~= nil then
        camera.centerL = false
        if camera.enabled ~= true then
            Native.set_first_person_enabled(true)
        end
    end
    return true
end

function Camera.is_active()
    return Native.is_first_person_enabled()
end

function Camera.get_ray(mario)
    local camera = Native.get_first_person_camera()
    if camera == nil or type(camera.yaw) ~= "number" or type(camera.pitch) ~= "number" then
        return nil
    end

    local origin = Native.get_lakitu_position()
    if origin == nil then
        if mario == nil or mario.pos == nil then return nil end
        origin = { x = mario.pos.x, y = (mario.pos.y or 0) + 120, z = mario.pos.z }
    end

    local yaw_sin = Native.sins(camera.yaw)
    local yaw_cos = Native.coss(camera.yaw)
    local pitch_sin = Native.sins(camera.pitch)
    local pitch_cos = Native.coss(camera.pitch)

    return origin, {
        x = -pitch_cos * yaw_sin,
        y = -pitch_sin,
        z = -pitch_cos * yaw_cos,
    }
end

local function make_cell_key(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

function Camera.trace_voxel_ray(origin, direction, max_distance, blocks, cell_size)
    if origin == nil or direction == nil then return nil end
    cell_size = cell_size or 90
    max_distance = max_distance or (cell_size * 6)
    blocks = blocks or {}

    local x = math.floor((origin.x or 0) / cell_size)
    local y = math.floor((origin.y or 0) / cell_size)
    local z = math.floor((origin.z or 0) / cell_size)
    local previous_x, previous_y, previous_z = nil, nil, nil

    local function axis_parameters(origin_value, cell, direction_value)
        if math.abs(direction_value) < 0.000001 then
            return math.huge, math.huge, 0
        end
        local step = direction_value > 0 and 1 or -1
        local boundary = direction_value > 0 and ((cell + 1) * cell_size) or (cell * cell_size)
        return (boundary - origin_value) / direction_value,
            cell_size / math.abs(direction_value), step
    end

    local max_x, delta_x, step_x = axis_parameters(origin.x or 0, x, direction.x or 0)
    local max_y, delta_y, step_y = axis_parameters(origin.y or 0, y, direction.y or 0)
    local max_z, delta_z, step_z = axis_parameters(origin.z or 0, z, direction.z or 0)

    for _ = 1, 64 do
        if blocks[make_cell_key(x, y, z)] ~= nil then
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

function Camera.get_world_surface_hit(origin, direction, reach)
    if origin == nil or direction == nil then return nil end
    reach = reach or 540
    local result = Native.find_surface_on_ray(
        origin.x, origin.y, origin.z,
        direction.x * reach, direction.y * reach, direction.z * reach,
        2.0
    )
    if result == nil or result.surface == nil or result.hitPos == nil then return nil end
    return result
end

function Camera.health_to_half_hearts(health)
    local minimum, maximum = 0x00FF, 0x0880
    health = tonumber(health) or minimum
    local fraction = (health - minimum) / (maximum - minimum)
    fraction = math.max(0, math.min(1, fraction))
    return math.max(0, math.min(20, math.floor(fraction * 20 + 0.5)))
end

function Camera.update_health(mario)
    if mario == nil or mario.playerIndex ~= 0 or type(mario.health) ~= "number" then return end
    local health = mario.health
    if last_health ~= nil and health < last_health then
        local damage = last_health - health
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
    last_health = health
end

function Camera.reset()
    initialized = false
    warning_shown = false
    last_health = nil
end

return Camera
