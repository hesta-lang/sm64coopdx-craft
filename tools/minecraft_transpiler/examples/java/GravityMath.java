package dev.stevecraft.transpiler;

public final class GravityMath {
    private GravityMath() {}

    public static double stepVerticalVelocity(double velocityY, double gravity, double terminalVelocity) {
        if (velocityY > terminalVelocity) {
            velocityY = velocityY - gravity;
        }
        if (velocityY < terminalVelocity) {
            velocityY = terminalVelocity;
        }
        return velocityY;
    }

    public static double clampHorizontalSpeed(double speed, double minimum, double maximum) {
        return Math.max(minimum, Math.min(maximum, speed));
    }
}
