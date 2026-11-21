-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone model assignment following the verified DynOS/Lua loading path.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.2.3-alpha"
local STEVE_GEO_NAME = "mario_geo"

local sModelId = nil
local sModelLoadAttempted = false
local sModelAppliedObject = nil
local sWarned = false
local sVerifyWarned = false
local sLastSteveState = nil

-- Bedrock-inspired animation-controller pattern: observe conditions and select a state.
-- This controller is observational; it does not replace movement or play bone animations yet.
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

-- The name passed to the API is a GeoLayout symbol, not the .bin filename.
local function load_steve_model()
    if sModelLoadAttempted then return sModelId end
    sModelLoadAttempted = true

    if type(smlua_model_util_get_id) ~= "function" then
        print("[SteveCraft] ERROR: smlua_model_util_get_id API unavailable.")
        return nil
    end

    local ok, modelId = pcall(smlua_model_util_get_id, STEVE_GEO_NAME)
    if not ok then
        print("[SteveCraft] ERROR: GeoLayout lookup raised an error: " .. tostring(modelId))
        return nil
    end

    if type(modelId) ~= "number" or modelId == E_MODEL_ERROR_MODEL then
        print('[SteveCraft] ERROR: DynOS could not resolve GeoLayout symbol "' .. STEVE_GEO_NAME .. '".')
        print("[SteveCraft] Check actor registration and the internal GeoLayout name in the .geo.bin.")
        return nil
    end

    sModelId = modelId
    print("[SteveCraft] GeoLayout resolved to extended model id=" .. tostring(modelId))
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
    update_steve_controller(m)
    if m.marioObj == nil then return end

    local modelId = load_steve_model()
    if modelId == nil then return end
    if sModelAppliedObject == m.marioObj then return end

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
    if currentId == modelId then
        print("[SteveCraft] Steve model assigned and verified on the existing marioObj.")
    else
        print("[SteveCraft] Steve model assigned; read-back verification is unavailable on this build.")
    end
end

local function on_warp()
    sModelAppliedObject = nil
    sLastSteveState = nil
end

-- Native SM64CoopDX movement and collision remain enabled; no second actor is created.
hook_event(HOOK_MARIO_UPDATE, apply_steve_to_mario)
hook_event(HOOK_ON_WARP, on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
