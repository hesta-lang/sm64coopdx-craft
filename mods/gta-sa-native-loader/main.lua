-- name: GTA SA Native DFF + IFP Test
-- description: Loads the original GTA SA player DFF/TXD and tests IFP animation playback.
-- version: 0.2.0-alpha

-- Put your own original GTA SA archives in the app-specific external folder.
-- This folder is accessible to this app without requesting broad storage access.
local GTA_ROOT = "/storage/emulated/0/Android/data/com.maniscat2.sm64coopdx/files/GTA_SA"
local PLAYER_IMG = GTA_ROOT .. "/models/player.img"
local ANIM_IMG = GTA_ROOT .. "/anim/anim.img"

local PLAYER_DFF = "player.dff"
local PLAYER_TXD = "player.txd"
local PED_IFP = "ped.ifp"
local MODEL_SCALE = 100.0
local MODEL_OFFSET = 180.0

local gtaModelId = nil
local gtaObject = nil
local gtaLoadAttempted = false
local gtaAnimationActive = false
local gtaSpawnFailureLogged = false

local function gta_log(message)
    print("[GTA SA TEST] " .. tostring(message))
end

local function find_test_animation(animations)
    local firstAnimation = nil

    for _, animation in ipairs(animations) do
        if firstAnimation == nil then
            firstAnimation = animation
        end

        local name = string.upper(animation.name or "")
        if name == "IDLE" or string.find(name, "IDLE", 1, true) ~= nil then
            return animation.name
        end
    end

    -- Some ped.ifp variants do not contain a clip literally named IDLE.
    -- Use the first decoded clip as a parser/playback smoke test in that case.
    if firstAnimation ~= nil then
        gta_log("No se encontró un clip IDLE; se probará el primero: " ..
                tostring(firstAnimation.name))
        return firstAnimation.name
    end

    return nil
end

local function gta_player_init(obj)
    obj.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
end

local id_bhvGtaNativePlayer = hook_behavior(
    nil,
    OBJ_LIST_LEVEL,
    true,
    gta_player_init,
    nil
)

local function load_gta_player()
    if gtaLoadAttempted then return end
    gtaLoadAttempted = true

    gta_log("Buscando player.img: " .. PLAYER_IMG)
    local archive, archiveError = gta_sa_scan_img(PLAYER_IMG)
    if archive == nil then
        gta_log("No se pudo leer player.img: " .. tostring(archiveError))
        gta_log("Comprueba que el archivo exista en la carpeta GTA_SA/models.")
        return
    end

    gta_log("IMG v" .. tostring(archive.version) ..
            " leído; entradas: " .. tostring(archive.count))

    local modelId, modelInfo = gta_sa_load_dff(
        PLAYER_IMG,
        PLAYER_DFF,
        MODEL_SCALE,
        PLAYER_IMG,
        PLAYER_TXD
    )

    if modelId == nil then
        gta_log("Falló player.dff/player.txd: " .. tostring(modelInfo))
        return
    end

    gtaModelId = modelId
    gta_log("DFF cargado. ID: " .. tostring(modelId) ..
            ", triángulos: " .. tostring(modelInfo.triangles) ..
            ", huesos: " .. tostring(modelInfo.bones) ..
            ", meshes con skin: " .. tostring(modelInfo.skinnedMeshes))

    gta_log("Buscando ped.ifp: " .. ANIM_IMG)
    local animationInfo, animationError =
        gta_sa_load_ifp(ANIM_IMG, PED_IFP, gtaModelId)

    if animationInfo == nil then
        gta_log("No se pudo leer ped.ifp: " .. tostring(animationError))
        return
    end

    local animations = animationInfo.animations or {}
    gta_log("IFP " .. tostring(animationInfo.version) ..
            " leído; animaciones: " .. tostring(#animations) ..
            ", huesos destino: " .. tostring(animationInfo.targetBones))

    for i = 1, math.min(#animations, 8) do
        gta_log("Clip " .. tostring(i) .. ": " ..
                tostring(animations[i].name) ..
                " (" .. tostring(animations[i].tracks) .. " tracks)")
    end

    local selectedAnimation = find_test_animation(animations)
    if selectedAnimation == nil then
        gta_log("El IFP se leyó, pero no contiene clips reproducibles.")
        return
    end

    local started, mapping =
        gta_sa_play_ifp(gtaModelId, selectedAnimation)

    if not started then
        gta_log("No se pudo reproducir " .. tostring(selectedAnimation) ..
                ": " .. tostring(mapping))
        return
    end

    gtaAnimationActive = true
    gta_log("Animación activa: " .. tostring(selectedAnimation) ..
            ". Coincidencias HAnim: " .. tostring(mapping.matchedById) ..
            ", asignadas por orden: " .. tostring(mapping.mappedByOrder) ..
            ", sin asignar: " .. tostring(mapping.unmappedTracks))
end

local function mario_update(m)
    if m.playerIndex ~= 0 then return end

    if not gtaLoadAttempted then
        load_gta_player()
    end

    if gtaModelId == nil then return end

    if gtaAnimationActive then
        local updated, updateError =
            gta_sa_update_ifp(gtaModelId, 1.0 / 30.0)

        if not updated then
            gtaAnimationActive = false
            gta_log("La actualización IFP se detuvo: " .. tostring(updateError))
        end
    end

    if gtaObject == nil then
        gtaObject = spawn_sync_object(
            id_bhvGtaNativePlayer,
            gtaModelId,
            m.pos.x + MODEL_OFFSET,
            m.pos.y,
            m.pos.z,
            nil
        )

        if gtaObject ~= nil then
            gta_log("Modelo de prueba creado junto al jugador.")
        elseif not gtaSpawnFailureLogged then
            gtaSpawnFailureLogged = true
            gta_log("No se pudo crear el objeto de prueba.")
        end
    else
        -- Keep the model visible near the local player during movement tests.
        gtaObject.oPosX = m.pos.x + MODEL_OFFSET
        gtaObject.oPosY = m.pos.y
        gtaObject.oPosZ = m.pos.z
    end
end

hook_event(HOOK_MARIO_UPDATE, mario_update)
