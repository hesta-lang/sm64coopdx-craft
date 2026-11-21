-- SteveCraft movement adapter.
-- The host SM64CoopDX C engine remains authoritative for MarioState physics.
-- Lua reads that native state to select Steve animations and footstep timing.
local Physics = {}
local Native = require("systems/native_engine")
local last_state = nil
local last_step_frame = -100000
local last_position = nil
local last_position_frame = -1

local function state_from_mario(mario)
    local native_state = Native.read_player_physics_state(mario)
    if native_state == nil then return "idle", nil end

    local action = native_state.action
    if type(ACT_FLAG_SWIMMING) == "number" and (action & ACT_FLAG_SWIMMING) ~= 0 then
        return "swim", native_state
    end
    if type(ACT_FLAG_AIR) == "number" and (action & ACT_FLAG_AIR) ~= 0 then
        if native_state.velocity_y > 0 then return "jump", native_state end
        return "fall", native_state
    end
    if type(ACT_FLAG_MOVING) == "number" and (action & ACT_FLAG_MOVING) ~= 0 then
        return "move", native_state
    end
    -- The Android character/controller port can report a movement action
    -- without ACT_FLAG_MOVING. Use the real ground-contact and horizontal
    -- velocity fields as a reliable fallback.
    local velocity_x = native_state.velocity_x or 0
    local velocity_z = native_state.velocity_z or 0
    local horizontal_speed = math.sqrt(velocity_x * velocity_x + velocity_z * velocity_z)
    if native_state.floor ~= nil
        and math.max(math.abs(native_state.forward_speed or 0), horizontal_speed) >= 1.5 then
        return "move", native_state
    end
    return "idle", native_state
end

function Physics.get_state(mario)
    local state = state_from_mario(mario)
    return state
end

function Physics.get_native_state(mario)
    return Native.read_player_physics_state(mario)
end

function Physics.update(mario, sounds, get_footstep_material)
    local state, native_state = state_from_mario(mario)
    local frame = tonumber(gGlobalTimer) or 0
    local moved_distance = 0
    local position = native_state and native_state.position or (mario and mario.pos) or nil
    if position ~= nil and frame ~= last_position_frame then
        if last_position ~= nil then
            local dx = (position.x or 0) - (last_position.x or 0)
            local dz = (position.z or 0) - (last_position.z or 0)
            moved_distance = math.sqrt(dx * dx + dz * dz)
        end
        last_position = { x = position.x or 0, y = position.y or 0, z = position.z or 0 }
        last_position_frame = frame
    end

    -- Final fallback for Android builds whose MarioState floor pointer and
    -- ACT_FLAG_MOVING are not populated consistently: detect real horizontal
    -- player displacement while not in an airborne or swimming action.
    local action = native_state and native_state.action or 0
    local airborne = type(ACT_FLAG_AIR) == "number" and (action & ACT_FLAG_AIR) ~= 0
    local swimming = type(ACT_FLAG_SWIMMING) == "number" and (action & ACT_FLAG_SWIMMING) ~= 0
    if state == "idle" and not airborne and not swimming and moved_distance >= 0.35 then
        state = "move"
    end

    if state ~= last_state then
        last_state = state
        print("[SteveCraft] Movement state: " .. state)
    end

    if state ~= "move" or native_state == nil then
        return state
    end

    local vx = native_state.velocity_x or 0
    local vz = native_state.velocity_z or 0
    local planar_speed = math.sqrt(vx * vx + vz * vz)
    local displacement_speed = moved_distance * 30
    local speed = math.max(math.abs(native_state.forward_speed or 0), planar_speed, displacement_speed)
    if speed < 1.5 then return state end
    local interval = math.max(8, math.min(16, math.floor(17 - speed * 0.4)))
    if frame - last_step_frame >= interval then
        last_step_frame = frame
        local material = type(get_footstep_material) == "function"
            and get_footstep_material(mario)
            or "stone"
        if sounds and type(sounds.play_footstep) == "function" then
            sounds.play_footstep(material, native_state.position, math.min(1.0, 0.78 + speed * 0.018))
        end
    end

    return state
end

function Physics.reset()
    last_state = nil
    last_step_frame = -100000
    last_position = nil
    last_position_frame = -1
end

function Physics.native_capabilities()
    return Native.capabilities()
end

return Physics
