-- name: SteveCraft - Independent Player
-- description: Runs a separate Steve controller and render object while Mario remains the engine compatibility proxy.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.1.0-alpha"
local STEVE_GEO_NAME = "steve_geo"

-- These values are an initial SM64-unit controller profile, not final
-- Minecraft constants. The exact scale will be calibrated with Steve's model.
local STEVE_MAX_SPEED = 18.0
local STEVE_GROUND_ACCEL = 0.30
local STEVE_AIR_ACCEL = 0.08
local STEVE_GROUND_FRICTION = 0.58
local STEVE_AIR_FRICTION = 0.995
local STEVE_GRAVITY = 2.5
local STEVE_JUMP_SPEED = 42.0
local STEVE_TERMINAL_VELOCITY = -75.0
local STEVE_WALL_RADIUS = 24.0
local STEVE_WALL_LOWER_OFFSET = 30.0
local STEVE_WALL_UPPER_OFFSET = 60.0
local STEVE_STEP_HEIGHT = 20.0

local sModelId = nil
local sModelLoadAttempted = false
local sModelWarningShown = false
local sPlayers = {}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function get_player_state(playerIndex)
    if sPlayers[playerIndex] == nil then
        sPlayers[playerIndex] = {
            visual = nil,
            proxyObject = nil,
            originalInvisible = false,
            ownsHiddenFlag = false,
            initialized = false,
            position = { x = 0.0, y = 0.0, z = 0.0 },
            velocity = { x = 0.0, y = 0.0, z = 0.0 },
            yaw = 0,
            onGround = false,
            lastPhysicsFrame = -1,
            lastStepType = -1,
            lastStepResult = 0,
        }
    end
    return sPlayers[playerIndex]
end

local function load_steve_model()
    if sModelLoadAttempted then
        return sModelId
    end

    sModelLoadAttempted = true
    local ok, modelId = pcall(smlua_model_util_get_id, STEVE_GEO_NAME)
    if ok and type(modelId) == "number" and modelId > 0 then
        sModelId = modelId
        return sModelId
    end

    if not sModelWarningShown then
        print("[SteveCraft] Missing actors/steve_geo.bin; keeping the vanilla player visible and vanilla physics active.")
        sModelWarningShown = true
    end
    return nil
end

local function initialize_steve_state(m, state)
    if state.initialized and state.proxyObject == m.marioObj then
        return
    end

    state.position.x = m.pos.x
    state.position.y = m.pos.y
    state.position.z = m.pos.z
    state.velocity.x = m.vel.x
    state.velocity.y = m.vel.y
    state.velocity.z = m.vel.z
    state.yaw = m.faceAngle.y
    state.onGround = m.floor ~= nil and m.pos.y <= m.floorHeight + 2.0
    state.proxyObject = m.marioObj
    state.initialized = true
    state.lastPhysicsFrame = -1
end

local function hide_mario_proxy(m, state)
    if m == nil or m.marioObj == nil or m.marioObj.header == nil then
        return false
    end

    local gfx = m.marioObj.header.gfx
    if gfx == nil or gfx.node == nil then
        return false
    end

    if not state.ownsHiddenFlag then
        state.originalInvisible = (gfx.node.flags & GRAPH_RENDER_INVISIBLE) ~= 0
        state.ownsHiddenFlag = true
        state.proxyObject = m.marioObj
    end

    -- Mario remains the real SM64 player identity for interactions, damage,
    -- platforms and engine bookkeeping. Only his mesh is hidden.
    gfx.node.flags = gfx.node.flags | GRAPH_RENDER_INVISIBLE
    m.visibleToObjects = true
    return true
end

local function restore_mario_proxy(state)
    if not state.ownsHiddenFlag or state.proxyObject == nil then
        return
    end

    local object = state.proxyObject
    if object.header ~= nil and object.header.gfx ~= nil and object.header.gfx.node ~= nil then
        local flags = object.header.gfx.node.flags
        if state.originalInvisible then
            flags = flags | GRAPH_RENDER_INVISIBLE
        else
            flags = flags & (~GRAPH_RENDER_INVISIBLE)
        end
        object.header.gfx.node.flags = flags
    end

    state.ownsHiddenFlag = false
    state.proxyObject = nil
end

local function spawn_steve_visual(m, state, modelId)
    if state.visual ~= nil then
        return state.visual
    end

    local visual = spawn_non_sync_object(
        id_bhvStaticObject,
        modelId,
        state.position.x, state.position.y, state.position.z,
        function(object)
            object.oFlags = object.oFlags | OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
            object.oFaceAngleYaw = state.yaw
            object.oMoveAngleYaw = state.yaw
            object.oOpacity = 255
        end
    )

    if visual ~= nil then
        state.visual = visual
    end
    return visual
end

local function update_steve_visual(state)
    local visual = state.visual
    if visual == nil then
        return
    end

    visual.oPosX = state.position.x
    visual.oPosY = state.position.y
    visual.oPosZ = state.position.z
    visual.oFaceAngleYaw = state.yaw
    visual.oMoveAngleYaw = state.yaw
    visual.oVelX = state.velocity.x
    visual.oVelY = state.velocity.y
    visual.oVelZ = state.velocity.z
end

local function write_steve_to_mario_proxy(m, state, floorHeight, floor, wall)
    -- Steve owns the position and velocity. This function mirrors them into
    -- MarioState and its render/collision object so SM64 still sees one player.
    m.pos.x = state.position.x
    m.pos.y = state.position.y
    m.pos.z = state.position.z
    m.nonInstantWarpPos.x = state.position.x
    m.nonInstantWarpPos.y = state.position.y
    m.nonInstantWarpPos.z = state.position.z

    m.vel.x = state.velocity.x
    m.vel.y = state.velocity.y
    m.vel.z = state.velocity.z
    m.faceAngle.y = state.yaw
    m.intendedYaw = state.yaw
    m.forwardVel = math.sqrt(state.velocity.x * state.velocity.x + state.velocity.z * state.velocity.z)
    m.slideVelX = state.velocity.x
    m.slideVelZ = state.velocity.z
    m.floorHeight = floorHeight
    m.floor = floor
    if wall ~= nil then
        m.wall = wall
    end
    m.visibleToObjects = true

    local object = m.marioObj
    if object ~= nil then
        object.oPosX = state.position.x
        object.oPosY = state.position.y
        object.oPosZ = state.position.z
        object.oVelX = state.velocity.x
        object.oVelY = state.velocity.y
        object.oVelZ = state.velocity.z
        object.oFaceAngleYaw = state.yaw

        local gfx = object.header.gfx
        if gfx ~= nil then
            gfx.pos.x = state.position.x
            gfx.pos.y = state.position.y
            gfx.pos.z = state.position.z
            gfx.angle.y = state.yaw
        end
    end
end

local function stevecraft_physics(m, stepType, stepArg)
    if m == nil or m.playerIndex ~= 0 or m.marioObj == nil then
        return nil
    end
    if stepType ~= STEP_TYPE_GROUND and stepType ~= STEP_TYPE_AIR then
        return nil
    end

    local state = get_player_state(m.playerIndex)
    if state.visual == nil or not state.initialized then
        return nil
    end
    if m.freeze ~= 0 or (m.action & ACT_FLAG_INTANGIBLE) ~= 0 then
        return nil
    end

    -- Some Mario actions can request more than one physics pass in a frame.
    -- Steve integrates once; repeated calls reuse the previous result.
    if state.lastPhysicsFrame == gGlobalTimer then
        return state.lastStepResult
    end
    state.lastPhysicsFrame = gGlobalTimer

    local wasGrounded = state.onGround
    local inputStrength = clamp(m.controller.stickMag / 64.0, 0.0, 1.0)
    if inputStrength > 0.05 then
        local targetSpeed = STEVE_MAX_SPEED * inputStrength
        local targetX = sins(m.intendedYaw) * targetSpeed
        local targetZ = coss(m.intendedYaw) * targetSpeed
        local acceleration = wasGrounded and STEVE_GROUND_ACCEL or STEVE_AIR_ACCEL
        state.velocity.x = state.velocity.x + (targetX - state.velocity.x) * acceleration
        state.velocity.z = state.velocity.z + (targetZ - state.velocity.z) * acceleration
        state.yaw = m.intendedYaw
    else
        local friction = wasGrounded and STEVE_GROUND_FRICTION or STEVE_AIR_FRICTION
        state.velocity.x = state.velocity.x * friction
        state.velocity.z = state.velocity.z * friction
    end

    if wasGrounded and (m.controller.buttonPressed & A_BUTTON) ~= 0 then
        state.velocity.y = STEVE_JUMP_SPEED
        state.onGround = false
        if (m.action & ACT_FLAG_AIR) == 0 then
            set_mario_action(m, ACT_JUMP, 0)
        end
    elseif not wasGrounded then
        state.velocity.y = math.max(state.velocity.y - STEVE_GRAVITY, STEVE_TERMINAL_VELOCITY)
    else
        state.velocity.y = 0.0
    end

    local oldY = state.position.y
    local requested = {
        x = state.position.x + state.velocity.x,
        y = state.position.y + state.velocity.y,
        z = state.position.z + state.velocity.z,
    }

    -- Reuse SM64's collision world as the compatibility layer. Steve's
    -- controller chooses velocity; these queries only resolve the proxy.
    local beforeWallX = requested.x
    local beforeWallZ = requested.z
    local lowerWall = resolve_and_return_wall_collisions(
        requested, STEVE_WALL_LOWER_OFFSET, STEVE_WALL_RADIUS
    )
    local upperWall = resolve_and_return_wall_collisions(
        requested, STEVE_WALL_UPPER_OFFSET, STEVE_WALL_RADIUS
    )
    local wall = upperWall or lowerWall

    if math.abs(requested.x - beforeWallX) > 0.01 then
        state.velocity.x = 0.0
    end
    if math.abs(requested.z - beforeWallZ) > 0.01 then
        state.velocity.z = 0.0
    end

    local floorHeight, floor = find_floor(requested.x, requested.y + 100.0, requested.z)
    local grounded = false
    local result = stepType == STEP_TYPE_AIR and AIR_STEP_NONE or GROUND_STEP_NONE

    if floor ~= nil and state.velocity.y <= 0.0 then
        local nearStep = wasGrounded and math.abs(floorHeight - oldY) <= STEVE_STEP_HEIGHT
        local fallingOntoFloor = requested.y <= floorHeight
        if nearStep or fallingOntoFloor then
            requested.y = floorHeight
            state.velocity.y = 0.0
            grounded = true
        end
    end

    if stepType == STEP_TYPE_GROUND and not grounded then
        result = GROUND_STEP_LEFT_GROUND
    elseif stepType == STEP_TYPE_AIR and grounded then
        result = AIR_STEP_LANDED
    elseif wall ~= nil and stepType == STEP_TYPE_AIR then
        result = AIR_STEP_HIT_WALL
    elseif wall ~= nil and stepType == STEP_TYPE_GROUND then
        result = GROUND_STEP_HIT_WALL
    end

    state.position.x = requested.x
    state.position.y = requested.y
    state.position.z = requested.z
    state.onGround = grounded
    state.lastStepType = stepType
    state.lastStepResult = result

    write_steve_to_mario_proxy(m, state, floorHeight, floor, wall)
    update_steve_visual(state)
    return result
end

local function stevecraft_update_player(m)
    if m == nil or m.playerIndex ~= 0 or m.marioObj == nil then
        return
    end

    local modelId = load_steve_model()
    if modelId == nil then
        return
    end

    local state = get_player_state(m.playerIndex)
    initialize_steve_state(m, state)

    local visual = spawn_steve_visual(m, state, modelId)
    if visual == nil then
        return
    end

    update_steve_visual(state)
    hide_mario_proxy(m, state)
end

local function stevecraft_object_unloaded(object)
    for _, state in pairs(sPlayers) do
        if state.visual == object then
            state.visual = nil
            restore_mario_proxy(state)
        end
        if state.proxyObject == object then
            state.proxyObject = nil
            state.ownsHiddenFlag = false
            state.initialized = false
        end
    end
end

local function stevecraft_on_warp()
    -- The old area's objects are about to be discarded. Re-seed Steve's
    -- independent transform from the newly spawned Mario proxy next time.
    for _, state in pairs(sPlayers) do
        state.visual = nil
        state.proxyObject = nil
        state.ownsHiddenFlag = false
        state.initialized = false
        state.lastPhysicsFrame = -1
    end
end

hook_event(HOOK_BEFORE_PHYS_STEP, stevecraft_physics)
hook_event(HOOK_MARIO_UPDATE, stevecraft_update_player)
hook_event(HOOK_ON_OBJECT_UNLOAD, stevecraft_object_unloaded)
hook_event(HOOK_ON_WARP, stevecraft_on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
