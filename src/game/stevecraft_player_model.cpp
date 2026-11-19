#include "sm64.h"

#include <cmath>
#include <cstring>
#include <string>

#include "engine/graph_node.h"
#include "game/mario.h"
#include "game/stevecraft_player_model.h"
#include "game/stevecraft_player_proxy.h"
#include "model_ids.h"

extern "C" {
#include "pc/lua/utils/smlua_anim_utils.h"
#include "pc/lua/utils/smlua_model_utils.h"
}

/* Implemented by DynOS. This points at the selected model's independent
 * GeoLayout, not Mario's hard-coded mario_geo hierarchy. */
struct GraphNode *DynOS_Model_GetGeo(u32 modelId);

namespace {

struct PlayerModelState {
    Object *object = nullptr;
    GraphNode *originalGeo = nullptr;
    GraphNode *modelGeo = nullptr;
    GraphNode *appliedGeo = nullptr;
    std::string animationName;
    std::string appliedAnimationName;
    Vec3f originalScale = { 1.0f, 1.0f, 1.0f };
    Vec3f modelScale = { 1.0f, 1.0f, 1.0f };
    bool hasOriginalState = false;
    bool originalPlayerRenderFlag = false;
    bool enabled = false;
    bool scaleConfigured = false;
    bool scaleApplied = false;
    bool animationAttempted = false;
};

PlayerModelState sPlayerModelStates[MAX_PLAYERS];

PlayerModelState *get_player_model_state(s32 playerIndex) {
    if (playerIndex < 0 || playerIndex >= MAX_PLAYERS) {
        return nullptr;
    }
    return &sPlayerModelStates[playerIndex];
}

void capture_original_state(PlayerModelState &state, Object *object) {
    if (!object || state.object == object) {
        return;
    }

    /* Object-pool slots can be recycled across area transitions. Never
     * dereference the previous object while switching to the new one. */
    state.object = object;
    state.originalGeo = object->header.gfx.sharedChild;
    state.originalPlayerRenderFlag =
        (object->header.gfx.node.flags & GRAPH_RENDER_PLAYER) != 0;
    for (s32 axis = 0; axis < 3; ++axis) {
        state.originalScale[axis] = object->header.gfx.scale[axis];
    }
    state.appliedGeo = nullptr;
    state.hasOriginalState = true;
    state.scaleApplied = false;
    state.appliedAnimationName.clear();
    state.animationAttempted = false;
}

void reset_animation_to_start(Object *object) {
    if (!object || !object->header.gfx.animInfo.curAnim) {
        return;
    }

    Animation *animation = object->header.gfx.animInfo.curAnim;
    AnimInfo *animInfo = &object->header.gfx.animInfo;
    /* Keep animID/prevAnimID in sync with the engine's action state. They
     * identify Mario's action animation and are also the guard used by
     * set_mario_animation(); invalidating them here would make that function
     * replace this custom rig animation on the next update. */
    animInfo->animFrame = animation->startFrame;
    animInfo->prevAnimFrame = animation->startFrame;
    animInfo->animFrameAccelAssist = animation->startFrame << 16;
    animInfo->animAccel = 0x10000;
    animInfo->animTimer = 0;
    animInfo->animYTrans = 0;
    animInfo->prevAnimFrameTimestamp = 0;
    animInfo->prevAnimPtr = nullptr;
}

} // namespace

extern "C" s32 stevecraft_player_model_set_model(s32 playerIndex, s32 extendedModelId) {
    PlayerModelState *state = get_player_model_state(playerIndex);
    if (!state || extendedModelId <= 0 || extendedModelId > 65535) {
        return 0;
    }

    const u16 modelId = smlua_model_util_load(static_cast<enum ModelExtendedId>(extendedModelId));
    if (modelId == MODEL_NONE || modelId == MODEL_ERROR_MODEL) {
        return 0;
    }

    GraphNode *modelGeo = DynOS_Model_GetGeo(modelId);
    if (!modelGeo) {
        return 0;
    }

    state->modelGeo = modelGeo;
    state->enabled = true;
    /* Keep the selected named animation when switching between model
     * profiles; the update path will restart it against the new GeoLayout. */
    state->appliedAnimationName.clear();
    state->animationAttempted = false;
    return 1;
}

extern "C" s32 stevecraft_player_model_set_scale(
    s32 playerIndex, f32 scaleX, f32 scaleY, f32 scaleZ
) {
    PlayerModelState *state = get_player_model_state(playerIndex);
    const f32 values[] = { scaleX, scaleY, scaleZ };
    if (!state) {
        return 0;
    }

    for (f32 value : values) {
        if (!std::isfinite(static_cast<double>(value)) || value <= 0.0f || value > 16.0f) {
            return 0;
        }
    }

    state->modelScale[0] = scaleX;
    state->modelScale[1] = scaleY;
    state->modelScale[2] = scaleZ;
    state->scaleConfigured = true;
    return 1;
}

extern "C" s32 stevecraft_player_model_set_animation(
    s32 playerIndex, const char *animationName
) {
    PlayerModelState *state = get_player_model_state(playerIndex);
    if (!state || !state->enabled || !animationName) {
        return 0;
    }

    const size_t nameLength = std::strlen(animationName);
    if (nameLength == 0 || nameLength > 127) {
        return 0;
    }

    if (state->animationName != animationName) {
        state->animationName = animationName;
        state->appliedAnimationName.clear();
        state->animationAttempted = false;
    } else if (state->appliedAnimationName.empty()) {
        /* Calling again after registering an animation permits a retry. */
        state->animationAttempted = false;
    }
    return 1;
}

extern "C" void stevecraft_player_model_clear(s32 playerIndex) {
    PlayerModelState *state = get_player_model_state(playerIndex);
    if (!state) {
        return;
    }

    state->enabled = false;
    state->modelGeo = nullptr;
    state->animationName.clear();
    state->appliedAnimationName.clear();
    state->animationAttempted = false;
    state->scaleConfigured = false;
}

extern "C" s32 stevecraft_player_model_is_enabled(s32 playerIndex) {
    PlayerModelState *state = get_player_model_state(playerIndex);
    return (state && state->enabled && state->modelGeo) ? 1 : 0;
}

extern "C" void stevecraft_player_model_update_mario(struct MarioState *m) {
    if (!m || !m->marioObj) {
        return;
    }

    PlayerModelState *state = get_player_model_state(m->playerIndex);
    if (!state) {
        return;
    }

    Object *object = m->marioObj;
    capture_original_state(*state, object);

    if (!state->enabled || !state->modelGeo) {
        if (state->appliedGeo && object->header.gfx.sharedChild == state->appliedGeo
            && state->originalGeo) {
            object->header.gfx.sharedChild = state->originalGeo;
        }
        if (state->scaleApplied && state->hasOriginalState) {
            for (s32 axis = 0; axis < 3; ++axis) {
                object->header.gfx.scale[axis] = state->originalScale[axis];
            }
        }
        if (state->hasOriginalState) {
            if (state->originalPlayerRenderFlag) {
                object->header.gfx.node.flags |= GRAPH_RENDER_PLAYER;
            } else {
                object->header.gfx.node.flags &= ~GRAPH_RENDER_PLAYER;
            }
        }
        if (!state->appliedAnimationName.empty() && m->animation
            && m->animation->targetAnim) {
            /* The renderer dereferences curAnim while preparing animation
             * globals. Restore a valid engine animation instead of nulling
             * the pointer when the independent rig is removed. */
            object->header.gfx.animInfo.curAnim = m->animation->targetAnim;
            reset_animation_to_start(object);
        }
        if (!state->appliedAnimationName.empty()) {
            object->header.gfx.animInfo.prevAnimPtr = nullptr;
        }
        state->appliedGeo = nullptr;
        state->scaleApplied = false;
        state->appliedAnimationName.clear();
        return;
    }

    if (object->header.gfx.sharedChild != state->modelGeo) {
        object->header.gfx.sharedChild = state->modelGeo;
    }
    state->appliedGeo = state->modelGeo;

    if (state->scaleConfigured) {
        for (s32 axis = 0; axis < 3; ++axis) {
            object->header.gfx.scale[axis] = state->modelScale[axis];
        }
        state->scaleApplied = true;
    } else if (state->scaleApplied && state->hasOriginalState) {
        for (s32 axis = 0; axis < 3; ++axis) {
            object->header.gfx.scale[axis] = state->originalScale[axis];
        }
        state->scaleApplied = false;
    }

    if (!state->animationName.empty()) {
        const char *currentName = smlua_anim_util_get_current_animation_name(object);
        const bool isCurrent = currentName
            && std::strcmp(currentName, state->animationName.c_str()) == 0;

        if (isCurrent) {
            /* First application or model switch: start the named animation
             * on this model's own rig without disturbing Mario's action ID. */
            if (state->appliedAnimationName != state->animationName) {
                reset_animation_to_start(object);
                state->appliedAnimationName = state->animationName;
            }
            state->animationAttempted = false;
        } else if (!state->animationAttempted || !state->appliedAnimationName.empty()) {
            /* Rebind after the vanilla action changes its animation ID. */
            smlua_anim_util_set_animation(object, state->animationName.c_str());
            currentName = smlua_anim_util_get_current_animation_name(object);

            if (currentName && std::strcmp(currentName, state->animationName.c_str()) == 0) {
                reset_animation_to_start(object);
                state->appliedAnimationName = state->animationName;
                state->animationAttempted = false;
            } else {
                state->animationAttempted = true;
            }
        }
    }

    /* When proxy mode is active, the selected custom GeoLayout replaces the
     * otherwise hidden Mario mesh. Normal players keep their original flags. */
    /* The renderer uses this flag to collect player-specific bone data
     * (such as minimumBoneY) from the independent GeoLayout. */
    object->header.gfx.node.flags |= GRAPH_RENDER_PLAYER;

    if (m->playerIndex == 0 && stevecraft_player_proxy_is_enabled()) {
        object->header.gfx.node.flags &= ~GRAPH_RENDER_INVISIBLE;
    }
}
