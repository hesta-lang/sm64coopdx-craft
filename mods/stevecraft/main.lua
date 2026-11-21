-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone visual test with a Bedrock-inspired movement-state controller.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.2.2-alpha"
local STEVE_GEO_NAME = "mario_geo"

local sModelId = nil
local sModelLoadAttempted = false
local sModelAppliedObject = nil
local sWarned = false
local sLastSteveState = nil

-- Bedrock-inspired animation-controller pattern: observe conditions, select a state,
-- and react only when the state changes. This does not alter gameplay physics.
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
end

local function load_steve_model()
    if sModelLoadAttempted then return sModelId end
    sModelLoadAttempted = true
    if type(smlua_model_util_get_id) ~= "function" then
        print("[SteveCraft] ERROR: smlua_model_util_get_id API unavailable.")
        return nil
    end
    local ok, modelId = pcall(smlua_model_util_get_id, STEVE_GEO_NAME)
    if not ok then
        print("[SteveCraft] ERROR: model lookup raised an error: " .. tostring(modelId))
        return nil
    end
    if type(modelId) ~= 'number' or modelId == E_MODEL_ERROR_MODEL then
        print("[SteveCraft] ERROR: DynOS GeoLayout " .. STEVE_GEO_NAME .. " was not found.")
        return nil
    end
    sModelId = modelId
    print("[SteveCraft] DynOS GeoLayout found; extended model id=" .. tostring(modelId))
    return sModelId
end

local function apply_steve_to_mario(m)
    if m == nil or m.playerIndex ~= 0 then return end
    update_steve_controller(m)
    if m.marioObj == nil then return end
    local modelId = load_steve_model()
    if modelId == nil then return end
    if sModelAppliedObject == m.marioObj then return end
    local ok, result = pcall(obj_set_model_extended, m.marioObj, modelId)
    if not ok or result == false then
        if not sWarned then
            print("[SteveCraft] ERROR: obj_set_model_extended failed: " .. tostring(result))
            sWarned = true
        end
        return
    end
    sModelAppliedObject = m.marioObj
    print("[SteveCraft] Steve GeoLayout assigned to Mario existing player object.")
end

local function on_warp()
    sModelAppliedObject = nil
    sLastSteveState = nil
end

-- Native SM64CoopDX movement remains enabled in this validation stage.
hook_event(HOOK_MARIO_UPDATE, apply_steve_to_mario)
hook_event(HOOK_ON_WARP, on_warp)
-- Build metadata: 0.2.2-alpha; this controller is observational only.
print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
