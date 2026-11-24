-- name: GTA SA Native Loader
-- category: Tools
-- description: Carga archivos DFF/TXD e IFP originales de GTA San Andreas desde IMG v2 en Android.
-- version: 0.3.0-alpha

-- Este es un mod Lua independiente de un solo archivo.
-- El soporte nativo gta_sa_* está compilado dentro del APK Android.

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
    print("[GTA SA] " .. tostring(message))
end

local function find_test_animation(animations)
    local firstAnimation = nil
    for _, animation in ipairs(animations or {}) do
        if firstAnimation == nil then firstAnimation = animation end
        local name = string.upper(animation.name or "")
        if name == "IDLE" or string.find(name, "IDLE", 1, true) ~= nil then
            return animation.name
        end
    end
    return firstAnimation and firstAnimation.name or nil
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

    gta_log("Buscando " .. PLAYER_IMG)
    local archive, archiveError = gta_sa_scan_img(PLAYER_IMG)
    if archive == nil then
        gta_log("No se pudo abrir player.img: " .. tostring(archiveError))
        return
    end
    gta_log("IMG v" .. tostring(archive.version) ..
        " leído; entradas: " .. tostring(archive.count))

    local modelId, modelInfo = gta_sa_load_dff(
        PLAYER_IMG, PLAYER_DFF, MODEL_SCALE, PLAYER_IMG, PLAYER_TXD
    )
    if modelId == nil then
        gta_log("Error al cargar player.dff: " .. tostring(modelInfo))
        return
    end
    gtaModelId = modelId
    gta_log("DFF cargado: " .. tostring(modelInfo.triangles) ..
        " triángulos, " .. tostring(modelInfo.bones) .. " huesos.")

    local animationInfo, animationError = gta_sa_load_ifp(
        ANIM_IMG, PED_IFP, gtaModelId
    )
    if animationInfo == nil then
        gta_log("No se pudo cargar ped.ifp: " .. tostring(animationError))
        return
    end

    local animations = animationInfo.animations or {}
    gta_log("IFP leído; clips: " .. tostring(#animations))
    for i = 1, math.min(#animations, 8) do
        gta_log("Clip " .. tostring(i) .. ": " ..
            tostring(animations[i].name))
    end

    local selectedAnimation = find_test_animation(animations)
    if selectedAnimation == nil then
        gta_log("El IFP no contiene animaciones.")
        return
    end

    local started, mapping = gta_sa_play_ifp(gtaModelId, selectedAnimation)
    if not started then
        gta_log("No se pudo iniciar " .. tostring(selectedAnimation) ..
            ": " .. tostring(mapping))
        return
    end

    gtaAnimationActive = true
    gta_log("Animación activa: " .. tostring(selectedAnimation))
end

local function mario_update(m)
    if m.playerIndex ~= 0 then return end
    if not gtaLoadAttempted then load_gta_player() end
    if gtaModelId == nil then return end

    if gtaAnimationActive then
        local updated, updateError = gta_sa_update_ifp(gtaModelId, 1.0 / 30.0)
        if not updated then
            gtaAnimationActive = false
            gta_log("Actualización IFP detenida: " .. tostring(updateError))
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
            gta_log("Objeto DFF creado junto al jugador.")
        elseif not gtaSpawnFailureLogged then
            gtaSpawnFailureLogged = true
            gta_log("No se pudo crear el objeto DFF.")
        end
    else
        gtaObject.oPosX = m.pos.x + MODEL_OFFSET
        gtaObject.oPosY = m.pos.y
        gtaObject.oPosZ = m.pos.z
    end
end

hook_event(HOOK_MARIO_UPDATE, mario_update)
