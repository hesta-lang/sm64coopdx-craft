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

    local speed = math.abs(native_state.forward_speed)
    if speed < 2 then return state end

    local frame = tonumber(gGlobalTimer) or 0
    local interval = math.max(9, math.min(18, math.floor(19 - speed * 0.45)))
    if frame - last_step_frame >= interval then
        last_step_frame = frame
        local material = type(get_footstep_material) == "function"
            and get_footstep_material(mario)
            or "stone"
        if sounds and type(sounds.play_footstep) == "function" then
            sounds.play_footstep(material, native_state.position, math.min(0.62, 0.38 + speed * 0.012))
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
