package.path = "mods/stevecraft/?.lua;" .. package.path

local GridTransform = require("systems/grid_transform")
local object = {
    oPosX = 129.25, oPosY = 181.5, oPosZ = -89.75,
    oMoveAnglePitch = 120, oMoveAngleYaw = 220, oMoveAngleRoll = -60,
    oFaceAnglePitch = -300, oFaceAngleYaw = 900, oFaceAngleRoll = 30,
    oAngleVelPitch = 15, oAngleVelYaw = 22, oAngleVelRoll = 9,
}
assert(GridTransform.apply(object, 90) == true)
assert(object.oPosX == 135, "X was not centered on the 90-unit grid")
assert(object.oPosY == 225, "Y was not centered on the 90-unit grid")
assert(object.oPosZ == -45, "negative Z was not centered on the 90-unit grid")
for _, key in ipairs({
    "oMoveAnglePitch", "oMoveAngleYaw", "oMoveAngleRoll",
    "oFaceAnglePitch", "oFaceAngleYaw", "oFaceAngleRoll",
    "oAngleVelPitch", "oAngleVelYaw", "oAngleVelRoll",
}) do
    assert(object[key] == 0, key .. " was not zeroed")
end
assert(GridTransform.snap_center(-135, 90) == -135, "negative cell center calculation failed")
assert(GridTransform.snap_center(0, 90) == 45, "origin did not snap to cell center")
assert(GridTransform.apply(nil, 90) == false, "nil object must be rejected")
print("PASS: fixed grid centers, zero Euler rotation and angular velocity")
