-- SteveCraft movement adapter.
-- The host SM64CoopDX C engine remains authoritative for MarioState physics.
-- Lua reads that native state to select Steve animations and footstep timing.
local Physics = {}
local Native = require("systems/native_engine")
local last_state = nil
local last_step_frame = -100000

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
    if state ~= last_state then
        last_state = state
        print("[SteveCraft] Movement state: " .. state)
    end

    if state ~= "move" or native_state == nil or native_state.floor == nil then
        return state
    end

    local vx = native_state.velocity_x or 0
    local vz = native_state.velocity_z or 0
    local planar_speed = math.sqrt(vx * vx + vz * vz)
    local speed = math.max(math.abs(native_state.forward_speed or 0), planar_speed)
    if speed < 1.5 then return state end

    local frame = tonumber(gGlobalTimer) or 0
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
end

function Physics.native_capabilities()
    return Native.capabilities()
end

return Physics
