-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone visual actor test. Keeps vanilla Mario movement stable while validating the supplied DynOS model.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.2.1-alpha"
-- DynOS resolves the GeoLayout symbol stored inside the supplied binary.
-- The uploaded file is minecraft_steve_geo.bin; its internal symbol is mario_geo.
local STEVE_GEO_NAME = "mario_geo"

local sModelId = nil
local sModelLoadAttempted = false
local sModelAppliedObject = nil
local sWarned = false

local function load_steve_model()
    if sModelLoadAttempted then
        return sModelId
    end
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
    if type(modelId) ~= "number" or modelId == E_MODEL_ERROR_MODEL then
        print("[SteveCraft] ERROR: DynOS GeoLayout '" .. STEVE_GEO_NAME .. "' was not found.")
        return nil
    end

    sModelId = modelId
    print("[SteveCraft] DynOS GeoLayout found; extended model id=" .. tostring(modelId))
    return sModelId
end

local function apply_steve_to_mario(m)
    if m == nil or m.playerIndex ~= 0 or m.marioObj == nil then
        return
    end

    local modelId = load_steve_model()
    if modelId == nil then
        return
    end

    if sModelAppliedObject == m.marioObj then
        return
    end

    local ok, result = pcall(obj_set_model_extended, m.marioObj, modelId)
    if not ok or result == false then
        if not sWarned then
            print("[SteveCraft] ERROR: obj_set_model_extended failed: " .. tostring(result))
            sWarned = true
        end
        return
    end

    sModelAppliedObject = m.marioObj
    print("[SteveCraft] Steve GeoLayout assigned to Mario's existing player object.")
end

local function on_warp()
    sModelAppliedObject = nil
end

-- This diagnostic build deliberately does NOT override HOOK_BEFORE_PHYS_STEP.
-- Mario remains the sole engine proxy and retains vanilla position, collision,
-- action and network updates until the model is confirmed visible.
hook_event(HOOK_MARIO_UPDATE, apply_steve_to_mario)
hook_event(HOOK_ON_WARP, on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
