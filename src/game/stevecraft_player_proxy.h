#ifndef STEVECRAFT_PLAYER_PROXY_H
#define STEVECRAFT_PLAYER_PROXY_H

#include <PR/ultratypes.h>

struct MarioState;

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The proxy is disabled by default. Steve owns position and velocity; Mario
 * remains the invisible SM64CoopDX player identity used by existing actors.
 *
 * Public setter units are Minecraft units:
 *   position: blocks
 *   velocity: blocks per game tick
 *   yaw/pitch: degrees (Minecraft convention)
 *   hitbox: blocks
 */
void stevecraft_player_proxy_enable(s32 enabled);
s32 stevecraft_player_proxy_is_enabled(void);

void stevecraft_player_set_state(
    f32 x, f32 y, f32 z,
    f32 velocityX, f32 velocityY, f32 velocityZ,
    f32 yawDegrees, f32 pitchDegrees,
    s32 onGround, s32 crouching
);
void stevecraft_player_set_hitbox(f32 radiusBlocks, f32 heightBlocks, f32 downOffsetBlocks);

/* Called around execute_mario_action() by object_list_processor.c. */
void stevecraft_player_proxy_prepare_mario(struct MarioState *m);
void stevecraft_player_proxy_capture_engine_state(struct MarioState *m);
void stevecraft_player_proxy_update_mario(struct MarioState *m);

/* Input sampled from the real local controller. */
f32 stevecraft_player_get_input_x(void);
f32 stevecraft_player_get_input_z(void);
s32 stevecraft_player_get_buttons_down(void);
s32 stevecraft_player_get_buttons_pressed(void);

/* Feedback emitted by the SM64CoopDX proxy update. */
s32 stevecraft_player_get_engine_action(void);
s32 stevecraft_player_get_engine_action_arg(void);
s32 stevecraft_player_get_engine_action_timer(void);
s32 stevecraft_player_get_health(void);
s32 stevecraft_player_get_hurt_counter(void);
s32 stevecraft_player_get_engine_on_ground(void);
s32 stevecraft_player_get_engine_interacting(void);
s32 stevecraft_player_get_engine_riding(void);

#ifdef __cplusplus
}
#endif

#endif
