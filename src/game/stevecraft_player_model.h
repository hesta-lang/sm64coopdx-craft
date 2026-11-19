#ifndef STEVECRAFT_PLAYER_MODEL_H
#define STEVECRAFT_PLAYER_MODEL_H

#include <PR/ultratypes.h>

struct MarioState;

#ifdef __cplusplus
extern "C" {
#endif

/* Per-player visual models, independent of Mario's fixed Character table. */
s32 stevecraft_player_model_set_model(s32 playerIndex, s32 extendedModelId);
s32 stevecraft_player_model_set_scale(s32 playerIndex, f32 scaleX, f32 scaleY, f32 scaleZ);
s32 stevecraft_player_model_set_animation(s32 playerIndex, const char *animationName);
void stevecraft_player_model_clear(s32 playerIndex);
s32 stevecraft_player_model_is_enabled(s32 playerIndex);

/* Apply the selected visual profile to the player's render object. */
void stevecraft_player_model_update_mario(struct MarioState *m);

#ifdef __cplusplus
}
#endif

#endif
