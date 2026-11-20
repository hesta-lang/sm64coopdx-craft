-- name: SteveCraft - Independent Player
-- description: Adds an independent Steve render object with Mario retained as the invisible SM64 player proxy.
-- incompatible: none
-- pausable: true

local STEVECRAFT_VERSION = "0.1.0-alpha"
local STEVE_GEO_NAME = "steve_geo"

local sModelId = nil
local sModelLoadAttempted = false
local sModelWarningShown = false
local sPlayers = {}

local function get_player_state(playerIndex)
    if sPlayers[playerIndex] == nil then
        sPlayers[playerIndex] = {
            visual = nil,
            proxyObject = nil,
            originalInvisible = false,
            ownsHiddenFlag = false,
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
        print("[SteveCraft] Missing actors/steve_geo.bin; keeping the vanilla player visible.")
        sModelWarningShown = true
    end
    return nil
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

    -- Mario remains a normal player object for collision, interactions,
    -- damage, moving platforms and network/player bookkeeping.
    -- Only its rendered mesh is hidden after Steve was spawned successfully.
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
        m.pos.x, m.pos.y, m.pos.z,
        function(object)
            object.oFlags = object.oFlags | OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
            object.oFaceAngleYaw = m.faceAngle.y
            object.oMoveAngleYaw = m.faceAngle.y
            object.oOpacity = 255
        end
    )

    if visual ~= nil then
        state.visual = visual
    end
    return visual
end

local function update_steve_visual(m, visual)
    -- The MarioState is the engine compatibility proxy. Steve is rendered
    -- by a different Object and has its own model/animation namespace.
    -- Both use the same transform so there is no second physics authority.
    visual.oPosX = m.pos.x
    visual.oPosY = m.pos.y
    visual.oPosZ = m.pos.z
    visual.oFaceAnglePitch = m.faceAngle.x
    visual.oFaceAngleYaw = m.faceAngle.y
    visual.oFaceAngleRoll = m.faceAngle.z
    visual.oMoveAngleYaw = m.faceAngle.y
    visual.oVelX = m.vel.x
    visual.oVelY = m.vel.y
    visual.oVelZ = m.vel.z
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
    local visual = spawn_steve_visual(m, state, modelId)
    if visual == nil then
        return
    end

    update_steve_visual(m, visual)
    hide_mario_proxy(m, state)
end

local function stevecraft_object_unloaded(object)
    for _, state in pairs(sPlayers) do
        if state.visual == object then
            state.visual = nil
        end
        if state.proxyObject == object then
            state.proxyObject = nil
            state.ownsHiddenFlag = false
        end
    end
end

local function stevecraft_on_warp()
    -- Object pointers from the old area must not be reused after a warp.
    for _, state in pairs(sPlayers) do
        state.visual = nil
        state.proxyObject = nil
        state.ownsHiddenFlag = false
    end
end

hook_event(HOOK_MARIO_UPDATE, stevecraft_update_player)
hook_event(HOOK_ON_OBJECT_UNLOAD, stevecraft_object_unloaded)
hook_event(HOOK_ON_WARP, stevecraft_on_warp)

print("[SteveCraft] Standalone mod loaded (" .. STEVECRAFT_VERSION .. ").")
