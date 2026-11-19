#include "sm64.h"
#include "game/stevecraft_player_proxy.h"

#include <cmath>

#include "game/mario.h"
#include "engine/graph_node.h"

namespace {

constexpr f32 kSm64UnitsPerMinecraftBlock = 160.0f / 1.8f;
constexpr f32 kDefaultHitboxRadiusBlocks = 0.3f;
constexpr f32 kDefaultHitboxHeightBlocks = 1.8f;

struct SteveProxyState {
    f32 position[3] = { 0.0f, 0.0f, 0.0f };
    f32 velocity[3] = { 0.0f, 0.0f, 0.0f };
    f32 yawDegrees = 0.0f;
    f32 pitchDegrees = 0.0f;
    f32 hitboxRadiusBlocks = kDefaultHitboxRadiusBlocks;
    f32 hitboxHeightBlocks = kDefaultHitboxHeightBlocks;
    f32 hitboxDownOffsetBlocks = 0.0f;
    bool onGround = true;
    bool crouching = false;
    bool initialized = false;
};

struct EngineFeedback {
    s32 action = 0;
    s32 actionArg = 0;
    s32 actionTimer = 0;
    s32 health = 0;
    s32 hurtCounter = 0;
    bool onGround = false;
    bool interacting = false;
    bool riding = false;
};

bool sProxyEnabled = false;
SteveProxyState sSteve;
EngineFeedback sEngine;
struct Object *sSnapshottedObject = nullptr;
bool sOriginalInvisible = false;
f32 sOriginalHitboxRadius = 0.0f;
f32 sOriginalHitboxHeight = 0.0f;
f32 sOriginalHurtboxRadius = 0.0f;
f32 sOriginalHurtboxHeight = 0.0f;
f32 sOriginalHitboxDownOffset = 0.0f;

bool finite_number(f32 value) {
    return std::isfinite(static_cast<double>(value));
}

s16 angle_from_degrees(f32 degrees) {
    f32 wrapped = std::fmod(degrees, 360.0f);
    if (wrapped < -180.0f) wrapped += 360.0f;
    if (wrapped >= 180.0f) wrapped -= 360.0f;
    return static_cast<s16>(std::lround(wrapped * (65536.0f / 360.0f)));
}

void snapshot_object(struct MarioState *m) {
    if (!m || !m->marioObj || sSnapshottedObject == m->marioObj) {
        return;
    }

    if (sSnapshottedObject) {
        sSnapshottedObject->header.gfx.node.flags =
            static_cast<s16>((sSnapshottedObject->header.gfx.node.flags & ~GRAPH_RENDER_INVISIBLE)
                | (sOriginalInvisible ? GRAPH_RENDER_INVISIBLE : 0));
        sSnapshottedObject->hitboxRadius = sOriginalHitboxRadius;
        sSnapshottedObject->hitboxHeight = sOriginalHitboxHeight;
        sSnapshottedObject->hurtboxRadius = sOriginalHurtboxRadius;
        sSnapshottedObject->hurtboxHeight = sOriginalHurtboxHeight;
        sSnapshottedObject->hitboxDownOffset = sOriginalHitboxDownOffset;
    }

    sSnapshottedObject = m->marioObj;
    sOriginalInvisible = (sSnapshottedObject->header.gfx.node.flags & GRAPH_RENDER_INVISIBLE) != 0;
    sOriginalHitboxRadius = sSnapshottedObject->hitboxRadius;
    sOriginalHitboxHeight = sSnapshottedObject->hitboxHeight;
    sOriginalHurtboxRadius = sSnapshottedObject->hurtboxRadius;
    sOriginalHurtboxHeight = sSnapshottedObject->hurtboxHeight;
    sOriginalHitboxDownOffset = sSnapshottedObject->hitboxDownOffset;
}

void restore_object(void) {
    if (!sSnapshottedObject) {
        return;
    }

    sSnapshottedObject->header.gfx.node.flags =
        static_cast<s16>((sSnapshottedObject->header.gfx.node.flags & ~GRAPH_RENDER_INVISIBLE)
            | (sOriginalInvisible ? GRAPH_RENDER_INVISIBLE : 0));
    sSnapshottedObject->hitboxRadius = sOriginalHitboxRadius;
    sSnapshottedObject->hitboxHeight = sOriginalHitboxHeight;
    sSnapshottedObject->hurtboxRadius = sOriginalHurtboxRadius;
    sSnapshottedObject->hurtboxHeight = sOriginalHurtboxHeight;
    sSnapshottedObject->hitboxDownOffset = sOriginalHitboxDownOffset;
    sSnapshottedObject = nullptr;
}

void apply_hitbox(struct MarioState *m) {
    if (!m || !m->marioObj) {
        return;
    }

    const f32 radius = sSteve.hitboxRadiusBlocks * kSm64UnitsPerMinecraftBlock;
    const f32 height = sSteve.hitboxHeightBlocks * kSm64UnitsPerMinecraftBlock;
    const f32 downOffset = sSteve.hitboxDownOffsetBlocks * kSm64UnitsPerMinecraftBlock;
    m->marioObj->hitboxRadius = radius;
    m->marioObj->hitboxHeight = height;
    m->marioObj->hurtboxRadius = radius;
    m->marioObj->hurtboxHeight = height;
    m->marioObj->hitboxDownOffset = downOffset;
}

void apply_steve_transform(struct MarioState *m) {
    if (!m || !m->marioObj || !sSteve.initialized) {
        return;
    }

    for (s32 axis = 0; axis < 3; ++axis) {
        const f32 position = sSteve.position[axis] * kSm64UnitsPerMinecraftBlock;
        const f32 velocity = sSteve.velocity[axis] * kSm64UnitsPerMinecraftBlock;
        m->pos[axis] = position;
        m->nonInstantWarpPos[axis] = position;
        m->vel[axis] = velocity;
        m->marioObj->header.gfx.pos[axis] = position;
    }

    const s16 yaw = angle_from_degrees(sSteve.yawDegrees);
    const s16 pitch = angle_from_degrees(sSteve.pitchDegrees);
    m->faceAngle[0] = pitch;
    m->faceAngle[1] = yaw;
    m->intendedYaw = yaw;
    m->intendedMag = 0.0f;
    m->marioObj->header.gfx.angle[0] = pitch;
    m->marioObj->header.gfx.angle[1] = yaw;

    const f32 yawRadians = sSteve.yawDegrees * (3.14159265358979323846f / 180.0f);
    const f32 forwardX = -std::sin(yawRadians);
    const f32 forwardZ = std::cos(yawRadians);
    m->forwardVel = (sSteve.velocity[0] * forwardX + sSteve.velocity[2] * forwardZ)
        * kSm64UnitsPerMinecraftBlock;
    m->slideVelX = m->vel[0];
    m->slideVelZ = m->vel[2];
    m->visibleToObjects = true;
}

void initialize_from_mario(struct MarioState *m) {
    if (!m || sSteve.initialized) {
        return;
    }

    for (s32 axis = 0; axis < 3; ++axis) {
        sSteve.position[axis] = m->pos[axis] / kSm64UnitsPerMinecraftBlock;
        sSteve.velocity[axis] = m->vel[axis] / kSm64UnitsPerMinecraftBlock;
    }

    sSteve.yawDegrees = static_cast<f32>(m->faceAngle[1]) * (360.0f / 65536.0f);
    sSteve.pitchDegrees = static_cast<f32>(m->faceAngle[0]) * (360.0f / 65536.0f);
    sSteve.onGround = m->floor != nullptr;
    sSteve.crouching = false;
    sSteve.initialized = true;
}

} // namespace

extern "C" void stevecraft_player_proxy_enable(s32 enabled) {
    const bool next = enabled != 0;
    if (next && !sProxyEnabled) {
        sSteve.initialized = false;
    }
    sProxyEnabled = next;
}

extern "C" s32 stevecraft_player_proxy_is_enabled(void) {
    return sProxyEnabled ? 1 : 0;
}

extern "C" void stevecraft_player_set_state(
    f32 x, f32 y, f32 z,
    f32 velocityX, f32 velocityY, f32 velocityZ,
    f32 yawDegrees, f32 pitchDegrees,
    s32 onGround, s32 crouching
) {
    const f32 values[] = { x, y, z, velocityX, velocityY, velocityZ, yawDegrees, pitchDegrees };
    for (f32 value : values) {
        if (!finite_number(value)) {
            return;
        }
    }

    if (std::fabs(x) > 10000000.0f || std::fabs(y) > 10000000.0f
        || std::fabs(z) > 10000000.0f
        || std::fabs(velocityX) > 10000.0f || std::fabs(velocityY) > 10000.0f
        || std::fabs(velocityZ) > 10000.0f) {
        return;
    }

    sSteve.position[0] = x;
    sSteve.position[1] = y;
    sSteve.position[2] = z;
    sSteve.velocity[0] = velocityX;
    sSteve.velocity[1] = velocityY;
    sSteve.velocity[2] = velocityZ;
    sSteve.yawDegrees = yawDegrees;
    sSteve.pitchDegrees = std::fmax(-90.0f, std::fmin(90.0f, pitchDegrees));
    sSteve.onGround = onGround != 0;
    sSteve.crouching = crouching != 0;
    sSteve.initialized = true;
}

extern "C" void stevecraft_player_set_hitbox(
    f32 radiusBlocks, f32 heightBlocks, f32 downOffsetBlocks
) {
    if (!finite_number(radiusBlocks) || !finite_number(heightBlocks)
        || !finite_number(downOffsetBlocks)) {
        return;
    }
    if (radiusBlocks <= 0.0f || radiusBlocks > 8.0f
        || heightBlocks <= 0.0f || heightBlocks > 16.0f
        || std::fabs(downOffsetBlocks) > 16.0f) {
        return;
    }

    sSteve.hitboxRadiusBlocks = radiusBlocks;
    sSteve.hitboxHeightBlocks = heightBlocks;
    sSteve.hitboxDownOffsetBlocks = downOffsetBlocks;
}

extern "C" void stevecraft_player_proxy_prepare_mario(struct MarioState *m) {
    if (!sProxyEnabled || !m || m->playerIndex != 0 || !m->marioObj) {
        return;
    }

    snapshot_object(m);
    initialize_from_mario(m);
    apply_hitbox(m);
    apply_steve_transform(m);
}

extern "C" void stevecraft_player_proxy_capture_engine_state(struct MarioState *m) {
    if (!sProxyEnabled || !m || m->playerIndex != 0) {
        return;
    }

    sEngine.action = static_cast<s32>(m->action);
    sEngine.actionArg = static_cast<s32>(m->actionArg);
    sEngine.actionTimer = static_cast<s32>(m->actionTimer);
    sEngine.health = static_cast<s32>(m->health);
    sEngine.hurtCounter = static_cast<s32>(m->hurtCounter);
    /* This reports SM64 floor contact only; Steve's own onGround flag remains
     * the authority for Minecraft movement and block collision. */
    sEngine.onGround = (m->floor != nullptr)
        && (m->pos[1] <= m->floorHeight + 1.0f);
    sEngine.interacting = (m->interactObj != nullptr) || (m->usedObj != nullptr);
    sEngine.riding = m->riddenObj != nullptr;
}

extern "C" void stevecraft_player_proxy_update_mario(struct MarioState *m) {
    if (!sProxyEnabled) {
        restore_object();
        return;
    }
    if (!m || m->playerIndex != 0 || !m->marioObj) {
        return;
    }

    snapshot_object(m);
    apply_steve_transform(m);
    apply_hitbox(m);
    m->marioObj->header.gfx.node.flags |= GRAPH_RENDER_INVISIBLE;
    m->visibleToObjects = true;
}

extern "C" f32 stevecraft_player_get_input_x(void) {
    if (!gMarioStates[0].controller) return 0.0f;
    return gMarioStates[0].controller->stickX / 64.0f;
}

extern "C" f32 stevecraft_player_get_input_z(void) {
    if (!gMarioStates[0].controller) return 0.0f;
    return gMarioStates[0].controller->stickY / 64.0f;
}

extern "C" s32 stevecraft_player_get_buttons_down(void) {
    if (!gMarioStates[0].controller) return 0;
    return static_cast<s32>(gMarioStates[0].controller->buttonDown);
}

extern "C" s32 stevecraft_player_get_buttons_pressed(void) {
    if (!gMarioStates[0].controller) return 0;
    return static_cast<s32>(gMarioStates[0].controller->buttonPressed);
}

extern "C" s32 stevecraft_player_get_engine_action(void) { return sEngine.action; }
extern "C" s32 stevecraft_player_get_engine_action_arg(void) { return sEngine.actionArg; }
extern "C" s32 stevecraft_player_get_engine_action_timer(void) { return sEngine.actionTimer; }
extern "C" s32 stevecraft_player_get_health(void) { return sEngine.health; }
extern "C" s32 stevecraft_player_get_hurt_counter(void) { return sEngine.hurtCounter; }
extern "C" s32 stevecraft_player_get_engine_on_ground(void) { return sEngine.onGround ? 1 : 0; }
extern "C" s32 stevecraft_player_get_engine_interacting(void) { return sEngine.interacting ? 1 : 0; }
extern "C" s32 stevecraft_player_get_engine_riding(void) { return sEngine.riding ? 1 : 0; }
