#include "sm64.h"
#include "game/stevecraft_runtime.h"

#include <algorithm>
#include <cmath>

#include "game/area.h"
#include "game/camera.h"
#include "game/first_person_cam.h"
#include "game/mario.h"
#include "engine/surface_collision.h"
#include "engine/math_util.h"
#include "pc/djui/djui.h"
#include "pc/lua/utils/smlua_camera_utils.h"
#include "pc/controller/controller_mouse.h"

#ifdef TOUCH_CONTROLS
#include "pc/controller/controller_touchscreen.h"
#endif

namespace {
constexpr float kPi = 3.14159265358979323846f;
constexpr float kDegreesPerAngleUnit = 360.0f / 65536.0f;
constexpr float kUnitsPerMinecraftBlock = 160.0f / 1.8f;
constexpr float kStandingEyeHeight = 1.62f;
constexpr float kCrouchingEyeHeight = 1.27f;
constexpr float kSwimmingEyeHeight = 0.40f;
constexpr float kThirdPersonDistanceBlocks = 4.0f;
constexpr float kCameraProbeHalfSizeBlocks = 0.1f;

bool sEnabled = false;
bool sInitialized = false;
s32 sPerspective = STEVECRAFT_PERSPECTIVE_FIRST_PERSON;
float sEyeHeight = kStandingEyeHeight * kUnitsPerMinecraftBlock;
s16 sYaw = 0;
s16 sPitch = 0;

float to_radians(s16 angle) {
    return static_cast<float>(angle) * (2.0f * kPi / 65536.0f);
}

float distance3(const Vec3f a, const Vec3f b) {
    const float x = a[0] - b[0];
    const float y = a[1] - b[1];
    const float z = a[2] - b[2];
    return std::sqrt(x * x + y * y + z * z);
}

float camera_max_zoom(const Vec3f eye, const Vec3f backward, float requestedDistance) {
    float distance = requestedDistance;
    const float probe = kCameraProbeHalfSizeBlocks * kUnitsPerMinecraftBlock;

    /*
     * This is Minecraft Camera.getMaxZoom's eight-corner test, translated to
     * SM64 world units. find_surface_on_ray is the engine's triangle-surface
     * ray query; it keeps SM64 level geometry as the collision authority.
     */
    for (s32 i = 0; i < 8; ++i) {
        Vec3f origin = {
            eye[0] + ((i & 1) ? probe : -probe),
            eye[1] + ((i & 2) ? probe : -probe),
            eye[2] + ((i & 4) ? probe : -probe)
        };
        Vec3f ray = {
            backward[0] * distance,
            backward[1] * distance,
            backward[2] * distance
        };
        Vec3f hitPosition = {0.0f, 0.0f, 0.0f};
        struct Surface *hitSurface = nullptr;
        find_surface_on_ray(origin, ray, &hitSurface, hitPosition, 3.0f);
        if (hitSurface != nullptr) {
            const float hitDistance = distance3(eye, hitPosition);
            if (hitDistance < distance) {
                distance = hitDistance;
            }
        }
    }
    return distance;
}

void apply_touch_look() {
    if (!camera_config_is_mouse_look_enabled()) {
        return;
    }

    const float sensitivityX = 0.3f * static_cast<float>(camera_config_get_x_sensitivity());
    const float sensitivityY = 0.4f * static_cast<float>(camera_config_get_y_sensitivity());
    float deltaX = 0.0f;
    float deltaY = 0.0f;

#ifdef TOUCH_CONTROLS
    deltaX = static_cast<float>(touch_x);
    deltaY = static_cast<float>(touch_y);
    /* Touch deltas are consumed once; they are not integrated repeatedly. */
    touch_x = 0;
    touch_y = 0;
#else
    if (mouse_relative_enabled) {
        deltaX = static_cast<float>(mouse_x);
        deltaY = static_cast<float>(mouse_y);
    }
#endif

    const float invertX = camera_config_is_x_inverted() ? -1.0f : 1.0f;
    const float invertY = camera_config_is_y_inverted() ? -1.0f : 1.0f;
    sYaw = static_cast<s16>(sYaw - static_cast<s32>(sensitivityX * 1.5f * deltaX * invertX));
    sPitch = static_cast<s16>(sPitch + static_cast<s32>(sensitivityY * 1.5f * deltaY * invertY));
    sPitch = static_cast<s16>(std::max<s32>(-0x3F00, std::min<s32>(0x3F00, sPitch)));
}

void publish_camera(struct MarioState *m, const Vec3f position, const Vec3f focus, s16 viewYaw) {
    if (!m || !m->area || !m->area->camera) return;

    struct Camera *camera = m->area->camera;
    vec3f_copy(gLakituState.pos, position);
    vec3f_copy(gLakituState.curPos, position);
    vec3f_copy(gLakituState.goalPos, position);
    vec3f_copy(gLakituState.focus, focus);
    vec3f_copy(gLakituState.curFocus, focus);
    vec3f_copy(gLakituState.goalFocus, focus);
    vec3f_copy(camera->pos, position);
    vec3f_copy(camera->focus, focus);

    gLakituState.yaw = viewYaw;
    gLakituState.nextYaw = viewYaw;
    camera->yaw = viewYaw;

    /* Minecraft changes perspective immediately, without Lakitu easing. */
    gLakituState.posHSpeed = 0.0f;
    gLakituState.posVSpeed = 0.0f;
    gLakituState.focHSpeed = 0.0f;
    gLakituState.focVSpeed = 0.0f;
    vec3s_set(gLakituState.shakeMagnitude, 0, 0, 0);
}

} // namespace

extern "C" void stevecraft_runtime_enable(s32 enabled) {
    sEnabled = enabled != 0;
    sInitialized = false;
    if (!sEnabled) {
        sPerspective = STEVECRAFT_PERSPECTIVE_FIRST_PERSON;
    }
}

extern "C" void stevecraft_camera_set_perspective(s32 perspective) {
    if (perspective < STEVECRAFT_PERSPECTIVE_FIRST_PERSON
        || perspective > STEVECRAFT_PERSPECTIVE_THIRD_PERSON_FRONT) {
        return;
    }
    sPerspective = perspective;
    sInitialized = false;
}

extern "C" s32 stevecraft_runtime_is_enabled(void) {
    return sEnabled ? 1 : 0;
}

extern "C" s32 stevecraft_camera_get_perspective(void) {
    return sPerspective;
}

extern "C" void stevecraft_update_camera(struct MarioState *m) {
    if (!sEnabled || !m || m->playerIndex != 0 || !m->marioBodyState
        || !m->area || !m->area->camera || gDjuiInMainMenu) {
        return;
    }

    /* Do not override scripted cameras, cannons, dialogs or forced actions. */
    if (first_person_check_cancels(m) || m->area->camera->cutscene != 0) {
        return;
    }

    if (!sInitialized) {
        sYaw = m->faceAngle[1];
        sPitch = 0;
        const float initialHeight = mario_is_crouching(m)
            ? kCrouchingEyeHeight : kStandingEyeHeight;
        sEyeHeight = initialHeight * kUnitsPerMinecraftBlock;
        sInitialized = true;
    }

    apply_touch_look();

    /* The first-person hand viewmodel reads these legacy camera angles. */
    gFirstPersonCamera.yaw = sYaw;
    gFirstPersonCamera.pitch = sPitch;

    float targetEyeHeight = kStandingEyeHeight;
    if (mario_is_crouching(m)) {
        targetEyeHeight = kCrouchingEyeHeight;
    }
    if (m->action & (ACT_FLAG_SWIMMING | ACT_FLAG_SWIMMING_OR_FLYING)) {
        targetEyeHeight = kSwimmingEyeHeight;
    }

    const float targetEyeUnits = targetEyeHeight * kUnitsPerMinecraftBlock;
    sEyeHeight += (targetEyeUnits - sEyeHeight) * 0.5f;

    Vec3f eye = {
        m->pos[0],
        m->pos[1] + sEyeHeight,
        m->pos[2]
    };

    s16 viewYaw = sYaw;
    s16 viewPitch = sPitch;
    if (sPerspective == STEVECRAFT_PERSPECTIVE_THIRD_PERSON_FRONT) {
        viewYaw = static_cast<s16>(viewYaw + 0x8000);
        viewPitch = static_cast<s16>(-viewPitch);
    }

    const float yaw = to_radians(viewYaw);
    const float pitch = to_radians(viewPitch);
    const float sinYaw = std::sin(yaw);
    const float cosYaw = std::cos(yaw);
    const float sinPitch = std::sin(pitch);
    const float cosPitch = std::cos(pitch);

    /* Minecraft Camera.setRotation() applied to FORWARDS=(0,0,-1). */
    Vec3f forward = {
        -sinYaw * cosPitch,
        -sinPitch,
        cosYaw * cosPitch
    };

    Vec3f position = {eye[0], eye[1], eye[2]};
    if (sPerspective != STEVECRAFT_PERSPECTIVE_FIRST_PERSON) {
        float distance = kThirdPersonDistanceBlocks * kUnitsPerMinecraftBlock;

        /*
         * The third-person camera sits behind the look direction. Cast the
         * collision rays along that same backward vector; casting forward
         * would test the space in front of Steve and let the camera clip
         * through walls behind him.
         */
        Vec3f backward = {-forward[0], -forward[1], -forward[2]};
        const float actualDistance = camera_max_zoom(eye, backward, distance);
        position[0] += backward[0] * actualDistance;
        position[1] += backward[1] * actualDistance;
        position[2] += backward[2] * actualDistance;
        m->marioBodyState->modelState = 0;
    } else {
        m->marioBodyState->modelState = 0x100;
    }

    Vec3f focus = {eye[0], eye[1], eye[2]};
    publish_camera(m, position, focus, viewYaw);
}
