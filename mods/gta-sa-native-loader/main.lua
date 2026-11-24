-- name: GTA San Andreas Native Player
-- description: Loads player.dff and player.txd directly from a GTA SA IMG v2 archive. Reads ped.ifp metadata from anim.img.
-- version: 0.1.0-alpha

-- Copy the ORIGINAL player.img and anim.img from your GTA San Andreas installation
-- to the folder below. The files are read in-place; they are not extracted or converted.
local PLAYER_IMG = "/storage/emulated/0/GTA_SA/models/player.img"
local ANIM_IMG = "/storage/emulated/0/GTA_SA/anim/anim.img"

local PLAYER_DFF = "player.dff"
local PLAYER_TXD = "player.txd"
local PED_IFP = "ped.ifp"

local gtaModelId = nil
local gtaSpawned = false
local gtaLoadAttempted = false
local gtaAnimationInfo = nil
local gtaAnimationActive = false

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

    local archive = gta_sa_scan_img(PLAYER_IMG)
    if archive == nil then
        print("[GTA SA] No se pudo abrir player.img. Comprueba PLAYER_IMG.")
        return
    end

    print("[GTA SA] IMG v" .. tostring(archive.version) ..
          ": " .. tostring(archive.count) .. " entradas.")

    local modelId, modelInfo = gta_sa_load_dff(
        PLAYER_IMG,
        PLAYER_DFF,
        100.0,
        PLAYER_IMG,
        PLAYER_TXD
    )

    if modelId == nil then
        print("[GTA SA] Error al cargar player.dff: " .. tostring(modelInfo))
        return
    end

    gtaModelId = modelId
    print("[GTA SA] player.dff cargado: " ..
          tostring(modelInfo.triangles) .. " triángulos.")

    gtaAnimationInfo = gta_sa_load_ifp(ANIM_IMG, PED_IFP, gtaModelId)
    if gtaAnimationInfo ~= nil then
        local selectedAnimation = nil
        for _, animation in ipairs(gtaAnimationInfo.animations) do
            if string.upper(animation.name) == "IDLE" then
                selectedAnimation = animation.name
                break
            end
        end
        if selectedAnimation == nil and #gtaAnimationInfo.animations > 0 then
            selectedAnimation = gtaAnimationInfo.animations[1].name
        end
        if selectedAnimation ~= nil then
            local started, mapping = gta_sa_play_ifp(gtaModelId, selectedAnimation)
            if started then
                gtaAnimationActive = true
                print("[GTA SA] IFP activo: " .. selectedAnimation ..
                      " (IDs: " .. tostring(mapping.matchedById) ..
                      ", retarget: " .. tostring(mapping.mappedByOrder) .. ").")
            else
                gtaAnimationActive = false
                print("[GTA SA] No se pudo aplicar IFP: " .. tostring(mapping))
            end
        end
    else
        print("[GTA SA] ped.ifp no disponible; el modelo permanece estático.")
    end
end

local function mario_update(m)
    if m.playerIndex ~= 0 then return end

    load_gta_player()

    if gtaModelId ~= nil and gtaAnimationActive then
        gta_sa_update_ifp(gtaModelId, 1.0 / 30.0)
    end

    if gtaModelId ~= nil and not gtaSpawned then
        local obj = spawn_sync_object(
            id_bhvGtaNativePlayer,
            gtaModelId,
            m.pos.x + 180,
            m.pos.y,
            m.pos.z,
            nil
        )
        gtaSpawned = obj ~= nil
    end
end

hook_event(HOOK_MARIO_UPDATE, mario_update)
