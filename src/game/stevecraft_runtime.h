#ifndef STEVECRAFT_RUNTIME_H
#define STEVECRAFT_RUNTIME_H

#include <PR/ultratypes.h>

#ifdef __cplusplus
extern "C" {
#endif

enum SteveCraftPerspective {
    STEVECRAFT_PERSPECTIVE_FIRST_PERSON = 0,
    STEVECRAFT_PERSPECTIVE_THIRD_PERSON_BACK = 1,
    STEVECRAFT_PERSPECTIVE_THIRD_PERSON_FRONT = 2
};

/* Called by Lua when SteveCraft is loaded/unloaded. */
void stevecraft_runtime_enable(s32 enabled);
void stevecraft_camera_set_perspective(s32 perspective);
s32 stevecraft_runtime_is_enabled(void);
s32 stevecraft_camera_get_perspective(void);

/* Called from the engine's existing first-person update point each frame. */
void stevecraft_update_camera(struct MarioState *m);

#ifdef __cplusplus
}
#endif

#endif
