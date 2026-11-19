package dev.stevecraft.bridge;

/*
 * This class is intentionally limited to the native bridge contract.
 * Minecraft's real movement and collision classes will be imported and
 * transpiled in later stages; no physics is fabricated in this fixture.
 */
public final class PlayerProxyFrame {
    public static void enable() {
        SteveCraftBridge.enable(true);
        SteveCraftBridge.setHitbox(0.3f, 1.8f, 0.0f);
    }

    public static void publishState(
        float x, float y, float z,
        float velocityX, float velocityY, float velocityZ,
        float yaw, float pitch,
        boolean onGround, boolean crouching
    ) {
        SteveCraftBridge.setState(
            x, y, z, velocityX, velocityY, velocityZ,
            yaw, pitch, onGround, crouching
        );
    }

    public static boolean selectModel(int playerIndex, int extendedModelId) {
        return SteveCraftBridge.setModel(playerIndex, extendedModelId);
    }

    public static boolean setModelScale(int playerIndex, float scaleX, float scaleY, float scaleZ) {
        return SteveCraftBridge.setScale(playerIndex, scaleX, scaleY, scaleZ);
    }

    public static boolean selectAnimation(int playerIndex, String animationName) {
        return SteveCraftBridge.setAnimation(playerIndex, animationName);
    }

    public static void clearModel(int playerIndex) {
        SteveCraftBridge.clearModel(playerIndex);
    }

    public static float readMoveX() {
        return SteveCraftBridge.getInputX();
    }

    public static float readMoveZ() {
        return SteveCraftBridge.getInputZ();
    }

    public static int readButtonsDown() {
        return SteveCraftBridge.getButtonsDown();
    }

    public static int readButtonsPressed() {
        return SteveCraftBridge.getButtonsPressed();
    }

    public static int readEngineAction() {
        return SteveCraftBridge.getEngineAction();
    }

    public static int readEngineActionArg() {
        return SteveCraftBridge.getEngineActionArg();
    }

    public static int readEngineActionTimer() {
        return SteveCraftBridge.getEngineActionTimer();
    }

    public static int readHealth() {
        return SteveCraftBridge.getHealth();
    }

    public static int readHurtCounter() {
        return SteveCraftBridge.getHurtCounter();
    }

    public static boolean readEngineGrounded() {
        return SteveCraftBridge.getEngineOnGround() != 0;
    }

    public static boolean readInteraction() {
        return SteveCraftBridge.getEngineInteracting() != 0;
    }

    public static boolean readRiding() {
        return SteveCraftBridge.getEngineRiding() != 0;
    }

    private PlayerProxyFrame() {
    }
}
