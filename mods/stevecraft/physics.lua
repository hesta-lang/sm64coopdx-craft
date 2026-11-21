-- SteveCraft movement adapter.
-- This module observes SM64CoopDX movement state to select Steve's idle/walk
-- animation and drive paced footstep audio. It does not replace Mario physics:
-- gravity, acceleration, friction, collision response and jump impulses remain
-- native SM64CoopDX until a separately validated Minecraft physics port exists.

local Physics = {}
local last_state = nil
local last_step_frame = -100000

local function state_from_mario(mario)
    if mario == nil then return "idle" end
    local action = mario.action or 0
    if type(ACT_FLAG_SWIMMING) == "number" and (action & ACT_FLAG_SWIMMING) ~= 0 then
        return "swim"
    end
    if type(ACT_FLAG_AIR) == "number" and (action & ACT_FLAG_AIR) ~= 0 then
        local vertical_speed = mario.vel and (mario.vel.y or 0) or 0
        if vertical_speed > 0 then return "jump" end
        return "fall"
    end
    if type(ACT_FLAG_MOVING) == "number" and (action & ACT_FLAG_MOVING) ~= 0 then
        return "move"
    end
    return "idle"
end

function Physics.get_state(mario)
    return state_from_mario(mario)
end

function Physics.update(mario, sounds, get_footstep_material)
    local state = state_from_mario(mario)
    if state ~= last_state then
        last_state = state
        print("[SteveCraft] Movement state: " .. state)
    end

    if state ~= "move" or mario == nil or mario.floor == nil then
        return state
    end

    local speed = math.abs(tonumber(mario.forwardVel) or 0)
    if speed < 2 then return state end

    local frame = tonumber(gGlobalTimer) or 0
    local interval = math.max(9, math.min(18, math.floor(19 - speed * 0.45)))
    if frame - last_step_frame >= interval then
        last_step_frame = frame
        local material = type(get_footstep_material) == "function"
            and get_footstep_material(mario)
            or "stone"
        if sounds and type(sounds.play_footstep) == "function" then
            sounds.play_footstep(material, mario.pos, math.min(0.62, 0.38 + speed * 0.012))
        end
    end

    return state
end

function Physics.reset()
    last_state = nil
    last_step_frame = -100000
end

return Physics
