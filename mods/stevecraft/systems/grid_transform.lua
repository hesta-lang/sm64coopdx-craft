-- Enforces the voxel grid as an axis-aligned, square lattice.
local GridTransform = {}

local ANGLE_FIELDS = {
    "oMoveAnglePitch", "oMoveAngleYaw", "oMoveAngleRoll",
    "oFaceAnglePitch", "oFaceAngleYaw", "oFaceAngleRoll",
    "oAngleVelPitch", "oAngleVelYaw", "oAngleVelRoll",
}

function GridTransform.snap_center(value, cell_size)
    if type(value) ~= "number" or type(cell_size) ~= "number" or cell_size <= 0 then
        return nil
    end
    return math.floor(value / cell_size) * cell_size + cell_size * 0.5
end

function GridTransform.apply(object, cell_size)
    if object == nil then return false end
    local x = GridTransform.snap_center(object.oPosX, cell_size)
    local y = GridTransform.snap_center(object.oPosY, cell_size)
    local z = GridTransform.snap_center(object.oPosZ, cell_size)
    if x == nil or y == nil or z == nil then return false end

    object.oPosX = x
    object.oPosY = y
    object.oPosZ = z

    for _, field in ipairs(ANGLE_FIELDS) do
        object[field] = 0
    end
    return true
end

return GridTransform
