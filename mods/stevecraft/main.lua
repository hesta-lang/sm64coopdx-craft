-- name: SteveCraft - Mario Proxy / Steve Renderer
-- description: Standalone model assignment following the verified DynOS/Lua loading path.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.2.4-alpha"
local STEVE_GEO_NAME = "mario_geo"

local sModelId = nil
local sModelLoadAttempted = false
local sModelAppliedObject = nil
local sWarned = false
local sVerifyWarned = false
local sLastSteveState = nil

local sAnimationsRegistered = false
local sCurrentSteveAnimation = nil
local STEVE_ANIMATION_FRAMES = 24
local STEVE_ANIMATION_PARTS = 20
local STEVE_ANIM_IDLE = "stevecraft_idle"
local STEVE_ANIM_WALK = "stevecraft_walk"

-- These zero-based channel indices follow MarioAnimPart in include/types.h.
-- The original mario_geo has exactly 20 GEO_ANIMATED_PART nodes in this traversal order.
local STEVE_PART = {
    TORSO = 2,
    HEAD = 3,
    LEFT_ARM = 5,
    LEFT_FOREARM = 6,
    RIGHT_ARM = 9,
    RIGHT_FOREARM = 10,
    LEFT_THIGH = 13,
    LEFT_LEG = 14,
    RIGHT_THIGH = 17,
    RIGHT_LEG = 18,
}

local function round_animation_value(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function steve_animation_value(kind, part, axis, frame)
    local phase = (frame / STEVE_ANIMATION_FRAMES) * (math.pi * 2)
    local wave = math.sin(phase)

    if kind == "idle" then
        if axis == 1 and part == STEVE_PART.TORSO then
            return round_animation_value(wave * 96) -- ~0.53 degrees
        end
        if axis == 1 and part == STEVE_PART.HEAD then
            return round_animation_value(wave * -32)
        end
        return 0
    end

    if kind == "walk" and axis == 1 then
        local swing = wave * 5461 -- ~30 degrees in SM64's 16-bit angle units
        if part == STEVE_PART.LEFT_ARM then return round_animation_value(swing) end
        if part == STEVE_PART.RIGHT_ARM then return round_animation_value(-swing) end
        if part == STEVE_PART.LEFT_THIGH then return round_animation_value(-swing) end
        if part == STEVE_PART.RIGHT_THIGH then return round_animation_value(swing) end

        -- Subtle elbow bend layered over the opposing Minecraft-style swing.
        if part == STEVE_PART.LEFT_FOREARM then
            return round_animation_value(math.max(0, wave) * 900)
        end
        if part == STEVE_PART.RIGHT_FOREARM then
            return round_animation_value(math.max(0, -wave) * 900)
        end
    end

    return 0
end

local function build_steve_animation(kind)
    local values = {}
    local index = {}

    -- ANIM_FLAG_6 (0x40) tells the renderer to skip the reserved root translation.
    -- The index format still requires three [frameCount, valueOffset] pairs here.
    for _ = 1, 3 do
        index[#index + 1] = STEVE_ANIMATION_FRAMES
        index[#index + 1] = 0
    end

    -- Each GEO_ANIMATED_PART consumes X/Y/Z rotation channels in traversal order.
    for part = 0, STEVE_ANIMATION_PARTS - 1 do
        for axis = 1, 3 do
            local valueOffset = #values
            index[#index + 1] = STEVE_ANIMATION_FRAMES
            index[#index + 1] = valueOffset

            for frame = 0, STEVE_ANIMATION_FRAMES - 1 do
                values[#values + 1] = steve_animation_value(kind, part, axis, frame)
            end
        end
    end

    return values, index
end

local function register_steve_animations()
    if sAnimationsRegistered then return true end
    if type(smlua_anim_util_register_animation) ~= "function" then
        print("[SteveCraft] WARNING: custom animation registration API unavailable.")
        return false
    end

    local definitions = {
        { kind = "idle", name = STEVE_ANIM_IDLE },
        { kind = "walk", name = STEVE_ANIM_WALK },
    }

    for _, definition in ipairs(definitions) do
        local values, index = build_steve_animation(definition.kind)
        local expectedIndexLength = 6 + (STEVE_ANIMATION_PARTS * 3 * 2)
        if #index ~= expectedIndexLength
            or #values ~= STEVE_ANIMATION_PARTS * 3 * STEVE_ANIMATION_FRAMES then
            print("[SteveCraft] ERROR: generated animation channel count is invalid for " .. definition.name)
            return false
        end

        local ok, err = pcall(
            smlua_anim_util_register_animation,
            definition.name,
            0x40, -- ANIM_FLAG_6: no root translation; rotate animated parts only
            0,    -- animYTransDivisor
            0,    -- startFrame
            0,    -- loopStart
            STEVE_ANIMATION_FRAMES,
            values,
            index
        )
        if not ok then
            print("[SteveCraft] ERROR: animation registration failed for " .. definition.name .. ": " .. tostring(err))
            return false
        end
        print("[SteveCraft] Registered " .. definition.name .. " (" .. #values .. " values, " .. #index .. " index entries).")
    end

    sAnimationsRegistered = true
    return true
end

local function apply_steve_animation(m, state)
    if not sAnimationsRegistered or m.marioObj == nil then return end
    if type(smlua_anim_util_set_animation) ~= "function" then return end

    local target = state == "move" and STEVE_ANIM_WALK or STEVE_ANIM_IDLE
    if target == sCurrentSteveAnimation then return end

    local ok, err = pcall(smlua_anim_util_set_animation, m.marioObj, target)
    if not ok then
        print("[SteveCraft] ERROR: unable to select " .. target .. ": " .. tostring(err))
        return
    end

    sCurrentSteveAnimation = target
    print("[SteveCraft] Animation selected: " .. target)
end

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
    return state
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
    local state = update_steve_controller(m)
    if m.marioObj == nil then return end

    local modelId = load_steve_model()
    if modelId == nil then return end
    if sModelAppliedObject == m.marioObj then
        apply_steve_animation(m, state)
        return
    end

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
    if register_steve_animations() then
        sCurrentSteveAnimation = nil
        apply_steve_animation(m, state)
    end
    if currentId == modelId then
        print("[SteveCraft] Steve model assigned and verified on the existing marioObj.")
    else
        print("[SteveCraft] Steve model assigned; read-back verification is unavailable on this build.")
    end
end

local function on_warp()
    sModelAppliedObject = nil
    sLastSteveState = nil
    sCurrentSteveAnimation = nil
end


-- The CI harness exposes the pure generator only when explicitly requested.
if rawget(_G, "__STEVECRAFT_TEST") ~= nil then
    __STEVECRAFT_TEST.build_animation = build_steve_animation
    __STEVECRAFT_TEST.animation_value = steve_animation_value
    __STEVECRAFT_TEST.constants = {
        frames = STEVE_ANIMATION_FRAMES,
        parts = STEVE_ANIMATION_PARTS,
        expected_index_length = 6 + (STEVE_ANIMATION_PARTS * 3 * 2),
    }
    return
end

-- Native SM64CoopDX movement and collision remain enabled; no second actor is created.
hook_event(HOOK_MARIO_UPDATE, apply_steve_to_mario)
hook_event(HOOK_ON_WARP, on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
